; Independent Everything search page state, query orchestration, and result
; serialization. The es.exe process machinery remains in qbar_everything.ahk
; for now so the two entry points share one backend and one owned instance.

global EverythingHost := 0
global EverythingVisible := false
global EverythingWindowInitialized := false
global EverythingPendingText := ""
global EverythingPendingOpen := false
global EverythingOpenSerial := 0
global EverythingQuerySeq := 0
global EverythingQueryText := ""
global EverythingCategory := "all"
global EverythingResults := []
global EverythingResultsVersion := 0
global EverythingIconSent := Map()
global EverythingIconQueue := []
global EverythingIconQueued := Map()
global EverythingIconTimer := false
global EverythingQueryCallback := 0

global EverythingPanelWidth := 960
global EverythingPanelHeight := 680
global EverythingPanelMinWidth := 640
global EverythingPanelMinHeight := 440

; The page uses stable IDs; display labels are supplied by the page language.
EverythingCategoryIds() {
    return ["all", "folder", "excel", "word", "ppt", "pdf", "image", "video", "audio", "archive"]
}

EverythingCategoryValid(category) {
    category := StrLower(Trim(category))
    for value in EverythingCategoryIds()
        if value = category
            return true
    return false
}

; Keep the extension lists in one place. The sidebar adds these native
; Everything clauses to the same search expression; folder: remains a
; separate category for directories.
EverythingCategoryClause(category) {
    switch StrLower(Trim(category)) {
        case "folder":
            return "folder:"
        case "excel":
            return "ext:xls;xlsx;xlsm;xlsb;xlt;xltx;xltm;csv;tsv"
        case "word":
            return "ext:doc;docx;docm;dot;dotx;dotm;rtf;odt"
        case "ppt":
            return "ext:ppt;pptx;pptm;pps;ppsx;ppsm;pot;potx;potm;odp"
        case "pdf":
            return "ext:pdf"
        case "image":
            return "ext:jpg;jpeg;png;gif;bmp;webp;tif;tiff;svg;ico;heic;heif;avif"
        case "video":
            return "ext:mp4;mkv;avi;mov;wmv;flv;webm;m4v;mpeg;mpg;ts;m2ts;3gp"
        case "audio":
            return "ext:mp3;wav;flac;aac;m4a;ogg;opus;wma;ape;aiff;alac;mid;midi"
        case "archive":
            return "ext:zip;rar;7z;tar;gz;bz2;xz;tgz;zst;cab"
        default:
            return ""
    }
}

EverythingBuildQuery(text, category := "all") {
    text := Trim(text, " `t")
    category := EverythingCategoryValid(category) ? StrLower(Trim(category)) : "all"
    clause := EverythingCategoryClause(category)
    if clause = "" || text = ""
        return text = "" ? clause : text
    ; Apply the type condition in the same native Everything query. Everything
    ; 1.4 uses angle brackets for grouping; round-bracket grouping is optional
    ; and may be disabled in the user's configuration. Keep OR branches
    ; subject to the type clause without making the user's text literal.
    return "<" . text . "> " . clause
}

EverythingShow(query := "", explicitQuery := false) {
    global EverythingVisible, EverythingPendingText, EverythingPendingOpen
    global EverythingOpenSerial, EverythingWindowInitialized, EverythingCategory, EverythingQueryText
    if explicitQuery && EverythingVisible
        EverythingCancelSearch("new open query")
    if explicitQuery {
        EverythingPendingText := Trim(query, " `t")
        EverythingQueryText := EverythingPendingText
        EverythingCategory := "all"
        EverythingPendingOpen := true
        EverythingOpenSerial += 1
    } else if !EverythingVisible {
        EverythingPendingText := EverythingWindowInitialized ? EverythingQueryText : ""
        EverythingPendingOpen := true
        EverythingOpenSerial += 1
    }
    if !EverythingEnsureWebView() {
        EverythingVisible := false
        return false
    }
    EverythingVisible := true
    if EverythingWindowInitialized
        PanelHostShow(EverythingHost, 0, 0, false)
    else {
        size := ScreenFitSize(EverythingPanelWidth, EverythingPanelHeight,
            EverythingPanelMinWidth, EverythingPanelMinHeight)
        PanelHostShow(EverythingHost, size[1], size[2], true)
        EverythingWindowInitialized := true
    }

    panelGui := PanelHostGui(EverythingHost)
    if IsObject(panelGui) {
        try WinRestore("ahk_id " . panelGui.Hwnd)
        try WinActivate("ahk_id " . panelGui.Hwnd)
    }
    WindowBarApplyNativeMode(EverythingHost, WindowBarIsNative(EverythingHost))
    WindowBarApplyPinnedState(EverythingHost, WindowBarIsPinned(EverythingHost),
        EverythingVisible, EverythingHide, Map("requireActive", true))
    WindowBarSetPinnedPage(EverythingHost, WindowBarIsPinned(EverythingHost))
    PanelHostStartAutoHide(EverythingHost, EverythingHide,
        Map("requireActive", true))
    if PanelHostPageReady(EverythingHost) {
        EverythingBeginPendingOpen()
        SetTimer(EverythingFocusInput, -1)
    }
    return true
}

