; Qbar recent execution history and decayed command usage.
;
; History and usage are persisted by qbar_store.ahk. This module keeps the
; existing in-memory/page-facing shape while command_history is the only
; persistent source.

global QbarHistoryLoaded := false
global QbarHistoryLoading := false
global QbarHistoryItems := []
global QbarHistoryNextId := 1
global QbarHistoryLimit := 10
global QbarHistoryDisplayLimit := 10
global QbarHistoryDisplayedSeq := 0
global QbarHistoryDisplayedPageId := 0
global QbarHistoryDisplayedIds := Map()
global QbarUsageItems := Map()
global QbarUsageHalfLifeSeconds := 604800 ; seven days

QbarHistoryEnsureLoaded() {
    global QbarHistoryLoaded, QbarHistoryLoading, QbarHistoryItems, QbarUsageItems
    global QbarStoreError, QbarHistoryLimit
    if QbarHistoryLoaded
        return true
    if QbarHistoryLoading
        return false

    QbarHistoryLoading := true
    try {
        if !QbarStoreReady && !QbarStoreInit()
            return false
        if !QbarStoreDeduplicateRunHistory()
            DebugLog("Qbar run history deduplication failed")

        historyRows := []
        if !QbarStoreLoadHistoryRows(&historyRows, QbarHistoryLimit) {
            DebugLog("Qbar history rows could not be loaded: " . QbarStoreError)
            return false
        }
        usageRows := []
        if !QbarStoreLoadUsageRows(&usageRows) {
            DebugLog("Qbar usage rows could not be loaded: " . QbarStoreError)
            return false
        }

        candidateHistory := []
        seenHistory := Map()
        for row in historyRows {
            try {
                entry := QbarHistoryEntryFromStore(row)
                if !IsObject(entry)
                    continue
                identity := QbarHistoryIdentity(entry)
                if identity = "" {
                    DebugLog("Qbar history row rejected: invalid payload")
                    continue
                }
                if seenHistory.Has(identity)
                    continue
                seenHistory[identity] := true
                candidateHistory.Push(entry)
            } catch as loadError {
                DebugLog("Qbar history row rejected errorType=" . Type(loadError))
            }
        }

        candidateUsage := Map()
        for row in usageRows {
            if row.Has("usage_key")
                candidateUsage[row["usage_key"]] := Map(
                    "score", QbarStoreFloat(row["score"], 0),
                    "lastUsedUtc", QbarHistoryStoreTime(row["last_used_at"]),
                    "useCount", QbarStoreInteger(row["use_count"], 0))
        }

        QbarHistoryItems := candidateHistory
        QbarUsageItems := candidateUsage
        if !QbarHistoryItems.Length
            QbarHistorySeedInitialSettings()
        QbarHistoryLoaded := true
        return true
    } finally {
        QbarHistoryLoading := false
    }
}

QbarHistorySeedInitialSettings() {
    global QbarHistoryItems
    command := QbarRegistryCommand("builtin.settings.open")
    if !IsObject(command) || !command["enabled"]
        return false

    input := command["aliases"].Length ? command["aliases"][1] : command["displayName"]
    now := QbarStoreNow()
    entry := Map(
        "id", QbarHistoryNewId(),
        "kind", "settings",
        "commandId", command["commandId"],
        "pluginId", command["pluginId"],
        "candidateKey", "",
        "label", command["displayName"],
        "input", input,
        "args", Map(),
        "payload", Map("page", "general"),
        "replayable", true,
        "createdAt", now,
        "lastUsedUtc", QbarHistoryStoreTime(now))
    if !QbarStoreSaveHistoryEntry(entry, command)
        return false
    QbarHistoryItems.Push(entry)
    return true
}

QbarHistoryEntryFromStore(row) {
    if !IsObject(row) || !row.Has("id") || row["id"] = ""
        return 0
    payload := row.Has("payload_json") ? QbarRegistryJsonMap(row["payload_json"]) : Map()
    args := row.Has("args_json") ? QbarRegistryJsonMap(row["args_json"]) : Map()
    kind := QbarHistoryKindForHandler(
        row.Has("handler_id") ? row["handler_id"] : "", payload)
    return Map(
        "id", row["id"],
        "kind", kind,
        "commandId", row.Has("command_id") ? row["command_id"] : "",
        "pluginId", row.Has("plugin_id") ? row["plugin_id"] : "",
        "candidateKey", row.Has("candidate_key") ? row["candidate_key"] : "",
        "label", row.Has("command_title") ? row["command_title"] : "",
        "input", row.Has("input_text") ? row["input_text"] : "",
        "args", args,
        "payload", payload,
        "replayable", row.Has("replayable") && row["replayable"] = "1",
        "createdAt", row.Has("created_at") ? row["created_at"] : "",
        "lastUsedUtc", QbarHistoryStoreTime(row.Has("last_used_at") ? row["last_used_at"] : ""))
}

