; Copy complete saved note bodies from the fixed prompt tag, once per action.
global NotesCycleLastCopiedNoteId := 0
global NotesCycleRunning := false

NotesCycleCopyNextPrompt() {
    global NotesCycleLastCopiedNoteId, NotesCycleRunning
    if NotesCycleRunning
        return false
    NotesCycleRunning := true
    stage := "read"
    noteId := 0
    try {
        note := NotesStoreReadNextTaggedNote("提示词", NotesCycleLastCopiedNoteId)
        if note["status"] = "error"
            throw Error("Note query failed")
        if note["status"] = "empty" {
            NotesCycleLastCopiedNoteId := 0
            DebugLog("Notes cycle empty")
            ShowMsg(LLMText(
                "No note body is available under the “提示词” tag. Add the tag and save some content.",
                "“提示词”标签下没有可复制的正文，请给笔记添加该标签并保存内容。"), 2500)
            return false
        }
        noteId := note["id"]
        stage := "copy"
        text := NotesExternalizeMarkdown(note["content"])
        if Trim(text, " `t`r`n") = "" || !NotesSetClipboard(text, "user-copy")
            throw Error("Note body could not be copied")
        NotesCycleLastCopiedNoteId := noteId
        try {
            title := Trim(RegExReplace(String(note["title"]), "\s+", " "))
            if title = ""
                title := LLMText("Untitled", "无标题")
            ShowMsg(LLMText("Copied: ", "已复制：") . title, 1400)
        } catch as noticeError {
            try DebugLog("Notes cycle notice failed errorType=" . Type(noticeError))
        }
        try DebugLog("Notes cycle copied noteId=" . noteId)
        return true
    } catch as cycleError {
        try DebugLog("Notes cycle failed stage=" . stage . " noteId=" . noteId
            . " errorType=" . Type(cycleError))
        ShowMsg(stage = "read"
            ? LLMText("Notes could not be read. Try again shortly.", "暂时无法读取笔记，请稍后重试。")
            : LLMText("Copy failed. Try again shortly.", "复制失败，请稍后重试。"), 2500)
        return false
    } finally {
        NotesCycleRunning := false
    }
}
