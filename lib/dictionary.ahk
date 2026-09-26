; Local dictionary panel for single English words. Backed by an ECDICT-format
; stardict SQLite database (resources\dictionary.db) queried through CSQLite
; and rendered in a WebView2 panel (dictionary.html). The translate hotkey
; consults it first: a selection that is one known English word opens this
; card, anything else keeps going to the translate panel.

global DictionaryHost := 0
global DictionaryGui := 0
global DictionaryController := 0
global DictionaryWebView := 0
global DictionaryPageReady := false
global DictionaryVisible := false
global DictionaryPendingEntry := 0
global DictionaryPendingQuery := ""
global DictionaryFocusTimer := false
global DictionaryDB := 0

DictionaryDBPath() {
    return A_ScriptDir . "\resources\dictionary.db"
}

; A dictionary candidate is a single token of Latin letters with optional
; internal apostrophes or hyphens; surrounding punctuation is ignored. The
; length cap keeps accidental giant selections out of the SQL literal.
DictionaryNormalizeWord(text) {
    text := Trim(text, " `t`r`n`v`f" . Chr(34) . "'“”‘’.,;:!?()[]{}<>…—–-")
    if RegExMatch(text, "^[A-Za-z][A-Za-z'\-]{0,63}$", &m)
        return m[0]
    return ""
}

; One read-only connection kept for the lifetime of the script; the database
; is opened lazily on the first lookup and reused after that.
DictionaryConnect() {
    global DictionaryDB
    if IsObject(DictionaryDB)
        return DictionaryDB
    dllFolder := A_ScriptDir . "\resources"
    if !FileExist(DictionaryDBPath()) || !FileExist(dllFolder . "\SQLite3.dll")
        return 0
    try db := CSQLite(dllFolder)
    catch as loadError {
        DebugLog("dictionary sqlite load failed: " . loadError.Message)
        return 0
    }
    if !db.OpenDB(DictionaryDBPath(), "R") {
        DebugLog("dictionary open failed: " . db.ErrorMsg)
        return 0
    }
    DictionaryDB := db
    return db
}

; Exact, case-insensitive lookup (the word column uses COLLATE NOCASE).
; Returns a Map of entry fields, or 0 when the word is unknown.
DictionaryLookup(word) {
    global DictionaryDB
    db := DictionaryConnect()
    if !IsObject(db)
        return 0
    safeWord := StrReplace(word, "'", "''")
    sql := "SELECT word, IFNULL(phonetic,''), IFNULL(translation,''), IFNULL(definition,''),"
        . " IFNULL(pos,''), IFNULL(collins,0), IFNULL(oxford,0), IFNULL(tag,''),"
        . " IFNULL(bnc,0), IFNULL(frq,0), IFNULL(exchange,'')"
        . " FROM stardict WHERE word = '" . safeWord . "' LIMIT 1"
    gotTable := false
    try gotTable := db.GetTable(sql, &table)
    if !gotTable {
        DebugLog("dictionary query failed: " . db.ErrorMsg)
        return 0
    }
    if table.RowCount < 1
        return 0
    row := table.Rows[1]
    return Map(
        "word", row[1], "phonetic", row[2], "translation", row[3], "definition", row[4],
        "pos", row[5], "collins", row[6], "oxford", row[7], "tag", row[8],
        "bnc", row[9], "frq", row[10], "exchange", row[11]
    )
}

; From the translate hotkey: when the selection is one English word the local
; dictionary knows, show the dictionary card and report true so the caller
; skips the translate panel.
DictionaryTryShow(text) {
    word := DictionaryNormalizeWord(text)
    if word = ""
        return false
    entry := DictionaryLookup(word)
    if !IsObject(entry)
        return false
    DictionaryShow(entry)
    return true
}