QbarHistoryKindForHandler(handlerId, payload := 0) {
    switch handlerId {
        case "builtin.ai.ask":
            return "ai"
        case "builtin.everything.search":
            return "everything"
        case "builtin.notes.search":
            return "notes"
        case "builtin.clipboard.open":
            return "clipboard"
        case "builtin.settings.open":
            return "settings"
        case "builtin.search", "builtin.open-url":
            return "url"
        case "builtin.run":
            return "run"
        case "builtin.open-path":
            return Type(payload) = "Map" && payload.Has("action")
                && Type(payload["action"]) = "String" && payload["action"] = "reveal"
                ? "reveal" : "path"
        case "builtin.start-menu.open":
            return "shortcut"
        default:
            return "history"
    }
}

QbarHistoryStoreTime(value) {
    value := String(value)
    if RegExMatch(value, "^\d{14}$")
        return value
    return value = "" ? "" : StrReplace(StrReplace(StrReplace(StrReplace(value, "-", ""), "T", ""), ":", ""), "Z", "")
}

QbarHistoryNewId() {
    global QbarHistoryNextId
    id := "qbar-history-" . A_TickCount . "-" . QbarHistoryNextId
    QbarHistoryNextId += 1
    return id
}

QbarHistoryNew(kind, label, input, payload, commandId := "") {
    return Map(
        "kind", String(kind),
        "label", String(label),
        "input", String(input),
        "payload", payload,
        "commandId", String(commandId),
        "pluginId", "",
        "candidateKey", "",
        "replayable", true,
        "createdAt", QbarStoreNow(),
        "lastUsedUtc", "")
}

QbarHistoryRemember(entry) {
    global QbarHistoryItems, QbarHistoryLimit
    if !QbarHistoryEnsureLoaded()
        return false
    normalized := QbarHistoryNormalizeEntry(entry)
    if !IsObject(normalized)
        return false

    identity := QbarHistoryIdentity(normalized)
    if identity = ""
        return false

    oldId := ""
    oldTitle := ""
    foundIndex := 0
    for index, existing in QbarHistoryItems {
        if QbarHistoryIdentity(existing) = identity {
            foundIndex := index
            oldId := existing["id"]
            oldTitle := existing.Has("label") ? String(existing["label"]) : ""
            break
        }
    }
    if foundIndex
        QbarHistoryItems.RemoveAt(foundIndex)

    normalized["id"] := oldId != "" ? oldId : QbarHistoryNewId()
    normalized["lastUsedUtc"] := FormatTime(A_NowUTC, "yyyyMMddHHmmss")
    QbarUsageRemember(normalized)
    QbarHistoryItems.InsertAt(1, normalized)
    while QbarHistoryItems.Length > QbarHistoryLimit
        QbarHistoryItems.Pop()
    command := QbarHistoryResolveCommand(normalized)
    if IsObject(command) {
        normalized["commandId"] := command["commandId"]
        normalized["pluginId"] := command["pluginId"]
        normalized["label"] := oldTitle != "" ? oldTitle : command["displayName"]
        if command["pluginRetired"] || command["commandRetired"]
            normalized["replayable"] := false
        QbarStoreSaveHistoryEntry(normalized, command)
    }
    return true
}

QbarUsageRemember(entry) {
    global QbarUsageItems
    key := QbarHistoryUsageKey(entry)
    if key = ""
        return false
    command := QbarHistoryResolveCommand(entry)
    if !IsObject(command)
        return false
    current := QbarUsageInfo(key)
    QbarStoreRememberUsage(key, command["commandId"], entry.Has("candidateKey") ? entry["candidateKey"] : "")
    QbarRegistryRememberUsage(key)
    QbarUsageItems[key] := Map(
        "score", current["score"] + 1,
        "lastUsedUtc", FormatTime(A_NowUTC, "yyyyMMddHHmmss"),
        "useCount", current.Has("useCount") ? current["useCount"] + 1 : 1)
    return true
}

