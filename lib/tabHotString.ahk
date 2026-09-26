; CapsLock+Tab hotstring replacement.
; Calculation and JavaScript evaluation are intentionally not part of this
; action; only configured text replacements are applied.

TabHotStringAction() {
    global A_Clipboard, ClipboardWatcherSuspended
    oldClipboard := ClipboardAll()
    replacement := ""

    selectedText := GetSelectedText()
    if selectedText != "" {
        replacement := GetHotStringReplacement(selectedText, &matched)
        if replacement != "" && replacement != selectedText
            SetClipboardText(replacement)
    } else {
        ClipboardWatcherSuspended := true
        try {
            A_Clipboard := ""
            SendInput("+{Home}")
            Sleep(10)
            SendInput("^{Insert}")
            if ClipWait(0.15) {
                lineText := A_Clipboard
                replacement := GetHotStringReplacement(lineText, &matched)
                if replacement != "" && replacement != lineText {
                    A_Clipboard := replacement
                    SendInput("^v")
                    Sleep(60)
                }
            }
        } finally {
            ClipboardWatcherSuspended := false
        }
    }
    A_Clipboard := oldClipboard
    return replacement
}
