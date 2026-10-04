# AGENTS.md

## 项目目标

本项目用于将 `capslock-plus` 改造成 AutoHotkey v2（AHK v2）版本，并在此基础上改进现有功能。

AHK2 实现统一放在 `lib/`，WebView2 面板页面放在 `pages/`；`capslock-plus` 子目录仅作为原项目参考，不在其中新增或修改实现文件。

## 开发约束

- 禁止编写测试。
- 禁止启动或运行脚本。
- 禁止删除文件。
- 大型持久化数据（例如历史数据库、媒体和附件）优先保存到安装目录下的 `data/`，不要默认放进 `%AppData%`。这类目录属于用户运行数据，安装包不得携带示例/开发机数据，也不得在覆盖更新或卸载时覆盖、删除；安装目录需要可写。若某种安装方式不能保证可写，必须在设计中明确处理方式和数据迁移规则。
- 风格统一：所有 WebView2 页面必须遵循统一的视觉主题、字体、颜色、边框、圆角、阴影、控件状态和深浅色规则；共享样式优先放在 `pages/theme.css`，页面文件只保留必要的局部布局和组件样式，不得重新引入互相冲突的独立配色或主题切换逻辑。
- 暂不考虑兼容性问题；代码要求简洁、优雅、高效、清晰，优先使用现有的官方实现，避免重复造轮子。
- WebView2 页面中的 toast 与提示、确认、输入及复杂模态弹窗统一复用 `pages/toast.js` 的 `AppToast` 和 `pages/dialog.js` 的 `AppDialog`（复杂交互使用 `AppDialog.open`），样式遵循 `pages/theme.css`；不要在页面中重复实现相同能力或直接使用浏览器原生 `alert`、`confirm`、`prompt`。共享封装缺少所需能力时，先扩展共享封装再由页面调用。
- 临时测试或诊断文件如果不需要提交，统一加入本地 `.git/info/exclude`；不要为此修改项目级
  `.gitignore`。确认文件尚未被 Git 跟踪，因为 `exclude` 不会隐藏已跟踪文件的修改或删除。

## 打包文档

Inno Setup、Ahk2Exe、发布资源清单、脱敏配置和安装目录的完整说明见
[`docs/packaging.md`](docs/packaging.md)。除非用户明确要求发布，否则开发任务不要自动重新打包；
根目录 `capslock_p2.ini` 可能含个人 API 凭据，禁止作为安装包输入文件。

## 工具坑记录

- **校验 AHK 语法**：用 PowerShell 直接调用，`/ErrorStdOut` 必须带，输出并进管道之后再读
  `$LASTEXITCODE`：

  ```powershell
  $exe  = 'D:\utils\AutoHotkey\v2\AutoHotkey64.exe'   # 本机路径，仓库不内置运行时
  $text = (& $exe /ErrorStdOut /validate 'capslock_p2.ahk' 2>&1 | Out-String).Trim()
  "exit=$LASTEXITCODE"   # 0 = 没有错误（警告不影响它）；2 = 语法错误或脚本路径不存在
  $text                  # 非空即错误或警告详情：<绝对路径> (行号) : ==> Missing operand.
  ```

  下面几条都实测过，少任何一条都会得到**假阳性**：

  - **`/ErrorStdOut` 不能省**：省掉后语法错误也返回 `0`，错误被丢弃，既没有对话框也没有输出。
  - **必须真的等进程**：`AutoHotkey64.exe` 是 GUI 子系统程序，PowerShell 默认不为它等待；写成
    `& $exe ... | Out-String` 这样**有管道**才会等，`$LASTEXITCODE` 才是这次的退出码。
  - **不要用 `Start-Process ... -RedirectStandardOutput/-RedirectStandardError` 去读
    `$p.ExitCode`**：本机 PowerShell 7.6.3 实测，只要带重定向，`-PassThru` 拿到的 `ExitCode` 恒为
    空（`cmd /c exit 3` 也一样；`Refresh()`、`Wait-Process` 之后仍然为空），于是「读不到退出码」
    会被当成「没报错」。而且 AHK 把错误写在 **stderr**，只重定向 stdout 的话文件始终是空的。
    不带重定向时 `-PassThru` 的 `ExitCode` 是正常的，错误文本直接打在控制台上。
  - **不要在 Git Bash 里校验**：MSYS 会把 `/ErrorStdOut`、`/validate` 当成 Unix 路径改写成
    `C:/Program Files/Git/ErrorStdOut`，AHK 报 "Script file not found"；而且 bash 的 `$?` 取的是管道
    **最后一个**命令的状态，`| head` 会把 AHK 的 2 掩成 0。PowerShell 的 `$LASTEXITCODE` 由原生命令
    设置、不受管道后面的 cmdlet 影响，所以上面那个 `| Out-String` 是安全的。

  路径规则：相对路径按 **CWD** 解析（失败时报错会带上它实际去找的绝对路径）；`#Include` 按**脚本
  自身所在目录**解析，所以从任意 CWD 用绝对路径校验都成立。退出码 `2` 同时表示语法错误和
  `Script file not found`，要区分就看输出文本。

