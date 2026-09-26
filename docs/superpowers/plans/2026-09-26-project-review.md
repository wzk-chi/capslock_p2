# capslock_p2 Project Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair confirmed correctness/privacy issues and progressively simplify capslock_p2 into a single-config, single-settings-center WebView2 application without changing the main CapsLock workflows.

**Architecture:** Keep the existing AHK v2 entry point and provider contracts, but introduce explicit configuration and panel-host boundaries. Complete correctness and privacy fixes first, then remove runtime dependencies for the retired calculator/QStyle features, then split qbar and shared WebView2 code behind stable public entry functions.

**Tech Stack:** AutoHotkey v2, WebView2, HTML/CSS/vanilla JavaScript, WinHTTP, SQLite/CSQLite, Inno Setup resource layout.

**Spec:** `docs/superpowers/specs/2026-09-26-project-review-design.md`

## Global Constraints

- `AGENTS.md` forbids writing tests, starting/running scripts, deleting files, and modifying `capslock-plus/`.
- Do not run AutoHotkey, JavaScript, the compiled application, Everything, Ahk2Exe, Inno Setup, or an installer during implementation.
- Use the existing WebView2, SQLite, JSON, Promise, and crypto implementations; do not add a package manager or runtime dependency.
- Keep public entry functions used by `lib/keymap.ahk`, `lib/keys.ahk`, qbar commands, and user extensions stable unless a compatibility wrapper is explicitly added.
- Preserve user configuration files: legacy `[QStyle]`, calculator, and `loadScript` keys are ignored after migration but are not deleted automatically.
- Never log API keys, endpoint query strings, selected text, qbar input, AI questions, translation text, or clipboard contents.
- Verification is static only: `git diff --check`, `rg` reference checks, INI/HTML/resource consistency checks, and Git status/diff review.

---

## File map and ownership

The implementation uses these boundaries:

- `lib/config.ahk`: configuration loading, default migration, typed reads, safe writes, and change application.
- `lib/core.ahk`: process initialization, clipboard/selection services, language/DPI helpers, tray, and loading UI; it calls `Config*` instead of owning INI parsing.
- `lib/windowBinding.ahk` (new): binding persistence, capture modes, stale-window maintenance, and activation; `lib/windows.ahk` keeps transparency and mouse-speed behavior.
- `lib/panelHost.ahk` (new): reusable WebView2 GUI/controller lifecycle, page execution, navigation state, and focus monitor helpers.
- `lib/tabHotString.ahk` (new): CapsLock+Tab hotstring replacement only.
- `lib/qbar.ahk`: stable qbar facade and shared state.
- `lib/qbar_panel.ahk`, `lib/qbar_index.ahk`, `lib/qbar_commands.ahk`, `lib/qbar_everything.ahk`, `lib/qbar_navigation.ahk`: qbar responsibilities split by data source and behavior.
- `lib/llm.ahk`, `lib/translate.ahk`, `lib/llmTranslate.ahk`, `lib/aiChat.ahk`: retain provider and feature contracts, but use `PanelHost` and central settings.
- `lib/settings.ahk`: central settings-window host, schema, snapshot/save/test routing, and window-binding capture bridge.
- `pages/settings.html`: sole live settings UI, including qbar backend fields and descriptive window binding labels.
- `pages/chat.html`, `pages/translate.html`: feature panels only; their settings buttons send `openSettings` to AHK and no longer mount the embedded settings component.
- `pages/settings.js`: retained in the repository for resource compatibility, but no live page references it after Task 6.
- `README.md`, `docs/architecture.md`, `docs/packaging.md`, `pages/usage.html`, `tools/capslock_p2-default.ini`, `capslock_p2-settingsDemo.ini`: synchronized documentation/configuration surface.

## Static verification convention

Because tests and runtime execution are forbidden, each task ends with:

```powershell
git diff --check
rg -n "QStyle|EvaluateExpression|settings.js|loadScript|DebugLog\(" lib pages README.md docs tools capslock_p2-settingsDemo.ini
git status --short
```

