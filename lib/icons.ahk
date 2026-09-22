; ---------------------------------------------------------------------------
; Shell icons for qbar rows.
;
; An HICON comes from SHGetFileInfoW (the same source Explorer uses), is
; encoded to PNG through GDI+ in a memory IStream, base64'd into a data URI
; and pushed to the page once per key. Nothing touches disk and no temp
; files exist: the whole pipeline lives in DllCalls against system DLLs.
;
; Keys are coarse on purpose so the cache stays small:
;   folder     one generic folder icon (what Explorer shows for plain ones)
;   ext:<ext>  the icon every file with that extension shares, looked up
;              through SHGFI_USEFILEATTRIBUTES (registry only, no disk hit)
;   p:<path>   a per-file icon, for things that own one: executables,
;              shortcuts, installers...
; A failed extraction is cached as "" so a row keeps its type glyph and no
; keystroke pays for the attempt twice.
; ---------------------------------------------------------------------------

global IconCache := Map()        ; key -> data URI, "" marks a failed attempt
global IconSent := Map()         ; keys already pushed to the page
global IconGdiplusToken := 0

; The icon key for a filesystem path: directories all share "folder", files
; with self-owned icons are keyed per path, everything else per extension.
IconKeyForPath(path) {
    static iconOwners := ",exe,lnk,ico,cmd,bat,scr,msi,com,url,appref-ms,"
    SplitPath(path, , , &extension)
    extension := StrLower(extension)
    if extension != "" && InStr(iconOwners, "," . extension . ",")
        return "p:" . StrLower(path)
    return extension = "" ? "" : "ext:" . extension
}

; data URI for a key, extracting on first use.
IconDataURI(key) {
    global IconCache
    if IconCache.Has(key)
        return IconCache[key]
    uri := IconDataURIForKey(key)
    IconCache[key] := uri
    DebugLog("Icon key=" . key . " bytes=" . StrLen(uri))
    return uri
}

IconDataURIForKey(key) {
    if key = "folder"
        return IconExtract("folder", 0x10)    ; FILE_ATTRIBUTE_DIRECTORY
    if SubStr(key, 1, 4) = "ext:"
        return IconExtract("icon." . SubStr(key, 5), 0x80)   ; FILE_ATTRIBUTE_NORMAL
    if SubStr(key, 1, 2) = "p:" {
        path := SubStr(key, 3)
        uri := IconExtract(path, 0)
        if uri = ""
            ; The file is gone or the path icon could not be read; fall back
            ; to the plain extension icon so a stale result row still looks right.
            uri := IconExtract(path, 0x80)
        return uri
    }
    return ""
}

IconExtract(fileName, attributes) {
    hicon := IconHicon(fileName, attributes)
    if !hicon
        return ""
    uri := IconHiconToPng(hicon)
    DllCall("user32\DestroyIcon", "ptr", hicon)
    return uri
}

; SHGFI_ICON | SHGFI_LARGEICON (32px at 96 DPI, more on scaled displays --
; the page renders the image at 16 CSS px either way). USEFILEATTRIBUTES
; looks the icon up from the extension alone, without touching the file.
IconHicon(fileName, attributes) {
    sfi := Buffer(A_PtrSize = 8 ? 1216 : 1212, 0)   ; sizeof(SHFILEINFOW)
    flags := 0x100        ; SHGFI_ICON
    if attributes != 0
        flags |= 0x10     ; SHGFI_USEFILEATTRIBUTES
    ok := DllCall("shell32\SHGetFileInfoW"
        , "wstr", fileName
        , "uint", attributes
        , "ptr", sfi
        , "uint", sfi.Size
        , "uint", flags
        , "ptr")
    return ok ? NumGet(sfi, 0, "ptr") : 0
}

