
WindowBar.init();
const input = document.getElementById('input');
const messages = document.getElementById('messages');
const status = document.getElementById('status');
const sendBtn = document.getElementById('send');
const pinBtn = document.getElementById('pinPanel');
const newChatBtn = document.getElementById('newChat');
const settingsBtn = document.getElementById('openSettings');
const appTitle = document.getElementById('windowTitle');
const windowDrag = document.getElementById('windowDrag');
const independentBtn = document.getElementById('independentPanel');
const closeBtn = document.getElementById('closePanel');
const currentTitle = document.getElementById('currentTitle');
const sidebar = document.getElementById('sidebar');
const toggleSidebarBtn = document.getElementById('toggleSidebar');
const multiSelectBtn = document.getElementById('multiSelect');
const historyHeading = document.getElementById('historyHeading');
const historyList = document.getElementById('historyList');
const selectionBar = document.getElementById('selectionBar');
const selectionCount = document.getElementById('selectionCount');
const selectAllBtn = document.getElementById('selectAllSessions');
const deleteSelectedBtn = document.getElementById('deleteSelectedSessions');
const exitMultiSelectBtn = document.getElementById('exitMultiSelect');
const sessionContextMenu = document.getElementById('sessionContextMenu');
const appLayout = document.getElementById('appLayout');
const loadOlderBtn = document.getElementById('loadOlder');
const saveRetryBar = document.getElementById('saveRetry');

let hostReady = false;
let viewGeneration = 0;
let activeSessionId = 0;
let sessionOffset = 0;
let sessionHasMore = false;
let sessionPageLoading = false;
let olderMessagesLoading = false;
let selectionMode = false;
let selectedSessionIds = new Set();
let contextSession = null;

const STRINGS = {
  en: {
    appTitle: 'capslock_p2 AI',
    newChat: 'New chat',
    settings: 'Settings',
    sidebar: 'AI chat sidebar',
    chatLabel: 'AI Q&A',
    sessionActions: 'Conversation actions',
    send: 'Send',
    history: 'Chat history',
    multiSelect: 'Select chats',
    exitMultiSelect: 'Cancel',
    selectAll: 'Select all',
    selected: 'selected',
    deleteSelected: 'Delete',
    rename: 'Rename',
    pin: 'Pin',
    unpin: 'Unpin',
    pinPanel: 'Pin',
    unpinPanel: 'Unpin',
    delete: 'Delete',
    cancel: 'Cancel',
    confirm: 'OK',
    loadOlder: 'Load older messages',
    emptyHistory: 'No saved conversations yet.',
    interrupted: 'Answer not completed.',
    saveRetry: 'The answer could not be saved. Check the data folder and retry.',
    retrySave: 'Retry save',
    selectSession: 'Select',
    deleteSessionTitle: 'Delete conversation',
    deleteSessionsTitle: 'Delete conversations',
    deleteOneMessage: 'This conversation and its messages will be deleted.',
    deleteManyMessage: 'The selected conversations and their messages will be deleted.',
    expandSidebar: 'Show sidebar',
    collapseSidebar: 'Hide sidebar',
    nameLabel: 'Conversation name',
    nameRequired: 'Enter a conversation name.',
    nameTooLong: 'Names can be up to 80 characters.',
    close: 'Close',
    independent: 'Independent window',
    dragWindow: 'Drag to move',
    copy: 'Copy',
    copied: 'Copied',
    copyFailed: 'Copy failed',
    thinking: 'Thinking…',
    inputPlaceholder: 'Ask anything. Enter to send, Shift+Enter for a new line.'
  },
  zh: {
    appTitle: 'capslock_p2 AI',
    newChat: '新建对话',
    settings: '设置',
    sidebar: 'AI 会话侧栏',
    chatLabel: 'AI 问答',
    sessionActions: '会话操作',
    send: '发送',
    history: '会话历史',
    multiSelect: '进入多选',
    exitMultiSelect: '取消',
    selectAll: '全选',
    selected: '项已选',
    deleteSelected: '删除',
    rename: '重命名',
    pin: '置顶',
    unpin: '取消置顶',
    delete: '删除',
    cancel: '取消',
    confirm: '确定',
    loadOlder: '加载更早消息',
    emptyHistory: '还没有保存的会话。',
    interrupted: '回答未完成。',
    saveRetry: '回答已生成，但保存失败。请检查数据目录后重试。',
    retrySave: '重试保存',
    selectSession: '选择',
    deleteSessionTitle: '删除会话',
    deleteSessionsTitle: '删除会话',
    deleteOneMessage: '这条会话及其对话记录将被删除。',
    deleteManyMessage: '选中的会话及其对话记录将被删除。',
    expandSidebar: '展开侧栏',
    collapseSidebar: '折叠侧栏',
    nameLabel: '会话名称',
    nameRequired: '会话名称不能为空。',
    nameTooLong: '名称不能超过 80 个字符。',
    pinPanel: '固定',
    unpinPanel: '取消固定',
    close: '关闭',
    independent: '独立窗口',
    dragWindow: '拖动移动窗口',
    copy: '复制',
    copied: '已复制',
    copyFailed: '复制失败',
    thinking: '思考中…',
    inputPlaceholder: '输入问题：Enter 发送，Shift+Enter 换行'
  }
};

