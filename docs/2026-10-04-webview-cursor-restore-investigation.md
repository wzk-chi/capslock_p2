# WebView2 鼠标指针恢复调查记录

记录日期：2026-10-04；更新：2026-10-05

状态：计数边界已修正并命中运行日志；鼠标移动恢复逻辑已统一；指针状态仍待验证。

## 1. 现状

Windows 的“键入时隐藏指针”设置会在键盘输入后隐藏系统指针。面板显示时会调用 AHK 的 `ShowSystemCursor()`；所有交互式 PanelHost 页面共用 `pages/cursor.js`，以约 80 毫秒节流监听页面鼠标移动，再由 `lib/shared/panelHost.ahk` 统一调用 `ShowSystemCursor()`。页面不再各自实现监听和节流，且没有轮询。

页面使用 Chromium/WebView2 处理 Web 内容输入，这可以解释为何 WebView2 面板的自动恢复表现可能与原生编辑控件不同；但这本身不能证明 Chromium 是隐藏指针的原因。应区分 Windows 隐藏指针的触发条件和隐藏后没有自动恢复的情况。

## 2. `ShowSystemCursor()` 的计数边界与修正

实现位于 `lib/features/windows.ahk`。`ShowCursor(TRUE)` 会增加显示计数；显示计数达到零时指针已可见。原实现返回值只判断小于零的情况，其余都调用 `ShowCursor(FALSE)` 平衡。

根据 Windows `ShowCursor` API 文档，显示计数大于或等于零时指针可见。因此存在以下边界：

1. 调用前显示计数为 `-1`，指针隐藏。
2. `ShowCursor(TRUE)` 将计数加到 `0`，返回 `0`，此时指针已可见。
3. 原代码将 `0` 归入平衡分支，再调用 `ShowCursor(FALSE)`，计数回到 `-1`，撤销了这次显示。

现已修正为：返回值小于零时继续增加到非负；返回值大于零时才调用一次 `ShowCursor(FALSE)` 平衡计数，并读取平衡后的计数；返回值恰为零时保持不变。日志中没有指针状态记录，因此新增了低频诊断：只有首次返回值小于或等于零时才记录计数恢复；`GetCursorInfo` 检查后若指针仍隐藏，则每个连续隐藏阶段只记录一次，检测到指针显示后才重置记录标记。不会为每次鼠标移动写日志。

```ahk
count := DllCall("ShowCursor", "Int", 1)
firstCount := count
if count < 0 {
    while count < 0
        count := DllCall("ShowCursor", "Int", 1)
} else if count > 0 {
    count := DllCall("ShowCursor", "Int", -1)
}
if firstCount <= 0
    DebugLog("ShowSystemCursor recovered display counter first=" . firstCount
        . " final=" . count)
```

2026-10-05 13:19:01 的运行日志记录了 `ShowSystemCursor recovered display counter first=0 final=0`。这确认实际运行中命中了零值边界；修正后计数保持为 `0`。旧逻辑会在此处再减一次，将计数降到 `-1`。当前日志没有 `cursor still hidden` 记录，无法确认该次调用后的 `GetCursorInfo` 可见标志。这个边界确实会发生，但仍不能证明它解释了所有指针隐藏现象；其他复现仍需结合计数和指针状态判断。

## 3. 处理方向

- 保留 Windows 的系统级用户偏好，不默认通过 `SPI_SETMOUSEVANISH` 修改全局设置；该设置会影响其他应用。
- 观察现有页面鼠标移动恢复机制是否仍有遗漏；若仍复现，结合恢复计数日志和 `GetCursorInfo` 判断系统隐藏状态与显示计数。
- 页面事件监听、节流和宿主恢复已统一到 `pages/cursor.js` 与 `lib/shared/panelHost.ahk`；这不会关闭 Windows 的隐藏策略。

## 4. 参考

- Windows API：[`ShowCursor`](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-showcursor)。
- 项目实现：`lib/features/windows.ahk` 的 `ShowSystemCursor()`。
- 页面事件：`pages/cursor.js`；宿主统一分发：`lib/shared/panelHost.ahk`。
