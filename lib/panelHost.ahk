; Shared WebView2 panel lifecycle.
; Feature modules own their page state and business callbacks. This module owns
; the common GUI/controller/page setup, navigation state, execution guard,
; focus timer and teardown.

global PanelHostFocusHosts := []

PanelHostCreate(pagePath, title, options := 0) {
    options := IsObject(options) ? options : Map()
    guiOptions := options.Has("guiOptions") ? options["guiOptions"] : "+AlwaysOnTop +Resize +ToolWindow"
    dataPath := options.Has("dataPath") ? options["dataPath"] : A_Temp . "\CapsLockPlusWebView2"
    initialShow := options.Has("initialShow") ? options["initialShow"] : ""
    controllerBackColor := options.Has("controllerBackColor") ? options["controllerBackColor"] : ""
    callbacks := options.Has("callbacks") && IsObject(options["callbacks"])
        ? options["callbacks"] : Map()

    host := Map(
        "pagePath", pagePath,
        "title", title,
        "guiOptions", guiOptions,
        "dataPath", dataPath,
        "initialShow", initialShow,
        "controllerBackColor", controllerBackColor,
        "callbacks", callbacks,
        "gui", 0,
        "controller", 0,
        "webView", 0,
        "pageReady", false,
        "visible", false,
        "realized", false,
        "focusTimer", false,
        "focusMonitor", 0,
        "focusTick", 0,
        "focusLossPending", false,
        "focusLossSerial", 0,
        "focusRegistered", false,
        "focusReturnHwnd", 0,
        "gotFocusHandler", 0,
        "lostFocusHandler", 0,
        "navigationHandler", 0,
        "messageHandler", 0)

    host["gui"] := Gui(guiOptions, title)
    host["gui"].MarginX := 0
    host["gui"].MarginY := 0
    if callbacks.Has("backColor")
        host["gui"].BackColor := callbacks["backColor"]
    if callbacks.Has("close")
        host["gui"].OnEvent("Close", callbacks["close"])
    if callbacks.Has("escape")
        host["gui"].OnEvent("Escape", callbacks["escape"])
    if callbacks.Has("resize")
        host["gui"].OnEvent("Size", callbacks["resize"])
    return host
}

PanelHostEnsure(host) {
    if !IsObject(host)
        return false
    if IsObject(host["gui"]) && IsObject(host["webView"])
        return true

    pagePath := host["pagePath"]
    loaderPath := PanelHostLoaderPath()
    if !FileExist(pagePath)
        throw Error("WebView2 page is missing: " . pagePath)
    if !FileExist(loaderPath)
        throw Error("WebView2Loader.dll is missing: " . loaderPath)

    if !host["realized"] {
        if host["initialShow"] != ""
            host["gui"].Show(host["initialShow"])
        host["realized"] := true
    }

    try {
        host["controller"] := WebView2.CreateControllerAsync(
            host["gui"].Hwnd, 0, host["dataPath"], "", loaderPath
        ).await2(15000)
        host["controller"].Fill()
        host["gotFocusHandler"] := PanelHostGotFocus.Bind(host)
        host["lostFocusHandler"] := PanelHostLostFocus.Bind(host)
        host["controller"].add_GotFocus(host["gotFocusHandler"])
        host["controller"].add_LostFocus(host["lostFocusHandler"])
        callbacks := host["callbacks"]
        if IsNumber(host["controllerBackColor"])
            try host["controller"].DefaultBackgroundColor := host["controllerBackColor"]
        host["webView"] := host["controller"].CoreWebView2
        host["navigationHandler"] := PanelHostNavigationCompleted.Bind(host)
        host["messageHandler"] := PanelHostWebMessageReceived.Bind(host)
        host["webView"].add_NavigationCompleted(host["navigationHandler"])
        host["webView"].add_WebMessageReceived(host["messageHandler"])
        PanelHostNavigate(host)
        return true
    } catch as webViewError {
        host["pageReady"] := false
        host["webView"] := 0
        host["controller"] := 0
        host["realized"] := false
        PanelHostHide(host)
        throw webViewError
    }
}

PanelHostNavigationCompleted(host, sender, args) {
    try success := args.IsSuccess
    catch
        success := false
    host["pageReady"] := success
    callbacks := host["callbacks"]
    if callbacks.Has("navigation")
        callbacks["navigation"].Call(sender, args)
}

