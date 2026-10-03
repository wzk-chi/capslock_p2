/* Shared modal dialog factory for WebView2 pages.
   Pages provide only their editor content and action callbacks; the shell,
   dismissal behavior, focus surface and busy/error states stay consistent. */
(function () {
  'use strict';

  let sequence = 0;

  function create(options = {}) {
    const dialog = document.createElement('dialog');
    dialog.className = 'app-dialog' + (options.className ? ' ' + options.className : '');

    const body = document.createElement('div');
    body.className = 'app-dialog-body';
    const head = document.createElement('div');
    head.className = 'app-dialog-head';
    const heading = document.createElement('div');
    const kicker = document.createElement('div');
    kicker.className = 'app-dialog-kicker';
    kicker.textContent = options.kicker || '';
    kicker.hidden = !kicker.textContent;
    const title = document.createElement('h3');
    title.textContent = options.title || '';
    title.id = 'app-dialog-title-' + (++sequence);
    heading.append(kicker, title);
    const closeButton = document.createElement('button');
    closeButton.type = 'button';
    closeButton.className = 'icon-btn';
    closeButton.title = options.closeLabel || '关闭';
    closeButton.setAttribute('aria-label', options.closeLabel || '关闭');
    if (typeof window.createIcon === 'function')
      closeButton.appendChild(window.createIcon('x'));
    else
      closeButton.textContent = '×';
    head.append(heading, closeButton);

    const editor = document.createElement('div');
    editor.className = 'app-dialog-editor';
    const error = document.createElement('div');
    error.className = 'app-dialog-error';
    error.hidden = true;
    error.setAttribute('role', 'alert');
    const actions = document.createElement('div');
    actions.className = 'app-dialog-actions';
    const cancelButton = document.createElement('button');
    cancelButton.type = 'button';
    cancelButton.className = 'btn ghost';
    cancelButton.textContent = options.cancelText || '取消';
    const saveButton = document.createElement('button');
    saveButton.type = 'button';
    saveButton.className = 'btn';
    saveButton.textContent = options.saveText || '保存';
    actions.append(cancelButton, saveButton);
    body.append(head, editor, error, actions);
    dialog.appendChild(body);
    document.body.appendChild(dialog);
    dialog.setAttribute('aria-labelledby', title.id);

    let closeNotified = false;
    const notifyClosed = () => {
      if (closeNotified) return;
      closeNotified = true;
      if (typeof options.onClose === 'function') options.onClose(api);
    };
    const close = () => {
      if (dialog.open) dialog.close();
      else notifyClosed();
    };
    const api = {
      dialog,
      editor,
      error,
      title,
      closeButton,
      cancelButton,
      saveButton,
      open() {
        closeNotified = false;
        if (!dialog.open) dialog.showModal();
      },
      close,
      setTitle(value) {
        title.textContent = value || '';
      },
      setError(message = '') {
        error.textContent = message || '';
        error.hidden = !message;
      },
      setBusy(busy, label = '') {
        saveButton.disabled = !!busy;
        saveButton.textContent = busy ? (label || '处理中…') : (options.saveText || '保存');
      }
    };

    dialog.addEventListener('close', notifyClosed);
    dialog.addEventListener('cancel', event => {
      event.preventDefault();
      close();
    });
    dialog.addEventListener('click', event => {
      if (event.target === dialog) close();
    });
    closeButton.addEventListener('click', close);
    cancelButton.addEventListener('click', close);
    if (typeof window.refreshIcons === 'function') window.refreshIcons();
    return api;
  }

  window.AppDialog = Object.freeze({ create });
})();
