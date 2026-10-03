/* Shared modal dialog factory for WebView2 pages.
   Pages provide only their editor content and action callbacks; the shell,
   dismissal behavior, focus surface and busy/error states stay consistent. */
(function () {
  'use strict';

  let sequence = 0;

  function create(options = {}) {
    const dialog = document.createElement('dialog');
    dialog.className = 'app-dialog' + (options.className ? ' ' + options.className : '');
    if (options.id) dialog.id = options.id;

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
    cancelButton.className = options.cancelClassName || 'btn ghost';
    cancelButton.hidden = options.cancelText === false;
    cancelButton.textContent = cancelButton.hidden ? '' : (options.cancelText || '取消');
    const saveButton = document.createElement('button');
    saveButton.type = 'button';
    saveButton.className = options.saveClassName || 'btn';
    saveButton.hidden = options.saveText === false;
    saveButton.textContent = saveButton.hidden ? '' : (options.saveText || '保存');
    actions.append(cancelButton, saveButton);
    actions.hidden = cancelButton.hidden && saveButton.hidden;
    body.append(head, editor, error, actions);
    dialog.appendChild(body);
    document.body.appendChild(dialog);
    dialog.setAttribute('aria-labelledby', title.id);
    if (options.descriptionId)
      dialog.setAttribute('aria-describedby', options.descriptionId);

    const initialFocus = options.initialFocus === 'save'
      ? saveButton : options.initialFocus === 'close' ? closeButton
        : (cancelButton.hidden ? saveButton : cancelButton);

    let closeNotified = false;
    let closeEventsToIgnore = 0;
    const notifyClosed = () => {
      if (closeNotified) return;
      closeNotified = true;
      if (typeof options.onClose === 'function') options.onClose(api);
    };
    const close = () => {
      if (dialog.open) {
        closeEventsToIgnore++;
        dialog.close();
      }
      notifyClosed();
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
        requestAnimationFrame(() => {
          if (dialog.open && !initialFocus.hidden && !initialFocus.disabled)
            initialFocus.focus();
        });
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
        saveButton.textContent = busy ? (label || '处理中…')
          : (options.saveText === false ? '' : (options.saveText || '保存'));
      }
    };

    dialog.addEventListener('close', () => {
      if (closeEventsToIgnore > 0) {
        closeEventsToIgnore--;
        return;
      }
      notifyClosed();
    });
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
