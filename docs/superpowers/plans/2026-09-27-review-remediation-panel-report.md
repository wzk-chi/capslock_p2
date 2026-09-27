# PanelHost、窗口绑定与共享实现执行报告

日期：2026-09-27

范围：执行整改计划中的 PanelHost 生命周期收敛、窗口绑定消息/元数据、共享编码与剪贴板所有权、qbarDebug 删除及退役文件文档同步。未运行 AHK、JavaScript、Everything、诊断脚本、测试、编译器或安装器；未读取个人 `capslock_p2.ini`。

## 已完成的改动

### PanelHost 生命周期

- `lib/panelHost.ahk` 现在保存导航和 Web 消息事件 token，并在创建失败或销毁前注销事件；移除了只写不读的 `focusTimer` 字段和 `PanelHostEnsure()` 中无用的局部回调变量。
- 导航完成后由 `PanelHostNavigationCompleted()` 单次写入 `pageReady`，再以 `(host, sender, args)` 调用功能回调。
- 新增只读入口 `PanelHostGui()`、`PanelHostPageReady()`、`PanelHostWindowActive()`；焦点监视器仅保存用于取消的回调。
- AI 问答、翻译、词典和 qbar 已移除 GUI/controller/WebView/pageReady/focusTimer 镜像全局状态及 `SyncHost()`，保留各自的显示、请求、历史、焦点与 qbar 开闭状态。`keys.ahk` 改用 `AiChatIsActive()`、`LLMTranslateIsActive()` 和 `DictionaryIsActive()`。
- 设置页仍保留 `SettingsSyncHost()` 镜像状态，因为它与本轮并行的设置保存改造重叠，未在本子任务中改写；它的导航回调已适配新签名。

### 窗口绑定

- `lib/windows.ahk` 新增严格的 `WindowBindingNumber()`（仅 1–10）和 `WindowBindingModes()`（模式 1–3 的标签及描述）。`WindowBindingDisplay()` 从该元数据读取，并对未绑定返回独立记录。
- `BindingTap()`、`CompletePendingBinding()`、`BindWindowFromActive()`、`SaveWindowBinding()`、`activateWinAction()` 与 `winsSort()` 都先校验编号；键盘动作不再先进行宽松的 `+ 0` 转换。
- 删除未被读取的 `GettingWinInfo` 状态。现有 type-2 清理、type-3 刷新、持久化字段和 10 号绑定的序列化格式均未改变。
- 设置快照由主线加入 `bindingModes`；页面以宿主元数据渲染模式，并把持久化编号 10 显示为 `CapsLock + 0`。无绑定记录仍显示“未绑定”，下拉框仍代表下一次捕获的模式。

### 公共实现与 qbar

- `lib/crypto.ahk` 新增 `UrlEncodeUtf8()`；qbar 搜索 URL 替换和有道表单统一使用它。Youdao 签名改用已有 `CryptoSha256Hex()`，已移除重复 BCrypt SHA-256 和 URL 编码函数。
- `RebuildHotStringPattern()` 在构建时按短键去重并稳定地按长度倒序排列；初始化中的重复 `HotStringInit` 定时器及包装函数已删除。
- `TabHotStringAction()` 不再在“已有选区”路径重复持有剪贴板快照。无选区路径和 `SetClipboardText()` 都用 `try/finally` 恢复之前的监听挂起状态，并仅在剪贴板序号仍归本次操作时恢复旧剪贴板，避免覆盖用户在操作期间的新复制内容。
- TabHotString 解码已由配置层唯一承担，`core.ahk` 中的旧 `HotStringUnescape()` 已删除。
- `pages/qbar.html` 删除 qbarDebug、querySerial、deferredQuery 和组合输入调试消息；IME 组合期间仍抑制查询，compositionend 后发送一次查询。`lib/qbar_panel.ahk` 同时删除 host `debug` 消息分支。

### 退役文件与文档

- 已按用户明确授权删除：`lib/math.ahk`、`lib/jsEval.ahk`、`loadScript/`、`pages/settings.js`、`tools/ini_parse_check.ahk`、`tools/ini_write_check.ahk`。
- `docs/architecture.md`、`docs/packaging.md`、旧设计说明、整改计划及 Inno Setup 注释已同步为“已授权删除”，并说明这些文件不属于发布或运行时资源。

## 静态核对

- `git diff --check` 通过；输出仅包含 Git 的行尾转换提示，没有空白错误。
- 搜索确认不存在 `qbarDebug`、`deferredQuery`、`querySerial`、qbar host `debug` 分支、`BCryptSha256Hex`、`YoudaoUrlEncode`、`QbarUrlEncode` 或 `HotStringInit` 的活动引用。
- 搜索确认 AI、翻译、词典和 qbar 不再保留镜像 GUI/controller/WebView/pageReady/focusTimer 或 `SyncHost()`；公共 `CreateControllerAsync` 与 `ExecuteScriptAsync` 仅在 `panelHost.ahk`。
- 搜索确认所有功能导航回调已采用 `(host, sender, args)`；设置页也已适配该签名。
- 搜索确认窗口绑定数字入口均经过 `WindowBindingNumber()`，模式文字由 `WindowBindingModes()` 提供给设置快照；页面只消费快照元数据。
- 确认授权删除目标均不存在，`loadScript/` 空目录也已移除；未改动 `capslock-plus/`。

## 未做的运行时验证

依项目约束未启动 AHK 或网页，因此 WebView2 的事件 token 注销、面板焦点行为、IME 组合输入、剪贴板序号竞争和窗口绑定的实际激活流程均只做了静态审阅，仍需在允许运行的环境中手工验证。