let lang = 'en';

function t(key) {
  return (STRINGS[lang] && STRINGS[lang][key]) || STRINGS.en[key] || key;
}

function setButtonLabel(button, text) {
  const label = button.querySelector('[data-label]');
  if (label) label.textContent = text;
  else button.textContent = text;
}

function updateSelectionUI() {
  sidebar.classList.toggle('is-selecting', selectionMode);
  selectionBar.hidden = !selectionMode;
  selectionCount.textContent = `${selectedSessionIds.size} ${t('selected')}`;
  multiSelectBtn.setAttribute('aria-pressed', selectionMode ? 'true' : 'false');
  const multiSelectLabel = selectionMode ? t('exitMultiSelect') : t('multiSelect');
  multiSelectBtn.setAttribute('aria-label', multiSelectLabel);
  multiSelectBtn.title = multiSelectLabel;
  historyList.querySelectorAll('.session-check').forEach(check => {
    check.checked = selectedSessionIds.has(Number(check.closest('.session-row').dataset.sessionId));
  });
  deleteSelectedBtn.disabled = selectedSessionIds.size === 0;
}

function applyLanguage() {
  document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
  document.title = t('appTitle');
  appTitle.textContent = t('appTitle');
  windowDrag.title = t('dragWindow');
  independentBtn.title = t('independent');
  independentBtn.setAttribute('aria-label', t('independent'));
  closeBtn.title = t('close');
  closeBtn.setAttribute('aria-label', t('close'));
  setButtonLabel(pinBtn, pinBtn.classList.contains('pinned') ? t('unpinPanel') : t('pinPanel'));
  pinBtn.title = pinBtn.querySelector('[data-label]').textContent;
  pinBtn.setAttribute('aria-label', pinBtn.title);
  setButtonLabel(newChatBtn, t('newChat'));
  newChatBtn.setAttribute('aria-label', t('newChat'));
  newChatBtn.title = t('newChat');
  setButtonLabel(settingsBtn, t('settings'));
  settingsBtn.setAttribute('aria-label', t('settings'));
  settingsBtn.title = t('settings');
  setButtonLabel(sendBtn, t('send'));
  sidebar.setAttribute('aria-label', t('sidebar'));
  document.querySelector('.chat-panel').setAttribute('aria-label', t('chatLabel'));
  sessionContextMenu.setAttribute('aria-label', t('sessionActions'));
  historyHeading.textContent = t('history');
  multiSelectBtn.setAttribute('aria-label', sidebar.classList.contains('is-selecting') ? t('exitMultiSelect') : t('multiSelect'));
  selectAllBtn.textContent = t('selectAll');
  deleteSelectedBtn.textContent = t('deleteSelected');
  exitMultiSelectBtn.textContent = t('exitMultiSelect');
  sessionContextMenu.querySelector('[data-label="rename"]').textContent = t('rename');
  sessionContextMenu.querySelector('[data-label="pin"]').textContent = t('pin');
  sessionContextMenu.querySelector('[data-label="delete"]').textContent = t('delete');
  loadOlderBtn.textContent = t('loadOlder');
  saveRetryBar.querySelectorAll('.retry-save').forEach(button => button.textContent = t('retrySave'));
  toggleSidebarBtn.setAttribute('aria-label', sidebar.classList.contains('is-collapsed') ? t('expandSidebar') : t('collapseSidebar'));
  updateSelectionUI();
  input.placeholder = t('inputPlaceholder');
}

function post(obj) {
  if (window.chrome && chrome.webview)
    chrome.webview.postMessage(JSON.stringify(obj));
}

function postType(type, text) {
  post({ type: type, text: text || '' });
}

function applyPinnedState(value) {
  const pinned = !!value;
  WindowBar.setPinned(pinned);
  setButtonLabel(pinBtn, pinned ? t('unpinPanel') : t('pinPanel'));
  pinBtn.title = pinBtn.querySelector('[data-label]').textContent;
  pinBtn.setAttribute('aria-label', pinBtn.title);
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const helper = document.createElement('textarea');
    helper.value = text;
    helper.setAttribute('readonly', '');
    helper.style.position = 'fixed';
    helper.style.opacity = '0';
    document.body.appendChild(helper);
    helper.select();
    let copied = false;
    try { copied = document.execCommand('copy'); } catch {}
    helper.remove();
    return copied;
  }
}