The exact `rg` patterns for each task are listed below. A task is not marked complete when a pattern still finds a live reference that the task was supposed to remove.

### Task 1: Repair window binding lifecycle and validation

**Files:**

- Modify: `lib/windows.ahk`
- Modify: `lib/settings.ahk`
- Modify: `pages/settings.html`
- Modify: `README.md`

**Interfaces:**

- Preserve `BindWindowFromActive(bindingNumber, bindType)`, `BindingTap(bindingNumber)`, `activateWinAction(bindingNumber)`, `winsSort(bindingNumber)`, and `getWinInfo(bindingNumber, bindType)`.
- Add `WindowBindingType(value, fallback := 1) -> Integer` to clamp capture mode values to `1..3`.
- Add `WindowBindingDisplay(type) -> Map` returning `{label, description}` for the settings snapshot/UI.
- Preserve the serialized fields `bindType`, `count`, `id_N`, `class_N`, `exe_N`, and `path_N`.

- [ ] **Step 1: Reproduce the stale-handle control flow statically.** Confirm that `activateWinAction()` currently prunes a type-1 item before `FindReplacementWindow()` and that type 3 never prunes. Record the function names in the change description; do not run the script.
- [ ] **Step 2: Make type-1 activation recoverable.** Handle type 1 through `FindReplacementWindow()` before pruning. If the HWND is dead, search the stored class/executable; if no replacement exists and `path` exists, launch the stored path. Only remove the binding after recovery and launch both fail.
- [ ] **Step 3: Make type-2 and type-3 lists hygienic.** Prune dead HWNDs before cycling; then refresh type-3 windows by the first item’s class/executable; deduplicate by HWND after refresh. Save a changed list only when its contents changed, so activation does not write the INI on every key press.
- [ ] **Step 4: Validate settings capture fields.** Use `WindowBindingType()` for `bindType`; accept a binding number only when it is an integer from 1 to 10 before scheduling the delayed capture.
- [ ] **Step 5: Replace opaque labels.** In `pages/settings.html`, render `单个窗口`, `窗口组`, and `同应用窗口`, plus the short descriptions from the snapshot. Keep the selection values `1`, `2`, and `3` unchanged.
- [ ] **Step 6: Update the user-facing window-binding section in `README.md`.** Explain activation versus capture with one example for each mode and remove “短按/双击/三击” wording where the settings page is the capture surface.
- [ ] **Step 7: Run static verification.** Use `git diff --check`; search for `当前窗口|追加窗口|同类窗口` and leave those old labels only in explicitly retained migration/compatibility notes; search for `bindType` to confirm all numeric entry points use the clamp helper.
- [ ] **Step 8: Commit.**

```powershell
git add lib/windows.ahk lib/settings.ahk pages/settings.html README.md
git commit -m "fix: stabilize window binding lifecycle"
```

### Task 2: Fix Everything decoding and remove private data from logs

**Files:**

- Modify: `lib/qbar.ahk`
- Modify: `lib/llm.ahk`
- Modify: `lib/youdaoTranslate.ahk`
- Modify: `lib/core.ahk`
- Modify: `docs/architecture.md`
- Modify: `README.md`

**Interfaces:**

- Preserve `QbarIsValidUtf8(buf, size)`, `QbarParseEsCsv(path)`, `DebugLog(message)`, and all LLM/provider public functions.
- Add `DebugLogPrivate(label, value) -> void`, logging only `label` and `StrLen(value)`.
- Add `LLMLogEndpoint(url) -> String`, returning protocol/host/path without query or fragment; it must never return the original query string.