EverythingBeginPendingOpen() {
    global EverythingPendingOpen, EverythingPendingText, EverythingCategory
    global EverythingOpenSerial, EverythingVisible
    if !EverythingVisible || !EverythingPendingOpen || !PanelHostPageReady(EverythingHost)
        return
    text := EverythingPendingText
    category := EverythingCategory
    serial := EverythingOpenSerial
    EverythingPendingOpen := false
    payload := Map(
        "text", text,
        "categoryId", category,
        "uiLanguage", LLMUiLanguage())
    EverythingExec("window.initialize(" . JSON.stringify(payload, 0) . ");")
    SetTimer(EverythingStartInitialQuery.Bind(text, category, serial), -1)
    SetTimer(EverythingFocusInput, -1)
}

EverythingStartInitialQuery(text, category, serial, *) {
    global EverythingOpenSerial, EverythingVisible
    if !EverythingVisible || serial != EverythingOpenSerial
        return
    EverythingBeginQuery(text, category, true)
}

EverythingBeginQuery(text, category := "all", immediate := false) {
    global EverythingQueryCallback, EverythingQuerySeq, EverythingQueryText, EverythingCategory
    global EverythingVisible, EverythingResults, EverythingResultsVersion
    if !EverythingVisible
        return
    if !EverythingCategoryValid(category)
        category := "all"
    if IsObject(EverythingQueryCallback)
        SetTimer(EverythingQueryCallback, 0)
    EverythingQueryCallback := 0
    ; Invalidate the old backend immediately, before the new debounce window;
    ; otherwise a very fast old process could publish under the new request.
    QbarEsCancelJob("everything query changed")
    EverythingCancelIconQueue()
    ; Invalidate actions against the previous result set as soon as a new
    ; query starts, including while its replacement results are still pending.
    EverythingResultsVersion += 1
    EverythingQueryText := String(text)
    EverythingCategory := StrLower(Trim(category))
    EverythingQuerySeq += 1
    requestId := EverythingQuerySeq
    if Trim(EverythingQueryText, " `t") = "" && EverythingCategory = "all" {
        EverythingResults := []
        EverythingExec("window.setResults(" . JSON.stringify(Map(
            "requestId", requestId,
            "resultsVersion", EverythingResultsVersion,
            "items", [],
            "truncated", JSON.false), 0) . ");")
        EverythingExec("window.setSearchState(" . JSON.stringify(Map(
            "state", "ready",
            "requestId", requestId,
            "message", EverythingText(
                "Enter a file name or choose a file type.",
                "请输入文件名或选择文件类型。")), 0) . ");")
        return
    }
    EverythingExec("window.setSearchState(" . JSON.stringify(Map(
        "state", "loading", "requestId", requestId, "message", EverythingText("Searching…", "搜索中…")), 0) . ");")
    EverythingQueryCallback := EverythingRunQuery.Bind(
        EverythingQueryText, EverythingCategory, requestId)
    SetTimer(EverythingQueryCallback, immediate ? -1 : -100)
}

EverythingRunQuery(text, category, requestId, *) {
    global EverythingVisible, EverythingQuerySeq
    global QbarEsSeq
    if !EverythingVisible || requestId != EverythingQuerySeq
        return
    query := EverythingBuildQuery(text, category)
    DebugLog("Everything query category=" . category)
    DebugLogPrivate("Everything query", query)
    QbarEsResolveBackend(query, QbarEsSeq, requestId)
}

EverythingPublishResults(results, seq, requestId) {
    global EverythingVisible, EverythingResults, EverythingResultsVersion, EverythingQuerySeq
    if !QbarEsRequestIsCurrent(seq, requestId)
        return
    limit := QbarEsMaxResults()
    truncated := results.Length > limit
    while results.Length > limit
        results.Pop()

    normalized := []
    id := 0
    for item in results {
        id += 1
        path := String(item["short"])
        name := "", parent := "", extension := ""
        size := 0
        modifiedAt := ""
        SplitPath(path, &name, &parent, &extension)
        try size := FileGetSize(path)
        try modifiedAt := FileGetTime(path, "M")
        kind := item.Has("type") ? item["type"] : (DirExist(path) ? "folder" : "file")
        normalized.Push(Map(
            "id", String(id),
            "fullPath", path,
            "name", name = "" ? path : name,
            "parentPath", parent,
            "kind", kind,
            "extension", StrLower(extension),
            "size", size,
            "modifiedAt", modifiedAt,
            "label", item.Has("label") ? item["label"] : path,
            "icon", item.Has("icon") ? item["icon"] : ""))
    }
    EverythingResults := normalized
    version := EverythingResultsVersion
    iconKeys := Map()
    rows := EverythingPageRows(normalized, &iconKeys)
    payload := Map(
        "requestId", EverythingQuerySeq,
        "resultsVersion", version,
        "items", rows,
        "truncated", truncated)
    EverythingExec("window.setResults(" . JSON.stringify(payload, 0) . ");")
    EverythingQueueIcons(iconKeys)
    EverythingExec("window.setSearchState(" . JSON.stringify(Map(
        "state", "ready", "requestId", EverythingQuerySeq,
        "message", EverythingText("", "")), 0) . ");")
}

