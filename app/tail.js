// app/tail.js — 顶部输入栏 + 禁止页面缩放手势

/* ===== 顶部输入栏：点歌词文字 → 屏幕上方出现输入框，后面「取消 / 确认」；确认才写回，画面不再自动放大 ===== */
(function(){
  var bar=document.createElement("div");
  bar.id="textBar";bar.setAttribute("role","dialog");bar.setAttribute("aria-label","修改文字");bar.setAttribute("aria-hidden","true");
  bar.innerHTML='<input type="text" id="textBarIn" enterkeyhint="done" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="输入一句话" aria-label="文字"><button type="button" class="tb-cancel">取消</button><button type="button" class="tb-ok">确认</button>';
  document.body.appendChild(bar);
  /* 预热：页面空闲时让磨砂层先渲染一次，避免第一次打开时临时创建图层导致动画掉帧 */
  (window.requestIdleCallback||function(f){setTimeout(f,600)})(function(){
    bar.style.transition="none";bar.style.opacity=".01";void bar.offsetWidth;
    requestAnimationFrame(function(){requestAnimationFrame(function(){bar.style.opacity="";bar.style.transition=""})});
  });
  var inp=bar.querySelector("#textBarIn"),cur=null,curT=null,curO=null;
  function close(){
    bar.classList.remove("show");bar.setAttribute("aria-hidden","true");
    if(cur)cur.classList.remove("editing");
    cur=null;curT=null;curO=null;inp.blur();
    inp.removeAttribute("maxlength");inp.placeholder="输入一句话";
  }
  /* open(卡片, 文本框[, 选项])：选项 {value, maxLength, placeholder, onOk(新文字)} 用于非歌词卡片的输入（如主题名称） */
  function open(c,t,o){
    if(cur&&cur!==c)cur.classList.remove("editing");
    cur=c;curT=t;curO=o||null;
    inp.value=(o&&o.value!=null)?o.value:t.value.replace(/\n/g," ");
    if(o&&o.maxLength>0)inp.maxLength=o.maxLength;else inp.removeAttribute("maxlength");
    inp.placeholder=(o&&o.placeholder)||"输入一句话";
    if(c)c.classList.add("editing");                    /* 正在改的这一句保持高亮 */
    void bar.offsetWidth;                          /* 先强制排版一次，保证第一次也是从"隐藏态"开始过渡 */
    bar.classList.add("show");bar.setAttribute("aria-hidden","false");
    try{inp.focus({preventScroll:true})}catch(_){inp.focus()}
    try{inp.setSelectionRange(inp.value.length,inp.value.length)}catch(_){}
  }
  function ok(){
    if(curO&&curO.onOk){var f=curO.onOk,v=inp.value;close();f(v);return}
    if(curT){var t=curT;t.value=inp.value;t.dispatchEvent(new Event("input",{bubbles:true}))}
    close();
  }
  bar.querySelector(".tb-ok").addEventListener("click",ok);
  bar.querySelector(".tb-cancel").addEventListener("click",close);
  inp.addEventListener("keydown",function(e){
    e.stopPropagation();
    if(e.isComposing||e.keyCode===229)return;
    if(e.key==="Enter"){e.preventDefault();ok()}
    else if(e.key==="Escape"){e.preventDefault();close()}
  });
  inp.addEventListener("keyup",function(e){e.stopPropagation()});
  window.__openTextBar=open;
})();

/* ===== 禁止双指捏合缩放整个页面（iOS 用 gesture 事件，其余浏览器拦多指 touchmove / ctrl+滚轮） ===== */
(function(){
  var stop=function(e){if(e.cancelable)e.preventDefault()};
  ["gesturestart","gesturechange","gestureend"].forEach(function(n){document.addEventListener(n,stop,{passive:false})});
  document.addEventListener("touchmove",function(e){if(e.touches&&e.touches.length>1)stop(e)},{passive:false});
  window.addEventListener("wheel",function(e){if(e.ctrlKey)stop(e)},{passive:false});
})();