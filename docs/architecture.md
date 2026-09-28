# 架构说明

面向开发者与贡献者的代码地图。构建与发布流程见 [`packaging.md`](packaging.md)，用户使用说明见根目录 `README.md`。

## 顶层设计

- 入口 `capslock_p2.ahk` 用 `#include` 引入全部 `lib/*.ahk`；AHK v2 中每个被包含的文件加载时即执行，
  全局变量和函数在所有文件间共享。
- **键盘层**：按住 CapsLock 进入键层，`lib/input/keymap.ahk` 做键位方案与层调度，`lib/input/keys.ahk` 提供
  `keyFunc_*` 动作函数；`lib/input/customHotkeys.ahk` 注册不占用 CapsLock 层的全局快捷键映射。
- **UI 面板全部是 WebView2**：`pages/*.html` 由 AHK 侧通过 `lib/shared/panelHost.ahk` 创建控制器并承载。
  AHK ⇄ 页面双向通信通过 thqby ahk2_lib 的绑定（`WebView2.ahk`）——页面用
  `window.chrome.webview.postMessage` 发 JSON，宿主统一接收并调用页面函数。
- **翻译引擎是 provider 注册表架构**：面板调度只认识注册表，不认识具体引擎（见下）。
- **LLM 公共层**：`lib/shared/llm.ahk` 统一读取 `[LLM]`、估算并裁剪输入 token、组装
  OpenAI 兼容请求、处理同步响应和 SSE 流，并提供配置提示词模板渲染；翻译与 AI 只提供各自的消息内容和结果处理。
- **配置分层**：`capslock_p2-default.ini` 保存完整默认值，`capslock_p2-settingsDemo.ini` 只作详细参考，
  `capslock_p2.ini` 只保存用户覆盖项。`lib/app/config.ahk` 先加载默认配置，再叠加用户配置；设置页保存时会删除恢复为默认值的覆盖项。

## 目录结构与模块职责

```
capslock_p2.ahk                    入口：#include 全部 lib 模块
lib\
  config.ahk                       schema、字段 codec、INI 解析、默认覆盖层、类型读取与原子写入
  core.ahk                         初始化、剪贴板、热串匹配、选区读取与公共服务
  windows.ahk                      窗口管理、winbind、热键注册
  keys.ahk / keymap.ahk            keyFunc_* 动作 / 键位方案与键层调度
  customHotkeys.ahk                [CustomHotkey] 全局快捷键重映射
  panelHost.ahk                    WebView2 GUI、controller、导航、脚本执行与焦点生命周期
  icons.ahk                        shell 图标提取（HICON → GDI+ PNG → data URI）
  qbar.ahk                         qbar 状态与稳定入口
  qbar_panel.ahk                   qbar 面板生命周期、消息和尺寸
  qbar_index.ahk                   条目索引、过滤和图标行准备
  qbar_commands.ahk                命令、运行、网址和 AI 调度
  qbar_everything.ahk              Everything 后端、异步可取消作业、CSV 与 UTF-8 解析
  qbar_navigation.ahk              文件夹导航和路径补全
  translate.ahk                    翻译引擎注册表与共用翻译配置（provider 契约与调度解析）
  languageDetect.ahk               互译模式的本地原文语言识别与候选状态
  llm.ahk                           共用 LLM 配置、token 估算、请求体、同步/SSE 请求与响应解析
  llmTranslate.ahk                 翻译面板本体 + 翻译提示词 + 各引擎的调度编排
  youdaoTranslate.ahk              有道智云翻译 API（[TYoudao]，WinHttp + SHA-256 签名）
  volcengineTranslate.ahk          火山引擎翻译 API（[TVolcengine]，V4 签名、TextList 分批）
  crypto.ahk                       SHA-256 / HMAC-SHA-256 签名基元（BCrypt）
  dictionary.ahk                   本地词典卡片（ECDICT 词库只读查询与序号队列）
  aiChat.ahk                       AI 聊天面板（使用 [LLM]、[QAI] 仅存行为设置、多轮对话）
  WebView2.ahk / ComVar.ahk / Promise.ahk   thqby ahk2_lib WebView2 绑定（保持官方原名）
  CSQLite.ahk / JSON.ahk           thqby ahk2_lib SQLite / JSON 官方库（保持原名）
pages\                             WebView2 面板页面
  qbar.html / translate.html / dictionary.html / chat.html / settings.html   WebView2 面板页面
  usage.html                        独立「使用介绍」页，浏览器打开（CapsLock+F1），不走 WebView2
  vendor\                            marked.min.js + DOMPurify（AI 回答 markdown 渲染）
  resources\                         es.exe、内置 Everything、SQLite3.dll、dictionary.db、图标
userAHK\                           用户自定义入口（main.ahk，自动加载）
WebView2\                          WebView2Loader.dll（32/64 位）
tools\                             Inno Setup 打包配置与脱敏 ini（不参与运行）
capslock-plus\                     原版 AHK v1 源码（只读参考，禁止修改）
```

