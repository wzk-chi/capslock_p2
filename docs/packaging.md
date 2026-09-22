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
- 发布用脱敏配置：`tools/capslock_p2-default.ini`

`tools/capslock_p2.iss` 不参与程序运行，`tools/capslock_p2-default.ini` 只作为安装包的首次配置模板。

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
- `pages\`：`qbar.html`、`translate.html`、`dictionary.html`、`chat.html`、`settings.js`、`usage.html`（浏览器打开的「使用介绍」页，CapsLock+F1）
- `vendor\`：AI 回答使用的 `marked.min.js`、`purify.min.js`
- `loadScript\`：JavaScript 扩展
- `resources\dictionary.db`：ECDICT 本地词典
- `resources\SQLite3.dll`：词典的 SQLite 引擎
- `resources\es.exe`：Everything 查询命令行工具
- `resources\Everything-1.4.1.1032.x64\`：内置 Everything 主程序和语言文件
- `resources\capslock_p2-icon.png`：运行时托盘图标
- `resources\capslock_p2-icon.ico`：EXE、安装器和快捷方式图标
- `WebView2\64bit\WebView2Loader.dll`
- `capslock_p2-settingsDemo.ini`、`README.md` 和 `LICENSE`（GPL v2，派生自 Capslock+ 需随程序分发）

安装器默认创建当前用户的开始菜单和桌面快捷方式。用户可以在安装向导中改选安装目录，但程序需要对该目录具有写入权限，因为配置、日志和窗口绑定记录位于程序目录旁。

Everything 建立索引时使用独立数据目录：

```text
%LocalAppData%\capslock_p2\Everything\
```

WebView2 Runtime 不随安装包内置，目标机器需要预先安装 Microsoft Edge WebView2 Runtime。内置 Everything 第一次建立 NTFS 索引时可能请求一次管理员权限。

## 配置和安全规则

开发机根目录的 `capslock_p2.ini` 是个人配置，可能包含真实 API 地址和 API Key，**禁止作为安装包输入文件**。安装器只使用不含凭据的 `tools/capslock_p2-default.ini`：

- 首次安装时生成 `capslock_p2.ini`；
- 升级时使用 `onlyifdoesntexist`，保留用户已有的 API 配置；
- 不打包 `capslock_p2-debug.log`；
- 不打包 `capslock_p2-winsInfosRecorder.ini`；
- 不打包 `capslock-plus\`、`.claude\`、诊断脚本和 AHK 源码；
- 不把个人 API Key 写入 `.iss`、默认配置或任何发布文档。

生成的安装器是一个 EXE，但安装后仍会有 `pages`、`resources` 等运行时文件，这是因为 WebView2、SQLite、词典和 Everything 都必须按磁盘路径访问。不要为了追求“安装后只有一个文件”而把这些文件删除或移动到未被代码支持的位置。

## 输出与验证

建议把中间主程序放在 `build\payload\`，把最终安装器放在 `dist\`。构建后做以下静态核对：

1. Ahk2Exe 和 ISCC 退出码均为 0。
2. `pages\`、`vendor\`、`resources\dictionary.db`、`resources\SQLite3.dll`、Everything、64 位 WebView2 loader 和图标均存在。
3. 安装包配置引用的是 `tools/capslock_p2-default.ini`，没有引用根目录个人 `capslock_p2.ini`。
4. 发布物中没有 API Key、调试日志和机器专属窗口绑定记录。
5. 使用 PowerShell 或文件工具核对文件和哈希，不启动项目程序，不执行安装器验证其运行效果。

开发任务如果只涉及代码或文档，**不要自动重新打包**；只有用户明确要求发布包时，才调用 Ahk2Exe 和 Inno Setup。
