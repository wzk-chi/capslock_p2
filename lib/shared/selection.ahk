; Selection reading through UI Automation and clipboard fallback.

; Copies the active selection and restores the clipboard only after a
; successful copy. A failed copy leaves the clipboard untouched. A copy that ends
; with a newline is ambiguous — a real line-wise selection, or an editor
; copying the current line because nothing is selected (the reference's
; getSelText discarded both; its comment names the trailing newline). The
; mode picks the trade-off:
;   "strict"    keep the reference behavior; a trailing newline means "no
;               real selection". UI Automation returns an empty result
;               directly for a supported control with no active selection;
;               the clipboard path is used only when UIA is unsupported.
;   "multiline" keep certain selections: a copy with an interior newline is
;               a real multi-line selection, a bare line-copy is discarded.
;   "any"       keep everything and just drop the trailing newline; used
;               where a wrong guess is visible and editable (qbar prefill).
GetSelectedText(mode := "strict", waitSeconds := 0.15, allowCtrlCFallback := false) {
    global A_Clipboard, CapsLockHeld

    ; Prefer UI Automation so reading a selection does not touch the system
    ; clipboard.
    uiaSupported := false
    uiaText := GetSelectedTextViaUIA(&uiaSupported)
    if uiaSupported {
        return NormalizeSelectedText(uiaText, mode)
    }

    oldClipboard := ClipboardAll()
    result := ""
    success := false
    copySequence := 0
    suspendToken := ClipboardSuspendBegin("temporary-selection")
    try {
        sequenceBefore := ClipboardSequenceNumber()
        SendInput("^{Insert}")
        success := WaitClipboardSequenceChange(sequenceBefore, waitSeconds, &copySequence)
        if !success && allowCtrlCFallback {
            ; Chrome accepts Ctrl+C more consistently in this state. The
            ; CapsLock layer is briefly stood down so this synthetic C cannot
            ; be routed to caps_c; the original clipboard is restored below only
            ; when this fallback actually produces a new clipboard sequence.
            previousCapsLockHeld := CapsLockHeld
            CapsLockHeld := false
            try {
                sequenceBefore := ClipboardSequenceNumber()
                SendInput("^c")
                success := WaitClipboardSequenceChange(sequenceBefore, waitSeconds, &copySequence)
            } finally {
                CapsLockHeld := previousCapsLockHeld && GetKeyState("CapsLock", "P")
            }
        }
        if success {
            ClipboardHistoryMarkOwnedSequence(copySequence, "temporary-selection")
            result := A_Clipboard
            result := NormalizeSelectedText(result, mode)
        }
    } finally {
        ; A failed copy must not change the clipboard. On success, restore only
        ; while the clipboard still contains this copy; otherwise preserve the
        ; user's newer clipboard contents.
        if success && copySequence && ClipboardSequenceNumber() = copySequence {
            A_Clipboard := oldClipboard
            ClipboardHistoryMarkOwnedSequence(ClipboardSequenceNumber(), "temporary-selection")
        }
        ClipboardSuspendEnd(suspendToken)
    }
    return result
}

NormalizeSelectedText(text, mode) {
    if SubStr(text, -1) != "`n"
        return text
    if mode = "any"
        return RTrim(text, "`r`n")
    if mode = "multiline" && InStr(text, "`n", , 1, 2)
        return text
    return ""
}

; Returns the selected text through IUIAutomationTextPattern. `supported` is
; true when the focused control exposes TextPattern, even when its selection
; is empty. No clipboard fallback is performed here; callers can decide
; whether they want to use the compatibility path below.
GetSelectedTextViaUIA(&supported := false, &hasSelection := false) {
    supported := false
    hasSelection := false
    automation := UIASelectedTextAutomation()
    if !automation
        return ""

    activeHwnd := WinExist("A")
    ; Chromium/Electron creates its accessibility provider lazily. The first
    ; WM_GETOBJECT request can therefore expose the tree before the focused
    ; editor range is populated. Give that provider a couple of short retries;
    ; this keeps the normal native-control path immediate.
    retryCount := 1
    try if WinGetClass("ahk_id " . activeHwnd) = "Chrome_WidgetWin_1"
        retryCount := 3

    sawSupported := false
    Loop retryCount {
        attempt := A_Index
        if attempt > 1
            Sleep(20)
        UIAActivateChromiumAccessibility(activeHwnd, automation, attempt > 1)
        attemptSupported := false
        attemptHasSelection := false
        text := UIAReadFocusedSelection(automation, &attemptSupported, &attemptHasSelection)
        if attemptSupported
            sawSupported := true
        if attemptHasSelection
            hasSelection := true
        if attemptSupported && text != "" {
            supported := true
            return text
        }
    }
    supported := sawSupported
    return ""
}

