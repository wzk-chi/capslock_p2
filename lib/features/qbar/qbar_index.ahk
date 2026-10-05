; qbar item index, filtering, and row preparation.

QbarAllItems() {
    items := []
    for item in QbarConfigItems()
        items.Push(item)
    startMenuProvider := QbarRegistryDynamicProviderByHandler("builtin.start-menu.open")
    for item in QbarStartMenuItems() {
        indexed := QbarIndexAttachDynamicProvider(item, startMenuProvider,
            "builtin.start-menu.open")
        if !indexed.Has("dynamicBlocked")
            items.Push(indexed)
    }
    return items
}

QbarIndexCopyItem(item) {
    copy := Map()
    if Type(item) != "Map"
        return copy
    for key, value in item
        copy[key] := value
    return copy
}

QbarIndexAttachDynamicProvider(item, provider, handlerId := "") {
    copy := QbarIndexCopyItem(item)
    if copy.Has("value") && Type(copy["value"]) = "String" {
        candidateKey := StrLower(StrReplace(Trim(copy["value"]), "/", Chr(92)))
        if candidateKey != ""
            copy["candidateKey"] := candidateKey
    }
    if Type(provider) != "Map" || !provider["enabled"] {
        if handlerId != "" && QbarRegistryDynamicProviderUnavailable(handlerId)
            copy["dynamicBlocked"] := true
        return copy
    }
    candidateKey := copy.Has("candidateKey") ? String(copy["candidateKey"]) : ""
    copy["commandId"] := provider["commandId"]
    copy["pluginId"] := provider["pluginId"]
    copy["usageKey"] := provider["usageKey"]
    if candidateKey != ""
        copy["usageKey"] .= ":" . candidateKey
    return copy
}

QbarInvalidateConfigIndex() {
    global QbarConfigIndexCache, QbarConfigIndexGeneration
    QbarConfigIndexGeneration += 1
    QbarConfigIndexCache := 0
    QbarSearchOnConfigInvalidated()
}

QbarInvalidateResultSnapshot() {
    global QbarResultSnapshot
    QbarResultSnapshot := 0
}

QbarQueryContextCurrent(registryGeneration, queryId, querySeq, sessionId) {
    global QbarVisible, QbarSessionId, QbarPageQueryId, QbarQuerySeq
    return QbarVisible && sessionId != "" && sessionId = QbarSessionId
        && queryId > 0 && queryId = QbarPageQueryId
        && querySeq = QbarQuerySeq && registryGeneration = QbarRegistryGeneration()
}

QbarResultSnapshotCurrent(registryGeneration, queryId, sessionId, &snapshot := 0) {
    global QbarResultSnapshot
    snapshot := 0
    if Type(QbarResultSnapshot) != "Map"
        return false
    if !QbarQueryContextCurrent(registryGeneration, queryId,
        QbarResultSnapshot["querySeq"], sessionId)
        return false
    if QbarResultSnapshot["sessionId"] != sessionId
        || QbarResultSnapshot["queryId"] != queryId
        || QbarResultSnapshot["registryGeneration"] != registryGeneration
        return false
    snapshot := QbarResultSnapshot
    return true
}

