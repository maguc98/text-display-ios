// app/song-library.js — 歌曲库：把导入的音频 + LRC 存进 IndexedDB，重开应用自动恢复，音乐面板里显示歌曲列表
/* 设计要点
   1. 不改 player.js：包一层 #audioFile / #lrcFile 的 onchange，原有导入流程照常执行，我们只是“顺手存一份”。
   2. 数据库 yiufm-songs：songs 仓库放歌曲信息（很小，列表只读这个），files 仓库放音频本体（只在播放时才读）。
   3. 当前歌曲的 id 存在 localStorage（song_cur），启动时据此恢复音频；不会自动播放（iOS 不允许）。
   4. 依赖 player.js 里的全局：audio、TS、WT、LRC_META、karaCur、AUDIO_ON、parseLRC、applyLRC、setPlay、updateAudioInfo。 */
(function(){
  'use strict';

  var DB_NAME = 'yiufm-songs', CUR_KEY = 'song_cur';
  var $ = function(id){ return document.getElementById(id); };
  var songs = [];          // 歌曲信息列表（按添加时间从新到旧）
  var curId = null;        // 当前歌曲 id
  var dbp = null;          // 数据库 Promise
  var myURL = null;        // 本模块创建的音频临时链接
  var curCover = '';       // 当前歌曲的封面（dataURL；音频里没有内嵌封面则为空）

  if(!window.indexedDB){ buildPanel(); render('当前环境不支持保存歌曲'); return; }

  /* ---------------- IndexedDB 小工具 ---------------- */
  function openDB(){
    if(dbp) return dbp;
    dbp = new Promise(function(res, rej){
      var r = indexedDB.open(DB_NAME, 1);
      r.onupgradeneeded = function(){
        var d = r.result;
        if(!d.objectStoreNames.contains('songs')) d.createObjectStore('songs', {keyPath: 'id', autoIncrement: true});
        if(!d.objectStoreNames.contains('files')) d.createObjectStore('files', {keyPath: 'id'});
      };
      r.onsuccess = function(){ res(r.result); };
      r.onerror = function(){ rej(r.error); };
    });
    return dbp;
  }
  function wrap(r){ return new Promise(function(res, rej){ r.onsuccess = function(){ res(r.result); }; r.onerror = function(){ rej(r.error); }; }); }
  function txDone(tx){ return new Promise(function(res, rej){ tx.oncomplete = function(){ res(); }; tx.onerror = tx.onabort = function(){ rej(tx.error); }; }); }

  function loadList(){
    return openDB().then(function(db){ return wrap(db.transaction('songs').objectStore('songs').getAll()); })
      .then(function(list){ songs = (list || []).sort(function(a, b){ return b.added - a.added; }); });
  }
  function putMeta(s){ return openDB().then(function(db){ var tx = db.transaction('songs', 'readwrite'); tx.objectStore('songs').put(s); return txDone(tx); }); }
  function getFile(id){ return openDB().then(function(db){ return wrap(db.transaction('files').objectStore('files').get(id)); }); }
  function find(id){ for(var i = 0; i < songs.length; i++) if(songs[i].id === id) return songs[i]; return null; }

  function saveCur(){ try{ if(curId == null) localStorage.removeItem(CUR_KEY); else localStorage.setItem(CUR_KEY, String(curId)); }catch(_){} }
  function loadCur(){ try{ var v = localStorage.getItem(CUR_KEY); return v ? +v : null; }catch(_){ return null; } }


  /* ---------------- 内嵌封面：从音频文件里读出来 ----------------
     支持 mp3（ID3v2.2/2.3/2.4 的 APIC）、m4a/mp4（covr）、flac（PICTURE）。读不到就返回空字符串。 */
  function readBuf(blob, a, b){
    var part = blob.slice(a, b);
    if(part.arrayBuffer) return part.arrayBuffer();
    return new Promise(function(res, rej){ var r = new FileReader(); r.onload = function(){ res(r.result); }; r.onerror = function(){ rej(r.error); }; r.readAsArrayBuffer(part); });
  }
  function ascii(u, s, n){ var o = ''; for(var i = s; i < s + n && i < u.length; i++) o += String.fromCharCode(u[i]); return o; }
  function be32(u, p){ return u[p] * 16777216 + ((u[p + 1] << 16) | (u[p + 2] << 8) | u[p + 3]); }
  function syncsafe(u, p){ return ((u[p] & 0x7f) << 21) | ((u[p + 1] & 0x7f) << 14) | ((u[p + 2] & 0x7f) << 7) | (u[p + 3] & 0x7f); }
  function sniff(d){
    if(d[0] === 0xFF && d[1] === 0xD8) return 'image/jpeg';
    if(d[0] === 0x89 && d[1] === 0x50 && d[2] === 0x4E && d[3] === 0x47) return 'image/png';
    if(ascii(d, 0, 4) === 'GIF8') return 'image/gif';
    return '';
  }

  function parseAPIC(body, isV2){
    var enc = body[0], q = 1, mime;
    if(isV2){ mime = ascii(body, 1, 3).toLowerCase() === 'png' ? 'image/png' : 'image/jpeg'; q = 4; }
    else { var e = body.indexOf(0, 1); if(e < 0) return null; mime = ascii(body, 1, e - 1); q = e + 1; }
    var type = body[q]; q++;
    if(enc === 1 || enc === 2){ while(q + 1 < body.length && !(body[q] === 0 && body[q + 1] === 0)) q += 2; q += 2; }
    else { while(q < body.length && body[q] !== 0) q++; q++; }
    var data = body.subarray(q);
    return data.length > 8 ? {type: type, bytes: data, mime: sniff(data) || mime} : null;
  }
  function scanID3(u, ver, flags){
    var p = 0, best = null, hdr = ver === 2 ? 6 : 10;
    if(ver >= 3 && (flags & 0x40)) p = ver === 4 ? syncsafe(u, 0) : be32(u, 0) + 4;      // 跳过扩展头
    while(p + hdr <= u.length){
      var id, sz, fl = 0;
      if(ver === 2){ id = ascii(u, p, 3); sz = (u[p + 3] << 16) | (u[p + 4] << 8) | u[p + 5]; }
      else { id = ascii(u, p, 4); sz = ver === 4 ? syncsafe(u, p + 4) : be32(u, p + 4); fl = u[p + 9]; }
      if(!/^[A-Z0-9]{3,4}$/.test(id) || sz <= 0 || p + hdr + sz > u.length) break;       // 遇到填充区或坏数据就停
      if(id === 'APIC' || id === 'PIC'){
        var body = u.subarray(p + hdr, p + hdr + sz);
        if(ver === 4 && (fl & 0x01)) body = body.subarray(4);                              // 数据长度指示符
        var pic = parseAPIC(body, ver === 2);
        if(pic && (!best || (pic.type === 3 && best.type !== 3))) best = pic;
        if(best && best.type === 3) break;
      }
      p += hdr + sz;
    }
    return best;
  }
  function parseID3(blob){
    return readBuf(blob, 0, 10).then(function(b){
      var v = new Uint8Array(b);
      if(ascii(v, 0, 3) !== 'ID3') return null;
      var size = syncsafe(v, 6);
      return readBuf(blob, 10, 10 + Math.min(size, 16 * 1048576)).then(function(buf){ return scanID3(new Uint8Array(buf), v[3], v[5]); });
    });
  }

  function parseFlacPic(u){
    var type = be32(u, 0), ml = be32(u, 4), mime = ascii(u, 8, ml), p = 8 + ml;
    p += 4 + be32(u, p);                 // 描述
    p += 16;                             // 宽 高 色深 颜色数
    var n = be32(u, p); p += 4;
    var data = u.subarray(p, p + n);
    return data.length > 8 ? {type: type, bytes: data, mime: sniff(data) || mime} : null;
  }
  function flacWalk(blob, off, best){
    return readBuf(blob, off, off + 4).then(function(b){
      var h = new Uint8Array(b);
      if(h.length < 4) return best;
      var last = h[0] & 0x80, type = h[0] & 0x7f, len = (h[1] << 16) | (h[2] << 8) | h[3];
      function next(){ return (last || (best && best.type === 3)) ? best : flacWalk(blob, off + 4 + len, best); }
      if(type === 6 && len <= 16 * 1048576){
        return readBuf(blob, off + 4, off + 4 + len).then(function(bb){
          var pic = parseFlacPic(new Uint8Array(bb));
          if(pic && (!best || pic.type === 3)) best = pic;
          return next();
        });
      }
      return next();
    });
  }

  function mp4Walk(u, s, e, out){
    var p = s;
    while(p + 8 <= e){
      var sz = be32(u, p), t = ascii(u, p + 4, 4), hs = 8;
      if(sz === 1){ sz = be32(u, p + 8) * 4294967296 + be32(u, p + 12); hs = 16; } else if(sz === 0) sz = e - p;
      if(sz < 8 || p + sz > e) break;
      var bs = p + hs, be = p + sz;
      if(t === 'udta' || t === 'ilst') mp4Walk(u, bs, be, out);
      else if(t === 'meta') mp4Walk(u, bs + 4, be, out);
      else if(t === 'covr'){
        var q = bs;
        while(q + 16 <= be){
          var ds = be32(u, q);
          if(ds < 16 || q + ds > be) break;
          if(ascii(u, q + 4, 4) === 'data' && !out.pic){ var img = u.subarray(q + 16, q + ds); if(img.length > 8) out.pic = {type: 3, bytes: img, mime: sniff(img) || 'image/jpeg'}; }
          q += ds;
        }
      }
      p += sz;
    }
  }
  function mp4Top(blob, off){
    return readBuf(blob, off, off + 16).then(function(b){
      var v = new Uint8Array(b);
      if(v.length < 8) return null;
      var size = be32(v, 0), type = ascii(v, 4, 4), hdr = 8;
      if(size === 1){ size = be32(v, 8) * 4294967296 + be32(v, 12); hdr = 16; } else if(size === 0) size = blob.size - off;
      if(size < 8) return null;
      if(type === 'moov'){
        if(size > 64 * 1048576) return null;
        return readBuf(blob, off + hdr, off + size).then(function(bb){ var out = {}; mp4Walk(new Uint8Array(bb), 0, bb.byteLength, out); return out.pic || null; });
      }
      if(off + size >= blob.size) return null;
      return mp4Top(blob, off + size);
    });
  }

  function toDataURL(pic){
    return new Promise(function(res){
      var url = URL.createObjectURL(new Blob([pic.bytes], {type: pic.mime || 'image/jpeg'})), im = new Image();
      im.onload = function(){
        var out = '';
        try{
          var sc = Math.min(1, 640 / Math.max(im.width, im.height)), c = document.createElement('canvas'), x;
          c.width = Math.max(1, Math.round(im.width * sc)); c.height = Math.max(1, Math.round(im.height * sc));
          x = c.getContext('2d'); x.fillStyle = '#fff'; x.fillRect(0, 0, c.width, c.height); x.drawImage(im, 0, 0, c.width, c.height);
          out = c.toDataURL('image/jpeg', 0.86);
        }catch(_){}
        URL.revokeObjectURL(url); res(out);
      };
      im.onerror = function(){ URL.revokeObjectURL(url); res(''); };
      im.src = url;
    });
  }
  // 返回封面 dataURL；没有内嵌封面或解析失败都返回 ''
  function extractCover(blob){
    return readBuf(blob, 0, 12).then(function(b){
      var v = new Uint8Array(b);
      if(ascii(v, 0, 3) === 'ID3') return parseID3(blob);
      if(ascii(v, 0, 4) === 'fLaC') return flacWalk(blob, 4, null);
      if(ascii(v, 4, 4) === 'ftyp') return mp4Top(blob, 0);
      return null;
    }).then(function(pic){ return pic ? toDataURL(pic) : ''; }).catch(function(){ return ''; });
  }
  window.__extractCover = extractCover;       // 方便单独测试

  // 老版本存进去的歌没有 cover 字段：第一次用到时补提取并存回
  function ensureCover(id, rec){
    if(typeof rec.cover === 'string') return Promise.resolve(rec.cover);
    return extractCover(rec.blob).then(function(c){
      return openDB().then(function(db){ var tx = db.transaction('files', 'readwrite'); tx.objectStore('files').put({id: id, blob: rec.blob, cover: c}); return txDone(tx); })
        .then(function(){ return c; }, function(){ return c; });
    });
  }
  // 列表用的小封面：居中裁成正方形，96px，存进歌曲信息里（几 KB），列表不用读音频本体
  function makeThumb(src){
    return new Promise(function(res){
      if(!src) return res('');
      var im = new Image();
      im.onload = function(){
        try{
          var n = 96, c = document.createElement('canvas'), m = Math.min(im.width, im.height);
          c.width = c.height = n;
          c.getContext('2d').drawImage(im, (im.width - m) / 2, (im.height - m) / 2, m, m, 0, 0, n, n);
          res(c.toDataURL('image/jpeg', 0.8));
        }catch(_){ res(''); }
      };
      im.onerror = function(){ res(''); };
      im.src = src;
    });
  }
  var thumbBusy = false;
  function fillThumbs(){        // 老歌没有缩略图：一首一首补，补完存回
    if(thumbBusy) return;
    thumbBusy = true;
    (function next(){
      var s = null;
      for(var i = 0; i < songs.length; i++) if(typeof songs[i].thumb !== 'string'){ s = songs[i]; break; }
      if(!s){ thumbBusy = false; return; }
      getFile(s.id).then(function(rec){ return (rec && rec.blob && find(s.id)) ? ensureCover(s.id, rec) : ''; })
        .then(makeThumb)
        .then(function(t){ if(!find(s.id)) return; s.thumb = t; return putMeta(s); })
        .catch(function(){ if(typeof s.thumb !== 'string') s.thumb = ''; })
        .then(function(){ render(); next(); });
    })();
  }

  function loadCover(id, rec){
    return (rec ? Promise.resolve(rec) : getFile(id))
      .then(function(r){ return r ? ensureCover(id, r) : ''; })
      .then(function(c){ if(curId === id){ curCover = c || ''; syncNow(); } })
      .catch(function(){});
  }

  /* ---------------- 音乐模式：把歌名和封面交给迷你播放器 ----------------
     mini-player.js 每 200ms 读 window.__musicTitle / __musicCover：有值就显示歌名和封面，空就按原样（歌词句 + 自选封面）。 */
  function isMusicMode(){
    var b = $('btnModeMusic'), m = $('modeSlider');
    return !!((b && b.classList.contains('on')) || (m && m.classList.contains('is-music')));
  }
  function syncNow(){
    var s = curId != null ? find(curId) : null, on = isMusicMode() && !!s;
    window.__musicTitle = on ? s.name : '';
    window.__musicCover = on ? (s.custom || curCover) : '';
  }

  /* ---------------- 每首歌各自的自选封面 ----------------
     存在歌曲信息里：custom = 大图（裁好的 JPEG），cthumb = 列表用的 96px 小图。
     优先级：自选封面 > 音频里读出来的封面 > 默认样式。mini-player.js 通过下面三个 window 钩子来用它。 */
  window.__musicCoverTarget = function(){            // 现在该把选的图存给谁：音乐模式且有当前歌曲时返回歌曲 id，否则 null（走原来的全局自选封面）
    return (isMusicMode() && curId != null && find(curId)) ? curId : null;
  };
  window.__musicCoverSet = function(url, id){        // 保存成功返回 true
    var s = id != null ? find(id) : null;
    if(!s || !url) return false;
    s.custom = url; s.cthumb = url;                  // 先用大图顶上，列表立刻就变；96px 小图生成好后再换掉
    putMeta(s).catch(function(err){ console.error('保存自选封面失败', err); alert('保存封面失败：存储空间可能不足。'); });
    syncNow(); render();
    makeThumb(url).then(function(t){
      if(!t || !find(id) || s.custom !== url) return;
      s.cthumb = t; render(); return putMeta(s);
    }).catch(function(err){ console.error('保存自选封面失败', err); });
    return true;
  };
  window.__musicCoverReset = function(){             // 返回 'reset' = 已恢复默认；'keep' = 这首歌没有原封面，不允许恢复；'none' = 这首歌本来就没有自选封面；null = 不在音乐模式歌曲里（由调用方处理全局封面）
    var s = curId != null ? find(curId) : null;
    if(s && s.custom){
      if(!curCover && !s.thumb) return 'keep';       // 这首歌没有读取到原封面：自选封面就是它唯一的封面，没有可恢复的默认，不允许清掉（只能继续换图）
      delete s.custom; delete s.cthumb;
      putMeta(s).catch(function(err){ console.error('恢复默认封面失败', err); });
      syncNow(); render();
      return 'reset';
    }
    return (window.__musicTitle && s) ? 'none' : null;
  };
  function watchMode(){
    var nodes = [$('modeSlider'), $('btnModeMusic'), $('btnModeText')].filter(Boolean);
    if(window.MutationObserver && nodes.length){
      var mo = new MutationObserver(syncNow);
      nodes.forEach(function(n){ mo.observe(n, {attributes: true, attributeFilter: ['class']}); });
    }
    ['btnModeMusic', 'btnModeText'].forEach(function(id){
      var b = $(id);
      if(b) b.addEventListener('click', function(){ setTimeout(syncNow, 0); setTimeout(syncNow, 450); });
    });
    syncNow();
  }

  /* ---------------- 界面 ---------------- */
  var listEl = null, footEl = null;
  function buildPanel(){
    var panel = $('musicPanel');
    if(!panel || $('songLib')) return;
    var st = document.createElement('style');
    st.textContent =
      '#musicPanel{padding:2px 0 6px!important;text-align:left!important}' +
      '#musicPanel>:not(#songLib){display:none!important}' +
      '#songLib{margin:0;text-align:left;color:#fff}' +
      '#songLib .sl-head{margin:0 2px 8px;font-size:12px;color:rgba(255,255,255,.5);letter-spacing:.2px}' +
      '#songLib .sl-head:empty{display:none}' +
      '#songLib .sl-list{display:flex;flex-direction:column;gap:6px}' +
      '#songLib .sl-row{position:relative;display:flex;align-items:center;gap:11px;padding:8px;border-radius:16px;background:rgba(255,255,255,.07);cursor:pointer;-webkit-tap-highlight-color:transparent;transition:background .2s ease,transform .18s ease}' +
      '#songLib .sl-row:active{transform:scale(.985);background:rgba(255,255,255,.12)}' +
      '#songLib .sl-wrap{position:relative;border-radius:16px;overflow:hidden}' +
      '#songLib .sl-bg{position:absolute;top:0;right:0;bottom:0;width:0;display:flex;align-items:center;justify-content:flex-end;overflow:hidden;white-space:nowrap;border-radius:16px;background:#ff453a;color:#fff;font-size:14px;font-weight:600;pointer-events:none}' +
      '#songLib .sl-bg span{padding-right:22px}' +
      /* 遮罩只染色、不模糊，也不对整层做 opacity 动画（否则它会变成“背景根”，里面弹窗的高斯模糊就采不到后面的画面）*/
      '@keyframes slDlgIn{from{background-color:rgba(0,0,0,0)}to{background-color:rgba(0,0,0,.36)}}' +
      '@keyframes slDlgOut{from{background-color:rgba(0,0,0,.36)}to{background-color:rgba(0,0,0,0)}}' +
      '@keyframes slBoxIn{from{opacity:0;transform:translateY(10px) scale(.92)}to{opacity:1;transform:none}}' +
      '@keyframes slBoxOut{from{opacity:1;transform:none}to{opacity:0;transform:scale(.96)}}' +
      '#slDlg{position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483000;display:flex;align-items:center;justify-content:center;padding:24px;box-sizing:border-box;background-color:rgba(0,0,0,.36);-webkit-tap-highlight-color:transparent;animation:slDlgIn .26s ease both}' +
      '#slDlg.out{pointer-events:none;animation:slDlgOut .2s ease both}' +
      /* 弹窗本体：和主面板 / 歌词偏移尺一致 —— 深色玻璃底（--p-bg）+ 高斯模糊（--g-blur）+ 当前封面放大后的模糊光晕 */
      '#slDlg .sl-dlg-box{position:relative;isolation:isolate;overflow:hidden;width:min(100%,300px);border-radius:28px;padding:20px 16px 16px;box-sizing:border-box;text-align:center;color:#fff;' +
        'background:var(--p-bg,rgba(30,30,34,.7));-webkit-backdrop-filter:var(--g-blur,blur(23px));backdrop-filter:var(--g-blur,blur(23px));box-shadow:0 10px 30px rgba(0,0,0,.36);' +
        'animation:slBoxIn .34s cubic-bezier(.32,.72,0,1) both}' +
      '#slDlg .sl-dlg-box::before{content:"";position:absolute;inset:-60px;z-index:-1;pointer-events:none;background:var(--cover,linear-gradient(135deg,#3a3f55,#1c1c24)) center/cover no-repeat;filter:blur(44px) saturate(1.6);opacity:.4;transform:translateZ(0)}' +
      '#slDlg.out .sl-dlg-box{animation:slBoxOut .2s ease both}' +
      /* 阴影 / 高光：照抄主面板的各档 */
      'html body.ui-glow #slDlg .sl-dlg-box{box-shadow:0 10px 28px rgba(0,0,0,.32),inset 0 0 0 1px rgba(255,255,255,.2)!important}' +
      'html body.light-bg.ui-glow #slDlg .sl-dlg-box{box-shadow:0 8px 20px rgba(0,0,0,.10),inset 0 0 0 1px rgba(255,255,255,.2)!important}' +
      'html body.ui-shadow #slDlg .sl-dlg-box{box-shadow:0 14px 34px rgba(0,0,0,.26)!important}' +
      'html body.light-bg.ui-shadow #slDlg .sl-dlg-box{box-shadow:0 12px 28px rgba(0,0,0,.10)!important}' +
      'html body.ui-glow.ui-shadow #slDlg .sl-dlg-box{box-shadow:0 12px 30px rgba(0,0,0,.34),0 4px 12px rgba(0,0,0,.16),inset 0 0 0 1px rgba(255,255,255,.2)!important}' +
      'html body.light-bg.ui-glow.ui-shadow #slDlg .sl-dlg-box{box-shadow:0 10px 24px rgba(0,0,0,.10),0 3px 10px rgba(0,0,0,.06),inset 0 0 0 1px rgba(255,255,255,.2)!important}' +
      'html body.performance-mode.ui-shadow #slDlg .sl-dlg-box{box-shadow:0 8px 22px rgba(0,0,0,.18)!important}' +
      'html body.performance-mode.ui-glow #slDlg .sl-dlg-box{box-shadow:0 8px 22px rgba(0,0,0,.18),inset 0 0 0 1px rgba(255,255,255,.2)!important}' +
      '@media (prefers-reduced-motion:reduce){#slDlg,#slDlg .sl-dlg-box{animation-duration:.01s!important}}' +
      '#slDlg .sl-dlg-t{font-size:17px;font-weight:700;line-height:1.35}' +
      '#slDlg .sl-dlg-m{margin-top:8px;font-size:13px;line-height:1.55;color:var(--p-sub,rgba(255,255,255,.58));word-break:break-all}' +
      '#slDlg .sl-dlg-b{display:flex;gap:10px;margin-top:18px}' +
      '#slDlg .sl-dlg-b button{flex:1;height:42px;border:0;border-radius:14px;font-size:15px;font-weight:600;color:#fff;background:var(--p-fill2,rgba(255,255,255,.15));cursor:pointer;-webkit-tap-highlight-color:transparent}' +
      '#slDlg .sl-dlg-b button:active{opacity:.7}' +
      '#slDlg .sl-dlg-b button.ok{background:#ff453a}' +
      '#songLib .sl-row{touch-action:pan-y;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none}' +
      '#songLib .sl-row.on{background:rgba(143,176,255,.22);box-shadow:inset 0 0 0 1px rgba(143,176,255,.38)}' +
      '#songLib .sl-cov{flex:none;width:44px;height:44px;border-radius:11px;overflow:hidden;display:flex;align-items:center;justify-content:center;font-size:18px;font-weight:700;color:rgba(255,255,255,.92);text-shadow:0 1px 3px rgba(0,0,0,.25)}' +
      '#songLib .sl-cov img{width:100%;height:100%;object-fit:cover;display:block}' +
      '#songLib .sl-info{flex:1;min-width:0}' +
      '#songLib .sl-t{font-size:15px;font-weight:600;line-height:1.3;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}' +
      '#songLib .sl-row.on .sl-t{color:#b7ccff}' +
      '#songLib .sl-s{margin-top:2px;display:flex;align-items:center;gap:6px;font-size:12px;color:rgba(255,255,255,.55);white-space:nowrap;overflow:hidden}' +
      '#songLib .sl-s span{overflow:hidden;text-overflow:ellipsis}' +
      '#songLib .sl-tag{flex:none;padding:0 5px;border-radius:5px;font-size:10px;line-height:15px;font-style:normal;background:rgba(255,255,255,.14);color:rgba(255,255,255,.7)}' +
      '#songLib .sl-eq{flex:none;display:flex;align-items:flex-end;gap:2px;width:16px;height:14px}' +
      '#songLib .sl-eq i{flex:1;height:30%;border-radius:1px;background:#8fb0ff}' +
      '#songLib.playing .sl-eq i{animation:slEq .9s ease-in-out infinite}' +
      '#songLib.playing .sl-eq i:nth-child(2){animation-delay:-.3s;animation-duration:.75s}' +
      '#songLib.playing .sl-eq i:nth-child(3){animation-delay:-.6s;animation-duration:1.05s}' +
      '@keyframes slEq{0%,100%{height:25%}50%{height:100%}}' +
      'body.performance-mode #songLib .sl-eq i{animation:none!important}' +
      '@media (prefers-reduced-motion:reduce){#songLib .sl-eq i{animation:none!important}}' +
      '#songLib .sl-empty{display:flex;flex-direction:column;align-items:center;gap:10px;padding:26px 14px;font-size:13px;line-height:1.6;text-align:center;color:rgba(255,255,255,.55)}' +
      '#songLib .sl-empty svg{width:34px;height:34px;color:#8fb0ff;opacity:.8}';
    document.head.appendChild(st);
    var box = document.createElement('div');
    box.id = 'songLib';
    box.innerHTML = '<div class="sl-head" id="slFoot"></div><div class="sl-list" id="slList"></div>';
    panel.appendChild(box);
    listEl = $('slList'); footEl = $('slFoot');
    listEl.addEventListener('click', onListClick);
    listEl.addEventListener('pointerdown', swDown);
    listEl.addEventListener('pointermove', swMove);
    listEl.addEventListener('pointerup', swUp);
    listEl.addEventListener('pointercancel', swUp);
  }

  function fmtT(s){ if(!s || !isFinite(s)) return ''; var m = Math.floor(s / 60), x = Math.floor(s % 60); return m + ':' + (x < 10 ? '0' : '') + x; }
  function fmtSize(b){ return b >= 1048576 ? (b / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(b / 1024)) + ' KB'; }
  function esc(s){ return String(s).replace(/[&<>"]/g, function(c){ return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]; }); }

  var NOTE_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>';
  function coverHTML(s){
    var src = s.cthumb || s.thumb || (s.id === curId ? curCover : '');
    if(src) return '<div class="sl-cov"><img alt="" src="' + src + '"></div>';
    var h = (s.id * 47) % 360, ch = Array.from(String(s.name || '♪'))[0] || '♪';
    return '<div class="sl-cov" style="background:linear-gradient(135deg,hsl(' + h + ',42%,48%),hsl(' + ((h + 40) % 360) + ',46%,30%))">' + esc(ch.toUpperCase()) + '</div>';
  }
  function syncPlaying(){
    var box = $('songLib');
    if(box) box.classList.toggle('playing', typeof audio !== 'undefined' && !!audio && !audio.paused && !audio.ended);
  }

  function render(msg){
    syncNow();
    offSync();
    if(!listEl) buildPanel();
    if(!listEl) return;
    if(msg){ listEl.innerHTML = '<div class="sl-empty">' + esc(msg) + '</div>'; footEl.textContent = ''; return; }
    if(!songs.length){
      listEl.innerHTML = '<div class="sl-empty">' + NOTE_SVG + '<div>还没有保存的歌曲<br>在「设置 → Beta 版测试」里选择音频<br>会自动加入这里</div></div>';
      footEl.textContent = '';
      return;
    }
    var total = 0;
    listEl.innerHTML = songs.map(function(s){
      total += s.size || 0;
      var on = s.id === curId;
      var sub = [s.artist, fmtT(s.dur)].filter(Boolean).join(' · ') || fmtSize(s.size || 0);
      return '<div class="sl-wrap"><div class="sl-bg"><span>删除</span></div><div class="sl-row' + (on ? ' on' : '') + '" data-id="' + s.id + '">' + coverHTML(s) +
        '<div class="sl-info"><div class="sl-t">' + esc(s.name) + '</div><div class="sl-s"><span>' + esc(sub) + '</span>' + (s.lrc ? '<em class="sl-tag">词</em>' : '') + '</div></div>' +
        (on ? '<span class="sl-eq"><i></i><i></i><i></i></span>' : '') +
        '</div></div>';
    }).join('');
    footEl.textContent = '共 ' + songs.length + ' 首 · 占用 ' + fmtSize(total);
    syncPlaying();
  }

  /* 应用内确认框：有些 iOS 网页壳会拦截 window.confirm（不弹、直接当取消），所以自己画一个。返回 Promise<boolean> */
  function askConfirm(title, msg, okText){
    return new Promise(function(resolve){
      if(document.getElementById('slDlg')){ resolve(false); return; }
      var ov = document.createElement('div');
      ov.id = 'slDlg';
      ov.innerHTML = '<div class="sl-dlg-box" role="alertdialog" aria-modal="true"><div class="sl-dlg-t"></div><div class="sl-dlg-m"></div>' +
        '<div class="sl-dlg-b"><button type="button" data-k="0">取消</button><button type="button" class="ok" data-k="1"></button></div></div>';
      ov.querySelector('.sl-dlg-t').textContent = title;
      ov.querySelector('.sl-dlg-m').textContent = msg;
      ov.querySelector('.ok').textContent = okText || '确定';
      var done = false;
      function close(v){
        if(done) return; done = true;
        ov.classList.add('out');
        setTimeout(function(){ if(ov.parentNode) ov.parentNode.removeChild(ov); }, 230);
        resolve(v);
      }
      ov.addEventListener('pointerdown', function(e){ e.stopPropagation(); });
      ov.addEventListener('click', function(e){
        e.stopPropagation();
        var b = e.target.closest && e.target.closest('[data-k]');
        if(b) close(b.getAttribute('data-k') === '1');
        else if(e.target === ov) close(false);
      });
      try{                                                   // 封面光晕：把主面板上的 --cover 带过来（弹窗挂在 body 上，不一定能继承到）
        var hb = document.getElementById('hub'), cv = hb && getComputedStyle(hb).getPropertyValue('--cover');
        if(cv && cv.trim()) ov.style.setProperty('--cover', cv.trim());
      }catch(_){}
      document.body.appendChild(ov);
    });
  }

  function onListClick(e){
    if(performance.now() < swClickBlockUntil){ e.stopPropagation(); return; }   // 刚滑完，松手产生的 click 不算点击
    var row = e.target.closest && e.target.closest('.sl-row');
    if(row) selectSong(+row.getAttribute('data-id'), true);
  }

  /* ---------------- 左滑删除 ----------------
     向左拖动一行：整行跟手左移，右侧露出红色“删除”。拖过约 80px，或快速甩动，就走 removeSong()（仍会弹确认框）；
     否则、或确认框点了取消，就弹回原位。竖向滚动 / 向右拖不处理；斜着往左上、左下拖也算（偏离水平 60° 以内）。 */
  var sw = null, swClickBlockUntil = 0;

  function swDown(e){
    swClickBlockUntil = 0;
    if(e.isPrimary === false || (e.pointerType === 'mouse' && e.button !== 0)) return;
    var row = e.target.closest && e.target.closest('.sl-row');
    if(!row || !row.parentNode) return;
    sw = {id: e.pointerId, row: row, bg: row.parentNode.querySelector('.sl-bg'), x0: e.clientX, y0: e.clientY,
          dx: 0, v: 0, t: performance.now(), on: false, w: row.offsetWidth || 1};
  }

  function swMove(e){
    if(!sw || e.pointerId !== sw.id) return;
    if(!sw.row.isConnected || !sw.bg){ sw = null; return; }
    var mx = e.clientX - sw.x0, my = e.clientY - sw.y0;
    if(!sw.on){
      var ax = Math.abs(mx), ay = Math.abs(my);
      if(ay > 30 && ay > ax * 2.2){ sw = null; return; }                         // 明显竖向：交还给列表滚动
      if(mx > -10 || ax < ay * 0.6) return;                                      // 还没向左拖够，或太偏竖向：再观察（允许斜着往左下 / 左上拖，约 60° 以内都算）
      sw.on = true;
      sw.row.style.transition = 'none'; sw.bg.style.transition = 'none';
      try{ sw.row.setPointerCapture(e.pointerId); }catch(_){}
    }
    var dx = Math.min(sw.w, Math.max(0, -mx)), now = performance.now(), dt = now - sw.t;
    if(dt > 0) sw.v = 0.6 * ((dx - sw.dx) / dt) + 0.4 * sw.v;                   // 向左的速度（px/ms）
    sw.dx = dx; sw.t = now;
    sw.row.style.transform = 'translateX(' + (-dx) + 'px)';
    sw.bg.style.width = dx + 'px';
  }

  function swReset(s){
    if(!s.row.isConnected) return;
    s.row.style.transition = 'transform .25s cubic-bezier(.32,.72,0,1)';
    s.bg.style.transition = 'width .25s cubic-bezier(.32,.72,0,1)';
    s.row.style.transform = 'translateX(0)'; s.bg.style.width = '0';
    setTimeout(function(){
      s.row.style.transition = ''; s.row.style.transform = '';
      s.bg.style.transition = ''; s.bg.style.width = '';
    }, 300);
  }

  function swUp(e){
    if(!sw || e.pointerId !== sw.id) return;
    var s = sw; sw = null;
    if(!s.on) return;
    swClickBlockUntil = performance.now() + 400;
    try{ s.row.releasePointerCapture(e.pointerId); }catch(_){}
    var commit = s.dx > Math.min(s.w * 0.5, 80) || (s.v > 0.3 && s.dx > 30);      // 拖过约 80px，或快速甩一下（含被系统打断的 pointercancel）
    if(!commit){ swReset(s); return; }
    s.row.style.transition = 'transform .18s ease'; s.bg.style.transition = 'width .18s ease';
    s.row.style.transform = 'translateX(' + (-s.w) + 'px)'; s.bg.style.width = s.w + 'px';
    var id = +s.row.getAttribute('data-id');
    removeSong(id).then(function(ok){ if(!ok) swReset(s); });                    // 弹应用内确认框；取消就弹回
  }

  /* ---------------- 歌词偏移尺（每首歌各记一个） ----------------
     竖向刻度尺挂在 #hub 左侧、和面板底边对齐：拖动尺子，指针处的数值就是偏移（毫秒）。
     偏移写进 player.js 的全局 LYR_OFF（秒）：歌词用的时间 = 音频时间 − 偏移，所以正值 = 歌词延后，负值 = 提前。
     数值存在歌曲信息的 off 字段里，换歌自动换成那首歌自己的值。不动 TS / WT，随时可归零。 */
  var OFF_MAX = 1000, OFF_STEP = 10, PPM = 0.4;     // 范围 ±1000ms，每 10ms 一格，每 1ms 占 0.4px（一格 4px）
  var offMs = 0, offCur = 0, offId, offBox = null, offCv = null, offValEl = null;
  var offDown = false, offLastY = 0, offLastT = 0, offVel = 0, offRaf = 0, offTarget = null, offSaveT = 0;
  var offTapT = 0, offDownY = 0, offDownT = 0, offMoved = false;

  function clampOff(v){ return Math.max(-OFF_MAX, Math.min(OFF_MAX, v)); }
  function fmtOff(v){ return (v > 0 ? '+' : '') + v; }

  function offBuild(){
    var hub = $('hub');
    if(!hub || $('lyOff')) return;
    var st = document.createElement('style');
    st.textContent =
      '#lyOff{position:absolute;right:calc(100% + 8px);bottom:0;width:64px;height:clamp(200px,34vh,300px);display:none;flex-direction:column;border-radius:22px;overflow:hidden;' +
        'background:var(--p-bg,rgba(30,30,34,.7));-webkit-backdrop-filter:var(--g-blur,blur(23px));backdrop-filter:var(--g-blur,blur(23px));box-shadow:0 10px 30px rgba(0,0,0,.36);' +
        'touch-action:none;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;-webkit-tap-highlight-color:transparent;color:#fff;z-index:2}' +
      '#lyOff.show{display:flex}' +
      /* 和面板一样：深色玻璃底（--p-bg + 高斯模糊）上面，再叠一层当前封面放大后的模糊光晕（同 #hubGlow::before） */
      '#lyOff::before{content:"";position:absolute;inset:-60px;z-index:-1;pointer-events:none;background:var(--cover,linear-gradient(135deg,#3a3f55,#1c1c24)) center/cover no-repeat;filter:blur(44px) saturate(1.6);opacity:.4;transform:translateZ(0)}' +
      /* 阴影 / 高光：照抄 #hubGlass 的各档（柔和阴影、高光描边、浅色背景、性能模式） */
      'html body.ui-glow #lyOff{box-shadow:0 10px 28px rgba(0,0,0,.32),inset 0 0 0 1px rgba(255,255,255,.2)!important}' +
      'html body.light-bg.ui-glow #lyOff{box-shadow:0 8px 20px rgba(0,0,0,.10),inset 0 0 0 1px rgba(255,255,255,.2)!important}' +
      'html body.ui-shadow #lyOff{box-shadow:0 14px 34px rgba(0,0,0,.26)!important}' +
      'html body.light-bg.ui-shadow #lyOff{box-shadow:0 12px 28px rgba(0,0,0,.10)!important}' +
      'html body.ui-glow.ui-shadow #lyOff{box-shadow:0 12px 30px rgba(0,0,0,.34),0 4px 12px rgba(0,0,0,.16),inset 0 0 0 1px rgba(255,255,255,.2)!important}' +
      'html body.light-bg.ui-glow.ui-shadow #lyOff{box-shadow:0 10px 24px rgba(0,0,0,.10),0 3px 10px rgba(0,0,0,.06),inset 0 0 0 1px rgba(255,255,255,.2)!important}' +
      'html body.performance-mode.ui-shadow #lyOff{box-shadow:0 8px 22px rgba(0,0,0,.18)!important}' +
      'html body.performance-mode.ui-glow #lyOff{box-shadow:0 8px 22px rgba(0,0,0,.18),inset 0 0 0 1px rgba(255,255,255,.2)!important}' +
      '#lyOff .lo-v{flex:none;padding:10px 0 0;text-align:center;line-height:1.1}' +
      '#lyOff .lo-v b{display:block;font:700 14px/1.15 ui-monospace,SFMono-Regular,Menlo,monospace;font-variant-numeric:tabular-nums;transition:color .2s ease}' +
      '#lyOff.nz .lo-v b{color:#b7ccff}' +
      '#lyOff .lo-v em{font-style:normal;font-size:10px;color:rgba(255,255,255,.5)}' +
      '#lyOff canvas{flex:1;min-height:0;width:100%;display:block;-webkit-mask-image:linear-gradient(transparent,#000 18%,#000 82%,transparent);mask-image:linear-gradient(transparent,#000 18%,#000 82%,transparent)}';
    document.head.appendChild(st);
    offBox = document.createElement('div');
    offBox.id = 'lyOff';
    offBox.setAttribute('aria-label', '歌词时间偏移');
    offBox.innerHTML = '<div class="lo-v"><b id="loV">0</b><em>ms</em></div><canvas id="loC"></canvas>';
    hub.appendChild(offBox);
    offCv = $('loC'); offValEl = $('loV');
    offBox.addEventListener('pointerdown', offDownH);
    offBox.addEventListener('pointermove', offMoveH);
    offBox.addEventListener('pointerup', offUpH);
    offBox.addEventListener('pointercancel', offUpH);
    if(window.ResizeObserver) new ResizeObserver(offDraw).observe(offCv);
  }

  function offDraw(){
    var c = offCv; if(!c) return;
    var w = c.clientWidth, h = c.clientHeight;
    if(!w || !h) return;
    var dpr = Math.min(3, window.devicePixelRatio || 1), pw = Math.round(w * dpr), ph = Math.round(h * dpr);
    if(c.width !== pw || c.height !== ph){ c.width = pw; c.height = ph; }
    var x = c.getContext('2d');
    x.setTransform(dpr, 0, 0, dpr, 0, 0);
    x.clearRect(0, 0, w, h);
    var cy = h / 2, half = cy / PPM, v, y;
    var v0 = Math.ceil((offCur - half) / OFF_STEP) * OFF_STEP, v1 = Math.floor((offCur + half) / OFF_STEP) * OFF_STEP;
    x.font = '10px ui-monospace,SFMono-Regular,Menlo,monospace';
    x.textBaseline = 'middle';
    for(v = v0; v <= v1; v += OFF_STEP){
      if(v < -OFF_MAX || v > OFF_MAX) continue;
      y = Math.round(cy - (v - offCur) * PPM) - 0.5;
      var big = v % 100 === 0, mid = v % 50 === 0;
      x.fillStyle = 'rgba(255,255,255,' + (big ? 0.7 : mid ? 0.5 : 0.3) + ')';
      x.fillRect(12, y, big ? 16 : mid ? 11 : 7, 1);
      if(v % 200 === 0){ x.fillStyle = 'rgba(255,255,255,.55)'; x.fillText(v === 0 ? '0' : fmtOff(v), 34, y + 0.5); }
    }
    // 中间固定的指针：左边一个小三角 + 一条亮线
    x.fillStyle = '#fff';
    x.beginPath(); x.moveTo(0, cy - 5); x.lineTo(7, cy); x.lineTo(0, cy + 5); x.closePath(); x.fill();
    x.fillRect(8, cy - 1, 22, 2);
  }

  function offApply(){                 // 把 offCur 取整到 10ms，变了就生效 + 防抖保存
    var m = clampOff(Math.round(offCur / OFF_STEP) * OFF_STEP);
    if(m === offMs) return;
    offMs = m;
    LYR_OFF = m / 1000;
    offLabel();
    if(typeof startTick === 'function') startTick();       // 暂停时也让歌词立刻按新偏移刷新
    clearTimeout(offSaveT);
    offSaveT = setTimeout(function(){
      var s = find(offId);
      if(s && (s.off || 0) !== offMs){ s.off = offMs; putMeta(s).catch(function(){}); }
    }, 500);
  }
  function offLabel(){
    if(offValEl) offValEl.textContent = fmtOff(offMs);
    if(offBox) offBox.classList.toggle('nz', offMs !== 0);
  }
  function offStop(){ if(offRaf){ cancelAnimationFrame(offRaf); offRaf = 0; } offTarget = null; }
  function offLoop(){                  // 松手后：先惯性滑行，速度小了再吸附到最近的一格
    offRaf = 0;
    if(offOwnerGone()) return;
    if(offTarget == null){
      offCur = clampOff(offCur + offVel * 16);
      offVel *= 0.94;
      if(Math.abs(offCur) >= OFF_MAX) offVel = 0;
      if(Math.abs(offVel) < 0.01) offTarget = Math.round(offCur / OFF_STEP) * OFF_STEP;
    } else {
      var d = offTarget - offCur;
      if(Math.abs(d) < 0.05){ offCur = offTarget; offTarget = null; offVel = 0; offApply(); offDraw(); return; }
      offCur += d * 0.3;
    }
    offApply(); offDraw();
    offRaf = requestAnimationFrame(offLoop);
  }
  function offOwnerGone(){ return !offBox || !offBox.classList.contains('show'); }

  function offDownH(e){
    if(e.pointerType === 'mouse' && e.button !== 0) return;
    e.preventDefault();
    try{ offBox.setPointerCapture(e.pointerId); }catch(_){}
    offStop();
    offDown = true; offMoved = false; offVel = 0;
    offLastY = offDownY = e.clientY; offLastT = offDownT = e.timeStamp;
  }
  function offMoveH(e){
    if(!offDown) return;
    var dy = e.clientY - offLastY, dt = Math.max(1, e.timeStamp - offLastT);
    if(Math.abs(e.clientY - offDownY) > 6) offMoved = true;
    // 尺子跟着手指走：手指往下，尺子往下，指针处的数值变大（上面是正值）
    offCur = clampOff(offCur + dy / PPM);
    offVel = 0.7 * offVel + 0.3 * (dy / PPM / dt);
    offLastY = e.clientY; offLastT = e.timeStamp;
    offApply(); offDraw();
  }
  function offUpH(e){
    if(!offDown) return;
    offDown = false;
    try{ offBox.releasePointerCapture(e.pointerId); }catch(_){}
    if(!offMoved && e.timeStamp - offDownT < 300){        // 轻点：连点两下归零
      if(e.timeStamp - offTapT < 320){ offTapT = 0; offVel = 0; offTarget = 0; offRaf = requestAnimationFrame(offLoop); return; }
      offTapT = e.timeStamp;
    }
    if(e.timeStamp - offLastT > 80) offVel = 0;           // 停了一会儿再松手：不滑行
    offRaf = requestAnimationFrame(offLoop);
  }

  // 当前歌曲变了：换成这首歌自己的偏移；没有当前歌曲就藏起来
  function offSync(){
    if(!offBox) return;
    var s = curId != null ? find(curId) : null;
    if(curId !== offId){
      offStop(); clearTimeout(offSaveT);
      offId = curId;
      offMs = 0; LYR_OFF = 0;
      offCur = s ? clampOff(s.off || 0) : 0;
      offApply();                          // 取整并写入 LYR_OFF（这时不会触发保存：值没变化时直接返回；变了也只是写回同一个值）
    }
    offBox.classList.toggle('show', !!s);
    offLabel();
    if(s) offDraw();
  }

  /* ---------------- 导入：包一层原有的 onchange ---------------- */
  var MIME = {mp3: 'audio/mpeg', m4a: 'audio/mp4', aac: 'audio/aac', wav: 'audio/wav', flac: 'audio/flac', ogg: 'audio/ogg', opus: 'audio/ogg'};

  function addSong(f){
    var ext = (f.name.split('.').pop() || '').toLowerCase();
    var mime = f.type || MIME[ext] || 'audio/mpeg';
    var blob = (f.type === mime) ? f : f.slice(0, f.size, mime);
    var dup = null;
    for(var i = 0; i < songs.length; i++) if(songs[i].fn === f.name && songs[i].size === f.size){ dup = songs[i]; break; }
    if(dup){                                   // 同名同大小：不重复保存，直接指向已有的那首
      curId = dup.id; curCover = ''; saveCur(); render(); watchDuration(dup.id); loadCover(dup.id); return Promise.resolve(dup);
    }
    var meta = {name: f.name.replace(/\.[^.]+$/, ''), fn: f.name, artist: '', size: f.size, dur: 0, added: Date.now(), lrc: '', mime: mime};
    var cover = '';
    return extractCover(blob).then(function(c){ cover = c; return makeThumb(c); }).then(function(t){ meta.thumb = t; return openDB(); }).then(function(db){
      var tx = db.transaction(['songs', 'files'], 'readwrite');
      var rq = tx.objectStore('songs').add(meta);
      rq.onsuccess = function(){ meta.id = rq.result; tx.objectStore('files').put({id: meta.id, blob: blob, cover: cover}); };
      return txDone(tx);
    }).then(function(){
      songs.unshift(meta); curId = meta.id; curCover = cover; saveCur(); render(); watchDuration(meta.id);
      try{ if(navigator.storage && navigator.storage.persist) navigator.storage.persist(); }catch(_){}
      return meta;
    }).catch(function(err){
      console.error('保存歌曲失败', err);
      alert('保存歌曲失败：存储空间可能不足。这首歌这次仍可播放，但下次打开需要重新导入。');
    });
  }

  // 记下这首歌的时长（元数据读出来之后）
  function watchDuration(id){
    function save(){
      var s = find(id);
      if(!s || !isFinite(audio.duration) || audio.duration <= 0) return;
      if(Math.abs((s.dur || 0) - audio.duration) > 0.5){ s.dur = audio.duration; putMeta(s); render(); }
    }
    if(audio.readyState >= 1 && curId === id) { save(); return; }
    var h = function(){ audio.removeEventListener('loadedmetadata', h); if(curId === id) save(); };
    audio.addEventListener('loadedmetadata', h);
  }

  function readText(f){
    return new Promise(function(res, rej){
      var r = new FileReader();
      r.onload = function(){ res(r.result); };
      r.onerror = function(){ rej(r.error); };
      r.readAsText(f, 'utf-8');
    });
  }

  function attachLrc(txt){
    var s = find(curId);
    if(!s) return;                              // 还没有当前歌曲，没法绑定
    var meta = parseLRC(txt).meta || {};
    s.lrc = txt;
    if(meta.ti) s.name = meta.ti;
    if(meta.ar) s.artist = meta.ar;
    putMeta(s).then(render).catch(function(err){ console.error('保存歌词失败', err); });
  }

  function hookInputs(){
    var a = $('audioFile'), l = $('lrcFile');
    if(a){
      var origA = a.onchange;
      a.onchange = function(){
        var f = this.files && this.files[0];
        var ret = origA ? origA.apply(this, arguments) : undefined;   // 原流程会清空 input，所以先把文件取出来
        if(f) addSong(f);
        return ret;
      };
    }
    if(l){
      var origL = l.onchange;
      l.onchange = function(){
        var f = this.files && this.files[0];
        var ret = origL ? origL.apply(this, arguments) : undefined;
        if(f) readText(f).then(attachLrc).catch(function(err){ console.error('读取歌词失败', err); });
        return ret;
      };
    }
  }

  /* ---------------- 切歌 / 删除 / 启动恢复 ---------------- */
  function freeURL(){
    if(myURL){ URL.revokeObjectURL(myURL); myURL = null; }
    if(typeof releaseAudioObjectURL === 'function') releaseAudioObjectURL();   // player.js 自己创建的那个
  }

  function clearLyrics(){
    TS = []; WT = []; karaCur = null;
    LRC_META = {ti: '', ar: '', al: '', by: ''};
  }

  function selectSong(id, autoPlay){
    var s = find(id);
    if(!s) return Promise.resolve();
    return getFile(id).then(function(rec){
      if(!rec || !rec.blob){ alert('这首歌的音频数据找不到了，建议删除后重新导入。'); return; }
      // 先换歌词（此时旧音频还在，不会被 applyLRC 里的 currentTime 误伤），再换音频
      if(s.lrc){
        var parsed = parseLRC(s.lrc);
        if(parsed.items.length) applyLRC(parsed); else clearLyrics();
      } else clearLyrics();
      freeURL();
      myURL = URL.createObjectURL(rec.blob);
      curId = id; curCover = ''; saveCur(); render(); loadCover(id, rec);
      if(autoPlay){
        var h = function(){ audio.removeEventListener('loadedmetadata', h); if(curId === id && typeof setPlay === 'function') setPlay(true); };
        audio.addEventListener('loadedmetadata', h);
      }
      audio.src = myURL;
      audio.load();
      watchDuration(id);
      if(window.updateMusicPanel) window.updateMusicPanel();
    }).catch(function(err){
      console.error('切换歌曲失败', err);
      alert('切换歌曲失败，请重试。');
    });
  }

  /* 删除动画：整行向左滑出（左滑删除时已经在外面了就跳过这一步），再把这一行的高度收起来，下面的歌顶上来 */
  function slideOut(id){
    return new Promise(function(resolve){
      var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion:reduce)').matches;
      var row = listEl && listEl.querySelector('.sl-row[data-id="' + id + '"]');
      var wrap = row && row.parentNode, bg = wrap && wrap.querySelector('.sl-bg');
      if(reduce || !row || !bg){ resolve(); return; }
      var w = row.offsetWidth, h = wrap.offsetHeight, goal = 'translateX(' + (-w) + 'px)';
      var wait = row.style.transform === goal ? 0 : 230;
      wrap.style.height = h + 'px';
      void wrap.offsetHeight;
      if(wait){
        row.style.transition = 'transform .22s ease'; bg.style.transition = 'width .22s ease';
        row.style.transform = goal; bg.style.width = w + 'px';
      }
      setTimeout(function(){
        wrap.style.transition = 'height .26s ease,margin-bottom .26s ease,opacity .26s ease';
        wrap.style.height = '0'; wrap.style.marginBottom = '-6px'; wrap.style.opacity = '0';
        setTimeout(resolve, 270);
      }, wait);
    });
  }

  function removeSong(id){                      // 返回 Promise：true = 已删除，false = 取消或失败
    var s = find(id);
    if(!s) return Promise.resolve(false);
    return askConfirm('删除这首歌？', '「' + s.name + '」的音频和歌词都会从应用里移除。', '删除').then(function(ok){
     if(!ok) return false;
     return openDB().then(function(db){
      var tx = db.transaction(['songs', 'files'], 'readwrite');
      tx.objectStore('songs').delete(id);
      tx.objectStore('files').delete(id);
      return txDone(tx);
    }).then(function(){ return slideOut(id);
    }).then(function(){
      songs = songs.filter(function(x){ return x.id !== id; });
      if(curId === id){                         // 删的是正在播放的：停掉并清空音频（歌词卡片保留）
        try{ audio.pause(); }catch(_){}
        freeURL();
        audio.removeAttribute('src'); audio.load();
        AUDIO_ON = false;
        curId = null; curCover = ''; saveCur();
        updateAudioInfo();
      }
      render();
      if(window.updateMusicPanel) window.updateMusicPanel();
      return true;
    }).catch(function(err){ console.error('删除失败', err); alert('删除失败，请重试。'); return false; });
    });
  }

  // 启动：恢复上次播放的歌曲（只装载，不自动播放）
  function restore(){
    var id = loadCur();
    var s = id != null ? find(id) : null;
    if(!s){ curId = null; render(); return Promise.resolve(); }
    return getFile(id).then(function(rec){
      if(!rec || !rec.blob){ curId = null; saveCur(); render(); return; }
      curId = id; curCover = ''; render(); loadCover(id, rec);
      // 自动保存已经恢复了歌词文字和时间轴，这里只补回“逐字时间”（它没被自动保存），不去动卡片内容
      if(s.lrc){
        try{
          var p = parseLRC(s.lrc);
          if(p.items.length && p.items.length === TS.length){
            WT = p.items.map(function(x){ return x.wt || null; });
            karaCur = null;
          }
        }catch(_){}
      }
      myURL = URL.createObjectURL(rec.blob);
      audio.src = myURL;
      audio.load();
      watchDuration(id);
      if(window.updateMusicPanel) window.updateMusicPanel();
    });
  }

  window.addEventListener('pagehide', function(){ if(myURL) URL.revokeObjectURL(myURL); });

  /* ---------------- 启动 ---------------- */
  buildPanel();
  offBuild();
  if(typeof audio !== 'undefined' && audio){ ['play', 'playing', 'pause', 'ended', 'emptied'].forEach(function(ev){ audio.addEventListener(ev, syncPlaying); }); }
  hookInputs();
  watchMode();
  render('正在读取…');
  loadList().then(function(){ fillThumbs(); return restore().catch(function(err){ console.error('恢复上次歌曲失败', err); render(); }); }).catch(function(err){
    console.error('歌曲库初始化失败', err);
    render('歌曲库无法使用（可能是当前环境不允许保存数据）');
  });

  /* 启动默认进入音乐模式：模式按钮的点击逻辑在别的文件里、加载得比这里晚，
     所以等页面全部加载完再替用户点一下“音乐模式”按钮（已经是音乐模式就不动）。 */
  function defaultMusicMode(){
    var b = $('btnModeMusic');
    if(!b || isMusicMode() || document.body.classList.contains('music-mode')) return;
    b.click();
  }
  if(document.readyState === 'complete') setTimeout(defaultMusicMode, 400);
  else window.addEventListener('load', function(){ setTimeout(defaultMusicMode, 400); });

  window.SongLibrary = {list: function(){ return songs.slice(); }, select: selectSong, remove: removeSong, current: function(){ return curId; }};
})();
