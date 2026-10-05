# 架构说明

面向开发者与贡献者的代码地图。构建与发布流程见 [`packaging.md`](packaging.md)，用户使用说明见根目录 `README.md`。

## 顶层设计

- 入口 `capslock_p2.ahk` 用 `#include` 引入全部 `lib/*.ahk`；AHK v2 中每个被包含的文件加载时即执行，
  全局变量和函数在所有文件间共享。
- **键盘层**：按住 CapsLock 进入键层，`lib/input/keymap.ahk` 做键位方案与层调度，`lib/input/keys.ahk` 提供
  `keyFunc_*` 动作函数；`lib/input/appProfiles.ahk` 按前台 EXE 路径解析应用覆盖；
  `lib/input/customHotkeys.ahk` 注册不占用 CapsLock 层的全局和应用快捷键映射。
  **`keyFunc_*` 是面向用户的配置 API，不能按「有没有代码引用」判断死活**：键位是由 `[Keys]` 按函数名选择并交给
  `RunConfiguredAction()` 执行的，所以一个 `keyFunc_*` 在全部 AHK 源码和两个 ini 里都可能一次都不出现，却仍然
  是用户可绑定、README 明确指向的接口。同理，回调是以函数引用形式传递的（`OnExit(Shutdown)`），名字后面不带
  括号——用「函数名后面有没有 `(`」来找死代码会把它们全判成死的。
- **UI 面板全部是 WebView2**：`pages/*.html` 由 AHK 侧通过 `lib/shared/panelHost.ahk` 创建控制器并承载；临时面板的失焦隐藏共用 `PanelHostStartAutoHide()`，使用自定义标题栏的页面再共用 `windowBar.ahk` 的窗口样式切换、拖动、置顶和独立窗口抑制逻辑。
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
  clipboard/clipboard_store.ahk   安装目录下 SQLite 剪贴板历史数据库与事务
  clipboard/clipboard_formats.ahk ClipboardAll 白名单格式解析、校验与恢复
  clipboard/clipboard_history.ahk 历史采集队列、去重、收藏、容量和回放
  clipboard/clipboard_panel.ahk   剪贴板历史 WebView2 面板与消息协议
  windows.ahk                      窗口管理、winbind、热键注册
  keys.ahk / keymap.ahk            keyFunc_* 动作 / 键位方案与键层调度
  appProfiles.ahk                  EXE 路径应用配置、继承解析与持久化
  customHotkeys.ahk                [CustomHotkey] 全局和应用快捷键重映射
  panelHost.ahk                    WebView2 GUI、controller、导航、脚本执行、共用失焦隐藏与隐藏页延迟释放生命周期
  windowBar.ahk                    WebView2 自定义标题栏、普通窗口切换、拖动、置顶与失焦隐藏抑制
  icons.ahk                        shell 图标提取（HICON → GDI+ PNG → data URI）
  qbar.ahk                         qbar 状态与稳定入口
  qbar_panel.ahk                   qbar 面板生命周期、消息和尺寸
  qbar_index.ahk                   条目索引、过滤和图标行准备
  qbar_commands.ahk                命令、运行、网址和 AI 调度
  qbar_everything.ahk              Everything 共用后端、异步可取消作业、CSV 与 UTF-8 解析
  everything.ahk                   独立 Everything 页状态、分类查询、结果序号与序列化
  everything_panel.ahk             Everything WebView2 面板生命周期和消息协议
  everything_actions.ahk           打开、定位、文件剪贴板和路径复制
  qbar_navigation.ahk              文件夹导航和路径补全
  qbar_notes.ahk                   笔记页生命周期、编辑会话和页面协议
  qbar_notes_store.ahk             安装目录下 SQLite 正文/元数据存储
  qbar_notes_actions.ahk           原始图片文件、WebView2 文件句柄和笔记剪贴板动作
  translate.ahk                    翻译引擎注册表与共用翻译配置（provider 契约与调度解析）
  languageDetect.ahk               互译模式的本地原文语言识别与候选状态
  llm.ahk                           共用 LLM 配置、token 估算、请求体、同步/SSE 请求与响应解析
  llmTranslate.ahk                 翻译面板本体 + 翻译提示词 + 各引擎的调度编排
  youdaoTranslate.ahk              有道智云翻译 API（[TYoudao]，WinHttp + SHA-256 签名）
  volcengineTranslate.ahk          火山引擎翻译 API（[TVolcengine]，V4 签名、TextList 分批）
  crypto.ahk                       SHA-256 / HMAC-SHA-256 签名基元（BCrypt）
  dictionary.ahk                   本地词典卡片（ECDICT 词库只读查询与序号队列）
  aiChat.ahk                       AI 聊天面板、会话命令和流式请求生命周期
  aiChat_store.ahk                 AI 多会话 SQLite 存储（{app}\data\ai-chat\ai-chat.db）
  WebView2.ahk / ComVar.ahk / Promise.ahk   thqby ahk2_lib WebView2 绑定（保持官方原名）
  CSQLite.ahk / JSON.ahk           thqby ahk2_lib SQLite / JSON 官方库（保持原名）
