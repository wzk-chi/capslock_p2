; Clipboard history lifecycle, capture queue and actions.

global ClipboardHistoryLoaded := false
global ClipboardHistoryEnabled := true
global ClipboardHistoryBaselineSequence := 0
global ClipboardHistoryEpoch := 0
global ClipboardHistoryNextEvent := 1
global ClipboardHistoryCaptureOrder := 0
global ClipboardHistoryEvents := Map()
global ClipboardHistorySequenceEvents := Map()
global ClipboardHistoryOwnedSequences := Map()
global ClipboardHistoryPendingTasks := Map()

ClipboardHistoryInitialize() {
    global ClipboardHistoryLoaded, ClipboardHistoryEnabled
    global ClipboardHistoryBaselineSequence, ClipboardHistoryEpoch
    global ClipboardHistoryEvents, ClipboardHistorySequenceEvents, ClipboardHistoryOwnedSequences
    global ClipboardHistoryPendingTasks
    global ClipboardHistoryCaptureOrder
    global ClipboardHistoryStoreMaxItems
    if ClipboardHistoryLoaded
        return true
    ClipboardHistoryLoaded := true
    ClipboardHistoryEnabled := ConfigRead("ClipboardHistory", "enabled", "1") != "0"
    ClipboardHistoryEpoch += 1
    ClipboardHistoryEvents := Map()
    ClipboardHistorySequenceEvents := Map()
    ClipboardHistoryOwnedSequences := Map()
    ClipboardHistoryPendingTasks := Map()
    ClipboardHistoryBaselineSequence := ClipboardSequenceNumber()
    ClipboardHistoryStoreMaxItems := ClipboardHistoryIntegerConfig("maxItems", 500, 20, 5000)
    if !ClipboardHistoryStoreInit() {
        ClipboardHistoryLoaded := false
        return false
    }
    ClipboardHistoryCaptureOrder := Max(0, ClipboardHistoryStoreNextOrder() - 1)
    return true
}

ClipboardHistoryShutdown(*) {
    global ClipboardHistoryLoaded, ClipboardHistoryEpoch, ClipboardHistoryEvents
    global ClipboardHistorySequenceEvents, ClipboardHistoryOwnedSequences
    global ClipboardHistoryPendingTasks
    ClipboardHistoryEpoch += 1
    ClipboardHistoryEvents := Map()
    ClipboardHistorySequenceEvents := Map()
    ClipboardHistoryOwnedSequences := Map()
    ClipboardHistoryPendingTasks := Map()
    ClipboardHistoryStoreClose()
    ClipboardHistoryLoaded := false
}

ClipboardHistoryIntegerConfig(key, fallback, minimum, maximum) {
    value := ConfigRead("ClipboardHistory", key, String(fallback))
    try value := Integer(value)
    catch
        return fallback
    return Max(minimum, Min(maximum, value))
}

ClipboardHistoryIsEnabled() {
    global ClipboardHistoryEnabled
    return ClipboardHistoryEnabled
}

ClipboardHistorySetEnabled(enabled) {
    global ClipboardHistoryEnabled, ClipboardHistoryEpoch, ClipboardHistoryBaselineSequence
    ClipboardHistoryEnabled := !!enabled
    ClipboardHistoryEpoch += 1
    ClipboardHistoryBaselineSequence := ClipboardSequenceNumber()
    return ClipboardHistoryEnabled
}

ClipboardHistoryOnSettingsChanged() {
    global ClipboardHistoryStoreMaxItems
    enabled := ConfigRead("ClipboardHistory", "enabled", "1") != "0"
    ClipboardHistoryStoreMaxItems := ClipboardHistoryIntegerConfig("maxItems", 500, 20, 5000)
    ClipboardHistorySetEnabled(enabled)
}