function createCopyButton(bubble, visible = false) {
  const copyButton = document.createElement('button');
  copyButton.type = 'button';
  copyButton.className = 'copy-message';
  copyButton.hidden = !visible;
  copyButton.disabled = !visible;
  copyButton.title = t('copy');
  copyButton.setAttribute('aria-label', t('copy'));
  copyButton.appendChild(createIcon('copy'));
  copyButton.addEventListener('click', async event => {
    event.preventDefault();
    event.stopPropagation();
    const text = bubble.dataset.raw || '';
    if (!text) return;
    const copied = await copyText(text);
    copyButton.classList.toggle('copied', copied);
    copyButton.title = copied ? t('copied') : t('copyFailed');
    copyButton.setAttribute('aria-label', copyButton.title);
    AppToast.show(copied ? t('copied') : t('copyFailed'), copied ? 'success' : 'error');
    if (copied) {
      setTimeout(() => {
        copyButton.classList.remove('copied');
        copyButton.title = t('copy');
        copyButton.setAttribute('aria-label', t('copy'));
      }, 1200);
    }
  });
  return copyButton;
}

function createAssistantRow() {
  const row = document.createElement('div');
  row.className = 'message-row assistant-row';
  const bubble = document.createElement('div');
  bubble.className = 'msg assistant';
  const copyButton = createCopyButton(bubble);
  row.appendChild(bubble);
  row.appendChild(copyButton);
  return { row, bubble, copyButton };
}

function assistantCopyButton(bubble) {
  return bubble && bubble.parentElement
    ? bubble.parentElement.querySelector('.copy-message') : null;
}

function scrollToBottom() {
  messages.scrollTop = messages.scrollHeight;
}

// Diagnostic telemetry contains lengths only, never message content. It lets
// the host compare the accumulated stream with what the page held at finish.
function postStreamDebug(phase, bubble) {
  const raw = bubble ? (bubble.dataset.raw || '') : '';
  const rendered = bubble ? (bubble.textContent || '') : '';
  const requestId = bubble ? (bubble.dataset.streamId || '') : '';
  post({ type: 'streamDebug', phase: phase,
    requestId: requestId,
    rawLength: String(raw.length), renderedLength: String(rendered.length) });
}

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text || '';
  return div.innerHTML;
}

// Assistant answers arrive as markdown; marked parses it and DOMPurify strips
// anything dangerous from the model output before it becomes HTML.
function renderMarkdown(text) {
  const source = String(text ?? '');
  if (window.marked && window.DOMPurify) {
    try {
      return DOMPurify.sanitize(marked.parse(source, { breaks: true, gfm: true }));
    } catch (error) {
      // fall through to plain text
    }
  }
  return escapeHtml(source).replace(/\r?\n/g, '<br>');
}

/* ---- host -> page ---- */

let loadedTurns = [];

function postView(type, fields = {}) {
  if (!hostReady) return;
  post({ ...fields, type, viewGeneration });
}

