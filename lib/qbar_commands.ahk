; qbar command dispatch, configured actions, and safe launching.

QbarExecute(text, selected, ctrlHeld, selectedType := "") {
    text := Trim(text, " `t")
    ; "键 ->类型 值" adds an entry to the settings file. It is decided on the
    ; typed text alone and before the row handling, because the row for the
    ; trigger would otherwise replace the command with just the trigger.
    if QbarTryInlineConfig(text)
        return
    if selected != "" {
        ; The AI option row asks with the typed text as-is. A bare trigger
        ; word only shows the hint (handled inside QbarAiAsk).
        if selectedType = "ai" {
            QbarAiAsk(selected)
            return
        }
        if selectedType = "search" {
            ; An engine row is armed only while there is nothing to search for
            ; yet: it fills the trigger in and leaves the caret after it. Once
            ; the line already reads "trigger query", the row is just the pinned
            ; match for its own trigger, so fall through and search with it
            ; rather than clearing what was typed.
            if QbarSearchArgument(text, selected) = "" {
                QbarExec("window.startSearch(" . LLMJsonQuote(selected) . ");")
                return
            }
        } else {
            ; A highlighted row wins over the typed text. In folder mode the
            ; selected name replaces the leaf of the typed path.
            if QbarIsFolderQuery(text)
                text := QbarFolderOf(text) . selected
            else
                text := selected
        }
    }
    if text = ""
        return
    DebugLog("QbarExecute ctrl=" . ctrlHeld . " selectedType=" . selectedType)
    DebugLogPrivate("Qbar execute", text)

    if ctrlHeld {
        ; A highlighted file or folder row is revealed in Explorer instead of
        ; the domain fallback -- mainly for Everything results, but folder
        ; browsing gets it too.
        if selected != "" && (selectedType = "file" || selectedType = "folder") {
            QbarLocateInExplorer(text)
            return
        }
        ; Ctrl+Enter otherwise treats the typed text as a domain name.
        QbarOpenUrl("www." . text . ".com")
        return
    }

    firstToken := QbarFirstToken(text)
    if firstToken != text {
        rest := Trim(SubStr(text, StrLen(firstToken) + 1), " `t")
        ; Everything trigger: refresh the live results right away in case the
        ; debounce timer has not fired yet, and keep the panel open.
        if !QbarConfigShortKeyExists(firstToken) && QbarEsAlias(firstToken) {
            QbarEsFlushNow(rest)
            return
        }
        ; "ai <question>" / "q <question>" -- the configured LLM answers or
        ; explains; an ini entry named ai/q wins over the built-in command.
        if !QbarConfigShortKeyExists(firstToken) && QbarAiAlias(firstToken) {
            QbarAiAsk(rest)
            return
        }
        ; "cl <sub>" -- version display and a shortcut to the settings files.
        if QbarTryClCommand(firstToken, rest)
            return
        ; "web <url>" opens whatever follows as a site, http:// added when it
        ; is missing; a configured "web" trigger wins over the command word.
        if firstToken = "web" && !QbarConfigShortKeyExists("web") {
            QbarOpenUrl(rest)
            return
        }
        ; Search engine trigger: substitute {q} with the URL-encoded argument.
        search := QbarFindByShort(QbarSearchEntries(), firstToken)
        if !IsObject(search)
            search := QbarFindByShort(QbarSearchEntries(), QbarEngineAlias(firstToken))
        if IsObject(search) {
            QbarOpenUrl(StrReplace(search["value"], "{q}", QbarUrlEncode(rest)))
            return
        }
        if QbarRunBy(firstToken, rest)
            return
    }

    if QbarRunBy(text)
        return
    web := QbarFindByShort(QbarConfigItemsOf("QWeb"), text)
    if IsObject(web) {
        QbarOpenUrl(web["value"])
        return
    }
    app := QbarFindByShort(QbarStartMenuItems(), text)
    if IsObject(app) {
        QbarRunShortcut(app)
        return
    }

    ; "type" would shadow the built-in Type() function in the global namespace.
    stringType := CheckStringType(text)
    if stringType = "file" || stringType = "folder" || stringType = "ftp" {
        QbarOpenPath(text)
        return
    }
    if stringType = "web" {
        QbarOpenUrl(text)
        return
    }

    ; Searching stays deliberate: only a [QSearch] trigger searches. A line
    ; that matched nothing at all becomes a question for the configured LLM --
    ; the launcher's catch-all instead of doing nothing.
    DebugLog("QbarExecute no match, asking AI")
    DebugLogPrivate("Qbar AI question", text)
    QbarAiAsk(text)
}

