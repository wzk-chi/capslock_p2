; qbar Everything backend and CSV decoding.

QbarEsRequest(text, firstToken) {
    global QbarEsMode, QbarEsPending, QbarEsSeq, QbarEsLastResults
    arg := Trim(SubStr(text, StrLen(firstToken) + 1), " `t")
    if arg = "" {
        ; Only the trigger so far: back to the normal list, which pins the
        ; trigger row itself.
        QbarEsMode := false
        QbarEsSeq += 1
        SetTimer(QbarEsFlush, 0)
        QbarSendResults(QbarFilterItems(text), false)
        return
    }
    QbarEsMode := true
    QbarEsPending := arg
    QbarEsSeq += 1
    QbarSendResults(QbarEsLastResults, false)
    SetTimer(QbarEsFlush, -100)
}

QbarEsFlush() {
    global QbarEsPending, QbarEsSeq, QbarEsMode, QbarEsLastResults, QbarVisible
    if !QbarEsMode || !QbarVisible
        return
    seq := QbarEsSeq
    arg := QbarEsPending
    results := QbarEsSearch(arg)
    ; A newer query took over while es.exe was running, or the panel closed.
    if seq != QbarEsSeq || !QbarEsMode || !QbarVisible
        return
    QbarEsLastResults := results
    QbarSendResults(results, false)
}

; Enter on a typed "e <query>" line: flush the pending search immediately so a
; race with the debounce cannot leave the list stale.

QbarEsFlushNow(arg) {
    global QbarEsMode, QbarEsPending, QbarEsSeq
    if arg = ""
        return
    QbarEsMode := true
    QbarEsPending := arg
    QbarEsSeq += 1
    QbarEsFlush()
}

; Triggers that switch qbar into Everything file search, all equivalent.

QbarEsAlias(token) {
    static aliases := Map("e", true, "everything", true, "find", true, "f", true)
    return aliases.Has(StrLower(token))
}

QbarEsSearch(arg) {
    global QbarEsUseBundled, QbarEsBundledColdStart
    exe := QbarEsExe()
    if exe = "" {
        QbarEsHint(QbarText("es.exe not found next to the script.", "脚本旁未找到 es.exe。"))
        return []
    }
    useBundled := QbarEsBackend()
    if useBundled = 1 && !QbarEsEnsureBundled()
        return []
    results := QbarEsRun(arg, useBundled, &exitCode)
    ; The user's Everything went away mid-session: re-decide the backend, and
    ; the next query takes the bundled path if it must.
    if useBundled = -1 && exitCode != 0 {
        QbarEsUseBundled := 0
        DebugLog("Es default backend failed exit=" . exitCode . ", backend reset")
    }
    if !results.Length && QbarEsBundledColdStart {
        ; The first index build takes seconds; poll briefly instead of showing
        ; an empty list and going quiet.
        QbarEsBundledColdStart := false
        Loop 10 {
            Sleep(1500)
            results := QbarEsRun(arg, useBundled, &exitCode)
            if results.Length
                break
        }
    }
    DebugLog("Es search results=" . results.Length)
    DebugLogPrivate("Es search argument", arg)
    return results
}

; Decides which Everything answers es.exe: the user's own (default IPC) when it
; is up, otherwise the bundled copy under resources. Decided once per session.

QbarEsBackend() {
    global QbarEsUseBundled
    if QbarEsUseBundled != 0
        return QbarEsUseBundled
    QbarEsUseBundled := QbarEsDefaultAvailable() ? -1 : 1
    DebugLog("Es backend=" . (QbarEsUseBundled = -1 ? "default" : "bundled"))
    return QbarEsUseBundled
}

; The user's own Everything answers the default IPC window. A process check
; first (cheap), then one real es.exe call, which fails fast (exit 8) when the
; window is not reachable.

QbarEsDefaultAvailable() {
    exe := QbarEsExe()
    if exe = "" || !ProcessExist("Everything.exe")
        return false
    tmp := A_Temp . "\qbar-es-probe.txt"
    cmdline := Chr(34) . exe . Chr(34) . " -csv -no-header -n 1 -full-path-and-name " . Chr(34) . "1" . Chr(34)
    exitCode := RunWait(A_ComSpec . " /c " . Chr(34) . cmdline . " > " . Chr(34) . tmp . Chr(34) . " 2>nul" . Chr(34), "", "Hide")
    try FileDelete(tmp)
    return exitCode = 0
}

