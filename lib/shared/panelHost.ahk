; Shared WebView2 panel lifecycle.
; Feature modules own their page state and business callbacks. This module owns
; the common GUI/controller/page setup, navigation state, execution guard,
; focus timer, hidden-page release scheduler and teardown.

; All PanelHost pages share one one-shot timer. Each host stores only its own
; hidden-since time and deadline; the scheduler wakes for the nearest deadline.
global PanelHostRegistry := Map()
global PanelHostRegistrySequence := 0
global PanelHostDestroyRetryMs := 60000

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
        "navigationStartingHandler", 0,
        "navigationHandler", 0,
        "messageHandler", 0,
        "navigationStartingToken", 0,
        "navigationToken", 0,
        "messageToken", 0,
        "acceptedNavigationId", 0,
        "registryId", 0,
        "destroyHiddenAt", 0,
        "destroyDeadline", 0,
        "destroyGeneration", 0)

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
    PanelHostRegister(host)
    return host
}

PanelHostEnsure(host) {
    if !IsObject(host)
        return false
    ; Ensure is called on the path to opening a panel. Cancel expiry before a
    ; due timer can dispose the controller between ensure and show.
    PanelHostCancelDestroyCountdown(host)
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
        host["navigationStartingHandler"] := PanelHostNavigationStarting.Bind(host)
        host["navigationHandler"] := PanelHostNavigationCompleted.Bind(host)
        host["messageHandler"] := PanelHostWebMessageReceived.Bind(host)
        host["navigationStartingToken"] := host["webView"].add_NavigationStarting(host["navigationStartingHandler"])
        host["navigationToken"] := host["webView"].add_NavigationCompleted(host["navigationHandler"])
        host["messageToken"] := host["webView"].add_WebMessageReceived(host["messageHandler"])
        PanelHostNavigate(host)
        return true
    } catch as webViewError {
        PanelHostReleaseWebView(host)
        host["realized"] := false
        PanelHostHide(host)
        throw webViewError
    }
}

PanelHostNavigationStarting(host, sender, args) {
    try {
        uri := args.Uri
        navigationId := args.NavigationId
    } catch {
        try args.Cancel := true
        return
    }
    if !PanelHostIsPageUri(host, uri) {
        args.Cancel := true
        if navigationId = host["acceptedNavigationId"]
            host["acceptedNavigationId"] := 0
        DebugLog("panel navigation blocked title=" . host["title"])
        return
    }
    host["pageReady"] := false
    host["acceptedNavigationId"] := navigationId
}

PanelHostNavigationCompleted(host, sender, args) {
    try navigationId := args.NavigationId
    catch
        navigationId := 0
    if !navigationId || navigationId != host["acceptedNavigationId"]
        return
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
    try source := args.Source
    catch
        return
    if !PanelHostIsPageUri(host, source)
        return
    try message := args.TryGetWebMessageAsString()
    catch
        message := ""
    if message = '{"type":"cursorMove"}' {
        ShowSystemCursor()
        return
    }
    callbacks := host["callbacks"]
    if callbacks.Has("message")
        callbacks["message"].Call(sender, args)
}

PanelHostLoaderPath() {
    return A_ScriptDir . "\WebView2\" . (A_PtrSize = 8 ? "64bit" : "32bit") . "\WebView2Loader.dll"
}

PanelHostPageUrl(pagePath) {
    fullPath := PanelHostNormalizePath(pagePath)
    if fullPath = ""
        throw Error("Could not resolve WebView2 page path")
    urlBuffer := Buffer(65536, 0)
    charCount := 32768
    result := DllCall("Shlwapi\UrlCreateFromPathW", "WStr", fullPath,
        "Ptr", urlBuffer, "UInt*", &charCount, "UInt", 0, "Int")
    if result < 0
        throw Error("Could not create WebView2 page URL")
    return StrGet(urlBuffer, "UTF-16")
}

