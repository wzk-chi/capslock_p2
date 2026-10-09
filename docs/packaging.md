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
- 运行设置和用户数据：首次启动时在安装目录创建 `data\capslock_p2.db`

`tools/capslock_p2.iss` 不参与程序运行。可信默认设置在首次初始化时写入主数据库；安装包不携带配置 INI 或用户数据。

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
- `pages\`：`theme.css`、`icons.js`、`windowbar.js`、`panel.js`、`settings-page.js`、`clipboard-history.js`、`clipboard-view.js`、`chat.js`、`qbar.html`、`qbar-notes.html`、`qbar-search.js`、`everything.html`、`translate.html`、`dictionary.html`、`chat.html`、`settings.html`、`usage.html`（浏览器打开的「使用介绍」页，CapsLock+F1）。设置、剪贴板历史和聊天页面的业务脚本按原 classic script 顺序加载各自页面文件；剪贴板页面先加载 `clipboard-view.js`，再加载 `clipboard-history.js`。所有 HTML 页面依赖同目录的 `theme.css` 共享主题文件；交互面板通过 `panel.js` 节流上报鼠标移动，以恢复系统指针。
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
- `README.md` 和 `LICENSE`（GPL v2，派生自 Capslock+ 需随程序分发）

设置中心由 CapsLock+F12、托盘菜单「设置」和 qbar `cl set` 打开；翻译和 AI 页面中的设置按钮只发送消息，
不会再加载独立的设置脚本。`pages\settings.js` 与旧的 `loadScript\`、`lib\math.ahk`、
`lib\jsEval.ahk`、INI 诊断副本已在本轮经用户授权删除，不属于运行时或发布资源。

安装器默认创建当前用户的开始菜单和桌面快捷方式。用户可以在安装向导中改选安装目录，但程序需要对该目录具有写入权限，因为主数据库和日志位于程序目录旁。

Everything 建立索引时使用独立数据目录：

```text
%LocalAppData%\capslock_p2\Everything\
```

Everything 页的 `es.exe` 和版本化 Everything 只从安装包的 `resources\` 布局查找；设置中心不提供路径重定向，旧用户 INI 中的 `esPath`、`everythingPath`、`esInstance` 文本不会再参与运行时。结果上限属于 `builtin.everything` 工具设置，范围为 1–500。

设置和用户内容统一使用一个主数据库；笔记图片保留独立媒体目录：

```text
{app}\data\capslock_p2.db
{app}\data\qbar-notes\media\
```

`data\` 不出现在安装器 `[Files]` 或 `UninstallDelete` 中，因此安装包不携带用户数据，覆盖更新和同目录重装不会覆盖数据库或图片。卸载也不会主动删除数据；更换安装目录时复制主数据库及 `data\qbar-notes\media`。

运行配置、插件、笔记、剪贴板历史和 AI 会话统一保存在 `{app}\data\capslock_p2.db`。媒体文件保存在 `{app}\data\qbar-notes\media`。这些路径不列入安装包，也不由覆盖更新或卸载清理。

旧版 `capslock_p2.ini`、窗口绑定 INI 与四个独立数据库仅供本次开发环境的手动迁移，已完成导入并保留原文件。程序启动时直接读取主库；全新安装首次创建主库并写入默认配置及插件设置，不检测、读取或清理旧来源。安装包不包含旧 INI、默认 INI、示例 INI 或独立数据库。

WebView2 Runtime 不随安装包内置，目标机器需要预先安装 Microsoft Edge WebView2 Runtime。内置 Everything 第一次建立 NTFS 索引时可能请求一次管理员权限。

## 配置和安全规则

开发机根目录的 `capslock_p2.ini` 是个人迁移来源，可能包含真实 API 地址和 API Key，**禁止作为安装包输入文件**。安装包不携带默认 INI、示例 INI、用户 INI 或窗口绑定 INI：

- 首次创建主数据库时，将可信默认项写入 `cfg_defaults`；个人修改写入 `cfg_values`，插件默认项归各自插件设置；
- 不打包 `capslock_p2-debug.log`；
- 不打包 `capslock_p2-winsInfosRecorder.ini`；
- 不打包 `capslock-plus\`、`.claude\`、已退役诊断脚本和 AHK 源码；
- 不把个人 API Key 写入 `.iss`、数据库 seed 或任何发布文档。

多行提示词和热字符串按逻辑文本存入 SQLite，不使用 INI 转义。凭据使用当前 Windows 用户的 DPAPI 保护；日志不记录 API Key、请求正文、剪贴板或用户输入。

生成的安装器是一个 EXE，但安装后仍会有 `pages`、`resources` 等运行时文件，这是因为 WebView2、SQLite、词典和 Everything 都必须按磁盘路径访问。程序按固定资源布局查找 es.exe 和内置 Everything；不要把它们删除或移动到未被代码支持的位置。

## 输出与验证

建议把中间主程序放在 `build\payload\`，把最终安装器放在 `dist\`。构建后做以下静态核对：

1. Ahk2Exe 和 ISCC 退出码均为 0。
2. `pages\`、`vendor\`、`resources\dictionary.db`、`resources\SQLite3.dll`、Everything、64 位 WebView2 loader 和图标均存在。
3. 安装包不包含任何 `data\` 内容、配置 INI、个人配置或窗口绑定 INI。
4. 发布物中没有 API Key、调试日志和机器专属窗口绑定记录。
5. 使用 PowerShell 或文件工具核对文件和哈希，不启动项目程序，不执行安装器验证其运行效果。

开发任务如果只涉及代码或文档，**不要自动重新打包**；只有用户明确要求发布包时，才调用 Ahk2Exe 和 Inno Setup。
