; qbar WebView2 panel lifecycle and page messaging.

QbarEnsureWebView() {
    global QbarHost
    pagePath := A_ScriptDir . "\pages\qbar.html"
    if IsObject(QbarHost) {
        try {
            PanelHostEnsure(QbarHost)
            return true
        } catch as existingError {
            PanelHostHide(QbarHost)
            DebugLog("qbar webview failed")
            ShowMsg("WebView2 initialization failed: " . existingError.Message, 5000)
            return false
        }
    }

    QbarHost := PanelHostCreate(pagePath, "qbar", Map(
        "guiOptions", "+AlwaysOnTop +ToolWindow -Caption",
        "dataPath", A_Temp . "\CapsLockPlusQbarWebView2",
        "initialShow", "x" . QbarOffscreen . " y" . QbarOffscreen
            . " w" . QbarWidth . " h" . QbarCollapsedHeight() . " NA",
        "callbacks", Map(
            "close", QbarHide,
            "escape", QbarHide,
            "navigation", QbarNavigationCompleted,
            "message", QbarWebMessageReceived)))

    try {
        PanelHostEnsure(QbarHost)
        DebugLog("Qbar WebView2 ready")
        return true
    } catch as webViewError {
        PanelHostHide(QbarHost)
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

QbarNavigationCompleted(host, sender, args) {
    global QbarVisible
    DebugLog("Qbar navigation completed success=" . PanelHostPageReady(host))
    if !PanelHostPageReady(host) {
        try ShowMsg("Qbar page failed to load (" . args.WebErrorStatus . ").", 4000)
        return
    }
    if QbarVisible {
        QbarPushLanguage()
        QbarStartIndexLoad()
    }
}

QbarShutdown(*) {
    global QbarHost, QbarVisible, QbarOpen
    global QbarIndexReady, QbarIndexLoading
    QbarVisible := false
    QbarOpen := false
    QbarIndexReady := false
    QbarSearchCancel()
    QbarCancelIconQueue()
    SetTimer(QbarWarmIndex, 0)
    QbarIndexLoading := false
    PanelHostDestroy(QbarHost)
    QbarHost := 0
    try IconGdiplusStop()
}

; ---------------------------------------------------------------------------
; Page -> AHK
; ---------------------------------------------------------------------------

; Page payloads arrive as JSON (the pages post JSON.stringify'd objects);
; parse once and read the fields through LLMMsgField.

QbarWebMessageReceived(sender, args) {
    global QbarQuerySeq, QbarPageQueryId
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    messageType := LLMMsgField(msg, "type")
    if messageType = "query" {
        text := LLMMsgField(msg, "text")
        QbarQuerySeq += 1
        querySeq := QbarQuerySeq
        pageQueryIdValid := false
        pageQueryId := LLMMsgNumber(msg, "queryId", &pageQueryIdValid, 0, true)
        if !pageQueryIdValid
            return
        QbarPageQueryId := pageQueryId
        DebugLog("Qbar query received")
        DebugLogPrivate("Qbar query", text)
        SetTimer(QbarQuery.Bind(text, querySeq, pageQueryId), -1)
    } else if messageType = "execute" {
        text := LLMMsgField(msg, "text")
        selected := LLMMsgField(msg, "selected")
        selectedType := LLMMsgField(msg, "selectedType")
        sessionId := LLMMsgField(msg, "sessionId")
        candidateId := LLMMsgField(msg, "candidateId")
        commandId := LLMMsgField(msg, "commandId")
        queryIdValid := false
        queryId := LLMMsgNumber(msg, "queryId", &queryIdValid, 0, true)
        if !queryIdValid
            queryId := 0
        generationValid := false
        registryGeneration := LLMMsgNumber(msg, "registryGeneration", &generationValid, 0, true)
        if !generationValid
            registryGeneration := 0
        ctrlValid := false
        ctrl := LLMMsgBoolean(msg, "ctrl", &ctrlValid, false)
        if !ctrlValid
            ctrl := false
        SetTimer(QbarExecute.Bind(text, selected, ctrl, selectedType, commandId,
            registryGeneration, queryId, sessionId, candidateId), -1)
    } else if messageType = "executeHistory" {
        historyId := LLMMsgField(msg, "historyId")
        pageQueryIdValid := false
        pageQueryId := LLMMsgNumber(msg, "queryId", &pageQueryIdValid, 0, true)
        if !pageQueryIdValid || historyId = ""
            return
        SetTimer(QbarHistoryReplay.Bind(historyId, QbarQuerySeq, pageQueryId), -1)
    } else if messageType = "resize" {
        ; WebView2 may deliver the row count as a JSON number or numeric text.
        ; Reject fractions and malformed values before converting.
        rowsValid := false
        rows := LLMMsgNumber(msg, "text", &rowsValid, 0, true)
        if !rowsValid {
            rowsValid := false
            rows := LLMMsgNumber(msg, "rows", &rowsValid, 0, true)
        }
        if !rowsValid {
            DebugLog("Qbar resize ignored: invalid row count")
            return
        }
        QbarResize(Integer(rows))
    } else if messageType = "ready" {
        ; The page's script is alive; the payload is its viewport size, which
        ; tells a blank panel apart from a zero-sized one.
        DebugLog("Qbar page script ready")
        QbarRefit()
    } else if messageType = "searchKeysReady" {
        ; Key conversion is performed in a deferred turn so the WebView2
        ; callback never owns the potentially large response validation work.
        SetTimer(QbarSearchKeysReady.Bind(msg), -1)
    } else if messageType = "hide" {
        QbarHide()
    }
}

; The first qbar query used to trigger the start-menu scan while the user was
; already typing. That blocks the WebView2 callback during IME composition and
; can turn a Chinese composition such as "你好" into its intermediate pinyin.
; Warm the index before enabling the input instead, with a visible loading row.

QbarStartIndexLoad() {
    global QbarHost, QbarVisible, QbarIndexReady, QbarIndexLoading, QbarSearchState
    if !QbarVisible || !PanelHostPageReady(QbarHost)
        return
    if QbarIndexReady {
        if QbarSearchState = "ready" || QbarSearchState = "degraded"
            QbarFinishIndexLoad()
        else
            QbarSearchStartBuild()
        return
    }
    if QbarIndexLoading
        return
    QbarIndexLoading := true
    DebugLog("Qbar index loading")
    QbarExec("window.setLoading(true," . LLMJsonQuote(
        QbarText("Loading applications…", "正在加载应用列表…")) . ");")
    SetTimer(QbarWarmIndex, -1)
}

QbarWarmIndex(*) {
    global QbarVisible, QbarIndexReady, QbarIndexLoading, QbarStartMenuCache
    if !QbarVisible {
        QbarIndexLoading := false
        return
    }
    ; This is deliberately done before accepting input. QbarStartMenuItems()
    ; caches the result, so normal queries do not repeat the scan.
    try QbarStartMenuItems()
    catch as scanError {
        DebugLog("Qbar index scan failed")
        QbarStartMenuCache := []
    }
    QbarIndexLoading := false
    QbarIndexReady := true
    DebugLog("Qbar index ready")
    QbarSearchStartBuild()
}

QbarFinishIndexLoad() {
    global QbarHost, QbarVisible, QbarPendingText, QbarSearchState
    if !QbarVisible || !PanelHostPageReady(QbarHost)
        return
    if QbarSearchState = "building" || QbarSearchState = "idle"
        return
    QbarExec("window.setLoading(false);window.setInput(" . LLMJsonQuote(QbarPendingText)
        . ");window.focusInput();")
}

QbarRefit() {
    global QbarHost
    if !IsObject(QbarHost)
        return
    PanelHostFill(QbarHost)
    controller := QbarHost["controller"]
    if IsObject(controller)
        try controller.IsVisible := true
}

; ---------------------------------------------------------------------------
; Window sizing
; ---------------------------------------------------------------------------

QbarResize(rows) {
    global QbarHost, QbarCurrentRows, QbarInputHeight, QbarRowHeight, QbarPadding, QbarGap
    rows := Max(0, Min(QbarMaxRows, rows + 0))
    if rows = QbarCurrentRows
        return
    QbarCurrentRows := rows
    if !IsObject(PanelHostGui(QbarHost))
        return
    height := QbarPadding * 2 + QbarInputHeight
        + (rows > 0 ? QbarGap + rows * QbarRowHeight : 0)
    ; The panel never moves, so restating the resting position here is
    ; deterministic: the results grow the window downward instead of the window
    ; drifting. Reading the position back instead only invites it.
    QbarPlace(QbarRestingX(), QbarRestingY(), QbarWidth, height)
    DebugLog("Qbar resize rows=" . rows . " height=" . height)
    PanelHostFill(QbarHost)
}

; The single place geometry is ever applied. Show carries the full rectangle
; rather than Move: the working translate panel positions itself with Show too,
; and one API for every change means identical numbers always land identically.

QbarPlace(x, y, width, height) {
    global QbarHost
    panelGui := PanelHostGui(QbarHost)
    if !IsObject(panelGui)
        return
    try panelGui.Show("x" . x . " y" . y . " w" . width . " h" . height . " NA")
    QbarApplyRegion()
}

; The page can round its own corners but not the window's, so the window is
; clipped to a rounded region -- which crops the WebView2 child along with it.
; Sized from the live client rect so the clip always matches the panel.

QbarApplyRegion() {
    global QbarHost
    panelGui := PanelHostGui(QbarHost)
    if !IsObject(panelGui)
        return
    clientRect := Buffer(16, 0)
    DllCall("GetClientRect", "ptr", panelGui.Hwnd, "ptr", clientRect)
    clientWidth := NumGet(clientRect, 8, "int")
    clientHeight := NumGet(clientRect, 12, "int")
    if clientWidth <= 0 || clientHeight <= 0
        return
    diameter := FixDpi(QbarCornerRadius()) * 2
    region := DllCall("CreateRoundRectRgn", "int", 0, "int", 0
        , "int", clientWidth + 1, "int", clientHeight + 1
        , "int", diameter, "int", diameter, "ptr")
    if !region
        return
    ; SetWindowRgn takes ownership of the region when it succeeds.
    if !DllCall("SetWindowRgn", "ptr", panelGui.Hwnd, "ptr", region, "int", 1)
        DllCall("DeleteObject", "ptr", region)
}

QbarCornerRadius() {
    global QbarCardRadius
    return QbarCardRadius
}

; Place the collapsed bar around the upper third of the screen and let the list
; grow downward from it. Gui.Show sizes are logical pixels, while these screen
; coordinates are physical pixels, so only the position is converted here.

QbarRestingX() {
    return Max(0, Round((A_ScreenWidth - FixDpi(QbarWidth)) / 2))
}

QbarRestingY() {
    return Max(0, Round((A_ScreenHeight - FixDpi(QbarCollapsedHeight())) / 3))
}

QbarCollapsedHeight() {
    global QbarPadding, QbarInputHeight
    return QbarPadding * 2 + QbarInputHeight
}

; ---------------------------------------------------------------------------
; Item index
; ---------------------------------------------------------------------------

; Every item is a Map: short (trigger), label (what the list shows), type
; (search|folder|file|web|app) and value (the ini value / file path / lnk path).

QbarPushLanguage() {
    QbarExec("window.setLanguage(" . LLMJsonQuote(IsChineseLanguage() ? "zh" : "en") . ");")
}