UIAReadFocusedSelection(automation, &supported := false, &hasSelection := false) {
    supported := false
    hasSelection := false

    focused := 0
    pattern := 0
    ranges := 0
    range := 0
    bstr := 0
    try {
        ComCall(8, automation, "ptr*", &focused := 0)
        if !focused
            return ""
        ComCall(16, focused, "int", 10014, "ptr*", &pattern := 0)
        if !pattern
            return ""
        controlType := UIAElementControlType(focused)
        if !UIAElementSupportsTextSelection(controlType)
            return ""
        supported := true
        ComCall(5, pattern, "ptr*", &ranges := 0)
        if !ranges
            return ""
        count := 0
        ComCall(3, ranges, "int*", &count := 0)
        if count < 1
            return ""
        ComCall(4, ranges, "int", 0, "ptr*", &range := 0)
        if !range
            return ""
        ComCall(12, range, "int", -1, "ptr*", &bstr := 0)
        if !bstr
            return ""
        text := StrGet(bstr, "UTF-16")
        hasSelection := text != ""
        return text
    } catch as uiaError {
        supported := false
        return ""
    } finally {
        if bstr
            try DllCall("oleaut32\SysFreeString", "ptr", bstr)
        if range
            try ObjRelease(range)
        if ranges
            try ObjRelease(ranges)
        if pattern
            try ObjRelease(pattern)
        if focused
            try ObjRelease(focused)
    }
}

UIAElementControlType(element) {
    controlType := 0
    try ComCall(10, element, "int*", &controlType := 0)
    return controlType
}

UIAElementSupportsTextSelection(controlType) {
    ; UIA_TextPattern is meaningful for these controls. Chromium's render host
    ; can expose a non-null TextPattern while still reporting control type 0;
    ; treating that provider as supported turns a real selection into an empty
    ; result and prevents the standard copy fallback from running.
    return controlType = 50004 ; UIA_EditControlTypeId
        || controlType = 50020 ; UIA_TextControlTypeId
        || controlType = 50030 ; UIA_DocumentControlTypeId
}

UIAActivateChromiumAccessibility(hwnd, automation, force := false) {
    static activatedHwnds := Map()
    if !hwnd || (!force && activatedHwnds.Has(hwnd))
        return
    childWindows := []
    try {
        for childHwnd in WinGetControlsHwnd("ahk_id " . hwnd) {
            try className := WinGetClass("ahk_id " . childHwnd)
            catch
                continue
            if InStr(className, "Chrome_RenderWidgetHostHWND")
                childWindows.Push(childHwnd)
        }
    } catch {
    }
    ; Older WebView2 builds expose the host through ControlGetHwnd even when
    ; WinGetControlsHwnd does not return it, so keep the named lookup as a
    ; compatibility fallback.
    try {
        namedChild := ControlGetHwnd("Chrome_RenderWidgetHostHWND1", "ahk_id " . hwnd)
        if namedChild && !HasValue(childWindows, namedChild)
            childWindows.Push(namedChild)
    } catch {
    }
    for childHwnd in childWindows {
        try {
            ; UiaRootObjectId := 1. This asks Chromium/Electron to publish its
            ; accessibility tree before GetFocusedElement is queried.
            DllCall("user32\SendMessageW", "ptr", childHwnd, "uint", 0x003D
                , "ptr", 0, "ptr", 1, "ptr")
            root := 0
            ComCall(6, automation, "ptr", childHwnd, "ptr*", &root := 0)
            if root {
                ObjRelease(root)
                activatedHwnds[hwnd] := true
                return
            }
        } catch {
        }
    }
}

HasValue(values, needle) {
    for value in values
        if value = needle
            return true
    return false
}

UIASelectedTextAutomation() {
    static automation := 0
    if automation
        return automation
    clsid := Buffer(16, 0)
    iid := Buffer(16, 0)
    if DllCall("ole32\CLSIDFromString", "wstr", "{FF48DBA4-60EF-4201-AA87-54103EEF594E}", "ptr", clsid.Ptr) != 0
        return 0
    if DllCall("ole32\CLSIDFromString", "wstr", "{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}", "ptr", iid.Ptr) != 0
        return 0
    hr := DllCall("ole32\CoCreateInstance", "ptr", clsid.Ptr, "ptr", 0
        , "uint", 1, "ptr", iid.Ptr, "ptr*", &automation := 0, "hresult")
    return hr = 0 ? automation : 0
}
