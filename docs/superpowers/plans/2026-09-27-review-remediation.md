# capslock_p2 Review Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 `docs/2026-09-27-review-reassessment.md` 修复已确认的配置、消息、调度、日志和生命周期问题，减少重复实现，同时保持现有 CapsLock、qbar、翻译、词典、AI 问答和窗口绑定的用户行为。

**Architecture:** 先把配置 schema、字段 codec、纯值校验和幂等写入集中到 `lib/config.ahk`，再让设置保存和外部重载通过有效配置差异驱动运行时更新。qbar 的资源位置由程序固定，配置索引使用按 generation 失效的轻量缓存；词典和 Everything 消息先快速入队，Everything 使用可取消、带期限的进程作业。PanelHost 最后收敛 WebView2 原生状态，业务模块继续拥有自己的请求、历史、焦点策略和页面业务状态。

**Tech Stack:** AutoHotkey v2、WebView2、WinHTTP、SQLite/CSQLite、现有 JSON/Promise/crypto 实现、HTML/CSS/vanilla JavaScript、PowerShell 静态检查。

**Spec:** `docs/2026-09-27-review-reassessment.md`；背景设计参考 `docs/superpowers/specs/2026-09-26-project-review-design.md`。

## Global Constraints

- 遵守 `AGENTS.md`：禁止编写测试，禁止启动或运行 AHK、JavaScript、应用程序、Everything、诊断脚本、Ahk2Exe、Inno Setup 和安装器；禁止修改 `capslock-plus/`。本次用户明确授权删除复核确认无活动引用的退役文件：`lib/math.ahk`、`lib/jsEval.ahk`、`loadScript/`、`pages/settings.js`、`tools/ini_parse_check.ahk`、`tools/ini_write_check.ahk`。
- 验证只使用静态方法：`git diff --check`、`rg` 引用核对、PowerShell 文件/INI/HTML 结构检查、资源清单检查和 Git 状态检查。
- 不增加包管理器、后台服务、第三方运行时或新的网络服务；复用现有 WebView2、SQLite、JSON、Promise 和 crypto 实现。
- 不读取、展示或写入个人 `capslock_p2.ini`、API Key、调试日志或其他私密运行数据；文档和命令输出不能包含个人凭据。
- API Key、endpoint 查询串、选区、剪贴板、qbar 输入、AI 问题、翻译原文和译文不得进入文件日志；界面错误可以显示给用户，但日志只记录本地定义的错误类别、状态、计数、长度和耗时。
- 页面消息回调只负责取值、校验和排队；不得在 WebView2 回调内同步创建另一个 WebView2、执行长时间网络/Everything/SQLite 工作或等待异步结果。
- AHK 延迟闭包不得依赖 `for` 循环变量捕获；需要传值时使用 `.Bind(...)` 或在函数参数中保存值。
- 保留历史用户配置文本。退役字段只停止读取或展示，不主动删除用户 INI 内容；本轮用户已明确授权删除已确认无活动引用的退役源文件和诊断文件，删除已完成，不重新创建或重新接入它们。
- 现有公共动作名、序列化窗口绑定字段、provider 契约和主要用户流程保持不变。内部函数可以直接重命名，但必须同步更新所有仓内调用点，不新增无意义兼容包装。
- 每个任务完成后做静态检查并保留逻辑完整、可独立审阅的边界；提交仅在用户明确要求时创建。

---

## File map and ownership after the plan

| 文件 | 计划后的职责 |
| --- | --- |
| `lib/config.ahk` | schema 元数据、逻辑值与存储值 codec、INI 解析/幂等写入、配置快照和有效差异 |
| `lib/core.ahk` | 全局运行时应用、托盘、选区/剪贴板、语言和公共工具；不维护第二份配置白名单 |
| `lib/settings.ahk` | 设置窗口、草稿基线/变更集合、消息路由、测试和窗口捕获；不重复定义字段类型 |
| `lib/llm.ahk` | LLM 候选值校验、消息字段类型读取、请求构建、流式传输和安全日志 |
| `lib/qbar.ahk` / `qbar_index.ahk` | qbar facade、共享状态、配置索引和查询过滤 |
| `lib/qbar_everything.ahk` | 固定资源定位、Everything 后端状态、异步进程作业、CSV 解码和结果回填 |
| `lib/dictionary.ahk` | 词典面板业务、SQLite 查询队列、查询序号和结果有效性 |
| `lib/panelHost.ahk` | WebView2 GUI/controller/WebView、事件订阅、pageReady、焦点计时器和销毁 |
| `lib/windows.ahk` / `pages/settings.html` | 窗口绑定生命周期、模式元数据和设置页展示 |
| `lib/crypto.ahk` / `lib/youdaoTranslate.ahk` / `lib/qbar.ahk` | 一个公共 SHA-256 和一个公共 UTF-8 URL 编码实现 |
| `pages/qbar.html` / `lib/qbar_panel.ahk` | qbar 输入组合控制和业务消息；移除无效 debug 消息 |
| `README.md`, `docs/*.md`, `pages/usage.html`, `capslock_p2-default.ini`, `capslock_p2-settingsDemo.ini`, `tools/capslock_p2.iss` | 与实际配置字段、退役文件和发布资源一致的说明与清单 |

## Dependency graph