QbarHistoryResolveCommand(entry) {
    if Type(entry) != "Map"
        return 0
    commandId := entry.Has("commandId") && Type(entry["commandId"]) = "String"
        ? entry["commandId"] : ""
    if commandId = ""
        commandId := QbarHistoryDefaultCommandId(entry.Has("kind") ? entry["kind"] : "")
    if commandId = ""
        return 0
    command := QbarRegistryCommand(commandId)
    if !IsObject(command)
        return 0
    if entry.Has("pluginId") && entry["pluginId"] != ""
        && entry["pluginId"] != command["pluginId"]
        return 0
    return command
}

QbarHistoryDefaultCommandId(kind) {
    switch kind {
        case "ai":
            return "builtin.ai.ask"
        case "everything":
            return "builtin.everything.search"
        case "notes":
            return "builtin.notes.search"
        case "clipboard":
            return "builtin.clipboard.open"
        case "settings":
            return "builtin.settings.open"
        case "url":
            return "builtin.url.open"
        case "path", "reveal":
            return "builtin.path.open"
        case "shortcut":
            return "builtin.start-menu.open"
        default:
            return ""
    }
}

; Return the score after applying the seven-day half-life, plus the raw last
; execution time for deterministic tie-breaking in the page sort.
QbarUsageInfo(key) {
    global QbarUsageItems, QbarUsageHalfLifeSeconds
    info := Map("score", 0, "lastUsedUtc", "")
    if !QbarHistoryEnsureLoaded()
        return info
    if key = "" || !QbarUsageItems.Has(key)
        return info

    usage := QbarUsageItems[key]
    if Type(usage) != "Map" || !usage.Has("score") || !usage.Has("lastUsedUtc")
        return info
    valid := false
    score := QbarUsageReadScore(usage["score"], &valid)
    lastUsedUtc := usage["lastUsedUtc"]
    if !valid || Type(lastUsedUtc) != "String"
        return info
    if !RegExMatch(lastUsedUtc, "^\d{14}$")
        return info

    elapsed := 0
    try elapsed := DateDiff(A_NowUTC, lastUsedUtc, "Seconds")
    catch
        return info
    if elapsed > 0
        score *= 2 ** (0 - elapsed / QbarUsageHalfLifeSeconds)
    info["score"] := score
    info["lastUsedUtc"] := lastUsedUtc
    return info
}

QbarUsageReadScore(value, &valid := false) {
    valid := false
    valueType := Type(value)
    if valueType != "Integer" && valueType != "Float"
        return 0
    score := value + 0
    if score <= 0
        return 0
    valid := true
    return score
}

QbarHistoryUsageKey(entry) {
    command := QbarHistoryResolveCommand(entry)
    if IsObject(command) {
        usageKey := command["usageKey"]
        candidateKey := entry.Has("candidateKey") ? String(entry["candidateKey"]) : ""
        return candidateKey = "" ? usageKey : usageKey . ":" . candidateKey
    }
    return ""
}

QbarHistoryRows(limit := 10) {
    global QbarHistoryItems, QbarHistoryDisplayLimit
    rows := []
    if !QbarHistoryEnsureLoaded()
        return rows
    limit := Max(0, Min(QbarHistoryDisplayLimit, Integer(limit)))
    if limit = 0
        return rows
    for entry in QbarHistoryItems {
        if entry["input"] = "" || entry["label"] = ""
            continue
        kind := entry["kind"]
        payload := entry["payload"]
        icon := ""
        if kind = "shortcut" && payload.Has("shortcutPath")
            icon := IconKeyForPath(payload["shortcutPath"])
        else if (kind = "path" || kind = "reveal") && payload.Has("path")
            icon := IconKeyForPath(payload["path"])
        else if kind = "run"
            icon := QbarRegistryCommandIconKey(QbarHistoryResolveCommand(entry))
        row := Map(
            "historyId", entry["id"],
            "short", entry["input"],
            "label", QbarHistoryDisplayLabel(entry),
            "type", QbarHistoryRowType(kind),
            "replayable", QbarHistoryCanReplayEntry(entry) ? JSON.true : JSON.false)
        if icon != ""
            row["icon"] := icon
        rows.Push(row)
        if rows.Length >= limit
            break
    }
    return rows
}

