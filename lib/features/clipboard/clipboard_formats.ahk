; Clipboard format capture and restoration.
;
; History stores a validated ClipboardAll-compatible buffer instead of opaque
; handles. Registered format names are persisted in the manifest and are
; registered again when a history item is restored in a later process.

global ClipboardHistoryMaxTextBytes := 32 * 1024 * 1024
global ClipboardHistoryMaxImageBytes := 128 * 1024 * 1024
global ClipboardHistoryImagePreviewCache := Map()
global ClipboardHistoryImagePreviewCacheOrder := []
global ClipboardHistoryImagePreviewCacheBytes := 0
global ClipboardHistoryImagePreviewCacheMaxBytes := 32 * 1024 * 1024

ClipboardHistoryCaptureCurrent(sequence := 0, maxBytes := 0) {
    global ClipboardHistoryMaxTextBytes, ClipboardHistoryMaxImageBytes
    record := 0
    if !DllCall("user32\OpenClipboard", "ptr", 0)
        return 0
    try {
        formats := ClipboardHistoryEnumerateFormats()
        if !formats["hasAny"]
            return 0

        if ClipboardHistoryHasExcludeMarker(formats)
            return 0
        if ClipboardHistoryHasCanIncludeMarker(formats) = false
            return 0

        maxBytes := maxBytes > 0 ? maxBytes : 256 * 1024 * 1024
        entries := []
        unicodeId := formats["unicode"]
        if unicodeId {
            if ClipboardHistoryReadFormat(unicodeId, ClipboardHistoryMaxTextBytes, &textData)
                entries.Push(Map("id", unicodeId, "name", "", "kind", "text", "data", textData))
        } else if formats["text"] {
            if ClipboardHistoryReadFormat(formats["text"], ClipboardHistoryMaxTextBytes, &textData)
                entries.Push(Map("id", formats["text"], "name", "", "kind", "text", "data", textData))
        }

        if formats["files"] {
            if ClipboardHistoryReadFormat(formats["files"], ClipboardHistoryMaxTextBytes, &fileData)
                entries.Push(Map("id", formats["files"], "name", "", "kind", "files", "data", fileData))
        }

        imageCandidates := []
        if formats["png"]
            imageCandidates.Push(Map("id", formats["png"], "name", formats["pngName"]))
        if formats["dibv5"]
            imageCandidates.Push(Map("id", formats["dibv5"], "name", ""))
        if formats["dib"]
            imageCandidates.Push(Map("id", formats["dib"], "name", ""))
        for candidate in imageCandidates {
            if !ClipboardHistoryReadFormat(candidate["id"], ClipboardHistoryMaxImageBytes, &imageData)
                continue
            if !ClipboardHistoryImageCandidateValid(candidate["id"], imageData)
                continue
            entries.Push(Map("id", candidate["id"], "name", candidate["name"],
                "kind", "image", "data", imageData))
            break
        }

        if formats["html"] {
            if ClipboardHistoryReadFormat(formats["html"], ClipboardHistoryMaxTextBytes, &htmlData)
                entries.Push(Map("id", formats["html"], "name", formats["htmlName"], "kind", "rich", "data", htmlData))
        }
        if formats["rtf"] {
            if ClipboardHistoryReadFormat(formats["rtf"], ClipboardHistoryMaxTextBytes, &rtfData)
                entries.Push(Map("id", formats["rtf"], "name", formats["rtfName"], "kind", "rich", "data", rtfData))
        }
        if !entries.Length
            return 0

        record := ClipboardHistoryBuildRecord(entries, sequence)
        if !IsObject(record)
            return 0
        if maxBytes > 0 && record["byteSize"] > maxBytes
            return 0
        return record
    } finally {
        DllCall("user32\CloseClipboard")
    }
}

