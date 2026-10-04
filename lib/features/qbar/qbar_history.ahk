; Qbar recent execution history and decayed command usage.
;
; History and usage are persisted by qbar_store.ahk. This module keeps the
; existing in-memory/page-facing shape while command_history is the only
; persistent source.

global QbarHistoryLoaded := false
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
    global QbarHistoryLoaded, QbarHistoryItems, QbarUsageItems, QbarStoreError
    if QbarHistoryLoaded
        return
    QbarHistoryLoaded := true
    QbarHistoryItems := []
    QbarUsageItems := Map()
    if !QbarStoreReady && !QbarStoreInit()
        return
    if !QbarStoreDeduplicateRunHistory()
        DebugLog("Qbar run history deduplication failed")
    seenHistory := Map()
    historyRows := QbarStoreLoadHistoryRows(QbarHistoryLimit)
    for row in historyRows {
        entry := QbarHistoryEntryFromStore(row)
        if !IsObject(entry)
            continue
        identity := QbarHistoryIdentity(entry)
        if identity != "" && seenHistory.Has(identity)
            continue
        if identity != ""
            seenHistory[identity] := true
        QbarHistoryItems.Push(entry)
    }
    if !QbarHistoryItems.Length && QbarStoreError = ""
        QbarHistorySeedInitialSettings()
    for row in QbarStoreLoadUsageRows() {
        if row.Has("usage_key")
            QbarUsageItems[row["usage_key"]] := Map(
                "score", QbarStoreFloat(row["score"], 0),
                "lastUsedUtc", QbarHistoryStoreTime(row["last_used_at"]),
                "useCount", QbarStoreInteger(row["use_count"], 0))
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
    kind := QbarHistoryKindForHandler(row.Has("handler_id") ? row["handler_id"] : "")
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
        "replayable", !row.Has("replayable") || row["replayable"] != "0",
        "createdAt", row.Has("created_at") ? row["created_at"] : "",
        "lastUsedUtc", QbarHistoryStoreTime(row.Has("last_used_at") ? row["last_used_at"] : ""))
}

QbarHistoryKindForHandler(handlerId) {
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
            return "path"
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
        "createdAt", QbarStoreNow(),
        "lastUsedUtc", "")
}

QbarHistoryRemember(entry) {
    global QbarHistoryItems, QbarHistoryLimit
    QbarHistoryEnsureLoaded()
    normalized := QbarHistoryNormalizeEntry(entry)
    if !IsObject(normalized)
        return false

    identity := QbarHistoryIdentity(normalized)
    if identity = ""
        return false

    oldId := ""
    foundIndex := 0
    for index, existing in QbarHistoryItems {
        if QbarHistoryIdentity(existing) = identity {
            foundIndex := index
            oldId := existing["id"]
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
    if !IsObject(entry)
        return 0
    if entry.Has("commandId") && entry["commandId"] != "" {
        command := QbarRegistryCommand(entry["commandId"])
        if IsObject(command)
            return command
    }
    input := entry.Has("input") ? String(entry["input"]) : ""
    resolution := QbarRegistryResolve(input)
    if resolution["candidates"].Length
        return QbarRegistryCommand(resolution["candidates"][1]["commandId"])
    kind := entry.Has("kind") ? entry["kind"] : ""
    fallbackId := kind = "path" || kind = "reveal" ? "builtin.path.open"
        : kind = "url" ? "builtin.open-url"
        : kind = "shortcut" ? "builtin.start-menu.open" : ""
    return fallbackId = "" ? 0 : QbarRegistryCommand(fallbackId)
}

; Return the score after applying the seven-day half-life, plus the raw last
; execution time for deterministic tie-breaking in the page sort.
QbarUsageInfo(key) {
    global QbarUsageItems, QbarUsageHalfLifeSeconds
    QbarHistoryEnsureLoaded()
    info := Map("score", 0, "lastUsedUtc", "")
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
    if IsObject(command)
        return command["usageKey"]
    return ""
}

QbarHistoryRows(limit := 10) {
    global QbarHistoryItems, QbarHistoryDisplayLimit
    QbarHistoryEnsureLoaded()
    limit := Max(0, Min(QbarHistoryDisplayLimit, Integer(limit)))
    rows := []
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
            "type", QbarHistoryRowType(kind))
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
    toolName := ""
    if IsObject(command) {
        toolName := command["displayName"]
    }
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
        return entry.Has("label") ? Trim(String(entry["label"])) : ""
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

QbarHistoryReplay(historyId, querySeq := 0, pageQueryId := 0) {
    global QbarHistoryItems
    QbarHistoryEnsureLoaded()
    if !QbarHistoryCanReplay(historyId, querySeq, pageQueryId)
        return false

    for entry in QbarHistoryItems {
        if entry["id"] != historyId
            continue
        if entry.Has("replayable") && !entry["replayable"]
            return false
        outcome := QbarHistoryExecuteEntry(entry)
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
        case "ai":
            if !QbarHistoryPayloadString(payload, "question", &value)
                value := ""
            normalizedPayload["question"] := value
        case "everything":
            if !QbarHistoryPayloadString(payload, "query", &value)
                value := ""
            runQuery := payload.Has("runQuery") ? QbarHistoryBoolValue(payload["runQuery"]) : false
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

QbarHistoryBoolValue(value) {
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
            return true
        if isFalse
            return false
    }
    if Type(value) = "Integer"
        return value != 0
    raw := StrLower(Trim(String(value)))
    return raw = "true" || raw = "1"
}

QbarHistoryIdentity(entry) {
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
