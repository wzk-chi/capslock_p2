
const state = {
  draft: null, baseSections: null, baseProfiles: [], basePlugins: [],
  page: 'general', dirty: false, pluginsDirty: false,
  dirtyFields: new Set(), windowPickerDialog: null,
  saveSequence: 0, latestAppliedSaveId: 0, pendingSaveSections: new Map(),
  qbarPluginDraft: null, qbarPluginToolSettings: {}, qbarPluginSaving: false,
  qbarDeleteTarget: null, qbarDeleteSaving: false, qbarDeleteDialog: null,
  qbarPluginDialog: null, qbarCreateKind: '', qbarCreateDraft: null,
  qbarCreateSaving: false, qbarCreateDialog: null,
  hotkeyProfileId: '', baseProfileStamp: '', profilesDirty: false, overridesOnly: false,
  hotkeyApplicationDialog: null
};
let shortcutRecording = null;
let shortcutCaptureSequence = 0;
const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const post = payload => {
  if (window.chrome && chrome.webview) chrome.webview.postMessage(JSON.stringify(payload));
};
const clone = value => JSON.parse(JSON.stringify(value || {}));
const pickerState = { selectedIndex: 0, kind: '', root: null, rows: [] };
let translationLanguageCodes = [];
let translationLanguageByCode = new Map();
const section = name => (state.draft && state.draft.sections && state.draft.sections[name]) || {};
function hotkeyProfile() {
  if (!state.draft || !Array.isArray(state.draft.profiles) || !state.hotkeyProfileId) return null;
  return state.draft.profiles.find(profile => String(profile.id) === String(state.hotkeyProfileId)) || null;
}
function normalizeCustomTrigger(value) {
  let raw = String(value ?? '').trim();
  if (!raw) return '';
  if (/^(ctrl|control|alt|shift|win|windows)$/i.test(raw)) return '';
  let prefix = '';
  const modifiers = { ctrl: '^', control: '^', alt: '!', shift: '+', win: '#', windows: '#' };
  const parts = raw.split('+').map(part => part.trim());
  let partIndex = 0;
  while (partIndex < parts.length - 1 && modifiers[parts[partIndex].toLowerCase()]) {
    prefix += modifiers[parts[partIndex].toLowerCase()];
    partIndex++;
  }
  if (partIndex) raw = parts.slice(partIndex).join('+').trim();
  else {
    while (raw && '^!+#'.includes(raw[0])) prefix += raw[0], raw = raw.slice(1);
  }
  if (raw.length >= 2 && raw[0] === '{' && raw[raw.length - 1] === '}') raw = raw.slice(1, -1);
  return [...'^!+#'].filter(modifier => prefix.includes(modifier)).join('') + raw.toLowerCase();
}
function customKeyLabel(value) {
  const key = String(value || '').replace(/^\{(.*)\}$/, '$1');
  const names = { space: 'Space', esc: 'Esc', escape: 'Esc', enter: 'Enter', tab: 'Tab',
    backspace: 'Backspace', delete: 'Delete', insert: 'Insert', pgup: 'PageUp', pgdn: 'PageDown',
    left: 'Left', right: 'Right', up: 'Up', down: 'Down' };
  return names[key.toLowerCase()] || (/^[a-z0-9]$/i.test(key) ? key.toUpperCase() : key);
}
function formatCustomTrigger(value) {
  const normalized = normalizeCustomTrigger(value);
  let raw = normalized;
  let prefix = '';
  while (raw && '^!+#'.includes(raw[0])) prefix += raw[0], raw = raw.slice(1);
  const modifiers = { '^': 'Ctrl', '!': 'Alt', '+': 'Shift', '#': 'Win' };
  const labels = [...'^!+#'].filter(modifier => prefix.includes(modifier)).map(modifier => modifiers[modifier]);
  const key = customKeyLabel(raw);
  if (key) labels.push(key);
  return labels.join('+');
}
function normalizeCustomSend(value) {
  const raw = String(value ?? '').trim();
  if (!raw || raw === '@native' || raw === '@block' || /^[\^!+#]/.test(raw)) return raw;
  const modifiers = { ctrl: '^', control: '^', alt: '!', shift: '+', win: '#', windows: '#' };
  const parts = raw.split('+').map(part => part.trim());
  let prefix = '';
  let partIndex = 0;
  while (partIndex < parts.length - 1 && modifiers[parts[partIndex].toLowerCase()]) {
    prefix += modifiers[parts[partIndex].toLowerCase()];
    partIndex++;
  }
  if (partIndex) {
    let key = parts.slice(partIndex).join('+').trim();
    if (key && !/^\{.*\}$/.test(key) && !/^[a-z0-9]$/i.test(key)) key = '{' + key + '}';
    return prefix + key;
  }
  if (/^(space|enter|tab|esc|escape|backspace|delete|insert|home|end|left|right|up|down|f(?:[1-9]|1[0-9]|2[0-4]))$/i.test(raw))
    return '{' + raw + '}';
  return raw;
}
function formatCustomSend(value) {
  const raw = String(value ?? '').trim();
  if (!raw || raw === '@native' || raw === '@block') return raw;
  let prefix = '';
  let key = raw;
  while (key && '^!+#'.includes(key[0])) prefix += key[0], key = key.slice(1);
  if (!prefix && /^\{.*\}$/.test(key)) return customKeyLabel(key);
  if (!prefix) return raw;
  const modifiers = { '^': 'Ctrl', '!': 'Alt', '+': 'Shift', '#': 'Win' };
  const labels = [...'^!+#'].filter(modifier => prefix.includes(modifier)).map(modifier => modifiers[modifier]);
  if (key) labels.push(customKeyLabel(key));
  return labels.join('+');
}
function shortcutSection(name) {
  const profile = hotkeyProfile();
  const globalValues = section(name);
  if (!profile && name === 'CustomHotkey') {
    const normalized = {};
    Object.entries(globalValues).forEach(([key, value]) => { normalized[normalizeCustomTrigger(key)] = value; });
    return normalized;
  }
  if (!profile) return globalValues;
  const overrides = profile.sections && profile.sections[name] || {};
  if (name === 'CustomHotkey') {
    const normalized = {};
    Object.entries(globalValues).forEach(([key, value]) => { normalized[normalizeCustomTrigger(key)] = value; });
    Object.entries(overrides).forEach(([key, value]) => { normalized[normalizeCustomTrigger(key)] = value; });
    return normalized;
  }
  return Object.assign({}, globalValues, overrides);
}
function shortcutOverrideExists(sectionName, key) {
  const profile = hotkeyProfile();
  if (!profile || !profile.sections || !profile.sections[sectionName]) return false;
  const target = sectionName === 'CustomHotkey' ? normalizeCustomTrigger(key) : key;
  return Object.keys(profile.sections[sectionName]).some(raw =>
    (sectionName === 'CustomHotkey' ? normalizeCustomTrigger(raw) : raw) === target);
}
function markHotkeyProfileDirty() {
  state.dirty = true;
  state.profilesDirty = true;
  setStatus('未保存');
}
function setShortcutDraftValue(sectionName, key, value) {
  const normalizedKey = sectionName === 'CustomHotkey' ? normalizeCustomTrigger(key) : key;
  const profile = hotkeyProfile();
  if (!profile) {
    const values = state.draft.sections[sectionName] || {};
    Object.keys(values).forEach(raw => {
      if (raw !== normalizedKey && sectionName === 'CustomHotkey'
        && normalizeCustomTrigger(raw) === normalizedKey) {
        delete values[raw]; markDirty(sectionName, raw);
      }
    });
    setDraftValue(sectionName, normalizedKey, value);
    return;
  }
  if (!profile.sections) profile.sections = { Keys: {}, CustomHotkey: {} };
  if (!profile.sections[sectionName]) profile.sections[sectionName] = {};
  Object.keys(profile.sections[sectionName]).forEach(raw => {
    if (raw !== normalizedKey && sectionName === 'CustomHotkey'
      && normalizeCustomTrigger(raw) === normalizedKey) delete profile.sections[sectionName][raw];
  });
  profile.sections[sectionName][normalizedKey] = value;
  markHotkeyProfileDirty();
}
function removeShortcutDraftValue(sectionName, key) {
  const normalizedKey = sectionName === 'CustomHotkey' ? normalizeCustomTrigger(key) : key;
  const profile = hotkeyProfile();
  if (!profile) {
    const values = state.draft.sections[sectionName] || {};
    let matched = false;
    Object.keys(values).forEach(raw => {
      if ((sectionName === 'CustomHotkey' ? normalizeCustomTrigger(raw) : raw) === normalizedKey) {
        values[raw] = '';
        markDirty(sectionName, raw);
        matched = true;
      }
    });
    if (!matched) setDraftValue(sectionName, normalizedKey, '');
    return;
  }
  if (profile.sections && profile.sections[sectionName]) {
    Object.keys(profile.sections[sectionName]).forEach(raw => {
      if ((sectionName === 'CustomHotkey' ? normalizeCustomTrigger(raw) : raw) === normalizedKey)
        delete profile.sections[sectionName][raw];
    });
  }
  markHotkeyProfileDirty();
}
const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
const compactWindowText = value => {
  const text = String(value ?? '').trim();
  return text.length > 40 ? text.slice(0, 40) + '…' : text;
};
const applicationName = value => {
  const raw = String(value ?? '').trim().split(/[\\/]/).pop().replace(/\.exe$/i, '');
  return raw ? raw.charAt(0).toUpperCase() + raw.slice(1) : '';
};
const windowApplicationName = item => applicationName(item && item.exe) || compactWindowText(item && (item.title || item.windowClass));

function setWindowPickerSelection(index) {
  pickerState.selectedIndex = index;
  if (pickerState.kind === 'hotkeyApplication')
    post({ type: 'hotkeyPickerTrace', stage: 'row_selected', index });
  if (pickerState.root)
    $$('#windowPickerRows tr', pickerState.root).forEach(row => row.classList.toggle('selected', Number(row.dataset.index) === index));
  if (state.windowPickerDialog) {
    state.windowPickerDialog.setActionEnabled('select', index >= 1);
    if (index > 0) state.windowPickerDialog.focusAction('select');
  }
}

function closeWindowPickerDialog() {
  if (!state.windowPickerDialog) return;
  const dialog = state.windowPickerDialog;
  state.windowPickerDialog = null;
  pickerState.selectedIndex = 0;
  pickerState.root = null;
  pickerState.rows = [];
  dialog.close({ action: 'host' });
}

window.receiveWindowPicker = function (payload) {
  closeWindowPickerDialog();
  const isApplication = payload && (payload.kind === 'application' || payload.kind === 'hotkeyApplication');
  const rows = Array.isArray(payload && payload.rows) ? payload.rows : [];
  const columns = isApplication ? ['应用', '窗口数', '程序路径'] : ['窗口标题', '应用', '窗口类'];
  pickerState.kind = payload && payload.kind || '';
  pickerState.rows = rows;
  pickerState.selectedIndex = 0;
  let controller;
  controller = AppDialog.open({
    title: payload && payload.title || '选择',
    size: 'wide',
    className: 'picker-dialog',
    actions: [
      { id: 'cancel', text: '取消', role: 'cancel', kind: 'ghost' },
      { id: 'select', text: '选择', disabled: true }
    ],
    initialFocus: 'cancel',
    render(root, api) {
      pickerState.root = root;
      const meta = document.createElement('div'); meta.className = 'picker-dialog-meta';
      const description = document.createElement('p'); description.className = 'picker-description';
      description.id = 'app-dialog-picker-description';
      description.textContent = payload && payload.description || '';
      api.setDescriptionId(description.id);
      const count = document.createElement('span'); count.className = 'picker-count';
      count.textContent = rows.length ? rows.length + ' 项' : '';
      meta.append(description, count);
      const tableWrap = document.createElement('div'); tableWrap.className = 'picker-table-wrap';
      const table = document.createElement('table'); table.className = 'picker-table';
      const head = document.createElement('thead'); const headRow = document.createElement('tr');
      columns.forEach(column => { const cell = document.createElement('th'); cell.textContent = column; headRow.appendChild(cell); });
      head.appendChild(headRow);
      const body = document.createElement('tbody');
      body.id = 'windowPickerRows';
      rows.forEach((item, offset) => {
        const index = offset + 1;
        const row = document.createElement('tr'); row.dataset.index = String(index);
        const values = isApplication ? [item.name, item.count, item.path] : [item.title, item.exe, item.class];
        values.forEach(value => { const cell = document.createElement('td'); cell.textContent = value == null ? '' : String(value); row.appendChild(cell); });
        row.addEventListener('click', () => setWindowPickerSelection(index));
        row.addEventListener('dblclick', () => { setWindowPickerSelection(index); confirmWindowPickerSelection(); });
        body.appendChild(row);
      });
      const empty = document.createElement('div'); empty.className = 'picker-empty';
      empty.textContent = '没有可选择的项目。'; empty.classList.toggle('visible', rows.length === 0);
      if (!rows.length) table.hidden = true;
      table.append(head, body); tableWrap.append(table, empty);
      root.append(meta, tableWrap);
    },
    onAction(id, api) {
      if (id === 'select') {
        confirmWindowPickerSelection();
        return api.keepOpen();
      }
    },
    onClose(result) {
      if (state.windowPickerDialog === controller) state.windowPickerDialog = null;
      pickerState.selectedIndex = 0;
      pickerState.kind = '';
      pickerState.root = null;
      pickerState.rows = [];
      if (!result || (result.action !== 'host' && result.action !== 'select'))
        post({ type: 'cancelWindowPicker' });
    }
  });
  state.windowPickerDialog = controller;
  if (pickerState.kind === 'hotkeyApplication')
    post({ type: 'hotkeyPickerTrace', stage: 'picker_shown', rowCount: rows.length });
};

window.closeWindowPicker = closeWindowPickerDialog;

function confirmWindowPickerSelection() {
  if (pickerState.selectedIndex < 1) {
    if (pickerState.kind === 'hotkeyApplication')
      post({ type: 'hotkeyPickerTrace', stage: 'submit_without_selection' });
    return;
  }
  if (pickerState.kind === 'hotkeyApplication') {
    const application = pickerState.rows[pickerState.selectedIndex - 1];
    if (application && application.path) {
      post({ type: 'selectHotkeyApplicationPath', path: application.path });
    } else {
      post({ type: 'hotkeyPickerTrace', stage: 'selected_path_missing', index: pickerState.selectedIndex });
    }
    return;
  }
  post({ type: 'selectWindowPicker', index: pickerState.selectedIndex });
}

function setStatus(text, error = false) {
  const node = $('#status');
  node.textContent = text || '';
  node.classList.toggle('error', !!error);
}
function markDirty(sectionName = '', key = '') {
  const value = true;
  state.dirty = value;
  if (sectionName && key) state.dirtyFields.add(sectionName + '\u0000' + key);
  if (value) setStatus('未保存');
}
function markPluginsDirty() {
  state.pluginsDirty = true;
  state.dirty = true;
  setStatus('未保存');
}
function setDraftValue(sectionName, key, value) {
  if (!state.draft.sections[sectionName]) state.draft.sections[sectionName] = {};
  state.draft.sections[sectionName][key] = value;
  markDirty(sectionName, key);
}
function readControl(node) {
  return node.type === 'checkbox' ? (node.checked ? '1' : '0') : node.value;
}
function translationLanguageLabel(entry) {
  return entry.labelZh;
}
function setSettingsLoaded(loaded) {
  $$('[data-section][data-key]').forEach(node => { node.disabled = !loaded; });
  $('#saveBtn').disabled = !loaded;
}
function setTranslationLanguageCatalog(value) {
  if (!Array.isArray(value) || value.length === 0) return false;
  const seen = new Set();
  const catalog = [];
  for (const entry of value) {
    if (!entry || typeof entry !== 'object') return false;
    const code = String(entry.code ?? '').trim();
    const labelZh = String(entry.labelZh ?? '').trim();
    const labelEn = String(entry.labelEn ?? '').trim();
    const key = code.toLowerCase();
    if (!/^[a-z]{2,8}(?:-[a-z0-9]{1,8})*$/i.test(code) || key === 'system'
        || !labelZh || !labelEn || seen.has(key)) return false;
    seen.add(key);
    catalog.push({ code, labelZh, labelEn });
  }
  translationLanguageCodes = catalog.map(entry => entry.code);
  translationLanguageByCode = new Map(catalog.map(entry => [entry.code.toLowerCase(), entry]));
  $$('select[data-translation-language-select]').forEach(select => {
    const previous = select.value;
    const options = [];
    if (select.hasAttribute('data-language-select')) {
      const system = document.createElement('option');
      system.value = 'system';
      system.textContent = document.documentElement.lang === 'en' ? 'System language' : '系统语言';
      options.push(system);
    }
    for (const entry of catalog) {
      const option = document.createElement('option');
      option.value = entry.code;
      option.textContent = translationLanguageLabel(entry);
      options.push(option);
    }
    select.replaceChildren(...options);
    if (options.some(option => option.value === previous)) select.value = previous;
    select.disabled = false;
  });
  return true;
}
function normalizeTranslationLanguage(value, fallback = '') {
  const raw = String(value ?? '').trim().toLowerCase();
  const match = translationLanguageByCode.get(raw);
  return match ? match.code : fallback;
}
function normalizeTargetLanguageValue(value) {
  const raw = String(value ?? '').trim();
  return raw.toLowerCase() === 'system' ? 'system' : normalizeTranslationLanguage(raw, 'system');
}
function normalizeTranslationModeValue(value) {
  return String(value ?? '').trim().toLowerCase() === 'bidirectional' ? 'bidirectional' : 'fixed';
}
function normalizePairLanguageValue(value, fallback) {
  return normalizeTranslationLanguage(value, normalizeTranslationLanguage(fallback,
    translationLanguageCodes[0] || ''));
}
function updateTranslateModeFields() {
  const mode = normalizeTranslationModeValue(section('TTranslate').mode);
  const pairFields = $('#bidirectionalLanguageFields');
  const fixedField = $('#fixedTargetLanguageField');
  if (pairFields) pairFields.hidden = mode !== 'bidirectional';
  if (fixedField) fixedField.hidden = mode === 'bidirectional';
}
function updateLanguageSelectLabels() {
  $$('select[data-translation-language-select] option').forEach(option => {
    const entry = translationLanguageByCode.get(option.value.toLowerCase());
    option.textContent = option.value === 'system'
      ? (document.documentElement.lang === 'en' ? 'System language' : '系统语言')
      : entry ? translationLanguageLabel(entry) : option.value;
  });
}
function writeControl(node) {
  const rawValue = section(node.dataset.section)[node.dataset.key] ?? '';
  const value = node.hasAttribute('data-language-select') ? normalizeTargetLanguageValue(rawValue) : rawValue;
  if (node.type === 'checkbox') node.checked = value !== '' && value !== '0';
  else node.value = value;
}
function bindStaticControls() {
  $$('[data-section][data-key]').forEach(node => {
    const update = () => {
      setDraftValue(node.dataset.section, node.dataset.key, readControl(node));
      if (node.dataset.section === 'TTranslate' && node.dataset.key === 'mode')
        updateTranslateModeFields();
    };
    node.addEventListener('input', update);
    node.addEventListener('change', update);
  });
}
function refreshStaticControls() {
  $$('[data-section][data-key]').forEach(writeControl);
  updateTranslateModeFields();
}

function prettyKey(key) {
  const names = { backquote: '`', leftSquareBracket: '[', rightSquareBracket: ']', backslash: '\\', semicolon: ';', quote: "'", comma: ',', dot: '.', slash: '/', space: 'Space', ralt: 'RAlt', minus: '-', equal: '=' };
  if (key === 'press_caps') return 'CapsLock 点按';
  let prefix = 'CapsLock';
  let suffix = key.slice(5);
  if (key.startsWith('caps_lalt_')) { prefix += ' + Alt'; suffix = key.slice(10); }
  else if (key.startsWith('caps_')) suffix = key.slice(5);
  return prefix + ' + ' + (names[suffix] || suffix.toUpperCase());
}
const SHORTCUT_GROUPS = [
  { id: 'press', label: 'CapsLock 点按' },
  { id: 'move', label: '移动' },
  { id: 'select', label: '选中' },
  { id: 'edit', label: '编辑' },
  { id: 'clipboard', label: '剪贴板' },
  { id: 'window', label: '窗口' },
  { id: 'tools', label: '工具' },
  { id: 'mouse', label: '鼠标' },
  { id: 'other', label: '其他' }
];
function shortcutActionName(action) {
  return String(action || '').trim().replace(/\s*\(.*/, '').toLowerCase();
}
const ACTION_LABELS = {
  '@block': '禁用动作', '@native': '保留应用原键',
  keyFunc_doNothing: '无操作', keyFunc_toggleCapsLock: '切换大小写', keyFunc_send: '自定义', keyFunc_run: '运行程序',
  keyFunc_mouseSpeedIncrease: '提高鼠标速度', keyFunc_mouseSpeedDecrease: '降低鼠标速度',
  keyFunc_moveLeft: '向左移动', keyFunc_moveRight: '向右移动', keyFunc_moveUp: '向上移动', keyFunc_moveDown: '向下移动',
  keyFunc_moveWordLeft: '按词向左移动', keyFunc_moveWordRight: '按词向右移动',
  keyFunc_backspace: '退格', keyFunc_delete: '删除字符', keyFunc_deleteAll: '删除全部', keyFunc_deleteWord: '删除单词',
  keyFunc_forwardDeleteWord: '向后删除单词', keyFunc_end: '移动到行尾', keyFunc_home: '移动到行首',
  keyFunc_moveToPageBeginning: '移动到页面开头', keyFunc_moveToPageEnd: '移动到页面末尾', keyFunc_deleteLine: '删除整行',
  keyFunc_deleteToLineBeginning: '删除到行首', keyFunc_deleteToLineEnd: '删除到行尾',
  keyFunc_deleteToPageBeginning: '删除到页面开头', keyFunc_deleteToPageEnd: '删除到页面末尾',
  keyFunc_enterWherever: '在任意位置回车', keyFunc_esc: '退出 / 取消', keyFunc_enter: '回车',
  keyFunc_doubleChar: '输入成对字符', keyFunc_sendChar: '发送字符', keyFunc_doubleAngle: '输入尖括号', keyFunc_doubleQuote: '输入双引号',
  keyFunc_pageUp: '向上翻页', keyFunc_pageDown: '向下翻页', keyFunc_pageMoveUp: '切换到上一个页面', keyFunc_pageMoveDown: '切换到下一个页面',
  keyFunc_switchClipboard: '切换粘贴来源', keyFunc_pasteSystem: '粘贴系统剪贴板', keyFunc_cut_1: '剪切到剪贴板 1',
  keyFunc_copy_1: '复制到剪贴板 1', keyFunc_paste_1: '粘贴剪贴板 1', keyFunc_cut_2: '剪切到剪贴板 2',
  keyFunc_copy_2: '复制到剪贴板 2', keyFunc_paste_2: '粘贴剪贴板 2', keyFunc_undoRedo: '撤销 / 重做',
  keyFunc_tabPrve: '切换到上一个标签页', keyFunc_tabNext: '切换到下一个标签页', keyFunc_jumpPageTop: '跳到页面顶部',
  keyFunc_jumpPageBottom: '跳到页面底部', keyFunc_qbar: '打开 qbar', keyFunc_clipboardHistory: '打开剪贴板历史', keyFunc_translate: '打开翻译',
  keyFunc_editSelectedText: '编辑并复制选中文字', keyFunc_tabHotString: '执行 Tab 替换', keyFunc_openCpasDocs: '打开使用介绍',
  keyFunc_openSettings: '打开设置中心', keyFunc_reload: '重新加载配置', keyFunc_mediaPrev: '上一首媒体',
  keyFunc_mediaNext: '下一首媒体', keyFunc_mediaPlayPause: '播放 / 暂停媒体', keyFunc_volumeUp: '增大音量',
  keyFunc_volumeDown: '减小音量', keyFunc_volumeMute: '静音', keyFunc_winbind_activate: '激活绑定窗口',
  keyFunc_winbind_binding: '绑定窗口 / 窗口组 / 应用', keyFunc_winPin: '切换窗口置顶', keyFunc_winTransparent: '切换窗口透明度',
  keyFunc_selectUp: '向上选中', keyFunc_selectDown: '向下选中', keyFunc_selectLeft: '向左选中', keyFunc_selectRight: '向右选中',
  keyFunc_selectHome: '选中到行首', keyFunc_selectEnd: '选中到行尾', keyFunc_selectToPageBeginning: '选中到页面开头',
  keyFunc_selectToPageEnd: '选中到页面末尾', keyFunc_selectCurrentWord: '选中当前词', keyFunc_selectCurrentLine: '选中当前行',
  keyFunc_selectWordLeft: '按词向左选中', keyFunc_selectWordRight: '按词向右选中', keyFunc_pageMoveLineUp: '按行向上翻页',
  keyFunc_pageMoveLineDown: '按行向下翻页', keyFunc_goCjkPage: '切换中日韩页面', keyFunc_click_left: '鼠标左键',
  keyFunc_click_right: '鼠标右键', keyFunc_mouse_up: '鼠标向上移动', keyFunc_mouse_down: '鼠标向下移动',
  keyFunc_mouse_left: '鼠标向左移动', keyFunc_mouse_right: '鼠标向右移动', keyFunc_wheel_up: '鼠标滚轮向上',
  keyFunc_wheel_down: '鼠标滚轮向下'
};
function shortcutActionLabel(action) {
  const raw = String(action || '').trim();
  if (raw === '@block') return '禁用动作';
  if (raw === '@native') return '保留应用原键';
  const match = raw.match(/^([A-Za-z0-9_]+)(?:\((.*)\))?$/);
  if (!match || !ACTION_LABELS[match[1]]) return '自定义动作';
  const name = match[1];
  const args = (match[2] || '').trim();
  if (!args) return ACTION_LABELS[name];
  if (name === 'keyFunc_send') return '自定义：' + ahkSendLabel(args);
  if (name === 'keyFunc_winbind_activate' || name === 'keyFunc_winbind_binding')
    return ACTION_LABELS[name] + ' ' + args;
  return ACTION_LABELS[name] + '（' + args + '）';
}
function ahkSendLabel(value) {
  const raw = String(value || '').trim();
  let index = 0;
  const modifiers = [];
  const modifierNames = { '^': 'Ctrl', '!': 'Alt', '+': 'Shift', '#': 'Win' };
  while (modifierNames[raw[index]]) modifiers.push(modifierNames[raw[index++]]);
  let key = raw.slice(index);
  const namedKeys = {
    '{Space}': 'Space', '{Enter}': 'Enter', '{Tab}': 'Tab', '{Esc}': 'Esc', '{Backspace}': 'Backspace',
    '{Delete}': 'Delete', '{Insert}': 'Insert', '{Home}': 'Home', '{End}': 'End', '{PgUp}': 'PageUp',
    '{PgDn}': 'PageDown', '{Up}': 'Up', '{Down}': 'Down', '{Left}': 'Left', '{Right}': 'Right'
  };
  key = namedKeys[key] || (key.startsWith('{') && key.endsWith('}') ? key.slice(1, -1) : key);
  if (key.length === 1) key = key.toUpperCase();
  return modifiers.concat(key || '按键').join('+');
}
function shortcutActionCategory(action) {
  const name = shortcutActionName(action);
  if (name === 'keyfunc_togglecapslock') return 'press';
  if (/(^|_)select/.test(name)) return 'select';
  if (/(^|_)(move|home|end|pageup|pagedown|jump)/.test(name)) return 'move';
  if (/(^|_)(copy|cut|paste|switchclipboard|clipboardhistory)/.test(name)) return 'clipboard';
  if (/(^|_)(delete|backspace|forwarddelete|enter|double|sendchar|editselectedtext)/.test(name)) return 'edit';
  if (/(^|_)(winbind|wintransparent|winpin)/.test(name)) return 'window';
  if (/(^|_)(qbar|translate|dictionary|opencpasdocs|reload|tabhotstring)/.test(name)) return 'tools';
  if (/(^|_)(mousespeed|click|mouse|wheel)/.test(name)) return 'mouse';
  return 'other';
}
function shortcutActionGroups(values, allowNative = true) {
  const current = Object.values(values).filter(Boolean);
  const baseActions = Object.keys(ACTION_LABELS).filter(action => allowNative || action !== '@native');
  const actions = [...new Set(current.concat(baseActions))];
  const grouped = new Map(SHORTCUT_GROUPS.map(group => [group.id, []]));
  for (const action of actions) {
    const groupId = shortcutActionCategory(action);
    if (!grouped.has(groupId)) grouped.set(groupId, []);
    grouped.get(groupId).push(action);
  }
  return SHORTCUT_GROUPS
    .map(group => ({ ...group, actions: grouped.get(group.id) || [] }))
    .filter(group => group.actions.length);
}
function stopShortcutRecording(notifyHost = true) {
  if (!shortcutRecording) return;
  if (notifyHost) post({ type: 'stopShortcutRecording', captureId: shortcutRecording.captureId });
  shortcutRecording.button.classList.remove('recording');
  shortcutRecording.button.textContent = '录制';
  shortcutRecording = null;
}
function ensureShortcutOption(select, action) {
  if ([...select.options].some(option => option.value === action)) return;
  const option = document.createElement('option');
  option.value = action;
  option.textContent = shortcutActionLabel(action);
  select.append(option);
}
window.receiveShortcutCapture = function (capture) {
  if (!shortcutRecording || !capture || !capture.value
    || Number(capture.captureId) !== shortcutRecording.captureId) return;
  if (shortcutRecording.kind === 'custom') {
    if (shortcutRecording.field === 'trigger') {
      shortcutRecording.input.value = capture.label || formatCustomTrigger(capture.value);
      updateCustomHotkeyKey(shortcutRecording.row, shortcutRecording.input, true);
    } else {
      shortcutRecording.input.value = capture.label || formatCustomSend(capture.value);
      shortcutRecording.row.dataset.sendValue = normalizeCustomSend(capture.value);
      if (shortcutRecording.row.dataset.key) {
        setShortcutDraftValue('CustomHotkey', shortcutRecording.row.dataset.key,
          customHotkeyActionValue(shortcutRecording.row));
        syncCustomHotkeyRemove(shortcutRecording.row);
      }
    }
    stopShortcutRecording(false);
    setStatus('已录制 ' + (capture.label || capture.value) + '，请保存');
    return;
  }
  const action = 'keyFunc_send(' + capture.value + ')';
  ensureShortcutOption(shortcutRecording.select, action);
  shortcutRecording.select.value = action;
  setShortcutDraftValue('Keys', shortcutRecording.key, action);
  syncShortcutRestoreButton(
    shortcutRecording.select.closest('.shortcut-row'), 'Keys', shortcutRecording.key);
  stopShortcutRecording(false);
  setStatus('已录制 ' + (capture.label || capture.value) + '，请保存');
};
window.shortcutCaptureFailed = function (capture) {
  if (!shortcutRecording || !capture
    || Number(capture.captureId) !== shortcutRecording.captureId) return;
  stopShortcutRecording(false);
  setStatus(document.documentElement.lang === 'en'
    ? 'Could not start shortcut recording. Try again.'
    : '无法启动按键录制，请重试。', true);
};
window.addEventListener('blur', stopShortcutRecording);
function shortcutCategory(key, action) {
  if (key === 'press_caps') return 'press';
  const name = shortcutActionName(action);
  if (/(^|_)select/.test(name)) return 'select';
  if (/(^|_)(move|home|end|pageup|pagedown)/.test(name)) return 'move';
  if (/(^|_)(copy|cut|paste|switchclipboard|clipboardhistory)/.test(name)) return 'clipboard';
  if (/(^|_)(delete|backspace|forwarddelete|enter|editselectedtext)/.test(name)) return 'edit';
  if (/(^|_)(winbind|wintransparent|winpin)/.test(name)) return 'window';
  if (/(^|_)(qbar|translate|dictionary|opencpasdocs|reload|tabscript)/.test(name)) return 'tools';
  if (/(^|_)mousespeed/.test(name)) return 'mouse';
  return 'other';
}
function applyShortcutFilter(updateShortcutGroups = true) {
  const query = ($('#shortcutFilter')?.value || '').trim().toLowerCase();
  const onlyOverrides = !!hotkeyProfile() && state.overridesOnly;
  let visibleShortcutCount = 0;
  const shortcutRoot = $('#shortcutList');
  if (updateShortcutGroups) {
    $$('.shortcut-group', shortcutRoot).forEach(group => {
      let matchCount = 0;
      $$('.shortcut-row', group).forEach(row => {
        const matched = (!query || row.dataset.label.includes(query))
          && (!onlyOverrides || row.dataset.overridden === 'true');
        row.hidden = !matched;
        if (matched) matchCount++, visibleShortcutCount++;
      });
      group.hidden = matchCount === 0;
      group.open = !!query && matchCount > 0;
      const count = $('.shortcut-group-count', group);
      if (count) count.textContent = String(matchCount) + ' 项';
    });
    let shortcutEmpty = $('.shortcut-empty', shortcutRoot);
    if (!visibleShortcutCount) {
      if (!shortcutEmpty) {
        shortcutEmpty = document.createElement('div');
        shortcutEmpty.className = 'shortcut-empty';
        shortcutRoot.append(shortcutEmpty);
      }
      shortcutEmpty.textContent = query ? '没有匹配的快捷键'
        : onlyOverrides ? '此应用没有修改过的快捷键' : '没有可用的快捷键';
    } else if (shortcutEmpty) shortcutEmpty.remove();
  }

  const customRoot = $('#customHotkeyList');
  const customRows = $$('.custom-hotkey-row', customRoot);
  const visibleCustomCount = customRows.filter(row => {
    const matched = !onlyOverrides || row.dataset.overridden === 'true';
    row.hidden = !matched;
    return matched;
  }).length;
  let customFilterEmpty = $('.custom-hotkey-filter-empty', customRoot);
  if (onlyOverrides && customRows.length && !visibleCustomCount) {
    if (!customFilterEmpty) {
      customFilterEmpty = document.createElement('div');
      customFilterEmpty.className = 'custom-hotkey-filter-empty';
      customRoot.append(customFilterEmpty);
    }
    customFilterEmpty.textContent = '此应用没有修改过的自定义快捷键';
  } else if (customFilterEmpty) customFilterEmpty.remove();
  const customEmpty = $('.custom-hotkey-empty', customRoot);
  if (customEmpty)
    customEmpty.textContent = onlyOverrides ? '此应用没有自定义快捷键修改项' : '尚未添加自定义快捷键';
}
function syncShortcutRestoreButton(row, sectionName, key) {
  if (!row) return;
  const overridden = shortcutOverrideExists(sectionName, key);
  row.dataset.overridden = overridden ? 'true' : 'false';
  if (!hotkeyProfile()) return;
  const actions = row.querySelector('.shortcut-row-actions');
  if (!actions) return;
  let restore = actions.querySelector('.shortcut-restore');
  if (overridden) {
    if (restore) return;
    restore = document.createElement('button');
    restore.type = 'button';
    restore.className = 'btn ghost mini shortcut-record shortcut-restore';
    restore.textContent = '恢复继承';
    restore.addEventListener('click', () => {
      removeShortcutDraftValue(sectionName, key);
      renderHotkeyEditor();
    });
    actions.append(restore);
  } else if (restore) {
    restore.remove();
  }
}
function renderShortcuts(preserveExpandedGroups = true) {
  stopShortcutRecording();
  const root = $('#shortcutList');
  const filterQuery = ($('#shortcutFilter')?.value || '').trim();
  const expandedGroups = preserveExpandedGroups && !filterQuery
    ? new Set($$('.shortcut-group[open]', root).map(group => group.dataset.group))
    : new Set();
  root.replaceChildren();
  const values = shortcutSection('Keys');
  const actionGroups = shortcutActionGroups(values, false);
  const grouped = new Map(SHORTCUT_GROUPS.map(group => [group.id, []]));
  for (const key of Object.keys(values)) {
    const groupId = shortcutCategory(key, values[key]);
    if (!grouped.has(groupId)) grouped.set(groupId, []);
    grouped.get(groupId).push({ key, action: values[key] });
  }
  for (const group of SHORTCUT_GROUPS) {
    const entries = grouped.get(group.id) || [];
    if (!entries.length) continue;
    entries.sort((a, b) => prettyKey(a.key).localeCompare(prettyKey(b.key)));

    const details = document.createElement('details');
    details.className = 'shortcut-group';
    details.dataset.group = group.id;
    const summary = document.createElement('summary');
    summary.appendChild(createIcon('chevron-right', 'summary-icon'));
    const title = document.createElement('span');
    title.textContent = group.label;
    const count = document.createElement('span');
    count.className = 'shortcut-group-count';
    count.textContent = String(entries.length) + ' 项';
    summary.append(title, count);
    const list = document.createElement('div');
    list.className = 'shortcut-group-list';

    for (const entry of entries) {
      const row = document.createElement('div');
      row.className = 'shortcut-row';
      row.dataset.label = (prettyKey(entry.key) + ' ' + shortcutActionLabel(entry.action) + ' ' + entry.action + ' ' + group.label).toLowerCase();
      const label = document.createElement('span');
      label.className = 'shortcut-label';
      label.title = prettyKey(entry.key);
      label.textContent = prettyKey(entry.key);
      const select = document.createElement('select');
      for (const group of actionGroups) {
        const optgroup = document.createElement('optgroup');
        optgroup.label = group.label;
        for (const action of group.actions) {
          const option = document.createElement('option');
          option.value = action;
          option.textContent = shortcutActionLabel(action);
          optgroup.append(option);
        }
        select.append(optgroup);
      }
      select.value = entry.action || 'keyFunc_doNothing';
      select.addEventListener('change', () => {
        setShortcutDraftValue('Keys', entry.key, select.value);
        syncShortcutRestoreButton(row, 'Keys', entry.key);
      });
      const actionButtons = document.createElement('div');
      actionButtons.className = 'shortcut-row-actions';
      const record = document.createElement('button');
      record.type = 'button';
      record.className = 'btn mini shortcut-record';
      record.textContent = '录制';
      record.title = '录制按键组合';
      record.addEventListener('click', () => {
        if (shortcutRecording && shortcutRecording.button === record) {
          stopShortcutRecording();
          setStatus('已取消录制');
          return;
        }
        stopShortcutRecording();
        const captureId = ++shortcutCaptureSequence;
        shortcutRecording = { key: entry.key, select, button: record, captureId };
        record.classList.add('recording');
        record.textContent = '按键…';
        setStatus('按下要录制的快捷键');
        post({ type: 'startShortcutRecording', key: entry.key, captureId });
      });
      actionButtons.append(record);
      row.append(label, select, actionButtons);
      syncShortcutRestoreButton(row, 'Keys', entry.key);
      list.append(row);
    }
    details.append(summary, list);
    root.append(details);
  }
  applyShortcutFilter();
  if (!filterQuery)
    $$('.shortcut-group', root).forEach(group => {
      group.open = expandedGroups.has(group.dataset.group);
    });
  refreshIcons();
}
function updateCustomHotkeyKey(row, triggerInput, formatValue = false) {
  const oldKey = row.dataset.key;
  const newKey = normalizeCustomTrigger(triggerInput.value);
  let suffix = newKey;
  while (suffix && '^!+#'.includes(suffix[0])) suffix = suffix.slice(1);
  if (formatValue && suffix) triggerInput.value = formatCustomTrigger(newKey);
  if (oldKey && oldKey !== newKey) {
    removeShortcutDraftValue('CustomHotkey', oldKey);
  }
  row.dataset.key = newKey;
  if (newKey) {
    setShortcutDraftValue('CustomHotkey', newKey, customHotkeyActionValue(row));
  }
  syncCustomHotkeyRemove(row);
}
function customHotkeyActionValue(row) {
  if (row.dataset.mode === 'native') return '@native';
  if (row.dataset.mode === 'block') return '@block';
  return row.dataset.sendValue || '';
}
function updateCustomHotkeyMode(row, modeSelect, sendInput, sendRecord) {
  const previousMode = row.dataset.mode || 'send';
  const mode = modeSelect.value;
  if (shortcutRecording && shortcutRecording.row === row && mode !== 'send')
    stopShortcutRecording();
  if (previousMode === 'send') row.dataset.sendValue = normalizeCustomSend(sendInput.value);
  row.dataset.mode = mode;
  const isSending = mode === 'send';
  sendInput.disabled = !isSending;
  sendInput.value = isSending
    ? formatCustomSend(row.dataset.sendValue || '')
    : mode === 'native' ? '保留原有功能' : '已禁用此快捷键';
  sendInput.placeholder = isSending ? '例如 Ctrl+C' : '';
  sendRecord.disabled = !isSending;
  if (row.dataset.key)
    setShortcutDraftValue('CustomHotkey', row.dataset.key, customHotkeyActionValue(row));
  syncCustomHotkeyRemove(row);
}
function syncCustomHotkeyRemove(row) {
  const remove = row.querySelector('.custom-hotkey-remove');
  const profile = hotkeyProfile();
  const overridden = !!row.dataset.key && shortcutOverrideExists('CustomHotkey', row.dataset.key);
  row.dataset.overridden = !profile || !row.dataset.key || overridden ? 'true' : 'false';
  if (remove) remove.hidden = !!profile && !!row.dataset.key && !overridden;
}
function startCustomHotkeyRecording(row, input, field, button) {
  if (shortcutRecording && shortcutRecording.button === button) {
    stopShortcutRecording();
    setStatus('已取消录制');
    return;
  }
  stopShortcutRecording();
  const captureId = ++shortcutCaptureSequence;
  shortcutRecording = { kind: 'custom', row, input, field, button, captureId };
  button.classList.add('recording');
  button.textContent = '按键…';
  setStatus('按下要录制的快捷键');
  post({ type: 'startShortcutRecording', key: 'custom', captureId });
}
function addCustomHotkeyRow(root, initialTrigger = '', initialSend = '') {
  root.querySelector('.custom-hotkey-empty')?.remove();
  const row = document.createElement('div');
  row.className = 'pair-row custom-hotkey-row';
  row.dataset.key = normalizeCustomTrigger(initialTrigger);
  row.dataset.mode = initialSend === '@native' ? 'native'
    : initialSend === '@block' ? 'block' : 'send';
  row.dataset.sendValue = row.dataset.mode === 'send' ? normalizeCustomSend(initialSend) : '';

  const triggerField = document.createElement('div');
  triggerField.className = 'custom-hotkey-field';
  const triggerLabel = document.createElement('span');
  triggerLabel.textContent = '触发键';
  const triggerControl = document.createElement('div');
  triggerControl.className = 'custom-hotkey-control';
  const triggerInput = document.createElement('input');
  triggerInput.value = formatCustomTrigger(initialTrigger);
  triggerInput.placeholder = '例如 Alt+C';
  triggerInput.setAttribute('aria-label', '触发键');
  const triggerRecord = document.createElement('button');
  triggerRecord.type = 'button';
  triggerRecord.className = 'btn ghost custom-hotkey-record';
  triggerRecord.textContent = '录制';
  triggerRecord.title = '录制触发键';
  triggerRecord.addEventListener('click', () =>
    startCustomHotkeyRecording(row, triggerInput, 'trigger', triggerRecord));
  triggerControl.append(triggerInput, triggerRecord);
  triggerField.append(triggerLabel, triggerControl);

  const sendField = document.createElement('div');
  sendField.className = 'custom-hotkey-field';
  const sendLabel = document.createElement('span');
  sendLabel.textContent = '快捷键行为';
  const sendControl = document.createElement('div');
  sendControl.className = 'custom-hotkey-control';
  const modeSelect = document.createElement('select');
  modeSelect.className = 'custom-hotkey-mode';
  modeSelect.setAttribute('aria-label', '快捷键行为');
  [['send', '发送按键'], ['native', '保留原功能'], ['block', '禁用快捷键']].forEach(([value, label]) => {
    const option = document.createElement('option');
    option.value = value;
    option.textContent = label;
    modeSelect.append(option);
  });
  modeSelect.value = row.dataset.mode;
  const sendInput = document.createElement('input');
  sendInput.value = row.dataset.mode === 'send' ? formatCustomSend(initialSend)
    : row.dataset.mode === 'native' ? '保留原有功能' : '已禁用此快捷键';
  sendInput.placeholder = row.dataset.mode === 'send' ? '例如 Ctrl+C' : '';
  sendInput.disabled = row.dataset.mode !== 'send';
  sendInput.setAttribute('aria-label', '发送按键');
  const sendRecord = document.createElement('button');
  sendRecord.type = 'button';
  sendRecord.className = 'btn ghost custom-hotkey-record';
  sendRecord.textContent = '录制';
  sendRecord.title = '录制发送键';
  sendRecord.disabled = row.dataset.mode !== 'send';
  sendRecord.addEventListener('click', () =>
    startCustomHotkeyRecording(row, sendInput, 'send', sendRecord));
  modeSelect.addEventListener('change', () =>
    updateCustomHotkeyMode(row, modeSelect, sendInput, sendRecord));
  sendControl.append(modeSelect, sendInput, sendRecord);
  sendField.append(sendLabel, sendControl);

  const remove = document.createElement('button');
  remove.className = 'icon-btn custom-hotkey-remove';
  remove.type = 'button';
  remove.appendChild(createIcon('x'));
  remove.title = '删除自定义快捷键';
  remove.setAttribute('aria-label', '删除自定义快捷键');
  remove.addEventListener('click', () => {
    const root = row.parentElement;
    const hadTrigger = !!row.dataset.key;
    if (row.dataset.key) {
      removeShortcutDraftValue('CustomHotkey', row.dataset.key);
    }
    if (shortcutRecording && shortcutRecording.row === row) stopShortcutRecording();
    row.remove();
    if (hadTrigger || !root.querySelector('.custom-hotkey-row')) renderCustomHotkeys();
  });

  triggerInput.addEventListener('input', () => {
    state.dirty = true;
    setStatus('未保存');
  });
  triggerInput.addEventListener('change', () => updateCustomHotkeyKey(row, triggerInput, true));
  sendInput.addEventListener('input', () => {
    row.dataset.sendValue = normalizeCustomSend(sendInput.value);
    if (row.dataset.key) {
      setShortcutDraftValue('CustomHotkey', row.dataset.key, customHotkeyActionValue(row));
      syncCustomHotkeyRemove(row);
    }
  });
  row.append(triggerField, sendField, remove);
  root.append(row);
  syncCustomHotkeyRemove(row);
  refreshIcons();
  return row;
}
function renderCustomHotkeys() {
  const root = $('#customHotkeyList');
  root.replaceChildren();
  const entries = Object.entries(shortcutSection('CustomHotkey'))
    .filter(([trigger, action]) => String(trigger).trim() && String(action).trim());
  if (!entries.length) {
    const empty = document.createElement('div');
    empty.className = 'custom-hotkey-empty';
    empty.textContent = '尚未添加自定义快捷键';
    root.append(empty);
    applyShortcutFilter(false);
    return;
  }
  entries.forEach(([trigger, send]) => addCustomHotkeyRow(root, trigger, send));
  applyShortcutFilter(false);
}
function renderPairs(sectionName, rootId, multiline = false) {
  const root = $('#' + rootId);
  root.replaceChildren();
  const values = section(sectionName);
  const entries = Object.entries(values);
  if (!entries.length) entries.push(['', '']);
  entries.forEach(([key, value]) => addPairRow(sectionName, root, key, value, multiline));
}
function qbarToolCommands(plugin) {
  return plugin && Array.isArray(plugin.commands) ? plugin.commands : [];
}
function qbarToolVisible(plugin) {
  if (!plugin) return false;
  if (plugin.definitionId === 'builtin.search' || plugin.definitionId === 'builtin.run') return true;
  if (plugin.source && plugin.source !== 'builtin') return true;
  return qbarToolCommands(plugin).some(command =>
    Array.isArray(command.aliases) && command.aliases.some(alias => String(alias || '').trim()));
}
function qbarToolGroup(plugin) {
  if (plugin.definitionId === 'builtin.search') return 'search';
  if (plugin.definitionId === 'builtin.run') return 'run';
  return 'builtin';
}
function qbarToolName(plugin) {
  return String(plugin.name || '').trim() || '未命名工具';
}
function qbarToolCommandText(plugin) {
  const aliases = [];
  qbarToolCommands(plugin).forEach(command => (command.aliases || []).forEach(alias => {
    const value = String(alias || '').trim();
    if (value && !aliases.includes(value)) aliases.push(value);
  }));
  if (aliases.length) return aliases.join(' / ');
  return plugin.source && plugin.source !== 'builtin'
    || plugin.definitionId === 'builtin.search' || plugin.definitionId === 'builtin.run'
    ? '使用工具名称' : '未设置命令';
}
function qbarToolEnabled(plugin) {
  return plugin.enabled !== false && qbarToolCommands(plugin).some(command => command.enabled !== false);
}
function renderQbarToolAliases(command, root) {
  command.aliases = Array.isArray(command.aliases) ? command.aliases : [];
  root.replaceChildren();
  command.aliases.forEach((alias, index) => {
    const wrap = document.createElement('span'); wrap.className = 'plugin-alias';
    const input = document.createElement('input'); input.value = alias; input.setAttribute('aria-label', '命令别名');
    input.addEventListener('input', () => { command.aliases[index] = input.value.trim(); });
    const remove = document.createElement('button');
    remove.type = 'button'; remove.className = 'icon-btn'; remove.title = '删除别名';
    remove.appendChild(createIcon('x'));
    remove.addEventListener('click', () => {
      command.aliases.splice(index, 1);
      renderQbarToolAliases(command, root);
    });
    wrap.append(input, remove); root.append(wrap);
  });
  const add = document.createElement('button'); add.type = 'button'; add.className = 'btn mini'; add.textContent = '添加别名';
  add.addEventListener('click', () => { command.aliases.push(''); renderQbarToolAliases(command, root); });
  root.append(add);
}
function openQbarToolDialog(plugin) {
  state.qbarPluginDraft = clone(plugin);
  state.qbarPluginToolSettings = clone(plugin.toolSettings || {});
  state.qbarPluginSaving = false;
  state.qbarPluginDialog = AppDialog.open({
    title: qbarToolName(plugin) + '设置',
    actions: [
      { id: 'cancel', text: '取消', role: 'cancel', kind: 'ghost' },
      { id: 'save', text: '保存' }
    ],
    render(root) { renderQbarToolDialog(root); },
    onAction(id, api) {
      if (id === 'save') {
        saveQbarToolDialog(api);
        return api.keepOpen();
      }
    },
    onClose() {
      state.qbarPluginDraft = null;
      state.qbarPluginToolSettings = {};
      state.qbarPluginSaving = false;
      state.qbarPluginDialog = null;
    }
  });
}
function closeQbarToolDialog() {
  const dialog = state.qbarPluginDialog;
  state.qbarPluginDialog = null;
  if (dialog) dialog.close({ action: 'cancel' });
  state.qbarPluginDraft = null;
  state.qbarPluginToolSettings = {};
  state.qbarPluginSaving = false;
}
function openQbarDeleteDialog(plugin) {
  if (!plugin || !plugin.deletable) return;
  state.qbarDeleteTarget = { pluginId: plugin.pluginId, name: qbarToolName(plugin) };
  state.qbarDeleteSaving = false;
  state.qbarDeleteDialog = AppDialog.open({
    title: '删除工具',
    className: 'qbar-delete-dialog',
    message: `确定删除“${state.qbarDeleteTarget.name}”吗？删除后会从 Qbar 工具列表移除。`,
    actions: [
      { id: 'cancel', text: '取消', role: 'cancel', kind: 'ghost' },
      { id: 'delete', text: '删除', kind: 'danger' }
    ],
    onAction(id, api) {
      if (id === 'delete') {
        confirmQbarPluginDelete(api);
        return api.keepOpen();
      }
    },
    onClose() {
      state.qbarDeleteTarget = null;
      state.qbarDeleteSaving = false;
      state.qbarDeleteDialog = null;
    }
  });
}
function confirmQbarPluginDelete(dialog = state.qbarDeleteDialog) {
  const target = state.qbarDeleteTarget;
  if (!target || state.qbarDeleteSaving || !dialog) return;
  state.qbarDeleteSaving = true;
  dialog.setError('');
  dialog.setBusy(true, '删除中…', 'delete');
  post({ type: 'deleteQbarPlugin', pluginId: target.pluginId });
}
function qbarCreateSetError(message = '') {
  if (state.qbarCreateDialog) state.qbarCreateDialog.setError(message);
}
function closeQbarCreateDialog() {
  const dialog = state.qbarCreateDialog;
  state.qbarCreateDialog = null;
  if (dialog) dialog.close({ action: 'cancel' });
  state.qbarCreateKind = '';
  state.qbarCreateDraft = null;
  state.qbarCreateSaving = false;
  qbarCreateSetError('');
}
function qbarCreateField(labelText, value, placeholder, wide, onInput) {
  const field = document.createElement('label');
  field.className = 'field' + (wide ? ' wide' : '');
  const label = document.createElement('span'); label.textContent = labelText;
  const input = document.createElement('input');
  input.value = value || ''; input.placeholder = placeholder || '';
  input.addEventListener('input', () => onInput(input.value));
  field.append(label, input);
  return { field, input };
}
function openQbarCreateDialog(kind) {
  kind = kind === 'run' ? 'run' : 'search';
  const search = kind === 'search';
  state.qbarCreateKind = kind;
  state.qbarCreateDraft = {
    displayName: search ? '新搜索' : '新项目',
    aliases: [],
    settings: search
      ? { template: 'https://www.google.com/search?q={q}', encodeQuery: true }
      : { command: '', runAs: false, argumentMode: 'append' }
  };
  state.qbarCreateSaving = false;
  state.qbarCreateDialog = AppDialog.open({
    title: search ? '添加网页搜索' : '添加快捷命令',
    initialFocus: 'content',
    actions: [
      { id: 'cancel', text: '取消', role: 'cancel', kind: 'ghost' },
      { id: 'create', text: '添加' }
    ],
    render(root) { renderQbarCreateDialog(root); },
    onAction(id, api) {
      if (id === 'create') {
        saveQbarCreateDialog(api);
        return api.keepOpen();
      }
    },
    onClose() {
      state.qbarCreateKind = '';
      state.qbarCreateDraft = null;
      state.qbarCreateSaving = false;
      state.qbarCreateDialog = null;
    }
  });
}
function renderQbarCreateDialog(editor) {
  const draft = state.qbarCreateDraft;
  if (!draft) return;
  const search = state.qbarCreateKind === 'search';
  qbarCreateSetError('');
  editor.replaceChildren();

  const general = document.createElement('div'); general.className = 'grid';
  const name = qbarCreateField('工具名称', draft.displayName, search ? '例如：百度' : '例如：开发命令', false,
    value => { draft.displayName = value; });
  name.input.autofocus = true;
  general.append(name.field);
  editor.append(general);

  const detail = document.createElement('div'); detail.className = 'plugin-detail-section';
  const title = document.createElement('strong'); title.textContent = search ? '搜索设置' : '命令设置';
  const hint = document.createElement('div'); hint.className = 'hint';
  hint.textContent = search ? '使用 {q} 代表用户输入的搜索内容。' : '命令会在输入别名后执行，搜索内容会作为参数追加。';
  const grid = document.createElement('div'); grid.className = 'grid';
  if (search) {
    const template = qbarCreateField('搜索网址模板', draft.settings.template,
      'https://example.com/search?q={q}', true, value => { draft.settings.template = value; });
    grid.append(template.field);
    const encodeField = document.createElement('label'); encodeField.className = 'check';
    const encode = document.createElement('input'); encode.type = 'checkbox'; encode.checked = draft.settings.encodeQuery !== false;
    encode.addEventListener('change', () => { draft.settings.encodeQuery = encode.checked; });
    encodeField.append(encode, document.createTextNode('编码搜索内容')); grid.append(encodeField);
  } else {
    const command = qbarCreateField('执行命令或程序路径', draft.settings.command, '例如：code.exe', true,
      value => { draft.settings.command = value; });
    grid.append(command.field);
    const runAsField = document.createElement('label'); runAsField.className = 'check';
    const runAs = document.createElement('input'); runAs.type = 'checkbox'; runAs.checked = !!draft.settings.runAs;
    runAs.addEventListener('change', () => { draft.settings.runAs = runAs.checked; });
    runAsField.append(runAs, document.createTextNode('以管理员身份运行')); grid.append(runAsField);
  }
  detail.append(title, hint, grid); editor.append(detail);

  const aliasSection = document.createElement('div'); aliasSection.className = 'plugin-detail-section';
  const aliasTitle = document.createElement('strong'); aliasTitle.textContent = '命令别名（可选）';
  const aliasHint = document.createElement('div'); aliasHint.className = 'hint';
  aliasHint.textContent = '可以添加多个别名；不添加别名时，Qbar 会使用工具名称匹配。';
  const aliasList = document.createElement('div'); aliasList.className = 'plugin-alias-list';
  renderQbarToolAliases({ aliases: draft.aliases }, aliasList);
  aliasSection.append(aliasTitle, aliasHint, aliasList);
  editor.append(aliasSection);
  refreshIcons();
}
function saveQbarCreateDialog(dialog = state.qbarCreateDialog) {
  const draft = state.qbarCreateDraft;
  if (!draft || state.qbarCreateSaving || !dialog) return;
  draft.displayName = String(draft.displayName || '').trim();
  draft.aliases = [...new Set((draft.aliases || [])
    .map(alias => String(alias || '').trim()).filter(Boolean))];
  if (!draft.displayName) return qbarCreateSetError('请输入工具名称。');
  if (state.qbarCreateKind === 'search') {
    draft.settings.template = draft.settings.template == null ? '' : String(draft.settings.template).trim();
    if (!draft.settings.template.includes('{q}'))
      return qbarCreateSetError('搜索网址模板必须包含 {q}。');
  } else {
    draft.settings.command = draft.settings.command == null ? '' : String(draft.settings.command).trim();
    if (!draft.settings.command)
      return qbarCreateSetError('请输入执行命令或程序路径。');
  }

  state.qbarCreateSaving = true;
  dialog.setBusy(true, '添加中…', 'create');
  qbarCreateSetError('');
  post({ type: 'createPlugin', kind: state.qbarCreateKind, displayName: draft.displayName,
    aliases: draft.aliases, settings: clone(draft.settings) });
}
function applySavedQbarPluginToDraft() {
  if (!state.qbarPluginDraft || !state.draft) return;
  const saved = clone(state.qbarPluginDraft);
  saved.toolSettings = clone(state.qbarPluginToolSettings || {});
  (saved.commands || []).forEach(command => {
    command.aliases = [...new Set((command.aliases || [])
      .map(alias => String(alias || '').trim()).filter(Boolean))];
  });
  const plugins = Array.isArray(state.draft.plugins) ? state.draft.plugins : (state.draft.plugins = []);
  const index = plugins.findIndex(item => item && item.pluginId === saved.pluginId);
  if (index >= 0) plugins[index] = saved;
  else plugins.push(saved);
  const basePlugins = Array.isArray(state.basePlugins) ? state.basePlugins : (state.basePlugins = []);
  const baseIndex = basePlugins.findIndex(item => item && item.pluginId === saved.pluginId);
  if (baseIndex >= 0) basePlugins[baseIndex] = clone(saved);
  else basePlugins.push(clone(saved));
  renderPlugins();
  recomputeDirtyState();
  if (!state.dirty) setStatus('');
}
function renderQbarSchemaSettings(plugin, editor, title, hintText = '') {
  const schema = plugin.settingsSchema || {};
  const settings = plugin.settings || (plugin.settings = {});
  const entries = Object.entries(schema);
  if (!entries.length) return;

  const sectionRoot = document.createElement('div'); sectionRoot.className = 'plugin-detail-section';
  const sectionTitle = document.createElement('strong'); sectionTitle.textContent = title;
  const grid = document.createElement('div'); grid.className = 'grid';
  entries.forEach(([key, field]) => {
    const value = Object.hasOwn(settings, key) ? settings[key] : field.default;
    if (!Object.hasOwn(settings, key)) settings[key] = value;
    if (field.type === 'boolean') {
      const checkField = document.createElement('label'); checkField.className = 'check';
      const input = document.createElement('input'); input.type = 'checkbox';
      input.checked = value === true || value === 1 || value === '1' || value === 'true';
      input.addEventListener('change', () => { settings[key] = input.checked; });
      checkField.append(input, document.createTextNode(field.label || key)); grid.append(checkField);
    } else if (field.type === 'integer') {
      const scale = Math.max(1, Number(field.displayScale) || 1);
      const settingField = document.createElement('label'); settingField.className = 'field';
      const label = document.createElement('span'); label.textContent = field.label || key;
      const input = document.createElement('input'); input.type = 'number';
      if (field.min != null) input.min = String(Number(field.min) / scale);
      if (field.max != null) input.max = String(Number(field.max) / scale);
      if (field.step != null) input.step = String(Number(field.step) / scale);
      input.value = value == null ? '' : String(Number(value) / scale);
      input.addEventListener('input', () => {
        const number = input.value.trim() === '' ? NaN : Number(input.value);
        settings[key] = Number.isFinite(number) ? number * scale : '';
      });
      settingField.append(label, input); grid.append(settingField);
    }
  });
  sectionRoot.append(sectionTitle, grid);
  if (hintText) {
    const hint = document.createElement('div'); hint.className = 'hint'; hint.textContent = hintText;
    sectionRoot.append(hint);
  }
  editor.append(sectionRoot);
}

function renderQbarToolDialog(editor) {
  const plugin = state.qbarPluginDraft;
  if (!plugin) return;
  editor.replaceChildren();
  const general = document.createElement('div'); general.className = 'grid';
  const nameField = document.createElement('label'); nameField.className = 'field';
  const nameLabel = document.createElement('span'); nameLabel.textContent = '工具名称';
  const nameInput = document.createElement('input'); nameInput.value = qbarToolName(plugin);
  nameInput.addEventListener('input', () => { plugin.name = nameInput.value; });
  nameField.append(nameLabel, nameInput); general.append(nameField);
  const enabledField = document.createElement('label'); enabledField.className = 'check';
  const enabled = document.createElement('input'); enabled.type = 'checkbox'; enabled.checked = plugin.enabled !== false;
  enabled.addEventListener('change', () => { plugin.enabled = enabled.checked; });
  enabledField.append(enabled, document.createTextNode('启用工具')); general.append(enabledField);
  editor.append(general);
  if (plugin.definitionValid === false || plugin.settingsValid === false) {
    const warning = document.createElement('div'); warning.className = 'hint';
    warning.textContent = plugin.definitionValid === false
      ? '此工具当前无法使用，请重新启动应用后重试。'
      : '此工具的设置无效，已暂停使用。请检查设置后重新启用。';
    editor.append(warning);
  }

  const settings = plugin.settings || (plugin.settings = {});
  if (plugin.definitionId === 'builtin.clipboard') {
    renderQbarSchemaSettings(plugin, editor, '剪贴板历史设置',
      '“启用工具”控制 Qbar 入口；此处控制自动记录、容量和清理策略。收藏和置顶项不参与到期清理，数据保存在安装目录 data\\clipboard-history。');
  } else if (plugin.definitionId === 'builtin.search') {
    const sectionRoot = document.createElement('div'); sectionRoot.className = 'plugin-detail-section';
    const sectionTitle = document.createElement('strong'); sectionTitle.textContent = '搜索设置';
    const grid = document.createElement('div'); grid.className = 'grid';
    const templateField = document.createElement('label'); templateField.className = 'field wide';
    const templateLabel = document.createElement('span'); templateLabel.textContent = '搜索网址模板';
    const template = document.createElement('input');
    template.value = settings.template || ''; template.placeholder = 'https://example.com/search?q={q}';
    template.addEventListener('input', () => { settings.template = template.value; });
    templateField.append(templateLabel, template); grid.append(templateField);
    const encodeField = document.createElement('label'); encodeField.className = 'check';
    const encode = document.createElement('input'); encode.type = 'checkbox'; encode.checked = settings.encodeQuery !== false;
    encode.addEventListener('change', () => { settings.encodeQuery = encode.checked; });
    encodeField.append(encode, document.createTextNode('编码搜索内容')); grid.append(encodeField);
    sectionRoot.append(sectionTitle, grid); editor.append(sectionRoot);
  } else if (plugin.definitionId === 'builtin.run') {
    const sectionRoot = document.createElement('div'); sectionRoot.className = 'plugin-detail-section';
    const sectionTitle = document.createElement('strong'); sectionTitle.textContent = '命令设置';
    const grid = document.createElement('div'); grid.className = 'grid';
    const commandField = document.createElement('label'); commandField.className = 'field wide';
    const commandLabel = document.createElement('span'); commandLabel.textContent = '执行命令';
    const commandInput = document.createElement('input'); commandInput.value = settings.command || '';
    commandInput.addEventListener('input', () => { settings.command = commandInput.value; });
    commandField.append(commandLabel, commandInput); grid.append(commandField);
    const runAsField = document.createElement('label'); runAsField.className = 'check';
    const runAs = document.createElement('input'); runAs.type = 'checkbox'; runAs.checked = !!settings.runAs;
    runAs.addEventListener('change', () => { settings.runAs = runAs.checked; });
    runAsField.append(runAs, document.createTextNode('以管理员身份运行')); grid.append(runAsField);
    sectionRoot.append(sectionTitle, grid); editor.append(sectionRoot);
  }
  if (plugin.pluginId === 'builtin.everything') {
    const sectionRoot = document.createElement('div'); sectionRoot.className = 'plugin-detail-section';
    const sectionTitle = document.createElement('strong'); sectionTitle.textContent = '文件搜索设置';
    const field = document.createElement('label'); field.className = 'field';
    const label = document.createElement('span'); label.textContent = '最多结果数';
    const input = document.createElement('input'); input.type = 'number'; input.min = '1'; input.max = '500';
    input.value = state.qbarPluginToolSettings.esMaxResults ?? 50;
    input.addEventListener('input', () => { state.qbarPluginToolSettings.esMaxResults = input.value; });
    field.append(label, input); sectionRoot.append(sectionTitle, field); editor.append(sectionRoot);
  }

  const commandSection = document.createElement('div'); commandSection.className = 'plugin-detail-section';
  const commandTitle = document.createElement('strong'); commandTitle.textContent = '命令';
  const commandHint = document.createElement('div'); commandHint.className = 'hint';
  commandHint.textContent = qbarToolCommandText(plugin) === '使用工具名称'
    ? '未设置别名时，Qbar 会使用工具名称匹配。'
    : '输入这些别名后，Qbar 会执行当前工具。';
  commandSection.append(commandTitle, commandHint);
  qbarToolCommands(plugin).forEach(command => {
    const aliasList = document.createElement('div'); aliasList.className = 'plugin-alias-list';
    renderQbarToolAliases(command, aliasList); commandSection.append(aliasList);
  });
  editor.append(commandSection);
  refreshIcons();
}
function saveQbarToolDialog(dialog = state.qbarPluginDialog) {
  const plugin = state.qbarPluginDraft;
  if (!plugin || state.qbarPluginSaving || !dialog) return;
  const payloadPlugin = clone(plugin);
  delete payloadPlugin.toolSettings;
  (payloadPlugin.commands || []).forEach(command => {
    command.aliases = [...new Set((command.aliases || []).map(alias => String(alias || '').trim()).filter(Boolean))];
  });
  state.qbarPluginSaving = true;
  dialog.setBusy(true, '保存中…', 'save');
  post({ type: 'saveQbarPlugin', plugin: payloadPlugin, toolSettings: clone(state.qbarPluginToolSettings || {}) });
}
function renderQbarToolTable(title, group, plugins) {
  const card = document.createElement('section'); card.className = 'qbar-plugin-table-card';
  const head = document.createElement('div'); head.className = 'qbar-plugin-table-head';
  const heading = document.createElement('h3'); heading.textContent = title; head.append(heading);
  if (group === 'search' || group === 'run') {
    const add = document.createElement('button'); add.type = 'button'; add.className = 'btn mini';
    add.textContent = group === 'search' ? '添加搜索' : '添加快捷命令';
    add.addEventListener('click', () => createPlugin(group));
    head.append(add);
  }
  card.append(head);
  const wrap = document.createElement('div'); wrap.className = 'qbar-plugin-table-wrap';
  const table = document.createElement('table'); table.className = 'qbar-plugin-table';
  const thead = document.createElement('thead'); const headRow = document.createElement('tr');
  ['名称', '命令', '状态', '操作'].forEach(text => { const cell = document.createElement('th'); cell.textContent = text; headRow.append(cell); });
  thead.append(headRow); table.append(thead);
  const tbody = document.createElement('tbody');
  if (!plugins.length) {
    const row = document.createElement('tr'); const cell = document.createElement('td');
    cell.colSpan = 4; cell.className = 'empty'; cell.textContent = '暂无工具'; row.append(cell); tbody.append(row);
  } else {
    plugins.forEach(plugin => {
      const row = document.createElement('tr');
      const name = document.createElement('td'); name.className = 'tool-name'; name.textContent = qbarToolName(plugin);
      const command = document.createElement('td'); command.className = 'tool-command'; command.textContent = qbarToolCommandText(plugin);
      const enabled = qbarToolEnabled(plugin);
      const status = document.createElement('td'); status.className = 'tool-status' + (enabled ? '' : ' off');
      status.textContent = enabled ? '已启用' : '已停用';
      const actions = document.createElement('td');
      if (plugin.deletable) {
        const remove = document.createElement('button');
        remove.type = 'button'; remove.className = 'btn mini qbar-plugin-delete';
        remove.title = '删除' + qbarToolName(plugin);
        remove.setAttribute('aria-label', remove.title);
        remove.append(createIcon('trash-2'), document.createTextNode('删除'));
        remove.addEventListener('click', event => {
          event.stopPropagation();
          openQbarDeleteDialog(plugin);
        });
        actions.append(remove);
      } else {
        actions.className = 'tool-action-empty';
        actions.textContent = '—';
        actions.title = '核心内置工具不可删除';
      }
      row.append(name, command, status, actions);
      row.addEventListener('click', () => openQbarToolDialog(plugin));
      tbody.append(row);
    });
  }
  table.append(tbody); wrap.append(table); card.append(wrap);
  return card;
}
function renderPlugins() {
  const root = $('#qbarPluginTables');
  if (!root) return;
  root.replaceChildren();
  const plugins = ((state.draft && state.draft.plugins) || []).filter(qbarToolVisible);
  [['内置工具', 'builtin'], ['网页搜索', 'search'], ['快捷命令', 'run']].forEach(([title, group]) => {
    root.append(renderQbarToolTable(title, group, plugins.filter(plugin => qbarToolGroup(plugin) === group)));
  });
}
function addPairRow(sectionName, root, initialKey = '', initialValue = '', multiline = false) {
  const row = document.createElement('div');
  row.className = 'pair-row';
  row.dataset.key = initialKey;
  const keyInput = document.createElement('input'); keyInput.value = initialKey; keyInput.placeholder = '键';
  const valueInput = document.createElement(multiline ? 'textarea' : 'input'); valueInput.value = initialValue; valueInput.placeholder = '值';
  const remove = document.createElement('button'); remove.className = 'icon-btn'; remove.type = 'button'; remove.appendChild(createIcon('x'));
  row.append(keyInput, valueInput, remove); root.append(row); refreshIcons();
  const updateKey = () => {
    const oldKey = row.dataset.key;
    const newKey = keyInput.value.trim();
    if (oldKey && oldKey !== newKey) {
      state.draft.sections[sectionName][oldKey] = '';
      markDirty(sectionName, oldKey);
    }
    row.dataset.key = newKey;
    if (newKey) {
      state.draft.sections[sectionName][newKey] = valueInput.value;
      markDirty(sectionName, newKey);
    }
  };
  keyInput.addEventListener('input', updateKey);
  valueInput.addEventListener('input', () => {
    if (row.dataset.key) {
      state.draft.sections[sectionName][row.dataset.key] = valueInput.value;
      markDirty(sectionName, row.dataset.key);
    }
  });
  remove.addEventListener('click', () => {
    if (row.dataset.key) {
      state.draft.sections[sectionName][row.dataset.key] = '';
      markDirty(sectionName, row.dataset.key);
    }
    row.remove();
  });
}
function renderBindings() {
  const root = $('#bindingList'); root.replaceChildren();
  const modes = new Map((state.bindingModes || []).map(mode => [String(mode.id), mode]));
  for (const binding of (state.draft.bindings || [])) {
    const card = document.createElement('div'); card.className = 'binding-card';
    const head = document.createElement('div'); head.className = 'binding-head';
    const title = document.createElement('span'); title.className = 'binding-number';
    title.textContent = 'CapsLock + ' + (binding.number === 10 ? '0' : binding.number);
    const mode = modes.get(String(binding.bindType));
    const select = document.createElement('select');
    select.innerHTML = [...modes.entries()].map(([value, item]) =>
      `<option value="${value}">${item.label}</option>`).join('');
    select.value = mode ? String(binding.bindType) : '1';
    const actions = document.createElement('div'); actions.className = 'binding-actions';
    const renderActions = () => {
      actions.replaceChildren();
      if (select.value === '3') {
        const selectOpenApplication = document.createElement('button');
        selectOpenApplication.type = 'button'; selectOpenApplication.className = 'btn'; selectOpenApplication.textContent = '选择已打开应用';
        selectOpenApplication.addEventListener('click', () => post({ type: 'selectOpenApplication', number: binding.number, bindType: 3 }));
        const selectOtherApplication = document.createElement('button');
        selectOtherApplication.type = 'button'; selectOtherApplication.className = 'btn'; selectOtherApplication.textContent = '选择其他应用';
        selectOtherApplication.addEventListener('click', () => post({ type: 'selectOtherApplication', number: binding.number, bindType: 3 }));
        actions.append(selectOpenApplication, selectOtherApplication);
      } else {
        const selectWindow = document.createElement('button');
        selectWindow.type = 'button'; selectWindow.className = 'btn';
        selectWindow.textContent = select.value === '2' ? '添加已打开窗口' : '绑定已打开窗口';
        selectWindow.addEventListener('click', () => post({ type: 'selectOpenWindow', number: binding.number, bindType: Number(select.value) }));
        actions.append(selectWindow);
      }
    };
    head.append(title, select, actions); card.append(head);
    const modeHint = document.createElement('div'); modeHint.className = 'binding-mode-hint'; card.append(modeHint);
    const updateModeHint = () => { modeHint.textContent = (modes.get(select.value) || modes.get('1')).description; };
    select.addEventListener('change', () => { updateModeHint(); renderActions(); });
    updateModeHint();
    renderActions();
    const items = document.createElement('div'); items.className = 'binding-items';
    if (binding.items && binding.items.length) {
      const applicationNames = [...new Set(binding.items.map(windowApplicationName).filter(Boolean))];
      const fullText = binding.items.map(item => [item.title, item.exe, item.windowClass].filter(Boolean).join(' · ')).join('\n');
      applicationNames.forEach(name => {
        const line = document.createElement('div');
        line.textContent = name;
        line.title = fullText;
        items.append(line);
      });
    } else if (binding.applicationPath) {
      items.textContent = applicationName(binding.applicationPath);
      items.title = binding.applicationPath;
    } else items.textContent = '未绑定';
    card.append(items); root.append(card);
  }
}
function closeHotkeyApplicationDialog() {
  const dialog = state.hotkeyApplicationDialog;
  state.hotkeyApplicationDialog = null;
  if (dialog) dialog.close({ action: 'cancel' });
}
function hotkeyProfileLabel(profile) {
  return String(profile && (profile.displayName || profile.exePath) || '应用');
}
function createGlobalHotkeyRow() {
  const row = document.createElement('tr');
  row.className = 'hotkey-global-row' + (state.hotkeyProfileId ? '' : ' selected');

  const description = document.createElement('td');
  const name = document.createElement('div');
  name.className = 'hotkey-app-name';
  const title = document.createElement('strong');
  title.textContent = '全局';
  const spacer = document.createElement('span');
  spacer.className = 'hotkey-app-path';
  spacer.setAttribute('aria-hidden', 'true');
  name.append(title, spacer);
  description.append(name);

  const status = document.createElement('td');
  status.className = 'hotkey-app-status';
  status.textContent = state.hotkeyProfileId ? '默认配置' : '当前配置';
  row.append(description, status, document.createElement('td'));
  row.addEventListener('click', () => {
    const previousProfileId = state.hotkeyProfileId;
    state.hotkeyProfileId = '';
    renderHotkeyEditor(previousProfileId);
    closeHotkeyApplicationDialog();
  });
  return row;
}
function createHotkeyApplicationRow(profile, root) {
  const row = document.createElement('tr');
  row.className = String(profile.id) === String(state.hotkeyProfileId) ? 'selected' : '';

  const appCell = document.createElement('td');
  const appName = document.createElement('div');
  appName.className = 'hotkey-app-name';
  const name = document.createElement('strong');
  name.textContent = hotkeyProfileLabel(profile);
  const path = document.createElement('span');
  path.className = 'hotkey-app-path';
  path.textContent = profile.exePath || '';
  appName.append(name, path);
  appCell.append(appName);

  const statusCell = document.createElement('td');
  const enabled = String(profile.enabled) === '1';
  const status = document.createElement('span');
  status.className = 'hotkey-app-status' + (enabled ? '' : ' off');
  status.textContent = enabled ? '已启用' : '已禁用';
  statusCell.append(status);

  const actionsCell = document.createElement('td');
  const actions = document.createElement('div');
  actions.className = 'hotkey-app-actions';

  const remove = document.createElement('button');
  remove.type = 'button';
  remove.className = 'btn ghost';
  remove.textContent = '删除';
  remove.addEventListener('click', event => {
    event.stopPropagation();
    closeHotkeyApplicationDialog();
    AppDialog.confirm({
      title: '删除应用配置',
      message: '确定删除“' + hotkeyProfileLabel(profile) + '”的快捷键配置吗？',
      confirmText: '删除',
      tone: 'danger'
    }).then(confirmed => {
      if (confirmed) {
        const previousProfileId = state.hotkeyProfileId;
        state.draft.profiles = state.draft.profiles.filter(item => String(item.id) !== String(profile.id));
        if (String(state.hotkeyProfileId) === String(profile.id)) state.hotkeyProfileId = '';
        markHotkeyProfileDirty();
        if (String(previousProfileId || '') !== String(state.hotkeyProfileId || ''))
          renderHotkeyEditor(previousProfileId);
      }
      openHotkeyApplicationDialog();
    });
  });

  const toggle = document.createElement('button');
  toggle.type = 'button';
  toggle.className = 'btn ghost';
  toggle.textContent = enabled ? '禁用' : '启用';
  toggle.addEventListener('click', event => {
    event.stopPropagation();
    profile.enabled = enabled ? '0' : '1';
    markHotkeyProfileDirty();
    renderHotkeyScope();
    renderHotkeyApplicationRows(root);
  });

  actions.append(remove, toggle);
  actionsCell.append(actions);
  row.append(appCell, statusCell, actionsCell);
  row.addEventListener('click', () => {
    const previousProfileId = state.hotkeyProfileId;
    state.hotkeyProfileId = String(profile.id);
    renderHotkeyEditor(previousProfileId);
    closeHotkeyApplicationDialog();
  });
  return row;
}
function renderHotkeyApplicationRows(root) {
  if (!root || !state.draft) return;
  root.replaceChildren();
  const profiles = Array.isArray(state.draft.profiles) ? state.draft.profiles : [];
  const description = document.createElement('p');
  description.className = 'picker-description';
  description.textContent = '选择要编辑的范围。';
  const count = document.createElement('span');
  count.className = 'picker-count';
  count.textContent = profiles.length + ' 个应用';
  const meta = document.createElement('div');
  meta.className = 'picker-dialog-meta';
  meta.append(description, count);

  const tableWrap = document.createElement('div');
  tableWrap.className = 'picker-table-wrap';
  const table = document.createElement('table');
  table.className = 'picker-table';
  const head = document.createElement('thead');
  const headRow = document.createElement('tr');
  ['应用', '状态', '操作'].forEach(label => {
    const cell = document.createElement('th');
    cell.textContent = label;
    headRow.append(cell);
  });
  head.append(headRow);
  const body = document.createElement('tbody');
  body.append(createGlobalHotkeyRow());
  profiles.forEach(profile => body.append(createHotkeyApplicationRow(profile, root)));
  table.append(head, body);
  const empty = document.createElement('div');
  empty.className = 'picker-empty';
  empty.textContent = '还没有添加应用。';
  empty.classList.toggle('visible', profiles.length === 0);
  tableWrap.append(table, empty);
  root.append(meta, tableWrap);
}
function openHotkeyApplicationDialog() {
  if (!state.draft || state.hotkeyApplicationDialog) return;
  let dialog;
  dialog = AppDialog.open({
    title: '应用范围',
    size: 'wide',
    className: 'picker-dialog hotkey-application-dialog',
    actions: [
      { id: 'cancel', text: '关闭', role: 'cancel', kind: 'ghost' },
      { id: 'open', text: '选择已打开应用', kind: 'secondary' },
      { id: 'add', text: '从文件选择' }
    ],
    render(root) { renderHotkeyApplicationRows(root); },
    onAction(id, api) {
      if (id === 'open' || id === 'add') {
        post({ type: id === 'open' ? 'selectHotkeyOpenApplication' : 'selectHotkeyApplication' });
        return api.keepOpen();
      }
    },
    onClose() {
      if (state.hotkeyApplicationDialog === dialog) state.hotkeyApplicationDialog = null;
    }
  });
  state.hotkeyApplicationDialog = dialog;
}
window.openHotkeyApplicationDialog = openHotkeyApplicationDialog;
function renderHotkeyScope() {
  const profile = hotkeyProfile();
  const button = $('#hotkeyScopeButton');
  const overridesButton = $('#hotkeyOverridesOnly');
  const name = $('#hotkeyScopeName');
  const status = $('#hotkeyScopeStatus');
  if (!button || !name || !status) return;
  const label = profile ? hotkeyProfileLabel(profile) : '全局';
  const disabled = !!profile && String(profile.enabled) !== '1';
  name.textContent = label;
  status.hidden = !disabled;
  overridesButton.hidden = !profile;
  overridesButton.setAttribute('aria-pressed', profile && state.overridesOnly ? 'true' : 'false');
  button.setAttribute('aria-label', '选择快捷键范围，当前为' + label
    + (disabled ? '，已停用' : ''));
}
window.hotkeyApplicationSelected = function (profile) {
  if (!profile || !profile.id || !profile.exePath || !state.draft) {
    post({ type: 'hotkeyPickerTrace', stage: 'profile_callback_invalid' });
    return;
  }
  const profiles = Array.isArray(state.draft.profiles) ? state.draft.profiles : [];
  const previousProfileId = state.hotkeyProfileId;
  const existing = profiles.find(item => String(item.id) === String(profile.id)
    || String(item.exePath || '').toLowerCase() === String(profile.exePath || '').toLowerCase());
  if (existing) profile = existing;
  else profiles.push(clone(profile));
  state.draft.profiles = profiles;
  state.hotkeyProfileId = String(profile.id);
  if (!existing) markHotkeyProfileDirty();
  renderHotkeyEditor(previousProfileId); closeHotkeyApplicationDialog();
  post({ type: 'hotkeyPickerTrace', stage: 'profile_applied' });
};
function renderHotkeyEditor(previousProfileId = state.hotkeyProfileId) {
  const sameScope = String(previousProfileId || '') === String(state.hotkeyProfileId || '');
  renderHotkeyScope();
  renderCustomHotkeys();
  renderShortcuts(sameScope);
}
function renderAll(previousProfileId = state.hotkeyProfileId) {
  refreshStaticControls();
  renderHotkeyEditor(previousProfileId);
  renderPairs('TabHotString', 'tabList', true);
  renderPlugins();
  renderBindings();
}
function setPage(page, syncHost = true) {
  if (page !== 'shortcuts') stopShortcutRecording();
  state.page = page;
  $$('.nav button').forEach(button => button.classList.toggle('active', button.dataset.page === page));
  $$('.page').forEach(node => node.classList.toggle('active', node.dataset.pageView === page));
  const active = $(`.nav button[data-page="${page}"]`);
  $('#pageTitle').textContent = active ? active.textContent : '设置';
  if (syncHost) post({ type: 'setSettingsPage', page });
}
function showToast(message, type = 'info') { AppToast.show(message, type); }
function buildLlmTest() {
  return Object.assign({ type: 'testSettings', target: 'llm' }, section('LLM'));
}
function buildTranslationTest(target) {
  const shared = section('TTranslate'), youdao = section('TYoudao'), volcengine = section('TVolcengine');
  if (target === 'youdao') return {
    type: 'testSettings', target,
    appId: youdao.appPaidID || '', appKey: youdao.appPaidKey || '',
    targetLanguage: shared.targetLanguage || ''
  };
  return {
    type: 'testSettings', target,
    volcAccessKey: volcengine.accessKey || '', volcSecretKey: volcengine.secretKey || '',
    targetLanguage: shared.targetLanguage || '', volcRegion: volcengine.region || ''
  };
}
function receiveSnapshot(snapshot) {
  if (state.dirty && state.draft) {
    setStatus('外部配置已变化；请保存当前修改或取消后重新载入', true);
    return;
  }
  state.pendingSaveSections.clear();
  if (!setTranslationLanguageCatalog(snapshot && snapshot.languageCatalog)) {
    setSettingsLoaded(false);
    setStatus('语言选项加载失败，请重新打开设置。', true);
    return;
  }
  setSettingsLoaded(true);
  const selectedProfileId = state.hotkeyProfileId;
  closeHotkeyApplicationDialog();
  const sections = clone(snapshot.sections);
  sections.Keys = clone(snapshot.keys || sections.Keys);
  if (!sections.TTranslate) sections.TTranslate = {};
  sections.TTranslate.mode = normalizeTranslationModeValue(sections.TTranslate.mode);
  sections.TTranslate.languageA = normalizePairLanguageValue(sections.TTranslate.languageA, 'zh-CN');
  sections.TTranslate.languageB = normalizePairLanguageValue(sections.TTranslate.languageB, 'en');
  sections.TTranslate.targetLanguage = normalizeTargetLanguageValue(
    sections.TTranslate.targetLanguage);
  state.baseSections = sections;
  state.baseProfiles = clone(snapshot.profiles || []);
  state.basePlugins = clone(snapshot.plugins || []);
  state.baseProfileStamp = String(snapshot.profileStamp || '');
  state.bindingModes = clone(snapshot.bindingModes || []);
  const profiles = clone(snapshot.profiles || []);
  state.hotkeyProfileId = profiles.some(profile => String(profile.id) === String(selectedProfileId))
    ? selectedProfileId : '';
  state.profilesDirty = false;
  state.draft = {
    sections: clone(sections), bindings: clone(snapshot.bindings),
    plugins: clone(snapshot.plugins || []), profiles
  };
  state.dirtyFields.clear();
  state.pluginsDirty = false;
  document.documentElement.lang = snapshot.uiLanguage === 'en' ? 'en' : 'zh-CN';
  updateLanguageSelectLabels();
  renderAll(selectedProfileId);
  setPage(snapshot.page || state.page || 'general', false);
  state.dirty = false; setStatus('');
  if (snapshot.toast) showToast(snapshot.toast);
}

function applySettingsSaveReceipt(receipt, submittedSections = undefined) {
  if (!receipt || typeof receipt !== 'object' || !state.draft) return;
  let baselineChanged = false;
  let profilesChanged = false;
  let pluginsChanged = false;
  let tabHotStringsChanged = false;
  let hotkeyKeysChanged = false;
  let customHotkeysChanged = false;
  let translateModeChanged = false;
  const controlsToRefresh = new Set();
  if (Array.isArray(receipt.bindings)) {
    const bindings = clone(receipt.bindings);
    const bindingModes = clone(receipt.bindingModes || []);
    const bindingsChanged = JSON.stringify(state.draft.bindings || []) !== JSON.stringify(bindings)
      || JSON.stringify(state.bindingModes || []) !== JSON.stringify(bindingModes);
    state.draft.bindings = bindings;
    state.bindingModes = bindingModes;
    if (bindingsChanged) renderBindings();
  }
  if (receipt.uiLanguage) {
    document.documentElement.lang = receipt.uiLanguage === 'en' ? 'en' : 'zh-CN';
    updateLanguageSelectLabels();
  }
  if (receipt.sectionsCommitted && receipt.sections && typeof receipt.sections === 'object') {
    const oldBase = state.baseSections || {};
    const sections = clone(receipt.sections);
    sections.Keys = clone(receipt.keys || sections.Keys || {});
    if (sections.TTranslate) {
      sections.TTranslate.mode = normalizeTranslationModeValue(sections.TTranslate.mode);
      sections.TTranslate.languageA = normalizePairLanguageValue(sections.TTranslate.languageA, 'zh-CN');
      sections.TTranslate.languageB = normalizePairLanguageValue(sections.TTranslate.languageB, 'en');
      sections.TTranslate.targetLanguage = normalizeTargetLanguageValue(
        sections.TTranslate.targetLanguage);
    }
    Object.keys(sections).forEach(sectionName => {
      const previous = oldBase[sectionName] || {};
      const current = state.draft.sections[sectionName]
        || (state.draft.sections[sectionName] = {});
      const committed = sections[sectionName] || {};
      const keys = new Set([...Object.keys(previous), ...Object.keys(committed)]);
      keys.forEach(key => {
        const oldValue = String(previous[key] ?? '');
        const committedValue = String(committed[key] ?? '');
        if (oldValue !== committedValue) {
          if (sectionName === 'TabHotString') tabHotStringsChanged = true;
          else if (sectionName === 'Keys') hotkeyKeysChanged = true;
          else if (sectionName === 'CustomHotkey') customHotkeysChanged = true;
          else if (sectionName === 'TTranslate' && key === 'mode') translateModeChanged = true;
        }
        const submitted = submittedSections && submittedSections[sectionName];
        if (submitted && Object.hasOwn(submitted, key)) {
          if (String(current[key] ?? '') !== String(submitted[key] ?? '')) return;
        } else if (String(current[key] ?? '') !== oldValue) return;
        if (Object.hasOwn(committed, key)) current[key] = committed[key];
        else delete current[key];
        controlsToRefresh.add(sectionName + '\u0000' + key);
      });
    });
    state.baseSections = sections;
    baselineChanged = true;
  }
  if (receipt.profilesCommitted && Array.isArray(receipt.profiles)) {
    state.baseProfiles = clone(receipt.profiles);
    state.baseProfileStamp = String(receipt.profileStamp || '');
    baselineChanged = true;
    profilesChanged = true;
  }
  if (receipt.pluginsCommitted && Array.isArray(receipt.plugins)) {
    state.basePlugins = clone(receipt.plugins);
    baselineChanged = true;
    pluginsChanged = true;
  }
  if (receipt.toolSettingsCommitted && receipt.toolSettings) {
    let toolSettingsChanged = false;
    [state.draft.plugins, state.basePlugins].forEach(plugins => {
      const plugin = (plugins || []).find(item => item && item.pluginId === 'builtin.everything');
      if (!plugin) return;
      if (JSON.stringify(plugin.toolSettings || {}) !== JSON.stringify(receipt.toolSettings))
        toolSettingsChanged = true;
      plugin.toolSettings = clone(receipt.toolSettings);
    });
    baselineChanged = true;
    pluginsChanged = pluginsChanged || toolSettingsChanged;
  }
  if (baselineChanged) {
    recomputeDirtyState();
    if (controlsToRefresh.size) {
      $$('[data-section][data-key]').forEach(node => {
        if (controlsToRefresh.has(node.dataset.section + '\u0000' + node.dataset.key))
          writeControl(node);
      });
    }
    if (translateModeChanged) updateTranslateModeFields();
    if (tabHotStringsChanged) renderPairs('TabHotString', 'tabList', true);
    if (profilesChanged) renderHotkeyEditor();
    else if (hotkeyKeysChanged) renderShortcuts();
    if (customHotkeysChanged && !profilesChanged) renderCustomHotkeys();
    if (pluginsChanged) renderPlugins();
  }
}

function recomputeDirtyState() {
  const changes = buildChangedSections();
  state.dirtyFields.clear();
  Object.entries(changes).forEach(([sectionName, values]) => {
    Object.keys(values).forEach(key => state.dirtyFields.add(sectionName + '\u0000' + key));
  });
  state.profilesDirty = JSON.stringify((state.draft && state.draft.profiles) || [])
    !== JSON.stringify(state.baseProfiles || []);
  state.pluginsDirty = JSON.stringify((state.draft && state.draft.plugins) || [])
    !== JSON.stringify(state.basePlugins || []);
  state.dirty = state.dirtyFields.size > 0 || state.profilesDirty || state.pluginsDirty;
  return state.dirty;
}

function buildChangedSections() {
  const changes = {};
  const baseSections = state.baseSections || {};
  const draftSections = (state.draft && state.draft.sections) || {};
  const names = new Set([...Object.keys(baseSections), ...Object.keys(draftSections)]);
  for (const sectionName of names) {
    const before = baseSections[sectionName] || {};
    const after = draftSections[sectionName] || {};
    const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
    for (const key of keys) {
      const oldValue = String(before[key] ?? '');
      const newValue = String(after[key] ?? '');
      if (oldValue === newValue) continue;
      if (!changes[sectionName]) changes[sectionName] = {};
      changes[sectionName][key] = newValue;
    }
  }
  return changes;
}
function buildPluginPayload() {
  const plugins = clone((state.draft && state.draft.plugins) || []);
  plugins.forEach(plugin => (plugin.commands || []).forEach(command => {
    if (!Array.isArray(command.aliases)) return;
    command.aliases = [...new Set(command.aliases.map(alias => String(alias || '').trim()).filter(Boolean))];
  }));
  return plugins;
}
function saveDraft() {
  if (!state.draft) return;
  const changes = buildChangedSections();
  const hasSectionChanges = Object.keys(changes).some(name => Object.keys(changes[name]).length);
  if (!hasSectionChanges && !state.pluginsDirty && !state.profilesDirty) {
    setStatus('没有需要保存的变化');
    state.dirty = false;
    state.dirtyFields.clear();
    return;
  }
  setStatus('保存中…');
  const saveId = ++state.saveSequence;
  state.pendingSaveSections.set(saveId, clone(changes));
  while (state.pendingSaveSections.size > 8)
    state.pendingSaveSections.delete(state.pendingSaveSections.keys().next().value);
  const payload = {
    type: 'saveSettings', page: state.page, sections: changes, saveId,
    base: clone(state.baseSections || {}),
    profiles: clone((state.draft && state.draft.profiles) || []),
    profilesDirty: state.profilesDirty,
    baseProfileStamp: state.baseProfileStamp
  };
  if (state.pluginsDirty) payload.plugins = buildPluginPayload();
  post(payload);
}
window.receiveSnapshot = receiveSnapshot;
window.settingsSaved = function (ok, text, receipt, saveId) {
  const parsedSaveId = Number(saveId);
  const hasSaveId = Number.isSafeInteger(parsedSaveId) && parsedSaveId > 0;
  const hasSubmittedSnapshot = hasSaveId && state.pendingSaveSections.has(parsedSaveId);
  const submittedSections = hasSaveId
    ? state.pendingSaveSections.get(parsedSaveId) : undefined;
  if (hasSaveId) state.pendingSaveSections.delete(parsedSaveId);
  if (receipt && hasSaveId && hasSubmittedSnapshot
    && parsedSaveId > state.latestAppliedSaveId) {
    state.latestAppliedSaveId = parsedSaveId;
    applySettingsSaveReceipt(receipt, submittedSections);
  }
  const message = text || (ok ? '已保存' : '保存失败');
  setStatus(ok && state.dirty ? message + '；保存期间的新修改仍未保存' : message, !ok);
};
window.qbarPluginSaved = function (ok, text, receipt) {
  if (receipt) applySettingsSaveReceipt(receipt);
  if (ok) {
    if (receipt && receipt.pluginsCommitted && Array.isArray(receipt.plugins)
      && state.qbarPluginDraft) {
      const saved = receipt.plugins.find(plugin =>
        plugin && plugin.pluginId === state.qbarPluginDraft.pluginId);
      if (saved) state.qbarPluginDraft = clone(saved);
    }
    applySavedQbarPluginToDraft();
    closeQbarToolDialog();
    showToast(text || '工具设置已保存。', 'success');
    return;
  }
  state.qbarPluginSaving = false;
  if (state.qbarPluginDialog) state.qbarPluginDialog.setBusy(false);
  showToast(text || '工具设置保存失败。', 'error');
};
window.qbarPluginCreated = function (ok, text, receipt) {
  if (receipt) applySettingsSaveReceipt(receipt);
  if (ok) {
    if (receipt && receipt.pluginsCommitted && Array.isArray(receipt.plugins)) {
      state.draft.plugins = clone(receipt.plugins);
      state.basePlugins = clone(receipt.plugins);
      recomputeDirtyState();
      renderPlugins();
    }
    closeQbarCreateDialog();
    showToast(text || '工具已添加。', 'success');
    return;
  }
  state.qbarCreateSaving = false;
  if (state.qbarCreateDialog) state.qbarCreateDialog.setBusy(false);
  qbarCreateSetError(text || '工具添加失败。');
};
window.qbarPluginDeleted = function (ok, text, pluginId, receipt) {
  if (receipt) applySettingsSaveReceipt(receipt);
  if (ok) {
    if (receipt && receipt.pluginsCommitted && Array.isArray(receipt.plugins)) {
      state.draft.plugins = clone(receipt.plugins);
      state.basePlugins = clone(receipt.plugins);
    } else {
      if (state.draft && Array.isArray(state.draft.plugins))
        state.draft.plugins = state.draft.plugins.filter(plugin => plugin.pluginId !== pluginId);
      if (Array.isArray(state.basePlugins))
        state.basePlugins = state.basePlugins.filter(plugin => plugin.pluginId !== pluginId);
    }
    recomputeDirtyState();
    renderPlugins();
    if (state.qbarDeleteDialog) state.qbarDeleteDialog.close();
    showToast(text || '工具已删除。', 'success');
    return;
  }
  state.qbarDeleteSaving = false;
  if (state.qbarDeleteDialog) {
    state.qbarDeleteDialog.setBusy(false);
    state.qbarDeleteDialog.setError(text || '删除工具失败。');
  }
};
window.settingsTestResult = function (ok, text) {
  setStatus('');
  AppDialog.alert({
    title: ok ? '测试正常' : '测试失败',
    message: ok ? '连接正常' : (text || '未知错误')
  });
};
function requestSettingsExit(action) {
  if (!state.dirty) {
    post(action === 'close' ? { type: 'hide' } : { type: 'getSettings' });
    return;
  }
  AppDialog.confirm({
    title: '未保存的修改',
    message: '当前有未保存的修改，确定放弃吗？',
    confirmText: '放弃更改',
    tone: 'danger'
  }).then(ok => {
    if (!ok) return;
    state.dirty = false;
    post(action === 'close' ? { type: 'hide' } : { type: 'getSettings' });
  });
}
window.requestCloseSettings = () => requestSettingsExit('close');
$('#nav').addEventListener('click', event => { const button = event.target.closest('button[data-page]'); if (button) setPage(button.dataset.page); });
$('#saveBtn').addEventListener('click', saveDraft);
$('#cancelBtn').addEventListener('click', () => requestSettingsExit('discard'));
$('#testLlm').addEventListener('click', () => { setStatus('测试中…'); post(buildLlmTest()); });
$('#openLlmSettings').addEventListener('click', () => setPage('llm'));
$('#openLlmSettingsFromTranslate').addEventListener('click', () => setPage('llm'));
$('#testYoudao').addEventListener('click', () => { setStatus('测试中…'); post(buildTranslationTest('youdao')); });
$('#testVolcengine').addEventListener('click', () => { setStatus('测试中…'); post(buildTranslationTest('volcengine')); });
function createPlugin(kind) {
  openQbarCreateDialog(kind);
}
$('#hotkeyScopeButton').addEventListener('click', openHotkeyApplicationDialog);
$('#hotkeyOverridesOnly').addEventListener('click', () => {
  if (!hotkeyProfile()) return;
  state.overridesOnly = !state.overridesOnly;
  renderHotkeyScope();
  applyShortcutFilter();
});
$('#addCustomHotkey').addEventListener('click', () => {
  const row = addCustomHotkeyRow($('#customHotkeyList'));
  row.querySelector('input')?.focus();
});
$('#shortcutFilter').addEventListener('input', applyShortcutFilter);
$$('[data-add-pair]').forEach(button => button.addEventListener('click', () => {
  const sectionName = button.dataset.addPair;
  const rootId = 'tabList';
  addPairRow(sectionName, $('#' + rootId), '', '', sectionName === 'TabHotString');
}));
setSettingsLoaded(false);
bindStaticControls();
post({ type: 'getSettings' });