- [ ] **Step 1: Define the safe log contract.** Add `DebugLogPrivate()` and use it for qbar query/execute/AI text, selected text, and any future private payload. It must not include the value, a substring of the value, or a reversible encoding.
- [ ] **Step 2: Replace qbar private logs.** Change logs at query receipt/apply, execution, no-match AI dispatch, and Everything search to report sequence IDs, row counts, selected type, and text length only.
- [ ] **Step 3: Sanitize LLM/provider logs.** Replace the raw endpoint log with `LLMLogEndpoint()`. Stop logging the Youdao app ID; retain only request character count, target code, HTTP status, and response length.
- [ ] **Step 4: Correct UTF-8 validation.** Permit bytes `0x00..0x7F`, reject isolated continuation bytes, validate 2/3/4-byte sequences and reject truncated sequences before `StrGet`. Preserve BOM handling and CP0 fallback for genuinely non-UTF-8 output.
- [ ] **Step 5: Update the privacy documentation.** State that debug logs contain lengths/counts/statuses only and never user input or credentials.
- [ ] **Step 6: Run static verification.** Search `DebugLog(` for concatenations with `text`, `arg`, `question`, `endpoint`, `apiKey`, `appID`, `A_Clipboard`, and `translation`; each result must either be removed, sanitized, or be a constant label. Run `git diff --check`.
- [ ] **Step 7: Commit.**

```powershell
git add lib/qbar.ahk lib/llm.ahk lib/youdaoTranslate.ahk lib/core.ahk docs/architecture.md README.md
git commit -m "fix: protect debug logs and decode file results safely"
```

### Task 3: Stop full reloads for small runtime changes

**Files:**

- Modify: `lib/core.ahk`
- Modify: `lib/keys.ahk`
- Modify: `lib/windows.ahk`
- Modify: `lib/settings.ahk`

**Interfaces:**

- Preserve `SetSettings(section, key, value)` and `ReloadSettings()`.
- Add `ApplySettingChange(section, key, value) -> void` for incremental runtime updates.
- Add `SettingInteger(section, key, fallback, minimum, maximum) -> Integer` and `SettingNumber(section, key, fallback, minimum, maximum) -> Number` for shared clamping.

- [ ] **Step 1: Add typed setting readers.** Implement the two helpers using `Config` values and explicit regex/number checks; invalid values return the fallback and are not written back automatically.
- [ ] **Step 2: Separate persistence from runtime application.** Make `SetSettings()` write and update the in-memory section, then call `ApplySettingChange()`; reserve `ReloadSettings()` for external file reloads and multi-section settings saves.
- [ ] **Step 3: Handle global settings incrementally.** Update `allowClipboard`, `debug`, `mouseSpeed`, `language`, `autostart`, and `loadingAnimation` directly. Only rebuild hotstrings, JavaScript compatibility state, or the key map when their specific sections change.
- [ ] **Step 4: Change runtime callers.** Mouse-speed and clipboard toggle actions must no longer parse the whole file, reinitialize JavaScript, refresh every derived setting, and rewrite the tray state on every press.
- [ ] **Step 5: Validate settings-page batches.** `SettingsApplyDraft()` continues to use one full reload after a multi-section save, but all scalar fields go through the typed helpers before being applied.
- [ ] **Step 6: Run static verification.** Search `SetSettings(` and `ReloadSettings()` call sites; confirm only batch saves/external reloads call the full reload path. Run `git diff --check`.
- [ ] **Step 7: Commit.**

```powershell
git add lib/core.ahk lib/keys.ahk lib/windows.ahk lib/settings.ahk
git commit -m "refactor: apply small settings changes incrementally"
```

### Task 4: Introduce the configuration boundary

**Files:**

- Create: `lib/config.ahk`
- Modify: `capslock_p2.ahk`
- Modify: `lib/core.ahk`
- Modify: `lib/settings.ahk`
- Modify: `lib/llm.ahk`
- Modify: `lib/llmTranslate.ahk`
- Modify: `lib/aiChat.ahk`
- Modify: `lib/qbar.ahk`
- Modify: `lib/youdaoTranslate.ahk`
- Modify: `lib/volcengineTranslate.ahk`

**Interfaces:**

- `ConfigLoad() -> void`
- `ConfigRead(section, key, defaultValue := "") -> String`
- `ConfigHas(section, key) -> Boolean`
- `ConfigSection(section) -> Map`
- `ConfigWrite(section, key, value) -> void`
- `ConfigWriteBatch(changes) -> void`
- `ConfigApplyDefaults() -> void`
- `ConfigSectionExists(section) -> Boolean`