function formatSessionTime(rawValue) {
  const raw = String(rawValue || '');
  if (!/^\d{14}$/.test(raw)) return '';
  const date = new Date(Number(raw.slice(0, 4)), Number(raw.slice(4, 6)) - 1,
    Number(raw.slice(6, 8)), Number(raw.slice(8, 10)), Number(raw.slice(10, 12)));
  const now = new Date();
  const clock = date.toLocaleTimeString(lang === 'zh' ? 'zh-CN' : 'en-US', { hour: '2-digit', minute: '2-digit' });
  if (date.toDateString() === now.toDateString()) return lang === 'zh' ? `今天 ${clock}` : `Today ${clock}`;
  const yesterday = new Date(now);
  yesterday.setDate(yesterday.getDate() - 1);
  if (date.toDateString() === yesterday.toDateString()) return lang === 'zh' ? `昨天 ${clock}` : `Yesterday ${clock}`;
  return lang === 'zh'
    ? `${date.getMonth() + 1}月${date.getDate()}日`
    : date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

function makeSessionRow(session) {
  const row = document.createElement('div');
  row.className = 'session-row';
  row.dataset.sessionId = String(session.id);
  row.dataset.pinned = session.pinned ? 'true' : 'false';
  row.dataset.title = String(session.title || '');
  row._session = session;
  row.setAttribute('role', 'listitem');
  const isCurrent = Number(session.id) === activeSessionId;
  if (isCurrent) row.setAttribute('aria-current', 'true');

  const check = document.createElement('input');
  check.className = 'session-check';
  check.type = 'checkbox';
  check.setAttribute('aria-label', `${t('selectSession')} ${session.title || ''}`);
  check.checked = selectedSessionIds.has(Number(session.id));

  const open = document.createElement('button');
  open.className = 'session-open';
  open.type = 'button';
  open.setAttribute('aria-current', isCurrent ? 'true' : 'false');
  const pin = createIcon('pin');
  pin.classList.add('session-pin');
  pin.hidden = !session.pinned;
  const copy = document.createElement('span');
  copy.className = 'session-copy';
  const title = document.createElement('span');
  title.className = 'session-title';
  title.textContent = String(session.title || '');
  const time = document.createElement('span');
  time.className = 'session-time';
  time.textContent = formatSessionTime(session.lastChatAt);
  copy.append(title, time);
  open.append(pin, copy);
  row.append(check, open);
  return row;
}

function renderSessionRows(sessions, append = false) {
  if (!append) historyList.replaceChildren();
  if (!append && !sessions.length) {
    const empty = document.createElement('div');
    empty.className = 'empty-history';
    empty.textContent = t('emptyHistory');
    historyList.appendChild(empty);
  }
  sessions.forEach(session => historyList.appendChild(makeSessionRow(session)));
  refreshIcons();
}

function renderTurns(turns, resetComposer = false) {
  loadedTurns = Array.isArray(turns) ? turns.slice() : [];
  olderMessagesLoading = false;
  messages.replaceChildren();
  saveRetryBar.replaceChildren();
  saveRetryBar.hidden = true;
  if (resetComposer) {
    status.textContent = '';
    input.disabled = false;
    sendBtn.disabled = false;
    loadOlderBtn.disabled = false;
  }
  loadedTurns.forEach(turn => {
    window.appendMessage('user', turn.question || '');
    if (turn.answer)
      window.appendMessage('assistant', turn.answer);
    if (turn.status === 'generating')
      window.setThinking(true);
    else if (turn.status === 'interrupted' || turn.status === 'failed')
      window.setError(t('interrupted'));
    if (turn.savePending)
      window.showSaveRetry({ turnId: turn.id, message: t('saveRetry') });
  });
}

window.onHostState = function (state) {
  if (!state || !Number.isInteger(Number(state.viewGeneration))) return;
  hostReady = true;
  viewGeneration = Number(state.viewGeneration);
  activeSessionId = Number(state.sessionId) || 0;
  markCurrentSessionRows();
  if (!activeSessionId) clearSessionSelection();
  lang = state.uiLanguage === 'zh' ? 'zh' : 'en';
  currentTitle.textContent = String(state.title || t('newChat'));
  applyLanguage();
  applyPinnedState(!!state.pinned);
  renderTurns(state.turns || [], true);
  loadOlderBtn.hidden = !state.hasOlder;
  if (!state.storageAvailable && state.storageMessage)
    window.showStorageError({ message: state.storageMessage });
};

window.setSessionPage = function (page) {
  if (!page || !hostReady || Number(page.viewGeneration) !== viewGeneration) return;
  if (!page.storageAvailable) {
    if (page && page.message) window.showStorageError({ message: page.message });
    sessionPageLoading = false;
    return;
  }
  const offset = Number(page.offset) || 0;
  if (offset === 0) {
    sessionOffset = 0;
    selectedSessionIds.clear();
    updateSelectionUI();
  }
  renderSessionRows(page.sessions || [], offset > 0);
  markCurrentSessionRows();
  sessionOffset = offset + (page.sessions || []).length;
  sessionHasMore = !!page.hasMore;
  sessionPageLoading = false;
};

window.exitMultiSelect = function (result) {
  if (result && Number(result.viewGeneration) !== viewGeneration) return;
  clearSessionSelection();
};

window.prependSessionTurns = function (result) {
  if (!result || Number(result.viewGeneration) !== viewGeneration
      || Number(result.sessionId) !== activeSessionId) return;
  olderMessagesLoading = false;
  const oldHeight = messages.scrollHeight;
  const oldTop = messages.scrollTop;
  const older = Array.isArray(result.turns) ? result.turns : [];
  const seen = new Set(loadedTurns.map(turn => Number(turn.id)));
  loadedTurns = older.filter(turn => !seen.has(Number(turn.id))).concat(loadedTurns);
  renderTurns(loadedTurns);
  messages.scrollTop = oldTop + messages.scrollHeight - oldHeight;
  loadOlderBtn.hidden = !result.hasOlder;
};

window.olderMessagesFailed = function (result) {
  if (result && Number(result.viewGeneration) === viewGeneration)
    olderMessagesLoading = false;
};

window.updateSessionTitle = function (result) {
  if (!result || Number(result.viewGeneration) !== viewGeneration) return;
  const row = historyList.querySelector(`.session-row[data-session-id="${Number(result.sessionId)}"]`);
  if (row) {
    row.dataset.title = String(result.title || '');
    row._session.title = String(result.title || '');
    row.querySelector('.session-title').textContent = String(result.title || '');
    row.querySelector('.session-check').setAttribute('aria-label', `${t('selectSession')} ${result.title || ''}`);
  }
  if (Number(result.sessionId) === activeSessionId)
    currentTitle.textContent = String(result.title || '');
};

window.appendUserQuestion = function (result) {
  if (!result || Number(result.viewGeneration) !== viewGeneration) return;
  activeSessionId = Number(result.sessionId) || activeSessionId;
  markCurrentSessionRows();
  if (result.title) currentTitle.textContent = String(result.title);
  window.appendMessage('user', String(result.text || ''));
  loadedTurns.push({
    id: Number(result.turnId) || 0,
    ordinal: loadedTurns.length ? Number(loadedTurns[loadedTurns.length - 1].ordinal) + 1 : 1,
    question: String(result.text || ''), answer: '', status: 'generating'
  });
  olderMessagesLoading = false;
  input.disabled = true;
  sendBtn.disabled = true;
  loadOlderBtn.disabled = true;
  window.setThinking(true);
};

window.showSaveRetry = function (result) {
  if (!result || !Number(result.turnId)) return;
  const turnId = Number(result.turnId);
  let item = saveRetryBar.querySelector(`.save-retry-item[data-turn-id="${turnId}"]`);
  if (!item) {
    item = document.createElement('div');
    item.className = 'save-retry-item';
    item.dataset.turnId = String(turnId);
    const message = document.createElement('span');
    message.className = 'save-retry-message';
    const button = document.createElement('button');
    button.className = 'retry-save';
    button.type = 'button';
    button.dataset.turnId = String(turnId);
    item.append(message, button);
    saveRetryBar.appendChild(item);
  }
  item.querySelector('.save-retry-message').textContent = String(result.message || t('saveRetry'));
  item.querySelector('.retry-save').textContent = t('retrySave');
  const turn = loadedTurns.find(item => Number(item.id) === Number(result.turnId));
  if (turn) turn.savePending = true;
  saveRetryBar.hidden = false;
};

window.hideSaveRetry = function (result) {
  if (!result) saveRetryBar.replaceChildren();
  else {
    saveRetryBar.querySelector(`.save-retry-item[data-turn-id="${Number(result.turnId)}"]`)?.remove();
    const turn = loadedTurns.find(item => Number(item.id) === Number(result.turnId));
    if (turn) turn.savePending = false;
  }
  saveRetryBar.hidden = !saveRetryBar.childElementCount;
};

window.restoreInput = function (result) {
  if (!result) return;
  input.value = String(result.text || '');
  input.focus();
};

window.showStorageError = function (result) {
  if (result && result.message)
    AppToast.show(String(result.message), 'error');
};

window.showAnswerError = function (result) {
  const turn = result && loadedTurns.find(item => Number(item.id) === Number(result.turnId));
  if (turn) turn.status = 'failed';
  window.setError(result && result.message ? String(result.message) : t('interrupted'));
};

// The AHK side owns the conversation history and echoes every message back,
// so rendering is purely a mirror of that history.
window.appendMessage = function (role, text) {
  const isUser = role === 'user';
  if (isUser) {
    const row = document.createElement('div');
    row.className = 'message-row user-row';
    const bubble = document.createElement('div');
    bubble.className = 'msg user';
    bubble.dataset.raw = text || '';
    bubble.textContent = text || '';
    row.appendChild(createCopyButton(bubble, true));
    row.appendChild(bubble);
    messages.appendChild(row);
    refreshIcons();
  } else {
    const entry = createAssistantRow();
    entry.bubble.dataset.raw = text || '';
    entry.bubble.innerHTML = renderMarkdown(text);
    entry.copyButton.hidden = !String(text || '');
    entry.copyButton.disabled = !String(text || '');
    messages.appendChild(entry.row);
    refreshIcons();
  }
  scrollToBottom();
};

function cancelStreamingRender(bubble) {
  if (bubble._renderFrame) cancelAnimationFrame(bubble._renderFrame);
  bubble._renderFrame = 0;
}

function renderStreamingBubble(bubble, scroll = true) {
  bubble.classList.remove('thinking');
  bubble.innerHTML = renderMarkdown(bubble.dataset.raw);
  const copyButton = assistantCopyButton(bubble);
  if (copyButton) {
    copyButton.hidden = true;
    copyButton.disabled = true;
  }
  if (scroll) scrollToBottom();
}

function scheduleStreamingRender(bubble) {
  if (bubble._renderFrame) return;
  const streamId = bubble.dataset.streamId;
  bubble._renderFrame = requestAnimationFrame(() => {
    bubble._renderFrame = 0;
    if (!bubble.isConnected || bubble.dataset.streamId !== streamId
        || !bubble.classList.contains('streaming')) return;
    renderStreamingBubble(bubble);
  });
}

window.startStreamingMessage = function (payload) {
  const requestId = payload && typeof payload === 'object' ? payload.requestId : payload;
  const turnId = payload && typeof payload === 'object' ? Number(payload.turnId) : 0;
  let bubble = messages.querySelector('.msg.assistant.thinking');
  let copyButton = assistantCopyButton(bubble);
  if (!bubble) {
    const entry = createAssistantRow();
    bubble = entry.bubble;
    copyButton = entry.copyButton;
    messages.appendChild(entry.row);
    refreshIcons();
  }
  cancelStreamingRender(bubble);
  bubble.className = 'msg assistant streaming thinking';
  bubble.dataset.raw = '';
  bubble.dataset.streamId = String(requestId ?? '');
  bubble.dataset.turnId = String(turnId || '');
  bubble.dataset.nextDelta = '1';
  bubble._pendingDeltas = new Map();
  if (copyButton) {
    copyButton.hidden = true;
    copyButton.disabled = true;
    copyButton.classList.remove('copied');
    copyButton.title = t('copy');
    copyButton.setAttribute('aria-label', t('copy'));
  }
  bubble.textContent = t('thinking');
  input.disabled = true;
  sendBtn.disabled = true;
  loadOlderBtn.disabled = true;
  scrollToBottom();
};

window.appendStreaming = function (requestId, sequence, text) {
  const bubble = messages.querySelector('.msg.assistant.streaming');
  if (!bubble) {
    postStreamDebug('append-missing', null);
    return;
  }
  if (bubble.dataset.streamId !== String(requestId ?? '')) {
    postStreamDebug('append-stale', bubble);
    return;
  }
  if (!(bubble._pendingDeltas instanceof Map))
    bubble._pendingDeltas = new Map();
  const sequenceNumber = Number(sequence);
  if (!Number.isInteger(sequenceNumber) || sequenceNumber < 1)
    return;
  const expected = Number(bubble.dataset.nextDelta || '1');
  if (sequenceNumber < expected)
    return;
  if (sequenceNumber > expected) {
    bubble._pendingDeltas.set(sequenceNumber, text || '');
    return;
  }
  const applyDelta = delta => {
    bubble.dataset.raw += delta || '';
    bubble.dataset.nextDelta = String(Number(bubble.dataset.nextDelta) + 1);
  };
  applyDelta(text);
  while (bubble._pendingDeltas.has(Number(bubble.dataset.nextDelta))) {
    const next = Number(bubble.dataset.nextDelta);
    const delta = bubble._pendingDeltas.get(next);
    bubble._pendingDeltas.delete(next);
    applyDelta(delta);
  }
  scheduleStreamingRender(bubble);
};

window.finishStreamingMessage = function (payload, legacyAnswer) {
  const result = payload && typeof payload === 'object'
    ? payload : { requestId: payload, answer: legacyAnswer, status: 'complete' };
  const requestId = result.requestId;
  const answer = result.answer;
  const bubble = messages.querySelector('.msg.assistant.streaming');
  if (!bubble || bubble.dataset.streamId !== String(requestId ?? '')) {
    postStreamDebug('finish-stale', bubble);
    return;
  }
  cancelStreamingRender(bubble);
  bubble.dataset.raw = String(answer ?? '');
  bubble._pendingDeltas = new Map();
  renderStreamingBubble(bubble);
  const copyButton = assistantCopyButton(bubble);
  if (copyButton) {
    copyButton.hidden = !bubble.dataset.raw;
    copyButton.disabled = !bubble.dataset.raw;
  }
  postStreamDebug('finish', bubble);
  if (bubble) bubble.classList.remove('streaming', 'thinking');
  const turn = loadedTurns.find(item => Number(item.id) === Number(result.turnId || bubble?.dataset.turnId));
  if (turn) {
    turn.answer = String(answer ?? '');
    turn.status = result.status || 'complete';
  }
  status.textContent = '';
  input.disabled = false;
  sendBtn.disabled = false;
  loadOlderBtn.disabled = false;
  input.focus();
};

window.removeStreamingMessage = function (payload) {
  const result = payload && typeof payload === 'object' ? payload : { requestId: payload };
  const requestId = result.requestId;
  const bubble = messages.querySelector('.msg.assistant.streaming');
  if (!bubble || bubble.dataset.streamId !== String(requestId ?? '')) {
    postStreamDebug('remove-stale', bubble);
    return;
  }
  cancelStreamingRender(bubble);
  if (bubble.parentElement && bubble.parentElement.classList.contains('message-row'))
    bubble.parentElement.remove();
  else
    bubble.remove();
  const turn = loadedTurns.find(item => Number(item.id) === Number(result.turnId || bubble?.dataset.turnId));
  if (turn && result.status) turn.status = result.status;
  input.disabled = false;
  sendBtn.disabled = false;
  loadOlderBtn.disabled = false;
  input.focus();
};

window.setThinking = function (on) {
  let bubble = messages.querySelector('.msg.assistant.thinking');
  if (on) {
    if (!bubble) {
      const entry = createAssistantRow();
      bubble = entry.bubble;
      messages.appendChild(entry.row);
      refreshIcons();
    }
    bubble.className = 'msg assistant thinking';
    const copyButton = assistantCopyButton(bubble);
    if (copyButton) {
      copyButton.hidden = true;
      copyButton.disabled = true;
    }
    bubble.textContent = t('thinking');
  } else if (bubble) {
    if (bubble.parentElement && bubble.parentElement.classList.contains('message-row'))
      bubble.parentElement.remove();
    else
      bubble.remove();
  }
  scrollToBottom();
};

window.setError = function (text) {
  window.setThinking(false);
  const bubble = document.createElement('div');
  bubble.className = 'msg assistant error';
  bubble.textContent = text || '';
  messages.appendChild(bubble);
  status.textContent = '';
  scrollToBottom();
};

window.newSession = function () {
  messages.textContent = '';
  status.textContent = '';
};

window.trimMessages = function (limit) {
  const bubbles = Array.from(messages.children);
  const keep = Math.max(0, Number(limit) || 0);
  while (bubbles.length > keep)
    bubbles.shift().remove();
};

function setSidebarCollapsed(collapsed) {
  sidebar.classList.toggle('is-collapsed', collapsed);
  toggleSidebarBtn.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
  toggleSidebarBtn.setAttribute('aria-label', collapsed ? t('expandSidebar') : t('collapseSidebar'));
  toggleSidebarBtn.title = collapsed ? t('expandSidebar') : t('collapseSidebar');
  toggleSidebarBtn.replaceChildren(createIcon(collapsed ? 'panel-left-open' : 'panel-left-close'));
  refreshIcons();
}

function markCurrentSessionRows() {
  historyList.querySelectorAll('.session-row').forEach(row => {
    const isCurrent = Number(row.dataset.sessionId) === activeSessionId;
    row.setAttribute('aria-current', isCurrent ? 'true' : 'false');
    row.querySelector('.session-open')?.setAttribute('aria-current', isCurrent ? 'true' : 'false');
  });
}

function clearSessionSelection() {
  selectedSessionIds.clear();
  selectionMode = false;
  updateSelectionUI();
}

function toggleSessionSelection(row) {
  const sessionId = Number(row.dataset.sessionId);
  if (selectedSessionIds.has(sessionId)) selectedSessionIds.delete(sessionId);
  else selectedSessionIds.add(sessionId);
  updateSelectionUI();
}

function closeSessionContextMenu() {
  sessionContextMenu.hidden = true;
  contextSession = null;
}

function showSessionContextMenu(row, clientX, clientY) {
  contextSession = row._session;
  const pinAction = sessionContextMenu.querySelector('[data-menu-action="pin"]');
  pinAction.querySelector('[data-label="pin"]').textContent = contextSession.pinned ? t('unpin') : t('pin');
  sessionContextMenu.hidden = false;
  const layoutRect = appLayout.getBoundingClientRect();
  const menuWidth = sessionContextMenu.offsetWidth;
  const menuHeight = sessionContextMenu.offsetHeight;
  const left = Math.max(8, Math.min(clientX - layoutRect.left, layoutRect.width - menuWidth - 8));
  const top = Math.max(8, Math.min(clientY - layoutRect.top, layoutRect.height - menuHeight - 8));
  sessionContextMenu.style.left = `${left}px`;
  sessionContextMenu.style.top = `${top}px`;
}

async function deleteSessionIds(ids, title = '') {
  if (!ids.length) return;
  const generation = viewGeneration;
  const confirmed = await AppDialog.confirm({
    title: title || (ids.length === 1 ? t('deleteSessionTitle') : t('deleteSessionsTitle')),
    message: ids.length === 1 ? t('deleteOneMessage') : t('deleteManyMessage'),
    confirmText: t('delete'),
    cancelText: t('cancel'),
    tone: 'danger'
  });
  if (confirmed && generation === viewGeneration)
    postView('deleteSessions', { sessionIds: ids });
}

async function runSessionMenuAction(action) {
  if (!contextSession) return;
  const session = contextSession;
  const generation = viewGeneration;
  closeSessionContextMenu();
  if (action === 'rename') {
    const title = await AppDialog.prompt({
      title: t('rename'),
      label: t('nameLabel'),
      value: session.title,
      confirmText: t('confirm'),
      cancelText: t('cancel'),
      validate: value => !String(value).trim() ? t('nameRequired')
        : String(value).trim().length > 80 ? t('nameTooLong') : ''
    });
    if (title !== null && generation === viewGeneration)
      postView('renameSession', { sessionId: Number(session.id), title: String(title).trim() });
  } else if (action === 'pin') {
    if (generation === viewGeneration)
      postView('pinSession', { sessionId: Number(session.id), pinned: !session.pinned });
  } else if (action === 'delete') {
    await deleteSessionIds([Number(session.id)]);
  }
}

async function deleteSelectedSessions() {
  const ids = Array.from(selectedSessionIds);
  const generation = viewGeneration;
  if (!ids.length) return;
  const confirmed = await AppDialog.confirm({
    title: `${t('deleteSessionsTitle')} (${ids.length})`,
    message: t('deleteManyMessage'),
    confirmText: t('delete'),
    cancelText: t('cancel'),
    tone: 'danger'
  });
  if (confirmed && generation === viewGeneration)
    postView('deleteSessions', { sessionIds: ids });
}

/* ---- page -> host ---- */

function send() {
  const text = input.value.trim();
  if (!text || !hostReady || input.disabled)
    return;
  postView('ask', { text, sessionId: activeSessionId });
  input.value = '';
  input.style.height = 'auto';
  input.focus();
}

input.addEventListener('keydown', event => {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    send();
    return;
  }
});

