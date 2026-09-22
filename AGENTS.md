# AGENTS.md

## 项目目标

本项目用于将 `capslock-plus` 改造成 AutoHotkey v2（AHK v2）版本，并在此基础上改进现有功能。

AHK2 实现统一放在 `lib/`，WebView2 面板页面放在 `pages/`；`capslock-plus` 子目录仅作为原项目参考，不在其中新增或修改实现文件。

## 开发约束

- 禁止编写测试。
- 禁止启动或运行脚本。
- 禁止删除文件。
- 优先使用现有的官方实现，不要重复造轮子。

## 打包文档

Inno Setup、Ahk2Exe、发布资源清单、脱敏配置和安装目录的完整说明见
[`docs/packaging.md`](docs/packaging.md)。除非用户明确要求发布，否则开发任务不要自动重新打包；
根目录 `capslock_p2.ini` 可能含个人 API 凭据，禁止作为安装包输入文件。

## 工具坑记录

- **不要在 Git Bash 里调用 AutoHotkey 校验语法**：MSYS 会把 `/ErrorStdOut`、`/validate`
  这类开关参数当成 Unix 路径转换成 `C:/Program Files/Git/ErrorStdOut`，AHK 报
  "Script file not found"；且管道里 `head` 的 exit 0 会造成「校验通过」的假阳性。
  正确做法是用 PowerShell 原生调用并显式等待退出码：

  ```powershell
  $p = Start-Process "D:\utils\AutoHotkey\v2\AutoHotkey64.exe" -ArgumentList `
    '/ErrorStdOut','/validate','capslock_p2.ahk' -Wait -PassThru -RedirectStandardOutput out.txt
  $p.ExitCode   # 0 = 通过，2 = 语法错误（错误详情在 out.txt）
  ```

- **`/validate` 不输出 `#Warn` 警告**（如函数内未声明 global 就赋值），只有实际重载脚本才暴露。
- **AHK 的 `NumPut` 只收纯数字**：传入 `ComValue`（如 `ComObjArray` 迭代出的 VT_UI1 包装）或
  String 会抛 "Invalid parameter(s)"；而且 VT_UI1 的 ComValue 参与 `+ 0` 这类算术会直接抛
  "Expected a Number"。COM/SafeArray 数据入缓存前先转成纯数值（`NumGet` 读出即是），
  不要把 ComValue 存进数组再消费。WebView2 面板回调内不要同步 `await2` 创建另一个
  WebView2（会 15 秒超时），用 `SetTimer(fn, -1)` 延迟到回调外。

