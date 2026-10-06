; Shortcut recorder: InputHook lifecycle and WebView result delivery.

global SettingsShortcutHook := 0
global SettingsShortcutTarget := ""
global SettingsShortcutCaptureGeneration := 0
global SettingsShortcutStartTimer := 0
global SettingsShortcutCapturePending := false
global SettingsShortcutCaptureId := 0

SettingsQueueShortcutCapture(message) {
    global SettingsShortcutCaptureGeneration, SettingsShortcutStartTimer
    global SettingsShortcutCapturePending, SettingsShortcutCaptureId
    msg := LLMMessageParse(message)
    captureIdValid := false
    captureId := LLMMsgNumber(msg, "captureId", &captureIdValid, 0, true)
    if !captureIdValid || captureId < 1
        return
    criticalState := Critical("On")
    try {
        SettingsStopShortcutCapture()
        SettingsShortcutCaptureGeneration += 1
        generation := SettingsShortcutCaptureGeneration
        SettingsShortcutCaptureId := captureId
        SettingsShortcutCapturePending := true
        timer := SettingsStartShortcutCapture.Bind(message, generation, captureId)
        SettingsShortcutStartTimer := timer
        SetTimer(timer, -1)
    } finally {
        Critical(criticalState)
    }
}

SettingsStartShortcutCapture(message, generation, captureId, *) {
    global SettingsShortcutHook, SettingsShortcutTarget, SettingsShortcutCaptureGeneration
    global SettingsShortcutStartTimer, SettingsShortcutCapturePending
    global SettingsVisible, SettingsHost
    if generation != SettingsShortcutCaptureGeneration || !SettingsShortcutCapturePending
        return
    msg := LLMMessageParse(message)
    target := LLMMsgField(msg, "key")
    if target = "" {
        if generation = SettingsShortcutCaptureGeneration
            SettingsStopShortcutCapture(generation, captureId)
        return
    }
    try {
        hook := InputHook("L0")
        hook.KeyOpt("{All}", "+NS")
        hook.OnKeyDown := SettingsShortcutKeyDown.Bind(generation)
    } catch as captureError {
        if generation = SettingsShortcutCaptureGeneration {
            SettingsSendShortcutCaptureFailure(captureId, generation)
            SettingsStopShortcutCapture(generation, captureId)
            DebugLog("Shortcut capture initialization failed errorType=" . Type(captureError))
        }
        return
    }
    criticalState := Critical("On")
    started := false
    startErrorType := ""
    try {
        if generation = SettingsShortcutCaptureGeneration
            && SettingsShortcutCapturePending && SettingsVisible
            && IsObject(SettingsHost) && PanelHostPageReady(SettingsHost) {
            SettingsShortcutStartTimer := 0
            SettingsShortcutTarget := target
            SettingsShortcutHook := hook
            try {
                hook.Start()
                SettingsShortcutCapturePending := false
                started := true
            } catch as captureError {
                SettingsShortcutHook := 0
                SettingsShortcutTarget := ""
                SettingsShortcutCapturePending := false
                startErrorType := Type(captureError)
            }
        } else if generation = SettingsShortcutCaptureGeneration
            SettingsShortcutCapturePending := false
    } finally {
        Critical(criticalState)
    }
    if !started {
        try hook.Stop()
        if startErrorType != "" {
            SettingsSendShortcutCaptureFailure(captureId, generation)
            SettingsStopShortcutCapture(generation, captureId)
            DebugLog("Shortcut capture start failed errorType=" . startErrorType)
        }
    }
}

SettingsStopShortcutCapture(expectedGeneration := 0, expectedCaptureId := 0, *) {
    global SettingsShortcutHook, SettingsShortcutTarget, SettingsShortcutCaptureGeneration
    global SettingsShortcutStartTimer, SettingsShortcutCapturePending, SettingsShortcutCaptureId
    criticalState := Critical("On")
    try {
        if expectedGeneration && expectedGeneration != SettingsShortcutCaptureGeneration
            return false
        if expectedCaptureId && expectedCaptureId != SettingsShortcutCaptureId
            return false
        SettingsShortcutCaptureGeneration += 1
        timer := SettingsShortcutStartTimer
        SettingsShortcutStartTimer := 0
        SettingsShortcutCapturePending := false
        SettingsShortcutCaptureId := 0
        if IsObject(timer)
            SetTimer(timer, 0)
        hook := SettingsShortcutHook
        SettingsShortcutHook := 0
        SettingsShortcutTarget := ""
    } finally {
        Critical(criticalState)
    }
    if IsObject(hook)
        try hook.Stop()
    return true
}

SettingsStopShortcutCaptureMessage(message) {
    msg := LLMMessageParse(message)
    captureIdValid := false
    captureId := LLMMsgNumber(msg, "captureId", &captureIdValid, 0, true)
    if captureIdValid && captureId > 0
        SettingsStopShortcutCapture(0, captureId)
}

SettingsShortcutKeyDown(generation, hook, vk, sc) {
    global SettingsShortcutHook, SettingsShortcutTarget, SettingsShortcutCaptureGeneration
    global SettingsShortcutCaptureId
    if generation != SettingsShortcutCaptureGeneration || !IsObject(SettingsShortcutHook)
        return
    if SettingsShortcutIsModifier(vk)
        return
    key := SettingsShortcutKeyInfo(vk, sc)
    if !IsObject(key)
        return
    modifiers := SettingsShortcutModifierInfo()
    target := SettingsShortcutTarget
    captureId := SettingsShortcutCaptureId
    value := modifiers["value"] . key["value"]
    label := modifiers["label"]
    if label != ""
        label .= "+"
    label .= key["label"]
    SettingsShortcutHook := 0
    SettingsShortcutTarget := ""
    try hook.Stop()
    SetTimer(SettingsSendShortcutCapture.Bind(
        generation, captureId, target, value, label), -1)
}

