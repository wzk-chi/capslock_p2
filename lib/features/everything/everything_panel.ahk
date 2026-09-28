; Everything WebView2 panel lifecycle and page messages.

EverythingEnsureWebView() {
    global EverythingHost, EverythingPanelWidth, EverythingPanelHeight
    global EverythingPanelMinWidth, EverythingPanelMinHeight, EverythingPageReady
    if IsObject(EverythingHost) {
        try {
            PanelHostEnsure(EverythingHost)
            return true
        } catch as existingError {
            PanelHostHide(EverythingHost)
            EverythingPageReady := false
            DebugLog("Everything webview failed")
            ShowMsg("WebView2 initialization failed: " . existingError.Message, 5000)
            return false
        }
    }

    size := ScreenFitSize(EverythingPanelWidth, EverythingPanelHeight,
        EverythingPanelMinWidth, EverythingPanelMinHeight)
    EverythingHost := PanelHostCreate(
        A_ScriptDir . "\pages\everything.html", "capslock_p2 Everything", Map(
            "guiOptions", "+Resize +MinSize640x440 +MinimizeBox +MaximizeBox +SysMenu",
            "dataPath", A_Temp . "\CapsLockPlusEverythingWebView2",
            "initialShow", "x-32000 y-32000 w" . size[1] . " h" . size[2] . " NA",
            "callbacks", Map(
                "close", EverythingHide,
                "escape", EverythingHide,
                "resize", EverythingResize,
                "navigation", EverythingNavigationCompleted,
                "message", EverythingWebMessageReceived)))
    try {
        PanelHostEnsure(EverythingHost)
        return true
    } catch as webViewError {
        EverythingPageReady := false
        PanelHostHide(EverythingHost)
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

EverythingNavigationCompleted(host, sender, args) {
    global EverythingVisible, EverythingPageReady, EverythingIconSent
    EverythingPageReady := PanelHostPageReady(host)
    EverythingCancelIconQueue()
    if EverythingPageReady
        EverythingIconSent := Map()
    DebugLog("Everything navigation completed success=" . EverythingPageReady)
    if !EverythingPageReady {
        try EverythingSetError(EverythingText(
            "WebView2 could not load the Everything panel.",
            "WebView2 未能加载 Everything 面板。"))
        return
    }
    if EverythingVisible {
        EverythingBeginPendingOpen()
        SetTimer(EverythingFocusInput, -1)
    }
}

EverythingResize(targetGui, minMax, width, height) {
    global EverythingHost
    PanelHostResize(EverythingHost, minMax)
}

EverythingWebMessageReceived(sender, args) {
    global EverythingQuerySeq, EverythingCategory, EverythingPageReady
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    messageType := LLMMsgField(msg, "type")
    if messageType = "ready" {
        EverythingPageReady := true
        EverythingBeginPendingOpen()
        return
    }
    if messageType = "query" {
        text := LLMMsgField(msg, "text")
        category := LLMMsgField(msg, "categoryId")
        if !EverythingCategoryValid(category)
            category := EverythingCategory
        immediateValid := false
        immediate := LLMMsgBoolean(msg, "immediate", &immediateValid, false)
        SetTimer(EverythingBeginQuery.Bind(text, category, immediate), -1)
        return
    }
    if messageType = "action" {
        action := LLMMsgField(msg, "action")
        resultId := LLMMsgField(msg, "resultId")
        version := LLMMsgField(msg, "resultsVersion")
        if action = "" || resultId = ""
            return
        SetTimer(EverythingHandleAction.Bind(action, resultId, version), -1)
        return
    }
    if messageType = "cursorMove" {
        ShowSystemCursor()
        return
    }
    if messageType = "hide" {
        EverythingHide()
        return
    }
}

EverythingHide(*) {
    global EverythingVisible, EverythingPendingOpen, EverythingPageReady, EverythingFocusSeenActive
    EverythingVisible := false
    EverythingFocusSeenActive := false
    EverythingPendingOpen := false
    EverythingCancelSearch("panel hidden")
    PanelHostHide(EverythingHost)
    PanelHostStopFocusMonitor(EverythingHost)
}

EverythingCancelSearch(reason := "") {
    global EverythingEsMode, EverythingQueryCallback, EverythingQuerySeq
    EverythingEsMode := false
    EverythingCancelIconQueue()
    EverythingQuerySeq += 1
    if IsObject(EverythingQueryCallback)
        SetTimer(EverythingQueryCallback, 0)
    EverythingQueryCallback := 0
    QbarEsCancelJob(reason)
}

EverythingShutdown(*) {
    global EverythingHost, EverythingVisible, EverythingWindowInitialized, EverythingFocusSeenActive
    global EverythingPageReady, EverythingEsMode, QbarEsBundledStarted
    EverythingVisible := false
    EverythingFocusSeenActive := false
    EverythingPageReady := false
    EverythingEsMode := false
    EverythingCancelSearch("shutdown")
    if QbarEsBundledStarted {
        everythingExe := QbarEsEverythingExe()
        if everythingExe != ""
            try Run(QbarEsQuoteArg(everythingExe) . " -instance "
                . QbarEsQuoteArg(QbarEsInstanceName()) . " -exit")
    }
    PanelHostDestroy(EverythingHost)
    EverythingHost := 0
    EverythingWindowInitialized := false
}
