; CapsLock+Q (qbar) — WebView2 launcher panel.
; Ported from the reference implementation (capslock-plus/lib/lib_clQ.ahk) to AHK v2.
; The panel is hosted by WebView2 (qbar.html); AHK owns the item index, the
; filtering rules and the execution rules, the page only renders and reports keys.

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
global QbarCardRadius := 12        ; window corner radius; [QStyle] borderRadius wins
global QbarOffscreen := 30000      ; setup position, kept off every desktop

; ---------------------------------------------------------------------------
; Entry points
; ---------------------------------------------------------------------------

QbarToggle(*) {
    global QbarVisible
    DebugLog("QbarToggle visible=" . QbarVisible)
    if QbarVisible
        QbarHide()
    else
        QbarShow()
}

QbarShow() {
    global QbarGui, QbarVisible, QbarOpen, QbarPendingText, QbarCurrentRows, QbarEsHintShown
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
    WinActivate("ahk_id " . QbarGui.Hwnd)
    SetTimer(QbarFocusMonitor, 100)

    if QbarPageReady {
        ; The page keeps its state across hide/show while the window starts
        ; collapsed; make its next render re-report the row count.
        QbarExec("window.resetRows();")
        QbarPushStyle()
        QbarStartIndexLoad()
    }
    DebugLog("Qbar shown")
}

QbarHide(*) {
    global QbarGui, QbarVisible, QbarOpen, QbarFocusTimer, QbarFolderDir, QbarFolderItems, QbarFutureStack
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
    if IsObject(QbarGui)
        QbarGui.Hide()
    SetTimer(QbarFocusMonitor, 0)
    QbarFocusTimer := false
}