- [ ] **Step 1: Move INI parsing/default migration.** Move `ParseIniFile`, `WriteIniValue`, `LoadSettings`, `ApplySettingsDefaults`, and the three existing migrations into `lib/config.ahk`; preserve `Config`, `SettingsFile`, and `SettingsModifyTime` globals as compatibility state.
- [ ] **Step 2: Implement atomic batch writes.** Write a complete new UTF-8-RAW document to a uniquely named sibling temp file, close it, then replace the original with the native file move operation; preserve comments and section ordering from the existing writer.
- [ ] **Step 3: Keep compatibility wrappers.** Leave `LoadSettings()`, `SetSettings()`, `GetGlobalSetting()`, and `WriteIniValue()` as thin wrappers where existing modules still call them; wrappers delegate to `Config*` and contain no parsing logic.
- [ ] **Step 4: Route feature getters through the boundary.** Replace direct `Config.Has(section)` reads in LLM, translation providers, qbar path options, and settings snapshots with `ConfigRead/ConfigHas` while leaving dynamic sections (`QRun`, `QWeb`, `QSearch`, `TabHotString`) iterable through `ConfigSection`.
- [ ] **Step 5: Add section metadata.** Define one source of truth for static sections, allowed scalar keys, dynamic sections, and numeric ranges; make `SettingsAllowedKey()` consume it rather than maintaining a second switch list.
- [ ] **Step 6: Verify include order and references.** Include `lib/config.ahk` before modules that execute initialization; search for direct parser/writer implementations and ensure only `lib/config.ahk` contains them. Do not run AHK.
- [ ] **Step 7: Commit.**

```powershell
git add capslock_p2.ahk lib/config.ahk lib/core.ahk lib/settings.ahk lib/llm.ahk lib/llmTranslate.ahk lib/aiChat.ahk lib/qbar.ahk lib/youdaoTranslate.ahk lib/volcengineTranslate.ahk
git commit -m "refactor: centralize configuration access"
```

### Task 5: Remove calculator/QStyle runtime dependencies and expose qbar backend settings

**Files:**

- Create: `lib/tabHotString.ahk`
- Modify: `capslock_p2.ahk`
- Modify: `lib/keymap.ahk`
- Modify: `lib/keys.ahk`
- Modify: `lib/qbar.ahk`
- Modify: `lib/settings.ahk`
- Modify: `pages/settings.html`
- Modify: `pages/qbar.html`
- Modify: `tools/capslock_p2-default.ini`
- Modify: `capslock_p2-settingsDemo.ini`

**Interfaces:**

- Add `TabHotStringAction() -> String`, which performs the existing hotstring replacement path and never calls expression evaluation.
- Preserve `keyFunc_tabScript(*)` as a compatibility wrapper that calls `TabHotStringAction()`.
- Add `QbarSettingsSnapshot() -> Map` and `SettingsQbarAllowedKey(key) -> Boolean` for `esPath`, `everythingPath`, `esInstance`, and `esMaxResults`.

