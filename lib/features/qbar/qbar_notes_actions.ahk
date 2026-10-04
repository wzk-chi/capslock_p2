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

; Deletes media files that no note_assets row and no note references.
;
; This is the only place that removes user media, and it used to compare
; note_assets.relative_path verbatim against "media\<file>" while older builds
; stored an absolute path there, so every image was deleted on the next start.
; Two things keep that from returning: the stored value is normalized before it
; is compared, and a file is also kept when its asset id still appears in some
; note's Markdown, which stays true even if the path column is wrong again.
NotesStoreCleanOrphans() {
    global NotesStoreMedia, NotesPendingAssets, NotesDB, NotesDBReady
    if !IsObject(NotesDB) || !NotesDBReady || !DirExist(NotesStoreMedia)
        return false
    referenced := Map()
    if !NotesStoreQuery("SELECT relative_path FROM note_assets;", &table)
        return false
    for row in table.Rows {
        relative := NotesStoreRelativeAssetPath(row[1])
        if relative != ""
            referenced[relative] := true
    }
    referencedIds := Map()
    if NotesStoreQuery("SELECT content_md FROM notes WHERE content_md LIKE '%asset:%';", &noteTable)
        for row in noteTable.Rows
            for assetId in NotesAssetIdsFromMarkdown(row[1])
                referencedIds[assetId] := true
    pendingPaths := Map()
    for assetId, asset in NotesPendingAssets
        pendingPaths[asset["relativePath"]] := true
    Loop Files, NotesStoreMedia . "\*", "F" {
        fileName := A_LoopFileName
        relative := "media\" . fileName
        if referenced.Has(relative) || pendingPaths.Has(relative)
            continue
        if referencedIds.Has(NotesAssetIdFromFileName(fileName))
            continue
        try FileDelete(A_LoopFileFullPath)
    }
    return true
}

; Asset ids are generated without dots, so the id is everything before the first
; one. Legacy rows may also have been stored without an extension at all.
NotesAssetIdFromFileName(fileName) {
    dot := InStr(fileName, ".")
    return dot ? SubStr(fileName, 1, dot - 1) : String(fileName)
}

; Puts an image file on the clipboard as a bitmap. A_Clipboard only ever carries
; text, so this goes through GDI+ (the token shared with the qbar icon cache)
; and SetClipboardData. The HBITMAP handed to the clipboard becomes the system's
; to own and must not be deleted here.
NotesSetClipboardImage(path, reason := "temporary-paste") {
    global WhichClipboardNow
    if path = "" || !FileExist(path) || !IconGdiplusStart()
        return false
    bitmap := 0
    if DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", path, "ptr*", &bitmap, "int") != 0 || !bitmap
        return false
    handle := 0
    pngData := ClipboardHistoryGdipSavePngBytes(bitmap)
    pngFormat := DllCall("user32\RegisterClipboardFormatW", "wstr", "PNG", "uint")
    pngArchive := 0
    pngGlobal := 0
    if reason = "user-copy" && pngFormat && IsObject(pngData)
        pngArchive := ClipboardHistoryBuildArchive([
            Map("id", pngFormat, "name", "PNG", "kind", "image", "data", pngData)])
    status := DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "ptr", bitmap, "ptr*", &handle,
        "uint", 0xFFFFFFFF, "int")   ; opaque white, so alpha images paste intact
    DllCall("gdiplus\GdipDisposeImage", "ptr", bitmap)
    if status != 0 || !handle {
        if handle
            DllCall("gdi32\DeleteObject", "ptr", handle, "int")
        return false
    }
    if pngFormat && IsObject(pngData) {
        pngGlobal := DllCall("kernel32\GlobalAlloc", "uint", 0x42, "uptr", pngData.Size, "ptr")
        pngLocked := pngGlobal ? DllCall("kernel32\GlobalLock", "ptr", pngGlobal, "ptr") : 0
        if pngLocked {
            DllCall("Kernel32\RtlMoveMemory", "ptr", pngLocked, "ptr", pngData.Ptr, "uptr", pngData.Size)
            DllCall("kernel32\GlobalUnlock", "ptr", pngGlobal)
        } else if pngGlobal {
            DllCall("kernel32\GlobalFree", "ptr", pngGlobal)
            pngGlobal := 0
        }
    }
    if !DllCall("user32\OpenClipboard", "ptr", 0, "int") {
        DllCall("gdi32\DeleteObject", "ptr", handle, "int")
        if pngGlobal
            DllCall("kernel32\GlobalFree", "ptr", pngGlobal)
        return false
    }
    suspendToken := ClipboardSuspendBegin(reason)
    try {
        if !DllCall("user32\EmptyClipboard", "int") {
            DllCall("gdi32\DeleteObject", "ptr", handle, "int")
            return false
        }
        ; CF_BITMAP (2) takes an HBITMAP. CF_DIB (8) is the neighbouring value
        ; and takes a global memory block holding a BITMAPINFO followed by the
        ; bits; handing it a bitmap handle makes every reader -- including this
        ; process' own OnClipboardChange, which snapshots all formats -- treat
        ; the handle as a pointer and corrupts the heap.
        if !DllCall("user32\SetClipboardData", "uint", 2, "ptr", handle, "ptr") {
            DllCall("gdi32\DeleteObject", "ptr", handle, "int")   ; the clipboard refused it, so it is still ours
            if pngGlobal
                DllCall("kernel32\GlobalFree", "ptr", pngGlobal)
            pngGlobal := 0
            return false
        }
        if pngGlobal {
            if DllCall("user32\SetClipboardData", "uint", pngFormat, "ptr", pngGlobal, "ptr")
                pngGlobal := 0
        }
        sequence := ClipboardSequenceNumber()
        ClipboardHistoryMarkOwnedSequence(sequence, reason)
        WhichClipboardNow := 0
        success := true
    } finally {
        DllCall("user32\CloseClipboard", "int")
        ClipboardSuspendEnd(suspendToken)
        if pngGlobal
            DllCall("kernel32\GlobalFree", "ptr", pngGlobal)
    }
    if success && reason = "user-copy" && IsObject(pngArchive)
        ClipboardHistoryPublishExplicit(sequence, pngArchive, reason)
    return success
}

