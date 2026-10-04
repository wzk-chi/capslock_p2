; File and clipboard operations for the Everything page.

EverythingOpenResult(item) {
    path := Trim(item["fullPath"])
    if path = ""
        return
    if !FileExist(path) && !DirExist(path) {
        EverythingActionFeedback(EverythingText("The item no longer exists.", "该项目已不存在。"), true)
        return
    }
    try {
        Run(QbarFilesystemTarget(path))
        EverythingActionFeedback(EverythingText("Opened", "已打开"), false)
    } catch {
        EverythingActionFeedback(EverythingText("Cannot open the item.", "无法打开该项目。"), true)
    }
}

EverythingRevealResult(item) {
    path := Trim(item["fullPath"])
    if path = ""
        return
    if !FileExist(path) && !DirExist(path) {
        EverythingActionFeedback(EverythingText("The item no longer exists.", "该项目已不存在。"), true)
        return
    }
    if DirExist(path) {
        try {
            Run(QbarFilesystemTarget(path))
            EverythingActionFeedback(EverythingText("Folder opened", "已打开文件夹"), false)
        } catch {
            EverythingActionFeedback(EverythingText("Cannot open the folder.", "无法打开文件夹。"), true)
        }
        return
    }
    parent := item["parentPath"]
    if parent = ""
        SplitPath(path, , &parent)
    if parent = "" || !DirExist(parent) {
        EverythingActionFeedback(EverythingText("The containing folder was not found.", "找不到所在文件夹。"), true)
        return
    }
    try {
        Run("explorer.exe /select," . Chr(34) . path . Chr(34))
        EverythingActionFeedback(EverythingText("Shown in folder", "已在文件夹中显示"), false)
    } catch {
        EverythingActionFeedback(EverythingText("Cannot show the item in Explorer.", "无法在资源管理器中显示该项目。"), true)
    }
}

EverythingCopyText(text, message := "") {
    global A_Clipboard
    suspendToken := ClipboardSuspendBegin("user-copy")
    try {
        A_Clipboard := String(text)
        ClipboardHistoryMarkOwnedSequence(ClipboardSequenceNumber(), "user-copy")
    }
    catch {
        ClipboardSuspendEnd(suspendToken)
        EverythingActionFeedback(EverythingText("Copy failed", "复制失败"), true)
        return false
    }
    ClipboardSuspendEnd(suspendToken)
    ClipboardHistoryPublishExplicit(ClipboardSequenceNumber(), 0, "user-copy")
    EverythingActionFeedback(message != "" ? message : EverythingText("Copied", "已复制"), false)
    return true
}

; Copy one path as CF_HDROP so Explorer and other shell targets can paste a
; file or folder. AHK's Clipboard assignment only supplies text and cannot
; represent this operation.
EverythingCopyFiles(path, attempt := 0, *) {
    path := String(path)
    if path = "" || (!FileExist(path) && !DirExist(path)) {
        EverythingActionFeedback(EverythingText("The item no longer exists.", "该项目已不存在。"), true)
        return false
    }
    charCount := StrLen(path) + 2
    byteCount := 20 + charCount * 2
    hGlobal := DllCall("kernel32\GlobalAlloc", "uint", 0x42, "uptr", byteCount, "ptr")
    locked := hGlobal ? DllCall("kernel32\GlobalLock", "ptr", hGlobal, "ptr") : 0
    if !hGlobal || !locked {
        if hGlobal
            DllCall("kernel32\GlobalFree", "ptr", hGlobal)
        EverythingActionFeedback(EverythingText("Copy failed", "复制失败"), true)
        return false
    }
    NumPut("uint", 20, locked, 0) ; DROPFILES.pFiles
    NumPut("uint", 0, locked, 4)  ; pt.x
    NumPut("uint", 0, locked, 8)  ; pt.y
    NumPut("uint", 0, locked, 12) ; fNC
    NumPut("uint", 1, locked, 16) ; fWide = TRUE
    StrPut(path, locked + 20, StrLen(path) + 1, "UTF-16")
    NumPut("ushort", 0, locked, 20 + (StrLen(path) + 1) * 2)
    DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)
    locked := 0

    if !DllCall("user32\OpenClipboard", "ptr", 0) {
        DllCall("kernel32\GlobalFree", "ptr", hGlobal)
        if attempt < 5 {
            SetTimer(EverythingCopyFiles.Bind(path, attempt + 1), -60)
            return true
        }
        EverythingActionFeedback(EverythingText("The clipboard is busy.", "剪贴板正忙。"), true)
        return false
    }

    suspendToken := ClipboardSuspendBegin("user-copy")
    success := false
    try {
        if !DllCall("user32\EmptyClipboard")
            throw Error("EmptyClipboard failed")
        if !DllCall("user32\SetClipboardData", "uint", 15, "ptr", hGlobal)
            throw Error("SetClipboardData failed")
        hGlobal := 0 ; ownership transferred to the clipboard
        ClipboardHistoryMarkOwnedSequence(ClipboardSequenceNumber(), "user-copy")
        success := true
    } catch as copyError {
        DebugLog("Everything file copy failed")
    } finally {
        if locked
            try DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)
        if hGlobal
            DllCall("kernel32\GlobalFree", "ptr", hGlobal)
        DllCall("user32\CloseClipboard")
        ClipboardSuspendEnd(suspendToken)
    }
    if success
        ClipboardHistoryPublishExplicit(ClipboardSequenceNumber(), 0, "user-copy")
    if success
        EverythingActionFeedback(EverythingText("Copied", "已复制"), false)
    else
        EverythingActionFeedback(EverythingText("Copy failed", "复制失败"), true)
    return success
}

EverythingActionFeedback(message, isError := false) {
    global EverythingVisible, EverythingPageReady
    if !EverythingVisible || !EverythingPageReady
        return
    payload := Map("message", String(message), "error", isError ? JSON.true : JSON.false)
    EverythingExec("window.showActionResult(" . JSON.stringify(payload, 0) . ");")
}