pages\                             WebView2 面板页面
  qbar.html / qbar-notes.html / everything.html / translate.html / dictionary.html / chat.html / settings.html   WebView2 面板页面
  theme.css / icons.js / windowbar.js / dialog.js / toast.js 共享主题、图标、标题栏、对话框和 Toast
  notes-preview.js                   把 Vditor 渲染出的笔记正文拍平成可复制行并算行数预算
  vendor\                            Vditor（笔记页编辑器与预览渲染）、marked + DOMPurify（AI 回答）、图标、拼音
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

### AI 问答多会话

多会话设计与数据字段见 [`2026-10-05-ai-chat-multi-session-design.md`](2026-10-05-ai-chat-multi-session-design.md)。`aiChat_store.ahk` 独占会话数据库访问；`aiChat.ahk` 编排持久化轮次、主回答和首问标题请求；`chat.html` 负责会话侧栏和消息视图。数据库保存在 `{app}\data\ai-chat\ai-chat.db`，只在运行时创建。面板每次从隐藏状态重新打开时进入空白会话；历史按置顶状态、最后聊天时间倒序排列，支持切换、重命名、置顶、单条删除和多选删除。侧栏默认折叠，收起时保留新建对话和设置两个操作按钮。

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
  问答共用 `[LLM]`，问答的专用系统提示词保存在 `[QAI]`。系统提示词要求保留原文的换行与段落结构。
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
设置页、AI 页和 Everything 页是普通可调整大小的窗口；qbar、翻译、词典和 Everything 默认失焦隐藏。

页面通信遵循同一套习惯：

- **页面 → AHK**：`postMessage` 一个 JSON 字符串，外层一定有 `type` 字段；AHK 侧统一用
  `LLMMessageParse` / `LLMMsgField(msg, "type")` 解析与取字段（避免直接手撕 JSON）。
- **AHK → 页面**：现有页面通常由 `PanelHostExecute()` 调用页面函数；笔记页的普通状态改用 WebView2 JSON 消息，需要传递图片写入权限时使用 `PostWebMessageAsJsonWithAdditionalObjects` 附带单文件句柄。
- **页面数据**：在 `pages/*.html` 里声明 `window` 级函数（如 `window.setResults`、
  `window.setEntry`），AHK 用字符串调用。

### 页面 Toast 通知

- 所有 `pages/*.html` 页面共用 `pages/toast.js` 的 `window.AppToast`，页面通过
  `AppToast.show(message, type, duration)` 显示通知，`AppToast.hide()` 主动关闭；类型为
  `success`、`info`、`warning`、`error`，默认类型是 `info`，默认显示 4200 毫秒。
