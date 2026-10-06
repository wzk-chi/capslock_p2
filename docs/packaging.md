# 打包说明

本项目使用 **AutoHotkey v2 + Inno Setup** 发布。运行程序和安装包是两个不同的产物：

```text
capslock_p2.ahk
    └─ Ahk2Exe ─> capslock_p2.exe       主程序

capslock_p2.exe + 动态资源
    └─ Inno Setup ─> capslock_p2-setup.exe  单文件安装包
```

## 工具

- AutoHotkey v2：开发版本 2.0.13
- Ahk2Exe：用于把 `capslock_p2.ahk` 编译成 64 位主程序
- Inno Setup 6：用于把主程序和动态资源压缩成一个安装 EXE
- Inno Setup 配置：`tools/capslock_p2.iss`
- 发布用脱敏配置：`capslock_p2-default.ini`

`tools/capslock_p2.iss` 不参与程序运行，`capslock_p2-default.ini` 是程序和安装包共用的完整默认配置。

## 构建顺序

先编译主程序，再编译 Inno Setup 安装包。建议使用 PowerShell 的 `Start-Process -Wait -PassThru`，确保能读取真实退出码：

```powershell
$project = "D:\develop\project\cpaslock_p2"
$ahk2exe = "D:\utils\AutoHotkey\Compiler\Ahk2Exe.exe"
$base = "D:\utils\AutoHotkey\v2\AutoHotkey64.exe"

Start-Process $ahk2exe -ArgumentList @(
  '/in', "$project\capslock_p2.ahk",
  '/out', "$project\build\payload\capslock_p2.exe",
  '/base', $base,
  '/icon', "$project\resources\capslock_p2-icon.ico"
) -Wait -PassThru

$iscc = "C:\Users\13356\AppData\Local\Programs\Inno Setup 6\ISCC.exe"
Start-Process $iscc -ArgumentList @("$project\tools\capslock_p2.iss") -Wait -PassThru
```

如果路径或输出文件名含空格，应按 PowerShell 参数规则传递。不要在 Git Bash 中调用 AHK 编译器；MSYS 可能把 `/in`、`/out`、`/base`、`/validate` 等参数改写成路径。AHK 语法校验也应使用 PowerShell 原生命令，详见 `AGENTS.md`。

## 安装包内容

安装器从 `tools/capslock_p2.iss` 读取资源并释放到用户选择的安装目录，默认是：

```text
%LocalAppData%\capslock_p2\
```

资源保持原有目录结构，因为主程序通过 `A_ScriptDir` 按文件路径加载：

