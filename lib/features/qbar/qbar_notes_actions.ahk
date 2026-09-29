; QBar notes file assets, clipboard helpers, and WebView2 file handles.

NotesAssetUrl(assetId, mime := "") {
    if !RegExMatch(String(assetId), "^[A-Za-z0-9_-]+$")
        return ""
    extension := mime = "" ? "" : "." . NotesAssetExtension(mime)
    return "https://qbar-notes.local/" . assetId . extension
}

NotesAssetExtension(mime) {
    switch StrLower(Trim(String(mime))) {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/bmp":
            return "bmp"
        case "image/svg+xml":
            return "svg"
        case "image/avif":
            return "avif"
        case "image/tiff":
            return "tiff"
        case "image/x-icon":
            return "ico"
        case "image/heic":
            return "heic"
        case "image/heif":
            return "heif"
        default:
            return "bin"
    }
}

NotesNewAssetId() {
    return FormatTime(A_NowUTC, "yyyyMMddHHmmss") . "-" . A_TickCount . "-" . Random(10000, 99999)
}

NotesCreatePendingAsset(editorId, requestId, mime, originalName) {
    global NotesPendingAssets, NotesStoreMedia
    if editorId = "" || requestId = ""
        return 0
    if !NotesStoreInit()
        return 0
    assetId := NotesNewAssetId()
    extension := NotesAssetExtension(mime)
    path := NotesStoreMedia . "\" . assetId . "." . extension
    try {
        fileHandle := FileOpen(path, "w")
        fileHandle.Close()
    } catch {
        return 0
    }
    relativePath := "media\" . assetId . "." . extension
    asset := Map(
        "id", assetId,
        "editorId", editorId,
        "requestId", requestId,
        "path", path,
        "relativePath", relativePath,
        "mime", String(mime),
        "name", String(originalName),
        "state", "pending",
        "noteId", 0)
    NotesPendingAssets[assetId] := asset
    return asset
}

NotesAssetIdsFromMarkdown(content) {
    ids := []
    seen := Map()
    pos := 1
    while RegExMatch(String(content), "asset:([A-Za-z0-9_-]+)", &match, pos) {
        id := match[1]
        if !seen.Has(id) {
            seen[id] := true
            ids.Push(id)
        }
        pos := match.Pos + match.Len
    }
    return ids
}

NotesValidateAssetReferences(noteId, editorId, assetIds) {
    global NotesPendingAssets, NotesStoreError
    for assetId in assetIds {
        if NotesPendingAssets.Has(assetId) {
            pending := NotesPendingAssets[assetId]
            if pending["editorId"] != editorId || pending["state"] != "ready" {
                NotesStoreError := "图片尚未写入完成"
                return false
            }
            continue
        }
        if noteId = "" || !IsObject(NotesStoreGetNoteAsset(noteId, assetId)) {
            NotesStoreError := "图片资产不存在或不属于当前笔记"
            return false
        }
    }
    return true
}

NotesAssetForSave(assetId, noteId, editorId, oldAssetMap := 0) {
    global NotesPendingAssets
    if NotesPendingAssets.Has(assetId) {
        pending := NotesPendingAssets[assetId]
        if pending["editorId"] = editorId && pending["state"] = "ready"
            return pending
        return 0
    }
    if IsObject(oldAssetMap) && oldAssetMap.Has(assetId)
        return oldAssetMap[assetId]
    return NotesStoreGetNoteAsset(noteId, assetId)
}

NotesFinalizeAssets(editorId, referenced, noteId) {
    global NotesPendingAssets
    keep := Map()
    for assetId in referenced
        keep[assetId] := true
    toDelete := []
    editorAssets := []
    for assetId, asset in NotesPendingAssets
        if asset["editorId"] = editorId
            editorAssets.Push(assetId)
    for assetId in editorAssets {
        asset := NotesPendingAssets[assetId]
        if asset["editorId"] != editorId
            continue
        if keep.Has(assetId) {
            NotesPendingAssets.Delete(assetId)
        } else {
            toDelete.Push(asset["path"])
            NotesPendingAssets.Delete(assetId)
        }
    }
    for path in toDelete
        try FileDelete(path)
}

NotesCancelEditorAssets(editorId) {
    global NotesPendingAssets
    editorAssets := []
    for assetId, asset in NotesPendingAssets
        if asset["editorId"] = editorId
            editorAssets.Push(assetId)
    for assetId in editorAssets {
        asset := NotesPendingAssets[assetId]
        try FileDelete(asset["path"])
        NotesPendingAssets.Delete(assetId)
    }
}

NotesDeleteRelativeAsset(relativePath) {
    global NotesStoreRoot
    relativePath := StrReplace(String(relativePath), "/", "\")
    if relativePath = "" || InStr(relativePath, "..")
        return false
    path := NotesStoreRoot . "\" . relativePath
    if FileExist(path)
        try FileDelete(path)
    return !FileExist(path)
}

NotesStoreCleanOrphans() {
    global NotesStoreMedia, NotesPendingAssets, NotesDB, NotesDBReady
    if !IsObject(NotesDB) || !NotesDBReady || !DirExist(NotesStoreMedia)
        return false
    referenced := Map()
    if !NotesStoreQuery("SELECT relative_path FROM note_assets;", &table)
        return false
    for row in table.Rows
        referenced[StrReplace(row[1], "/", "\")] := true
    pendingPaths := Map()
    for assetId, asset in NotesPendingAssets
        pendingPaths[asset["relativePath"]] := true
    Loop Files, NotesStoreMedia . "\*", "F" {
        relative := "media\" . A_LoopFileName
        if referenced.Has(relative) || pendingPaths.Has(relative)
            continue
        try FileDelete(A_LoopFileFullPath)
    }
    return true
}

NotesSetClipboard(text) {
    global A_Clipboard, ClipboardWatcherSuspended, WhichClipboardNow
    previous := ClipboardWatcherSuspended
    ClipboardWatcherSuspended := true
    try {
        A_Clipboard := String(text)
        WhichClipboardNow := 0
    } finally {
        ClipboardWatcherSuspended := previous
    }
}

NotesPasteToTarget(text, targetHwnd := 0) {
    global A_Clipboard, ClipboardWatcherSuspended, WhichClipboardNow
    if text = ""
        return false
    previous := ClipboardWatcherSuspended
    ClipboardWatcherSuspended := true
    oldClipboard := ClipboardAll()
    ownedSequence := 0
    try {
        if targetHwnd && !WinExist("ahk_id " . targetHwnd)
            return false
        if targetHwnd {
            WinActivate("ahk_id " . targetHwnd)
            if !WinWaitActive("ahk_id " . targetHwnd, , 0.4)
                return false
        }
        A_Clipboard := text
        ownedSequence := ClipboardSequenceNumber()
        SendInput("^v")
        Sleep(60)
        WhichClipboardNow := 0
        return !targetHwnd || WinActive("ahk_id " . targetHwnd)
    } finally {
        if ownedSequence && ClipboardSequenceNumber() = ownedSequence
            A_Clipboard := oldClipboard
        ClipboardWatcherSuspended := previous
    }
}

NotesCopyTextForExternal(note) {
    if !IsObject(note)
        return ""
    title := Trim(String(note["title"]))
    content := NotesExternalizeMarkdown(note["content"])
    return (title != "" ? "# " . title . "`n`n" : "") . content
}

NotesExternalizeMarkdown(content) {
    return RegExReplace(String(content), "!\[([^\]]*)\]\(asset:[^\)]*\)", "[$1]")
}
