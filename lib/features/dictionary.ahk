; Local dictionary panel for single English words. Backed by an ECDICT-format
; stardict SQLite database (resources\dictionary.db) queried through CSQLite
; and rendered in a WebView2 panel (dictionary.html). The translate hotkey
; consults it first: a selection that is one known English word opens this
; card, anything else keeps going to the translate panel.

global DictionaryHost := 0
global DictionaryVisible := false
global DictionaryPendingEntry := 0
global DictionaryPendingQuery := ""
global DictionaryDB := 0
global DictionarySessionId := 0
global DictionaryQuerySeq := 0
global DictionaryLookupTimer := 0
global DictionarySuggestionTimer := 0

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
        DebugLog("dictionary sqlite load failed")
        return 0
    }
    if !db.OpenDB(DictionaryDBPath(), "R") {
        DebugLog("dictionary open failed")
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
        DebugLog("dictionary query failed")
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
    DebugLog("dictionary selected length=" . StrLen(word) . " known=" . IsObject(entry))
    if !IsObject(entry)
        return false
    DictionaryShow(entry)
    return true
}

DictionaryShow(entry := 0, query := "") {
    global DictionaryHost, DictionaryVisible, DictionarySessionId, DictionaryQuerySeq
    global DictionaryLookupTimer, DictionarySuggestionTimer
    global DictionaryPendingEntry, DictionaryPendingQuery
    DictionaryVisible := true
    DictionarySessionId += 1
    DictionaryQuerySeq += 1
    if IsObject(DictionaryLookupTimer)
        SetTimer(DictionaryLookupTimer, 0)
    if IsObject(DictionarySuggestionTimer)
        SetTimer(DictionarySuggestionTimer, 0)
    DictionaryLookupTimer := 0
    DictionarySuggestionTimer := 0
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
    panelGui := PanelHostGui(DictionaryHost)
    if IsObject(panelGui) {
        WinActivate("ahk_id " . panelGui.Hwnd)
    }
    WindowBarApplyNativeMode(DictionaryHost, WindowBarIsNative(DictionaryHost))
    WindowBarApplyPinnedState(DictionaryHost, WindowBarIsPinned(DictionaryHost),
        DictionaryVisible, DictionaryHide)
    WindowBarSetPinnedPage(DictionaryHost, WindowBarIsPinned(DictionaryHost))

    if PanelHostPageReady(DictionaryHost) {
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
    global DictionaryHost
    pagePath := A_ScriptDir . "\pages\dictionary.html"
    if IsObject(DictionaryHost) {
        try {
            PanelHostEnsure(DictionaryHost)
            return true
        } catch as existingError {
            PanelHostHide(DictionaryHost)
            DebugLog("dictionary webview failed")
            ShowMsg("WebView2 initialization failed: " . existingError.Message, 5000)
            return false
        }
    }

    dictionarySize := ScreenFitSize(640, 640, 460, 380)
    DictionaryHost := PanelHostCreate(pagePath, "capslock_p2 词典", Map(
        "guiOptions", "+Resize +MinSize460x380 +MinimizeBox +MaximizeBox +SysMenu +ToolWindow -Caption",
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

    try {
        startTick := A_TickCount
        DebugLog("Dictionary webview creating")
        PanelHostEnsure(DictionaryHost)
        DebugLog("Dictionary webview ready in " . (A_TickCount - startTick) . " ms")
        return true
    } catch as webViewError {
        DebugLog("Dictionary webview failed")
        PanelHostHide(DictionaryHost)
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

DictionaryNavigationCompleted(host, sender, args) {
    global DictionaryPendingEntry, DictionaryPendingQuery, DictionaryVisible
    if !PanelHostPageReady(host) {
        ShowMsg("The dictionary page could not be loaded.", 3500)
        return
    }
    if DictionaryVisible {
        WindowBarSyncPageState(host)
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
    global DictionaryHost, DictionarySessionId, DictionaryQuerySeq
    global DictionaryLookupTimer, DictionarySuggestionTimer
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    messageType := LLMMsgField(msg, "type")
    if WindowBarHandleDebugMessage(msg, "dictionary")
        return
    if WindowBarHandleMessage(DictionaryHost, messageType, DictionaryHide)
        return
    if messageType = "lookup" {
        word := DictionaryNormalizeWord(LLMMsgField(msg, "text"))
        if word = ""
            return
        DictionaryQuerySeq += 1
        if IsObject(DictionarySuggestionTimer)
            SetTimer(DictionarySuggestionTimer, 0)
        DictionarySuggestionTimer := 0
        if IsObject(DictionaryLookupTimer)
            SetTimer(DictionaryLookupTimer, 0)
        DictionaryLookupTimer := DictionaryRunLookup.Bind(word, DictionarySessionId, DictionaryQuerySeq)
        SetTimer(DictionaryLookupTimer, -1)
    } else if messageType = "openTranslate" {
        text := LLMMsgField(msg, "text")
        SetTimer(() => DictionaryOpenTranslate(text), -1)
    } else if messageType = "suggest" {
        query := LLMMsgField(msg, "text")
        DictionaryQuerySeq += 1
        if IsObject(DictionarySuggestionTimer)
            SetTimer(DictionarySuggestionTimer, 0)
        DictionarySuggestionTimer := DictionaryRunSuggestions.Bind(query, DictionarySessionId, DictionaryQuerySeq)
        SetTimer(DictionarySuggestionTimer, -1)
    }
}

DictionaryRunLookup(word, sessionId, querySeq) {
    global DictionaryVisible, DictionarySessionId, DictionaryQuerySeq, DictionaryLookupTimer
    DictionaryLookupTimer := 0
    if !DictionaryVisible || sessionId != DictionarySessionId || querySeq != DictionaryQuerySeq
        return
    entry := DictionaryLookup(word)
    if !DictionaryVisible || sessionId != DictionarySessionId || querySeq != DictionaryQuerySeq
        return
    if IsObject(entry)
        DictionaryPushEntry(entry)
    else
        DictionaryPushMiss(word)
}

DictionaryRunSuggestions(query, sessionId, querySeq) {
    global DictionaryVisible, DictionarySessionId, DictionaryQuerySeq, DictionarySuggestionTimer
    DictionarySuggestionTimer := 0
    if !DictionaryVisible || sessionId != DictionarySessionId || querySeq != DictionaryQuerySeq
        return
    DictionarySendSuggestions(query, sessionId, querySeq)
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
    DebugLog("dictionary push query auto=" . autoLookup . " length=" . StrLen(text))
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
; the regexp scalar function registered by CSQLite does the matching). Query
; text is bound as data so apostrophes cannot change the SQL. Capped at 12 words,
; deduplicated across tiers.
DictionarySendSuggestions(query, sessionId := 0, querySeq := 0) {
    global DictionaryHost, DictionaryVisible, DictionarySessionId, DictionaryQuerySeq
    if !IsObject(DictionaryHost)
        return
    if sessionId && (!DictionaryVisible || sessionId != DictionarySessionId || querySeq != DictionaryQuerySeq)
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
            "SELECT word FROM stardict WHERE word LIKE ? ESCAPE '\'" . freqOrder,
            [escaped . "%"], words, seen, 12, "prefix", StrLen(word))
        DictionarySuggestCollect(db,
            "SELECT word FROM stardict WHERE word LIKE ? ESCAPE '\'" . freqOrder,
            ["%" . escaped . "%"], words, seen, 12, "contains", StrLen(word))
        if words.Length < 12 && StrLen(word) >= 3
            DictionarySuggestCollect(db,
                "SELECT word FROM stardict WHERE word LIKE ? AND word REGEXP ?" . freqOrder,
                [SubStr(word, 1, 1) . "%", DictionaryFuzzyPattern(word)],
                words, seen, 12, "fuzzy", StrLen(word))
    }
    if sessionId && (!DictionaryVisible || sessionId != DictionarySessionId || querySeq != DictionaryQuerySeq)
        return
    PanelHostExecute(DictionaryHost, "window.setSuggestions(" . JSON.stringify(words, 0) . ");")
}

; Run one suggestion query and merge new words into the capped list.
DictionarySuggestCollect(db, sql, parameters, words, seen, cap, tier, inputLength) {
    if words.Length >= cap
        return
    failed := false
    querySucceeded := false
    candidateWords := []
    candidateSeen := Map()
    stage := "prepare"
    statement := 0
    try statement := db.Prepare(sql . " LIMIT 24")
    catch {
        DebugLog("dictionary suggestions failed tier=" . tier
            . " stage=prepare result=exception inputLength=" . inputLength)
        return
    }
    if !statement {
        ; Prepare is the only statement helper here that exposes SQLite's
        ; return code through db.ErrorCode. Capture it before doing anything else.
        errorCode := db.ErrorCode
        DebugLog("dictionary suggestions failed tier=" . tier
            . " stage=prepare rc=" . errorCode . " inputLength=" . inputLength)
        return
    }

    try {
        stage := "bind"
        for index, value in parameters {
            if !db.StatementBindText(statement, index, value) {
                ; StatementBindText exposes success/failure, not the SQLite code.
                DebugLog("dictionary suggestions failed tier=" . tier
                    . " stage=bind index=" . index . " result=false inputLength=" . inputLength)
                failed := true
                break
            }
        }
        if !failed {
            loop {
                stage := "step"
                resultCode := db.StatementStep(statement)
                if resultCode = 101 {
                    querySucceeded := true
                    break
                }
                if resultCode != 100 {
                    ; Do not use db.ErrorCode here: Step returns its own code and
                    ; does not refresh the CSQLite error properties.
                    DebugLog("dictionary suggestions failed tier=" . tier
                        . " stage=step rc=" . resultCode . " inputLength=" . inputLength)
                    failed := true
                    break
                }
                stage := "column"
                suggestedWord := db.StatementColumnText(statement, 0)
                stage := "collect"
                if !seen.Has(suggestedWord) && !candidateSeen.Has(suggestedWord) {
                    candidateSeen[suggestedWord] := true
                    candidateWords.Push(suggestedWord)
                    if candidateWords.Length >= cap - words.Length {
                        ; Reaching the caller's cap is a successful early stop.
                        querySucceeded := true
                        break
                    }
                }
            }
        }
    } catch {
        failed := true
        DebugLog("dictionary suggestions failed tier=" . tier
            . " stage=" . stage . " result=exception inputLength=" . inputLength)
    } finally {
        finalized := false
        try finalized := db.StatementFinalize(statement)
        catch {
            finalized := false
        }
        if !finalized
            ; StatementFinalize also exposes only success/failure.
            DebugLog("dictionary suggestions failed tier=" . tier
                . " stage=finalize result=false inputLength=" . inputLength)
    }
    ; Keep a failed tier from leaking partially stepped rows into later tiers.
    if querySucceeded && finalized && !failed {
        for suggestedWord in candidateWords {
            seen[suggestedWord] := true
            words.Push(suggestedWord)
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

DictionaryHide(*) {
    global DictionaryHost, DictionaryVisible, DictionarySessionId, DictionaryQuerySeq
    global DictionaryLookupTimer, DictionarySuggestionTimer
    global DictionaryPendingEntry, DictionaryPendingQuery
    DictionaryVisible := false
    DictionarySessionId += 1
    DictionaryQuerySeq += 1
    if IsObject(DictionaryLookupTimer)
        SetTimer(DictionaryLookupTimer, 0)
    if IsObject(DictionarySuggestionTimer)
        SetTimer(DictionarySuggestionTimer, 0)
    DictionaryLookupTimer := 0
    DictionarySuggestionTimer := 0
    DictionaryPendingEntry := 0
    DictionaryPendingQuery := ""
    PanelHostHide(DictionaryHost)
}

DictionaryShutdown(*) {
    global DictionaryHost, DictionaryVisible, DictionaryPendingEntry, DictionaryPendingQuery, DictionaryDB
    global DictionarySessionId, DictionaryQuerySeq
    global DictionaryLookupTimer, DictionarySuggestionTimer
    DictionaryVisible := false
    DictionarySessionId += 1
    DictionaryQuerySeq += 1
    if IsObject(DictionaryLookupTimer)
        SetTimer(DictionaryLookupTimer, 0)
    if IsObject(DictionarySuggestionTimer)
        SetTimer(DictionarySuggestionTimer, 0)
    DictionaryLookupTimer := 0
    DictionarySuggestionTimer := 0
    DictionaryPendingEntry := 0
    DictionaryPendingQuery := ""
    PanelHostDestroy(DictionaryHost)
    DictionaryHost := 0
    try DictionaryDB := 0
}

DictionaryIsActive() {
    global DictionaryHost
    return PanelHostWindowActive(DictionaryHost)
}
