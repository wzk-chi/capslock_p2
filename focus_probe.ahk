#Requires AutoHotkey v2.0
#SingleInstance Force

; Standalone runtime probe for the WebView2 focus/keyboard handoff.
; It observes low-level input and WinEvent notifications, passes every input
; event through unchanged, and never calls SetFocus/WinActivate/Send.

global FocusProbeLogFile := A_ScriptDir . "\focus_probe.log"
global FocusProbeEvents := []
global FocusProbeSequence := 0
global FocusProbeFlushActive := false
global FocusProbeLastSnapshot := ""
global FocusProbeKeyboardCallback := 0
global FocusProbeMouseCallback := 0
global FocusProbeWinEventCallback := 0
global FocusProbeKeyboardHook := 0
global FocusProbeMouseHook := 0
global FocusProbeWinEventHooks := []

Persistent()
OnExit(FocusProbeShutdown)
FocusProbeStart()

FocusProbeStart() {
    global FocusProbeKeyboardCallback, FocusProbeMouseCallback
    global FocusProbeWinEventCallback, FocusProbeKeyboardHook, FocusProbeMouseHook
    global FocusProbeWinEventHooks

    FocusProbeWrite("PROBE_START pid=" . DllCall("GetCurrentProcessId", "uint")
        . " tick=" . A_TickCount)

    try {
        FocusProbeKeyboardCallback := CallbackCreate(FocusProbeKeyboardProc, "F")
        FocusProbeKeyboardHook := DllCall("SetWindowsHookEx"
            , "int", 13 ; WH_KEYBOARD_LL
            , "ptr", FocusProbeKeyboardCallback
            , "ptr", 0
            , "uint", 0
            , "ptr")
        if !FocusProbeKeyboardHook
            throw Error("keyboard hook failed error=" . DllCall("GetLastError"))

        FocusProbeMouseCallback := CallbackCreate(FocusProbeMouseProc, "F")
        FocusProbeMouseHook := DllCall("SetWindowsHookEx"
            , "int", 14 ; WH_MOUSE_LL
            , "ptr", FocusProbeMouseCallback
            , "ptr", 0
            , "uint", 0
            , "ptr")
        if !FocusProbeMouseHook
            throw Error("mouse hook failed error=" . DllCall("GetLastError"))

        FocusProbeWinEventCallback := CallbackCreate(FocusProbeWinEventProc, "F")
        for event in [0x0003, 0x0008, 0x0009, 0x8005] {
            eventHook := DllCall("SetWinEventHook"
                , "uint", event
                , "uint", event
                , "ptr", 0
                , "ptr", FocusProbeWinEventCallback
                , "uint", 0
                , "uint", 0
                , "uint", 0
                , "ptr")
            if eventHook
                FocusProbeWinEventHooks.Push(eventHook)
            else
                FocusProbeQueue("WIN_EVENT_HOOK_ERROR"
                    , "event=" . FocusProbeEventName(event)
                    . " error=" . DllCall("GetLastError"))
        }

        SetTimer(FocusProbeSnapshot, 10)
        SetTimer(FocusProbeFlush, 20)
        ; Safety stop. The probe can be stopped earlier by terminating only its
        ; own process after the reproduction is complete.
        SetTimer(FocusProbeStop, -300000)
        FocusProbeSnapshot()
        FocusProbeQueue("READY", "keyboardHook=" . FocusProbeKeyboardHook
            . " mouseHook=" . FocusProbeMouseHook
            . " winEventHooks=" . FocusProbeWinEventHooks.Length)
        FocusProbeFlush()
    } catch as probeError {
        FocusProbeWrite("PROBE_START_ERROR " . probeError.Message)
        ExitApp(1)
    }
}

FocusProbeStop(*) {
    ExitApp(0)
}

