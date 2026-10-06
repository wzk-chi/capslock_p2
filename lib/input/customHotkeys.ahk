; User-defined global and per-application shortcut remapping.

global CustomHotkeyBindings := []
global CustomHotkeyIndex := Map("globalActions", Map(), "profilesByPath", Map())

RegisterCustomHotkeys() {
    global CustomHotkeyBindings, CustomHotkeyIndex
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
    globalActions := CustomHotkeyBuildActionMap(ConfigSection("CustomHotkey"))
    CustomHotkeyCollectTriggers(triggers, globalActions)
    profilesByPath := Map()
    for profileId, profile in AppProfiles {
        profileActions := CustomHotkeyBuildActionMap(
            profile["sections"].Has("CustomHotkey")
                ? profile["sections"]["CustomHotkey"] : Map())
        CustomHotkeyCollectTriggers(triggers, profileActions)
        if profile["enabled"] != "1"
            continue
        profilePath := AppProfileNormalizePath(profile["exePath"])
        if profilePath != "" && !profilesByPath.Has(profilePath)
            profilesByPath[profilePath] := profileActions
    }
    CustomHotkeyIndex := Map(
        "globalActions", globalActions,
        "profilesByPath", profilesByPath)
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

CustomHotkeyBuildActionMap(values) {
    actions := Map()
    for trigger, action in values {
        normalizedTrigger := ConfigNormalizeCustomHotkeyTrigger(trigger)
        if normalizedTrigger = ""
            continue
        canonical := StrLower(Trim(String(trigger))) = normalizedTrigger
        normalizedAction := Trim(String(action))
        if !actions.Has(normalizedTrigger) {
            actions[normalizedTrigger] := Map(
                "action", normalizedAction, "canonical", canonical)
            continue
        }
        current := actions[normalizedTrigger]
        if current["canonical"]
            continue
        if canonical {
            actions[normalizedTrigger] := Map(
                "action", normalizedAction, "canonical", true)
        } else {
            current["action"] := normalizedAction
        }
    }
    return actions
}

CustomHotkeyCollectTriggers(triggers, actions) {
    for trigger, action in actions
        triggers[trigger] := true
}

CustomHotkeyActive(trigger, *) {
    global SettingsShortcutHook, SettingsShortcutCapturePending
    if CapsLockLayerActive()
        return false
    if IsObject(SettingsShortcutHook) || SettingsShortcutCapturePending
        return false
    action := CustomHotkeyResolve(trigger)
    return action != "" && action != "@native"
}

MakeCustomHotkeyHandler(trigger) {
    return (*) => CustomHotkeySend(trigger)
}

; `trigger` is canonical because callers are bound only from the registered map.
; Resolve the active executable on every check/send; never reuse HotIf's result.
CustomHotkeyResolve(trigger) {
    global CustomHotkeyIndex
    active := GetActiveWindowInfo()
    if active {
        profilePath := AppProfileNormalizePath(active.path)
        profilesByPath := CustomHotkeyIndex["profilesByPath"]
        if profilePath != "" && profilesByPath.Has(profilePath) {
            profileActions := profilesByPath[profilePath]
            if profileActions.Has(trigger)
                return profileActions[trigger]["action"]
        }
    }
    globalActions := CustomHotkeyIndex["globalActions"]
    action := globalActions.Has(trigger) ? globalActions[trigger]["action"] : ""
    if action = "" && trigger = "^v"
        return "@builtin_pasteSystem"
    return action
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