- [ ] **Step 1: Extract the hotstring-only action.** Move the clipboard/selection replacement behavior from `tabAction()` into `TabHotStringAction()` without copying calculation fallback branches.
- [ ] **Step 2: Keep the old configured action name.** Make `keyFunc_tabScript()` call `TabHotStringAction()` so old `[Keys]` values do not fail; set the shipped default key mapping to the same stable wrapper.
- [ ] **Step 3: Remove calculator runtime includes.** Stop including `lib/math.ahk` and `lib/jsEval.ahk`; stop initializing the JavaScript calculation runtime; leave both files and `loadScript/` untouched on disk.
- [ ] **Step 4: Remove calculator settings from the live schema.** Stop rendering and accepting `loadScript` and `javascriptOriginalReturn` in the central settings page; legacy keys remain readable in the raw INI but have no runtime effect.
- [ ] **Step 5: Stop reading QStyle.** Remove qbar style injection and the live page `setStyle` path; keep fixed qbar CSS variables and fixed row limits. Do not rewrite or delete existing `[QStyle]` entries.
- [ ] **Step 6: Add qbar backend fields to the settings center.** Add `Qbar` to snapshots and allowed sections; render path, instance, and max-results fields with integer validation for `esMaxResults`; persist through the same batch save.
- [ ] **Step 7: Synchronize default and example INI files.** Remove live calculator/QStyle entries and comments, add the supported Qbar backend defaults, and keep the example’s key mapping and comments consistent with `keyFunc_tabScript`.
- [ ] **Step 8: Run static verification.** Search live includes and calls for `EvaluateExpression`, `EvaluateJavaScript`, `InitializeJavaScriptRuntime`, `QStyle`, `setStyle`, `loadScript`, and `javascriptOriginalReturn`; only intentionally retained compatibility files/comments may remain. Run `git diff --check`.
- [ ] **Step 9: Commit.**

```powershell
git add capslock_p2.ahk lib/tabHotString.ahk lib/keymap.ahk lib/keys.ahk lib/qbar.ahk lib/settings.ahk pages/settings.html pages/qbar.html tools/capslock_p2-default.ini capslock_p2-settingsDemo.ini
git commit -m "refactor: retire calculator and qbar style settings"
```

### Task 6: Make the central settings window the only live settings UI

**Files:**

- Modify: `lib/settings.ahk`
- Modify: `lib/aiChat.ahk`
- Modify: `lib/llmTranslate.ahk`
- Modify: `pages/chat.html`
- Modify: `pages/translate.html`
- Modify: `pages/settings.html`
- Modify: `pages/settings.js`

**Interfaces:**

- Change `SettingsShow(*)` to `SettingsShow(initialPage := "general", *)`; accepted pages are `general`, `llm`, `translate`, `ai`, `shortcuts`, `tab`, `qbar`, and `windows`.
- Preserve `SettingsPushSnapshot()`, `SettingsApplyDraft()`, `SettingsRunTest()`, `SettingsHide()`, and all existing central settings WebView message types.
- Feature panels continue posting `{type: "openSettings"}`; AHK translates this to `SettingsShow("llm")`.

- [ ] **Step 1: Add initial-page state.** Store a validated `SettingsPendingPage`, include it in the first snapshot, and make `settings.html` select that page after receiving the snapshot.
- [ ] **Step 2: Route first-run setup.** Change AI and translation first-run branches to open the central settings window on `llm`; do not create an embedded form in either feature panel.
- [ ] **Step 3: Remove live overlay mounting.** Remove `settings.js` script tags and `LLMSettings.mount()` calls from `pages/chat.html` and `pages/translate.html`; retain their buttons and `openSettings` message.
- [ ] **Step 4: Remove duplicate host-side state.** Delete or bypass `AiChatSettingsOpen`, `LLMTranslateSettingsOpen`, their overlay save/test/push handlers, and use central settings messages instead. Keep stream cancellation and panel focus behavior intact.
- [ ] **Step 5: Keep `pages/settings.js` inert.** Leave the file in the repository but remove any packaging/documentation claim that it is a live settings surface; add a compatibility header explaining that no shipped page references it.
- [ ] **Step 6: Reconcile settings-page drafts.** Ensure central save, cancel, test, and page navigation use one draft snapshot; preserve unsaved changes until explicit cancel/save and show secrets as password fields.
- [ ] **Step 7: Run static verification.** Search `pages/chat.html`, `pages/translate.html`, `lib/aiChat.ahk`, and `lib/llmTranslate.ahk` for `LLMSettings`, `settings.js`, and overlay save/test handlers; only `openSettings` and central AHK routing should remain. Run `git diff --check`.
- [ ] **Step 8: Commit.**

```powershell
git add lib/settings.ahk lib/aiChat.ahk lib/llmTranslate.ahk pages/chat.html pages/translate.html pages/settings.html pages/settings.js
git commit -m "refactor: use one settings center"
```

