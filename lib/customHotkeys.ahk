; User-defined global shortcut remapping.

global CustomHotkeyTriggers := []

RegisterCustomHotkeys() {
    global CustomHotkeyTriggers
    HotIf(CustomHotkeyActive)
    try {
        for trigger in CustomHotkeyTriggers
            try Hotkey(trigger, "Off")
        CustomHotkeyTriggers := []

        for trigger, action in ConfigSection("CustomHotkey") {
            trigger := Trim(String(trigger))
            action := Trim(String(action))
            if trigger = "" || action = ""
                continue
            try {
                Hotkey(trigger, MakeCustomHotkeyHandler(action))
                CustomHotkeyTriggers.Push(trigger)
            } catch as hotkeyError {
                DebugLog("Custom hotkey skipped triggerLength=" . StrLen(trigger)
                    . " actionLength=" . StrLen(action) . " error=" . hotkeyError.Message)
            }
        }
    } finally {
        HotIf()
    }
    DebugLog("Custom hotkeys registered count=" . CustomHotkeyTriggers.Length)
}

CustomHotkeyActive(*) {
    global CapsLockHeld
    return !CapsLockHeld
}

MakeCustomHotkeyHandler(action) {
    return (*) => CustomHotkeySend(action)
}

CustomHotkeySend(action) {
    if Trim(String(action)) = ""
        return
    try SendInput(action)
    catch as sendError
        DebugLog("Custom hotkey send failed actionLength=" . StrLen(String(action))
            . " error=" . sendError.Message)
}
