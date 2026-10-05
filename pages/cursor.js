/* Shared Windows mouse-vanish recovery for interactive WebView2 pages. */
(() => {
  const bridge = window.chrome && window.chrome.webview;
  if (!bridge) return;

  const message = 'capslockPlus:cursorMove';
  let lastPostedAt = 0;
  document.addEventListener('mousemove', () => {
    const now = performance.now();
    if (now - lastPostedAt < 80) return;
    lastPostedAt = now;
    bridge.postMessage(message);
  }, { passive: true });
})();