ClipboardHistoryMarkOwnedSequence(sequence, reason := "internal") {
    global ClipboardHistoryEnabled, ClipboardHistoryEpoch
    global ClipboardHistoryEvents, ClipboardHistorySequenceEvents, ClipboardHistoryOwnedSequences
    if !ClipboardHistoryEnabled || !sequence
        return false
    ClipboardHistoryPruneOwnedSequences()
    if ClipboardHistorySequenceEvents.Has(sequence) {
        eventId := ClipboardHistorySequenceEvents[sequence]
        if ClipboardHistoryEvents.Has(eventId) {
            event := ClipboardHistoryEvents[eventId]
            if !event["processed"] {
                event["reason"] := String(reason)
                event["awaitingExplicit"] := event["reason"] = "user-copy"
                    || event["reason"] = "user-cut"
            }
        }
        return true
    }
    ClipboardHistoryOwnedSequences[sequence] := Map(
        "reason", String(reason), "epoch", ClipboardHistoryEpoch,
        "expiresAt", A_TickCount + 5000)
    return true
}

ClipboardHistoryTakeOwnedSequence(sequence, &reason := "") {
    global ClipboardHistoryEpoch, ClipboardHistoryOwnedSequences
    reason := ""
    ClipboardHistoryPruneOwnedSequences()
    if !sequence || !ClipboardHistoryOwnedSequences.Has(sequence)
        return false
    state := ClipboardHistoryOwnedSequences[sequence]
    ClipboardHistoryOwnedSequences.Delete(sequence)
    if !IsObject(state) || state["epoch"] != ClipboardHistoryEpoch
        return false
    if state.Has("expiresAt") && A_TickCount > state["expiresAt"]
        return false
    reason := String(state["reason"])
    return true
}

ClipboardHistoryPruneOwnedSequences(*) {
    global ClipboardHistoryEpoch, ClipboardHistoryOwnedSequences
    expired := []
    for sequence, state in ClipboardHistoryOwnedSequences {
        if !IsObject(state) || state["epoch"] != ClipboardHistoryEpoch
            expired.Push(sequence)
        else if state.Has("expiresAt") && A_TickCount > state["expiresAt"]
            expired.Push(sequence)
    }
    for sequence in expired
        ClipboardHistoryOwnedSequences.Delete(sequence)
}

ClipboardHistoryCleanupEvent(eventId) {
    global ClipboardHistoryEvents, ClipboardHistorySequenceEvents, ClipboardHistoryPendingTasks
    if !eventId || !ClipboardHistoryEvents.Has(eventId)
        return
    event := ClipboardHistoryEvents[eventId]
    sequence := event.Has("sequence") ? event["sequence"] : 0
    ClipboardHistoryEvents.Delete(eventId)
    if sequence && ClipboardHistorySequenceEvents.Has(sequence)
        if ClipboardHistorySequenceEvents[sequence] = eventId
            ClipboardHistorySequenceEvents.Delete(sequence)
    if ClipboardHistoryPendingTasks.Has(eventId)
        ClipboardHistoryPendingTasks.Delete(eventId)
}

ClipboardHistoryQueueEvent(eventId) {
    global ClipboardHistoryEvents, ClipboardHistoryPendingTasks
    if !eventId || !ClipboardHistoryEvents.Has(eventId)
        return false
    event := ClipboardHistoryEvents[eventId]
    if event["processed"] || event["queued"]
        return true
    event["queued"] := true
    ClipboardHistoryPendingTasks[eventId] := true
    SetTimer(ClipboardHistoryProcessEvent.Bind(eventId), -1)
    return true
}

