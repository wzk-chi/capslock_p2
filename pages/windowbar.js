/* Shared behavior for custom WebView2 title bars. Page code owns labels and
   state; this module only wires the common drag and window actions. */
(function () {
  'use strict';

  function post(type) {
    if (window.chrome && chrome.webview)
      chrome.webview.postMessage(JSON.stringify({ type }));
  }

  function debug(stage, detail = '') {
    if (window.chrome && chrome.webview)
      chrome.webview.postMessage(JSON.stringify({
        type: 'uiDebug', source: 'windowbar', stage, detail
      }));
  }

  function icon(name) {
    const node = document.createElement('i');
    node.dataset.lucide = /^[a-z0-9-]+$/i.test(String(name)) ? String(name) : 'circle';
    return node;
  }

  function build(root) {
    debug('build:start');
    const title = root.dataset.windowbarTitle || document.title || 'capslock_p2';
    const iconName = root.dataset.windowbarIcon || 'window';
    const chinese = (document.documentElement.lang || '').toLowerCase().startsWith('zh');
    const labels = chinese
      ? { pin: '固定', independent: '独立窗口', close: '关闭', drag: '拖动移动窗口' }
      : { pin: 'Pin', independent: 'Independent window', close: 'Close', drag: 'Drag to move' };

    const drag = document.createElement('div');
    drag.id = 'windowDrag';
    drag.className = 'window-drag';
    drag.dataset.windowbarDrag = '';
    drag.title = labels.drag;
    drag.append(icon(iconName));
    const titleNode = document.createElement('span');
    titleNode.id = 'windowTitle';
    titleNode.className = 'window-title';
    titleNode.textContent = title;
    drag.append(titleNode);

    const actions = document.createElement('div');
    actions.className = 'window-actions';
    actions.append(
      actionButton('pin', labels.pin, icon('pin'), true),
      actionButton('independent', labels.independent, icon('external-link')),
      actionButton('close', labels.close, icon('x'))
    );
    root.replaceChildren(drag, actions);
    debug('build:done');
  }

  function actionButton(action, label, iconNode, screenReaderLabel = false) {
    const button = document.createElement('button');
    button.type = 'button';
    button.id = action === 'pin' ? 'pinPanel'
      : (action === 'independent' ? 'independentPanel' : 'closePanel');
    button.className = `window-action${action === 'close' ? ' close' : ''}`;
    button.dataset.windowbarAction = action;
    button.setAttribute('aria-label', label);
    button.title = label;
    button.setAttribute('aria-pressed', 'false');
    button.append(iconNode);
    if (screenReaderLabel) {
      const text = document.createElement('span');
      text.className = 'sr-only';
      text.dataset.label = '';
      text.textContent = label;
      button.append(text);
    }
    return button;
  }

  function init(root = document.querySelector('[data-windowbar]')) {
    debug('init:enter', root ? 'root' : 'no-root');
    if (!root || root.dataset.windowbarReady === 'true') return root;
    if (!root.querySelector('[data-windowbar-drag]'))
      build(root);
    root.dataset.windowbarReady = 'true';

    const drag = root.querySelector('[data-windowbar-drag]');
    if (drag) {
      drag.addEventListener('mousedown', event => {
        if (event.button !== 0) return;
        event.preventDefault();
        post('windowDragStart');
      });
    }

    root.querySelectorAll('[data-windowbar-action]').forEach(button => {
      const action = button.dataset.windowbarAction;
      if (action === 'close') button.addEventListener('click', () => post('hide'));
      if (action === 'independent') button.addEventListener('click', () => post('windowToggleNative'));
      if (action === 'pin') button.addEventListener('click', () => post('togglePinned'));
    });
    debug('init:bound');
    return root;
  }

  function getRoot(root) {
    return root || document.querySelector('[data-windowbar]');
  }

  function setPinned(value, root) {
    root = getRoot(root);
    if (!root) return;
    const button = root.querySelector('[data-windowbar-action="pin"]');
    if (!button) return;
    const pinned = !!value;
    button.classList.toggle('pinned', pinned);
    button.setAttribute('aria-pressed', pinned ? 'true' : 'false');
  }

  function setNativeWindowMode(value, root) {
    root = getRoot(root);
    if (!root) return;
    const native = !!value;
    root.classList.toggle('native-window', native);
    const button = root.querySelector('[data-windowbar-action="independent"]');
    if (button) button.setAttribute('aria-pressed', native ? 'true' : 'false');
  }

  window.WindowBar = { init, post, debug, setPinned, setNativeWindowMode };
  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', () => init(), { once: true });
  else
    init();
})();
