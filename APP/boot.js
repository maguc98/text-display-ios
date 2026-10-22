// app/boot.js — 启动
applyPreset(0);render();$("gbox").classList.toggle("hide",bgMode!=="grad");$("ibox").classList.toggle("hide",bgMode!=="img");$("solidbox").classList.toggle("hide",bgMode!=="solid");applyBg();startTick();

/* ===== Original script block separator ===== */

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    // 仅在 HTTPS 或 localhost 环境下注册，避免本地 file:// 或编辑器预览时报错
    if (window.location.protocol === 'https:' || window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') {
      navigator.serviceWorker.register('./sw.js')
        .then(reg => console.log('SW ready:', reg.scope))
        .catch(err => console.log('SW bypassed:', err.message));
    }
  });
}

