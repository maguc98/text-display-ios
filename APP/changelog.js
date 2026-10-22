// app/changelog.js — 设置页「更新日志」：悬浮毛玻璃卡片（顶部高斯模糊），添加 / 修改版本需输入密码
(function(){
  var PW="20070312",KEY="changelogV2",OLD="changelogV1";
  var list=[],pick=false,editIdx=-1,onAuth=null,open=false,verEl=null;

  /* 初始内容：来自你给的设计图（「已知问题」图里没显示内容，这里不放，可用「修改版本」补上） */
  var SEED={v:"v0.1.1 Beta 3",d:"2026-10-21",s:[
    {t:"新功能",i:["主题选择器升级为网格卡片：每个主题独立记忆背景类型","长按主题卡片显示笔形遮罩，点击进入编辑","支持拖动主题卡片调整顺序","顶部文字输入栏：修改文字不再触发页面自动放大","播放卡片：上滑迷你条打开"]},
    {t:"优化",i:["玻璃拟态材质统一：面板 / 菜单 / 按钮共用一套模糊参数","背景切换平滑过渡","时间轴性能优化：用 scaleX 代替 width"]},
    {t:"修复",i:["修复主题选择器展开过程中毛玻璃失效的问题","修复 iOS 上内容不绘制的问题","修复迷你条收起时残留黑边的问题"]}
  ]};
  function clone(o){return JSON.parse(JSON.stringify(o))}
  function cleanSecs(a){
    return (Array.isArray(a)?a:[]).filter(function(x){return x&&typeof x.t==="string"&&Array.isArray(x.i)})
      .map(function(x){return {t:x.t,i:x.i.filter(function(s){return typeof s==="string"&&s})}}).filter(function(x){return x.i.length});
  }
  function load(){
    var a=null;try{a=JSON.parse(localStorage.getItem(KEY)||"null")}catch(_){}
    if(Array.isArray(a)){
      a=a.filter(function(x){return x&&typeof x.v==="string"}).map(function(x){return {v:x.v,d:typeof x.d==="string"?x.d:"",s:cleanSecs(x.s)}});
      if(a.length)return a;
    }
    /* 从第一版（每条只有平铺的 n 数组）迁移：顺序不变，同名版本换成新内容，找不到同名版本就把新内容放在最后 */
    var out=[],o=null,hit=false;try{o=JSON.parse(localStorage.getItem(OLD)||"null")}catch(_){}
    if(Array.isArray(o))o.forEach(function(x){
      if(!x||typeof x.v!=="string")return;
      if(x.v===SEED.v){out.push(clone(SEED));hit=true;return}
      var n=Array.isArray(x.n)?x.n.filter(function(s){return typeof s==="string"&&s}):[];
      out.push({v:x.v,d:typeof x.d==="string"?x.d:"",s:n.length?[{t:"更新",i:n}]:[]});
    });
    if(!hit)out.push(clone(SEED));
    return out;
  }
  function persist(){try{localStorage.setItem(KEY,JSON.stringify(list));return true}catch(_){return false}}
  function today(){var t=new Date(),p=function(n){return(n<10?"0":"")+n};return t.getFullYear()+"-"+p(t.getMonth()+1)+"-"+p(t.getDate())}
  function mk(tag,cls,txt){var e=document.createElement(tag);if(cls)e.className=cls;if(txt!=null)e.textContent=txt;return e}
  function kind(t){return t.indexOf("新功能")>=0?"new":t.indexOf("优化")>=0?"opt":t.indexOf("修复")>=0?"fix":(t.indexOf("已知")>=0||t.indexOf("问题")>=0)?"bug":"def"}

  /* 编辑框文本 ⇄ 分类数据：「# 分类名」开头的行是分类标题，其余每行一条 */
  function toText(s){return s.map(function(x){return "# "+x.t+"\n"+x.i.join("\n")}).join("\n")}
  function fromText(txt){
    var out=[],cur=null;
    txt.split("\n").forEach(function(l){
      l=l.trim();if(!l)return;
      var m=/^[#＃]+\s*(.*)$/.exec(l);
      if(m){cur={t:m[1].trim()||"更新",i:[]};out.push(cur)}
      else{if(!cur){cur={t:"更新",i:[]};out.push(cur)}cur.i.push(l)}
    });
    return out.filter(function(x){return x.i.length});
  }

  /* ---------- 样式 ---------- */
  var CSS=""
  +"#clSheet{position:fixed;inset:0;z-index:99990;visibility:hidden;opacity:0;"
  +"transition:opacity calc(.3s/var(--ui-spd,1)) ease,visibility 0s calc(.3s/var(--ui-spd,1))}"
  +"#clSheet.show{visibility:visible;opacity:1;transition:opacity calc(.3s/var(--ui-spd,1)) ease,visibility 0s}"
  +"#clSheet .cl-mask{position:absolute;inset:0;background:rgba(0,0,0,.3)}"
  +"#clSheet .cl-card{position:absolute;left:0;right:0;margin:0 auto;width:calc(100% - 36px);max-width:440px;"
  +"top:calc(env(safe-area-inset-top,0px) + 58px);bottom:calc(env(safe-area-inset-bottom,0px) + 98px);border-radius:32px;color:#fff;"
  +"box-shadow:0 20px 60px rgba(0,0,0,.4);transform:translateY(18px) scale(.985);"
  +"transition:transform calc(.4s/var(--ui-spd,1)) cubic-bezier(.3,1,.4,1)}"
  +"#clSheet.show .cl-card{transform:none}"
  /* 三层并列（不嵌套 backdrop-filter，iOS 上更稳）：底层毛玻璃 / 滚动内容 / 顶部毛玻璃标题栏 */
  +"#clSheet .cl-glass{position:absolute;inset:0;border-radius:32px;border:1px solid rgba(255,255,255,.16);"
  +"background:var(--g-fill),rgba(30,28,36,.46);-webkit-backdrop-filter:var(--g-blur) saturate(1.4);backdrop-filter:var(--g-blur) saturate(1.4)}"
  +"#clSheet .cl-body{position:absolute;inset:0;z-index:1;border-radius:32px;overflow-y:auto;overscroll-behavior:contain;-webkit-overflow-scrolling:touch;"
  +"padding:calc(var(--cl-top,100px) + 14px) 16px 22px;scrollbar-width:none}"
  +"#clSheet .cl-body::-webkit-scrollbar{display:none}"
  +"#clSheet .cl-head{position:absolute;left:0;right:0;top:0;z-index:2;padding:16px 16px 12px 22px;border-radius:32px 32px 0 0;"
  +"background:rgba(46,42,54,.3);-webkit-backdrop-filter:var(--g-blur) saturate(1.5);backdrop-filter:var(--g-blur) saturate(1.5);border-bottom:1px solid rgba(255,255,255,.12)}"
  +"#clSheet .cl-bar{display:flex;align-items:center;gap:10px}"
  +"#clSheet .cl-tt{flex:1;min-width:0;display:flex;align-items:baseline;gap:10px;white-space:nowrap;overflow:hidden}"
  +"#clSheet .cl-title{font-size:19px;font-weight:800;letter-spacing:.3px}"
  +"#clSheet .cl-cur{font-size:12.5px;color:rgba(255,255,255,.55);overflow:hidden;text-overflow:ellipsis}"
  +"#clSheet .cl-x{flex:none;width:32px;height:32px;border:none;border-radius:16px;background:rgba(255,255,255,.16);color:#fff;font-size:14px;cursor:pointer}"
  +"#clSheet .cl-x:active{background:rgba(255,255,255,.28)}"
  +"#clSheet .cl-acts{display:flex;gap:10px;margin-top:12px;padding-right:6px}"
  +"#clSheet .cl-acts .chip{flex:1;padding:8px 0;font-size:13px;color:#fff}"
  +"#clSheet .cl-hint{display:none;align-items:center;gap:8px;margin-top:10px;padding-right:6px;font-size:12.5px;color:rgba(255,255,255,.75)}"
  +"#clSheet.picking .cl-hint{display:flex}"
  +"#clSheet .cl-hint span{flex:1;min-width:0}"
  +"#clSheet .cl-hint button{flex:none;border:none;border-radius:9px;background:rgba(255,255,255,.16);color:#fff;font:inherit;font-size:12px;height:26px;padding:0 10px;cursor:pointer}"
  +"#clSheet .cl-item{padding:16px 16px 6px;margin-bottom:12px;border-radius:26px;background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.06)}"
  +"#clSheet .cl-item.latest{border-color:rgba(143,176,255,.5);background:rgba(143,176,255,.1)}"
  +"#clSheet .cl-vr{display:flex;align-items:center;gap:10px;margin-bottom:12px}"
  +"#clSheet .cl-v{font-size:18px;font-weight:800;min-width:0;word-break:break-word}"
  +"#clSheet .cl-d{font-size:12.5px;color:rgba(255,255,255,.5);font-variant-numeric:tabular-nums;white-space:nowrap}"
  +"#clSheet .cl-new{margin-left:auto;flex:none;padding:3px 11px;border-radius:12px;background:rgba(130,150,230,.78);font-size:12px;font-weight:700}"
  +"#clSheet .cl-sec{margin-bottom:12px}"
  +"#clSheet .cl-tag{display:inline-block;padding:4px 11px;border-radius:12px;font-size:12.5px;font-weight:700;background:rgba(255,255,255,.14);color:#fff}"
  +"#clSheet .cl-tag.k-new{background:rgba(88,190,110,.34);color:#c3f3cb}"
  +"#clSheet .cl-tag.k-opt{background:rgba(90,160,215,.38);color:#c4e4ff}"
  +"#clSheet .cl-tag.k-fix{background:rgba(214,150,95,.38);color:#ffdcb8}"
  +"#clSheet .cl-tag.k-bug{background:rgba(215,95,108,.38);color:#ffc6cc}"
  +"#clSheet ul{margin:10px 0 0;padding:0;list-style:none}"
  +"#clSheet li{position:relative;padding:0 0 0 18px;margin-bottom:8px;font-size:13.5px;line-height:1.6;color:rgba(255,255,255,.88);word-break:break-word}"
  +"#clSheet li::before{content:\"\";position:absolute;left:3px;top:.62em;width:6px;height:6px;border-radius:50%;background:#8fb0ff}"
  +"#clSheet .k-new+ul li::before{background:#6fd283}"
  +"#clSheet .k-opt+ul li::before{background:#5aaee6}"
  +"#clSheet .k-fix+ul li::before{background:#f0a050}"
  +"#clSheet .k-bug+ul li::before{background:#f07a85}"
  +"#clSheet.picking .cl-item{cursor:pointer;outline:1.5px dashed rgba(143,176,255,.8);outline-offset:-1.5px}"
  +"#clSheet.picking .cl-item:active{background:rgba(143,176,255,.24)}"
  +"#clSheet .cl-empty{padding:40px 0;text-align:center;font-size:13px;color:rgba(255,255,255,.5)}"
  +".cl-layer{position:fixed;inset:0;z-index:99995;display:flex;align-items:flex-start;justify-content:center;overflow-y:auto;padding:calc(env(safe-area-inset-top,0px) + 56px) 22px 22px;"
  +"background:rgba(0,0,0,.5);opacity:0;visibility:hidden;transition:opacity calc(.25s/var(--ui-spd,1)) ease,visibility 0s calc(.25s/var(--ui-spd,1))}"
  +".cl-layer.show{opacity:1;visibility:visible;transition:opacity calc(.25s/var(--ui-spd,1)) ease,visibility 0s}"
  +".cl-layer .cl-box{width:100%;max-width:380px;padding:18px 18px 16px;border-radius:24px;color:#fff;"
  +"background:linear-gradient(rgba(36,38,48,.62),rgba(36,38,48,.62));-webkit-backdrop-filter:var(--g-blur) saturate(1.5);backdrop-filter:var(--g-blur) saturate(1.5);"
  +"box-shadow:0 10px 40px rgba(0,0,0,.45);transform:translateY(-10px);transition:transform calc(.3s/var(--ui-spd,1)) cubic-bezier(.3,1,.4,1)}"
  +".cl-layer.show .cl-box{transform:none}"
  +".cl-layer .cl-bt{font-size:16px;font-weight:800;margin-bottom:12px}"
  +".cl-layer label{display:block;font-size:12px;color:rgba(255,255,255,.6);margin:10px 0 5px}"
  +".cl-layer input,.cl-layer textarea{display:block;width:100%;box-sizing:border-box;border:none;outline:none;border-radius:12px;padding:10px 12px;"
  +"background:rgba(255,255,255,.12);color:#fff;font:inherit;font-size:14px;-webkit-user-select:text;user-select:text}"
  +".cl-layer textarea{min-height:170px;resize:none;line-height:1.5}"
  +".cl-layer input::placeholder,.cl-layer textarea::placeholder{color:rgba(255,255,255,.35)}"
  +".cl-layer .cl-qk{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:6px}"
  +".cl-layer .cl-qk button{border:none;border-radius:10px;height:26px;padding:0 10px;font:inherit;font-size:12px;font-weight:600;color:#fff;background:rgba(255,255,255,.14);cursor:pointer}"
  +".cl-layer .cl-qk button:active{background:rgba(255,255,255,.28)}"
  +".cl-layer .cl-err{min-height:18px;margin-top:8px;font-size:12px;color:#ff7a8a}"
  +".cl-layer .cl-btns{display:flex;gap:10px;margin-top:8px}"
  +".cl-layer .cl-btns button{flex:1;border:none;border-radius:14px;height:40px;font:inherit;font-size:14px;font-weight:600;color:#fff;background:rgba(255,255,255,.14);cursor:pointer}"
  +".cl-layer .cl-btns button.ok{background:rgba(80,125,240,.7)}"
  +".cl-layer .cl-btns button:active{filter:brightness(1.25)}"
  +".cl-layer.bad .cl-box{animation:clShake .36s ease}"
  +"@keyframes clShake{20%{transform:translateX(-8px)}40%{transform:translateX(7px)}60%{transform:translateX(-5px)}80%{transform:translateX(3px)}}";
  var st=document.createElement("style");st.id="clStyle";st.textContent=CSS;document.head.appendChild(st);

  /* ---------- DOM ---------- */
  var sheet=mk("div");sheet.id="clSheet";sheet.setAttribute("role","dialog");sheet.setAttribute("aria-label","更新日志");sheet.setAttribute("aria-hidden","true");
  sheet.innerHTML='<div class="cl-mask"></div><div class="cl-card"><div class="cl-glass"></div><div class="cl-body" id="clBody"></div>'
    +'<div class="cl-head"><div class="cl-bar"><div class="cl-tt"><span class="cl-title">更新日志</span><span class="cl-cur" id="clCur"></span></div><button type="button" class="cl-x" aria-label="关闭">✕</button></div>'
    +'<div class="cl-acts"><button type="button" class="chip" id="clAdd">添加版本</button><button type="button" class="chip" id="clMod">修改版本</button></div>'
    +'<div class="cl-hint"><span>点选下方要修改的版本</span><button type="button" id="clPickCancel">取消</button></div></div></div>';
  document.body.appendChild(sheet);
  var head=sheet.querySelector(".cl-head"),bodyEl=sheet.querySelector("#clBody"),curEl=sheet.querySelector("#clCur");

  var auth=mk("div","cl-layer");auth.id="clAuth";auth.setAttribute("aria-hidden","true");
  auth.innerHTML='<div class="cl-box" role="dialog" aria-label="输入密码"><div class="cl-bt">输入密码</div>'
    +'<input type="password" id="clPw" inputmode="numeric" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="请输入密码" aria-label="密码">'
    +'<div class="cl-err" id="clAuthErr"></div><div class="cl-btns"><button type="button" id="clAuthNo">取消</button><button type="button" class="ok" id="clAuthOk">确认</button></div></div>';
  document.body.appendChild(auth);
  var pw=auth.querySelector("#clPw"),authErr=auth.querySelector("#clAuthErr");

  var ed=mk("div","cl-layer");ed.id="clEdit";ed.setAttribute("aria-hidden","true");
  ed.innerHTML='<div class="cl-box" role="dialog" aria-label="编辑版本"><div class="cl-bt" id="clEdTitle">添加版本</div>'
    +'<label for="clEv">版本号</label><input type="text" id="clEv" maxlength="40" autocomplete="off" placeholder="例如 v0.1.2 Beta 4">'
    +'<label for="clEd">日期（可留空）</label><input type="text" id="clEd" maxlength="20" autocomplete="off" placeholder="例如 2026-10-22">'
    +'<label for="clEn">更新内容（「# 」开头的行是分类标题，其余每行一条）</label>'
    +'<div class="cl-qk"><button type="button" data-k="新功能">＋新功能</button><button type="button" data-k="优化">＋优化</button><button type="button" data-k="修复">＋修复</button><button type="button" data-k="已知问题">＋已知问题</button></div>'
    +'<textarea id="clEn" placeholder="# 新功能&#10;主题选择器升级为网格卡片&#10;# 修复&#10;修复若干问题"></textarea>'
    +'<div class="cl-err" id="clEdErr"></div><div class="cl-btns"><button type="button" id="clEdNo">取消</button><button type="button" class="ok" id="clEdOk">保存</button></div></div>';
  document.body.appendChild(ed);
  var fv=ed.querySelector("#clEv"),fd=ed.querySelector("#clEd"),fn=ed.querySelector("#clEn"),edErr=ed.querySelector("#clEdErr");

  /* ---------- 渲染 ---------- */
  function fit(){sheet.querySelector(".cl-card").style.setProperty("--cl-top",head.offsetHeight+"px")}
  function curText(){
    var t=verEl?verEl.textContent.replace(/^\s*版本\s*/,"").trim():"";
    return "当前 "+(t||(list[0]&&list[0].v)||"");
  }
  function render(){
    bodyEl.innerHTML="";curEl.textContent=curText();
    if(!list.length){bodyEl.appendChild(mk("div","cl-empty","暂无更新记录"));return}
    list.forEach(function(it,i){
      var c=mk("div","cl-item"+(i===0?" latest":""));c.dataset.i=i;
      var r=mk("div","cl-vr");r.appendChild(mk("span","cl-v",it.v));
      if(it.d)r.appendChild(mk("span","cl-d",it.d));
      if(i===0)r.appendChild(mk("span","cl-new","最新"));
      c.appendChild(r);
      it.s.forEach(function(sec){
        var s=mk("div","cl-sec");s.appendChild(mk("span","cl-tag k-"+kind(sec.t),sec.t));
        var ul=mk("ul");sec.i.forEach(function(x){ul.appendChild(mk("li","",x))});s.appendChild(ul);c.appendChild(s);
      });
      bodyEl.appendChild(c);
    });
  }
  function setPick(on){pick=!!on;sheet.classList.toggle("picking",pick);fit()}

  /* ---------- 打开 / 关闭 ---------- */
  function openSheet(){
    if(open)return;open=true;list=load();setPick(false);render();
    sheet.classList.add("show");sheet.setAttribute("aria-hidden","false");
    requestAnimationFrame(function(){fit();bodyEl.scrollTop=0});
  }
  function closeSheet(){
    if(!open)return;open=false;hideAuth();hideEdit();setPick(false);
    sheet.classList.remove("show");sheet.setAttribute("aria-hidden","true");
  }
  sheet.querySelector(".cl-x").addEventListener("click",closeSheet);
  sheet.querySelector(".cl-mask").addEventListener("click",closeSheet);

  /* ---------- 密码 ---------- */
  function showAuth(cb){
    onAuth=cb;pw.value="";authErr.textContent="";auth.classList.remove("bad");
    void auth.offsetWidth;auth.classList.add("show");auth.setAttribute("aria-hidden","false");
    try{pw.focus({preventScroll:true})}catch(_){pw.focus()}
  }
  function hideAuth(){auth.classList.remove("show","bad");auth.setAttribute("aria-hidden","true");pw.blur();pw.value="";onAuth=null}
  function submitAuth(){
    if(pw.value===PW){var f=onAuth;hideAuth();if(f)f();return}
    authErr.textContent="密码错误";pw.value="";
    auth.classList.remove("bad");void auth.offsetWidth;auth.classList.add("bad");
    try{pw.focus({preventScroll:true})}catch(_){pw.focus()}
  }
  auth.querySelector("#clAuthOk").addEventListener("click",submitAuth);
  auth.querySelector("#clAuthNo").addEventListener("click",hideAuth);

  /* ---------- 编辑 ---------- */
  function showEdit(i){
    editIdx=i;edErr.textContent="";
    ed.querySelector("#clEdTitle").textContent=i<0?"添加版本":"修改版本";
    if(i<0){fv.value="";fd.value=today();fn.value=""}
    else{fv.value=list[i].v;fd.value=list[i].d;fn.value=toText(list[i].s)}
    void ed.offsetWidth;ed.classList.add("show");ed.setAttribute("aria-hidden","false");
    try{fv.focus({preventScroll:true})}catch(_){fv.focus()}
  }
  function hideEdit(){ed.classList.remove("show");ed.setAttribute("aria-hidden","true");fv.blur();fd.blur();fn.blur();editIdx=-1}
  function saveEdit(){
    var v=fv.value.trim();if(!v){edErr.textContent="请填写版本号";return}
    var it={v:v,d:fd.value.trim(),s:fromText(fn.value)};
    var prev=list.slice();
    if(editIdx<0)list.unshift(it);else list[editIdx]=it;
    if(!persist()){list=prev;edErr.textContent="保存失败：存储空间不可用";return}
    var added=editIdx<0;hideEdit();setPick(false);render();if(added)bodyEl.scrollTop=0;
  }
  ed.querySelector("#clEdOk").addEventListener("click",saveEdit);
  ed.querySelector("#clEdNo").addEventListener("click",hideEdit);
  /* 分类快捷按钮：在光标处插入「# 分类名」一行 */
  ed.querySelector(".cl-qk").addEventListener("click",function(e){
    var b=e.target.closest&&e.target.closest("button");if(!b)return;
    var v=fn.value,a=fn.selectionStart==null?v.length:fn.selectionStart,z=fn.selectionEnd==null?v.length:fn.selectionEnd;
    var pre=v.slice(0,a),ins=(pre&&pre.slice(-1)!=="\n"?"\n":"")+"# "+b.dataset.k+"\n";
    fn.value=pre+ins+v.slice(z);
    var pos=(pre+ins).length;
    try{fn.focus({preventScroll:true})}catch(_){fn.focus()}
    try{fn.setSelectionRange(pos,pos)}catch(_){}
  });

  /* ---------- 两个按钮：每次点击都要先输入密码 ---------- */
  sheet.querySelector("#clAdd").addEventListener("click",function(){
    showAuth(function(){setPick(false);showEdit(-1)});
  });
  sheet.querySelector("#clMod").addEventListener("click",function(){
    showAuth(function(){
      if(!list.length)return;
      setPick(true);bodyEl.scrollTop=0;
    });
  });
  sheet.querySelector("#clPickCancel").addEventListener("click",function(){setPick(false)});
  bodyEl.addEventListener("click",function(e){
    if(!pick)return;var c=e.target.closest&&e.target.closest(".cl-item");if(!c)return;
    showEdit(+c.dataset.i);
  });

  /* ---------- 键盘：输入框内的按键不外泄给全局快捷键；Esc 逐层关闭 ---------- */
  [pw,fv,fd,fn].forEach(function(inp){
    inp.addEventListener("keydown",function(e){
      e.stopPropagation();
      if(e.isComposing||e.keyCode===229)return;
      if(e.key==="Enter"&&inp!==fn){e.preventDefault();if(inp===pw)submitAuth();else saveEdit()}
      else if(e.key==="Escape"){e.preventDefault();if(inp===pw)hideAuth();else hideEdit()}
    });
    inp.addEventListener("keyup",function(e){e.stopPropagation()});
  });
  document.addEventListener("keydown",function(e){
    if(e.key!=="Escape"||!open)return;
    if(auth.classList.contains("show"))hideAuth();
    else if(ed.classList.contains("show"))hideEdit();
    else if(pick)setPick(false);
    else closeSheet();
  });
  window.addEventListener("resize",function(){if(open)fit()});

  /* ---------- 入口：设置页里，紧挨在「版本 …」上方的一个按钮（版本行保持原样，其它模块仍靠它定位） ---------- */
  function hook(){
    var pg5=document.getElementById("pg5");if(!pg5)return false;
    var ver=null;[].forEach.call(pg5.querySelectorAll(".qtip"),function(el){if(el.textContent.indexOf("版本")>=0)ver=el});
    if(!ver)return false;
    verEl=ver;
    if(pg5.querySelector(".cl-entry-btn"))return true;
    var b=mk("button","chip cl-entry-btn");b.type="button";
    b.style.cssText="width:100%;margin-top:16px;padding:12px 0;font-size:14px;display:flex;align-items:center;justify-content:center;gap:8px;";
    b.innerHTML='<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9.5"/><path d="M12 7v6.2"/><path d="M12 16.9v.2"/></svg><span>更新日志</span>';
    b.addEventListener("click",function(e){e.stopPropagation();openSheet()});
    ver.parentNode.insertBefore(b,ver);
    return true;
  }
  if(!hook()){
    var mo=new MutationObserver(function(){if(hook())mo.disconnect()});
    mo.observe(document.body,{childList:true,subtree:true});
  }
  window.__openChangelog=openSheet;
})();
