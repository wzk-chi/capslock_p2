; Copy complete saved note bodies from the selected notes tag, once per action.
global NotesCycleLastCopiedNoteId := 0
global NotesCycleLastCopiedTagId := 0
global NotesCycleRunning := false

NotesCycleResetProgress() {
    global NotesCycleLastCopiedNoteId, NotesCycleLastCopiedTagId
    NotesCycleLastCopiedNoteId := 0
    NotesCycleLastCopiedTagId := 0
}

NotesCycleCopyNextNote() {
    global NotesCycleLastCopiedNoteId, NotesCycleLastCopiedTagId, NotesCycleRunning
    if NotesCycleRunning
        return false
    NotesCycleRunning := true
    stage := "read"
    noteId := 0
    tagId := 0
    try {
        tag := NotesStoreGetCycleCopyTag()
        if tag["status"] = "error"
            throw Error("Cycle tag setting could not be read")
        tagId := tag["id"]
        if !tagId {
            NotesCycleLastCopiedTagId := 0
            NotesCycleLastCopiedNoteId := 0
            DebugLog("Notes cycle tag not selected")
            ShowMsg(LLMText(
                "Choose a cycle tag in Notes settings first.",
                "请先在笔记设置中选择循环标签。"), 2500)
            return false
        }
        if tagId != NotesCycleLastCopiedTagId
            NotesCycleLastCopiedNoteId := 0
        note := NotesStoreReadNextTaggedNote(tagId, NotesCycleLastCopiedNoteId)
        if note["status"] = "error"
            throw Error("Note query failed")
        if note["status"] = "empty" {
            NotesCycleLastCopiedNoteId := 0
            DebugLog("Notes cycle empty tagId=" . tagId)
            emptyMessage := IsChineseLanguage()
                ? "标签“" . tag["name"] . "”下没有可复制的正文，请添加笔记内容或选择其他标签。"
                : "No note body is available under tag " . tag["name"]
                    . ". Add note content or select another tag."
            ShowMsg(emptyMessage, 2500)
            return false
        }
        noteId := note["id"]
        stage := "copy"
        text := NotesExternalizeMarkdown(note["content"])
        if Trim(text, " `t`r`n") = "" || !NotesSetClipboard(text, "user-copy")
            throw Error("Note body could not be copied")
        NotesCycleLastCopiedTagId := tagId
        NotesCycleLastCopiedNoteId := noteId
        try {
            title := Trim(RegExReplace(String(note["title"]), "\s+", " "))
            if title = ""
                title := LLMText("Untitled", "无标题")
            ShowMsg(title, 1400)
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
