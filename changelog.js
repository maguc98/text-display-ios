/* ==========================================================
 * 更新日志 (changelog.js) - 纯文本极简版 (带一键复制模板)
 * ========================================================== */

var CHANGELOG_TEXT = `

<!-- ================= 👇 专属修改模板（直接复制这一整块） 👇 =================

# v0.1.2 | 2026-11-05 | 最新
### 新功能
- 写你的新功能 A
- 写你的新功能 B

### 优化
- 写你的优化点

### 修复
- 写你修复的 Bug

### 已知问题
- 写还没修好的问题（可选）

---

================================================================================ -->

# v0.1.1 Beta 3 | 2026-10-21 | 最新
### 新功能
- 主题选择器升级为网格卡片：每个主题独立记忆背景类型
- 长按主题卡片显示笔形遮罩，点击进入编辑
- 支持拖动主题卡片调整顺序
- 顶部文字输入栏：修改文字不再触发页面自动放大
- 播放卡片：上滑迷你条打开

### 优化
- 玻璃拟态材质统一：面板 / 菜单 / 按钮共用一套模糊参数
- 背景切换平滑过渡
- 时间轴性能优化：用 scaleX 代替 width

### 修复
- 修复主题选择器展开过程中毛玻璃失效的问题
- 修复 iOS 上内容不绘制的问题
- 修复迷你条收起时残留黑边的问题

### 已知问题
- iOS Safari 上首次展开主题选择器时，毛玻璃偶现约 200ms 延迟
- 部分 Android 机型长时间播放后帧率缓慢下降
- 极长文本在海报排版下可能超出屏幕边界

---

# v0.0.3 | 2026-09-28
### 新功能
- 深色磨砂面板重新设计
- 小卡片布局：右侧设置面板 + 底部迷你条
- 动效风格改为单个下拉选择 + 气泡菜单

### 优化
- 卡片区域紧凑排版
- 滑杆与开关统一为 iOS 风格

### 修复
- 修复部分机型上弹出菜单定位错位的问题

---

# v0.0.2 | 2026-09-10
### 新功能
- 全屏文字背景，移除居中舞台限制
- 底部迷你播放条 + 点开才出现的小卡片
- 时间轴长按放大镜

### 优化
- 弹簧物理优化
- 面板展开 / 收起改为 WAAPI 驱动

---

# v0.0.1 | 2026-08-15
### 新功能
- 文字逐句播放，支持多种动效
- 混色渐变 / 纯色 / 图片背景
- 逐句卡片编辑
- 自动保存、导入 / 导出项目
`;

// 👆 ================== 配置区结束 ==================


