# AGENTS.md

## 项目目标

本项目用于将 `capslock-plus` 改造成 AutoHotkey v2（AHK v2）版本，并在此基础上改进现有功能。

AHK2 实现统一放在 `lib/`，WebView2 面板页面放在 `pages/`；`capslock-plus` 子目录仅作为原项目参考，不在其中新增或修改实现文件。

## 开发约束

- 禁止编写测试。
- 禁止启动或运行脚本。
- 禁止删除文件。
- 排查 Bug 时先检查相关日志和错误输出，再定位代码并确定修复方案；现有日志不足时，再补充必要的诊断信息。
- 大型持久化数据（例如历史数据库、媒体和附件）优先保存到安装目录下的 `data/`，不要默认放进 `%AppData%`。这类目录属于用户运行数据，安装包不得携带示例/开发机数据，也不得在覆盖更新或卸载时覆盖、删除；安装目录需要可写。若某种安装方式不能保证可写，必须在设计中明确处理方式和数据迁移规则。
- 风格统一：所有 WebView2 页面必须遵循统一的视觉主题、字体、颜色、边框、圆角、阴影、控件状态和深浅色规则；共享样式优先放在 `pages/theme.css`，页面文件只保留必要的局部布局和组件样式，不得重新引入互相冲突的独立配色或主题切换逻辑。
- 所有页面都面向最终用户：只展示用户完成任务或作出决策所需的信息，不加入只有开发者能理解的术语、内部标识、调试内容或实现细节。错误提示应使用用户能理解的描述，并在必要时说明可采取的下一步；技术诊断信息写入日志，不直接展示给用户。
- 暂不考虑兼容性问题；代码要求简洁、优雅、高效、清晰，优先使用现有的官方实现，避免重复造轮子。
- WebView2 页面中的 toast 与提示、确认、输入及复杂模态弹窗统一复用 `pages/toast.js` 的 `AppToast` 和 `pages/dialog.js` 的 `AppDialog`（复杂交互使用 `AppDialog.open`），样式遵循 `pages/theme.css`；不要在页面中重复实现相同能力或直接使用浏览器原生 `alert`、`confirm`、`prompt`。共享封装缺少所需能力时，先扩展共享封装再由页面调用。
- 临时测试或诊断文件如果不需要提交，统一加入本地 `.git/info/exclude`；不要为此修改项目级
  `.gitignore`。确认文件尚未被 Git 跟踪，因为 `exclude` 不会隐藏已跟踪文件的修改或删除。

## Qbar 工具规范

- 新增 Qbar 工具优先接入现有插件/命令体系，复用别名解析、候选展示、执行、设置、历史与使用统计流程；不要另建平行的工具系统，或把业务分发散落到页面和快捷键分支。
- 模块职责保持清晰：`qbar_plugin_catalog.ahk` 声明内置插件定义；`qbar_plugin_host.ahk` 管理注册、实例和配置校验；`qbar_registry.ahk` 构建内存注册表并解析别名与候选；`qbar_store.ahk` 集中处理 Qbar 数据持久化；`qbar_index.ahk` 生成展示项；`qbar_commands.ahk` 接收并校验执行请求；`qbar_execution.ahk` 调用已注册的 handler；`pages/qbar.html` 只负责交互和展示。新增动作应调用现有功能或共享服务，避免复制已有实现。
- 区分插件定义、插件实例和命令。`definitionId`、`pluginId`、`commandId` 使用稳定且带命名空间的身份；显示名称、别名和用户输入都不是命令身份。重命名或修改别名不得改变稳定 ID；执行、历史和使用统计按 ID 关联，不根据显示文本反查。
- 别名匹配不区分大小写，连续空白按一个空格归一化，多词别名采用最长匹配。别名冲突是多个有效候选，不是覆盖错误；保留并展示全部候选，按统一排序规则选择。
- 页面消息、数据库字段和 manifest 都是不可信输入。执行只接受宿主已注册且通过白名单校验的 `handlerId`，不得把其中的函数名或代码直接执行；设置和参数在进入 handler 前校验。Qbar 页面向宿主传递命令及查询上下文标识，宿主校验 session、query 和注册表版本，拒绝过期请求。
- 插件别名、启用状态、设置、历史和使用频率通过 `qbar_store.ahk` 持久化；其他模块不得自行访问 Qbar 数据库。配置变更用事务保存并更新内存注册表和相关索引；逐字符查询只读内存注册表，不查询 SQLite。不要把可执行 AHK 代码存入数据库。
- 排查 Qbar 问题先查看现有 `DebugLog` 记录；补充日志时保留足够的状态和错误上下文，不记录密钥等敏感值。
- 详细设计参考 [`docs/2026-10-02-qbar-plugin-refactor-design.md`](docs/2026-10-02-qbar-plugin-refactor-design.md)。

## 打包文档

Inno Setup、Ahk2Exe、发布资源清单、脱敏配置和安装目录的完整说明见
[`docs/packaging.md`](docs/packaging.md)。除非用户明确要求发布，否则开发任务不要自动重新打包；
根目录 `capslock_p2.ini` 可能含个人 API 凭据，禁止作为安装包输入文件。

## 工具坑记录

- **校验 AHK 语法**：在 PowerShell 中直接调用，并保留 `/ErrorStdOut` 和 `Out-String` 管道，确保读取本次运行的退出码。不要用 Git Bash（会改写 AHK 参数）或 `Start-Process` 重定向后读取 `ExitCode`。

  ```powershell
  $exe  = 'D:\utils\AutoHotkey\v2\AutoHotkey64.exe'   # 本机路径，仓库不内置运行时
  $text = (& $exe /ErrorStdOut /validate 'capslock_p2.ahk' 2>&1 | Out-String).Trim()
  "exit=$LASTEXITCODE"   # 0 = 无错误；2 = 语法错误或脚本路径不存在
  $text                  # 错误和警告详情
  ```

  相对脚本路径按当前工作目录解析，`#Include` 按脚本所在目录解析。

- **`#Warn` 警告**：警告会显示但不影响 `/validate` 退出码；`exit=0` 不代表没有警告。默认警告模式可能弹出对话框，导致校验挂起。要无弹窗收集警告，可在项目根目录将脚本从 stdin 传入，并把裸 `#Warn` 改为 `#Warn All, StdOut`：

  ```powershell
  $patch = (Get-Content -Raw capslock_p2.ahk) -replace '(?m)^#Warn\s*$', '#Warn All, StdOut'
  ($patch | & $exe /ErrorStdOut /validate '*' 2>&1 | Out-String).Trim()
  ```

  stdin 模式下 `A_ScriptDir` 取当前工作目录，因此应从项目根目录执行。
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
