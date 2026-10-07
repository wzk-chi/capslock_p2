(() => {
  const webview = window.chrome && window.chrome.webview;
  if (!webview) return;

  const logTiming = stage => {
    try { webview.postMessage(JSON.stringify({ type: 'panelTiming', stage, ms: Math.round(performance.now()) })); }
    catch { /* Timing must not interrupt page behavior. */ }
  };
  logTiming('bridge-ready');
  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', () => logTiming('dom-ready'), { once: true });
  else logTiming('dom-ready');
  if (document.readyState === 'complete') logTiming('loaded');
  else window.addEventListener('load', () => logTiming('loaded'), { once: true });

  let lastCursorMove = 0;
  document.addEventListener('mousemove', () => {
    const now = performance.now();
    if (now - lastCursorMove < 80) return;
    lastCursorMove = now;
    webview.postMessage(JSON.stringify({ type: 'cursorMove' }));
  }, { passive: true });
})();