; Starts the bundled copy under its own instance name with its own config and
; database, so the user's own Everything is never touched. The instance needs
; elevation to read the NTFS index (MFT), which shows one UAC prompt; a probe
; first avoids repeating that prompt when the instance is already up.

QbarEsEnsureBundled() {
    global QbarEsBundledStarted, QbarEsBundledColdStart, QbarEsBundledFailed
    if QbarEsBundledStarted
        return true
    if QbarEsBundledFailed
        return false
    if QbarEsInstanceReachable() {
        QbarEsBundledStarted := true
        DebugLog("Es bundled instance already running")
        return true
    }
    exe := QbarEsEverythingExe()
    if exe = "" {
        QbarEsHint(QbarText("No Everything available for file search.", "没有可用的 Everything，文件搜索不可用。"))
        QbarEsBundledFailed := true
        return false
    }
    dataDir := EnvGet("LOCALAPPDATA") . "\capslock_p2\Everything"
    try DirCreate(dataDir)
    command := Chr(34) . exe . Chr(34) . " -instance " . QbarEsInstanceName()
        . " -startup -config " . Chr(34) . dataDir . "\Everything.ini" . Chr(34)
        . " -db " . Chr(34) . dataDir . "\Everything.db" . Chr(34)
    try Run("*RunAs " . command)
    catch {
        DebugLog("Bundled Everything start declined")
        QbarEsHint(QbarText("File search needs admin rights to build the index.", "文件搜索需要管理员权限来建立索引。"))
        QbarEsBundledFailed := true
        return false
    }
    QbarEsBundledStarted := true
    QbarEsBundledColdStart := true
    DebugLog("Bundled Everything starting instance=" . QbarEsInstanceName())
    return true
}

QbarEsInstanceReachable() {
    exe := QbarEsExe()
    if exe = ""
        return false
    tmp := A_Temp . "\qbar-es-probe.txt"
    cmdline := Chr(34) . exe . Chr(34) . " -instance " . QbarEsInstanceName()
        . " -csv -no-header -n 1 -full-path-and-name " . Chr(34) . "1" . Chr(34)
    exitCode := RunWait(A_ComSpec . " /c " . Chr(34) . cmdline . " > " . Chr(34) . tmp . Chr(34) . " 2>nul" . Chr(34), "", "Hide")
    try FileDelete(tmp)
    return exitCode = 0
}

; Runs one es.exe query into a temp file and parses it. es.exe talks to the
; running Everything over IPC, so once an instance is up this is instant.

QbarEsRun(arg, useBundled, &exitCode) {
    exe := QbarEsExe()
    instance := useBundled = 1 ? " -instance " . QbarEsInstanceName() : ""
    tmp := A_Temp . "\qbar-es-" . A_TickCount . ".txt"
    quotedArg := Chr(34) . StrReplace(arg, Chr(34), Chr(34) . Chr(34)) . Chr(34)
    cmdline := Chr(34) . exe . Chr(34) . instance . " -csv -no-header -n " . QbarEsMaxResults()
        . " -full-path-and-name " . quotedArg
    exitCode := RunWait(A_ComSpec . " /c " . Chr(34) . cmdline . " > " . Chr(34) . tmp . Chr(34) . " 2>nul" . Chr(34), "", "Hide")
    results := QbarParseEsCsv(tmp)
    try FileDelete(tmp)
    return results
}

; es.exe -csv emits one quoted column per row: the full path. Lines cannot
; contain CR/LF (Windows filenames may not), so a plain line split is safe.
; Encoding: this es.exe build writes UTF-8 without a BOM, older builds write
; the system code page -- hence BOM, then a strict UTF-8 check, then CP0.

