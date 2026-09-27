; qbar item index, filtering, and row preparation.

QbarAllItems() {
    items := []
    for item in QbarConfigItems()
        items.Push(item)
    for item in QbarStartMenuItems()
        items.Push(item)
    return items
}

QbarInvalidateConfigIndex() {
    global QbarConfigIndexCache, QbarConfigIndexGeneration
    QbarConfigIndexGeneration += 1
    QbarConfigIndexCache := 0
}

QbarConfigIndex() {
    global QbarConfigIndexCache, QbarConfigIndexGeneration
    if IsObject(QbarConfigIndexCache)
        && QbarConfigIndexCache["generation"] = QbarConfigIndexGeneration
        return QbarConfigIndexCache

    items := []
    sections := Map("QSearch", [], "QRun", [], "QWeb", [])
    byShort := Map()
    configuredSearch := Map()

    ; Discoverability rows always lead the list. A configured q/e trigger still
    ; wins at dispatch time because configured presence is indexed separately.
    items.Push(Map("short", "q", "label", "q <AI 问答 ai>", "type", "search", "value", ""))
    items.Push(Map("short", "e", "label", "e <文件搜索 everything|find|f>", "type", "search", "value", ""))

    ; Presence precedence stays QRun -> QWeb -> QSearch, matching the former
    ; QbarConfigShortKeyExists scan. Display order stays QSearch -> QRun -> QWeb.
    for section in ["QRun", "QWeb", "QSearch"]
        for key, value in ConfigSection(section)
            QbarConfigIndexRecordPresence(byShort, QbarShortKey(key))

    for key, value in ConfigSection("QSearch") {
        short := QbarShortKey(key)
        if Trim(value) = "" || short = "default"
            continue
        configuredSearch[StrLower(short)] := true
        entry := Map("short", short, "label", key, "type", "search", "value", value)
        sections["QSearch"].Push(entry)
        QbarConfigIndexRecordEntry(byShort, "QSearch", entry)
    }
    for key, value in ConfigSection("QRun") {
        if Trim(value) = ""
            continue
        short := QbarShortKey(key)
        runString := "", runAsAdmin := false, parameters := ""
        resolved := ExtractSetString(value, &runString, &runAsAdmin, &parameters)
        if resolved = ""
            resolved := Trim(value)
        isFolder := CheckStringType(resolved) = "folder"
        entry := Map(
            "short", short,
            "label", key,
            "type", isFolder ? "folder" : "file",
            "value", value,
            "icon", isFolder ? "folder" : IconKeyForPath(resolved))
        sections["QRun"].Push(entry)
        QbarConfigIndexRecordEntry(byShort, "QRun", entry)
    }
    for key, value in ConfigSection("QWeb") {
        if Trim(value) = ""
            continue
        entry := Map("short", QbarShortKey(key), "label", key, "type", "web", "value", value)
        sections["QWeb"].Push(entry)
        QbarConfigIndexRecordEntry(byShort, "QWeb", entry)
    }

    ; The dynamic s row follows the configured QSearch rows. A non-empty user
    ; entry suppresses it; an empty entry retains the previous fallback row.
    if !configuredSearch.Has("s") {
        if IsChineseLanguage()
            entry := Map("short", "s", "label", "s <搜索>", "type", "search", "value", "https://www.bing.com/search?q={q}")
        else
            entry := Map("short", "s", "label", "s <search>", "type", "search", "value", "https://www.google.com/search?q={q}")
        sections["QSearch"].Push(entry)
        QbarConfigIndexRecordEntry(byShort, "QSearch", entry)
    }

    for entry in sections["QSearch"]
        items.Push(entry)
    for entry in sections["QRun"]
        items.Push(entry)
    for entry in sections["QWeb"]
        items.Push(entry)

    QbarConfigIndexCache := Map(
        "items", items,
        "sections", sections,
        "byShort", byShort,
        "generation", QbarConfigIndexGeneration)
    return QbarConfigIndexCache
}

QbarConfigIndexRecordPresence(byShort, short) {
    token := short
    if token = ""
        return
    if !byShort.Has(token)
        byShort[token] := Map("configured", true)
    else
        byShort[token]["configured"] := true
}

QbarConfigIndexRecordEntry(byShort, section, entry) {
    token := entry["short"]
    if token = ""
        return
    if !byShort.Has(token)
        byShort[token] := Map("configured", false)
    ; First entry in a section keeps the same duplicate-trigger behavior as
    ; the former linear QbarFindByShort() scan.
    if !byShort[token].Has(section)
        byShort[token][section] := entry
}