### Task 7: Extract the reusable WebView2 panel host

**Files:**

- Create: `lib/panelHost.ahk`
- Modify: `capslock_p2.ahk`
- Modify: `lib/qbar.ahk`
- Modify: `lib/dictionary.ahk`
- Modify: `lib/llmTranslate.ahk`
- Modify: `lib/aiChat.ahk`
- Modify: `lib/settings.ahk`

**Interfaces:**

- `PanelHostCreate(pagePath, title, options := 0) -> Map`
- `PanelHostEnsure(host) -> Boolean`
- `PanelHostNavigate(host) -> void`
- `PanelHostExecute(host, script) -> void`
- `PanelHostShow(host, width, height, center := true) -> void`
- `PanelHostHide(host) -> void`
- `PanelHostStopFocusMonitor(host) -> void`
- `PanelHostDestroy(host) -> void`

Each host map contains `gui`, `controller`, `webView`, `pageReady`, `visible`, `focusTimer`, `pagePath`, and `dataPath`; panel-specific callbacks are stored as `onClose`, `onEscape`, `onResize`, and `onNavigation`.

- [ ] **Step 1: Implement path and lifecycle helpers.** Centralize loader selection, `file:///` URL construction, off-screen first realization, controller Fill, navigation state, and error messages.
- [ ] **Step 2: Implement focus/close semantics.** Keep the existing rule for panels: first Esc blurs an input in JavaScript, native Close/Escape or focus loss hides the panel; settings host may remain active while it is a normal resizable window.
- [ ] **Step 3: Migrate settings and dictionary first.** Replace only their repeated creation/show/hide/resize code while preserving their existing public globals as aliases to host fields.
- [ ] **Step 4: Migrate translation and AI.** Move ExecuteScript guards and navigation callbacks to `PanelHost`; keep stream IDs and feature histories in their feature modules.
- [ ] **Step 5: Migrate qbar.** Preserve borderless/off-screen initialization and controller visibility behavior as qbar-specific options.
- [ ] **Step 6: Run static verification.** Search feature modules for direct `CreateControllerAsync`, loader path construction, duplicated `ExecuteScriptAsync` guards, and focus-monitor setup; only `panelHost.ahk` may own shared lifecycle code. Run `git diff --check`.
- [ ] **Step 7: Commit.**

```powershell
git add capslock_p2.ahk lib/panelHost.ahk lib/qbar.ahk lib/dictionary.ahk lib/llmTranslate.ahk lib/aiChat.ahk lib/settings.ahk
git commit -m "refactor: share WebView2 panel lifecycle"
```

### Task 8: Split qbar by responsibility

**Files:**

- Create: `lib/qbar_panel.ahk`
- Create: `lib/qbar_index.ahk`
- Create: `lib/qbar_commands.ahk`
- Create: `lib/qbar_everything.ahk`
- Create: `lib/qbar_navigation.ahk`
- Modify: `capslock_p2.ahk`
- Modify: `lib/qbar.ahk`

**Interfaces:**

- `qbar.ahk` retains `QbarToggle`, `QbarShow`, `QbarHide`, `QbarExec`, `QbarSetInput`, and the stable functions used by `lib/keys.ahk`.
- `qbar_panel.ahk` owns `QbarEnsureWebView`, navigation/message callbacks, focus and shutdown, and sizing.
- `qbar_index.ahk` owns `QbarAllItems`, `QbarConfigItems`, `QbarStartMenuItems`, filtering, sorting, and icon row preparation.
- `qbar_commands.ahk` owns `QbarTryClCommand`, `QbarExecute`, configured run/web/search actions, and safe path launching.
- `qbar_everything.ahk` owns `QbarEsRequest`, backend selection, process probing, CSV parsing, UTF-8 decoding, and bundled instance lifecycle.
- `qbar_navigation.ahk` owns folder prefix detection, parent/forward stacks, and path completion.