; Handles "键 ->类型 值", which adds one entry to the settings file so qbar can
; be extended without leaving it. Returns true when the text was such a command,
; so the caller stops.

QbarTryInlineConfig(text) {
    firstToken := QbarFirstToken(text)
    if firstToken = text
        return false
    rest := Trim(SubStr(text, StrLen(firstToken) + 1), " `t")
    arrowWord := QbarFirstToken(rest)
    if !RegExMatch(arrowWord, "^->(.*)$", &match)
        return false
    value := Trim(SubStr(rest, StrLen(arrowWord) + 1), " `t")
    if value = ""
        return false
    section := QbarInlineSection(match[1], value)
    if section = ""
        return false
    QbarAddSetting(section, firstToken, value)
    return true
}

; The settings section an inline command writes to, or "" when the arrow asks
; for nothing recognisable -- in that case the text is left to the normal
; triggers rather than being swallowed.

QbarInlineSection(arrowWord, value) {
    switch StrLower(Trim(arrowWord)) {
        case "run", "qrun", "path", "file", "folder", "ftp":
            return "QRun"
        case "web", "qweb":
            return "QWeb"
        case "search", "qsearch":
            return "QSearch"
        case "str", "string", "hotstring", "tabhotstring":
            return "TabHotString"
        case "":
            ; A bare arrow guesses from the value: a URL carrying {q} is a
            ; search, whatever the shell can classify is a path or a site, and
            ; anything left over becomes a hotstring.
            if RegExMatch(value, "i)(http:|www|\.com|\.net|\.org).*\{q\}")
                return "QSearch"
            detected := CheckStringType(value)
            if detected = "file" || detected = "folder" || detected = "ftp"
                return "QRun"
            if detected = "web"
                return "QWeb"
            return "TabHotString"
        default:
            return ""
    }
}

; Adds one entry, asking first and asking again before replacing a key that is
; already configured. TabHotString values keep a literal \n so the file stays
; one line per key.

QbarAddSetting(section, key, value) {
    prompt := QbarText("Add to ", "添加到 ") . "[" . section . "]`n`n" . key . "=" . value
    if MsgBox(prompt, "qbar", "OKCancel") != "OK"
        return

    existing := ""
    existing := ConfigRead(section, key, "")
    if existing != "" {
        prompt := QbarText("That key is already set. Replace it?", "该键已存在，要覆盖吗？")
        prompt .= "`n`n" . key . "=" . existing . "`n`n-> " . key . "=" . value
        if MsgBox(prompt, "qbar", "OKCancel") != "OK"
            return
    }

    if section = "TabHotString"
        value := StrReplace(StrReplace(value, "\n", "`n"), "`n", "\n")

    if ConfigSet(section, key, value)
        ShowMsg(QbarText("Added ", "已添加 ") . key, 1500)
}

; "cl <sub>" -- the built-in command surface of the reference bar: version
; display and a shortcut to the settings center. Its pay/donate entries point
; at the original author and stay out. Returns true when the line was a cl command.

QbarTryClCommand(cmd, param) {
    global AppName, AppVersion
    if cmd != "cl"
        return false
    if param = "version" || param = "about" {
        ShowMsg(AppName . "  " . AppVersion, 4000)
        return true
    }
    if param = "set" || param = "settings" {
        QbarHide()
        ; Qbar commands arrive from a WebView2 callback. Defer creation of the
        ; settings WebView until that callback has returned.
        SetTimer(SettingsShow, -1)
        return true
    }
    ShowMsg(QbarText("Unknown cl command: ", "未知的 cl 命令：") . param, 2500)
    return true
}

; The reference answers to a couple of alternative engine spellings (g/gg,
; m/mdn). A configured trigger that really is "gg" or "mdn" is looked up first
; and wins, so this only fills the gaps.

QbarEngineAlias(token) {
    static aliases := Map("gg", "g", "mdn", "m")
    lower := StrLower(token)
    return aliases.Has(lower) ? aliases[lower] : token
}

; Triggers for the AI answer/explain command.

QbarAiAlias(token) {
    static aliases := Map("ai", true, "q", true)
    return aliases.Has(StrLower(token))
}

; Closes the launcher and opens the AI chat with the text as the question;
; when the API is not configured yet the chat opens its settings view first,
; and asks the question once settings are saved.

