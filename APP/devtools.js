// app/devtools.js — 开发者相关
(function(){
  var el=document.getElementById('performanceMode');
  if(!el)return;
  var saved=null;
  try{saved=localStorage.getItem('performanceMode')}catch(_){}
  var enabled=saved===null?true:saved==='1';
  el.checked=enabled;
  el.addEventListener('change',function(){
    var on=!!el.checked;
    document.body.classList.toggle('performance-mode',on);
    try{localStorage.setItem('performanceMode',on?'1':'0')}catch(_){}
    window.dispatchEvent(new Event('performance-mode-change'));
  });
})();
/* ==========================================================
 * 实时日志系统
 * - 拦截 console.* / window.onerror / unhandledrejection
 * - 面板：底部滑出，深色玻璃，实时刷新
 * - 入口：#pg5 系统设置里的"实时日志"按钮，或 __openLogPanel()
 * ========================================================== */
(function(){
  'use strict';
  if (window.__loggerInstalled) return;
  window.__loggerInstalled = true;

  /* ---------- 配置 ---------- */
  var MAX_LOGS = 800;      // 内存中最多保留
  var MAX_DOM  = 500;      // DOM 中最多保留
  var FLUSH_MS = 120;      // 批量刷新间隔
  var LV = ['debug','log','info','warn','error'];

  /* ---------- 状态 ---------- */
  var logs = [];           // { id, t, level, text }
  var seq = 0;
  var renderedUpTo = 0;
  var panelOpen = false;
  var dirty = false;
  var timerId = 0;
  var inLog = false;
  var autoScroll = true;
  var filters = { debug:true, log:true, info:true, warn:true, error:true };
  var orig = {};
  LV.forEach(function(k){ orig[k] = console[k] || function(){}; });

  /* ---------- 工具 ---------- */
  function safeStr(v){
    if (typeof v === 'string') return v;
    if (v instanceof Error) return (v.stack || (v.name + ': ' + v.message));
    if (v === null) return 'null';
    if (v === undefined) return 'undefined';
    if (typeof v === 'function') return '[Function ' + (v.name || 'anonymous') + ']';
    if (typeof v === 'object'){
      try {
        if (v.nodeType === 1) return '[<' + (v.nodeName || '?').toLowerCase() + '>]';
        if (v.nodeType === 3) return '[#text]';
        return JSON.stringify(v);
      } catch(e){
        try { return Object.prototype.toString.call(v); } catch(_){ return '[Object]'; }
      }
    }
    return String(v);
  }

  function fmtTime(t){
    var d = new Date(t);
    function p(n, l){ n = String(n); while (n.length < (l || 2)) n = '0' + n; return n; }
    return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds()) + '.' + p(d.getMilliseconds(), 3);
  }

  function push(level, args){
    if (inLog || window.__logPaused) return; // 开发者选项里的「暂停抓取日志」
    inLog = true;
    try {
      var parts = [];
      for (var i = 0; i < args.length; i++) parts.push(safeStr(args[i]));
      var entry = { id: ++seq, t: Date.now(), level: level, text: parts.join(' ') };
      logs.push(entry);
      if (logs.length > MAX_LOGS) logs.splice(0, logs.length - MAX_LOGS);
      if (panelOpen) markDirty();
    } catch(e){
      /* 日志系统自身出错不能影响主流程 */
    } finally {
      inLog = false;
    }
  }

  /* ---------- 拦截 console ---------- */
  LV.forEach(function(level){
    console[level] = function(){
      push(level, arguments);
      try { return orig[level].apply(console, arguments); } catch(_){}
    };
  });

  /* ---------- 全局错误 ---------- */
  window.addEventListener('error', function(e){
    if (e.target && e.target !== window && e.target.nodeType === 1){
      var src = e.target.src || e.target.href || '';
      push('error', ['资源加载失败: ' + src + ' <' + (e.target.nodeName || '?').toLowerCase() + '>']);
      return;
    }
    var msg = e.message || 'Unknown error';
    var loc = e.filename ? (e.filename.split('/').pop() + ':' + (e.lineno||0) + ':' + (e.colno||0)) : '';
    var stack = e.error && e.error.stack ? ('\n' + e.error.stack) : '';
    push('error', [msg + (loc ? (' @ ' + loc) : '') + stack]);
  }, true);

  window.addEventListener('unhandledrejection', function(e){
    var r = e.reason;
    var msg = (r && r.stack) ? r.stack : safeStr(r);
    push('error', ['Unhandled Rejection: ' + msg]);
  });

  /* ---------- 样式注入 ---------- */
  var CSS = ''
    + '#logMask{position:fixed;inset:0;z-index:99998;background:rgba(0,0,0,.55);opacity:0;visibility:hidden;transition:opacity calc(.3s/var(--ui-spd,1)) ease,visibility 0s calc(.3s/var(--ui-spd,1));pointer-events:none}'
    + '#logMask.show{opacity:1;visibility:visible;transition:opacity calc(.3s/var(--ui-spd,1)) ease,visibility 0s;pointer-events:auto}'
    + '#logPanel{position:fixed;left:0;right:0;bottom:0;height:82vh;z-index:99999;display:flex;flex-direction:column;'
    + 'background:rgba(16,18,24,.94);-webkit-backdrop-filter:var(--g-blur) saturate(1.4);backdrop-filter:var(--g-blur) saturate(1.4);'
    + 'border-radius:22px 22px 0 0;border-top:1px solid rgba(255,255,255,.14);color:#e8e8ea;'
    + 'font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,"PingFang SC",monospace;font-size:12.5px;'
    + 'transform:translateY(100%);transition:transform calc(.35s/var(--ui-spd,1)) cubic-bezier(.3,1,.4,1);'
    + 'padding-bottom:env(safe-area-inset-bottom,0);box-shadow:0 -10px 40px rgba(0,0,0,.45);will-change:transform}'
    + '#logPanel.show{transform:none}'
    + '#logPanel .lp-head{flex:none;display:flex;align-items:center;gap:8px;padding:10px 14px 8px;border-bottom:1px solid rgba(255,255,255,.08);touch-action:none}'
    + '#logPanel .lp-title{font-size:13.5px;font-weight:700;color:#fff;flex:1;min-width:0}'
    + '#logPanel .lp-title em{font-style:normal;color:rgba(255,255,255,.55);font-weight:500;margin-left:6px;font-size:12px}'
    + '#logPanel .lp-head button{border:none;background:rgba(255,255,255,.1);color:#fff;height:28px;padding:0 10px;border-radius:9px;font:inherit;font-size:12px;display:inline-flex;align-items:center;justify-content:center;gap:4px;cursor:pointer}'
    + '#logPanel .lp-head button:active{background:rgba(255,255,255,.22)}'
    + '#logPanel .lp-head button.close{width:28px;padding:0;background:rgba(255,255,255,.14)}'
    + '#logPanel .lp-filters{flex:none;display:flex;gap:6px;padding:8px 14px;flex-wrap:wrap;border-bottom:1px solid rgba(255,255,255,.06)}'
    + '#logPanel .lp-filters button{border:none;background:rgba(255,255,255,.06);color:rgba(255,255,255,.55);height:24px;padding:0 9px;border-radius:8px;font:inherit;font-size:11px;font-weight:600;letter-spacing:.3px;cursor:pointer}'
    + '#logPanel .lp-filters button.on{background:rgba(143,176,255,.5);color:#fff}'
    + '#logPanel .lp-filters button[data-lv="error"].on{background:rgba(255,90,110,.6)}'
    + '#logPanel .lp-filters button[data-lv="warn"].on{background:rgba(255,190,80,.6);color:#1a1a1a}'
    + '#logPanel .lp-body{flex:1;min-height:0;overflow-y:auto;overscroll-behavior:contain;-webkit-overflow-scrolling:touch;padding:6px 10px 10px;scrollbar-width:thin;scrollbar-color:rgba(255,255,255,.3) transparent}'
    + '#logPanel .lp-body::-webkit-scrollbar{width:6px}'
    + '#logPanel .lp-body::-webkit-scrollbar-thumb{background:rgba(255,255,255,.3);border-radius:3px}'
    + '#logPanel .lg-row{display:flex;gap:6px;padding:4px 6px;border-radius:8px;line-height:1.45;word-break:break-word;white-space:pre-wrap;border-left:2px solid transparent}'
    + '#logPanel .lg-row+.lg-row{margin-top:1px}'
    + '#logPanel .lg-time{flex:none;color:rgba(255,255,255,.35);font-size:11px;padding-top:1px;font-variant-numeric:tabular-nums}'
    + '#logPanel .lg-lv{flex:none;font-size:10.5px;font-weight:700;padding-top:2px;min-width:36px;letter-spacing:.3px}'
    + '#logPanel .lg-msg{flex:1;min-width:0;font-size:12px}'
    + '#logPanel .lg-log{border-left-color:rgba(255,255,255,.2)}'
    + '#logPanel .lg-log .lg-lv{color:rgba(255,255,255,.6)}'
    + '#logPanel .lg-debug{border-left-color:rgba(160,160,180,.3);opacity:.75}'
    + '#logPanel .lg-debug .lg-lv{color:rgba(160,160,180,.9)}'
    + '#logPanel .lg-info{border-left-color:rgba(110,180,255,.8);background:rgba(110,180,255,.06)}'
    + '#logPanel .lg-info .lg-lv{color:#7cb8ff}'
    + '#logPanel .lg-warn{border-left-color:rgba(255,190,80,.9);background:rgba(255,190,80,.07)}'
    + '#logPanel .lg-warn .lg-lv{color:#ffbe50}'
    + '#logPanel .lg-error{border-left-color:rgba(255,90,110,.95);background:rgba(255,90,110,.09)}'
    + '#logPanel .lg-error .lg-lv{color:#ff5a6e}'
    + '#logPanel .lp-foot{flex:none;display:flex;align-items:center;gap:8px;padding:8px 14px;border-top:1px solid rgba(255,255,255,.08);font-size:11.5px;color:rgba(255,255,255,.55)}'
    + '#logPanel .lp-foot .stat{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}'
    + '#logPanel .lp-foot button{border:none;background:rgba(255,255,255,.1);color:#fff;height:28px;padding:0 10px;border-radius:9px;font:inherit;font-size:12px;cursor:pointer}'
    + '#logPanel .lp-foot button:active{background:rgba(255,255,255,.22)}'
    + '#logToast{position:fixed;left:50%;bottom:calc(env(safe-area-inset-bottom,0px) + 40px);transform:translate(-50%,20px);z-index:100000;'
    + 'background:rgba(30,32,40,.95);color:#fff;padding:10px 18px;border-radius:14px;font-size:13px;'
    + '-webkit-backdrop-filter:var(--g-blur);backdrop-filter:var(--g-blur);'
    + 'box-shadow:0 10px 30px rgba(0,0,0,.4);opacity:0;pointer-events:none;'
    + 'transition:opacity calc(.25s/var(--ui-spd,1)) ease,transform calc(.25s/var(--ui-spd,1)) ease}'
    + '#logToast.show{opacity:1;transform:translate(-50%,0)}';

  var styleEl = document.createElement('style');
  styleEl.id = 'logStyle';
  styleEl.textContent = CSS;
  document.head.appendChild(styleEl);

  /* ---------- 面板 DOM ---------- */
  var mask = document.createElement('div');
  mask.id = 'logMask';
  document.body.appendChild(mask);

  var panel = document.createElement('div');
  panel.id = 'logPanel';
  panel.setAttribute('aria-hidden', 'true');
  panel.innerHTML =
    '<div class="lp-head">' +
      '<span class="lp-title">实时日志 <em id="logCount">0</em></span>' +
      '<button type="button" class="close" data-act="close" aria-label="关闭">✕</button>' +
    '</div>' +
    '<div class="lp-filters" id="logFilters"></div>' +
    '<div class="lp-body" id="logBody"></div>' +
    '<div class="lp-foot">' +
      '<span class="stat" id="logStat">—</span>' +
      '<button type="button" data-act="copy">复制</button>' +
      '<button type="button" data-act="download">导出</button>' +
      '<button type="button" data-act="clear">清空</button>' +
    '</div>';
  document.body.appendChild(panel);

  var bodyEl = panel.querySelector('#logBody');
  var filtersEl = panel.querySelector('#logFilters');
  var countEl = panel.querySelector('#logCount');
  var statEl = panel.querySelector('#logStat');

  LV.forEach(function(lv){
    var b = document.createElement('button');
    b.type = 'button';
    b.dataset.lv = lv;
    b.textContent = lv;
    b.classList.toggle('on', filters[lv]);
    b.onclick = function(){
      filters[lv] = !filters[lv];
      b.classList.toggle('on', filters[lv]);
      rebuild();
    };
    filtersEl.appendChild(b);
  });

  /* ---------- 渲染 ---------- */
  function buildRow(e){
    var row = document.createElement('div');
    row.className = 'lg-row lg-' + e.level;
    var t = document.createElement('span');
    t.className = 'lg-time';
    t.textContent = fmtTime(e.t);
    var lv = document.createElement('span');
    lv.className = 'lg-lv';
    lv.textContent = e.level.toUpperCase();
    var m = document.createElement('span');
    m.className = 'lg-msg';
    m.textContent = e.text;
    row.appendChild(t); row.appendChild(lv); row.appendChild(m);
    return row;
  }

  function updateStat(){
    var total = logs.length, errs = 0, warns = 0;
    for (var i = 0; i < logs.length; i++){
      if (logs[i].level === 'error') errs++;
      else if (logs[i].level === 'warn') warns++;
    }
    countEl.textContent = total + (errs ? '  ·  ' + errs + ' error' : '') + (warns ? '  ·  ' + warns + ' warn' : '');
    statEl.textContent = total + ' 条 · ' + (autoScroll ? '自动滚动' : '已暂停滚动');
  }

  function flush(){
    if (timerId){ clearTimeout(timerId); timerId = 0; }
    if (!panelOpen || !dirty) return;
    dirty = false;
    var frag = null, maxId = renderedUpTo;
    for (var i = 0; i < logs.length; i++){
      var e = logs[i];
      if (e.id <= renderedUpTo) continue;
      if (!filters[e.level]) continue;
      if (!frag) frag = document.createDocumentFragment();
      frag.appendChild(buildRow(e));
      if (e.id > maxId) maxId = e.id;
    }
    if (frag){
      bodyEl.appendChild(frag);
      renderedUpTo = maxId;
      while (bodyEl.childElementCount > MAX_DOM) bodyEl.removeChild(bodyEl.firstElementChild);
      if (autoScroll) bodyEl.scrollTop = bodyEl.scrollHeight;
    }
    updateStat();
  }

  function schedule(){
    if (timerId) return;
    timerId = setTimeout(flush, FLUSH_MS);
  }

  function markDirty(){ dirty = true; schedule(); }

  function rebuild(){
    bodyEl.innerHTML = '';
    renderedUpTo = 0;
    dirty = true;
    flush();
  }

  bodyEl.addEventListener('scroll', function(){
    var atBottom = bodyEl.scrollHeight - bodyEl.scrollTop - bodyEl.clientHeight < 40;
    if (atBottom !== autoScroll){ autoScroll = atBottom; updateStat(); }
  }, { passive: true });

  /* ---------- 打开 / 关闭 ---------- */
  function openPanel(){
    if (panelOpen) return;
    panelOpen = true;
    panel.classList.add('show');
    panel.setAttribute('aria-hidden', 'false');
    mask.classList.add('show');
    rebuild();
  }
  function closePanel(){
    if (!panelOpen) return;
    panelOpen = false;
    panel.classList.remove('show');
    panel.setAttribute('aria-hidden', 'true');
    mask.classList.remove('show');
  }

  mask.addEventListener('click', closePanel);

  panel.addEventListener('click', function(e){
    var b = e.target && e.target.closest ? e.target.closest('button') : null;
    if (!b) return;
    var act = b.dataset.act;
    if (act === 'close') closePanel();
    else if (act === 'clear'){
      logs.length = 0; renderedUpTo = 0; bodyEl.innerHTML = ''; updateStat(); toast('已清空');
    }
    else if (act === 'copy') copyAll();
    else if (act === 'download') downloadAll();
  });

  /* ---------- 头部下拉关闭 ---------- */
  var headEl = panel.querySelector('.lp-head');
  var dragY = 0, dragging = false;
  headEl.addEventListener('pointerdown', function(e){
    if (e.target.closest('button')) return;
    dragging = true; dragY = e.clientY;
    panel.style.transition = 'none';
    try { headEl.setPointerCapture(e.pointerId); } catch(_){}
  });
  headEl.addEventListener('pointermove', function(e){
    if (!dragging) return;
    var dy = Math.max(0, e.clientY - dragY);
    panel.style.transform = 'translateY(' + dy + 'px)';
  });
  function endDrag(e){
    if (!dragging) return;
    dragging = false;
    var dy = Math.max(0, e.clientY - dragY);
    panel.style.transition = '';
    panel.style.transform = '';
    if (dy > 100) closePanel();
  }
  headEl.addEventListener('pointerup', endDrag);
  headEl.addEventListener('pointercancel', endDrag);

  /* ---------- 复制 / 导出 ---------- */
  function dumpText(){
    return logs.map(function(e){
      return '[' + fmtTime(e.t) + '][' + e.level.toUpperCase() + '] ' + e.text;
    }).join('\n');
  }

  function copyAll(){
    var text = dumpText();
    if (!text){ toast('没有日志'); return; }
    if (navigator.clipboard && navigator.clipboard.writeText){
      navigator.clipboard.writeText(text).then(
        function(){ toast('已复制 ' + logs.length + ' 条'); },
        function(){ fallbackCopy(text); }
      );
    } else {
      fallbackCopy(text);
    }
  }
  function fallbackCopy(text){
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'position:fixed;left:-9999px;top:0;opacity:0';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch(_){}
    document.body.removeChild(ta);
    toast(ok ? '已复制' : '复制失败，请手动选择');
  }

  function downloadAll(){
    var text = dumpText();
    if (!text){ toast('没有日志'); return; }
    
    // 如果已经有弹窗，先删掉
    var old = document.getElementById('logExportModal');
    if (old) old.remove();
    
    // 创建全屏遮罩弹窗
    var overlay = document.createElement('div');
    overlay.id = 'logExportModal';
    overlay.style.cssText = 'position:fixed;inset:0;z-index:100001;background:rgba(0,0,0,.85);display:flex;flex-direction:column;padding:20px;padding-top:calc(env(safe-area-inset-top,0px) + 20px);padding-bottom:calc(env(safe-area-inset-bottom,0px) + 20px);';
    
    var title = document.createElement('div');
    title.textContent = '日志导出 (全选复制)';
    title.style.cssText = 'color:#fff;font-size:16px;font-weight:bold;margin-bottom:10px;text-align:center;';
    
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'flex:1;width:100%;margin-bottom:12px;padding:12px;border-radius:12px;border:none;background:#fff;color:#000;font-family:ui-monospace,monospace;font-size:12px;resize:none;line-height:1.4;';
    ta.readOnly = true;
    
    var btnBox = document.createElement('div');
    btnBox.style.cssText = 'display:flex;gap:12px;flex:none;';
    
    var closeBtn = document.createElement('button');
    closeBtn.textContent = '关闭';
    closeBtn.style.cssText = 'flex:1;padding:14px;border-radius:12px;border:none;background:rgba(255,255,255,.2);color:#fff;font-size:16px;font-weight:bold;';
    closeBtn.onclick = function(){ overlay.remove(); };
    
    var copyBtn = document.createElement('button');
    copyBtn.textContent = '一键复制';
    copyBtn.style.cssText = 'flex:1;padding:14px;border-radius:12px;border:none;background:#8fb0ff;color:#fff;font-size:16px;font-weight:bold;';
    copyBtn.onclick = function(){ 
      ta.focus();
      ta.select();
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text);
        } else {
          document.execCommand('copy');
        }
        copyBtn.textContent = '✅ 已复制';
        copyBtn.style.background = '#4cd964';
      } catch(e) {
        document.execCommand('copy');
        copyBtn.textContent = '✅ 已复制';
      }
    };
    
    btnBox.appendChild(closeBtn);
    btnBox.appendChild(copyBtn);
    overlay.appendChild(title);
    overlay.appendChild(ta);
    overlay.appendChild(btnBox);
    document.body.appendChild(overlay);
    
    // 自动全选
    setTimeout(function(){ ta.focus(); ta.select(); }, 100);
  }

  /* ---------- Toast ---------- */
  var toastEl = null, toastTimer = 0;
  function toast(msg){
    if (!toastEl){
      toastEl = document.createElement('div');
      toastEl.id = 'logToast';
      document.body.appendChild(toastEl);
    }
    toastEl.textContent = msg;
    void toastEl.offsetWidth;
    toastEl.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function(){ toastEl.classList.remove('show'); }, 1600);
  }

  /* ---------- 注入入口按钮到 #pg5 ---------- */
  function injectEntry(){
    var pg5 = document.getElementById('pg5');
    if (!pg5 || pg5.querySelector('.log-entry-btn')) return;
    var box = pg5.querySelector('.pm-box') || pg5;
    var ver = null;
    box.querySelectorAll('.qtip').forEach(function(el){
      if (el.textContent.indexOf('版本') >= 0) ver = el;
    });
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'chip log-entry-btn';
    btn.style.cssText = 'width:100%;margin-top:16px;padding:10px 0;font-size:13px;';
    btn.textContent = '实时日志';
    btn.onclick = openPanel;
    if (ver) ver.parentNode.insertBefore(btn, ver);
    else box.appendChild(btn);
  }

  if (document.getElementById('pg5')) injectEntry();
  else {
    var mo = new MutationObserver(function(){
      if (document.getElementById('pg5')){ injectEntry(); mo.disconnect(); }
    });
    mo.observe(document.body, { childList: true, subtree: true });
  }

  /* ---------- 对外接口 ---------- */
  window.__openLogPanel = openPanel;
  window.__closeLogPanel = closePanel;
  window.__logger = {
    logs: function(){ return logs.slice(); },
    clear: function(){ logs.length = 0; renderedUpTo = 0; bodyEl.innerHTML = ''; updateStat(); },
    push: function(level, msg){ push(level, [msg]); },
    open: openPanel,
    close: closePanel
  };
})();