; A raw HICON becomes straight-alpha pixels by hand rather than through
; GdipCreateBitmapFromHICON: that shortcut paints mask-based icons (and on
; some systems even alpha ones) onto an opaque black background, which shows
; up in the page as a black box. GetIconInfo hands out the color bitmap and
; the AND mask; the alpha channel -- real or reconstructed from the mask --
; is merged here, and GDI+ only encodes the finished pixels to PNG.
IconHiconToPng(hicon) {
    if !IconGdiplusStart()
        return ""
    info := Buffer(32, 0)   ; ICONINFO
    if !DllCall("user32\GetIconInfo", "ptr", hicon, "ptr", info, "int")
        return ""
    ; On x64 the two HBITMAP members sit after 4 bytes of padding.
    maskOffset := A_PtrSize = 8 ? 16 : 12
    hbmMask := NumGet(info, maskOffset, "ptr")
    hbmColor := NumGet(info, maskOffset + 8, "ptr")

    uri := ""
    bm := Buffer(32, 0)     ; BITMAP
    if hbmColor && hbmMask && DllCall("gdi32\GetObjectW", "ptr", hbmColor, "int", bm.Size, "ptr", bm, "int") {
        width := NumGet(bm, 4, "int")
        height := NumGet(bm, 8, "int")
        if width > 0 && height > 0 {
            pixels := IconReadBitmap(hbmColor, width, height, 32)
            if IsObject(pixels) {
                IconApplyAlpha(pixels, hbmMask, width, height)
                uri := IconPixelsToPng(pixels, width, height)
            }
        }
    }
    ; GetIconInfo allocates both bitmaps; the caller owns them.
    DllCall("gdi32\DeleteObject", "ptr", hbmMask)
    DllCall("gdi32\DeleteObject", "ptr", hbmColor)
    return uri
}

; Rows of an HBITMAP as a top-down DIB of the requested depth.
IconReadBitmap(hbm, width, height, bitCount) {
    stride := ((width * bitCount + 31) >> 5) << 2   ; rows are DWORD aligned
    pixels := Buffer(stride * height, 0)
    bmi := Buffer(48, 0)    ; BITMAPINFOHEADER + palette room
    NumPut("uint", 40, bmi, 0)
    NumPut("int", width, bmi, 4)
    NumPut("int", -height, bmi, 8)      ; negative height: top-down rows
    NumPut("ushort", 1, bmi, 12)
    NumPut("ushort", bitCount, bmi, 14)
    screenDc := DllCall("user32\GetDC", "ptr", 0, "ptr")
    lines := 0
    try lines := DllCall("gdi32\GetDIBits"
        , "ptr", screenDc
        , "ptr", hbm
        , "uint", 0
        , "uint", height
        , "ptr", pixels
        , "ptr", bmi
        , "uint", 0      ; DIB_RGB_COLORS
        , "int")
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", screenDc)
    return lines = height ? pixels : 0
}

