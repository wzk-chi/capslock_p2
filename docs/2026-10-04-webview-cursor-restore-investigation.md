# WebView2 鼠标指针恢复调查记录

日期：2026-10-04

状态：问题分析记录；代码疑点尚未修正或运行验证。

## 1. 现状

Windows 的“键入时隐藏指针”设置会在键盘输入后隐藏系统指针。项目目前在面板显示时调用 AHK 的 `ShowSystemCursor()`；部分页面还以约 80 毫秒节流的 `mousemove` 事件向宿主发送 `cursorMove`，由 AHK 再调用 `ShowSystemCursor()`。

页面使用 Chromium/WebView2 处理 Web 内容输入，这可以解释为何 WebView2 面板的自动恢复表现可能与原生编辑控件不同；但这本身不能证明 Chromium 是隐藏指针的原因。应区分 Windows 隐藏指针的触发条件和隐藏后没有自动恢复的情况。

## 2. `ShowSystemCursor()` 的计数边界疑点

当前实现位于 `lib/features/windows.ahk`。其逻辑先调用一次 `ShowCursor(TRUE)`；返回值小于零时继续增加计数，否则调用 `ShowCursor(FALSE)` 抵消刚才的增加。

根据 Windows `ShowCursor` API 文档，显示计数大于或等于零时指针可见。因此存在以下边界：

1. 调用前显示计数为 `-1`，指针隐藏。
2. `ShowCursor(TRUE)` 将计数加到 `0`，返回 `0`，此时指针已可见。
3. 当前代码将 `0` 归入“原本可见”的分支，再调用 `ShowCursor(FALSE)`，计数回到 `-1`，撤销了这次显示。

建议的计数处理原则是：返回值小于零时继续增加到非负；返回值大于零时才调用一次 `ShowCursor(FALSE)` 平衡计数；返回值恰为零时保持不变。

```ahk
count := DllCall("ShowCursor", "Int", 1)
if count < 0 {
    while count < 0
        count := DllCall("ShowCursor", "Int", 1)
} else if count > 0 {
    DllCall("ShowCursor", "Int", -1)
}
```

这个边界是代码层面的可疑点，不足以证明它就是当前所有指针隐藏现象的根因；尤其尚未确认 Windows 的“键入时隐藏指针”是否会把 `ShowCursor` 计数改成 `-1`。修正前后仍需在允许运行程序时验证实际行为。

## 3. 处理方向

- 保留 Windows 的系统级用户偏好，不默认通过 `SPI_SETMOUSEVANISH` 修改全局设置；该设置会影响其他应用。
- 优先检查并修正 `ShowSystemCursor()` 的零值边界，再观察现有页面鼠标移动恢复机制是否仍有遗漏。
- 如需减少重复代码，可将页面的 `cursorMove` 上报和宿主恢复处理收进共享实现；这属于结构整理，不等于消除 Windows 的隐藏策略。
- 若之后仍需判断系统隐藏状态与应用显示计数，可在人工验证时分别观察 `ShowCursor` 返回计数和 `GetCursorInfo` 的显示状态，避免仅凭页面事件推断原因。

## 4. 参考

- Windows API：[`ShowCursor`](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-showcursor)。
- 项目实现：`lib/features/windows.ahk` 的 `ShowSystemCursor()`。
- WebView2 页面事件：`pages/chat.html`、`pages/dictionary.html`、`pages/everything.html`、`pages/translate.html`、`pages/clipboard-history.html`、`pages/qbar-notes.html`。