/* ==========================================================
 * 开发者选项：性能优化、卡顿检测、实时帧率、悬浮窗日志、全屏日志
 * ========================================================== */
(function(){
  'use strict';
  if (window.__devOptionsUltimate) return;
  window.__devOptionsUltimate = true;

  // 1. 状态管理（性能优化沿用原有的 #performanceMode 开关，不在这里重复保存）
  var state = {
    jank: localStorage.getItem('dev_jank') === '1',
    fps: localStorage.getItem('dev_fps') === '1',
    floatLog: localStorage.getItem('dev_float_log') === '1',
    pauseLog: localStorage.getItem('dev_pause_log') === '1'
  };
  window.__logPaused = state.pauseLog;
  if (state.fps) state.jank = true;

  // 2. 右上角 FPS 悬浮窗：胶囊 + 点击向下展开的「采样间隔」面板（胶囊可拖拽）
  var fpsUI = document.getElementById('fpsIndicator');
  if (fpsUI) fpsUI.remove(); // 若页面里有旧版节点，用新版替换
  fpsUI = document.createElement('div');
  fpsUI.id = 'fpsIndicator';
  fpsUI.style.cssText = 'position:fixed;top:calc(env(safe-area-inset-top,0px) + 10px);right:10px;z-index:99997;' +
    'opacity:0;pointer-events:none;transition:opacity calc(.3s/var(--ui-spd,1)) ease;user-select:none;-webkit-user-select:none;';
  fpsUI.innerHTML =
    '<div class="fpsCap">' +
      '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="opacity:.5">' +
      '<circle cx="9" cy="12" r="1"/><circle cx="9" cy="6" r="1"/><circle cx="9" cy="18" r="1"/>' +
      '<circle cx="15" cy="12" r="1"/><circle cx="15" cy="6" r="1"/><circle cx="15" cy="18" r="1"/></svg><span>--.- FPS</span>' +
    '</div>' +
    '<div class="fpsPanel">' +
      '<div class="fpsHead">采样间隔</div>' +
      '<div class="fpsRow"><input class="fpsSlider" type="range" min="50" max="2000" step="50" value="1000" aria-label="帧率采样间隔">' +
      '<span class="fpsVal">1.0s</span></div>' +
    '</div>';
  document.body.appendChild(fpsUI);
  var fpsCap = fpsUI.querySelector('.fpsCap');
  var fpsText = fpsCap.querySelector('span');
  var fpsPanel = fpsUI.querySelector('.fpsPanel');
  var fpsRange = fpsUI.querySelector('.fpsSlider');
  var fpsVal = fpsUI.querySelector('.fpsVal');

  // 采样间隔（毫秒）：50 ~ 2000，步长 50；默认 1000，记住用户上次的选择
  var refreshRate = 500;
  try {
    var savedInt = parseInt(localStorage.getItem('dev_fps_interval'), 10);
    if (savedInt >= 50 && savedInt <= 2000) refreshRate = Math.round(savedInt / 50) * 50;
  } catch(_) {}
  // >= 1000ms 显示为秒（1.2s），否则显示毫秒（500ms）
  function fmtInterval(ms) {
    return ms >= 1000 ? (ms / 1000).toFixed(2).replace(/0$/, '') + 's' : ms + 'ms';
  }
  function paintRange() {
    fpsRange.value = refreshRate;
    fpsRange.style.setProperty('--p', ((refreshRate - 50) / 1950 * 100).toFixed(1) + '%');
    fpsVal.textContent = fmtInterval(refreshRate);
  }
  paintRange();

  // 面板展开/收起：靠屏幕左半边时左对齐，靠下半屏时向上展开，避免跑出屏幕
  var panelOpen = false;
  function placePanel() {
    var r = fpsCap.getBoundingClientRect();
    fpsPanel.classList.toggle('left', r.left + r.width / 2 < window.innerWidth / 2);
    fpsPanel.classList.toggle('up', r.top + r.height / 2 > window.innerHeight / 2);
  }
  function setPanel(open) {
    panelOpen = open;
    if (open) placePanel();
    fpsPanel.classList.toggle('open', open);
    if (!open && !state.fps && fpsUI.style.opacity !== '0') {
      clearTimeout(activeTimer);
      activeTimer = setTimeout(hideFpsUI, 1500);
    }
  }

  // 胶囊：拖动换位置，轻点展开/收起面板（位移 < 5px 视为点击）
  var fpsDragging = false, fpsMoved = false, fpsStartX = 0, fpsStartY = 0, fpsLeft = 0, fpsTop = 0;
  fpsCap.addEventListener('pointerdown', function(e) {
    e.preventDefault();
    fpsDragging = true; fpsMoved = false;
    fpsStartX = e.clientX; fpsStartY = e.clientY;
    var rect = fpsUI.getBoundingClientRect();
    fpsLeft = rect.left; fpsTop = rect.top;
    // 拖拽时解除 right 限制，改为 left/top 定位
    fpsUI.style.right = 'auto';
    fpsUI.style.left = fpsLeft + 'px';
    fpsUI.style.top = fpsTop + 'px';
    try { fpsCap.setPointerCapture(e.pointerId); } catch(_) {}
  });
  fpsCap.addEventListener('pointermove', function(e) {
    if (!fpsDragging) return;
    if (!fpsMoved && Math.hypot(e.clientX - fpsStartX, e.clientY - fpsStartY) < 5) return;
    fpsMoved = true;
    var newLeft = Math.max(0, Math.min(window.innerWidth - fpsUI.offsetWidth, fpsLeft + e.clientX - fpsStartX));
    var newTop = Math.max(0, Math.min(window.innerHeight - fpsUI.offsetHeight, fpsTop + e.clientY - fpsStartY));
    fpsUI.style.left = newLeft + 'px';
    fpsUI.style.top = newTop + 'px';
    if (panelOpen) placePanel();
  });
  function endFpsDrag(e) {
    if (!fpsDragging) return;
    fpsDragging = false;
    try { fpsCap.releasePointerCapture(e.pointerId); } catch(_) {}
    if (e.type === 'pointerup' && !fpsMoved) setPanel(!panelOpen);
  }
  fpsCap.addEventListener('pointerup', endFpsDrag);
  fpsCap.addEventListener('pointercancel', endFpsDrag);

  // 滑块：拖动时立刻更新数值，并清掉旧定时器、按新间隔重建（restartFpsTimer 在下方第 3 节定义）
  fpsRange.addEventListener('input', function() {
    refreshRate = parseInt(this.value, 10) || 500;
    paintRange();
    try { localStorage.setItem('dev_fps_interval', String(refreshRate)); } catch(_) {}
    restartFpsTimer();
  });

  // 只有显示时才接收触摸；隐藏时必须放行，否则右上角会有一块看不见却点不动的区域
  var activeTimer = 0;
  function showFpsUI(msg, isError) {
    fpsText.textContent = msg;
    fpsUI.style.opacity = '1';
    fpsUI.style.pointerEvents = 'auto';
    fpsCap.style.background = isError ? 'rgba(255,60,60,.85)' : 'rgba(20,20,25,.75)';
    fpsCap.style.boxShadow = isError ? '0 4px 12px rgba(255,0,0,.3)' : '0 4px 12px rgba(0,0,0,.3)';
    clearTimeout(activeTimer);
    if (!state.fps && !panelOpen) activeTimer = setTimeout(hideFpsUI, isError ? 2500 : 1500);
  }
  function hideFpsUI() {
    clearTimeout(activeTimer);
    panelOpen = false;
    fpsPanel.classList.remove('open');
    fpsUI.style.opacity = '0';
    fpsUI.style.pointerEvents = 'none';
  }

  // 3. 帧率与卡顿检测（解耦：rAF 只计数，setInterval 负责渲染）
  var fps = 60, frames = 0, lastTime = performance.now(), lastWarnTime = 0;
  var origRAF = window.requestAnimationFrame; // 打补丁之前保存，计数循环不经过溯源包装

  document.addEventListener('visibilitychange', function(){
    lastTime = performance.now();
    frames = 0;
  });

  function countFrames() {
    if (state.jank) frames++;
    origRAF.call(window, countFrames);
  }
  origRAF.call(window, countFrames);

  // 采样：定时器按 refreshRate 触发；拖动滑块时 restartFpsTimer 会 clearInterval 旧的再 setInterval 新的
  var fpsTimer = 0;
  function sampleFps() {
    var now = performance.now();
    if (!state.jank) {
      lastTime = now; frames = 0;
      if (fpsUI.style.opacity !== '0') hideFpsUI();
      return;
    }
    var delta = now - lastTime;
    // 实时显示按所选间隔刷新；掉帧警告仍按约 1 秒的窗口判断，避免短间隔下帧数量化造成误报
    var need = state.fps ? refreshRate * 0.9 : 1000;
    if (delta >= need) {
      fps = Math.round((frames * 1000) / delta * 10) / 10; // 保留 1 位小数（number）
      frames = 0; lastTime = now;
      if (state.fps) {
        showFpsUI(fps.toFixed(1) + ' FPS', false);
        if (fps >= 50) { fpsCap.style.background = 'rgba(20,20,25,.75)'; fpsCap.style.color = '#4cd964'; }
        else if (fps >= 30) { fpsCap.style.background = 'rgba(255,150,0,.8)'; fpsCap.style.color = '#fff'; }
        else { fpsCap.style.background = 'rgba(255,60,60,.85)'; fpsCap.style.color = '#fff'; }
      } else if (fps < 40) {
        fpsCap.style.color = '#fff';
        showFpsUI('掉帧警告: ' + fps.toFixed(1) + ' FPS', true);
        if (window.console && console.warn) console.warn('[卡顿检测] 页面严重掉帧，当前 FPS: ' + fps);
      }
    }
  }
  function restartFpsTimer() {
    if (fpsTimer) clearInterval(fpsTimer);
    frames = 0; lastTime = performance.now();
    fpsTimer = setInterval(sampleFps, refreshRate);
  }
  restartFpsTimer();

  // 拦截 rAF 抓取卡顿溯源
  window.requestAnimationFrame = function(cb) {
    if (!state.jank) return origRAF.call(window, cb);
    return origRAF.call(window, function(ts) {
      var t0 = performance.now();
      try {
        if (typeof cb === 'function') cb(ts);
      } finally {
        var cost = performance.now() - t0;
        // 注意：不能在 finally 里 return，否则会吞掉回调抛出的异常
        if (cost > 16 && Date.now() - lastWarnTime >= 1500) {
          lastWarnTime = Date.now();
          var lines = (new Error().stack || '').split('\n');
          var codeLoc = '', mc = 0;
          for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (line.indexOf('at ') === 0) { codeLoc += '\n  ' + line; mc++; if (mc >= 3) break; }
          }
          if (!mc) {
            var raw = lines.filter(function(l){ return l.trim(); }).slice(0, 3);
            if (raw.length) codeLoc = '\n  ' + raw.join('\n  ');
          }
          if (!codeLoc) codeLoc = '未知位置';
          if (window.console && console.warn) {
            console.warn('[卡顿溯源] rAF 阻塞 ' + Math.round(cost) + 'ms (函数: ' + ((cb && cb.name) || 'anon') + ')\n位置: ' + codeLoc);
          }
        }
      }
    });
  };

  // 4. 悬浮窗日志
  var floatLog = document.createElement('div');
  floatLog.id = 'devFloatLog';
  floatLog.style.cssText = 'position:fixed;left:10px;bottom:calc(env(safe-area-inset-bottom,0px) + 120px);z-index:99996;' +
    'width:220px;background:rgba(20,22,28,.85);border:1px solid rgba(255,255,255,.1);border-radius:12px;' +
    'color:#fff;font-family:ui-monospace,monospace;font-size:11px;box-shadow:0 8px 24px rgba(0,0,0,.4);' +
    'display:none;flex-direction:column;overflow:hidden;touch-action:none;user-select:none;-webkit-user-select:none;';
  floatLog.innerHTML =
    '<div id="devFloatHead" style="padding:6px 8px;background:rgba(255,255,255,.05);display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid rgba(255,255,255,.05);cursor:move;">' +
      '<span style="color:#8fb0ff;font-weight:bold;font-size:10px;letter-spacing:.5px;">LOGS</span>' +
      '<div style="display:flex;gap:6px;">' +
        '<button type="button" id="devFloatExpand" style="background:none;border:none;color:#fff;cursor:pointer;padding:0 4px;font-size:14px;">⤢</button>' +
        '<button type="button" id="devFloatClose" style="background:none;border:none;color:#ff5a6e;cursor:pointer;padding:0 4px;font-size:14px;">×</button>' +
      '</div>' +
    '</div>' +
    '<div id="devFloatBody" style="padding:6px 8px;min-height:18px;display:flex;flex-direction:column;gap:4px;"></div>' +
    '<div id="devFloatResize" style="position:absolute;right:0;bottom:0;width:28px;height:28px;cursor:nwse-resize;touch-action:none;z-index:2;">' +
      '<svg width="28" height="28" viewBox="0 0 28 28" style="display:block;pointer-events:none"><path d="M24 16A8 8 0 0 1 16 24" fill="none" stroke="rgba(255,255,255,.6)" stroke-width="2.6" stroke-linecap="round"/></svg>' +
    '</div>';
  document.body.appendChild(floatLog);
  floatLog.style.display = state.floatLog ? 'flex' : 'none';

  var floatBody = floatLog.querySelector('#devFloatBody');
  var head = floatLog.querySelector('#devFloatHead');
  var resizer = floatLog.querySelector('#devFloatResize');
  var sized = false;          // 用户调过大小后：固定宽高，正文占满剩余空间，多显示几行
  var MIN_W = 150, MIN_H = 64;
  function applySized(w, h) {
    sized = true;
    floatLog.style.width = w + 'px';
    floatLog.style.height = h + 'px';
    floatBody.style.flex = '1 1 auto';
    floatBody.style.minHeight = '0';
    floatBody.style.overflow = 'hidden';
    floatBody.style.justifyContent = 'flex-end';   // 最新的日志贴底，旧的从顶部被裁掉
  }
  try {
    var savedSize = JSON.parse(localStorage.getItem('dev_float_size') || 'null');
    if (savedSize && savedSize.w >= MIN_W && savedSize.h >= MIN_H) {
      applySized(Math.min(savedSize.w, window.innerWidth - 8), Math.min(savedSize.h, window.innerHeight - 8));
    }
  } catch(_) {}
  var rs = null;
  resizer.addEventListener('pointerdown', function(e) {
    e.stopPropagation(); e.preventDefault();
    var rect = floatLog.getBoundingClientRect();
    // 改成 left/top 定位，右下角才能跟手
    floatLog.style.bottom = 'auto'; floatLog.style.right = 'auto';
    floatLog.style.left = rect.left + 'px'; floatLog.style.top = rect.top + 'px';
    rs = { x: e.clientX, y: e.clientY, w: rect.width, h: rect.height, l: rect.left, t: rect.top };
    try { resizer.setPointerCapture(e.pointerId); } catch(_) {}
  });
  resizer.addEventListener('pointermove', function(e) {
    if (!rs) return;
    e.stopPropagation();
    var w = Math.max(MIN_W, Math.min(window.innerWidth - rs.l, rs.w + (e.clientX - rs.x)));
    var h = Math.max(MIN_H, Math.min(window.innerHeight - rs.t, rs.h + (e.clientY - rs.y)));
    applySized(Math.round(w), Math.round(h));
  });
  function endResize(e) {
    if (!rs) return;
    e.stopPropagation();
    rs = null;
    try { resizer.releasePointerCapture(e.pointerId); } catch(_) {}
    try { localStorage.setItem('dev_float_size', JSON.stringify({ w: floatLog.offsetWidth, h: floatLog.offsetHeight })); } catch(_) {}
  }
  resizer.addEventListener('pointerup', endResize);
  resizer.addEventListener('pointercancel', endResize);
  var dragging = false, moved = false, startX = 0, startY = 0, startLeft = 0, startTop = 0;

  function openFull() { if (window.__openLogPanel) window.__openLogPanel(); }

  // 拖拽：整个浮窗都可拖，没有明显位移的点击视为"展开全屏日志"
  floatLog.addEventListener('pointerdown', function(e) {
    if (e.target.tagName === 'BUTTON') return;
    dragging = true; moved = false;
    startX = e.clientX; startY = e.clientY;
    var rect = floatLog.getBoundingClientRect();
    startLeft = rect.left; startTop = rect.top;
    floatLog.style.bottom = 'auto'; floatLog.style.right = 'auto';
    floatLog.style.left = startLeft + 'px'; floatLog.style.top = startTop + 'px';
    try { floatLog.setPointerCapture(e.pointerId); } catch(_) {}
  });
  floatLog.addEventListener('pointermove', function(e) {
    if (!dragging) return;
    var dx = e.clientX - startX, dy = e.clientY - startY;
    if (!moved && Math.abs(dx) + Math.abs(dy) < 6) return;
    moved = true;
    var maxL = window.innerWidth - floatLog.offsetWidth;
    var maxT = window.innerHeight - floatLog.offsetHeight;
    floatLog.style.left = Math.max(0, Math.min(maxL, startLeft + dx)) + 'px';
    floatLog.style.top = Math.max(0, Math.min(maxT, startTop + dy)) + 'px';
  });
  function endDrag(e) {
    if (!dragging) return;
    dragging = false;
    try { floatLog.releasePointerCapture(e.pointerId); } catch(_) {}
    if (!moved && e.type === 'pointerup' && e.target.tagName !== 'BUTTON') openFull();
  }
  floatLog.addEventListener('pointerup', endDrag);
  floatLog.addEventListener('pointercancel', endDrag);

  floatLog.querySelector('#devFloatExpand').onclick = openFull;
  floatLog.querySelector('#devFloatClose').onclick = function() {
    state.floatLog = false;
    floatLog.style.display = 'none';
    localStorage.setItem('dev_float_log', '0');
    var chk = document.getElementById('devFloatLogChk');
    if (chk) chk.checked = false;
  };

  // 链式拦截 console：先交给上一层（全屏日志系统）处理，再更新悬浮窗，绝不吞日志
  function toText(v) {
    if (typeof v === 'string') return v;
    if (v instanceof Error) return v.stack || (v.name + ': ' + v.message);
    try { return typeof v === 'object' && v !== null ? JSON.stringify(v) : String(v); } catch(_) { return String(v); }
  }
  var inFloat = false;
  function pushFloat(level, args) {
    if (!state.floatLog || state.pauseLog || inFloat) return;
    inFloat = true;
    try {
      var txt = Array.prototype.map.call(args, toText).join(' ').replace(/\s*\n\s*/g, ' ');
      var div = document.createElement('div');
      var color = level === 'error' ? '#ff5a6e' : (level === 'warn' ? '#ffbe50' : 'rgba(255,255,255,.7)');
      div.style.cssText = 'flex:none;color:' + color + ';line-height:1.3;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;';
      div.textContent = txt;
      floatBody.appendChild(div);
      var maxLines = sized ? 40 : 3;
      while (floatBody.children.length > maxLines) floatBody.removeChild(floatBody.firstElementChild);
    } catch(_) {
    } finally {
      inFloat = false;
    }
  }
  ['log', 'warn', 'error'].forEach(function(level) {
    var prev = console[level] || function(){};
    console[level] = function() {
      pushFloat(level, arguments);
      return prev.apply(console, arguments);
    };
  });

  // 一键抓取全部数据：环境 + 运行状态 + 全部日志，弹出全屏文本框供复制
  function pad(n, l) { n = String(n); while (n.length < (l || 2)) n = '0' + n; return n; }
  function buildDump() {
    var d = '=== 环境信息 ===\n';
    d += '设备: ' + navigator.userAgent + '\n';
    d += '屏幕: ' + screen.width + 'x' + screen.height + ' (DPR: ' + window.devicePixelRatio + ')\n';
    d += '视口: ' + window.innerWidth + 'x' + window.innerHeight + '\n';
    if (performance.memory) {
      d += '内存: 已用 ' + Math.round(performance.memory.usedJSHeapSize / 1048576) + ' MB / 限制 ' +
        Math.round(performance.memory.jsHeapSizeLimit / 1048576) + ' MB\n';
    }
    d += '\n=== 运行状态 ===\n';
    d += '当前 FPS: ' + (state.jank ? fps : '未检测（卡顿检测已关闭）') + '\n';
    d += '卡顿检测: ' + (state.jank ? '开' : '关') + '\n';
    d += '实时帧率: ' + (state.fps ? '开' : '关') + '\n';
    d += '悬浮窗日志: ' + (state.floatLog ? '开' : '关') + '\n';
    d += '暂停抓取日志: ' + (state.pauseLog ? '是' : '否') + '\n';
    d += '性能优化: ' + (document.body.classList.contains('performance-mode') ? '开' : '关') + '\n';
    try { d += '播放状态: ' + (playing ? '播放中' : '暂停') + '\n'; } catch (e) {}
    try { d += '当前句子: ' + (LN[idx] != null ? LN[idx] : '无') + ' (第 ' + (idx + 1) + '/' + LN.length + ' 句)\n'; } catch (e) {}
    d += '\n=== 日志记录 ===\n';
    var logs = (window.__logger && window.__logger.logs) ? window.__logger.logs() : [];
    if (logs.length) {
      logs.forEach(function(l) {
        var t = new Date(l.t);
        d += '[' + pad(t.getHours()) + ':' + pad(t.getMinutes()) + ':' + pad(t.getSeconds()) + '.' + pad(t.getMilliseconds(), 3) +
          '][' + String(l.level).toUpperCase() + '] ' + l.text + '\n';
      });
    } else {
      d += '（暂无日志记录）\n';
    }
    return d;
  }

  function openDumpModal() {
    var old = document.getElementById('devDumpModal');
    if (old) old.remove();
    var overlay = document.createElement('div');
    overlay.id = 'devDumpModal';
    overlay.style.cssText = 'position:fixed;inset:0;z-index:100002;background:rgba(0,0,0,.85);display:flex;flex-direction:column;' +
      'padding:20px;padding-top:calc(env(safe-area-inset-top,0px) + 20px);padding-bottom:calc(env(safe-area-inset-bottom,0px) + 20px);';

    var ta = document.createElement('textarea');
    ta.value = buildDump();
    ta.readOnly = true;
    ta.style.cssText = 'flex:1;width:100%;margin-bottom:12px;padding:12px;border-radius:12px;border:none;background:#fff;color:#000;' +
      'font-family:ui-monospace,monospace;font-size:12px;resize:none;line-height:1.4;box-sizing:border-box;';

    var btnBox = document.createElement('div');
    btnBox.style.cssText = 'display:flex;gap:12px;flex:none;';

    var closeBtn = document.createElement('button');
    closeBtn.type = 'button';
    closeBtn.textContent = '关闭';
    closeBtn.style.cssText = 'flex:1;padding:14px;border-radius:12px;border:none;background:rgba(255,255,255,.2);color:#fff;font-size:16px;font-weight:bold;';
    closeBtn.onclick = function(){ overlay.remove(); };

    var copyBtn = document.createElement('button');
    copyBtn.type = 'button';
    copyBtn.textContent = '一键复制';
    copyBtn.style.cssText = 'flex:1;padding:14px;border-radius:12px;border:none;background:#8fb0ff;color:#fff;font-size:16px;font-weight:bold;';
    function copyOk() { copyBtn.textContent = '✅ 已复制'; copyBtn.style.background = '#4cd964'; }
    function copyFail() { copyBtn.textContent = '复制失败，请长按文本手动复制'; copyBtn.style.background = '#ff5a6e'; }
    copyBtn.onclick = function() {
      ta.focus(); ta.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) {}
      if (ok) { copyOk(); return; }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(ta.value).then(copyOk, copyFail);
      } else copyFail();
    };

    btnBox.appendChild(closeBtn); btnBox.appendChild(copyBtn);
    overlay.appendChild(ta); overlay.appendChild(btnBox);
    document.body.appendChild(overlay);
    setTimeout(function(){ ta.focus(); ta.select(); }, 100);
  }

  // 5. 注入开发者选项到系统设置 #pg5
  function injectDevOptions() {
    var pg5 = document.getElementById('pg5');
    if (!pg5 || document.getElementById('devOptionsGroup')) return;
    var box = pg5.querySelector('.pm-box') || pg5;

    // 清理残留按钮
    var oldLog = box.querySelector('.log-entry-btn'); if (oldLog) oldLog.remove();
    var oldFps = document.getElementById('fpsToggleWrap'); if (oldFps) oldFps.remove();

    var grp = document.createElement('div');
    grp.id = 'devOptionsGroup';
    grp.className = 'grp';
    grp.style.cssText = 'margin-top:24px; border-top:1px solid rgba(255,255,255,.08); padding-top:16px;';
    grp.innerHTML =
      '<button class="gh" type="button" aria-expanded="false" style="background:rgba(143,176,255,.1); border:1px solid rgba(143,176,255,.2);">' +
        '<span style="color:#8fb0ff; font-weight:bold;">开发者选项</span>' +
        '<svg viewBox="0 0 24 24" style="stroke:#8fb0ff;"><path d="M6 9l6 6 6-6"/></svg>' +
      '</button>' +
      '<div class="gb"><div class="gi"><div class="gp">' +
        '<div style="display:flex;flex-direction:column;gap:14px;padding-top:10px;"></div>' +
      '</div></div></div>';
    var contentWrap = grp.querySelector('.gp > div');

    var ghBtn = grp.querySelector('.gh');
    ghBtn.addEventListener('click', function() {
      var on = grp.classList.toggle('open');
      ghBtn.setAttribute('aria-expanded', on ? 'true' : 'false');
      if (on) setTimeout(function(){ grp.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); }, uiT(460));
    });

    var ROW = 'display:flex;align-items:center;justify-content:space-between;width:100%;margin:0;padding:8px 12px;' +
      'background:rgba(255,255,255,.04);border-radius:12px;box-sizing:border-box;';

    // 圆角长条开关：label 包着 input，点击整条都能切换
    function addSwitch(id, labelTxt, isChecked, onChange) {
      var l = document.createElement('label');
      l.className = 'chk';
      l.style.cssText = ROW;
      var txt = document.createElement('span');
      txt.textContent = labelTxt;
      txt.style.cssText = 'font-size:14px;';
      var c = document.createElement('input');
      c.type = 'checkbox'; c.id = id; c.checked = isChecked;
      c.onchange = onChange;
      l.appendChild(txt);
      l.appendChild(c);
      contentWrap.appendChild(l);
      return c;
    }

    // A. 性能优化：把原有开关（含说明文字）整体收进来，保留它原来的保存与联动逻辑
    var perfInput = document.getElementById('performanceMode');
    var perfBlock = perfInput ? perfInput.closest('.qg') : null;
    if (perfBlock) {
      var perfWrap = document.createElement('div');
      while (perfBlock.firstChild) perfWrap.appendChild(perfBlock.firstChild);
      perfBlock.remove();
      var perfLabel = perfInput.closest('label');
      if (perfLabel) {
        // 文字放左、开关放右，样式与其他开关一致
        perfLabel.style.cssText = ROW;
        perfLabel.appendChild(perfInput);
        var perfDesc = perfLabel.nextElementSibling;
        if (perfDesc) perfDesc.style.padding = '6px 12px 0';
      }
      contentWrap.appendChild(perfWrap);
    }

    // B. 卡顿检测
    addSwitch('devJank', '卡顿检测', state.jank, function() {
      state.jank = this.checked;
      localStorage.setItem('dev_jank', state.jank ? '1' : '0');
      if (!state.jank && state.fps) {
        state.fps = false;
        document.getElementById('devFps').checked = false;
        localStorage.setItem('dev_fps', '0');
        hideFpsUI();
      }
    });

    // C. 实时帧率显示
    addSwitch('devFps', '实时帧率显示', state.fps, function() {
      state.fps = this.checked;
      localStorage.setItem('dev_fps', state.fps ? '1' : '0');
      if (state.fps && !state.jank) {
        state.jank = true;
        document.getElementById('devJank').checked = true;
        localStorage.setItem('dev_jank', '1');
      }
      if (!state.fps) hideFpsUI();
    });

    // D. 悬浮窗日志
    addSwitch('devFloatLogChk', '悬浮窗日志', state.floatLog, function() {
      state.floatLog = this.checked;
      localStorage.setItem('dev_float_log', state.floatLog ? '1' : '0');
      floatLog.style.display = state.floatLog ? 'flex' : 'none';
    });

    // E. 暂停抓取日志
    addSwitch('devPauseLogChk', '暂停抓取日志', state.pauseLog, function() {
      state.pauseLog = this.checked;
      window.__logPaused = state.pauseLog;
      localStorage.setItem('dev_pause_log', state.pauseLog ? '1' : '0');
    });

    // F. 按钮组
    var btnWrap = document.createElement('div');
    btnWrap.style.cssText = 'display:flex; gap:8px; margin-top:8px;';

    var btnDump = document.createElement('button');
    btnDump.type = 'button'; btnDump.className = 'chip';
    btnDump.style.cssText = 'flex:1;padding:10px 0;font-size:13px;background:rgba(143,176,255,.15);color:#8fb0ff;';
    btnDump.textContent = '抓取全部数据';
    btnDump.onclick = openDumpModal;

    var btnLog = document.createElement('button');
    btnLog.type = 'button'; btnLog.className = 'chip log-entry-btn';
    btnLog.style.cssText = 'flex:1;padding:10px 0;font-size:13px;';
    btnLog.textContent = '全屏日志';
    btnLog.onclick = openFull;

    btnWrap.appendChild(btnDump);
    btnWrap.appendChild(btnLog);
    contentWrap.appendChild(btnWrap);

    var ver = null;
    box.querySelectorAll('.qtip').forEach(function(el){
      if (el.textContent.indexOf('版本') >= 0) ver = el;
    });
    if (ver) ver.parentNode.insertBefore(grp, ver);
    else box.appendChild(grp);
  }

  if (document.getElementById('pg5')) injectDevOptions();
  else {
    var mo = new MutationObserver(function(){
      if (document.getElementById('pg5')){ injectDevOptions(); mo.disconnect(); }
    });
    mo.observe(document.body, { childList: true, subtree: true });
  }

})();

