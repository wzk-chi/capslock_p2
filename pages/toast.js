(() => {
  const types = {
    success: { label: '成功', icon: '✓', role: 'status', live: 'polite' },
    info: { label: '提示', icon: 'i', role: 'status', live: 'polite' },
    warning: { label: '注意', icon: '!', role: 'status', live: 'polite' },
    error: { label: '错误', icon: '×', role: 'alert', live: 'assertive' }
  };
  const defaultDuration = 4200;
  let toast = null;
  let hideTimer = 0;
  let hideAt = 0;
  let remaining = 0;
  let pointerInside = false;
  let focusInside = false;

  function isPaused() {
    return pointerInside || focusInside;
  }

  function stopTimer() {
    if (hideTimer) window.clearTimeout(hideTimer);
    hideTimer = 0;
  }

  function hide() {
    stopTimer();
    remaining = 0;
    if (toast) toast.classList.remove('visible');
  }

  function scheduleHide() {
    stopTimer();
    if (!toast || !toast.classList.contains('visible') || isPaused()) return;
    if (remaining <= 0) {
      hide();
      return;
    }
    hideAt = Date.now() + remaining;
    hideTimer = window.setTimeout(hide, remaining);
  }

  function pause() {
    if (!toast || !toast.classList.contains('visible') || !hideTimer) return;
    remaining = Math.max(0, hideAt - Date.now());
    stopTimer();
  }

  function resume() {
    if (!isPaused() && toast && toast.classList.contains('visible')) scheduleHide();
  }

  function createToast() {
    if (toast) return toast;
    toast = document.createElement('div');
    toast.className = 'ui-toast ui-toast--info';
    toast.setAttribute('aria-atomic', 'true');

    const icon = document.createElement('span');
    icon.className = 'ui-toast__icon';
    icon.setAttribute('aria-hidden', 'true');

    const body = document.createElement('span');
    body.className = 'ui-toast__body';
    const label = document.createElement('span');
    label.className = 'ui-toast__label';
    const message = document.createElement('span');
    message.className = 'ui-toast__message';
    body.append(label, message);

    const close = document.createElement('button');
    close.className = 'ui-toast__close';
    close.type = 'button';
    close.setAttribute('aria-label', '关闭提示');
    close.textContent = '×';
    close.addEventListener('click', hide);

    toast.append(icon, body, close);
    toast.addEventListener('pointerenter', () => {
      pointerInside = true;
      pause();
    });
    toast.addEventListener('pointerleave', () => {
      pointerInside = false;
      resume();
    });
    toast.addEventListener('focusin', () => {
      focusInside = true;
      pause();
    });
    toast.addEventListener('focusout', event => {
      if (!toast.contains(event.relatedTarget)) {
        focusInside = false;
        resume();
      }
    });
    document.body.appendChild(toast);
    return toast;
  }

  function show(message, type = 'info', duration = defaultDuration) {
    const text = String(message ?? '').trim();
    if (!text) return;

    const key = Object.hasOwn(types, type) ? type : 'info';
    const settings = types[key];
    const node = createToast();
    node.className = `ui-toast ui-toast--${key}`;
    node.setAttribute('role', settings.role);
    node.setAttribute('aria-live', settings.live);
    node.querySelector('.ui-toast__icon').textContent = settings.icon;
    node.querySelector('.ui-toast__label').textContent = settings.label;
    node.querySelector('.ui-toast__message').textContent = text;
    node.classList.add('visible');

    const requestedDuration = Number(duration);
    remaining = Number.isFinite(requestedDuration) ? Math.max(0, requestedDuration) : defaultDuration;
    scheduleHide();
  }

  window.AppToast = Object.freeze({ show, hide });
})();