; Builds the same whitelist from a ClipboardAll() buffer already captured by
; the system-slot branch. This path deliberately never opens the clipboard or
; calls GetClipboardData(); it only copies the selected blocks out of the
; stable snapshot reference.
ClipboardHistoryCaptureSnapshot(snapshot, sequence := 0, maxBytes := 0, formatContext := 0) {
    maxBytes := maxBytes > 0 ? maxBytes : 256 * 1024 * 1024
    entries := ClipboardHistoryParseClipboardSnapshot(snapshot, maxBytes)
    if !entries.Length
        return 0
    formats := ClipboardHistorySnapshotFormatMap(entries)
    formats["entries"] := entries
    if ClipboardHistorySnapshotHasExcludeMarker(formats)
        return 0
    if ClipboardHistorySnapshotCanInclude(formats) = false
        return 0

    allowed := ClipboardHistorySnapshotAllowedEntries(entries, formats)
    if !allowed.Length
        return 0
    record := ClipboardHistoryBuildRecord(allowed, sequence)
    if !IsObject(record) || record["byteSize"] > maxBytes
        return 0
    return record
}

ClipboardHistoryParseClipboardSnapshot(snapshot, maxBytes := 0) {
    entries := []
    if !IsObject(snapshot) || snapshot.Size < 4
        return entries
    maxBytes := maxBytes > 0 ? maxBytes : 512 * 1024 * 1024
    if snapshot.Size > maxBytes
        return entries

    offset := 0
    formatCount := 0
    while offset + 4 <= snapshot.Size {
        formatId := NumGet(snapshot, offset, "uint")
        offset += 4
        if !formatId
            return entries
        if offset + 4 > snapshot.Size
            return []
        dataBytes := NumGet(snapshot, offset, "uint")
        offset += 4
        if offset + dataBytes > snapshot.Size
            return []
        name := ClipboardHistoryFormatName(formatId)
        if !ClipboardHistorySnapshotFormatCandidate(formatId, name) {
            offset += dataBytes
            continue
        }
        if dataBytes > maxBytes
            return []
        data := Buffer(dataBytes, 0)
        if dataBytes
            DllCall("Kernel32\RtlMoveMemory", "ptr", data.Ptr,
                "ptr", snapshot.Ptr + offset, "uptr", dataBytes)
        offset += dataBytes
        formatCount += 1
        if formatCount > 64
            return []
        entries.Push(Map("id", formatId, "name", name, "kind", "raw", "data", data))
    }
    return []
}

ClipboardHistorySnapshotFormatCandidate(formatId, name) {
    if formatId = 1 || formatId = 8 || formatId = 13 || formatId = 15 || formatId = 17
        return true
    lowered := StrLower(String(name))
    return lowered = "png" || lowered = "html format" || lowered = "rich text format"
        || lowered = "excludeclipboardcontentfrommonitorprocessing"
        || lowered = "canincludeinclipboardhistory"
}

ClipboardHistorySnapshotFormatMap(entries) {
    result := Map(
        "unicode", 0, "text", 0, "files", 0,
        "png", 0, "pngName", "", "dibv5", 0, "dib", 0,
        "html", 0, "htmlName", "", "rtf", 0, "rtfName", "",
        "exclude", 0, "canInclude", 0, "hasAny", false)
    for entry in entries {
        formatId := entry["id"]
        name := String(entry["name"])
        lowered := StrLower(name)
        if formatId = 13
            result["unicode"] := formatId
        else if formatId = 1 && !result["text"]
            result["text"] := formatId
        else if formatId = 15
            result["files"] := formatId
        else if formatId = 17
            result["dibv5"] := formatId
        else if formatId = 8
            result["dib"] := formatId

        if lowered = "png" {
            result["png"] := formatId
            result["pngName"] := name
        } else if lowered = "html format" {
            result["html"] := formatId
            result["htmlName"] := name
        } else if lowered = "rich text format" {
            result["rtf"] := formatId
            result["rtfName"] := name
        } else if lowered = "excludeclipboardcontentfrommonitorprocessing"
            result["exclude"] := formatId
        else if lowered = "canincludeinclipboardhistory"
            result["canInclude"] := formatId
    }
    return result
}

ClipboardHistorySnapshotEntry(entries, formatId) {
    for entry in entries
        if entry["id"] = formatId
            return entry
    return 0
}

ClipboardHistorySnapshotHasExcludeMarker(formats) {
    entry := formats["exclude"] ? ClipboardHistorySnapshotEntry(formats["entries"], formats["exclude"]) : 0
    return IsObject(entry) && ClipboardHistorySnapshotDword(entry) != 0
}

ClipboardHistorySnapshotCanInclude(formats) {
    if !formats["canInclude"]
        return true
    entry := ClipboardHistorySnapshotEntry(formats["entries"], formats["canInclude"])
    value := IsObject(entry) ? ClipboardHistorySnapshotDword(entry) : -1
    return value > 0
}

