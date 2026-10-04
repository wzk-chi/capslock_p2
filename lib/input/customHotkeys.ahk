; User-defined global and per-application shortcut remapping.

global CustomHotkeyBindings := []

RegisterCustomHotkeys() {
    global CustomHotkeyBindings
    registrationErrors := []
    for binding in CustomHotkeyBindings {
        try {
            HotIf(binding["condition"])
            Hotkey("$" . binding["trigger"], "Off")
        }
    }
    HotIf()
    CustomHotkeyBindings := []

    triggers := Map()
    for trigger, action in ConfigSection("CustomHotkey") {
        normalizedTrigger := ConfigNormalizeCustomHotkeyTrigger(trigger)
        if normalizedTrigger != ""
            triggers[normalizedTrigger] := true
    }
    for profileId, profile in AppProfiles {
        if !profile["sections"].Has("CustomHotkey")
            continue
        for trigger, action in profile["sections"]["CustomHotkey"] {
            normalizedTrigger := ConfigNormalizeCustomHotkeyTrigger(trigger)
            if normalizedTrigger != ""
                triggers[normalizedTrigger] := true
        }
    }
    ; Ctrl+V has an existing built-in action and is part of the same ownership
    ; table so an application profile can override or release it.
    triggers["^v"] := true

    for trigger in triggers {
        trigger := String(trigger)
        condition := CustomHotkeyActive.Bind(trigger)
        HotIf(condition)
        try {
            Hotkey("$" . trigger, MakeCustomHotkeyHandler(trigger))
            CustomHotkeyBindings.Push(Map("trigger", trigger, "condition", condition))
        } catch as hotkeyError {
            registrationErrors.Push(trigger)
            DebugLog("Custom hotkey skipped triggerLength=" . StrLen(trigger)
                . " error=" . hotkeyError.Message)
        }
    }
    HotIf()
    DebugLog("Custom hotkeys registered count=" . CustomHotkeyBindings.Length)
    return registrationErrors
}

CustomHotkeyActive(trigger, *) {
    global SettingsShortcutHook
    if CapsLockLayerActive()
        return false
    if IsObject(SettingsShortcutHook)
        return false
    action := CustomHotkeyResolve(trigger)
    return action != "" && action != "@native"
}

MakeCustomHotkeyHandler(trigger) {
    return (*) => CustomHotkeySend(trigger)
}

CustomHotkeyResolve(trigger) {
    normalizedTrigger := ConfigNormalizeCustomHotkeyTrigger(trigger)
    profile := AppProfileActive()
    if IsObject(profile) && profile["sections"].Has("CustomHotkey") {
        profileAction := CustomHotkeyLookup(profile["sections"]["CustomHotkey"], normalizedTrigger, &found)
        if found
            return Trim(String(profileAction))
    }
    globalAction := CustomHotkeyLookup(ConfigSection("CustomHotkey"), normalizedTrigger, &found)
    action := found ? Trim(String(globalAction)) : ""
    if action = "" && normalizedTrigger = "^v"
        return "@builtin_pasteSystem"
    return action
}

CustomHotkeyLookup(values, normalizedTrigger, &found := false) {
    found := false
    fallback := ""
    for trigger, action in values {
        if ConfigNormalizeCustomHotkeyTrigger(trigger) = normalizedTrigger {
            found := true
            fallback := action
            if StrLower(Trim(String(trigger))) = normalizedTrigger
                return action
        }
    }
    return fallback
}

CustomHotkeySend(trigger, *) {
    action := CustomHotkeyResolve(trigger)
    if action = "" || action = "@native" || action = "@block"
        return
    if action = "@builtin_pasteSystem" {
        PasteSystemHotkey()
        return
    }
    try SendInput(action)
    catch as sendError
        DebugLog("Custom hotkey send failed actionLength=" . StrLen(String(action))
            . " error=" . sendError.Message)
}