QbarConfigIndex() {
    global QbarConfigIndexCache, QbarConfigIndexGeneration
    if IsObject(QbarConfigIndexCache)
        && QbarConfigIndexCache["generation"] = QbarConfigIndexGeneration
        return QbarConfigIndexCache

    items := []
    sections := Map()
    byShort := Map()

    ; Discoverability rows come from the plugin registry. The fallback values
    ; are only used when the database could not be opened during startup.
    for fallback in [
        Map("commandId", "builtin.ai.ask", "pluginId", "builtin.ai", "short", "q",
            "label", "AI 问答", "type", "search", "usageKey", "builtin:ai",
            "aliases", ["q", "ai"]),
        Map("commandId", "builtin.everything.search", "pluginId", "builtin.everything", "short", "e",
            "label", "文件搜索", "type", "everything", "usageKey", "builtin:everything",
            "aliases", ["e", "everything", "find", "f"]),
        Map("commandId", "builtin.notes.search", "pluginId", "builtin.notes", "short", "n",
            "label", "笔记", "type", "notes", "usageKey", "builtin:notes",
            "aliases", ["n", "note", "w", "write"]),
        Map("commandId", "builtin.clipboard.open", "pluginId", "builtin.clipboard", "short", "cv",
            "label", "剪贴板历史", "type", "clipboard", "usageKey", "builtin:clipboard",
            "aliases", ["cv"]),
        Map("commandId", "builtin.settings.open", "pluginId", "builtin.settings", "short", "cl set",
            "label", "设置", "type", "settings", "usageKey", "builtin:settings",
            "aliases", ["cl set", "cl settings"])
    ] {
        registered := QbarRegistryBuiltinItem(fallback["commandId"], fallback)
        if IsObject(registered)
            items.Push(registered)
    }

    registryItems := QbarRegistryUserItems()
    for entry in registryItems
        items.Push(entry)
    DebugLog("Qbar config index built registryItems=" . registryItems.Length
        . " totalItems=" . items.Length)

    QbarConfigIndexCache := Map(
        "items", items,
        "sections", sections,
        "byShort", byShort,
        "generation", QbarConfigIndexGeneration)
    return QbarConfigIndexCache
}

QbarConfigItems() {
    return QbarConfigIndex()["items"]
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
                    "usageKey", "shortcut:" . StrLower(A_LoopFileFullPath),
                    "icon", IconKeyForPath(A_LoopFileFullPath),
                    "exe", target
                ))
            }
        } catch as scanError {
            DebugLog("Start menu scan failed")
        }
    }
    DebugLog("Start menu items=" . items.Length)
    QbarStartMenuCache := items
    return items
}

; ---------------------------------------------------------------------------
; Query / filtering
; ---------------------------------------------------------------------------

QbarQuery(text, querySeq := 0, pageQueryId := 0) {
    global QbarVisible, QbarIndexReady, QbarQuerySeq, QbarCurrentQueryText
    if !QbarVisible || !QbarIndexReady
        return
    if querySeq && querySeq != QbarQuerySeq {
        DebugLog("Qbar query stale")
        DebugLogPrivate("Qbar stale query", text)
        return
    }
    text := Trim(text, " `t")
    QbarCurrentQueryText := text
    DebugLog("Qbar query apply")
    DebugLogPrivate("Qbar applied query", text)
    if text = "" {
        QbarSendResults(QbarHistoryRows(), false, "", "history", pageQueryId, querySeq, text)
        return
    }
    resolution := QbarRegistryResolve(text)
    if resolution["candidates"].Length {
        QbarSendResults(QbarRegistryResolutionRows(resolution), false, "", "normal",
            pageQueryId, querySeq, text)
        return
    }
    if QbarIsFolderQuery(text) {
        items := QbarFilterFolder(text)
        ; An empty folder still shows one row, like the reference does.
        placeholder := (items.Length = 0 && QbarLeafOf(text) = "")
            ? QbarText("(empty folder)", "（空文件夹）")
            : ""
        QbarSendResults(items, true, placeholder, "normal", pageQueryId, querySeq, text)
        return
    }
    results := QbarFilterItems(text)
    QbarSendResults(results, false, "", "normal", pageQueryId, querySeq, text)
}

QbarRegistryResolutionRows(resolution) {
    rows := []
    for candidate in resolution["candidates"] {
        rowType := candidate["kind"] = "search" ? "search"
            : candidate["handlerId"] = "builtin.everything.search" ? "everything"
            : candidate["handlerId"] = "builtin.notes.search" ? "notes"
            : candidate["handlerId"] = "builtin.clipboard.open" ? "clipboard"
            : candidate["handlerId"] = "builtin.settings.open" ? "settings"
            : candidate["kind"] = "run" ? "file" : "app"
        label := candidate["displayName"]
        row := Map(
            "short", candidate["matchedAlias"],
            "label", label,
            "type", rowType,
            "pinned", true,
            "matchRank", 0,
            "usageScore", candidate["usageScore"],
            "usageLastUsedUtc", candidate["usageLastUsedAt"],
            "commandId", candidate["commandId"],
            "pluginId", candidate["pluginId"],
            "args", resolution["args"],
            "aliases", [candidate["matchedAlias"]])
        if rowType = "file" {
            command := QbarRegistryCommand(candidate["commandId"])
            iconKey := QbarRegistryCommandIconKey(command)
            if iconKey != ""
                row["icon"] := iconKey
        }
        rows.Push(row)
    }
    return rows
}

