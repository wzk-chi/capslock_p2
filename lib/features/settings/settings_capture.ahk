; Shortcut recorder: InputHook lifecycle and WebView result delivery.

global SettingsShortcutHook := 0
global SettingsShortcutTarget := ""
global SettingsShortcutCaptureGeneration := 0
global SettingsShortcutStartTimer := 0
global SettingsShortcutCapturePending := false
global SettingsShortcutCaptureId := 0
global SettingsShortcutCaptureMode := "shortcut"
global SettingsShortcutCaptureFinishing := false
global SettingsShortcutCaptureNoticeShown := false
global SettingsShortcutCandidate := 0
global SettingsShortcutDrainHook := 0
global SettingsShortcutDrainKeys := Map()
global SettingsShortcutPressedKeys := Map()
global SettingsShortcutInitialHeldKeys := Map()
global SettingsShortcutMousePresses := Map()

SettingsQueueShortcutCapture(message) {
    global SettingsShortcutCaptureGeneration, SettingsShortcutStartTimer
    global SettingsShortcutCapturePending, SettingsShortcutCaptureId
    global SettingsShortcutCaptureMode, SettingsShortcutCaptureFinishing
    global SettingsShortcutCaptureNoticeShown, SettingsShortcutCandidate
    global SettingsShortcutPressedKeys, SettingsShortcutInitialHeldKeys
    msg := LLMMessageParse(message)
    captureId := LLMMsgNumber(msg, "captureId", &idValid, 0, true)
    if !idValid || captureId < 1
        return
    mode := StrLower(LLMMsgField(msg, "mode"))
    target := LLMMsgField(msg, "key")
    if (target = "singleInput") != (mode = "singleinput")
        return
    criticalState := Critical("On")
    repeatPressCancelled := false
    try {
        SettingsStopShortcutCapture()
        SettingsShortcutCaptureGeneration += 1
        generation := SettingsShortcutCaptureGeneration
        SettingsShortcutCaptureId := captureId
        SettingsShortcutCapturePending := true
        SettingsShortcutCaptureMode := mode = "singleinput" ? "singleInput" : "shortcut"
        SettingsShortcutCaptureFinishing := false
        SettingsShortcutCaptureNoticeShown := false
        SettingsShortcutCandidate := 0
        SettingsShortcutPressedKeys := Map()
        SettingsShortcutInitialHeldKeys := Map()
        repeatPressCancelled := KeyRepeatCancelCurrentPress()
        timer := SettingsStartShortcutCapture.Bind(message, generation, captureId)
        SettingsShortcutStartTimer := timer
        SetTimer(timer, -1)
    } finally {
        Critical(criticalState)
    }
    if repeatPressCancelled
        KeyRepeatPublishStatus()
}

