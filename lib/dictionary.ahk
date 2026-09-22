; Local dictionary panel for single English words. Backed by an ECDICT-format
; stardict SQLite database (resources\dictionary.db) queried through CSQLite
; and rendered in a WebView2 panel (dictionary.html). The translate hotkey
; consults it first: a selection that is one known English word opens this
; card, anything else keeps going to the translate panel.

global DictionaryGui := 0
global DictionaryController := 0
global DictionaryWebView := 0
global DictionaryPageReady := false
global DictionaryVisible := false
global DictionaryPendingEntry := 0
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

DictionaryShow(entry) {
    global DictionaryGui, DictionaryVisible, DictionaryPageReady, DictionaryFocusTimer
    global DictionaryPendingEntry
    DictionaryVisible := true
    DictionaryPendingEntry := entry
    if !DictionaryEnsureWebView() {
        DictionaryVisible := false
        DictionaryPendingEntry := 0
        return
    }
    dictionarySize := ScreenFitSize(640, 640, 460, 380)
    DictionaryGui.Show("w" . dictionarySize[1] . " h" . dictionarySize[2] . " Center")
    DictionaryRemoveFrameBorder(DictionaryGui.Hwnd)
    WinActivate("ahk_id " . DictionaryGui.Hwnd)
    ShowSystemCursor()
    SetTimer(DictionaryFocusMonitor, 100)
    DictionaryFocusTimer := true

    if DictionaryPageReady
        DictionaryPushEntry(entry)
}

