; Default key layouts and CapsLock-layer AHK v2 hotkeys.

global LayerKeyNames := Map(
    "a", "a", "b", "b", "c", "c", "d", "d", "e", "e", "f", "f", "g", "g", "h", "h", "i", "i", "j", "j", "k", "k", "l", "l", "m", "m", "n", "n", "o", "o", "p", "p", "q", "q", "r", "r", "s", "s", "t", "t", "u", "u", "v", "v", "w", "w", "x", "x", "y", "y", "z", "z",
    "1", "1", "2", "2", "3", "3", "4", "4", "5", "5", "6", "6", "7", "7", "8", "8", "9", "9", "0", "0",
    "F1", "f1", "F2", "f2", "F3", "f3", "F4", "f4", "F5", "f5", "F6", "f6", "F7", "f7", "F8", "f8", "F9", "f9", "F10", "f10", "F11", "f11", "F12", "f12",
    "Space", "space", "Tab", "tab", "Enter", "enter", "Esc", "esc", "Backspace", "backspace", "RAlt", "ralt",
    "-", "minus", "=", "equal", "[", "leftSquareBracket", "]", "rightSquareBracket", "\", "backslash", ";", "semicolon", "'", "quote", ",", "comma", ".", "dot", "/", "slash"
)
LayerKeyNames["SC029"] := "backquote"

global MathKeypad := Map(
    "u", "7", "i", "8", "o", "9", "j", "4", "k", "5", "l", "6", "m", "1", ",", "2", ".", "3", "space", "0", "ralt", ".", ";", "+", "'", "-", "p", "*", "/", "/", "[", "/"
)

global PasteSystemHotkeyRunning := false

BuildKeySet() {
    global Config, KeySet
    KeySet := Map()
    if Config.Has("Keys") {
        for key, value in Config["Keys"]
            KeySet[key] := value
    }

    defaults := CapsloxKeyDefaults()

    for key, value in defaults {
        if !KeySet.Has(key) || Trim(KeySet[key]) = ""
            KeySet[key] := value
    }
    DebugLog("KeySet press_caps=" . (KeySet.Has("press_caps") ? KeySet["press_caps"] : "<missing>"))
}