```text
Task 1 config schema/codec/writer
  ├─ Task 2 typed WebView messages + LLM validation/logging
  ├─ Task 3 settings draft diff + incremental runtime application
  │    ├─ Task 4 qbar resource policy + qbar config index cache
  │    └─ Task 5 window-binding metadata and UI
  └─ Task 6 qbar/dictionary/Everything scheduling

Task 7 PanelHost state convergence depends on stable message and save behavior
Task 8 shared implementations, qbarDebug, dead-symbol audit
Task 9 retired files/docs/packaging synchronization
Task 10 final static review
```

---

### Task 1: Establish the configuration schema, codecs, and idempotent writer

**Files:**

- Modify: `lib/config.ahk`
- Modify: `lib/core.ahk`
- Review callers: `lib/settings.ahk`, `lib/qbar_commands.ahk`, `lib/llm.ahk`, `lib/llmTranslate.ahk`, `lib/aiChat.ahk`, `lib/youdaoTranslate.ahk`, `lib/volcengineTranslate.ahk`
- Review inputs: `capslock_p2-default.ini`, `capslock_p2-settingsDemo.ini`

**Interfaces:**

- `ConfigSchema() -> Map`: returns section metadata without copying full default values.
- `ConfigField(section, key) -> Map|0`: returns the field record or `0` for an unknown static field.
- `ConfigValidateValue(section, key, value, &normalized := "") -> Boolean`: validates a candidate and writes the canonical logical value to `normalized`.
- `ConfigEncodeValue(section, key, logicalValue) -> String`: converts a logical value to one-line storage text.
- `ConfigDecodeValue(section, key, storedValue) -> String`: converts a recognized storage value to a logical value; unrecognized legacy text is returned unchanged.
- `ConfigWriteUserOverrides(changes, &fileChanged := false) -> Map`: validates/encodes a batch, writes at most once, sets `fileChanged`, and returns only effective logical changes.
- Existing `ConfigRead`, `ConfigSection`, `ConfigLoad`, and `ConfigSet` remain the live entry points; all callers use the new boundary.

**Schema records:**

```ahk
; Shape only; default values remain in capslock_p2-default.ini.
Map(
    "Global", Map("kind", "static", "keys", Map(
        "autostart", Map("type", "bool"),
        "mouseSpeed", Map("type", "int", "min", 1, "max", 20),
        "allowClipboard", Map("type", "bool"),
        "debug", Map("type", "bool"),
        "loadingAnimation", Map("type", "bool"),
        "language", Map("type", "enum", "values", ["0", "1", "2"]),
        "runAsAdmin", Map("type", "bool"))),
    "LLM", Map("kind", "static", "keys", Map(
        "endpoint", Map("type", "text"),
        "apiKey", Map("type", "secret"),
        "apiKeyHeader", Map("type", "text", "emptyDefault", "Authorization"),
        "apiKeyPrefix", Map("type", "text"),
        "model", Map("type", "text"),
        "thinking", Map("type", "bool"),
        "temperature", Map("type", "optionalNumber"),
        "timeout", Map("type", "int", "min", 1000, "max", 120000),
        "maxInputTokens", Map("type", "optionalPositiveInt"))),
    "Qbar", Map("kind", "static", "keys", Map(
        "esMaxResults", Map("type", "int", "min", 1, "max", 500))),
    "TabHotString", Map("kind", "dynamic", "codec", "hotString"),
    "QSearch", Map("kind", "dynamic", "codec", "plain"),
    "QRun", Map("kind", "dynamic", "codec", "plain"),
    "QWeb", Map("kind", "dynamic", "codec", "plain"),
    "CustomHotkey", Map("kind", "dynamic", "codec", "plain")
)
```

- Add `LLMTranslate.systemPrompt` and `QAI.systemPrompt` as `jsonScalar` codec fields.
- Add `TTranslate.engine` and `TTranslate.targetLanguage` enum validation using the currently registered provider names and existing language values.
- Keep `Keys` dynamic-key validation separate from page navigation metadata; action values still pass through `RunConfiguredAction()` safeguards.
- Do not add `esPath`, `everythingPath`, or user-editable `esInstance` to the live schema; Task 4 removes them from UI and runtime reads.

