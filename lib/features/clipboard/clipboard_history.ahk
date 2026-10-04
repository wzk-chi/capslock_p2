; Clipboard history lifecycle, capture queue and actions.

global ClipboardHistoryLoaded := false
global ClipboardHistoryEnabled := true
global ClipboardHistoryBaselineSequence := 0
global ClipboardHistoryEpoch := 0
global ClipboardHistoryNextEvent := 1
global ClipboardHistoryEvents := Map()
global ClipboardHistorySequenceEvents := Map()
global ClipboardHistoryOwnedSequences := Map()
global ClipboardHistoryPendingTasks := Map()
global ClipboardHistoryCaptureQueue := []
global ClipboardHistoryActiveCaptureEventId := ""
global ClipboardHistoryRetentionDays := 30
global ClipboardHistoryRetainedSnapshotBytes := 0
global ClipboardHistoryMaxRetainedSnapshotBytes := 256 * 1024 * 1024

ClipboardHistoryInitialize() {
    global ClipboardHistoryLoaded, ClipboardHistoryEnabled
    global ClipboardHistoryBaselineSequence, ClipboardHistoryEpoch
    global ClipboardHistoryEvents, ClipboardHistorySequenceEvents, ClipboardHistoryOwnedSequences
    global ClipboardHistoryPendingTasks, ClipboardHistoryCaptureQueue
    global ClipboardHistoryActiveCaptureEventId, ClipboardHistoryRetainedSnapshotBytes
    global ClipboardHistoryStoreMaxItems, ClipboardHistoryRetentionDays
    if ClipboardHistoryLoaded
        return true
    ClipboardHistoryLoaded := true
    ClipboardHistoryEnabled := ConfigRead("ClipboardHistory", "enabled", "1") != "0"
    ClipboardHistoryEpoch += 1
    ClipboardHistoryEvents := Map()
    ClipboardHistorySequenceEvents := Map()
    ClipboardHistoryOwnedSequences := Map()
    ClipboardHistoryPendingTasks := Map()
    ClipboardHistoryCaptureQueue := []
    ClipboardHistoryActiveCaptureEventId := ""
    ClipboardHistoryRetainedSnapshotBytes := 0
    ClipboardHistoryBaselineSequence := ClipboardSequenceNumber()
    ClipboardHistoryStoreMaxItems := ClipboardHistoryIntegerConfig("maxItems", 500, 20, 5000)
    ClipboardHistoryRetentionDays := ClipboardHistoryIntegerConfig("retentionDays", 30, 1, 3650)
    if !ClipboardHistoryStoreInit() {
        ClipboardHistoryLoaded := false
        return false
    }
    return true
}

