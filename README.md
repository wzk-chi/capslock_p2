# capslock_p2

按住 **CapsLock**，整个键盘变成一层高效按键：光标移动、文本选择、删改编辑、窗口管理随手可及，
松开即恢复打字。另带 qbar 启动器、翻译/本地词典、AI 问答、独立剪贴板等工具。

本项目脱胎于 [Capslock+](https://github.com/capslox/capslock-plus)（AHK v1 原版，GPL v2），
用 **AutoHotkey v2 重写并加以改进**：UI 面板改用 WebView2、新增翻译引擎注册表（LLM / 有道 / 火山）、
Everything 文件搜索、屏幕自适应等。
开发者请翻阅 [`docs/architecture.md`](docs/architecture.md)。

## 功能总览

| 功能 | 入口 |
|---|---|
| CapsLock 键层（移动 / 选择 / 编辑 / 翻页 / 删行） | 按住 CapsLock + 字母区 |
| qbar 启动器（搜索、启动、文件搜索、路径浏览） | CapsLock+Q |
| 文本替换（热串） | CapsLock+Tab |
| 翻译面板（LLM / 有道 / 火山） | CapsLock+T 或 CapsLock+F3 |
| 本地词典卡片（选中英文单词） | CapsLock+T / F3，单词命中本地词库时自动展示 |
| AI 问答聊天（支持追问） | CapsLock+Q → `ai`/`q` 或任意未命中输入 |
| 独立剪贴板（3 组） | CapsLock+C/X/V、CapsLock+LAlt+C/X/V；切换键可自定义 |
| 窗口绑定（winbind） | CapsLock+数字、CapsLock+LAlt+数字 |
| 窗口半透明 / 置顶 | CapsLock+F4 / CapsLock+F6 |
| 鼠标速度临时调节 | CapsLock+LAlt+滚轮 |
| 媒体 / 音量控制 | 绑定 `keyFunc_media*` / `keyFunc_volume*` 使用 |

## 快速开始

**环境**：Windows 10 / 11，安装 [AutoHotkey v2](https://www.autohotkey.com/)（开发版本 2.0.13）
与 WebView2 Runtime（Windows 11 自带；Windows 10 需安装 Microsoft Edge WebView2 运行时）。
Everything 为可选（`resources/` 已内置一份，首次运行会自动建立 NTFS 索引）。

1. 双击 `capslock_p2.ahk`，托盘出现图标即已运行。
2. 开机自启：右键托盘菜单「开机自启动」切换；或编辑 `capslock_p2.ini` 的 `[Global] autostart=1`
   （保存后程序自动重读）。
3. 默认值在 `capslock_p2-default.ini`，用户修改写入 `capslock_p2.ini`，只有有效变化才触发对应运行时更新，无需重启。
   完整说明和示例见 `capslock_p2-settingsDemo.ini`（只读参考，程序不加载它）。

发布版是**单文件安装包** `capslock_p2-setup.exe`（也常按版本命名如 `capslock_p2-setup-0.1.1.exe`）。
运行后自动释放主程序、WebView2 页面、词典、SQLite、Everything 和配置模板，默认安装到
`%LocalAppData%\capslock_p2\`。安装向导允许改目录（推荐用户有写权限的位置，程序会在安装目录旁
保存配置、日志和窗口绑定记录）。**重新安装或升级会保留已有的 `capslock_p2.ini`**，API 配置不丢。
Everything 索引数据在 `%LocalAppData%\capslock_p2\Everything\`。构建与发布细节见
[`docs/packaging.md`](docs/packaging.md)。

### CapsLock 的两种用法

- **按住 CapsLock**：进入键层，字母键变成功能键（如 CapsLock+J/K/L/I = 左/下/右/上选择）。松开即恢复打字。
- **点按 CapsLock**：触发 `press_caps` 动作。默认 `keyFunc_toggleCapsLock`（切换大小写），
  示例配置改成了 `keyFunc_send(^{Space})`（发送 Ctrl+Space，常用于切换输入法）。

## 默认按键布局（capslox 方案）

完整布局见示例 ini 的 `[Keys]` 段，这里列出常用部分：

| 按键 | 功能 | 按键 | 功能 |
|---|---|---|---|
| CapsLock+S/F | ← / → | CapsLock+A/G | 按词 ← / → |
| CapsLock+E/D | ↑ / ↓ | CapsLock+P/; | Home / End |
| CapsLock+J/K/L/I | 选择 ←↓→↑ | CapsLock+H/N/M/O | 选词← / 选10行↓ / 选当前词 / 选到行尾 |
| CapsLock+W/R | 退格 / 删除 | CapsLock+Backspace | 删整行 |
| CapsLock+[ / ] | 删到行首 / （自定义） | CapsLock+/ | 删到行尾 |
| CapsLock+C/X/V | 复制 / 剪切 / 粘贴（剪贴板 1） | CapsLock+LAlt+C/X/V | 同上（剪贴板 2） |
| CapsLock+U | 选到行首 | CapsLock+空格 | 回车 |
| CapsLock+- / = | PgUp / PgDn | CapsLock+Enter | 回车 |
| CapsLock+Q | qbar 启动器 | CapsLock+T / F3 | 翻译 / 词典 |
| CapsLock+Tab | 热串替换 | CapsLock+F1 | 打开使用介绍 |
| CapsLock+F4 | 窗口透明切换 | CapsLock+F5 | 重载配置 |
| CapsLock+F6 | 窗口置顶切换 | CapsLock+1~0 | 激活绑定的窗口 1~10 |
| CapsLock+LAlt+1~0 | 单击/双击/三击绑定窗口、窗口组、应用 | CapsLock+LAlt+滚轮 | 调节鼠标速度 |
| CapsLock+F12 | 打开设置中心 |  |  |

所有键都可在 `[Keys]` 里改，值为 `keyFunc_` 开头的函数（可带参数，如
`keyFunc_moveDown(10)`），完整函数清单见 `lib/input/keys.ahk`。
全局自定义快捷键写在 `[CustomHotkey]` 中，格式为「触发键=发送键」，例如
`!c=^c` 表示按 `Alt+C` 发送 `Ctrl+C`；设置中心的快捷键页可以直接录制。
设置中心的快捷键页也支持点「录制」直接录入组合键，例如 Ctrl+Space 会保存为
`keyFunc_send(^{Space})`。

面板窗口（翻译 / 词典 / AI 问答）尺寸会随屏幕自动缩放，在你当前屏幕上不用手动调。

## CapsLock+Tab：文本替换（热串）

光标右侧无选中时作用于当前行，有选中时作用于选中文字。只做热串替换，未命中时不改变原文。

### 热串替换

```ini
[TabHotString]
clp=capslock-plus
addr=example@example.com
sig=——张三\n13800000000
```

输入 `clp` 按 CapsLock+Tab → 替换成 `capslock-plus`。

- 尾部匹配：光标左边的文字以键结尾即可命中，键前面的文字原样保留。
- 键的来源有三个段：`[TabHotString]`、`[QRun]`、`[QWeb]`（后两者按短键匹配，比如在编辑器里
  输 `gh` 也能展开成 GitHub 网址）。同名优先级：TabHotString > QRun > QWeb。
- `[TabHotString]` 的值支持两个转义（C 风格）：`\n` → 真实换行，`\\` → 一个 `\`
  （所以字面的 `\n` 写成 `\\n`）；其余反斜杠组合原样保留，路径如 `D:\docs` 无需转义。
  `[QRun]`/`[QWeb]` 的值原样展开，不做转义。

## qbar 启动器（CapsLock+Q）

弹出一个输入框面板，输入即过滤，↑/↓ 选择，回车执行，Esc 或点击面板外关闭。
选中文本唤出时会**自动预填到输入框**。文件、文件夹和程序行显示真实的 shell 图标
（与资源管理器一致）；搜索、网址等非文件行用类型字形。

### 条目类型与配置

ini 的**键名就是标签**，写成 `短键<显示名>`（`<显示名>` 可省略），值才是目标：

```ini
[QSearch]
bd<百度>=https://www.baidu.com/s?wd={q}

[QRun]
vsc<VS Code>=C:\Program Files\Microsoft VS Code\Code.exe
admincmd<管理员 CMD>=*RunAs "C:\Windows\System32\cmd.exe"

[QWeb]
gh<GitHub>=https://github.com
```

- **QSearch**（搜索）：值里含 `{q}`。输入 `bd 关键词` 回车，关键词经 URL 编码替换进 `{q}` 打开。
  段留空时有一组内置引擎：`s`（Bing/Google）、`bd`、`g`（别名 `gg`）、`bing`、`wk`、`m`（MDN，
  别名 `mdn`）；ini 里写了同名的就覆盖那个内置项。
- **QRun**（运行）：程序 / 文件 / 文件夹，支持 `*RunAs` 管理员前缀和参数。
- **QWeb**（网址）：缺 `http://` 时自动补全。
- 不带触发词直接回车：像路径就打开，像网址就开浏览器；只有带触发词才算搜索。

### 路径浏览

输入 `e:\` 或 `e:\abc\` 列出目录内容，继续输入继续过滤。补全按键：

- **Tab**：把高亮行补进输入框（目录浏览时只替换最后一段路径）；列表隐藏时按 Tab 恢复显示。
- **\ 或 /**：同上补全，且补出来是文件夹就再补一个 `\` 直接进入该目录；无可补全时按键原样输入。

### 文件搜索（Everything)

输入 `e 关键词` 回车即搜文件，别名 `e` / `everything` / `find` / `f`。**边输入边出结果**
（100ms 防抖），支持 Everything 原生查询语法：`*.pdf`、`ext:pdf`、`size:>100mb`、`dm:today`、
多关键词空格相与等。回车打开，**Ctrl+回车**在资源管理器中定位（对普通文件/文件夹行同样有效）。

后端自动选择：本机 Everything 在运行就直接用它；没在运行则自动启动 `resources/` 里的内置实例
（首次需要一次管理员确认建立 NTFS 索引，之后随程序启停）。二者都没有时给出提示。

可选配置（`[Qbar]`）：

```ini
[Qbar]
; esMaxResults=50    最多返回条数
```

`es.exe`、内置 Everything 和实例名由安装包资源策略管理，设置中心不提供路径覆盖；旧配置中的路径字段不再生效。配置层会为提示词和 Tab 替换处理单行 INI 存储编码，日志不写入 API Key、请求正文、剪贴板或用户输入。

### 内置命令

| 输入 | 作用 |
|---|---|
| `ai` / `q` | 打开空白 AI 聊天面板；追加问题可直接提问（使用共用 `[LLM]` 配置） |
| `cl set` | 打开设置中心 |
| `cl version` / `cl about` | 显示版本号 |
| `web 网址` | 强制按网址打开，缺 `http://` 时自动补 |
| `*RunAs 触发词 参数` | 以管理员身份执行 QRun 条目 |

**AI 问答默认在第一行**：只要输入不是显式命令（没有精确命中触发词），qbar 列表第一行就是
「🤖 AI 问答」——回车即打开 AI 聊天，部分匹配的条目排在其后（↓ 选择）。

### 行内添加条目

不用手动编辑文件，在 qbar 里按格式输入并回车，弹确认框确认后写入 ini：

```
短键 ->类型 值
```

类型：`run` / `path` / `file` / `folder` / `ftp` → `[QRun]`；`web` / `qweb` → `[QWeb]`；
`search` / `qsearch` → `[QSearch]`；`str` / `string` / `hotstring` → `[TabHotString]`。
`->` 后留空则按值的形态自动判断（带 `{q}` 的网址 → QSearch，可识别路径 → QRun，
网址 → QWeb，其余 → TabHotString）。

```
vsc ->run C:\Program Files\Microsoft VS Code\Code.exe
gh ->web https://github.com
bd ->search https://www.baidu.com/s?wd={q}
clp ->str capslock-plus
```

## 翻译与本地词典（CapsLock+T / CapsLock+F3）

选中文字后按 CapsLock+T 弹出 **翻译面板**（WebView2）。面板优先使用 **LLM**（OpenAI 兼容
chat completions 接口，流式显示）；未配置 LLM 时自动改用已配置的其他引擎——**有道智云**
或**火山引擎**（均一次性返回，有道附带词典释义）。全部未配置时弹出设置窗口引导填写。
**多段文本会保留原文的换行结构**：LLM 按提示词要求保持原文分段；有道按行翻译（换行原样
提交、结果按行拼回）；火山把每行作为独立 TextList 条目翻译后按序拼回。

各引擎配置：

```ini
[LLM]                      ; 翻译与 AI 问答共用的 LLM API
endpoint=https://api.openai.com/v1/chat/completions
apiKey=sk-xxx
apiKeyHeader=Authorization
apiKeyPrefix=Bearer
model=deepseek-flash
thinking=0
temperature=0.2
timeout=30000
maxInputTokens=200000  翻译与 AI 共用的输入 token 估算上限

[LLMTranslate]             ; LLM 翻译专用提示词
systemPrompt=You are a precise translation engine. Translate the user's message into {{targetLanguage}}. Preserve meaning, tone, formatting, names and code. Keep the source text's line breaks and paragraph structure. Return only the translation, nothing else.

[TTranslate]               ; 所有翻译引擎共用配置
mode=fixed                 ; fixed 固定目标 / bidirectional 两种语言互译
languageA=zh-CN            ; 互译模式的第一种语言
languageB=en               ; 互译模式的第二种语言
targetLanguage=system      ; fixed 模式目标：跟随系统语言，也可选 zh-CN / zh-TW / en / ja / ko 等代码
engine=auto                ; auto（默认，优先 LLM，未配置时按已配置引擎回退）/ llm / youdao / volcengine

[TYoudao]                  ; 有道智云收费版翻译 API
appPaidID=
appPaidKey=

[TVolcengine]              ; 火山引擎机器翻译 API
accessKey=
secretKey=
region=cn-north-1
```

系统提示词支持简单模板变量：翻译中的 `{{targetLanguage}}` 会替换为翻译目标语言，AI 问答中的
`{{uiLanguage}}` 会替换为当前界面语言。未识别的变量会原样保留，便于发现拼写错误。
翻译设置支持固定目标和两种语言互译。固定模式在设置页选择一个目标语言；互译模式在设置页选择语言 A/B，
翻译面板再选择“原语言”和“目标语言”，点击交换按钮可交换当前方向。语言选项以各自语言的文字显示，
配置中保存为语言代码；自动识别不确定时需要在面板中手动选择方向。

设置中心分为「LLM」「翻译」「AI 问答」三个区域。LLM 区域只配置一套共用的 API、模型和采样参数；
翻译区域配置共用的翻译引擎、翻译方式和语言，以及有道和火山各自的 API 凭据；AI 问答区域只配置问答专用系统提示词。
有道应用在
<https://ai.youdao.com/console/#/> 申请（新账号有试用额度）；火山翻译在
<https://console.volcengine.com/translate> 开通。

### 本地词典卡片

用 CapsLock+T 触发翻译时，如果选中的是**单个英文单词**且存在于本地词库
`resources\dictionary.db`（ECDICT 格式，约 4.9 万高频词及其常见词形），弹出的不是翻译面板，
而是**词典卡片**：

- 展示词库里的全部字段：音标、柯林斯星级、牛津3000、考试标签（中考/高考/四六级/考研/托福/雅思/GRE）、
  词性分布、BNC / 当代语料库词频、中文释义、英文释义
- 词形变化（过去式 / 复数 / 比较级…）是可点击的词条，直接查该词；顶栏搜索框可继续查别的词，
  输入即联想：**前缀 → 包含 → 模糊**（子序列，`helo` → `hello`）三级匹配、按词频排序，
  ↑/↓ 选择、回车或点击查词，Esc 关闭联想
- 🔊 按钮本地发音（Windows 语音）
- 词库没有的词、多词选择或句子照旧走翻译面板

## AI 问答聊天（ai / q）

qbar 里输入「ai」或「q」可打开空白聊天面板；输入「ai 问题」「q 问题」，或输入未命中任何命令的内容回车，打开独立的
**AI 聊天面板**：气泡式对话，支持**追问**（最多保留最近 50 轮，即 100 条消息；更早内容自动遗忘），
「新会话」按钮清空重来。回答通过 OpenAI 兼容接口流式返回，模型自行判断输入是要回答的问题还是要解释的文本。
AI 窗口是普通可调整大小、可最小化和最大化的 WebView2 窗口；设置中心的「失焦后隐藏」默认开启，关闭后窗口会像设置页一样保留。
聊天或翻译面板处于活动窗口时 CapsLock 键层自动挂起（打大写字母不会误触图层动作）。
未配置 `[LLM]` API 时自动弹出设置窗口，保存后自动发出等待中的问题。

**上下文超限的处理**：发送前按「最近 50 轮 + 输入 token 估算上限」（`maxInputTokens`，默认 200000）
双重裁剪——超出预算的最旧轮次自动丢弃，单条超长消息只送尾部；翻译文本也使用同一上限，保证请求
不会被模型上下文上限整体拒绝；服务端仍报上下文超限时，错误提示会附带处理建议（缩短内容或新建会话）。

托盘「设置」打开设置中心，翻译和 AI 面板内也共用同一套 API 配置。翻译和 AI 问答都使用 `[LLM]` 中的同一套 API、模型和采样配置；
翻译共用的方式、语言和引擎选择保存在 `[TTranslate]`，LLM 翻译提示词保存在 `[LLMTranslate]`，AI 问答只在 `[QAI]` 中保留专用系统提示词。输入 token 估算上限统一配置在 `[LLM]`：

```ini
[QAI]
hideOnBlur=1
systemPrompt=You are the assistant built into the capslock_p2 launcher. The user's message is either a question to answer or a text to explain; decide which one it is. If it is a question, answer it directly and completely. If it is a text (a word, sentence, paragraph, error message, log entry, code snippet or URL), explain what it means. Reply in the language of the user's message; if the message is not in Chinese or English, reply in {{uiLanguage}}. Be concise.
```

## 独立剪贴板

系统剪贴板之外另有两组独立槽位，复制粘贴互不覆盖：

- CapsLock+C / X / V：剪贴板 1 的复制 / 剪切 / 粘贴
- CapsLock+LAlt+C / X / V：剪贴板 2
- 可将任意键绑定为 `keyFunc_switchClipboard`，循环切换「粘贴来源」槽位（系统 / 1 / 2）
- `[Global] allowClipboard=0` 可整体关闭（独立剪贴板失效，回到系统行为）

## 窗口功能

- **winbind**：CapsLock+数字激活对应编号的窗口；设置中心支持「窗口」「窗口组」「应用」三种模式。
  - **窗口**：绑定一个选定窗口；窗口重启后会按程序信息尝试找回，找不到时尝试启动原路径。
  - **窗口组**：手动添加已打开窗口；CapsLock+数字按保存顺序循环切换，当前窗口不在组内时回到第一个窗口。
  - **应用**：选择已打开应用或其他应用，自动维护该应用的全部窗口；应用未运行时会尝试启动。
  - 默认 CapsLock+LAlt+数字在 500ms 内单击、双击、三击，分别绑定窗口、窗口组、应用。
  绑定关系保存在 `capslock_p2-winsInfosRecorder.ini`。
- **CapsLock+F4**：窗口透明度循环切换；**CapsLock+F6**：置顶切换。
- **CapsLock+LAlt+鼠标滚轮**：临时调鼠标速度（`[Global] mouseSpeed` 为默认值，1~20），松开后恢复。

## 配置说明

- 配置文件分为三份：`capslock_p2-default.ini` 是完整默认配置，`capslock_p2-settingsDemo.ini` 是带详细说明的参考示例，`capslock_p2.ini` 是用户覆盖配置。程序先加载 default，再用用户配置覆盖；默认值不会写回用户文件。
- 用户配置文件：**`capslock_p2.ini`**（UTF-8）。只需写需要修改的项目；保存后 0.5 秒内自动重读，只有实际变化才应用；CapsLock+F5 可手动重载。外部修改与设置页未保存草稿冲突时，页面会提示重新载入。
- 设置中心入口：CapsLock+F12、托盘菜单「设置」、qbar 命令 `cl set`；翻译和 AI 面板中的设置按钮会直接打开对应的设置页。
- 段：`Global`、`TabHotString`、`Keys`、`CustomHotkey`、`LLM`、`LLMTranslate`、`TTranslate`、`TYoudao`、`TVolcengine`、`QAI`、`Qbar`、`QSearch`、`QRun`、`QWeb`。
- `[Global]` 常用项：

  | 键 | 默认 | 说明 |
  |---|---|---|
  | `autostart` | 0 | 开机启动：也可从托盘菜单切换；启用/关闭会同步当前用户启动文件夹的快捷方式 |
  | `debug` | 0 | 1 时写 `capslock_p2-debug.log`（不记录剪贴板内容和 API Key） |
  | `mouseSpeed` | 3 | CapsLock+LAlt+滚轮的基准速度 |
  | `allowClipboard` | 1 | 独立剪贴板开关 |
  | `loadingAnimation` | 1 | 启动动画：也可从托盘菜单切换；默认显示现代简约启动卡片 |
  | `language` | 1 | 界面语言：0 自动（Windows 显示语言），1 简体中文，2 英文；翻译/词典/AI 面板及设置界面跟随此设置，与翻译目标语言无关 |
  | `runAsAdmin` | 1 | 以管理员身份运行：1 开启，0 关闭；修改后重启程序生效，启动时会弹出 UAC |

## 调试

`[Global] debug=1` 后，根目录生成 `capslock_p2-debug.log`，记录设置加载、热键注册、qbar 请求、
翻译请求等关键链路的事件、计数、状态码和耗时（**不含用户输入、选区、剪贴板内容、API Key 或 endpoint 查询串**）。遇到行为不符时先看日志。

## 开发者

- 代码地图、翻译引擎注册表、屏幕/DPI 自适应等架构说明见 [`docs/architecture.md`](docs/architecture.md)。
- 构建与发布流程见 [`docs/packaging.md`](docs/packaging.md)。