SettingsShortcutIsModifier(vk) {
    return vk = 0x10 || vk = 0xA0 || vk = 0xA1
        || vk = 0x11 || vk = 0xA2 || vk = 0xA3
        || vk = 0x12 || vk = 0xA4 || vk = 0xA5
        || vk = 0x5B || vk = 0x5C
}

SettingsShortcutModifierInfo() {
    ctrl := GetKeyState("Ctrl", "P")
    alt := GetKeyState("Alt", "P")
    shift := GetKeyState("Shift", "P")
    win := GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
    value := (ctrl ? "^" : "") . (alt ? "!" : "") . (shift ? "+" : "") . (win ? "#" : "")
    label := (ctrl ? "Ctrl" : "")
    if alt
        label .= (label = "" ? "" : "+") . "Alt"
    if shift
        label .= (label = "" ? "" : "+") . "Shift"
    if win
        label .= (label = "" ? "" : "+") . "Win"
    return Map("value", value, "label", label)
}

SettingsShortcutKeyInfo(vk, sc) {
    keyName := ""
    try keyName := GetKeyName(Format("sc{:03X}", sc))
    if keyName = ""
        try keyName := GetKeyName(Format("vk{:02X}", vk))
    if keyName = ""
        return 0
    normalized := StrLower(keyName)
    if normalized = "space"
        return Map("value", "{Space}", "label", "Space")
    if normalized = "enter" || normalized = "numpadenter"
        return Map("value", normalized = "enter" ? "{Enter}" : "{NumpadEnter}",
            "label", normalized = "enter" ? "Enter" : "Num Enter")
    if normalized = "tab"
        return Map("value", "{Tab}", "label", "Tab")
    if normalized = "escape" || normalized = "esc"
        return Map("value", "{Esc}", "label", "Esc")
    if normalized = "backspace"
        return Map("value", "{Backspace}", "label", "Backspace")
    if normalized = "delete" || normalized = "del"
        return Map("value", "{Delete}", "label", "Delete")
    if normalized = "insert" || normalized = "ins"
        return Map("value", "{Insert}", "label", "Insert")
    if normalized = "home"
        return Map("value", "{Home}", "label", "Home")
    if normalized = "end"
        return Map("value", "{End}", "label", "End")
    if normalized = "pageup" || normalized = "pgup"
        return Map("value", "{PgUp}", "label", "PageUp")
    if normalized = "pagedown" || normalized = "pgdn"
        return Map("value", "{PgDn}", "label", "PageDown")
    if normalized = "up" || normalized = "down" || normalized = "left" || normalized = "right"
        return Map("value", "{" . keyName . "}", "label", keyName)
    if normalized = "capslock"
        return Map("value", "{CapsLock}", "label", "CapsLock")
    if normalized = "printscreen"
        return Map("value", "{PrintScreen}", "label", "PrintScreen")
    if normalized = "scrolllock"
        return Map("value", "{ScrollLock}", "label", "ScrollLock")
    if normalized = "pause"
        return Map("value", "{Pause}", "label", "Pause")
    if normalized = "appskey" || normalized = "contextmenu"
        return Map("value", "{AppsKey}", "label", "ContextMenu")
    if RegExMatch(keyName, "i)^F(?:[1-9]|1[0-9]|2[0-4])$")
        return Map("value", "{" . keyName . "}", "label", keyName)
    if RegExMatch(keyName, "i)^Numpad")
        return Map("value", "{" . keyName . "}", "label", "Num " . SubStr(keyName, 7))
    if StrLen(keyName) = 1 {
        if RegExMatch(keyName, "^[A-Za-z0-9]$")
            return Map("value", StrLower(keyName), "label", StrUpper(keyName))
        return Map("value", "{" . keyName . "}", "label", keyName)
    }
    return Map("value", "{" . keyName . "}", "label", keyName)
}

SettingsSendShortcutCapture(generation, captureId, target, value, label) {
    global SettingsHost
    global SettingsShortcutCaptureGeneration, SettingsShortcutCaptureId, SettingsVisible
    if target = ""
        return
    criticalState := Critical("On")
    try {
        if generation != SettingsShortcutCaptureGeneration
            || captureId != SettingsShortcutCaptureId || !SettingsVisible
            || !IsObject(SettingsHost) || !PanelHostPageReady(SettingsHost)
            return
        payload := Map("key", target, "captureId", captureId,
            "value", value, "label", label)
        PanelHostExecute(SettingsHost, "window.receiveShortcutCapture(" . JSON.stringify(payload, 0) . ");")
    } finally {
        Critical(criticalState)
    }
}

SettingsSendShortcutCaptureFailure(captureId, generation) {
    global SettingsHost, SettingsShortcutCaptureGeneration, SettingsShortcutCaptureId
    global SettingsVisible
    criticalState := Critical("On")
    try {
        if generation != SettingsShortcutCaptureGeneration
            || captureId != SettingsShortcutCaptureId || !SettingsVisible
            || !IsObject(SettingsHost) || !PanelHostPageReady(SettingsHost)
            return
        payload := Map("captureId", captureId)
        PanelHostExecute(SettingsHost,
            "window.shortcutCaptureFailed(" . JSON.stringify(payload, 0) . ");")
    } finally {
        Critical(criticalState)
    }
}