PanelHostIsPageUri(host, uri) {
    if !IsObject(host) || !host.Has("pagePath") || Type(uri) != "String"
        return false
    uriPath := PanelHostUriPath(uri)
    expectedPath := PanelHostNormalizePath(host["pagePath"])
    return uriPath != "" && expectedPath != "" && StrLower(uriPath) = StrLower(expectedPath)
}

PanelHostUriPath(uri) {
    if !RegExMatch(uri, "i)^file:") || InStr(uri, "?")
        return ""
    fragmentAt := InStr(uri, "#")
    if fragmentAt
        uri := SubStr(uri, 1, fragmentAt - 1)
    pathBuffer := Buffer(65536, 0)
    charCount := 32768
    result := DllCall("Shlwapi\PathCreateFromUrlW", "WStr", uri,
        "Ptr", pathBuffer, "UInt*", &charCount, "UInt", 0, "Int")
    if result < 0
        return ""
    return PanelHostNormalizePath(StrGet(pathBuffer, "UTF-16"))
}

PanelHostNormalizePath(path) {
    if Type(path) != "String" || path = ""
        return ""
    pathBuffer := Buffer(65536, 0)
    charCount := 32768
    result := DllCall("Kernel32\GetFullPathNameW", "WStr", path,
        "UInt", charCount, "Ptr", pathBuffer, "Ptr", 0, "UInt")
    if !result || result >= charCount
        return ""
    return StrGet(pathBuffer, "UTF-16")
}

PanelHostNavigate(host) {
    if !IsObject(host) || !IsObject(host["webView"])
        return
    host["pageReady"] := false
    host["acceptedNavigationId"] := 0
    host["webView"].Navigate(PanelHostPageUrl(host["pagePath"]))
}

PanelHostShow(host, width := 0, height := 0, center := true) {
    if !IsObject(host) || !IsObject(host["gui"])
        return
    PanelHostCancelDestroyCountdown(host)
    host["visible"] := true
    options := ""
    if width > 0
        options .= "w" . width . " "
    if height > 0
        options .= "h" . height . " "
    if center
        options .= "Center"
    host["gui"].Show(Trim(options))
    host["realized"] := true
    ShowSystemCursor()
    PanelHostFill(host)
    PanelHostLogFocus(host, "shown")
}

PanelHostHide(host) {
    if !IsObject(host)
        return
    PanelHostLogFocus(host, "hide-requested")
    wasVisible := host["visible"]
    PanelHostStopFocusMonitor(host)
    PanelHostStopAutoHide(host)
    if IsObject(host["gui"])
        host["gui"].Hide()
    host["visible"] := false
    if host.Has("windowBarNative")
        host["windowBarNative"] := false
    PanelHostLogFocus(host, "hidden")
    ; Repeated hide requests must not extend an already-running countdown.
    ; A never-shown but initialized page still gets a deadline on first hide.
    if wasVisible || !host["destroyHiddenAt"]
        PanelHostStartDestroyCountdown(host)
}

PanelHostRegister(host) {
    global PanelHostRegistry, PanelHostRegistrySequence
    static activationLoggingRegistered := false
    if !activationLoggingRegistered {
        ; Observe focus events independently of the auto-hide timer, including
        ; panels whose feature explicitly disables automatic hiding.
        OnMessage(0x0006, PanelHostActivationChanged) ; WM_ACTIVATE
        activationLoggingRegistered := true
    }
    PanelHostRegistrySequence += 1
    host["registryId"] := PanelHostRegistrySequence
    PanelHostRegistry[host["registryId"]] := host
}

PanelHostActivationChanged(wParam, lParam, msg, hwnd) {
    global PanelHostRegistry, DebugLogging
    if !DebugLogging
        return
    for registryId, host in PanelHostRegistry {
        panelGui := PanelHostGui(host)
        if !IsObject(panelGui)
            continue
        try panelHwnd := panelGui.Hwnd
        catch
            continue ; A GUI may be in the middle of being destroyed.
        if panelHwnd = hwnd {
            PanelHostLogFocus(host, (wParam & 0xFFFF) ? "activated" : "deactivated",
                " otherHwnd=" . lParam . " minimized=" . (wParam >> 16))
            return
        }
    }
}