- [x] **Step 1: Inventory all live configuration fields.** Compared `ConfigLoad()` sections, `SettingsConfigSections()`, the schema, default INI sections and runtime getters; qbar paths are intentionally excluded.
- [x] **Step 2: Add schema metadata without changing runtime behavior.** Define `ConfigSchema()` and `ConfigField()` in `lib/config.ahk`; make the initial implementation return the current accepted fields and dynamic sections, with qbar paths explicitly absent.
- [x] **Step 3: Implement scalar validation.** Implemented strict integer/number/boolean/enum and key-name validation with canonical logical values.
- [x] **Step 4: Implement field codecs.** Move or reuse the existing TabHotString escape algorithm so it runs once at the configuration boundary. Add a versioned JSON scalar storage marker for the two system prompts, using the existing JSON library through an array wrapper because bare JSON strings are unsupported by the current serializer. Decode only a valid marker; preserve all unmarked legacy text literally.
- [x] **Step 5: Apply decode on live settings load.** Keep `ConfigParseIni()` raw for the window-binding INI and other generic documents. During `ConfigLoad()`, decode only fields described by the live schema so `ConfigRead()` and `ConfigSection()` expose logical values. Remove the second TabHotString decode from the hotstring path after all callers are updated.
- [x] **Step 6: Normalize the INI writer.** Refactor `ConfigSetIniValue()` and `ConfigDeleteIniValue()` to preserve section/key order and comments while emitting exactly one final newline. Handle an existing trailing empty split element explicitly; applying the same logical update twice must produce byte-identical content.
- [x] **Step 7: Make batch writes atomic and observable.** Encode values before comparing/writing, write a single sibling temp file, move it into place once, set `fileChanged`, and return the effective logical field changes. Do not mutate the global `Config` until persistence succeeds.
- [x] **Step 8: Route scalar writes through the boundary.** Make `ConfigSet()` call `ConfigValidateValue()` and `ConfigEncodeValue()`; reject unknown static keys, illegal keys, CR/LF in plain fields, and invalid numeric/enum values. Keep dynamic section keys supported by the schema rules.
- [x] **Step 9: Verify the codec matrix statically.** Inspected logical/storage paths, escape markers, paths, empty values and default removal; `git diff --check` and direct-write searches completed.
- [x] **Step 10: Commit.** Changes are kept as one reviewable working-tree series; no commit was created because the user did not request one.

---

### Task 2: Make settings drafts diff-based and apply only effective changes

**Files:**

- Modify: `lib/settings.ahk`
- Modify: `lib/core.ahk`
- Modify: `pages/settings.html`
- Modify: `lib/config.ahk` if Task 1 exposes a small diff helper there

**Interfaces:**

- `ConfigEffectiveDiff(oldConfig, newConfig) -> Map`: compares logical values and excludes unchanged fields.
- `ApplyConfigChanges(effectiveChanges) -> void`: applies each changed section once and invalidates dependent caches.
- `SettingsSnapshotBaseline(snapshot) -> void` (page-local): stores the last accepted logical snapshot and the set of edited fields.
- `SettingsBuildChanges() -> Map` (page-local): returns only fields changed from the baseline, including explicit dynamic-key removals.
- `SettingsApplyDraft(message)`: accepts the change set and optional field baselines, writes once, reloads only when effective values changed, and sends one result/snapshot.

- [x] **Step 1: Define the baseline payload.** Snapshot baseline, bindings, keys, language/page and dirty draft preservation are implemented.
- [x] **Step 2: Track field edits in the page.** Static controls, pair rows, custom hotkeys, normalization and tombstones record section/key changes.
- [x] **Step 3: Send only changed logical values.** `saveDraft()` sends only changed sections with a baseline.
- [x] **Step 4: Validate the draft host-side.** Host-side section/key and value validation is routed through the schema boundary.
- [x] **Step 5: Detect conflicts against the accepted baseline.** Conflicting external values return a localized failure and preserve the draft.
- [x] **Step 6: Persist once and apply once.** Batch writes are one-shot; no-op saves skip reload/notifications, effective saves reload once and send one snapshot.
- [x] **Step 7: Preserve required side effects.** Corresponding key, hotstring, qbar, tray and panel side effects remain section-driven.
- [x] **Step 8: Keep save errors transactional.** Encoding/write failures return `settingsSaved(false)`; the page baseline changes only after a successful snapshot.
- [x] **Step 9: Audit external reload behavior.** External reloads use logical diffs; dirty settings drafts are preserved and receive a conflict/reload state.
- [x] **Step 10: Commit.** Changes are kept as one reviewable working-tree series; no commit was created because the user did not request one.

---

### Task 3: Fix message scalar types and LLM validation/privacy

**Files:**

- Modify: `lib/llm.ahk`
- Modify: `lib/settings.ahk`
- Modify: `lib/qbar_panel.ahk`
- Modify: `lib/dictionary.ahk` only if its message fields use the generic scalar helper
- Review: every `LLMMsgField()` call in `lib/`

**Interfaces:**

- `LLMMsgText(msg, key, defaultValue := "") -> String`: returns only string fields; scalar numbers/bools are not silently renamed.
- `LLMMsgNumber(msg, key, &ok := false, defaultValue := 0) -> Number`: accepts a JSON number or a validated numeric string and reports validity.
- `LLMMsgBoolean(msg, key, &ok := false, defaultValue := false) -> Boolean`: accepts JSON booleans and the exact strings `true/false`, `1/0` where the message contract allows them.
- `LLMSettingNumber(key, fallback, minimum, maximum, overrides := 0, &valid := false) -> Number`: validates override first, then active configuration.
- `LLMLogErrorKind(errorText, status := 0) -> String`: returns a local fixed category such as `config`, `http`, `network`, `timeout`, `decode`, or `stream`.

