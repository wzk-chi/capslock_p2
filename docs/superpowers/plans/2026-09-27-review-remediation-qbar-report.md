# qbar 修复实施报告

日期：2026-09-27

范围：实施总计划 Task 5（qbar 配置索引缓存与命令拆分）和 Task 7（Everything 异步可取消作业），并复核 Task 4 已完成的固定资源路径策略。

## 已实施

### 配置索引

- 新增按 generation 失效的 `QbarConfigIndex()`，只缓存 QSearch、QRun、QWeb 的标准化展示条目、分 section 条目和短键索引；开始菜单、文件夹、Everything 结果及图标发送状态保持独立生命周期。
- `QbarInvalidateConfigIndex()` 清空缓存并增加 generation。现有 `ApplyConfigChanges()` 已在 QSearch、QRun、QWeb 或界面语言发生有效变化时合批调用一次。
- 查询过滤、短键占用判断、搜索分派、QRun/QWeb 精确执行及参数替换改为复用缓存索引。
- 删除缓存接入后不再有调用者的 `QbarSearchEntries()` / `QbarConfigItemsOf()` 包装，避免保留第二套读取入口。
- 明确保留原规则：展示顺序为内置 q/e、QSearch、QRun、QWeb；空配置值仍占用短键但不生成可执行条目；同 section 重复短键仍取配置枚举中第一个；字符串匹配大小写行为不变；运行时执行仍重新检查文件/文件夹。
- 新增 `QbarSplitCommand()`，统一查询、执行、内联配置和 Everything 请求的首词/余量拆分，余量只移除空格和 Tab。

### Everything 作业

- 确认仓库随附的 `resources/es.exe` 包含官方 `-export-csv` 参数，查询和探测直接启动 es.exe 输出到专属 CSV，不再借助 `cmd.exe` 重定向。
- 增加单作业状态 `QbarEsJob`：记录作业类型、查询序号、PID、进程句柄、临时路径、开始时间、期限、后端、参数和所有者。
- 默认实例探测、内置实例探测和搜索共用 `Run(..., "Hide", &pid)`、短定时器轮询、固定期限、退出码读取、CSV 解析和清理流程。
- 查询参数和路径使用 Windows argv 反斜杠/引号规则逐字符引用。查询文本不写调试日志。
- 新查询、立即执行、离开 Everything 模式、清空查询、隐藏面板和关闭程序都会取消旧作业、递增序号并清理临时文件。只会关闭所有者标记为 `qbar-es-client` 的 es.exe 客户端进程，不会调用 `ProcessClose()` 关闭用户或内置 Everything 服务进程。
- 内置实例冷启动由 15 秒期限和定时重试表示；删除 `Sleep(1500)` 循环。旧结果在新作业完成前继续显示，期限到达只提示一次。
- `QbarEsBundledStarted` 只在本会话实际启动内置实例后置真；已经存在的内置实例只标记 reachable，关闭阶段不会退出它。
- es.exe 和 Everything 路径继续固定在程序 `resources` 目录，实例名固定为 `capslock_p2`，仅 `esMaxResults` 保持配置可调。

## 静态检查

- `git diff --check`：通过；只有 Git 的 LF/CRLF 工作树提示，无空白错误。
- `rg` 调度审计：qbar Everything 文件中没有 `RunWait`、`Sleep(`、`A_ComSpec`、固定 probe 临时文件或查询原文日志。
- `rg` 解析审计：`QbarFirstToken()` 只由 `QbarSplitCommand()` 调用；旧的重复 `SubStr(...StrLen(firstToken/trigger/arrowWord))` 组合已收敛。
- `rg` 索引审计：QSearch/QRun/QWeb 的 qbar 查询与执行入口均通过 `QbarConfigIndex()` / `QbarConfigEntry()`；`ApplyConfigChanges()` 中存在合批失效调用。
- 括号计数：本次五个 qbar 文件的 `{` / `}` 数量分别相等。
- 资源检查：仓库存在 `resources/es.exe`、`resources/Everything-1.4.1.1032.x64/everything.exe` 和 `Everything.lng`；Inno Setup 清单第 50、53 行仍包含 es.exe 与版本化 Everything 目录。

按 AGENTS.md 约束，未运行 AHK、JavaScript、Everything、测试、诊断脚本、编译器或安装器。因此运行时搜索结果、UAC 冷启动和取消时序尚未进行动态验证。

## 变更文件

- `lib/qbar.ahk`
- `lib/qbar_index.ahk`
- `lib/qbar_commands.ahk`
- `lib/qbar_everything.ahk`
- `lib/qbar_panel.ahk`
- `lib/core.ahk`（仅使用并保留工作区已有的 `ApplyConfigChanges()` → `QbarInvalidateConfigIndex()` 接口接入，本次未另行扩大修改）