- **`/validate` 会照常报 `#Warn` 警告，但警告不进退出码**：官方文档写的是 `/Validate` 下
  "load-time errors **and warnings** are displayed as usual"，而退出码只反映**错误**，所以
  `exit=0` 不等于「没有警告」。三种 load-time 警告都能抓到（下面用 `#Warn …, StdOut` 实测）：

  - `LocalSameAsGlobal`——函数里给同名全局赋值而没声明 `global`：
    `… (5) : ==> Warning: This local variable has the same name as a global variable.`
  - `Unreachable`——`Return`/`Break`/`Continue`/`Throw`/`Goto` 之后同层的行：
    `… (5) : ==> Warning: This line will never execute, due to Return preceding it.`
  - `VarUnset`——引用了从未被赋值的变量：
    `… (4) : ==> Warning: This variable appears to never be assigned a value.`

  这三种情况下退出码**都是 `0`**，只看退出码完全看不到警告。警告走 **stdout**，语法错误走
  **stderr**，所以上面配方里的 `2>&1` 两种都能收到。

  **由此而来的坑**：默认 `WarningMode` 是 `MsgBox`，而本项目 `capslock_p2.ahk` 第 5 行是裸 `#Warn`
  （= `All`，比不写更严——不写时 `LocalSameAsGlobal` 是关的）、第 10 行是 `#Warn VarUnset, Off`，
  也就是 MsgBox 模式。于是**校验一份带警告的脚本会弹出模态对话框并一直等在那里**，在自动化里看起来
  就是命令卡住（不是脚本慢）。`/ErrorStdOut` **救不了这个**——按文档它只管"prevent a script from
  launching"的语法错误，实测警告照样弹框、stderr 是空的。`#Warn` 指令又以**最后一次出现为准**，
  所以用 `/include` 预置一个 `StdOut` 也覆盖不掉脚本自己的设置。

  要抓警告又不想被对话框挡住，有一个不用改文件的办法：把脚本文本从 **stdin** 喂给 AHK（文件名写
  `*`），顺手把 `#Warn` 那一行改写成 `StdOut`。stdin 模式下 `A_ScriptDir` 取**初始工作目录**，
  所以在项目根目录下跑，`#Include` 照样解析得到：

  ```powershell
  # 接上面第一段的 $exe
  $patch = (Get-Content -Raw capslock_p2.ahk) -replace '(?m)^#Warn\s*$', '#Warn All, StdOut'
  ($patch | & $exe /ErrorStdOut /validate '*' 2>&1 | Out-String).Trim()
  ```

  实测这样能一次列出整棵 include 树里所有 `LocalSameAsGlobal` / `Unreachable` 警告，带绝对路径和
  行号，而且退出码仍然是 `0`。
- **AHK 的 `NumPut` 只收纯数字**：传入 `ComValue`（如 `ComObjArray` 迭代出的 VT_UI1 包装）或
  String 会抛 "Invalid parameter(s)"；而且 VT_UI1 的 ComValue 参与 `+ 0` 这类算术会直接抛
  "Expected a Number"。COM/SafeArray 数据入缓存前先转成纯数值（`NumGet` 读出即是），
  不要把 ComValue 存进数组再消费。WebView2 面板回调内不要同步 `await2` 创建另一个
  WebView2（会 15 秒超时），用 `SetTimer(fn, -1)` 延迟到回调外。

- **AHK v2 闭包不捕获 `for` 循环变量**：嵌套函数只捕获外层函数以 `local` 声明、参数、或赋值
  形式出现过的变量。`for host in hosts` 的循环变量这三者都不是，于是闭包里的 `host` 变成
  未赋值的局部变量，`SetTimer(() => Fn(host), -1)` 触发时抛
  "This variable has not been assigned a value"。这类延迟调用改用 `Fn.Bind(host, arg)`：
  传值，不依赖名字捕获。在函数体顶层赋值的普通局部变量（`text := ...`）不受影响。

- **WebView2 面板的鼠标指针恢复**：Windows 开启“键入时隐藏指针”后，WebView2 不一定像原生编辑控件
  一样在鼠标移动时自动恢复指针。所有可交互页面都要同时做好两层处理：宿主显示/激活面板时调用一次
  `ShowSystemCursor()`；页面用 `mousemove` 监听器按约 80ms 节流发送 `{ type: 'cursorMove' }`，宿主消息
  分支收到后再次调用 `ShowSystemCursor()`。只在 AHK 侧增加 `cursorMove` 分支而不在页面发送事件是不完整
  的；不要用高频无节流上报，也不要用轮询替代鼠标移动事件。现有参考实现是 `pages/chat.html` +
  `lib/features/aiChat.ahk`。