QbarAiAsk(text) {
    text := Trim(text)
    ; A bare trigger word ("ai"/"q" with nothing after it) is not a question;
    ; neither is an empty line. Both only ask for input.
    if text = "" || QbarAiAlias(text) {
        ShowMsg(QbarText("Type a question after the trigger, e.g.: q what is MFT", "输入要问的内容，例如：q 什么是 MFT"), 3000)
        return
    }
    QbarHide()
    AiChatShow(text)
}

QbarRunBy(shortKey, params := "") {
    entry := QbarFindByShort(QbarConfigItemsOf("QRun"), shortKey)
    if !IsObject(entry)
        return false

    if params != "" {
        ; The argument may itself be another entry's trigger (reference qrunBy).
        replacement := QbarFindByShort(QbarConfigItemsOf("QWeb"), params)
        if IsObject(replacement)
            params := replacement["value"]
        else {
            replacement := QbarFindByShort(QbarConfigItemsOf("QRun"), params)
            if IsObject(replacement)
                params := replacement["value"]
        }
    }

    command := QbarRunCommand(entry["value"], params)
    try {
        Run(command)
        QbarHide()
    } catch as runError {
        DebugLog("Qbar run failed")
        ShowMsg(QbarText("Cannot run: ", "无法运行：") . entry["value"], 2500)
    }
    return true
}

; Build a Run()-ready command from an ini value: honours "*RunAs", quoted paths
; and extra parameters, and quotes a bare path that contains spaces (Run needs
; quotes for those).

QbarRunCommand(value, params := "") {
    runString := ""
    runAsAdmin := false
    parameters := ""
    resolved := ExtractSetString(value, &runString, &runAsAdmin, &parameters)
    if resolved != ""
        command := runString . (parameters = "" ? "" : " " . parameters)
    else if FileExist(Trim(value))
        command := Chr(34) . Trim(value) . Chr(34)
    else
        command := Trim(value)
    if runAsAdmin
        command := "*RunAs " . command
    if params != ""
        command .= " " . Chr(34) . params . Chr(34)
    return command
}

QbarRunShortcut(item) {
    try {
        Run(QbarFilesystemTarget(item["value"]))
        QbarHide()
        return
    } catch {
        ; Fall through to the target executable when the .lnk is stale.
    }
    try {
        Run(QbarFilesystemTarget(item["exe"]))
        QbarHide()
    } catch as runError {
        DebugLog("Qbar start menu run failed")
        ShowMsg(QbarText("Cannot run: ", "无法运行：") . item["label"], 2500)
    }
}

; Run() accepts a bare path through ShellExecute, but quoting an existing path
; avoids trouble when it contains spaces. URLs are left untouched.

QbarFilesystemTarget(target) {
    target := Trim(target)
    if target = "" || RegExMatch(target, "i)^(https?|ftp)://")
        return target
    return FileExist(target) ? Chr(34) . target . Chr(34) : target
}

; Values typed as "www.host" or "host" become http:// URLs.

QbarOpenUrl(url) {
    url := Trim(url)
    if url = ""
        return
    if !RegExMatch(url, "i)^(https?|ftp)://")
        url := "http://" . url
    QbarOpenPath(url)
}

; Local files, folders and already-formed URLs go straight to the shell.

QbarOpenPath(path) {
    path := Trim(path)
    if path = ""
        return
    target := QbarFilesystemTarget(path)
    try {
        Run(target)
        QbarHide()
    } catch as runError {
        DebugLog("Qbar open failed")
        ShowMsg(QbarText("Cannot open: ", "无法打开：") . path, 2500)
    }
}

; Ctrl+Enter on a file row: reveal it in Explorer with the item selected. A
; folder row just opens, since there is nothing to select inside itself.

QbarLocateInExplorer(path) {
    path := Trim(path)
    if path = ""
        return
    if DirExist(path) {
        QbarOpenPath(path)
        return
    }
    parent := ""
    SplitPath(path, , &parent)
    if parent = "" || !DirExist(parent) {
        ShowMsg(QbarText("Not found: ", "找不到：") . path, 2500)
        return
    }
    try {
        Run("explorer.exe /select," . Chr(34) . path . Chr(34))
        QbarHide()
    } catch as runError {
        DebugLog("Qbar locate failed")
        ShowMsg(QbarText("Cannot open: ", "无法打开：") . path, 2500)
    }
}