- [x] **Step 1: Inventory scalar consumers.** Classified message consumers; qbar resize/ctrl and window capture use explicit scalar readers, text consumers retain the compatibility reader.
- [x] **Step 2: Split message readers.** Keep `LLMMsgField()` only as a compatibility text reader for callers that explicitly need text, or rename it to `LLMMsgText()` and update all callers. Implement number and boolean readers without turning JSON numeric 1/0 into `"true"/"false"`.
- [x] **Step 3: Fix settings capture types.** Read `number` with `LLMMsgNumber()`, require integer 1–10, read `bindType` with `LLMMsgNumber()` and `WindowBindingType()`, and only then schedule the delayed capture using `.Bind(bindingNumber, bindType)`.
- [x] **Step 4: Fix qbar message types.** Read resize as a validated integer string/number, ctrl as a boolean, and text/selected/selectedType as strings. Preserve the existing query and execute sequence checks.
- [x] **Step 5: Implement candidate-based LLM validation.** `LLMBuildRequest()` must validate endpoint, optional model, header fallback, optional temperature, timeout 1000–120000, thinking, and max-input semantics using overrides before reading global values. A malformed timeout returns a localized configuration error instead of throwing during `+ 0`.
- [x] **Step 6: Keep service compatibility.** API key enforcement occurs at request time, while settings saves remain independent; empty temperature remains omitted.
- [x] **Step 7: Sanitize stream logs.** Remove raw `errorText`, response bodies, endpoint query strings, and exception messages from `DebugLog()`. Log stream ID, success, HTTP status, stage/category, character count, and elapsed time. Keep the full error only in the callback/UI path.
- [x] **Step 8: Enforce byte types at the stream boundary.** `LLMStreamSafeArrayBytes()` must return plain 0–255 integers. In `LLMStreamOnData()`, skip invalid elements rather than logging and pushing them; in `LLMStreamDecode()`, retain bounds checks and CP0 fallback without logging payload content.
- [x] **Step 9: Static privacy/type audit.** Reviewed DebugLog call sites and scalar readers; raw request/user payloads and exception messages are excluded from reviewed logs.
- [x] **Step 10: Commit.** Changes are kept as one reviewable working-tree series; no commit was created because the user did not request one.

---

### Task 4: Remove editable qbar paths and fix the resource policy

**Files:**

