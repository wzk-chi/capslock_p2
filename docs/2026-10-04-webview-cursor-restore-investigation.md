# WebView2 鼠标指针恢复调查记录

记录日期：2026-10-04；更新：2026-10-05

状态：2026-10-04 至 2026-10-05 的移除方案是历史试验。当前 `AGENTS.md` 要求八个交互页发送节流后的鼠标移动消息，并在宿主显示面板及收到消息时恢复系统指针；实现已统一到 `pages/panel.js` 和 `lib/shared/panelHost.ahk`，实际运行表现仍待确认。

## 1. 现状

Windows 的“键入时隐藏指针”设置会在键盘输入后隐藏系统指针。此前用户手动试验期间移除了页面鼠标移动恢复消息和应用级 `ShowSystemCursor()` 调用，并反馈移除鼠标移动消息后指针仍正常。该反馈是历史试验结果，不代表所有面板路径都已验证。按当前项目约定，交互页面通过共享 `panel.js` 以约 80ms 节流发送恢复消息；宿主在共享面板显示/激活及收到该消息时调用 `ShowSystemCursor()`。实际按键后各面板的指针可见状态仍待确认。

页面使用 Chromium/WebView2 处理 Web 内容输入，这可以解释为何 WebView2 面板的自动恢复表现可能与原生编辑控件不同；但这本身不能证明 Chromium 是隐藏指针的原因。应区分 Windows 隐藏指针的触发条件和隐藏后没有自动恢复的情况。

## 2. `ShowSystemCursor()` 的计数边界与修正

原 `ShowSystemCursor()` 实现位于 `lib/features/windows.ahk`。`ShowCursor(TRUE)` 会增加显示计数；显示计数达到零时指针已可见。原实现返回值只判断小于零的情况，其余都调用 `ShowCursor(FALSE)` 平衡。

根据 Windows `ShowCursor` API 文档，显示计数大于或等于零时指针可见。因此存在以下边界：

1. 调用前显示计数为 `-1`，指针隐藏。
2. `ShowCursor(TRUE)` 将计数加到 `0`，返回 `0`，此时指针已可见。
3. 原代码将 `0` 归入平衡分支，再调用 `ShowCursor(FALSE)`，计数回到 `-1`，撤销了这次显示。

曾修正为：返回值小于零时继续增加到非负；返回值大于零时调用一次 `ShowCursor(FALSE)` 平衡计数；返回值恰为零时保持不变。该实现现位于 `lib/app/core.ahk` 的 `ShowSystemCursor()`，边界行为仍是当前共享实现要保留的约定。运行日志确认过 `first=0 final=0` 的边界。调查期间加入的计数日志和 `GetCursorInfo` 查询已移除。

```ahk
count := DllCall("ShowCursor", "Int", 1)
if count < 0 {
    while count < 0
        count := DllCall("ShowCursor", "Int", 1)
} else if count > 0 {
    DllCall("ShowCursor", "Int", -1)
}
```

2026-10-05 13:19:01 的运行日志记录了 `ShowSystemCursor recovered display counter first=0 final=0`。这确认实际运行中命中了零值边界；修正后计数保持为 `0`。旧逻辑会在此处再减一次，将计数降到 `-1`。当前日志没有 `cursor still hidden` 记录，无法确认该次调用后的 `GetCursorInfo` 可见标志。这个边界确实会发生，但仍不能证明它解释了所有指针隐藏现象；其他复现仍需结合计数和指针状态判断。

## 3. 处理方向

- 保留 Windows 的系统级用户偏好，不默认通过 `SPI_SETMOUSEVANISH` 修改全局设置；该设置会影响其他应用。
- 当前实现遵循 `AGENTS.md` 的共享恢复约定，不据单次历史试验删除鼠标消息或显示调用。若以后要变更该约定，应先更新项目规则，并对所有交互页、激活路径与 Windows 指针设置进行统一验证。

## 4. 参考

- Windows API：[`ShowCursor`](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-showcursor)。
- 面板生命周期：`lib/shared/panelHost.ahk`。
