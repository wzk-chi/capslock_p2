; Everything WebView2 panel lifecycle and page messages.

EverythingEnsureWebView() {
    global EverythingHost, EverythingPanelWidth, EverythingPanelHeight
    global EverythingPanelMinWidth, EverythingPanelMinHeight
    if IsObject(EverythingHost) {
        try {
            PanelHostEnsure(EverythingHost)
            return true
        } catch as existingError {
            PanelHostHide(EverythingHost)
            DebugLog("Everything webview failed")
            ShowMsg("WebView2 initialization failed: " . existingError.Message, 5000)
            return false
        }
    }

    size := ScreenFitSize(EverythingPanelWidth, EverythingPanelHeight,
        EverythingPanelMinWidth, EverythingPanelMinHeight)
    EverythingHost := PanelHostCreate(
        A_ScriptDir . "\pages\everything.html", "capslock_p2 Everything", Map(
            "guiOptions", "+Resize +MinSize640x440 +MinimizeBox +MaximizeBox +SysMenu +ToolWindow -Caption",
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
        PanelHostHide(EverythingHost)
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

EverythingNavigationCompleted(host, sender, args) {
    global EverythingVisible, EverythingIconSent
    pageReady := PanelHostPageReady(host)
    EverythingCancelIconQueue()
    if pageReady
        EverythingIconSent := Map()
    DebugLog("Everything navigation completed success=" . pageReady)
    if !pageReady {
        try EverythingSetError(EverythingText(
            "WebView2 could not load the Everything panel.",
            "WebView2 未能加载 Everything 面板。"))
        return
    }
    if EverythingVisible {
        WindowBarSyncPageState(host)
        EverythingBeginPendingOpen()
        SetTimer(EverythingFocusInput, -1)
    }
}

EverythingResize(targetGui, minMax, width, height) {
    global EverythingHost
    PanelHostResize(EverythingHost, minMax)
}

EverythingWebMessageReceived(sender, args) {
    global EverythingHost, EverythingQuerySeq, EverythingCategory
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    messageType := LLMMsgField(msg, "type")
    if WindowBarHandleDebugMessage(msg, "everything")
        return
    if WindowBarHandleMessage(EverythingHost, messageType, EverythingHide, 0,
        Map("requireActive", true))
        return
    if messageType = "ready" {
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
        versionValid := false
        version := LLMMsgNumber(msg, "resultsVersion", &versionValid, 0, true)
        if action = "" || resultId = "" || !versionValid
            || Type(version) != "Integer" || version <= 0
            return
        SetTimer(EverythingHandleAction.Bind(action, resultId, version), -1)
        return
    }
}

EverythingHide(*) {
    global EverythingVisible, EverythingPendingOpen
    EverythingVisible := false
    EverythingPendingOpen := false
    EverythingCancelSearch("panel hidden")
    PanelHostHide(EverythingHost)
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
    global EverythingHost, EverythingVisible, EverythingWindowInitialized
    global EverythingEsMode, QbarEsBundledStarted
    EverythingVisible := false
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