- [ ] **Step 1: Move functions by responsibility without changing signatures.** Copy each function group into its new file, remove the original definition from `qbar.ahk`, and retain the same globals.
- [ ] **Step 2: Add include order.** Include the five qbar files after shared config/panel/JSON modules and before `lib/keys.ahk`; move any one-time initialization that depends on a global into the existing `Initialize()` path.
- [ ] **Step 3: Keep qbar facade thin.** Leave only shared state declarations, public entry points, and calls between submodules in `qbar.ahk`.
- [ ] **Step 4: Check private references.** Search every moved function name across `lib`, `pages`, and `userAHK`; update include paths or private helper references while leaving every public qbar entry function unchanged.
- [ ] **Step 5: Run static verification.** Confirm one definition per qbar function, all `#Include` paths exist, no `capslock-plus/` file changed, and `git diff --check` passes.
- [ ] **Step 6: Commit.**

```powershell
git add capslock_p2.ahk lib/qbar.ahk lib/qbar_panel.ahk lib/qbar_index.ahk lib/qbar_commands.ahk lib/qbar_everything.ahk lib/qbar_navigation.ahk
git commit -m "refactor: split qbar responsibilities"
```

### Task 9: Synchronize documentation and release metadata

**Files:**

- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/packaging.md`
- Modify: `pages/usage.html`
- Modify: `tools/capslock_p2-default.ini`
- Modify: `capslock_p2-settingsDemo.ini`
- Modify: `tools/capslock_p2.iss`

**Interfaces:**

- Documentation must describe only live settings sections and runtime features.
- The release manifest must continue to include every referenced live page/resource and must not add the personal root `capslock_p2.ini`.

- [ ] **Step 1: Remove retired feature descriptions.** Delete calculator, JavaScript-extension, QStyle, and embedded-settings instructions from user-facing docs; do not delete source files.
- [ ] **Step 2: Document the central settings center.** List F12, tray, and `cl set` entry points; describe the LLM/translation/AI/qbar/window sections and the new binding labels.
- [ ] **Step 3: Synchronize defaults.** Make the installation template, example INI, settings page fields, `SettingsAllowedKey`, and runtime getters use the same section/key names and default values; keep API credentials empty.
- [ ] **Step 4: Update architecture map.** Document `config.ahk`, `panelHost.ahk`, the qbar submodules, and the retained-but-inactive compatibility files.
- [ ] **Step 5: Check packaging.** Ensure `tools/capslock_p2.iss` still includes live pages, vendor files, dictionary, SQLite, Everything, and WebView2 loader; do not run ISCC.
- [ ] **Step 6: Run static verification.** Search for `QStyle`, `EvaluateExpression`, `settings.js`, `loadScript`, calculator wording, and stale section names; inspect all remaining hits and confirm they are only explicitly retained compatibility files. Run `git diff --check`.
- [ ] **Step 7: Commit.**

```powershell
git add README.md docs/architecture.md docs/packaging.md pages/usage.html tools/capslock_p2-default.ini capslock_p2-settingsDemo.ini tools/capslock_p2.iss
git commit -m "docs: synchronize configuration and packaging"
```

### Task 10: Final static review and handoff

**Files:**

- Review: all changed files from Tasks 1–9
- Review: `AGENTS.md`, `docs/superpowers/specs/2026-09-26-project-review-design.md`

- [ ] **Step 1: Check repository scope.** Run `git status --short` and confirm no changes exist under `capslock-plus/`, no files were deleted, and only intended commits/files are present.
- [ ] **Step 2: Check references.** Use `rg --files` and `rg -n` to verify every new `#Include`, page resource, public function, settings section, and message type resolves to an existing file/definition.
- [ ] **Step 3: Check privacy.** Search debug statements again for raw user text, API key names, endpoint query strings, and clipboard values; inspect each hit manually.
- [ ] **Step 4: Check whitespace and staged state.** Run `git diff --check` and review `git log --oneline` plus `git show --stat` for each phase commit.
- [ ] **Step 5: Report limitations.** State explicitly that no AHK, JavaScript, application, test, or installer was run because the project instructions prohibit it; report static evidence instead of claiming runtime success.
