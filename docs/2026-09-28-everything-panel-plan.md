# Everything 独立搜索页面实施计划

日期：2026-09-28。状态：实施中；核心代码与页面已落地，待允许运行后的交互验证。

## 1. 已确认的目标与边界

- QBar 的 `e`、`everything`、`find`、`f` 是完全等价的独立 Everything 页启动入口。在 QBar 输入时不再查询文件，按 Enter 或点击入口才打开页面。
- `<别名> 关键词`（别名可以是 `e`、`everything`、`find` 或 `f`）打开页面、填入关键词并立即搜索；四个别名都保留 Everything 原生搜索表达式，不能只在 `e` 分支实现。
- 窗口参考 AI 问答页：原生标题栏、可拖动、可调整大小、可最小化和最大化；进入时激活搜索输入框。
- 失去焦点后自动隐藏，重新通过四个别名打开时复用窗口、文本、分类和尺寸状态。窗口不默认置顶。
- 不区分截图中的本地搜索与全盘搜索。
- 左侧分类固定为：全部、文件夹、EXCEL、WORD、PPT、PDF、图片、视频、音频、压缩文件。
- 文件结果右键菜单固定为：文件夹中显示、复制、复制路径、复制所在路径。
- 页面遵循 pages/theme.css 的统一主题与深浅色规则。截图用于布局参考。
- 本期不增加预览、删除、重命名、拖放、多选或独立快捷键。结果区增加名称、路径、大小和修改时间的升降序排序菜单，默认按修改时间降序。

## 2. 当前代码依据

