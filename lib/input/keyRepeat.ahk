; One long-press task; its snapshot owns the output and timer.

global KeyRepeatStatus := "stopped"
global KeyRepeatGeneration := 0
global KeyRepeatTask := 0
global KeyRepeatInputHotkeys := []

KeyRepeatInitialize() {
    KeyRepeatStop(true)
    KeyRepeatRefreshInputHooks()
}

KeyRepeatInputActive(*) {
    global KeyRepeatTask
    return KeyRepeatInputReleaseActive()
        && !SettingsShortcutCaptureActive()
        && (IsObject(KeyRepeatTask) || !CapsLockLayerActive())
}

KeyRepeatInputReleaseActive(*) {
    global AppStoreReady, Config, KeyRepeatStatus, SettingsSaving
    return AppStoreReady && KeyRepeatStatus != "stopped" && Config.Has("KeyRepeat")
        && !SettingsSaving && !SettingsShortcutCaptureActive()
}

KeyRepeatRefreshInputHooks() {
    global Config, KeyRepeatInputHotkeys
    KeyRepeatUnregisterInputHotkeys(KeyRepeatInputHotkeys)
    KeyRepeatInputHotkeys := []
    if !Config.Has("KeyRepeat")
        return false
    if Config["KeyRepeat"].Get("repeatKey", "") = ""
        return true
    if !KeyRepeatReadConfiguration(&input) {
        DiagnosticLogAlways("Long-press input hooks rejected reason=invalid-settings")
        return false
    }

    ; Block keyboard auto-repeat, replay the first down, and let the physical up pass.
    downHotkey := (input.kind = "button" ? "~*" : "$*") . input.key
    upHotkey := (input.kind = "button" ? "~*" : "~$*") . input.key . " Up"
    registered := []
    try {
        HotIf(KeyRepeatInputActive)
        Hotkey(downHotkey, KeyRepeatInputDown.Bind(input))
        registered.Push({name: downHotkey, condition: KeyRepeatInputActive})
        HotIf(KeyRepeatInputReleaseActive)
        Hotkey(upHotkey, KeyRepeatInputUp.Bind(input.key))
        registered.Push({name: upHotkey, condition: KeyRepeatInputReleaseActive})
    } catch as hotkeyError {
        KeyRepeatUnregisterInputHotkeys(registered)
        DiagnosticLogAlways("Long-press input hooks failed errorType="
            . Type(hotkeyError) . " detail=" . hotkeyError.Message)
        return false
    } finally {
        HotIf()
    }
    KeyRepeatInputHotkeys := registered
    DiagnosticLogAlways("Long-press input hooks registered kind=" . input.kind)
    return true
}

KeyRepeatUnregisterInputHotkeys(hotkeys) {
    try {
        for entry in hotkeys {
            HotIf(entry.condition)
            try Hotkey(entry.name, "Off")
        }
    } finally {
        HotIf()
    }
}

KeyRepeatStatusSnapshot() {
    global Config, KeyRepeatStatus, KeyRepeatTask
    criticalState := Critical("On")
    try {
        status := KeyRepeatStatus
        if IsObject(KeyRepeatTask) {
            key := KeyRepeatTask.key
            delay := KeyRepeatTask.delay
        } else {
            values := Config.Get("KeyRepeat", Map())
            key := values.Get("repeatKey", "")
            delay := Integer(values.Get("startupDelayMs", 0))
        }
    } finally {
        Critical(criticalState)
    }
    return Map("status", status, "enabled", status != "stopped" ? "1" : "0",
        "repeatKey", String(key), "delayMs", delay)
}

KeyRepeatToggle(*) {
    global KeyRepeatStatus
    KeyRepeatSetArmed(KeyRepeatStatus = "stopped", "hotkey")
}

