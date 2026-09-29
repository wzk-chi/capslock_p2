; QBar notes page lifecycle and page message protocol.

global NotesHost := 0
global NotesVisible := false
global NotesPendingSearch := ""
global NotesTargetHwnd := 0
global NotesQuerySeq := 0
global NotesEditorCounter := 0
global NotesEditorId := ""
global NotesEditorNoteId := ""
global NotesEditorSaving := false
global NotesSaveResults := Map()
global NotesCurrentTag := ""
global NotesStateSyncAttempts := 0
global NotesWidth := ScreenFitSize(1000, 720, 760, 520)[1]
global NotesHeight := ScreenFitSize(1000, 720, 760, 520)[2]

NotesShow(initialSearch := "", targetHwnd := 0, recordHistory := true) {
    global NotesHost, NotesVisible, NotesPendingSearch, NotesTargetHwnd, NotesWidth, NotesHeight
    NotesPendingSearch := String(initialSearch)
    if targetHwnd
        NotesTargetHwnd := targetHwnd
    if !NotesEnsureWebView()
        return false
    NotesVisible := true
    PanelHostShow(NotesHost, NotesWidth, NotesHeight, true)
    panelGui := PanelHostGui(NotesHost)
    if IsObject(panelGui)
        WinActivate("ahk_id " . panelGui.Hwnd)
    ShowSystemCursor()
    if recordHistory
        QbarHistoryRemember(QbarHistoryNotesEntry(NotesPendingSearch))
    NotesScheduleStateSync()
    return true
}

NotesHide(*) {
    global NotesHost, NotesVisible, NotesEditorSaving, NotesStateSyncAttempts
    if NotesEditorSaving
        return false
    NotesVisible := false
    NotesStateSyncAttempts := 0
    SetTimer(NotesSendInitialState, 0)
    PanelHostHide(NotesHost)
    return true
}

NotesIsActive() {
    global NotesVisible, NotesHost
    return NotesVisible && PanelHostWindowActive(NotesHost)
}

NotesEnsureWebView() {
    global NotesHost, NotesWidth, NotesHeight
    pagePath := A_ScriptDir . "\pages\qbar-notes.html"
    if IsObject(NotesHost) {
        try {
            PanelHostEnsure(NotesHost)
            NotesConfigureMediaMapping()
            return true
        } catch as existingError {
            PanelHostHide(NotesHost)
            ShowMsg("笔记页面初始化失败：" . existingError.Message, 5000)
            return false
        }
    }

    NotesHost := PanelHostCreate(pagePath, "capslock_p2 笔记", Map(
        "guiOptions", "+Resize +MinimizeBox +MaximizeBox +SysMenu +ToolWindow",
        "dataPath", A_Temp . "\CapsLockPlusNotesWebView2",
        "initialShow", "w" . NotesWidth . " h" . NotesHeight . " NA",
        "callbacks", Map(
            "close", NotesHide,
            "escape", NotesEscape,
            "resize", NotesResize,
            "navigation", NotesNavigationCompleted,
            "message", NotesWebMessageReceived)))
    try {
        PanelHostEnsure(NotesHost)
        NotesConfigureMediaMapping()
        return true
    } catch as webViewError {
        PanelHostHide(NotesHost)
        ShowMsg("笔记页面初始化失败：" . webViewError.Message, 5000)
        return false
    }
}

NotesConfigureMediaMapping() {
    global NotesHost, NotesStoreMedia, NotesStoreError
    if !IsObject(NotesHost) || !IsObject(NotesHost["webView"])
        return false
    if !NotesStoreInit()
        throw Error(NotesStoreError != "" ? NotesStoreError : "笔记数据目录不可用")
    NotesHost["webView"].SetVirtualHostNameToFolderMapping(
        "qbar-notes.local", NotesStoreMedia, WebView2.HOST_RESOURCE_ACCESS_KIND.ALLOW)
    return true
}

