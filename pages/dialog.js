/* Shared modal service for WebView2 pages.
   Simple interactions use AppDialog.alert/confirm/prompt. Complex dialogs use
   AppDialog.open({ render, actions, onAction }); the shell owns lifecycle,
   focus, dismissal, action buttons, busy state and the result Promise. */
(function () {
  'use strict';

  let sequence = 0;
  let shell = null;
  let active = null;
  let pendingCloseEvents = 0;

  const element = (tag, className = '', text = '') => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text) node.textContent = text;
    return node;
  };

  function ensureShell() {
    if (shell) return shell;
    const dialog = element('dialog', 'app-dialog');
    const body = element('div', 'app-dialog-body');
    const head = element('div', 'app-dialog-head');
    const heading = element('div');
    const kicker = element('div', 'app-dialog-kicker');
    const title = element('h3');
    title.id = 'app-dialog-title-' + (++sequence);
    const closeButton = element('button', 'icon-btn');
    closeButton.type = 'button';
    head.append(heading, closeButton);
    heading.append(kicker, title);
    const content = element('div', 'app-dialog-editor');
    const error = element('div', 'app-dialog-error');
    error.hidden = true;
    error.setAttribute('role', 'alert');
    const actions = element('div', 'app-dialog-actions');
    body.append(head, content, error, actions);
    dialog.appendChild(body);
    document.body.appendChild(dialog);
    dialog.setAttribute('aria-labelledby', title.id);
    shell = { dialog, content, error, actions, title, kicker, closeButton, buttons: new Map() };
    closeButton.title = '关闭';
    closeButton.setAttribute('aria-label', '关闭');
    if (typeof window.createIcon === 'function') closeButton.appendChild(window.createIcon('x'));
    else closeButton.textContent = '×';

    const dismiss = () => {
      if (active) active.close({ action: 'cancel' });
    };
    closeButton.addEventListener('click', dismiss);
    dialog.addEventListener('cancel', event => {
      event.preventDefault();
      dismiss();
    });
    dialog.addEventListener('click', event => {
      if (event.target === dialog) dismiss();
    });
    dialog.addEventListener('close', () => {
      if (pendingCloseEvents) {
        pendingCloseEvents--;
        return;
      }
      if (active && !active.settled) active.close({ action: 'dismiss' });
    });
    if (typeof window.refreshIcons === 'function') window.refreshIcons();
    return shell;
  }

  function normalizeAction(raw, index) {
    const action = typeof raw === 'string' ? { id: raw, text: raw } : (raw || {});
    const id = String(action.id || 'action' + index);
    const role = action.role || (id === 'cancel' ? 'cancel' : 'action');
    return {
      id,
      role,
      text: action.text || (role === 'cancel' ? '取消' : '确定'),
      kind: action.kind || (role === 'cancel' ? 'ghost' : 'primary'),
      disabled: !!action.disabled,
      hidden: !!action.hidden
    };
  }

  function actionClass(kind) {
    if (kind === 'ghost' || kind === 'secondary') return 'btn ghost';
    if (kind === 'danger') return 'btn danger';
    return 'btn';
  }

  function open(options = {}) {
    const currentShell = ensureShell();
    if (active) active.close({ action: 'replaced' });
    currentShell.dialog.className = 'app-dialog' + (options.className ? ' ' + options.className : '')
      + (options.size === 'wide' ? ' app-dialog--wide' : '');
    currentShell.title.textContent = options.title || '';
    currentShell.kicker.textContent = options.kicker || '';
    currentShell.kicker.hidden = !currentShell.kicker.textContent;
    currentShell.closeButton.title = options.closeLabel || '关闭';
    currentShell.closeButton.setAttribute('aria-label', options.closeLabel || '关闭');
    currentShell.content.replaceChildren();
    currentShell.error.textContent = '';
    currentShell.error.hidden = true;
    currentShell.actions.replaceChildren();
    currentShell.actions.hidden = false;
    currentShell.buttons.clear();

    let resolveResult;
    const result = new Promise(resolve => { resolveResult = resolve; });
    let settled = false;
    let handlingAction = false;
    const descriptors = (options.actions || []).map(normalizeAction);
    const primaryAction = descriptors.find(item => item.role !== 'cancel' && !item.hidden);
    let controller;

    const finish = value => {
      if (settled) return;
      settled = true;
      controller.settled = true;
      if (active === controller) active = null;
      if (currentShell.dialog.open) {
        pendingCloseEvents++;
        currentShell.dialog.close();
      }
      resolveResult(value);
      if (typeof options.onClose === 'function') options.onClose(value, api);
    };
    const keepOpen = () => ({ keepOpen: true });
    const setActionEnabled = (id, enabled) => {
      const descriptor = descriptors.find(item => item.id === id);
      if (descriptor) descriptor.disabled = !enabled;
      const button = currentShell.buttons.get(id);
      if (button) button.disabled = !enabled;
    };
    const setActionText = (id, text) => {
      const button = currentShell.buttons.get(id);
      if (button) {
        button.textContent = text || '';
        button.dataset.defaultText = text || '';
      }
    };
    const focusAction = id => {
      const button = currentShell.buttons.get(id);
      if (button && !button.disabled && !button.hidden) button.focus();
    };
    const setBusy = (busy, label = '', id = primaryAction && primaryAction.id) => {
      if (!id) return;
      const button = currentShell.buttons.get(id);
      if (!button) return;
      if (!button.dataset.defaultText) button.dataset.defaultText = button.textContent;
      button.disabled = !!busy;
      button.textContent = busy ? (label || '处理中…') : button.dataset.defaultText;
    };
    const submit = id => {
      const descriptor = descriptors.find(item => item.id === id);
      if (descriptor) handleAction(descriptor);
    };
    const api = {
      content: currentShell.content,
      result,
      keepOpen,
      close: finish,
      setTitle(value) { currentShell.title.textContent = value || ''; },
      setDescriptionId(id = '') {
        if (id) currentShell.dialog.setAttribute('aria-describedby', id);
        else currentShell.dialog.removeAttribute('aria-describedby');
      },
      setError(message = '') {
        currentShell.error.textContent = message || '';
        currentShell.error.hidden = !message;
      },
      setBusy,
      setActionEnabled,
      setActionText,
      focusAction,
      submit,
      isOpen() { return currentShell.dialog.open && !settled; }
    };
    controller = {
      result,
      close: finish,
      setTitle: api.setTitle,
      setDescriptionId: api.setDescriptionId,
      setError: api.setError,
      setBusy,
      setActionEnabled,
      setActionText,
      focusAction,
      isOpen: api.isOpen,
      settled: false
    };
    active = controller;

    function handleAction(descriptor) {
      if (settled || handlingAction || descriptor.disabled) return;
      if (descriptor.role === 'cancel') {
        finish({ action: descriptor.id });
        return;
      }
      handlingAction = true;
      Promise.resolve(typeof options.onAction === 'function'
        ? options.onAction(descriptor.id, api)
        : undefined).then(value => {
          handlingAction = false;
          if (settled || value === false || (value && value.keepOpen)) return;
          finish({ action: descriptor.id, value });
        }).catch(error => {
          handlingAction = false;
          api.setError(error && error.message ? error.message : '操作失败。');
        });
    }

    descriptors.forEach(descriptor => {
      const button = element('button', actionClass(descriptor.kind), descriptor.text);
      button.type = 'button';
      button.disabled = descriptor.disabled;
      button.hidden = descriptor.hidden;
      button.dataset.defaultText = descriptor.text;
      button.addEventListener('click', () => handleAction(descriptor));
      currentShell.actions.appendChild(button);
      currentShell.buttons.set(descriptor.id, button);
    });
    currentShell.actions.hidden = !descriptors.some(item => !item.hidden);

    if (options.message) {
      const message = element('p', 'app-dialog-message', options.message);
      message.id = 'app-dialog-message-' + (++sequence);
      currentShell.content.appendChild(message);
      currentShell.dialog.setAttribute('aria-describedby', message.id);
    } else if (options.descriptionId) {
      currentShell.dialog.setAttribute('aria-describedby', options.descriptionId);
    } else {
      currentShell.dialog.removeAttribute('aria-describedby');
    }
    if (typeof options.render === 'function') {
      const rendered = options.render(currentShell.content, api);
      if (rendered instanceof Node) currentShell.content.appendChild(rendered);
    }

    if (options.initialFocus === 'content') {
      requestAnimationFrame(() => {
        if (!currentShell.dialog.open) return;
        const target = currentShell.content.querySelector('[autofocus], input, select, textarea, button');
        if (target && !target.disabled) target.focus();
      });
    } else {
      const target = currentShell.buttons.get(options.initialFocus)
        || currentShell.buttons.get((descriptors.find(item => item.role === 'cancel') || {}).id)
        || (primaryAction && currentShell.buttons.get(primaryAction.id))
        || currentShell.closeButton;
      requestAnimationFrame(() => {
        if (currentShell.dialog.open && !target.hidden && !target.disabled) target.focus();
      });
    }
    currentShell.dialog.showModal();
    if (typeof window.refreshIcons === 'function') window.refreshIcons();
    return controller;
  }

  function alertDialog(options = {}) {
    const controller = open({
      ...options,
      actions: [{ id: 'ok', text: options.okText || '确定' }],
      initialFocus: 'ok'
    });
    return controller.result.then(() => undefined);
  }

  function confirm(options = {}) {
    const controller = open({
      ...options,
      actions: [
        { id: 'cancel', text: options.cancelText || '取消', role: 'cancel', kind: 'ghost' },
        { id: 'confirm', text: options.confirmText || '确定', kind: options.tone === 'danger' ? 'danger' : 'primary' }
      ],
      initialFocus: options.initialFocus || 'cancel'
    });
    return controller.result.then(result => result && result.action === 'confirm');
  }

  function prompt(options = {}) {
    let input = null;
    const controller = open({
      ...options,
      initialFocus: 'content',
      actions: [
        { id: 'cancel', text: options.cancelText || '取消', role: 'cancel', kind: 'ghost' },
        { id: 'confirm', text: options.confirmText || '确定', kind: 'primary' }
      ],
      render(root, api) {
        const field = element('label', 'app-dialog-field');
        const label = element('span', '', options.label || '内容');
        input = element('input', 'app-dialog-input');
        input.type = options.type || 'text';
        input.value = String(options.value ?? '');
        input.placeholder = options.placeholder || '';
        input.autocomplete = 'off';
        input.addEventListener('keydown', event => {
          if (event.key === 'Enter' && !event.isComposing) {
            event.preventDefault();
            api.submit('confirm');
          }
        });
        field.append(label, input);
        root.appendChild(field);
      },
      onAction(id, api) {
        if (id !== 'confirm') return;
        const value = input ? input.value : '';
        if (typeof options.validate === 'function') {
          const error = options.validate(value);
          if (error) {
            api.setError(error);
            return api.keepOpen();
          }
        }
        return value;
      }
    });
    return controller.result.then(result => result && result.action === 'confirm' ? result.value : null);
  }

  function dismiss() {
    if (active) active.close({ action: 'dismiss' });
  }

  window.AppDialog = Object.freeze({ open, alert: alertDialog, confirm, prompt, dismiss });
})();