; Merges transparency into 32bpp BGRA pixels: the color bitmap's own alpha
; channel wins when it is present (icon DIBs are premultiplied, so it is
; un-premultiplied for PNG); otherwise the AND mask supplies it -- bit clear
; = opaque, bit set = transparent. The mask bitmap is twice the icon height,
; with the AND mask in its top half, so a top-down read of the whole bitmap
; starts with exactly the rows needed here.
IconApplyAlpha(pixels, hbmMask, width, height) {
    total := width * height
    hasAlpha := false
    Loop total {
        if NumGet(pixels, A_Index * 4 - 1, "uchar") {
            hasAlpha := true
            break
        }
    }
    if hasAlpha {
        Loop total {
            offset := A_Index * 4 - 4
            alpha := NumGet(pixels, offset + 3, "uchar")
            if alpha != 0 && alpha != 255 {
                NumPut("uchar", Min(255, (NumGet(pixels, offset, "uchar") * 255) // alpha), pixels, offset)
                NumPut("uchar", Min(255, (NumGet(pixels, offset + 1, "uchar") * 255) // alpha), pixels, offset + 1)
                NumPut("uchar", Min(255, (NumGet(pixels, offset + 2, "uchar") * 255) // alpha), pixels, offset + 2)
            }
        }
        return
    }
    maskHeight := 0
    mbm := Buffer(32, 0)
    if DllCall("gdi32\GetObjectW", "ptr", hbmMask, "int", mbm.Size, "ptr", mbm, "int")
        maskHeight := NumGet(mbm, 8, "int")
    if maskHeight <= 0
        return
    mask := IconReadBitmap(hbmMask, width, maskHeight, 1)
    if !IsObject(mask)
        return
    maskStride := ((width + 31) >> 5) << 2
    Loop height {
        pixelRow := (A_Index - 1) * width * 4
        maskRow := (A_Index - 1) * maskStride
        Loop width {
            column := A_Index - 1
            byte := NumGet(mask, maskRow + (column >> 3), "uchar")
            alpha := (byte & (0x80 >> (column & 7))) ? 0 : 255
            NumPut("uchar", alpha, pixels, pixelRow + column * 4 + 3)
        }
    }
}

; Wraps the finished BGRA pixels in a GDI+ bitmap and encodes PNG.
IconPixelsToPng(pixels, width, height) {
    image := 0
    ; PixelFormat32bppARGB; the pixel buffer must outlive the save, which it
    ; does as this frame's local.
    if DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", width, "int", height, "int", width * 4, "int", 0x26200A, "ptr", pixels, "ptr*", &image, "int") != 0 || !image
        return ""
    uri := ""
    stream := 0
    if DllCall("ole32\CreateStreamOnHGlobal", "ptr", 0, "int", false, "ptr*", &stream, "hresult") = 0 && stream {
        if DllCall("gdiplus\GdipSaveImageToStream"
            , "ptr", image
            , "ptr", stream
            , "ptr", IconPngClsid()
            , "ptr", 0
            , "int") = 0 {
            size := IconStreamSize(stream)
            hglobal := 0
            if size && DllCall("ole32\GetHGlobalFromStream", "ptr", stream, "ptr*", &hglobal, "hresult") = 0 {
                locked := DllCall("kernel32\GlobalLock", "ptr", hglobal, "ptr")
                if locked {
                    bytes := Buffer(size, 0)
                    DllCall("kernel32\RtlMoveMemory", "ptr", bytes, "ptr", locked, "uptr", size)
                    DllCall("kernel32\GlobalUnlock", "ptr", hglobal)
                    uri := "data:image/png;base64," . IconBase64(bytes)
                }
            }
        }
        ObjRelease(stream)
    }
    DllCall("gdiplus\GdipDisposeImage", "ptr", image)
    return uri
}

; Exact byte count of a stream: seek to the end, then back to the start.
IconStreamSize(stream) {
    end := 0
    if ComCall(5, stream, "int64", 0, "uint", 1, "uint64*", &end, "hresult") != 0   ; STREAM_SEEK_END
        return 0
    ComCall(5, stream, "int64", 0, "uint", 0, "uint64*", &zero := 0, "hresult")     ; STREAM_SEEK_SET
    return end
}

IconGdiplusStart() {
    global IconGdiplusToken
    if IconGdiplusToken
        return true
    input := Buffer(24, 0)   ; GdiplusStartupInput, version 1, everything else off
    NumPut("uint", 1, input, 0)
    token := 0
    if DllCall("gdiplus\GdiplusStartup", "ptr*", &token, "ptr", input, "ptr", 0, "int") != 0
        return false
    IconGdiplusToken := token
    return true
}

IconGdiplusStop() {
    global IconGdiplusToken
    if IconGdiplusToken {
        DllCall("gdiplus\GdiplusShutdown", "ptr", IconGdiplusToken)
        IconGdiplusToken := 0
    }
}

IconPngClsid() {
    static clsid := 0
    if !IsObject(clsid) {
        clsid := Buffer(16, 0)
        DllCall("ole32\CLSIDFromString", "wstr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "ptr", clsid, "hresult")
    }
    return clsid
}

; CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, no line breaks in the data URI.
; The parameter cannot be named "buffer": identifiers are case-insensitive in
; AHK, so that name shadows the Buffer class the next line constructs.
IconBase64(bytes) {
    needed := 0
    DllCall("crypt32\CryptBinaryToStringW", "ptr", bytes, "uint", bytes.Size, "uint", 0x40000001, "ptr", 0, "uint*", &needed, "int")
    out := Buffer(needed * 2, 0)
    DllCall("crypt32\CryptBinaryToStringW", "ptr", bytes, "uint", bytes.Size, "uint", 0x40000001, "ptr", out, "uint*", &needed, "int")
    return StrGet(out)
}
