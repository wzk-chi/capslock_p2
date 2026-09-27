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
        "focusTimer", false,
        "focusMonitor", 0,
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
    if IsObject(host["gui"])
        host["gui"].Hide()
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
    host["focusTimer"] := true
    SetTimer(callback, interval)
    return true
}

PanelHostStopFocusMonitor(host) {
    if !IsObject(host)
        return
    if IsObject(host["focusMonitor"])
        SetTimer(host["focusMonitor"], 0)
    host["focusTimer"] := false
}

PanelHostDestroy(host) {
    if !IsObject(host)
        return
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