// 👇 ================== 解析与渲染逻辑 ==================
(function(){
  'use strict';
  if (window.__changelogInstalled) return;
  window.__changelogInstalled = true;

  // 1. 解析纯文本，转为程序需要的格式
  function parseText(text) {
    // 【新增】自动过滤掉 <!-- 和 --> 之间的内容（即上面的模板）
    text = text.replace(/<!--[\s\S]*?-->/g, '');

    var data = [];
    // 按 --- 分割不同版本块
    var blocks = text.split(/---+/);
    
    blocks.forEach(function(block) {
      block = block.trim();
      if (!block) return;
      
      var lines = block.split('\n');
      // 解析第一行： # 版本号 | 日期 | 最新
      var verInfo = lines[0].replace(/^#\s*/, '').trim();
      // 如果这行压根不是以 # 开头的，可能是没过滤干净的废代码，直接跳过
      if (!lines[0].trim().startsWith('#')) return;
      
      var parts = verInfo.split('|').map(function(s){ return s.trim(); });
      
      var ver = parts[0] || '未知版本';
      var date = parts[1] || '';
      var latest = (parts[2] === '最新' || parts[2] === 'true');
      
      var sections = [];
      var currentSection = null;
      
      for (var i = 1; i < lines.length; i++) {
        var line = lines[i].trim();
        if (!line) continue;
        
        // 解析分类标题
        if (line.indexOf('###') === 0) {
          var title = line.replace(/^###\s*/, '').trim();
          var type = 'new'; // 默认新功能
          if (title.indexOf('优化') >= 0) type = 'opt';
          else if (title.indexOf('修复') >= 0) type = 'fix';
          else if (title.indexOf('问题') >= 0 || title.indexOf('bug') >= 0 || title.indexOf('Bug') >= 0) type = 'bug';
          else if (title.indexOf('设计') >= 0) type = 'design';
          
          currentSection = { type: type, title: title, items: [] };
          sections.push(currentSection);
        } 
        // 解析列表项
        else if (line.indexOf('-') === 0 && currentSection) {
          var itemText = line.replace(/^-\s*/, '').trim();
          if (itemText) currentSection.items.push(itemText);
        }
      }
      
      data.push({
        ver: ver,
        date: date,
        latest: latest,
        sections: sections
      });
    });
    return data;
  }

  // 获取解析后的数据
  var CHANGELOG_DATA = parseText(CHANGELOG_TEXT);
  
  // 自动从第一条数据中提取当前版本号
  var CURRENT_VERSION = CHANGELOG_DATA.length > 0 ? CHANGELOG_DATA[0].ver : 'v1.0.0';

  /* ---- 面板 DOM ---- */
  var mask = document.createElement('div');
  mask.id = 'changelogMask';
  document.body.appendChild(mask);

  var panel = document.createElement('div');
  panel.id = 'changelogPanel';
  panel.setAttribute('aria-hidden', 'true');
  panel.setAttribute('role', 'dialog');
  panel.innerHTML =
    '<div class="cl-head">' +
      '<div class="cl-title">更新日志<em>当前 ' + CURRENT_VERSION + '</em></div>' +
      '<button type="button" class="cl-close" aria-label="关闭">✕</button>' +
    '</div>' +
    '<div class="cl-body"></div>';
  document.body.appendChild(panel);

  var bodyEl = panel.querySelector('.cl-body');
  var closeBtn = panel.querySelector('.cl-close');

  /* ---- 渲染 ---- */
  var html = '';
  CHANGELOG_DATA.forEach(function(v){
    html += '<div class="cl-ver' + (v.latest ? ' latest' : '') + '">';
    html += '<div class="cl-ver-head">';
    html += '<span class="cl-ver-no">' + v.ver + '</span>';
    if (v.date) html += '<span class="cl-ver-date">' + v.date + '</span>';
    if (v.latest) html += '<span class="cl-badge">最新</span>';
    html += '</div>';
    
    v.sections.forEach(function(s){
      if (!s.items.length) return; // 如果分类下没写东西就跳过
      html += '<div class="cl-group ' + s.type + '">';
      html += '<span class="cl-group-title">' + s.title + '</span>';
      html += '<ul>';
      s.items.forEach(function(t){ html += '<li>' + t + '</li>'; });
      html += '</ul></div>';
    });
    html += '</div>';
  });
  bodyEl.innerHTML = html;

  /* ---- 打开 / 关闭 ---- */
  var isOpen = false;

  function setOrigin(e){
    if (!e || e.clientX == null) {
      panel.style.removeProperty('--mx');
      panel.style.removeProperty('--my');
      return;
    }
    var W = panel.offsetWidth  || 420; 
    var H = panel.offsetHeight || 500;
    var mx = e.clientX - (window.innerWidth  / 2 - W / 2);
    var my = e.clientY - (window.innerHeight / 2 - H / 2);
    panel.style.setProperty('--mx', mx.toFixed(1) + 'px');
    panel.style.setProperty('--my', my.toFixed(1) + 'px');
  }

  function open(e){
    if (isOpen) return;
    isOpen = true;

    ['qpop', 'mediaMenu', 'stylePop', 'ddPop', 'bgPop', 'zoomPop'].forEach(function(id){
      var el = document.getElementById(id);
      if (el && el.classList.contains('show')) {
        el.classList.remove('show');
        el.setAttribute('aria-hidden', 'true');
      }
    });

    setOrigin(e);

    mask.classList.add('show');
    panel.classList.add('show');
    panel.setAttribute('aria-hidden', 'false');
    bodyEl.scrollTop = 0;
  }

  function close(){
    if (!isOpen) return;
    isOpen = false;
    mask.classList.remove('show');
    panel.classList.remove('show');
    panel.setAttribute('aria-hidden', 'true');
  }

  mask.addEventListener('click', close);
  closeBtn.addEventListener('click', close);
  document.addEventListener('keydown', function(e){
    if (e.key === 'Escape' && isOpen) close();
  });

  /* ---- 注入入口 ---- */
  function inject(){
    var pg5 = document.getElementById('pg5');
    if (!pg5 || pg5.querySelector('.cl-entry-btn')) return;
    var box = pg5.querySelector('.pm-box') || pg5;
    var verEl = null;
    box.querySelectorAll('.qtip').forEach(function(el){
      if (el.textContent.indexOf('版本') >= 0) verEl = el;
    });

    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'chip cl-entry-btn';
    btn.innerHTML =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">' +
        '<path d="M12 8v5M12 16h.01"/><circle cx="12" cy="12" r="9"/>' +
      '</svg>更新日志';
    btn.addEventListener('click', function(e){ open(e); });

    if (verEl) verEl.parentNode.insertBefore(btn, verEl);
    else box.appendChild(btn);

    if (verEl) {
      verEl.style.cursor = 'pointer';
      verEl.style.textDecoration = 'underline';
      verEl.style.textDecorationColor = 'rgba(255,255,255,.25)';
      verEl.style.textUnderlineOffset = '3px';
      verEl.addEventListener('click', function(e){ open(e); });
    }
  }

  if (document.getElementById('pg5')) inject();
  else {
    var mo = new MutationObserver(function(){
      if (document.getElementById('pg5')) { inject(); mo.disconnect(); }
    });
    mo.observe(document.body, { childList: true, subtree: true });
  }

  window.__openChangelog  = open;
  window.__closeChangelog = close;
})();