// app/player.js — 音频、LRC、播放循环
/* ===== 音乐播放器核心状态 ===== */
var audio = document.getElementById('audio');
var AUDIO_ON = false;
var TS = [];
var LRC_META = {ti:'',ar:'',al:'',by:''};
var bag=null,shown="",txtT=0,curMode="";
function shuf(a){for(var i=a.length-1;i>0;i--){var j=Math.floor(Math.random()*(i+1)),t=a[i];a[i]=a[j];a[j]=t}}
function nextIdx(auto){
  if (window.playMode === 2) return idx; // 单曲循环模式，不切下一句
  if(auto&&window.__noLoop&&LN.length>1&&idx>=LN.length-1&&!$("shuf").checked){setPlay(false);return idx}
  var n=LN.length;
  if(!$("shuf").checked||n<2)return (idx+1)%n;
  if(bag===null){bag=[];for(var i=0;i<n;i++)if(i!==idx)bag.push(i);shuf(bag)}
  else if(!bag.length){bag=[];for(var j=0;j<n;j++)bag.push(j);shuf(bag);if(bag[bag.length-1]===idx)bag.unshift(bag.pop())}
  return bag.pop();
}
// 主播放循环只在播放期间持续运行；暂停时停止逐帧回调，恢复播放时再启动。
var tickRaf = 0;
var lastUiPaint = 0;  // UI 绘制节流
var lastTickTime = 0; // 上一次真正执行 tick 逻辑的时间，用于限制到约 30 FPS
var updatePending = false; // 切句渲染已排队、尚未执行
/* 切句渲染 update() 很重：不在 tick（rAF 回调）里同步执行，而是排到下一个任务。
   排队期间 idx 已经改了、但画面还是旧句，所以 tick 在此期间暂停推进，
   避免重复切句，也避免海报模式的旧 box 被误取消 out 状态而闪回。 */
function deferUpdate(){
  if(updatePending)return;
  updatePending=true;
  setTimeout(function(){updatePending=false;update();},0);
}

function startTick(){
  if(!tickRaf) tickRaf = requestAnimationFrame(tick);
}
function tick(ts){
  tickRaf = 0;
  if(playing) startTick();

  // 降频：播放中最高约 30 FPS（间隔不足 30ms 的帧直接跳过）。
  // 暂停时不跳过，保证暂停那一帧的状态/时间轴一定会被绘制。
  if(playing && ts - lastTickTime < 30) return;
  lastTickTime = ts;

  if(!last)last=ts;
  var dt=Math.min(.1,(ts-last)/1000);last=ts;
  if(updatePending)return; // 等排队的 update() 执行完再继续

  if(AUDIO_ON && audio && audio.duration && LN.length){
    var ct = audio.currentTime;
    var lo = 0, hi = Math.min(TS.length, LN.length) - 1, i = 0;
    while(lo <= hi){
      var mid = (lo + hi) >> 1;
      if((TS[mid] || 0) <= ct){ i = mid; lo = mid + 1; }
      else { hi = mid - 1; }
    }
    if(i !== idx){ idx = i; prog = 0; deferUpdate(); return; }
    var start = TS[idx] || 0;
    var end = (idx+1 < TS.length) ? TS[idx+1] : (audio.duration || start + 5);
    prog = Math.min(1, Math.max(0, (ct - start) / Math.max(0.1, end - start)));
    if(!playing){
      var now = performance.now();
      if(now - lastUiPaint > 100) { paintStat(); paintTL(); lastUiPaint = now; }
      return;
    }
  } else {
    if(!playing){
      var now = performance.now();
      if(now - lastUiPaint > 100) { paintStat(); paintTL(); lastUiPaint = now; }
      return;
    }
    prog += dt / secOf(idx);
    if(prog >= 1){ prog = 0; idx = nextIdx(true); deferUpdate(); return; }
  }

  if(curMode==="poster"&&cur){
    var _d=secOf(idx),_l=Math.min(.4,_d*.15),_o=prog*_d>=_d-_l;
    if(_o&&!cur._po){cur._po=1;cur.classList.add("out")}
    else if(!_o&&cur._po&&prog<1){cur._po=0;cur.classList.remove("out")}
  }

  // 节流：每 100ms 更新一次 UI 状态，降低重排压力
  var now = performance.now();
  if(now - lastUiPaint > 100) {
    paintStat();
    paintTL();
    lastUiPaint = now;
  }
}

var IC={
 pause:'<svg viewBox="0 0 24 24"><rect x="6" y="5" width="4.2" height="14" rx="2.1" fill="currentColor"/><rect x="13.8" y="5" width="4.2" height="14" rx="2.1" fill="currentColor"/></svg>',
 play:'<svg viewBox="0 0 24 24"><path d="M8.4 6.4v11.2L17.6 12z" fill="currentColor" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round"/></svg>',
 next:'<svg viewBox="0 0 24 24"><path d="M5.5 6.6v10.8L14.8 12z" fill="currentColor" stroke="currentColor" stroke-width="2.2" stroke-linejoin="round"/><path d="M18.8 6.2v11.6" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" fill="none"/></svg>'};