NotesPasteImageToTarget(path, targetHwnd := 0) {
    global A_Clipboard, WhichClipboardNow
    if path = ""
        return false
    suspendToken := ClipboardSuspendBegin("temporary-paste")
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
        if !NotesSetClipboardImage(path)
            return false
        ownedSequence := ClipboardSequenceNumber()
        SendInput("^v")
        Sleep(60)
        WhichClipboardNow := 0
        return !targetHwnd || WinActive("ahk_id " . targetHwnd)
    } finally {
        if ownedSequence && ClipboardSequenceNumber() = ownedSequence {
            A_Clipboard := oldClipboard
            ClipboardHistoryMarkOwnedSequence(ClipboardSequenceNumber(), "temporary-paste")
        }
        ClipboardSuspendEnd(suspendToken)
    }
}

NotesSetClipboard(text, reason := "user-copy") {
    global A_Clipboard, WhichClipboardNow
    sequence := 0
    suspendToken := ClipboardSuspendBegin(reason)
    try {
        A_Clipboard := String(text)
        sequence := ClipboardSequenceNumber()
        ClipboardHistoryMarkOwnedSequence(sequence, reason)
        WhichClipboardNow := 0
    } finally {
        ClipboardSuspendEnd(suspendToken)
    }
    if reason = "user-copy"
        ClipboardHistoryPublishExplicit(sequence, 0, reason)
    return sequence != 0
}

NotesPasteToTarget(text, targetHwnd := 0) {
    global A_Clipboard, WhichClipboardNow
    if text = ""
        return false
    suspendToken := ClipboardSuspendBegin("temporary-paste")
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
        ClipboardHistoryMarkOwnedSequence(ownedSequence, "temporary-paste")
        SendInput("^v")
        Sleep(60)
        WhichClipboardNow := 0
        return !targetHwnd || WinActive("ahk_id " . targetHwnd)
    } finally {
        if ownedSequence && ClipboardSequenceNumber() = ownedSequence {
            A_Clipboard := oldClipboard
            ClipboardHistoryMarkOwnedSequence(ClipboardSequenceNumber(), "temporary-paste")
        }
        ClipboardSuspendEnd(suspendToken)
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