NotesNavigationCompleted(host, sender, args) {
    global NotesVisible
    if !PanelHostPageReady(host) {
        try ShowMsg("笔记页面加载失败（" . args.WebErrorStatus . "）。", 4000)
        return
    }
    NotesConfigureMediaMapping()
    NotesScheduleStateSync()
}

NotesResize(gui, minMax, width, height) {
    global NotesHost
    PanelHostResize(NotesHost, minMax)
}

NotesEscape(*) {
    global NotesEditorId, NotesEditorSaving
    if NotesEditorSaving
        return
    if NotesEditorId != "" {
        NotesPost(Map("type", "confirmCancel"))
        return
    }
    NotesHide()
}

NotesSendInitialState() {
    global NotesPendingSearch, NotesCurrentTag, NotesStateSyncAttempts
    if !NotesVisible
        return
    if !PanelHostPageReady(NotesHost) {
        NotesStateSyncAttempts += 1
        if NotesStateSyncAttempts <= 10
            SetTimer(NotesSendInitialState, -50)
        else
            DebugLog("notes page state sync timed out")
        return
    }
    NotesStateSyncAttempts := 0
    NotesPost(Map("type", "hostState", "language", IsChineseLanguage() ? "zh" : "en"))
    NotesSendTags()
    NotesSendList(NotesPendingSearch, NotesCurrentTag)
}

NotesScheduleStateSync() {
    global NotesStateSyncAttempts
    NotesStateSyncAttempts := 0
    SetTimer(NotesSendInitialState, 0)
    SetTimer(NotesSendInitialState, -1)
}

NotesSendTags() {
    global NotesCurrentTag, NotesStoreError
    tags := NotesStoreTagList()
    NotesPost(Map("type", "setTags", "tags", tags, "current", NotesCurrentTag,
        "error", NotesStoreError))
}

NotesSendList(searchText := "", tagName := "") {
    global NotesQuerySeq, NotesPendingSearch, NotesCurrentTag, NotesStoreError
    if !NotesVisible
        return
    NotesPendingSearch := String(searchText)
    NotesCurrentTag := String(tagName)
    NotesQuerySeq += 1
    rows := NotesStoreList(NotesPendingSearch, NotesCurrentTag)
    listError := ""
    if !IsObject(rows) {
        listError := NotesStoreError
        rows := []
    }
    NotesPost(Map("type", "setNotes", "notes", rows, "search", NotesPendingSearch, "tag", NotesCurrentTag,
        "error", listError))
}

NotesBeginEdit(noteId := "") {
    global NotesEditorCounter, NotesEditorId, NotesEditorNoteId, NotesEditorSaving, NotesSaveResults
    if NotesEditorSaving
        return false
    if NotesEditorId != ""
        NotesCancelEditorAssets(NotesEditorId)
    NotesEditorCounter += 1
    NotesEditorId := "editor-" . A_TickCount . "-" . NotesEditorCounter
    NotesEditorNoteId := String(noteId)
    NotesEditorSaving := false
    NotesSaveResults := Map()
    note := noteId = "" ? Map(
        "id", 0, "title", "", "content", "", "pinned", false,
        "tags", [], "assets", []) : NotesStoreReadNote(noteId)
    if !IsObject(note)
        note := Map("id", 0, "title", "", "content", "", "pinned", false,
            "tags", [], "assets", [])
    payload := Map(
        "editorId", NotesEditorId,
        "noteId", note["id"],
        "title", note["title"],
        "content", note["content"],
        "tags", note["tags"],
        "assets", note["assets"])
    NotesPost(Map("type", "openEditor", "editor", payload))
    return true
}

