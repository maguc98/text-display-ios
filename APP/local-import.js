// app/local-import.js — 批量导入：从「文件」App 多选 音频 + 同名 LRC + 同名封面图 + 同名 .meta.json，自动配对后交给歌曲库入库
/* 设计要点
   1. 不另建数据库：持久化、去重、封面提取、播放、删除都由 song-library.js（IndexedDB yiufm-songs）负责，
      本文件只做「多选 → 按文件名分类配对 → 交给 SongLibrary.importScanned」。所以播放层不用改，blob URL 的释放也沿用 song-library 里的 freeURL。
   2. 文件名配对：去扩展名（.meta.json 当一个整体去掉）、统一成 NFC、忽略大小写，iOS 文件名可能是 NFD。
   3. 不设 accept：iOS 文件选择器对 .lrc / .json 这类没有系统类型的扩展名，加了 accept 反而会灰掉，所以选完再自己过滤。
   4. 选择器的 <input> 一直留在页面里，导入完成后才清空，避免 iOS 上 File 提前失效。
   API（和原需求保持同名）：
     LocalImport.pick()    → Promise<{added, updated, skipped, failed, total, ignored:[文件名]}>
     LocalImport.all()     → 歌曲信息数组    LocalImport.remove(id)  LocalImport.clear()    LocalImport.quota() → {used, quota} | null
   事件：'local-import-ready'  detail = {added, updated, skipped, failed, total, ignored} */