ClipboardHistorySnapshotDword(entry) {
    if !IsObject(entry) || !IsObject(entry["data"]) || entry["data"].Size < 4
        return -1
    return NumGet(entry["data"], 0, "uint")
}

ClipboardHistorySnapshotAllowedEntries(entries, formats) {
    allowed := []
    if formats["unicode"] {
        entry := ClipboardHistorySnapshotEntry(entries, formats["unicode"])
        if IsObject(entry) {
            entry["kind"] := "text"
            allowed.Push(entry)
        }
    } else if formats["text"] {
        entry := ClipboardHistorySnapshotEntry(entries, formats["text"])
        if IsObject(entry) {
            entry["kind"] := "text"
            allowed.Push(entry)
        }
    }
    if formats["files"] {
        entry := ClipboardHistorySnapshotEntry(entries, formats["files"])
        if IsObject(entry) {
            entry["kind"] := "files"
            allowed.Push(entry)
        }
    }
    for imageId in [formats["png"], formats["dibv5"], formats["dib"]] {
        if !imageId
            continue
        entry := ClipboardHistorySnapshotEntry(entries, imageId)
        if IsObject(entry) && ClipboardHistoryImageCandidateValid(imageId, entry["data"]) {
            entry["kind"] := "image"
            allowed.Push(entry)
            break
        }
    }
    if formats["html"] {
        entry := ClipboardHistorySnapshotEntry(entries, formats["html"])
        if IsObject(entry) {
            entry["kind"] := "rich"
            allowed.Push(entry)
        }
    }
    if formats["rtf"] {
        entry := ClipboardHistorySnapshotEntry(entries, formats["rtf"])
        if IsObject(entry) {
            entry["kind"] := "rich"
            allowed.Push(entry)
        }
    }
    return allowed
}

ClipboardHistoryEnumerateFormats() {
    result := Map(
        "unicode", 0, "text", 0, "files", 0,
        "png", 0, "pngName", "", "dibv5", 0, "dib", 0,
        "html", 0, "htmlName", "", "rtf", 0, "rtfName", "",
        "exclude", 0, "canInclude", 0, "hasAny", false)
    formatId := 0
    Loop {
        formatId := DllCall("user32\EnumClipboardFormats", "uint", formatId, "uint")
        if !formatId
            break
        result["hasAny"] := true
        name := ClipboardHistoryFormatName(formatId)
        lowered := StrLower(name)
        if formatId = 13
            result["unicode"] := formatId
        else if formatId = 1 && !result["text"]
            result["text"] := formatId
        else if formatId = 15
            result["files"] := formatId
        else if formatId = 17
            result["dibv5"] := formatId
        else if formatId = 8
            result["dib"] := formatId

        if lowered = "png" {
            result["png"] := formatId
            result["pngName"] := name
        } else if lowered = "html format" {
            result["html"] := formatId
            result["htmlName"] := name
        } else if lowered = "rich text format" {
            result["rtf"] := formatId
            result["rtfName"] := name
        } else if lowered = "excludeclipboardcontentfrommonitorprocessing"
            result["exclude"] := formatId
        else if lowered = "canincludeinclipboardhistory"
            result["canInclude"] := formatId
    }
    return result
}

ClipboardHistoryFormatName(formatId) {
    if formatId < 0xC000 || formatId > 0xFFFF
        return ""
    nameBuffer := Buffer(512, 0)
    length := DllCall("user32\GetClipboardFormatNameW", "uint", formatId,
        "ptr", nameBuffer.Ptr, "int", 256, "int")
    return length > 0 ? StrGet(nameBuffer, "UTF-16") : ""
}

ClipboardHistoryHasExcludeMarker(formats) {
    return !formats["exclude"] ? false
        : ClipboardHistoryReadDwordFormat(formats["exclude"]) != 0
}

ClipboardHistoryHasCanIncludeMarker(formats) {
    if !formats["canInclude"]
        return true
    return ClipboardHistoryReadDwordFormat(formats["canInclude"]) > 0
}

ClipboardHistoryReadDwordFormat(formatId) {
    if !ClipboardHistoryReadFormat(formatId, 16, &markerBuffer)
        return -1
    return markerBuffer.Size >= 4 ? NumGet(markerBuffer, 0, "uint") : -1
}