KeyRepeatSetArmed(armed, source := "settings") {
    global AppStoreReady, Config, KeyRepeatStatus, KeyRepeatInputHotkeys, SettingsSaving
    if !armed {
        changed := KeyRepeatStop(true)
        if changed {
            DiagnosticLogAlways("Long-press mode changed armed=0 source=" . source)
            if source = "hotkey"
                KeyRepeatShowInfo("Long-press repeat is off.", "已关闭长按连发。")
        } else
            KeyRepeatPublishStatus()
        return true
    }
    if SettingsShortcutCaptureActive() || SettingsSaving
        return false
    if !AppStoreReady || !Config.Has("KeyRepeat") {
        KeyRepeatShowError("Long-press repeat settings are unavailable.",
            "长按连发设置暂时不可用，请重新打开设置后重试。")
        return false
    }
    if KeyRepeatStatus != "stopped" {
        KeyRepeatPublishStatus()
        return true
    }
    if Config["KeyRepeat"].Get("repeatKey", "") = "" {
        DiagnosticLogAlways("Long-press mode start rejected reason=missing-input source=" . source)
        if source = "hotkey"
            KeyRepeatShowInfo("Record a key or mouse button in Long-press Repeat settings first.",
                "请先录制一个键盘键或鼠标按键。")
        KeyRepeatPublishStatus()
        return false
    }
    if !KeyRepeatReadConfiguration(&input) || KeyRepeatInputHotkeys.Length != 2 {
        DiagnosticLogAlways("Long-press mode start rejected reason=invalid-settings-or-hooks")
        KeyRepeatShowError("The long-press repeat settings are unavailable. Reopen Settings and try again.",
            "长按连发暂时无法启用，请重新打开设置后重试。")
        KeyRepeatPublishStatus()
        return false
    }

    criticalState := Critical("On")
    changed := false
    try {
        if !SettingsShortcutCaptureActive() && !SettingsSaving && AppStoreReady
            && KeyRepeatConfigStillMatches(input) {
            KeyRepeatStatus := "armed"
            changed := true
        }
    } finally {
        Critical(criticalState)
    }
    if changed {
        DiagnosticLogAlways("Long-press mode changed armed=1 source=" . source)
        KeyRepeatPublishStatus()
        if source = "hotkey"
            KeyRepeatShowInfo("Long-press repeat is on. Hold the recorded input to repeat.",
                "已启动长按连发。按住录制的按键即可连发。")
    }
    return changed
}

KeyRepeatReadConfiguration(&input) {
    global Config
    input := 0
    if !Config.Has("KeyRepeat")
        return false
    values := Config["KeyRepeat"]
    if !ConfigValidateSingleInput(values.Get("repeatKey", ""), &key)
        || key = "" || !KeyRepeatBuildOutput(key, &kind, &sendValue)
        || !ConfigValidateValue("KeyRepeat", "startupDelayMs",
            values.Get("startupDelayMs", ""), &delay)
        || !ConfigValidateValue("KeyRepeat", "intervalMs",
            values.Get("intervalMs", ""), &interval)
        return false
    input := {key: key, kind: kind, sendValue: sendValue,
        delay: Integer(delay), interval: Integer(interval)}
    return true
}

KeyRepeatInputDown(input, *) {
    global KeyRepeatStatus, KeyRepeatGeneration, KeyRepeatTask
    failure := ""
    started := false
    criticalState := Critical("On")
    try {
        if IsObject(KeyRepeatTask) && KeyRepeatTask.key = input.key
            return
        pressed := GetKeyState(input.key, "P")
        if input.kind = "keyboard" {
            SendLevel(0)
            SendInput("{Blind}" . (pressed
                ? SubStr(input.sendValue, 1, -1) . " down}" : input.sendValue))
        }
        if !pressed || KeyRepeatStatus != "armed" || !KeyRepeatInputActive()
            || !KeyRepeatConfigStillMatches(input)
            return

        task := input.Clone()
        KeyRepeatGeneration += 1
        task.generation := KeyRepeatGeneration
        task.timer := KeyRepeatTimerCallback.Bind(task.generation)
        KeyRepeatTask := task
        KeyRepeatStatus := "waiting"
        SetTimer(task.timer, -Max(1, task.delay))
        started := true
    } catch as startError {
        failure := Type(startError) . ": " . startError.Message
        KeyRepeatResetHeldLocked("stopped")
    } finally {
        Critical(criticalState)
    }
    if failure != ""
        KeyRepeatReportFailure(failure)
    else if started {
        DiagnosticLogAlways("Long-press hold detected kind=" . input.kind
            . " delayMs=" . input.delay . " intervalMs=" . input.interval)
        KeyRepeatPublishStatus()
    }
}

KeyRepeatInputUp(keyName, *) {
    global KeyRepeatTask, KeyRepeatStatus
    criticalState := Critical("On")
    stopped := false
    try {
        if IsObject(KeyRepeatTask) && KeyRepeatTask.key = keyName
            && !GetKeyState(keyName, "P") {
            previousStatus := KeyRepeatStatus
            KeyRepeatResetHeldLocked("armed")
            stopped := true
        }
    } finally {
        Critical(criticalState)
    }
    if stopped {
        DiagnosticLogAlways("Long-press repeat stopped reason=input-release state=" . previousStatus)
        KeyRepeatPublishStatus()
    }
}

