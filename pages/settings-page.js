(() => {
'use strict';

const state = {
  schema: null, base: null, draft: null, status: 'loading', sessionId: '', revision: 0,
  page: 'general', windowPickerDialog: null,
  qbarPluginDraft: null, qbarDeleteTarget: null, qbarDeleteDialog: null,
  qbarPluginDialog: null, qbarCreateDraft: null, qbarCreateDialog: null,
  hotkeyProfileId: '', overridesOnly: false, hotkeyApplicationDialog: null,
  customHotkeyActions: [], bindingModes: []
};

const pendingRequests = new Map();
let requestSequence = 0;
let shortcutRecording = null;
let shortcutCaptureSequence = 0;
const CUSTOM_HOTKEY_BUILTIN_PREFIX = '@builtin:shortcut/';
const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const post = payload => {
  if (!window.chrome?.webview) return false;
  try {
    chrome.webview.postMessage(JSON.stringify({ ...payload, requestId: payload.requestId ?? ++requestSequence, sessionId: state.sessionId }));
    return true;
  } catch { return false; }
};
function cancelRequest(id) {
  const pending = pendingRequests.get(Number(id));
  if (pending) clearTimeout(pending.timer);
  pendingRequests.delete(Number(id));
}
function clearPendingRequests() {
  for (const id of pendingRequests.keys()) cancelRequest(id);
}
function request(payload, responseType, onReply) {
  const requestId = ++requestSequence, sessionId = state.sessionId;
  const timer = setTimeout(() => {
    if (!pendingRequests.has(requestId)) return;
    cancelRequest(requestId);
    onReply({ requestId, sessionId, ok: false, timedOut: true });
  }, 30000);
  pendingRequests.set(requestId, { sessionId, responseType, onReply, timer });
  if (!post({ ...payload, requestId })) { cancelRequest(requestId); return 0; }
  return requestId;
}

const stableJson = value => JSON.stringify(value, (key, entry) => {
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return entry;
  const sorted = Object.create(null);
  Object.keys(entry).sort().forEach(name => { sorted[name] = entry[name]; });
  return sorted;
});
const clone = value => JSON.parse(JSON.stringify(value || {}));
const pickerState = { selectedIndex: 0, kind: '', root: null, rows: [] };
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

function setShortcutDraftValue(sectionName, key, value) {
  const normalizedKey = sectionName === 'CustomHotkey' ? normalizeCustomTrigger(key) : key;
  const profile = hotkeyProfile();
  if (!profile) {
    const values = state.draft.sections[sectionName] || {};
    Object.keys(values).forEach(raw => {
      if (raw !== normalizedKey && sectionName === 'CustomHotkey'
        && normalizeCustomTrigger(raw) === normalizedKey) {
        delete values[raw]; updateDirtyStatus(sectionName, raw);
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
  updateDirtyStatus();
}
function removeShortcutDraftValue(sectionName, key) {
  const normalizedKey = sectionName === 'CustomHotkey' ? normalizeCustomTrigger(key) : key;
  const profile = hotkeyProfile();
  if (!profile) {
    const values = state.draft.sections[sectionName] || {};
    let matched = false;
    Object.keys(values).forEach(raw => {
      if ((sectionName === 'CustomHotkey' ? normalizeCustomTrigger(raw) : raw) === normalizedKey) {
        delete values[raw];
        updateDirtyStatus(sectionName, raw);
        matched = true;
      }
    });
    return;
  }
  if (profile.sections && profile.sections[sectionName]) {
    Object.keys(profile.sections[sectionName]).forEach(raw => {
      if ((sectionName === 'CustomHotkey' ? normalizeCustomTrigger(raw) : raw) === normalizedKey)
        delete profile.sections[sectionName][raw];
    });
  }
  updateDirtyStatus();
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

function receiveWindowPicker(payload) {
  if (!isLoaded() || isSaving() || payload?.sessionId !== state.sessionId) return;
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
  $('#saveBtn').disabled = state.status !== 'editing' || !hasChanges();
}
function updateDirtyStatus() {

  setStatus(hasChanges() ? '未保存' : '');
}
function setDraftValue(sectionName, key, value) {
  if (!state.draft.sections[sectionName]) state.draft.sections[sectionName] = {};
  state.draft.sections[sectionName][key] = isSecretSetting(sectionName, key) && typeof value !== 'object'
    ? { op: value ? 'set' : 'clear', ...(value ? { value } : {}) } : value;
  updateDirtyStatus(sectionName, key);
}
function readControl(node) {
  if (isSecretSetting(node.dataset.section, node.dataset.key)
    && node.dataset.secretSaved === 'true' && node.dataset.secretEdited !== 'true')
    return section(node.dataset.section)[node.dataset.key];
  return node.type === 'checkbox' ? (node.checked ? '1' : '0') : node.value;
}

function createSettingsField(schema, value, onChange = null) {
  const checkbox = schema.type === 'bool' || schema.type === 'boolean';
  const numeric = ['int', 'integer', 'optionalNumber', 'optionalPositiveInt'].includes(schema.type);
  const wide = schema.wide ?? (checkbox || schema.type === 'secret' || schema.multiline === true);
  const field = document.createElement('label');
  field.className = (checkbox ? 'check ui-form-check' : 'field ui-form-field') + (wide ? ' wide' : '');
  const label = document.createElement('span'); label.textContent = schema.label;
  const input = document.createElement(schema.type === 'enum' ? 'select' : schema.multiline ? 'textarea' : 'input');
  input.className = 'ui-form-control';
  if (input.tagName === 'INPUT')
    input.type = checkbox ? 'checkbox' : schema.type === 'secret' ? 'password' : numeric ? 'number' : 'text';
  const scale = Number(schema.displayScale) || 1;
  if (numeric) {
    for (const name of ['min', 'max', 'step'])
      if (schema[name] != null) input[name] = String(Number(schema[name]) / scale);
    if (!schema.step) input.step = schema.type === 'optionalNumber' ? 'any' : '1';
    if (schema.type === 'optionalPositiveInt') input.min = '1';
  }
  if (schema.type === 'enum')
    for (const candidate of schema.values) {
      const option = document.createElement('option');
      option.value = String(candidate);
      option.textContent = schema.labels?.[candidate]
        || translationLanguageByCode.get(String(candidate).toLowerCase())?.labelZh || String(candidate);
      input.append(option);
    }
  if (checkbox) input.checked = value === true || value === 1 || value === '1' || value === 'true';
  else input.value = value == null || typeof value === 'object' ? '' : String(numeric ? Number(value) / scale : value);
  input.placeholder = schema.placeholder || '';
  const copy = checkbox ? document.createElement('span') : field;
  if (checkbox) { copy.className = 'ui-form-copy'; copy.append(label); }
  else field.append(label, input);
  if (schema.hint) {
    const hint = document.createElement('small'); hint.className = 'ui-form-hint'; hint.textContent = schema.hint;
    copy.append(hint);
  }
  if (checkbox) field.append(copy, input);
  if (onChange) input.addEventListener(checkbox || input.tagName === 'SELECT' ? 'change' : 'input', () => {
    const next = checkbox ? input.checked : numeric && input.value.trim() !== ''
      ? Number(input.value) * scale : input.value;
    onChange(next);
  });
  return { field, input };
}
function compareSettingsFields(a, b) {
  return (a.order ?? Number.MAX_SAFE_INTEGER) - (b.order ?? Number.MAX_SAFE_INTEGER);
}
function renderSettingsForms() {
  $$('.settings-groups').forEach(root => root.replaceChildren());
  for (const group of state.schema.groups) {
    const root = $('.settings-groups', $('.page[data-page-view="' + group.page + '"]'));
    const card = document.createElement('section'); card.className = 'card ui-form-panel';
    const head = document.createElement('div'); head.className = 'card-head';
    const title = document.createElement('h3'); title.textContent = group.title; head.append(title);
    if (group.action) {
      const action = document.createElement('button'); action.type = 'button'; action.className = 'btn';
      action.dataset.settingsAction = group.action;
      action.textContent = group.action === 'openLlm' ? 'LLM 设置' : '测试'; head.append(action);
    }
    const grid = document.createElement('div'); grid.className = 'grid ui-form-grid';
    const fields = Object.entries(state.schema.fields).flatMap(([sectionName, definitions]) =>
      Object.entries(definitions).filter(([, schema]) => !schema.hidden && schema.group === group.id)
        .map(([key, schema]) => ({ sectionName, key, schema }))
    ).sort((a, b) => compareSettingsFields(a.schema, b.schema));
    for (const { sectionName, key, schema } of fields) {
      const { field, input } = createSettingsField(schema, section(sectionName)[key]);
      input.dataset.section = sectionName; input.dataset.key = key;
      if (schema.when) {
        field.dataset.visibleSection = sectionName;
        field.dataset.visibleKey = schema.when.key; field.dataset.visibleValue = schema.when.equals;
      }
      grid.append(field);
    }
    card.append(head, grid);
    if (group.hint) {
      const hint = document.createElement('div'); hint.className = 'hint'; hint.textContent = group.hint;
      card.append(hint);
    }
    root.append(card);
  }
  bindStaticControls();
  refreshIcons();
}

const isLoaded = () => state.status === 'editing' || state.status === 'saving';
const isSaving = () => state.status === 'saving';
function setEditorStatus(status) {
  state.status = status;
  document.body.classList.toggle('settings-saving', status === 'saving');
  const blocked = status !== 'editing';
  $('.content').inert = blocked;
  $('#saveBtn').disabled = blocked || !hasChanges();
  $('#cancelBtn').disabled = status === 'saving';
  $$('[data-section][data-key]').forEach(node => { node.disabled = blocked; });
  $$('.secret-control input').forEach(updateSecretActions);
}
function setSettingsSaving(saving) {
  if (saving) { setEditorStatus('saving'); setStatus('保存中…'); }
  else if (state.status !== 'error') setEditorStatus(state.draft ? 'editing' : 'loading');
}
function setSettingsLoaded(loaded) {
  setEditorStatus(loaded ? (isSaving() ? 'saving' : 'editing') : 'error');
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
  translationLanguageByCode = new Map(catalog.map(entry => [entry.code.toLowerCase(), entry]));

  return true;
}

function updateTranslateModeFields() {
  $$('[data-visible-key]').forEach(field => {
    field.hidden = section(field.dataset.visibleSection)[field.dataset.visibleKey] !== field.dataset.visibleValue;
  });
}

function writeControl(node) {
  const value = section(node.dataset.section)[node.dataset.key];
  const secret = isSecretSetting(node.dataset.section, node.dataset.key);
  if (secret) {
    const saved = value.op === 'keep' && value.present;
    node.type = 'password';
    node.placeholder = saved ? '••••••••••••' : '';
    node.dataset.secretSaved = saved ? 'true' : 'false';
    node.dataset.secretEdited = value.op === 'keep' ? 'false' : 'true';
    node.dataset.secretLoaded = 'false';
    node.value = value.op === 'set' ? value.value : '';
    updateSecretActions(node);
  } else if (node.type === 'checkbox') node.checked = value !== '' && value !== '0';
  else node.value = value;
}
function isSecretSetting(sectionName, key) {
  return state.schema?.fields?.[sectionName]?.[key]?.type === 'secret';
}

function bindStaticControls() {
  $$('[data-section][data-key]').forEach(node => {
    if (isSecretSetting(node.dataset.section, node.dataset.key)) {
      node.autocomplete = 'off';
      node.spellcheck = false;
      const control = document.createElement('div');
      control.className = 'secret-control';
      node.parentElement.insertBefore(control, node);
      control.append(node);

      const actions = document.createElement('div');
      actions.className = 'secret-actions';
      control.append(actions);
      const viewButton = createSecretAction('eye', '查看密钥', 'secret-view');
      const copyButton = createSecretAction('copy', '复制密钥', 'secret-copy');
      const clearButton = createSecretAction('trash-2', '清除密钥', 'secret-clear');
      actions.append(viewButton, copyButton, clearButton);

      viewButton.addEventListener('click', () => toggleSecretVisibility(node, viewButton));
      copyButton.addEventListener('click', () => copySecret(node, copyButton));
      clearButton.addEventListener('click', () => {
        cancelSecretRequest(node);
        node.value = '';
        node.placeholder = '';
        node.type = 'password';
        node.dataset.secretEdited = 'true';
        node.dataset.secretLoaded = 'false';
        setDraftValue(node.dataset.section, node.dataset.key, '');
        updateSecretActions(node);
      });
    }
    const update = () => {
      if (isSecretSetting(node.dataset.section, node.dataset.key)) {
        cancelSecretRequest(node);
        node.dataset.secretEdited = 'true';
        node.dataset.secretLoaded = 'false';
        updateSecretActions(node);
      }
      setDraftValue(node.dataset.section, node.dataset.key, readControl(node));
      if (node.dataset.section === 'TTranslate' && node.dataset.key === 'mode')
        updateTranslateModeFields();
    };
    node.addEventListener('input', update);
    node.addEventListener('change', update);
  });
}
function createSecretAction(icon, label, className) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'secret-action ' + className;
  button.setAttribute('aria-label', label);
  button.title = label;
  button.append(createIcon(icon));
  return button;
}
function updateSecretActions(input) {
  const control = input.closest('.secret-control');
  if (!control) return;
  const hasValue = !!input.value
    || (input.dataset.secretSaved === 'true' && input.dataset.secretEdited !== 'true');
  const view = $('.secret-view', control);
  const copy = $('.secret-copy', control);
  const clear = $('.secret-clear', control);
  const pending = !!input.dataset.secretPendingId;
  [view, copy, clear].forEach(button => {
    if (button) button.disabled = !isLoaded() || isSaving() || !hasValue || pending;
  });
  if (view) {
    const revealed = input.type === 'text';
    view.setAttribute('aria-label', revealed ? '隐藏密钥' : '查看密钥');
    view.title = revealed ? '隐藏密钥' : '查看密钥';
    const icon = view.querySelector('[data-lucide]');
    const name = revealed ? 'eye-off' : 'eye';
    if (icon && icon.dataset.lucide !== name) {
      icon.dataset.lucide = name;
      refreshIcons();
    }
  }
}
function cancelSecretRequest(input) {
  const requestId = input.dataset.secretPendingId;
  if (!requestId) return;
  cancelRequest(requestId);
  delete input.dataset.secretPendingId;
  updateSecretActions(input);
}
function toggleSecretVisibility(input) {
  if (input.type === 'text') { input.type = 'password'; updateSecretActions(input); return; }
  if (input.value) { input.type = 'text'; updateSecretActions(input); return; }
  if (input.dataset.secretSaved !== 'true' || input.dataset.secretPendingId) return;
  const id = request({ type: 'revealSecret', section: input.dataset.section, key: input.dataset.key }, 'secretResult',
    result => applySecretResult(input, 'reveal', result));
  if (id) input.dataset.secretPendingId = String(id);
  else showToast('无法发送查看请求，请重试。', 'error');
  updateSecretActions(input);
}
function copySecret(input) {
  if (!input.value && !(input.dataset.secretSaved === 'true' && input.dataset.secretEdited !== 'true')) return;
  if (input.dataset.secretPendingId) return;
  const payload = { type: 'copySecret', section: input.dataset.section, key: input.dataset.key };
  if (input.value && input.dataset.secretEdited === 'true') payload.value = input.value;
  const id = request(payload, 'secretResult', result => applySecretResult(input, 'copy', result));
  if (id) input.dataset.secretPendingId = String(id);
  else showToast('无法发送复制请求，请重试。', 'error');
  updateSecretActions(input);
}
function applySecretResult(input, action, result) {
  if (input.dataset.secretPendingId !== String(result.requestId)) return;
  delete input.dataset.secretPendingId;
  if (!result.ok) {
    updateSecretActions(input);
    showToast(action === 'copy' ? '无法复制密钥，请重试。' : '无法查看密钥，请重试。', 'error');
    return;
  }
  if (action === 'reveal' && input.dataset.secretEdited !== 'true') {
    input.value = String(result.value); input.type = 'text';
  } else if (action === 'copy') showToast('已复制到剪贴板。', 'success');
  updateSecretActions(input);
}

function lockDisplayedSecrets() {
  $$('[data-section][data-key]').forEach(input => {
    if (!isSecretSetting(input.dataset.section, input.dataset.key)) return;
    cancelSecretRequest(input);
    input.value = '';
    input.type = 'password';
    input.dataset.secretLoaded = 'false';
    input.placeholder = input.dataset.secretSaved === 'true' ? '••••••••••••' : '';
    updateSecretActions(input);
  });
};
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
function normalizeCustomHotkeyActions(value) {
  if (!Array.isArray(value)) return [];
  const unsupported = new Set([
    'keyFunc_send', 'keyFunc_run', 'keyFunc_doubleChar', 'keyFunc_sendChar',
    'keyFunc_winbind_activate', 'keyFunc_winbind_binding'
  ]);
  return [...new Set(value.filter(id => {
    if (typeof id !== 'string' || !id.startsWith(CUSTOM_HOTKEY_BUILTIN_PREFIX)) return false;
    const action = id.slice(CUSTOM_HOTKEY_BUILTIN_PREFIX.length);
    return /^[A-Za-z0-9_]+$/.test(action)
      && Object.prototype.hasOwnProperty.call(ACTION_LABELS, action)
      && !unsupported.has(action);
  }))];
}
function customHotkeyBuiltinActionLabel(id) {
  const action = String(id || '').startsWith(CUSTOM_HOTKEY_BUILTIN_PREFIX)
    ? String(id).slice(CUSTOM_HOTKEY_BUILTIN_PREFIX.length) : '';
  return Object.prototype.hasOwnProperty.call(ACTION_LABELS, action)
    ? ACTION_LABELS[action] : '当前功能不可用';
}
function populateCustomHotkeyBuiltinActions(select, selectedId = '') {
  select.replaceChildren();
  const groupedActions = new Map(SHORTCUT_GROUPS.map(group => [group.id, []]));
  state.customHotkeyActions.forEach(id => {
    const action = id.slice(CUSTOM_HOTKEY_BUILTIN_PREFIX.length);
    const category = shortcutActionCategory(action);
    if (!groupedActions.has(category)) groupedActions.set(category, []);
    groupedActions.get(category).push(id);
  });
  SHORTCUT_GROUPS.forEach(group => {
    const ids = groupedActions.get(group.id) || [];
    if (!ids.length) return;
    const optgroup = document.createElement('optgroup');
    optgroup.label = group.label;
    ids.forEach(id => {
      const option = document.createElement('option');
      option.value = id;
      option.textContent = customHotkeyBuiltinActionLabel(id);
      optgroup.append(option);
    });
    select.append(optgroup);
  });
  if (selectedId && !state.customHotkeyActions.includes(selectedId)) {
    const unavailable = document.createElement('option');
    unavailable.value = selectedId;
    unavailable.textContent = '当前功能不可用';
    unavailable.disabled = true;
    select.append(unavailable);
  }
  const value = selectedId || state.customHotkeyActions[0] || '';
  select.value = value;
  return select.value;
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
function receiveShortcutCapture(capture) {
  if (!shortcutRecording || !capture || !capture.value
    || capture.sessionId !== state.sessionId || isSaving()
    || Number(capture.captureId) !== shortcutRecording.captureId) return;
  if (shortcutRecording.kind === 'custom') {
    if (shortcutRecording.field === 'trigger') {
      shortcutRecording.input.value = capture.label || formatCustomTrigger(capture.value);
      updateCustomHotkeyKey(shortcutRecording.row, shortcutRecording.input, true);
    } else {
      shortcutRecording.input.value = capture.label || formatCustomSend(capture.value);
      shortcutRecording.row.dataset.sendValue = normalizeCustomSend(capture.value);
      shortcutRecording.row.dataset.overridden = 'true';
      syncCustomHotkeyDraft();
      syncCustomHotkeyRemove(shortcutRecording.row);
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
function shortcutCaptureFailed(capture) {
  if (!shortcutRecording || !capture
    || capture.sessionId !== state.sessionId || isSaving()
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
  const newKey = normalizeCustomTrigger(triggerInput.value);
  let suffix = newKey;
  while (suffix && '^!+#'.includes(suffix[0])) suffix = suffix.slice(1);
  if (formatValue && suffix) triggerInput.value = formatCustomTrigger(newKey);
  row.dataset.key = newKey;
  row.dataset.overridden = 'true';
  syncCustomHotkeyDraft();
  syncCustomHotkeyRemove(row);
}
function customHotkeyActionValue(row) {
  if (row.dataset.mode === 'native') return '@native';
  if (row.dataset.mode === 'block') return '@block';
  if (row.dataset.mode === 'builtin') return row.dataset.builtinAction || '';
  return row.dataset.sendValue || '';
}
function updateCustomHotkeyMode(row, modeSelect, sendInput, actionSelect, sendRecord) {
  const previousMode = row.dataset.mode || 'send';
  const mode = modeSelect.value;
  if (shortcutRecording && shortcutRecording.row === row && mode !== 'send')
    stopShortcutRecording();
  if (previousMode === 'send') row.dataset.sendValue = normalizeCustomSend(sendInput.value);
  if (previousMode === 'builtin') row.dataset.builtinAction = actionSelect.value || row.dataset.builtinAction || '';
  row.dataset.mode = mode;
  const isSending = mode === 'send';
  const isBuiltin = mode === 'builtin';
  if (isBuiltin)
    row.dataset.builtinAction = populateCustomHotkeyBuiltinActions(
      actionSelect, row.dataset.builtinAction || '');
  sendInput.hidden = isBuiltin;
  actionSelect.hidden = !isBuiltin;
  sendInput.disabled = !isSending;
  sendInput.value = isSending
    ? formatCustomSend(row.dataset.sendValue || '')
    : mode === 'native' ? '保留原有功能' : '已禁用此快捷键';
  sendInput.placeholder = isSending ? '例如 Ctrl+C' : '';
  sendRecord.hidden = !isSending;
  sendRecord.disabled = !isSending;
  row.dataset.overridden = 'true';
  syncCustomHotkeyDraft();
  syncCustomHotkeyRemove(row);
}
function syncCustomHotkeyRemove(row) {
  const remove = row.querySelector('.custom-hotkey-remove');
  const profile = hotkeyProfile();
  const overridden = row.dataset.overridden === 'true';
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
  row.dataset.overridden = !hotkeyProfile() || !initialTrigger
    || shortcutOverrideExists('CustomHotkey', initialTrigger) ? 'true' : 'false';
  row.dataset.mode = initialSend === '@native' ? 'native'
    : initialSend === '@block' ? 'block'
      : String(initialSend).startsWith(CUSTOM_HOTKEY_BUILTIN_PREFIX) ? 'builtin' : 'send';
  row.dataset.sendValue = row.dataset.mode === 'send' ? normalizeCustomSend(initialSend) : '';
  row.dataset.builtinAction = row.dataset.mode === 'builtin'
    ? String(initialSend) : state.customHotkeyActions[0] || '';

  const triggerField = document.createElement('div');
  triggerField.className = 'custom-hotkey-field';
  const triggerLabel = document.createElement('span');
  triggerLabel.textContent = '触发键';
  const triggerControl = document.createElement('div');
  triggerControl.className = 'custom-hotkey-control';
  const triggerInput = document.createElement('input');
  triggerInput.className = 'custom-hotkey-trigger';
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
  sendLabel.textContent = '映射目标';
  const sendControl = document.createElement('div');
  sendControl.className = 'custom-hotkey-control';
  const modeSelect = document.createElement('select');
  modeSelect.className = 'custom-hotkey-mode';
  modeSelect.setAttribute('aria-label', '映射目标类型');
  [['send', '发送按键'], ['builtin', '自带功能'], ['native', '保留原功能'], ['block', '禁用快捷键']].forEach(([value, label]) => {
    const option = document.createElement('option');
    option.value = value;
    option.textContent = label;
    if (value === 'builtin' && !state.customHotkeyActions.length) option.disabled = true;
    modeSelect.append(option);
  });
  modeSelect.value = row.dataset.mode;
  const sendInput = document.createElement('input');
  sendInput.className = 'custom-hotkey-send';
  sendInput.value = row.dataset.mode === 'send' ? formatCustomSend(initialSend)
    : row.dataset.mode === 'native' ? '保留原有功能' : '已禁用此快捷键';
  sendInput.placeholder = row.dataset.mode === 'send' ? '例如 Ctrl+C' : '';
  sendInput.disabled = row.dataset.mode !== 'send';
  sendInput.hidden = row.dataset.mode === 'builtin';
  sendInput.setAttribute('aria-label', '发送按键');
  const actionSelect = document.createElement('select');
  actionSelect.className = 'custom-hotkey-action';
  actionSelect.setAttribute('aria-label', '自带功能');
  if (row.dataset.mode === 'builtin')
    row.dataset.builtinAction = populateCustomHotkeyBuiltinActions(
      actionSelect, row.dataset.builtinAction);
  actionSelect.hidden = row.dataset.mode !== 'builtin';
  actionSelect.disabled = row.dataset.mode !== 'builtin';
  const sendRecord = document.createElement('button');
  sendRecord.type = 'button';
  sendRecord.className = 'btn ghost custom-hotkey-record';
  sendRecord.textContent = '录制';
  sendRecord.title = '录制发送键';
  sendRecord.disabled = row.dataset.mode !== 'send';
  sendRecord.hidden = row.dataset.mode !== 'send';
  sendRecord.addEventListener('click', () =>
    startCustomHotkeyRecording(row, sendInput, 'send', sendRecord));
  modeSelect.addEventListener('change', () => {
    updateCustomHotkeyMode(row, modeSelect, sendInput, actionSelect, sendRecord);
    actionSelect.disabled = modeSelect.value !== 'builtin';
  });
  actionSelect.addEventListener('change', () => {
    row.dataset.builtinAction = actionSelect.value;
    row.dataset.overridden = 'true';
    syncCustomHotkeyDraft();
    syncCustomHotkeyRemove(row);
  });
  sendControl.append(modeSelect, sendInput, actionSelect, sendRecord);
  sendField.append(sendLabel, sendControl);

  const remove = document.createElement('button');
  remove.className = 'icon-btn custom-hotkey-remove';
  remove.type = 'button';
  remove.appendChild(createIcon('x'));
  remove.title = '删除自定义快捷键';
  remove.setAttribute('aria-label', '删除自定义快捷键');
  remove.addEventListener('click', () => {
    const root = row.parentElement;
    const key = row.dataset.key;
    const inherited = hotkeyProfile() ? Object.entries(section('CustomHotkey'))
      .find(([trigger]) => normalizeCustomTrigger(trigger) === key)?.[1] : '';
    if (shortcutRecording && shortcutRecording.row === row) stopShortcutRecording();
    row.remove();
    syncCustomHotkeyDraft();
    if (inherited && !$$('.custom-hotkey-row', root).some(item => item.dataset.key === key))
      addCustomHotkeyRow(root, key, inherited);
    if (!root.querySelector('.custom-hotkey-row')) renderCustomHotkeys();
  });

  triggerInput.addEventListener('input', () => updateCustomHotkeyKey(row, triggerInput));
  triggerInput.addEventListener('change', () => updateCustomHotkeyKey(row, triggerInput, true));
  sendInput.addEventListener('input', () => {
    row.dataset.sendValue = normalizeCustomSend(sendInput.value);
    row.dataset.overridden = 'true';
    syncCustomHotkeyDraft();
    syncCustomHotkeyRemove(row);
  });
  row.append(triggerField, sendField, remove);
  root.append(row);
  syncCustomHotkeyRemove(row);
  refreshIcons();
  return row;
}
function syncCustomHotkeyDraft() {
  if (!state.draft || isSaving()) return;
  const values = Object.create(null);
  const profile = hotkeyProfile();
  $$('.custom-hotkey-row', $('#customHotkeyList')).forEach(row => {
    const key = normalizeCustomTrigger($('.custom-hotkey-trigger', row).value);
    row.dataset.key = key;
    if (key && (!profile || row.dataset.overridden === 'true'))
      values[key] = customHotkeyActionValue(row);
  });
  if (profile) profile.sections.CustomHotkey = values;
  else state.draft.sections.CustomHotkey = values;

  setStatus(hasChanges() ? '未保存' : '');
}
function findCustomHotkeyError() {
  const seen = new Set();
  for (const row of $$('.custom-hotkey-row', $('#customHotkeyList'))) {
    const input = $('.custom-hotkey-trigger', row);
    const key = normalizeCustomTrigger(input.value);
    const action = customHotkeyActionValue(row);
    if (!input.value.trim() && !action && row.dataset.mode === 'send') continue;
    if (!key || !key.replace(/^[\^!+#]+/, ''))
      return { message: '请填写完整的触发键。', target: input };
    if (!action) return { message: '请填写映射目标。', target: $('.custom-hotkey-send', row) };
    if (seen.has(key)) return { message: '触发键重复，请编辑已有项。', target: input };
    seen.add(key);
  }
  return null;
}
function validateCustomHotkeyRows() {
  const error = findCustomHotkeyError();
  if (!error) return true;
  showToast(error.message, 'warning');
  error.target.focus();
  return false;
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
function qbarToolIdentity(plugin) { return plugin.pluginId || plugin.draftId; }
function pluginMeta(plugin) {
  return plugin.draftId ? state.schema.creatableTools[plugin.kind]
    : state.schema.tools[plugin.pluginId];
}
function qbarToolCommands(plugin) {
  return plugin.draftId ? [{ aliases: plugin.aliases }] : plugin.commands;
}
function qbarToolVisible(plugin) {
  const meta = pluginMeta(plugin);
  return meta.definitionId === 'builtin.search' || meta.definitionId === 'builtin.run'
    || meta.source !== 'builtin' || qbarToolCommands(plugin).some(command => command.aliases.length);
}
function qbarToolGroup(plugin) {
  const definitionId = pluginMeta(plugin).definitionId;
  return definitionId === 'builtin.search' ? 'search' : definitionId === 'builtin.run' ? 'run' : 'builtin';
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
  return pluginMeta(plugin).source && pluginMeta(plugin).source !== 'builtin'
    || pluginMeta(plugin).definitionId === 'builtin.search' || pluginMeta(plugin).definitionId === 'builtin.run'
    ? '使用工具名称' : '未设置命令';
}
function qbarToolEnabled(plugin) {
  return plugin.enabled !== false && pluginMeta(plugin).definitionValid !== false && pluginMeta(plugin).settingsValid !== false
    && (plugin.draftId || pluginMeta(plugin).commandEnabled);
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
  state.qbarPluginDialog = AppDialog.open({
    title: qbarToolName(plugin) + '设置',
    actions: [
      { id: 'cancel', text: '取消', role: 'cancel', kind: 'ghost' },
      { id: 'confirm', text: '确认' }
    ],
    render(root) { renderQbarToolDialog(root); },
    onAction(id, api) {
      if (id === 'confirm' && !confirmQbarToolDialog()) return api.keepOpen();
    },
    onClose() {
      state.qbarPluginDraft = null;
      state.qbarPluginDialog = null;
    }
  });
}
function openQbarDeleteDialog(plugin) {
  if (!plugin || !pluginMeta(plugin).deletable) return;
  state.qbarDeleteTarget = { pluginId: qbarToolIdentity(plugin), name: qbarToolName(plugin) };
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
      state.qbarDeleteDialog = null;
    }
  });
}
function confirmQbarPluginDelete(dialog = state.qbarDeleteDialog) {
  const target = state.qbarDeleteTarget;
  if (!target || !isLoaded() || isSaving() || !dialog) return;
  if (state.draft && Array.isArray(state.draft.plugins))
    state.draft.plugins = state.draft.plugins.filter(plugin => qbarToolIdentity(plugin) !== target.pluginId);
  dialog.close();
  updateDirtyStatus();
  renderPlugins();
  showToast('删除已暂存，请点击右上角“保存”后生效。', 'info');
}

function openQbarCreateDialog(kind) {
  const meta = state.schema.creatableTools[kind];
  const settings = Object.create(null);
  for (const [key, field] of Object.entries(meta.settingsSchema))
    settings[key] = Object.hasOwn(field, 'default') ? field.default : '';
  state.qbarCreateDraft = { draftId: 'draft.' + crypto.randomUUID(), kind,
    name: kind === 'search' ? '新搜索' : '新项目', enabled: true, settings, aliases: [] };
  state.qbarCreateDialog = AppDialog.open({
    title: kind === 'search' ? '添加网页搜索' : '添加快捷命令', initialFocus: 'content',
    actions: [{ id: 'cancel', text: '取消', role: 'cancel', kind: 'ghost' },
      { id: 'create', text: '确认' }],
    render(root) {
      root.append(createSettingsField({ type: 'text', label: '工具名称' },
        state.qbarCreateDraft.name, value => { state.qbarCreateDraft.name = value; }).field);
      renderQbarSchemaSettings(state.qbarCreateDraft, root, '工具设置');
      const aliases = document.createElement('div'); aliases.className = 'plugin-alias-list';
      renderQbarToolAliases({ aliases: state.qbarCreateDraft.aliases }, aliases); root.append(aliases);
    },
    onAction(id, api) {
      if (id !== 'create') return;
      const error = validateQbarToolDraft(state.qbarCreateDraft);
      if (error) { api.setError(error); return api.keepOpen(); }
      state.draft.plugins.push(clone(state.qbarCreateDraft));
       renderPlugins();
      setStatus('未保存');
    },
    onClose() { state.qbarCreateDraft = null; state.qbarCreateDialog = null; }
  });
}

function renderQbarSchemaSettings(plugin, editor, title) {
  const entries = Object.entries(pluginMeta(plugin).settingsSchema)
    .sort(([, a], [, b]) => compareSettingsFields(a, b));
  if (!entries.some(([key, field]) => !field.hidden || !Object.hasOwn(plugin.settings, key))) return;
  const root = document.createElement('div'); root.className = 'plugin-detail-section ui-form-panel';
  const heading = document.createElement('strong'); heading.textContent = title;
  const grid = document.createElement('div'); grid.className = 'grid ui-form-grid';
  for (const [key, field] of entries)
    if (!field.hidden || !Object.hasOwn(plugin.settings, key)) grid.append(createSettingsField(field, plugin.settings[key],
      value => { plugin.settings[key] = value; }).field);
  root.append(heading, grid); editor.append(root);
}

function renderQbarToolDialog(editor) {
  const plugin = state.qbarPluginDraft;
  if (!plugin) return;
  editor.replaceChildren();
  const general = document.createElement('div'); general.className = 'grid ui-form-grid';
  general.append(
    createSettingsField({ type: 'text', label: '工具名称', wide: true }, qbarToolName(plugin),
      value => { plugin.name = value; }).field,
    createSettingsField({ type: 'boolean', label: '启用工具' }, plugin.enabled !== false,
      value => { plugin.enabled = value; }).field
  );
  editor.append(general);
  if (pluginMeta(plugin).definitionValid === false || pluginMeta(plugin).settingsValid === false) {
    const warning = document.createElement('div'); warning.className = 'hint';
    warning.textContent = pluginMeta(plugin).definitionValid === false
      ? '此工具当前无法使用，请重新启动应用后重试。'
      : '此工具的设置无效，已暂停使用。请检查设置后重新启用。';
    editor.append(warning);
  }

  renderQbarSchemaSettings(plugin, editor, '工具设置');

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
function confirmQbarToolDialog() {
  const plugin = state.qbarPluginDraft;
  if (!plugin || !state.draft) return false;
  const error = validateQbarToolDraft(plugin);
  if (error) {
    state.qbarPluginDialog?.setError(error);
    return false;
  }
  const draftPlugin = clone(plugin);
  qbarToolCommands(draftPlugin).forEach(command => {
    command.aliases = [...new Set((command.aliases || []).map(alias => String(alias || '').trim()).filter(Boolean))];
  });
  const plugins = Array.isArray(state.draft.plugins)
    ? state.draft.plugins : (state.draft.plugins = []);
  const index = plugins.findIndex(item => item && qbarToolIdentity(item) === qbarToolIdentity(draftPlugin));
  if (index < 0) return;
  plugins[index] = draftPlugin;
  renderPlugins();

  setStatus(hasChanges() ? '未保存' : '');
  showToast('修改已暂存，请点击右上角“保存”后生效。', 'info');
  return true;
}
function validateQbarToolDraft(plugin) {
  if (!String(plugin.name || '').trim() || String(plugin.name).trim().length > 80)
    return '工具名称需要填写，且不能超过 80 个字符。';
  for (const [key, field] of Object.entries(pluginMeta(plugin).settingsSchema || {})) {
    const value = plugin.settings?.[key];
    if (field.type === 'integer') {
      if (!Number.isInteger(value) || value < field.min || value > field.max
        || (value - (field.min ?? value)) % (field.step ?? 1) !== 0)
        return '请检查“' + (field.label || '工具选项') + '”的数值范围。';
    } else if (field.type === 'enum' && !field.values.includes(value))
      return '请选择“' + field.label + '”。';
    else if (field.type === 'url-template' && !String(value || '').includes('{q}'))
      return '搜索网址需要包含 {q}。';
    else if (field.type === 'command-line' && (!String(value || '').trim() || /[\r\n]/.test(value)))
      return '请填写完整的单行执行命令。';
  }
  return '';
}
function renderQbarToolTable(title, group, plugins) {
  const card = document.createElement('section'); card.className = 'qbar-plugin-table-card';
  const head = document.createElement('div'); head.className = 'qbar-plugin-table-head';
  const heading = document.createElement('h3'); heading.textContent = title; head.append(heading);
  if (group === 'search' || group === 'run') {
    const add = document.createElement('button'); add.type = 'button'; add.className = 'btn mini';
    add.textContent = group === 'search' ? '添加搜索' : '添加快捷命令';
    add.addEventListener('click', () => openQbarCreateDialog(group));
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
      if (pluginMeta(plugin).deletable) {
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
  const keyInput = document.createElement('input'); keyInput.className = 'pair-key'; keyInput.value = initialKey; keyInput.placeholder = '触发词';
  const valueInput = document.createElement(multiline ? 'textarea' : 'input'); valueInput.className = 'pair-value'; valueInput.value = initialValue; valueInput.placeholder = '替换内容';
  const remove = document.createElement('button'); remove.className = 'icon-btn'; remove.type = 'button'; remove.appendChild(createIcon('x'));
  remove.title = '删除替换'; remove.setAttribute('aria-label', '删除替换');
  row.append(keyInput, valueInput, remove); root.append(row); refreshIcons();
  const update = () => updatePairDraft(sectionName, root);
  keyInput.addEventListener('input', update);
  valueInput.addEventListener('input', update);
  remove.addEventListener('click', () => {
    row.remove();
    update();
  });
}
function updatePairDraft(sectionName, root) {
  if (!state.draft || isSaving()) return;
  const values = Object.create(null);
  $$('.pair-row', root).forEach(row => {
    const key = $('.pair-key', row).value.trim();
    if (key) values[key] = $('.pair-value', row).value;
  });
  state.draft.sections[sectionName] = values;

  setStatus(hasChanges() ? '未保存' : '');
}
function findPairRowError(root) {
  const seen = new Set();
  for (const row of $$('.pair-row', root)) {
    const keyInput = $('.pair-key', row);
    const valueInput = $('.pair-value', row);
    const key = keyInput.value.trim();
    const value = valueInput.value;
    if (!key && !value) continue;
    let error = '';
    let target = keyInput;
    if (!key) error = '请填写替换的触发词。';
    else if (!value) {
      error = '请填写替换内容；不需要的替换请用右侧删除按钮移除。';
      target = valueInput;
    } else if (seen.has(key)) error = '触发词重复，请修改后再保存。';
    if (error) return { message: error, target };
    seen.add(key);
  }
  return null;
}
function validatePairRows(root) {
  const error = findPairRowError(root);
  if (error) {
    showToast(error.message, 'warning');
    error.target.focus();
    return false;
  }
  return true;
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
    select.innerHTML = [['0', { label: '未绑定' }], ...modes.entries()].map(([value, item]) =>
      `<option value="${value}">${item.label}</option>`).join('');
    select.value = mode ? String(binding.bindType) : '0';
    const actions = document.createElement('div'); actions.className = 'binding-actions';
    const renderActions = () => {
      actions.replaceChildren();
      if (select.value === '0') {
        const hint = document.createElement('span'); hint.className = 'hint';
        hint.textContent = '此快捷键槽位未绑定窗口。'; actions.append(hint);
      } else if (select.value === '3') {
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
      const clearButton = document.createElement('button');
      clearButton.type = 'button'; clearButton.className = 'btn mini ghost';
      clearButton.textContent = '清除绑定';
      clearButton.addEventListener('click', () => clearWindowBinding(binding));
      actions.append(clearButton);
    };
    head.append(title, select, actions); card.append(head);
    const modeHint = document.createElement('div'); modeHint.className = 'binding-mode-hint'; card.append(modeHint);
    const updateModeHint = () => { modeHint.textContent = (modes.get(select.value) || modes.get('1')).description; };
    select.addEventListener('change', () => {
      if (select.value === '0') { clearWindowBinding(binding); return; }
      binding.bindType = Number(select.value);
      updateModeHint(); renderActions(); updateDirtyStatus();
    });
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
    const draft = state.draft;
    closeHotkeyApplicationDialog();
    AppDialog.confirm({
      title: '删除应用配置',
      message: '确定删除“' + hotkeyProfileLabel(profile) + '”的快捷键配置吗？',
      confirmText: '删除',
      tone: 'danger'
    }).then(confirmed => {
      if (!isLoaded() || isSaving() || state.draft !== draft) return;
      if (confirmed) {
        const previousProfileId = state.hotkeyProfileId;
        state.draft.profiles = state.draft.profiles.filter(item => String(item.id) !== String(profile.id));
        if (String(state.hotkeyProfileId) === String(profile.id)) state.hotkeyProfileId = '';
        updateDirtyStatus();
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
    updateDirtyStatus();
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
  if (!validateCustomHotkeyRows()) return;
  syncCustomHotkeyDraft();
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
function hotkeyApplicationSelected(profile, sessionId) {
  if (!isLoaded() || isSaving() || sessionId !== state.sessionId) return;
  if (!profile || !profile.id || !profile.exePath || !state.draft) {
    post({ type: 'hotkeyPickerTrace', stage: 'profile_callback_invalid' });
    return;
  }
  if (!validateCustomHotkeyRows()) return;
  syncCustomHotkeyDraft();
  const profiles = Array.isArray(state.draft.profiles) ? state.draft.profiles : [];
  const previousProfileId = state.hotkeyProfileId;
  const existing = profiles.find(item => String(item.id) === String(profile.id)
    || String(item.exePath || '').toLowerCase() === String(profile.exePath || '').toLowerCase());
  if (existing) profile = existing;
  else profiles.push(clone(profile));
  state.draft.profiles = profiles;
  state.hotkeyProfileId = String(profile.id);
  if (!existing) updateDirtyStatus();
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
  const timings = {};
  for (const [phase, render] of [
    ['formsMs', renderSettingsForms], ['controlsMs', refreshStaticControls],
    ['shortcutsMs', () => renderHotkeyEditor(previousProfileId)],
    ['tabMs', () => renderPairs('TabHotString', 'tabList', true)],
    ['pluginsMs', renderPlugins], ['bindingsMs', renderBindings]
  ]) {
    const startedAt = performance.now();
    render();
    timings[phase] = Math.round(performance.now() - startedAt);
  }
  return timings;
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
function resolveTestSecret(value) {
  return value.op === 'set' ? value.value : value.op === 'clear' ? '' : undefined;
}
function buildLlmTest() {
  const values = clone(section('LLM'));
  const key = resolveTestSecret(values.apiKey);
  if (key === undefined) delete values.apiKey; else values.apiKey = key;
  return { type: 'testSettings', target: 'llm', ...values };
}
function buildTranslationTest(target) {
  const payload = { type: 'testSettings', target, targetLanguage: section('TTranslate').targetLanguage };
  const fields = target === 'youdao'
    ? [['TYoudao', 'appPaidID', 'appId'], ['TYoudao', 'appPaidKey', 'appKey']]
    : [['TVolcengine', 'accessKey', 'volcAccessKey'], ['TVolcengine', 'secretKey', 'volcSecretKey']];
  for (const [sectionName, key, name] of fields) {
    const value = resolveTestSecret(section(sectionName)[key]);
    if (value !== undefined) payload[name] = value;
  }
  if (target === 'volcengine') payload.volcRegion = section('TVolcengine').region;
  return payload;
}

function applySettingsSnapshot(snapshot, committed = false) {
  const startedAt = performance.now();
  if (!snapshot?.sessionId || !snapshot.config || !snapshot.schema
    || !Array.isArray(snapshot.config.profiles) || !Array.isArray(snapshot.config.plugins)
    || !Array.isArray(snapshot.config.bindings) || !Number.isSafeInteger(snapshot.revision))
    throw new Error('Invalid settings snapshot');
  if (!committed && isSaving()) return false;
  if (!committed && state.sessionId === snapshot.sessionId && isLoaded()) {
    setPage(snapshot.page || state.page, false);
    if (snapshot.toast) showToast(snapshot.toast);
    reportSettingsTiming(snapshot, 'snapshot-reuse', startedAt);
    return true;
  }
  if (!committed && hasChanges()) return false;
  if (!setTranslationLanguageCatalog(snapshot.languageCatalog))
    throw new Error('Invalid language catalog');
  clearPendingRequests();
  stopShortcutRecording(false);
  closeWindowPickerDialog();
  AppDialog.dismiss();
  const selectedProfileId = state.hotkeyProfileId;
  state.schema = snapshot.schema;
  state.sessionId = snapshot.sessionId;
  state.revision = snapshot.revision;
  state.base = clone(snapshot.config);
  state.draft = clone(snapshot.config);
  state.customHotkeyActions = normalizeCustomHotkeyActions(snapshot.customHotkeyActions);
  state.bindingModes = snapshot.bindingModes;
  state.hotkeyProfileId = state.draft.profiles.some(profile => profile.id === selectedProfileId)
    ? selectedProfileId : '';
  document.documentElement.lang = snapshot.uiLanguage === 'en' ? 'en' : 'zh-CN';
  $('.side-foot').textContent = 'v' + snapshot.appVersion;
  const setupMs = Math.round(performance.now() - startedAt);
  const timings = renderAll(selectedProfileId);
  setSettingsLoaded(true);
  setPage(snapshot.page || state.page || 'general', false);
  if (!committed) setStatus('');
  if (snapshot.toast) showToast(snapshot.toast);
  reportSettingsTiming(snapshot, 'render', startedAt, { setupMs, ...timings,
    optionCount: document.querySelectorAll('option').length });
  const sessionId = state.sessionId;
  requestAnimationFrame(() => requestAnimationFrame(() => {
    if (state.sessionId === sessionId && isLoaded()) reportSettingsTiming(snapshot, 'paint', startedAt);
  }));
  return true;
}
function reportSettingsTiming(snapshot, stage, startedAt, metrics = {}) {
  post({ type: 'settingsTiming', openTraceId: snapshot.openTraceId,
    stage, ms: Math.round(performance.now() - startedAt), ...metrics });
}
function editableDocument(document) {
  return { sections: clone(document.sections),
    profiles: [...document.profiles].sort((a, b) => a.id.localeCompare(b.id)),
    plugins: editablePluginSnapshot(document.plugins),
    bindings: editableBindingSnapshot(document.bindings) };
}
function hasChanges() {
  return !!state.base && !!state.draft && (
    stableJson(editableDocument(state.draft)) !== stableJson(editableDocument(state.base))
    || (isLoaded() && (!!findPairRowError($('#tabList')) || !!findCustomHotkeyError())));
}

function editablePluginSnapshot(plugins) {
  const aliases = values => [...new Set(values.map(alias => String(alias).trim().replace(/\s+/g, ' ').toLowerCase()).filter(Boolean))].sort();
  return plugins.map(plugin => plugin.draftId
    ? { draftId: plugin.draftId, kind: plugin.kind, name: plugin.name.trim(),
        enabled: plugin.enabled, settings: clone(plugin.settings), aliases: aliases(plugin.aliases) }
    : { pluginId: plugin.pluginId, name: plugin.name.trim(), enabled: plugin.enabled,
        settings: clone(plugin.settings), commands: plugin.commands.map(command => ({
          commandId: command.commandId, aliases: aliases(command.aliases)
        })).sort((a, b) => a.commandId.localeCompare(b.commandId)) }
  ).sort((a, b) => (a.pluginId || a.draftId).localeCompare(b.pluginId || b.draftId));
}

function editableBindingSnapshot(bindings) {
  return bindings.map(binding => ({ number: Number(binding.number), bindType: Number(binding.bindType),
    applicationPath: binding.applicationPath || '', selectionToken: binding.selectionToken || '',
    items: (binding.items || []).map(item => ({ path: item.path || '', exe: item.exe || '',
      windowClass: item.windowClass || '' })) })).sort((a, b) => a.number - b.number);
}

function saveDraft() {
  if (!isLoaded() || !state.draft || isSaving()) return;
  if (!validatePairRows($('#tabList')) || !validateCustomHotkeyRows()) return;
  updatePairDraft('TabHotString', $('#tabList'));
  syncCustomHotkeyDraft();
  stopShortcutRecording();
  if (!hasChanges()) { setStatus('没有需要保存的变化'); return; }
  $$('.secret-control input').forEach(cancelSecretRequest);
  setSettingsSaving(true);
  if (!request({ type: 'saveSettings', page: state.page,
    revision: state.revision, draft: editableDocument(state.draft) }, 'saved',
    result => settingsSaved(result.ok, result.text, result.snapshot, result.timedOut))) {
    setSettingsSaving(false);
    setStatus('无法发送保存请求，修改仍保留。请重试。', true);
  }

}

function receiveBindingCandidate(candidate) {
  if (!candidate || !state.draft || isSaving() || candidate.sessionId !== state.sessionId) return;
  const rows = Array.isArray(state.draft.bindings) ? state.draft.bindings : [];
  const index = rows.findIndex(item => Number(item.number) === Number(candidate.number));
  if (index < 0) return;
  rows[index] = editableBindingSnapshot([candidate])[0];

  renderBindings();
  setStatus('窗口选择已暂存，请点击右上角“保存”后生效。');
};

function clearWindowBinding(binding) {
  if (!binding || isSaving()) return;
  const index = (state.draft.bindings || []).findIndex(item => Number(item.number) === Number(binding.number));
  if (index < 0) return;
  post({ type: 'clearWindowBindingCandidate', number: binding.number });
  state.draft.bindings[index] = {
    number: binding.number, bindType: 0, applicationPath: '', items: []
  };

  renderBindings();
  updateDirtyStatus();
}
function reportSettingsPageError(error, phase) {
  const location = String(error?.stack || '').match(/settings-page\.js:(\d+):(\d+)/);
  post({ type: 'settingsPageError', phase, errorType: String(error?.name || 'Error'),
    line: location ? Number(location[1]) : 0, column: location ? Number(location[2]) : 0 });
}
function receiveSnapshot(snapshot) {
  try { return applySettingsSnapshot(snapshot); }
  catch (error) {
    reportSettingsPageError(error, 'load');
    settingsLoadFailed();
    return false;
  }
};
function settingsSaved(ok, text, snapshot, timedOut) {
  if (!isSaving()) return;
  if (timedOut) {
    setSettingsLoaded(false);
    setStatus('未收到保存结果，请重新加载应用后确认设置。', true);
    return;
  }
  try {
    if (ok && (snapshot?.sessionId !== state.sessionId || !applySettingsSnapshot(snapshot, true)))
      throw new Error('Incomplete save receipt');
    setStatus(text || (ok ? '设置已保存。' : '保存失败，修改仍保留。'), !ok);
  } catch (error) {
    reportSettingsPageError(error, 'save-receipt');
    if (ok) state.base = clone(state.draft);
    setSettingsLoaded(false);
    setStatus(ok ? '设置已保存，请重新打开设置以载入最新内容。'
      : '无法加载保存结果，请重新打开设置。', true);
  } finally {
    setSettingsSaving(false);
  }
};
function settingsLoadFailed() {
  setSettingsLoaded(false);
  setStatus('无法加载设置，请重新打开设置。若仍失败，请查看错误日志。', true);
};
function settingsPickerFailed(sessionId) {
  if (sessionId === state.sessionId && isLoaded() && !isSaving())
    showToast('所选窗口已关闭或发生变化，请重新选择。', 'error');
};

function settingsTestResult(ok, text, sessionId) {
  if (!isLoaded() || isSaving() || sessionId !== state.sessionId) return;
  setStatus(hasChanges() ? '未保存' : '');
  showToast(ok ? '连接正常。' : (text || '连接检查失败，请检查配置。'), ok ? 'success' : 'error');
}

function requestSettingsExit(action) {
  if (isSaving()) return;
  const discard = () => {
    setEditorStatus('loading');
    stopShortcutRecording();
    closeWindowPickerDialog();
    AppDialog.dismiss();
    state.draft = state.base ? clone(state.base) : null;
    lockDisplayedSecrets();
    post({ type: 'discardSettingsDraft' });
    if (action === 'close') {
      post({ type: 'hide' });
      state.sessionId = '';
    } else {
      setSettingsLoaded(false);
      post({ type: 'getSettings' });
    }
  };
  if (!hasChanges()) { discard(); return; }
  AppDialog.confirm({ title: '未保存的修改', message: '当前页面的修改将被放弃，确定继续吗？',
    confirmText: '放弃更改', tone: 'danger' }).then(ok => { if (ok) discard(); });
}
$('#nav').addEventListener('click', event => { const button = event.target.closest('button[data-page]'); if (button) setPage(button.dataset.page); });
$('#saveBtn').addEventListener('click', saveDraft);
$('#cancelBtn').addEventListener('click', () => requestSettingsExit('discard'));
window.addEventListener('keydown', event => {
  if (!isSaving() && isLoaded()) return;
  event.preventDefault();
  event.stopImmediatePropagation();
}, true);

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

const messageHandlers = {
  snapshot: receiveSnapshot,
  windowPicker: receiveWindowPicker,
  closeWindowPicker: closeWindowPickerDialog,
  applicationSelected: payload => hotkeyApplicationSelected(payload.profile, payload.sessionId),
  bindingCandidate: receiveBindingCandidate, pickerFailed: payload => settingsPickerFailed(payload.sessionId),
  shortcutCapture: receiveShortcutCapture, shortcutCaptureFailed,
  testResult: payload => settingsTestResult(payload.ok, payload.text, payload.sessionId),
  loadFailed: settingsLoadFailed, requestClose: () => requestSettingsExit('close'),
  openApplicationDialog: openHotkeyApplicationDialog
};
chrome.webview.addEventListener('message', event => {
  const message = event.data;
  if (!message || typeof message !== 'object') return;
  const pending = pendingRequests.get(Number(message.payload?.requestId));
  try {
    if (pending) {
      if (message.type !== pending.responseType || message.payload.sessionId !== pending.sessionId
        || state.sessionId !== pending.sessionId) return;
      cancelRequest(message.payload.requestId);
      pending.onReply(message.payload);
    } else if (Object.hasOwn(messageHandlers, message.type)) {
      messageHandlers[message.type](message.payload);
    }
  } catch (error) {
    reportSettingsPageError(error, message.type);
    if (isSaving()) { setSettingsLoaded(false); setStatus('无法载入保存结果，请重新打开设置。', true); }
  }
});

setEditorStatus('loading');
document.addEventListener('click', event => {
  const action = event.target.closest('[data-settings-action]')?.dataset.settingsAction;
  if (!action || !isLoaded() || isSaving()) return;
  if (action === 'openLlm') { setPage('llm'); return; }
  setStatus('测试中…');
  if (!post(action === 'testLlm' ? buildLlmTest()
    : buildTranslationTest(action === 'testYoudao' ? 'youdao' : 'volcengine')))
    setStatus('无法发送连接检查请求，请重试。', true);
});
post({ type: 'getSettings' });

})();