QbarConfigItems() {
    return QbarConfigIndex()["items"]
}

QbarStartMenuItems() {
    global QbarStartMenuCache
    if IsObject(QbarStartMenuCache)
        return QbarStartMenuCache
    items := []
    ; The same program is normally registered in both start menus, so its name
    ; repeats; the reference keyed its collection by label and kept the first,
    ; which is what makes one row per program. A label is only claimed once an
    ; entry has passed the filters, so a stale shortcut cannot hide a good one.
    seen := Map()
    for base in [A_StartMenu, A_StartMenuCommon] {
        try {
            Loop Files, base . "\*.lnk", "R" {
                name := A_LoopFileName
                ; The reference implementation skips uninstall stubs.
                if InStr(name, ".ini") || InStr(name, "卸载") || InStr(name, "uninstall")
                    continue
                label := RegExReplace(name, "i)\.lnk$")
                if seen.Has(label)
                    continue
                ; FileGetShortcut writes into output variables in v2 rather than
                ; returning an object, and it throws when the link cannot be read.
                target := ""
                try FileGetShortcut(A_LoopFileFullPath, &target)
                catch
                    continue
                if !RegExMatch(target, "i)exe$")
                    continue
                seen[label] := true
                items.Push(Map(
                    "short", label,
                    "label", label,
                    "type", "app",
                    "value", A_LoopFileFullPath,
                    "icon", IconKeyForPath(A_LoopFileFullPath),
                    "exe", target
                ))
            }
        } catch as scanError {
            DebugLog("Start menu scan failed")
        }
    }
    DebugLog("Start menu items=" . items.Length)
    QbarStartMenuCache := items
    return items
}

; ---------------------------------------------------------------------------
; Query / filtering
; ---------------------------------------------------------------------------

QbarQuery(text, querySeq := 0) {
    global QbarVisible, QbarEsMode, QbarIndexReady, QbarQuerySeq
    if !QbarVisible || !QbarIndexReady
        return
    if querySeq && querySeq != QbarQuerySeq {
        DebugLog("Qbar query stale")
        DebugLogPrivate("Qbar stale query", text)
        return
    }
    text := Trim(text, " `t")
    DebugLog("Qbar query apply")
    DebugLogPrivate("Qbar applied query", text)
    if text = "" {
        if QbarEsMode
            QbarEsCancelJob("empty query")
        QbarEsMode := false
        QbarSendResults([], false)
        return
    }
    hasArgument := QbarSplitCommand(text, &firstToken, &rest)
    ; "e <query>" (and its aliases) searches files; a configured trigger of the
    ; same name still wins.
    if hasArgument && !QbarConfigShortKeyExists(firstToken) && QbarEsAlias(firstToken) {
        if rest = "" {
            QbarEsCancelJob("empty Everything argument")
            QbarEsMode := false
            QbarSendResults(QbarFilterItems(text), false)
        } else {
            QbarEsRequest(rest)
        }
        return
    }
    if QbarEsMode
        QbarEsCancelJob("left Everything mode")
    QbarEsMode := false
    if QbarIsFolderQuery(text) {
        items := QbarFilterFolder(text)
        ; An empty folder still shows one row, like the reference does.
        placeholder := (items.Length = 0 && QbarLeafOf(text) = "")
            ? QbarText("(empty folder)", "（空文件夹）")
            : ""
        QbarSendResults(items, true, placeholder)
        return
    }
    results := QbarFilterItems(text)
    ; The AI option is the default first row whenever the line is not an
    ; explicit command -- that is, nothing matched a trigger exactly (no
    ; pinned row). Enter then asks the assistant with the line as-is, while
    ; partial matches stay right below for arrow-down selection. The row
    ; carries the typed text as its short key, so executing it asks exactly
    ; that.
    explicitCommand := false
    for item in results {
        if item.Has("pinned") && item["pinned"] {
            explicitCommand := true
            break
        }
    }
    if !explicitCommand && Trim(text) != ""
        results.InsertAt(1, Map(
            "short", text,
            "label", QbarText("Ask AI  ⏎  ", "AI 问答  ⏎  ") . text,
            "type", "ai",
            "pinned", true,
            "icon", ""
        ))
    QbarSendResults(results, false)
}

; A configured trigger always wins over path browsing, matching the reference
; implementation's check before it switches into folder-browse mode.