QbarHistoryDisplayLabel(entry) {
    kind := entry["kind"]
    command := QbarHistoryResolveCommand(entry)
    toolName := entry.Has("label") ? Trim(String(entry["label"])) : ""
    if toolName = "" && IsObject(command)
        toolName := command["displayName"]
    if toolName = "" {
        toolName := kind = "ai" ? "AI 问答"
            : kind = "everything" ? "文件搜索"
            : kind = "notes" ? "笔记"
            : kind = "clipboard" ? "剪贴板历史"
            : kind = "settings" ? "设置"
            : kind = "url" ? "打开网址"
            : kind = "run" ? "快捷命令"
            : kind = "shortcut" ? "开始菜单"
            : kind = "path" || kind = "reveal" ? "打开路径" : "历史记录"
    }
    content := QbarHistoryDisplayContent(entry, command)
    return content = "" ? toolName : toolName . " " . content
}

QbarHistoryDisplayContent(entry, command := 0) {
    kind := entry["kind"]
    payload := entry["payload"]
    if kind = "ai"
        return payload.Has("question") ? Trim(String(payload["question"])) : ""
    if kind = "everything"
        return payload.Has("query") ? Trim(String(payload["query"])) : ""
    if kind = "notes"
        return payload.Has("search") ? Trim(String(payload["search"])) : ""
    if kind = "clipboard"
        return payload.Has("search") ? Trim(String(payload["search"])) : ""
    if kind = "path" || kind = "reveal"
        return payload.Has("path") ? Trim(String(payload["path"])) : ""
    if kind = "shortcut"
        return entry.Has("input") ? Trim(String(entry["input"])) : ""
    content := QbarHistoryInputArguments(entry, command)
    if content = "" && kind = "url" && IsObject(payload) && payload.Has("url")
        if !IsObject(command) || command["handlerId"] = "builtin.open-url"
            content := Trim(String(payload["url"]))
    return content
}

QbarHistoryInputArguments(entry, command := 0) {
    input := entry.Has("input") ? Trim(String(entry["input"]), " `t") : ""
    if input = ""
        return ""
    commandId := IsObject(command) ? command["commandId"] : ""
    resolution := QbarRegistryResolve(input)
    if resolution["candidates"].Length {
        for candidate in resolution["candidates"]
            if commandId = "" || candidate["commandId"] = commandId
                return resolution["args"]
    }
    QbarSplitCommand(input, &firstToken, &rest)
    return rest
}

QbarHistoryRowType(kind) {
    switch kind {
        case "shortcut", "run":
            return "app"
        case "url":
            return "web"
        case "path", "reveal":
            return "file"
        case "ai":
            return "ai"
        case "everything":
            return "everything"
        case "notes":
            return "notes"
        case "clipboard":
            return "clipboard"
        case "settings":
            return "settings"
        default:
            return "history"
    }
}

QbarHistorySetDisplayed(querySeq, pageQueryId, rows) {
    global QbarHistoryDisplayedSeq, QbarHistoryDisplayedPageId, QbarHistoryDisplayedIds
    QbarHistoryDisplayedSeq := querySeq
    QbarHistoryDisplayedPageId := pageQueryId
    QbarHistoryDisplayedIds := Map()
    for row in rows {
        if row.Has("historyId")
            QbarHistoryDisplayedIds[row["historyId"]] := true
    }
}

QbarHistoryClearDisplayed() {
    global QbarHistoryDisplayedSeq, QbarHistoryDisplayedPageId, QbarHistoryDisplayedIds
    QbarHistoryDisplayedSeq := 0
    QbarHistoryDisplayedPageId := 0
    QbarHistoryDisplayedIds := Map()
}

QbarHistoryMarkPluginRetired(pluginId) {
    global QbarHistoryItems
    if Type(QbarHistoryItems) != "Array"
        return
    for entry in QbarHistoryItems
        if Type(entry) = "Map" && entry.Has("pluginId")
            && entry["pluginId"] = pluginId
            entry["replayable"] := false
}

QbarHistoryCanReplay(historyId, querySeq, pageQueryId) {
    global QbarVisible, QbarHistoryDisplayedSeq, QbarHistoryDisplayedPageId
    global QbarHistoryDisplayedIds, QbarQuerySeq, QbarPageQueryId
    if !QbarVisible || historyId = "" || pageQueryId <= 0
        return false
    if querySeq != QbarQuerySeq || pageQueryId != QbarPageQueryId
        return false
    if querySeq != QbarHistoryDisplayedSeq || pageQueryId != QbarHistoryDisplayedPageId
        return false
    return QbarHistoryDisplayedIds.Has(historyId)
}

