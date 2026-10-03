; qbar command dispatch, configured actions, and safe launching.

QbarExecute(text, selected, ctrlHeld, selectedType := "", commandId := "", registryGeneration := 0,
    queryId := 0, sessionId := "", candidateId := "") {
    text := Trim(text, " `t")
    if commandId != "" {
        command := QbarRegistryCommand(commandId)
        if !IsObject(command)
            return false
        if registryGeneration && registryGeneration != QbarRegistryGeneration()
            return false
        if sessionId != "" && sessionId != QbarSessionId
            return false
        if queryId && queryId != QbarPageQueryId
            return false
        if candidateId != "" && sessionId != "" {
            candidatePrefix := sessionId . ":" . queryId . ":"
            if SubStr(candidateId, 1, StrLen(candidatePrefix)) != candidatePrefix
                return false
        }
        resolution := QbarRegistryResolve(text)
        args := resolution["args"]
        if command["handlerId"] = "builtin.search" && args = "" && selected != "" {
            QbarExec("window.startSearch(" . LLMJsonQuote(selected) . ");")
            return true
        }
        return QbarExecuteRegistered(commandId, args, ctrlHeld, registryGeneration)
    }
    ; Keep the settings shortcut usable when the SQLite registry could not be
    ; opened and Qbar is showing its static fallback rows.
    if selectedType = "settings" {
        QbarHide()
        QbarScheduleSettingsHistory(QbarHistoryNew("settings", "cl set", "cl set",
            Map("page", "general")))
        return true
    }
    resolution := QbarRegistryResolve(text)
    if resolution["candidates"].Length {
        candidate := resolution["candidates"][1]
        return QbarExecuteRegistered(candidate["commandId"], resolution["args"], ctrlHeld,
            QbarRegistryGeneration())
    }
    if QbarEsAlias(text) && !QbarConfigShortKeyExists(text) {
        QbarHide()
        if EverythingShow("", false)
            QbarHistoryRemember(QbarHistoryEverythingEntry("", false))
        return
    }
    if !QbarConfigShortKeyExists(text) && QbarNotesAlias(text) {
        QbarScheduleNotes("", true)
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
    if QbarSplitCommand(text, &typedToken, &typedRest)
        && !QbarConfigShortKeyExists(typedToken) && QbarNotesAlias(typedToken) {
        QbarScheduleNotes(typedRest, true)
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
        if selectedType = "notes" {
            QbarScheduleNotes(QbarSearchArgument(text, selected), true)
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

QbarHistoryNotesEntry(searchText) {
    searchText := Trim(String(searchText))
    input := searchText = "" ? "笔记" : "笔记 " . searchText
    return QbarHistoryNew("notes", input, input, Map("search", searchText))
}

QbarNotesAlias(token) {
    static aliases := Map("n", true, "note", true, "w", true, "write", true)
    return aliases.Has(StrLower(Trim(token)))
}

QbarScheduleNotes(searchText := "", recordHistory := true) {
    global QbarTargetHwnd
    targetHwnd := QbarTargetHwnd
    QbarHide()
    SetTimer(NotesShow.Bind(String(searchText), targetHwnd, recordHistory), -1)
    return true
}

QbarScheduleNotesHistory(entry) {
    global QbarTargetHwnd
    targetHwnd := QbarTargetHwnd
    QbarHide()
    SetTimer(QbarNotesHistoryAction.Bind(entry, targetHwnd), -1)
    return "deferred"
}

QbarNotesHistoryAction(entry, targetHwnd, *) {
    if NotesShow(entry["payload"]["search"], targetHwnd, false)
        QbarHistoryRemember(entry)
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
        case "notes":
            return QbarScheduleNotesHistory(entry)
        case "settings":
            QbarHide()
            return QbarScheduleSettingsHistory(entry)
        default:
            return false
    }
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