NotesHandleSave(msg) {
    global NotesEditorId, NotesEditorNoteId, NotesEditorSaving, NotesSaveResults, NotesStoreError
    global NotesPendingSearch, NotesCurrentTag
    editorId := LLMMsgField(msg, "editorId")
    if editorId = ""
        return
    seqValid := false
    saveSeq := LLMMsgNumber(msg, "saveSeq", &seqValid, 0, true)
    if !seqValid
        return
    key := editorId . ":" . Integer(saveSeq)
    if NotesSaveResults.Has(key) {
        NotesPost(NotesSaveResults[key])
        return
    }
    if editorId != NotesEditorId || NotesEditorSaving
        return
    title := LLMMsgField(msg, "title")
    content := LLMMsgField(msg, "content")
    tags := NotesMessageArray(msg, "tags")
    noteId := LLMMsgField(msg, "noteId")
    if noteId = ""
        noteId := NotesEditorNoteId
    NotesEditorSaving := true
    savedId := 0
    ok := NotesStoreSaveNote(noteId, title, content, tags, editorId, &savedId)
    result := ok
        ? Map("type", "saveResult", "ok", JSON.true,
            "saveSeq", Integer(saveSeq), "noteId", savedId)
        : Map("type", "saveResult", "ok", JSON.false,
            "saveSeq", Integer(saveSeq), "error", NotesStoreError)
    NotesSaveResults[key] := result
    NotesPost(result)
    NotesEditorSaving := false
    if ok {
        NotesEditorId := ""
        NotesEditorNoteId := String(savedId)
        NotesSendTags()
        NotesSendList(NotesPendingSearch, NotesCurrentTag)
    }
}

NotesHandleAssetStart(msg) {
    global NotesHost, NotesEditorId, NotesPendingAssets
    editorId := LLMMsgField(msg, "editorId")
    requestId := LLMMsgField(msg, "requestId")
    if editorId = "" || editorId != NotesEditorId || requestId = ""
        return
    mime := LLMMsgField(msg, "mime")
    originalName := LLMMsgField(msg, "name")
    asset := NotesCreatePendingAsset(editorId, requestId, mime, originalName)
    if !IsObject(asset) {
        NotesPost(Map("type", "assetWriteResult", "editorId", editorId, "requestId", requestId,
            "assetId", "", "ok", JSON.false, "error", "无法创建图片文件"))
        return
    }
    try {
        env := NotesHost["webView"].Environment
        handle := env.CreateWebFileSystemFileHandle(asset["path"], WebView2.FILE_SYSTEM_HANDLE_PERMISSION.READ_WRITE)
        objects := env.CreateObjectCollection([handle])
        payload := Map("type", "assetHandle", "editorId", editorId, "requestId", requestId,
            "assetId", asset["id"], "url", NotesAssetUrl(asset["id"], asset["mime"]))
        NotesHost["webView"].PostWebMessageAsJsonWithAdditionalObjects(JSON.stringify(payload, 0), objects)
    } catch as handleError {
        NotesPendingAssets.Delete(asset["id"])
        try FileDelete(asset["path"])
        NotesPost(Map("type", "assetWriteResult", "editorId", editorId, "requestId", requestId,
            "assetId", asset["id"], "ok", JSON.false, "error", handleError.Message))
    }
}

NotesHandleAssetWritten(msg) {
    global NotesPendingAssets
    editorId := LLMMsgField(msg, "editorId")
    requestId := LLMMsgField(msg, "requestId")
    assetId := LLMMsgField(msg, "assetId")
    ok := NotesMessageBool(msg, "ok", false)
    if !NotesPendingAssets.Has(assetId)
        return
    asset := NotesPendingAssets[assetId]
    if asset["editorId"] != editorId || asset["requestId"] != requestId
        return
    if !ok {
        try FileDelete(asset["path"])
        NotesPendingAssets.Delete(assetId)
        NotesPost(Map("type", "assetWriteResult", "editorId", editorId, "requestId", requestId,
            "assetId", assetId, "ok", JSON.false, "error", "图片写入失败"))
        return
    }
    asset["state"] := "ready"
    NotesPost(Map("type", "assetWriteResult", "editorId", editorId, "requestId", requestId,
        "assetId", assetId, "url", NotesAssetUrl(assetId, asset["mime"]), "ok", JSON.true))
}