- `capslock_p2.exe`
- `pages\`：`theme.css`、`icons.js`、`windowbar.js`、`panel.js`、`settings-page.js`、`clipboard-history.js`、`chat.js`、`qbar.html`、`qbar-notes.html`、`qbar-search.js`、`everything.html`、`translate.html`、`dictionary.html`、`chat.html`、`settings.html`、`usage.html`（浏览器打开的「使用介绍」页，CapsLock+F1）。设置、剪贴板历史和聊天页面的业务脚本按原 classic script 顺序加载各自页面文件。所有 HTML 页面依赖同目录的 `theme.css` 共享主题文件；交互面板通过 `panel.js` 节流上报鼠标移动，以恢复系统指针。
- `vendor\`：AI 回答使用的 `marked.min.js`、`purify.min.js`，共享 UI 图标库
  `lucide\lucide.min.js` 及其许可证，还有随安装包分发的 `pinyin-pro\pinyin-pro.js`、MIT
  许可和来源说明。
- `resources\dictionary.db`：ECDICT 本地词典
- `resources\SQLite3.dll`：词典的 SQLite 引擎
- `resources\es.exe`：Everything 查询命令行工具
- `resources\Everything-1.4.1.1032.x64\`：内置 Everything 主程序和语言文件
- `resources\capslock_p2-icon.png`：运行时托盘图标
- `resources\capslock_p2-icon.ico`：EXE、安装器和快捷方式图标
- `WebView2\64bit\WebView2Loader.dll`
- `capslock_p2-default.ini`、`capslock_p2-settingsDemo.ini`、`README.md` 和 `LICENSE`（GPL v2，派生自 Capslock+ 需随程序分发）

设置中心由 CapsLock+F12、托盘菜单「设置」和 qbar `cl set` 打开；翻译和 AI 页面中的设置按钮只发送消息，
不会再加载独立的设置脚本。`pages\settings.js` 与旧的 `loadScript\`、`lib\math.ahk`、
`lib\jsEval.ahk`、INI 诊断副本已在本轮经用户授权删除，不属于运行时或发布资源。

安装器默认创建当前用户的开始菜单和桌面快捷方式。用户可以在安装向导中改选安装目录，但程序需要对该目录具有写入权限，因为配置、日志和窗口绑定记录位于程序目录旁。

Everything 建立索引时使用独立数据目录：

```text
%LocalAppData%\capslock_p2\Everything\
```

Everything 页的 `es.exe` 和版本化 Everything 只从安装包的 `resources\` 布局查找；设置中心不提供路径重定向，旧用户 INI 中的 `esPath`、`everythingPath`、`esInstance` 文本不会再参与运行时。`Qbar.esMaxResults` 仍可在 1–500 范围内调整。

QBar 笔记使用安装目录下的运行时数据目录：

```text
{app}\data\qbar-notes\qbar-notes.db
{app}\data\qbar-notes\media\
```

该目录不出现在安装器 `[Files]` 或 `UninstallDelete` 中，因此安装包不携带用户笔记，覆盖更新和同目录重装不会覆盖数据库或图片。卸载也不会主动删除笔记；更换安装目录时由用户手动复制整个 `data\qbar-notes` 目录。

大型持久化数据遵循 `AGENTS.md`：优先保存在 `{app}\data\<功能名>\`，作为安装目录下的运行时用户数据，不列入安装包，也不由覆盖更新或卸载清理。剪贴板历史使用 `{app}\data\clipboard-history\clipboard-history.db`，运行后按需创建。更换安装目录时一并迁移相应功能的数据子目录。

Qbar 插件、历史和使用频率数据库使用 `{app}\data\qbar\qbar.db`。安装器的 `[Files]` 是显式资源清单，不包含 `data\`；
脚本也没有 `UninstallDelete` 项，因此不会打包、覆盖更新或卸载清理该数据库。更换安装目录时复制整个 `data\qbar` 子目录。

升级时若目标库不存在而旧 `%AppData%\capslock_p2\qbar.db` 存在，程序使用 SQLite 一致性备份迁移到同目录暂存库，
核对完整性、关键表和记录数后才无覆盖发布，原库保留。若两处数据库同时存在，则校验 `{app}\data\qbar\qbar.db`：
有效时记录冲突并使用目标库，旧库仍保留且不会合并；无效时停止初始化并提示两处路径，保留两库。
迁移失败不会创建并启用空库；安装目录或目标库写入失败会提示检查写入权限后重试，不会静默回退 AppData。

AI 问答多会话使用 `{app}\data\ai-chat\ai-chat.db`。数据库只在运行时创建；安装器通过显式资源清单打包，不包含 `data\`，也没有删除该目录的卸载项，因此覆盖更新、同目录重装和卸载不会覆盖或删除会话。更换安装目录时用户复制整个 `data\ai-chat` 子目录。详细设计见 [`2026-10-05-ai-chat-multi-session-design.md`](2026-10-05-ai-chat-multi-session-design.md)。

WebView2 Runtime 不随安装包内置，目标机器需要预先安装 Microsoft Edge WebView2 Runtime。内置 Everything 第一次建立 NTFS 索引时可能请求一次管理员权限。

## 配置和安全规则

开发机根目录的 `capslock_p2.ini` 是个人配置，可能包含真实 API 地址和 API Key，**禁止作为安装包输入文件**。安装器只使用不含凭据的 `capslock_p2-default.ini`：

- 安装包提供 `capslock_p2-default.ini`；首次运行直接使用它，并自动打开一次 `pages\usage.html` 使用介绍页；程序只在用户配置中记录内部的首次运行标记，其他设置仍按需保存覆盖项；
- 用户文件只保存覆盖项，升级时不会覆盖已有的用户配置；
- 不打包 `capslock_p2-debug.log`；
- 不打包 `capslock_p2-winsInfosRecorder.ini`；
- 不打包 `capslock-plus\`、`.claude\`、已退役诊断脚本和 AHK 源码；
- 不把个人 API Key 写入 `.iss`、默认配置或任何发布文档。

系统提示词等多行字段由配置层编码为单行 INI 存储值，读取时恢复逻辑换行；TabHotString 继续兼容 `\n` 与 `\\` 约定。配置保存只持久化有效变化，日志不记录 API Key、请求正文、剪贴板或用户输入。

生成的安装器是一个 EXE，但安装后仍会有 `pages`、`resources` 等运行时文件，这是因为 WebView2、SQLite、词典和 Everything 都必须按磁盘路径访问。程序按固定资源布局查找 es.exe 和内置 Everything；不要把它们删除或移动到未被代码支持的位置。

## 输出与验证

建议把中间主程序放在 `build\payload\`，把最终安装器放在 `dist\`。构建后做以下静态核对：

1. Ahk2Exe 和 ISCC 退出码均为 0。
2. `pages\`、`vendor\`、`resources\dictionary.db`、`resources\SQLite3.dll`、Everything、64 位 WebView2 loader 和图标均存在。
3. 安装包配置引用的是 `capslock_p2-default.ini`，没有引用根目录个人 `capslock_p2.ini`。
4. 发布物中没有 API Key、调试日志和机器专属窗口绑定记录。
5. 使用 PowerShell 或文件工具核对文件和哈希，不启动项目程序，不执行安装器验证其运行效果。

开发任务如果只涉及代码或文档，**不要自动重新打包**；只有用户明确要求发布包时，才调用 Ahk2Exe 和 Inno Setup。
