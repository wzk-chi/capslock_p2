; User-defined global and per-application shortcut remapping.

global CustomHotkeyBindings := []
global CustomHotkeyIndex := Map("globalActions", Map(), "profilesByPath", Map())

; Expose only built-in actions callable without user-supplied arguments. The
; persisted ID is resolved through this fixed map before any action is invoked.
CustomHotkeyBuiltinActions() {
    static actions := Map(
        "@builtin:shortcut/keyFunc_doNothing", "keyFunc_doNothing",
        "@builtin:shortcut/keyFunc_toggleCapsLock", "keyFunc_toggleCapsLock",
        "@builtin:shortcut/keyFunc_mouseSpeedIncrease", "keyFunc_mouseSpeedIncrease",
        "@builtin:shortcut/keyFunc_mouseSpeedDecrease", "keyFunc_mouseSpeedDecrease",
        "@builtin:shortcut/keyFunc_moveLeft", "keyFunc_moveLeft",
        "@builtin:shortcut/keyFunc_moveRight", "keyFunc_moveRight",
        "@builtin:shortcut/keyFunc_moveUp", "keyFunc_moveUp",
        "@builtin:shortcut/keyFunc_moveDown", "keyFunc_moveDown",
        "@builtin:shortcut/keyFunc_moveWordLeft", "keyFunc_moveWordLeft",
        "@builtin:shortcut/keyFunc_moveWordRight", "keyFunc_moveWordRight",
        "@builtin:shortcut/keyFunc_backspace", "keyFunc_backspace",
        "@builtin:shortcut/keyFunc_delete", "keyFunc_delete",
        "@builtin:shortcut/keyFunc_deleteAll", "keyFunc_deleteAll",
        "@builtin:shortcut/keyFunc_deleteWord", "keyFunc_deleteWord",
        "@builtin:shortcut/keyFunc_forwardDeleteWord", "keyFunc_forwardDeleteWord",
        "@builtin:shortcut/keyFunc_end", "keyFunc_end",
        "@builtin:shortcut/keyFunc_home", "keyFunc_home",
        "@builtin:shortcut/keyFunc_moveToPageBeginning", "keyFunc_moveToPageBeginning",
        "@builtin:shortcut/keyFunc_moveToPageEnd", "keyFunc_moveToPageEnd",
        "@builtin:shortcut/keyFunc_deleteLine", "keyFunc_deleteLine",
        "@builtin:shortcut/keyFunc_deleteToLineBeginning", "keyFunc_deleteToLineBeginning",
        "@builtin:shortcut/keyFunc_deleteToLineEnd", "keyFunc_deleteToLineEnd",
        "@builtin:shortcut/keyFunc_deleteToPageBeginning", "keyFunc_deleteToPageBeginning",
        "@builtin:shortcut/keyFunc_deleteToPageEnd", "keyFunc_deleteToPageEnd",
        "@builtin:shortcut/keyFunc_enterWherever", "keyFunc_enterWherever",
        "@builtin:shortcut/keyFunc_esc", "keyFunc_esc",
        "@builtin:shortcut/keyFunc_enter", "keyFunc_enter",
        "@builtin:shortcut/keyFunc_doubleAngle", "keyFunc_doubleAngle",
        "@builtin:shortcut/keyFunc_doubleQuote", "keyFunc_doubleQuote",
        "@builtin:shortcut/keyFunc_pageUp", "keyFunc_pageUp",
        "@builtin:shortcut/keyFunc_pageDown", "keyFunc_pageDown",
        "@builtin:shortcut/keyFunc_pageMoveUp", "keyFunc_pageMoveUp",
        "@builtin:shortcut/keyFunc_pageMoveDown", "keyFunc_pageMoveDown",
        "@builtin:shortcut/keyFunc_switchClipboard", "keyFunc_switchClipboard",
        "@builtin:shortcut/keyFunc_pasteSystem", "keyFunc_pasteSystem",
        "@builtin:shortcut/keyFunc_cut_1", "keyFunc_cut_1",
        "@builtin:shortcut/keyFunc_copy_1", "keyFunc_copy_1",
        "@builtin:shortcut/keyFunc_paste_1", "keyFunc_paste_1",
        "@builtin:shortcut/keyFunc_undoRedo", "keyFunc_undoRedo",
        "@builtin:shortcut/keyFunc_cut_2", "keyFunc_cut_2",
        "@builtin:shortcut/keyFunc_copy_2", "keyFunc_copy_2",
        "@builtin:shortcut/keyFunc_paste_2", "keyFunc_paste_2",
        "@builtin:shortcut/keyFunc_tabPrve", "keyFunc_tabPrve",
        "@builtin:shortcut/keyFunc_tabNext", "keyFunc_tabNext",
        "@builtin:shortcut/keyFunc_jumpPageTop", "keyFunc_jumpPageTop",
        "@builtin:shortcut/keyFunc_jumpPageBottom", "keyFunc_jumpPageBottom",
        "@builtin:shortcut/keyFunc_qbar", "keyFunc_qbar",
        "@builtin:shortcut/keyFunc_clipboardHistory", "keyFunc_clipboardHistory",
        "@builtin:shortcut/keyFunc_translate", "keyFunc_translate",
        "@builtin:shortcut/keyFunc_editSelectedText", "keyFunc_editSelectedText",
        "@builtin:shortcut/keyFunc_tabHotString", "keyFunc_tabHotString",
        "@builtin:shortcut/keyFunc_openCpasDocs", "keyFunc_openCpasDocs",
        "@builtin:shortcut/keyFunc_openSettings", "keyFunc_openSettings",
        "@builtin:shortcut/keyFunc_reload", "keyFunc_reload",
        "@builtin:shortcut/keyFunc_mediaPrev", "keyFunc_mediaPrev",
        "@builtin:shortcut/keyFunc_mediaNext", "keyFunc_mediaNext",
        "@builtin:shortcut/keyFunc_mediaPlayPause", "keyFunc_mediaPlayPause",
        "@builtin:shortcut/keyFunc_volumeUp", "keyFunc_volumeUp",
        "@builtin:shortcut/keyFunc_volumeDown", "keyFunc_volumeDown",
        "@builtin:shortcut/keyFunc_volumeMute", "keyFunc_volumeMute",
        "@builtin:shortcut/keyFunc_winPin", "keyFunc_winPin",
        "@builtin:shortcut/keyFunc_winTransparent", "keyFunc_winTransparent",
        "@builtin:shortcut/keyFunc_selectUp", "keyFunc_selectUp",
        "@builtin:shortcut/keyFunc_selectDown", "keyFunc_selectDown",
        "@builtin:shortcut/keyFunc_selectLeft", "keyFunc_selectLeft",
        "@builtin:shortcut/keyFunc_selectRight", "keyFunc_selectRight",
        "@builtin:shortcut/keyFunc_selectHome", "keyFunc_selectHome",
        "@builtin:shortcut/keyFunc_selectEnd", "keyFunc_selectEnd",
        "@builtin:shortcut/keyFunc_selectToPageBeginning", "keyFunc_selectToPageBeginning",
        "@builtin:shortcut/keyFunc_selectToPageEnd", "keyFunc_selectToPageEnd",
        "@builtin:shortcut/keyFunc_selectCurrentWord", "keyFunc_selectCurrentWord",
        "@builtin:shortcut/keyFunc_selectCurrentLine", "keyFunc_selectCurrentLine",
        "@builtin:shortcut/keyFunc_selectWordLeft", "keyFunc_selectWordLeft",
        "@builtin:shortcut/keyFunc_selectWordRight", "keyFunc_selectWordRight",
        "@builtin:shortcut/keyFunc_pageMoveLineUp", "keyFunc_pageMoveLineUp",
        "@builtin:shortcut/keyFunc_pageMoveLineDown", "keyFunc_pageMoveLineDown",
        "@builtin:shortcut/keyFunc_goCjkPage", "keyFunc_goCjkPage",
        "@builtin:shortcut/keyFunc_click_left", "keyFunc_click_left",
        "@builtin:shortcut/keyFunc_click_right", "keyFunc_click_right",
        "@builtin:shortcut/keyFunc_mouse_up", "keyFunc_mouse_up",
        "@builtin:shortcut/keyFunc_mouse_down", "keyFunc_mouse_down",
        "@builtin:shortcut/keyFunc_mouse_left", "keyFunc_mouse_left",
        "@builtin:shortcut/keyFunc_mouse_right", "keyFunc_mouse_right",
        "@builtin:shortcut/keyFunc_wheel_up", "keyFunc_wheel_up",
        "@builtin:shortcut/keyFunc_wheel_down", "keyFunc_wheel_down")
    return actions
}

CustomHotkeyBuiltinActionSnapshot() {
    actions := []
    for actionId in CustomHotkeyBuiltinActions()
        actions.Push(actionId)
    return actions
}

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
    if InStr(action, "@builtin:", true) = 1 {
        builtinActions := CustomHotkeyBuiltinActions()
        if !builtinActions.Has(action) {
            DebugLog("Custom hotkey builtin action rejected idLength=" . StrLen(action))
            return
        }
        RunConfiguredAction(builtinActions[action])
        return
    }
    try SendInput(action)
    catch as sendError
        DebugLog("Custom hotkey send failed actionLength=" . StrLen(String(action))
            . " error=" . sendError.Message)
}