QbarHistoryCanReplayEntry(entry) {
    command := 0
    runArgs := ""
    return QbarHistoryAuthorizeReplay(entry, &command, &runArgs)
}

QbarHistoryAuthorizeReplay(entry, &command := 0, &runArgs := "") {
    command := 0
    runArgs := ""
    value := ""
    exe := ""
    commandLine := ""
    runQuery := false
    replayable := false
    if Type(entry) != "Map" || !entry.Has("replayable")
        return false
    if !QbarHistoryReadBoolean(entry["replayable"], &replayable) || !replayable
        return false
    if !entry.Has("commandId") || Type(entry["commandId"]) != "String"
        || entry["commandId"] = ""
        || !entry.Has("pluginId") || Type(entry["pluginId"]) != "String"
        || entry["pluginId"] = ""
        || !entry.Has("kind") || Type(entry["kind"]) != "String"
        || !entry.Has("payload") || Type(entry["payload"]) != "Map"
        return false
    if !QbarHistoryEntryPayloadValid(entry)
        return false

    command := QbarRegistryCommand(entry["commandId"])
    if !IsObject(command) || command["pluginId"] != entry["pluginId"]
        || !command["enabled"] || !command["pluginEnabled"] || !command["commandEnabled"]
        || command["pluginRetired"] || command["commandRetired"]
        || !QbarPluginHostHandlerAllowed(command["handlerId"])
        return false

    kind := entry["kind"]
    handlerId := command["handlerId"]
    if kind = "reveal" {
        if handlerId != "builtin.open-path"
            return false
    } else if QbarHistoryKindForHandler(handlerId) != kind
        return false

    payload := entry["payload"]
    switch kind {
        case "run":
            if handlerId != "builtin.run"
                return false
            if !QbarHistoryPayloadString(payload, "command", &commandLine) || commandLine = ""
                return false
            if !entry.Has("args") || Type(entry["args"]) != "Map"
                || !entry["args"].Has("args")
                || Type(entry["args"]["args"]) != "String"
                return false
            runArgs := entry["args"]["args"]
        case "shortcut":
            if !QbarHistoryPayloadString(payload, "shortcutPath", &value) || value = ""
                || !QbarHistoryPayloadString(payload, "exe", &exe)
                return false
        case "url":
            if !QbarHistoryPayloadString(payload, "url", &value)
                || !RegExMatch(value, "i)^(https?|ftp)://")
                return false
        case "path", "reveal":
            if !QbarHistoryPayloadString(payload, "path", &value) || value = ""
                return false
            if kind = "reveal" && (!payload.Has("action")
                || Type(payload["action"]) != "String" || payload["action"] != "reveal")
                return false
            if kind = "path" && payload.Has("action")
                && (Type(payload["action"]) != "String" || payload["action"] != "open")
                return false
        case "ai":
            if !QbarHistoryPayloadString(payload, "question", &value)
                return false
        case "everything":
            if !QbarHistoryPayloadString(payload, "query", &value)
                return false
            if !payload.Has("runQuery")
                return false
            if !QbarHistoryReadBoolean(payload["runQuery"], &runQuery)
                return false
        case "notes", "clipboard":
            if !QbarHistoryPayloadString(payload, "search", &value)
                return false
        case "settings":
            if !QbarHistoryPayloadString(payload, "page", &value)
                || !QbarHistorySettingsPageAllowed(value)
                return false
        default:
            return false
    }
    return true
}

QbarHistorySettingsPageAllowed(page) {
    static pages := Map("general", true, "mouse", true, "llm", true,
        "translate", true, "ai", true, "shortcuts", true, "tab", true,
        "qbar", true, "windows", true)
    return Type(page) = "String" && pages.Has(page)
}

QbarHistoryReplay(historyId, querySeq := 0, pageQueryId := 0) {
    global QbarHistoryItems
    if !QbarHistoryEnsureLoaded()
        return false
    if !QbarHistoryCanReplay(historyId, querySeq, pageQueryId)
        return false

    for entry in QbarHistoryItems {
        if entry["id"] != historyId
            continue
        command := 0
        runArgs := ""
        if !QbarHistoryAuthorizeReplay(entry, &command, &runArgs)
            return false
        outcome := QbarHistoryExecuteEntry(entry, command, runArgs)
        if outcome = "deferred"
            return true
        if outcome
            QbarHistoryRemember(entry)
        return outcome ? true : false
    }
    return false
}