CapsloxKeyDefaults() {
    defaults := Map(
        "press_caps", "keyFunc_toggleCapsLock",
        "caps_a", "keyFunc_moveWordLeft", "caps_b", "keyFunc_moveDown(10)", "caps_c", "keyFunc_copy_1", "caps_d", "keyFunc_moveDown", "caps_e", "keyFunc_moveUp", "caps_f", "keyFunc_moveRight", "caps_g", "keyFunc_moveWordRight", "caps_h", "keyFunc_selectWordLeft", "caps_i", "keyFunc_selectUp", "caps_j", "keyFunc_selectLeft", "caps_k", "keyFunc_selectDown", "caps_l", "keyFunc_selectRight", "caps_m", "keyFunc_doNothing", "caps_n", "keyFunc_selectDown(10)", "caps_o", "keyFunc_selectEnd", "caps_p", "keyFunc_home", "caps_q", "keyFunc_qbar", "caps_r", "keyFunc_delete", "caps_s", "keyFunc_moveLeft", "caps_t", "keyFunc_translate", "caps_u", "keyFunc_selectHome", "caps_v", "keyFunc_paste_1", "caps_w", "keyFunc_backspace", "caps_x", "keyFunc_cut_1", "caps_y", "keyFunc_selectUp(10)", "caps_z", "keyFunc_doNothing",
        "caps_backquote", "keyFunc_doNothing", "caps_1", "keyFunc_winbind_activate(1)", "caps_2", "keyFunc_winbind_activate(2)", "caps_3", "keyFunc_winbind_activate(3)", "caps_4", "keyFunc_winbind_activate(4)", "caps_5", "keyFunc_winbind_activate(5)", "caps_6", "keyFunc_winbind_activate(6)", "caps_7", "keyFunc_winbind_activate(7)", "caps_8", "keyFunc_winbind_activate(8)", "caps_9", "keyFunc_winbind_activate(9)", "caps_0", "keyFunc_winbind_activate(10)",
        "caps_minus", "keyFunc_pageUp", "caps_equal", "keyFunc_pageDown", "caps_backspace", "keyFunc_deleteLine", "caps_tab", "keyFunc_tabScript", "caps_leftSquareBracket", "keyFunc_deleteToLineBeginning", "caps_rightSquareBracket", "keyFunc_doNothing", "caps_backslash", "keyFunc_doNothing", "caps_semicolon", "keyFunc_end", "caps_quote", "keyFunc_doNothing", "caps_enter", "keyFunc_enterWherever", "caps_comma", "keyFunc_selectCurrentWord", "caps_dot", "keyFunc_selectWordRight", "caps_slash", "keyFunc_deleteToLineEnd", "caps_space", "keyFunc_enter", "caps_ralt", "keyFunc_doNothing",
        "caps_f1", "keyFunc_openCpasDocs", "caps_f2", "keyFunc_mathBoard", "caps_f3", "keyFunc_translate", "caps_f4", "keyFunc_winTransparent", "caps_f5", "keyFunc_reload", "caps_f6", "keyFunc_winPin", "caps_f7", "keyFunc_doNothing", "caps_f8", "keyFunc_getJSEvalString", "caps_f9", "keyFunc_doNothing", "caps_f10", "keyFunc_doNothing", "caps_f11", "keyFunc_doNothing", "caps_f12", "keyFunc_switchClipboard",
        "caps_lalt_a", "keyFunc_moveWordLeft(3)", "caps_lalt_b", "keyFunc_moveDown(30)", "caps_lalt_c", "keyFunc_copy_2", "caps_lalt_d", "keyFunc_moveDown(3)", "caps_lalt_e", "keyFunc_moveUp(3)", "caps_lalt_f", "keyFunc_moveRight(5)", "caps_lalt_g", "keyFunc_moveWordRight(3)", "caps_lalt_h", "keyFunc_selectWordLeft(3)", "caps_lalt_i", "keyFunc_selectUp(3)", "caps_lalt_j", "keyFunc_selectLeft(5)", "caps_lalt_k", "keyFunc_selectDown(3)", "caps_lalt_l", "keyFunc_selectRight(5)", "caps_lalt_m", "keyFunc_doNothing", "caps_lalt_n", "keyFunc_selectDown(30)", "caps_lalt_o", "keyFunc_selectToPageEnd", "caps_lalt_p", "keyFunc_moveToPageBeginning", "caps_lalt_q", "keyFunc_doNothing", "caps_lalt_r", "keyFunc_forwardDeleteWord", "caps_lalt_s", "keyFunc_moveLeft(5)", "caps_lalt_t", "keyFunc_moveUp(30)", "caps_lalt_u", "keyFunc_selectToPageBeginning", "caps_lalt_v", "keyFunc_paste_2", "caps_lalt_w", "keyFunc_deleteWord", "caps_lalt_x", "keyFunc_cut_2", "caps_lalt_y", "keyFunc_selectUp(30)", "caps_lalt_z", "keyFunc_doNothing",
        "caps_lalt_backquote", "keyFunc_doNothing", "caps_lalt_1", "keyFunc_winbind_binding(1)", "caps_lalt_2", "keyFunc_winbind_binding(2)", "caps_lalt_3", "keyFunc_winbind_binding(3)", "caps_lalt_4", "keyFunc_winbind_binding(4)", "caps_lalt_5", "keyFunc_winbind_binding(5)", "caps_lalt_6", "keyFunc_winbind_binding(6)", "caps_lalt_7", "keyFunc_winbind_binding(7)", "caps_lalt_8", "keyFunc_winbind_binding(8)", "caps_lalt_9", "keyFunc_winbind_binding(9)", "caps_lalt_0", "keyFunc_winbind_binding(10)", "caps_lalt_minus", "keyFunc_doNothing", "caps_lalt_equal", "keyFunc_doNothing", "caps_lalt_backspace", "keyFunc_deleteAll", "caps_lalt_tab", "keyFunc_doNothing", "caps_lalt_leftSquareBracket", "keyFunc_deleteToPageBeginning", "caps_lalt_rightSquareBracket", "keyFunc_doNothing", "caps_lalt_backslash", "keyFunc_doNothing", "caps_lalt_semicolon", "keyFunc_doNothing", "caps_lalt_quote", "keyFunc_doNothing", "caps_lalt_enter", "keyFunc_doNothing", "caps_lalt_comma", "keyFunc_selectCurrentLine", "caps_lalt_dot", "keyFunc_selectWordRight(3)", "caps_lalt_slash", "keyFunc_deleteToPageEnd", "caps_lalt_space", "keyFunc_doNothing", "caps_lalt_ralt", "keyFunc_doNothing",
        "caps_win_1", "keyFunc_winbind_binding(1)", "caps_win_2", "keyFunc_winbind_binding(2)", "caps_win_3", "keyFunc_winbind_binding(3)", "caps_win_4", "keyFunc_winbind_binding(4)", "caps_win_5", "keyFunc_winbind_binding(5)", "caps_win_6", "keyFunc_winbind_binding(6)", "caps_win_7", "keyFunc_winbind_binding(7)", "caps_win_8", "keyFunc_winbind_binding(8)", "caps_win_9", "keyFunc_winbind_binding(9)", "caps_win_0", "keyFunc_winbind_binding(10)",
        "caps_lalt_wheelUp", "keyFunc_mouseSpeedIncrease", "caps_lalt_wheelDown", "keyFunc_mouseSpeedDecrease"
    )
    for key in ["caps_lalt_f1", "caps_lalt_f2", "caps_lalt_f3", "caps_lalt_f4", "caps_lalt_f5", "caps_lalt_f6", "caps_lalt_f7", "caps_lalt_f8", "caps_lalt_f9", "caps_lalt_f10", "caps_lalt_f11", "caps_lalt_f12"]
        defaults[key] := "keyFunc_doNothing"
    return defaults
}

