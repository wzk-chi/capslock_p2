; CapsLock+Q (qbar) — WebView2 launcher panel.
; Ported from the reference implementation (capslock-plus/lib/lib_clQ.ahk) to AHK v2.
; The panel is hosted by WebView2 (qbar.html). This file keeps the shared state
; and stable entry points; qbar behavior is split into focused modules below.

global QbarHost := 0
global QbarVisible := false
global QbarOpen := false            ; re-entrancy guard for QbarShow/QbarHide
global QbarTargetHwnd := 0          ; external window captured before qbar opens
global QbarTargetPid := 0
global QbarTargetSessionId := ""
global QbarIndexReady := false
global QbarIndexLoading := false
global QbarPendingText := ""
global QbarQuerySeq := 0
global QbarPageQueryId := 0
global QbarSessionSerial := 0
global QbarSessionId := ""
global QbarCurrentRows := 0
global QbarStartMenuCache := 0      ; 0 = not scanned yet, otherwise an array
global QbarConfigIndexCache := 0    ; lazily built registry-backed index
global QbarConfigIndexGeneration := 1
global QbarFolderDir := ""
global QbarFolderItems := []
global QbarFutureStack := []        ; forward history for keyFunc_qbar_lowerFolderPath
global QbarIconQueue := []          ; icon keys waiting for incremental extraction
global QbarIconQueued := Map()      ; de-duplicates the pending icon queue
global QbarIconTimer := false       ; one-shot icon extraction timer is armed
global QbarSearchState := "idle"   ; idle|building|ready|degraded
global QbarSearchGeneration := 0
global QbarSearchConfigGeneration := 0
global QbarSearchEntries := []
global QbarSearchEntryById := Map()
global QbarSearchKeys := Map()
global QbarSearchExpectedCount := 0
global QbarSearchTimeoutTimer := 0

global QbarEsSeq := 0               ; bumped per request; late jobs are dropped
global QbarEsJob := 0               ; the one shared es.exe process/retry job
global QbarEsJobId := 0
global QbarEsUseBundled := 0        ; 0 undecided, -1 the user's Everything, 1 the bundled copy
global QbarEsBundledStarted := false ; true only when this session launched the bundled server
global QbarEsBundledState := "unknown" ; unknown|starting|reachable|failed
global QbarEsWarmupDeadline := 0
global QbarEsBundledFailed := false ; start declined; do not prompt again this session

; Panel geometry in logical pixels, mirrored by qbar.html's CSS variables.
; Screen-relative: 420 logical px at 1920x1080, wider on bigger screens and
; never narrower than that default — a command bar reads fine even on small
; laptops, so only the scale-up side adapts.
global QbarWidth := ScreenFitSize(420, 0, 420, 0)[1]
global QbarInputHeight := 34
global QbarRowHeight := 30
global QbarPadding := 10
global QbarGap := 6
global QbarMaxRows := 12
global QbarCardRadius := 12        ; fixed window corner radius
global QbarOffscreen := 30000      ; setup position, kept off every desktop

; ---------------------------------------------------------------------------
; Entry points
; ---------------------------------------------------------------------------

; Stable qbar facade: entry points and shared text helpers.

QbarToggle(*) {
    global QbarVisible
    DebugLog("QbarToggle visible=" . QbarVisible)
    if QbarVisible
        QbarHide()
    else
        QbarShow()
}

QbarShow() {
    global QbarHost, QbarVisible, QbarOpen, QbarPendingText, QbarCurrentRows, QbarTargetHwnd
    global QbarTargetPid, QbarTargetSessionId
    global QbarSessionSerial, QbarSessionId
    if QbarOpen
        return

    QbarSessionSerial += 1
    QbarSessionId := "qbar-" . QbarSessionSerial . "-" . A_TickCount

    activeHwnd := WinGetID("A")
    QbarTargetHwnd := 0
    QbarTargetPid := 0
    QbarTargetSessionId := QbarSessionId
    if activeHwnd && ClipboardHistoryTargetWindowValid(activeHwnd, 0) {
        QbarTargetHwnd := activeHwnd
        try QbarTargetPid := WinGetPID("ahk_id " . activeHwnd)
        catch
            QbarTargetHwnd := 0
    }

    ; "any": a line-wise selection must prefill too, even though it ends with
    ; the newline that strict mode reads as an editor's no-selection
    ; line-copy. A wrong guess here just shows up in the input, one clear
    ; keystroke away from gone.
    QbarPendingText := GetSelectedText("any")
    ; The reference implementation prefixes the selection with a space and puts
    ; the caret in front of it, so a command can be typed ahead of the text.
    if QbarPendingText != ""
        QbarPendingText := " " . QbarPendingText

    if !QbarEnsureWebView()
        return

    QbarVisible := true
    QbarOpen := true
    QbarHost["visible"] := true
    ; Exactly one geometry call for the whole reveal, and it goes through
    ; QbarPlace like every other geometry change. Mixing Move and Show, or
    ; restating the rectangle in a second call, is what let the panel appear
    ; centred and then snap to the lower right.
    QbarCurrentRows := 0
    QbarPlace(QbarRestingX(), QbarRestingY(), QbarWidth, QbarCollapsedHeight())
    panelGui := PanelHostGui(QbarHost)
    if IsObject(panelGui)
        WinActivate("ahk_id " . panelGui.Hwnd)
    PanelHostStartAutoHide(QbarHost, QbarHide)
    SetTimer(QbarTrackExternalTarget, 100)

    if PanelHostPageReady(QbarHost) {
        ; The page keeps its state across hide/show while the window starts
        ; collapsed; make its next render re-report the row count.
        QbarExec("window.resetRows();")
        QbarPushLanguage()
        QbarStartIndexLoad()
    }
    DebugLog("Qbar shown")
}