DictionaryShow(entry := 0, query := "") {
    global DictionaryHost, DictionaryGui, DictionaryVisible, DictionaryPageReady, DictionaryFocusTimer
    global DictionaryPendingEntry, DictionaryPendingQuery
    DebugLog("dictionary show kind=" . (IsObject(entry) ? "entry" : "blank")
        . " queryLength=" . StrLen(query)
        . " activeBefore=" . WinExist("A"))
    DictionaryVisible := true
    DictionaryPendingEntry := entry
    DictionaryPendingQuery := Trim(query)
    if !DictionaryEnsureWebView() {
        DictionaryVisible := false
        DictionaryPendingEntry := 0
        DictionaryPendingQuery := ""
        return
    }
    dictionarySize := ScreenFitSize(640, 640, 460, 380)
    PanelHostShow(DictionaryHost, dictionarySize[1], dictionarySize[2], true)
    DictionarySyncHost()
    DictionaryRemoveFrameBorder(DictionaryGui.Hwnd)
    WinActivate("ahk_id " . DictionaryGui.Hwnd)
    DebugLog("dictionary activated hwnd=" . DictionaryGui.Hwnd
        . " activeAfter=" . WinExist("A")
        . " pageReady=" . DictionaryPageReady)
    ShowSystemCursor()
    DictionaryFocusTimer := PanelHostStartFocusMonitor(DictionaryHost, DictionaryFocusMonitor)

    if DictionaryPageReady {
        if IsObject(entry)
            DictionaryPushEntry(entry)
        else {
            DictionaryClearPage()
            DictionaryPushQuery(DictionaryPendingQuery)
        }
    }
}

DictionaryShowQuery(text) {
    DictionaryShow(0, text)
}