MakeActionHandler(actionKey) {
    return (*) => RunLayerAction(actionKey)
}

RegisterCapsHotkeys() {
    ; Keep CapsLock as one blocking hotkey, like the reference implementation.
    ; Waiting for release here prevents the native CapsLock toggle and keeps the
    ; layer active for the complete key-hold interval.
    Hotkey("CapsLock", CapsLockPress)
    Hotkey("<!CapsLock", CapsLockWithModifierPress)
    Hotkey("#CapsLock", CapsLockWithModifierPress)

    Hotkey("$^v", PasteSystemHotkey)
    RegisterCapsLayerHotkeys()
}

; Register the complete layer once and use a condition to activate it only
; while CapsLock is held. This follows the reference project's #If CapsLock
; layout and leaves ordinary shortcuts, including Alt+V, available at idle.
RegisterCapsLayerHotkeys() {
    global CapsLockHeld, LayerKeyNames
    HotIf(CapsLockLayerActive)
    try {
        for physicalKey, suffix in LayerKeyNames
            Hotkey(physicalKey, MakeActionHandler("caps_" . suffix))
        Hotkey("LAlt", (*) => 0)

        for physicalKey, suffix in LayerKeyNames
            Hotkey("<!" . physicalKey, MakeActionHandler("caps_lalt_" . suffix))
        Hotkey("<!WheelUp", MakeActionHandler("caps_lalt_wheelUp"))
        Hotkey("<!WheelDown", MakeActionHandler("caps_lalt_wheelDown"))

        for digit in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
            Hotkey("#" . digit, MakeActionHandler("caps_win_" . digit))
        DebugLog("Caps layer static registration complete")
    } finally {
        HotIf()
    }
}

PasteSystemHotkey(*) {
    global PasteSystemHotkeyRunning
    if PasteSystemHotkeyRunning {
        DebugLog("Ctrl+V re-entry ignored")
        return
    }
    PasteSystemHotkeyRunning := true
    try {
        DebugLog("Ctrl+V hotkey received")
        if ClipboardEnabled()
            keyFunc_pasteSystem()
        else
            SendInput("^v")
    } finally {
        PasteSystemHotkeyRunning := false
    }
}

CapsLockLayerActive(*) {
    global CapsLockHeld
    ; The layer follows the physical key and nothing else. The reference project
    ; clears its CapsLock flag only for the duration of opening qbar and restores
    ; it immediately after, so CapsLock+ shortcuts stay usable while the panel is
    ; up. Typing into the panel is unaffected either way, because typing never
    ; holds CapsLock.
    ;
    ; The one exception is handled where it belongs: keyFunc_qbar itself stands
    ; down while the chat or translate panel is the active window, so an
    ; uppercase Q cannot drop qbar onto the typing panel.
    return CapsLockHeld
}

CapsLockPress(*) {
    HandleCapsLockPress(true)
}

CapsLockWithModifierPress(*) {
    ; Alt+CapsLock and Win+CapsLock enter the layer but do not invoke the
    ; single-tap action when released, matching the reference behavior.
    HandleCapsLockPress(false)
}

HandleCapsLockPress(runTapAction) {
    global CapsLockHeld, CapsLockUsed, CtrlZPending, WinTapedX, KeySet
    if CapsLockHeld {
        DebugLog("CapsLock press ignored: layer already held")
        KeyWait("CapsLock")
        return
    }

    CapsLockHeld := true
    CapsLockUsed := false
    CtrlZPending := true
    ; The reference implementation only treats a release within 300ms as a
    ; tap (setCapsLock2 timer), so a long hold never fires press_caps.
    tapPending := runTapAction
    SetTimer(() => (tapPending := false), -300)
    DebugLog("CapsLockDown tapAction=" . runTapAction)

    ; The reference project keeps this handler alive until CapsLock is up.
    ; That blocks the native toggle and makes the condition-based layer
    ; available for every key pressed during the hold.
    try {
        KeyWait("CapsLock")
    } finally {
        CapsLockHeld := false
        DebugLog("CapsLockUp used=" . CapsLockUsed . " tapAction=" . tapPending)

        if WinTapedX != -1
            winsSort(WinTapedX)
        if tapPending && !CapsLockUsed
            RunConfiguredAction(KeySet.Has("press_caps") ? KeySet["press_caps"] : "keyFunc_toggleCapsLock")
        CapsLockUsed := false
    }
}

RunLayerAction(actionKey) {
    global CapsLockUsed, KeySet, MathBoardOpen, MathKeypad
    CapsLockUsed := true
    DebugLog("Layer action=" . actionKey)
    if MathBoardOpen && SubStr(actionKey, 1, 5) = "caps_" && !InStr(actionKey, "lalt") {
        suffix := SubStr(actionKey, 6)
        if MathKeypad.Has(suffix) {
            SendText(MathKeypad[suffix])
            return
        }
    }
    action := KeySet.Has(actionKey) ? KeySet[actionKey] : "keyFunc_doNothing"
    RunConfiguredAction(action)
}
