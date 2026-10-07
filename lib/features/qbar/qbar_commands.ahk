; qbar command dispatch, configured actions, and safe launching.

QbarExecute(ctrlHeld, registryGeneration, queryId, sessionId, candidateId) {
    if !QbarResultSnapshotCurrent(registryGeneration, queryId, sessionId, &snapshot)
        return false
    if candidateId != "" {
        if !snapshot["candidates"].Has(candidateId) {
            DebugLog("Qbar candidate execution rejected: unknown candidate")
            return false
        }
        candidate := snapshot["candidates"][candidateId]
        if Type(candidate) != "Map"
            return false
        return QbarExecuteSnapshotCandidate(candidate, ctrlHeld, registryGeneration)
    }
    return QbarExecuteRawText(snapshot["query"], ctrlHeld, registryGeneration)
}

QbarExecuteSnapshotCandidate(candidate, ctrlHeld, registryGeneration) {
    if candidate.Has("commandId") {
        commandId := candidate["commandId"]
        command := QbarRegistryCommand(commandId)
        if !IsObject(command) || !command["enabled"]
            return false
        args := candidate.Has("args") ? String(candidate["args"]) : ""
        if command["handlerId"] = "builtin.search" && args = "" {
            QbarExec("window.startSearch(" . LLMJsonQuote(candidate["short"]) . ");")
            return true
        }
        payload := 0
        if command["handlerId"] = "builtin.start-menu.open" {
            if !candidate.Has("value") || !candidate.Has("exe")
                return false
            payload := Map(
                "value", candidate["value"],
                "exe", candidate["exe"],
                "label", candidate["label"],
                "candidateKey", candidate.Has("candidateKey") ? candidate["candidateKey"] : "")
        } else if command["handlerId"] = "builtin.open-path" && candidate.Has("value") {
            payload := Map(
                "path", candidate["value"],
                "candidateKey", candidate.Has("candidateKey") ? candidate["candidateKey"] : "")
        }
        return QbarExecuteRegistered(commandId, args, ctrlHeld, registryGeneration, payload)
    }
    if candidate.Has("staticAction") && !QbarRegistryIsAvailable()
        return QbarStaticFallbackActionExecute(candidate["staticAction"],
            candidate.Has("args") ? String(candidate["args"]) : "")

    itemType := candidate.Has("type") ? candidate["type"] : ""
    if itemType = "app" && candidate.Has("value") && candidate.Has("exe") {
        if ctrlHeld {
            text := candidate["short"]
            url := QbarNormalizeUrl("www." . text . ".com")
            if QbarOpenUrl(url)
                return QbarHistoryRemember(QbarHistoryUrlEntry(text, url))
            return false
        }
        if QbarRunShortcut(candidate)
            return QbarHistoryRemember(QbarHistoryShortcutEntry(candidate))
        return false
    }
    if (itemType = "file" || itemType = "folder") && candidate.Has("value") {
        path := candidate["value"]
        if ctrlHeld {
            if QbarLocateInExplorer(path)
                return QbarHistoryRemember(QbarHistoryNew("reveal", path, path,
                    Map("path", path, "action", "reveal")))
            return false
        }
        if QbarOpenPath(path)
            return QbarHistoryRemember(QbarHistoryNew("path", path, path,
                Map("path", path)))
    }
    return false
}

QbarStaticFallbackActionExecute(action, args) {
    switch action {
        case "ai":
            if QbarAiAsk(args)
                return QbarHistoryRemember(QbarHistoryAiEntry(args))
        case "everything":
            QbarHide()
            runQuery := Trim(args) != ""
            if EverythingShow(args, runQuery)
                return QbarHistoryRemember(QbarHistoryEverythingEntry(args, runQuery))
        case "notes":
            return QbarScheduleNotes(args, true)
        case "clipboard":
            targetContext := ClipboardHistoryCaptureTargetContext()
            QbarHide()
            if ClipboardHistoryShow(args, targetContext, true)
                return QbarHistoryRemember(QbarHistoryClipboardEntry(args))
        case "settings":
            QbarHide()
            QbarScheduleSettingsHistory(QbarHistoryNew("settings", "cl set", "cl set",
                Map("page", "general")))
            return true
    }
    return false
}