document.addEventListener('keydown', event => {
  if (event.key !== 'Escape') return;
  if (document.querySelector('.app-dialog[open]')) return;
  if (!sessionContextMenu.hidden) {
    event.preventDefault();
    closeSessionContextMenu();
    return;
  }
  const active = document.activeElement;
  if (active && (active.matches('input, textarea, select') || active.isContentEditable)) {
    event.preventDefault();
    active.blur();
    return;
  }
  if (selectionMode) {
    event.preventDefault();
    clearSessionSelection();
    return;
  }
  if (!sidebar.classList.contains('is-collapsed')) {
    event.preventDefault();
    setSidebarCollapsed(true);
    return;
  }
  event.preventDefault();
  postType('hide');
});

input.addEventListener('input', () => {
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, 140) + 'px';
});
sendBtn.addEventListener('click', send);

// Links inside answers open in the default browser (the AHK side handles it),
// never navigate this panel away.
messages.addEventListener('click', event => {
  const link = event.target.closest('a');
  if (!link)
    return;
  event.preventDefault();
  postView('openUrl', { text: link.href });
});

toggleSidebarBtn.addEventListener('click', () => {
  setSidebarCollapsed(!sidebar.classList.contains('is-collapsed'));
});
newChatBtn.addEventListener('click', () => postView('newSession'));
settingsBtn.addEventListener('click', () => postView('openSettings'));
multiSelectBtn.addEventListener('click', () => {
  selectionMode = !selectionMode;
  if (!selectionMode) selectedSessionIds.clear();
  updateSelectionUI();
});
exitMultiSelectBtn.addEventListener('click', clearSessionSelection);
selectAllBtn.addEventListener('click', () => {
  historyList.querySelectorAll('.session-row').forEach(row => selectedSessionIds.add(Number(row.dataset.sessionId)));
  updateSelectionUI();
});
deleteSelectedBtn.addEventListener('click', deleteSelectedSessions);
saveRetryBar.addEventListener('click', event => {
  const button = event.target.closest('.retry-save');
  if (!button) return;
  const turnId = Number(button.dataset.turnId);
  if (turnId) postView('retrySaveAnswer', { turnId });
});
loadOlderBtn.addEventListener('click', () => {
  requestOlderMessages();
});

