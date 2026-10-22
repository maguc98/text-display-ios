// app/mini-player.js — 迷你条 + 播放卡片抽屉
/* ===== Original script block separator ===== */

/* ---- v0.0.2 布局：迷你条 ⇄ 小卡片 ---- */
(function(){
  var B=document.body,g=function(i){return document.getElementById(i)};
  var mini=g("mini"),back=g("hback"),stg=g("stage");
  var npT=g("npT"),miT=g("miT"),tile=g("miTile"),cover=g("hubCover"),ckey="";
  var ckey2="",coverPainted=false;
  function paintCover(){
    var bg=g("bg");
    var bgImg=(typeof bgMode!=="undefined"&&bgMode==="img"&&typeof imgData!=="undefined"&&imgData)?imgData:"";
    var val,key;
    /* --cover：背景页图片 / 背景光晕，只跟背景走 */
    if(bgImg){key="i"+bgImg.length+bgImg.slice(-48);val="url('"+bgImg+"')"}
    else{var bi=bg.style.backgroundImage;
      if(bi&&bi!=="none"){key="g"+bi;val=bi}
      else{var c=bg.style.backgroundColor||"#1c1c24";key="c"+c;val="linear-gradient("+c+","+c+")"}}
    if(key!==ckey){ckey=key;B.style.setProperty("--cover",val)}
    
    /* --cover2：图一（迷你条小封面）和图二（卡片大封面）的独立封面；没设置时回退到 --cover */
    var cc=window.customCoverData||"";
    var k2=cc?"i"+cc.length+cc.slice(-48):"";
    
    if(k2!==ckey2){
      var oldCkey2 = ckey2;
      ckey2 = k2;
      
      // 读取渐变速度
      var speed = parseFloat(document.getElementById("qFadeSpeed") ? document.getElementById("qFadeSpeed").value : 1.5);
      
      // 交叉渐变动画（在写入新图之前，先把旧图复制成一层盖在上面，再淡出）
      if(cc && speed > 0 && coverPainted) {
        var nImg = document.getElementById("npImg");
        var targets = [tile, nImg];
        targets.forEach(function(el){
          if(!el) return;
          var oldBg = getComputedStyle(el).backgroundImage;
          if(oldBg && oldBg !== 'none') {
            var oldLayer = document.createElement("div");
            oldLayer.style.cssText = "position:absolute;inset:0;background-size:cover;background-position:center;z-index:1;pointer-events:none;border-radius:inherit;display:flex;align-items:center;justify-content:center;font:inherit;color:inherit;background-image:" + oldBg + ";";
            /* 旧状态还是占位字（没有图片）时，把字一起带进旧层，避免它瞬间消失 */
            if(!el.classList.contains("img")) oldLayer.textContent = el.textContent;
            
            if(getComputedStyle(el).position === 'static') el.style.position = 'relative';
            el.style.overflow = "hidden";
            el.appendChild(oldLayer);
            
            void oldLayer.offsetHeight;
            oldLayer.style.transition = "opacity " + speed + "s ease";
            oldLayer.style.opacity = "0";
            setTimeout(function(){ oldLayer.remove(); }, speed * 1000);
          }
        });
      }
      
      if(cc){
        B.style.setProperty("--cover2","url('"+cc+"')");
      } else {
        B.style.removeProperty("--cover2");
      }
    }
    
    cover.classList.toggle("img",!!bgImg);
    if(tile) tile.classList.toggle("img",!!(cc||bgImg));
    coverPainted=true;
  }

  // ===== 独立封面上传 =====
  var coverFile=document.createElement('input');
  coverFile.type='file';coverFile.accept='image/*';coverFile.style.display='none';
  document.body.appendChild(coverFile);
  window.__pickCover=function(){coverFile.click()};
  coverFile.onchange=function(){
    var f=this.files[0];this.value="";if(!f)return;
    var r=new FileReader();
    r.onload=function(){
      var im=new Image();
      im.onload=function(){
        // 如果页面上有 openCrop 函数，调用它进行 1:1 裁剪
        if (typeof openCrop === "function") {
          openCrop(im, function(croppedCanvas){
            // 裁剪界面已完全关闭；延迟 2.5 秒（2500毫秒）再执行渐变
            setTimeout(function(){
              window.customCoverData = croppedCanvas.toDataURL('image/jpeg', 0.85);
              paintCover();
              document.dispatchEvent(new Event('change')); // 触发自动保存
            }, 2500);
          }, {
            ratio: 1, 
            max: 800, 
            title: "裁剪专属封面 · 1:1", 
            sub: "拖动选择显示位置，双指或滑杆缩放"
          });
        } else {
          // 兜底：如果没有裁剪器，按原逻辑压缩
          var maxW=800,maxH=800;
          var scale=Math.min(1,maxW/im.width,maxH/im.height);
          var cvs=document.createElement('canvas');
          cvs.width=Math.max(1,Math.round(im.width*scale));cvs.height=Math.max(1,Math.round(im.height*scale));
          cvs.getContext('2d').drawImage(im,0,0,cvs.width,cvs.height);
          window.customCoverData=cvs.toDataURL('image/jpeg',0.85);
          paintCover();
          document.dispatchEvent(new Event('change'));
        }
      };
      im.src=r.result;
    };
    r.readAsDataURL(f);
  };

  // 点击小封面，直接弹出修改图片（大封面在播放卡片里同样绑定）
  // if(tile) tile.addEventListener('click',function(e){e.stopPropagation();coverFile.click();}); // 已取消：点击迷你条封面不再弹出换图
  function isOpen(){return B.classList.contains("open")}
  function setOpen(on){
    on=!!on;
    // 打开右侧前，强制关闭左侧播放卡片
    if(on) {
      var npCardEl = document.getElementById("npCard");
      if (npCardEl && npCardEl.classList.contains("show")) {
        if (typeof npClose === "function") npClose();
      }
    }
    if(isOpen()===on)return;
    B.classList.toggle("open",on);
    mini.setAttribute("aria-expanded",on?"true":"false");
    if(!on&&typeof qOpen==="function")qOpen(false);
    if(on&&typeof putThumb==="function"&&typeof curK==="function")setTimeout(function(){putThumb(curK(),true)},0);
  }
  mini.addEventListener("click",function(e){
    if(e.target.closest&&e.target.closest("button"))return;
    setOpen(!isOpen());
  });
  mini.addEventListener("keydown",function(e){
    if((e.key==="Enter"||e.key===" ")&&e.target===mini){e.preventDefault();setOpen(!isOpen())}
  });
  var miSet=g("miSet");
  if(miSet)miSet.addEventListener("click",function(e){e.stopPropagation();setOpen(true)});

  /* ---- 播放卡片：上滑迷你条弹出，下滑 / 点外面收起 ---- */
  var npCard=document.createElement("div");npCard.id="npCard";npCard.setAttribute("role","dialog");npCard.setAttribute("aria-hidden","true");
  npCard.innerHTML='<div class="np-grab"></div><div class="np-cov"><div class="np-img" id="npImg">文</div><span class="np-cov-i" id="npCovBtn" role="button" aria-label="更换封面"><svg viewBox="0 0 24 24" width="30" height="30" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="3"/><circle cx="9" cy="10" r="1.8"/><path d="M4 18l5-5 4 4 3-3 4 4"/></svg></span></div>'
    +'<div class="np-t" id="npTt">—</div><div class="np-s1" id="npS1"></div><div class="np-s2" id="npS2"></div>'
    +'<div class="np-row">'
    +'<button class="np-b" type="button" data-a="prev" aria-label="上一句"><svg viewBox="0 0 24 24"><path d="M18.5 6.6v10.8L9.2 12z" fill="currentColor" stroke="currentColor" stroke-width="2.2" stroke-linejoin="round"/><path d="M5.2 6.2v11.6" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"/></svg></button>'
    +'<button class="np-b" type="button" data-a="play" aria-label="暂停/继续"></button>'
    +'<button class="np-b" type="button" data-a="next" aria-label="下一句"></button>'
    +'<span class="np-sp"></span>'
    +'<button class="np-b" type="button" data-a="mode" id="npModeBtn" aria-label="播放模式"></button>'
    +'</div>';
  document.body.appendChild(npCard);
  var npPlay=npCard.querySelector('[data-a="play"]'),npNext=npCard.querySelector('[data-a="next"]');
  npNext.innerHTML=IC.next;

  // 播放模式相关
  window.playMode = 0; // 0:顺序, 1:随机, 2:重复
  var npModeBtn = npCard.querySelector("#npModeBtn");
  var modeIcons = [
    '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6h12M4 12h12M4 18h12"/><path d="M17 15l3 3-3 3"/></svg>',
    '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 3h5v5M4 20L21 3M21 16v5h-5M15 15l6 6M4 4l5 5"/></svg>',
    '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 2l4 4-4 4M3 11v-1a4 4 0 0 1 4-4h14M7 22l-4-4 4-4M21 13v1a4 4 0 0 1-4 4H3"/></svg>'
  ];
  if(npModeBtn) {
    npModeBtn.innerHTML = modeIcons[0];
  }
  var npImg=npCard.querySelector("#npImg"),npTt=npCard.querySelector("#npTt"),npS1=npCard.querySelector("#npS1"),npS2=npCard.querySelector("#npS2"),npTimer=0;
  var npCov=npCard.querySelector(".np-cov"),npCovBtn=npCard.querySelector("#npCovBtn"),npArmT=0;
  function npArm(on){clearTimeout(npArmT);npCov.classList.toggle("armed",!!on);if(on)npArmT=setTimeout(function(){npCov.classList.remove("armed")},3000)}
  npImg.addEventListener("click",function(e){e.stopPropagation();npArm(!npCov.classList.contains("armed"))});   /* 点一下：蒙版 + 中间图标；再点封面别处收起；3 秒自动收起 */
  npCovBtn.addEventListener("click",function(e){e.stopPropagation();npArm(false);coverFile.click()});            /* 点中间图标：选图 */
  var isNpDragging = false; // 拖拽抽屉期间为 true：npRefresh 只直接赋值，不做淡入动画
  // 直接设置文字（不动画），并同步 fadeSwap 用的目标值，避免之后比较出错
  function npSetNow(el,txt){
    clearTimeout(el._ft);el._tgt=txt;
    if(el.textContent!==txt)el.textContent=txt;
    el.style.removeProperty('transition');el.style.opacity='1';
  }
  function npRefresh(){
    // 如果正在拖拽，直接更新文字内容，不加任何动画，保证流畅度
    if(isNpDragging){
      npSetNow(npTt,curT(miT));
      var st0=mini.querySelector(".mi-s");
      var s10=st0 ? st0.textContent : "";
      if(npS1.textContent !== s10) npS1.textContent = s10;
      var n0=0,nx0="";try{n0=LN.length;nx0=String((LN[(idx+1)%n0]||"")).replace(/\s+/g," ").trim()}catch(_){}
      npSetNow(npS2,nx0&&n0>1?"下一句 · "+nx0:"");
      if(npImg.textContent !== tile.textContent) npImg.textContent = tile.textContent;
      npImg.classList.toggle("img",tile.classList.contains("img"));
      var isPlay0=(typeof playing!=="undefined"&&playing)?1:0;
      if(npPlay._p !== isPlay0){npPlay._p=isPlay0;npPlay.innerHTML=isPlay0?IC.pause:IC.play}
      return;
    }
    // 1. 标题：保留柔和动画
    fadeSwap(npTt,curT(miT));
    
    // 2. 进度/剩余时间：直接赋值，绝对不添加动画，防止跳变闪烁
    var st=mini.querySelector(".mi-s");
    var s1=st ? st.textContent : "";
    if(npS1.textContent !== s1) npS1.textContent = s1;
    
    // 3. 下一句：保留柔和动画
    var n=0,nx="";try{n=LN.length;nx=String((LN[(idx+1)%n]||"")).replace(/\s+/g," ").trim()}catch(_){}
    var s2Text = nx&&n>1?"下一句 · "+nx:"";
    fadeSwap(npS2,s2Text);
    
    // 4. 封面首字 / 播放键图标：刷新率提到 50ms 后，只在真的变了才写 DOM（否则按钮里的图标每 50ms 重建一次）
    if(npImg.textContent !== tile.textContent) npImg.textContent = tile.textContent;
    npImg.classList.toggle("img",tile.classList.contains("img"));
    var isPlay=(typeof playing!=="undefined"&&playing)?1:0;
    if(npPlay._p !== isPlay){npPlay._p=isPlay;npPlay.innerHTML=isPlay?IC.pause:IC.play}
  }
  function npOpen(){
    // 打开左侧前，强制关闭右侧工具栏
    if(B.classList.contains("open")) {
      if (typeof setOpen === "function") setOpen(false);
    }
    
    npRefresh();clearInterval(npTimer);npTimer=setInterval(npRefresh,document.body.classList.contains("performance-mode")?100:50);
    npCard.classList.add("show");npCard.setAttribute("aria-hidden","false");
    if(!B.classList.contains("np-open"))B.classList.add("np-open");
  }
  function npClose(){
    clearInterval(npTimer);
    npCard.classList.remove("show");
    npCard.setAttribute("aria-hidden","true");
    if(B.classList.contains("np-open"))B.classList.remove("np-open"); // 恢复底部小白条（先判断再删：无条件 remove 也会触发 class 变动，被下面的 MutationObserver 反复调用 npClose 造成死循环）
  }
  window.addEventListener("performance-mode-change",function(){
    if(!npCard.classList.contains("show"))return;
    clearInterval(npTimer);
    npTimer=setInterval(npRefresh,document.body.classList.contains("performance-mode")?100:50);
  });
  npCard.addEventListener("click",function(e){
    var b=e.target.closest&&e.target.closest("button");if(!b)return;e.stopPropagation();
    var a=b.getAttribute("data-a");
    if(a==="prev"){var n=LN.length||1;gotoIdx((idx-1+n)%n,false)}
    else if(a==="next"){gotoIdx(nextIdx(),false)}
    else if(a==="play"){setPlay(!playing)}
    else if(a==="mode"){
      window.playMode = (window.playMode + 1) % 3;
      npModeBtn.innerHTML = modeIcons[window.playMode];
      // 联动原来的随机复选框（只有在随机模式下才勾选 shuf）
      var shufChk = document.getElementById("shuf");
      if (shufChk) { shufChk.checked = (window.playMode === 1); shufChk.dispatchEvent(new Event("change")); }
    }
    npRefresh();
  });
  // ====== 迷你条左右滑动逻辑 ======
  (function(){
    var sx=0,sy=0,down=false,swiped=false;
    mini.addEventListener("pointerdown",function(e){
      swiped=false;
      if(e.target.closest&&e.target.closest("button"))return;
      sx=e.clientX;sy=e.clientY;down=true;
    });
    mini.addEventListener("pointerup",function(e){
      if(!down)return;down=false;
      var dx=e.clientX-sx,dy=e.clientY-sy;
      if(Math.abs(dx)>36&&Math.abs(dx)>Math.abs(dy)*1.5){B.classList.toggle("mx",dx>0);swiped=true}
      else if(dy<-36&&Math.abs(dy)>Math.abs(dx)*1.5){npOpen();swiped=true}
    });
    mini.addEventListener("pointercancel",function(){down=false});
    mini.addEventListener("click",function(e){if(swiped){swiped=false;e.stopImmediatePropagation();e.preventDefault()}},true);
    mini.addEventListener("keydown",function(e){
      if(e.target!==mini)return;
      if(e.key==="ArrowRight")B.classList.add("mx");else if(e.key==="ArrowLeft")B.classList.remove("mx");
    });
  })();
  // ====== 滑动逻辑结束 ======

  // ====== 底部抽屉 (Bottom Sheet) 动画逻辑 ======
  var miGrab = document.createElement('div');
  miGrab.className = 'mi-grab';
  mini.appendChild(miGrab);
  var npGrab = npCard.querySelector('.np-grab');
  
  var isDragging = false, dragFromMini = false, startY = 0, fullH = 0, endTimer = 0;
  var PT = 10, PB = 12; // 卡片上下内边距（与 CSS 一致），高度收到 0 时必须一起归零，否则会残留一条边
  // 清掉所有行内样式，交回给 CSS 管理
  function resetCard() {
    npCard.style.cssText = '';
  }

  // 把卡片设成"比例 p"的样子：p=0 完全消失（只剩小白条），p=1 完整卡片
  function paint(p, h) {
    npCard.style.height = h + 'px';
    npCard.style.paddingTop = (PT * p) + 'px';
    npCard.style.paddingBottom = (PB * p) + 'px';
    npCard.style.pointerEvents = p > 0 ? 'auto' : 'none';
    if (p > 0) {
      npCard.style.background = 'rgba(65, 65, 75, ' + (0.45 * p) + ')';
      npCard.style.boxShadow = '0 18px 50px rgba(0,0,0,' + (0.25 * p) + ')';
      npCard.style.backdropFilter = ''; npCard.style.webkitBackdropFilter = '';
    } else {
      // 高度为 0 时连毛玻璃模糊一起去掉，否则会留下一条黑边
      npCard.style.background = 'transparent';
      npCard.style.boxShadow = 'none';
      npCard.style.backdropFilter = 'none'; npCard.style.webkitBackdropFilter = 'none';
    }
  }

  function startDrag(e, fromMini, y0) {
    isNpDragging = true;
    e.preventDefault();
    e.stopPropagation();
    try { e.currentTarget.setPointerCapture(e.pointerId); } catch(_) {}
    clearTimeout(endTimer);
    // 卡片已经展开时，迷你条上的小白条也只负责"往下收"
    if (fromMini && npCard.classList.contains('show')) fromMini = false;
    dragFromMini = fromMini;
    npRefresh(); // isNpDragging 为 true：文字直接就位、不淡入，露出时就是最新内容
    
    npCard.classList.add('show');
    npCard.style.transition = 'none';
    npCard.style.height = 'auto';
    npCard.style.paddingTop = ''; npCard.style.paddingBottom = '';
    npCard.style.opacity = '1';
    npCard.style.visibility = 'visible';
    npCard.style.transform = 'none';
    fullH = npCard.offsetHeight;
    
    isDragging = true;
    startY = (typeof y0 === 'number') ? y0 : e.clientY;
    
    if (fromMini) {
      paint(0, 0); // paint 会把 pointerEvents 设成 none，露出后在 paint(p>0) 里恢复 auto
    }
  }

  function moveDrag(e) {
    if (!isDragging) return;
    var dy = e.clientY - startY;
    var currentH = dragFromMini ? (0 - dy) : (fullH - dy);
    currentH = Math.max(0, Math.min(fullH, currentH));
    paint(currentH / fullH, currentH);
  }

  function endDrag(e) {
    if (!isDragging) return;
    isDragging = false;
    var dy = e.clientY - startY;
    var shouldOpen = dragFromMini ? (-dy > 80) : (dy <= 80);
    
    var _d = (0.35 / UISPD) + 's';
    npCard.style.transition = 'height ' + _d + ' cubic-bezier(0.32, 0.72, 0, 1), padding ' + _d + ' cubic-bezier(0.32, 0.72, 0, 1), background ' + _d + ', box-shadow ' + _d;

    if (shouldOpen) {
      paint(1, fullH);
      if (typeof npOpen === 'function') npOpen();
      endTimer = setTimeout(function(){
        if (isDragging) return;
        resetCard();
        npCard.classList.add('show');
      }, uiT(350));
    } else {
      paint(0, 0);
      if (typeof npClose === 'function') npClose();
      endTimer = setTimeout(function(){
        if (isDragging) return;
        // 先在隐藏状态下清理，避免满尺寸卡片闪现；最终只留下小白条
        npCard.style.cssText = 'transition:none;visibility:hidden;opacity:0';
        void npCard.offsetHeight;
        npCard.classList.remove('show'); // 彻底隐藏卡片
        npCard.style.cssText = '';
      }, uiT(350));
    }
    isNpDragging = false;
  }

  if (miGrab) {
    var gPending = false, gX = 0, gY = 0, gDragged = false;
    miGrab.addEventListener('pointerdown', function(e){
      gDragged = false; gPending = true; gX = e.clientX; gY = e.clientY;
      try { miGrab.setPointerCapture(e.pointerId); } catch(_) {} // 鼠标移出 20px 高的小白条后仍能收到 move（触屏本来就隐式捕获）；click 仍会冒泡给迷你条
      try { miGrab.setPointerCapture(e.pointerId); } catch(_) {}
      e.stopPropagation(); // 只挡 pointerdown（避免迷你条横滑/上滑逻辑重复触发）；不 preventDefault，单击照常产生
    });
    miGrab.addEventListener('pointermove', function(e){
      if (isDragging) { moveDrag(e); return; }
      if (!gPending) return;
      var dx = e.clientX - gX, dy = e.clientY - gY;
      if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) {
        gPending = false; gDragged = true;
        startDrag(e, true, gY);
        moveDrag(e);
      } else if (Math.abs(dx) > 10) {
        gPending = false; // 横向为主：不是抽屉拖拽
      }
    });
    miGrab.addEventListener('pointerup', function(e){ gPending = false; endDrag(e); });
    miGrab.addEventListener('pointercancel', function(e){ gPending = false; endDrag(e); });
    // 只有真的拖过才吞掉 click；普通单击放行给迷你条（展开/收起面板）
    miGrab.addEventListener('click', function(e){
      if (gDragged) { gDragged = false; e.stopPropagation(); e.preventDefault(); }
    });
  }
  if (npGrab) {
    npGrab.addEventListener('pointerdown', function(e){ startDrag(e, false); });
    npGrab.addEventListener('pointermove', moveDrag);
    npGrab.addEventListener('pointerup', endDrag);
    npGrab.addEventListener('pointercancel', endDrag);
  }
  // ====== 抽屉动画逻辑结束 ======
  document.addEventListener("pointerdown",function(e){
    // 如果点击的是裁剪界面（#crop）及其内部元素，直接跳过，不触发关闭逻辑
    if(e.target && e.target.closest && e.target.closest("#crop")) return;
    
    if(npCard.classList.contains("show")&&!npCard.contains(e.target)&&!mini.contains(e.target))npClose();
  },true);
  new MutationObserver(function(){if(B.classList.contains("open"))npClose()}).observe(B,{attributes:true,attributeFilter:["class"]});
  back.addEventListener("click",function(){setOpen(false)});
  g("cfold").onclick=function(e){if(e)e.stopPropagation();setOpen(false)};
  /* 卡片展开时，点一下背景 = 收起（不触发暂停） */
  document.addEventListener("click",function(e){
    if(!isOpen())return;
    if(stg.contains(e.target)){e.stopPropagation();e.preventDefault();setOpen(false)}
  },true);
  /* 当前句子 → 迷你条 / 卡片标题 */
  var last=null;
  /* 文字淡出 -> 换字 -> 淡入（纯透明度，没有位移）。_tgt 记住"正在换成什么"，避免 50ms 刷新时反复重置 */
  function curT(el){return el._tgt!==undefined?el._tgt:el.textContent}
  function fadeSwap(el,txt){
    if(curT(el)===txt)return;
    el._tgt=txt;clearTimeout(el._ft);
    el.style.transition="opacity "+(.14/UISPD)+"s ease";el.style.opacity="0";
    el._ft=setTimeout(function(){
      el.textContent=txt;
      el.style.transition="opacity "+(.22/UISPD)+"s ease";el.style.opacity="1";
    },uiT(150));
  }
  function tick(){
    paintCover();
    var s="";try{s=(LN&&LN[idx])||""}catch(_){}
    s=String(s).replace(/\s+/g," ").trim();
    if(s===last)return;last=s;
    var t=s||"—";
    
    fadeSwap(npT,t);
    fadeSwap(miT,t);
    tile.textContent=cover.textContent=s?Array.from(s)[0]:"文";
  }
  tick();setInterval(tick,200);
})();

