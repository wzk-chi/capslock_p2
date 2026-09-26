; qbar item index, filtering, and row preparation.

QbarAllItems() {
    items := []
    for item in QbarConfigItems()
        items.Push(item)
    for item in QbarStartMenuItems()
        items.Push(item)
    return items
}

QbarConfigItems() {
    items := []
    ; Trigger rows for the built-in commands, so they are discoverable and
    ; Tab-completable like the search engines are. Enter with no argument
    ; arms the trigger and lets the question be typed after it.
    items.Push(Map("short", "q", "label", "q <AI 问答 ai>", "type", "search", "value", ""))
    ; The Everything trigger row, so the alias list in the label makes the file
    ; search discoverable and Tab-completable like the search engines are.
    items.Push(Map("short", "e", "label", "e <文件搜索 everything|find|f>", "type", "search", "value", ""))
    for entry in QbarSearchEntries()
        items.Push(entry)
    for key, value in ConfigSection("QRun") {
            if Trim(value) = ""
                continue
            ; Resolve *RunAs / quoting / parameters once: the resolved target
            ; decides both the row type and its icon key.
            runString := "", runAsAdmin := false, parameters := ""
            resolved := ExtractSetString(value, &runString, &runAsAdmin, &parameters)
            if resolved = ""
                resolved := Trim(value)
            isFolder := CheckStringType(resolved) = "folder"
            items.Push(Map(
                "short", QbarShortKey(key),
                "label", key,
                "type", isFolder ? "folder" : "file",
                "value", value,
                "icon", isFolder ? "folder" : IconKeyForPath(resolved)
            ))
        }
    }
    for key, value in ConfigSection("QWeb") {
            if Trim(value) = ""
                continue
            items.Push(Map("short", QbarShortKey(key), "label", key, "type", "web", "value", value))
        }
    }
    return items
}

; [QSearch] entries, plus the built-in engines for every trigger the settings do
; not define -- so adding one entry replaces only the trigger it names rather
; than dropping the whole set. The special key "default" is never listed.

QbarSearchEntries() {
    entries := []
    configured := Map()
    for key, value in ConfigSection("QSearch") {
            if Trim(value) = "" || QbarShortKey(key) = "default"
                continue
            short := QbarShortKey(key)
            configured[StrLower(short)] := true
            entries.Push(Map("short", short, "label", key, "type", "search", "value", value))
        }
    }

    defaults := [
        Map("key", "bd",   "label", "bd <百度>",      "value", "https://www.baidu.com/s?wd={q}"),
        Map("key", "g",    "label", "g <谷歌 gg>",    "value", "https://www.google.com/search?q={q}"),
        Map("key", "bing", "label", "bing <必应>",    "value", "https://www.bing.com/search?q={q}"),
        Map("key", "wk",   "label", "wk <维基百科>",  "value", "https://zh.wikipedia.org/w/index.php?search={q}"),
        Map("key", "m",    "label", "m <MDN mdn>",    "value", "https://developer.mozilla.org/zh-CN/search?q={q}")
    ]
    ; "s" is the plain one-word trigger. Its engine follows the interface
    ; language, since Bing and Google are each the better default where they are
    ; the one the system already leans on.
    if IsChineseLanguage()
        defaults.InsertAt(1, Map("key", "s", "label", "s <搜索>", "value", "https://www.bing.com/search?q={q}"))
    else
        defaults.InsertAt(1, Map("key", "s", "label", "s <search>", "value", "https://www.google.com/search?q={q}"))
    for entry in defaults {
        if configured.Has(StrLower(entry["key"]))
            continue
        entries.Push(Map("short", entry["key"], "label", entry["label"], "type", "search", "value", entry["value"]))
    }
    return entries
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
        DebugLog("Qbar query stale seq=" . querySeq . " latest=" . QbarQuerySeq)
        DebugLogPrivate("Qbar stale query", text)
        return
    }
    text := Trim(text, " `t")
    DebugLog("Qbar query apply seq=" . querySeq)
    DebugLogPrivate("Qbar applied query", text)
    if text = "" {
        QbarEsMode := false
        QbarSendResults([], false)
        return
    }
    firstToken := QbarFirstToken(text)
    ; "e <query>" (and its aliases) searches files; a configured trigger of the
    ; same name still wins.
    if firstToken != text && !QbarConfigShortKeyExists(firstToken) && QbarEsAlias(firstToken) {
        QbarEsRequest(text, firstToken)
        return
    }
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
    if QbarConfigShortKeyExists(text) || QbarConfigShortKeyExists(QbarFirstToken(text))
        return false
    return QbarFolderOf(text) != ""
}

QbarFilterItems(text) {
    matchStrLeft := QbarFirstToken(text)
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
    if Trim(token) = ""
        return false
    for section in ["QRun", "QWeb", "QSearch"] {
        for key, value in ConfigSection(section) {
            if QbarShortKey(key) = token
                return true
        }
    }
    return false
}

QbarConfigItemsOf(section) {
    items := []
    for key, value in ConfigSection(section) {
        if Trim(value) = ""
            continue
        items.Push(Map("short", QbarShortKey(key), "label", key, "value", value))
    }
    return items
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
