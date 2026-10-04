; CapsLock+Tab hotstring replacement.
; Calculation and JavaScript evaluation are intentionally not part of this
; action; only configured text replacements are applied.

TabHotStringAction() {
    global A_Clipboard
    replacement := ""

    selectedText := GetSelectedText()
    if selectedText != "" {
        replacement := GetHotStringReplacement(selectedText, &matched)
        if replacement != "" && replacement != selectedText
            SetClipboardText(replacement)
    } else {
        oldClipboard := ClipboardAll()
        ownedSequence := 0
        suspendToken := ClipboardSuspendBegin("temporary-hotstring")
        try {
            A_Clipboard := ""
            ownedSequence := ClipboardSequenceNumber()
            ClipboardHistoryMarkOwnedSequence(ownedSequence, "temporary-hotstring")
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
                    ClipboardHistoryMarkOwnedSequence(ownedSequence, "temporary-hotstring")
                    SendInput("^v")
                    Sleep(60)
                }
            }
        } finally {
            if ownedSequence && ClipboardSequenceNumber() = ownedSequence {
                A_Clipboard := oldClipboard
                ClipboardHistoryMarkOwnedSequence(ClipboardSequenceNumber(), "temporary-hotstring")
            }
            ClipboardSuspendEnd(suspendToken)
        }
    }
    return replacement
}