QbarHide(*) {
    global QbarHost, QbarVisible, QbarOpen, QbarFolderDir, QbarFolderItems, QbarFutureStack
    global QbarIndexLoading, QbarQuerySeq, QbarPageQueryId, QbarSearchState
    QbarVisible := false
    QbarOpen := false
    QbarFolderDir := ""
    QbarFolderItems := []
    QbarFutureStack := []
    QbarQuerySeq += 1
    QbarPageQueryId := 0
    QbarHistoryClearDisplayed()
    QbarCancelIconQueue()
    ; Keep a completed search-key cache across ordinary hide/show cycles. A
    ; build that is still in flight must be cancelled so its late response
    ; cannot install data for a hidden session.
    if QbarSearchState = "building"
        QbarSearchCancel()
    QbarExec("window.resetLoadingSnapshot && window.resetLoadingSnapshot();")
    SetTimer(QbarWarmIndex, 0)
    QbarIndexLoading := false
    SetTimer(QbarTrackExternalTarget, 0)
    PanelHostHide(QbarHost)
}

QbarTrackExternalTarget(*) {
    global QbarVisible, QbarTargetHwnd, QbarTargetPid, QbarTargetSessionId, QbarSessionId
    if !QbarVisible
        return
    activeHwnd := WinGetID("A")
    if activeHwnd && ClipboardHistoryTargetWindowValid(activeHwnd, 0) {
        QbarTargetHwnd := activeHwnd
        try {
            QbarTargetPid := WinGetPID("ahk_id " . activeHwnd)
            QbarTargetSessionId := QbarSessionId
        } catch {
            QbarTargetHwnd := 0
            QbarTargetPid := 0
        }
    } else if activeHwnd && !ClipboardHistoryIsQbarWindow(activeHwnd) {
        ; A different panel in this process is not a valid target and must not
        ; leave the previous external window usable for a later command.
        QbarTargetHwnd := 0
        QbarTargetPid := 0
        QbarTargetSessionId := QbarSessionId
    }
}

QbarExec(script) {
    global QbarHost
    return PanelHostExecute(QbarHost, script)
}

QbarSetInput(text) {
    QbarExec("window.setInput(" . LLMJsonQuote(text) . ");")
}

QbarText(english, chinese) {
    return IsChineseLanguage() ? chinese : english
}

; The reference stores "[short]<optional reminder>" as the ini key and strips
; the reminder for lookups (lib_settings.ahk getShortSetKey).

QbarShortKey(key) {
    return Trim(RegExReplace(key, "\s*<.*>$"))
}

QbarFirstToken(text) {
    return RegExReplace(text, "\s.*$")
}

; Splits a qbar command exactly like the former QbarFirstToken()+SubStr()
; pairs. Only spaces and tabs are trimmed from the argument so selected text
; containing a newline keeps the existing behavior.

QbarSplitCommand(text, &firstToken, &rest) {
    firstToken := QbarFirstToken(text)
    rest := ""
    if firstToken = text
        return false
    rest := Trim(SubStr(text, StrLen(firstToken) + 1), " `t")
    return true
}

; What was typed after a trigger: "bd 键盘" gives "键盘". Empty when the line is
; only the trigger, or does not start with it at all.

QbarSearchArgument(text, trigger) {
    if !QbarSplitCommand(text, &firstToken, &rest) || firstToken != trigger
        return ""
    return rest
}