/* ==========================================================
 * 视觉异常捕捉器 (抓取闪烁、重排、渲染卡顿)
 * 独立监控，不修改原项目逻辑。回调里只做最轻量的计数，名字在每秒汇总时才生成，
 * 避免监控自身成为新的卡顿来源。
 * ========================================================== */
(function(){
  'use strict';
  if (window.__visualAnomalyDetector) return;
  window.__visualAnomalyDetector = true;

  function warn(msg) { if (window.console && console.warn) console.warn(msg); }

  function elName(el) {
    var n = (el.tagName || '?').toLowerCase();
    if (el.id) return n + '#' + el.id;
    var c = el.className;
    if (c && typeof c === 'string') {
      var parts = c.trim().split(/\s+/).slice(0, 2).join('.');
      if (parts) n += '.' + parts;
    }
    return n;
  }

  // 1. 高频 DOM 修改（style / class 被反复改动，是闪烁、重排的常见元凶）
  var counts = new Map();      // 元素 -> 本秒内被修改的次数（回调里只做这一件事）
  var lastWarnTime = 0;
  var HOT = 25;                // 单个元素 1 秒内被改超过 25 次，视为风险

  var observer = new MutationObserver(function(mutations) {
    for (var i = 0; i < mutations.length; i++) {
      var t = mutations[i].target;
      counts.set(t, (counts.get(t) || 0) + 1);
    }
  });

  var stage = document.getElementById('stage') || document.body;
  observer.observe(stage, { attributes: true, subtree: true, attributeFilter: ['style', 'class'] });

  setInterval(function() {
    var groups = {};           // 名字 -> { n: 最高频次, els: 元素个数 }
    var any = false;
    counts.forEach(function(n, el) {
      if (n <= HOT) return;
      if (el.closest && el.closest('#logPanel, #devFloatLog, #fpsIndicator, #devDumpModal')) return; // 忽略开发者工具自身
      if (el.hasAttribute && el.hasAttribute('data-compositor')) return; // 只改 transform 的合成层动画（如镜头 .cam），不会重排，忽略
      var k = elName(el);
      var g = groups[k] || (groups[k] = { n: 0, els: 0 });
      if (n > g.n) g.n = n;
      g.els++;
      any = true;
    });
    counts.clear();
    if (!any) return;
    var now = Date.now();
    if (now - lastWarnTime < 2000) return; // 防止刷屏
    lastWarnTime = now;
    var rows = Object.keys(groups).map(function(k){ return [k, groups[k]]; })
      .sort(function(a, b){ return b[1].n - a[1].n; }).slice(0, 3);
    warn('[视觉异常] 检测到高频重排/闪烁风险:\n' + rows.map(function(r){
      return '  元素: ' + r[0] + '  频率: ' + r[1].n + ' 次/秒' + (r[1].els > 1 ? '  (共 ' + r[1].els + ' 个同名元素)' : '');
    }).join('\n'));
  }, 1000);

  // 2. 布局偏移（画面元素突然跳动）
  if (window.PerformanceObserver) {
    try {
      var po = new PerformanceObserver(function(list) {
        list.getEntries().forEach(function(entry) {
          if (!entry.hadRecentInput && entry.value > 0.05) {
            var src = '';
            try {
              if (entry.sources && entry.sources[0] && entry.sources[0].node && entry.sources[0].node.nodeType === 1) {
                src = ' 元素: ' + elName(entry.sources[0].node);
              }
            } catch (_) {}
            warn('[视觉异常] 画面发生明显偏移(跳动): 分数 ' + entry.value.toFixed(3) + src);
          }
        });
      });
      po.observe({ type: 'layout-shift', buffered: true });
    } catch (e) {}
  }

  // 3. 渲染卡顿：优先用 long-animation-frame（浏览器只会上报 ≥50ms 的长帧），不支持时退回 longtask
  if (window.PerformanceObserver) {
    var useLoaf = false;
    try {
      var poLoaf = new PerformanceObserver(function(list) {
        list.getEntries().forEach(function(entry) {
          var who = '';
          try {
            var s = entry.scripts && entry.scripts[0];
            if (s) who = ' 主要来源: ' + (s.sourceFunctionName || s.invoker || '?');
          } catch (_) {}
          warn('[视觉异常] 长动画帧: 一帧耗时 ' + Math.round(entry.duration) + 'ms' + who);
        });
      });
      poLoaf.observe({ type: 'long-animation-frame', buffered: true });
      useLoaf = true;
    } catch (e) {}
    if (!useLoaf) {
      try {
        var poTask = new PerformanceObserver(function(list) {
          list.getEntries().forEach(function(entry) {
            if (entry.duration > 50) warn('[视觉异常] 长任务阻塞主线程: ' + Math.round(entry.duration) + 'ms');
          });
        });
        poTask.observe({ type: 'longtask', buffered: true });
      } catch (err) {}
    }
  }

  if (window.console && console.info) {
    console.info('[系统] 视觉异常捕捉器已启动，开始监控重排、闪烁与渲染卡顿。');
  }
})();