KeyRepeatConfigStillMatches(input) {
    global Config
    if !Config.Has("KeyRepeat")
        return false
    values := Config["KeyRepeat"]
    return String(values.Get("repeatKey", "")) = input.key
        && Integer(values.Get("startupDelayMs", -1)) = input.delay
        && Integer(values.Get("intervalMs", -1)) = input.interval
}

KeyRepeatStop(quiet := false) {
    global KeyRepeatStatus
    criticalState := Critical("On")
    try {
        changed := KeyRepeatStatus != "stopped"
        KeyRepeatResetHeldLocked("stopped")
    } finally {
        Critical(criticalState)
    }
    if changed {
        KeyRepeatPublishStatus()
        if !quiet
            KeyRepeatShowInfo("Long-press repeat is off.", "已关闭长按连发。")
    }
    return changed
}

KeyRepeatCancelCurrentPress() {
    global KeyRepeatStatus, KeyRepeatTask
    criticalState := Critical("On")
    try {
        cancelled := IsObject(KeyRepeatTask)
        if cancelled
            KeyRepeatResetHeldLocked(KeyRepeatStatus = "stopped" ? "stopped" : "armed")
    } finally {
        Critical(criticalState)
    }
    return cancelled
}

KeyRepeatResetHeldLocked(nextStatus) {
    global KeyRepeatStatus, KeyRepeatGeneration, KeyRepeatTask
    task := KeyRepeatTask
    KeyRepeatTask := 0
    KeyRepeatGeneration += 1
    KeyRepeatStatus := nextStatus
    if IsObject(task)
        SetTimer(task.timer, 0)
}

KeyRepeatTimerCallback(generation, *) {
    global AppStoreReady, KeyRepeatGeneration, KeyRepeatStatus, KeyRepeatTask
    failure := ""
    changed := false
    repeatStarted := false
    criticalState := Critical("On")
    try {
        task := KeyRepeatTask
        if !IsObject(task) || generation != KeyRepeatGeneration
            return
        if !AppStoreReady
            throw Error("The application database is unavailable.")
        if !KeyRepeatConfigStillMatches(task) {
            KeyRepeatResetHeldLocked("armed")
            changed := true
        } else if !GetKeyState(task.key, "P") {
            KeyRepeatResetHeldLocked("armed")
            changed := true
        } else {
            KeyRepeatEmit(task)
            if KeyRepeatStatus = "waiting" {
                KeyRepeatStatus := "running"
                repeatStarted := true
                changed := true
            }
            SetTimer(task.timer, task.interval)
        }
    } catch as callbackError {
        failure := Type(callbackError) . ": " . callbackError.Message
        KeyRepeatResetHeldLocked("stopped")
    } finally {
        Critical(criticalState)
    }
    if failure != "" {
        KeyRepeatReportFailure(failure)
        return
    }
    if repeatStarted
        DiagnosticLogAlways("Long-press repeat started intervalMs=" . task.interval)
    if changed
        KeyRepeatPublishStatus()
}

KeyRepeatBuildOutput(keyName, &kind, &sendValue) {
    if RegExMatch(keyName, "i)^(lbutton|rbutton|mbutton|xbutton[12])$") {
        kind := "button"
        sendValue := keyName
        return true
    }
    kind := "keyboard"
    keyCode := GetKeyVK(keyName)
    scanCode := GetKeySC(keyName)
    if !keyCode || !scanCode
        return false
    sendValue := "{vk" . Format("{:02X}", keyCode)
        . "sc" . Format("{:03X}", scanCode) . "}"
    return true
}

KeyRepeatEmit(input) {
    static buttons := Map("lbutton", "Left", "rbutton", "Right",
        "mbutton", "Middle", "xbutton1", "X1", "xbutton2", "X2")
    SendLevel(0)
    if input.kind = "button"
        Click(buttons[input.key])
    else
        SendInput("{Blind}" . input.sendValue)
}

KeyRepeatReportFailure(detail) {
    DiagnosticLogAlways("Long-press repeat stopped after input failure detail=" . detail)
    KeyRepeatPublishStatus()
    KeyRepeatShowError("Long-press repeat stopped because input failed.",
        "长按连发遇到输入错误，已停止。")
}

KeyRepeatPublishStatus() {
    global SettingsVisible, SettingsEditSessionId
    if SettingsVisible && SettingsEditSessionId != ""
        try SettingsPost("keyRepeatState", KeyRepeatStatusSnapshot())
}

KeyRepeatShowInfo(english, chinese) {
    ShowMsg(LLMText(english, chinese), 1400)
}

KeyRepeatShowError(english, chinese) {
    ShowMsg(LLMText(english, chinese), 2600)
}