- Modify: `lib/qbar_everything.ahk`
- Modify: `lib/config.ahk` schema records from Task 1
- Modify: `lib/settings.ahk`
- Modify: `pages/settings.html`
- Modify: `capslock_p2-default.ini`
- Modify: `capslock_p2-settingsDemo.ini`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/packaging.md` only where the resource policy is described
- Review: `tools/capslock_p2.iss`

**Interfaces:**

- `QbarEsToolPath() -> String`: returns `A_ScriptDir . "\\resources\\es.exe"` only when the packaged resource exists.
- `QbarEsEverythingExe() -> String`: searches only the versioned resource directories for `everything.exe`.
- `QbarEsInstanceName() -> String`: returns the fixed internal instance name, `capslock_p2`.
- `QbarEsMaxResults() -> Integer`: continues reading the editable `Qbar.esMaxResults` field and clamps it to 1–500.

- [x] **Step 1: Remove live path fields from schema and settings.** Delete `esPath`, `everythingPath`, and `esInstance` from static writable field metadata, qbar page controls, draft allowlists, and snapshot expectations. Keep `esMaxResults`.
- [x] **Step 2: Replace runtime path getters.** Make `QbarEsToolPath()` use the fixed resource path; make `QbarEsEverythingExe()` scan the packaged versioned directory; make `QbarEsInstanceName()` return the constant. Remove user-configured path caches and fallback branches.
- [x] **Step 3: Preserve legacy text without applying it.** Existing user INI text is not migrated; ignored qbar path keys are documented as having no runtime effect.
- [x] **Step 4: Update default/demo configurations.** Remove editable path fields from the active template and example; retain the qbar result-limit setting and explanatory resource text.
- [x] **Step 5: Update the settings UI and documentation.** Replace path inputs with a resource-status hint and result-limit input. Explain that the bundled resources are installed with the program and cannot be redirected from the settings center.
- [x] **Step 6: Verify packaging consistency.** Confirm `tools/capslock_p2.iss` includes `resources/es.exe`, the versioned Everything directory, the loader and icon. Do not run ISCC.
- [x] **Step 7: Commit.** Changes are kept as one reviewable working-tree series; no commit was created because the user did not request one.

---

### Task 5: Add qbar configuration index caching with explicit invalidation

**Files:**

- Modify: `lib/qbar.ahk`
- Modify: `lib/qbar_index.ahk`
- Modify: `lib/qbar_commands.ahk`
- Modify: `lib/core.ahk` change application
- Modify: `lib/config.ahk` only if a generation helper belongs at the config boundary

**Interfaces:**

- `QbarInvalidateConfigIndex() -> void`: clears the normalized qbar configuration index and increments its generation.
- `QbarConfigIndex() -> Map`: lazily returns `{items, byShort, generation}` for `QSearch`, `QRun`, and `QWeb`.
- `QbarConfigShortKeyExists(token) -> Boolean`: reads `byShort` while preserving existing precedence semantics.
- `QbarSplitCommand(text, &firstToken, &rest) -> Boolean`: centralizes first-token/rest parsing without changing case or whitespace rules.

- [x] **Step 1: Record current ordering rules.** Ordering, aliases, exact matches, duplicate resolution and empty-value occupancy are documented in the qbar implementation report.
- [x] **Step 2: Add cache state.** Add one qbar config-index Map and a generation counter; do not combine it with the start-menu cache, folder cache, Everything state or IconSent.
- [x] **Step 3: Build the index lazily.** Move the existing config-item normalization, `ExtractSetString()`, icon-key calculation and short-key map creation into one builder. Preserve duplicate-key resolution explicitly rather than relying on Map iteration order.
- [x] **Step 4: Route query and command consumers through the index.** Update `QbarAllItems()`, `QbarFilterItems()`, `QbarConfigShortKeyExists()`, `QbarRunBy()` and search resolution to reuse the index. Keep file/folder existence checks at execution time.
- [x] **Step 5: Centralize token parsing.** Replace repeated `QbarFirstToken()` plus `SubStr()` pairs in query, execute and inline-config paths with `QbarSplitCommand()`; preserve `Trim(..., " `t")` semantics.
- [x] **Step 6: Invalidate on effective changes.** In `ApplyConfigChanges()`, invalidate for QSearch/QRun/QWeb changes and for language changes that alter the built-in search row. Invalidate only once per batch.
- [x] **Step 7: Static behavior audit.** Configuration consumers reuse the generation cache and retain configured-trigger precedence and duplicate resolution.
- [x] **Step 8: Commit.** Changes are kept as one reviewable working-tree series; no commit was created because the user did not request one.

---

### Task 6: Move dictionary work out of WebView callbacks

**Files:**

- Modify: `lib/dictionary.ahk`
- Modify: `pages/dictionary.html` only if result sequence metadata must be carried in messages

**Interfaces:**

- `DictionarySessionId` and `DictionaryQuerySeq` globals identify the current panel session and latest query.
- `DictionaryQueueLookup(word, sessionId, querySeq) -> void` returns immediately and schedules lookup work.
- `DictionaryQueueSuggestions(query, sessionId, querySeq) -> void` returns immediately and replaces the pending suggestion timer.
- `DictionaryRunLookup(*) -> void` and `DictionaryRunSuggestions(*) -> void` perform SQLite work outside the WebView callback.
- `DictionaryPushSuggestions(words, sessionId, querySeq) -> void` drops stale results.

- [x] **Step 1: Add session and query counters.** Session and query counters increment on show/request/hide/shutdown and are carried through queued work.
- [x] **Step 2: Queue lookup messages.** In `DictionaryWebMessageReceived()`, parse and validate text, increment the sequence, and schedule `DictionaryRunLookup`; do not call `DictionaryLookup()` or `DictionaryPushEntry()` synchronously.
- [x] **Step 3: Queue suggestions.** Keep the page’s 120 ms debounce, then have AHK replace a one-shot suggestion timer with the latest query. The callback only parses the message and records the latest request.
- [x] **Step 4: Guard database work.** Before and after the SQLite operation, verify session/query identity and `DictionaryVisible`; drop results for a hidden or newer request.
- [x] **Step 5: Preserve current ranking and limits.** Existing prefix/contains/fuzzy tiers, frequency order, cap and escaping remain in the queued path.
- [x] **Step 6: Cancel lifecycle work.** On hide/shutdown, stop the suggestion timer, invalidate query/session IDs, and prevent a late timer from executing page scripts.
- [x] **Step 7: Static callback audit.** The WebView callback only validates, updates sequence state and queues work.
- [x] **Step 8: Commit.** Changes are kept as one reviewable working-tree series; no commit was created because the user did not request one.

---

### Task 7: Replace Everything RunWait/Sleep with a cancellable process job

**Files:**

- Modify: `lib/qbar.ahk`
- Modify: `lib/qbar_everything.ahk`
- Modify: `lib/qbar_panel.ahk`
- Review: `tools/capslock_p2.iss` resource paths

**Interfaces:**

- `QbarEsJob := 0|Map`: `{kind, seq, pid, tmpPath, startedAt, deadline, useBundled, arg, owner}`.
- `QbarEsStartSearch(arg, useBundled, seq) -> Boolean`: launches one hidden command process and schedules polling.
- `QbarEsPollJob(*) -> void`: checks process completion/deadline and schedules itself while pending.
- `QbarEsFinishJob(job, exitCode, timedOut := false) -> void`: reads/parses output only for the current job, deletes its temp file, and clears state.
- `QbarEsCancelJob(reason := "") -> void`: stops polling, closes only the process owned by qbar, deletes its temp file and invalidates the sequence.
- `QbarEsStartProbe(kind, seq) -> Boolean`: uses the same job lifecycle for default/bundled reachability; it must not use `RunWait()`.

- [x] **Step 1: Define job ownership.** One job Map records qbar client ownership separately from user/Everything service ownership.
- [x] **Step 2: Create unique output paths.** Task-specific temp CSV paths contain process/sequence/tick/job data and are cleaned on all completion paths.
- [x] **Step 3: Launch without RunWait.** Start the hidden command with `Run(..., "Hide", &pid)` and record `pid`, deadline and sequence. Escape the executable, output path and query according to the actual Windows command contract; do not assume arbitrary query text is safe merely because it is surrounded by quotes.
- [x] **Step 4: Poll with a short timer.** `QbarEsPollJob()` checks `ProcessExist(pid)` and a fixed deadline. It must return quickly, reschedule while pending, and never sleep in a loop.
- [x] **Step 5: Parse only completed current jobs.** After the process exits, parse CSV, delete the file, compare the job sequence with `QbarEsSeq`, `QbarVisible` and `QbarEsMode`, then publish results or discard them.
- [x] **Step 6: Replace bundled cold-start retry.** Remove the ten `Sleep(1500)` loop. Represent index warm-up as a deadline and repeated query jobs; keep last results visible, show a bounded loading state, and produce one timeout hint.
- [x] **Step 7: Rework backend probing.** Default/bundled probes share the async job state and distinguish reachable, starting and failed ownership states.
- [x] **Step 8: Cancel on all lifecycle transitions.** `QbarHide`, `QbarShutdown`, a newer query and an expired session cancel or invalidate the old job. A late result must not update a new panel session.
- [x] **Step 9: Static scheduling audit.** No `RunWait` or long sleep loop remains; completion paths clean up and check sequence/session state.
- [x] **Step 10: Commit.** Changes are kept as one reviewable working-tree series; no commit was created because the user did not request one.

---

### Task 8: Converge PanelHost state without flattening panel behavior

**Files:**

- Modify: `lib/panelHost.ahk`
- Modify: `lib/aiChat.ahk`
- Modify: `lib/llmTranslate.ahk`
- Modify: `lib/dictionary.ahk`
- Modify: `lib/settings.ahk`
- Modify: `lib/qbar_panel.ahk`
- Modify: `lib/keys.ahk` if panel-activity checks stop using mirrored GUI globals

**Interfaces:**

- `PanelHostPageReady(host) -> Boolean`, `PanelHostGui(host) -> Gui|0`, and `PanelHostWindowActive(host) -> Boolean` are read-only helpers if direct Map access is not retained.
- Navigation callback signature becomes `navigation(host, sender, args)` or receives a typed result; it must not reassign `host["pageReady"]`.
- `PanelHostStartFocusMonitor(host, callback, interval := 100) -> Boolean` stores only the callback needed for cancellation.
- Each feature retains `Visible`, pending text/history/request IDs and feature-specific focus policy; `gui/controller/webView/pageReady` are read from Host.

- [x] **Step 1: Remove unused host state.** Delete the unused `callbacks` local in `PanelHostEnsure()` and the write-only `focusTimer` field. Keep callback references, event subscription tokens, `focusMonitor`, page readiness, visibility and realization only where they are read.
- [x] **Step 2: Make Host own navigation readiness.** Public navigation handling updates pageReady once, then invokes the feature callback with Host context. Remove duplicate `args.IsSuccess` reads and Host writes from feature navigation callbacks.
- [x] **Step 3: Track event subscription tokens.** Store `add_NavigationCompleted` and `add_WebMessageReceived` tokens using the existing WebView2 binding and remove them before destroying/replacing the WebView. Do not write a new COM event wrapper.
- [x] **Step 4: Migrate settings and dictionary.** Dictionary uses Host helpers; settings mirrors were removed while preserving unsaved confirmation and dictionary border/focus behavior.
- [x] **Step 5: Migrate translation and AI.** Remove mirrored controller/WebView/pageReady state while preserving stream IDs, pending text, history, first-activation grace, hide-on-blur and settings-follow-up behavior.
- [x] **Step 6: Migrate qbar.** Preserve off-screen realization, borderless placement, controller visibility, row resize and focus behavior. Keep qbar-specific `QbarVisible`/`QbarOpen` state separate from Host visibility.
- [x] **Step 7: Update external callers.** Replace `keys.ahk` panel Hwnd checks with feature predicates such as `AiChatIsActive()`, `LLMTranslateIsActive()`, and `DictionaryIsActive()` if direct mirrored GUI globals are removed. Update all callers in the same change.
- [x] **Step 8: Static lifecycle audit.** Common controller creation/script execution remains in PanelHost; feature modules use Host helpers and retain only business state.
- [x] **Step 9: Commit.** Changes are kept as one reviewable working-tree series; no commit was created because the user did not request one.

---

### Task 9: Repair window-binding message types and centralize mode metadata

**Files:**

- Modify: `lib/windows.ahk`
- Modify: `lib/settings.ahk`
- Modify: `pages/settings.html`
- Modify: `lib/llm.ahk` scalar readers from Task 3
- Modify: `README.md`

**Interfaces:**

- `WindowBindingType(value, fallback := 1) -> Integer` accepts only integer 1–3.
- `WindowBindingNumber(value, fallback := 0) -> Integer` accepts only integer 1–10.
- `WindowBindingModes() -> Array<Map>` returns `{id,label,description}` for modes 1–3 and an explicit unbound display record where needed.
- `SettingsBindingSnapshot()` returns bindings plus the mode metadata once; the page does not duplicate mode labels.

- [x] **Step 1: Normalize numeric message reads.** Use `LLMMsgNumber()` for settings `number` and `bindType`; do not pass numeric JSON values through a boolean-coercing text helper. Reject fractional, negative, empty and out-of-range values before scheduling.
- [x] **Step 2: Validate key-driven binding numbers.** Apply `WindowBindingNumber()` in `BindingTap()`, `BindWindowFromActive()`, `activateWinAction()` and the settings bridge. Invalid action arguments become no-ops and cannot create INI sections outside 1–10.
- [x] **Step 3: Centralize mode metadata.** Make `WindowBindingModes()` the single source of labels/descriptions. `WindowBindingDisplay()` can select from it; settings snapshot sends it once or sends mode IDs that the page maps from a snapshot-provided list.
- [x] **Step 4: Preserve UI semantics.** The page distinguishes “未绑定” from the next capture mode; mode IDs and serialized fields remain unchanged.
- [x] **Step 5: Align keyboard labels.** Ensure the binding whose persistent number is 10 is displayed as CapsLock+0 while activation still uses number 10. Update README examples without changing configuration keys.
- [x] **Step 6: Review lifecycle helpers.** Remove write-only `GettingWinInfo` if no extension contract uses it; preserve stale-handle recovery, type-2 pruning and type-3 refresh behavior. Do not rewrite window activation in this UI cleanup task.
- [x] **Step 7: Static verification.** Numeric entry points use range helpers and mode labels come from the snapshot metadata.
- [x] **Step 8: Commit.** Changes are kept as one reviewable working-tree series; no commit was created because the user did not request one.

---

### Task 10: Consolidate shared algorithms and clipboard ownership

**Files:**

- Modify: `lib/crypto.ahk`
- Modify: `lib/youdaoTranslate.ahk`
- Modify: `lib/qbar.ahk`
- Modify: `lib/core.ahk`
- Modify: `lib/tabHotString.ahk`
- Modify: `lib/keys.ahk` only if clipboard helper signatures change

**Interfaces:**

- `CryptoSha256Hex(text) -> String` remains the only text SHA-256 helper.
- `UrlEncodeUtf8(text) -> String` is shared by qbar search URLs and Youdao form fields; it encodes UTF-8 bytes using RFC 3986 unreserved characters and `%20` for spaces.
- `HotStringKeys` is deduplicated and ordered longest-first before matching.
- `TabHotStringAction()` restores clipboard/listener state from one clearly owned transaction per operation.

- [x] **Step 1: Replace Youdao hash helper.** Change the Youdao signature call to `CryptoSha256Hex()` and remove the duplicate `BCryptSha256Hex()` body after checking no external caller uses that name.
- [x] **Step 2: Add and adopt URL encoder.** Move the common byte loop into a neutral helper, update qbar and Youdao callers, and preserve each caller’s placement of query/form delimiters.
- [x] **Step 3: Remove duplicate startup hotstring work.** Keep `RebuildHotStringPattern()` in the synchronous initialization path; remove the one-shot `HotStringInit` timer and its unused wrapper. Keep rebuild dispatch for relevant configuration changes.
- [x] **Step 4: Deduplicate and order hotstring keys.** Build a Map of unique short keys, then sort by descending length with a stable section order for equal lengths. Keep `HotStringValue()` precedence and empty-value fallback unchanged.
- [x] **Step 5: Define clipboard ownership.** For selected text, let `SetClipboardText()` own its snapshot; for no selection, wrap copy/paste in `try/finally`, restore only if the clipboard sequence still belongs to the operation, and restore the prior watcher-suspension state.
- [x] **Step 6: Preserve behavior.** Clipboard ownership changes retain UIA/keyboard selection paths, CapsLock behavior and user clipboard-change protection.
- [x] **Step 7: Static audit.** Duplicate hash/URL helpers and startup timer references are absent; clipboard paths restore prior state with sequence guards.
- [x] **Step 8: Commit.** Changes are kept as one reviewable working-tree series; no commit was created because the user did not request one.

---

### Task 11: Remove qbarDebug and audit internal dead branches

**Files:**

- Modify: `pages/qbar.html`
- Modify: `lib/qbar_panel.ahk`
- Modify: `lib/aiChat.ahk`
- Modify: `lib/llmTranslate.ahk`
- Modify: `lib/config.ahk`
- Modify: `lib/core.ahk`
- Review deletion already authorized: `lib/math.ahk`, `lib/jsEval.ahk`, `loadScript/`, `pages/settings.js`, `tools/ini_parse_check.ahk`, `tools/ini_write_check.ahk`

**Interfaces:**

- qbar page messages remain `ready`, `query`, `execute`, `resize`, and `hide`; there is no live `debug` message type.
- Retained user-extension and third-party library symbols are explicitly listed in an audit note; internal unreachable helpers are removed only after dynamic-reference search.

- [x] **Step 1: Remove qbarDebug calls.** Delete `qbarDebug()`, its debug message posts and the page-only `querySerial`/`deferredQuery` state after verifying `composing`, `event.isComposing` and query deferral still work independently.
- [x] **Step 2: Remove the host debug branch.** Delete `messageType = "debug"` handling from `QbarWebMessageReceived()` and update message documentation.
- [x] **Step 3: Audit dynamic references.** Reviewed AHK/page/config/user entry references, timer bindings, provider registrations and dynamic key actions before removing only internal helpers.
- [x] **Step 4: Remove only confirmed internal branches.** The initial audit candidates are `LLMAiChatComplete()`, `TranslateLlmComplete()`, `ConfigHas()`, `ConfigSectionExists()`, `ConfigWrite()`, `ConfigWriteBatch()`, and the old `SettingNumber()` entry. Remove each only after Task 1/3 have absorbed its useful validation behavior and the dynamic-reference audit finds no public extension contract. Do not remove `keyFunc_*`, explicit extension helpers, WebView2 dependencies or provider callback methods solely because `rg` finds no direct call.
- [x] **Step 5: Record retired-file removal.** `docs/architecture.md`、`docs/packaging.md` 和本计划记录了授权删除；不重新创建已删除文件、不恢复旧 include，也不为旧诊断副本增加测试。
- [x] **Step 6: Static verification.** Confirm no live page sends `debug`, no host handles it, retired files are not included or packaged, and no removed symbol appears in dynamic configuration or provider registration.
- [x] **Step 7: Commit.** Changes are kept as one reviewable working-tree series; no commit was created because the user did not request one.

---

### Task 12: Synchronize documentation, defaults and packaging

**Files:**

- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/packaging.md`
- Modify: `pages/usage.html`
- Modify: `capslock_p2-default.ini`
- Modify: `capslock_p2-settingsDemo.ini`
- Review: `tools/capslock_p2.iss`
- Review: `docs/2026-09-27-review-reassessment.md`