FocusProbeShutdown(*) {
    global FocusProbeKeyboardHook, FocusProbeMouseHook
    global FocusProbeWinEventHooks, FocusProbeKeyboardCallback
    global FocusProbeMouseCallback, FocusProbeWinEventCallback

    SetTimer(FocusProbeSnapshot, 0)
    SetTimer(FocusProbeFlush, 0)
    SetTimer(FocusProbeStop, 0)
    FocusProbeQueue("PROBE_STOP", "tick=" . A_TickCount)
    FocusProbeFlush()

    if FocusProbeKeyboardHook
        DllCall("UnhookWindowsHookEx", "ptr", FocusProbeKeyboardHook)
    if FocusProbeMouseHook
        DllCall("UnhookWindowsHookEx", "ptr", FocusProbeMouseHook)
    for eventHook in FocusProbeWinEventHooks
        if eventHook
            DllCall("UnhookWinEvent", "ptr", eventHook)
    if FocusProbeKeyboardCallback
        CallbackFree(FocusProbeKeyboardCallback)
    if FocusProbeMouseCallback
        CallbackFree(FocusProbeMouseCallback)
    if FocusProbeWinEventCallback
        CallbackFree(FocusProbeWinEventCallback)
}

; ---------------------------------------------------------------------------
; Low-level hooks. These callbacks only enqueue a short record and always call
; CallNextHookEx, so the probe cannot suppress the observed input.
; ---------------------------------------------------------------------------

FocusProbeKeyboardProc(nCode, wParam, lParam) {
    nextResult := DllCall("CallNextHookEx"
        , "ptr", 0, "int", nCode, "uptr", wParam, "ptr", lParam, "ptr")
    if nCode >= 0 {
        vk := NumGet(lParam, 0, "uint")
        scan := NumGet(lParam, 4, "uint")
        flags := NumGet(lParam, 8, "uint")
        event := FocusProbeKeyboardEventName(wParam)
        FocusProbeQueue("KBD"
            , "event=" . event
            . " vk=0x" . Format("{:02X}", vk)
            . " scan=0x" . Format("{:02X}", scan)
            . " flags=0x" . Format("{:02X}", flags)
            . " injected=" . ((flags & 0x10) != 0)
            . " nextResult=" . nextResult
            . " nextBlocked=" . (nextResult != 0))
    }
    return nextResult
}

FocusProbeMouseProc(nCode, wParam, lParam) {
    if nCode >= 0 && FocusProbeIsRelevantMouseEvent(wParam) {
        x := NumGet(lParam, 0, "int")
        y := NumGet(lParam, 4, "int")
        flags := NumGet(lParam, 12, "uint")
        FocusProbeQueue("MOUSE"
            , "event=" . FocusProbeMouseEventName(wParam)
            . " x=" . x . " y=" . y
            . " flags=0x" . Format("{:02X}", flags)
            . " injected=" . ((flags & 0x1) != 0))
    }
    return DllCall("CallNextHookEx"
        , "ptr", 0, "int", nCode, "uptr", wParam, "ptr", lParam, "ptr")
}

FocusProbeWinEventProc(hWinEventHook, event, hwnd, idObject, idChild, idEventThread, msEventTime) {
    if !hwnd
        return
    FocusProbeQueue("WIN_EVENT"
        , "event=" . FocusProbeEventName(event)
        . " hwnd=" . hwnd
        . " object=" . idObject
        . " child=" . idChild
        . " eventThread=" . idEventThread
        . " window=" . FocusProbeWindowSummary(hwnd))
}

; ---------------------------------------------------------------------------
; Focus snapshots. AHK's A_TickCount is used intentionally so the probe's
; timestamps can be compared directly with capslock_p2-debug.log.
; ---------------------------------------------------------------------------

FocusProbeSnapshot(*) {
    global FocusProbeLastSnapshot

    active := DllCall("GetForegroundWindow", "ptr")
    info := Buffer(A_PtrSize = 8 ? 72 : 48, 0)
    NumPut("uint", info.Size, info, 0)
    focus := 0
    capture := 0
    caret := 0
    if DllCall("GetGUIThreadInfo", "uint", 0, "ptr", info.Ptr, "int") {
        active := NumGet(info, 8, "ptr")
        focus := NumGet(info, 8 + A_PtrSize, "ptr")
        capture := NumGet(info, 8 + A_PtrSize * 2, "ptr")
        caret := NumGet(info, 8 + A_PtrSize * 5, "ptr")
    }

    mouseButtons := (GetKeyState("LButton", "P") ? "L1" : "L0")
        . (GetKeyState("RButton", "P") ? "R1" : "R0")
    caps := GetKeyState("CapsLock", "P") ? 1 : 0
    snapshot := active . "|" . focus . "|" . capture . "|" . caret
        . "|" . mouseButtons . "|caps=" . caps
    if snapshot = FocusProbeLastSnapshot
        return
    FocusProbeLastSnapshot := snapshot
    FocusProbeQueue("FOCUS"
        , "active=" . FocusProbeWindowSummary(active)
        . " guiFocus=" . FocusProbeWindowSummary(focus)
        . " guiCapture=" . FocusProbeWindowSummary(capture)
        . " guiCaret=" . FocusProbeWindowSummary(caret)
        . " mouse=" . mouseButtons
        . " capsPhysical=" . caps)
}

