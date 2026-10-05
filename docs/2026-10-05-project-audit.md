# 项目功能审查及复核意见

初审日期：2026-10-05
复核日期：2026-10-05
细化及再次复核日期：2026-10-05

状态：原文 36 项已逐条复核并细化到实际文件、当前行号、接口和关联调用点。整改进行中：第 02、03、04、05、06、07、08、09、10、11、12、13、14、15、16、17、18、20、21、29、30、32 项已完成代码修改及静态核查；第 35 项按复核结论保留现实现；其余逐项跟进。编号对应初审条目。未按项目约束运行程序、脚本或测试。

文中的位置链接指向当前工作区的实际文件和行号；行号以本次细化时源码为准，后续修改后应按函数名重新定位。拟新增的文件/函数会明确标为建议，不代表本次已经实现。

## 复核结论

原文多数源码观察成立，但把若干设计差异、条件风险和潜在性能成本写成了确定故障，部分 P1 评级偏高。本版将它们区分为具体缺陷、宿主校验缺口、设计约定待统一和可选结构整理。

优先保留的具体问题包括：配置读取失败被接受为空覆盖层、设置保存部分提交、插件设置及命令归属漏校验、删除/禁用工具后历史仍可重放、词典联想的单引号处理，以及窗口绑定坏数据和缺版本动作消息的处理。Qbar 动态 provider 尚未接通属于扩展架构落差。性能与拆分项均需要控制方案复杂度，不以文件长度、同步调用或重复代码本身判定严重故障。

本次重点修正文档：

| 原判断或建议 | 复核后的修改 |
| --- | --- |
| Everything 查询必须作为普通 argv 整体引用 | ES 自行解析原始命令行，普通搜索中的双引号会保留为搜索语法。撤回整体 QbarEsQuoteArg(query) 建议，改为隔离 ES 开关解析。 |
| 互译识别不确定仍请求是 P1，应恢复 needsDirection | Git 提交 1a961e0 明确添加了目标 A 回退。改为当前行为、来源标签和旧说明不一致，不能仅按旧计划撤销后来行为。 |
| Qbar 注册表没有原子替换 | 成功重建已有 next 一次替换。真正问题是提交后重建失败及部分读取失败被当成空数据。 |
| Core 消息桥可直接收到不可信 frame 消息 | 当前仅订阅 CoreWebView2.WebMessageReceived，未订阅 Frame 消息。撤回 frame 断言，保留顶层来源/导航策略加固。 |
| 同步网络调用证明整个应用卡住，20/120 秒是总超时 | 同步等待已确认，整体冻结未复现。SetTimeouts 是网络各阶段超时，不是端到端截止时间。 |
| 剪贴板每次容量统计扫描数百 MiB、500 条是硬上限 | length(BLOB) 不必读取整个 BLOB；500 是默认非收藏/非置顶记录上限，运行时可调整。512 MiB 是逻辑字段预算。 |
| AI checkpoint 增加 WAL 写入，应引入片段日志 | 当前未设置 WAL；完整回答重复保存有成本，但未证明瓶颈。优先调整现有 checkpoint 阈值，不默认新增存储结构。 |
| 设置全量渲染可能覆盖草稿 | 已有 dirty/draft 快照保护。保留动态列表重复渲染的观察，撤回草稿丢失暗示。 |
| F8 旧动作名应保留兼容别名 | 与当前“不考虑兼容性、保持简洁”约束不符。建议统一语义命名并同步静态引用。 |

优先级使用规则：

- P2：有明确源码证据的功能缺陷、输入契约漏检或条件可靠性风险，应列入近期整改。
- P3：维护/性能候选、文档一致性或产品策略，按实际改动与成本安排。
- 本次未取得足以把原 P1 条目定为已证实高危故障的证据；原 P1 已按真实触发条件下调。

## 应用、配置与设置

### 01 应用核心聚合多个功能域——部分成立，P3 结构建议

- 依据：[core.ahk](../lib/app/core.ahk) 同时承担启动/退出、设置应用、选区/UI Automation、剪贴板槽、热串和界面辅助。
- 复核意见：职责跨度属实，文件大本身不能证明扩展性差。拆到多个文件也不会自动消除 AHK 全局状态耦合。
- 修改意见：保留应用级编排入口；后续修改涉及某个完整独立流程时，再按所有权移出选区服务、剪贴板槽或输入动作解析。不要以减少行数为目标创建大量 helper 文件。

**具体位置与建议改法**