ClipboardHistoryShutdown(*) {
    global ClipboardHistoryLoaded, ClipboardHistoryEpoch, ClipboardHistoryEvents
    global ClipboardHistorySequenceEvents, ClipboardHistoryOwnedSequences
    global ClipboardHistoryPendingTasks, ClipboardHistoryCaptureQueue
    global ClipboardHistoryActiveCaptureEventId, ClipboardHistoryRetainedSnapshotBytes
    ClipboardHistoryEpoch += 1
    ClipboardHistoryEvents := Map()
    ClipboardHistorySequenceEvents := Map()
    ClipboardHistoryOwnedSequences := Map()
    ClipboardHistoryPendingTasks := Map()
    ClipboardHistoryCaptureQueue := []
    ClipboardHistoryActiveCaptureEventId := ""
    ClipboardHistoryRetainedSnapshotBytes := 0
    ClipboardHistoryShutdownPanel()
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

ClipboardHistoryRetentionCutoff() {
    global ClipboardHistoryRetentionDays
    return FormatTime(DateAdd(A_NowUTC, -ClipboardHistoryRetentionDays, "Days"),
        "yyyy-MM-ddTHH:mm:ss") . ".000Z"
}

ClipboardHistoryIsEnabled() {
    global ClipboardHistoryEnabled
    return ClipboardHistoryEnabled
}

ClipboardHistorySetEnabled(enabled) {
    global ClipboardHistoryEnabled, ClipboardHistoryEpoch, ClipboardHistoryBaselineSequence
    global ClipboardHistoryEvents, ClipboardHistorySequenceEvents, ClipboardHistoryPendingTasks
    global ClipboardHistoryCaptureQueue, ClipboardHistoryRetainedSnapshotBytes
    Critical("On")
    try {
        ClipboardHistoryEnabled := !!enabled
        ClipboardHistoryEpoch += 1
        ClipboardHistoryBaselineSequence := ClipboardSequenceNumber()
        ClipboardHistoryDiscardPendingEvents()
    } finally {
        Critical("Off")
    }
    return ClipboardHistoryEnabled
}

ClipboardHistoryOnSettingsChanged() {
    global ClipboardHistoryStoreMaxItems, ClipboardHistoryRetentionDays
    enabled := ConfigRead("ClipboardHistory", "enabled", "1") != "0"
    ClipboardHistoryStoreMaxItems := ClipboardHistoryIntegerConfig("maxItems", 500, 20, 5000)
    ClipboardHistoryRetentionDays := ClipboardHistoryIntegerConfig("retentionDays", 30, 1, 3650)
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
    global ClipboardHistoryRetainedSnapshotBytes
    Critical("On")
    try {
        if !eventId || !ClipboardHistoryEvents.Has(eventId)
            return
        event := ClipboardHistoryEvents[eventId]
        sequence := event.Has("sequence") ? event["sequence"] : 0
        snapshotBytes := event.Has("slotSnapshotBytes") ? event["slotSnapshotBytes"] : 0
        ClipboardHistoryRetainedSnapshotBytes := Max(0,
            ClipboardHistoryRetainedSnapshotBytes - snapshotBytes)
        ClipboardHistoryEvents.Delete(eventId)
        if sequence && ClipboardHistorySequenceEvents.Has(sequence)
            if ClipboardHistorySequenceEvents[sequence] = eventId
                ClipboardHistorySequenceEvents.Delete(sequence)
        if ClipboardHistoryPendingTasks.Has(eventId)
            ClipboardHistoryPendingTasks.Delete(eventId)
    } finally {
        Critical("Off")
    }
}

; Discard queued events but keep the active event's snapshot accounted for
; until its finally block releases the remaining reference.
ClipboardHistoryDiscardPendingEvents() {
    global ClipboardHistoryEvents, ClipboardHistorySequenceEvents
    global ClipboardHistoryPendingTasks, ClipboardHistoryCaptureQueue
    global ClipboardHistoryActiveCaptureEventId, ClipboardHistoryRetainedSnapshotBytes
    remainingEvents := Map()
    retainedBytes := 0
    activeId := ClipboardHistoryActiveCaptureEventId
    if activeId != "" && ClipboardHistoryEvents.Has(activeId) {
        activeEvent := ClipboardHistoryEvents[activeId]
        remainingEvents[activeId] := activeEvent
        if activeEvent.Has("slotSnapshotBytes")
            retainedBytes := activeEvent["slotSnapshotBytes"]
    }
    ClipboardHistoryEvents := remainingEvents
    ClipboardHistorySequenceEvents := Map()
    ClipboardHistoryPendingTasks := Map()
    ClipboardHistoryCaptureQueue := []
    ClipboardHistoryRetainedSnapshotBytes := retainedBytes
}

ClipboardHistoryQueueEvent(eventId) {
    global ClipboardHistoryEvents, ClipboardHistoryPendingTasks
    global ClipboardHistoryCaptureQueue, ClipboardHistoryActiveCaptureEventId
    Critical("On")
    try {
        if !eventId || !ClipboardHistoryEvents.Has(eventId)
            return false
        event := ClipboardHistoryEvents[eventId]
        if event["processed"] || event["queued"]
            return true
        event["queued"] := true
        ClipboardHistoryPendingTasks[eventId] := true
        if ClipboardHistoryActiveCaptureEventId = "" {
            ClipboardHistoryActiveCaptureEventId := eventId
            event["queued"] := false
            SetTimer(ClipboardHistoryProcessEvent.Bind(eventId), -1)
        } else
            ClipboardHistoryCaptureQueue.Push(eventId)
        return true
    } finally {
        Critical("Off")
    }
}

; Keep one large capture/parse/hash/save pipeline active at a time. Pending
; events retain only their bounded source snapshots, not concurrent work copies.
ClipboardHistoryScheduleNextCapture() {
    global ClipboardHistoryEvents, ClipboardHistoryCaptureQueue
    global ClipboardHistoryActiveCaptureEventId
    if ClipboardHistoryActiveCaptureEventId != ""
        return false
    while ClipboardHistoryCaptureQueue.Length {
        eventId := ClipboardHistoryCaptureQueue.RemoveAt(1)
        if !ClipboardHistoryEvents.Has(eventId)
            continue
        event := ClipboardHistoryEvents[eventId]
        if !event["queued"] || event["processed"]
            continue
        event["queued"] := false
        ClipboardHistoryActiveCaptureEventId := eventId
        SetTimer(ClipboardHistoryProcessEvent.Bind(eventId), -1)
        return true
    }
    try ClipboardHistoryPanelCaptureQueueDrained()
    return false
}

ClipboardHistoryNotify(dataType, reason := "", sequence := 0) {
    global ClipboardHistoryEnabled, ClipboardHistoryBaselineSequence, ClipboardHistoryEpoch
    global ClipboardHistoryNextEvent, ClipboardHistoryEvents, ClipboardHistorySequenceEvents
    if !ClipboardHistoryEnabled {
        DebugLog("ClipboardHistoryNotify ignored because history is disabled")
        return 0
    }
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
    if reason = "" {
        suspendReason := ClipboardSuspendReason()
        if suspendReason = "user-copy" || suspendReason = "user-cut"
            reason := suspendReason
        else
            reason := suspendReason = "" ? "external" : "pending"
    }
    ClipboardHistoryNextEvent += 1
    eventId := "clipboard-event-" . A_TickCount . "-" . ClipboardHistoryNextEvent
    event := Map(
        "eventId", eventId,
        "sequence", sequence,
        "dataType", Integer(dataType),
        "reason", String(reason),
        "pendingReason", reason = "pending" ? String(suspendReason) : "",
        "epoch", ClipboardHistoryEpoch,
        "observedAtUtc", ClipboardHistoryStoreNow(),
        "explicit", false,
        "awaitingExplicit", reason = "user-copy" || reason = "user-cut",
        "queued", false,
        "processed", false,
        "slotSnapshot", 0,
        "slotSnapshotBytes", 0,
        "finalized", false)
    ClipboardHistoryEvents[eventId] := event
    ClipboardHistorySequenceEvents[sequence] := eventId
    DebugLog("ClipboardHistoryNotify event=" . eventId . " sequence=" . sequence
        . " type=" . dataType . " reason=" . reason)
    return eventId
}

ClipboardHistoryOfferSlotSnapshot(eventId, sequence, snapshot, formatContext := 0) {
    global ClipboardHistoryEvents, ClipboardHistoryRetainedSnapshotBytes
    global ClipboardHistoryMaxRetainedSnapshotBytes
    Critical("On")
    try {
        if eventId = "" || !ClipboardHistoryEvents.Has(eventId)
            return false
        event := ClipboardHistoryEvents[eventId]
        if event["sequence"] != sequence || !IsObject(snapshot)
            return false
        previousBytes := event.Has("slotSnapshotBytes") ? event["slotSnapshotBytes"] : 0
        nextBytes := snapshot.Size
        retainedBytes := ClipboardHistoryRetainedSnapshotBytes - previousBytes + nextBytes
        if retainedBytes > ClipboardHistoryMaxRetainedSnapshotBytes {
            DebugLog("Clipboard history retained snapshot skipped: memory budget")
            return false
        }
        ClipboardHistoryRetainedSnapshotBytes := retainedBytes
        ; Retain the stable object reference until the delayed whitelist pass. Do
        ; not consult the mutable global SystemClipboard at processing time.
        event["slotSnapshot"] := snapshot
        event["slotSnapshotBytes"] := nextBytes
        event["formatContext"] := formatContext
        return true
    } finally {
        Critical("Off")
    }
}

ClipboardHistoryFinalizeNotify(eventId) {
    global ClipboardHistoryEvents, ClipboardHistoryPendingTasks
    if !eventId || !ClipboardHistoryEvents.Has(eventId)
        return
    event := ClipboardHistoryEvents[eventId]
    if event["finalized"]
        return
    event["finalized"] := true
    if event["reason"] = "pending" {
        SetTimer(ClipboardHistoryResolvePending.Bind(eventId), -50)
        return
    }
    if event["reason"] != "external" && !event["explicit"] {
        if event["awaitingExplicit"]
            SetTimer(ClipboardHistoryExpireAwaitingExplicit.Bind(eventId), -5000)
        else
            ClipboardHistoryCleanupEvent(eventId)
        return
    }
    ClipboardHistoryQueueEvent(eventId)
}

ClipboardHistoryResolvePending(eventId, *) {
    global ClipboardHistoryEvents, ClipboardHistoryEpoch
    if !ClipboardHistoryEvents.Has(eventId)
        return
    event := ClipboardHistoryEvents[eventId]
    if !event["finalized"] || event["queued"] || event["processed"]
        return
    if event["epoch"] != ClipboardHistoryEpoch {
        ClipboardHistoryCleanupEvent(eventId)
        return
    }
    if event["reason"] = "pending"
        event["reason"] := "external"
    if event["reason"] != "external" && !event["explicit"] {
        if !event["awaitingExplicit"]
            ClipboardHistoryCleanupEvent(eventId)
        return
    }
    ClipboardHistoryQueueEvent(eventId)
}

ClipboardHistoryExpireAwaitingExplicit(eventId, *) {
    global ClipboardHistoryEvents
    if !ClipboardHistoryEvents.Has(eventId)
        return
    event := ClipboardHistoryEvents[eventId]
    if event["awaitingExplicit"] && !event["explicit"] && !event["processed"]
        ClipboardHistoryCleanupEvent(eventId)
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
        ClipboardHistoryOfferSlotSnapshot(eventId, sequence, snapshot)
    event["finalized"] := false
    return ClipboardHistoryQueueEvent(eventId)
}

ClipboardHistoryProcessEvent(eventId, *) {
    global ClipboardHistoryEnabled, ClipboardHistoryEvents, ClipboardHistoryEpoch
    global ClipboardHistoryActiveCaptureEventId
    global ClipboardHistoryStoreError
    Critical("On")
    try {
        if ClipboardHistoryActiveCaptureEventId != eventId
            return false
        if !ClipboardHistoryEvents.Has(eventId) {
            ClipboardHistoryActiveCaptureEventId := ""
            ClipboardHistoryScheduleNextCapture()
            return false
        }
        event := ClipboardHistoryEvents[eventId]
        if event["processed"] {
            ClipboardHistoryActiveCaptureEventId := ""
            ClipboardHistoryScheduleNextCapture()
            return false
        }
        event["queued"] := false
        event["processed"] := true
    } finally {
        Critical("Off")
    }
    result := false
    try {
        if !ClipboardHistoryEnabled
            return false
        if event["epoch"] != ClipboardHistoryEpoch
            return false
        if event["reason"] != "external" && !event["explicit"]
            return false
        maxBytes := ClipboardHistoryIntegerConfig("maxCaptureBytes", 256 * 1024 * 1024,
            1024 * 1024, 256 * 1024 * 1024)
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
        if !IsObject(record) {
            DebugLog("ClipboardHistory capture rejected event=" . eventId
                . " reason=unsupported-or-over-limit")
            return false
        }
        if event["epoch"] != ClipboardHistoryEpoch
            return false
        if event["reason"] = "user-cut"
            record["cut"] := true
        result := ClipboardHistoryRemember(record, event)
        DebugLog("ClipboardHistory capture event=" . eventId . " type="
            . record["primaryType"] . " saved=" . result
            . (result ? "" : " error=" . ClipboardHistoryStoreError))
        return result
    } finally {
        ClipboardHistoryCleanupEvent(eventId)
        Critical("On")
        try {
            if ClipboardHistoryActiveCaptureEventId = eventId {
                ClipboardHistoryActiveCaptureEventId := ""
                ClipboardHistoryScheduleNextCapture()
            }
        } finally {
            Critical("Off")
        }
    }
}

ClipboardHistoryRemember(record, event := 0) {
    global ClipboardHistoryStoreMaxItems, ClipboardHistoryEpoch, ClipboardHistoryStoreError
    result := false
    capacityFull := false
    Critical("On")
    try {
        if !IsObject(record) || !ClipboardHistoryStoreInit()
            return false
        if IsObject(event) && event.Has("epoch") && event["epoch"] != ClipboardHistoryEpoch
            return false
        existing := ClipboardHistoryStoreFindByHash(record["contentHash"])
        now := ClipboardHistoryStoreNow()
        if IsObject(existing) {
            record["id"] := existing["id"]
            record["isFavorite"] := existing["is_favorite"] != "0"
            record["noteText"] := existing.Has("note_text") ? existing["note_text"] : ""
            record["isPinned"] := existing.Has("is_pinned") && existing["is_pinned"] != "0"
            record["pinOrder"] := existing.Has("pin_order") ? Integer(existing["pin_order"]) : 0
        } else {
            record["id"] := ClipboardHistoryNewId()
            record["isFavorite"] := false
            record["noteText"] := ""
            record["isPinned"] := false
            record["pinOrder"] := 0
        }
        record["lastCapturedAtUtc"] := now
        if ClipboardHistoryStoreSave(record, record["snapshot"], record["manifestJson"],
            ClipboardHistoryRetentionCutoff(), ClipboardHistoryStoreMaxItems) {
            ClipboardHistoryImagePreviewCachePrune()
            result := true
        } else {
            capacityFull := InStr(ClipboardHistoryStoreError, "容量已满") > 0
        }
    } finally {
        Critical("Off")
    }
    if capacityFull
        ShowMsg("剪贴板历史容量已满，未记录新内容。", 5000)
    return result
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

ClipboardHistoryCopyPrepared(item, dragKind := "") {
    global SystemClipboard, WhichClipboardNow
    if !IsObject(item) || !IsObject(item["snapshot"])
        return false
    archive := item["snapshot"]
    manifestJson := item["manifestJson"]
    if dragKind != "" {
        ; Native drags expose only their real file/image formats, never text fallbacks.
        entries := ClipboardHistoryParseArchive(archive, manifestJson, true, dragKind)
        try manifest := JSON.Parse(manifestJson, false, true)
        catch
            manifest := []
        if Type(manifest) != "Array"
            return false
        dragEntries := []
        dragManifest := []
        for entry in entries {
            index := entry["manifestIndex"]
            if index > manifest.Length || !IsObject(manifest[index])
                continue
            manifestEntry := manifest[index]
            if !manifestEntry.Has("kind") || String(manifestEntry["kind"]) != dragKind
                continue
            if dragKind = "files" && (entry["id"] != 15 || entry["name"] != "")
                continue
            dragEntries.Push(entry)
            dragManifest.Push(manifestEntry)
        }
        if !dragEntries.Length
            return false
        archive := ClipboardHistoryBuildArchive(dragEntries)
        if !IsObject(archive)
            return false
        manifestJson := JSON.stringify(dragManifest, 0)
    }
    ownerHwnd := ClipboardHistoryOwnerHwnd()
    token := ClipboardSuspendBegin("history-replay")
    success := false
    try {
        success := ClipboardHistoryRestoreArchive(archive, ownerHwnd,
            manifestJson, &restoredSnapshot)
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
    if success && item.Has("id")
        ClipboardHistoryTouchItem(item["id"])
    return success
}

ClipboardHistoryTouchItem(id) {
    if !ClipboardHistoryStoreTouch(id) {
        DebugLog("Clipboard history recent-use update failed")
        return false
    }
    return true
}

ClipboardHistoryPasteItem(id, targetHwnd := 0) {
    item := ClipboardHistoryStoreGetItem(id)
    if !IsObject(item)
        return false
    context := targetHwnd ? ClipboardHistoryTargetContextFromHwnd(targetHwnd) : 0
    return ClipboardHistoryPastePrepared(item, context, true)
}

ClipboardHistoryPastePrepared(item, targetContext := 0, activateTarget := false,
    expectedClipboardSequence := 0, expectedSessionId := "") {
    global SystemClipboard, WhichClipboardNow, ClipboardHistorySessionId
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
        if expectedSessionId != "" && ClipboardHistorySessionId != expectedSessionId
            return false
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
        Critical("On")
        try {
            if expectedSessionId != "" && ClipboardHistorySessionId != expectedSessionId
                return false
            if targetHwnd && (!ClipboardHistoryTargetWindowValid(targetHwnd, targetPid)
                || WinActive("ahk_id " . targetHwnd) != targetHwnd
                || ClipboardSequenceNumber() != ownedSequence)
                return false
            SendInput("^v")
            success := true
        } finally {
            Critical("Off")
        }
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

ClipboardHistorySetNoteItem(id, noteText) {
    return ClipboardHistoryStoreSetNote(id, SubStr(String(noteText), 1, 4000))
}

ClipboardHistorySetNotesItems(ids, noteText) {
    return ClipboardHistoryStoreSetNotes(ids, SubStr(String(noteText), 1, 4000))
}

ClipboardHistorySetPinnedItem(id, desiredState) {
    return ClipboardHistoryStoreSetPinned(id, desiredState)
}

ClipboardHistoryDeleteItem(id) {
    if !ClipboardHistoryStoreDelete(id)
        return false
    ClipboardHistoryImagePreviewCacheDelete(id)
    try ClipboardHistoryPanelChanged()
    return true
}

ClipboardHistoryDeleteItems(ids) {
    if !ClipboardHistoryStoreDeleteMany(ids)
        return false
    for id in ids
        ClipboardHistoryImagePreviewCacheDelete(id)
    return true
}

ClipboardHistoryClearNonFavorites() {
    global ClipboardHistoryEpoch, ClipboardHistoryPendingTasks
    global ClipboardHistoryEvents, ClipboardHistorySequenceEvents
    global ClipboardHistoryCaptureQueue, ClipboardHistoryRetainedSnapshotBytes
    previousEpoch := ClipboardHistoryEpoch
    Critical("On")
    try {
        ClipboardHistoryEpoch += 1
        if !ClipboardHistoryStoreClearNonFavorites() {
            ClipboardHistoryEpoch := previousEpoch
            return false
        }
        ClipboardHistoryDiscardPendingEvents()
    } finally {
        Critical("Off")
    }
    ClipboardHistoryImagePreviewCachePrune()
    try ClipboardHistoryPanelChanged()
    return true
}

ClipboardHistoryRows(searchText := "", primaryType := "all", favoriteOnly := false,
    dateAfter := "", dateBefore := "", page := 1, limit := 20) {
    rows := []
    for row in ClipboardHistoryStoreList(searchText, primaryType, favoriteOnly,
        dateAfter, dateBefore, page, limit) {
        fileCount := Integer(row["file_count"])
        rows.Push(Map(
            "id", row["id"],
            "type", row["primary_type"],
            "richText", row["is_rich_text"] != "0",
            "preview", row["preview_text"],
            "favorite", row["is_favorite"] != "0",
            "note", row.Has("note_text") ? row["note_text"] : "",
            "pinned", row.Has("is_pinned") && row["is_pinned"] != "0",
            "pinOrder", row.Has("pin_order") ? Integer(row["pin_order"]) : 0,
            "capturedAt", row["last_captured_at_utc"],
            "imageWidth", Integer(row["image_width"]),
            "imageHeight", Integer(row["image_height"]),
            "itemCount", row["primary_type"] = "file" ? fileCount : 1,
            "byteSize", Integer(row["byte_size"])))
    }
    return rows
}

ClipboardHistoryCounts(searchText := "", primaryType := "", favoriteOnly := false,
    dateAfter := "", dateBefore := "") {
    return ClipboardHistoryStoreCounts(searchText, primaryType, favoriteOnly, dateAfter, dateBefore)
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
