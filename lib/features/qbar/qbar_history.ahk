; qbar recent execution history.
;
; The history is deliberately separate from capslock_p2.ini. It stores only
; successful, repeatable actions and keeps enough resolved data to replay an
; action even after the corresponding Qbar configuration entry changes.

global QbarHistoryLoaded := false
global QbarHistoryItems := []
global QbarHistoryNextId := 1
global QbarHistoryLimit := 10
global QbarHistoryDisplayLimit := 10
global QbarHistoryDisplayedSeq := 0
global QbarHistoryDisplayedPageId := 0
global QbarHistoryDisplayedIds := Map()

QbarHistoryFilePath() {
    return A_AppData . "\capslock_p2\qbar-history.json"
}

QbarHistoryDirectory() {
    return A_AppData . "\capslock_p2"
}

QbarHistoryEnsureLoaded() {
    global QbarHistoryLoaded, QbarHistoryItems
    if QbarHistoryLoaded
        return
    QbarHistoryLoaded := true
    QbarHistoryItems := []

    path := QbarHistoryFilePath()
    if !FileExist(path)
        return

    try raw := FileRead(path, "UTF-8")
    catch as readError {
        DebugLog("Qbar history read failed")
        return
    }
    try document := JSON.Parse(raw, false, true)
    catch as parseError {
        DebugLog("Qbar history parse failed")
        return
    }
    if Type(document) != "Map" || !document.Has("items") || Type(document["items"]) != "Array"
        return

    seen := Map()
    for stored in document["items"] {
        entry := QbarHistoryNormalizeEntry(stored)
        if !IsObject(entry)
            continue
        identity := QbarHistoryIdentity(entry)
        if identity = "" || seen.Has(identity)
            continue
        seen[identity] := true
        entry["id"] := QbarHistoryNewId()
        QbarHistoryItems.Push(entry)
        if QbarHistoryItems.Length >= QbarHistoryLimit
            break
    }
}

QbarHistoryNewId() {
    global QbarHistoryNextId
    id := "qbar-history-" . QbarHistoryNextId
    QbarHistoryNextId += 1
    return id
}

QbarHistoryNew(kind, label, input, payload) {
    return Map(
        "kind", String(kind),
        "label", String(label),
        "input", String(input),
        "payload", payload,
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
    QbarHistoryItems.InsertAt(1, normalized)
    while QbarHistoryItems.Length > QbarHistoryLimit
        QbarHistoryItems.Pop()
    QbarHistorySave()
    return true
}

QbarHistorySave() {
    global QbarHistoryItems
    serialized := []
    for entry in QbarHistoryItems
        serialized.Push(QbarHistorySerializeEntry(entry))
    document := Map("items", serialized)

    try {
        DirCreate(QbarHistoryDirectory())
        ConfigAtomicWrite(QbarHistoryFilePath(), JSON.stringify(document, 0))
    } catch as writeError {
        ; A history write failure must never turn a successful launch into a
        ; launch error. The in-memory list remains usable for this session.
        DebugLog("Qbar history write failed")
        return false
    }
    return true
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
        row := Map(
            "historyId", entry["id"],
            "short", entry["input"],
            "label", entry["label"],
            "type", QbarHistoryRowType(kind))
        if icon != ""
            row["icon"] := icon
        rows.Push(row)
        if rows.Length >= limit
            break
    }
    return rows
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
        outcome := QbarHistoryExecuteEntry(entry)
        if outcome = "deferred"
            return true
        if outcome
            QbarHistoryRemember(entry)
        return outcome ? true : false
    }
    return false
}

QbarHistorySerializeEntry(entry) {
    kind := entry["kind"]
    payload := entry["payload"]
    serializedPayload := Map()
    switch kind {
        case "run":
            serializedPayload["command"] := payload["command"]
        case "shortcut":
            serializedPayload["shortcutPath"] := payload["shortcutPath"]
            serializedPayload["exe"] := payload["exe"]
        case "url":
            serializedPayload["url"] := payload["url"]
        case "path", "reveal":
            serializedPayload["path"] := payload["path"]
        case "ai":
            serializedPayload["question"] := payload["question"]
        case "everything":
            serializedPayload["query"] := payload["query"]
            serializedPayload["runQuery"] := QbarHistoryBoolValue(payload["runQuery"]) ? JSON.true : JSON.false
        case "settings":
            serializedPayload["page"] := payload["page"]
    }
    return Map(
        "kind", kind,
        "label", entry["label"],
        "input", entry["input"],
        "payload", serializedPayload,
        "lastUsedUtc", entry["lastUsedUtc"])
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
        "label", label,
        "input", input,
        "payload", normalizedPayload,
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
        case "run", "shortcut", "url", "path", "reveal", "ai", "everything", "settings":
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
