/* On-demand clipboard content viewer, using the shared dialog and read-only buffers. */
(function () {
  'use strict';

  let active = null;
  let sequence = 0;
  const post = message => {
    if (window.chrome?.webview) chrome.webview.postMessage(JSON.stringify(message));
  };
  const element = (tag, className = '', text = '') => {
    const node = document.createElement(tag);
    node.className = className;
    node.textContent = text;
    return node;
  };
  const matches = data => active && active.dialog?.isOpen()
    && data.sessionId === active.sessionId && Number(data.requestId) === active.requestId
    && String(data.id) === active.id;

  function open(row, sessionId, onClose) {
    const viewer = {
      id: String(row.id), kind: row.type === 'rich' ? 'text' : row.type,
      sessionId, requestId: ++sequence, dialog: null, api: null,
      root: null, cleanup: null, files: null, selection: null, opening: false
    };
    const isFile = viewer.kind === 'file';
    viewer.dialog = AppDialog.open({
      title: isFile ? '查看文件' : viewer.kind === 'image' ? '查看图片' : '查看文本',
      className: 'history-view-dialog',
      initialFocus: false,
      actions: [
        { id: isFile ? 'open' : 'copy', text: isFile ? '打开' : '复制', disabled: true },
        { id: 'close', text: '关闭', role: 'cancel', kind: 'ghost' }
      ],
      render(root, api) {
        viewer.root = root;
        viewer.api = api;
        root.append(element('p', 'history-view-loading', '正在读取内容…'));
      },
      onAction(action, api) {
        if (action === 'copy') {
          post({ type: 'copy', sessionId, id: viewer.id });
        } else if (action === 'open' && viewer.selection) {
          if (viewer.opening) return api.keepOpen();
          viewer.opening = true;
          api.setError('');
          api.setBusy(true, '正在打开…', 'open');
          post({ type: 'fileOpen', sessionId, id: viewer.id,
            requestId: viewer.requestId, fileIndex: viewer.selection.selectedIndex + 1 });
        }
        return api.keepOpen();
      },
      onClose(result) {
        if (active === viewer) active = null;
        post({ type: 'cancelView', sessionId, requestId: viewer.requestId });
        if (viewer.cleanup) viewer.cleanup();
        viewer.root.replaceChildren();
        if (result?.action === 'close' || result?.action === 'cancel') onClose?.();
      }
    });
    active = viewer;
    post({ type: 'view', sessionId, id: viewer.id, requestId: viewer.requestId });
  }

  function renderText(viewer, text) {
    const content = element('pre', 'history-view-text', text);
    content.tabIndex = 0;
    content.setAttribute('aria-label', '完整文本');
    viewer.root.replaceChildren(content);
    viewer.api.setActionEnabled('copy', true);
    content.focus();
  }

  function renderFiles(viewer, files) {
    if (!Array.isArray(files) || !files.length || files.some(path => typeof path !== 'string' || !path))
      throw new Error('Invalid file list');
    if (files.length === 1) {
      viewer.opening = true;
      viewer.root.replaceChildren(element('p', 'history-view-loading', '正在打开文件…'));
      post({ type: 'fileOpen', sessionId: viewer.sessionId, id: viewer.id,
        requestId: viewer.requestId, fileIndex: 1 });
      return;
    }
    const description = element('p', 'history-view-hint', `这条记录包含 ${files.length} 项，请选择要打开的文件。`);
    const selection = element('select', 'history-view-files');
    selection.size = Math.min(8, files.length);
    selection.setAttribute('aria-label', '选择文件');
    files.forEach((path, index) => {
      const option = element('option', '', path.split(/[\\/]/).pop() || path);
      option.value = String(index + 1);
      selection.append(option);
    });
    selection.selectedIndex = 0;
    const pathLabel = element('p', 'history-view-file-path', files[0]);
    selection.addEventListener('change', () => { pathLabel.textContent = files[selection.selectedIndex] || ''; });
    selection.addEventListener('dblclick', () => viewer.api.submit('open'));
    selection.addEventListener('keydown', event => {
      if (event.key === 'Enter') { event.preventDefault(); viewer.api.submit('open'); }
    });
    viewer.selection = selection;
    viewer.files = files;
    viewer.root.replaceChildren(description, selection, pathLabel);
    viewer.api.setActionEnabled('open', true);
    selection.focus();
  }

  function renderImage(viewer, bytes) {
    if (viewer.cleanup) viewer.cleanup();
    const url = URL.createObjectURL(new Blob([bytes], { type: 'image/png' }));
    const events = new AbortController();
    const toolbar = element('div', 'history-view-toolbar');
    const zoomLabel = element('span', 'history-view-zoom', '—');
    const stage = element('div', 'history-view-stage');
    stage.tabIndex = 0;
    stage.setAttribute('aria-label', '图片；滚轮或加减键缩放，拖动或方向键移动');
    const image = element('img', 'history-view-image');
    let observer = null;
    viewer.cleanup = () => {
      events.abort();
      observer?.disconnect();
      image.removeAttribute('src');
      URL.revokeObjectURL(url);
    };
    image.alt = '剪贴板图片';
    image.draggable = false;
    image.hidden = true;
    const loading = element('span', 'history-view-loading', '正在显示图片…');
    stage.append(image, loading);
    let scale = 1, x = 0, y = 0, loaded = false, fitting = true, drag = null;
    let width = stage.clientWidth, height = stage.clientHeight;

    const paint = () => {
      image.style.transform = `translate(${x}px, ${y}px) scale(${scale})`;
      zoomLabel.textContent = `${Math.round(scale * 1000) / 10}%`;
    };
    const fitScale = () => Math.min(1, stage.clientWidth / image.naturalWidth, stage.clientHeight / image.naturalHeight);
    const fit = () => {
      if (!loaded) return;
      fitting = true;
      scale = fitScale();
      x = (stage.clientWidth - image.naturalWidth * scale) / 2;
      y = (stage.clientHeight - image.naturalHeight * scale) / 2;
      paint();
    };
    const zoom = (value, centerX = stage.clientWidth / 2, centerY = stage.clientHeight / 2) => {
      if (!loaded) return;
      const next = Math.max(Math.min(.01, fitScale()), Math.min(8, value));
      const ratio = next / scale;
      x = centerX - (centerX - x) * ratio;
      y = centerY - (centerY - y) * ratio;
      scale = next;
      fitting = false;
      paint();
    };
    const tool = (text, label, action) => {
      const button = element('button', 'history-view-tool', text);
      button.type = 'button';
      button.title = label;
      button.setAttribute('aria-label', label);
      button.addEventListener('click', action, { signal: events.signal });
      toolbar.append(button);
    };
    tool('−', '缩小图片', () => zoom(scale / 1.25));
    toolbar.append(zoomLabel);
    tool('+', '放大图片', () => zoom(scale * 1.25));
    tool('适应窗口', '适应窗口', fit);
    tool('100%', '原始大小', () => zoom(1));
    toolbar.append(element('span', 'history-view-hint', '滚轮缩放 · 拖动移动'));
    viewer.root.replaceChildren(toolbar, stage);

    image.addEventListener('load', () => {
      loaded = true;
      image.hidden = false;
      loading.remove();
      fit();
      viewer.api.setActionEnabled('copy', true);
    }, { signal: events.signal });
    image.addEventListener('error', () => {
      loading.textContent = '图片无法显示';
      viewer.api.setError('无法显示这张图片，请尝试复制后在图片应用中打开。');
    }, { signal: events.signal });
    stage.addEventListener('wheel', event => {
      event.preventDefault();
      const rect = stage.getBoundingClientRect();
      const delta = event.deltaY * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? stage.clientHeight : 1);
      zoom(scale * Math.exp(Math.max(-.3, Math.min(.3, -delta * .002))),
        event.clientX - rect.left, event.clientY - rect.top);
    }, { passive: false, signal: events.signal });
    stage.addEventListener('pointerdown', event => {
      if (!loaded || event.button !== 0) return;
      event.preventDefault();
      stage.focus();
      stage.setPointerCapture(event.pointerId);
      drag = { id: event.pointerId, x: event.clientX, y: event.clientY };
      stage.classList.add('dragging');
    }, { signal: events.signal });
    stage.addEventListener('pointermove', event => {
      if (!drag || drag.id !== event.pointerId) return;
      x += event.clientX - drag.x;
      y += event.clientY - drag.y;
      drag.x = event.clientX;
      drag.y = event.clientY;
      fitting = false;
      paint();
    }, { signal: events.signal });
    stage.addEventListener('lostpointercapture', () => {
      drag = null;
      stage.classList.remove('dragging');
    }, { signal: events.signal });
    stage.addEventListener('keydown', event => {
      if (event.key === '+' || event.key === '=') zoom(scale * 1.25);
      else if (event.key === '-') zoom(scale / 1.25);
      else if (event.key === '0') fit();
      else if (event.key === '1') zoom(1);
      else if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key) && loaded) {
        x += event.key === 'ArrowLeft' ? 32 : event.key === 'ArrowRight' ? -32 : 0;
        y += event.key === 'ArrowUp' ? 32 : event.key === 'ArrowDown' ? -32 : 0;
        fitting = false;
        paint();
      } else return;
      event.preventDefault();
    }, { signal: events.signal });
    observer = new ResizeObserver(() => {
      const nextWidth = stage.clientWidth, nextHeight = stage.clientHeight;
      if (loaded) {
        if (fitting) fit();
        else { x += (nextWidth - width) / 2; y += (nextHeight - height) / 2; paint(); }
      }
      width = nextWidth;
      height = nextHeight;
    });
    observer.observe(stage);
    image.src = url;
    stage.focus();
  }

  function handleHostMessage(data) {
    if (data.type !== 'viewError' && data.type !== 'viewOpened') return false;
    if (!matches(data)) return true;
    if (data.type === 'viewOpened') active.dialog.close({ action: 'opened' });
    else {
      active.opening = false;
      active.api.setBusy(false, '', 'open');
      if (active.kind === 'file') active.api.setActionEnabled('open', !!active.files);
      active.api.setError(data.message || '无法查看这条历史，请稍后重试。');
      if (!active.files) active.root.replaceChildren();
    }
    return true;
  }

  if (window.chrome?.webview) chrome.webview.addEventListener('sharedbufferreceived', event => {
    const buffer = event.getBuffer();
    try {
      const data = event.additionalData;
      if (data?.type !== 'historyViewContent' || !matches(data) || data.kind !== active.kind) return;
      const viewer = active;
      viewer.api.setError('');
      if (data.kind === 'image') renderImage(viewer, buffer);
      else {
        const text = new TextDecoder('utf-8', { ignoreBOM: true }).decode(buffer);
        if (data.kind === 'file') renderFiles(viewer, JSON.parse(text));
        else renderText(viewer, text);
      }
    } catch (error) {
      console.error('Clipboard content view failed', error);
      if (active?.dialog?.isOpen()) {
        if (active.cleanup) { active.cleanup(); active.cleanup = null; }
        active.root.replaceChildren();
        active.api.setActionEnabled(active.kind === 'file' ? 'open' : 'copy', false);
        active.api.setError('无法显示这条历史，请关闭后重试。');
      }
    } finally {
      chrome.webview.releaseBuffer(buffer);
    }
  });

  window.ClipboardView = Object.freeze({ open, handleHostMessage });
})();