- [x] **Step 1: Document the final qbar resource policy.** Remove editable path instructions; document bundled `es.exe`, bundled Everything resource lookup, fixed internal instance and editable result limit.
- [x] **Step 2: Document configuration codecs.** Explain which textareas preserve line breaks, that user-facing text is encoded in the INI storage boundary, and that literal backslashes/legacy TabHotString values are preserved.
- [x] **Step 3: Document save behavior.** State that only effective changes trigger runtime application; external edits can produce a settings conflict when the page has unsaved changes; no API key or user text is logged.
- [x] **Step 4: Document async lifecycle.** Describe dictionary suggestion cancellation, Everything query timeout/cancellation, hidden-panel invalidation and ownership of bundled process shutdown without claiming runtime performance results.
- [x] **Step 5: Update architecture map.** Reflect the schema boundary, qbar index, process job, dictionary queue, PanelHost ownership, window-binding mode metadata and retired files.
- [x] **Step 6: Check defaults and examples.** Ensure removed qbar path keys are absent from active example fields, result-limit defaults agree with schema, and legacy fields are described as ignored rather than silently migrated.
- [x] **Step 7: Check packaging.** Confirm all live pages/resources remain in `tools/capslock_p2.iss`, the removed retired files are absent from the release inputs, and the personal root INI is never an input.
- [x] **Step 8: Commit.** Changes are kept as one reviewable working-tree series; no commit was created because the user did not request one.