QbarEnsureWebView() {
    global QbarGui, QbarController, QbarWebView, QbarPageReady
    if IsObject(QbarGui) && IsObject(QbarWebView)
        return true

    pagePath := A_ScriptDir . "\pages\qbar.html"
    loaderPath := A_ScriptDir . "\WebView2\" . (A_PtrSize = 8 ? "64bit" : "32bit") . "\WebView2Loader.dll"
    if !FileExist(pagePath) {
        ShowMsg("pages\qbar.html is missing.", 3500)
        return false
    }
    if !FileExist(loaderPath) {
        ShowMsg("WebView2Loader.dll is missing: " . loaderPath, 5000)
        return false
    }

    if !IsObject(QbarGui) {
        QbarGui := Gui("+AlwaysOnTop +ToolWindow -Caption", "qbar")
        QbarGui.MarginX := 0
        QbarGui.MarginY := 0
        QbarGui.OnEvent("Close", QbarHide)
        QbarGui.OnEvent("Escape", QbarHide)
    }
    ; The controller needs a realised, laid-out window before it is created
    ; (the working LLM panel shows its Gui first too). Keep it off every desktop
    ; so the one-time setup through WebView2 never flashes on screen.
    QbarGui.Show("x" . QbarOffscreen . " y" . QbarOffscreen
        . " w" . FixDpi(QbarWidth) . " h" . QbarCollapsedHeight() . " NA")

    try {
        dataPath := A_Temp . "\CapsLockPlusQbarWebView2"
        QbarController := WebView2.CreateControllerAsync(
            QbarGui.Hwnd, 0, dataPath, "", loaderPath
        ).await2(15000)
        QbarController.Fill()
        QbarWebView := QbarController.CoreWebView2
        QbarWebView.add_NavigationCompleted(QbarNavigationCompleted)
        QbarWebView.add_WebMessageReceived(QbarWebMessageReceived)
        QbarPageReady := false
        pageUrl := "file:///" . StrReplace(pagePath, "\", "/")
        DebugLog("Qbar WebView2 ready, navigating to " . pageUrl)
        QbarWebView.Navigate(pageUrl)
        return true
    } catch as webViewError {
        QbarPageReady := false
        QbarWebView := 0
        QbarController := 0
        if IsObject(QbarGui)
            QbarGui.Hide()
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

QbarNavigationCompleted(sender, args) {
    global QbarPageReady, QbarVisible, QbarPendingText
    try success := args.IsSuccess
    catch
        success := false
    DebugLog("Qbar navigation completed success=" . success)
    QbarPageReady := success
    if !success {
        try ShowMsg("Qbar page failed to load (" . args.WebErrorStatus . ").", 4000)
        return
    }
    if QbarVisible {
        QbarPushStyle()
        QbarStartIndexLoad()
    }
}

QbarFocusMonitor(*) {
    global QbarGui, QbarVisible, QbarFocusTimer
    if !QbarVisible || !IsObject(QbarGui) {
        SetTimer(QbarFocusMonitor, 0)
        QbarFocusTimer := false
        return
    }
    if !WinActive("ahk_id " . QbarGui.Hwnd)
        QbarHide()
}

QbarShutdown(*) {
    global QbarGui, QbarController, QbarWebView, QbarVisible, QbarOpen, QbarPageReady
    global QbarIndexReady, QbarIndexLoading
    global QbarEsBundledStarted
    QbarVisible := false
    QbarOpen := false
    QbarPageReady := false
    QbarIndexReady := false
    SetTimer(QbarFocusMonitor, 0)
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
    try QbarWebView := 0
    try QbarController := 0
    try IconGdiplusStop()
    if IsObject(QbarGui) {
        try QbarGui.Destroy()
        QbarGui := 0
    }
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
        DebugLog("Qbar query received seq=" . querySeq . " text=" . text)
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
            DebugLog("Qbar resize ignored: non-numeric payload raw=" . raw)
            return
        }
        QbarResize(raw + 0)
    } else if messageType = "ready" {
        ; The page's script is alive; the payload is its viewport size, which
        ; tells a blank panel apart from a zero-sized one.
        DebugLog("Qbar page script ready viewport=" . LLMMsgField(msg, "text"))
        QbarRefit()
    } else if messageType = "debug" {
        DebugLog("Qbar page " . LLMMsgField(msg, "text"))
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

QbarExec(script) {
    global QbarWebView, QbarPageReady
    if !QbarPageReady || !IsObject(QbarWebView)
        return
    try QbarWebView.ExecuteScriptAsync(script)
    catch
        return
}

; Re-assert the controller's size and visibility. The bounds come from the
; parent's client rect, which can be stale if the window was resized before the
; page finished loading.
QbarRefit() {
    global QbarController
    if !IsObject(QbarController)
        return
    try QbarController.Fill()
    try QbarController.IsVisible := true
}

; ---------------------------------------------------------------------------
; Window sizing
; ---------------------------------------------------------------------------

QbarResize(rows) {
    global QbarGui, QbarController, QbarCurrentRows, QbarInputHeight, QbarRowHeight, QbarPadding, QbarGap
    rows := Max(0, Min(QbarListCount(), rows + 0))
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
    if IsObject(QbarController)
        try QbarController.Fill()
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
    radius := QbarStyleNumber("borderRadius", String(QbarCardRadius)) + 0
    return radius >= 0 ? radius : QbarCardRadius
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
QbarAllItems() {
    items := []
    for item in QbarConfigItems()
        items.Push(item)
    for item in QbarStartMenuItems()
        items.Push(item)
    return items
}

QbarConfigItems() {
    global Config
    items := []
    ; Trigger rows for the built-in commands, so they are discoverable and
    ; Tab-completable like the search engines are. Enter with no argument
    ; arms the trigger and lets the question be typed after it.
    items.Push(Map("short", "q", "label", "q <AI 问答 ai>", "type", "search", "value", ""))
    ; The Everything trigger row, so the alias list in the label makes the file
    ; search discoverable and Tab-completable like the search engines are.
    items.Push(Map("short", "e", "label", "e <文件搜索 everything|find|f>", "type", "search", "value", ""))
    for entry in QbarSearchEntries()
        items.Push(entry)
    if Config.Has("QRun") {
        for key, value in Config["QRun"] {
            if Trim(value) = ""
                continue
            ; Resolve *RunAs / quoting / parameters once: the resolved target
            ; decides both the row type and its icon key.
            runString := "", runAsAdmin := false, parameters := ""
            resolved := ExtractSetString(value, &runString, &runAsAdmin, &parameters)
            if resolved = ""
                resolved := Trim(value)
            isFolder := CheckStringType(resolved) = "folder"
            items.Push(Map(
                "short", QbarShortKey(key),
                "label", key,
                "type", isFolder ? "folder" : "file",
                "value", value,
                "icon", isFolder ? "folder" : IconKeyForPath(resolved)
            ))
        }
    }
    if Config.Has("QWeb") {
        for key, value in Config["QWeb"] {
            if Trim(value) = ""
                continue
            items.Push(Map("short", QbarShortKey(key), "label", key, "type", "web", "value", value))
        }
    }
    return items
}

; [QSearch] entries, plus the built-in engines for every trigger the settings do
; not define -- so adding one entry replaces only the trigger it names rather
; than dropping the whole set. The special key "default" is never listed.
QbarSearchEntries() {
    global Config
    entries := []
    configured := Map()
    if Config.Has("QSearch") {
        for key, value in Config["QSearch"] {
            if Trim(value) = "" || QbarShortKey(key) = "default"
                continue
            short := QbarShortKey(key)
            configured[StrLower(short)] := true
            entries.Push(Map("short", short, "label", key, "type", "search", "value", value))
        }
    }

    defaults := [
        Map("key", "bd",   "label", "bd <百度>",      "value", "https://www.baidu.com/s?wd={q}"),
        Map("key", "g",    "label", "g <谷歌 gg>",    "value", "https://www.google.com/search?q={q}"),
        Map("key", "bing", "label", "bing <必应>",    "value", "https://www.bing.com/search?q={q}"),
        Map("key", "wk",   "label", "wk <维基百科>",  "value", "https://zh.wikipedia.org/w/index.php?search={q}"),
        Map("key", "m",    "label", "m <MDN mdn>",    "value", "https://developer.mozilla.org/zh-CN/search?q={q}")
    ]
    ; "s" is the plain one-word trigger. Its engine follows the interface
    ; language, since Bing and Google are each the better default where they are
    ; the one the system already leans on.
    if IsChineseLanguage()
        defaults.InsertAt(1, Map("key", "s", "label", "s <搜索>", "value", "https://www.bing.com/search?q={q}"))
    else
        defaults.InsertAt(1, Map("key", "s", "label", "s <search>", "value", "https://www.google.com/search?q={q}"))
    for entry in defaults {
        if configured.Has(StrLower(entry["key"]))
            continue
        entries.Push(Map("short", entry["key"], "label", entry["label"], "type", "search", "value", entry["value"]))
    }
    return entries
}

QbarStartMenuItems() {
    global QbarStartMenuCache
    if IsObject(QbarStartMenuCache)
        return QbarStartMenuCache
    items := []
    ; The same program is normally registered in both start menus, so its name
    ; repeats; the reference keyed its collection by label and kept the first,
    ; which is what makes one row per program. A label is only claimed once an
    ; entry has passed the filters, so a stale shortcut cannot hide a good one.
    seen := Map()
    for base in [A_StartMenu, A_StartMenuCommon] {
        try {
            Loop Files, base . "\*.lnk", "R" {
                name := A_LoopFileName
                ; The reference implementation skips uninstall stubs.
                if InStr(name, ".ini") || InStr(name, "卸载") || InStr(name, "uninstall")
                    continue
                label := RegExReplace(name, "i)\.lnk$")
                if seen.Has(label)
                    continue
                ; FileGetShortcut writes into output variables in v2 rather than
                ; returning an object, and it throws when the link cannot be read.
                target := ""
                try FileGetShortcut(A_LoopFileFullPath, &target)
                catch
                    continue
                if !RegExMatch(target, "i)exe$")
                    continue
                seen[label] := true
                items.Push(Map(
                    "short", label,
                    "label", label,
                    "type", "app",
                    "value", A_LoopFileFullPath,
                    "icon", IconKeyForPath(A_LoopFileFullPath),
                    "exe", target
                ))
            }
        } catch as scanError {
            DebugLog("Start menu scan failed for " . base . ": " . scanError.Message)
        }
    }
    DebugLog("Start menu items=" . items.Length)
    QbarStartMenuCache := items
    return items
}

; ---------------------------------------------------------------------------
; Query / filtering
; ---------------------------------------------------------------------------

QbarQuery(text, querySeq := 0) {
    global QbarVisible, QbarEsMode, QbarIndexReady, QbarQuerySeq
    if !QbarVisible || !QbarIndexReady
        return
    if querySeq && querySeq != QbarQuerySeq {
        DebugLog("Qbar query stale seq=" . querySeq . " latest=" . QbarQuerySeq . " text=" . text)
        return
    }
    text := Trim(text, " `t")
    DebugLog("Qbar query apply seq=" . querySeq . " text=" . text)
    if text = "" {
        QbarEsMode := false
        QbarSendResults([], false)
        return
    }
    firstToken := QbarFirstToken(text)
    ; "e <query>" (and its aliases) searches files; a configured trigger of the
    ; same name still wins.
    if firstToken != text && !QbarConfigShortKeyExists(firstToken) && QbarEsAlias(firstToken) {
        QbarEsRequest(text, firstToken)
        return
    }
    QbarEsMode := false
    if QbarIsFolderQuery(text) {
        items := QbarFilterFolder(text)
        ; An empty folder still shows one row, like the reference does.
        placeholder := (items.Length = 0 && QbarLeafOf(text) = "")
            ? QbarText("(empty folder)", "（空文件夹）")
            : ""
        QbarSendResults(items, true, placeholder)
        return
    }
    results := QbarFilterItems(text)
    ; The AI option is the default first row whenever the line is not an
    ; explicit command -- that is, nothing matched a trigger exactly (no
    ; pinned row). Enter then asks the assistant with the line as-is, while
    ; partial matches stay right below for arrow-down selection. The row
    ; carries the typed text as its short key, so executing it asks exactly
    ; that.
    explicitCommand := false
    for item in results {
        if item.Has("pinned") && item["pinned"] {
            explicitCommand := true
            break
        }
    }
    if !explicitCommand && Trim(text) != ""
        results.InsertAt(1, Map(
            "short", text,
            "label", QbarText("Ask AI  ⏎  ", "AI 问答  ⏎  ") . text,
            "type", "ai",
            "pinned", true,
            "icon", ""
        ))
    QbarSendResults(results, false)
}

; A configured trigger always wins over path browsing, matching the reference
; implementation's check before it switches into folder-browse mode.
QbarIsFolderQuery(text) {
    if QbarConfigShortKeyExists(text) || QbarConfigShortKeyExists(QbarFirstToken(text))
        return false
    return QbarFolderOf(text) != ""
}

QbarFilterItems(text) {
    matchStrLeft := QbarFirstToken(text)
    glob := QbarGlobToRegEx(text)
    results := []
    for item in QbarAllItems() {
        short := item["short"]
        if !(RegExMatch(item["label"], glob) || short = matchStrLeft)
            continue
        ; An exact trigger match floats to the top (reference: column 3 pinning).
        pinned := short = matchStrLeft
        results.Push(Map(
            "short", short,
            "label", item["label"],
            "type", item["type"],
            "pinned", pinned,
            "icon", item.Has("icon") ? item["icon"] : ""
        ))
    }
    return results
}

QbarFilterFolder(text) {
    dir := QbarFolderOf(text)
    leaf := QbarLeafOf(text)
    items := QbarFolderItemsFor(dir)
    if leaf = ""
        return items

    glob := QbarGlobToRegEx(leaf)
    results := []
    for item in items {
        if RegExMatch(item["label"], glob)
            results.Push(item)
    }
    return results
}

QbarFolderItemsFor(dir) {
    global QbarFolderDir, QbarFolderItems
    if dir = QbarFolderDir
        return QbarFolderItems
    items := []
    try {
        Loop Files, dir . "*", "FD" {
            if InStr(FileExist(A_LoopFileFullPath), "H")
                continue
            isFolder := InStr(FileExist(A_LoopFileFullPath), "D") ? true : false
            items.Push(Map(
                "short", A_LoopFileName,
                "label", A_LoopFileName,
                "type", isFolder ? "folder" : "file",
                "value", A_LoopFileFullPath,
                "pinned", false,
                "icon", isFolder ? "folder" : IconKeyForPath(A_LoopFileFullPath)
            ))
        }
    } catch as folderError {
        DebugLog("Folder listing failed for " . dir . ": " . folderError.Message)
    }
    QbarFolderDir := dir
    QbarFolderItems := items
    return items
}

QbarSendResults(results, folderMode, placeholder := "") {
    global IconSent
    rows := []
    icons := Map()
    for item in results {
        row := Map("short", item["short"], "label", item["label"], "type", item["type"],
            "pinned", item.Has("pinned") && item["pinned"] ? JSON.true : JSON.false)
        iconKey := item.Has("icon") ? item["icon"] : ""
        if iconKey != "" {
            row["icon"] := iconKey
            ; First use of a key extracts and caches the data URI right here;
            ; the page only ever receives each key once.
            uri := IconDataURI(iconKey)
            if uri != "" && !IconSent.Has(iconKey) {
                IconSent[iconKey] := true
                icons[iconKey] := uri
            }
        }
        rows.Push(row)
    }
    ; Icons go first so the rows that reference them render with them in
    ; place; ExecuteScriptAsync runs submitted scripts in order.
    if icons.Count
        QbarExec("window.addIcons(" . JSON.stringify(icons, 0) . ");")
    QbarExec("window.setResults(" . JSON.stringify(rows, 0) . "," . (folderMode ? "true" : "false")
        . "," . LLMJsonQuote(placeholder) . ");")
}

; ---------------------------------------------------------------------------
; Execution (the core of the reference ButtonSubmit label)
; ---------------------------------------------------------------------------

QbarExecute(text, selected, ctrlHeld, selectedType := "") {
    text := Trim(text, " `t")
    ; "键 ->类型 值" adds an entry to the settings file. It is decided on the
    ; typed text alone and before the row handling, because the row for the
    ; trigger would otherwise replace the command with just the trigger.
    if QbarTryInlineConfig(text)
        return
    if selected != "" {
        ; The AI option row asks with the typed text as-is. A bare trigger
        ; word only shows the hint (handled inside QbarAiAsk).
        if selectedType = "ai" {
            QbarAiAsk(selected)
            return
        }
        if selectedType = "search" {
            ; An engine row is armed only while there is nothing to search for
            ; yet: it fills the trigger in and leaves the caret after it. Once
            ; the line already reads "trigger query", the row is just the pinned
            ; match for its own trigger, so fall through and search with it
            ; rather than clearing what was typed.
            if QbarSearchArgument(text, selected) = "" {
                QbarExec("window.startSearch(" . LLMJsonQuote(selected) . ");")
                return
            }
        } else {
            ; A highlighted row wins over the typed text. In folder mode the
            ; selected name replaces the leaf of the typed path.
            if QbarIsFolderQuery(text)
                text := QbarFolderOf(text) . selected
            else
                text := selected
        }
    }
    if text = ""
        return
    DebugLog("QbarExecute text=" . text . " ctrl=" . ctrlHeld)

    if ctrlHeld {
        ; A highlighted file or folder row is revealed in Explorer instead of
        ; the domain fallback -- mainly for Everything results, but folder
        ; browsing gets it too.
        if selected != "" && (selectedType = "file" || selectedType = "folder") {
            QbarLocateInExplorer(text)
            return
        }
        ; Ctrl+Enter otherwise treats the typed text as a domain name.
        QbarOpenUrl("www." . text . ".com")
        return
    }

    firstToken := QbarFirstToken(text)
    if firstToken != text {
        rest := Trim(SubStr(text, StrLen(firstToken) + 1), " `t")
        ; Everything trigger: refresh the live results right away in case the
        ; debounce timer has not fired yet, and keep the panel open.
        if !QbarConfigShortKeyExists(firstToken) && QbarEsAlias(firstToken) {
            QbarEsFlushNow(rest)
            return
        }
        ; "ai <question>" / "q <question>" -- the configured LLM answers or
        ; explains; an ini entry named ai/q wins over the built-in command.
        if !QbarConfigShortKeyExists(firstToken) && QbarAiAlias(firstToken) {
            QbarAiAsk(rest)
            return
        }
        ; "cl <sub>" -- version display and a shortcut to the settings files.
        if QbarTryClCommand(firstToken, rest)
            return
        ; "web <url>" opens whatever follows as a site, http:// added when it
        ; is missing; a configured "web" trigger wins over the command word.
        if firstToken = "web" && !QbarConfigShortKeyExists("web") {
            QbarOpenUrl(rest)
            return
        }
        ; Search engine trigger: substitute {q} with the URL-encoded argument.
        search := QbarFindByShort(QbarSearchEntries(), firstToken)
        if !IsObject(search)
            search := QbarFindByShort(QbarSearchEntries(), QbarEngineAlias(firstToken))
        if IsObject(search) {
            QbarOpenUrl(StrReplace(search["value"], "{q}", QbarUrlEncode(rest)))
            return
        }
        if QbarRunBy(firstToken, rest)
            return
    }

    if QbarRunBy(text)
        return
    web := QbarFindByShort(QbarConfigItemsOf("QWeb"), text)
    if IsObject(web) {
        QbarOpenUrl(web["value"])
        return
    }
    app := QbarFindByShort(QbarStartMenuItems(), text)
    if IsObject(app) {
        QbarRunShortcut(app)
        return
    }

    ; "type" would shadow the built-in Type() function in the global namespace.
    stringType := CheckStringType(text)
    if stringType = "file" || stringType = "folder" || stringType = "ftp" {
        QbarOpenPath(text)
        return
    }
    if stringType = "web" {
        QbarOpenUrl(text)
        return
    }

    ; Searching stays deliberate: only a [QSearch] trigger searches. A line
    ; that matched nothing at all becomes a question for the configured LLM --
    ; the launcher's catch-all instead of doing nothing.
    DebugLog("QbarExecute no match, asking AI text=" . text)
    QbarAiAsk(text)
}

; Handles "键 ->类型 值", which adds one entry to the settings file so qbar can
; be extended without leaving it. Returns true when the text was such a command,
; so the caller stops.
QbarTryInlineConfig(text) {
    firstToken := QbarFirstToken(text)
    if firstToken = text
        return false
    rest := Trim(SubStr(text, StrLen(firstToken) + 1), " `t")
    arrowWord := QbarFirstToken(rest)
    if !RegExMatch(arrowWord, "^->(.*)$", &match)
        return false
    value := Trim(SubStr(rest, StrLen(arrowWord) + 1), " `t")
    if value = ""
        return false
    section := QbarInlineSection(match[1], value)
    if section = ""
        return false
    QbarAddSetting(section, firstToken, value)
    return true
}

; The settings section an inline command writes to, or "" when the arrow asks
; for nothing recognisable -- in that case the text is left to the normal
; triggers rather than being swallowed.
QbarInlineSection(arrowWord, value) {
    switch StrLower(Trim(arrowWord)) {
        case "run", "qrun", "path", "file", "folder", "ftp":
            return "QRun"
        case "web", "qweb":
            return "QWeb"
        case "search", "qsearch":
            return "QSearch"
        case "str", "string", "hotstring", "tabhotstring":
            return "TabHotString"
        case "":
            ; A bare arrow guesses from the value: a URL carrying {q} is a
            ; search, whatever the shell can classify is a path or a site, and
            ; anything left over becomes a hotstring.
            if RegExMatch(value, "i)(http:|www|\.com|\.net|\.org).*\{q\}")
                return "QSearch"
            detected := CheckStringType(value)
            if detected = "file" || detected = "folder" || detected = "ftp"
                return "QRun"
            if detected = "web"
                return "QWeb"
            return "TabHotString"
        default:
            return ""
    }
}

; Adds one entry, asking first and asking again before replacing a key that is
; already configured. TabHotString values keep a literal \n so the file stays
; one line per key.
QbarAddSetting(section, key, value) {
    global Config
    prompt := QbarText("Add to ", "添加到 ") . "[" . section . "]`n`n" . key . "=" . value
    if MsgBox(prompt, "qbar", "OKCancel") != "OK"
        return

    existing := ""
    if Config.Has(section) && Config[section].Has(key)
        existing := Config[section][key]
    if existing != "" {
        prompt := QbarText("That key is already set. Replace it?", "该键已存在，要覆盖吗？")
        prompt .= "`n`n" . key . "=" . existing . "`n`n-> " . key . "=" . value
        if MsgBox(prompt, "qbar", "OKCancel") != "OK"
            return
    }

    if section = "TabHotString"
        value := StrReplace(StrReplace(value, "\n", "`n"), "`n", "\n")

    if SetSettings(section, key, value)
        ShowMsg(QbarText("Added ", "已添加 ") . key, 1500)
}

; "cl <sub>" -- the built-in command surface of the reference bar: version
; display and a shortcut to the settings files. Its pay/donate entries point at
; the original author and stay out. Returns true when the line was a cl command.
QbarTryClCommand(cmd, param) {
    global AppName, AppVersion, SettingsFile
    if cmd != "cl"
        return false
    if param = "version" || param = "about" {
        ShowMsg(AppName . "  " . AppVersion, 4000)
        return true
    }
    if param = "set" || param = "settings" {
        opened := false
        if FileExist(SettingsFile) {
            Run(SettingsFile)
            opened := true
        }
        demoFile := A_ScriptDir . "\capslock_p2-settingsDemo.ini"
        if FileExist(demoFile) {
            Run(demoFile)
            opened := true
        }
        if opened
            QbarHide()
        else
            ShowMsg(QbarText("No settings file found.", "未找到设置文件。"), 2500)
        return true
    }
    ShowMsg(QbarText("Unknown cl command: ", "未知的 cl 命令：") . param, 2500)
    return true
}

; The reference answers to a couple of alternative engine spellings (g/gg,
; m/mdn). A configured trigger that really is "gg" or "mdn" is looked up first
; and wins, so this only fills the gaps.
QbarEngineAlias(token) {
    static aliases := Map("gg", "g", "mdn", "m")
    lower := StrLower(token)
    return aliases.Has(lower) ? aliases[lower] : token
}

; Triggers for the AI answer/explain command.
QbarAiAlias(token) {
    static aliases := Map("ai", true, "q", true)
    return aliases.Has(StrLower(token))
}

; Closes the launcher and opens the AI chat with the text as the question;
; when the API is not configured yet the chat opens its settings view first,
; and asks the question once settings are saved.
QbarAiAsk(text) {
    text := Trim(text)
    ; A bare trigger word ("ai"/"q" with nothing after it) is not a question;
    ; neither is an empty line. Both only ask for input.
    if text = "" || QbarAiAlias(text) {
        ShowMsg(QbarText("Type a question after the trigger, e.g.: q what is MFT", "输入要问的内容，例如：q 什么是 MFT"), 3000)
        return
    }
    QbarHide()
    AiChatShow(text)
}

QbarRunBy(shortKey, params := "") {
    entry := QbarFindByShort(QbarConfigItemsOf("QRun"), shortKey)
    if !IsObject(entry)
        return false

    if params != "" {
        ; The argument may itself be another entry's trigger (reference qrunBy).
        replacement := QbarFindByShort(QbarConfigItemsOf("QWeb"), params)
        if IsObject(replacement)
            params := replacement["value"]
        else {
            replacement := QbarFindByShort(QbarConfigItemsOf("QRun"), params)
            if IsObject(replacement)
                params := replacement["value"]
        }
    }

    command := QbarRunCommand(entry["value"], params)
    try {
        Run(command)
        QbarHide()
    } catch as runError {
        DebugLog("Qbar run failed: " . runError.Message)
        ShowMsg(QbarText("Cannot run: ", "无法运行：") . entry["value"], 2500)
    }
    return true
}

; Build a Run()-ready command from an ini value: honours "*RunAs", quoted paths
; and extra parameters, and quotes a bare path that contains spaces (Run needs
; quotes for those).
QbarRunCommand(value, params := "") {
    runString := ""
    runAsAdmin := false
    parameters := ""
    resolved := ExtractSetString(value, &runString, &runAsAdmin, &parameters)
    if resolved != ""
        command := runString . (parameters = "" ? "" : " " . parameters)
    else if FileExist(Trim(value))
        command := Chr(34) . Trim(value) . Chr(34)
    else
        command := Trim(value)
    if runAsAdmin
        command := "*RunAs " . command
    if params != ""
        command .= " " . Chr(34) . params . Chr(34)
    return command
}

QbarRunShortcut(item) {
    try {
        Run(QbarFilesystemTarget(item["value"]))
        QbarHide()
        return
    } catch {
        ; Fall through to the target executable when the .lnk is stale.
    }
    try {
        Run(QbarFilesystemTarget(item["exe"]))
        QbarHide()
    } catch as runError {
        DebugLog("Qbar start menu run failed: " . runError.Message)
        ShowMsg(QbarText("Cannot run: ", "无法运行：") . item["label"], 2500)
    }
}

; Run() accepts a bare path through ShellExecute, but quoting an existing path
; avoids trouble when it contains spaces. URLs are left untouched.
QbarFilesystemTarget(target) {
    target := Trim(target)
    if target = "" || RegExMatch(target, "i)^(https?|ftp)://")
        return target
    return FileExist(target) ? Chr(34) . target . Chr(34) : target
}

; Values typed as "www.host" or "host" become http:// URLs.
QbarOpenUrl(url) {
    url := Trim(url)
    if url = ""
        return
    if !RegExMatch(url, "i)^(https?|ftp)://")
        url := "http://" . url
    QbarOpenPath(url)
}

; Local files, folders and already-formed URLs go straight to the shell.
QbarOpenPath(path) {
    path := Trim(path)
    if path = ""
        return
    target := QbarFilesystemTarget(path)
    try {
        Run(target)
        QbarHide()
    } catch as runError {
        DebugLog("Qbar open failed: " . runError.Message)
        ShowMsg(QbarText("Cannot open: ", "无法打开：") . path, 2500)
    }
}

; Ctrl+Enter on a file row: reveal it in Explorer with the item selected. A
; folder row just opens, since there is nothing to select inside itself.
QbarLocateInExplorer(path) {
    path := Trim(path)
    if path = ""
        return
    if DirExist(path) {
        QbarOpenPath(path)
        return
    }
    parent := ""
    SplitPath(path, , &parent)
    if parent = "" || !DirExist(parent) {
        ShowMsg(QbarText("Not found: ", "找不到：") . path, 2500)
        return
    }
    try {
        Run("explorer.exe /select," . Chr(34) . path . Chr(34))
        QbarHide()
    } catch as runError {
        DebugLog("Qbar locate failed: " . runError.Message)
        ShowMsg(QbarText("Cannot open: ", "无法打开：") . path, 2500)
    }
}

; ---------------------------------------------------------------------------
; Everything file search ("e <query>", aliases: everything / find / f)
; ---------------------------------------------------------------------------

; The typed line reads "e <query>": keep the previous results visible and
; schedule the real es.exe call behind a short debounce -- one keystroke of
; latency in exchange for far fewer process spawns.
QbarEsRequest(text, firstToken) {
    global QbarEsMode, QbarEsPending, QbarEsSeq, QbarEsLastResults
    arg := Trim(SubStr(text, StrLen(firstToken) + 1), " `t")
    if arg = "" {
        ; Only the trigger so far: back to the normal list, which pins the
        ; trigger row itself.
        QbarEsMode := false
        QbarEsSeq += 1
        SetTimer(QbarEsFlush, 0)
        QbarSendResults(QbarFilterItems(text), false)
        return
    }
    QbarEsMode := true
    QbarEsPending := arg
    QbarEsSeq += 1
    QbarSendResults(QbarEsLastResults, false)
    SetTimer(QbarEsFlush, -100)
}

QbarEsFlush() {
    global QbarEsPending, QbarEsSeq, QbarEsMode, QbarEsLastResults, QbarVisible
    if !QbarEsMode || !QbarVisible
        return
    seq := QbarEsSeq
    arg := QbarEsPending
    results := QbarEsSearch(arg)
    ; A newer query took over while es.exe was running, or the panel closed.
    if seq != QbarEsSeq || !QbarEsMode || !QbarVisible
        return
    QbarEsLastResults := results
    QbarSendResults(results, false)
}

; Enter on a typed "e <query>" line: flush the pending search immediately so a
; race with the debounce cannot leave the list stale.
QbarEsFlushNow(arg) {
    global QbarEsMode, QbarEsPending, QbarEsSeq
    if arg = ""
        return
    QbarEsMode := true
    QbarEsPending := arg
    QbarEsSeq += 1
    QbarEsFlush()
}

; Triggers that switch qbar into Everything file search, all equivalent.
QbarEsAlias(token) {
    static aliases := Map("e", true, "everything", true, "find", true, "f", true)
    return aliases.Has(StrLower(token))
}

QbarEsSearch(arg) {
    global QbarEsUseBundled, QbarEsBundledColdStart
    exe := QbarEsExe()
    if exe = "" {
        QbarEsHint(QbarText("es.exe not found next to the script.", "脚本旁未找到 es.exe。"))
        return []
    }
    useBundled := QbarEsBackend()
    if useBundled = 1 && !QbarEsEnsureBundled()
        return []
    results := QbarEsRun(arg, useBundled, &exitCode)
    ; The user's Everything went away mid-session: re-decide the backend, and
    ; the next query takes the bundled path if it must.
    if useBundled = -1 && exitCode != 0 {
        QbarEsUseBundled := 0
        DebugLog("Es default backend failed exit=" . exitCode . ", backend reset")
    }
    if !results.Length && QbarEsBundledColdStart {
        ; The first index build takes seconds; poll briefly instead of showing
        ; an empty list and going quiet.
        QbarEsBundledColdStart := false
        Loop 10 {
            Sleep(1500)
            results := QbarEsRun(arg, useBundled, &exitCode)
            if results.Length
                break
        }
    }
    DebugLog("Es search arg=" . arg . " results=" . results.Length)
    return results
}

; Decides which Everything answers es.exe: the user's own (default IPC) when it
; is up, otherwise the bundled copy under resources. Decided once per session.
QbarEsBackend() {
    global QbarEsUseBundled
    if QbarEsUseBundled != 0
        return QbarEsUseBundled
    QbarEsUseBundled := QbarEsDefaultAvailable() ? -1 : 1
    DebugLog("Es backend=" . (QbarEsUseBundled = -1 ? "default" : "bundled"))
    return QbarEsUseBundled
}

; The user's own Everything answers the default IPC window. A process check
; first (cheap), then one real es.exe call, which fails fast (exit 8) when the
; window is not reachable.
QbarEsDefaultAvailable() {
    exe := QbarEsExe()
    if exe = "" || !ProcessExist("Everything.exe")
        return false
    tmp := A_Temp . "\qbar-es-probe.txt"
    cmdline := Chr(34) . exe . Chr(34) . " -csv -no-header -n 1 -full-path-and-name " . Chr(34) . "1" . Chr(34)
    exitCode := RunWait(A_ComSpec . " /c " . Chr(34) . cmdline . " > " . Chr(34) . tmp . Chr(34) . " 2>nul" . Chr(34), "", "Hide")
    try FileDelete(tmp)
    return exitCode = 0
}

; Starts the bundled copy under its own instance name with its own config and
; database, so the user's own Everything is never touched. The instance needs
; elevation to read the NTFS index (MFT), which shows one UAC prompt; a probe
; first avoids repeating that prompt when the instance is already up.
QbarEsEnsureBundled() {
    global QbarEsBundledStarted, QbarEsBundledColdStart, QbarEsBundledFailed
    if QbarEsBundledStarted
        return true
    if QbarEsBundledFailed
        return false
    if QbarEsInstanceReachable() {
        QbarEsBundledStarted := true
        DebugLog("Es bundled instance already running")
        return true
    }
    exe := QbarEsEverythingExe()
    if exe = "" {
        QbarEsHint(QbarText("No Everything available for file search.", "没有可用的 Everything，文件搜索不可用。"))
        QbarEsBundledFailed := true
        return false
    }
    dataDir := EnvGet("LOCALAPPDATA") . "\capslock_p2\Everything"
    try DirCreate(dataDir)
    command := Chr(34) . exe . Chr(34) . " -instance " . QbarEsInstanceName()
        . " -startup -config " . Chr(34) . dataDir . "\Everything.ini" . Chr(34)
        . " -db " . Chr(34) . dataDir . "\Everything.db" . Chr(34)
    try Run("*RunAs " . command)
    catch {
        DebugLog("Bundled Everything start declined")
        QbarEsHint(QbarText("File search needs admin rights to build the index.", "文件搜索需要管理员权限来建立索引。"))
        QbarEsBundledFailed := true
        return false
    }
    QbarEsBundledStarted := true
    QbarEsBundledColdStart := true
    DebugLog("Bundled Everything starting instance=" . QbarEsInstanceName())
    return true
}

QbarEsInstanceReachable() {
    exe := QbarEsExe()
    if exe = ""
        return false
    tmp := A_Temp . "\qbar-es-probe.txt"
    cmdline := Chr(34) . exe . Chr(34) . " -instance " . QbarEsInstanceName()
        . " -csv -no-header -n 1 -full-path-and-name " . Chr(34) . "1" . Chr(34)
    exitCode := RunWait(A_ComSpec . " /c " . Chr(34) . cmdline . " > " . Chr(34) . tmp . Chr(34) . " 2>nul" . Chr(34), "", "Hide")
    try FileDelete(tmp)
    return exitCode = 0
}

; Runs one es.exe query into a temp file and parses it. es.exe talks to the
; running Everything over IPC, so once an instance is up this is instant.
QbarEsRun(arg, useBundled, &exitCode) {
    exe := QbarEsExe()
    instance := useBundled = 1 ? " -instance " . QbarEsInstanceName() : ""
    tmp := A_Temp . "\qbar-es-" . A_TickCount . ".txt"
    quotedArg := Chr(34) . StrReplace(arg, Chr(34), Chr(34) . Chr(34)) . Chr(34)
    cmdline := Chr(34) . exe . Chr(34) . instance . " -csv -no-header -n " . QbarEsMaxResults()
        . " -full-path-and-name " . quotedArg
    exitCode := RunWait(A_ComSpec . " /c " . Chr(34) . cmdline . " > " . Chr(34) . tmp . Chr(34) . " 2>nul" . Chr(34), "", "Hide")
    results := QbarParseEsCsv(tmp)
    try FileDelete(tmp)
    return results
}

; es.exe -csv emits one quoted column per row: the full path. Lines cannot
; contain CR/LF (Windows filenames may not), so a plain line split is safe.
; Encoding: this es.exe build writes UTF-8 without a BOM, older builds write
; the system code page -- hence BOM, then a strict UTF-8 check, then CP0.
QbarParseEsCsv(path) {
    results := []
    if !FileExist(path)
        return results
    esFile := FileOpen(path, "r")
    size := esFile.Length
    buf := Buffer(size + 1, 0)
    if size > 0
        esFile.RawRead(buf, size)
    esFile.Close()
    offset := 0
    encoding := "CP0"
    if size >= 3 && NumGet(buf, 0, "UChar") = 0xEF && NumGet(buf, 1, "UChar") = 0xBB && NumGet(buf, 2, "UChar") = 0xBF {
        offset := 3
        encoding := "UTF-8"
    } else if QbarIsValidUtf8(buf, size)
        encoding := "UTF-8"
    text := StrGet(buf.Ptr + offset, encoding)

    quote := Chr(34)
    Loop Parse, text, "`n", "`r" {
        line := A_LoopField
        if line = ""
            continue
        if SubStr(line, 1, 1) = quote && SubStr(line, -1) = quote && StrLen(line) >= 2
            line := StrReplace(SubStr(line, 2, StrLen(line) - 2), quote . quote, quote)
        ; Folder rows end with a backslash, which reads better without.
        if StrLen(line) > 3 && SubStr(line, -1) = "\"
            line := RTrim(line, "\")
        name := ""
        dir := ""
        SplitPath(line, &name, &dir)
        if name = ""
            label := line
        else if dir != ""
            label := name . "  ·  " . dir
        else
            label := name
        isFolder := DirExist(line) ? true : false
        results.Push(Map(
            "short", line,
            "label", label,
            "type", isFolder ? "folder" : "file",
            "pinned", false,
            "icon", isFolder ? "folder" : IconKeyForPath(line)
        ))
    }
    return results
}

; Strict UTF-8 shape check (no BOM required), used to pick between the UTF-8
; and system code page decodings of es.exe output.
QbarIsValidUtf8(buf, size) {
    index := 0
    while index < size {
        byte := NumGet(buf, index, "UChar")
        index += 1
        if byte >= 0xF8      ; reserved lead byte
            return false
        if byte < 0xC0       ; a continuation byte with no lead byte before it
            return false
        expected := byte < 0xE0 ? 1 : (byte < 0xF0 ? 2 : 3)
        if index + expected > size
            return false
        Loop expected {
            if (NumGet(buf, index + A_Index - 1, "UChar") & 0xC0) != 0x80
                return false
        }
        index += expected
    }
    return true
}

QbarEsExe() {
    global QbarEsPath, Config
    if QbarEsPath != ""
        return QbarEsPath
    if Config.Has("Qbar") && Config["Qbar"].Has("esPath") && Trim(Config["Qbar"]["esPath"]) != "" {
        candidate := Trim(Config["Qbar"]["esPath"])
        if FileExist(candidate) {
            QbarEsPath := candidate
            return candidate
        }
    }
    candidate := A_ScriptDir . "\resources\es.exe"
    if FileExist(candidate)
        QbarEsPath := candidate
    return QbarEsPath
}

; The bundled copy lives in a versioned folder under resources; the first
; folder that contains everything.exe wins. [Qbar] everythingPath overrides.
QbarEsEverythingExe() {
    global QbarEsEverythingPath, Config
    if QbarEsEverythingPath != ""
        return QbarEsEverythingPath
    if Config.Has("Qbar") && Config["Qbar"].Has("everythingPath") && Trim(Config["Qbar"]["everythingPath"]) != "" {
        candidate := Trim(Config["Qbar"]["everythingPath"])
        if FileExist(candidate) {
            QbarEsEverythingPath := candidate
            return candidate
        }
    }
    Loop Files, A_ScriptDir . "\resources\*", "D" {
        candidate := A_LoopFileFullPath . "\everything.exe"
        if FileExist(candidate) {
            QbarEsEverythingPath := candidate
            return candidate
        }
    }
    return ""
}

QbarEsInstanceName() {
    global Config
    if Config.Has("Qbar") && Config["Qbar"].Has("esInstance") && Trim(Config["Qbar"]["esInstance"]) != ""
        return Trim(Config["Qbar"]["esInstance"])
    return "capslock_p2"
}

QbarEsMaxResults() {
    global Config
    if Config.Has("Qbar") && Config["Qbar"].Has("esMaxResults") {
        value := Trim(Config["Qbar"]["esMaxResults"])
        if RegExMatch(value, "^\d+$") && value + 0 > 0
            return value + 0
    }
    return 50
}

; One hint per panel show, so a missing prerequisite does not pop a message on
; every keystroke.
QbarEsHint(text) {
    global QbarEsHintShown
    if QbarEsHintShown
        return
    QbarEsHintShown := true
    ShowMsg(text, 3000)
}

; ---------------------------------------------------------------------------
; Folder navigation (wired to keyFunc_qbar_upperFolderPath / lowerFolderPath)
; ---------------------------------------------------------------------------

QbarUpperFolderPath() {
    global QbarVisible, QbarFutureStack, QbarFolderDir
    if !QbarVisible || QbarFolderDir = ""
        return false
    dir := QbarFolderDir
    parent := QbarParentFolder(dir)
    if parent = "" || parent = dir
        return false
    QbarFutureStack.Push(dir)
    QbarSetInput(parent)
    return true
}

QbarLowerFolderPath() {
    global QbarVisible, QbarFutureStack
    if !QbarVisible || !QbarFutureStack.Length
        return false
    QbarSetInput(QbarFutureStack.Pop())
    return true
}

QbarSetInput(text) {
    QbarExec("window.setInput(" . LLMJsonQuote(text) . ");")
}

; "e:\abc\def\" -> "e:\abc\"; the drive root resolves to itself.
QbarParentFolder(dir) {
    trimmed := RTrim(dir, "\")
    if RegExMatch(trimmed, "^.*\\", &match)
        return match[0]
    return trimmed . "\"
}

; ---------------------------------------------------------------------------
; Style
; ---------------------------------------------------------------------------

; Only values actually present in [QStyle] are sent, so an unconfigured panel
; keeps the shared theme it has in common with the translation panel.
QbarPushStyle() {
    style := Map("uiLanguage", IsChineseLanguage() ? "zh" : "en", "maxRows", String(QbarListCount()))
    for key in ["borderBackgroundColor", "textBackgroundColor", "textColor", "listBackgroundColor", "listColor"] {
        value := QbarConfiguredColor(key)
        if value != ""
            style[key] := value
    }
    for key in ["borderRadius", "textFontSize", "listFontSize"] {
        value := QbarConfiguredNumber(key)
        if value != ""
            style[key] := value
    }
    QbarExec("window.setStyle(" . JSON.stringify(style, 0) . ");")
}

QbarConfiguredColor(key) {
    global Config
    if !Config.Has("QStyle") || !Config["QStyle"].Has(key)
        return ""
    return QbarStyleColor(key, "")
}

QbarConfiguredNumber(key) {
    global Config
    if !Config.Has("QStyle") || !Config["QStyle"].Has(key)
        return ""
    return QbarStyleNumber(key, "")
}

QbarListCount() {
    global QbarMaxRows
    count := QbarStyleNumber("listCount", String(QbarMaxRows)) + 0
    return count > 0 ? count : QbarMaxRows
}

; [QStyle] colours are either #RRGGBB or the reference project's 0xBBGGRR.
QbarStyleColor(key, fallback) {
    global Config
    if !Config.Has("QStyle") || !Config["QStyle"].Has(key)
        return fallback
    value := Trim(Config["QStyle"][key])
    if value = ""
        return fallback
    if RegExMatch(value, "i)^#?([0-9a-f]{6})$", &match)
        return "#" . match[1]
    if RegExMatch(value, "i)^0x([0-9a-f]{6})$", &match) {
        bgr := match[1]
        return "#" . SubStr(bgr, 5, 2) . SubStr(bgr, 3, 2) . SubStr(bgr, 1, 2)
    }
    return fallback
}

QbarStyleNumber(key, fallback) {
    global Config
    if !Config.Has("QStyle") || !Config["QStyle"].Has(key)
        return fallback
    value := Trim(Config["QStyle"][key])
    if RegExMatch(value, "^\d+$")
        return value
    return fallback
}

; ---------------------------------------------------------------------------
; Helpers
; ---------------------------------------------------------------------------

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

QbarConfigShortKeyExists(token) {
    global Config
    if Trim(token) = ""
        return false
    for section in ["QRun", "QWeb", "QSearch"] {
        if !Config.Has(section)
            continue
        for key, value in Config[section] {
            if QbarShortKey(key) = token
                return true
        }
    }
    return false
}

QbarConfigItemsOf(section) {
    global Config
    if !Config.Has(section)
        return []
    items := []
    for key, value in Config[section] {
        if Trim(value) = ""
            continue
        items.Push(Map("short", QbarShortKey(key), "label", key, "value", value))
    }
    return items
}

QbarFindByShort(items, shortKey) {
    for item in items {
        if item["short"] = shortKey
            return item
    }
    return 0
}

; Glob to regex, matching the reference easyGlobToRegEx: everything except * and
; ? is quoted, so the query is a literal search with optional wildcards.
QbarGlobToRegEx(glob) {
    pattern := RegExReplace(glob, "[^*?]+", "\Q$0\E")
    pattern := StrReplace(pattern, "*", ".*")
    pattern := StrReplace(pattern, "?", ".")
    return "iS)" . pattern
}

; The existing directory prefix of a path, ending with a backslash.
QbarFolderOf(text) {
    if !RegExMatch(text, "i)^([a-zA-Z]:\\(?:[^\\]*\\)*)", &match)
        return ""
    dir := match[1]
    return DirExist(dir) ? dir : ""
}

QbarLeafOf(text) {
    return RegExMatch(text, "i)(?<=\\)[^\\]*$", &match) ? match[0] : ""
}

; Percent-encode UTF-8 bytes, leaving the URI unreserved set intact.
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