FocusProbeQueue(kind, detail) {
    global FocusProbeEvents, FocusProbeSequence
    FocusProbeSequence += 1
    FocusProbeEvents.Push(Format("{} [{}] {} {}"
        , A_TickCount, FocusProbeSequence, kind, detail))
}

FocusProbeFlush(*) {
    global FocusProbeEvents, FocusProbeLogFile, FocusProbeFlushActive
    if FocusProbeFlushActive || !FocusProbeEvents.Length
        return
    FocusProbeFlushActive := true
    try {
        events := FocusProbeEvents
        FocusProbeEvents := []
        text := ""
        for _, line in events
            text .= line . "`n"
        FileAppend(text, FocusProbeLogFile, "UTF-8")
    } catch as flushError {
        ; The probe must not interrupt the keyboard hook if its log file is
        ; temporarily unavailable.
        OutputDebug("focus_probe flush failed: " . flushError.Message)
    } finally {
        FocusProbeFlushActive := false
    }
}

FocusProbeWrite(line) {
    global FocusProbeLogFile
    try FileAppend(Format("{} [0] {}" . "`n", A_TickCount, line)
        , FocusProbeLogFile, "UTF-8")
}

FocusProbeWindowSummary(hwnd) {
    if !hwnd
        return "0"
    try pid := WinGetPID("ahk_id " . hwnd)
    catch
        pid := 0
    try className := WinGetClass("ahk_id " . hwnd)
    catch
        className := "?"
    try title := WinGetTitle("ahk_id " . hwnd)
    catch
        title := "?"
    title := StrReplace(StrReplace(SubStr(title, 1, 80), "`r", " "), "`n", " ")
    title := StrReplace(title, "|", "/")
    return hwnd . ",pid=" . pid . ",class=" . className . ",title=" . title
}

FocusProbeIsRelevantMouseEvent(wParam) {
    return wParam = 0x0201 || wParam = 0x0202
        || wParam = 0x0204 || wParam = 0x0205
        || wParam = 0x0207 || wParam = 0x0208
        || wParam = 0x020A || wParam = 0x020B || wParam = 0x020C
        || wParam = 0x020E || wParam = 0x020F
}

FocusProbeKeyboardEventName(wParam) {
    switch wParam {
        case 0x0100: return "DOWN"
        case 0x0101: return "UP"
        case 0x0104: return "SYS_DOWN"
        case 0x0105: return "SYS_UP"
    }
    return "0x" . Format("{:X}", wParam)
}

FocusProbeMouseEventName(wParam) {
    switch wParam {
        case 0x0201: return "LBUTTON_DOWN"
        case 0x0202: return "LBUTTON_UP"
        case 0x0204: return "RBUTTON_DOWN"
        case 0x0205: return "RBUTTON_UP"
        case 0x0207: return "MBUTTON_DOWN"
        case 0x0208: return "MBUTTON_UP"
        case 0x020A: return "WHEEL"
        case 0x020B: return "XBUTTON_DOWN"
        case 0x020C: return "XBUTTON_UP"
        case 0x020E: return "XBUTTON2_DOWN"
        case 0x020F: return "XBUTTON2_UP"
    }
    return "0x" . Format("{:X}", wParam)
}

FocusProbeEventName(event) {
    switch event {
        case 0x0003: return "FOREGROUND"
        case 0x0008: return "CAPTURE_START"
        case 0x0009: return "CAPTURE_END"
        case 0x8005: return "OBJECT_FOCUS"
    }
    return "0x" . Format("{:X}", event)
}