SettingsStartShortcutCapture(message, generation, captureId, *) {
    global SettingsShortcutHook, SettingsShortcutTarget, SettingsShortcutCaptureGeneration
    global SettingsShortcutStartTimer, SettingsShortcutCapturePending
    global SettingsVisible, SettingsHost
    global SettingsShortcutDrainHook, SettingsShortcutInitialHeldKeys, SettingsShortcutCaptureMode
    if generation != SettingsShortcutCaptureGeneration || !SettingsShortcutCapturePending
        return
    if IsObject(SettingsShortcutDrainHook) {
        SettingsShortcutStartTimer := SettingsStartShortcutCapture.Bind(
            message, generation, captureId)
        return
    }
    msg := LLMMessageParse(message)
    if !SettingsIsEditMessage(msg)
        return
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
        hook.OnKeyUp := SettingsShortcutKeyUp.Bind(generation)
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
                if SettingsShortcutCaptureMode = "singleInput" {
                    SettingsShortcutInitialHeldKeys := SettingsShortcutSnapshotHeldKeys()
                    for vk in SettingsShortcutInitialHeldKeys
                        if vk > 6
                            try hook.KeyOpt("{" . Format("vk{:02X}", vk) . "}", "+V")
                }
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
    global SettingsShortcutCaptureMode, SettingsShortcutCaptureFinishing
    global SettingsShortcutCaptureNoticeShown, SettingsShortcutCandidate
    global SettingsShortcutMousePresses, SettingsShortcutPressedKeys, SettingsShortcutInitialHeldKeys
    criticalState := Critical("On")
    try {
        if (expectedGeneration && expectedGeneration != SettingsShortcutCaptureGeneration)
            || (expectedCaptureId && expectedCaptureId != SettingsShortcutCaptureId)
            return false
        hook := SettingsShortcutHook
        draining := IsObject(hook) && SettingsShortcutCaptureMode = "singleInput"
            && SettingsShortcutPrepareHookDrain(hook)
        SettingsShortcutCaptureGeneration += 1
        timer := SettingsShortcutStartTimer
        SettingsShortcutStartTimer := 0
        SettingsShortcutCapturePending := false
        SettingsShortcutCaptureId := 0
        SettingsShortcutCaptureMode := "shortcut"
        SettingsShortcutCaptureFinishing := false
        SettingsShortcutCaptureNoticeShown := false
        SettingsShortcutCandidate := 0
        SettingsShortcutPressedKeys := Map()
        SettingsShortcutInitialHeldKeys := Map()
        heldMousePresses := Map()
        for button, press in SettingsShortcutMousePresses
            if GetKeyState(button, "P")
                heldMousePresses[button] := press
        SettingsShortcutMousePresses := heldMousePresses
        if IsObject(timer)
            SetTimer(timer, 0)
        if IsObject(hook) && !draining
            try hook.Stop()
        SettingsShortcutHook := 0
        SettingsShortcutTarget := ""
    } finally {
        Critical(criticalState)
    }
    return true
}