- DOM 由共享脚本创建，外观和颜色由 `pages/theme.css` 统一管理，并沿用主题的明暗色变量。
  指针悬停或 Toast 获得键盘焦点时暂停关闭计时；鼠标移出或焦点离开后继续计时，也可用关闭按钮立即收起。
- 设置页的 `showToast()` 与笔记页的 `toast()` 是页面业务层薄封装，分别用于设置操作反馈和笔记操作反馈，
  实际显示都委托给 `AppToast`。
- 新页面应加载 `theme.css` 和 `toast.js`，直接复用 `AppToast`，不要另写 Toast 标记、计时器或局部配色。
  安装清单在 `tools/capslock_p2.iss` 中显式包含 `toast.js`。
- `lib/app/core.ahk` 的 `ShowMsg()` 是不依赖 WebView 页面的 AHK 原生 `ToolTip`，用于全局快捷键和宿主错误反馈；
  它与页面 Toast 属于不同通知路径。

### 统一弹窗

- 所有 WebView2 页面弹窗统一由 `pages/dialog.js` 的 `AppDialog` 服务创建。简单交互使用 `AppDialog.alert/confirm/prompt`，复杂弹窗使用 `AppDialog.open(options)`；窗口外框、标题栏、关闭按钮、遮罩、按钮区、焦点行为及忙碌/错误状态由共享服务负责，外观和主题变量集中在 `pages/theme.css`。
- 复杂弹窗通过 `render(root, api)` 提供页面正文，通过 `actions` 声明操作按钮，通过 `onAction` 处理业务；`open()` 返回带 `result` Promise 的控制器，供宿主异步完成保存或选择。页面不得自行维护弹窗 DOM、Promise resolve、按钮监听和关闭清理状态。
- 页面只提供正文渲染和业务回调；允许通过 `className` 或 `size: "wide"` 添加语义尺寸修饰（修饰类及共用样式放在 `theme.css`），页面局部样式仅负责正文布局，不得重新实现独立弹窗外框、遮罩、按钮区或颜色主题。
- 统一弹窗负责关闭按钮、Esc 和点击遮罩的关闭行为，并通过 `onClose` 让页面清理业务状态；需要提交/取消的弹窗使用共享操作按钮，纯提示弹窗可隐藏按钮区。动态正文应使用文本节点写入，并为有说明的弹窗设置 `aria-describedby`。
- 页面不得调用浏览器原生 `alert()`、`confirm()` 或 `prompt()`；确认、文本输入等交互也必须用 `AppDialog` 实现，避免出现不受应用控制的浏览器弹框。
- 新增弹窗不得直接声明原生 `<dialog>` 或在页面自行调用 `showModal()`；应复用 `AppDialog`，以保证设置、选择器、确认和工具配置弹窗的交互与视觉一致。`<dialog>` 只能作为 `dialog.js` 的内部实现。使用 `AppDialog` 的页面须加载 `dialog.js`，安装清单 `tools/capslock_p2.iss` 也须包含该共享脚本。

面板实例的骨架（创建 GUI → `PanelHostEnsure()` → 导航回调置 `pageReady` →
`PanelHostShow/Hide()`）在 `panelHost.ahk` 集中实现，功能模块只处理各自职责：

- **qbar**：`qbar_panel.ahk` 负责窗口和通信，`qbar_index.ahk` 负责索引与行图标；`QbarExec` 调用公共宿主，行图标经 `icons.ahk` 从 shell 提取后
  以 data URI 推给页面并按扩展名/路径缓存。`QbarShow` 每次把窗口重置到收拢高度，页面需配合
  `window.resetRows` 让下一次渲染重报行数（否则隐藏期间残留的 `reportedRows` 会让窗口
   保持收拢、列表只剩半行）。
