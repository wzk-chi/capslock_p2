/* Shared API settings overlay, mounted by both WebView2 panels (translator +
   AI chat). Extracted from the translator's in-page settings view so every
   panel shows the same dialog.

   A page calls LLMSettings.mount({ targetLanguage: bool, engines: bool,
   provider: bool }); the AHK host keeps receiving the same getSettings /
   saveSettings / testSettings messages and answers through window.setSettings
   / window.setTestResult / window.setSaved, exactly as before.
   saveSettings / testSettings carry a "provider" field matching the AHK-side
   translation provider registry (lib\translate.ahk): each engine registers
   there with TranslateRegisterProvider and is mirrored in PROVIDERS below —
   adding an engine means one entry on each side. Pages can hook
   window.onHostSettings to react to pushed settings (ui language, mode, ...). */
(function () {
  const STRINGS = {
    en: {
      settingsTitle: 'API Settings',
      settingsHint: 'Each engine keeps its own credentials, stored in capslock_p2.ini.',
      firstNotice: 'First time use: fill in an API config below, click Test to confirm the connection, then Save.',
      tabLlm: 'LLM API',
      tabYoudao: 'Youdao',
      tabVolcengine: 'Volcengine',
      endpointLabel: 'API URL (endpoint)',
      endpointHint: 'Base URL is enough — /v1/chat/completions is appended automatically (…/v1 → only /chat/completions). A full URL is used as-is.',
      apiKeyLabel: 'API Key',
      modelLabel: 'Model',
      targetLanguageLabel: 'Target Language',
      targetPlaceholder: 'e.g. Simplified Chinese. Empty = auto (non-Chinese → Simplified Chinese, Chinese → English)',
      appIdLabel: 'App ID (appPaidID)',
      appKeyLabel: 'App Secret (appPaidKey)',
      youdaoTargetLanguageLabel: 'Target Language',
      volcAccessKeyLabel: 'AccessKey ID',
      volcSecretKeyLabel: 'Secret AccessKey',
      volcTargetLanguageLabel: 'Target Language',
      engineLabel: 'Translation engine',
      engineAuto: 'Auto — LLM first, others fallback',
      engineLlm: 'LLM',
      engineYoudao: 'Youdao',
      engineVolcengine: 'Volcengine',
      youdaoHint: 'Youdao Smart Cloud (paid) translation API. Apply at https://ai.youdao.com/console/#/ — new accounts get trial credit. Translation uses LLM first; other engines are used automatically when no LLM is configured.',
      volcengineHint: 'Volcengine machine translation API. Apply at https://console.volcengine.com/translate. Translation uses LLM first; other engines are used automatically when no LLM is configured.',
      test: 'Test',
      save: 'Save',
      cancel: 'Cancel',
      testing: 'Testing…',
      needEndpoint: 'Please fill in the API URL first.',
      needAppId: 'Please fill in the app ID and app secret first.',
      needVolcKeys: 'Please fill in the AccessKey ID and Secret AccessKey first.'
    },
    zh: {
      settingsTitle: 'API 设置',
      settingsHint: '各引擎凭据独立保存于 capslock_p2.ini。',
      firstNotice: '首次使用：请填写下方 API 配置，点「测试」确认连通后保存。',
      tabLlm: 'LLM API',
      tabYoudao: '有道翻译',
      tabVolcengine: '火山翻译',
      endpointLabel: 'API 地址（endpoint）',
      endpointHint: '填 Base URL 即可，会自动补上 /v1/chat/completions（填 …/v1 则只补 /chat/completions）；填完整地址则原样使用。',
      apiKeyLabel: 'API Key',
      modelLabel: '模型（Model）',
      targetLanguageLabel: '目标语言',
      targetPlaceholder: '如 简体中文；留空 = 自动（非中文→简体中文，中文→英文）',
      appIdLabel: '应用ID（appPaidID）',
      appKeyLabel: '应用密钥（appPaidKey）',
      youdaoTargetLanguageLabel: '目标语言',
      volcAccessKeyLabel: 'AccessKey ID',
      volcSecretKeyLabel: 'Secret AccessKey',
      volcTargetLanguageLabel: '目标语言',
      engineLabel: '翻译引擎',
      engineAuto: '自动（优先 LLM，未配置时用其他引擎）',
      engineLlm: 'LLM',
      engineYoudao: '有道翻译',
      engineVolcengine: '火山翻译',
      youdaoHint: '有道智云收费版翻译 API。申请：https://ai.youdao.com/console/#/（新账号有试用额度）。翻译优先使用 LLM；未配置 LLM 时自动使用其他引擎。',
      volcengineHint: '火山引擎机器翻译 API。申请：https://console.volcengine.com/translate。翻译优先使用 LLM；未配置 LLM 时自动使用其他引擎。',
      test: '测试',
      save: '保存',
      cancel: '取消',
      testing: '测试中…',
      needEndpoint: '请先填写 API 地址。',
      needAppId: '请先填写应用ID和应用密钥。',
      needVolcKeys: '请先填写 AccessKey ID 和 Secret AccessKey。'
    }
  };

  // Translation engines, mirroring the AHK provider registry
  // (lib\translate.ahk, TranslateRegisterProvider). `show` hides an engine's
  // tab when the host page did not mount it; `required` returns the STRINGS
  // key of the missing-field message, or '' when the form is complete.
  const ENGINE_AUTO = ['auto', 'engineAuto'];
  const PROVIDERS = [
    {
      id: 'llm',
      // targetLanguage belongs to the translator page only.
      fields: (o) => o.targetLanguage
        ? ['endpoint', 'apiKey', 'model', 'targetLanguage']
        : ['endpoint', 'apiKey', 'model'],
      required: (form) => (form.endpoint ? '' : 'needEndpoint')
    },
    {
      id: 'youdao',
      show: (o) => !!o.engines,
      fields: () => ['appId', 'appKey', 'youdaoTargetLanguage'],
      required: (form) => ((form.appId && form.appKey) ? '' : 'needAppId'),
      paneHint: 'youdaoHint'
    },
    {
      id: 'volcengine',
      show: (o) => !!o.engines,
      fields: () => ['volcAccessKey', 'volcSecretKey', 'volcTargetLanguage'],
      required: (form) => ((form.volcAccessKey && form.volcSecretKey) ? '' : 'needVolcKeys'),
      paneHint: 'volcengineHint'
    }
  ];
  const FIELD_HINTS = { endpoint: 'endpointHint' };
  const FIELD_DATALISTS = {
    targetLanguage: ['Simplified Chinese', 'Traditional Chinese', 'English', 'Japanese', 'Korean', 'French', 'German', 'Spanish', 'Russian'],
    youdaoTargetLanguage: ['Simplified Chinese', 'Traditional Chinese', 'English', 'Japanese', 'Korean', 'French', 'German', 'Spanish', 'Russian'],
    volcTargetLanguage: ['Simplified Chinese', 'Traditional Chinese', 'English', 'Japanese', 'Korean', 'French', 'German', 'Spanish', 'Russian']
  };
  const FIELD_PLACEHOLDERS = { targetLanguage: 'targetPlaceholder', youdaoTargetLanguage: 'targetPlaceholder', volcTargetLanguage: 'targetPlaceholder' };

  // Scoped styles: the overlay carries its own rules so host pages with
  // different layouts all render the identical dialog.
  const CSS = `
.llmset { position: fixed; inset: 0; background: inherit; padding: 18px; display: none; flex-direction: column; overflow-y: auto; z-index: 10; }
.llmset h2 { margin: 0; font-size: 16px; font-weight: 650; }
.llmset .hint { color: #697386; font-size: 12px; margin-top: 2px; }
.llmset-body { display: flex; gap: 16px; margin-top: 14px; flex: 1; min-height: 0; }
.llmset-tabs { display: flex; flex-direction: column; gap: 4px; min-width: 104px; }
.llmset-tabs button { text-align: left; border: 0; border-radius: 8px; padding: 9px 14px; background: transparent; color: #697386; cursor: pointer; font-weight: 600; font-size: 13px; }
.llmset-tabs button:hover { background: #e8eefb; color: #356ae6; }
.llmset-tabs button.active { background: #356ae6; color: #fff; }
.llmset-panes { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.llmset-pane { display: none; }
.llmset-pane.active { display: block; }
.llmset label { font-size: 12px; color: #697386; display: block; margin: 10px 0 4px; }
.llmset input, .llmset select { width: 100%; padding: 9px 11px; border: 1px solid #d5dae3; border-radius: 8px; background: #fff; color: #20242b; font: 13px/1.4 Consolas, "Microsoft YaHei", monospace; outline: none; }
.llmset select { font-family: "Segoe UI", "Microsoft YaHei", sans-serif; }
.llmset input:focus, .llmset select:focus { border-color: #4b7bec; box-shadow: 0 0 0 3px #4b7bec22; }
.llmset .fieldStatus { min-height: 18px; margin-top: 10px; font-size: 12px; color: #697386; white-space: pre-wrap; word-break: break-all; }
.llmset .fieldStatus.ok { color: #1c7c3c; }
.llmset .fieldStatus.err { color: #c0392b; }
.llmset .actions { display: flex; gap: 10px; margin-top: 12px; }
.llmset button { border: 0; border-radius: 8px; padding: 8px 16px; background: #356ae6; color: white; cursor: pointer; font-weight: 600; }
.llmset button:hover { background: #2859c7; }
.llmset button:disabled { background: #9aa8c2; cursor: wait; }
.llmset button.secondary { background: transparent; color: #356ae6; border: 1px solid #b9c6e8; font-weight: 500; }
.llmset button.secondary:hover { background: #e8eefb; }
.llmset .notice { border: 1px solid #e5c96b; background: #fdf6e3; color: #7a5b00; padding: 10px 12px; border-radius: 8px; font-size: 13px; margin: 10px 0 2px; }
@media (prefers-color-scheme: dark) {
  .llmset input, .llmset select { border-color: #46505f; background: #2b313b; color: #eef1f6; }
  .llmset .hint, .llmset label { color: #aab4c4; }
  .llmset-tabs button { color: #aab4c4; }
  .llmset-tabs button:hover { background: #2b3547; color: #8db0f5; }
  .llmset button.secondary { color: #8db0f5; border-color: #4a5b82; }
  .llmset button.secondary:hover { background: #2b3547; }
  .llmset .notice { background: #38311c; border-color: #6b5b25; color: #e8c66a; }
}`;

  let root = null;
  let options = {};
  let inputs = {};
  let labels = {};
  let hints = {};
  let paneHints = {};
  let engineSelect = null;
  let fieldStatus = null;
  let notice = null;
  let titleNode = null;
  let hintNode = null;
  let tabsNode = null;
  let tabButtons = {};
  let panes = {};
  let activeTab = 'llm';
  let testBtn = null;
  let saveBtn = null;
  let backBtn = null;
  let values = {};
  let lang = (navigator.language || '').toLowerCase().startsWith('zh') ? 'zh' : 'en';

  function t(key) {
    return (STRINGS[lang] && STRINGS[lang][key]) || STRINGS.en[key] || key;
  }

  function post(obj) {
    if (window.chrome && chrome.webview)
      chrome.webview.postMessage(JSON.stringify(obj));
  }

  function postType(type, text) {
    post({ type: type, text: text || '' });
  }

  function el(tag, className, parent) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (parent) parent.appendChild(node);
    return node;
  }

  function visibleProviders() {
    return PROVIDERS.filter((p) => !p.show || p.show(options));
  }

  function providerDef(id) {
    return PROVIDERS.find((p) => p.id === id) || PROVIDERS[0];
  }

  function fieldsOf(provider) {
    return providerDef(provider).fields(options);
  }

  function addField(providerId, name, hintKey, datalist) {
    const pane = panes[providerId];
    const label = el('label', '', pane);
    label.setAttribute('for', 'llmset-' + name);
    labels[name] = label;   // element; the string key is name + 'Label'
    let listId = '';
    if (datalist) {
      listId = 'llmset-list-' + name;
      const list = el('datalist', '', pane);
      list.id = listId;
      for (const option of datalist) {
        const opt = document.createElement('option');
        opt.value = option;
        list.appendChild(opt);
      }
    }
    const input = el('input', '', pane);
    input.id = 'llmset-' + name;
    input.spellcheck = false;
    if (listId) input.setAttribute('list', listId);
    inputs[name] = input;
    if (hintKey) {
      hints[name] = el('div', 'hint', pane);
      hints[name].style.marginTop = '4px';
    }
    return input;
  }

  function switchTab(provider) {
    activeTab = provider;
    for (const tab of Object.keys(tabButtons))
      tabButtons[tab].classList.toggle('active', tab === provider);
    for (const pane of Object.keys(panes))
      panes[pane].classList.toggle('active', pane === provider);
  }

  function readForm(provider) {
    const form = { provider };
    for (const name of fieldsOf(provider))
      form[name] = inputs[name].value.trim();
    if (engineSelect)
      form.engine = engineSelect.value;
    return form;
  }

  function validateForm(provider) {
    const form = readForm(provider);
    const needKey = providerDef(provider).required(form);
    if (needKey) {
      fieldStatus.textContent = t(needKey);
      fieldStatus.className = 'fieldStatus err';
      return null;
    }
    return form;
  }

  function applyTexts() {
    titleNode.textContent = t('settingsTitle');
    hintNode.textContent = t('settingsHint');
    notice.textContent = t('firstNotice');
    for (const tab of Object.keys(tabButtons))
      tabButtons[tab].textContent = t('tab' + tab.charAt(0).toUpperCase() + tab.slice(1));
    for (const name of Object.keys(labels))
      labels[name].textContent = t(name + 'Label');
    for (const name of Object.keys(hints))
      hints[name].textContent = t(FIELD_HINTS[name] || '');
    for (const id of Object.keys(paneHints))
      paneHints[id].textContent = t(providerDef(id).paneHint || '');
    if (engineSelect) {
      labels.engine.textContent = t('engineLabel');
      for (const opt of engineSelect.options)
        opt.textContent = t(opt.dataset.labelKey);
    }
    for (const name of Object.keys(FIELD_PLACEHOLDERS))
      if (inputs[name])
        inputs[name].placeholder = t(FIELD_PLACEHOLDERS[name]);
    testBtn.textContent = t('test');
    saveBtn.textContent = t('save');
    backBtn.textContent = t('cancel');
  }

  function close() {
    if (!root)
      return;
    root.style.display = 'none';
    postType('settings', 'close');
  }

  window.LLMSettings = {
    mount: function (mountOptions) {
      options = Object.assign({}, mountOptions || {});
      const style = document.createElement('style');
      style.textContent = CSS;
      document.head.appendChild(style);

      root = el('div', 'llmset', document.body);
      titleNode = el('h2', 'llmset-title', root);
      hintNode = el('div', 'hint llmset-hint', root);
      notice = el('div', 'notice', root);
      notice.style.display = 'none';

      if (options.provider) {
        const engineWrap = el('div', '', root);
        const engineLabel = el('label', '', engineWrap);
        engineLabel.setAttribute('for', 'llmset-engine');
        labels.engine = engineLabel;
        engineSelect = el('select', '', engineWrap);
        engineSelect.id = 'llmset-engine';
        const engineOptions = [ENGINE_AUTO].concat(
          visibleProviders().map((p) => [p.id, 'engine' + p.id.charAt(0).toUpperCase() + p.id.slice(1)]));
        for (const [value, labelKey] of engineOptions) {
          const opt = document.createElement('option');
          opt.value = value;
          opt.dataset.labelKey = labelKey;
          engineSelect.appendChild(opt);
        }
      }

      const body = el('div', 'llmset-body', root);
      tabsNode = el('nav', 'llmset-tabs', body);

      const tabDefs = visibleProviders();
      if (tabDefs.length < 2)
        tabsNode.style.display = 'none';

      const panesWrap = el('div', 'llmset-panes', body);
      for (const tabDef of tabDefs) {
        const id = tabDef.id;
        const button = el('button', '', tabsNode);
        button.addEventListener('click', () => switchTab(id));
        tabButtons[id] = button;
        panes[id] = el('div', 'llmset-pane', panesWrap);
        for (const name of tabDef.fields(options))
          addField(id, name, FIELD_HINTS[name] || '', FIELD_DATALISTS[name] || null);
        if (tabDef.paneHint) {
          paneHints[id] = el('div', 'hint', panes[id]);
          paneHints[id].style.marginTop = '10px';
        }
      }

      fieldStatus = el('div', 'fieldStatus', panesWrap);
      const actions = el('div', 'actions', panesWrap);
      testBtn = el('button', '', actions);
      saveBtn = el('button', '', actions);
      backBtn = el('button', 'secondary', actions);

      testBtn.addEventListener('click', () => {
        const form = validateForm(activeTab);
        if (!form)
          return;
        fieldStatus.textContent = t('testing');
        fieldStatus.className = 'fieldStatus';
        testBtn.disabled = true;
        post(Object.assign({ type: 'testSettings' }, form));
      });
      saveBtn.addEventListener('click', () => {
        saveBtn.disabled = true;
        post(Object.assign({ type: 'saveSettings' }, readForm(activeTab)));
      });
      backBtn.addEventListener('click', close);

      switchTab('llm');
      window.setSettings(values);
    },
    open: function (firstRun) {
      if (!root)
        return;
      notice.style.display = firstRun ? 'block' : 'none';
      root.style.display = 'flex';
      fieldStatus.textContent = '';
      fieldStatus.className = 'fieldStatus';
      postType('settings', 'open');
      const firstField = fieldsOf(activeTab)[0];
      if (inputs[firstField])
        inputs[firstField].focus();
    }
  };

  /* ---- host -> page, same function names as the old in-page view ---- */

  window.setSettings = function (s) {
    if (s) values = Object.assign(values, s);
    lang = values.uiLanguage === 'zh' ? 'zh' : 'en';
    for (const name of Object.keys(inputs))
      inputs[name].value = values[name] || '';
    if (engineSelect)
      engineSelect.value = PROVIDERS.some((p) => p.id === values.engine) ? values.engine : 'auto';
    applyTexts();
    if (typeof window.onHostSettings === 'function')
      window.onHostSettings(values);
  };

  window.openSettings = function (firstRun) {
    LLMSettings.open(firstRun);
  };

  window.setTestResult = function (ok, text) {
    fieldStatus.textContent = text || '';
    fieldStatus.className = 'fieldStatus ' + (ok ? 'ok' : 'err');
    testBtn.disabled = false;
  };

  window.setSaved = function (ok, text) {
    fieldStatus.textContent = text || '';
    fieldStatus.className = 'fieldStatus ' + (ok ? 'ok' : 'err');
    saveBtn.disabled = false;
    if (ok) setTimeout(close, 800);
  };
})();
