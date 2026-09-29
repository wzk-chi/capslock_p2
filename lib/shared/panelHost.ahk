; Shared WebView2 panel lifecycle.
; Feature modules own their page state and business callbacks. This module owns
; the common GUI/controller/page setup, navigation state, execution guard,
; focus timer and teardown.

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
        "focusMonitor", 0,
        "windowBarNative", false,
        "windowBarPinned", false,
        "navigationHandler", 0,
        "messageHandler", 0,
        "navigationToken", 0,
        "messageToken", 0)

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
        if IsNumber(host["controllerBackColor"])
            try host["controller"].DefaultBackgroundColor := host["controllerBackColor"]
        host["webView"] := host["controller"].CoreWebView2
        host["navigationHandler"] := PanelHostNavigationCompleted.Bind(host)
        host["messageHandler"] := PanelHostWebMessageReceived.Bind(host)
        host["navigationToken"] := host["webView"].add_NavigationCompleted(host["navigationHandler"])
        host["messageToken"] := host["webView"].add_WebMessageReceived(host["messageHandler"])
        PanelHostNavigate(host)
        return true
    } catch as webViewError {
        PanelHostDetachWebViewEvents(host)
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
    DebugLog("panel navigation title=" . host["title"] . " success=" . success)
    callbacks := host["callbacks"]
    if callbacks.Has("navigation")
        callbacks["navigation"].Call(host, sender, args)
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
    host["visible"] := false
    PanelHostStopFocusMonitor(host)
    PanelHostStopAutoHide(host)
    if host.Has("windowBarNative")
        host["windowBarNative"] := false
    if IsObject(host["gui"])
        host["gui"].Hide()
}

PanelHostExecute(host, script) {
    if !IsObject(host) || !host["pageReady"] || !IsObject(host["webView"])
        return false
    try {
        host["webView"].ExecuteScriptAsync(script)
        return true
    } catch {
        DebugLog("panel execute failed title=" . host["title"])
        return false
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
    host["focusMonitor"] := callback
    SetTimer(callback, interval)
    return true
}

; Shared focus-to-hide behavior for transient panels. A feature supplies only
; its hide callback; visibility, first-activation grace, and window-bar
; suppressions are handled here.
PanelHostStartAutoHide(host, hideCallback, options := 0) {
    if !IsObject(host) || !IsObject(hideCallback)
        return false
    options := IsObject(options) ? options : Map()
    PanelHostStopAutoHide(host)
    host["autoHideCallback"] := hideCallback
    host["autoHideGuard"] := options.Has("guard") ? options["guard"] : 0
    host["autoHideRequireActive"] := options.Has("requireActive") && options["requireActive"]
    host["autoHideSeenActive"] := false
    interval := options.Has("interval") ? options["interval"] : 100
    monitor := PanelHostAutoHideMonitor.Bind(host)
    host["autoHideMonitor"] := monitor
    SetTimer(monitor, interval)
    return true
}

PanelHostStopAutoHide(host) {
    if !IsObject(host)
        return
    if host.Has("autoHideMonitor") && IsObject(host["autoHideMonitor"])
        SetTimer(host["autoHideMonitor"], 0)
    if host.Has("autoHideMonitor")
        host["autoHideMonitor"] := 0
    if host.Has("autoHideCallback")
        host["autoHideCallback"] := 0
    if host.Has("autoHideGuard")
        host["autoHideGuard"] := 0
    if host.Has("autoHideSeenActive")
        host["autoHideSeenActive"] := false
}

PanelHostAutoHideMonitor(host, *) {
    if !IsObject(host)
        return
    if !host["visible"] || !IsObject(host["gui"]) {
        PanelHostStopAutoHide(host)
        return
    }
    ; A pinned or native-window panel is intentionally persistent. The timer
    ; remains registered so returning to the custom transient mode resumes
    ; the same behavior without feature-specific monitor code.
    if (host.Has("windowBarPinned") && host["windowBarPinned"])
        return
    if (host.Has("windowBarNative") && host["windowBarNative"])
        return
    guard := host.Has("autoHideGuard") ? host["autoHideGuard"] : 0
    if IsObject(guard) && guard.Call()
        return
    if PanelHostWindowActive(host) {
        host["autoHideSeenActive"] := true
        return
    }
    if host.Has("autoHideRequireActive") && host["autoHideRequireActive"]
        if !host["autoHideSeenActive"]
            return
    hideCallback := host.Has("autoHideCallback") ? host["autoHideCallback"] : 0
    if IsObject(hideCallback)
        hideCallback.Call()
}

PanelHostStopFocusMonitor(host) {
    if !IsObject(host)
        return
    if IsObject(host["focusMonitor"])
        SetTimer(host["focusMonitor"], 0)
    host["focusMonitor"] := 0
}

PanelHostDetachWebViewEvents(host) {
    if !IsObject(host) || !IsObject(host["webView"])
        return
    if host["navigationToken"]
        try host["webView"].remove_NavigationCompleted(host["navigationToken"])
    if host["messageToken"]
        try host["webView"].remove_WebMessageReceived(host["messageToken"])
    host["navigationToken"] := 0
    host["messageToken"] := 0
    host["navigationHandler"] := 0
    host["messageHandler"] := 0
}

PanelHostGui(host) {
    return IsObject(host) ? host["gui"] : 0
}

PanelHostPageReady(host) {
    return IsObject(host) && host["pageReady"]
}

PanelHostWindowActive(host) {
    panelGui := PanelHostGui(host)
    return IsObject(panelGui) && WinActive("ahk_id " . panelGui.Hwnd)
}

PanelHostDestroy(host) {
    if !IsObject(host)
        return
    PanelHostStopFocusMonitor(host)
    PanelHostStopAutoHide(host)
    PanelHostDetachWebViewEvents(host)
    if IsObject(host["gui"])
        try host["gui"].Destroy()
    host["gui"] := 0
    host["controller"] := 0
    host["webView"] := 0
    host["pageReady"] := false
    host["visible"] := false
    host["realized"] := false
}
