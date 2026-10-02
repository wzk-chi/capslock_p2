; qbar derived search keys and the asynchronous page-side pinyin build.
;
; The page owns the pinyin conversion because the official pinyin-pro browser
; distribution is already a local WebView2 asset. AHK owns the resulting keys,
; matching and execution data so a search key can never become a command.

QbarSearchStartBuild() {
    global QbarHost, QbarVisible, QbarSearchState, QbarSearchGeneration
    global QbarSearchConfigGeneration, QbarSearchEntries, QbarSearchEntryById
    global QbarSearchKeys, QbarSearchExpectedCount, QbarSearchTimeoutTimer
    global QbarConfigIndexGeneration
    if !QbarVisible || !PanelHostPageReady(QbarHost)
        return false

    if QbarSearchState = "ready" && QbarSearchConfigGeneration = QbarConfigIndexGeneration {
        QbarFinishIndexLoad()
        return true
    }
    if QbarSearchState = "building"
        return true

    QbarSearchGeneration += 1
    generation := QbarSearchGeneration
    QbarSearchConfigGeneration := QbarConfigIndexGeneration
    QbarSearchState := "building"
    QbarSearchKeys := Map()
    QbarSearchEntries := []
    QbarSearchEntryById := Map()

    payloadItems := []
    id := 0
    for item in QbarAllItems() {
        id += 1
        ; The property is only an in-memory identity for this snapshot. It is
        ; never sent back as an execution value.
        item["searchId"] := id
        entry := Map("id", id, "item", item, "order", id)
        QbarSearchEntries.Push(entry)
        QbarSearchEntryById[id] := entry
        payloadItems.Push(Map("id", id, "label", item["label"]))
    }
    QbarSearchExpectedCount := id

    QbarExec("window.setLoading(true," . LLMJsonQuote(
        QbarText("Preparing search…", "正在准备搜索…")) . ");")
    payload := Map("generation", generation, "items", payloadItems)
    if !QbarExec("window.buildQbarSearchKeys(" . JSON.stringify(payload, 0) . ");") {
        QbarSearchDegrade(generation, "page_unavailable")
        return false
    }

    if IsObject(QbarSearchTimeoutTimer)
        SetTimer(QbarSearchTimeoutTimer, 0)
    QbarSearchTimeoutTimer := QbarSearchTimeout.Bind(generation)
    SetTimer(QbarSearchTimeoutTimer, -5000)
    return true
}

QbarSearchTimeout(generation, *) {
    global QbarSearchState
    if QbarSearchState = "building"
        QbarSearchDegrade(generation, "timeout")
}

QbarSearchCancel() {
    global QbarSearchState, QbarSearchGeneration, QbarSearchConfigGeneration
    global QbarSearchEntries, QbarSearchEntryById, QbarSearchKeys
    global QbarSearchExpectedCount, QbarSearchTimeoutTimer
    QbarSearchGeneration += 1
    QbarSearchState := "idle"
    QbarSearchConfigGeneration := 0
    QbarSearchEntries := []
    QbarSearchEntryById := Map()
    QbarSearchKeys := Map()
    QbarSearchExpectedCount := 0
    if IsObject(QbarSearchTimeoutTimer)
        SetTimer(QbarSearchTimeoutTimer, 0)
    QbarSearchTimeoutTimer := 0
}

QbarSearchOnConfigInvalidated() {
    global QbarVisible, QbarIndexReady, QbarHost
    QbarSearchCancel()
    if QbarVisible && PanelHostPageReady(QbarHost) {
        QbarIndexReady := false
        QbarStartIndexLoad()
    }
}

QbarSearchKeysReady(msg) {
    global QbarSearchState, QbarSearchGeneration, QbarSearchConfigGeneration
    global QbarSearchExpectedCount, QbarSearchEntryById, QbarSearchKeys
    global QbarSearchTimeoutTimer
    global QbarConfigIndexGeneration
    if QbarSearchState != "building" || !IsObject(msg)
        return

    generationOk := false
    generation := LLMMsgNumber(msg, "generation", &generationOk, 0, true)
    if !generationOk || generation != QbarSearchGeneration
        return

    okValid := false
    ok := LLMMsgBoolean(msg, "ok", &okValid, false)
    if !okValid || !ok {
        QbarSearchDegrade(generation, "page_error")
        return
    }
    if !msg.Has("items") || Type(msg["items"]) != "Array"
        return QbarSearchDegrade(generation, "invalid_items")
    rawItems := msg["items"]
    if rawItems.Length != QbarSearchExpectedCount
        return QbarSearchDegrade(generation, "count_mismatch")

    nextKeys := Map()
    seen := Map()
    for raw in rawItems {
        if Type(raw) != "Map"
            return QbarSearchDegrade(generation, "item_not_object")
        idValid := false
        id := LLMMsgNumber(raw, "id", &idValid, 0, true)
        if !idValid || !QbarSearchEntryById.Has(id) || seen.Has(id)
            return QbarSearchDegrade(generation, "invalid_id")
        fullValid := false
        full := QbarSearchReadKeyArray(raw, "pinyinFull", &fullValid)
        initialsValid := false
        initials := QbarSearchReadKeyArray(raw, "pinyinInitials", &initialsValid)
        wordValid := false
        word := QbarSearchReadKeyString(raw, "wordInitials", &wordValid)
        if !fullValid || !initialsValid || !wordValid
            return QbarSearchDegrade(generation, "invalid_key")
        nextKeys[id] := Map("full", full, "initials", initials, "word", word)
        seen[id] := true
    }
    if seen.Count != QbarSearchExpectedCount
        return QbarSearchDegrade(generation, "missing_id")

    QbarSearchKeys := nextKeys
    QbarSearchConfigGeneration := QbarConfigIndexGeneration
    QbarSearchState := "ready"
    if IsObject(QbarSearchTimeoutTimer)
        SetTimer(QbarSearchTimeoutTimer, 0)
    QbarSearchTimeoutTimer := 0
    DebugLog("Qbar search keys ready count=" . seen.Count)
    QbarFinishIndexLoad()
}