---

### Task 13: Final static review and handoff

**Files:**

- Review: all files changed by Tasks 1–12
- Review: `AGENTS.md`, `docs/2026-09-27-review-reassessment.md`, this plan

- [x] **Step 1: Confirm repository scope.** Run `git status --short --untracked-files=all`; confirm only intended files changed, the explicitly authorized retired files are the only deletions, and `capslock-plus/` is untouched.
- [x] **Step 2: Check includes and resources.** Static include/resource scan completed; all listed live files and packaged resources exist.
- [x] **Step 3: Check schema coverage.** Static comparison completed; qbar path keys are absent from the live schema, UI and templates.
- [x] **Step 4: Check codec round trips statically.** Static inspection completed for multiline fields, escape markers, paths and default removal.
- [x] **Step 5: Check message types.** Static search completed for scalar readers, binding IDs and qbar resize/ctrl ranges.
- [x] **Step 6: Check scheduling and cancellation.** Static search completed for dictionary/Everything timers, sequences, deadlines, cleanup and ownership.
- [x] **Step 7: Check privacy.** Static DebugLog audit completed; raw user payloads and exception messages removed from the reviewed paths.
- [x] **Step 8: Check PanelHost ownership.** Static lifecycle audit completed; common controller creation and script execution remain in PanelHost.
- [x] **Step 9: Check dead-symbol and retired-file audit.** Static symbol/reference audit completed; authorized retired files are absent.
- [x] **Step 10: Run static commands only.** `git diff --check`, targeted `rg`, PowerShell resource checks and Git status completed; no runtime commands were used.
- [x] **Step 11: Report limitations.** Runtime WebView2, AHK, SQLite, Everything, clipboard and network behavior remains unverified by policy.
- [x] **Step 12: Commit or hand off.** Hand off the reviewable working-tree series without packaging, publishing or a new commit.