ClipboardHistoryNotify(dataType, reason := "", sequence := 0) {
    global ClipboardHistoryEnabled, ClipboardHistoryBaselineSequence, ClipboardHistoryEpoch
    global ClipboardHistoryNextEvent, ClipboardHistoryEvents, ClipboardHistorySequenceEvents
    global ClipboardHistoryCaptureOrder
    if !ClipboardHistoryEnabled
        return 0
    if !sequence
        sequence := ClipboardSequenceNumber()
    if !sequence || sequence = ClipboardHistoryBaselineSequence
        return 0
    ownedReason := ""
    owned := ClipboardHistoryTakeOwnedSequence(sequence, &ownedReason)
    if ClipboardHistorySequenceEvents.Has(sequence) {
        eventId := ClipboardHistorySequenceEvents[sequence]
        if owned && ClipboardHistoryEvents.Has(eventId) {
            event := ClipboardHistoryEvents[eventId]
            if !event["processed"] {
                event["reason"] := ownedReason
                event["awaitingExplicit"] := ownedReason = "user-copy"
                    || ownedReason = "user-cut"
            }
        }
        return eventId
    }
    if reason = "" && owned
        reason := ownedReason
    if reason = ""
        reason := ClipboardSuspendReason()
    if reason = ""
        reason := "external"
    ClipboardHistoryNextEvent += 1
    ClipboardHistoryCaptureOrder += 1
    eventId := "clipboard-event-" . A_TickCount . "-" . ClipboardHistoryNextEvent
    event := Map(
        "eventId", eventId,
        "sequence", sequence,
        "dataType", Integer(dataType),
        "reason", String(reason),
        "epoch", ClipboardHistoryEpoch,
        "observedAtUtc", ClipboardHistoryStoreNow(),
        "captureOrder", ClipboardHistoryCaptureOrder,
        "explicit", false,
        "awaitingExplicit", reason = "user-copy" || reason = "user-cut",
        "queued", false,
        "processed", false,
        "slotSnapshot", 0,
        "finalized", false)
    ClipboardHistoryEvents[eventId] := event
    ClipboardHistorySequenceEvents[sequence] := eventId
    return eventId
}

ClipboardHistoryOfferSlotSnapshot(eventId, sequence, snapshot, formatContext := 0) {
    global ClipboardHistoryEvents
    if eventId = "" || !ClipboardHistoryEvents.Has(eventId)
        return false
    event := ClipboardHistoryEvents[eventId]
    if event["sequence"] != sequence || !IsObject(snapshot)
        return false
    ; Retain the stable object reference until the delayed whitelist pass. Do
    ; not consult the mutable global SystemClipboard at processing time.
    event["slotSnapshot"] := snapshot
    event["formatContext"] := formatContext
    return true
}

ClipboardHistoryFinalizeNotify(eventId) {
    global ClipboardHistoryEvents, ClipboardHistoryPendingTasks
    if !eventId || !ClipboardHistoryEvents.Has(eventId)
        return
    event := ClipboardHistoryEvents[eventId]
    if event["finalized"]
        return
    event["finalized"] := true
    if event["reason"] != "external" && !event["explicit"] {
        if !event["awaitingExplicit"]
            ClipboardHistoryCleanupEvent(eventId)
        return
    }
    ClipboardHistoryQueueEvent(eventId)
}

ClipboardHistoryPublishExplicit(sequence, snapshot := 0, reason := "user-copy") {
    global ClipboardHistoryEnabled, ClipboardHistoryEvents, ClipboardHistorySequenceEvents, ClipboardHistoryEpoch
    if !ClipboardHistoryEnabled || !sequence
        return false
    eventId := ClipboardHistorySequenceEvents.Has(sequence)
        ? ClipboardHistorySequenceEvents[sequence] : ClipboardHistoryNotify(1, reason, sequence)
    if !eventId || !ClipboardHistoryEvents.Has(eventId)
        return false
    event := ClipboardHistoryEvents[eventId]
    if event["processed"]
        return true
    event["reason"] := reason
    event["explicit"] := true
    event["awaitingExplicit"] := false
    event["epoch"] := ClipboardHistoryEpoch
    if IsObject(snapshot)
        event["slotSnapshot"] := snapshot
    event["finalized"] := false
    return ClipboardHistoryQueueEvent(eventId)
}

