; CapsLock-layer AHK v2 hotkeys. The complete default layout lives in
; capslock_p2-default.ini and is overlaid by the user's Keys section.

global LayerKeyNames := Map(
    "a", "a", "b", "b", "c", "c", "d", "d", "e", "e", "f", "f", "g", "g", "h", "h", "i", "i", "j", "j", "k", "k", "l", "l", "m", "m", "n", "n", "o", "o", "p", "p", "q", "q", "r", "r", "s", "s", "t", "t", "u", "u", "v", "v", "w", "w", "x", "x", "y", "y", "z", "z",
    "1", "1", "2", "2", "3", "3", "4", "4", "5", "5", "6", "6", "7", "7", "8", "8", "9", "9", "0", "0",
    "F1", "f1", "F2", "f2", "F3", "f3", "F4", "f4", "F5", "f5", "F6", "f6", "F7", "f7", "F8", "f8", "F9", "f9", "F10", "f10", "F11", "f11", "F12", "f12",
    "Space", "space", "Tab", "tab", "Enter", "enter", "Esc", "esc", "Backspace", "backspace", "RAlt", "ralt",
    "-", "minus", "=", "equal", "[", "leftSquareBracket", "]", "rightSquareBracket", "\", "backslash", ";", "semicolon", "'", "quote", ",", "comma", ".", "dot", "/", "slash"
)
LayerKeyNames["SC029"] := "backquote"

global PasteSystemHotkeyRunning := false

BuildKeySet() {
    global KeySet
    KeySet := Map()
    for key, value in ConfigSection("Keys")
        if Trim(String(value)) != ""
            KeySet[key] := value
    DebugLog("KeySet press_caps=" . (KeySet.Has("press_caps") ? KeySet["press_caps"] : "<missing>"))
}

MakeActionHandler(actionKey) {
    return (*) => RunLayerAction(actionKey)
}

RegisterCapsHotkeys() {
    ; Keep CapsLock as one blocking hotkey, like the reference implementation.
    ; Waiting for release here prevents the native CapsLock toggle and keeps the
    ; layer active for the complete key-hold interval.
    Hotkey("CapsLock", CapsLockPress)
    Hotkey("<!CapsLock", CapsLockWithAltPress)

    Hotkey("$^v", PasteSystemHotkey)
    RegisterCapsLayerHotkeys()
}

; Register the complete layer once and use a condition to activate it only
; while the physical CapsLock key is held. This follows the reference
; project's #If CapsLock layout and leaves ordinary shortcuts, including
; Backspace and Alt+V, available at idle.
RegisterCapsLayerHotkeys() {
    global LayerKeyNames
    HotIf(CapsLockLayerActive)
    try {
        for physicalKey, suffix in LayerKeyNames
            Hotkey(physicalKey, MakeActionHandler("caps_" . suffix))
        Hotkey("LAlt", (*) => 0)

        for physicalKey, suffix in LayerKeyNames
            Hotkey("<!" . physicalKey, MakeActionHandler("caps_lalt_" . suffix))
        Hotkey("<!WheelUp", MakeActionHandler("caps_lalt_wheelUp"))
        Hotkey("<!WheelDown", MakeActionHandler("caps_lalt_wheelDown"))

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
    ; Do not depend on the CapsLock hotkey thread reaching its cleanup code.
    ; Long-running panel/clipboard actions can keep that thread alive after the
    ; physical key has already been released. The physical state is the only
    ; reliable boundary for deciding whether a normal key should be blocked.
    return GetKeyState("CapsLock", "P")
}

CapsLockPress(*) {
    HandleCapsLockPress(true)
}

CapsLockWithAltPress(*) {
    ; Alt+CapsLock enters the layer but does not invoke the
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
    global CapsLockUsed, KeySet
    CapsLockUsed := true
    DebugLog("Layer action=" . actionKey)
    action := KeySet.Has(actionKey) ? KeySet[actionKey] : "keyFunc_doNothing"
    RunConfiguredAction(action)
}
