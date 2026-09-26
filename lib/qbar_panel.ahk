; qbar WebView2 panel lifecycle and page messaging.

QbarEnsureWebView() {
    global QbarHost, QbarGui, QbarController, QbarWebView, QbarPageReady
    pagePath := A_ScriptDir . "\pages\qbar.html"
    if IsObject(QbarHost) {
        try {
            PanelHostEnsure(QbarHost)
            QbarSyncHost()
            return true
        } catch as existingError {
            PanelHostHide(QbarHost)
            DebugLog("qbar webview failed: " . existingError.Message)
            ShowMsg("WebView2 initialization failed: " . existingError.Message, 5000)
            return false
        }
    }

    QbarHost := PanelHostCreate(pagePath, "qbar", Map(
        "guiOptions", "+AlwaysOnTop +ToolWindow -Caption",
        "dataPath", A_Temp . "\CapsLockPlusQbarWebView2",
        "initialShow", "x" . QbarOffscreen . " y" . QbarOffscreen
            . " w" . FixDpi(QbarWidth) . " h" . QbarCollapsedHeight() . " NA",
        "callbacks", Map(
            "close", QbarHide,
            "escape", QbarHide,
            "navigation", QbarNavigationCompleted,
            "message", QbarWebMessageReceived)))
    QbarSyncHost()

    try {
        PanelHostEnsure(QbarHost)
        QbarSyncHost()
        DebugLog("Qbar WebView2 ready")
        return true
    } catch as webViewError {
        PanelHostHide(QbarHost)
        QbarSyncHost()
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

QbarSyncHost() {
    global QbarHost, QbarGui, QbarController, QbarWebView, QbarPageReady
    if !IsObject(QbarHost) {
        QbarGui := 0
        QbarController := 0
        QbarWebView := 0
        QbarPageReady := false
        return
    }
    QbarGui := QbarHost["gui"]
    QbarController := QbarHost["controller"]
    QbarWebView := QbarHost["webView"]
    QbarPageReady := QbarHost["pageReady"]
}

QbarNavigationCompleted(sender, args) {
    global QbarHost, QbarPageReady, QbarVisible, QbarPendingText
    try success := args.IsSuccess
    catch
        success := false
    DebugLog("Qbar navigation completed success=" . success)
    QbarPageReady := success
    if IsObject(QbarHost)
        QbarHost["pageReady"] := success
    if !success {
        try ShowMsg("Qbar page failed to load (" . args.WebErrorStatus . ").", 4000)
        return
    }
    if QbarVisible {
        QbarPushLanguage()
        QbarStartIndexLoad()
    }
}

QbarFocusMonitor(*) {
    global QbarHost, QbarGui, QbarVisible, QbarFocusTimer
    if !QbarVisible || !IsObject(QbarGui) {
        PanelHostStopFocusMonitor(QbarHost)
        QbarFocusTimer := false
        return
    }
    if !WinActive("ahk_id " . QbarGui.Hwnd)
        QbarHide()
}

QbarShutdown(*) {
    global QbarHost, QbarGui, QbarController, QbarWebView, QbarVisible, QbarOpen, QbarPageReady, QbarFocusTimer
    global QbarIndexReady, QbarIndexLoading
    global QbarEsBundledStarted
    QbarVisible := false
    QbarOpen := false
    QbarPageReady := false
    QbarIndexReady := false
    PanelHostStopFocusMonitor(QbarHost)
    SetTimer(QbarWarmIndex, 0)
    QbarIndexLoading := false
    ; Stop only the bundled instance this script brought up; the user's own
    ; Everything is never touched. Best effort: an elevated instance may refuse
    ; the exit message from a non-elevated script and stay in the tray, where it
    ; can be exited by hand.
    if QbarEsBundledStarted {
        everythingExe := QbarEsEverythingExe()
        if everythingExe != ""
            try Run(Chr(34) . everythingExe . Chr(34) . " -instance " . QbarEsInstanceName() . " -exit")
    }
    PanelHostDestroy(QbarHost)
    QbarHost := 0
    QbarWebView := 0
    QbarController := 0
    QbarGui := 0
    QbarFocusTimer := false
    try IconGdiplusStop()
}

; ---------------------------------------------------------------------------
; Page -> AHK
; ---------------------------------------------------------------------------

; Page payloads arrive as JSON (the pages post JSON.stringify'd objects);
; parse once and read the fields through LLMMsgField.

QbarWebMessageReceived(sender, args) {
    global QbarQuerySeq
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    messageType := LLMMsgField(msg, "type")
    if messageType = "query" {
        text := LLMMsgField(msg, "text")
        QbarQuerySeq += 1
        querySeq := QbarQuerySeq
        DebugLog("Qbar query received seq=" . querySeq)
        DebugLogPrivate("Qbar query", text)
        SetTimer(() => QbarQuery(text, querySeq), -1)
    } else if messageType = "execute" {
        text := LLMMsgField(msg, "text")
        selected := LLMMsgField(msg, "selected")
        selectedType := LLMMsgField(msg, "selectedType")
        ctrl := LLMMsgField(msg, "ctrl") = "true"
        SetTimer(() => QbarExecute(text, selected, ctrl, selectedType), -1)
    } else if messageType = "resize" {
        ; The page only ever posts a numeric row count, but a non-numeric
        ; payload (observed once as boolean true, arriving reentrantly while
        ; the start-menu scan ran) used to crash this callback twice: the +0
        ; coercion threw, and after the error dialog the resumed thread hit
        ; the unassigned local on the next line. Log and ignore instead.
        raw := LLMMsgField(msg, "text")
        if !IsNumber(raw) {
            DebugLog("Qbar resize ignored: non-numeric payload type=" . Type(raw))
            return
        }
        QbarResize(raw + 0)
    } else if messageType = "ready" {
        ; The page's script is alive; the payload is its viewport size, which
        ; tells a blank panel apart from a zero-sized one.
        DebugLog("Qbar page script ready")
        QbarRefit()
    } else if messageType = "debug" {
        DebugLog("Qbar page debug message received")
    } else if messageType = "hide" {
        QbarHide()
    }
}

; The first qbar query used to trigger the start-menu scan while the user was
; already typing. That blocks the WebView2 callback during IME composition and
; can turn a Chinese composition such as "你好" into its intermediate pinyin.
; Warm the index before enabling the input instead, with a visible loading row.

QbarStartIndexLoad() {
    global QbarVisible, QbarPageReady, QbarIndexReady, QbarIndexLoading
    if !QbarVisible || !QbarPageReady
        return
    if QbarIndexReady {
        QbarFinishIndexLoad()
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
        DebugLog("Qbar index scan failed: " . scanError.Message)
        QbarStartMenuCache := []
    }
    QbarIndexLoading := false
    QbarIndexReady := true
    DebugLog("Qbar index ready")
    QbarFinishIndexLoad()
}

QbarFinishIndexLoad() {
    global QbarVisible, QbarPageReady, QbarPendingText
    if !QbarVisible || !QbarPageReady
        return
    QbarExec("window.setLoading(false);window.setInput(" . LLMJsonQuote(QbarPendingText)
        . ");window.focusInput();")
}

QbarRefit() {
    global QbarHost, QbarController
    if !IsObject(QbarHost)
        return
    PanelHostFill(QbarHost)
    try QbarController.IsVisible := true
}

; ---------------------------------------------------------------------------
; Window sizing
; ---------------------------------------------------------------------------

QbarResize(rows) {
    global QbarHost, QbarGui, QbarController, QbarCurrentRows, QbarInputHeight, QbarRowHeight, QbarPadding, QbarGap
    rows := Max(0, Min(QbarMaxRows, rows + 0))
    if rows = QbarCurrentRows
        return
    QbarCurrentRows := rows
    if !IsObject(QbarGui)
        return
    height := FixDpi(QbarPadding * 2 + QbarInputHeight + (rows > 0 ? QbarGap + rows * QbarRowHeight : 0))
    ; The panel never moves, so restating the resting position here is
    ; deterministic: the results grow the window downward instead of the window
    ; drifting. Reading the position back instead only invites it.
    QbarPlace(QbarRestingX(), QbarRestingY(), FixDpi(QbarWidth), height)
    DebugLog("Qbar resize rows=" . rows . " height=" . height)
    PanelHostFill(QbarHost)
}

; The single place geometry is ever applied. Show carries the full rectangle
; rather than Move: the working translate panel positions itself with Show too,
; and one API for every change means identical numbers always land identically.

QbarPlace(x, y, width, height) {
    global QbarGui
    if !IsObject(QbarGui)
        return
    try QbarGui.Show("x" . x . " y" . y . " w" . width . " h" . height . " NA")
    QbarApplyRegion()
}

; The page can round its own corners but not the window's, so the window is
; clipped to a rounded region -- which crops the WebView2 child along with it.
; Sized from the live client rect so the clip always matches the panel.

QbarApplyRegion() {
    global QbarGui
    if !IsObject(QbarGui)
        return
    clientRect := Buffer(16, 0)
    DllCall("GetClientRect", "ptr", QbarGui.Hwnd, "ptr", clientRect)
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
    if !DllCall("SetWindowRgn", "ptr", QbarGui.Hwnd, "ptr", region, "int", 1)
        DllCall("DeleteObject", "ptr", region)
}

QbarCornerRadius() {
    global QbarCardRadius
    return QbarCardRadius
}

; Centre the collapsed bar, so the input sits in the middle of the screen and the
; list grows downward from it. Centring the expanded panel instead would make the
; input drift every time the results changed height.

QbarRestingX() {
    return Max(0, Round((A_ScreenWidth - FixDpi(QbarWidth)) / 2))
}

QbarRestingY() {
    return Max(0, Round((A_ScreenHeight - QbarCollapsedHeight()) / 2))
}

QbarCollapsedHeight() {
    global QbarPadding, QbarInputHeight
    return FixDpi(QbarPadding * 2 + QbarInputHeight)
}

; ---------------------------------------------------------------------------
; Item index
; ---------------------------------------------------------------------------

; Every item is a Map: short (trigger), label (what the list shows), type
; (search|folder|file|web|app) and value (the ini value / file path / lnk path).

QbarPushLanguage() {
    QbarExec("window.setLanguage(" . LLMJsonQuote(IsChineseLanguage() ? "zh" : "en") . ");")
}

; ---------------------------------------------------------------------------
; Helpers
; ---------------------------------------------------------------------------

