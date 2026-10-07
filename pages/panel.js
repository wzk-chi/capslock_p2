(() => {
  const webview = window.chrome && window.chrome.webview;
  if (!webview) return;

  let lastCursorMove = 0;
  document.addEventListener('mousemove', () => {
    const now = performance.now();
    if (now - lastCursorMove < 80) return;
    lastCursorMove = now;
    webview.postMessage(JSON.stringify({ type: 'cursorMove' }));
  }, { passive: true });
})();