NotesHandleCancelEdit(editorId) {
    global NotesEditorId, NotesEditorNoteId, NotesEditorSaving
    if editorId = "" || editorId != NotesEditorId || NotesEditorSaving
        return
    NotesCancelEditorAssets(editorId)
    NotesEditorId := ""
    NotesEditorNoteId := ""
    NotesPost(Map("type", "cancelResult", "ok", JSON.true))
}

NotesHandleMessage(msg) {
    global NotesCurrentTag, NotesPendingSearch
    messageType := LLMMsgField(msg, "type")
    switch messageType {
        case "ready":
            NotesScheduleStateSync()
        case "query":
            NotesSendList(LLMMsgField(msg, "text"), LLMMsgField(msg, "tag"))
        case "beginEdit":
            NotesBeginEdit(LLMMsgField(msg, "noteId"))
        case "saveNote":
            SetTimer(NotesHandleSave.Bind(msg), -1)
        case "cancelEdit":
            NotesHandleCancelEdit(LLMMsgField(msg, "editorId"))
        case "assetStart":
            SetTimer(NotesHandleAssetStart.Bind(msg), -1)
        case "assetWritten":
            NotesHandleAssetWritten(msg)
        case "assetCancel":
            NotesHandleAssetCancel(msg)
        case "copyLine":
            NotesHandleCopyLine(msg)
        case "pasteLine":
            NotesHandlePasteLine(msg)
        case "copyNotes":
            NotesHandleCopyNotes(msg)
        case "pasteNote":
            NotesHandlePasteNote(LLMMsgField(msg, "noteId"))
        case "deleteNotes":
            NotesHandleDelete(NotesMessageArray(msg, "noteIds"))
        case "setPinned":
            NotesHandlePinned(NotesMessageArray(msg, "noteIds"), NotesMessageBool(msg, "value", false))
        case "tagFilter":
            NotesCurrentTag := LLMMsgField(msg, "tag")
            NotesSendList(NotesPendingSearch, NotesCurrentTag)
        case "addTag":
            NotesStoreAddTag(LLMMsgField(msg, "name"))
            NotesSendTags()
            NotesSendList(NotesPendingSearch, NotesCurrentTag)
        case "renameTag":
            NotesStoreRenameTag(LLMMsgField(msg, "tagId"), LLMMsgField(msg, "name"))
            NotesSendTags()
            NotesSendList(NotesPendingSearch, NotesCurrentTag)
        case "deleteTag":
            NotesStoreDeleteTag(LLMMsgField(msg, "tagId"))
            NotesSendTags()
            NotesSendList(NotesPendingSearch, NotesCurrentTag)
        case "cursorMove":
            ; WebView2 does not always replay the native cursor after Windows'
            ; mouse-vanish-on-typing behavior. Restore it on page mouse moves,
            ; matching the behavior of native edit controls.
            ShowSystemCursor()
        case "hide":
            NotesHide()
    }
}

NotesHandleAssetCancel(msg) {
    global NotesPendingAssets
    editorId := LLMMsgField(msg, "editorId")
    requestId := LLMMsgField(msg, "requestId")
    assetId := LLMMsgField(msg, "assetId")
    if editorId = "" && requestId = "" && assetId = ""
        return
    matches := []
    for candidateId, asset in NotesPendingAssets {
        if editorId != "" && asset["editorId"] != editorId
            continue
        if requestId != "" && asset["requestId"] != requestId
            continue
        if assetId != "" && candidateId != assetId
            continue
        matches.Push(candidateId)
    }
    for candidateId in matches {
        asset := NotesPendingAssets[candidateId]
        try FileDelete(asset["path"])
        NotesPendingAssets.Delete(candidateId)
    }
}