; A configured trigger always wins over path browsing, matching the reference
; implementation's check before it switches into folder-browse mode.

QbarIsFolderQuery(text) {
    QbarSplitCommand(text, &firstToken, &rest)
    if QbarConfigShortKeyExists(text) || QbarConfigShortKeyExists(firstToken)
        return false
    return QbarFolderOf(text) != ""
}

QbarFilterItems(text) {
    QbarSplitCommand(text, &matchStrLeft, &rest)
    glob := QbarGlobToRegEx(text)
    results := []
    for entry in QbarSearchCurrentEntries() {
        item := entry["item"]
        if item.Has("dynamicBlocked") && item["dynamicBlocked"]
            continue
        short := item["short"]
        matchRank := 60
        if !QbarSearchMatchItem(item, text, matchStrLeft, glob, &matchRank)
            continue
        usageScore := 0
        usageLastUsedUtc := ""
        if item.Has("usageKey") {
            usage := QbarUsageInfo(item["usageKey"])
            usageScore := usage["score"]
            usageLastUsedUtc := usage["lastUsedUtc"]
        }
        ; An exact trigger match floats to the top (reference: column 3 pinning).
        pinned := short = matchStrLeft
        results.Push(Map(
            "short", short,
            "label", item["label"],
            "type", item["type"],
            "pinned", pinned,
            "icon", item.Has("icon") ? item["icon"] : "",
            "matchRank", matchRank,
            "usageScore", usageScore,
            "usageLastUsedUtc", usageLastUsedUtc,
            "searchOrder", entry["order"],
            "commandId", item.Has("commandId") ? item["commandId"] : "",
            "pluginId", item.Has("pluginId") ? item["pluginId"] : "",
            "value", item.Has("value") ? item["value"] : "",
            "exe", item.Has("exe") ? item["exe"] : "",
            "candidateKey", item.Has("candidateKey") ? item["candidateKey"] : "",
            "dynamicBlocked", item.Has("dynamicBlocked") && item["dynamicBlocked"]
        ))
    }
    return results
}

QbarRegistryBuiltinItem(commandId, fallback) {
    command := QbarRegistryCommand(commandId)
    if !IsObject(command)
        return fallback
    if !command["enabled"]
        return 0
    aliases := []
    for alias in command["aliases"]
        aliases.Push(alias)
    if !aliases.Length
        return 0
    short := aliases[1]
    rowType := commandId = "builtin.everything.search" ? "everything"
        : commandId = "builtin.notes.search" ? "notes"
        : commandId = "builtin.clipboard.open" ? "clipboard"
        : commandId = "builtin.settings.open" ? "settings" : "search"
    label := command["displayName"]
    return Map(
        "short", short,
        "label", label,
        "type", rowType,
        "value", "",
        "usageKey", command["usageKey"],
        "commandId", command["commandId"],
        "pluginId", command["pluginId"],
        "aliases", aliases)
}

QbarFilterFolder(text) {
    provider := QbarRegistryDynamicProviderByHandler("builtin.open-path")
    if QbarRegistryDynamicProviderUnavailable("builtin.open-path")
        return []
    dir := QbarFolderOf(text)
    leaf := QbarLeafOf(text)
    items := QbarFolderItemsFor(dir)
    if leaf = "" {
        results := items
    } else {
        glob := QbarGlobToRegEx(leaf)
        results := []
        for item in items {
            if RegExMatch(item["label"], glob)
                results.Push(item)
        }
    }
    attached := []
    for item in results
        attached.Push(QbarIndexAttachDynamicProvider(item, provider, "builtin.open-path"))
    return attached
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
        DebugLog("Folder listing failed")
        DebugLogPrivate("Folder listing path", dir)
    }
    QbarFolderDir := dir
    QbarFolderItems := items
    return items
}