(function(){
  'use strict';

  var AUDIO_RE = /\.(mp3|m4a|flac|wav|aac|ogg|opus)$/i;
  var IMG_RE   = /\.(jpe?g|png|webp)$/i;
  var LRC_RE   = /\.lrc$/i;
  var META_RE  = /\.json$/i;

  function nfc(t){ try{ return String(t).normalize('NFC'); }catch(_){ return String(t); } }
  function baseOf(name){ return nfc(name).replace(/\.meta\.json$/i, '').replace(/\.[^.]+$/, '').toLowerCase(); }

  /* ---------- 读文本：UTF-8 / UTF-16 BOM / GB18030 依次尝试，去掉 BOM ---------- */
  function readBytes(f){
    if(f.arrayBuffer) return f.arrayBuffer();
    return new Promise(function(res, rej){ var r = new FileReader(); r.onload = function(){ res(r.result); }; r.onerror = function(){ rej(r.error); }; r.readAsArrayBuffer(f); });
  }
  function decode(buf){
    var u = new Uint8Array(buf), t;
    if(u[0] === 0xFF && u[1] === 0xFE) return new TextDecoder('utf-16le').decode(u.subarray(2));
    if(u[0] === 0xFE && u[1] === 0xFF) return new TextDecoder('utf-16be').decode(u.subarray(2));
    try{ t = new TextDecoder('utf-8', {fatal: true}).decode(u); }
    catch(_){ try{ t = new TextDecoder('gb18030').decode(u); }catch(__){ t = new TextDecoder('utf-8').decode(u); } }
    return t.replace(/^\uFEFF/, '');
  }
  function readText(f){ return readBytes(f).then(decode); }

  /* ---------- 分类配对 ---------- */
  function classify(files){
    var groups = {}, order = [], ignored = [];
    function g(b){ if(!groups[b]){ groups[b] = {}; order.push(b); } return groups[b]; }
    files.forEach(function(f){
      var n = f.name || '';
      if(n.indexOf('._') === 0 || n.charAt(0) === '.') return;                 // 隐藏文件
      if(AUDIO_RE.test(n)){ var a = g(baseOf(n)); if(a.audio) ignored.push(n); else a.audio = f; }   // 同名不同格式只收第一个
      else if(LRC_RE.test(n)) g(baseOf(n)).lrc = f;
      else if(IMG_RE.test(n)) g(baseOf(n)).cover = f;
      else if(META_RE.test(n)) g(baseOf(n)).metaFile = f;
      else ignored.push(n);
    });
    var list = [];
    order.forEach(function(b){ if(groups[b].audio) list.push(groups[b]); });     // 没有音频的孤立附属文件静默丢弃
    return {groups: list, ignored: ignored};
  }

  // meta.json 里的 coverPath 是带 App 安装 UUID 的绝对路径，不可信：只取文件名，去本批文件里找
  function resolveMeta(group, files){
    if(!group.metaFile) return Promise.resolve();
    return readText(group.metaFile).then(function(txt){
      var meta = JSON.parse(txt);
      if(!meta || typeof meta !== 'object') return;
      group.meta = meta;
      if(!group.cover && meta.coverPath){
        var cn = nfc(String(meta.coverPath).split('/').pop()).toLowerCase();
        for(var i = 0; i < files.length; i++){
          if(IMG_RE.test(files[i].name) && nfc(files[i].name).toLowerCase() === cn){ group.cover = files[i]; break; }
        }
      }
    }).catch(function(){});                                                      // meta 坏了就当没有
  }

  function toItem(g){
    var it = {name: g.audio.name, size: g.audio.size, src: 'local', getBlob: function(){ return Promise.resolve(g.audio); }};
    if(g.lrc) it.getLrc = function(){ return readText(g.lrc); };
    if(g.cover) it.getCover = function(){ return Promise.resolve(g.cover); };
    if(g.meta) it.meta = g.meta;
    return it;
  }

  /* ---------- 选择器 ---------- */
  var inp = null, pending = null;
  function ensureInput(){
    if(inp) return inp;
    inp = document.createElement('input');
    inp.type = 'file'; inp.multiple = true; inp.className = 'hide';
    inp.setAttribute('aria-hidden', 'true');
    document.body.appendChild(inp);
    inp.addEventListener('change', function(){
      var files = Array.prototype.slice.call(inp.files || []), done = pending;
      pending = null;
      if(!done) return;
      run(files, done.onProgress).then(function(r){ inp.value = ''; done.resolve(r); });   // 全部入库完才清空 input
    });
    return inp;
  }

  function empty(ignored){ return {added: 0, updated: 0, skipped: 0, failed: 0, total: 0, ignored: ignored || []}; }

  function run(files, onProgress){
    if(!files.length) return Promise.resolve(empty());
    var c = classify(files);
    if(!window.SongLibrary || !window.SongLibrary.importScanned){
      var r0 = empty(c.ignored); r0.failed = c.groups.length; return Promise.resolve(r0);
    }
    return Promise.all(c.groups.map(function(g){ return resolveMeta(g, files); })).then(function(){
      return window.SongLibrary.importScanned(c.groups.map(toItem), {manual: true, onProgress: onProgress});
    }).then(function(stat){
      stat.total = c.groups.length; stat.ignored = c.ignored;
      window.dispatchEvent(new CustomEvent('local-import-ready', {detail: stat}));
      return stat;
    }).catch(function(e){
      console.warn('[local-import] 导入失败', e);
      var r = empty(c.ignored); r.failed = c.groups.length; r.total = c.groups.length; return r;
    });
  }

  var api = {};
  api.pick = function(opts){
    opts = opts || {};
    var i = ensureInput();
    if(pending){ pending.resolve(empty()); pending = null; }                    // 上一次选了一半取消的
    return new Promise(function(resolve){
      pending = {resolve: resolve, onProgress: opts.onProgress};
      i.click();
    });
  };
  api.all    = function(){ return window.SongLibrary ? window.SongLibrary.list() : []; };
  api.remove = function(id){ return window.SongLibrary ? window.SongLibrary.remove(id) : undefined; };
  api.clear  = function(){ return window.SongLibrary && window.SongLibrary.clearAll ? window.SongLibrary.clearAll() : Promise.resolve(); };
  api.quota  = function(){
    if(!navigator.storage || !navigator.storage.estimate) return Promise.resolve(null);
    return navigator.storage.estimate().then(function(e){ return {used: e.usage || 0, quota: e.quota || 0}; }, function(){ return null; });
  };
  window.LocalImport = api;

  /* ---------- 设置 → 数据备份 → 本地导入管理 ---------- */
  var $ = function(id){ return document.getElementById(id); };
  var btnTimer = 0;
  function mb(n){ return (n / 1048576).toFixed(1) + ' MB'; }
  function showQuota(){
    var el = $('localQuota'); if(!el) return;
    api.quota().then(function(q){
      var n = api.all().length;
      el.textContent = q ? ('已导入 ' + n + ' 首 · 已用 ' + mb(q.used) + ' / 可用 ' + mb(q.quota)) : ('已导入 ' + n + ' 首 · 当前环境不支持查询存储空间');
    });
  }
  function setBtn(t){ var b = $('localImportBtn'); if(b) b.textContent = t; }
  function summary(r){
    if(!r.total) return r.ignored.length ? '没有可导入的音频' : '未选择文件';
    var m = r.added || r.updated ? ('新增 ' + r.added + ' 首' + (r.updated ? '，补歌词 ' + r.updated + ' 首' : '')) : '没有新歌（已存在）';
    if(r.failed) m += '（' + r.failed + ' 首失败）';
    return m;
  }

  function bindUI(){
    var bi = $('localImportBtn'), bc = $('localClearBtn');
    if(bi) bi.addEventListener('click', function(){
      if(bi.disabled) return;
      api.quota().then(function(q){
        if(q && q.quota && q.quota - q.used < 500 * 1048576 && !confirm('剩余存储空间不足 500MB，继续导入可能失败。是否继续？')) return;
        bi.disabled = true; clearTimeout(btnTimer);
        return api.pick({onProgress: function(i, n){ setBtn('导入中 ' + i + ' / ' + n); }}).then(function(r){
          console.log('[local-import] 完成', r);
          setBtn(summary(r) + (r.ignored.length ? ' · 忽略 ' + r.ignored.length + ' 个' : ''));
          showQuota();
        }).then(function(){ bi.disabled = false; btnTimer = setTimeout(function(){ setBtn('批量导入'); }, 3000); });
      });
    });
    if(bc) bc.addEventListener('click', function(){
      if(!api.all().length){ alert('还没有导入的歌曲。'); return; }
      if(!confirm('确定清空所有已导入的歌曲？音频和歌词都会从应用里移除，此操作不可恢复。\n（文件 App 里的原文件不受影响。）')) return;
      api.clear().then(showQuota, function(e){ console.error(e); alert('清空失败，请重试。'); });
    });
    showQuota();
    window.addEventListener('local-import-ready', showQuota);
    window.addEventListener('ios-music-ready', showQuota);
    // 请求持久化存储，降低被系统清理的概率
    try{ if(navigator.storage && navigator.storage.persist) navigator.storage.persist().then(function(ok){ console.log('[storage] 持久化:', ok ? '已授予' : '被拒绝'); }); }catch(_){}
  }
  bindUI();
  if(window.SongLibrary === undefined) setTimeout(showQuota, 1500);
})();