; Focus diagnostics contain only panel identity, window handles and state,
; and follow the same debug setting as other routine panel logs.
PanelHostLogFocus(host, stage, details := "") {
    global DebugLogging
    if !DebugLogging
        return
    panelGui := PanelHostGui(host)
    try hwnd := IsObject(panelGui) ? panelGui.Hwnd : 0
    catch
        hwnd := 0
    foreground := DllCall("GetForegroundWindow", "ptr")
    SplitPath(host["pagePath"], &pageName)
    monitoring := host.Has("autoHideMonitor") && IsObject(host["autoHideMonitor"])
    requireActive := host.Has("autoHideRequireActive") && host["autoHideRequireActive"]
    seenActive := host.Has("autoHideSeenActive") && host["autoHideSeenActive"]
    DebugLog("panel focus panel=" . host["registryId"] . " page=" . pageName
        . " stage=" . stage . " hwnd=" . hwnd . " foreground=" . foreground
        . " active=" . (hwnd != 0 && hwnd = foreground)
        . " visible=" . host["visible"]
        . " windowVisible=" . (hwnd ? DllCall("IsWindowVisible", "ptr", hwnd, "int") : 0)
        . " pinned=" . WindowBarIsPinned(host) . " native=" . WindowBarIsNative(host)
        . " monitoring=" . monitoring . " requireActive=" . requireActive
        . " seenActive=" . seenActive . details)
}

PanelHostLogAutoHideState(host, state) {
    global DebugLogging
    if !DebugLogging
        return
    ; The monitor runs every 100 ms; write only changes in its decision.
    if host.Has("autoHideLogState") && host["autoHideLogState"] = state
        return
    host["autoHideLogState"] := state
    PanelHostLogFocus(host, "auto-hide-" . state)
}

PanelHostUnregister(host) {
    global PanelHostRegistry
    if !IsObject(host) || !host.Has("registryId")
        return
    registryId := host["registryId"]
    if registryId && PanelHostRegistry.Has(registryId)
        PanelHostRegistry.Delete(registryId)
    host["registryId"] := 0
}

PanelHostHasPage(host) {
    return IsObject(host) && IsObject(host["controller"]) && IsObject(host["webView"])
}

PanelHostDestroyDelayMs() {
    return SettingInteger("Global", "webViewDestroyMinutes", 30, 0, 1440) * 60000
}

PanelHostClockMs() {
    return DllCall("GetTickCount64", "uint64")
}

PanelHostStartDestroyCountdown(host) {
    if !IsObject(host)
        return
    if !PanelHostHasPage(host) {
        host["destroyHiddenAt"] := 0
        host["destroyDeadline"] := 0
        host["destroyGeneration"] += 1
        PanelHostRescheduleDestroySweep()
        return
    }
    host["destroyGeneration"] += 1
    host["destroyHiddenAt"] := PanelHostClockMs()
    delay := PanelHostDestroyDelayMs()
    host["destroyDeadline"] := delay > 0 ? host["destroyHiddenAt"] + delay : 0
    PanelHostRescheduleDestroySweep()
}

PanelHostCancelDestroyCountdown(host, reschedule := true) {
    if !IsObject(host)
        return
    host["destroyGeneration"] += 1
    host["destroyHiddenAt"] := 0
    host["destroyDeadline"] := 0
    if reschedule
        PanelHostRescheduleDestroySweep()
}