ClipboardHistoryReadFormat(formatId, maxBytes, &dataBuffer := 0) {
    dataBuffer := 0
    handle := DllCall("user32\GetClipboardData", "uint", formatId, "ptr")
    if !handle
        return false
    size := DllCall("kernel32\GlobalSize", "ptr", handle, "uptr")
    if size < 0 || size > maxBytes
        return false
    if size = 0 {
        dataBuffer := Buffer(0)
        return true
    }
    locked := DllCall("kernel32\GlobalLock", "ptr", handle, "ptr")
    if !locked
        return false
    try {
        dataBuffer := Buffer(size, 0)
        DllCall("Kernel32\RtlMoveMemory", "ptr", dataBuffer.Ptr, "ptr", locked, "uptr", size)
        return true
    } finally {
        DllCall("kernel32\GlobalUnlock", "ptr", handle)
    }
}

ClipboardHistoryBuildRecord(entries, sequence := 0) {
    validEntries := []
    for entry in entries {
        if entry["kind"] = "files" && !ClipboardHistoryDecodeFiles(entry["data"]).Length
            continue
        validEntries.Push(entry)
    }
    entries := validEntries
    if !entries.Length
        return 0
    textPlain := ""
    files := []
    primaryType := "text"
    isRichText := false
    imageWidth := 0
    imageHeight := 0
    totalBytes := 0
    manifest := []
    for entry in entries {
        data := entry["data"]
        totalBytes += data.Size
        manifest.Push(Map("id", entry["id"], "name", entry["name"], "kind", entry["kind"]))
        if entry["kind"] = "text" {
            textPlain := ClipboardHistoryDecodeText(data, entry["id"] = 13)
        } else if entry["kind"] = "files" {
            files := ClipboardHistoryDecodeFiles(data)
            primaryType := "file"
        } else if entry["kind"] = "image" {
            if primaryType != "file"
                primaryType := "image"
            ClipboardHistoryImageDimensions(entry["id"], data, &imageWidth, &imageHeight)
        } else if entry["kind"] = "rich" {
            isRichText := true
        }
    }
    if files.Length
        primaryType := "file"
    else if textPlain = "" && ClipboardHistoryFormatMapHasValue(manifest, "kind", "image")
        primaryType := "image"
    else
        ; Rich text is intentionally indexed under the text filter. The
        ; isRichText flag and manifest retain the original rich formats.
        primaryType := "text"

    preview := ClipboardHistoryPreview(textPlain, files, primaryType, isRichText)
    searchText := textPlain
    if files.Length
        searchText .= (searchText = "" ? "" : "`n") . ClipboardHistoryJoin(files, "`n")
    if searchText = ""
        searchText := isRichText ? "富文本" : primaryType = "image" ? "图片" : "剪贴板"
    archive := ClipboardHistoryBuildArchive(entries)
    if !IsObject(archive)
        return 0
    totalBytes += archive.Size
    hash := ClipboardHistoryCanonicalHash(entries)
    return Map(
        "snapshot", archive,
        "manifestJson", JSON.stringify(manifest, 0),
        "primaryType", primaryType,
        "isRichText", isRichText,
        "contentHash", hash,
        "textPlain", textPlain,
        "searchText", searchText,
        "previewText", preview,
        "filesJson", JSON.stringify(files, 0),
        "files", files,
        "imageWidth", imageWidth,
        "imageHeight", imageHeight,
        "itemCount", files.Length ? files.Length : 1,
        "byteSize", totalBytes,
        "sequence", sequence)
}