ClipboardHistoryProcessEvent(eventId, *) {
    global ClipboardHistoryEnabled, ClipboardHistoryEvents, ClipboardHistoryPendingTasks, ClipboardHistoryEpoch
    if !ClipboardHistoryEvents.Has(eventId)
        return false
    if !ClipboardHistoryEnabled {
        ClipboardHistoryCleanupEvent(eventId)
        return false
    }
    event := ClipboardHistoryEvents[eventId]
    event["queued"] := false
    if event["processed"]
        return false
    event["processed"] := true
    result := false
    try {
        if event["epoch"] != ClipboardHistoryEpoch
            return false
        if event["reason"] != "external" && !event["explicit"]
            return false
        maxBytes := ClipboardHistoryIntegerConfig("maxCaptureBytes", 256 * 1024 * 1024,
            1024 * 1024, 512 * 1024 * 1024)
        if IsObject(event["slotSnapshot"])
            record := ClipboardHistoryCaptureSnapshot(event["slotSnapshot"], event["sequence"],
                maxBytes, event.Has("formatContext") ? event["formatContext"] : 0)
        else {
            ; Without a borrowed slot snapshot the current clipboard must still be
            ; the event that caused this notification. A later clipboard change is
            ; never allowed to be read as an older history item.
            if ClipboardSequenceNumber() != event["sequence"]
                return false
            record := ClipboardHistoryCaptureCurrent(event["sequence"], maxBytes)
        }
        if !IsObject(record)
            return false
        if event["reason"] = "user-cut"
            record["cut"] := true
        result := ClipboardHistoryRemember(record, event)
        return result
    } finally {
        ClipboardHistoryCleanupEvent(eventId)
    }
}

ClipboardHistoryRemember(record, event := 0) {
    global ClipboardHistoryCaptureOrder, ClipboardHistoryStoreMaxItems
    if !IsObject(record) || !ClipboardHistoryStoreInit()
        return false
    existing := ClipboardHistoryStoreFindByHash(record["contentHash"])
    now := ClipboardHistoryStoreNow()
    if IsObject(existing) {
        record["id"] := existing["id"]
        record["createdAtUtc"] := existing["created_at_utc"]
        record["isFavorite"] := existing["is_favorite"] != "0"
    } else {
        record["id"] := ClipboardHistoryNewId()
        record["createdAtUtc"] := now
        record["isFavorite"] := false
    }
    record["favoritedAtUtc"] := existing && existing.Has("favorited_at_utc")
        ? existing["favorited_at_utc"] : ""
    ClipboardHistoryCaptureOrder += 1
    record["lastCapturedAtUtc"] := now
    record["lastCaptureOrder"] := ClipboardHistoryCaptureOrder
    if !ClipboardHistoryStoreSave(record, record["snapshot"], record["manifestJson"])
        return false
    ClipboardHistoryStoreTrimNonFavorites(ClipboardHistoryStoreMaxItems)
    try ClipboardHistoryPanelChanged()
    return true
}

ClipboardHistoryNewId() {
    global ClipboardHistoryNextEvent
    ClipboardHistoryNextEvent += 1
    return "clipboard-item-" . A_TickCount . "-" . ClipboardHistoryNextEvent
}

ClipboardHistoryCopyItem(id) {
    item := ClipboardHistoryStoreGetItem(id)
    if !IsObject(item)
        return false
    return ClipboardHistoryCopyPrepared(item)
}

ClipboardHistoryCopyPrepared(item) {
    global SystemClipboard, WhichClipboardNow
    if !IsObject(item) || !IsObject(item["snapshot"])
        return false
    ownerHwnd := ClipboardHistoryOwnerHwnd()
    token := ClipboardSuspendBegin("history-replay")
    success := false
    try {
        success := ClipboardHistoryRestoreArchive(item["snapshot"], ownerHwnd,
            item["manifestJson"], &restoredSnapshot)
        if success {
            WhichClipboardNow := 0
            ; The stored archive is already a validated ClipboardAll-format
            ; buffer. Keep it as the current system slot without taking a
            ; second full snapshot from the clipboard.
            SystemClipboard := restoredSnapshot
            ClipboardHistoryMarkOwnedSequence(ClipboardSequenceNumber(), "history-replay")
        }
    } finally {
        ClipboardSuspendEnd(token)
    }
    return success
}