`math.ahk`、`jsEval.ahk`、`loadScript\` 和 `pages/settings.js` 已退出运行路径，并在本轮用户授权的退役清理中删除；
它们不属于当前运行时架构。旧诊断脚本同样不作为配置行为验证依据。

## 翻译引擎注册表

`lib/features/translate/translate.ahk` 是所有翻译引擎的编排层。每个引擎 = 一个客户端文件（`lib/features/translate/*Translate.ahk`）+
该文件**底部一行 `TranslateRegisterProvider("engine", Map(...))` 自注册**。面板
（`lib/features/translate/llmTranslate.ahk`）只通过注册表取 provider：

- `TranslateResolve(engine)`：`[TTranslate] engine` 指定 ID 则按指定取（未配置也返回，
  用于显示该引擎的 `notConfigured` 提示）；`auto` 优先第一个已配置的 `llm`，否则按注册顺序
  找第一个 `configured()` 为真的引擎。
- 调度、设置保存和 API 测试全部按 engine 查表；`TranslateProviders()`
  返回全部已注册引擎供页面逻辑遍历。
- `[TTranslate]` 的 `mode=fixed` 使用 `targetLanguage`；`mode=bidirectional` 使用 `languageA` 和
  `languageB`。`TranslateResolveDirection()` 在 provider 调用前生成一次请求快照，固定模式直接解析目标，
  互译模式根据 `languageDetect.ahk` 或面板的原／目标语言选择生成方向。三个 provider 只消费快照中的目标语言。
- `languageDetect.ahk` 对中日韩、阿拉伯文、俄文等脚本做本地识别，对拉丁文字使用常见词评分；证据不足时返回
  `ambiguous`，面板要求用户选择原语言和目标语言，不发起 API 请求。

provider 契约（`Map` 的字段）见 `lib/features/translate/translate.ahk` 头部注释，核心是：

| 字段 | 用途 |
|---|---|
| `streaming` | 1 = 流式引擎（面板走逐片段 UI）；0 = 一次性返回 |
| `configured` | `() -> bool`，引擎是否已配置可用 |
| `translate` | `(text, onDelta, onFinished, overrides)`，必须调用 `onFinished(answer, success, errorText)` |
| `test` | 可选的固定 `Hello` API 测试 |
| `save` | 写该引擎自己的 ini 字段（「已保存但字段仍为空」的警告文案在 `saveEmpty`） |
| `push` | 返回设置表单字段表，合并进面板的设置推送 |

新引擎的热路径由一条规则概括：**只加一个客户端文件 + 一行注册 + 更新中央设置页的字段元数据**，
面板与协议层的 `LLMTranslate*` 前缀保持不动。

### 已接入引擎

- **llm**：OpenAI 兼容 `chat/completions` 流式接口，是面板的默认与优先引擎。翻译和 AI
  问答共用 `[LLM]`，问答的专用系统提示词和 `hideOnBlur` 保存在 `[QAI]`。系统提示词要求保留原文的换行与段落结构。
- **youdao**：有道智云 v3，`[TYoudao] appPaidID/appPaidKey`，目标语言使用调度快照并映射到有道代码。同步 WinHttp 请求放到
  `SetTimer(fn, -1)` 回调外执行；签名 = `SHA256(appKey + input + salt + curtime + secret)`，
  `input` 按 ≤20 字符规则截取，`salt` 用 `UuidCreate`。多行文本按行提交、结果按行拼回。
- **volcengine**：火山引擎机器翻译，`[TVolcengine] accessKey/secretKey/region`，目标语言使用调度快照（region
  默认 `cn-north-1`）。V4 签名与地区相关的部分用 `crypto.ahk` 的 `CryptoSha256Hex` /
  `CryptoHmacSha256`（返回二进制 Buffer 供链式调用）。每次请求用 `TextList` 分批
  （≤16 条 / ≤4500 字符），用 `TranslationList` 按序取回后重建原换行结构。

### 多段翻译为什么能保留分段

三个引擎从三条不同路径保住了分段：

- LLM：系统提示词显式要求保持换行与段落结构；
- 有道：表单体用百分号编码，文中换行在请求里存活，服务端按行翻译、客户端按行拼回；
- 火山：客户端自己把文本按行拆成 TextList 条目，翻译后按顺序放回（空行在拆的时候记录、
  拼的时候补回）。

## WebView2 面板

所有 WebView2 面板共用 `lib/shared/panelHost.ahk` 的生命周期；功能模块只保存业务状态和页面回调。宿主统一持有 GUI、controller、WebView、导航就绪状态、事件 token 和焦点监视器。
设置页和 AI 页是普通可调整大小的窗口；qbar、翻译、词典默认失焦隐藏，AI 是否失焦隐藏由 `[QAI] hideOnBlur` 控制。

页面通信遵循同一套习惯：

- **页面 → AHK**：`postMessage` 一个 JSON 字符串，外层一定有 `type` 字段；AHK 侧统一用
  `LLMMessageParse` / `LLMMsgField(msg, "type")` 解析与取字段（避免直接手撕 JSON）。
- **AHK → 页面**：由 `PanelHostExecute()` 统一调用 `ExecuteScriptAsync("window.fn(" . JSON.stringify(payload, 0) . ")")`。
- **页面数据**：在 `pages/*.html` 里声明 `window` 级函数（如 `window.setResults`、
  `window.setEntry`），AHK 用字符串调用。

面板实例的骨架（创建 GUI → `PanelHostEnsure()` → 导航回调置 `pageReady` →
`PanelHostShow/Hide()`）在 `panelHost.ahk` 集中实现，功能模块只处理各自职责：

- **qbar**：`qbar_panel.ahk` 负责窗口和通信，`qbar_index.ahk` 负责索引与行图标；`QbarExec` 调用公共宿主，行图标经 `icons.ahk` 从 shell 提取后
  以 data URI 推给页面并按扩展名/路径缓存。`QbarShow` 每次把窗口重置到收拢高度，页面需配合
  `window.resetRows` 让下一次渲染重报行数（否则隐藏期间残留的 `reportedRows` 会让窗口
  保持收拢、列表只剩半行）。
- **translate**：`LLMTranslateStartRequest` 是唯一调度点——先由 `TranslateResolveDirection` 确定原语言、目标语言和
  请求代号，再按 `TranslateResolve` 的结果把请求分给流式引擎（onDelta 逐片段追加）或一次性引擎（完成后整段 `SetResult`）。
  过期请求的流式片段和完成回调会被丢弃；互译面板的交换按钮只改变当前请求方向，不写入配置。
- **dictionary**：查询走 `CSQLite` 的只读连接；搜索联想三段式（前缀→包含→模糊子序列，
  词频排序）。词形、其余音标字段都是可点击的跳转查询；消息回调只记录查询序号，SQLite 工作在可取消队列中执行。
- **settings**：`settings.html` 是唯一活动设置界面；F12、托盘菜单、qbar `cl set` 和功能页设置按钮都路由到它。

设置写入经过 `config.ahk` 的 schema 与字段 codec；提示词和 Tab 替换在 INI 边界使用单行编码，运行时只暴露逻辑文本。页面只发送相对基线的变更，只有有效变化才触发对应运行时应用；外部修改与未保存草稿冲突时保留草稿并提示用户。

qbar 的 `es.exe` 和内置 Everything 由程序资源目录定位，设置页只允许调整结果数量；QSearch/QRun/QWeb 使用 generation 缓存，配置或语言变化时统一失效。Everything 客户端查询使用带期限、序号和临时 CSV 的可取消作业，退出时只回收 qbar 自己启动的客户端或本会话拉起的内置实例。

## 屏幕自适应与 DPI

- AHK v2 默认 PerMonitorV2 DPI 感知，`Gui.DPIScale := true` 是默认值，因此 `Gui.Show("w960")`
  是逻辑像素，窗口变化时由系统自动按 DPI 重标。`A_ScreenDPI` / `A_ScreenWidth` 只有主屏的
  物理像素值。
- `ScreenFitSize(width, height, minWidth, minHeight)`（`core.ahk`）以 1920×1080 为基准：
  `scale = Min(screenW/1920, screenH/1080)`，尺寸按 scale 伸缩并夹在 `[min, 90%/85% 工作区]`
  之间。做法是让逻辑尺寸随屏幕物理分辨率缩，Windows 缩放在此之上再整体放大一次，两者互不干扰。
- `FixDpi()`（`core.ahk`）是 `Ceil(value / 96 * A_ScreenDPI)`，仅用于手动换算物理像素的场景
  （qbar 的 WebView2 controller bounds 需要它，因为 controller 用物理坐标定位）。

## 剪贴板、选区与独立剪贴板

- `ClipboardAll()` 快照 + 恢复是唯一可靠的选择文本读取方式；`ClipboardWatcherSuspended`
  在读取期间挂起独立剪贴板监听，防止把自己读到的内容当成用户的复制行为。
- `GetSelectedText(mode)` 三种模式继承自参考实现的「整行复制」规则：
  - `strict`：以换行结尾则视为「在 IDE 复制了整行」，丢弃（原版行为，编辑器无选中时会取到当前行）；
  - `multiline`：有内部换行（≥2 个）则保留——翻译面板用它，让多段文本能进翻译；
  - `any`：无条件保留并去掉末尾换行——qbar 用它，让任何选中都能预填到输入框。
  代价是：在完整选中当前行的编辑器里，qbar 会把当前行预填进去（可见、可编辑）。
- 独立剪贴板在 `[Global] allowClipboard` 开关下于系统之外维护 3 组槽位，复制/剪切/粘贴键
  跟随 `allowClipboard` 与 `keyFunc_switchClipboard` 选择的「粘贴来源」。

## 与原版 capslock-plus 的主要差异

- **AHK v2 重写**，qbar / 翻译从原生 ListView+Gui 换成 **WebView2** 面板。
- qbar 列表用 **↑/↓** 导航（v1 是 CapsLock+E/D，因为 qbar 打开期间键层挂起，直接打字进输入框）。
- qbar 的文件/文件夹/程序行显示真实 shell 图标（HICON 经 GDI+ 转 PNG、以 data URI 推给页面
  并按扩展名/路径缓存）；面板暂不支持拖动。
- 热串匹配按**短键**（`gh<GitHub>` 按 `gh` 匹配），比 v1 的键名正则更宽容；未命中时
  CapsLock+Tab 不改动文本（v1 会原样重新粘贴）。项目当前不再提供行内计算器或 JavaScript 扩展运行时。
- 翻译引擎由 Lua/内建的有道换成 **provider 注册表**，支持 LLM / 有道 / 火山并可按需扩展。
- **未移植**：拼音搜索、`>cdo` 等旧命令；`cl` 系列内置命令以实际支持的为准。

## 开发约定与坑

约束（来自 `AGENTS.md`，必须遵守）：**不写测试、不启动运行脚本**；优先复用现有官方实现，
不重复造轮子；`capslock-plus/` 子目录只读参考，禁止修改。本轮仅按用户的明确授权删除了已确认
无活动引用的退役文件，后续删除仍需单独授权。

- **语法校验**：必须用 PowerShell 原生调用并等待退出码（Git Bash 的 MSYS 会把 `/validate`
  改写成 Unix 路径，且管道 `head` 会制造 exit 0 假阳性）：

  ```powershell
  $p = Start-Process "D:\utils\AutoHotkey\v2\AutoHotkey64.exe" -ArgumentList `
    '/ErrorStdOut','/validate','capslock_p2.ahk' -Wait -PassThru -RedirectStandardOutput out.txt
  $p.ExitCode   # 0 = 通过；2 = 语法错误（详情在 out.txt）
  ```

  注意 `/validate` 不输出 `#Warn` 警告，只有重载脚本才暴露。
- **命名**：`#Warn` 保持开启（仅关闭 `VarUnset`）；AHK v2 类名占用全局命名空间，局部变量不要
  与内置类名（如 `File`）或库类名（`Core`、`JSON` 等）同名。
- **翻译引擎扩展入口**：新建 `lib/features/translate/*Translate.ahk` → 实现 provider 契约 → 文件底部一行注册 →
  在中央设置页增加对应字段，完成扩展。
- **thqby `JSON.stringify` 只序列化 Map/Array/Object**：顶层 String（含 `""`）会抛
  “has no method named OwnProps”。传给页面的标量一律用 `LLMJsonQuote`（内部包一层数组后
  `SubStr(JSON.stringify([v],0),2,-1)`）。
- **WebView2 回调不要阻塞**：`WebMessageReceived` 里不要同步 `await2` 创建另一个 WebView2
  （15 秒超时）；需要时用 `SetTimer(fn, -1)` 延迟到回调外。启动期的长任务（如 qbar 的
  Everything 热索引）可能让页面回调 reentrant 地压在计时器回调之上，消息处理器要容忍
  非预期的字段类型（先判 `IsNumber` 再 `+ 0`）。
- **日志红线**：`DebugLog` 只记录事件、计数、状态码和耗时，绝不写用户输入、选区、剪贴板内容、
  API Key 或 endpoint 查询串（`capslock_p2.ini` 也可能含真实凭据，禁止进入安装包或文档）。