EverythingPageRows(items, &iconKeys) {
    global EverythingIconSent
    rows := []
    iconKeys := Map()
    for item in items {
        row := Map(
            "id", item["id"],
            "name", item["name"],
            "parentPath", item["parentPath"],
            "fullPath", item["fullPath"],
            "kind", item["kind"],
            "extension", item["extension"],
            "size", item["size"],
            "modifiedAt", item["modifiedAt"])
        iconKey := item["icon"]
        if iconKey != "" {
            row["icon"] := iconKey
            if !EverythingIconSent.Has(iconKey)
                iconKeys[iconKey] := true
        }
        rows.Push(row)
    }
    return rows
}

EverythingCancelIconQueue() {
    global EverythingIconQueue, EverythingIconQueued, EverythingIconTimer
    SetTimer(EverythingFlushIconQueue, 0)
    EverythingIconQueue := []
    EverythingIconQueued := Map()
    EverythingIconTimer := false
}

EverythingQueueIcons(keys) {
    global EverythingIconQueue, EverythingIconQueued, EverythingIconTimer, EverythingIconSent
    for key, pending in keys {
        if !pending || key = "" || EverythingIconSent.Has(key) || EverythingIconQueued.Has(key)
            continue
        EverythingIconQueued[key] := true
        EverythingIconQueue.Push(key)
    }
    if EverythingIconQueue.Length && !EverythingIconTimer {
        EverythingIconTimer := true
        SetTimer(EverythingFlushIconQueue, -1)
    }
}

EverythingFlushIconQueue(*) {
    global EverythingIconQueue, EverythingIconQueued, EverythingIconTimer, EverythingIconSent
    icons := Map()
    extracted := 0
    while EverythingIconQueue.Length && extracted < 8 {
        key := EverythingIconQueue.RemoveAt(1)
        if EverythingIconQueued.Has(key)
            EverythingIconQueued.Delete(key)
        if EverythingIconSent.Has(key)
            continue
        extracted += 1
        uri := IconDataURI(key)
        if uri != "" {
            EverythingIconSent[key] := true
            icons[key] := uri
        }
    }
    if icons.Count
        EverythingExec("window.addIcons(" . JSON.stringify(icons, 0) . ");")
    if EverythingIconQueue.Length
        SetTimer(EverythingFlushIconQueue, -1)
    else
        EverythingIconTimer := false
}

EverythingSetError(text) {
    global EverythingVisible, EverythingQuerySeq
    if !EverythingVisible
        return
    EverythingCancelIconQueue()
    EverythingExec("window.setSearchState(" . JSON.stringify(Map(
        "state", "error", "requestId", EverythingQuerySeq, "message", text), 0) . ");")
}

EverythingText(english, chinese) {
    return IsChineseLanguage() ? chinese : english
}

EverythingExec(script) {
    global EverythingHost
    return PanelHostExecute(EverythingHost, script)
}

EverythingFocusInput(*) {
    global EverythingVisible, EverythingHost
    if EverythingVisible && PanelHostPageReady(EverythingHost) {
        EverythingExec("window.focusInput();")
    }
}

EverythingIsActive() {
    global EverythingHost, EverythingVisible
    return EverythingVisible && PanelHostWindowActive(EverythingHost)
}

EverythingFindResult(resultId, version) {
    global EverythingResults, EverythingResultsVersion
    if Type(version) != "Integer" || version <= 0 || version != EverythingResultsVersion
        return 0
    for item in EverythingResults
        if String(item["id"]) = String(resultId)
            return item
    return 0
}

EverythingHandleAction(action, resultId, version, *) {
    item := EverythingFindResult(resultId, version)
    if !IsObject(item) {
        EverythingActionFeedback(EverythingText("The result is no longer available.", "该结果已不可用。"), true)
        return
    }
    switch action {
        case "open":
            EverythingOpenResult(item)
        case "reveal":
            EverythingRevealResult(item)
        case "copy":
            EverythingCopyFiles(item["fullPath"])
        case "copyPath":
            EverythingCopyText(item["fullPath"], EverythingText("Path copied", "已复制路径"))
        case "copyParent":
            parent := item["parentPath"]
            if parent = ""
                parent := item["fullPath"]
            EverythingCopyText(parent, EverythingText("Containing folder copied", "已复制所在路径"))
    }
}