NotesHandleCopyLine(msg) {
    line := NotesStoreCopyLine(LLMMsgField(msg, "noteId"), LLMMsgField(msg, "text"))
    if line = "" {
        NotesPost(Map("type", "actionResult", "action", "copyLine", "ok", JSON.false, "error", "内容已变化"))
        return
    }
    NotesSetClipboard(line)
    NotesPost(Map("type", "actionResult", "action", "copyLine", "ok", JSON.true))
}

NotesHandlePasteLine(msg) {
    global NotesTargetHwnd
    line := NotesStoreCopyLine(LLMMsgField(msg, "noteId"), LLMMsgField(msg, "text"))
    if line = ""
        return
    NotesHide()
    NotesPasteToTarget(line, NotesTargetHwnd)
}

NotesHandleCopyNotes(msg) {
    ids := NotesMessageArray(msg, "noteIds")
    output := ""
    for noteId in ids {
        note := NotesStoreReadNote(noteId)
        if !IsObject(note)
            continue
        part := NotesCopyTextForExternal(note)
        if part = ""
            continue
        if output != ""
            output .= "`n`n---`n`n"
        output .= part
    }
    NotesSetClipboard(output)
    NotesPost(Map("type", "actionResult", "action", "copy", "ok", JSON.true))
}

NotesHandlePasteNote(noteId) {
    global NotesTargetHwnd
    note := NotesStoreReadNote(noteId)
    if !IsObject(note)
        return
    NotesHide()
    NotesPasteToTarget(NotesCopyTextForExternal(note), NotesTargetHwnd)
}

NotesHandleDelete(ids) {
    global NotesStoreError, NotesPendingSearch, NotesCurrentTag
    ok := NotesStoreDeleteNotes(ids)
    NotesPost(Map("type", "actionResult", "action", "delete", "ok", ok ? JSON.true : JSON.false,
        "error", ok ? "" : NotesStoreError))
    if ok {
        NotesSendTags()
        NotesSendList(NotesPendingSearch, NotesCurrentTag)
    }
}

NotesHandlePinned(ids, value) {
    global NotesStoreError, NotesPendingSearch, NotesCurrentTag
    ok := NotesStoreSetPinned(ids, value)
    NotesPost(Map("type", "actionResult", "action", "pin", "ok", ok ? JSON.true : JSON.false,
        "error", ok ? "" : NotesStoreError))
    if ok
        NotesSendList(NotesPendingSearch, NotesCurrentTag)
}

NotesMessageArray(msg, key) {
    result := []
    if !IsObject(msg) || !msg.Has(key) || Type(msg[key]) != "Array"
        return result
    for value in msg[key] {
        if Type(value) = "String" || Type(value) = "Integer"
            result.Push(String(value))
    }
    return result
}

NotesMessageBool(msg, key, fallback := false) {
    if !IsObject(msg) || !msg.Has(key)
        return fallback
    value := msg[key]
    if Type(value) = "ComValue" {
        try return value == JSON.true
        catch
            return fallback
    }
    if Type(value) = "Integer"
        return value != 0
    return StrLower(String(value)) = "true" || String(value) = "1"
}

NotesPost(payload) {
    global NotesHost
    if !IsObject(NotesHost) || !IsObject(NotesHost["webView"])
        return false
    try {
        NotesHost["webView"].PostWebMessageAsJson(JSON.stringify(payload, 0))
        return true
    } catch as postError {
        DebugLog("notes page message failed: " . postError.Message)
        return false
    }
}

NotesWebMessageReceived(sender, args) {
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    if !IsObject(msg)
        return
    NotesHandleMessage(msg)
}

NotesShutdown(*) {
    global NotesHost, NotesVisible, NotesEditorId, NotesStateSyncAttempts
    NotesVisible := false
    NotesStateSyncAttempts := 0
    SetTimer(NotesSendInitialState, 0)
    if NotesEditorId != ""
        NotesCancelEditorAssets(NotesEditorId)
    NotesEditorId := ""
    PanelHostDestroy(NotesHost)
    NotesHost := 0
    NotesStoreClose()
}