ClipboardHistoryPasteItem(id, targetHwnd := 0) {
    item := ClipboardHistoryStoreGetItem(id)
    if !IsObject(item)
        return false
    context := targetHwnd ? ClipboardHistoryTargetContextFromHwnd(targetHwnd) : 0
    return ClipboardHistoryPastePrepared(item, context, true)
}

ClipboardHistoryPastePrepared(item, targetContext := 0, activateTarget := false,
    expectedClipboardSequence := 0) {
    global SystemClipboard, WhichClipboardNow
    if !IsObject(item) || !IsObject(item["snapshot"])
        return false
    if IsObject(targetContext) {
        if !ClipboardHistoryTargetContextValid(targetContext)
            return false
        targetHwnd := targetContext["hwnd"]
        targetPid := targetContext["pid"]
    } else {
        targetHwnd := 0
        targetPid := 0
    }
    if targetHwnd && !ClipboardHistoryTargetWindowValid(targetHwnd, targetPid)
        return false
    if activateTarget && targetHwnd {
        WinActivate("ahk_id " . targetHwnd)
        if !WinWaitActive("ahk_id " . targetHwnd, , 0.4)
            return false
    }
    ownerHwnd := ClipboardHistoryOwnerHwnd()
    token := ClipboardSuspendBegin("history-replay")
    success := false
    try {
        if targetHwnd && (!ClipboardHistoryTargetWindowValid(targetHwnd, targetPid)
            || WinActive("ahk_id " . targetHwnd) != targetHwnd)
            return false
        if expectedClipboardSequence && ClipboardSequenceNumber() != expectedClipboardSequence
            return false
        if !ClipboardHistoryRestoreArchive(item["snapshot"], ownerHwnd,
            item["manifestJson"], &restoredSnapshot)
            return false
        WhichClipboardNow := 0
        SystemClipboard := restoredSnapshot
        ownedSequence := ClipboardSequenceNumber()
        ClipboardHistoryMarkOwnedSequence(ownedSequence, "history-replay")
        if targetHwnd && (!ClipboardHistoryTargetWindowValid(targetHwnd, targetPid)
            || WinActive("ahk_id " . targetHwnd) != targetHwnd
            || ClipboardSequenceNumber() != ownedSequence)
            return false
        SendInput("^v")
        success := true
    } finally {
        ClipboardSuspendEnd(token)
    }
    return success
}

ClipboardHistorySetFavoriteItem(id, desiredState) {
    if !ClipboardHistoryStoreSetFavorite(id, desiredState)
        return false
    return true
}

ClipboardHistoryDeleteItem(id) {
    if !ClipboardHistoryStoreDelete(id)
        return false
    try ClipboardHistoryPanelChanged()
    return true
}

ClipboardHistoryClearNonFavorites() {
    global ClipboardHistoryEpoch, ClipboardHistoryPendingTasks
    if !ClipboardHistoryStoreClearNonFavorites()
        return false
    ; Invalidate delayed captures only after the database transaction has
    ; committed. A failed clear must leave both the store and the queue usable.
    ClipboardHistoryEpoch += 1
    ClipboardHistoryPendingTasks := Map()
    try ClipboardHistoryPanelChanged()
    return true
}

ClipboardHistoryRows(searchText := "", primaryType := "all", favoriteOnly := false,
    cursor := 0, limit := 50) {
    rows := []
    for row in ClipboardHistoryStoreList(searchText, primaryType, favoriteOnly, cursor, limit) {
        files := []
        try parsed := JSON.Parse(row["files_json"], false, true)
        catch
            parsed := []
        if Type(parsed) = "Array"
            files := parsed
        rows.Push(Map(
            "id", row["id"],
            "type", row["primary_type"],
            "richText", row["is_rich_text"] != "0",
            "preview", row["preview_text"],
            "text", row["text_plain"],
            "files", files,
            "favorite", row["is_favorite"] != "0",
            "capturedAt", row["last_captured_at_utc"],
            "imageWidth", Integer(row["image_width"]),
            "imageHeight", Integer(row["image_height"]),
            "itemCount", Integer(row["item_count"]),
            "byteSize", Integer(row["byte_size"]),
            "cursor", Integer(row["last_capture_order"])))
    }
    return rows
}

