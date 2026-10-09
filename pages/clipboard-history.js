
WindowBar.init();
window.setPinned = function(value) { WindowBar.setPinned(value); };
window.setNativeWindowMode = function(value) { WindowBar.setNativeWindowMode(value); };
const list = document.getElementById('list');
const search = document.getElementById('search');
const dateFilter = document.getElementById('dateFilter');
const selectedDateOption = document.getElementById('selectedDateOption');
const status = document.getElementById('status');
const clearButton = document.getElementById('clearButton');
const favoriteFilter = document.getElementById('favoriteFilter');
const favoriteCount = document.getElementById('favoriteCount');
const prevPage = document.getElementById('prevPage');
const nextPage = document.getElementById('nextPage');
const pageLabel = document.getElementById('pageLabel');
const pageSize = document.getElementById('pageSize');
const contextMenu = document.getElementById('contextMenu');
const multiSelectButton = document.getElementById('multiSelectButton');
const selectionCount = document.getElementById('selectionCount');
const bulkNoteButton = document.getElementById('bulkNoteButton');
const bulkDeleteButton = document.getElementById('bulkDeleteButton');
const state = {
  sessionId: '',
  rows: [],
  type: 'all',
  favoriteOnly: false,
  search: '',
  dateFilter: 'all',
  selectedDate: '',
  dateAfter: '',
  dateBefore: '',
  page: 1,
  pageSize: 20,
  pageCount: 1,
  renderedPage: 1,
  renderedPageSize: 20,
  counts: {},
  selectedId: '',
  contextId: '',
  multiSelectMode: false,
  selectedIds: new Set(),
  bulkBusy: false,
  querySerial: 0,
  queryTimer: 0,
  loading: false,
  composing: false,
  pendingFavorites: new Map(),
  nativeDragPending: new Set(),
  imagePreviews: new Map(),
  imagePreviewOrder: [],
  imagePreviewRequested: new Set(),
  imageObserver: null
};