QbarSearchReadKeyArray(raw, key, &valid := false) {
    valid := false
    result := []
    if !raw.Has(key) || Type(raw[key]) != "Array"
        return result
    for value in raw[key] {
        if Type(value) != "String" || (value != "" && !RegExMatch(value, "^[a-z]+$"))
            return result
        if value != ""
            result.Push(value)
    }
    valid := true
    return result
}

QbarSearchReadKeyString(raw, key, &valid := false) {
    valid := false
    if !raw.Has(key) || Type(raw[key]) != "String"
        return ""
    value := raw[key]
    if value != "" && !RegExMatch(value, "^[a-z]+$")
        return ""
    valid := true
    return value
}

QbarSearchDegrade(generation, reason := "error") {
    global QbarSearchState, QbarSearchGeneration, QbarSearchTimeoutTimer
    if generation != QbarSearchGeneration
        return
    if IsObject(QbarSearchTimeoutTimer)
        SetTimer(QbarSearchTimeoutTimer, 0)
    QbarSearchTimeoutTimer := 0
    QbarSearchState := "degraded"
    DebugLog("Qbar search degraded reason=" . reason)
    QbarFinishIndexLoad()
}

QbarSearchCurrentEntries() {
    global QbarSearchEntries
    if QbarSearchEntries.Length
        return QbarSearchEntries
    entries := []
    order := 0
    for item in QbarAllItems() {
        order += 1
        entries.Push(Map("id", 0, "item", item, "order", order))
    }
    return entries
}

QbarSearchMatchItem(item, text, matchStrLeft, glob, &matchRank := 60) {
    global QbarSearchKeys
    matchRank := 60
    label := String(item["label"])
    short := String(item["short"])
    lowerText := StrLower(text)
    lowerLabel := StrLower(label)
    lowerShort := StrLower(short)

    if lowerLabel = lowerText || lowerShort = lowerText {
        matchRank := 0
        return true
    }
    if SubStr(lowerLabel, 1, StrLen(lowerText)) = lowerText
        || SubStr(lowerShort, 1, StrLen(lowerText)) = lowerText {
        matchRank := 10
        return true
    }

    ; Built-in commands may have several accepted aliases, but only their
    ; canonical row is exposed in the list. Match those aliases here so
    ; typing a non-canonical alias still finds that one row.
    if item.Has("aliases") {
        for alias in item["aliases"] {
            aliasText := StrLower(String(alias))
            if aliasText = lowerText {
                matchRank := 0
                return true
            }
            if SubStr(aliasText, 1, StrLen(lowerText)) = lowerText {
                matchRank := 10
                return true
            }
        }
    }

    ; Pinyin and word initials intentionally only accept a plain ASCII query.
    ; Commands with arguments, paths and wildcard expressions retain the old
    ; literal/glob behavior below.
    if RegExMatch(text, "^[A-Za-z]+$") && item.Has("searchId") {
        id := item["searchId"]
        if QbarSearchKeys.Has(id) {
            derivedKeys := QbarSearchKeys[id]
            query := StrLower(text)
            for key in derivedKeys["initials"] {
                if key = query {
                    matchRank := 20
                    return true
                }
            }
            word := derivedKeys["word"]
            if word != "" {
                if word = query {
                    matchRank := 20
                    return true
                }
                if SubStr(word, 1, StrLen(query)) = query {
                    matchRank := 30
                    return true
                }
            }
            for key in derivedKeys["initials"] {
                if SubStr(key, 1, StrLen(query)) = query {
                    matchRank := 30
                    return true
                }
            }
            for key in derivedKeys["full"] {
                if key = query {
                    matchRank := 40
                    return true
                }
                if SubStr(key, 1, StrLen(query)) = query {
                    matchRank := 50
                    return true
                }
            }
        }
    }

    if RegExMatch(label, glob) || short = matchStrLeft {
        matchRank := 60
        return true
    }
    return false
}