| 位置 | 现状 | 实施影响 |
| --- | --- | --- |
| lib/features/qbar/qbar_index.ahk | QbarConfigIndex 创建 Everything 入口；QbarQuery 对 e/everything/find/f 参数实时发起查询 | 入口改成打开页面；四个别名在输入时都只生成启动项 |
| lib/features/qbar/qbar_commands.ahk | search 类型入口默认补全；存在 AI 页启动方式 | 必须覆盖四个别名的裸命令和带参数路径，防止先补全或被选中项覆盖参数 |
| lib/features/qbar/qbar_everything.ahk | Everything 页共用的 CLI 查询、实例探测、CSV、超时和取消 | 后端状态只由独立 Everything 页路由，保留一套异步机制 |
| lib/features/qbar/qbar.ahk、qbar_panel.ahk | 保存搜索状态；隐藏 QBar 取消搜索；退出时结束自有内置实例 | 搜索生命周期移交 Everything 功能 |
| lib/features/aiChat.ahk | 原生窗口、单实例复用、会话内保留尺寸位置；失焦隐藏可配置 | 复用窗口模式，不照搬其失焦隐藏默认值 |
| lib/shared/panelHost.ahk | 统一 WebView2 创建、显示、执行消息和销毁 | 新页面继续通过该宿主创建 |
| lib/features/qbar/icons.ahk | IconCache 缓存图标；IconSent 记录给 QBar 发过的图标 | 可共享图标数据，发送记录必须每个页面独立 |
| lib/app/config.ahk | Qbar.esMaxResults 默认 50，范围 1–500 | 本期保留此配置键，避免无关配置迁移 |
| tools/capslock_p2.iss | pages/*.html 通配收录、theme.css 单独收录 | 新 HTML 已被覆盖，不为此重新打包 |

本次重新查看工作区时，已有改动为 AGENTS.md、README.md、capslock_p2-default.ini、capslock_p2-settingsDemo.ini、lib/features/dictionary.ahk、pages/dictionary.html。实施前再次查看状态与相关 diff，以实际内容为准，保留已有修改。当前没有在资源目录找到 es.exe 的文本说明，新增 CLI 开关不得凭空假定受内置版本支持。

## 3. 页面与交互设计

### 3.1 页面结构

```text
┌ 原生标题栏：capslock_p2 Everything ── 最小化 / 最大化 / 关闭 ┐
│ 搜索输入框：支持 Everything 语法                  [搜索]    │
├──────────┬────────────────────────────────────────────────┤
│ 全部     │ 图标  文件名                                   │
│ 文件夹   │       所在目录                                │
│ EXCEL    │                                                │
│ WORD     │ 图标  文件名                                   │
│ PPT      │       所在目录                                │
│ PDF      │                                                │
│ 图片     │                                                │
│ 视频     │                                                │
│ 音频     │                                                │
│ 压缩文件 │                                                │
├──────────┴────────────────────────────────────────────────┤
│ 搜索中 / 错误 / 当前分类                已显示 N 项         │
└───────────────────────────────────────────────────────────┘
```

- 初始逻辑尺寸建议 960×680，最小尺寸 640×440；通过 ScreenFitSize 适配可用屏幕和 DPI，并核对 MinSize 不与小屏可用区域冲突。
- 搜索栏和底部状态栏固定；分类栏约 112px，结果区占剩余空间。两个列表均允许独立纵向滚动，底栏不被挤出窗口。
- 行高约 56px，图标 24–28px。名称、父目录分两行，长路径省略，悬停显示完整路径。
- 首版结果字段包含名称、路径、类型、图标、大小和修改时间；大小和修改时间由 AHK 随返回结果读取，用于当前结果集排序。
- 字体、文字、背景、选中态、边框、圆角、阴影和焦点样式沿用现有主题。可复用的菜单/列表状态样式放 theme.css，并限定组件类名，避免影响 QBar 几何尺寸。
- 界面文案跟随现有中英文设置；分类标识使用稳定英文 ID，不能依靠显示文字判断过滤类型。

### 3.2 打开与恢复

| 场景 | 明确行为 |
| --- | --- |
| 首次执行任一裸别名（e/everything/find/f） | 打开空输入框，分类“全部”，暂不查询，聚焦输入框 |
| 执行任一别名加文本 | 替换输入内容，分类重置为“全部”，立即查询，光标在文本末尾 |
| 已打开时再次执行任一别名加文本 | 复用同一窗口，更新文本并重新查询，不创建第二个窗口 |
| 再次执行任一裸别名 | 恢复当前会话的文本和分类；有搜索条件时刷新结果，文件名和分类都为空时不查询，聚焦并选中输入内容以便改搜 |
| 窗口已最小化 | 恢复并激活；正常显示时不重设位置和尺寸 |
| 失去焦点 | 自动隐藏并取消当前查询；重新打开时保留文本、分类和窗口尺寸 |
| 点击原生关闭按钮 | 隐藏窗口并取消当前搜索，保留会话内文本、分类和窗口尺寸 |
| 退出主程序 | 取消作业、关闭句柄、销毁面板，仅结束本程序启动的内置 Everything 实例 |

打开流程：先保存 pendingOpen 内容和递增打开序号，再显示/激活窗口。WebView 首次加载完成且页面 ready 后只消费一次 pendingOpen，按“同步语言与分类 → 填入文本 → 发起搜索 → 聚焦”执行。已有页面也走同一初始化入口，避免 navigation 和 ready 双重搜索。

宿主通过 PanelHostMoveFocus 配合页面 focusInput 完成焦点交接；页面准备好后再聚焦。迟到的查询结果只更新列表，不能再次抢焦点。若加载期间用户已切到别的窗口，迟到的 ready 不重新激活整个窗口。

创建 WebView2 必须在页面回调之外执行，使用 SetTimer 和 Bind；不在回调内同步等待第二个 WebView2 的 await2。

### 3.3 搜索与键盘

- 输入变化由宿主统一做 100ms 防抖；中文输入法组字期间不提交，compositionend 后提交最终内容。
- 点击“搜索”或在输入框按 Enter，取消防抖并立即执行当前条件；输入框中的 Enter 不意外打开第一条文件。
- 单击结果选中，双击结果打开；列表获得焦点后 Enter 打开选中项，Ctrl+Enter 在文件夹中显示。
- ArrowDown 可从输入框进入结果列表；列表内上下键改变选中项并滚动到可见位置。Ctrl+L 返回并选中搜索框内容。
- 列表获得焦点时 Ctrl+C 复制文件；输入框里的 Ctrl+C 保持文本复制行为。
- Esc 先关闭右键菜单，其次将列表焦点返回输入框；在输入框且没有菜单时隐藏页面。IME 组字时不截获 Enter/Esc。
- 输入框保留正常的斜杠、反斜杠、Tab 焦点行为，不继承 QBar 的路径自动补全键处理。
- 打开文件或资源管理器、复制成功后，Everything 窗口继续保留。

## 4. 分类与原生语法的组合

分类为单选。点击后立即以当前输入重新查询，清除旧选中项与菜单。类型条件和用户的 Everything 表达式组合后一次交给 Everything 查询，查询最多请求结果上限加一项，页面最终只保留配置的结果数。

首版扩展名集合集中定义在 AHK 后端一处，页面只传分类 ID：

| ID / 显示文字 | 查询限制 |
| --- | --- |
| all / 全部 | 不增加限制，包含文件与文件夹 |
| folder / 文件夹 | folder: |
| excel / EXCEL | ext:xls;xlsx;xlsm;xlsb;xlt;xltx;xltm;csv;tsv |
| word / WORD | ext:doc;docx;docm;dot;dotx;dotm;rtf;odt |
| ppt / PPT | ext:ppt;pptx;pptm;pps;ppsx;ppsm;pot;potx;potm;odp |
| pdf / PDF | ext:pdf |
| image / 图片 | ext:jpg;jpeg;png;gif;bmp;webp;tif;tiff;svg;ico;heic;heif;avif |
| video / 视频 | ext:mp4;mkv;avi;mov;wmv;flv;webm;m4v;mpeg;mpg;ts;m2ts;3gp |
| audio / 音频 | ext:mp3;wav;flac;aac;m4a;ogg;opus;wma;ape;aiff;alac;mid;midi |
| archive / 压缩文件 | ext:zip;rar;7z;tar;gz;bz2;xz;tgz;zst;cab |

组合规则：

1. 保留用户表达式，不拆词、不自动加通配符，不将其解释为 shell 命令或任意 es.exe CLI 参数。
2. “全部”直接传原表达式。其他分类将非空表达式与分类条件用空格连接作 AND；空表达式直接使用分类条件。
3. 示例：输入 `成绩单` 并选图片，实际表达式为 `成绩单 ext:jpg;jpeg;png;gif;bmp;webp;tif;tiff;svg;ico;heic;heif;avif`。
4. 用户写了 ext:pdf 却选 WORD，结果是用户条件与 WORD 条件的交集，通常为零；不擅自覆盖用户表达式。
5. 路径引号、regex:、size:、dm:、逻辑运算均交给 Everything 解析；不做替代 Everything 的自制语法校验。
6. 开始编码查询构造器前，静态核对 Voidtools 官方搜索语法和内置 1.4 支持范围，尤其扩展名列表、regex、size: 比较符以及空查询。此核对不运行 es.exe。发现版本差异时修正映射与筛选规则。
7. Windows 参数转义继续复用现有 QbarEsQuoteArg 的实现逻辑。Everything 分组和 Windows argv 转义是两个步骤，不能相互替代。

当输入为空且分类为“全部”时不调用 Everything，清空旧结果并提示输入文件名或选择文件类型；选择了具体分类时，即使输入为空，也按该分类查询。

## 5. 右键菜单和操作语义

对文件和文件夹结果均可用；首版单选。右键先选中目标，再在鼠标处打开菜单；空白区不弹出文件菜单。支持菜单键和 Shift+F10，以选中行定位菜单；边缘自动避让。

| 菜单项 | 行为 |
| --- | --- |
| 文件夹中显示 | 在资源管理器中打开父目录并选中该文件/文件夹；磁盘根目录直接打开根目录 |
| 复制 | 将文件/文件夹以 Windows 文件剪贴板格式放入系统剪贴板，资源管理器 Ctrl+V 可复制实际文件 |
| 复制路径 | 写入该项完整路径的 Unicode 文本，不额外添加引号 |
| 复制所在路径 | 写入父目录完整路径的 Unicode 文本；选中的是文件夹时复制其父目录，根目录返回自身 |

- “文件夹中显示”优先采用 Windows Shell 官方 SHParseDisplayName / SHOpenFolderAndSelectItems，正确释放 PIDL；路径为根目录时单独处理。不直接调用会隐藏 QBar 的操作函数。
- 双击/Enter 通过宿主的明确文件打开函数交给 Windows 默认关联；可复用既有安全路径目标处理逻辑，不把文件名再次当 QBar 命令解析。
- “复制”使用官方 CF_HDROP / DROPFILES Unicode 文件列表；需要时附带 Preferred DropEffect=DROPEFFECT_COPY。不能用复制路径文本冒充复制文件。
- 文件剪贴板在申请和填写好全局内存后才 EmptyClipboard；使用 OpenClipboard/CloseClipboard，成功交给 SetClipboardData 的内存由系统持有，失败分支释放仍由调用者持有的内存。
- 剪贴板忙时用有限次数的定时器重试，最终失败显示提示；不长时间 Sleep，不在复制成功后恢复旧剪贴板。复制目标在发起操作时冻结，不随结果列表更新而变。
- 文件操作前检查目标状态；文件已移除、无权限、资源管理器打开失败等分别给出非阻塞提示。路径复制允许复制仍在当前结果中的已失效路径；实际打开/复制文件要求目标可用。
- 菜单在点击外部、Esc、搜索条件变化、结果替换、页面隐藏或失焦时关闭。菜单关闭不等于隐藏整个窗口。
- 菜单和操作消息只携带 host 分配的结果 ID 与结果版本；AHK 从当前结果快照取路径，不信任页面传回的任意路径。

## 6. 搜索后端与数据设计

### 6.1 模块划分

建议新增：

- lib/features/everything/everything.ahk：公共入口、功能状态、窗口是否激活、查询参数与分类定义。
- lib/features/everything/everything_panel.ahk：PanelHost、ready/open 协调、消息收发、隐藏与退出。
- `lib/features/qbar/qbar_everything.ahk`：承载独立 Everything 页共用的 CLI 查询、实例探测、异步作业、CSV 解码和参数转义；不复制第二套后端。
- lib/features/everything/everything_actions.ahk：打开、定位、文件复制、两种路径复制。
- pages/everything.html：页面布局、分类切换、列表、键盘交互、右键菜单和状态显示。

QBar 只负责识别四个别名并启动页面；qbar_everything.ahk 只保留页面实际使用的共用后端实现，不再保留旧的 QBar 内嵌搜索入口或兼容调度函数。

### 6.2 功能状态

- 窗口：host、visible、windowInitialized、pageReady、pendingOpen、openSerial。
- 查询：queryText、categoryId、requestId、queryTimer、currentJob。
- 结果：resultsVersion、resultsById、renderedResults、selectedId、status。
- 实例：backendChoice、bundledState、bundledOwned、warmupDeadline。
- 图标：功能独立的 sentIconKeys；数据复用 IconCache/图标提取工具。页面重载时清空自身发送记录。

请求有效性依据 Everything 的 requestId 和 visible，不依赖 QbarVisible。失焦会隐藏页面并使当前请求失效，重新打开后发起新请求。结果消息携带请求 ID，JS 同样丢弃落后于最新输入版本的回包。

### 6.3 作业流程

1. 条件变化立即递增请求 ID，取消旧防抖和旧客户端作业，关闭菜单、清除选中状态。
2. 防抖结束或立即搜索时构造有效查询。每个作业记录查询、分类、序号、PID/句柄、期限、输出路径和实例选择。
3. 优先探测用户已有 Everything，失败后复用/启动独立命名的内置实例。保留仅终止本程序自有实例的原则。
4. 复用当前 50ms 左右的短轮询；探测 3 秒、搜索 5 秒、冷启动总等待 15 秒作为初始值。超时、用户取消、拒绝提权分别进入可恢复状态。
5. 进程完成且当前请求仍有效后读取并解析输出，分配结果 ID，一次更新结果快照；旧请求不得清空新结果或显示新请求的错误。
6. 错误在页面状态区显示，并提供重新搜索入口；不能沿用“本次会话提示一次后永久不再尝试”的失败锁定方式。
7. 后端不存在或启动失败时输入框仍可编辑。执行中的旧结果可以短暂显示，但置为过期状态并禁止操作，成功后原子替换。
8. 结果为零是正常状态，不据此推断正在建索引。输出读取/CSV 解析失败必须显示错误，不能伪装为零结果。
9. 明确成功、失败、超时、取消、隐藏、退出每条路径的进程和句柄释放责任。沿用现有查询产生的临时输出生命周期；实施期间不执行任何清理命令或删除工作区文件。

### 6.4 结果模型与数量

建议结果结构：`{id, fullPath, name, parentPath, kind, extension, size, modifiedAt, iconKey}`。展示文本通过 textContent，数据通过 JSON 序列化发送，不直接拼入 HTML。

首版沿用 Qbar.esMaxResults（默认 50，上限 500）作为页面结果上限，不沿用 qbar.html 的 MAX_RENDERED=60 截断。页内显示全部已返回结果，排序菜单只改变当前结果集顺序。

为判断是否截断，查询最多请求配置上限加一项，页面只显示配置上限项。多出一项时显示“已显示前 N 项，请细化条件”；否则显示“已显示 N 项”。不将截断后的数量标成索引总数。本期不实现分页或无限滚动；后续如需此能力，应核对 ES 官方 offset/sort/count 支持再设计。

CSV 首版仍使用完整路径单列，保留现有 UTF-8/BOM/系统代码页兼容。文件夹识别保留现有机制，但图标提取和批量路径检查采用有界分批处理，并在每批开始检查序号；不能把所有耗时工作堆在 WebView 消息回调里。定时器只是分批调度，不宣称消除了单次文件系统调用的阻塞。

### 6.5 消息协议

| 方向 | 消息 | 核心字段与职责 |
| --- | --- | --- |
| 页面 → AHK | ready | 页面初始化完成；协调 pendingOpen，只消费一次 |
| 页面 → AHK | query | text、categoryId、immediate；校验分类白名单和字段类型 |
| 页面 → AHK | action | action、resultId、resultsVersion；操作白名单和结果快照校验 |
| 页面 → AHK | hide | 显式隐藏页面 |
| AHK → 页面 | initialize | 文本、分类、语言；恢复和聚焦 |
| AHK → 页面 | searchState | 请求 ID、loading/empty/error/ready、提示 |
| AHK → 页面 | setResults | 请求 ID、结果版本、结果数组、是否截断 |
| AHK → 页面 | addIcons | 图标 key → data URI，每页独立记录 |
| AHK → 页面 | actionResult | 操作结果及短提示，避免打断输入 |

初始化填入文本时使用不触发 query 的页面接口，由宿主统一安排首次查询，避免宿主和 input 事件各提交一次。

## 7. QBar 接入的明确规则

- 保留并统一处理四个等价别名：`e`、`everything`、`find`、`f`。它们必须共用同一个 Everything 启动函数、同一套页面初始化和同一套查询参数解析，不能分别维护四套分支。
- 用户已有同名 QRun/QWeb/QSearch 配置继续优先；优先级按完整 token 判断，因此配置了 `everything` 时只覆盖 `everything`，不能误覆盖 `e`、`find` 或 `f`，反之亦然。
- 在 QbarQuery 检测到明确内置别名时，只展示“打开 Everything”或“在 Everything 中搜索：…”启动行；不调用 ES 后端，也不让通用 AI 兜底成为该命令的默认动作。
- 入口行需要明确的功能标记或新类型，执行时不能走普通 search 行的 startSearch 补空格路径。若加类型，四个别名的入口展示可以显示各自 token，但同步 qbar.html 的 TYPE_RANK/TYPE_GLYPH 和结果序列化；不得只给 `e` 增加特殊类型。
- 执行时先从原始输入提取第一个 token，并确认它属于四个内置别名，再保留后续完整文本；不能让 selected token 覆盖 `e 合同 ext:pdf`、`everything 合同 ext:pdf`、`find 合同 ext:pdf` 或 `f 合同 ext:pdf` 的参数。
- 裸命令、选中入口、带文本命令、参数内容恰好是另一个别名四类情况都走统一启动函数。例如 `e e`、`everything find`、`find f`、`f everything` 分别搜索 `e`、`find`、`f`、`everything`，第二个 token 不能被再次当成启动命令剥掉。
- 关闭 QBar，然后在 WebView 回调之外调用 EverythingShow(text, hasExplicitQuery)。Ctrl+Enter 对该入口也按启动处理，避免落入 www.*.com 兜底。
- QbarHide 不再取消 Everything 页的作业，QbarShutdown 不再拥有 Everything 服务器退出逻辑。
- lib/input/keys.ahk 的 keyFunc_qbar 参考 AI/词典页增加 EverythingIsActive 判断，避免该页输入大写 Q 时误唤起 QBar。
- 不把 Everything 页与 AI 的 API 配置检查绑定；该页不需要 LLM 配置。

## 8. 分步实施清单

### P0：确定基线与官方接口

- [ ] 查看当前 git status 和目标文件 diff，记录已有修改；不回退任何已有工作。
- [ ] 核对 Voidtools 官方查询语法，以及 Windows 文件剪贴板和 Shell 定位 API；不执行应用或诊断脚本。
- [ ] 全局搜索 QbarEs*、IconSent、Shutdown 的引用，列出迁移后调用关系。
- [ ] 确认本计划中的默认交互：空文件名且“全部”分类不查询，具体分类可单独查询，单选、复制文件、结果上限提示。

完成条件：原有入口/生命周期引用已定位，分类表达式和 Windows API 参数依据明确。

### P1：独立搜索后端

- [x] 新建 everything.ahk；复用 qbar_everything.ahk 的共用后端实现，避免复制两套实例管理代码。
- [x] 建立分类表、有效查询构造器、请求序号、结果模型和上限加一项截断判断。
- [x] 保留实例选择、进程轮询、取消、超时和编码处理，并把错误状态发布到独立页面。
- [x] 核对旧 QbarEs 后端只保留一份实现；QBar 入口通过适配层进入 Everything 页面。

完成条件：Everything 模式的查询、发布、取消、退出依据 Everything 状态；QBar 兼容路径仍可用，但页面结果不再发送到 QBar。

### P2：窗口和页面骨架

- [x] 新建 everything_panel.ahk 和 pages/everything.html，接入 PanelHost。
- [x] 实现原生窗口、尺寸位置复用、最小化恢复、关闭隐藏和失焦自动隐藏。
- [x] 完成 ready/open 去重、激活输入框、带入文本和首次搜索。
- [x] 建立共享主题布局及加载、空结果、错误状态，接好分类栏和结果列表。
- [x] 独立管理图标发送记录，复用现有图标缓存。

完成条件：协议字段和 JS 函数逐一对照一致；焦点操作只由打开/明确用户行为触发。

### P3：文件交互

- [x] 新建 everything_actions.ahk，实现打开、定位、CF_HDROP 复制和两种路径复制。
- [x] 实现右键菜单位置约束、键盘导航、四个菜单动作和操作提示。
- [x] 加入结果版本校验、文件失效分支和剪贴板内存/重试处理。
- [x] 实现单击选择、双击打开、Enter/Ctrl+Enter/Ctrl+C/Esc/IME 行为。

完成条件：每个菜单动作都有唯一宿主处理分支；输入框快捷键不被列表行为覆盖。

### P4：入口迁移和主程序生命周期

- [x] 修改 qbar_index.ahk、qbar_commands.ahk 和 qbar_everything.ahk 的共用后端路由。
- [x] 同步 qbar.html 和 QbarSendResults；四个别名全部展示为打开 Everything 的入口，不再在 QBar 展示文件查询结果。
- [x] 从 qbar.ahk/qbar_panel.ahk 移走 Everything 状态、隐藏取消和自有实例退出责任。
- [x] capslock_p2.ahk 加入新模块 include；lib/app/core.ahk 的 Shutdown 调用 EverythingShutdown。
- [x] lib/input/keys.ahk 加入 Everything 页激活判断。

完成条件：所有别名统一打开页面；QBar 的普通应用启动、网页搜索、AI 和路径浏览仍有完整调用路径。

### P5：设置文案、文档和静态验收

- [x] pages/settings.html 将现有 esMaxResults 说明明确为独立 Everything 页的结果上限，保留 Qbar 配置键兼容性。
- [x] 更新 README.md、capslock_p2-settingsDemo.ini、capslock_p2-default.ini 的相关说明，并同步 pages/usage.html、docs/architecture.md 和 docs/packaging.md。
- [x] 复核 pages/*.html 已覆盖新页面；未打包、未提交、未发布。
- [x] 阅读 diff、引用搜索、include 路径、消息字段、主题变量和资源释放分支；已执行 git diff --check。
- [x] 汇报静态检查结论与未运行项，保留本计划的完成状态勾选记录。

## 9. 验收矩阵

下列为实现必须满足的行为规格，不是新增测试代码。本项目禁止编写测试、启动或运行脚本，因此本轮及后续未获新授权的实施阶段只做静态检查；实际窗口、剪贴板、Everything 行为不得标成已实测。

| 条件 | 预期 |
| --- | --- |
| e / everything / find / f | 四个裸别名分别打开同一个 Everything 页面，行为、窗口复用、焦点和分类状态完全一致 |
| e 合同 / everything 合同 / find 合同 / f 合同 | 四种写法都把“合同”带入同一个页面并立即搜索，QBar 本身不查询文件 |
| e ext:pdf dm:today / everything ext:pdf dm:today / find ext:pdf dm:today / f ext:pdf dm:today | 四种写法都保留同一条原生语法查询 |
| 搜索参数含空格、引号、中文、管道、反斜杠 | 参数完整保留并按 Everything 语法解释，不被 shell 执行 |
| 输入 e e、everything find、find f、f everything | 页面分别搜索 e、find、f、everything，只剥离第一个启动别名 |
| 四个别名中任一 token 存在同名配置命令 | 只按完整 token 延续原有配置优先级，不影响其他三个内置别名 |
| 先搜慢查询 A，再搜 B | A 的成功/失败均不能覆盖 B |
| 输入中切换 PDF，再切图片 | 使用新分类的完整后端查询，旧结果不可操作 |
| OR 表达式 + 类型过滤 | OR 的各分支都受所选分类约束 |
| 清空输入框 | “全部”分类清空结果且不查询；具体分类按类型查询 |
| 中文输入法组字、Enter、Esc | 不搜索中间拼音，不误打开文件/关闭窗口 |
| 第一次打开/重开/最小化恢复 | 输入框可直接输入，单窗口复用，尺寸位置保留 |
| 点击别的窗口/打开文件/打开资源管理器 | Everything 页自动隐藏并取消当前查询；重新打开后恢复输入和分类 |
| 关闭页面后迟到的结果 | 不重开窗口、不更新隐藏页为当前请求 |
| 复制文件/文件夹 | 系统剪贴板携带文件格式，预期支持资源管理器粘贴 |
| 复制路径/所在路径，含中文空格/UNC/根目录 | 完整 Unicode 路径，父目录规则一致 |
| 结果文件已删除、剪贴板忙、用户拒绝提权 | 显示明确错误，页面仍可继续搜索或重试 |
| 用户已有 Everything / 本程序启动内置实例 | 退出时仅处理自己拥有的实例 |
| QBar 已发送某扩展名图标后打开新页 | 新页仍收到所需图标 |
| 返回数量达到上限 | 有截断提示，不显示虚假的全局总数 |
| 点击排序菜单的八个选项 | 当前结果集按名称、路径、大小或修改时间升序/降序重排；切换后选中项回到第一项，菜单可用 Esc 或点击外部关闭 |
| 深浅色、小窗口、高 DPI、长文件名 | 主题统一，结果可滚动，菜单不越界，控件可用 |

完成交付应包括：上述功能实现、相关说明更新、静态检查记录，以及明确列出的未运行验证项。若后续用户授权人工运行，可按此矩阵操作现有程序验证，无需编写任何测试或诊断脚本。