ClipboardHistoryCounts(searchText := "", primaryType := "", favoriteOnly := false) {
    return ClipboardHistoryStoreCounts(searchText, primaryType, favoriteOnly)
}

ClipboardHistoryOwnerHwnd() {
    global ClipboardHistoryHost
    try {
        panelGui := PanelHostGui(ClipboardHistoryHost)
        return IsObject(panelGui) ? panelGui.Hwnd : 0
    } catch
        return 0
}

; A target is a value object, not just a HWND. A reused HWND or a stale Qbar
; session must never receive a history paste intended for another window.
ClipboardHistoryCaptureTargetContext() {
    activeHwnd := WinGetID("A")
    if !activeHwnd
        return 0
    if ClipboardHistoryIsQbarWindow(activeHwnd)
        return ClipboardHistoryQbarTargetContext()
    if !ClipboardHistoryTargetWindowValid(activeHwnd, 0)
        return 0
    return ClipboardHistoryTargetContextFromHwnd(activeHwnd, "foreground", "")
}

ClipboardHistoryTargetContextFromHwnd(hwnd, source := "provided", sessionId := "") {
    if !hwnd || !ClipboardHistoryTargetWindowValid(hwnd, 0)
        return 0
    try pid := WinGetPID("ahk_id " . hwnd)
    catch
        return 0
    return Map("hwnd", hwnd, "pid", pid, "source", String(source),
        "sessionId", String(sessionId))
}

ClipboardHistoryTargetContextValid(context) {
    if !IsObject(context) || !context.Has("hwnd") || !context.Has("pid")
        return false
    hwnd := context["hwnd"]
    pid := context["pid"]
    if !ClipboardHistoryTargetWindowValid(hwnd, pid)
        return false
    if context.Has("sessionId") && context["sessionId"] != ""
        return ClipboardHistoryQbarSessionValid(context)
    return true
}

ClipboardHistoryQbarSessionValid(context) {
    global QbarSessionId
    if !IsObject(context) || !context.Has("sessionId") || context["sessionId"] = ""
        return true
    return context["sessionId"] = QbarSessionId
}

ClipboardHistoryTargetWindowValid(hwnd, expectedPid := 0) {
    if !hwnd || !WinExist("ahk_id " . hwnd)
        return false
    try pid := WinGetPID("ahk_id " . hwnd)
    catch
        return false
    if expectedPid && pid != expectedPid
        return false
    ; All WebView2 panels belong to this process. Rejecting the process itself
    ; also covers panels that have not yet populated their host-specific state.
    if pid = DllCall("kernel32\GetCurrentProcessId", "uint")
        return false
    return true
}

ClipboardHistoryIsQbarWindow(hwnd) {
    global QbarHost
    return ClipboardHistoryHostWindowId(QbarHost) = hwnd
}

ClipboardHistoryHostWindowId(host) {
    if !IsObject(host)
        return 0
    try hostGui := PanelHostGui(host)
    catch
        return 0
    return IsObject(hostGui) ? hostGui.Hwnd : 0
}

ClipboardHistoryQbarTargetContext() {
    global QbarTargetHwnd, QbarTargetPid, QbarTargetSessionId, QbarSessionId
    if !QbarTargetHwnd || !QbarTargetPid
        return 0
    if !ClipboardHistoryTargetWindowValid(QbarTargetHwnd, QbarTargetPid)
        return 0
    if QbarTargetSessionId = "" || QbarTargetSessionId != QbarSessionId
        return 0
    return Map("hwnd", QbarTargetHwnd, "pid", QbarTargetPid,
        "source", "qbar", "sessionId", QbarTargetSessionId)
}