ClipboardHistoryCanonicalHash(entries) {
    parts := []
    total := 0
    for entry in entries {
        nameText := String(entry["name"])
        kindText := String(entry["kind"])
        nameBytes := Buffer(StrPut(nameText, "UTF-8"), 0)
        kindBytes := Buffer(StrPut(kindText, "UTF-8"), 0)
        StrPut(nameText, nameBytes, "UTF-8")
        StrPut(kindText, kindBytes, "UTF-8")
        data := entry["data"]
        parts.Push(Map("name", nameBytes, "kind", kindBytes, "data", data))
        total += 4 + nameBytes.Size + 4 + kindBytes.Size + 4 + data.Size
    }
    canonical := Buffer(total, 0)
    offset := 0
    for part in parts {
        nameBytes := part["name"]
        kindBytes := part["kind"]
        data := part["data"]
        NumPut("uint", nameBytes.Size, canonical, offset)
        offset += 4
        DllCall("Kernel32\RtlMoveMemory", "ptr", canonical.Ptr + offset,
            "ptr", nameBytes.Ptr, "uptr", nameBytes.Size)
        offset += nameBytes.Size
        NumPut("uint", kindBytes.Size, canonical, offset)
        offset += 4
        DllCall("Kernel32\RtlMoveMemory", "ptr", canonical.Ptr + offset,
            "ptr", kindBytes.Ptr, "uptr", kindBytes.Size)
        offset += kindBytes.Size
        NumPut("uint", data.Size, canonical, offset)
        offset += 4
        if data.Size
            DllCall("Kernel32\RtlMoveMemory", "ptr", canonical.Ptr + offset,
                "ptr", data.Ptr, "uptr", data.Size)
        offset += data.Size
    }
    return ClipboardHistoryBufferHash(canonical)
}

ClipboardHistoryImagePreview(id, maxWidth := 640, maxHeight := 360) {
    global ClipboardHistoryImagePreviewCache
    key := String(id)
    if ClipboardHistoryImagePreviewCache.Has(key)
        return ClipboardHistoryImagePreviewCache[key]
    item := ClipboardHistoryStoreGetItem(id)
    preview := IsObject(item)
        ? ClipboardHistoryImagePreviewFromArchive(item["snapshot"], item["manifestJson"], maxWidth, maxHeight)
        : ""
    ClipboardHistoryImagePreviewCacheStore(key, preview)
    return preview
}

ClipboardHistoryImagePreviewCacheStore(key, preview) {
    global ClipboardHistoryImagePreviewCache, ClipboardHistoryImagePreviewCacheOrder
    global ClipboardHistoryImagePreviewCacheBytes, ClipboardHistoryImagePreviewCacheMaxBytes
    previewSize := StrLen(preview)
    if previewSize > ClipboardHistoryImagePreviewCacheMaxBytes {
        preview := ""
        previewSize := 0
    }
    while ClipboardHistoryImagePreviewCacheOrder.Length
        && ClipboardHistoryImagePreviewCacheBytes + previewSize > ClipboardHistoryImagePreviewCacheMaxBytes {
        oldestKey := ClipboardHistoryImagePreviewCacheOrder.RemoveAt(1)
        if ClipboardHistoryImagePreviewCache.Has(oldestKey) {
            ClipboardHistoryImagePreviewCacheBytes -= StrLen(ClipboardHistoryImagePreviewCache[oldestKey])
            ClipboardHistoryImagePreviewCache.Delete(oldestKey)
        }
    }
    ClipboardHistoryImagePreviewCache[key] := preview
    if previewSize {
        ClipboardHistoryImagePreviewCacheOrder.Push(key)
        ClipboardHistoryImagePreviewCacheBytes += previewSize
    }
}

ClipboardHistoryImagePreviewFromArchive(archive, manifestJson, maxWidth, maxHeight) {
    entries := ClipboardHistoryParseArchive(archive, manifestJson)
    if !entries.Length
        return ""

    imageData := 0
    imageKind := ""
    for entry in entries {
        if StrLower(String(entry["name"])) = "png" {
            imageData := entry["data"]
            imageKind := "png"
            break
        }
    }
    if !IsObject(imageData) {
        for entry in entries {
            if entry["id"] = 17 || entry["id"] = 8 {
                imageData := entry["data"]
                imageKind := "dib"
                break
            }
        }
    }
    if !IsObject(imageData) || !IconGdiplusStart()
        return ""

    image := 0
    stream := 0
    if imageKind = "png" {
        hGlobal := DllCall("kernel32\GlobalAlloc", "uint", 0x42,
            "uptr", imageData.Size, "ptr")
        if !hGlobal
            return ""
        locked := DllCall("kernel32\GlobalLock", "ptr", hGlobal, "ptr")
        if !locked {
            DllCall("kernel32\GlobalFree", "ptr", hGlobal)
            return ""
        }
        DllCall("Kernel32\RtlMoveMemory", "ptr", locked, "ptr", imageData.Ptr,
            "uptr", imageData.Size)
        DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)
        if DllCall("ole32\CreateStreamOnHGlobal", "ptr", hGlobal, "int", true,
            "ptr*", &stream, "hresult") != 0 || !stream {
            DllCall("kernel32\GlobalFree", "ptr", hGlobal)
            return ""
        }
        if DllCall("gdiplus\GdipCreateBitmapFromStream", "ptr", stream,
            "ptr*", &image, "int") != 0 || !image {
            ObjRelease(stream)
            return ""
        }
    } else {
        pixelOffset := ClipboardHistoryDibPixelOffset(imageData)
        if pixelOffset < 0
            return ""
        if DllCall("gdiplus\GdipCreateBitmapFromGdiDib", "ptr", imageData.Ptr,
            "ptr", imageData.Ptr + pixelOffset, "ptr*", &image, "int") != 0 || !image
            return ""
    }

    preview := ClipboardHistoryGdipThumbnailUri(image, maxWidth, maxHeight)
    DllCall("gdiplus\GdipDisposeImage", "ptr", image)
    if stream
        ObjRelease(stream)
    return preview
}