function post(message) { if (window.chrome && chrome.webview) chrome.webview.postMessage(JSON.stringify(message)); }
document.addEventListener('drop', event => { event.preventDefault(); event.stopImmediatePropagation(); }, true);
function toast(text, type = 'info') { if (text) AppToast.show(text, type); }
function icon(node, name, className = '') { if (typeof createIcon === 'function') node.appendChild(createIcon(name, className)); else node.textContent = '•'; }
function typeIcon(type) { return type === 'image' ? 'image' : type === 'file' ? 'file' : type === 'rich' ? 'file-pen' : 'type'; }
function typeName(type) { return type === 'image' ? '图片' : type === 'file' ? '文件' : type === 'rich' ? '富文本' : '文本'; }
function timeText(value) {
  if (!value) return '';
  const digits = String(value).replace(/\D/g, '');
  if (digits.length < 14) return value;
  const date = new Date(Date.UTC(
    Number(digits.slice(0, 4)),
    Number(digits.slice(4, 6)) - 1,
    Number(digits.slice(6, 8)),
    Number(digits.slice(8, 10)),
    Number(digits.slice(10, 12)),
    Number(digits.slice(12, 14))
  ));
  const seconds = Math.max(0, Math.floor((Date.now() - date.getTime()) / 1000));
  if (seconds < 60) return '刚刚';
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} 小时前`;
  return `${Math.floor(seconds / 86400)} 天前`;
}
function sizeText(bytes) { if (!bytes) return ''; if (bytes < 1024) return `${bytes} B`; if (bytes < 1024*1024) return `${Math.round(bytes/1024)} KB`; return `${(bytes/1024/1024).toFixed(1)} MB`; }
function utcTimestamp(date) { return date.toISOString(); }
function localDateInputValue(date = new Date()) {
  const pad = value => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}
function dateRangeForFilter(filter) {
  if (filter === 'all') return { after: '', before: '' };
  if (filter === 'custom') {
    if (!state.selectedDate) return { after: '', before: '' };
    const [year, month, day] = state.selectedDate.split('-').map(Number);
    return {
      after: utcTimestamp(new Date(year, month - 1, day)),
      before: utcTimestamp(new Date(year, month - 1, day + 1))
    };
  }
  const start = new Date();
  start.setHours(0, 0, 0, 0);
  if (filter !== 'today') {
    const calendarDays = Math.max(1, Number(filter) || 1);
    start.setDate(start.getDate() - calendarDays + 1);
  }
  return { after: utcTimestamp(start), before: '' };
}
function updateDateFilterLabel() {
  selectedDateOption.hidden = !state.selectedDate;
  selectedDateOption.textContent = state.selectedDate;
  dateFilter.value = state.dateFilter === 'custom' && state.selectedDate
    ? 'custom-date' : state.dateFilter;
}
async function chooseCustomDate() {
  const sessionId = state.sessionId;
  const previousValue = state.dateFilter === 'custom' && state.selectedDate
    ? 'custom-date' : state.dateFilter;
  const value = await AppDialog.prompt({
    title: '选择日期', label: '日期', type: 'date',
    value: state.selectedDate || localDateInputValue(), confirmText: '应用'
  });
  if (state.sessionId !== sessionId) return;
  if (value === null || !/^\d{4}-\d{2}-\d{2}$/.test(String(value))) {
    dateFilter.value = previousValue;
    return;
  }
  state.dateFilter = 'custom';
  state.selectedDate = String(value);
  updateDateFilterLabel();
  requestQuery(true);
}
function requestQuery(reset = true, page = state.page) {
  clearTimeout(state.queryTimer);
  if (!state.sessionId) return;
  state.page = reset ? 1 : Math.max(1, Number(page) || 1);
  if (reset) state.selectedIds.clear();
  const queryId = ++state.querySerial;
  const dateRange = dateRangeForFilter(state.dateFilter);
  state.dateAfter = dateRange.after;
  state.dateBefore = dateRange.before;
  state.selectedId = '';
  // Keep the last list visible until its replacement arrives. Disable row
  // actions during the query so displayed results cannot be used as current.
  state.loading = true;
  list.inert = true;
  list.setAttribute('aria-busy', 'true');
  hideMenu();
  updateMultiSelectBar();
  state.queryTimer = setTimeout(() => {
    post({
      type: 'query', sessionId: state.sessionId, queryId,
      search: state.search, primaryType: state.type,
      favoriteOnly: state.favoriteOnly, dateFilter: state.dateFilter,
      selectedDate: state.selectedDate, dateAfter: state.dateAfter,
      dateBefore: state.dateBefore, page: state.page, pageSize: state.pageSize
    });
  }, 160);
}
function rowPreview(row) {
  return row.preview || typeName(row.type);
}
function rowMeta(row) {
  if (row.type === 'image' && row.imageWidth && row.imageHeight)
    return `${row.imageWidth} × ${row.imageHeight}`;
  if (row.type === 'file') return `${row.itemCount || 0} 项`;
  return row.byteSize ? sizeText(row.byteSize) : typeName(row.type);
}
function requestImagePreview(id) {
  const key = String(id);
  if (state.imagePreviewRequested.has(key) || state.imagePreviews.has(key)) return;
  state.imagePreviewRequested.add(key);
  post({ type: 'imagePreview', sessionId: state.sessionId, id });
}
function observeImageThumb(node, id) {
  if (state.imagePreviews.has(String(id))) return;
  if (typeof IntersectionObserver === 'undefined') {
    requestImagePreview(id);
    return;
  }
  if (!state.imageObserver) {
    state.imageObserver = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (!entry.isIntersecting) return;
        state.imageObserver.unobserve(entry.target);
        requestImagePreview(entry.target.dataset.imageId);
      });
    }, { root: list, rootMargin: '120px' });
  }
  node.dataset.imageId = id;
  state.imageObserver.observe(node);
}
function fillImagePreview(node, dataUri) {
  node.textContent = '';
  if (dataUri) {
    const image = document.createElement('img');
    image.src = dataUri;
    image.alt = '图片预览';
    image.draggable = false;
    node.appendChild(image);
  } else {
    icon(node, 'image');
  }
}
let iconRefreshScheduled = false;
function scheduleIconRefresh() {
  if (iconRefreshScheduled) return;
  iconRefreshScheduled = true;
  requestAnimationFrame(() => {
    iconRefreshScheduled = false;
    refreshIcons();
  });
}
function rememberImagePreview(key, dataUri) {
  state.imagePreviews.set(key, dataUri);
  state.imagePreviewOrder = state.imagePreviewOrder.filter(item => item !== key);
  if (dataUri) state.imagePreviewOrder.push(key);
  while (state.imagePreviewOrder.length > 48) {
    const oldest = state.imagePreviewOrder.shift();
    state.imagePreviews.delete(oldest);
  }
}
function removeImagePreview(id) {
  const key = String(id);
  state.imagePreviews.delete(key);
  state.imagePreviewOrder = state.imagePreviewOrder.filter(item => item !== key);
  state.imagePreviewRequested.delete(key);
}
function clearImagePreviews() {
  state.imagePreviews.clear();
  state.imagePreviewOrder = [];
  state.imagePreviewRequested.clear();
}
function applyImagePreview(id, dataUri) {
  const key = String(id);
  state.imagePreviewRequested.delete(key);
  const previewData = String(dataUri || '');
  rememberImagePreview(key, previewData);
  const article = findRowElement(id);
  const preview = article ? article.querySelector('.image-preview-wrap') : 0;
  if (!preview) return;
  fillImagePreview(preview, previewData);
  if (!previewData) scheduleIconRefresh();
}
function updateSummary() {
  const total = Number(state.counts.total || 0);
  const matching = Number(state.counts.matching ?? state.rows.length);
  const nonFavorite = Number(state.counts.nonFavorite || 0);
  favoriteCount.textContent = String(state.counts.favorite || 0);
  status.textContent = state.counts.error
    ? '历史存储不可用' : `共 ${total} 条 · 当前 ${matching} 条`;
  clearButton.disabled = !!state.counts.error || nonFavorite <= 0;
  favoriteFilter.classList.toggle('active', state.favoriteOnly);
  pageLabel.textContent = `第 ${state.page} / ${state.pageCount} 页`;
  prevPage.disabled = !!state.counts.error || state.page <= 1;
  nextPage.disabled = !!state.counts.error || state.page >= state.pageCount;
  pageSize.value = String(state.pageSize);
}
function findRowElement(id) {
  return Array.from(list.querySelectorAll('.history-row'))
    .find(item => item.dataset.id === String(id));
}
function selectRow(id) {
  const key = String(id);
  state.selectedId = id;
  list.querySelectorAll('.history-row').forEach(article => {
    const selected = article.dataset.id === key;
    article.classList.toggle('selected', selected);
    article.setAttribute('aria-selected', selected ? 'true' : 'false');
  });
}
function updateMultiSelectBar() {
  const count = state.selectedIds.size;
  multiSelectButton.textContent = state.multiSelectMode ? '取消多选' : '多选';
  multiSelectButton.classList.toggle('active', state.multiSelectMode);
  multiSelectButton.disabled = state.bulkBusy;
  selectionCount.hidden = !state.multiSelectMode;
  selectionCount.textContent = `已选 ${count} 项`;
  bulkNoteButton.hidden = !state.multiSelectMode;
  bulkDeleteButton.hidden = !state.multiSelectMode;
  bulkNoteButton.disabled = !state.multiSelectMode || count === 0 || state.bulkBusy;
  bulkDeleteButton.disabled = !state.multiSelectMode || count === 0 || state.bulkBusy;
}
function setMultiSelectMode(enabled) {
  if (state.bulkBusy) return;
  state.multiSelectMode = !!enabled;
  state.selectedIds.clear();
  state.selectedId = '';
  render();
}
function toggleMultiSelected(id) {
  const key = String(id);
  if (state.selectedIds.has(key)) state.selectedIds.delete(key);
  else state.selectedIds.add(key);
  const article = findRowElement(key);
  if (article) {
    const selected = state.selectedIds.has(key);
    article.classList.toggle('multi-selected', selected);
    article.classList.remove('selected');
    article.setAttribute('aria-selected', selected ? 'true' : 'false');
  }
  updateMultiSelectBar();
}
function updateFavoriteVisual(row) {
  const article = findRowElement(row.id);
  if (!article) return;
  const button = article.querySelector('.favorite-button');
  if (!button) return;
  button.classList.toggle('active', !!row.favorite);
  button.title = row.favorite ? '取消收藏' : '收藏';
  button.setAttribute('aria-label', button.title);
}
function appendEmptyState() {
  const empty = document.createElement('div');
  empty.className = 'empty';
  empty.textContent = state.search || state.favoriteOnly
    || state.type !== 'all' || state.dateFilter !== 'all'
    ? '没有匹配的历史' : '暂无剪贴板历史';
  list.appendChild(empty);
}
function applyFavoriteResult(id, desired) {
  const rowId = String(id || '');
  state.pendingFavorites.delete(rowId);
  const index = state.rows.findIndex(item => String(item.id) === rowId);
  if (index < 0) return;
  const row = state.rows[index], previous = !!row.favorite, next = !!desired;
  if (previous === next) { updateFavoriteVisual(row); return; }
  row.favorite = next;
  state.counts.favorite = Math.max(0, Number(state.counts.favorite || 0) + (next ? 1 : -1));
  state.counts.nonFavorite = Math.max(0, Number(state.counts.nonFavorite || 0) + (next ? -1 : 1));
  if (state.favoriteOnly && !next) {
    const matching = Math.max(0, Number(state.counts.matching ?? state.rows.length) - 1);
    state.counts.matching = matching;
    const article = findRowElement(row.id);
    if (article) article.remove();
    state.rows.splice(index, 1);
    state.selectedIds.delete(rowId);
    if (state.selectedId === row.id) state.selectedId = '';
    state.pageCount = Math.max(1, Math.ceil(matching / state.pageSize));
    if (!state.rows.length && !matching) appendEmptyState();
    updateSummary();
    updateMultiSelectBar();
    const expectedRows = Math.min(state.pageSize,
      Math.max(0, matching - (state.page - 1) * state.pageSize));
    if (state.page > state.pageCount || state.rows.length < expectedRows)
      requestQuery(false, Math.min(state.page, state.pageCount));
    return;
  }
  updateFavoriteVisual(row);
  updateSummary();
  updateMultiSelectBar();
}
function toggleFavorite(row) {
  const rowId = String(row.id);
  if (state.pendingFavorites.has(rowId)) return;
  const desired = !row.favorite;
  state.pendingFavorites.set(rowId, desired);
  post({ type: 'favorite', sessionId: state.sessionId, id: row.id, desired });
}
function configureNativeDrag(article, row) {
  if (row.type !== 'file' && row.type !== 'image') return;
  if (row.type === 'file' && !(row.itemCount > 0)) return;
  article.draggable = true;
  article.addEventListener('dragstart', event => {
    event.preventDefault();
    state.nativeDragPending.add(String(row.id));
    post({
      type: row.type === 'file' ? 'fileDrag' : 'imageDrag',
      sessionId: state.sessionId, id: row.id
    });
  });
}
async function editNote(row) {
  const sessionId = state.sessionId;
  const value = await AppDialog.prompt({title: row.note ? '编辑备注' : '添加备注', label: '备注', value: row.note || '', placeholder: '输入备注（最多 4000 字）', validate: text => String(text).length > 4000 ? '备注不能超过 4000 字。' : ''});
  if (value !== null && state.sessionId === sessionId)
    post({type:'note',sessionId,id:row.id,note:String(value)});
}
async function addBulkNote() {
  if (!state.multiSelectMode || !state.selectedIds.size || state.bulkBusy) return;
  const sessionId = state.sessionId;
  const ids = Array.from(state.selectedIds);
  state.bulkBusy = true;
  updateMultiSelectBar();
  const value = await AppDialog.prompt({title:`为 ${ids.length} 项添加备注`,label:'备注（会替换所选项的现有备注）',placeholder:'输入统一备注（最多 4000 字）',validate:text=>!String(text).trim()?'备注不能为空。':String(text).length>4000?'备注不能超过 4000 字。':''});
  if (state.sessionId !== sessionId) return;
  if (value === null) { state.bulkBusy = false; updateMultiSelectBar(); return; }
  post({type:'bulkNote',sessionId,ids,note:String(value)});
}
async function deleteBulkSelection() {
  if (!state.multiSelectMode || !state.selectedIds.size || state.bulkBusy) return;
  const sessionId = state.sessionId;
  const ids = Array.from(state.selectedIds);
  state.bulkBusy = true;
  updateMultiSelectBar();
  const confirmed = await AppDialog.confirm({title:`删除所选 ${ids.length} 项？`,message:'会删除所选历史，包括收藏和置顶项；此操作无法撤销。',confirmText:'删除',tone:'danger'});
  if (state.sessionId !== sessionId) return;
  if (!confirmed) { state.bulkBusy = false; updateMultiSelectBar(); return; }
  post({type:'bulkDelete',sessionId,ids});
}
function render() {
  if (state.imageObserver) state.imageObserver.disconnect();
  list.textContent = '';
  const storageError = String(state.counts.error || '');
  if (storageError) {
    const error = document.createElement('div');
    error.className = 'empty';
    error.textContent = `剪贴板历史不可用：${storageError}`;
    list.appendChild(error);
  } else if (!state.rows.length) {
    const empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = state.search || state.favoriteOnly
      || state.type !== 'all' || state.dateFilter !== 'all'
      ? '没有匹配的历史' : '暂无剪贴板历史';
    list.appendChild(empty);
  } else {
    state.rows.forEach(row => renderRow(row));
  }
  updateSummary();
  updateMultiSelectBar();
  refreshIcons();
}
function renderRow(row) {
  const rowId = String(row.id);
  const multiSelected = state.selectedIds.has(rowId);
  const visuallySelected = state.multiSelectMode ? multiSelected : row.id === state.selectedId;
  const article = document.createElement('article');
  article.className = 'history-row' + (!state.multiSelectMode && row.id === state.selectedId ? ' selected' : '') + (state.multiSelectMode && multiSelected ? ' multi-selected' : '');
  article.dataset.id = rowId;
  article.tabIndex = -1;
  article.setAttribute('role', 'option');
  article.setAttribute('aria-selected', visuallySelected ? 'true' : 'false');
  const glyph = document.createElement('div');
  glyph.className = 'type-icon';
  if (state.multiSelectMode) {
    icon(glyph, 'square', 'select-empty');
    icon(glyph, 'check', 'select-check');
  } else {
    icon(glyph, typeIcon(row.type));
  }
  const main = document.createElement('div');
  main.className = 'row-main';
  const imageKey = rowId;
  const cachedImagePreview = state.imagePreviews.get(imageKey);
  let preview = 0;
  if (row.type === 'image') {
    preview = document.createElement('div');
    preview.className = 'image-preview-wrap';
    fillImagePreview(preview, cachedImagePreview || '');
  } else {
    preview = document.createElement('div');
    const previewText = rowPreview(row);
    preview.className = 'preview' + (row.richText ? ' rich' : '')
      + (/[\r\n]/.test(previewText) ? ' multiline' : '');
    preview.textContent = previewText;
  }
  const note = document.createElement('div');
  if (row.note) {
    note.className = 'note';
    icon(note, 'message-square');
    const noteText = document.createElement('span');
    noteText.textContent = row.note;
    note.append(noteText);
  }
  const meta = document.createElement('div');
  meta.className = 'meta';
  meta.textContent = `${timeText(row.capturedAt)} · ${typeName(row.type)} · ${rowMeta(row)}`;
  if (row.pinned) {
    const pinBadge = document.createElement('span');
    pinBadge.className = 'pin-badge';
    icon(pinBadge, 'pin');
    meta.prepend(pinBadge);
  }
  main.append(preview);
  if (row.note) main.append(note);
  main.append(meta);
  const side = document.createElement('div');
  side.className = 'row-side';
  const fav = document.createElement('button');
  fav.className = 'favorite-button' + (row.favorite ? ' active' : '');
  fav.title = row.favorite ? '取消收藏' : '收藏';
  fav.setAttribute('aria-label', fav.title);
  fav.dataset.action = 'favorite';
  icon(fav, 'star');
  fav.addEventListener('click', event => { event.preventDefault(); event.stopPropagation(); toggleFavorite(row); });
  side.append(fav);
  article.append(glyph, main, side);
  article.addEventListener('click', event => {
    if (state.nativeDragPending.has(rowId)) { event.preventDefault(); event.stopPropagation(); return; }
    if (state.multiSelectMode) { if (event.detail === 1) toggleMultiSelected(row.id); return; }
    if (event.detail === 1) { selectRow(row.id); post({ type: 'copy', sessionId: state.sessionId, id: row.id }); }
  });
  article.addEventListener('dblclick', event => {
    event.preventDefault();
    if (state.multiSelectMode) return;
    selectRow(row.id);
    post({ type: 'paste', sessionId: state.sessionId, id: row.id });
  });
  article.addEventListener('contextmenu', event => {
    event.preventDefault();
    state.contextId = row.id;
    if (!state.multiSelectMode) selectRow(row.id);
    showMenu(event.clientX, event.clientY, row);
  });
  configureNativeDrag(article, row);
  list.appendChild(article);
  if (row.type === 'image' && !state.imagePreviews.has(imageKey)) observeImageThumb(preview, row.id);
}
function focusHistoryRow(index) {
  const rows = Array.from(list.querySelectorAll('.history-row'));
  if (!rows.length) return;
  const next = Math.max(0, Math.min(rows.length - 1, index < 0 ? 0 : index));
  const row = rows[next];
  state.selectedId = row.dataset.id;
  if (!state.multiSelectMode) selectRow(row.dataset.id);
  row.focus();
  row.scrollIntoView({ block: 'nearest' });
}
function showMenu(x, y, row) {
  contextMenu.classList.remove('hidden');
  contextMenu.querySelector('[data-action="favorite"] span').textContent =
    row.favorite ? '取消收藏' : '收藏';
  contextMenu.querySelector('[data-action="note"] span').textContent =
    row.note ? '编辑备注' : '添加备注';
  contextMenu.querySelector('[data-action="pin"] span').textContent =
    row.pinned ? '取消置顶' : '置顶';
  const left = Math.min(x, window.innerWidth - contextMenu.offsetWidth - 8);
  const top = Math.min(y, window.innerHeight - contextMenu.offsetHeight - 8);
  contextMenu.style.left = Math.max(8, left) + 'px';
  contextMenu.style.top = Math.max(8, top) + 'px';
  requestAnimationFrame(() => contextMenu.querySelector('.menu-item:not([hidden])')?.focus());
}
function hideMenu(returnFocus = false) {
  const id = state.contextId;
  contextMenu.classList.add('hidden');
  state.contextId = '';
  if (!returnFocus) return;
  const row = findRowElement(id);
  if (row) row.focus();
  else list.focus();
}
async function contextAction(action) {
  const sessionId = state.sessionId;
  const id = state.contextId;
  const row = state.rows.find(item => item.id === id);
  hideMenu();
  if (!id || !row) return;

  if (action === 'copy') post({ type: 'copy', sessionId, id });
  else if (action === 'paste') post({ type: 'paste', sessionId, id });
  else if (action === 'favorite') toggleFavorite(row);
  else if (action === 'note') editNote(row);
  else if (action === 'pin') post({ type: 'pin', sessionId, id, desired: !row.pinned });
  else if (action === 'delete') {
    const confirmed = !row.favorite || await AppDialog.confirm({
      title: '删除收藏历史',
      message: '删除后会同时移除收藏，确定继续吗？',
      confirmText: '删除',
      tone: 'danger'
    });
    if (confirmed && state.sessionId === sessionId)
      post({ type: 'delete', sessionId, id });
  }
}
contextMenu.addEventListener('click', event => {
  const button = event.target.closest('[data-action]');
  if (button) contextAction(button.dataset.action);
});
document.addEventListener('click', event => {
  if (!contextMenu.contains(event.target)) hideMenu();
});
list.addEventListener('keydown', event => {
  const rows = Array.from(list.querySelectorAll('.history-row'));
  if (!rows.length) return;
  const index = rows.findIndex(row => row.dataset.id === String(state.selectedId));
  if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
    event.preventDefault();
    const next = event.key === 'Home' ? 0
      : event.key === 'End' ? rows.length - 1
      : index + (event.key === 'ArrowDown' ? 1 : -1);
    focusHistoryRow(next);
    return;
  }
  if (event.key === 'ContextMenu' || (event.key === 'F10' && event.shiftKey)) {
    const row = rows[Math.max(0, index)];
    const item = state.rows.find(candidate => String(candidate.id) === row.dataset.id);
    if (!item) return;
    event.preventDefault();
    state.contextId = item.id;
    const rect = row.getBoundingClientRect();
    showMenu(rect.left + rect.width / 2, rect.top + rect.height / 2, item);
    return;
  }
  if (event.key === 'Escape' && !contextMenu.classList.contains('hidden')) {
    event.preventDefault();
    hideMenu(true);
    return;
  }
  const row = rows[Math.max(0, index)];
  if (state.multiSelectMode && (event.key === ' ' || event.key === 'Enter')) {
    event.preventDefault();
    toggleMultiSelected(row.dataset.id);
  } else if (!state.multiSelectMode && (event.key === 'Enter' || event.key === ' ')) {
    event.preventDefault();
    post({ type: event.ctrlKey ? 'paste' : 'copy', sessionId: state.sessionId, id: row.dataset.id });
  }
});
contextMenu.addEventListener('keydown', event => {
  const items = Array.from(contextMenu.querySelectorAll('.menu-item:not([hidden])'));
  if (!items.length) return;
  const current = items.indexOf(document.activeElement);
  let next = -1;
  if (event.key === 'ArrowDown') next = (current + 1 + items.length) % items.length;
  else if (event.key === 'ArrowUp') next = (current - 1 + items.length) % items.length;
  else if (event.key === 'Home') next = 0;
  else if (event.key === 'End') next = items.length - 1;
  else if (event.key === 'Escape') {
    event.preventDefault();
    hideMenu(true);
    return;
  }
  if (next >= 0) {
    event.preventDefault();
    items[next].focus();
  }
});
search.addEventListener('compositionstart',()=>{state.composing=true;});
search.addEventListener('compositionend',()=>{state.composing=false;state.search=search.value;requestQuery(true);});
search.addEventListener('input',()=>{state.search=search.value;if(!state.composing)requestQuery(true);});
document.querySelectorAll('.filter[data-type]').forEach(button => {
  button.addEventListener('click', () => {
    document.querySelectorAll('.filter[data-type]').forEach(item => item.classList.remove('active'));
    button.classList.add('active');
    state.type = button.dataset.type;
    requestQuery(true);
  });
});
dateFilter.addEventListener('change', () => {
  const nextFilter = dateFilter.value;
  if (nextFilter === 'custom') {
    chooseCustomDate();
    return;
  }
  if (nextFilter === 'custom-date') {
    state.dateFilter = 'custom';
    requestQuery(true);
    return;
  }
  state.dateFilter = nextFilter;
  state.selectedDate = '';
  updateDateFilterLabel();
  requestQuery(true);
});
favoriteFilter.addEventListener('click',()=>{state.favoriteOnly=!state.favoriteOnly;requestQuery(true);});
prevPage.addEventListener('click',()=>{if(state.page>1)requestQuery(false,state.page-1);});
nextPage.addEventListener('click',()=>{if(state.page<state.pageCount)requestQuery(false,state.page+1);});
pageSize.addEventListener('change',()=>{state.pageSize=Math.max(1,Number(pageSize.value)||20);requestQuery(false,1);});
multiSelectButton.addEventListener('click',()=>setMultiSelectMode(!state.multiSelectMode));
bulkNoteButton.addEventListener('click',addBulkNote);
bulkDeleteButton.addEventListener('click',deleteBulkSelection);
clearButton.addEventListener('click',()=>{post({type:'prepareClear',sessionId:state.sessionId});});
window.handleHostMessage=function(message){
  const data=message||{};
  if(data.type==='sessionEnd'){
    if(data.sessionId!==state.sessionId)return;
    clearTimeout(state.queryTimer);
    state.querySerial++;
    state.loading=false; list.inert=true; list.setAttribute('aria-busy','false');
    AppDialog.dismiss();
    hideMenu();
    state.sessionId=''; state.multiSelectMode=false; state.selectedIds.clear(); state.bulkBusy=false;
    state.pendingFavorites.clear(); state.imagePreviewRequested.clear(); state.nativeDragPending.clear();
    updateMultiSelectBar();
    return;
  }
  if(data.type==='hostState'){
    if(state.sessionId&&state.sessionId!==String(data.sessionId||''))AppDialog.dismiss();
    state.nativeDragPending.clear(); state.imagePreviewRequested.clear(); state.pendingFavorites.clear();
    state.multiSelectMode=false; state.selectedIds.clear(); state.bulkBusy=false;
    state.composing=false; state.contextId='';
    state.sessionId=String(data.sessionId||''); state.search=String(data.search||''); search.value=state.search;
    state.type=String(data.primaryType||'all'); state.favoriteOnly=!!data.favoriteOnly;
    state.dateFilter=String(data.dateFilter||'all'); state.selectedDate=String(data.selectedDate||''); updateDateFilterLabel();
    state.dateAfter=String(data.dateAfter||''); state.dateBefore=String(data.dateBefore||'');
    if(data.pageSize)state.pageSize=Number(data.pageSize)||20;
    document.querySelectorAll('.filter[data-type]').forEach(item=>item.classList.toggle('active',item.dataset.type===state.type));
    requestQuery(true);
  } else if(data.type==='historyResults'){
    if(data.sessionId!==state.sessionId)return;
    const responseQueryId=Number(data.queryId||0); if(responseQueryId&&responseQueryId!==state.querySerial)return;
    state.rows=Array.isArray(data.rows)?data.rows:[]; state.counts=data.counts||{};
    state.page=Number(data.page||state.page)||1; state.pageSize=Number(data.pageSize||state.pageSize)||20;
    state.pageCount=Math.max(1,Number(data.pageCount||1)); state.loading=false;
    const resetScroll=state.page!==state.renderedPage||state.pageSize!==state.renderedPageSize;
    list.inert=false; list.setAttribute('aria-busy','false'); render();
    if(resetScroll)list.scrollTop=0;
    state.renderedPage=state.page; state.renderedPageSize=state.pageSize;
  } else if(data.type==='imagePreview'){
    if(data.sessionId!==state.sessionId)return; applyImagePreview(data.id,data.data);
  } else if(data.type==='nativeDragFinished'){
    if(data.sessionId===state.sessionId)state.nativeDragPending.delete(String(data.id||''));
  } else if(data.type==='clearInfo'){
    const sessionId=String(data.sessionId||state.sessionId);
    AppDialog.confirm({
      title: '清空未收藏的剪贴板历史？',
      message: `将清空全部未收藏历史，当前共 ${data.nonFavoriteCount || 0} 条；${data.favoriteCount || 0} 条收藏会保留。`,
      confirmText: '清空未收藏',
      tone: 'danger'
    }).then(ok => {
      if (state.sessionId === sessionId)
        post({ type: ok ? 'clear' : 'cancelClear', sessionId, token: data.token });
    });
  } else if(data.type==='actionResult'){
    if(data.sessionId&&data.sessionId!==state.sessionId)return;
    if(data.ok)toast(data.message||'已完成','success'); else toast(data.message||'操作失败','error');
    if(data.action==='favorite'){
      if(data.ok)applyFavoriteResult(data.id,data.desired); else state.pendingFavorites.delete(String(data.id||''));
    } else if(data.action==='note'){
      const row=state.rows.find(item=>String(item.id)===String(data.id));
      if(data.ok&&row){row.note=String(data.note||'');requestQuery(false,state.page);}
    } else if(data.action==='pin'){
      if(data.ok)requestQuery(false,state.page);
    } else if(data.action==='fileDrag'||data.action==='imageDrag'){
      state.nativeDragPending.delete(String(data.id||''));
    } else if(data.action==='bulkNote'){
      state.bulkBusy=false;
      if(data.ok){state.selectedIds.clear();requestQuery(false,state.page);}else updateMultiSelectBar();
    } else if(data.action==='bulkDelete'){
      state.bulkBusy=false;
      if(data.ok){(data.ids||[]).forEach(removeImagePreview);state.selectedIds.clear();requestQuery(false,state.page);}else updateMultiSelectBar();
    } else if(data.action==='delete'){
      removeImagePreview(data.id);
      requestQuery(true);
    } else if(data.action==='clear'){
      clearImagePreviews();
      requestQuery(true);
    }
  }
};
window.refreshHistory=function(){requestQuery(true);};
window.setState=function(payload){ if(payload&&payload.sessionId)state.sessionId=payload.sessionId; if(payload&&payload.search!=null){state.search=payload.search;search.value=state.search;} requestQuery(true); };
setTimeout(()=>post({type:'ready',sessionId:state.sessionId}),0);
refreshIcons();