## Static verification command set

Use PowerShell-native commands from the repository root. The following commands are examples of the permitted checks; adapt the `rg` pattern to the task being reviewed.

```powershell
git diff --check
git status --short --untracked-files=all
rg -n "esPath|everythingPath|esInstance" lib pages README.md docs capslock_p2-default.ini capslock_p2-settingsDemo.ini tools
rg -n "LLMMsgField|LLMMsgNumber|LLMMsgBoolean|\+ 0|Integer\(" lib
rg -n "DebugLog\(" lib pages
rg -n "RunWait|Sleep\(|SetTimer\(|QbarEsJob|DictionaryQuerySeq" lib/qbar_everything.ahk lib/dictionary.ahk lib/qbar_panel.ahk
rg -n "CreateControllerAsync|WebView2Loader.dll|SyncHost|pageReady|add_NavigationCompleted|remove_NavigationCompleted" lib --glob '!WebView2.ahk'
rg -n "settings\.js|math\.ahk|jsEval\.ahk|loadScript|QStyle|EvaluateExpression|keyFunc_tabScript" capslock_p2.ahk lib pages README.md docs tools
```

Every `rg` hit requires manual classification. A hit in the reassessment, retired-file note or compatibility audit is not automatically a live runtime reference.

## Handoff

This plan is intentionally executable without runtime testing. Implementers should read this plan together with `docs/2026-09-27-review-reassessment.md`, complete tasks in dependency order, keep each change reviewable, and record static evidence after every task. This execution has user authorization for the retired-file deletion listed above; it does not authorize packaging, external communication, or publishing.