[].forEach.call(document.querySelectorAll(".ppb"),function(b){b.innerHTML=IC.pause});
[].forEach.call(document.querySelectorAll(".nxb"),function(b){b.innerHTML=IC.next});
function setPlay(v){
  playing=v;stage.classList.toggle("paused",!v);
  if(v) startTick();
  if(AUDIO_ON && audio){
    if(v) audio.play().catch(function(){
      // Safari may reject playback (for example, after a source or permission error).
      // Keep the UI and animation loop in sync with the actual playback state.
      if(playing && audio.paused) setPlay(false);
    });
    else audio.pause();
  }
  [].forEach.call(document.querySelectorAll(".ppb"),function(b){b.innerHTML=v?IC.pause:IC.play});
}
function gotoIdx(i, playNow){
  idx = i; prog = 0;
  if(AUDIO_ON && audio && TS.length) audio.currentTime = TS[i] || 0;
  update();
  if(playNow && !playing) setPlay(true);
}
/* ---- LRC 解析 ---- */
function parseLRC(txt){
  var lines = String(txt).split(/\r?\n/), out = [], meta = {};
  var re = /\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;
  lines.forEach(function(line){
    var m = line.match(/^\[(ti|ar|al|by|offset):(.*)\]\s*$/i);
    if(m){ meta[m[1].toLowerCase()] = m[2].trim(); return; }
    re.lastIndex = 0;
    var times = [], mm;
    while((mm = re.exec(line))){
      var frac = mm[3] ? parseFloat('0.' + mm[3]) : 0;
      times.push(+mm[1]*60 + +mm[2] + frac);
    }
    if(!times.length) return;
    var text = line.replace(re, '').trim();
    if(!text) return;
    times.forEach(function(t){ out.push({t:t, text:text}); });
  });
  out.sort(function(a,b){ return a.t - b.t; });
  return {items: out, meta: meta};
}

function applyLRC(lrc){
  var its = lrc.items;
  if(!its.length){ alert('这个 LRC 里没有解析到歌词'); return; }
  LRC_META = lrc.meta || {};
  var cards = document.querySelectorAll('#cards .card');
  if(cards.length === its.length){
    cards.forEach(function(c, i){
      var ta = c.querySelector('textarea');
      if(ta){ ta.value = its[i].text; ta.dispatchEvent(new Event('input')); }
    });
  } else {
    window.__setCards(its.map(function(x){ return {t: x.text}; }));
  }
  TS = its.map(function(x){ return x.t; });
  idx = 0; prog = 0;
  if(AUDIO_ON && audio && TS.length) audio.currentTime = TS[0] || 0;
  refreshAll();
  updateAudioInfo();
  if(window.updateMusicPanel) window.updateMusicPanel();
}

function fmtDur(s){
  if(!s || !isFinite(s)) return '--:--';
  var m = Math.floor(s/60), sec = Math.floor(s%60);
  return m + ':' + (sec<10?'0':'') + sec;
}
function updateAudioInfo(){
  var el = document.getElementById('audioInfo');
  if(!el) return;
  if(!audio.src){ el.textContent = '未加载音频 · 当前为固定时长模式'; return; }
  var name = LRC_META.ti || decodeURIComponent((audio.src.split('/').pop()||'音频').split('?')[0]);
  var ar = LRC_META.ar ? ' · ' + LRC_META.ar : '';
  el.textContent = name + ar + ' · ' + fmtDur(audio.duration);
}

document.getElementById('pickAudio').onclick = function(){ document.getElementById('audioFile').click(); };
// 记录本页创建的音频临时 URL；重复选择音频时释放旧 URL，避免长期使用时积累资源。
var audioObjectURL = null;
function releaseAudioObjectURL(){
  if(audioObjectURL){
    URL.revokeObjectURL(audioObjectURL);
    audioObjectURL = null;
  }
}
document.getElementById('audioFile').onchange = function(){
  var f = this.files[0]; this.value = ''; if(!f) return;
  releaseAudioObjectURL();
  audioObjectURL = URL.createObjectURL(f);
  audio.src = audioObjectURL;
  audio.load();
};
window.addEventListener('pagehide', releaseAudioObjectURL);
document.getElementById('pickLrc').onclick = function(){ document.getElementById('lrcFile').click(); };
document.getElementById('lrcFile').onchange = function(){
  var f = this.files[0]; this.value = ''; if(!f) return;
  var r = new FileReader();
  r.onload = function(){ applyLRC(parseLRC(r.result)); };
  r.readAsText(f, 'utf-8');
};

audio.addEventListener('loadedmetadata', function(){
  AUDIO_ON = true;
  if(LN.length && TS.length !== LN.length){
    var d = audio.duration || 0, n = LN.length;
    if(d > 0 && isFinite(d)){
      TS = [];
      for(var k = 0; k < n; k++) TS.push(d * k / n);
    }
  }
  updateAudioInfo();
  refreshAll();
});
audio.addEventListener('play',  function(){ playing = true; startTick(); stage.classList.remove('paused'); [].forEach.call(document.querySelectorAll('.ppb'),function(b){b.innerHTML=IC.pause}); });
audio.addEventListener('pause', function(){ playing = false; stage.classList.add('paused');    [].forEach.call(document.querySelectorAll('.ppb'),function(b){b.innerHTML=IC.play});  });
audio.addEventListener('ended', function(){
  if(window.__noLoop){ setPlay(false); return; }
  if(document.getElementById('shuf').checked){ gotoIdx(nextIdx(true), true); }
  else { gotoIdx(0, true); }
});
audio.addEventListener('error', function(){
  AUDIO_ON = false;
  updateAudioInfo();
});
/* 已取消：点击屏幕暂停/播放
stage.addEventListener("click",function(e){
  setPlay(!playing);
});
*/
[].forEach.call(document.querySelectorAll(".ppb"),function(b){b.onclick=function(e){e.stopPropagation();setPlay(!playing)}});
[].forEach.call(document.querySelectorAll(".nxb"),function(b){b.onclick=function(e){e.stopPropagation();gotoIdx(nextIdx(),false)}});
