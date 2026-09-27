; CapsLock+Q (qbar) — WebView2 launcher panel.
; Ported from the reference implementation (capslock-plus/lib/lib_clQ.ahk) to AHK v2.
; The panel is hosted by WebView2 (qbar.html). This file keeps the shared state
; and stable entry points; qbar behavior is split into focused modules below.

global QbarHost := 0
global QbarGui := 0
global QbarController := 0
global QbarWebView := 0
global QbarPageReady := false
global QbarVisible := false
global QbarOpen := false            ; re-entrancy guard for QbarShow/QbarHide
global QbarFocusTimer := false
global QbarIndexReady := false
global QbarIndexLoading := false
global QbarPendingText := ""
global QbarQuerySeq := 0
global QbarCurrentRows := 0
global QbarStartMenuCache := 0      ; 0 = not scanned yet, otherwise an array
global QbarFolderDir := ""
global QbarFolderItems := []
global QbarFutureStack := []        ; forward history for keyFunc_qbar_lowerFolderPath

; Everything file search state (triggered by "e <query>" and its aliases).
global QbarEsMode := false          ; the current query is an Everything search
global QbarEsPending := ""          ; latest query text waiting for the debounce timer
global QbarEsSeq := 0               ; bumped per request; a flush that finishes late is dropped
global QbarEsLastResults := []      ; previous results, kept visible while the next search runs
global QbarEsPath := ""             ; resolved es.exe path
global QbarEsEverythingPath := ""   ; resolved bundled everything.exe path
global QbarEsUseBundled := 0        ; 0 undecided, -1 the user's Everything, 1 the bundled copy
global QbarEsBundledStarted := false
global QbarEsBundledColdStart := false   ; we just launched it, allow a wait for the index
global QbarEsBundledFailed := false ; start declined; do not prompt again this session
global QbarEsHintShown := false

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
    global QbarHost, QbarGui, QbarVisible, QbarOpen, QbarFocusTimer, QbarPendingText, QbarCurrentRows, QbarEsHintShown
    if QbarOpen
        return

    ; "any": a line-wise selection must prefill too, even though it ends with
    ; the newline that strict mode reads as an editor's no-selection
    ; line-copy. A wrong guess here just shows up in the input, one clear
    ; keystroke away from gone.
    QbarPendingText := GetSelectedText("any")
    QbarEsHintShown := false
    ; The reference implementation prefixes the selection with a space and puts
    ; the caret in front of it, so a command can be typed ahead of the text.
    if QbarPendingText != ""
        QbarPendingText := " " . QbarPendingText

    if !QbarEnsureWebView()
        return

    QbarVisible := true
    QbarOpen := true
    ; Exactly one geometry call for the whole reveal, and it goes through
    ; QbarPlace like every other geometry change. Mixing Move and Show, or
    ; restating the rectangle in a second call, is what let the panel appear
    ; centred and then snap to the lower right.
    QbarCurrentRows := 0
    QbarPlace(QbarRestingX(), QbarRestingY(), FixDpi(QbarWidth), QbarCollapsedHeight())
    QbarHost["visible"] := true
    WinActivate("ahk_id " . QbarGui.Hwnd)
    QbarFocusTimer := PanelHostStartFocusMonitor(QbarHost, QbarFocusMonitor)

    if QbarPageReady {
        ; The page keeps its state across hide/show while the window starts
        ; collapsed; make its next render re-report the row count.
        QbarExec("window.resetRows();")
        QbarPushLanguage()
        QbarStartIndexLoad()
    }
    DebugLog("Qbar shown")
}

QbarHide(*) {
    global QbarHost, QbarGui, QbarVisible, QbarOpen, QbarFocusTimer, QbarFolderDir, QbarFolderItems, QbarFutureStack
    global QbarEsMode, QbarEsLastResults, QbarEsSeq, QbarIndexLoading, QbarQuerySeq
    QbarVisible := false
    QbarOpen := false
    QbarFolderDir := ""
    QbarFolderItems := []
    QbarFutureStack := []
    QbarEsMode := false
    QbarEsLastResults := []
    QbarEsSeq += 1
    QbarQuerySeq += 1
    SetTimer(QbarEsFlush, 0)
    SetTimer(QbarWarmIndex, 0)
    QbarIndexLoading := false
    PanelHostHide(QbarHost)
    PanelHostStopFocusMonitor(QbarHost)
    QbarFocusTimer := false
}

QbarExec(script) {
    global QbarHost
    PanelHostExecute(QbarHost, script)
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

; What was typed after a trigger: "bd 键盘" gives "键盘". Empty when the line is
; only the trigger, or does not start with it at all.

QbarSearchArgument(text, trigger) {
    if QbarFirstToken(text) != trigger
        return ""
    return Trim(SubStr(text, StrLen(trigger) + 1), " `t")
}

QbarUrlEncode(text) {
    static unreserved := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
    if text = ""
        return ""
    byteCount := StrPut(text, "UTF-8") - 1
    byteBuffer := Buffer(byteCount + 1, 0)
    StrPut(text, byteBuffer, "UTF-8")
    result := ""
    Loop byteCount {
        byte := NumGet(byteBuffer, A_Index - 1, "UChar")
        character := Chr(byte)
        if byte < 0x80 && InStr(unreserved, character)
            result .= character
        else
            result .= Format("%{:02X}", byte)
    }
    return result
}