PanelHostWebMessageReceived(host, sender, args) {
    callbacks := host["callbacks"]
    if callbacks.Has("message")
        callbacks["message"].Call(sender, args)
}

PanelHostLoaderPath() {
    return A_ScriptDir . "\WebView2\" . (A_PtrSize = 8 ? "64bit" : "32bit") . "\WebView2Loader.dll"
}

PanelHostPageUrl(pagePath) {
    return "file:///" . StrReplace(pagePath, "\", "/")
}

PanelHostNavigate(host) {
    if !IsObject(host) || !IsObject(host["webView"])
        return
    host["pageReady"] := false
    host["webView"].Navigate(PanelHostPageUrl(host["pagePath"]))
}

PanelHostShow(host, width := 0, height := 0, center := true) {
    if !IsObject(host) || !IsObject(host["gui"])
        return
    if !host["visible"]
        PanelHostCaptureReturnFocus(host)
    options := ""
    if width > 0
        options .= "w" . width . " "
    if height > 0
        options .= "h" . height . " "
    if center
        options .= "Center"
    host["gui"].Show(Trim(options))
    host["visible"] := true
    host["realized"] := true
    PanelHostFill(host)
}

PanelHostHide(host) {
    if !IsObject(host)
        return
    DebugLog("WebView2 hide begin title=" . host["title"]
        . " activeBefore=" . WinExist("A"))
    ; A panel that was on screen with a recorded focus target took the keyboard
    ; focus from another window, so hiding it owes that focus back. Note that
    ; the panel is usually already inactive by the time we get here -- the
    ; window underneath became active first, which is what triggered the hide
    ; -- so the test cannot be WinActive on the panel. A hide during setup or
    ; teardown recorded no target and must not reach into another window.
    owesFocus := host["visible"] && host["focusReturnHwnd"]
    host["visible"] := false
    PanelHostBlurActiveElement(host)
    if IsObject(host["gui"])
        host["gui"].Hide()
    DebugLog("WebView2 hide end title=" . host["title"]
        . " activeAfter=" . WinExist("A"))
    ; The window underneath is not necessarily foreground yet -- hiding a
    ; foreground window hands the foreground over asynchronously -- so this
    ; only records the debt. PanelHostSettleFocus discovers the target once the
    ; handoff has actually happened.
    if owesFocus
        PanelHostRestoreFocus(host)
}

; A native GUI can lose focus while the WebView2 document still keeps an
; input element as document.activeElement. Release that document focus before
; handing keyboard input back to the window underneath the panel.
PanelHostBlurActiveElement(host) {
    if !IsObject(host) || !host["pageReady"] || !IsObject(host["webView"])
        return
    try host["webView"].ExecuteScriptAsync(
        "(function(){var e=document.activeElement;"
        . "if(e && e !== document.body && typeof e.blur === 'function') e.blur();})();")
}

PanelHostExecute(host, script) {
    if !IsObject(host) || !host["pageReady"] || !IsObject(host["webView"])
        return false
    try {
        host["webView"].ExecuteScriptAsync(script)
        return true
    } catch
        return false
}

PanelHostGotFocus(host, sender := 0, args := 0) {
    if IsObject(host)
        DebugLog("WebView2 got focus title=" . host["title"]
            . " activeHwnd=" . WinExist("A"))
}

PanelHostLostFocus(host, sender := 0, args := 0) {
    if IsObject(host) {
        DebugLog("WebView2 lost focus title=" . host["title"]
            . " activeHwnd=" . WinExist("A"))
        callbacks := host["callbacks"]
        if callbacks.Has("lostFocus")
            try callbacks["lostFocus"].Call(sender, args)
    }
}

PanelHostFill(host) {
    if !IsObject(host) || !IsObject(host["controller"])
        return
    try host["controller"].Fill()
}

PanelHostResize(host, minMax) {
    if minMax != -1
        PanelHostFill(host)
}

PanelHostMoveFocus(host, focusKind := 0) {
    if !IsObject(host) || !IsObject(host["controller"])
        return
    try host["controller"].MoveFocus(focusKind)
}

PanelHostStartFocusMonitor(host, callback, interval := 100) {
    if !IsObject(host) || !IsObject(callback)
        return false
    PanelHostStopFocusMonitor(host)
    PanelHostEnsureActivationMonitor()
    host["focusMonitor"] := callback
    if !host["focusRegistered"] {
        PanelHostFocusHosts.Push(host)
        host["focusRegistered"] := true
    }
    host["focusTimer"] := true
    host["focusTick"] := PanelHostFocusTick.Bind(host)
    SetTimer(host["focusTick"], interval)
    return true
}

PanelHostStopFocusMonitor(host) {
    if !IsObject(host)
        return
    ; Invalidate any deferred focus-loss callback. A panel can be shown again
    ; before the old timer gets a chance to run; that old callback must not hide
    ; the new instance.
    host["focusLossSerial"] += 1
    host["focusLossPending"] := false
    if IsObject(host["focusTick"])
        SetTimer(host["focusTick"], 0)
    host["focusTick"] := 0
    host["focusTimer"] := false
}

PanelHostEnsureActivationMonitor() {
    static registered := false
    if registered
        return
    OnMessage(0x0006, PanelHostWindowActivate)
    registered := true
}

PanelHostWindowActivate(wParam, lParam, msg, hwnd) {
    global PanelHostFocusHosts
    if (wParam & 0xFFFF) != 0
        return

    externalHwnd := lParam ? lParam : WinExist("A")
    for host in PanelHostFocusHosts {
        if !IsObject(host) || !host["focusTimer"] || !host["visible"] || !IsObject(host["gui"])
            continue
        if host["gui"].Hwnd != hwnd
            continue
        DebugLog("WebView2 focus loss source=wm_activate title=" . host["title"]
            . " panelHwnd=" . host["gui"].Hwnd
            . " externalHwnd=" . externalHwnd
            . " " . DebugGuiFocusState())
        ; Do not hide from inside the activation message: Windows has not
        ; finished handing the foreground over yet, and pulling the panel out
        ; from under it is what leaves the window underneath active but
        ; focusless. Request a deferred hide which waits for the activation
        ; and the click that caused it to settle.
        PanelHostRequestFocusLoss(host, externalHwnd, "wm_activate")
        return
    }
}

PanelHostFocusTick(host) {
    if !IsObject(host) || !host["focusTimer"] || !host["visible"] || !IsObject(host["gui"])
        return
    if WinActive("ahk_id " . host["gui"].Hwnd)
        return
    DebugLog("WebView2 focus loss source=timer title=" . host["title"]
        . " panelHwnd=" . host["gui"].Hwnd
        . " externalHwnd=" . WinExist("A")
        . " " . DebugGuiFocusState())
    PanelHostRequestFocusLoss(host, WinExist("A"), "timer")
}

PanelHostRequestFocusLoss(host, externalHwnd, source := "unknown") {
    if !IsObject(host) || !host["focusTimer"] || !host["visible"] || !IsObject(host["gui"])
        return
    if host["focusLossPending"]
        return
    host["focusLossPending"] := true
    host["focusLossSerial"] += 1
    token := host["focusLossSerial"]
    ; Bind, not a closure: the host and token must survive until the message
    ; pump is free to run this callback.
    SetTimer(PanelHostHandleFocusLoss.Bind(host, externalHwnd, source, token, 0), -1)
}

; Wait for the activation caused by the outside click to finish before hiding
; the panel. A WM_ACTIVATE notification arrives on mouse-down, while the
; target control may not receive focus until mouse-up. Hiding in that gap makes
; the target window temporarily focusless and its first key messages are lost.
PanelHostHandleFocusLoss(host, externalHwnd, source := "unknown", token := 0, attempt := 0) {
    if !IsObject(host)
        return
    if !host["focusTimer"] || !host["visible"] || !IsObject(host["gui"]) {
        host["focusLossPending"] := false
        return
    }
    if token != host["focusLossSerial"]
        return
    activeHwnd := WinExist("A")
    if activeHwnd = host["gui"].Hwnd {
        ; The activation message can return before Windows changes the
        ; foreground window. Give that handoff a few short chances; if the
        ; user brought the panel back, cancel the pending hide.
        if source = "wm_activate" && attempt < 5 {
            SetTimer(PanelHostHandleFocusLoss.Bind(
                host, externalHwnd, source, token, attempt + 1), -10)
        } else {
            host["focusLossPending"] := false
        }
        return
    }

    targetHwnd := activeHwnd ? activeHwnd : externalHwnd
    mouseDown := GetKeyState("LButton", "P") || GetKeyState("RButton", "P")
    focusReady := PanelHostExternalFocusReady(targetHwnd)
    ; Keep the panel alive only while the originating click or activation is in
    ; flight. The bound is a safety valve for unusual windows which never
    ; report a focus handle; they still get the normal hide behavior.
    if attempt < 50 && (mouseDown || !focusReady) {
        SetTimer(PanelHostHandleFocusLoss.Bind(
            host, targetHwnd, source, token, attempt + 1), -10)
        return
    }

    host["focusLossPending"] := false
    ; The window which is active now is the one the user just selected. Do not
    ; restore the window that happened to be focused before the panel opened.
    PanelHostCaptureExternalFocus(host, targetHwnd)
    callback := host["focusMonitor"]
    DebugLog("WebView2 focus loss handle source=" . source
        . " title=" . host["title"]
        . " panelHwnd=" . host["gui"].Hwnd
        . " externalHwnd=" . targetHwnd
        . " attempt=" . attempt
        . " mouseDown=" . mouseDown
        . " focusReady=" . focusReady
        . " " . DebugGuiFocusState())
    ; The callback decides whether to hide; when it does, PanelHostHide returns
    ; the keyboard focus. Nothing is restored here, so a callback that keeps
    ; the panel open (the AI panel's activation grace) cannot hand the focus
    ; away from a panel that is still on screen.
    if IsObject(callback)
        callback.Call()
}

; A top-level window can be foreground before its GUI thread has installed a
; keyboard focus window. This is the state visible in the repro log as
; guiFocus=0. Chromium normally reports its top-level frame as the focus HWND,
; so this check deliberately tests only the thread-level handoff, not a child
; control.
PanelHostExternalFocusReady(hwnd) {
    if !hwnd || WinExist("A") != hwnd
        return false
    threadId := DllCall("GetWindowThreadProcessId", "ptr", hwnd, "ptr", 0, "uint")
    return threadId && PanelHostFocusedHwnd(threadId) != 0
}

; Record the focus state after the outside window has become active. This keeps
; the normal programmatic-hide path's original return target intact while
; making blur-hide follow the window the user actually clicked.
PanelHostCaptureExternalFocus(host, externalHwnd) {
    if !IsObject(host) || !externalHwnd || !IsObject(host["gui"])
        return
    if externalHwnd = host["gui"].Hwnd {
        host["focusReturnHwnd"] := 0
        return
    }
    threadId := DllCall("GetWindowThreadProcessId", "ptr", externalHwnd, "ptr", 0, "uint")
    focus := threadId ? PanelHostFocusedHwnd(threadId) : 0
    host["focusReturnHwnd"] := focus ? focus : externalHwnd
}

; ---------------------------------------------------------------------------
; Keyboard focus handoff
;
; Activating a window -- by WinActivate, by a click, or by hiding whatever was
; in front of it -- makes Windows set the keyboard focus to that window's
; top-level HWND. Re-seating the focus onto the control that had it is the
; application's own job, in its WM_SETFOCUS handling, and not every
; application does it, or does it promptly. Until it happens the window is
; active but has no focused control, so every keystroke is delivered to the
; frame and discarded -- the window looks focused and swallows input.
;
; WinActive() cannot tell those two states apart; it is true in both. That is
; why a panel which takes the foreground records the focused HWND before it
; does so, and puts it back after it hides.
; ---------------------------------------------------------------------------

; The keyboard focus of a thread, or 0 when no window of that thread has it.
; Pass 0 for the foreground window's thread.
PanelHostFocusedHwnd(threadId := 0) {
    info := Buffer(A_PtrSize = 8 ? 72 : 48, 0)
    NumPut("UInt", info.Size, info, 0)
    if !DllCall("GetGUIThreadInfo", "uint", threadId, "ptr", info.Ptr, "int")
        return 0
    return NumGet(info, 8 + A_PtrSize, "Ptr")
}

; True when the foreground thread has a focused window at all. Which window
; that is -- a child control or the top-level frame -- is the application's
; own business: Chromium keeps the focus on its frame and routes keys to the
; page from there, so requiring a child control would call that state broken
; and skip the very repair that is needed. The broken state has no focused
; window whatsoever, which is what the log shows on every focus loss.
PanelHostForegroundHasFocus() {
    return PanelHostFocusedHwnd(0) != 0
}

; Called before the panel takes the foreground.
PanelHostCaptureReturnFocus(host) {
    if !IsObject(host) || !IsObject(host["gui"])
        return
    host["focusReturnHwnd"] := 0
    target := DllCall("GetForegroundWindow", "ptr")
    if !target || target = host["gui"].Hwnd
        return
    threadId := DllCall("GetWindowThreadProcessId", "ptr", target, "ptr", 0, "uint")
    if !threadId
        return
    focus := PanelHostFocusedHwnd(threadId)
    ; Fall back to the window itself when its thread has no focus at all.
    ; SetFocus on a window that already has the focus is a no-op, so keeping
    ; the top-level as the target is safe.
    host["focusReturnHwnd"] := focus ? focus : target
}

; SetFocus only reaches a window whose thread owns the foreground window, or
; shares an input queue with it, so attach to the target's thread first.
PanelHostForceFocus(target) {
    if !target || !DllCall("IsWindow", "ptr", target, "int")
        return
    targetThread := DllCall("GetWindowThreadProcessId", "ptr", target, "ptr", 0, "uint")
    currentThread := DllCall("GetCurrentThreadId", "uint")
    attached := false
    if targetThread && targetThread != currentThread
        attached := DllCall("AttachThreadInput", "uint", currentThread, "uint", targetThread, "int", 1, "int")
    try
        DllCall("SetFocus", "ptr", target, "ptr")
    finally
        if attached
            DllCall("AttachThreadInput", "uint", currentThread, "uint", targetThread, "int", 0)
}

; Hands the keyboard focus back after a hide. Hiding a foreground window hands
; the foreground to the next window asynchronously, so the target cannot be
; read once here: at this instant it may still be the panel itself. Record the
; debt and let the settle pass discover where the focus belongs.
PanelHostRestoreFocus(host) {
    if !IsObject(host)
        return
    target := host["focusReturnHwnd"]
    host["focusReturnHwnd"] := 0
    if !target
        return
    SetTimer(PanelHostSettleFocus.Bind(target, 20), -30)
}

; Waits for the window underneath to become foreground, then puts the keyboard
; focus back on it. Runs only while the foreground is another process's window
; with no focused window at all, so it never fights an application that
; re-seats its own focus, and never touches a window that already has one.
PanelHostSettleFocus(target, remaining) {
    if remaining < 1
        return
    externalHwnd := WinExist("A")
    if !externalHwnd {
        SetTimer(PanelHostSettleFocus.Bind(target, remaining - 1), -30)
        return
    }
    ; Still one of our own windows (this panel mid-hide, or another panel): the
    ; handoff has not happened yet, so wait rather than grabbing the focus.
    try processId := WinGetPID("ahk_id " . externalHwnd)
    catch
        return
    if processId = DllCall("GetCurrentProcessId", "uint") {
        SetTimer(PanelHostSettleFocus.Bind(target, remaining - 1), -30)
        return
    }
    ; Only the window the focus was taken from is ours to repair. If the
    ; foreground went somewhere else, the user moved on and this is not our
    ; handoff to settle.
    if DllCall("GetAncestor", "ptr", target, "uint", 2, "ptr") != externalHwnd
        return
    if PanelHostForegroundHasFocus()
        return
    DebugLog("WebView2 focus restore target=" . externalHwnd
        . " focusHwnd=" . target
        . " attempt=" . (21 - remaining)
        . " " . DebugGuiFocusState())
    PanelHostForceFocus(target)
    ; The application may re-seat its own focus a moment later, so confirm and
    ; retry until it sticks or the user goes elsewhere.
    SetTimer(PanelHostSettleFocus.Bind(target, remaining - 1), -30)
}

PanelHostDestroy(host) {
    if !IsObject(host)
        return
    ; Hide first so the focus debt is settled the same way a normal hide
    ; settles it. Destroying a foreground window leaves the window underneath
    ; active but focusless, which is the same bug by another route.
    PanelHostHide(host)
    PanelHostStopFocusMonitor(host)
    if IsObject(host["gui"])
        try host["gui"].Destroy()
    host["gui"] := 0
    host["controller"] := 0
    host["webView"] := 0
    host["pageReady"] := false
    host["visible"] := false
    host["realized"] := false
}