function requestOlderMessages() {
  if (!activeSessionId || !loadedTurns.length || loadOlderBtn.hidden || loadOlderBtn.disabled || olderMessagesLoading) return;
  olderMessagesLoading = true;
  postView('loadOlderMessages', {
    sessionId: activeSessionId,
    beforeOrdinal: Number(loadedTurns[0].ordinal) || 0
  });
}
messages.addEventListener('scroll', () => {
  if (messages.scrollTop <= 32) requestOlderMessages();
});

historyList.addEventListener('click', event => {
  const row = event.target.closest('.session-row');
  if (!row) return;
  if (event.target.closest('.session-check')) return;
  if (selectionMode) {
    toggleSessionSelection(row);
    return;
  }
  if (event.target.closest('.session-open'))
    postView('loadSession', { sessionId: Number(row.dataset.sessionId) });
});
historyList.addEventListener('change', event => {
  const check = event.target.closest('.session-check');
  if (!check) return;
  const id = Number(check.closest('.session-row').dataset.sessionId);
  if (check.checked) selectedSessionIds.add(id);
  else selectedSessionIds.delete(id);
  updateSelectionUI();
});
historyList.addEventListener('contextmenu', event => {
  const row = event.target.closest('.session-row');
  if (!row) return;
  event.preventDefault();
  showSessionContextMenu(row, event.clientX, event.clientY);
});
historyList.addEventListener('keydown', event => {
  if (event.key !== 'ContextMenu' && !(event.shiftKey && event.key === 'F10')) return;
  const row = event.target.closest('.session-row');
  if (!row) return;
  event.preventDefault();
  const rect = row.getBoundingClientRect();
  showSessionContextMenu(row, rect.left + 24, rect.bottom);
  sessionContextMenu.querySelector('[role="menuitem"]').focus();
});
sessionContextMenu.addEventListener('click', event => {
  const item = event.target.closest('[data-menu-action]');
  if (item) runSessionMenuAction(item.dataset.menuAction);
});
document.addEventListener('click', event => {
  if (!sessionContextMenu.hidden && !sessionContextMenu.contains(event.target))
    closeSessionContextMenu();
});
historyList.addEventListener('scroll', () => {
  if (!sessionHasMore || sessionPageLoading
      || historyList.scrollTop + historyList.clientHeight < historyList.scrollHeight - 40) return;
  sessionPageLoading = true;
  postView('listSessions', { offset: sessionOffset });
});

// Pushed settings carry the ui language the page should use.
window.onHostSettings = function (s) {
  lang = s && s.uiLanguage === 'zh' ? 'zh' : 'en';
  applyLanguage();
};

window.setPinned = function (value) {
  applyPinnedState(value && typeof value === 'object' ? value.pinned : value);
};

window.setNativeWindowMode = function (value) {
  WindowBar.setNativeWindowMode(value);
};

applyLanguage();
input.focus();