ClipboardHistoryDibPixelOffset(data) {
    if !IsObject(data) || data.Size < 40
        return -1
    headerSize := NumGet(data, 0, "uint")
    if headerSize < 40 || headerSize > data.Size
        return -1
    bitCount := NumGet(data, 14, "ushort")
    compression := NumGet(data, 16, "uint")
    offset := headerSize
    if headerSize = 40 && compression = 3
        offset += 12
    else if headerSize = 40 && compression = 6
        offset += 16
    if bitCount <= 8 {
        colors := NumGet(data, 32, "uint")
        if !colors
            colors := 1 << bitCount
        offset += colors * 4
    }
    return offset < data.Size ? offset : -1
}

ClipboardHistoryGdipThumbnailUri(image, maxWidth, maxHeight) {
    width := 0
    height := 0
    if DllCall("gdiplus\GdipGetImageWidth", "ptr", image, "uint*", &width, "int") != 0
        return ""
    if DllCall("gdiplus\GdipGetImageHeight", "ptr", image, "uint*", &height, "int") != 0
        return ""
    if width <= 0 || height <= 0
        return ""
    scale := Min(1, Min(maxWidth / width, maxHeight / height))
    thumbWidth := Max(1, Round(width * scale))
    thumbHeight := Max(1, Round(height * scale))
    thumbnail := 0
    if DllCall("gdiplus\GdipGetImageThumbnail", "ptr", image,
        "uint", thumbWidth, "uint", thumbHeight, "ptr*", &thumbnail,
        "ptr", 0, "ptr", 0, "int") != 0 || !thumbnail
        return ""
    uri := ClipboardHistoryGdipSavePng(thumbnail)
    DllCall("gdiplus\GdipDisposeImage", "ptr", thumbnail)
    return uri
}

ClipboardHistoryGdipSavePng(image) {
    stream := 0
    if DllCall("ole32\CreateStreamOnHGlobal", "ptr", 0, "int", true,
        "ptr*", &stream, "hresult") != 0 || !stream
        return ""
    uri := ""
    try {
        if DllCall("gdiplus\GdipSaveImageToStream", "ptr", image, "ptr", stream,
            "ptr", IconPngClsid(), "ptr", 0, "int") = 0 {
            size := IconStreamSize(stream)
            hGlobal := 0
            if size && DllCall("ole32\GetHGlobalFromStream", "ptr", stream,
                "ptr*", &hGlobal, "hresult") = 0 {
                locked := DllCall("kernel32\GlobalLock", "ptr", hGlobal, "ptr")
                if locked {
                    bytes := Buffer(size, 0)
                    DllCall("Kernel32\RtlMoveMemory", "ptr", bytes, "ptr", locked,
                        "uptr", size)
                    DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)
                    uri := "data:image/png;base64," . IconBase64(bytes)
                }
            }
        }
    } finally {
        ObjRelease(stream)
    }
    return uri
}

ClipboardHistoryDecodeText(dataBuffer, unicode := true) {
    if !IsObject(dataBuffer) || dataBuffer.Size <= 0
        return ""
    try return unicode ? StrGet(dataBuffer, "UTF-16") : StrGet(dataBuffer, "CP0")
    catch
        return ""
}