QbarSendResults(results, folderMode, placeholder := "", mode := "normal", pageQueryId := 0,
    querySeq := 0, queryText := "") {
    global IconSent, QbarHost, QbarVisible, QbarPageQueryId, QbarQuerySeq
    global QbarSessionId, QbarCurrentQueryText, QbarResultSnapshot
    if pageQueryId = 0
        pageQueryId := QbarPageQueryId
    if querySeq = 0
        querySeq := QbarQuerySeq
    if !QbarVisible || !PanelHostPageReady(QbarHost)
        return
    if pageQueryId != QbarPageQueryId || querySeq != QbarQuerySeq || QbarSessionId = ""
        return
    if queryText = ""
        queryText := QbarCurrentQueryText
    registryGeneration := QbarRegistryGeneration()
    DebugLog("Qbar results mode=" . mode . " count=" . results.Length)
    QbarCancelIconQueue()
    if mode = "history"
        QbarHistorySetDisplayed(querySeq, pageQueryId, results)
    else
        QbarHistoryClearDisplayed()
    rows := []
    candidates := Map()
    iconKeys := Map()
    for item in results {
        candidateId := QbarSessionId . ":" . pageQueryId . ":" . (rows.Length + 1)
        row := Map("short", item["short"], "label", item["label"], "type", item["type"],
            "pinned", item.Has("pinned") && item["pinned"] ? JSON.true : JSON.false,
            "sessionId", QbarSessionId,
            "candidateId", candidateId,
            "registryGeneration", registryGeneration)
        candidates[candidateId] := QbarSnapshotCandidate(item, queryText)
        if item.Has("commandId") && IsObject(QbarRegistryCommand(item["commandId"]))
            row["commandId"] := item["commandId"]
        if item.Has("pluginId")
            row["pluginId"] := item["pluginId"]
        if item.Has("candidateKey")
            row["candidateKey"] := item["candidateKey"]
        if item.Has("matchRank")
            row["matchRank"] := item["matchRank"]
        if item.Has("searchOrder")
            row["searchOrder"] := item["searchOrder"]
        if item.Has("usageScore")
            row["usageScore"] := item["usageScore"]
        if item.Has("usageLastUsedUtc")
            row["usageLastUsedUtc"] := item["usageLastUsedUtc"]
        if item.Has("historyId")
            row["historyId"] := item["historyId"]
        if item.Has("history")
            row["history"] := item["history"]
        if item.Has("replayable")
            row["replayable"] := item["replayable"] ? JSON.true : JSON.false
        iconKey := item.Has("icon") ? item["icon"] : ""
        if iconKey != "" {
            row["icon"] := iconKey
            if !IconSent.Has(iconKey)
                iconKeys[iconKey] := true
        }
        rows.Push(row)
    }
    QbarResultSnapshot := Map(
        "sessionId", QbarSessionId,
        "queryId", pageQueryId,
        "querySeq", querySeq,
        "query", queryText,
        "registryGeneration", registryGeneration,
        "candidates", candidates)
    ; Publish rows before doing any shell icon extraction. Missing icons use
    ; the page glyph temporarily and arrive in small timer-driven batches.
    QbarExec("window.setResults(" . JSON.stringify(rows, 0) . "," . (folderMode ? "true" : "false")
        . "," . LLMJsonQuote(placeholder) . "," . LLMJsonQuote(mode) . "," . pageQueryId
        . "," . LLMJsonQuote(QbarSessionId) . "," . registryGeneration . ");")
    if iconKeys.Count
        QbarQueueIcons(iconKeys)
}