DictionaryEnsureWebView() {
    global DictionaryHost, DictionaryGui, DictionaryController, DictionaryWebView
    global DictionaryPageReady
    pagePath := A_ScriptDir . "\pages\dictionary.html"
    if IsObject(DictionaryHost) {
        try {
            PanelHostEnsure(DictionaryHost)
            DictionarySyncHost()
            return true
        } catch as existingError {
            PanelHostHide(DictionaryHost)
            DebugLog("dictionary webview failed: " . existingError.Message)
            ShowMsg("WebView2 initialization failed: " . existingError.Message, 5000)
            return false
        }
    }

    dictionarySize := ScreenFitSize(640, 640, 460, 380)
    DictionaryHost := PanelHostCreate(pagePath, "capslock_p2 词典", Map(
        "guiOptions", "+AlwaysOnTop -Caption +Resize +MinSize460x380 +ToolWindow",
        "dataPath", A_Temp . "\CapsLockPlusDictionaryWebView2",
        "initialShow", "x-32000 y-32000 w" . dictionarySize[1] . " h" . dictionarySize[2] . " NA",
        "callbacks", Map(
            "close", DictionaryHide,
            "escape", DictionaryHide,
            "resize", DictionaryResize,
            "navigation", DictionaryNavigationCompleted,
            "message", DictionaryWebMessageReceived,
            "backColor", DictionaryIsDarkTheme() ? "1F2127" : "FBF9F3"),
        "controllerBackColor", DictionaryIsDarkTheme() ? 0x27211FFF : 0xF3F9FBFF))
    DictionarySyncHost()

    try {
        startTick := A_TickCount
        DebugLog("Dictionary webview creating")
        PanelHostEnsure(DictionaryHost)
        DictionarySyncHost()
        DebugLog("Dictionary webview ready in " . (A_TickCount - startTick) . " ms")
        return true
    } catch as webViewError {
        DebugLog("Dictionary webview failed: " . webViewError.Message)
        PanelHostHide(DictionaryHost)
        DictionarySyncHost()
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

DictionarySyncHost() {
    global DictionaryHost, DictionaryGui, DictionaryController, DictionaryWebView, DictionaryPageReady
    if !IsObject(DictionaryHost) {
        DictionaryGui := 0
        DictionaryController := 0
        DictionaryWebView := 0
        DictionaryPageReady := false
        return
    }
    DictionaryGui := DictionaryHost["gui"]
    DictionaryController := DictionaryHost["controller"]
    DictionaryWebView := DictionaryHost["webView"]
    DictionaryPageReady := DictionaryHost["pageReady"]
}

DictionaryNavigationCompleted(sender, args) {
    global DictionaryHost, DictionaryPageReady, DictionaryPendingEntry, DictionaryPendingQuery, DictionaryVisible
    try success := args.IsSuccess
    catch
        success := false
    DictionaryPageReady := success
    if IsObject(DictionaryHost)
        DictionaryHost["pageReady"] := success
    if !success {
        ShowMsg("The dictionary page could not be loaded.", 3500)
        return
    }
    if DictionaryVisible {
        if IsObject(DictionaryPendingEntry)
            DictionaryPushEntry(DictionaryPendingEntry)
        else {
            DictionaryClearPage()
            DictionaryPushQuery(DictionaryPendingQuery)
        }
        DictionaryPendingEntry := 0
        DictionaryPendingQuery := ""
    }
}

DictionaryWebMessageReceived(sender, args) {
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    messageType := LLMMsgField(msg, "type")
    if messageType = "lookup" {
        word := DictionaryNormalizeWord(LLMMsgField(msg, "text"))
        if word = ""
            return
        entry := DictionaryLookup(word)
        if IsObject(entry)
            DictionaryPushEntry(entry)
        else
            DictionaryPushMiss(word)
    } else if messageType = "openTranslate" {
        text := LLMMsgField(msg, "text")
        SetTimer(() => DictionaryOpenTranslate(text), -1)
    } else if messageType = "suggest" {
        DictionarySendSuggestions(LLMMsgField(msg, "text"))
    } else if messageType = "drag" {
        ; Borderless window: drag from the page topbar by faking a title-bar
        ; hit (WM_NCLBUTTONDOWN with HTCAPTION).
        PostMessage(0xA1, 2, 0, , "ahk_id " . DictionaryGui.Hwnd)
    } else if messageType = "hide" {
        DictionaryHide()
    } else if messageType = "cursorMove" {
        ; Same mouse-vanish-on-typing recovery as the other panels.
        ShowSystemCursor()
    }
}

; Ship the whole row to the page as JSON; every field is a string so the page
; decides how to render numbers and empty values.
DictionaryPushEntry(entry) {
    global DictionaryHost
    if !IsObject(DictionaryHost)
        return
    payload := Map()
    for key, value in entry
        payload[key] := String(value)
    payload["uiLanguage"] := LLMUiLanguage()
    PanelHostExecute(DictionaryHost, "window.setEntry(" . JSON.stringify(payload, 0) . ");")
}

DictionaryPushMiss(word) {
    global DictionaryHost
    if !IsObject(DictionaryHost)
        return
    payload := Map("word", word, "miss", JSON.true, "uiLanguage", LLMUiLanguage())
    PanelHostExecute(DictionaryHost, "window.setEntry(" . JSON.stringify(payload, 0) . ");")
}

DictionaryPushQuery(text) {
    global DictionaryHost
    if !IsObject(DictionaryHost)
        return
    text := Trim(text)
    if text = ""
        return
    autoLookup := DictionaryNormalizeWord(text) != ""
    script := "window.setQuery(" . LLMJsonQuote(text) . "," . (autoLookup ? "true" : "false") . ");"
    PanelHostExecute(DictionaryHost, script)
}

DictionaryOpenTranslate(text) {
    DictionaryHide()
    LLMTranslateShow(text, true)
}

; Open the dictionary page without carrying over the previous lookup result.
DictionaryClearPage() {
    global DictionaryHost
    if !IsObject(DictionaryHost)
        return
    if PanelHostExecute(DictionaryHost, "window.clearEntry();")
        SetTimer(DictionaryFocusSearch, -1)
}

; WinActivate can complete just after the clear script is queued. Move the
; controller focus first, then focus the page's search input on the next tick.
DictionaryFocusSearch(*) {
    global DictionaryHost, DictionaryVisible
    if !DictionaryVisible || !IsObject(DictionaryHost)
        return
    PanelHostMoveFocus(DictionaryHost, 0)
    PanelHostExecute(DictionaryHost,
        "window.focus();document.getElementById('search').focus({preventScroll:true});")
}

; Word suggestions for the search box, in three tiers: words starting with the
; query, words containing it, then fuzzy subsequence matches ("helo" → hello;
; the regexp scalar function registered by CSQLite does the matching). Capped
; at 12 words, deduplicated across tiers.
DictionarySendSuggestions(query) {
    global DictionaryHost
    if !IsObject(DictionaryHost)
        return
    words := [], seen := Map()
    db := DictionaryConnect()
    word := IsObject(db) ? DictionaryNormalizeWord(query) : ""
    if word != "" {
        ; Rank by corpus frequency (frq is a rank; lower is more common) so
        ; "runn" suggests "running" before "runnings", then alphabetically.
        freqOrder := " ORDER BY (CASE WHEN frq > 0 THEN frq ELSE 1000000 END), word"
        escaped := DictionarySqlLikeEscape(word)
        DictionarySuggestCollect(db,
            "SELECT word FROM stardict WHERE word LIKE '" . escaped . "%' ESCAPE '\'" . freqOrder,
            words, seen, 12)
        DictionarySuggestCollect(db,
            "SELECT word FROM stardict WHERE word LIKE '%" . escaped . "%' ESCAPE '\'" . freqOrder,
            words, seen, 12)
        if words.Length < 12 && StrLen(word) >= 3
            DictionarySuggestCollect(db,
                "SELECT word FROM stardict WHERE word LIKE '" . SubStr(word, 1, 1)
                . "%' AND word REGEXP '" . DictionaryFuzzyPattern(word) . "'" . freqOrder,
                words, seen, 12)
    }
    PanelHostExecute(DictionaryHost, "window.setSuggestions(" . JSON.stringify(words, 0) . ");")
}

; Run one suggestion query and merge new words into the capped list.
DictionarySuggestCollect(db, sql, words, seen, cap) {
    if words.Length >= cap
        return
    table := 0, gotTable := false
    try gotTable := db.GetTable(sql . " LIMIT 24", &table)
    if !gotTable
        return
    for row in table.Rows {
        w := row[1]
        if !seen.Has(w) {
            seen[w] := true
            words.Push(w)
            if words.Length >= cap
                break
        }
    }
}

; "helo" → "(?i)^h.*e.*l.*o": a prefix-anchored subsequence pattern.
DictionaryFuzzyPattern(word) {
    pattern := "(?i)^"
    Loop Parse word
        pattern .= DictionaryRegexEscape(A_LoopField) . ".*"
    return SubStr(pattern, 1, StrLen(pattern) - 2)
}

DictionaryRegexEscape(char) {
    if RegExMatch(char, "[.*?+\[\](){}|^$\\]")
        return "\" . char
    return char
}

; Escape LIKE wildcards so a query like "a_b" stays literal (ESCAPE '\').
DictionarySqlLikeEscape(word) {
    word := StrReplace(word, "\", "\\")
    word := StrReplace(word, "%", "\%")
    word := StrReplace(word, "_", "\_")
    return word
}

DictionaryResize(targetGui, minMax, width, height) {
    global DictionaryHost
    PanelHostResize(DictionaryHost, minMax)
}

DictionaryIsDarkTheme() {
    try return RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) = 0
    catch
        return false
}

; Windows paints a thin light border around captionless resizable windows.
; Turn it off (DWMWA_BORDER_COLOR = 34, DWMWA_COLOR_NONE = 0xFFFFFFFE) while
; keeping the resize edges; a no-op where the attribute is unsupported.
DictionaryRemoveFrameBorder(hwnd) {
    borderNone := 0xFFFFFFFE
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 34, "uint*", borderNone, "int", 4)
}

DictionaryFocusMonitor(*) {
    global DictionaryHost, DictionaryGui, DictionaryVisible, DictionaryFocusTimer
    if !DictionaryVisible || !IsObject(DictionaryGui) {
        PanelHostStopFocusMonitor(DictionaryHost)
        DictionaryFocusTimer := false
        return
    }
    if !WinActive("ahk_id " . DictionaryGui.Hwnd) {
        DebugLog("dictionary focus blur hide panelHwnd=" . DictionaryGui.Hwnd
            . " activeHwnd=" . WinExist("A"))
        DictionaryHide()
    }
}

DictionaryHide(*) {
    global DictionaryHost, DictionaryGui, DictionaryVisible, DictionaryFocusTimer
    global DictionaryPendingEntry, DictionaryPendingQuery
    DebugLog("dictionary hide visible=" . DictionaryVisible
        . " activeHwnd=" . WinExist("A"))
    DictionaryVisible := false
    DictionaryPendingEntry := 0
    DictionaryPendingQuery := ""
    PanelHostHide(DictionaryHost)
    PanelHostStopFocusMonitor(DictionaryHost)
    DictionaryFocusTimer := false
}

DictionaryShutdown(*) {
    global DictionaryHost, DictionaryGui, DictionaryController, DictionaryWebView
    global DictionaryVisible, DictionaryPageReady, DictionaryPendingEntry, DictionaryPendingQuery, DictionaryDB
    DictionaryVisible := false
    DictionaryPageReady := false
    DictionaryPendingEntry := 0
    DictionaryPendingQuery := ""
    PanelHostDestroy(DictionaryHost)
    DictionaryHost := 0
    try DictionaryDB := 0
    DictionaryWebView := 0
    DictionaryController := 0
    DictionaryGui := 0
}