ClipboardHistoryDecodeFiles(dataBuffer) {
    files := []
    if !IsObject(dataBuffer) || dataBuffer.Size < 20
        return files
    offset := NumGet(dataBuffer, 0, "uint")
    wide := NumGet(dataBuffer, 16, "uint") != 0
    if offset < 20 || offset >= dataBuffer.Size
        return files
    unitBytes := wide ? 2 : 1
    encoding := wide ? "UTF-16" : "CP0"
    position := offset
    terminated := false
    while position + unitBytes <= dataBuffer.Size {
        start := position
        units := 0
        while position + unitBytes <= dataBuffer.Size {
            value := wide ? NumGet(dataBuffer, position, "ushort") : NumGet(dataBuffer, position, "uchar")
            if value = 0
                break
            units += 1
            position += unitBytes
        }
        if position + unitBytes > dataBuffer.Size
            return []
        if units = 0 {
            terminated := true
            break
        }
        text := StrGet(dataBuffer.Ptr + start, units, encoding)
        if text = ""
            return []
        files.Push(text)
        position += unitBytes
    }
    if !terminated
        return []
    return files
}

ClipboardHistoryImageCandidateValid(formatId, imageBuffer) {
    if !IsObject(imageBuffer) || imageBuffer.Size <= 0
        return false
    ClipboardHistoryImageDimensions(formatId, imageBuffer, &width, &height)
    return width > 0 && height > 0
}

ClipboardHistoryImageDimensions(formatId, imageBuffer, &width := 0, &height := 0) {
    width := 0
    height := 0
    if formatId = 17 || formatId = 8 {
        if imageBuffer.Size >= 24 {
            headerSize := NumGet(imageBuffer, 0, "uint")
            if headerSize >= 40 {
                width := Abs(NumGet(imageBuffer, 4, "int"))
                height := Abs(NumGet(imageBuffer, 8, "int"))
            }
        }
    } else if imageBuffer.Size >= 33 && NumGet(imageBuffer, 0, "uchar") = 0x89
        && NumGet(imageBuffer, 1, "uchar") = 0x50
        && NumGet(imageBuffer, 2, "uchar") = 0x4E
        && NumGet(imageBuffer, 3, "uchar") = 0x47
        && ClipboardHistoryUInt32BE(imageBuffer, 8) = 13
        && NumGet(imageBuffer, 12, "uchar") = 0x49
        && NumGet(imageBuffer, 13, "uchar") = 0x48
        && NumGet(imageBuffer, 14, "uchar") = 0x44
        && NumGet(imageBuffer, 15, "uchar") = 0x52 {
        width := ClipboardHistoryUInt32BE(imageBuffer, 16)
        height := ClipboardHistoryUInt32BE(imageBuffer, 20)
    }
}

ClipboardHistoryUInt32BE(dataBuffer, offset) {
    return (NumGet(dataBuffer, offset, "uchar") << 24)
        | (NumGet(dataBuffer, offset + 1, "uchar") << 16)
        | (NumGet(dataBuffer, offset + 2, "uchar") << 8)
        | NumGet(dataBuffer, offset + 3, "uchar")
}

ClipboardHistoryPreview(text, files, primaryType, isRichText := false) {
    if files.Length {
        preview := files[1]
        if files.Length > 1
            preview .= " 等 " . files.Length . " 项"
        return SubStr(preview, 1, 240)
    }
    if text != ""
        return SubStr(RegExReplace(text, "[`r`n]+", " ↵ "), 1, 240)
    return isRichText ? "富文本" : primaryType = "image" ? "图片" : "剪贴板内容"
}

ClipboardHistoryBuildArchive(entries) {
    total := 4
    for entry in entries
        total += 8 + entry["data"].Size
    if total > 256 * 1024 * 1024
        return 0
    archive := Buffer(total, 0)
    offset := 0
    for entry in entries {
        dataBytes := entry["data"].Size
        NumPut("uint", entry["id"], archive, offset)
        NumPut("uint", dataBytes, archive, offset + 4)
        offset += 8
        if dataBytes {
            DllCall("Kernel32\RtlMoveMemory", "ptr", archive.Ptr + offset,
                "ptr", entry["data"].Ptr, "uptr", dataBytes)
            offset += dataBytes
        }
    }
    ; ClipboardAll's public representation terminates with a zero format ID.
    NumPut("uint", 0, archive, offset)
    return archive
}