QbarExecuteRawText(text, ctrlHeld, registryGeneration) {
    text := Trim(String(text), " `t")
    if text = ""
        return false

    resolution := QbarRegistryResolve(text)
    if resolution["candidates"].Length {
        candidate := resolution["candidates"][1]
        return QbarExecuteRegistered(candidate["commandId"], resolution["args"],
            ctrlHeld, registryGeneration)
    }
    if !QbarRegistryIsAvailable() {
        if QbarEsAlias(text) && !QbarConfigShortKeyExists(text)
            return QbarStaticFallbackActionExecute("everything", "")
        if !QbarConfigShortKeyExists(text) && QbarNotesAlias(text)
            return QbarStaticFallbackActionExecute("notes", "")

        if QbarSplitCommand(text, &typedToken, &typedRest) {
            if !QbarConfigShortKeyExists(typedToken) && QbarEsAlias(typedToken)
                return QbarStaticFallbackActionExecute("everything", typedRest)
            if !QbarConfigShortKeyExists(typedToken) && QbarNotesAlias(typedToken)
                return QbarStaticFallbackActionExecute("notes", typedRest)
            if !QbarConfigShortKeyExists(typedToken) && QbarAiAlias(typedToken)
                return QbarStaticFallbackActionExecute("ai", typedRest)
        }
        if !QbarConfigShortKeyExists(text) && QbarAiAlias(text)
            return QbarStaticFallbackActionExecute("ai", "")
    }

    DebugLog("QbarExecute")
    DebugLogPrivate("Qbar execute", text)
    if ctrlHeld {
        url := QbarNormalizeUrl("www." . text . ".com")
        return QbarExecuteOpenUrl(url, text, registryGeneration)
    }

    app := QbarFindByShort(QbarStartMenuItems(), text)
    if IsObject(app)
        return QbarExecuteStartMenuItem(app, text, registryGeneration)
    stringType := CheckStringType(text)
    if stringType = "file" || stringType = "folder" || stringType = "ftp"
        return QbarExecuteOpenPath(text, false, registryGeneration)
    if stringType = "web" {
        url := QbarNormalizeUrl(text)
        return QbarExecuteOpenUrl(url, text, registryGeneration)
    }
    DebugLog("QbarExecute no match")
    return false
}

QbarExecuteStartMenuItem(item, text, registryGeneration) {
    provider := QbarRegistryDynamicProviderByHandler("builtin.start-menu.open")
    if IsObject(provider) {
        item := QbarIndexAttachDynamicProvider(item, provider)
        if item.Has("dynamicBlocked")
            return false
        payload := Map(
            "value", item["value"],
            "exe", item["exe"],
            "label", item["label"],
            "candidateKey", item["candidateKey"])
        return QbarExecuteRegistered(provider["commandId"], text, false,
            registryGeneration, payload)
    }
    if QbarRegistryDynamicProviderUnavailable("builtin.start-menu.open")
        return false
    if QbarRunShortcut(item)
        return QbarHistoryRemember(QbarHistoryShortcutEntry(item))
    return false
}

QbarExecuteOpenPath(path, ctrlHeld, registryGeneration) {
    candidateKey := StrLower(StrReplace(Trim(path), "/", Chr(92)))
    provider := QbarRegistryDynamicProviderByHandler("builtin.open-path")
    if IsObject(provider)
        return QbarExecuteRegistered(provider["commandId"], path, ctrlHeld,
            registryGeneration, Map("path", path, "candidateKey", candidateKey))
    if QbarRegistryDynamicProviderUnavailable("builtin.open-path")
        return false
    if ctrlHeld {
        if QbarLocateInExplorer(path)
            return QbarHistoryRemember(QbarHistoryNew("reveal", path, path,
                Map("path", path, "action", "reveal")))
        return false
    }
    if QbarOpenPath(path)
        return QbarHistoryRemember(QbarHistoryNew("path", path, path,
            Map("path", path)))
    return false
}

QbarExecuteOpenUrl(url, input, registryGeneration) {
    candidateKey := Trim(url)
    provider := QbarRegistryDynamicProviderByHandler("builtin.open-url")
    if IsObject(provider)
        return QbarExecuteRegistered(provider["commandId"], input, false,
            registryGeneration, Map("url", url, "candidateKey", candidateKey))
    if QbarRegistryDynamicProviderUnavailable("builtin.open-url")
        return false
    if QbarOpenUrl(url)
        return QbarHistoryRemember(QbarHistoryUrlEntry(input, url))
    return false
}

QbarRegisteredCommandDisplayArguments(command, text) {
    if !IsObject(command)
        return ""
    displayName := Trim(String(command["displayName"]))
    text := Trim(String(text), " `t")
    if displayName = "" || StrLower(SubStr(text, 1, StrLen(displayName))) != StrLower(displayName)
        return ""
    suffix := SubStr(text, StrLen(displayName) + 1)
    if suffix = "" || SubStr(suffix, 1, 1) != " "
        return ""
    return Trim(suffix, " `t")
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

QbarHistoryClipboardEntry(searchText) {
    searchText := Trim(String(searchText))
    input := "cv" . (searchText = "" ? "" : " " . searchText)
    return QbarHistoryNew("clipboard", input, input, Map("search", searchText))
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
    targetHwnd := ClipboardHistoryCurrentExternalTarget()
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

; Replay an already-resolved history entry. The caller owns the successful
; replay's remember/move-to-front step; settings is deferred because its
; WebView2 creation must happen outside the qbar message callback.

QbarHistoryExecuteEntry(entry, command, runArgs) {
    kind := entry["kind"]
    payload := entry["payload"]
    switch kind {
        case "run":
            return QbarRunCommandAction(QbarRunCommand(payload["command"], runArgs),
                command["displayName"])
        case "shortcut":
            item := Map(
                "label", entry["input"],
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
        case "clipboard":
            targetContext := ClipboardHistoryCaptureTargetContext()
            QbarHide()
            return ClipboardHistoryShow(entry["payload"]["search"], targetContext, true)
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