DictionaryEnsureWebView() {
    global DictionaryGui, DictionaryController, DictionaryWebView
    global DictionaryPageReady
    if IsObject(DictionaryGui) && IsObject(DictionaryWebView)
        return true

    pagePath := A_ScriptDir . "\pages\dictionary.html"
    loaderPath := A_ScriptDir . "\WebView2\" . (A_PtrSize = 8 ? "64bit" : "32bit") . "\WebView2Loader.dll"
    if !FileExist(pagePath) {
        ShowMsg("pages\dictionary.html is missing.", 3500)
        return false
    }
    if !FileExist(loaderPath) {
        ShowMsg("WebView2Loader.dll is missing: " . loaderPath, 5000)
        return false
    }

    if !IsObject(DictionaryGui) {
        ; Captionless window: the page's topbar drags it via the "drag"
        ; message, the page's own close button (or Esc / focus loss) hides it.
        DictionaryGui := Gui("+AlwaysOnTop -Caption +Resize +MinSize460x380 +ToolWindow", "capslock_p2 词典")
        DictionaryGui.MarginX := 0
        DictionaryGui.MarginY := 0
        ; Match the page background so the first paint never flashes white.
        DictionaryGui.BackColor := DictionaryIsDarkTheme() ? "1F2127" : "FBF9F3"
        DictionaryGui.OnEvent("Close", DictionaryHide)
        DictionaryGui.OnEvent("Escape", DictionaryHide)
        DictionaryGui.OnEvent("Size", DictionaryResize)
        dictionarySize := ScreenFitSize(640, 640, 460, 380)
    DictionaryGui.Show("w" . dictionarySize[1] . " h" . dictionarySize[2] . " Center")
    }

    try {
        dataPath := A_Temp . "\CapsLockPlusDictionaryWebView2"
        startTick := A_TickCount
        DebugLog("Dictionary webview creating")
        DictionaryController := WebView2.CreateControllerAsync(
            DictionaryGui.Hwnd, 0, dataPath, "", loaderPath
        ).await2(15000)
        DebugLog("Dictionary webview ready in " . (A_TickCount - startTick) . " ms")
        DictionaryController.Fill()
        ; Blend any fractional-pixel gap at the window edges into the page.
        DictionaryController.DefaultBackgroundColor := DictionaryIsDarkTheme() ? 0x27211FFF : 0xF3F9FBFF
        DictionaryWebView := DictionaryController.CoreWebView2
        DictionaryWebView.add_NavigationCompleted(DictionaryNavigationCompleted)
        DictionaryWebView.add_WebMessageReceived(DictionaryWebMessageReceived)
        DictionaryPageReady := false
        pageUrl := "file:///" . StrReplace(pagePath, "\", "/")
        DictionaryWebView.Navigate(pageUrl)
        return true
    } catch as webViewError {
        DebugLog("Dictionary webview failed: " . webViewError.Message)
        DictionaryPageReady := false
        DictionaryWebView := 0
        DictionaryController := 0
        DictionaryGui.Hide()
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

DictionaryNavigationCompleted(sender, args) {
    global DictionaryPageReady, DictionaryPendingEntry, DictionaryVisible
    try success := args.IsSuccess
    catch
        success := false
    DictionaryPageReady := success
    if !success {
        ShowMsg("The dictionary page could not be loaded.", 3500)
        return
    }
    if DictionaryVisible && IsObject(DictionaryPendingEntry) {
        DictionaryPushEntry(DictionaryPendingEntry)
        DictionaryPendingEntry := 0
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
    global DictionaryWebView, DictionaryPageReady
    if !DictionaryPageReady || !IsObject(DictionaryWebView)
        return
    payload := Map()
    for key, value in entry
        payload[key] := String(value)
    payload["uiLanguage"] := LLMTranslateUiLanguage()
    try DictionaryWebView.ExecuteScriptAsync("window.setEntry(" . JSON.stringify(payload, 0) . ");")
    catch
        return
}

DictionaryPushMiss(word) {
    global DictionaryWebView, DictionaryPageReady
    if !DictionaryPageReady || !IsObject(DictionaryWebView)
        return
    payload := Map("word", word, "miss", JSON.true, "uiLanguage", LLMTranslateUiLanguage())
    try DictionaryWebView.ExecuteScriptAsync("window.setEntry(" . JSON.stringify(payload, 0) . ");")
    catch
        return
}

; Word suggestions for the search box, in three tiers: words starting with the
; query, words containing it, then fuzzy subsequence matches ("helo" → hello;
; the regexp scalar function registered by CSQLite does the matching). Capped
; at 12 words, deduplicated across tiers.
DictionarySendSuggestions(query) {
    global DictionaryWebView, DictionaryPageReady
    if !DictionaryPageReady || !IsObject(DictionaryWebView)
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
    try DictionaryWebView.ExecuteScriptAsync("window.setSuggestions(" . JSON.stringify(words, 0) . ");")
    catch
        return
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
    global DictionaryController
    if minMax != -1 && IsObject(DictionaryController)
        try DictionaryController.Fill()
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
    global DictionaryGui, DictionaryVisible, DictionaryFocusTimer
    if !DictionaryVisible || !IsObject(DictionaryGui) {
        SetTimer(DictionaryFocusMonitor, 0)
        DictionaryFocusTimer := false
        return
    }
    if !WinActive("ahk_id " . DictionaryGui.Hwnd)
        DictionaryHide()
}

DictionaryHide(*) {
    global DictionaryGui, DictionaryVisible, DictionaryFocusTimer
    global DictionaryPendingEntry
    DictionaryVisible := false
    DictionaryPendingEntry := 0
    if IsObject(DictionaryGui)
        DictionaryGui.Hide()
    SetTimer(DictionaryFocusMonitor, 0)
    DictionaryFocusTimer := false
}

DictionaryShutdown(*) {
    global DictionaryGui, DictionaryController, DictionaryWebView
    global DictionaryVisible, DictionaryPageReady, DictionaryPendingEntry, DictionaryDB
    DictionaryVisible := false
    DictionaryPageReady := false
    DictionaryPendingEntry := 0
    SetTimer(DictionaryFocusMonitor, 0)
    try DictionaryDB := 0
    try DictionaryWebView := 0
    try DictionaryController := 0
    if IsObject(DictionaryGui) {
        try DictionaryGui.Destroy()
        DictionaryGui := 0
    }
}