QbarParseEsCsv(path) {
    results := []
    if !FileExist(path)
        return results
    esFile := FileOpen(path, "r")
    size := esFile.Length
    buf := Buffer(size + 1, 0)
    if size > 0
        esFile.RawRead(buf, size)
    esFile.Close()
    offset := 0
    encoding := "CP0"
    if size >= 3 && NumGet(buf, 0, "UChar") = 0xEF && NumGet(buf, 1, "UChar") = 0xBB && NumGet(buf, 2, "UChar") = 0xBF {
        offset := 3
        encoding := "UTF-8"
    } else if QbarIsValidUtf8(buf, size)
        encoding := "UTF-8"
    text := StrGet(buf.Ptr + offset, encoding)

    quote := Chr(34)
    Loop Parse, text, "`n", "`r" {
        line := A_LoopField
        if line = ""
            continue
        if SubStr(line, 1, 1) = quote && SubStr(line, -1) = quote && StrLen(line) >= 2
            line := StrReplace(SubStr(line, 2, StrLen(line) - 2), quote . quote, quote)
        ; Folder rows end with a backslash, which reads better without.
        if StrLen(line) > 3 && SubStr(line, -1) = "\"
            line := RTrim(line, "\")
        name := ""
        dir := ""
        SplitPath(line, &name, &dir)
        if name = ""
            label := line
        else if dir != ""
            label := name . "  ·  " . dir
        else
            label := name
        isFolder := DirExist(line) ? true : false
        results.Push(Map(
            "short", line,
            "label", label,
            "type", isFolder ? "folder" : "file",
            "pinned", false,
            "icon", isFolder ? "folder" : IconKeyForPath(line)
        ))
    }
    return results
}

; Strict UTF-8 shape check (no BOM required), used to pick between the UTF-8
; and system code page decodings of es.exe output.

QbarIsValidUtf8(buf, size) {
    index := 0
    while index < size {
        byte := NumGet(buf, index, "UChar")
        index += 1
        if byte <= 0x7F
            continue

        minSecond := 0x80
        maxSecond := 0xBF
        if byte >= 0xC2 && byte <= 0xDF {
            expected := 1
        } else if byte = 0xE0 {
            expected := 2
            minSecond := 0xA0
        } else if byte >= 0xE1 && byte <= 0xEC || byte >= 0xEE && byte <= 0xEF {
            expected := 2
        } else if byte = 0xED {
            expected := 2
            maxSecond := 0x9F
        } else if byte = 0xF0 {
            expected := 3
            minSecond := 0x90
        } else if byte >= 0xF1 && byte <= 0xF3 {
            expected := 3
        } else if byte = 0xF4 {
            expected := 3
            maxSecond := 0x8F
        } else {
            return false
        }
        if index + expected > size
            return false
        second := NumGet(buf, index, "UChar")
        if second < minSecond || second > maxSecond
            return false
        Loop expected {
            if (NumGet(buf, index + A_Index - 1, "UChar") & 0xC0) != 0x80
                return false
        }
        index += expected
    }
    return true
}

QbarEsExe() {
    global QbarEsPath
    if QbarEsPath != ""
        return QbarEsPath
    configuredPath := Trim(ConfigRead("Qbar", "esPath", ""))
    if configuredPath != "" {
        candidate := configuredPath
        if FileExist(candidate) {
            QbarEsPath := candidate
            return candidate
        }
    }
    candidate := A_ScriptDir . "\resources\es.exe"
    if FileExist(candidate)
        QbarEsPath := candidate
    return QbarEsPath
}

; The bundled copy lives in a versioned folder under resources; the first
; folder that contains everything.exe wins. [Qbar] everythingPath overrides.

QbarEsEverythingExe() {
    global QbarEsEverythingPath
    if QbarEsEverythingPath != ""
        return QbarEsEverythingPath
    configuredPath := Trim(ConfigRead("Qbar", "everythingPath", ""))
    if configuredPath != "" {
        candidate := configuredPath
        if FileExist(candidate) {
            QbarEsEverythingPath := candidate
            return candidate
        }
    }
    Loop Files, A_ScriptDir . "\resources\*", "D" {
        candidate := A_LoopFileFullPath . "\everything.exe"
        if FileExist(candidate) {
            QbarEsEverythingPath := candidate
            return candidate
        }
    }
    return ""
}

QbarEsInstanceName() {
    configuredName := Trim(ConfigRead("Qbar", "esInstance", ""))
    if configuredName != ""
        return configuredName
    return "capslock_p2"
}

QbarEsMaxResults() {
    return SettingInteger("Qbar", "esMaxResults", 50, 1, 500)
}

; One hint per panel show, so a missing prerequisite does not pop a message on
; every keystroke.

QbarEsHint(text) {
    global QbarEsHintShown
    if QbarEsHintShown
        return
    QbarEsHintShown := true
    ShowMsg(text, 3000)
}

; ---------------------------------------------------------------------------
; Folder navigation (wired to keyFunc_qbar_upperFolderPath / lowerFolderPath)
; ---------------------------------------------------------------------------

