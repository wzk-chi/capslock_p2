; CapsLock+Tab hotstring replacement.
; Calculation and JavaScript evaluation are intentionally not part of this
; action; only configured text replacements are applied.

TabHotStringAction() {
    global A_Clipboard, ClipboardWatcherSuspended
    replacement := ""

    selectedText := GetSelectedText()
    if selectedText != "" {
        replacement := GetHotStringReplacement(selectedText, &matched)
        if replacement != "" && replacement != selectedText
            SetClipboardText(replacement)
    } else {
        oldClipboard := ClipboardAll()
        previousSuspension := ClipboardWatcherSuspended
        ownedSequence := 0
        ClipboardWatcherSuspended := true
        try {
            A_Clipboard := ""
            ownedSequence := ClipboardSequenceNumber()
            SendInput("+{Home}")
            Sleep(10)
            SendInput("^{Insert}")
            if ClipWait(0.15) {
                lineText := A_Clipboard
                ownedSequence := ClipboardSequenceNumber()
                replacement := GetHotStringReplacement(lineText, &matched)
                if replacement != "" && replacement != lineText {
                    A_Clipboard := replacement
                    ownedSequence := ClipboardSequenceNumber()
                    SendInput("^v")
                    Sleep(60)
                }
            }
        } finally {
            if ownedSequence && ClipboardSequenceNumber() = ownedSequence
                A_Clipboard := oldClipboard
            ClipboardWatcherSuspended := previousSuspension
        }
    }
    return replacement
}