SettingsShortcutCaptureShutdown() {
    global SettingsShortcutStartTimer, SettingsShortcutCaptureGeneration
    global SettingsShortcutDrainHook, SettingsShortcutDrainKeys
    global SettingsShortcutMousePresses
    global SettingsShortcutPressedKeys, SettingsShortcutInitialHeldKeys
    global SettingsShortcutCaptureFinishing, SettingsShortcutCaptureNoticeShown
    SettingsStopShortcutCapture()
    criticalState := Critical("On")
    try {
        timer := SettingsShortcutStartTimer
        drainHook := SettingsShortcutDrainHook
        SettingsShortcutStartTimer := 0
        SettingsShortcutDrainHook := 0
        SettingsShortcutDrainKeys := Map()
        SettingsShortcutMousePresses := Map()
        SettingsShortcutPressedKeys := Map()
        SettingsShortcutInitialHeldKeys := Map()
        SettingsShortcutCaptureFinishing := false
        SettingsShortcutCaptureNoticeShown := false
        SettingsShortcutCaptureGeneration += 1
    } finally {
        Critical(criticalState)
    }
    if IsObject(timer)
        SetTimer(timer, 0)
    if IsObject(drainHook)
        try drainHook.Stop()
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
    global SettingsShortcutCaptureMode
    if generation != SettingsShortcutCaptureGeneration || !IsObject(SettingsShortcutHook)
        return
    if SettingsShortcutCaptureMode = "singleInput" {
        SettingsShortcutSingleKeyDown(generation, hook, vk, sc)
        return
    }
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

SettingsShortcutSingleKeyDown(generation, hook, vk, sc) {
    global SettingsShortcutCaptureGeneration, SettingsShortcutCaptureMode
    global SettingsShortcutCaptureFinishing, SettingsShortcutCandidate
    global SettingsShortcutPressedKeys, SettingsShortcutInitialHeldKeys
    if SettingsShortcutInitialHeldKeys.Has(vk)
        return
    SettingsShortcutPressedKeys[vk . ":" . sc] := {vk: vk, sc: sc}
    if generation != SettingsShortcutCaptureGeneration
        || SettingsShortcutCaptureMode != "singleInput" || SettingsShortcutCaptureFinishing
        || IsObject(SettingsShortcutCandidate) || !SettingsShortcutInitialInputsReleased()
        return
    if SettingsShortcutIsModifier(vk) || vk = 0x14 {
        SettingsShortcutRejectSingleInput()
        return
    }
    key := SettingsShortcutKeyInfo(vk, sc)
    if !IsObject(key)
        return
    value := ConfigNormalizeCustomHotkeyTrigger(key["value"])
    if !SettingsShortcutAcceptSingleInput(value, key["label"], "keyboard", vk, sc)
        SettingsShortcutRejectSingleInput()
}

SettingsShortcutKeyUp(generation, hook, vk, sc) {
    global SettingsShortcutCaptureGeneration, SettingsShortcutCaptureMode
    global SettingsShortcutCaptureFinishing, SettingsShortcutCandidate, SettingsShortcutPressedKeys
    if generation != SettingsShortcutCaptureGeneration {
        SettingsShortcutFinishDrain(hook, vk, sc)
        return
    }
    if SettingsShortcutReleaseInitialKey(vk, hook)
        return
    keyId := vk . ":" . sc
    if SettingsShortcutPressedKeys.Has(keyId)
        SettingsShortcutPressedKeys.Delete(keyId)
    candidate := SettingsShortcutCandidate
    if SettingsShortcutCaptureMode != "singleInput" || SettingsShortcutCaptureFinishing
        || !IsObject(candidate) || candidate.kind != "keyboard"
        || vk != candidate.vk || sc != candidate.sc
        return
    if SettingsShortcutInputModifiersDown() {
        SettingsShortcutResetCandidate()
        SettingsShortcutRejectSingleInput()
    } else
        SettingsShortcutFinishCandidate()
}

SettingsShortcutFinishCandidate() {
    global SettingsShortcutCandidate, SettingsShortcutCaptureFinishing
    global SettingsShortcutCaptureGeneration, SettingsShortcutCaptureId, SettingsShortcutTarget
    criticalState := Critical("On")
    try {
        candidate := SettingsShortcutCandidate
        if !SettingsSingleInputCaptureActive() || SettingsShortcutCaptureFinishing
            || !IsObject(candidate)
            return
        SettingsShortcutCaptureFinishing := true
        SetTimer(SettingsSendShortcutCapture.Bind(SettingsShortcutCaptureGeneration,
            SettingsShortcutCaptureId, SettingsShortcutTarget, candidate.value, candidate.label), -1)
    } finally {
        Critical(criticalState)
    }
}

SettingsShortcutPrepareHookDrain(hook) {
    global SettingsShortcutDrainHook, SettingsShortcutDrainKeys, SettingsShortcutPressedKeys
    drainKeys := Map()
    for keyId, keyState in SettingsShortcutPressedKeys
        if GetKeyState(Format("vk{:02X}", keyState.vk), "P")
            drainKeys[keyId] := keyState
    if !drainKeys.Count
        return false
    SettingsShortcutDrainHook := hook
    SettingsShortcutDrainKeys := drainKeys
    hook.KeyOpt("{All}", "+V")
    for _, keyState in drainKeys
        hook.KeyOpt("{" . Format("vk{:02X}", keyState.vk) . "}", "+S")
    return true
}

SettingsShortcutRejectSingleInput() {
    global SettingsShortcutCaptureNoticeShown
    if SettingsShortcutCaptureNoticeShown
        return
    SettingsShortcutCaptureNoticeShown := true
    ShowMsg(LLMText("Release modifier keys and record one key or mouse action.",
        "请松开组合键，再录制单个按键或鼠标操作。"), 2200)
}

SettingsShortcutInputModifiersDown() {
    modifiers := SettingsShortcutModifierInfo()
    return modifiers["value"] != "" || GetKeyState("CapsLock", "P")
}

SettingsShortcutSnapshotHeldKeys() {
    heldKeys := Map()
    Loop 255 {
        vk := A_Index
        if DllCall("GetAsyncKeyState", "Int", vk, "Short") & 0x8000
            heldKeys[vk] := true
    }
    return heldKeys
}

SettingsShortcutReleaseInitialKey(vk, hook := 0) {
    global SettingsShortcutInitialHeldKeys, SettingsShortcutHook
    if !SettingsShortcutInitialHeldKeys.Has(vk)
        return false
    SettingsShortcutInitialHeldKeys.Delete(vk)
    if !IsObject(hook)
        hook := SettingsShortcutHook
    if vk > 6 && IsObject(hook)
        hook.KeyOpt("{" . Format("vk{:02X}", vk) . "}", "+S")
    return true
}

SettingsShortcutInitialInputsReleased() {
    global SettingsShortcutInitialHeldKeys
    released := []
    for vk in SettingsShortcutInitialHeldKeys
        if !(DllCall("GetAsyncKeyState", "Int", vk, "Short") & 0x8000)
            released.Push(vk)
    for vk in released
        SettingsShortcutReleaseInitialKey(vk)
    return !SettingsShortcutInitialHeldKeys.Count
}

SettingsShortcutCaptureActive() {
    global SettingsShortcutHook, SettingsShortcutCapturePending
    global SettingsShortcutCaptureFinishing, SettingsShortcutDrainHook
    return SettingsShortcutCapturePending || IsObject(SettingsShortcutHook)
        || SettingsShortcutCaptureFinishing || IsObject(SettingsShortcutDrainHook)
}

SettingsSingleInputCaptureActive() {
    global SettingsShortcutCaptureMode, SettingsShortcutHook, SettingsShortcutCapturePending
    return SettingsShortcutCaptureMode = "singleInput" && !SettingsShortcutCapturePending
        && IsObject(SettingsShortcutHook)
}

SettingsShortcutFinishDrain(hook, vk, sc) {
    global SettingsShortcutDrainHook, SettingsShortcutDrainKeys, SettingsShortcutStartTimer
    global SettingsShortcutCapturePending
    if !IsObject(SettingsShortcutDrainHook) || hook != SettingsShortcutDrainHook
        return
    keyId := vk . ":" . sc
    if !SettingsShortcutDrainKeys.Has(keyId)
        return
    criticalState := Critical("On")
    try {
        SettingsShortcutDrainKeys.Delete(keyId)
        if !GetKeyState(Format("vk{:02X}", vk), "P")
            hook.KeyOpt("{" . Format("vk{:02X}", vk) . "}", "+V")
        if !SettingsShortcutDrainKeys.Count {
            SettingsShortcutDrainHook := 0
            try hook.Stop()
            if SettingsShortcutCapturePending && IsObject(SettingsShortcutStartTimer) {
                timer := SettingsShortcutStartTimer
                SettingsShortcutStartTimer := 0
                SetTimer(timer, -1)
            }
        }
    } finally {
        Critical(criticalState)
    }
}

SettingsCaptureSingleInputMouse(msg) {
    global SettingsShortcutCaptureId
    captureId := LLMMsgNumber(msg, "captureId", &idValid, 0, true)
    if !idValid || captureId != SettingsShortcutCaptureId || !SettingsIsEditMessage(msg)
        || !SettingsSingleInputCaptureActive()
        return
    button := StrLower(LLMMsgField(msg, "button"))
    if !RegExMatch(button, "^(?:lbutton|rbutton|mbutton|xbutton[12])$")
        return
    phase := StrLower(LLMMsgField(msg, "phase"))
    switch phase {
        case "down":
            modified := LLMMsgBoolean(msg, "modified", &modifiedValid, false)
            if modifiedValid
                SettingsShortcutMouseDown(button, "page", captureId, modified)
        case "up", "cancel":
            SettingsShortcutMouseUp(button, phase = "cancel")
    }
}

SettingsShortcutAcceptSingleInput(value, label, kind, vk := 0, sc := 0) {
    global SettingsShortcutCandidate, SettingsShortcutCaptureFinishing
    if !SettingsSingleInputCaptureActive() || SettingsShortcutCaptureFinishing
        || IsObject(SettingsShortcutCandidate) || !SettingsShortcutInitialInputsReleased()
        || SettingsShortcutInputModifiersDown()
        return false
    if !ConfigValidateSingleInput(value, &normalized) || normalized != value
        return false
    SettingsShortcutCandidate := {value: normalized, label: label, kind: kind, vk: vk, sc: sc}
    return true
}

SettingsShortcutResetCandidate() {
    global SettingsShortcutCandidate
    SettingsShortcutCandidate := 0
}

SettingsSingleInputLabel(value) {
    static labels := Map("lbutton", "鼠标左键", "rbutton", "鼠标右键",
        "mbutton", "鼠标中键", "xbutton1", "鼠标侧键 1", "xbutton2", "鼠标侧键 2")
    key := StrLower(String(value))
    if labels.Has(key)
        return labels[key]
    if RegExMatch(key, "^f(?:[1-9]|1[0-9]|2[0-4])$")
        return StrUpper(key)
    return StrLen(key) = 1 ? StrUpper(key) : key
}

SettingsShortcutMouseOutsideSettingsActive(*) {
    return SettingsSingleInputCaptureActive() && !SettingsMouseIsSettingsHostUnderPointer()
}

SettingsShortcutMouseReleaseActive(button, *) {
    global SettingsShortcutMousePresses, SettingsShortcutCaptureId, SettingsShortcutInitialHeldKeys
    if SettingsShortcutMousePresses.Has(button) {
        press := SettingsShortcutMousePresses[button]
        return press.source = "native" || press.captureId != SettingsShortcutCaptureId
            || !SettingsSingleInputCaptureActive() || !SettingsMouseIsSettingsHostUnderPointer()
    }
    if !SettingsSingleInputCaptureActive() || SettingsMouseIsSettingsHostUnderPointer()
        return false
    static mouseVK := Map("lbutton", 1, "rbutton", 2, "mbutton", 4,
        "xbutton1", 5, "xbutton2", 6)
    return !SettingsShortcutInitialHeldKeys.Has(mouseVK[button])
}

SettingsMouseIsSettingsHostUnderPointer() {
    global SettingsHost, SettingsVisible
    if !SettingsVisible || !IsObject(SettingsHost)
        return false
    panelGui := PanelHostGui(SettingsHost)
    if !IsObject(panelGui)
        return false
    windowUnderPointer := 0
    try MouseGetPos(,, &windowUnderPointer,, 2)
    catch
        return false
    if !windowUnderPointer
        return false
    if windowUnderPointer = panelGui.Hwnd
        return true
    rootHwnd := 0
    try rootHwnd := DllCall("GetAncestor", "Ptr", windowUnderPointer, "UInt", 2, "Ptr")
    return rootHwnd = panelGui.Hwnd
}

SettingsShortcutMouseDownNative(button, *) {
    global SettingsShortcutCaptureId
    SettingsShortcutMouseDown(button, "native", SettingsShortcutCaptureId)
}

SettingsShortcutMouseDown(button, source, captureId, modified := false) {
    global SettingsShortcutMousePresses, SettingsShortcutCaptureId, SettingsShortcutCaptureFinishing
    criticalState := Critical("On")
    try {
        if !SettingsSingleInputCaptureActive() || captureId != SettingsShortcutCaptureId
            return
        if SettingsShortcutMousePresses.Has(button)
            && SettingsShortcutMousePresses[button].captureId = captureId
            return
        SettingsShortcutMousePresses[button] := {source: source, captureId: captureId}
        if SettingsShortcutCaptureFinishing || !SettingsShortcutInitialInputsReleased()
            return
        if modified || SettingsShortcutInputModifiersDown()
            SettingsShortcutRejectSingleInput()
        else
            SettingsShortcutAcceptSingleInput(button, SettingsSingleInputLabel(button), "mouse")
        ; A page message may arrive after the physical click has already ended.
        if source = "page" && !GetKeyState(button, "P")
            SettingsShortcutMouseUp(button)
    } finally {
        Critical(criticalState)
    }
}

SettingsShortcutMouseUpNative(button, *) {
    SettingsShortcutMouseUp(button)
}

SettingsShortcutMouseUp(button, cancelled := false) {
    global SettingsShortcutMousePresses, SettingsShortcutCandidate
    global SettingsShortcutCaptureId, SettingsShortcutCaptureFinishing
    criticalState := Critical("On")
    try {
        if !SettingsShortcutMousePresses.Has(button)
            return
        press := SettingsShortcutMousePresses[button]
        SettingsShortcutMousePresses.Delete(button)
        candidate := SettingsShortcutCandidate
        if press.captureId != SettingsShortcutCaptureId || !SettingsSingleInputCaptureActive()
            || SettingsShortcutCaptureFinishing || !IsObject(candidate)
            || candidate.kind != "mouse" || candidate.value != button
            return
        if cancelled || SettingsShortcutInputModifiersDown() {
            SettingsShortcutResetCandidate()
            if !cancelled
                SettingsShortcutRejectSingleInput()
        } else
            SettingsShortcutFinishCandidate()
    } finally {
        Critical(criticalState)
    }
}

SettingsShortcutCaptureRegisterMouseHotkeys() {
    buttons := Map("LButton", "lbutton", "RButton", "rbutton", "MButton", "mbutton",
        "XButton1", "xbutton1", "XButton2", "xbutton2")
    HotIf(SettingsShortcutMouseOutsideSettingsActive)
    for hotkeyName, button in buttons
        Hotkey("*" . hotkeyName, SettingsShortcutMouseDownNative.Bind(button))
    for hotkeyName, button in buttons {
        HotIf(SettingsShortcutMouseReleaseActive.Bind(button))
        Hotkey("*" . hotkeyName . " Up", SettingsShortcutMouseUpNative.Bind(button))
        HotIf(SettingsShortcutMouseOutsideSettingsActive)
    }
    HotIf()
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
    global SettingsHost, SettingsEditSessionId
    global SettingsShortcutCaptureGeneration, SettingsShortcutCaptureId, SettingsVisible
    global SettingsShortcutCaptureMode
    if target = ""
        return
    criticalState := Critical("On")
    try {
        if generation != SettingsShortcutCaptureGeneration
            || captureId != SettingsShortcutCaptureId || !SettingsVisible
            || !IsObject(SettingsHost) || !PanelHostPageReady(SettingsHost)
            return
        payload := Map("sessionId", SettingsEditSessionId, "key", target, "captureId", captureId,
            "value", value, "label", label)
        SettingsPost("shortcutCapture", payload)
        if SettingsShortcutCaptureMode = "singleInput"
            SettingsStopShortcutCapture(generation, captureId)
    } finally {
        Critical(criticalState)
    }
}

SettingsSendShortcutCaptureFailure(captureId, generation) {
    global SettingsHost, SettingsEditSessionId, SettingsShortcutCaptureGeneration, SettingsShortcutCaptureId
    global SettingsVisible
    criticalState := Critical("On")
    try {
        if generation != SettingsShortcutCaptureGeneration
            || captureId != SettingsShortcutCaptureId || !SettingsVisible
            || !IsObject(SettingsHost) || !PanelHostPageReady(SettingsHost)
            return
        payload := Map("sessionId", SettingsEditSessionId, "captureId", captureId)
        SettingsPost("shortcutCaptureFailed", payload)
    } finally {
        Critical(criticalState)
    }
}