QbarHistoryNormalizeEntry(entry) {
    if Type(entry) != "Map" || !entry.Has("kind") || !entry.Has("payload")
        return 0
    kind := entry["kind"]
    if Type(kind) != "String" || !QbarHistoryKnownKind(kind)
        return 0
    if Type(entry["payload"]) != "Map"
        return 0
    if !QbarHistoryEntryPayloadValid(entry)
        return 0
    if !entry.Has("replayable")
        return 0
    replayable := false
    if !QbarHistoryReadBoolean(entry["replayable"], &replayable)
        return 0
    label := entry.Has("label") && Type(entry["label"]) = "String" ? entry["label"] : ""
    input := entry.Has("input") && Type(entry["input"]) = "String" ? entry["input"] : ""
    if label = "" || input = ""
        return 0
    payload := entry["payload"]
    normalizedPayload := Map()
    value := ""
    exe := ""

    switch kind {
        case "run":
            if !QbarHistoryPayloadString(payload, "command", &value) || value = ""
                return 0
            normalizedPayload["command"] := value
        case "shortcut":
            if !QbarHistoryPayloadString(payload, "shortcutPath", &value) || value = ""
                return 0
            if !QbarHistoryPayloadString(payload, "exe", &exe)
                exe := ""
            normalizedPayload["shortcutPath"] := value
            normalizedPayload["exe"] := exe
        case "url":
            if !QbarHistoryPayloadString(payload, "url", &value) || value = ""
                return 0
            normalizedPayload["url"] := value
        case "path", "reveal":
            if !QbarHistoryPayloadString(payload, "path", &value) || value = ""
                return 0
            normalizedPayload["path"] := value
            if payload.Has("action")
                normalizedPayload["action"] := payload["action"]
        case "ai":
            if !QbarHistoryPayloadString(payload, "question", &value)
                value := ""
            normalizedPayload["question"] := value
        case "everything":
            if !QbarHistoryPayloadString(payload, "query", &value)
                value := ""
            if !payload.Has("runQuery")
                return 0
            runQuery := false
            if !QbarHistoryReadBoolean(payload["runQuery"], &runQuery)
                return 0
            normalizedPayload["query"] := value
            normalizedPayload["runQuery"] := runQuery
        case "notes":
            if !QbarHistoryPayloadString(payload, "search", &value)
                value := ""
            normalizedPayload["search"] := value
        case "clipboard":
            if !QbarHistoryPayloadString(payload, "search", &value)
                value := ""
            normalizedPayload["search"] := value
        case "settings":
            if !QbarHistoryPayloadString(payload, "page", &value) || value = ""
                value := "general"
            normalizedPayload["page"] := value
    }

    lastUsedUtc := entry.Has("lastUsedUtc") && Type(entry["lastUsedUtc"]) = "String"
        ? entry["lastUsedUtc"] : ""
    return Map(
        "id", entry.Has("id") ? String(entry["id"]) : "",
        "kind", kind,
        "commandId", entry.Has("commandId") ? String(entry["commandId"]) : "",
        "pluginId", entry.Has("pluginId") ? String(entry["pluginId"]) : "",
        "candidateKey", entry.Has("candidateKey") ? String(entry["candidateKey"]) : "",
        "label", label,
        "input", input,
        "args", entry.Has("args") && IsObject(entry["args"]) ? entry["args"] : Map(),
        "payload", normalizedPayload,
        "replayable", replayable,
        "createdAt", entry.Has("createdAt") ? String(entry["createdAt"]) : QbarStoreNow(),
        "lastUsedUtc", lastUsedUtc)
}

QbarHistoryPayloadString(payload, key, &value := "") {
    value := ""
    if Type(payload) != "Map" || !payload.Has(key) || Type(payload[key]) != "String"
        return false
    value := payload[key]
    return true
}

QbarHistoryKnownKind(kind) {
    switch kind {
        case "run", "shortcut", "url", "path", "reveal", "ai", "everything", "notes", "clipboard", "settings":
            return true
        default:
            return false
    }
}