- **qbar notes**：`n`、`note`、`w`、`write` 由 qbar 延迟调度到独立窗口；顶部只保留搜索框和搜索按钮，页面主体是标签/预览两栏，新增使用右下角圆形悬浮按钮，卡片右键菜单提供复制、粘贴、修改、删除、多选和置顶；单击预览行复制、双击预览行粘贴，标题直接进入共用编辑态，保存或返回后回到列表。正文以 Markdown 明文存入 SQLite，图片以原始文件写入安装目录 `data\qbar-notes\media`，页面只获得专用虚拟主机 URL 和单文件写句柄。
  - **列表预览由页面渲染，AHK 不再解析 Markdown**。`NotesStoreList()` 每行只带 `markdown`（`content_md` 前 4000 字符）、`assets`（asset id → 媒体 URL，形状与编辑器用的 `NotesStoreAssets()` 一致）和 `revision`；页面用 `Vditor.md2html()` 渲染，再由 `pages/notes-preview.js` 遍历渲染结果拍平成可点击的行并算行数预算。**复制文本就是行自己的 `textContent`**，所以 `# 一级标题` 天然复制成 `一级标题`，不存在一套需要和渲染器保持同步的去语法规则。`NotesStoreAssetUrlIndex()` 一次批量查询解析图片 URL（不给每张图加一次查询），文件已丢失的资产不进映射，页面替换 `asset:` 引用时退回 alt 文本而不是破图。
  - **内容已变校验靠 `revision`，不再靠重新解析比对**。页面把收到的 `revision`（即 `updated_at`）随点击回传，`NotesStoreCopyRow()` 重读笔记比对，不一致就不复制。只用一个时间戳是刻意的：配上内容长度看着更严，但 SQLite 的 `length()` 数字符、AHK 的 `StrLen()` 数 UTF-16 码元，笔记里只要有 emoji 或增补平面汉字两边就会算出不同的值、复制直接失效；而同一秒内两次保存的窗口在实际流程里不存在（每次保存后列表都会重推、卡片重渲染）。
  - 图片行点击复制的是**图片本身**：`NotesStoreAssetFilePath()` 只认仍属于该笔记且在磁盘上存在的资产，`NotesSetClipboardImage()` 用 GDI+ 把它读成 HBITMAP 交给剪贴板（`A_Clipboard` 只能放文本），双击走同一条路再向目标窗口发送 Ctrl+V。
  - **Vditor 的按需资源必须走本地**：它把 lute 引擎、工具栏图标、i18n、内容主题都按 `${cdn}/dist/...` 动态加载，默认 cdn 指向 jsDelivr。页面用 `VEDITOR_CDN = '../vendor/vditor'` 指向内置副本；`vendor/vditor/dist/` 这个路径层级是它的硬要求，也因此 `.gitignore` 里的 `dist/` 必须锚定成 `/dist/`，否则整个 vendor 包会被静默忽略。
  - **笔记页会上报编辑器生命周期到调试日志**（`[Global] debug=1` 时）：页面发 `diagnostic` 消息，宿主写进 `capslock_p2-debug.log`。阶段有 `page-load`（全局对象在不在）、`editor-missing`、`editor-mount`、`editor-ready`（含耗时和注入的 lute script 数量）、`preview-ok`（行数）、`upload-failed` / `preview-failed`。这是为了在 WebView2 里出问题时能**读日志**而不是靠截图描述。**内容一律不进日志**：只发类型名、计数、耗时和主题名；错误只发 name 和 message 的**长度**（不发 message，因为渲染器的报错可能把它解析不了的那段 Markdown 引出来）。
  - **`note_assets.relative_path` 只存相对路径**（`media\<文件>`）。启动时的 `NotesStoreCleanOrphans()` 拿它和 `media\` 里的真实文件名比对，对不上就删除文件，所以这个字段写成绝对路径等于每次启动清空整个图片目录。写入统一走 `NotesAssetStoredPath()`（同时兼容上传中的 `relativePath` 和已存资产的 `path` 两种键），`NotesStoreNormalizeAssetFiles()` 会在启动时把历史遗留的绝对路径修回相对形式。清理本身还有第二道保险：只要某篇笔记的 Markdown 里仍引用某个 asset id，对应文件就不会被删，即使路径字段再次写错也不会丢图。
  - **编辑器是 Vditor，默认 `wysiwyg` 模式**，页面不再自己维护 contenteditable。原先那套 `serializeNode()`（DOM→Markdown）、`execCommand` 工具栏、`insertImageNode()`、以及为 contenteditable 的 `<pre>` 打的一堆补丁（进入代码块后按回车出不来）都已删除。编辑器手上的文档就是 Markdown，所以存储格式没变：载入时把 `asset:<id>` 换成真实媒体 URL 好让图片显示，保存时用 `withAssetRefs()` 换回引用形式（用 `split/join` 而不是正则，URL 不需要转义）。图片上传仍走原来的 WebView2 桥（`assetStart` → 宿主回一个可写句柄 → 页面写盘 → 宿主回媒体 URL），`uploadFile()` 返回 Promise、由 `assetWriteResult` 结算，粘贴和拖入因此走同一条路。`pages/theme.css` 末尾把 Vditor 暴露的自定义属性（它在 `.vditor` 和 `.vditor--dark` 上各定义一套）映射到 `--ui-*`；选择器写成两层的 `.note-editor .vditor` 是因为 `theme.css` 先于 Vditor 的样式表加载，同优先级的规则会输。**代码块靠 `↓` / `→` 退出，不是回车**：`it()` 在光标位于最后一行（或内容末尾）时，于代码块之后插入 `<p data-block="0">` 并把光标放进去；`ot()` 对称地处理 `↑` / `←` / `Backspace`。回车在代码块内只换行。`Alt+Enter` 是把焦点移到语言输入框，`Escape` 收起预览。**`options.ctrlEnter` 现在指向 `saveEditor()`**：它是 Vditor 留给调用方的回调（`ctrlEnter(markdown)`），以前没设，所以 `Ctrl+Enter` 完全无绑定，README 曾经误称它用来退出代码块。现在设上是因为它确实到得了——`Ctrl+Enter` 在三个模式下都不会被各自的按键处理吃掉，每个 `"Enter"` 分支要么要求 `!(0,c.yl)(t)`（平台主修饰键，Windows 上是 Ctrl）要么要求 Alt / Shift。`Ctrl+S` 则没有官方钩子可用（整个包里 `⌘S`、`KeyS` 各出现 0 次），由页面自己在 document 捕获阶段拦下；那里的 `preventDefault()` 是必需的，WebView2 没有关掉 `AreBrowserAcceleratorKeysEnabled`，而浏览器加速键只在渲染进程不消费该按键时才执行，不拦就会走「保存网页」。两个快捷键都与右下角保存按钮等价。预览区的正文样式来自 Vditor 的 `dist/css/content-theme/*.css`，那是编译后的字面颜色、没有自定义属性，而且 **Vditor 是运行时动态加载它的，晚于 `index.css`** —— 两者都设了同一属性时内容主题会赢，这在 `ir` 模式下就看得见（深色内容主题直接给 `.vditor-ir__link` 上色，不只在预览窗里）。`pages/theme.css` 因此把这些选择器逐条原样重写并加上 `.note-editor` 前缀：多一个类就足以在每一种情况下胜出，而且重写的是 Vditor 自己的选择器文本，不会因为它的类名变化而静默失效。只覆盖本项目真正会渲染的界面，speech / abc / graphviz 保持原样（那些功能没有启用）。**工具栏只列不依赖额外资源的项**：`preview` / `export` 会生成一个独立文档去取 `${cdn}/dist/method.min.js`（未内置，只会 404），`emoji` / `record` / `code-theme` / `content-theme` 同理各自需要 emoji 图片、录音器、highlight.js 样式。**新增工具栏项前先确认它运行时取哪些文件**，并对照 `vendor/vditor/dist/` 是否已内置。分屏预览不受影响：`edit-mode` 切到 `sv` 就在页内渲染，用的是已内置的内容主题。
  - **必须显式传 `customWysiwygToolbar`**（页面传空回调）。Vditor 3.11.2 在 wysiwyg 浮层路径上无条件调用它（`ve()` 的实现就是 `e.options.customWysiwygToolbar(t, e.wysiwyg.popover)`），但**没有给它默认值**：这个名字在 `dist/index.min.js` 里只出现 1 次（就在那个调用点），默认选项对象里也没有。于是这个调用抛异常，紧跟在它后面的 `le()`（负责定位浮层并把 `display` 设成 `block`）不执行，**浮层被建好却永远不可见**。表格行列面板、引用、列表项、链接引用、脚注浮层全部走这条路径，因此全受影响。**升级 Vditor 时要复查这一点是否已修。**
  - **浮动面板只在 wysiwyg 模式有**，这不是缺陷而是两种模式的分工：`ir`（即时渲染）走「显示源码」路线，靠一整套 `vditor-ir__marker--*`（heading / pre / bracket / paren / link / bi / title / info）在光标所在块显形供直接编辑，包里 `ir.popover` 出现 **0 次**；`wysiwyg` 走「显示面板」路线，没有任何源码 marker 类，改用 `popover` 提供块操作（它只有块类型徽标，如 `.vditor-wysiwyg__block:before { content: "</>" }`、`H1`–`H6`、`$$`、`"A"`、`^F`）。`sv` 的左侧是纯 Markdown 文本域。代码里的分叉在 `ge()`：按 `currentMode` 分别调 `se()`（wysiwyg，含浮层逻辑）或 `Q()`（ir/sv，只启停工具栏按钮）。
  - **具体到表格，`ir` 模式能改内容但不能改结构**：表格在 `ir` 下是真实的 `<table>`（点进单元格即可改文字，保存时 Markdown 由 `SpinVditorIRDOM` 从 DOM 重新生成），单元格之间还能用 Tab / Shift+Tab 和方向键穿行（`Et()` 实现了这套导航）。但**增删行列在 `ir` 下没有任何入口**：Tab 走到最后一格就停住（代码里算出的下一个单元格是 `null` 就什么都不做），Enter 是在单元格内插 `<br>`，而且表格享受不到 `ir` 的源码标记机制（lute 里 `vditor-ir__marker--table` 出现 0 次，`vditor-ir__node` 的 `data-type` 只有 `code-block` / `yaml-front-matter` / `math-block`）。**这是 Vditor 相对 Typora 的真实落差**——Typora 的实时预览模式给表格带操作栏。**正因如此，本项目的编辑器默认用 `wysiwyg`，并且把 `ir` 从「编辑模式」菜单里去掉了**（页面在 `after()` 里删掉 `[data-mode="ir"]` 那个按钮；菜单是工具栏构建时写死的三按钮列表，没有可配置项，包里也没有 `setMode` 这类 API。菜单上印的 `⌥⌘7/8/9` 是**真的**，不是装饰：Vditor 的按键处理器用 `/^Digit[7-9]$/` 匹配 `event.code` 来切 wysiwyg / ir / sv（它没有用 `q()` 去匹配那几个印出来的字符串，所以那几个字符串本身在包里只出现在那段 HTML 里，容易看漏）。因此光摘掉 `ir` 按钮并不足以让 `ir` 不可达，页面另在捕获阶段吞掉了 `Ctrl+Alt+8` 这一个组合，保留 `Alt+Ctrl+7` 和 `Alt+Ctrl+9`。删中间那个是安全的——`_bindEvent` 在构建时按索引把点击处理器绑在按钮元素上，剩下两个各自保留原有行为）。现在可切换的只有 `sv`（左源码右预览），要用源码手感时用它。
- **translate**：`LLMTranslateStartRequest` 是唯一调度点——先由 `TranslateResolveDirection` 确定原语言、目标语言和
  请求代号，再按 `TranslateResolve` 的结果把请求分给流式引擎（onDelta 逐片段追加）或一次性引擎（完成后整段 `SetResult`）。
  过期请求的流式片段和完成回调会被丢弃；互译面板的交换按钮只改变当前请求方向，不写入配置。
- **dictionary**：查询走 `CSQLite` 的只读连接；搜索联想三段式（前缀→包含→模糊子序列，
  词频排序）。词形、其余音标字段都是可点击的跳转查询；消息回调只记录查询序号，SQLite 工作在可取消队列中执行。
- **settings**：`settings.html` 是唯一活动设置界面；F12、托盘菜单、qbar `cl set` 和功能页设置按钮都路由到它。

设置写入经过 `config.ahk` 的 schema 与字段 codec；提示词和 Tab 替换在 INI 边界使用单行编码，运行时只暴露逻辑文本。页面只发送相对基线的变更，只有有效变化才触发对应运行时应用；外部修改与未保存草稿冲突时保留草稿并提示用户。

Everything 页的 `es.exe` 和内置 Everything 由程序资源目录定位，设置页只允许调整结果数量；Qbar 工具命令由 qbar.db 的插件注册表管理，配置变化通过 registry generation 失效旧候选。Qbar 的 `e`、`everything`、`find`、`f` 只负责打开独立页面并传入查询文本，Qbar 不再展示 Everything 结果。Everything 客户端查询使用带期限、序号和临时 CSV 的可取消作业，退出时只回收本会话拉起的客户端或内置实例。

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

- `ClipboardAll()` 快照 + 恢复是唯一可靠的选择文本读取方式；`ClipboardSuspendDepth` 与带
  reason 的 token 在读取期间挂起独立剪贴板监听，防止把自己读到的内容当成用户的复制行为；
  `ClipboardWatcherSuspended` 仅保留为管理器维护的兼容镜像。
- `GetSelectedText(mode)` 三种模式继承自参考实现的「整行复制」规则：
  - `strict`：以换行结尾则视为「在 IDE 复制了整行」，丢弃（原版行为，编辑器无选中时会取到当前行）；
  - `multiline`：有内部换行（≥2 个）则保留——翻译面板用它，让多段文本能进翻译；
  - `any`：无条件保留并去掉末尾换行——qbar 用它，让任何选中都能预填到输入框。
  代价是：在完整选中当前行的编辑器里，qbar 会把当前行预填进去（可见、可编辑）。
- 独立剪贴板在 `[Global] allowClipboard` 开关下于系统之外维护 3 组槽位，复制/剪切/粘贴键
  跟随 `allowClipboard` 与 `keyFunc_switchClipboard` 选择的「粘贴来源」。
- 剪贴板历史由独立服务监听所有外部剪贴板变化，并将文本、图片、CF_HDROP 文件列表和常见
  HTML/RTF 格式的白名单数据写入 `{app}\data\clipboard-history\clipboard-history.db`。
  公共回调只登记序号；已有的槽位 `ClipboardAll()` 快照会被历史采集复用，内部临时写入由带
  reason 的嵌套挂起 token 排除。历史回放会同步系统槽位，不重新抓取一次全量剪贴板。

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

- **语法校验**：做法与那几个会造成假阳性的坑（`/ErrorStdOut` 不能省、要读 `$LASTEXITCODE` 而不是
  `Start-Process` 带重定向时的 `ExitCode`、不要在 Git Bash 里校验）统一记在 `AGENTS.md` 的
  「工具坑记录」里，这里不再抄一份，免得两处各自漂移。**`/validate` 会照常显示 `#Warn` 警告**，
  但警告不影响退出码，所以 `exit=0` 只说明没有错误；本项目是 MsgBox 模式，带警告的校验会弹一个
  模态对话框一直等在那里，想不被挡住就用 `AGENTS.md` 里那段 stdin + `#Warn All, StdOut` 的查法。
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