QbarSnapshotCandidate(item, queryText) {
    candidate := Map(
        "short", String(item["short"]),
        "label", String(item["label"]),
        "type", String(item["type"]))
    for key in ["value", "exe", "candidateKey", "historyId"]
        if item.Has(key)
            candidate[key] := String(item[key])

    commandId := item.Has("commandId") ? String(item["commandId"]) : ""
    if commandId != "" {
        command := QbarRegistryCommand(commandId)
        if IsObject(command) && command["enabled"] {
            candidate["commandId"] := commandId
            args := item.Has("args") ? String(item["args"]) : ""
            if !item.Has("args") {
                resolution := QbarRegistryResolve(queryText)
                for resolved in resolution["candidates"]
                    if resolved["commandId"] = commandId {
                        args := resolution["args"]
                        break
                    }
                if args = ""
                    args := QbarRegisteredCommandDisplayArguments(command, queryText)
            }
            candidate["args"] := args
        } else if !IsObject(command) {
            staticAction := QbarStaticFallbackAction(commandId)
            if staticAction != "" {
                candidate["staticAction"] := staticAction
                candidate["args"] := QbarStaticCandidateArguments(item, queryText)
            }
        }
    }
    return candidate
}

QbarStaticFallbackAction(commandId) {
    static actions := Map(
        "builtin.ai.ask", "ai",
        "builtin.everything.search", "everything",
        "builtin.notes.search", "notes",
        "builtin.clipboard.open", "clipboard",
        "builtin.settings.open", "settings")
    return actions.Has(commandId) ? actions[commandId] : ""
}

QbarStaticCandidateArguments(item, queryText) {
    aliases := item.Has("aliases") && Type(item["aliases"]) = "Array"
        ? item["aliases"] : [item["short"]]
    lower := StrLower(Trim(queryText, " `t"))
    bestAlias := ""
    for alias in aliases {
        alias := Trim(String(alias), " `t")
        length := StrLen(alias)
        if length = 0 || StrLen(lower) < length
            continue
        if SubStr(lower, 1, length) != StrLower(alias)
            continue
        if StrLen(lower) > length && SubStr(lower, length + 1, 1) != " "
            continue
        if length > StrLen(bestAlias)
            bestAlias := alias
    }
    return bestAlias = "" ? "" : Trim(SubStr(queryText, StrLen(bestAlias) + 1), " `t")
}

QbarCancelIconQueue() {
    global QbarIconQueue, QbarIconQueued, QbarIconTimer
    SetTimer(QbarFlushIconQueue, 0)
    QbarIconQueue := []
    QbarIconQueued := Map()
    QbarIconTimer := false
}

QbarQueueIcons(keys) {
    global QbarIconQueue, QbarIconQueued, QbarIconTimer, IconSent
    for key, pending in keys {
        if !pending || key = "" || IconSent.Has(key) || QbarIconQueued.Has(key)
            continue
        QbarIconQueued[key] := true
        QbarIconQueue.Push(key)
    }
    if QbarIconQueue.Length && !QbarIconTimer {
        QbarIconTimer := true
        SetTimer(QbarFlushIconQueue, -1)
    }
}

QbarFlushIconQueue(*) {
    global QbarIconQueue, QbarIconQueued, QbarIconTimer, IconSent
    icons := Map()
    extracted := 0
    while QbarIconQueue.Length && extracted < 8 {
        key := QbarIconQueue.RemoveAt(1)
        if QbarIconQueued.Has(key)
            QbarIconQueued.Delete(key)
        if IconSent.Has(key)
            continue
        extracted += 1
        uri := IconDataURI(key)
        if uri != "" {
            IconSent[key] := true
            icons[key] := uri
        }
    }
    if icons.Count
        QbarExec("window.addIcons(" . JSON.stringify(icons, 0) . ");")
    if QbarIconQueue.Length
        SetTimer(QbarFlushIconQueue, -1)
    else
        QbarIconTimer := false
}

; ---------------------------------------------------------------------------
; Execution (the core of the reference ButtonSubmit label)
; ---------------------------------------------------------------------------

QbarConfigShortKeyExists(token) {
    return QbarRegistryHasAlias(token)
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