QbarIsFolderQuery(text) {
    QbarSplitCommand(text, &firstToken, &rest)
    if QbarConfigShortKeyExists(text) || QbarConfigShortKeyExists(firstToken)
        return false
    return QbarFolderOf(text) != ""
}

QbarFilterItems(text) {
    QbarSplitCommand(text, &matchStrLeft, &rest)
    glob := QbarGlobToRegEx(text)
    results := []
    for item in QbarAllItems() {
        short := item["short"]
        if !(RegExMatch(item["label"], glob) || short = matchStrLeft)
            continue
        ; An exact trigger match floats to the top (reference: column 3 pinning).
        pinned := short = matchStrLeft
        results.Push(Map(
            "short", short,
            "label", item["label"],
            "type", item["type"],
            "pinned", pinned,
            "icon", item.Has("icon") ? item["icon"] : ""
        ))
    }
    return results
}

QbarFilterFolder(text) {
    dir := QbarFolderOf(text)
    leaf := QbarLeafOf(text)
    items := QbarFolderItemsFor(dir)
    if leaf = ""
        return items

    glob := QbarGlobToRegEx(leaf)
    results := []
    for item in items {
        if RegExMatch(item["label"], glob)
            results.Push(item)
    }
    return results
}

QbarFolderItemsFor(dir) {
    global QbarFolderDir, QbarFolderItems
    if dir = QbarFolderDir
        return QbarFolderItems
    items := []
    try {
        Loop Files, dir . "*", "FD" {
            if InStr(FileExist(A_LoopFileFullPath), "H")
                continue
            isFolder := InStr(FileExist(A_LoopFileFullPath), "D") ? true : false
            items.Push(Map(
                "short", A_LoopFileName,
                "label", A_LoopFileName,
                "type", isFolder ? "folder" : "file",
                "value", A_LoopFileFullPath,
                "pinned", false,
                "icon", isFolder ? "folder" : IconKeyForPath(A_LoopFileFullPath)
            ))
        }
    } catch as folderError {
        DebugLog("Folder listing failed")
        DebugLogPrivate("Folder listing path", dir)
    }
    QbarFolderDir := dir
    QbarFolderItems := items
    return items
}

QbarSendResults(results, folderMode, placeholder := "") {
    global IconSent
    rows := []
    icons := Map()
    for item in results {
        row := Map("short", item["short"], "label", item["label"], "type", item["type"],
            "pinned", item.Has("pinned") && item["pinned"] ? JSON.true : JSON.false)
        iconKey := item.Has("icon") ? item["icon"] : ""
        if iconKey != "" {
            row["icon"] := iconKey
            ; First use of a key extracts and caches the data URI right here;
            ; the page only ever receives each key once.
            uri := IconDataURI(iconKey)
            if uri != "" && !IconSent.Has(iconKey) {
                IconSent[iconKey] := true
                icons[iconKey] := uri
            }
        }
        rows.Push(row)
    }
    ; Icons go first so the rows that reference them render with them in
    ; place; PanelHostExecute runs submitted scripts in order.
    if icons.Count
        QbarExec("window.addIcons(" . JSON.stringify(icons, 0) . ");")
    QbarExec("window.setResults(" . JSON.stringify(rows, 0) . "," . (folderMode ? "true" : "false")
        . "," . LLMJsonQuote(placeholder) . ");")
}

; ---------------------------------------------------------------------------
; Execution (the core of the reference ButtonSubmit label)
; ---------------------------------------------------------------------------

QbarConfigShortKeyExists(token) {
    token := Trim(token)
    if token = ""
        return false
    byShort := QbarConfigIndex()["byShort"]
    return byShort.Has(token) && byShort[token]["configured"]
}

QbarConfigEntry(section, shortKey) {
    token := Trim(shortKey)
    if token = ""
        return 0
    byShort := QbarConfigIndex()["byShort"]
    if !byShort.Has(token) || !byShort[token].Has(section)
        return 0
    return byShort[token][section]
}

QbarFindByShort(items, shortKey) {
    for item in items {
        if item["short"] = shortKey
            return item
    }
    return 0
}

; Glob to regex, matching the reference easyGlobToRegEx: everything except * and
; ? is quoted, so the query is a literal search with optional wildcards.

QbarGlobToRegEx(glob) {
    pattern := RegExReplace(glob, "[^*?]+", "\Q$0\E")
    pattern := StrReplace(pattern, "*", ".*")
    pattern := StrReplace(pattern, "?", ".")
    return "iS)" . pattern
}