; Re-read the configured delay from each host's original hide time. A zero
; delay disables pending releases without discarding those hide timestamps.
PanelHostRefreshDestroySchedule() {
    global PanelHostRegistry
    delay := PanelHostDestroyDelayMs()
    for registryId, host in PanelHostRegistry {
        if !host["destroyHiddenAt"]
            continue
        if host["visible"] || !PanelHostHasPage(host) {
            host["destroyDeadline"] := 0
            continue
        }
        host["destroyGeneration"] += 1
        host["destroyDeadline"] := delay > 0 ? host["destroyHiddenAt"] + delay : 0
    }
    PanelHostRescheduleDestroySweep()
}

PanelHostRescheduleDestroySweep() {
    global PanelHostRegistry
    SetTimer(PanelHostDestroySweep, 0)
    earliest := 0
    for registryId, host in PanelHostRegistry {
        deadline := host["destroyDeadline"]
        if !deadline || host["visible"] || !PanelHostHasPage(host)
            continue
        if !earliest || deadline < earliest
            earliest := deadline
    }
    if !earliest
        return
    remaining := Max(1, earliest - PanelHostClockMs())
    SetTimer(PanelHostDestroySweep, -Ceil(remaining))
}

PanelHostDestroySweep(*) {
    global PanelHostRegistry, PanelHostDestroyRetryMs
    now := PanelHostClockMs()
    for registryId, host in PanelHostRegistry {
        deadline := host["destroyDeadline"]
        if !deadline
            continue
        generation := host["destroyGeneration"]
        if host["visible"] || !PanelHostHasPage(host) {
            host["destroyHiddenAt"] := 0
            host["destroyDeadline"] := 0
            continue
        }
        if deadline > now
            continue
        canDestroy := PanelHostCanDestroyPage(host)
        ; The timer may have been interrupted by a show or a setting change
        ; while the page-specific guard ran. Honor the current host state.
        currentDeadline := host["destroyDeadline"]
        currentGeneration := host["destroyGeneration"]
        now := PanelHostClockMs()
        if !currentDeadline || currentDeadline != deadline || currentGeneration != generation || host["visible"]
            continue
        if currentDeadline > now || !PanelHostHasPage(host)
            continue
        if canDestroy {
            PanelHostDestroyPage(host, false)
            DebugLog("panel page released title=" . host["title"])
        } else {
            host["destroyGeneration"] += 1
            host["destroyDeadline"] := now + PanelHostDestroyRetryMs
            DebugLog("panel page release deferred title=" . host["title"])
        }
    }
    PanelHostRescheduleDestroySweep()
}

PanelHostCanDestroyPage(host) {
    callbacks := host["callbacks"]
    if !callbacks.Has("canDestroyPage") || !IsObject(callbacks["canDestroyPage"])
        return true
    try return callbacks["canDestroyPage"].Call(host) != false
    catch as callbackError {
        DebugLog("panel page release guard failed title=" . host["title"]
            . " error=" . callbackError.Message)
        return false
    }
}

PanelHostDestroyPage(host, reschedule := true) {
    if !IsObject(host) || host["visible"]
        return false
    PanelHostCancelDestroyCountdown(host, false)
    PanelHostReleaseWebView(host)
    if reschedule
        PanelHostRescheduleDestroySweep()
    return true
}

PanelHostReleaseWebView(host) {
    if !IsObject(host)
        return
    PanelHostDetachWebViewEvents(host)
    controller := host["controller"]
    if IsObject(controller) {
        try controller.Close()
        catch as closeError
            DebugLog("panel controller close failed title=" . host["title"]
                . " error=" . closeError.Message)
    }
    host["controller"] := 0
    host["webView"] := 0
    host["pageReady"] := false
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
    ; Activation may already have completed before the first timer tick.
    host["autoHideSeenActive"] := PanelHostWindowActive(host) != 0
    interval := options.Has("interval") ? options["interval"] : 100
    monitor := PanelHostAutoHideMonitor.Bind(host)
    host["autoHideMonitor"] := monitor
    host["autoHideLogState"] := ""
    SetTimer(monitor, interval)
    PanelHostLogFocus(host, "auto-hide-start", " interval=" . interval
        . " guard=" . IsObject(host["autoHideGuard"]))
    return true
}