- 位置：[lib/app/core.ahk:121](../lib/app/core.ahk#L121) 的 ClipboardSuspend 管理器（121–162 行）、[lib/app/core.ahk:520](../lib/app/core.ahk#L520) 的热串/动作解析（520–673 行）、[lib/app/core.ahk:674](../lib/app/core.ahk#L674) 的选区/UIA（674–911 行）、[lib/app/core.ahk:912](../lib/app/core.ahk#L912) 的剪贴板序号/槽位（912–1075 行）及 [lib/app/core.ahk:1142](../lib/app/core.ahk#L1142) 的 SetClipboardText()；入口包含表在 [capslock_p2.ahk:18](../capslock_p2.ahk#L18)。
- 首个可独立拆分单元建议为选区服务：将 GetSelectedText、NormalizeSelectedText 和完整 UIA helper 组移到拟新增的 lib/shared/selection.ahk；保留函数名和 strict/multiline/any 参数语义。不要只移动主函数而把 UIA 缓存/初始化留成难定位的跨文件状态。
- 后续确需整理时，再将 ClipboardSuspend、序号判断及临时写入放入一个共享剪贴板服务；槽位采集/恢复归同一所有者。热串规则与动作解析可以随输入层整理移动，core 保留 Initialize/Shutdown/ApplyConfigChanges 的调度，不为每个 helper 单独建文件。
- 同步入口 #Include 顺序和 [docs/architecture.md:25](architecture.md#L25) 的职责表。所有新文件仍在 Initialize() 执行前完成包含，global 初始化只保留一份；keyFunc_* 的配置 API 和 userAHK 的加载位置不能因文件迁移消失。
- 静态确认：移动的每个符号只有一处定义，ClipboardSuspend 的 try/finally 和“仅恢复本次拥有的剪贴板序号”判断完整保留。此项没有明确瓶颈，建议跟随相关功能修改实施。

### 02 配置读取失败被接受为空覆盖层——成立，P2 条件缺陷

- 依据：[config.ahk](../lib/app/config.ahk) 的 ConfigParseIni() 在读取失败时返回空 Map 并设置 loaded=false；ConfigLoad() 未接收该状态。ReloadSettings() 随后发布并应用回退配置。[core.ahk](../lib/app/core.ahk) 的 MonitorSettings() 又先记录了新的修改时间。
- 复核意见：已有文件暂时不可读会与空覆盖层混淆；回退状态可能持续到下一次重载，不能保证只是短暂失效。首次运行尚无用户 INI 是正常情况，不能一起报错。
- 修改意见：加载到候选配置并显式区分“用户文件不存在”“已有文件读取失败”“默认模板缺失”。读取失败保留最近有效运行态，不接受本次文件版本，并保留重试机会；完整成功后再发布配置和修改时间。只记录读取阶段和脱敏诊断，不输出配置正文。

**具体位置与建议改法**

- 位置：[lib/app/config.ahk:11](../lib/app/config.ahk#L11) ConfigLoad()、[lib/app/config.ahk:490](../lib/app/config.ahk#L490) ConfigParseIni()；调用端为 [lib/app/core.ahk:46](../lib/app/core.ahk#L46) Initialize()、[lib/app/core.ahk:183](../lib/app/core.ahk#L183) ReloadSettings()、[lib/app/core.ahk:315](../lib/app/core.ahk#L315) MonitorSettings()。profile 候选位于 [lib/input/appProfiles.ahk:12](../lib/input/appProfiles.ahk#L12)。保存调用为 [lib/features/settings.ahk:160](../lib/features/settings.ahk#L160) SettingsApplyQbarPlugin() 和 [lib/features/settings.ahk:617](../lib/features/settings.ahk#L617) SettingsApplyDraft()。
- ConfigLoad() 先在局部变量中读默认模板和用户文档，接收每次读取的 loaded 标志。默认 raw 文档只读一次并保留原副本；分别解码原 default 与“default 副本叠加 user raw”的候选，完成后才赋 ConfigDefaults/Config。不要混合已解码默认值和仍带存储编码的用户值，也不要原地 Overlay 污染默认副本。用户文件不存在仍是合法空覆盖，默认模板不存在必须单独识别。
- ConfigLoad(&errorCode) 返回成功与否；ConfigParseIni() 保留可选 loaded 接口并增加 exists 输出。ReloadSettings() 失败立即返回且不 ApplyConfigChanges、不重建快捷键、不推送默认回退快照；它保留 registrationErrors 数组，并新增可选加载结果输出供 [lib/features/settings.ahk:720](../lib/features/settings.ahk#L720) 区分“已写盘但未能应用”。
- MonitorSettings() 不提前接受新修改时间，只有完整配置加载成功才更新 SettingsModifyTime；失败版本由后续 500ms 调度重试。Initialize() 检查首次读取结果，无有效初始配置时提示并退出，不能继续注册不完整配置的热键。
- 保留现有 codec、默认覆盖和未知段保存规则；本条不新增整份 INI 的严格 schema 拒绝策略。与第 24 项结合时可共享一次成功读取的文档，避免 Config 与 profile 在两个读时刻分别取到不同版本。

**实施状态：已完成第 02 项代码修复。** [lib/app/config.ahk](../lib/app/config.ahk) 的 `ConfigLoad()` 现在一次读取默认文档和用户文档，额外取得文件存在状态；用户文件不存在仍按空覆盖处理，默认文件缺失、现存用户文件读取失败或文件时间不可确认均返回分类错误。默认原始 Map 只解析一次，以克隆副本叠加用户值，分别解码候选默认值和生效配置；两者构建成功后才发布 `ConfigDefaults`、`Config` 与 `SettingsModifyTime`，并把成功读取的用户 Map 交给同一次初始化/重载的 profile 解析。用户文件在读取前后时间戳变化时拒绝本次候选并重试。失败日志仅记录阶段类别并对连续同类重试去重，不记录配置正文。

[lib/input/appProfiles.ahk](../lib/input/appProfiles.ahk) 的 `AppProfilesLoad()` 改为先构造 profile 候选，可按调用选择暂不发布；初始化/重载会复用 ConfigLoad 已读取的用户 Map，避免二次读取到另一个文件版本。[lib/app/core.ahk](../lib/app/core.ahk) 的 `Initialize()` 检查配置和 profile 首次解析结果；失败时显示错误并退出，不注册不完整配置的热键。`ReloadSettings()` 增加可选 `loadSucceeded` 输出；配置或 profile 候选读取失败均不应用差异、不重建快捷键、不推送设置快照，profile 解析失败时同时恢复旧配置 Map 和已接受时间戳。`MonitorSettings()` 不再预先接受新时间戳；profile 检查只读候选，任一读取失败都会设置重试标志，每 500ms 继续尝试，直到一次完整加载成功并更新接受时间。

[lib/features/settings.ahk](../lib/features/settings.ahk) 的保存调用检查 reload 结果：若 INI 已写入但读取/应用失败，会明确提示“已写入但未应用”，保留失败态，并在普通设置保存失败分支提前返回，避免随后推送旧配置快照。设置页的 profile 冲突检查也只比较未发布候选；只有完整重载成功才替换运行态。写入 helper 和 profile 保存路径不再抢先更新 `SettingsModifyTime`，使监视器保留重试机会。**第 03 项仍需继续处理：** 本次只添加配置未应用时的必要状态提示和快照保护；完整跨存储回执、插件部分提交后的草稿基线/重试行为仍未实现。

**静态核查：** 已检索并检查 `ConfigLoad()`、`ReloadSettings()`、`MonitorSettings()` 及全部显式 reload 调用点；缺失用户 INI 与读取失败走不同路径，重载失败最终保留旧配置/profile 运行态，不应用差异或推送设置快照；初始读取失败会退出初始化。未运行程序、脚本或测试；AHK 语法和文件监视重试的运行时行为未验证。

### 03 设置保存跨存储部分提交——成立，P2

- 依据：[settings.ahk](../lib/features/settings.ahk) 的 SettingsApplyDraft() 先写 INI/重载，再提交插件变更；SettingsApplyQbarPlugin() 先写 esMaxResults，再提交插件数据库。后一步失败不会撤销前一步。
- 复核意见：这是失败反馈与实际状态不一致，不代表 INI 的原子文件写入本身失效。普通设置和插件库不必强行引入通用跨存储事务框架。
- 修改意见：先完成全部可写字段校验，明确保存单位。插件所属设置尽量在同一持久化边界提交；仍需分开保存时，失败反馈说明已保存部分，并刷新基线/快照，让重试只提交剩余变化。不要盲目回写旧 INI 覆盖用户期间的外部修改。

**具体位置与建议改法**

- 位置：[lib/features/settings.ahk:172](../lib/features/settings.ahk#L172) `SettingsApplyQbarPlugin()`（172–306，先准备并写入 `esMaxResults`、重载，再提交插件事务）、[lib/features/settings.ahk:642](../lib/features/settings.ahk#L642) `SettingsApplyDraft()`（642–824，准备 INI/profile 候选并按域提交）；回执构建/发送在 [lib/features/settings.ahk:592](../lib/features/settings.ahk#L592) 与 [lib/features/settings.ahk:877](../lib/features/settings.ahk#L877)。页面接收保存回执在 [pages/settings.html:2124](../pages/settings.html#L2124)、普通结果处理在 [pages/settings.html:2247](../pages/settings.html#L2247)、独立工具保存及基线更新在 [pages/settings.html:1545](../pages/settings.html#L1545)；普通外部快照仍由 [pages/settings.html:2086](../pages/settings.html#L2086) 的 dirty 守卫保护。
- 先做第 15 项的插件 patch 校验，再调用 ConfigPrepareUserOverrides() 准备 INI 候选；当前 profilesDirty=false 分支第 681 行直接写盘，建议也先 prepare，使所有输入错误发生在首次落盘前。INI 与 profile 已合并成同一文件，应维持一次 ConfigAtomicWrite()。
- 若保留两存储，回执必须表达实际提交结果，不能只发送 ok/text。建议附带 iniCommitted、pluginsCommitted、runtimeApplied，以及已提交字段的实际值/基线；提交成功后的 registry/UI 刷新问题与第 12 项共同处理。不要在失败时把旧 INI 全文件回写覆盖外部编辑。
- 页面 settingsSaved() 只清理已确认提交的 dirtyFields/profiles/plugins 标记，更新相应 baseSections/baseProfileStamp，重新比较仍未保存的 draft。**再次复核补充：**仅调用 SettingsPushSnapshot() 不够，因为 receiveSnapshot() 第 2073–2076 行会拒绝带草稿的快照；需要专门的保存回执更新基线，同时保留保存期间用户继续编辑的新值。
- 独立 Everything 工具弹窗也需更新 qbarPluginSaved() 和 [pages/settings.html:1540](../pages/settings.html#L1540) applySavedQbarPluginToDraft()：INI 已提交而别名失败时说明已保存部分并保留弹窗重试，不能关闭并清空全部编辑。若后续将 esMaxResults 归到插件 store 的同一事务，须同步 QbarEsMaxResults() 读取和设置快照，不能只改表单。
- 静态确认：任何“保存失败/部分保存”分支与实际提交标志一致；取消、失败和普通外部快照均不会抹掉未提交草稿。不需要跨文件/SQLite 通用事务框架。

**实施状态：已完成代码修改并静态复核。** `SettingsApplyDraft()` 先校验插件 patch、全局配置和应用 profile，再用 `ConfigPrepareUserOverrides()` 构造 INI 候选；若有 profile 修改，会合并到同一候选文件，全部校验完成后最多原子写入一次。配置写入后才进行运行态重载，再提交独立的插件数据库事务；未引入通用跨存储事务。

宿主 `settingsSaved()` / `qbarPluginSaved()` 回执现在携带 `settingsFileCommitted`、`runtimeApplied` 及各存储域的提交标记和已提交域快照。INI 已写但重载失败时明确报告“已写入、未应用”，不把运行态旧快照标成已提交基线；INI/profile 已应用但插件数据库失败时报告部分成功，并仅刷新已提交域的页面基线。页面保留用户保存期间新增的草稿差异，后续重试只重新提交未完成部分。独立的 Everything 工具保存也会保留弹窗，并在文件搜索数量已保存而插件事务失败时明确指出部分提交；对应 Qbar 设置基线同步到已应用值，避免主页面之后把旧数量写回。插件事务已提交后若剪贴板通知等后续刷新失败，回执仍反映已提交，并显示刷新提示。

插件创建、删除及独立保存也通过保存回执更新内存中的插件基线，因此带有全局未保存草稿时，页面拒收普通外部 snapshot 也不会丢失已提交的 Qbar 状态。回执刷新会保留草稿中相对旧基线已变化的字段；成功保存后再按新基线重新计算 dirty 状态。

静态核查覆盖两种保存入口、全部 `SettingsSendSaved`/`SettingsSendQbarPluginSaved` 回执、INI candidate/write/reload 顺序和页面的 committed-domain baseline 合并。按项目约束未运行 AHK、WebView、脚本或测试；文件监视器遇到部分保存、用户保存期间继续编辑、真实数据库提交失败与 WebView 回执时序仍未运行确认。

### 04 LLM 连接测试同步等待——部分成立，P2 响应风险

- 依据：[settings.ahk](../lib/features/settings.ahk) 的 SettingsRunTest() 调用 LLMChatComplete()；[llm.ahk](../lib/shared/llm.ahk) 的 LLMSendChatBody() 使用 Open(..., false) 和同步 Send()。
- 复核意见：测试调用链在 Send 返回前不能完成。宿主响应可能延迟，但 COM 消息泵/重入及独立 WebView 进程使“整个应用一定卡死”不能仅靠静态代码证实。最长 120 秒配置是各网络阶段超时参数，不是整个请求的最大耗时。
- 修改意见：为非流式请求提供可取消的异步完成接口，带请求身份并在关闭/新请求时失效。保留现有连接测试响应语义，不要求改为 SSE 流式协议；如需要总截止时间，单独定义。

**具体位置与建议改法**

- 位置：[lib/features/settings.ahk:846](../lib/features/settings.ahk#L846) `SettingsRunTest()`、[903](../lib/features/settings.ahk#L903) operation/回执、[76](../lib/features/settings.ahk#L76) 导航完成以及 [1158](../lib/features/settings.ahk#L1158) Hide / [1168](../lib/features/settings.ahk#L1168) Shutdown；[lib/shared/llm.ahk:393](../lib/shared/llm.ahk#L393) 请求构建、[463](../lib/shared/llm.ahk#L463) 非流式异步完成、[516](../lib/shared/llm.ahk#L516) 共用异步 HTTP transport、[743](../lib/shared/llm.ahk#L743) WinHTTP event sink、[828](../lib/shared/llm.ahk#L828) 事件连接、[900](../lib/shared/llm.ahk#L900) 队列调度、[1016](../lib/shared/llm.ahk#L1016) 非 SSE 完成及 [1207](../lib/shared/llm.ahk#L1207) 释放；页面 [pages/settings.html:2056](../pages/settings.html#L2056) 的 payload、2201–2207 回执、2228/2231/2232 三个测试按钮。
- `LLMChatCompleteAsync(messages, onFinished, overrides, structuredOn) -> operation` 已接入 [lib/shared/llm.ahk:463](../lib/shared/llm.ahk#L463)。operation 有幂等 `Cancel()`，`onFinished(responseText, success, errorText)` 保留响应契约；请求使用 `LLMBuildRequest(stream=false)`，不发 SSE Accept、不解析 delta。
- [lib/shared/llm.ahk:743](../lib/shared/llm.ahk#L743) 的共用 WinHTTP sink、[828](../lib/shared/llm.ahk#L828) 事件连接、[900](../lib/shared/llm.ahk#L900) 队列调度及 [1207](../lib/shared/llm.ahk#L1207) 释放由 SSE 与普通 HTTP 共用，响应消费者分开；未复制 COM vtable。finish/error/cancel 经一次终态门，取消先使请求状态失效再 Abort，并释放事件连接与闭包。
- Settings 使用当前测试代次与 owner operation：新测试先递增代次、清空并取消旧 owner；完成回调同时核对代次、窗口可见和页面就绪。Hide、Shutdown、页面加载/导航都会增加代次并取消。验证失败同样通过 `SetTimer` 回调，owner 在启动 child 前发布并通过 `SetCancel()` 接入 child，避免完成或取消后被后续返回值覆盖。
- `provider.test(msg,onFinished) -> operation` 已统一供 Settings 调用。有道/火山都保留草稿 overrides、Hello 请求、成功提示和既有 `settingsTestResult` 回执；最新代次唯一有效，旧完成不能操作新页面。
- 静态调用点检查确认设置测试不再同步调用 `LLMChatComplete()`；因全仓已无调用点，旧的 `LLMChatComplete()`、`LLMSendChatBody()` 和 `LLMResponseText()` 同步实现已移除。设置测试不存在同步等待、轮询或 SSE 降级；取消和释放覆盖新测试、隐藏、关闭与重新导航。网络阶段 timeout 和端到端截止时间仍明确区分，实际响应改善仍待后续允许运行确认。

**实施状态：代码已完成，静态核查通过；未运行程序、脚本或测试。** `lib/shared/llm.ahk` 新增 `LLMChatCompleteAsync()`，以 `LLMBuildRequest(..., stream=false)` 发送普通 JSON 请求，并复用现有 WinHTTP event sink、事件连接点、队列调度和释放函数；完整响应体按 UTF-8 字节累积后交回现有 HTTP/API 错误解析，不发 SSE Accept、不解析 delta。`lib/features/settings.ahk` 的测试消息现在先增加最新测试代次、清空并取消旧 operation，之后异步启动 LLM 或 provider 测试；完成回调要求代次一致、设置窗口可见且页面就绪。Hide、Shutdown 和页面加载失败均先使代次失效再取消 operation。草稿 overrides、Hello 正文、“连接正常”与现有 `settingsTestResult` 回执均保留。全仓没有 `LLMChatComplete()` 的其他调用点，旧同步请求函数已删除，避免保留第二条阻塞传输实现。

**静态核查与未运行边界：**检查了 `SettingsRunTest()`、唯一 `test` 分发点、operation 父子取消绑定、Hide/Shutdown/NavigationCompleted 失效路径和 `LLMChatCompleteAsync()` 完成路径；无同步等待、轮询或 SSE 降级，取消/完成只接受一次终态。此次遵循项目约束，未运行 AHK 语法验证、应用、脚本或测试；实际 COM 事件顺序、取消竞态、网络响应时间及页面重新导航时序仍未运行确认。超时仍是 WinHTTP 网络阶段 timeout，没有新增端到端截止时间。

### 05 用户提示直接展示内部错误——成立，P2

- 依据：[core.ahk](../lib/app/core.ahk) 的 ConfigSet()/RunConfiguredAction()、[settings.ahk](../lib/features/settings.ahk) 的 WebView 初始化以及 [windows.ahk](../lib/features/windows.ahk) 的保存失败均有未经处理的函数名或底层 Message 提示。
- 复核意见：用户难理解、缺少本地化和下一步提示属实；未找到外传链路，撤回“因此泄漏机器信息”的安全结论。应用自己生成的清楚验证错误应保留。
- 修改意见：按功能提供简短本地化说明，必要时提示重试或检查目录权限。底层异常写入日志前脱敏；避免把所有异常统一成没有信息的“失败”，也不要原样展示系统/COM 文本。

**具体位置与建议改法**

- 首批位置：[lib/app/core.ahk:348](../lib/app/core.ahk#L348) `ConfigSet()`、[lib/app/core.ahk:635](../lib/app/core.ahk#L635) `RunConfiguredAction()`；[lib/features/settings.ahk:39](../lib/features/settings.ahk#L39) `SettingsEnsureWebView()`、[82](../lib/features/settings.ahk#L82) 导航回执、[524](../lib/features/settings.ahk#L524) 文件选择器、[1045](../lib/features/settings.ahk#L1045) 窗口选择器及 [1065–1085](../lib/features/settings.ahk#L1065) 应用选择器；[lib/features/windows.ahk:279](../lib/features/windows.ahk#L279) `SaveWindowBinding()`。
- 逐个 catch 把“原始 Message 直接拼 UI”的语句改成按功能生成的两语言说明。例如设置写入失败说明“请确认安装目录可写后重试”，面板初始化失败说明“无法打开此面板，请重试或重新启动”，动作配置错误引导到快捷键设置，而不是把内部函数名当正文。
- 复用当前语言判断/文本 helper（[lib/shared/llm.ahk:14](../lib/shared/llm.ahk#L14) LLMUiLanguage()/LLMText()、core 的 IsChineseLanguage()）；不另外维护一套语言配置。用户主动配置的可读参数错误继续显示，不把所有验证提示变成空泛的“失败”。
- 同一 catch 记录功能、阶段、错误类别和脱敏诊断；不要 dump 传入配置 Map、API 凭据、完整 endpoint/用户正文。core 第 618–619 行当前已经记录底层动作错误，须一起审查敏感字段，避免 UI 修复后将原文无条件搬进日志。
- 静态确认：错误路径均有用户能采取的下一步；页面通知仍用 AppToast/AppDialog，宿主 ToolTip 仍走 ShowMsg()。本条只统一呈现，不改变异常是否返回/重试的业务语义。

**实施状态：已完成首批用户可见错误修正并静态核查。** `ConfigSet()` 的 schema 错误改为本地化字段校验提示；写文件失败提示检查安装目录可写并重试，日志只留 section/key 和错误类型。`RunConfiguredAction()` 的无效 handler 与执行异常改成本地化“检查快捷键设置/重试”提示，日志保留经过格式约束的函数名及错误类型，不再写异常原文。设置 WebView 创建/导航与窗口、应用选择器失败都给出本地化重开/重试说明，不把 WebView/COM/文件选择器消息直接显示给用户。窗口绑定保存失败提示检查所选窗口后重试；读取/写入异常日志改为阶段、绑定号和错误类型。

静态检索确认 core、settings、windows 的目标 UI catch 不再拼接 `Error.Message`；设置整体保存仍按提交状态提示成功、部分成功或失败，应用产生的字段验证错误保留。未运行程序、脚本或 UI；本地化实际显示、各类异常的重试路径以及用户能否据提示修复问题仍未运行验证。

### 06 AI 使用说明仍描述旧会话规则——成立，P2

- 依据：[README.md](../README.md) 的 AI 聊天章节仍说更早内容自动遗忘、新会话清空；[aiChat_store.ahk](../lib/features/aiChat_store.ahk) 支持分页读取历史轮次，并单独加载最近完成轮次作上下文。
- 复核意见：“最近 50 轮”是模型请求上下文限制，不是数据库历史保存上限；新会话创建空白会话，旧会话仍保留。
- 修改意见：分别说明持久化历史、页面分页和模型上下文/token 裁剪，补齐切换/重命名/置顶/删除、data/ai-chat 数据位置及迁移说明。

**具体位置与建议改法**

- 主要修改位置：[README.md:239](../README.md#L239) 的 AI 章节（239–250）；事实来源为 [lib/features/aiChat_store.ahk:487](../lib/features/aiChat_store.ahk#L487) ReadTurns()/LoadContext()（487–534）、[lib/features/aiChat.ahk:599](../lib/features/aiChat.ahk#L599) 页面状态/会话分页（599–695）和 [lib/features/aiChat.ahk:696](../lib/features/aiChat.ahk#L696) 新会话操作。
- 第 242–243 行改成“会话历史保存在本机；新对话进入空白会话，已有会话可从侧栏继续查看”。将“更早内容自动遗忘”明确限于模型上下文，而非删除本机记录；第 248–250 行说明最近轮次窗口和 token 预算是估算裁剪，不能承诺保证任何模型不会拒绝请求。
- 页面目前每批读取 100 个轮次、会话列表每页 50 条（host 第 606/639/675 行）；模型上下文从最近 50 个完成轮次构建后还会再裁剪。README 可用“按页加载”描述，不把这些加载批次数字写成保存上限。
- 补齐切换、重命名、置顶、删除和 data/ai-chat/ai-chat.db 的数据保留/迁移说明，与 [docs/architecture.md:84](architecture.md#L84) 和 [docs/packaging.md:94](packaging.md#L94) 的当前多会话说明一致。
- **再次复核补充：**[pages/usage.html:133](../pages/usage.html#L133) 与第 135 行是相同 AI 功能卡片。后续同步用户介绍时保留一份卡片，并补一句可从历史会话继续；这属于相关文案/布局整理，不需要修改会话存储。

**实施状态：已完成文档和用户介绍同步，静态核查通过。** `README.md` 已区分本机持久化历史、按页读取和模型上下文限制，说明空白新会话不会删除旧会话、历史会话可继续使用，并说明数据目录迁移、覆盖更新与卸载保留。上下文 token 限制改为估算，不再承诺保证服务端不会拒绝。`pages/usage.html` 合并重复 AI 功能卡片并补充历史会话、重命名、置顶与删除说明。架构与打包文档已有对应数据路径和迁移事实，无需改写。未运行程序、脚本或测试。

### 34 设置宿主职责较宽——部分成立，P3 结构建议

- 依据：[settings.ahk](../lib/features/settings.ahk) 同时处理面板路由、全局配置草稿、插件 CRUD、快捷键录制及应用/窗口选择器。
- 复核意见：分区职责明显，但单文件不是已发生功能错误。无需为每个消息分支增加一个服务层。
- 修改意见：以独立状态和完整生命周期为边界，优先抽取录制/选择器或配置校验流程；保留唯一 Settings 路由入口及统一保存结果，避免多套配置校验。

**具体位置与建议改法**

- 拆分锚点：[lib/features/settings.ahk:331](../lib/features/settings.ahk#L331) 的录制主函数（331–344、358–472）及 globals 8–9；[lib/features/settings.ahk:520](../lib/features/settings.ahk#L520) 的应用选择（520–568）和 [lib/features/settings.ahk:844](../lib/features/settings.ahk#L844) 的窗口/应用 picker（844–1025），globals 10–14。346–356 的页面允许列表不属于录制模块，不应整块误搬。
- 若需要拆文件，先抽拟新增的 lib/features/settings/settings_capture.ahk，保留 SettingsStart/StopShortcutCapture、输入钩子回调和发送捕获结果；再抽 picker 文件，集中 WindowPicker 状态和全部取消/恢复流程。函数可保持现名字，唯一消息路由仍在 SettingsWebMessageReceived()（81–141）。
- 全局设置 draft 的 607–729 行与插件修改 143–329 行可在第 03/15 项统一边界后再拆，避免同时搬代码又改变两套保存协议。schema/配置验证不在新模块复制。
- [lib/features/settings.ahk:1050](../lib/features/settings.ahk#L1050) SettingsHide()/Shutdown() 仍负责调用 StopCapture 与 ClosePicker，PanelHost 创建/销毁留在 facade；[capslock_p2.ahk:36](../capslock_p2.ahk#L36) 同步新增 include，[docs/architecture.md:25](architecture.md#L25) 更新模块职责。第 1–2 行“placeholder”旧注释也应随整理改成实际职责。
- 静态确认输入钩子、picker 和宿主各只有一个所有者，关闭/隐藏/取消路径都可清理；不为单个消息建立新服务文件。

## Qbar

### 10 选中候选的执行身份校验不完整——成立，P2 宿主契约缺口

- 依据：[qbar_panel.ahk](../lib/features/qbar/qbar_panel.ahk) 对无效/缺失数字降为 0；[qbar_commands.ahk](../lib/features/qbar/qbar_commands.ahk) 对上下文只做可选检查，candidateId 只验前缀，参数由 text 解析但 commandId 来自页面，二者未绑定。
- 复核意见：[qbar.html](../pages/qbar.html) 在 queryPending 时会阻止执行，正常候选携带上下文；无候选原始文本允许省略 candidateId，是已有设计。当前 [qbar_execution.ahk](../lib/features/qbar/qbar_execution.ahk) 也检查 command 存在、enabled 和 handler 白名单，不能写成任意代码执行。
- 修改意见：明确候选执行与原始文本两条契约。候选执行必须匹配当前 session/query/generation/candidate，从宿主快照取真实 command 和参数；原始文本入口忽略页面给定 commandId/selected，按当前 registry 重解析。复用历史 displayed-ID 管理思路，动态文件/开始菜单候选也纳入同一快照。

**具体位置与建议改法**

- 入口 [lib/features/qbar/qbar_panel.ahk:40](../lib/features/qbar/qbar_panel.ahk#L40) 页面导航失效及 [lib/features/qbar/qbar_panel.ahk:90](../lib/features/qbar/qbar_panel.ahk#L90) `QbarWebMessageReceived()`（query/execute）；查询和发布 [lib/features/qbar/qbar_index.ahk:150](../lib/features/qbar/qbar_index.ahk#L150) `QbarQuery()`、[lib/features/qbar/qbar_index.ahk:338](../lib/features/qbar/qbar_index.ahk#L338) `QbarSendResults()` 与 [lib/features/qbar/qbar_index.ahk:412](../lib/features/qbar/qbar_index.ahk#L412) `QbarSnapshotCandidate()`；验证与执行 [lib/features/qbar/qbar_commands.ahk:3](../lib/features/qbar/qbar_commands.ahk#L3) `QbarExecute()`（含 `QbarExecuteSnapshotCandidate()`、`QbarExecuteRawText()`）；页面 [pages/qbar.html:239](../pages/qbar.html#L239) `requestQuery()`、[pages/qbar.html:392](../pages/qbar.html#L392) `execute()`、[pages/qbar.html:476](../pages/qbar.html#L476) `setResults()`。
- 仅保存一个宿主当前查询快照：session、querySeq/queryId、generation、查询原文及 Map<candidateId,candidate>。QbarRegistryResolutionRows() 保留解析所得 args；FilterItems() 保留真实 value/exe/path 对象；文件夹条目复用 279–304 行的可信完整路径，不以 label/short 反查对象。
- QbarQuery() 各发布分支把原文/解析结果传到快照构建。QbarSendResults() 发布前再次核对可见状态和代次，先整体建立 Map 再给页面显示行；沿用现 candidateId 生成形式，增加实际查表。
- 消息入口严格解析身份，不再把缺失/非法字段默认成 0；排队执行时再次核对快照。generation 要“字段存在且与宿主当前值相等”，SQLite 不可用时的明确静态设置入口需要专门保留，不能把当前 generation=0 与缺字段混同而使设置入口失效。
- 候选分支从 Map 取得 command/args/payload，不再采用 QbarExecute() 第 21–24 行从页面 text 重算参数却执行页面指定 commandId 的组合。原始文本分支允许无 candidate，但忽略 selected/selectedType/commandId，使用本次宿主原文和当前 registry 解析。
- setResults() 增加批次 session/generation 元信息，即使 rows 为空也更新页面当前上下文；否则 raw 执行仍只能从不存在的 row 取身份。新 query、show、hide、shutdown 和 registry 发布清空快照（[lib/features/qbar/qbar.ahk:75](../lib/features/qbar/qbar.ahk#L75)、[lib/features/qbar/qbar_panel.ahk:53](../lib/features/qbar/qbar_panel.ahk#L53)）。
- 保留 queryPending、别名冲突排序、无参数搜索的触发词补全、路径/文件夹操作、Ctrl+Enter 和静态设置 fallback。静态确认所有选中结果都经 Map、参数只来自宿主对象，queued 执行有二次校验；快速输入/重开/配置刷新时序仍待运行确认。

**实施状态：已完成代码修改并静态复核。** `QbarSendResults()` 为每批候选在宿主建立单一快照，记录 session、页面 queryId、宿主 querySeq、registry generation、宿主保存的查询文本，以及精确 `candidateId → candidate` 映射。别名候选在快照中保存宿主解析出的 commandId/args；开始菜单、文件、文件夹等动态候选保存宿主实际的快捷方式路径、exe 或完整文件路径。SQLite 不可用时，仅允许静态内置白名单动作，例如设置入口；页面显示文本本身不成为执行身份。

页面的 `setResults()` 现在即使收到空列表也保存本批 session 和 generation。`execute` 消息必须提供正 queryId、当前 session、generation 和 candidateId 字段；缺失/错误类型不会降级成 0。执行排队后再次核对当前 session、queryId、querySeq、generation 和面板可见性；candidateId 非空时必须精确命中快照 Map，再从 Map 取得 commandId、参数或动态路径。文件/文件夹仍支持 Ctrl+Enter 定位，开始菜单使用快照里的 `.lnk` 和 exe；路径、设置等静态 fallback 都走宿主已有动作。

candidateId 为空时是独立的原始文本路径：宿主采用快照中的原始查询，按当前 registry 重新解析；忽略页面发送的 text、selected、selectedType、commandId。新 query 在入口处立即失效旧快照；显示/隐藏、页面成功或失败导航、关闭、shutdown 及 registry 发布也会清空它。Everything 结果发布还携带并复核启动时的 session/query/generation 上下文。

静态核查确认页面不再发送 selected/commandId 作为执行授权，generic execute 的唯一入口是带完整上下文的 `QbarExecute()`；候选执行只查快照，原始文本只使用宿主快照文本，注册命令仍在 `QbarExecuteRegistered()` 检查当前命令启用状态和 handler 白名单。历史重放仍经既有 displayed-history ID 路径，独立于普通候选执行。按项目约束未运行 AHK、WebView、程序、脚本或测试；快速输入、重开、registry 更新与菜单/文件真实动作时序仍待允许运行时验证。

### 11 删除或禁用工具后旧历史仍能重放——成立，P2 功能缺陷

- 依据：[qbar_store.ahk](../lib/features/qbar/qbar_store.ahk) 的 RetirePlugin() 不更新历史可重放状态，读取历史也不关联当前 enabled/retired；[qbar_history.ahk](../lib/features/qbar/qbar_history.ahk) 只看 entry.replayable，run 历史再由 [qbar_commands.ahk](../lib/features/qbar/qbar_commands.ahk) 直接启动旧 payload。
- 复核意见：必须用户再次选择历史才会执行，不是删除工具后自动启动。历史入口已有当前查询和展示 ID 校验。只更新数据库 replayable 仍不足以修复，因为历史在内存中只加载一次。
- 修改意见：每次重放按稳定 commandId 检查当前 command/plugin 的有效、启用和退休状态；同步更新持久化及内存历史的可执行显示，保留标题快照。最小修复先补稳定 ID 授权、快照 payload 校验和 entry.args；当前 run 重放未使用原参数。动作层统一与第 16 项一并处理，防止复用现注册执行入口后重复记录历史/统计。

**具体位置与建议改法**

- 位置：[lib/features/qbar/qbar_history.ahk:311](../lib/features/qbar/qbar_history.ahk#L311) `QbarHistoryRows()`、[469](../lib/features/qbar/qbar_history.ahk#L469) 逐条重放授权、[554](../lib/features/qbar/qbar_history.ahk#L554) `QbarHistoryReplay()` 及 [575](../lib/features/qbar/qbar_history.ahk#L575) Normalize；[lib/features/qbar/qbar_store.ahk:604](../lib/features/qbar/qbar_store.ahk#L604) 退役事务与 [823](../lib/features/qbar/qbar_store.ahk#L823) SaveHistoryEntry；[lib/features/qbar/qbar_commands.ahk:234](../lib/features/qbar/qbar_commands.ahk#L234) 回放动作；[pages/qbar.html:324](../pages/qbar.html#L324) 不可重放样式及 [pages/qbar.html:406](../pages/qbar.html#L406) 执行门。
- Replay() 在展示 ID 校验后**直接按 entry.commandId**查当前 registry，并核对 entry.pluginId、enabled、pluginRetired/commandRetired、handler 白名单和 payload 类型。不能用 ResolveCommand() 的授权回退：它在 ID 找不到时会按 input 别名查另一命令（216–219）。
- 删除事务同步设置关联持久化历史 replayable=0；临时禁用不永久覆盖此标志，而显示/执行时计算“原 replayable 且当前工具启用”，重新启用可恢复。更新历史缓存/显示，否则只改数据库不影响已加载的旧 entry。
- **再次复核补充：**NormalizeEntry() 第 503–517 行当前遗漏 replayable，应保留它，防止 Remember/Save 把缺字段当作 true。Rows()/SendResults() 向页面传有效可执行状态；[pages/qbar.html:299](../pages/qbar.html#L299) 的渲染及 392–398 的历史执行检查它，Tab 带回原文仍可用。
- run 重放采用 QbarRunCommand(payload.command, entry.args.args) 展开当时原参数，再调用已有启动动作；严格检查 args 字符串。最小语义为“payload 是当时执行设置快照，当前稳定 ID 决定授权”。旧 ResolveCommand() 回退错误已撤销；静态 url fallback 使用稳定 ID `builtin.url.open`，handler 仍是 `builtin.open-url`。
- **不要直接把 Replay 改为 QbarExecuteRegistered()：**它自身会 Remember/usage，Replay 外层也 Remember，Notes/Settings 还有延后成功路径。最小修复先补授权/参数，动作层统一与第 16 项一起处理，成功历史和使用频率只记一次，拒绝不记。
- 静态确认没有按别名重新授权失效历史，Normalize 不丢状态，创建 history 的各路径附真实稳定 ID；删除/禁用/再启用、带参数重放及延后计数需后续运行确认。

**实施状态：已完成代码修改并静态复核。** `QbarHistoryReplay()` 先验证当前 query 与 displayed-history ID，再针对每条历史直接按 `entry.commandId` 查当前 registry，要求 pluginId 精确匹配、命令与插件当前启用且未退役、定义有效并且 handler 在白名单内；kind 与当前 handler 也必须一致。payload 按 kind 校验，run 要求保存的 command 快照和字符串 args；回放以 `QbarRunCommand(payload.command, entry.args.args)` 恢复当时参数。ResolveCommand 不再按 input/别名换授权对象；仅当新建的非插件型 URL/path/shortcut 历史尚无 ID 时，按固定内置 kind 映射 canonical ID，真正回放仍要求历史条目内已有稳定 ID 和 pluginId。

删除插件事务将关联 `command_history.replayable` 持久化为 0，并在事务提交后将已加载缓存同步标为不可重放；仅禁用时保留该位，列表和执行门按当前命令 enabled/retired 即时计算，重新启用后可恢复。列表把 `replayable` 状态传给页面，禁用/删除工具的记录以淡化样式显示并提示可按 Tab 恢复输入；页面阻止直接执行，宿主再次验证。`QbarHistoryNormalizeEntry()` 严格保留 replayable，缺失或格式异常按不可重放处理；store save 缺失标记不再默认写为 1。历史工具标题以记录时快照写入并在重复执行时保留，改名不会改写旧历史名称；shortcut 的展示文本取原输入快照。

静态检索确认执行授权没有通过别名回退；Run payload/args 均从历史条目取值，当前 command 只提供稳定身份授权；settings page 与 url kind 有固定值/协议校验。未运行 AHK、程序、脚本或测试；真实数据库旧历史迁移、删除/禁用/再启用流程、带参数 Run 的操作结果及延迟面板打开路径未做运行验证。

### 12 提交后重建失败导致运行态与数据库不一致——成立，P2 条件风险

- 依据：[qbar_plugin_host.ahk](../lib/features/qbar/qbar_plugin_host.ahk) 修改、删除、新建都先 COMMIT 再 rebuild。若之后读取/构建失败，持久化已变化但仍返回失败。
- 复核意见：撤回“没有原子替换内存注册表”。[qbar_registry.ahk](../lib/features/qbar/qbar_registry.ahk) 已先构造 next，再一次替换运行表/generation。另需处理 settings/usage 读取失败返回空容器被当成成功的情况。
- 修改意见：把现有 rebuild 分为 build 与 publish。在同一 SQLite 写事务/连接内完成变更后构建 next，所有必要读取明确返回成功状态；build 成功才 commit，随后一次发布和失效索引。任何构建/提交失败保留旧表并回滚，不新建数据库副本或事务框架。

**具体位置与建议改法**

- 修改位置：[qbar_plugin_host.ahk:10](../lib/features/qbar/qbar_plugin_host.ahk#L10) 初始化、[45](../lib/features/qbar/qbar_plugin_host.ahk#L45) catalog、[154](../lib/features/qbar/qbar_plugin_host.ahk#L154) apply、[218](../lib/features/qbar/qbar_plugin_host.ahk#L218) delete、[284](../lib/features/qbar/qbar_plugin_host.ahk#L284) create；[qbar_registry.ahk:12](../lib/features/qbar/qbar_registry.ahk#L12) `QbarRegistryBuild()` 与 [120](../lib/features/qbar/qbar_registry.ahk#L120) `QbarRegistryPublish()`；[qbar_store.ahk:530](../lib/features/qbar/qbar_store.ahk#L530) runtime rows、[758](../lib/features/qbar/qbar_store.ahk#L758) settings、[781](../lib/features/qbar/qbar_store.ahk#L781) usage loaders；history usage 消费在 [qbar_history.ahk:45](../lib/features/qbar/qbar_history.ahk#L45)。
- 将 rebuild 拆为 `QbarRegistryBuild(&next)` 与 `QbarRegistryPublish(next)`。Build 只构造候选并返回明确错误；Publish 只交换表和 generation，不做 SQL/页面调用，并失效第 10 项的查询快照。
- settings/usage 读取改为 bool + 输出容器，区分成功空数据与失败；同步 registry/history 全部消费者。JSON 解析失败须作为非法设置处理，不能默认成成功空 Map。rollback 前保存原错误，避免 rollback 清掉原 store error。
- 三种修改和启动 catalog 统一为：预校验 → BEGIN → 写入 → Build → COMMIT → Publish；同一连接可以读自己的未提交数据，不需要库副本。begin 到 publish 保证 AHK 伪线程不重入共享连接，最小方案短 Critical 段且 finally 恢复先前状态；页面、网络与拼音/索引工作不放入该段。
- Publish 后再调用 [lib/features/qbar/qbar_index.ahk:12](../lib/features/qbar/qbar_index.ahk#L12) InvalidateConfigIndex() 及 [lib/features/qbar/qbar_search.ahk:81](../lib/features/qbar/qbar_search.ahk#L81) 的相关索引刷新。**第三次复核精度：**commit 前失败可 rollback；commit 后索引/页面失败只能报告“已保存，刷新失败”并重试刷新，不能声称全部失败都已回滚。
- 保留 next 原子交换、每次发布 generation 只增一次、失败旧 registry/索引仍服务。静态确认关键读取成功才 commit、commit 前不 publish、发布函数无副作用；数据库忙/只读/提交失败及事件重入仍需后续运行确认。

**实施状态：事务发布与查询快照失效已完成，静态核查通过。** [qbar_registry.ahk](../lib/features/qbar/qbar_registry.ahk) 已将候选构建和发布分开；运行表、插件设置、使用记录加载都通过 `bool + 输出容器` 区分读取失败与成功空结果，插件设置及定义 JSON 解析失败会拒绝构建。启动 catalog、修改、删除和创建都在 `BEGIN` 后写入并于同一连接内构建 next，成功后 `COMMIT`，随后在同一 `Critical` 保护段中一次发布；构建/提交失败先保留错误文本、回滚并继续服务旧 registry。`QbarRegistryPublish()` 交换运行表和 generation，并清空 Qbar 当前查询候选快照；它不做 SQL 或页面调用。提交后的索引失效移到事务外，单独记录异常并最多重试两次，不会将已提交数据库操作反馈为保存失败。插件修改预校验已在第 15 项实现。本项其他实际数据库忙/只读/提交失败及事件重入路径未运行确认。

### 13 Qbar 的 AppData 落点与当前约定不一致——成立，P3 已整改

- 依据：[qbar_store.ahk](../lib/features/qbar/qbar_store.ahk) 原使用 A_AppData；[早期插件设计](2026-10-02-qbar-plugin-refactor-design.md) 原本明确指定此位置。当前 AGENTS.md 和 [打包说明](packaging.md) 优先安装目录 data，未说明 Qbar 例外。
- 复核意见：不是已证实的存储故障。历史展示/加载 10 条不等于库只保存 10 条，但本轮也没有容量证据把它定为大型数据库问题。
- 修改意见：统一数据目录归属、设计和备份/迁移说明。若迁入 data/qbar，由 store 检测新旧库冲突并验证迁移结果，不覆盖既有目标库、不删除旧库；若暂保留小型配置库例外，明确记录依据和用户迁移规则。

**实施状态：已完成代码与文档更新；仅作静态核查。**

- [lib/features/qbar/qbar_store.ahk:12](../lib/features/qbar/qbar_store.ahk#L12) 将唯一路径改为 `A_ScriptDir\data\qbar\qbar.db`；[QbarStorePrepareDataPath()](../lib/features/qbar/qbar_store.ahk#L82) 在打开数据库前集中处理旧库迁移与并存冲突。其他 Qbar 模块仍通过 store 读写。
- 目标库已存在时直接选目标库；若旧库也存在，[QbarStoreLogPathConflict()](../lib/features/qbar/qbar_store.ahk#L125) 记录两条路径，并由 [QbarStoreValidateExistingTarget()](../lib/features/qbar/qbar_store.ahk#L144) 只读验证目标库完整性、外键、必需表和 schema version。验证失败则停止初始化、提示两处路径并保留两库，不会将旧库覆盖或合并到无效目标。目标不存在且无旧库时才创建新数据库。
- 仅旧库存在时，[QbarStoreBackupLegacyDatabase()](../lib/features/qbar/qbar_store.ahk#L195) 通过 SQLite 官方 `sqlite3_backup_init/step/finish` API 备份至新目录的独立暂存文件；[QbarStoreVerifyBackup()](../lib/features/qbar/qbar_store.ahk#L269) 检查源库和暂存库的 `PRAGMA integrity_check`、`PRAGMA foreign_key_check`、9 张必需表及每张表记录数。验证和连接关闭成功后，使用 `MoveFileW` 同目录发布；该调用目标存在时失败，不覆盖目标。迁移中断或失败会保留旧库和已生成的暂存文件，不进入新库创建路径，也不回退 AppData。
- [QbarStoreInit()](../lib/features/qbar/qbar_store.ahk#L21) 在创建、打开、初始化或迁移失败时记录具体阶段与底层原因，并以 `ShowMsg()` 提示用户检查安装目录写权限/空间后重试；目标库失败时不会偷偷改用旧库。并存时以目标为准的冲突写入 DebugLog。
- 用户说明见 [README.md:110](../README.md#L110) 与 [README.md:120](../README.md#L120)；设计路径和迁移规则见 [docs/2026-10-02-qbar-plugin-refactor-design.md:224](2026-10-02-qbar-plugin-refactor-design.md#L224)；早期 JSON 历史计划已注明被当前数据库设计取代，见 [docs/2026-09-28-qbar-history-plan.md:7](2026-09-28-qbar-history-plan.md#L7)；安装数据保留和迁移行为见 [docs/packaging.md:94](packaging.md#L94)；架构概览见 [docs/architecture.md:204](architecture.md#L204)。
- 静态核查 Inno Setup [tools/capslock_p2.iss:25](../tools/capslock_p2.iss#L25) 安装目录、[46–85 行](../tools/capslock_p2.iss#L46) 显式 `[Files]` 清单：未列入 `data\`，脚本没有 `UninstallDelete`，因此无需改变安装器。检查 [lib/vendor/CSQLite.ahk:140](../lib/vendor/CSQLite.ahk#L140) 的 `LoadOrSaveDb()`（140–173）会覆盖发布目标并删除暂存文件，故未复用；Qbar store 使用官方备份 API 并自行无覆盖发布。
- **未运行程序、脚本或测试。** AppData 含 WAL/journal 时的真实备份、安装目录只读、并发目标出现及升级/卸载保留行为均未做运行验证；旧库和数据库路径状态的判断只基于静态源码审查。

### 14 Everything 查询的 ES 开关边界——原论证撤回，保留 P2 参数边界问题

- 依据：[qbar_everything.ahk](../lib/features/qbar/qbar_everything.ahk) 将普通 query 直接接在固定选项后。仓内 es.exe 文件版本为 1.1.0.37。[官方说明](https://www.voidtools.com/support/everything/command_line_interface/) 和 [该版本源码](https://github.com/voidtools/es/blob/1.1.0.37/src/es.c) 表明 ES 用 GetCommandLine() 自行解析，普通搜索中的引号按搜索语法保留；-search* 会把剩余文本原样当成查询并停止开关解析。
- 复核意见：空格分成多个普通 argv 不是本项正确论证。把 foo bar 整体加引号可能变成短语匹配，改变 Everything 语义；QbarEsQuoteArg(query) 的原修复意见必须撤回。真正需要防范的是查询中 ES 开关样式文本被当成客户端选项，影响结果数量或导出位置。
- 修改意见：将固定客户端选项放前面，以官方 -search* 建立查询边界，再传原始 Everything 表达式；保留查询自身的短语引号。可执行文件和受信路径仍按各自参数契约处理。这是 ES 选项解析边界，不是 shell 代码注入。

**具体位置与建议改法**

- 唯一构造点：[lib/features/qbar/qbar_everything.ahk:118](../lib/features/qbar/qbar_everything.ahk#L118) QbarEsStartProcess()（118–159，132 query、133–134 command）；probe/search 链在 19–36、88–116 和 229–285。输入链为 [lib/features/everything/everything_panel.ahk:85](../lib/features/everything/everything_panel.ahk#L85) → [lib/features/everything/everything.ahk:161](../lib/features/everything/everything.ahk#L161) BeginQuery/RunQuery（161–213），分类表达式由 71–82 BuildQuery() 生成。
- 保留 probe query="1"、普通 query=arg；移除当前 queryArg 的 probe/空/nonempty 三分支，所有固定客户端选项之后统一追加 " -search* " + query。
- exe、instance、CSV 目标仍用现有各自路径引用；-search* 必须是最后一个客户端选项，其后原样保留 Everything 的短语引号、OR、<…> 分组和分类表达式，不能再拼 limit/export 等选项。
- 页面、分类和 Qbar alias 入口不再整体 quote/反斜杠变换，也不删除看似 ES 开关的搜索文本；边界只在客户端命令构造处处理，避免破坏合法搜索语法。
- 保留 limit+1 截断判断、后端 probe/切换、job seq、取消/重试/超时与 CSV 解码。静态确认每个 ES search/probe 构造都在 -search* 后放 query，之后没有选项拼接；空查询、短语和看似 -n/-export-csv 的文本需后续运行确认。

**实施状态：已完成代码修改，静态核查通过。** `lib/features/qbar/qbar_everything.ahk` 已移除 probe/空值/普通查询各自构造的 `queryArg`，probe 固定使用 `1`、普通查询保留原始 `arg`，并在全部 ES 客户端选项（含导出路径）之后统一追加 `-search*`。静态检查确认 query 不再整体引用或变换，`-search*` 后没有其他客户端开关拼接；探测/搜索仍共用原 job 生命周期与 CSV 导出流程。遵守项目约束，未运行程序、脚本或测试；空查询、短语引号和看似开关的搜索文本仍待允许运行时验证。

### 15 插件修改缺少设置和身份关系校验——成立，P2

- 依据：[qbar_plugin_host.ahk](../lib/features/qbar/qbar_plugin_host.ahk) 的 ApplyPluginChanges() 未核实 plugin/command 归属，settings Map 直接写入；[qbar_store.ahk](../lib/features/qbar/qbar_store.ahk) 按 commandId 更新别名。当前 [设置页](../pages/settings.html) 编辑搜索模板可以保存空值或无 {q} 模板，而新建入口已有相应校验。
- 复核意见：已有工具保存无效模板是普通 UI 可触发缺陷；跨插件 ID 属于不可信/损坏消息的条件风险。外键只保证对象存在，不保证请求中的归属正确。
- 修改意见：PluginHost 收敛一套 validate/normalize，供新建、编辑和整体设置保存调用。先从快照 payload 提取可写 patch，再校验对象有效性、真实归属及关联 definition 的必填/类型/范围/模板规则。settings 内未知字段可拒绝，不能把页面正常携带的只读展示字段一概判成非法。definition/handler 不接受页面覆写。

**具体位置与建议改法**

- 位置：[lib/features/qbar/qbar_plugin_host.ahk:155](../lib/features/qbar/qbar_plugin_host.ahk#L155) apply（155–269）、[275](../lib/features/qbar/qbar_plugin_host.ahk#L275) 严格布尔、[333](../lib/features/qbar/qbar_plugin_host.ahk#L333) settings normalizer、[438](../lib/features/qbar/qbar_plugin_host.ahk#L438) patch/身份校验及 [595](../lib/features/qbar/qbar_plugin_host.ahk#L595) user-plugin create；catalog 的 search/run schema 在 [lib/features/qbar/qbar_plugin_catalog.ahk:162](../lib/features/qbar/qbar_plugin_catalog.ahk#L162)。入口为 [lib/features/settings.ahk:147](../lib/features/settings.ahk#L147) create、[172](../lib/features/settings.ahk#L172) 独立保存及 [642](../lib/features/settings.ahk#L642) 整体保存；页面为 [pages/settings.html:1522](../pages/settings.html#L1522) 创建提交、[1565](../pages/settings.html#L1565) schema 编辑与 [1689](../pages/settings.html#L1689) 独立保存。
- 建议新增 PreparePluginChanges(raw,&patches,&error) 与 NormalizePluginSettings(definition,raw,&settings,&error)，先提取可写 patch、全批次验证后才 BEGIN。可写项限 pluginId、enabled、displayName、settings、commandId/aliases；definition/handler/schema 只取 catalog/registry 的真实记录，页面展示字段不写库。
- 插件和命令均须存在且未退休，command 真正 pluginId 与请求对象一致，不以命名空间前缀替代归属检查。布尔使用严格解析，非法值不默认转 false；复用 alias 归一化/冲突保留，不禁止不同命令别名相同。
- 统一必填字符串、{q} template、非空 command、enum/bool/整数范围规则，复用现 clipboard 严格规则并覆盖整体保存入口。独立工具须在 settings 第 194 行写 INI 之前验证；整体保存须在第 681/698 行写盘之前验证，与第 03 项接线。
- create 也走同一 normalizer，保留宿主生成稳定 ID 及只允许 search/run。**第三次复核补充：**页面创建第 1526–1527 行同时补 template/command，先改成只提交当前类型字段，才能在宿主拒绝 settings 未知字段；编辑页用既有 AppDialog 显示即时错误，仍以宿主检查为准。
- registry Build 的数据库 settings 也经 normalizer，坏数据禁用对应可执行命令并记录诊断；保存后的 ClipboardHistoryOnPluginSettingsChanged() 等通知不能遗漏。run schema 第 191 行声明 append/replace，但执行不消费 argumentMode、create 强制 append；最小方案明确当前仅支持 append，不把 enum 通过误写成 replace 已实现，不顺便开发新模式。
- 静态确认新建/独立/整体/DB加载同规则，未验证前不写任何存储，readonly ID不可覆写。无 {q}/空模板、整体 clipboard、跨插件 ID及配置后的通知需后续运行确认。

**实施状态：已完成代码修改并静态复核。** `QbarPluginHostPreparePluginChanges()` 先从页面对象提取可写 patch，再按当前注册表核实插件、命令及其归属；只接收已存在且未退役的 commandId，不读取页面传入的 definition、handler 或 schema。显示名称、布尔值、setting schema、别名列表都在进入 store 前校验和规范化；schema 拒绝未知字段，URL 模板要求 `{q}`，命令行不能为空或含换行，枚举/布尔/整数按 catalog 限定。别名只在同一命令内按大小写与连续空白归一后去重，不因其他命令存在同名别名而拒绝，因此注册表仍能保留全部冲突候选。

新建、独立工具保存与整体设置保存都先执行预校验；新建页面只发送当前工具类型的 schema 字段。`QbarRegistryBuild()` 也用同一 normalizer 检查从数据库读到的设置，错误设置或不匹配 catalog 的定义会让相应命令停用并写诊断日志，不会执行页面或数据库提供的 handler。整体设置保存路径在任何配置写入之前校验插件变更。

静态复核检查了创建、独立保存、整体保存、DB registry 构建及执行 handler 白名单调用点，并确认普通字段修改不会把页面展示字段写回数据库。未运行 AHK、应用、脚本或测试；各设置值与 WebView 消息的运行时类型、数据库坏数据修复体验和多候选实际排序仍未运行确认。独立 Qbar 保存同时写 INI 与插件数据库时的部分提交回执及页面草稿基线仍由第 03 项处理；火山/搜索模板错误提示的多语言一致性也尚未做运行验证。

### 16 dynamicProviders 尚未接通查询执行——成立，P2 扩展架构落差

- 依据：[qbar_registry.ahk](../lib/features/qbar/qbar_registry.ahk) 仅创建/填充 dynamicProviders，没有消费者；[qbar_execution.ahk](../lib/features/qbar/qbar_execution.ahk) 的 start-menu handler 返回 false，实际开始菜单/路径/URL 由既有 index/commands 分支处理。
- 复核意见：开始菜单当前仍能使用，问题是新动态插件不能仅靠定义/provider 接入。相关内置 fallback 工具被设置页隐藏，不应推导普通用户禁用它们后仍执行的场景。
- 修改意见：复用现有动态候选生成/执行函数，为它们补统一 provider adapter、稳定 commandId 和宿主快照，使 history/usage 复用同一链路。暂不接通时可收窄文档承诺并清理无消费者状态，不以重写全部业务为唯一方案。

**具体位置与建议改法**

- 位置：[lib/features/qbar/qbar_plugin_catalog.ahk:108](../lib/features/qbar/qbar_plugin_catalog.ahk#L108) fallback 定义（108–160）；[lib/features/qbar/qbar_registry.ahk:29](../lib/features/qbar/qbar_registry.ahk#L29) dynamicProviders、72–73 填充；[lib/features/qbar/qbar_plugin_host.ahk:123](../lib/features/qbar/qbar_plugin_host.ahk#L123) handler 白名单；[lib/features/qbar/qbar_index.ahk:3](../lib/features/qbar/qbar_index.ahk#L3) AllItems/start menu/query/filter/folder（3–10、71–155、199–233、263–304）。
- 使用 AHK 中静态 Map 为已有白名单 fallback handler 注册 index/query adapter；复用 handlerId，不另加 providerId、数据库函数名或平行 manifest 系统。registry 只收当前有效/启用且有受信 adapter 的 fallback command。
- AllItems() 经 start-menu adapter 复用现 StartMenuItems 缓存，再附真实 commandId/pluginId/candidateKey；继续进入 [lib/features/qbar/qbar_search.ahk:7](../lib/features/qbar/qbar_search.ahk#L7) 的拼音/首字母索引。路径/URL adapter 复用当前匹配与浏览助手，保留显式别名优先。
- FilterItems() 保留真实快捷方式/exe/path payload，第 10 项快照拥有它；页面只回身份。开始菜单 candidateKey 可为规范化 .lnk 完整路径，统计关联 commandId + candidateKey。
- [lib/features/qbar/qbar_execution.ahk:45](../lib/features/qbar/qbar_execution.ahk#L45) 动态 handler 接收可信 payload，start-menu 55 行不再 return false，调用 [lib/features/qbar/qbar_commands.ahk:385](../lib/features/qbar/qbar_commands.ahk#L385) RunShortcut()；路径/URL复用 416–449 行助手。Ctrl 定位在宿主候选动作层处理，每种接通后再去掉旧 167–184 行对应分支。
- 第一次执行和历史最终共用动作层，但外层只一次 Remember/usage；Notes/Settings 的延后成功回调单独接入，避免第 11 项双计数。当前隐藏的 fallback 工具不随整理变成新用户开关。
- 本项依赖 10/11/12/15，适合实际新增动态工具前实施。保留缓存/预热、拼音、重名排序、路径浏览与静态设置 fallback；静态确认 dynamicProviders 真正被消费且新增 adapter 不改页面/hotkey 业务，实际搜索/排序/定位/统计仍待运行确认。

**实施状态：已完成代码修改并静态复核。** `QbarRegistryDynamicProviderByHandler()` 现在消费 RegistryBuild 收集的已启用 fallback command，适配点仍使用 catalog 中的稳定 `handlerId`，不新增数据库 provider 名称或第二套注册表。`QbarAllItems()` 为开始菜单快照附加当前 `builtin.start-menu.open` 的 commandId、pluginId 和规范化快捷方式路径 candidateKey；文件夹浏览与 Everything 导入结果通过 `builtin.open-path` adapter 保存宿主路径；用户输入的文件/网址通过 `builtin.open-path` / `builtin.open-url` adapter 进入现有注册执行入口。

`QbarExecuteRegistered()` 的 start-menu handler 已执行受信快照中的 `.lnk` 与 exe，路径 handler 保留 Ctrl+Enter 定位，URL handler复用既有打开动作。候选 payload 只从第 10 项宿主快照生成，页面不负责路径解析。注册表存在但 provider 被禁用或无效时，索引不显示其动态候选、输入执行也会拒绝；仅在 SQLite registry 不可用时保留原静态 host fallback。已预热的 StartMenuItems 缓存、拼音/首字母筛选与输入路径行为保留。

动态 candidateKey 用规范化路径关联到 provider commandId；QbarUsageInfo、Store 使用记录和历史重放使用相同的 `usageKey + candidateKey`，删除/禁用授权由第 11 项历史门控制。首选动作都调用 `QbarExecutionRememberRegistered()`，成功历史和使用频率各记录一次；Notes/Settings 延后成功回调未改动。

静态核查确认 `dynamicProviders` 有唯一消费者、开始菜单不再命中 handler 的 `return false` 空实现、开始菜单/文件/文件夹候选执行使用宿主 payload，注册可用时没有绕过禁用状态的 host 直执行分支。按项目约束未运行 AHK、程序、脚本或测试；实际开始菜单索引、排序、Ctrl+Enter、文件打开和候选统计仍未运行验证。

## 翻译与词典

### 17 互译回退、方向显示与旧说明分叉——需重写原结论，P2

- 依据：[translate.ahk](../lib/features/translate/translate.ahk) 对不确定/语言对外结果回退到目标 A。Git 提交 1a961e0（feat: add identifier conversion and translation fallback）明确把旧 needsDirection 改成 ready；[旧互译计划](2026-09-28-translation-modes-plan.md)、README 当前说明和部分架构说明未同步。
- 复核意见：这是后来主动加入的行为，不能只引用较早计划判定 P1 付费错误并要求恢复手动选择。有道 from=auto、火山和 LLM 主要消费目标语言，原文暗示把错误源语言强制传给 provider 也不充分。当前把未知/第三语言来源显示成 B 仍会误导方向理解，needsDirection 分支也需与产品规则统一。
- 修改意见：按当前回退规则更新说明并准确表达“未确定来源、默认目标 A”，避免把 B 显示为已识别来源。若后续产品决定改成严格手动选择，再统一 resolver、控件状态和文档；不要仅凭旧计划撤销已有功能。

**具体位置与建议改法**

- 位置：[lib/features/translate/translate.ahk:152](../lib/features/translate/translate.ahk#L152) resolver（152–219，190–210 回退）；[lib/features/translate/llmTranslate.ahk:217](../lib/features/translate/llmTranslate.ahk#L217) SetDirection() 及 314–323 请求方向传递；[pages/translate.html:509](../pages/translate.html#L509) setDirection()（509–519）、402–414 新原文/手动选择和交换（545–570）。
- 保留目标 A 自动回退，在 resolver 结果增加 fallback 标志或 basis 字段，区别“识别到 B”与“默认按 B→A 处理”；通过 LLMTranslateSetDirection() 传入页面，不把第三语言伪装成已识别 B。
- 最小展示方案是在现有来源控件附近固定显示“来源未确定，默认译为 A”，B/A 仍作为可手选/交换的默认控件值。不要仅写到 loading/ready 随后覆盖的状态栏。手选/交换清除标记，新原文、setSource()（397–416）及设置快照也清除旧标记。
- 不要只把宿主 sourceLanguage 改为 auto：页面第 519–521 行当前拒绝该值，手动校验和交换也以具体语言为契约。上述标志方案无需扩大 provider 来源参数或增加第三种配置语言。
- **再次复核补充：**[README.md:215](../README.md#L215) 第 215–217 行仍宣称识别不确定需手动选择；[docs/architecture.md:99](architecture.md#L99) 第 99–103 行也写不发 API，不只是旧计划。同步这些说明及 [docs/2026-09-28-translation-modes-plan.md:130](2026-09-28-translation-modes-plan.md#L130) 的当前实施契约。当前 resolver 不返回 needsDirection，相关分支/API应明确退役或写清保留用途。

**实施状态：已完成代码与说明同步，静态核查通过。** `TranslateResolveDirection()` 对识别不确定或语言对外来源添加 `fallback=true`，仍以 A 为默认目标；`llmTranslate.ahk` 将该标记传给页面，并移除了当前无生产者的 `needsDirection` 分支。`pages/translate.html` 在语言栏下方常驻显示本地化回退说明；新原文、设置更新、手动选方向或交换后清除旧提示。README、架构说明和原计划均已同步当前行为。静态检索确认没有 `setNeedsDirection`/`LLMTranslateSetNeedsDirection` 调用。未运行程序、脚本或测试；各 provider、切换语言和失败路径的实际显示待允许运行时确认。
- 静态确认：未知/语言对外输入仍 ready 且目标 A，但不再显示为“已识别 B”；识别成功和手动请求不带 fallback，provider target code/sign/prompt 不改。

### 18 有道/火山同步请求——部分成立，P2 响应风险

- 依据：[youdaoTranslate.ahk](../lib/features/translate/youdaoTranslate.ahk) 与 [volcengineTranslate.ahk](../lib/features/translate/volcengineTranslate.ahk) 使用同步 Send()；火山长文批次顺序调用。一次性 provider 返回前完成网络处理。
- 复核意见：SetTimer 仅把工作移出 WebView 回调，同步等待仍存在；但取消/窗口响应的实际延迟未复现。四个 20 秒 timeout 是分别对应网络阶段，不能写成单个请求的总上限。
- 修改意见：与第 04 项复用可取消的异步非流式传输；保留各 provider 的签名、语言代码和响应解析职责。批次需要请求代次和明确截止时间，不把调度延后描述为已经后台异步。

**具体位置与建议改法**

- 位置：[lib/features/translate/youdaoTranslate.ahk:23](../lib/features/translate/youdaoTranslate.ahk#L23) `YoudaoTranslateAsync()`、[89](../lib/features/translate/youdaoTranslate.ahk#L89) 响应解析、[266](../lib/features/translate/youdaoTranslate.ahk#L266) provider 接口；[lib/features/translate/volcengineTranslate.ahk:27](../lib/features/translate/volcengineTranslate.ahk#L27) `VolcengineTranslateAsync()`、[72](../lib/features/translate/volcengineTranslate.ahk#L72) 串行批次、[137](../lib/features/translate/volcengineTranslate.ahk#L137) 换行重建、[180](../lib/features/translate/volcengineTranslate.ahk#L180) 单批签名、[215](../lib/features/translate/volcengineTranslate.ahk#L215) 响应解析、[303](../lib/features/translate/volcengineTranslate.ahk#L303) provider 接口。宿主 [lib/features/translate/llmTranslate.ahk:289](../lib/features/translate/llmTranslate.ahk#L289) 失效、[302](../lib/features/translate/llmTranslate.ahk#L302) 启动/完成、[448](../lib/features/translate/llmTranslate.ahk#L448) Hide / [457](../lib/features/translate/llmTranslate.ahk#L457) Shutdown；provider 契约 [lib/features/translate/translate.ahk:8](../lib/features/translate/translate.ahk#L8)；传输 [lib/shared/llm.ahk:516](../lib/shared/llm.ahk#L516)。
- **取消接口已统一：**翻译控制器保存 provider operation 并调用 `Cancel()`；LLM adapter `TranslateLlmStartStream()` 用 `LLMChatStreamOperation()` 包装底层流 ID，AI 聊天原数值 ID 接口保留。`streaming` 只决定逐段 UI，不再决定是否异步或可取消。
- 有道完成后解析沿用第 04 项共享传输；v3 salt/sign、POST form、全文换行、6000 UTF-8 字节检查、`from=auto`、目标代码和结果格式化均保留。
- 火山 owner operation 保存 lines、segments、批次位置、translated、当前 HTTP child 和终态；单批最多 16 条，通常按 4500 字符累计预算组合，每批独立签名，成功后才串行启动下一批，最后按原换行结构重建。单条超过预算的行仍会作为一个 segment 单独发送，不在本项中擅自拆句；后续须确认接口限制和拆分策略。Cancel 会失效 owner 并 Abort 当前 child；失败或取消都不会发后续批次，没有引入并行或线程。
- InvalidateRequest() 先递增 requestId、清空 operation、重置 running，再 Cancel 旧 operation。StartRequest() 先安装宿主 owner operation 再启动 provider；完成回调绑定 requestId 与 owner，通过 `SetCancel()` 把 child 接入。操作已完成/取消时，后续 child 返回不会覆盖 owner；取消后接入 child 会立即将其取消。火山批次只在前一批成功后推进。有道/火山 test 同步采用回调接口。
- 总截止时间仍未定义；各请求保留 20 秒网络阶段 timeout，不能当作整个多批请求的总时限。静态确认非流式 provider 不触发 SSE UI，签名仍归 provider，取消后的队列无新请求；真实取消时序/端到端耗时仍待运行确认。

**实施状态：代码已完成，静态核查通过；未运行程序、脚本或测试。** `youdaoTranslate.ahk` 与 `volcengineTranslate.ahk` 已把 translate/test 接口改为异步回调并返回幂等 `Cancel()` operation；共享传输使用 `lib/shared/llm.ahk` 现有 WinHTTP sink 和事件队列，不另建 COM vtable。有道仍使用 v3 签名、POST form、`from=auto`、目标语言映射、保留换行和 6000 UTF-8 字节上限；HTTP/API/JSON/空译文错误仍有用户反馈。火山仍逐批最多 16 条，通常按 4500 字符预算组合、每批新签名、串行发送并停在首错；返回分段数量不符会作为失败处理。重建按输入行索引插入换行，能保留前导、连续和尾部空行；取消会中止当前批并阻止后续批次。

`translate.ahk` 已明确 provider `translate(text,onDelta,onFinished,overrides) -> operation` 与 `test(msg,onFinished) -> operation` 的异步契约。`llmTranslate.ahk` 改为保存取消 operation；InvalidateRequest 先递增请求身份、清空当前 operation，再取消旧请求。新翻译回执仍校验请求身份，旧回调不会写入新翻译或已关闭页面。`settings.ahk` 的 provider 测试同样通过设置测试代次与取消句柄管理新旧测试。

**静态核查与未运行边界：**检索并检查了 provider 所有调用点，确认设置测试不再同步等待，非流式有道/火山不走 SSE；请求使用异步 `Open(..., true)` 和共享回调释放路径，没有 `WaitForResponse` 或轮询。复核了有道签名/form/source/字节校验及火山签名字段、批次推进、首错停止和换行重建。火山单条超 4500 字符的 segment 未拆分，真实 API 对其上限的响应仍需确认。按项目约束，未运行 AHK 语法验证、应用、脚本或测试；COM 事件真实时序、Cancel 与响应同时到达、真实 API 签名/响应、批次耗时和页面生命周期仍需后续获准运行时核实。各阶段仍为 20 秒网络 timeout，没有新设总截止时间。

### 19 翻译语言目录多处维护——成立，P3 一致性建议

- 依据：[translate.ahk](../lib/features/translate/translate.ahk)、[config.ahk](../lib/app/config.ahk)、[translate.html](../pages/translate.html) 和 [settings.html](../pages/settings.html) 重复列出语言代码/名称/选项。
- 复核意见：目前集合一致，属于扩展时的同步成本，不是已发生语言选择错误。
- 修改意见：统一稳定代码、显示名称和别名目录，schema/设置快照/页面选项消费同一来源。服务端语言码映射继续留在 provider，避免把所有服务差异塞入通用目录。

**具体位置与建议改法**

- 目录位置：[lib/features/translate/translate.ahk:30](../lib/features/translate/translate.ahk#L30) 的 code/name/alias（30–83）；[lib/app/config.ahk:56](../lib/app/config.ahk#L56) 三个枚举（56–60）；页面 [pages/translate.html:185](../pages/translate.html#L185) 重复目录/归一化（185–286）、[pages/settings.html:323](../pages/settings.html#L323) 固定 option（323–350）及 734–754 aliases。
- 在现有 translate.ahk 定义单一语言目录，记录稳定 code、英文请求名称、当前显示标签/原语言标签与 aliases；Codes/Name/Normalize 从目录派生。schema 两个具体语言枚举也由它派生，system 仅加入固定目标枚举，不进入 A/B。
- [lib/features/translate/llmTranslate.ahk:226](../lib/features/translate/llmTranslate.ahk#L226) PushLanguage() 与 [lib/features/settings.ahk:569](../lib/features/settings.ahk#L569) PushSnapshot() 附上展示目录。[pages/translate.html:532](../pages/translate.html#L532) onHostSettings() 和 [pages/settings.html:2072](../pages/settings.html#L2072) receiveSnapshot() 先建立选项，再填配置值；保持选中代码且目录刷新不标记草稿 dirty。
- 页面移除第二份 alias 表，消费宿主规范代码。首次快照到来前禁用相关提交，不能用尚空的目录把有效草稿重写成默认值；语言顺序和各语种现有标签保留。
- schema 在配置文件中早于 translate 文件包含（入口 18/32 行），只能在函数实际调用时派生目录，不新增包含时的跨文件初始化依赖。provider target code 映射和不支持语言提示留在各 provider。
- 静态确认稳定代码只声明一次，两页和 schema 同源；system、手动不同语言校验及现有 provider 能力不扩大。

### 30 词典联想 SQL 没有处理单引号——成立，已修复，P2 功能缺陷

- 依据（整改前）：[dictionary.ahk](../lib/features/dictionary.ahk) 允许内部撇号，精确查询有 SQL 引号转义；联想 LIKE 与 REGEXP 却直接拼接该文本，DictionarySqlLikeEscape() 只处理 LIKE 通配符。原 GetTable() 查询失败被忽略。
- 复核意见：整改前带撇号的合法查询能产生无效 SQL，缺陷有确定语法依据，无需把它扩大成脚本注入结论。
- 修改意见：复用现有 CSQLite 的 Prepare/Bind/Step 能力，将 LIKE 文本和 REGEXP 模式作为参数绑定；模式构建只负责搜索语义。给查询失败增加不含原文的诊断，避免再增加一套混合 SQL/LIKE 转义封装。

**具体位置与落实内容**

- 位置：[lib/features/dictionary.ahk:24](../lib/features/dictionary.ahk#L24) 合法词规则；[DictionarySendSuggestions()](../lib/features/dictionary.ahk#L327) 三层查询；[DictionarySuggestCollect()](../lib/features/dictionary.ahk#L359) 准备、绑定和取行；[DictionaryFuzzyPattern()](../lib/features/dictionary.ahk#L448) 与 [DictionarySqlLikeEscape()](../lib/features/dictionary.ahk#L462) 分别构建正则和 LIKE 搜索模式。精确查询仍使用其原有引号处理，本项没有重写该查询。已核对 [lib/vendor/CSQLite.ahk:257](../lib/vendor/CSQLite.ahk#L257) Prepare、BindText、Step、Finalize 与 ColumnText 契约；未修改 vendor。
- prefix/contains/fuzzy 三条联想 SQL 现为固定 SQL 文本。LIKE 参数分别绑定 `escaped . "%"` 与 `"%" . escaped . "%"`；fuzzy 将首字母前缀和 `DictionaryFuzzyPattern(word)` 分别绑定。`DictionarySqlLikeEscape()` 仅保留 LIKE 通配符语义，单引号作为参数数据传递，REGEXP 模式也不再拼进 SQL。
- `DictionarySuggestCollect()` 以 `Prepare(sql . " LIMIT 24")` 创建语句，参数位置从 1 开始绑定；`StatementStep()` 返回 100 时按第 0 列读取一行，101 表示完成，其他状态视为失败。收集中的每层结果先暂存，仅在查询成功且 Finalize 成功后并入总候选，避免 Step/读取异常把半层结果带入后续候选。
- Prepare 成功后的所有流程都处于 `try/finally` 中；达到候选上限、绑定失败、Step 失败或异常都会 Finalize。诊断仅记录 tier、stage、输入长度和 API 实际可用的结果：Prepare 可读到其 `ErrorCode`，BindText/Finalize 仅返回布尔值，Step 直接返回 SQLite 状态码；不读这些后续调用未更新的 `db.ErrorCode`，也不记录查询词、SQL 或正则文本。
- 保留频率排序、LIKE/REGEXP 匹配语义、每层 `LIMIT 24`、最终 12 条、跨层去重及 session/query 前后检查。

**实施状态：已完成（仅静态修改与核查；未运行程序、脚本或测试）**

- 修改文件：[lib/features/dictionary.ahk](../lib/features/dictionary.ahk)；更新本节文档。未改页面、vendor 或精确查询。
- 静态核查：三条 SQL 中不再拼接用户词或正则模式；每条 SQL 的占位符数与绑定参数数相符；LIKE 转义和三层查询顺序、排序及结果上限保留；每个成功 Prepare 后均进入 finally 调用 Finalize，失败层的暂存结果不会合并。`git diff --check` 通过。
- 运行边界：按仓库约束未启动脚本/程序、未运行测试，故没有运行时验证撇号词的候选结果或各 SQLite 错误分支。

### 31 词典分层查询的潜在同步成本——部分成立，P3 待度量

- 依据：[dictionary.ahk](../lib/features/dictionary.ahk) 分层执行同步 GetTable()；候选足够即短路，最终 12 条、每层 SQL LIMIT 24 的限制已有。
- 复核意见：包含/REGEXP 和频率排序可能处理较大候选集合，LIMIT 不等于只检查 24 行；本轮没有执行计划/独立耗时证据，不能定为必然全表慢扫描。
- 修改意见：在允许的后续性能工作中先核对索引和各层耗时，再优化 SQL/排序/回退策略。保留现有去抖、查询代次与结果上限，暂不为未经证明的延迟引入工作线程或独立查询系统。

**具体位置与建议改法**

- 位置：[pages/dictionary.html:545](../pages/dictionary.html#L545) 页面 120ms 输入去抖（545–557）；[lib/features/dictionary.ahk:204](../lib/features/dictionary.ahk#L204) 消息/单次 timer（204–239）、255–261 代次守卫、326–374 分层 SQL/Collect；[lib/vendor/CSQLite.ahk:206](../lib/vendor/CSQLite.ahk#L206) GetTable()（206–243）通过同步 sqlite3_exec。
- 先完成第 30 项绑定，Prepare/Step 仍然是同步查询，不能把参数化描述为异步优化。**再次复核精度：**宿主 SetTimer(...,-1) 只是延后，去抖在页面，不是宿主另做一次去抖。
- 后续获准度量时按 tier 记录处理候选量、查询耗时、是否已满足 cap；核对实际词库索引及频率排序查询计划，不能只按 word 的 NOCASE 注释猜测全部执行路径。
- 若某层确有延迟，先处理 SQL/既有索引；减少回退或改变排序会影响候选质量，应说明取舍。层间可以增加 session/query 检查以跳过失效后层，但不能因此声称可打断正在执行的单次 sqlite3_step。
- 静态确认 120ms 页面去抖、12/24 上限、足够候选短路和旧结果丢弃均保留。没有各层耗时证据时，不引入线程、独立连接或后台服务；LIMIT 既不证明只扫描 24 行，也不证明必然扫描整库。

## 输入与窗口功能

### 21 窗口绑定坏数据缺少严格解析——成立，P2 条件缺陷

- 依据：[windows.ahk](../lib/features/windows.ahk) 直接对 count 和 id_n 做 +0，再按 count 循环；初始化调用链没有专门处理该文件中的类型异常。
- 复核意见：非数字值或异常大数量可造成初始化错误/无效循环，但需要外部编辑或文件损坏触发，原 P1 偏高。持久化旧 HWND 已失效是正常恢复场景，不能把“窗口不存在”当成数据格式错误。
- 修改意见：校验数量、索引及句柄数值，限制工作量到实际可解析记录；逐项跳过坏数据并记诊断。完整序列化后复用原子文件替换可避免多次 IniWrite 中断的混合状态，不需要再引入数据库。

**具体位置与建议改法**

- 解析入口：[lib/features/windows.ahk:23](../lib/features/windows.ahk#L23) LoadWindowBindings()；数量和索引校验在 [lib/features/windows.ahk:105](../lib/features/windows.ahk#L105) WindowBindingParseUnsigned()、[lib/features/windows.ahk:131](../lib/features/windows.ahk#L131) WindowBindingItemKeys()；单项句柄解析在 [lib/features/windows.ahk:171](../lib/features/windows.ahk#L171) ReadWindowBindingItem()；原子持久化从 [lib/features/windows.ahk:279](../lib/features/windows.ahk#L279) SaveWindowBinding() 开始。
- 数量先做非负整数字符串及可转换范围检查；按文件实际存在的合法 id_* 索引枚举并保持数值顺序，只消费声明 count 范围内的项，不按巨大 count 做空循环，也不简单 Loop Min(count,记录数) 丢掉稀疏索引。ReadWindowBindingItem() 验证 id 纯数值/指针范围，坏字段返回 0，读完整文件后再发布候选 WinBindings。
- 失效但格式合法的 HWND（含可表示未打开的 0）仍保留有效 exe/path/class 元数据，后续恢复流程用它们找替代窗口；不能把失效句柄一律当坏格式而丢掉可找回绑定。两条当前有/无 count 分支都需要数值保护；本条不顺便添加旧格式迁移。
- SaveWindowBinding() 改为一次准备完整内容并只复用 ConfigAtomicWrite() 文件替换能力，返回明确成功结果；不能调用带应用 ConfigSchema 校验的 ConfigWriteValue() 去写数字绑定段。序列化目标编号时清理该段已不用的旧 id/class/exe/path 项，其他编号的段保持原样。
- **再次复核补充：**当前调用点是 [lib/features/windows.ahk:372](../lib/features/windows.ahk#L372) BindWindowToItem()、[lib/features/windows.ahk:411](../lib/features/windows.ahk#L411) AddWindowToGroup()、[lib/features/windows.ahk:439](../lib/features/windows.ahk#L439) BindWindowToApplication()；原实现先更新内存、忽略 Save 结果并提示“saved”。要求是在持久化成功后发布新绑定/提示成功，失败保留旧绑定；自动刷新调用位于 [lib/features/windows.ahk:535](../lib/features/windows.ahk#L535) 和 [lib/features/windows.ahk:549](../lib/features/windows.ahk#L549)，写盘失败不能撤销已经完成的窗口激活动作。

**实施状态：已完成代码修改和静态核查；未运行程序、脚本或测试。**

- 已在 [lib/features/windows.ahk:23](../lib/features/windows.ahk#L23) 先解析完整 INI 到候选 Map，再一次替换 WinBindings；文件读取失败保留旧 Map。count 通过非负整数字符串及 Int64 可转换范围校验。id_* 按实际存在的索引枚举并按数值排序；有 count 时仅读取 1..count，没 count 时保留旧格式的 0 起始索引，不为巨大 count 循环。重复数字索引、越界/非法索引和非法句柄逐项跳过并 DebugLog。
- [lib/features/windows.ahk:171](../lib/features/windows.ahk#L171) 对 HWND 做纯数字及当前指针宽度范围校验。数值合法但窗口已关闭（含 0）的记录仍带着 class/exe/path 加载，让既有窗口查找/替换流程继续恢复绑定。
- [lib/features/windows.ahk:279](../lib/features/windows.ahk#L279) 先在内存中生成整个绑定段，删除目标编号旧 section 后写回完整内容，通过 ConfigAtomicWrite() 替换；目标段的旧 id/class/exe/path 一并清除，其他 section 内容保留。保存函数返回成功/失败并将技术错误写日志，界面只提示保存失败。
- [lib/features/windows.ahk:372](../lib/features/windows.ahk#L372)、[lib/features/windows.ahk:411](../lib/features/windows.ahk#L411)、[lib/features/windows.ahk:439](../lib/features/windows.ahk#L439) 的单窗口、窗口组、应用绑定现在先保存成功再发布到 WinBindings 并提示成功；自动恢复保存结果在 [lib/features/windows.ahk:535](../lib/features/windows.ahk#L535) 和 [lib/features/windows.ahk:549](../lib/features/windows.ahk#L549) 检查并记录失败，不撤销已完成的窗口激活。
- 静态核查：代码调用链和引用位置已重新检索；针对源码的 git diff --check -- lib/features/windows.ahk 无空白错误。本项实际修改文件为 lib/features/windows.ahk 和本节文档。
- 运行边界：依照 AGENTS.md 禁止启动或运行程序、脚本和测试，因此尚未验证 AHK 语法、实际 INI 原子替换、损坏文件恢复、窗口组/应用启动与失效 HWND 的运行行为。

### 22 快捷键条件与 handler 重复解析——部分成立，P3

- 依据：[customHotkeys.ahk](../lib/input/customHotkeys.ahk) 的 HotIf 条件和执行 handler 都解析活动 profile，并遍历/归一化映射。
- 复核意见：重复解析属实，实际延迟未测量。HotIf 判断不是稳定的“同一事件”缓存边界，前台窗口和配置可能变化；原缓存建议可能发送错误应用动作。
- 修改意见：先在配置加载时构造规范化触发键 Map 和可执行路径索引，减少每次扫描。执行时重新确认活动 profile；未经可靠事件身份与失效机制，不缓存 HotIf 的动作结果给 handler。

**具体位置与建议改法**

- 位置：[lib/input/customHotkeys.ahk:5](../lib/input/customHotkeys.ahk#L5) RegisterCustomHotkeys()（17–34 已遍历全部配置）、[lib/input/customHotkeys.ahk:54](../lib/input/customHotkeys.ahk#L54) 条件/Resolve/Lookup/Send（54–108）；profile 查找在 [lib/input/appProfiles.ahk:165](../lib/input/appProfiles.ahk#L165)。
- 注册前构造规范化的 global action Map 和每个 profile 的 action Map，把当前 CustomHotkeyLookup() 第 86–93 行的逐项归一化移出 HotIf 热路径。条件和 handler 都只做 Map 查询，并在执行时重新读取当前活动 profile。
- 构造时保留现有冲突取值规则：规范化后的原键若本身就是规范形式优先，否则维持当前枚举回退顺序。保留“未找到”和“显式空/特殊动作”的区别，不能用 Map 的默认空值把所有情况合并。
- @native 释放原键、@block 吞掉动作、^v 无覆盖时回退 @builtin_pasteSystem 均保持；注册变更仍按当前绑定 condition 关闭旧 Hotkey，录制期间不启用自定义键。AppProfiles 的加载变化和 CustomHotkey 配置变化各自只重建一次映射。
- profile 路径索引若另行采用，需要保持外部重复路径时“首个有效启用配置”的现有语义；不缓存 HotIf 的动作给 handler。静态确认条件/handler 不再扫描原始配置，而执行前的前台应用检查仍在。

### 23 应用 profile 验证与规范化重复——成立，P3

- 依据：[appProfiles.ahk](../lib/input/appProfiles.ahk) 的 ValidateDraft() 和 PrepareDraftContent() 重复规则；[settings.ahk](../lib/features/settings.ahk) 当前先严格验证，再序列化。
- 复核意见：规则维护成本和未来漂移风险成立；当前严格验证在前，不能说正常保存已静默丢字段。
- 修改意见：一个纯校验/规范化函数返回规范数据和用户错误，序列化只消费结果；保持未知元数据保留规则，不在序列化时再静默修正输入。

**具体位置与建议改法**

- 位置：[lib/input/appProfiles.ahk:200](../lib/input/appProfiles.ahk#L200) AppProfilesValidateDraft()（200–253）与 [lib/input/appProfiles.ahk:255](../lib/input/appProfiles.ahk#L255) PrepareDraftContent()（255–314 重做规范化，316–382 序列化）；调用在 [lib/features/settings.ahk:664](../lib/features/settings.ahk#L664) 和第 691 行。
- 建议把严格验证和规范化提成 AppProfilesNormalizeDraft(profiles, &normalizedProfiles, &errorText)，在一次遍历里处理 ID/path 去重、缺省名称、enabled、Keys/CustomHotkey 标量和 @native 限制；非法用户输入报错，不 continue 丢项。
- SettingsApplyDraft() 第 665 行接收 normalizedProfiles；第 691 行的序列化只消费它，去掉 PrepareDraftContent() 开头第二份规则。当前仅这一个严格 UI 调用链，可直接统一接口，不保留一套兼容包装来重复校验。
- 316–382 行的未知 metadata、未知 key 与额外 KeyProfile 子段保留逻辑必须完整保留，缺省继承仍通过省略空 override 表达；序列化改造不能把它们当成脏数据清掉。
- 静态确认：每条验证规则只在规范化边界有一份；严格草稿错误仍阻止全部 INI 写入；磁盘加载的容错路径与 UI 严格路径不要互相替代。

### 24 每 500ms 重新解析 profile——成立，P3

- 依据：[core.ahk](../lib/app/core.ahk) 无文件时间变化仍调用 AppProfilesLoad()；[appProfiles.ahk](../lib/input/appProfiles.ahk) 每次重读 INI、重建 Map 并完整序列化比较。
- 复核意见：持续重复工作属实，但不能没有耗时证据判为明显性能问题。文件长度不能检测同长度编辑；内容指纹也仍需读文件。
- 修改意见：优先使用更细粒度文件版本判定，或在加载边界比较原始内容后跳过未变的解析/分配；明确后者只减少 CPU/对象工作，不消除 I/O。保留同秒编辑最终一致性，不默认引入复杂监视服务。

**具体位置与建议改法**

- 位置：[lib/app/core.ahk:278](../lib/app/core.ahk#L278) MonitorSettings()（278–294）、[lib/input/appProfiles.ahk:10](../lib/input/appProfiles.ahk#L10) Load()（10–68）、[lib/app/config.ahk:428](../lib/app/config.ahk#L428) INI 读取边界。
- 最小优化可先只减少解析/分配：AppProfilesLoad() 保存最近一次成功读取的原始文档或内容指纹，本次内容相同直接 changed=false 返回，不重建 AppProfiles、不 JSON.stringify；仅内容发生变化后解析并一次发布 Map/Stamp。失败不更新已接受内容，保持可重试。
- 同秒同长度编辑仍通过内容比较发现。若选用内容 hash，仍需读完整文件，不能在文档里称已消除 I/O；仅依赖 length 或秒级 mtime 不可代替内容判定。
- 后续确有磁盘读取成本时才考虑更细粒度文件版本。与第 02 项共同调整后，ReloadSettings() 可把同一次已读取用户段传给 profile builder，避免立即再次读同一 INI。
- 保留 500ms 外部修改响应、AppProfilesStamp 的规范化内容语义及设置页冲突检测；原始 INI/指纹都不写入日志。静态确认空闲路径不重做整个 profile 对象集，读取失败仍保留旧配置。

### 36 F8 的旧动作名与现有语义不符——成立，P3

- 依据：[keys.ahk](../lib/input/keys.ahk) 的 keyFunc_getJSEvalString 只编辑选中文本并复制；默认 INI、demo 和设置标签仍使用旧名/“表达式”文案。
- 复核意见：这是活动配置 API，不能误删编辑能力。原“保留旧名、新增兼容别名”建议与当前不考虑兼容性约束冲突。
- 修改意见：统一准确动作名，例如 keyFunc_editSelectedText，界面显示“编辑并复制选中文字”；同步默认配置、demo、设置标签/分类和文档静态引用，不维护双入口。实际实施时明确告知自定义配置的动作名变更。

**具体位置与建议改法**

- 实现 [lib/input/keys.ahk:354](../lib/input/keys.ahk#L354)（354–359）；默认绑定 [capslock_p2-default.ini:144](../capslock_p2-default.ini#L144)，demo [capslock_p2-settingsDemo.ini:164](../capslock_p2-settingsDemo.ini#L164)；设置标签 [pages/settings.html:833](../pages/settings.html#L833)，工具分类正则分别在第 885 与 954 行。
- 按当前不考虑兼容性的约定，将函数统一命名为 keyFunc_editSelectedText；同步两个 INI 的 caps_f8 以及页面标签/分类。两个分类规则要同时覆盖新名，不能只改展示名使该动作被分到错误类别。
- InputBox 第 356 行同时改为“编辑选中文字”/“Edit selected text”，移除旧表达式暗示及不准确的 capslock_p2 Tab 标题，沿用当前 UI 语言判断。
- 保留 GetSelectedText() 预填、取消时不改剪贴板、确定后通过 SetClipboardText() 写入的行为；原生 AHK InputBox 不是 WebView 弹窗，不需要为本项另外创建面板。
- 静态确认活动代码/默认/demo/设置分类不再残留旧动作名；该编辑能力仍对用户可配置。自定义 INI 名称变更在发布说明中告知，不增加双入口别名。

## 剪贴板与 AI 持久化

### 25 剪贴板容量统计及较宽 Critical——部分成立，P3 待度量

- 依据：[clipboard_history.ahk](../lib/features/clipboard/clipboard_history.ahk) 的 Critical 覆盖保存事务；[clipboard_store.ahk](../lib/features/clipboard/clipboard_store.ahk) 每次汇总用量，超额时逐条删除后重算。
- 复核意见：SQLite [length(BLOB)](https://www.sqlite.org/lang_corefunc.html#length) 不必加载整个 BLOB，不能按每次读取 512 MiB 推算成本；TEXT 转换和关联行遍历仍有开销。500 是默认非收藏/非置顶上限，插件可设 20–5000，收藏/置顶不受数量裁剪；512 MiB 是所计字段的逻辑预算，不是数据库文件大小上限。
- 修改意见：先区分聚合、裁剪和写入耗时。若需优化，优先一次获取候选大小并在原事务内批量裁剪。缩小 Critical 前必须确保共享 SQLite 连接的写事务串行、不会被 AHK 伪线程重入；不能只保留变量赋值 Critical 而放开事务。增量全局容量计数会增加修复/一致性成本，不作为默认方案。

**具体位置与建议改法**

- 位置：[lib/features/clipboard/clipboard_history.ahk:542](../lib/features/clipboard/clipboard_history.ahk#L542) Remember()（542–581，546–576 Critical）；[lib/features/clipboard/clipboard_store.ahk:233](../lib/features/clipboard/clipboard_store.ahk#L233) 保存事务（233–323）、325–344 总量口径、346–374 逐条预算裁剪、455–496 缩略图、534–558 预算修改、569–603 pin、671–681 数量裁剪。
- 本条先保留现结构；后续获准度量时分阶段记录写入、聚合、候选裁剪次数/耗时，只记数量、字节数和阶段。不能按 BLOB 体积推算聚合读取量。
- 若证明反复聚合确有成本，将 325–338 的逻辑字节表达式集中供总量和候选查询复用；item.byte_size 不包括 manifest/text/search/preview/files/note/thumbnail，不能拿它直接替代总预算。
- 在原写事务聚合一次总量；超额才按 is_favorite=0 AND is_pinned=0、保护 ID 及 last_captured_at_utc/id 原顺序一次读取候选 ID/同口径大小，累加挑够后批量删除。不足以释放空间时仍失败并 rollback，expiry/count/byte 三种清理仍属同一事务。
- 最小方案保留 Critical。放开之前须保证共享 connection 所有写入口串行且没有 AHK 伪线程事务重入。victim 缓存清理（clipboard_formats.ahk 的 599/616 起）尽量移到 COMMIT 成功后按实际 victimIds 处理，避免 rollback 后缓存误当项已消失。
- 缩略图当前超预算会回滚/跳过持久化，不主动裁其他项，不应套批量删除改变该行为。maxItems 口径见 [lib/features/qbar/qbar_plugin_catalog.ahk:73](../lib/features/qbar/qbar_plugin_catalog.ahk#L73)：500 默认、20–5000 可设、收藏/置顶不受此数量上限。静态确认所有预算字段、保护与顺序一致；无测量前不新增增量计数/表。

### 26 AI checkpoint 重写完整回答——部分成立，P3 待度量

- 依据：[aiChat.ahk](../lib/features/aiChat.ahk) 每秒最多 checkpoint 一次且仅长度增加时更新；[aiChat_store.ahk](../lib/features/aiChat_store.ahk) 绑定完整 answer 并提交事务，完成/失败最终保存已有。
- 复核意见：长回答有累计文本绑定及事务写入成本，但物理写入量和卡顿未测量。初始化未配置 journal_mode=WAL，撤回特定 WAL 判断。
- 修改意见：优先评估现有时间间隔/增长阈值，明确故障时可丢失的最近文本窗口并保留最终完整保存。不默认引入片段表、追加日志和合并恢复路径。

**具体位置与建议改法**

- 位置：[lib/features/aiChat.ahk:450](../lib/features/aiChat.ahk#L450) 请求开始/重置（450–474）、476–491 delta 调度、494–510 checkpoint、512–572 终态保存、342–387 中断；[lib/features/aiChat_store.ahk:284](../lib/features/aiChat_store.ahk#L284) SaveAnswer()（284–340），101–123 恢复未完成轮次；失败重试 [lib/features/aiChat.ahk:830](../lib/features/aiChat.ahk#L830)（830–852）。
- 首先度量 answerChars、新增字符量与 SaveAnswer 耗时，区分文本绑定/写事务与网络时间，不记录正文。当前没有 WAL 设定，也不能静态选择“最佳”间隔。
- 若需要降低频率，集中声明 checkpoint 间隔，用“增长阈值或最大等待时间”决定保存。最大等待时间不能省，否则低速/暂停流一直没有恢复点；未达阈值但有未保存文本时保留唯一 timer。
- 仅保存成功推进持久化长度/时间；失败保留重试，新增时间状态在开始、完成、取消时一并重置，requestId/turnId/running 守卫原样保留。
- 正常完成、失败、主动取消/关闭的最终完整保存无条件绕过节流；pending answer save、retry 和启动恢复继续有效。静态确认唯一有效 checkpoint、失败不推进基线、终态必存或保留重试；不新增片段表/日志，故障可丢失窗口需与产品目标确认。

### 09 Markdown 外部图片自动加载——事实成立，P3 产品策略

- 依据：[chat.html](../pages/chat.html) 将 marked.parse() 经 DOMPurify 后渲染，未另行限制外部图片；普通 Markdown 图片仍可发起加载。
- 复核意见：自动外连行为存在，但本轮未证实恶意外连或脚本注入；是否允许远程图片是产品策略，不能当成必须禁用的安全缺陷。
- 修改意见：明确外部媒体是否自动加载及允许的 URL 类型。需要隐私控制时再提供简单的按需加载策略，避免无需求引入代理或复杂允许列表。

**具体位置与建议改法**

- 位置：[pages/chat.html:504](../pages/chat.html#L504) renderMarkdown()（504–514）；761–784历史/完成消息、791–800流式bubble、882–913完成渲染；1142–1148链接处理。
- 当前自动加载若继续保留，只同步README的外部媒体说明，不必更改宿主/数据库。按需加载必须属于明确产品决定，不能当本次强制修复。

**实施状态：已按当前行为补充用户说明。** `README.md` 现在说明 AI 回复中的 Markdown 图片会从原网站加载；保留现有自动加载策略，不增加代理、下载或媒体存储逻辑。页面渲染入口仍统一经过现有 `renderMarkdown()`。遵守项目约束，未运行程序、脚本或测试；真实外部请求时机没有运行时确认。
- 若采用按需策略，集中在同一Markdown渲染/插入路径处理远程 src、srcset 及 picture/source 候选，使用现有本地化占位，用户选择后恢复已验证HTTP/HTTPS地址。处理须在进入可渲染聊天DOM前，不用load事件事后拦截。
- 历史/完成/流式均用同一策略，流式重渲染保留本会话用户已选择的加载状态，避免每个delta丢失选择。保留marked/DOMPurify、纯文本回退、dataset.raw和复制原回答，不引入代理/新表。
- 静态确认所有插入点共用renderMarkdown并覆盖srcset；解析/清理阶段是否提前发出资源请求及占位交互仍需后续网络运行确认。没有恶意外连/XSS的复现结论。

## WebView2 与页面结构

### 07 共享宿主缺少集中来源/导航策略——部分成立，P2 加固

- 依据：[panelHost.ahk](../lib/shared/panelHost.ahk) 转发 CoreWebView2.WebMessageReceived 时未读取 args.Source，也未统一限制顶层导航。[chat.html](../pages/chat.html) 已拦截回答链接并由宿主在默认浏览器打开。
- 复核意见：当前没有 FrameCreated/Frame.WebMessageReceived 订阅，不能把 Core 和 Frame 事件混为一谈；撤回不可信 frame 直接调用桥接的断言。本轮没有找到正常流程进入外部顶层页面并发出高权限消息的证据，原 P1 缺乏触发依据。
- 修改意见：共享入口只接受规范化后的预期面板 URL，按页面真实需求制定顶层导航策略。未来若接入 Frame 消息，为独立入口制定来源规则；不预先加入所有 frame 的监听或额外复杂授权层。

**具体位置与建议改法**

- 修改位置：[lib/shared/panelHost.ahk:12](../lib/shared/panelHost.ahk#L12) `PanelHostCreate()`、[65](../lib/shared/panelHost.ahk#L65) `PanelHostEnsure()`、[111](../lib/shared/panelHost.ahk#L111) `PanelHostNavigationStarting()`、[130](../lib/shared/panelHost.ahk#L130) `PanelHostNavigationCompleted()`、[146](../lib/shared/panelHost.ahk#L146) `PanelHostWebMessageReceived()`、[168](../lib/shared/panelHost.ahk#L168) `PanelHostPageUrl()`、[181](../lib/shared/panelHost.ahk#L181) `PanelHostIsPageUri()`、[216](../lib/shared/panelHost.ahk#L216) `PanelHostNavigate()`，事件解绑在 [534](../lib/shared/panelHost.ahk#L534)。
- PageUrl() 用 Windows 官方文件路径/URL 转换（如 UrlCreateFromPathW）生成编码正确的 file URL，避免安装目录中空格/中文/# 改变 URI 含义。共享判断仅接受该宿主的 file 页面，将 URI 还原/规范化路径后与 host.pagePath 比较；同文档 fragment 是否允许明确处理，不按字符串前缀放行整个目录。
- WebMessageReceived() 在任何业务 callback 之前核对 args.Source；不附加 pageReady 前置条件，否则导航完成前发出的 ready/getSettings 会被误拒。业务 session/query/version 守卫仍由功能层负责。
- Ensure() 注册 NavigationStarting 及成对 handler/token，非预期顶层文档 Cancel=true；仅允许导航才重置就绪/记录 NavigationId，完成时忽略被取消/过期导航。Detach/DestroyPage/失败清理同步注销新事件和清除导航状态，不新增 Frame 消息订阅。
- [lib/features/qbar/qbar_notes.ahk:99](../lib/features/qbar/qbar_notes.ahk#L99) 的 qbar-notes.local 虚拟主机仅供图片子资源，不进入顶层页面来源允许列表，也不能被导航限制误禁图片。[pages/chat.html:1142](../pages/chat.html#L1142) 回答链接和宿主默认浏览器打开继续保留。
- 静态确认 source判断先于callback、事件注册解绑成对、只接受确切本宿主页且媒体映射分离。file URI 实际编码/fragment及取消导航完成事件顺序仍需后续运行确认；本条不补造 frame 攻击路径。

**实施状态：代码已完成，静态核查通过；未运行程序、脚本或测试。** [lib/shared/panelHost.ahk](../lib/shared/panelHost.ahk) 现在用 `UrlCreateFromPathW` 生成编码后的面板 file URL；来源校验将 `file:` URI 还原成本机完整路径后与当前 host 的 `pagePath` 比较，并允许同文档 fragment、不接受 query 或其他顶层来源。`WebMessageReceived` 在业务回调及共享光标消息之前核对 `args.Source`，不要求 `pageReady`。新增 `NavigationStarting` handler/token，拒绝非本页导航；只记录允许的 NavigationId，完成回调忽略拒绝或过期 ID，释放时成对解绑。没有增加 Frame 事件。笔记虚拟主机仍只用于图片子资源；聊天链接继续交由默认浏览器打开。实际 WebView2 文件 URL 规范化、片段导航和取消事件时序仍待允许运行后确认。

### 08 指针恢复约定、代码和历史调查不一致——成立，P2 约定落实

- 依据：当前 AGENTS.md 要求所有交互页完整恢复流程；[chat.html](../pages/chat.html)/[aiChat.ahk](../lib/features/aiChat.ahk) 有实现，其他页未覆盖。[旧调查](2026-10-04-webview-cursor-restore-investigation.md) 记录了用户移除鼠标消息后仍正常，以及当时继续试验移除显示调用。
- 复核意见：规范覆盖缺口成立，但不能据此认定其他页当前一定看不到指针。旧调查是历史试验和用户反馈，原文把旧结论无条件判为错误不合理；当前明确提供的 AGENTS 仍决定后续开发约束。
- 修改意见：按当前约定把节流上报与宿主恢复收敛到共享实现，更新旧文档为历史试验状态。若未来采纳移除方案，先统一项目规则和适用证据，避免页面与文档各自采用不同结论。

**具体位置与建议改法**

- 当前位置：[lib/app/core.ahk:1338](../lib/app/core.ahk#L1338) `ShowSystemCursor()`；[lib/shared/panelHost.ahk:224](../lib/shared/panelHost.ahk#L224) `PanelHostShow()`、[146](../lib/shared/panelHost.ahk#L146) 来源校验后消息分支。聊天原监听已删除；共享监听位于 [pages/panel.js:1](../pages/panel.js#L1)。面板专用路径分别在 [lib/features/qbar/qbar.ahk:120](../lib/features/qbar/qbar.ahk#L120)、[lib/features/clipboard/clipboard_panel.ahk:58](../lib/features/clipboard/clipboard_panel.ahk#L58) 和 [lib/shared/windowBar.ahk:55](../lib/shared/windowBar.ahk#L55)。
- 已新增窄职责 [pages/panel.js](../pages/panel.js)：只装一次 passive mousemove，`performance.now()` 约 80ms 节流，存在 `chrome.webview` 才发送 `cursorMove`。Qbar、笔记、聊天、翻译、词典、Everything、剪贴板和设置八个交互页各引用一次；聊天自己的监听与节流变量已移除。
- 宿主已在第 07 项来源校验后集中消费 `cursorMove`，调用 `ShowSystemCursor()` 并返回；聊天重复分支已移除。`PanelHostShow()` 显示时恢复。
- **不能只改共享 Show：** [lib/features/qbar/qbar.ahk:75](../lib/features/qbar/qbar.ahk#L75) `QbarShow()` 经 [lib/features/qbar/qbar_panel.ahk:246](../lib/features/qbar/qbar_panel.ahk#L246) 的直接 `Gui.Show` 显示；当前在激活后调用恢复。剪贴板复用分支及 [lib/shared/windowBar.ahk:55](../lib/shared/windowBar.ahk#L55) 原生模式切换重新激活也已覆盖。向外部应用粘贴的 WinActivate 不属于面板恢复入口。
- 保留现恢复函数“计数恰为0不回减、已经可见时平衡”的逻辑，不更改Windows全局偏好，不加轮询。[tools/capslock_p2.iss:55](../tools/capslock_p2.iss#L55) 逐项清单及 [docs/packaging.md:56](packaging.md#L56) 增加共享JS；旧调查5–9行与旧页面审查61–65行标为历史试验，不抹掉过去用户反馈。
- 静态确认八页只有一份监听、显示/复用/模式切换均覆盖、message确实恢复、新JS已列包。真实键入后指针可见状态仍待后续运行确认。

**实施状态：代码与历史记录已更新，静态核查通过；未运行程序、脚本或测试。** 八个交互页各引入 `panel.js`，聊天专有监听已移除；共享页面每约 80ms 最多发送一次 `{type:"cursorMove"}`。来源通过共享 host 校验后才会触发恢复。`PanelHostShow()`、Qbar 自行 `Gui.Show` 后的激活、剪贴板已显示复用分支及原生窗口模式重新激活路径都调用 `ShowSystemCursor()`。脚本已加入 Inno Setup 显式清单、打包说明和架构资源表；旧调查及页面审查已标为历史试验，保留用户先前反馈。实际键入后指针状态仍待运行确认。

### 20 Everything 动作缺失版本可通过——成立，P2 宿主契约缺口

- 依据：[everything_panel.ahk](../lib/features/everything/everything_panel.ahk) 接受空 resultsVersion；[everything.ahk](../lib/features/everything/everything.ahk) 的 FindResult() 只在非空时转换/比较版本，结果 ID 每组从 1 重建。
- 复核意见：缺失/空字符串明确跳过版本检查；无法转换或转换后不等于当前代次的值已有拒绝。Integer() 本身不是严格格式校验，不能保证小数等非契约值均被拒；正常页面动作会发版本。
- 修改意见：宿主动作入口要求完整且匹配当前结果版本，缺失/非法/过期均拒绝，保留现有 resultsInteractive 与反馈。避免把既有版本机制重新实现一遍。

**具体位置与建议改法**

- 位置：[lib/features/everything/everything_panel.ahk:95](../lib/features/everything/everything_panel.ahk#L95) action分支95–104；[lib/features/everything/everything.ahk:368](../lib/features/everything/everything.ahk#L368) FindResult()/HandleAction（368–399）、164–190查询启动及250–263版本发布；页面 [pages/everything.html:436](../pages/everything.html#L436) 菜单、481双击及618–619键盘动作。
- 消息入口复用 [lib/shared/llm.ahk:162](../lib/shared/llm.ahk#L162) LLMMsgNumber(integerOnly=true)，要求解析成功、结果为 Integer 且版本大于 0 才排队；定时回调接收解析后的整数，不传原始字符串。
- FindResult() 去掉 version="" 默认值，拒绝非 Integer、非正数或与 EverythingResultsVersion 不符，再按 resultId 查找。该函数目前只有 HandleAction 一个调用点，必须同步其参数；不能只在消息入口比较版本，因为 timer 执行前结果集可能变化。
- 新查询开始时立即推进结果版本，使旧菜单/旧结果动作失效；该查询成功后的结果发布使用此版本。这样队列中的旧动作即使在新搜索尚未返回时才执行，也不能操作旧结果。保留单调版本、结果 ID、页面 resultsInteractive、菜单 menuResultVersion 快照和“结果已不可用”反馈，不另建候选快照。
- 静态确认所有动作不能省略 version，入口严格解析正整数，执行前再次比对当前代次；正常页面仍发送版本。菜单刷新、搜索失败时的交互以及真实文件动作反馈仍待运行确认。

**实施状态：已完成（静态核查）**

- 修改 [lib/features/everything/everything_panel.ahk](../lib/features/everything/everything_panel.ahk) 的 action 消息入口：复用 LLMMsgNumber(integerOnly=true)，仅将解析成功的正 Integer 版本绑定到延迟动作；缺失、格式非法、非正数或不能表示为 Integer 的版本不会入队。
- 修改 [lib/features/everything/everything.ahk](../lib/features/everything/everything.ahk)：每次新查询开始时推进 EverythingResultsVersion，查询结果沿用该代次发布；EverythingFindResult() 改为必须传入版本，并在扫描结果前拒绝非正 Integer 及非当前版本。延迟动作因此会在新查询开始或结果更新后被拒绝，原有“结果已不可用”反馈保留。
- 静态核查：动作入口唯一绑定到 EverythingHandleAction；FindResult 只有该调用点且无默认版本；页面菜单、双击和键盘动作都发送 resultsVersion；查询开始、空结果发布、普通结果发布使用一致的递增代次。未运行 AHK、程序、脚本或测试；WebView 消息时序、搜索期间页面反馈和实际文件动作仍未运行验证。

### 32 Everything pageReady 镜像——成立，P3 简化

- 依据：[everything_panel.ahk](../lib/features/everything/everything_panel.ahk) 同时从导航回调和 ready 消息维护 EverythingPageReady；[everything.ahk](../lib/features/everything/everything.ahk) 的 BeginPendingOpen() 和焦点路径又查 PanelHost。
- 复核意见：重复状态存在；原 129 行“直接查询 PanelHost”引用错误，该行仍查镜像，BeginPendingOpen() 才查 Host。最终页面执行已有 PanelHostExecute 就绪门，不能推成已发生错误执行。
- 修改意见：先明确 ready 是否代表脚本安装完成，再选唯一就绪来源；保留通知的触发职责，取消无独立语义的镜像。不要机械删除页面握手。

**具体位置与建议改法**

- 修改前的镜像位于 [lib/features/everything/everything.ahk:11](../lib/features/everything/everything.ahk#L11)，现已删除；当前 Show 的统一就绪门在 [everything.ahk:128](../lib/features/everything/everything.ahk#L128)，PendingOpen 与 Focus 的 Host 检查分别在 135–142、356–360。导航回调和 ready 握手在 [everything_panel.ahk:41](../lib/features/everything/everything_panel.ahk#L41)、76–80；反馈就绪门在 [everything_actions.ahk:141](../lib/features/everything/everything_actions.ahk#L141)。
- 当前ready无额外异步依赖，最小方案统一Host来源：移除EverythingPageReady的全局、复制/复位；Show/反馈改查PanelHostPageReady(EverythingHost)，navigation用局部pageReady完成日志和分支。
- ready分支保留EverythingBeginPendingOpen()触发，只去掉:=true；Host未就绪时该函数会返回，navigation完成后仍会触发，所以两个推进路径都需要保留。[pages/everything.html:639](../pages/everything.html#L639) applyLanguage后发送ready仍在。
- 保留PendingOpen/PendingText/OpenSerial、焦点timer及IconSent重置，Execute仍经PanelHostExecute。与第27抽脚本结合时必须维持原classic script时机。
- 静态确认全仓无镜像引用，pending仅消费一次，ready和navigation都可推进请求；隐藏销毁重建及连续打开顺序待运行确认。本条不意味着当前缺少最终执行就绪保护。

**实施状态：已完成代码简化，静态核查通过。** 已移除 `EverythingPageReady` 全局及导航、ready、隐藏/关闭时的复制和清零；Show、反馈与焦点判断统一读取 `PanelHostPageReady(EverythingHost)`。导航回调仍依据 PanelHost 就绪结果处理图标和待打开请求；ready 消息仍触发 `EverythingBeginPendingOpen()`，Host 未就绪时请求会保留并由导航回调继续推进。静态搜索确认无 `EverythingPageReady` 引用，页面 ready 握手、PendingOpen 序号和 `PanelHostExecute` 门仍在。未运行程序、脚本或测试；事件次序、隐藏重建和连续打开待后续运行确认。

### 27 设置/剪贴板/聊天大页面——部分成立，P3 结构建议

- 依据：[settings.html](../pages/settings.html)、[clipboard-history.html](../pages/clipboard-history.html)、[chat.html](../pages/chat.html) 内嵌较多业务脚本/样式，剪贴板还有长单行处理函数。
- 复核意见：可读性整理有价值，文件长度不能单独构成 P2 缺陷或强制大规模拆分依据。
- 修改意见：先恢复多行格式，再按独立状态/实际修改集中度抽取页面专属 JS 和必要局部样式。共享视觉仍归 theme.css，不引入构建框架，也不把简单交互拆成大量模块。

**具体位置与建议改法**

- 位置：[pages/settings.html:415](../pages/settings.html#L415) 内联脚本415–2255；[pages/clipboard-history.html:121](../pages/clipboard-history.html#L121) 内联121–730（569 focusHistoryRow、593 contextAction及594–727有长单行）；[pages/chat.html:198](../pages/chat.html#L198) 内联198–1260。
- 先按语句恢复多行格式。首轮抽取可每页仅一个专属脚本：拟新增settings-page.js、clipboard-history.js、chat.js，HTML在原script位置用普通classic script src替换。settings-page.js避免与已退役旧settings.js混淆，不立即拆几十个模块/引入ESM。
- 完整保留window.*宿主API、DOM查询时机、WindowBar初始化与vendor顺序（聊天marked/purify先加载）；设置单一draft、剪贴板session/query/busy/图片observer清理、聊天viewGeneration/requestId/序号/requestAnimationFrame仍在同一个页面状态所有者内。
- [tools/capslock_p2.iss:55](../tools/capslock_p2.iss#L55) 55–62是显式JS清单，三个新增文件必须逐项列入；抽CSS也需显式列入。同 [docs/packaging.md:56](packaging.md#L56) 与architecture页面资源表一起更新，不在本次审查重新打包。
- 静态确认原window入口数量/名字没有遗漏、脚本路径和清单相符、依赖顺序未变，没有多份state或file URL下新ESM依赖；加载时序和交互一致性仍待运行确认。

### 28 共享主题的字体/圆角与旧变量——成立，P3 一致性整理

- 依据：[theme.css](../pages/theme.css) 主要提供颜色/阴影；多个页面重复默认字体，部分页面沿用映射到新主题的旧别名。
- 复核意见：当前默认字体实际上相同，配色也统一，未证明已有字体漂移。词典正文等合理字体差异应保留。
- 修改意见：集中默认 UI 字体及少量圆角尺度；必要组件允许明确覆盖。先迁移并核对全部引用再移除旧变量，不创造过多主题 token。

**具体位置与建议改法**

- 位置：[pages/theme.css:3](../pages/theme.css#L3) token/alias（3–67）、109行控件字体继承；默认字体在chat:8、clipboard-history:14、dictionary:10、settings:10、everything:20、translate:8、qbar:17、qbar-notes:21。
- 增加一个默认UI字体变量如 --ui-font-family，在共享根设置默认；各页移除相同根声明，必要font shorthand只引用变量并保留原字号/行高。圆角先集中实际重复的8px控件/12px卡片等少量值，同值替换，不顺带重设计外观。
- 保留dictionary第106/173/203行的词头/正文衬线字体、代码和编辑输入等宽字体、pill/圆形及零圆角布局。旧alias消费者包括dictionary/settings/qbar/ui-preview，按真实映射逐项迁移后才删无人使用变量；--gold是独立字面色，不能假定等同任一ui token。
- Qbar --card-radius及派生内圆角需与 [lib/features/qbar/qbar.ahk:57](../lib/features/qbar/qbar.ahk#L57) QbarCardRadius、[lib/features/qbar/qbar_panel.ahk:265](../lib/features/qbar/qbar_panel.ahk#L265) 原生裁剪一致，不能只改页面公共数值造成边缘接缝。
- 静态确认默认UI字体单一、内容字体保留、移除alias无消费者、Qbar宿主/页面半径相同，深浅色逻辑仍只在共享主题。视觉效果未运行确认。

### 29 小型 bridge/窗口栏状态重复——需收窄，P3 可选

- 依据：多页重复两行 post()；chat/translate 对 WindowBar 已更新的 class/aria-pressed 又重复更新。
- 复核意见：两行 post() 本身不足以证明值得新建公共模块。dictionary/Everything 的本地化文案属于页面既有职责，不是必须抽象的重复。
- 修改意见：优先消除 WindowBar 状态的实质重复，页面继续提供本地化标签。只有统一消息/错误策略确有需要时才增加薄 bridge，不把业务 payload 塞进共享层。

**具体位置与建议改法**

- 位置：[pages/windowbar.js:107](../pages/windowbar.js#L107) setPinned()（107–115）已处理class/aria-pressed；[pages/chat.html:406](../pages/chat.html#L406) applyPinnedState()（406–412）和 [pages/translate.html:293](../pages/translate.html#L293)（293–301）重复处理。
- 最小修改移除chat第409–410与translate第295–296行的重复class/aria写入，保留WindowBar.setPinned()；页面继续更新本地化title、aria-label、data-label，translate pinned变量/dataset.i18n/语言切换也保留。
- [pages/dictionary.html:379](../pages/dictionary.html#L379) 与 [pages/everything.html:363](../pages/everything.html#L363) 的标签处理符合页面职责，不为消除两行post新增通用bridge。第08共享光标脚本也不接管业务payload/session/路由。
- 保留chat第1248–1250行宿主setPinned支持的参数格式、WindowBar.init幂等/拖动/窗口操作。静态确认class/aria所有者只有WindowBar而页面文字仍随语言更新，协议不变；屏幕阅读/置顶真实展示需运行确认。

**实施状态：已完成，静态核查通过。** `pages/chat.html` 与 `pages/translate.html` 的 `applyPinnedState()` 现在只调用 `WindowBar.setPinned()` 写 class/aria-pressed；页面仍更新自己的置顶/取消置顶文案与 title，消息协议不变。静态搜索确认 pin class 和 aria-pressed 只由 [pages/windowbar.js:107](../pages/windowbar.js#L107) 的共享方法写入。未运行页面；视觉及屏幕阅读器表现仍待运行确认。

### 33 设置动态列表一并渲染——部分成立，P3

- 依据：[settings.html](../pages/settings.html) 的 renderAll() 重建多个动态列表；refreshStaticControls()/renderHotkeyScope() 更新已有控件与状态，并非重建全部静态 DOM。
- 复核意见：receiveSnapshot() 有 dirty/draft 保护，草稿保存在独立 state，撤回草稿丢失暗示。多列表 DOM 工作属实，焦点/展开影响需具体路径确认。
- 修改意见：局部操作优先只刷新相应列表；先测量规模增长的成本。暂不默认引入 mounted/dirty/version 等多组懒挂载状态和通用 DOM diff 系统。

**具体位置与建议改法**

- 位置：[pages/settings.html:2040](../pages/settings.html#L2040) renderAll（2040–2045）；786–789静态控件更新；1030–1116 shortcuts、1274–1288 custom、1290–1297 pairs、1740–1748 plugins、1785–1839 bindings；2072–2106外部快照草稿保护。
- 建议窄职责renderHotkeyEditor()只刷新scope/custom/shortcuts；全局/profile选择1867–1871、1938–1941及新应用2024–2039调用它。profile启停1927–1933只刷scope/应用列表；删除1904–1921仅当前范围改变时重绘；首次完整快照2102行仍renderAll。
- 恢复继承1021–1024只刷相关快捷键区域。**再次复核补充：**当前该动作renderAll→renderShortcuts创建新details（1047–1049）→applyShortcutFilter第971行在无搜索时设open=false，同范围手动展开组会重新折叠，是明确源码路径。
- 若保留展开状态，在同一范围重建前临时记录open group ID；先完成过滤，再在无搜索词时恢复open。搜索自动展开不被覆盖，范围切换是否重置沿既有交互；不新增全页持久mounted/version/DOM diff状态。
- 保留draft/baseSections、dirtyFields/pluginsDirty/profilesDirty、快照保护、录制停止规则、过滤/overridesOnly和AppDialog。静态确认局部profile操作不刷新Tab/插件/绑定，首次snapshot仍完整，所有相关UI都被更新；实际焦点/过滤/收益待运行确认。

### 35 Everything 逐行事件监听——事实成立，P3 可选

- 依据：[everything.html](../pages/everything.html) 为每行绑定多个事件闭包，结果数量已有上限。
- 复核意见：未证明监听器是瓶颈，直接闭包也可保持代码清晰，事件委托不是必做修复。
- 修改意见：页面整理时可合并到容器委托，但须保持 resultsInteractive 检查、选择行为和结果版本传递；否则保留现实现即可。

**具体位置与建议改法**

- 位置：[pages/everything.html:441](../pages/everything.html#L441) renderResults（441–487，455附近data-index、478–482四种监听）；488–504选择、424–440菜单、614–621键盘。
- 当前可直接保留闭包；若改委托，在resultList仅注册一次mousedown/click/dblclick/contextmenu，用closest('.result')并确认目标仍属容器，保留mousedown原preventDefault，其他动作先检查resultsInteractive。
- 严格读data-index后从sortedResults()取当前项；可同时存data-result-id/data-results-version，处理时核对当前项版本，避免旧DOM或排序变化指向错误项目。click保留选择/列表焦点，dblclick带ID/version打开，contextmenu沿showMenu。
- 保留loading/error/stale不可执行、排序/图标缓存、菜单打开时menuResultId/menuResultVersion快照、Enter/Ctrl+Enter/Ctrl+C/方向键。空白容器右键不被结果行委托接管。
- 静态确认render不再创建四类监听、容器注册一次、索引对应排序后列表、所有动作仍带版本；单双击顺序/子节点/排序后的真实行为与性能收益待运行确认。

**处理状态：按复核建议保留现实现，本轮不改事件绑定。** 该项为可选整理，当前闭包实现清楚且没有监听开销证据；依项目约束不能运行性能测量，暂不以文件行数或监听数量推导瓶颈。静态确认现有监听仍走 `resultsInteractive`、结果版本及菜单快照保护；后续页面整理若发现实际收益，再按本节方案改为委托。

## 后续修改顺序与实施边界

1. 继续优先修复第 02、03、10、11、15 项的输入/保存/重放契约，以及第 12 项的提交发布一致性；第 20、21、30 项已完成。
2. 第 06、09、14、17 项已完成；第 08 项仍需统一指针约定，第 13 项正在迁移数据目录并同步说明。
3. 第 16 项在实际新增动态工具前接通扩展边界；其余拆分、元数据集中和重复逻辑整理随相关功能变更实施。
4. 第 04、18、25、26、31 项分别记录机制与待确认耗时。当前约束仍禁止运行程序/脚本及编写测试，性能测量只能在后续明确允许的工作中安排；本次没有新增诊断代码。

所有建议优先复用现有官方绑定、store、registry、PanelHost 和页面公共服务；不为推测风险引入平行系统，不默认加入兼容层、事务框架、工作线程或新数据表。


### 建议实施批次与依赖

| 批次 | 条目 | 应先完成的接口/边界 |
| --- | --- | --- |
| 独立的小范围正确性修复 | 02、20、21、30 | 配置读取结果、严格结果版本、窗口绑定解析/保存结果、词典参数绑定；20、21、30 已完成，02 进行中。 |
| Qbar 保存基础 | 12、15 | 先定义并统一插件规范化、关键读库成功结果、Build/Publish 与提交回执语义。 |
| Qbar 执行与历史 | 10、11 | 复用上述真实 registry，补当前快照和直接稳定 ID 授权；先保留原动作层，避免记历史两次。 |
| 设置部分提交反馈 | 03 | 依赖 02/12/15 的明确状态；宿主回执与页面基线更新必须同批，不能只改提示文案。 |
| ES 参数与说明 | 14、06、17 | 已完成；文案按当前真实分页/回退语义同步，没有恢复已主动改变的旧规则。 |
| 网络请求生命周期 | 04、18 | 非流式 HTTP、provider.test 和翻译 Cancel operation 同批接线；LLM SSE/AI 的既有 ID 接口只做局部 adapter。 |
| 共享面板与资源 | 07、08、27、28、32、33、35 | 来源事件注册/解绑、八页脚本和显式安装清单成套；页面拆分/局部整理按需要逐步实施；29 已完成，35 保留既有闭包。 |
| 扩展及待度量整理 | 16、01、19、22–26、31、34、36 | 动态 adapter 依赖 10/11/12/15；性能项先有允许环境的耗时证据，结构项保留所有权和现有行为。 |

每一批以文档中的“静态确认”作为代码审阅清单；它们是源码关系核对，不是新增测试。涉及网络、事件重入、窗口/指针或视觉的运行边界保持待确认，当前任务不实施这些验证。

## 复核方法与限制

- 阅读了完整相关调用链、当前 AGENTS.md、原设计/整改/调查说明，并用 git log/show 核对关键后续行为变更。
- 查看现有日志的相关事件/错误记录；未见容量聚合、checkpoint、profile 监视或词典分层查询的独立耗时证据，不能由事件间隔归因性能瓶颈。
- ES 参数语义核对了仓内文件版本和同版本官方源码；SQLite BLOB 长度成本核对了官方说明。
- 未启动项目、运行程序/脚本、编写或执行测试，未修改实现文件。因此条件故障和性能影响没有被表述为动态复现结论。