ClipboardHistoryParseArchive(archive, manifestJson := "") {
    if !IsObject(archive) || archive.Size < 4
        return []
    manifest := []
    if Trim(String(manifestJson)) != "" {
        try parsedManifest := JSON.Parse(manifestJson, false, true)
        catch
            parsedManifest := []
        if Type(parsedManifest) = "Array"
            manifest := parsedManifest
    }
    entries := []
    offset := 0
    count := 0
    terminated := false
    while offset + 4 <= archive.Size {
        formatId := NumGet(archive, offset, "uint")
        offset += 4
        if !formatId {
            terminated := true
            break
        }
        if offset + 4 > archive.Size
            return []
        dataBytes := NumGet(archive, offset, "uint")
        offset += 4
        if dataBytes > 256 * 1024 * 1024 || offset + dataBytes > archive.Size
            return []
        data := Buffer(dataBytes, 0)
        if dataBytes
            DllCall("Kernel32\RtlMoveMemory", "ptr", data.Ptr,
                "ptr", archive.Ptr + offset, "uptr", dataBytes)
        offset += dataBytes
        count += 1
        if count > 64
            return []
        name := ""
        if count <= manifest.Length && IsObject(manifest[count])
            if manifest[count].Has("name")
                name := String(manifest[count]["name"])
        entries.Push(Map("id", formatId, "name", name, "data", data))
    }
    return terminated ? entries : []
}

ClipboardHistoryRestoreArchive(archive, ownerHwnd := 0, manifestJson := "", &restoredArchive := 0) {
    restoredArchive := 0
    entries := ClipboardHistoryParseArchive(archive, manifestJson)
    if !entries.Length
        return false
    if !DllCall("user32\OpenClipboard", "ptr", ownerHwnd)
        return false
    success := false
    try {
        if !DllCall("user32\EmptyClipboard")
            return false
        resolvedEntries := []
        for entry in entries {
            formatId := entry["id"]
            if entry["name"] != ""
                formatId := DllCall("user32\RegisterClipboardFormatW", "wstr", entry["name"], "uint")
            if !formatId
                return false
            if formatId >= 0xC000 && entry["name"] = ""
                return false
            size := entry["data"].Size
            hGlobal := DllCall("kernel32\GlobalAlloc", "uint", 0x42,
                "uptr", Max(1, size), "ptr")
            if !hGlobal
                return false
            locked := size ? DllCall("kernel32\GlobalLock", "ptr", hGlobal, "ptr") : 0
            if size && !locked {
                DllCall("kernel32\GlobalFree", "ptr", hGlobal)
                return false
            }
            if size {
                DllCall("Kernel32\RtlMoveMemory", "ptr", locked,
                    "ptr", entry["data"].Ptr, "uptr", size)
                DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)
            }
            if !DllCall("user32\SetClipboardData", "uint", formatId, "ptr", hGlobal) {
                DllCall("kernel32\GlobalFree", "ptr", hGlobal)
                return false
            }
            resolvedEntries.Push(Map("id", formatId, "name", entry["name"],
                "kind", "raw", "data", entry["data"]))
        }
        restoredArchive := ClipboardHistoryBuildArchive(resolvedEntries)
        if !IsObject(restoredArchive)
            return false
        success := true
    } finally {
        DllCall("user32\CloseClipboard")
    }
    return success
}

ClipboardHistoryBufferHash(dataBuffer) {
    if !IsObject(dataBuffer)
        return ""
    return CryptoDigestHex(CryptoBcryptHash(dataBuffer, dataBuffer.Size, 0, 0))
}

ClipboardHistoryHasManifestKind(manifest, kind) {
    for entry in manifest
        if entry.Has("kind") && entry["kind"] = kind
            return true
    return false
}

ClipboardHistoryJoin(values, delimiter := "`n") {
    result := ""
    for index, value in values
        result .= (index > 1 ? delimiter : "") . String(value)
    return result
}

ClipboardHistoryFormatMapHasValue(values, key, needle) {
    for entry in values
        if entry.Has(key) && entry[key] = needle
            return true
    return false
}