QbarHistoryReadBoolean(value, &parsed := false) {
    parsed := false
    if Type(value) = "ComValue" {
        isTrue := false
        isFalse := false
        try isTrue := value == JSON.true
        catch
            isTrue := false
        try isFalse := value == JSON.false
        catch
            isFalse := false
        if isTrue
            parsed := true
        if isTrue || isFalse
            return true
        return false
    }
    if Type(value) = "Integer" {
        if value != 0 && value != 1
            return false
        parsed := value = 1
        return true
    }
    if Type(value) != "String"
        return false
    raw := StrLower(Trim(String(value)))
    if raw = "true" || raw = "1" {
        parsed := true
        return true
    }
    if raw = "false" || raw = "0" {
        parsed := false
        return true
    }
    return false
}

QbarHistoryEntryPayloadValid(entry) {
    if Type(entry) != "Map" || !entry.Has("kind") || Type(entry["kind"]) != "String"
        || !entry.Has("payload") || Type(entry["payload"]) != "Map"
        return false
    kind := entry["kind"]
    payload := entry["payload"]
    if !QbarHistoryKnownKind(kind)
        return false

    value := ""
    runQuery := false
    switch kind {
        case "run":
            if !QbarHistoryPayloadString(payload, "command", &value) || value = ""
                return false
            if entry.Has("args") {
                if Type(entry["args"]) != "Map"
                    return false
                if entry["args"].Has("args")
                    && Type(entry["args"]["args"]) != "String"
                    return false
            }
            return true
        case "shortcut":
            return QbarHistoryPayloadString(payload, "shortcutPath", &value)
                && value != "" && QbarHistoryPayloadString(payload, "exe", &value)
        case "url":
            return QbarHistoryPayloadString(payload, "url", &value)
                && RegExMatch(value, "i)^(https?|ftp)://")
        case "path", "reveal":
            if !QbarHistoryPayloadString(payload, "path", &value) || value = ""
                return false
            if kind = "reveal"
                return payload.Has("action") && Type(payload["action"]) = "String"
                    && payload["action"] = "reveal"
            return !payload.Has("action") || (Type(payload["action"]) = "String"
                && payload["action"] = "open")
        case "ai":
            return QbarHistoryPayloadString(payload, "question", &value)
        case "everything":
            if !QbarHistoryPayloadString(payload, "query", &value)
                return false
            return payload.Has("runQuery")
                && QbarHistoryReadBoolean(payload["runQuery"], &runQuery)
        case "notes", "clipboard":
            return QbarHistoryPayloadString(payload, "search", &value)
        case "settings":
            return QbarHistoryPayloadString(payload, "page", &value)
                && QbarHistorySettingsPageAllowed(value)
    }
    return false
}

QbarHistoryBoolValue(value) {
    parsed := false
    if !QbarHistoryReadBoolean(value, &parsed)
        return false
    return parsed
}

QbarHistoryIdentity(entry) {
    if !QbarHistoryEntryPayloadValid(entry)
        return ""
    kind := entry["kind"]
    payload := entry["payload"]
    switch kind {
        case "run":
            commandId := entry.Has("commandId") ? String(entry["commandId"]) : ""
            if commandId != "" {
                arguments := ""
                if entry.Has("args") && Type(entry["args"]) = "Map"
                    && entry["args"].Has("args")
                    arguments := String(entry["args"]["args"])
                else
                    arguments := QbarHistoryInputArguments(entry, QbarRegistryCommand(commandId))
                return kind . QbarHistoryIdentityPart(commandId)
                    . QbarHistoryIdentityPart(arguments)
            }
            return kind . QbarHistoryIdentityPart(payload["command"])
        case "shortcut":
            return kind . QbarHistoryIdentityPart(payload["shortcutPath"])
        case "url":
            return kind . QbarHistoryIdentityPart(payload["url"])
        case "path", "reveal":
            return kind . QbarHistoryIdentityPart(payload["path"])
        case "ai":
            return kind . QbarHistoryIdentityPart(payload["question"])
        case "everything":
            return kind . QbarHistoryIdentityPart(payload["query"]) . QbarHistoryIdentityPart(QbarHistoryBoolValue(payload["runQuery"]) ? "1" : "0")
        case "notes":
            return kind . QbarHistoryIdentityPart(payload["search"])
        case "clipboard":
            return kind . QbarHistoryIdentityPart(payload["search"])
        case "settings":
            return kind . QbarHistoryIdentityPart(payload["page"])
        default:
            return ""
    }
}

QbarHistoryIdentityPart(value) {
    value := String(value)
    return StrLen(value) . ":" . value
}