PanelHostStopAutoHide(host) {
    if !IsObject(host)
        return
    if host.Has("autoHideMonitor") && IsObject(host["autoHideMonitor"]) {
        PanelHostLogFocus(host, "auto-hide-stop")
        SetTimer(host["autoHideMonitor"], 0)
    }
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
        PanelHostLogAutoHideState(host, "unavailable")
        PanelHostStopAutoHide(host)
        return
    }
    ; A pinned or native-window panel is intentionally persistent. The timer
    ; remains registered so returning to the custom transient mode resumes
    ; the same behavior without feature-specific monitor code.
    if (host.Has("windowBarPinned") && host["windowBarPinned"]) {
        PanelHostLogAutoHideState(host, "pinned")
        return
    }
    if (host.Has("windowBarNative") && host["windowBarNative"]) {
        PanelHostLogAutoHideState(host, "native")
        return
    }
    guard := host.Has("autoHideGuard") ? host["autoHideGuard"] : 0
    if IsObject(guard) && guard.Call() {
        PanelHostLogAutoHideState(host, "guarded")
        return
    }
    if PanelHostWindowActive(host) {
        host["autoHideSeenActive"] := true
        PanelHostLogAutoHideState(host, "active")
        return
    }
    if PanelHostOwnedDialogActive(host) {
        host["autoHideSeenActive"] := true
        PanelHostLogAutoHideState(host, "owned-dialog")
        return
    }
    if host.Has("autoHideRequireActive") && host["autoHideRequireActive"]
        if !host["autoHideSeenActive"] {
            PanelHostLogAutoHideState(host, "waiting-activation")
            return
        }
    hideCallback := host.Has("autoHideCallback") ? host["autoHideCallback"] : 0
    if IsObject(hideCallback) {
        PanelHostLogAutoHideState(host, "hide")
        hideCallback.Call()
    } else
        PanelHostLogAutoHideState(host, "missing-callback")
}

PanelHostStopFocusMonitor(host) {
    if !IsObject(host)
        return
    if IsObject(host["focusMonitor"])
        SetTimer(host["focusMonitor"], 0)
    host["focusMonitor"] := 0
}

PanelHostDetachWebViewEvents(host) {
    if !IsObject(host)
        return
    webView := host["webView"]
    if IsObject(webView) {
        if host["navigationStartingToken"]
            try webView.remove_NavigationStarting(host["navigationStartingToken"])
        if host["navigationToken"]
            try webView.remove_NavigationCompleted(host["navigationToken"])
        if host["messageToken"]
            try webView.remove_WebMessageReceived(host["messageToken"])
    }
    host["navigationStartingToken"] := 0
    host["navigationToken"] := 0
    host["messageToken"] := 0
    host["navigationStartingHandler"] := 0
    host["navigationHandler"] := 0
    host["messageHandler"] := 0
    host["acceptedNavigationId"] := 0
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

PanelHostOwnedDialogActive(host) {
    panelGui := PanelHostGui(host)
    if !IsObject(panelGui)
        return false
    ; WebView2 file pickers are separate top-level windows. Keep the panel
    ; available while one of its owned dialogs has foreground focus.
    hwnd := panelGui.Hwnd
    owner := DllCall("GetForegroundWindow", "ptr")
    while owner {
        owner := DllCall("GetWindow", "ptr", owner, "uint", 4, "ptr") ; GW_OWNER
        if owner = hwnd
            return true
    }
    return false
}

PanelHostDestroy(host) {
    if !IsObject(host)
        return
    PanelHostStopFocusMonitor(host)
    PanelHostStopAutoHide(host)
    PanelHostCancelDestroyCountdown(host, false)
    host["visible"] := false
    PanelHostReleaseWebView(host)
    if IsObject(host["gui"])
        try host["gui"].Destroy()
    host["gui"] := 0
    host["realized"] := false
    PanelHostUnregister(host)
    PanelHostRescheduleDestroySweep()
}
