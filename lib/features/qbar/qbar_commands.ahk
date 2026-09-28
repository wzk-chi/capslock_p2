; qbar command dispatch, configured actions, and safe launching.

QbarExecute(text, selected, ctrlHeld, selectedType := "") {
    text := Trim(text, " `t")
    ; "键 ->类型 值" adds an entry to the settings file. It is decided on the
    ; typed text alone and before the row handling, because the row for the
    ; trigger would otherwise replace the command with just the trigger.
    if QbarTryInlineConfig(text)
        return
    if QbarEsAlias(text) && !QbarConfigShortKeyExists(text) {
        QbarHide()
        if EverythingShow("", false)
            QbarHistoryRemember(QbarHistoryEverythingEntry("", false))
        return
    }
    ; Preserve the complete argument from all four built-in aliases before
    ; considering whichever row the page last highlighted. This makes Enter
    ; reliable even when the debounce result has not reached WebView2 yet.
    if QbarSplitCommand(text, &typedToken, &typedRest)
        && !QbarConfigShortKeyExists(typedToken) && QbarEsAlias(typedToken) {
        QbarHide()
        if EverythingShow(typedRest, typedRest != "")
            QbarHistoryRemember(QbarHistoryEverythingEntry(typedRest, typedRest != ""))
        return
    }
    if selected != "" {
        if selectedType = "everything" {
            query := QbarEverythingArgument(text)
            QbarHide()
            if EverythingShow(query, query != "")
                QbarHistoryRemember(QbarHistoryEverythingEntry(query, query != ""))
            return
        }
        ; An explicit AI result row asks with the typed text as-is. A bare
        ; trigger word opens the chat with an empty composer.
        if selectedType = "ai" {
            question := QbarAiQuestion(selected)
            if QbarAiAsk(selected)
                QbarHistoryRemember(QbarHistoryAiEntry(question))
            return
        }
        if selectedType = "search" {
            ; An engine row is armed only while there is nothing to search for
            ; yet: it fills the trigger in and leaves the caret after it. Once
            ; the line already reads "trigger query", the row is just the pinned
            ; match for its own trigger, so fall through and search with it
            ; rather than clearing what was typed.
            if QbarSearchArgument(text, selected) = "" {
                ; The built-in q row is also the short form of the AI command.
                ; A bare q opens the chat; a configured q trigger keeps its
                ; normal search precedence.
                if QbarAiAlias(selected) && !QbarConfigShortKeyExists(selected) {
                    if QbarAiAsk(selected)
                        QbarHistoryRemember(QbarHistoryAiEntry(""))
                    return
                }
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
    ; AI is an explicit command. A bare q is normally handled by the built-in
    ; search row above; this branch covers bare ai and a q/ai input when the
    ; page has no selectable row yet.
    if !QbarConfigShortKeyExists(text) && QbarAiAlias(text) {
        if QbarAiAsk(text)
            QbarHistoryRemember(QbarHistoryAiEntry(""))
        return
    }
    DebugLog("QbarExecute")
    DebugLogPrivate("Qbar execute", text)

    if ctrlHeld {
        ; A highlighted file or folder row is revealed in Explorer instead of
        ; the domain fallback -- mainly for Everything results, but folder
        ; browsing gets it too.
        if selected != "" && (selectedType = "file" || selectedType = "folder") {
            if QbarLocateInExplorer(text)
                QbarHistoryRemember(QbarHistoryNew("reveal", text, text,
                    Map("path", Trim(text))))
            return
        }
        ; Ctrl+Enter otherwise treats the typed text as a domain name.
        url := QbarNormalizeUrl("www." . text . ".com")
        if QbarOpenUrl(url)
            QbarHistoryRemember(QbarHistoryUrlEntry(text, url))
        return
    }

    if QbarSplitCommand(text, &firstToken, &rest) {
        ; Everything trigger: close qbar and hand the complete remainder to the
        ; independent Everything panel. All four built-in aliases share this
        ; path; configured commands with the same token win above it.
        if !QbarConfigShortKeyExists(firstToken) && QbarEsAlias(firstToken) {
            QbarHide()
            if EverythingShow(rest, rest != "")
                QbarHistoryRemember(QbarHistoryEverythingEntry(rest, rest != ""))
            return
        }
        ; "ai <question>" / "q <question>" -- the configured LLM answers or
        ; explains; an ini entry named ai/q wins over the built-in command.
        if !QbarConfigShortKeyExists(firstToken) && QbarAiAlias(firstToken) {
            if QbarAiAsk(rest)
                QbarHistoryRemember(QbarHistoryAiEntry(rest))
            return
        }
        ; "cl <sub>" -- a shortcut to the settings center.
        if QbarTryClCommand(firstToken, rest)
            return
        ; "web <url>" opens whatever follows as a site, http:// added when it
        ; is missing; a configured "web" trigger wins over the command word.
        if firstToken = "web" && !QbarConfigShortKeyExists("web") {
            url := QbarNormalizeUrl(rest)
            if QbarOpenUrl(url)
                QbarHistoryRemember(QbarHistoryUrlEntry(text, url))
            return
        }
        ; Search engine trigger: substitute {q} with the URL-encoded argument.
        search := QbarConfigEntry("QSearch", firstToken)
        if !IsObject(search)
            search := QbarConfigEntry("QSearch", QbarEngineAlias(firstToken))
        if IsObject(search) {
            url := QbarNormalizeUrl(StrReplace(search["value"], "{q}", UrlEncodeUtf8(rest)))
            if QbarOpenUrl(url)
                QbarHistoryRemember(QbarHistoryUrlEntry(text, url))
            return
        }
        runSucceeded := false
        runCommand := ""
        if QbarRunBy(firstToken, rest, &runSucceeded, &runCommand) {
            if runSucceeded
                QbarHistoryRemember(QbarHistoryRunEntry(text, runCommand))
            return
        }
    }

    runSucceeded := false
    runCommand := ""
    if QbarRunBy(text, "", &runSucceeded, &runCommand) {
        if runSucceeded
            QbarHistoryRemember(QbarHistoryRunEntry(text, runCommand))
        return
    }
    web := QbarConfigEntry("QWeb", text)
    if IsObject(web) {
        url := QbarNormalizeUrl(web["value"])
        if QbarOpenUrl(url)
            QbarHistoryRemember(QbarHistoryUrlEntry(text, url))
        return
    }
    app := QbarFindByShort(QbarStartMenuItems(), text)
    if IsObject(app) {
        if QbarRunShortcut(app)
            QbarHistoryRemember(QbarHistoryShortcutEntry(app))
        return
    }

    ; "type" would shadow the built-in Type() function in the global namespace.
    stringType := CheckStringType(text)
    if stringType = "file" || stringType = "folder" || stringType = "ftp" {
        if QbarOpenPath(text)
            QbarHistoryRemember(QbarHistoryNew("path", text, text,
                Map("path", Trim(text))))
        return
    }
    if stringType = "web" {
        url := QbarNormalizeUrl(text)
        if QbarOpenUrl(url)
            QbarHistoryRemember(QbarHistoryUrlEntry(text, url))
        return
    }

    ; Unmatched text has no action. AI requires an explicit q/ai prefix.
    DebugLog("QbarExecute no match")
}

QbarHistoryAiEntry(question) {
    question := Trim(question)
    input := "ai" . (question = "" ? "" : " " . question)
    return QbarHistoryNew("ai", input, input, Map("question", question))
}

QbarHistoryEverythingEntry(query, runQuery) {
    query := Trim(query, " `t")
    input := "e" . (query = "" ? "" : " " . query)
    return QbarHistoryNew("everything", input, input,
        Map("query", query, "runQuery", runQuery))
}

QbarHistoryUrlEntry(input, url) {
    input := Trim(input, " `t")
    return QbarHistoryNew("url", input, input, Map("url", url))
}

QbarHistoryRunEntry(input, command) {
    input := Trim(input, " `t")
    return QbarHistoryNew("run", input, input, Map("command", command))
}

QbarHistoryShortcutEntry(item) {
    label := item["label"]
    return QbarHistoryNew("shortcut", label, label, Map(
        "shortcutPath", item["value"],
        "exe", item["exe"]))
}

QbarAiQuestion(text) {
    text := Trim(text)
    return QbarAiAlias(text) ? "" : text
}

; Replay an already-resolved history entry. The caller owns the successful
; replay's remember/move-to-front step; settings is deferred because its
; WebView2 creation must happen outside the qbar message callback.

QbarHistoryExecuteEntry(entry) {
    kind := entry["kind"]
    payload := entry["payload"]
    switch kind {
        case "run":
            return QbarRunCommandAction(payload["command"], payload["command"])
        case "shortcut":
            item := Map(
                "label", entry["label"],
                "value", payload["shortcutPath"],
                "exe", payload["exe"])
            return QbarRunShortcut(item)
        case "url":
            return QbarOpenUrl(payload["url"])
        case "path":
            return QbarOpenPath(payload["path"])
        case "reveal":
            return QbarLocateInExplorer(payload["path"])
        case "ai":
            return QbarAiAsk(payload["question"])
        case "everything":
            QbarHide()
            return EverythingShow(payload["query"], QbarHistoryBoolValue(payload["runQuery"]))
        case "settings":
            QbarHide()
            return QbarScheduleSettingsHistory(entry)
        default:
            return false
    }
}

; Handles "键 ->类型 值", which adds one entry to the settings file so qbar can
; be extended without leaving it. Returns true when the text was such a command,
; so the caller stops.

QbarTryInlineConfig(text) {
    if !QbarSplitCommand(text, &firstToken, &rest)
        return false
    if !QbarSplitCommand(rest, &arrowWord, &value)
        return false
    if !RegExMatch(arrowWord, "^->(.*)$", &match)
        return false
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
    prompt := QbarText("Add to ", "添加到 ") . "[" . section . "]`n`n" . key . "=" . value
    if MsgBox(prompt, "qbar", "OKCancel") != "OK"
        return

    existing := ""
    existing := ConfigRead(section, key, "")
    if existing != "" {
        prompt := QbarText("That key is already set. Replace it?", "该键已存在，要覆盖吗？")
        prompt .= "`n`n" . key . "=" . existing . "`n`n-> " . key . "=" . value
        if MsgBox(prompt, "qbar", "OKCancel") != "OK"
            return
    }

    if ConfigSet(section, key, value)
        ShowMsg(QbarText("Added ", "已添加 ") . key, 1500)
}

; "cl <sub>" -- the built-in shortcut to the settings center. Returns true
; when the line was a cl command.

QbarTryClCommand(cmd, param) {
    if cmd != "cl"
        return false
    if param = "set" || param = "settings" {
        QbarHide()
        ; Qbar commands arrive from a WebView2 callback. Defer creation of the
        ; settings WebView until that callback has returned.
        QbarScheduleSettingsHistory(QbarHistoryNew("settings", "cl set", "cl set",
            Map("page", "general")))
        return true
    }
    ShowMsg(QbarText("Unknown cl command: ", "未知的 cl 命令：") . param, 2500)
    return true
}

QbarScheduleSettingsHistory(entry) {
    SetTimer(QbarSettingsHistoryAction.Bind(entry), -1)
    return "deferred"
}

QbarSettingsHistoryAction(entry, *) {
    page := entry["payload"]["page"]
    if SettingsShow(page)
        QbarHistoryRemember(entry)
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
; a bare trigger or empty text opens an empty composer. When the API is not
; configured yet the chat opens its settings view first.

QbarAiAsk(text) {
    text := Trim(text)
    ; A bare trigger opens the chat so the question can be entered there.
    if QbarAiAlias(text)
        text := ""
    QbarHide()
    return AiChatShow(text)
}

QbarRunBy(shortKey, params := "", &didRun := false, &commandOut := "") {
    didRun := false
    commandOut := ""
    entry := QbarConfigEntry("QRun", shortKey)
    if !IsObject(entry)
        return false

    if params != "" {
        ; The argument may itself be another entry's trigger (reference qrunBy).
        replacement := QbarConfigEntry("QWeb", params)
        if IsObject(replacement)
            params := replacement["value"]
        else {
            replacement := QbarConfigEntry("QRun", params)
            if IsObject(replacement)
                params := replacement["value"]
        }
    }

    command := QbarRunCommand(entry["value"], params)
    commandOut := command
    didRun := QbarRunCommandAction(command, entry["value"])
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
    else if runString != ""
        command := runString . (parameters = "" ? "" : " " . parameters)
    else
        command := Trim(value)
    if runAsAdmin
        command := "*RunAs " . command
    if params != ""
        command .= " " . Chr(34) . params . Chr(34)
    return command
}

QbarRunCommandAction(command, errorText := "") {
    try {
        Run(command)
        QbarHide()
        return true
    } catch as runError {
        DebugLog("Qbar run failed")
        if errorText = ""
            errorText := command
        ShowMsg(QbarText("Cannot run: ", "无法运行：") . errorText, 2500)
        return false
    }
}

QbarRunShortcut(item) {
    try {
        Run(QbarFilesystemTarget(item["value"]))
        QbarHide()
        return true
    } catch {
        ; Fall through to the target executable when the .lnk is stale.
    }
    try {
        Run(QbarFilesystemTarget(item["exe"]))
        QbarHide()
        return true
    } catch as runError {
        DebugLog("Qbar start menu run failed")
        ShowMsg(QbarText("Cannot run: ", "无法运行：") . item["label"], 2500)
        return false
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

QbarNormalizeUrl(url) {
    url := Trim(url)
    if url = ""
        return ""
    if !RegExMatch(url, "i)^(https?|ftp)://")
        url := "http://" . url
    return url
}

QbarOpenUrl(url) {
    url := QbarNormalizeUrl(url)
    if url = ""
        return false
    return QbarOpenPath(url)
}

; Local files, folders and already-formed URLs go straight to the shell.

QbarOpenPath(path) {
    path := Trim(path)
    if path = ""
        return false
    target := QbarFilesystemTarget(path)
    try {
        Run(target)
        QbarHide()
        return true
    } catch as runError {
        DebugLog("Qbar open failed")
        ShowMsg(QbarText("Cannot open: ", "无法打开：") . path, 2500)
        return false
    }
}

; Ctrl+Enter on a file row: reveal it in Explorer with the item selected. A
; folder row just opens, since there is nothing to select inside itself.

QbarLocateInExplorer(path) {
    path := Trim(path)
    if path = ""
        return false
    if DirExist(path) {
        return QbarOpenPath(path)
    }
    parent := ""
    SplitPath(path, , &parent)
    if parent = "" || !DirExist(parent) {
        ShowMsg(QbarText("Not found: ", "找不到：") . path, 2500)
        return false
    }
    try {
        Run("explorer.exe /select," . Chr(34) . path . Chr(34))
        QbarHide()
        return true
    } catch as runError {
        DebugLog("Qbar locate failed")
        ShowMsg(QbarText("Cannot open: ", "无法打开：") . path, 2500)
        return false
    }
}
