; qbar Everything backend and CSV decoding.

QbarEsRequest(arg) {
    global QbarEsMode, QbarEsPending, QbarEsSeq, QbarEsLastResults
    QbarEsCancelJob("new query")
    QbarEsSeq += 1
    if arg = "" {
        ; Only the trigger so far: back to the normal list, which pins the
        ; trigger row itself.
        QbarEsMode := false
        return
    }
    QbarEsMode := true
    QbarEsPending := arg
    QbarSendResults(QbarEsLastResults, false)
    SetTimer(QbarEsFlush, -100)
}

QbarEsFlush() {
    global QbarEsPending, QbarEsSeq, QbarEsMode, QbarVisible
    if !QbarEsMode || !QbarVisible
        return
    seq := QbarEsSeq
    arg := QbarEsPending
    QbarEsResolveBackend(arg, seq)
}

; Enter on a typed "e <query>" line: flush the pending search immediately so a
; race with the debounce cannot leave the list stale.

QbarEsFlushNow(arg) {
    global QbarEsMode, QbarEsPending, QbarEsSeq
    if arg = ""
        return
    QbarEsCancelJob("immediate query")
    QbarEsSeq += 1
    QbarEsMode := true
    QbarEsPending := arg
    QbarEsResolveBackend(arg, QbarEsSeq)
}

; Triggers that switch qbar into Everything file search, all equivalent.

QbarEsAlias(token) {
    static aliases := Map("e", true, "everything", true, "find", true, "f", true)
    return aliases.Has(StrLower(token))
}

QbarEsResolveBackend(arg, seq) {
    global QbarEsUseBundled
    exe := QbarEsExe()
    if exe = "" {
        QbarEsHint(QbarText("es.exe is missing from the resources directory.", "资源目录中缺少 es.exe。"))
        return false
    }
    if QbarEsUseBundled = -1
        return QbarEsStartSearch(arg, -1, seq)
    if QbarEsUseBundled = 1
        return QbarEsEnsureBundled(arg, seq)
    if ProcessExist("Everything.exe")
        return QbarEsStartProbe("default", seq, arg)
    QbarEsUseBundled := 1
    return QbarEsEnsureBundled(arg, seq)
}

; Starts the bundled copy under its own instance name with its own config and
; database. A probe is always attempted first, so shutdown only exits a server
; this qbar session actually launched.

QbarEsEnsureBundled(arg, seq) {
    global QbarEsBundledState, QbarEsBundledFailed
    if QbarEsBundledFailed || QbarEsBundledState = "failed" {
        QbarEsHint(QbarText("No Everything backend is available.", "没有可用的 Everything 后端。"))
        return false
    }
    if QbarEsBundledState = "reachable"
        return QbarEsStartSearch(arg, 1, seq)
    if QbarEsBundledState = "starting"
        return QbarEsScheduleRetry(seq, arg, 250)
    if QbarEsEverythingExe() = "" {
        QbarEsBundledState := "failed"
        QbarEsBundledFailed := true
        QbarEsHint(QbarText("No Everything available for file search.", "没有可用的 Everything，文件搜索不可用。"))
        return false
    }
    return QbarEsStartProbe("bundled", seq, arg)
}

QbarEsLaunchBundled(seq, arg) {
    global QbarEsBundledStarted, QbarEsBundledState, QbarEsWarmupDeadline, QbarEsBundledFailed
    exe := QbarEsEverythingExe()
    if exe = "" {
        QbarEsHint(QbarText("No Everything available for file search.", "没有可用的 Everything，文件搜索不可用。"))
        QbarEsBundledFailed := true
        QbarEsBundledState := "failed"
        return false
    }
    dataDir := EnvGet("LOCALAPPDATA") . "\capslock_p2\Everything"
    try DirCreate(dataDir)
    command := QbarEsQuoteArg(exe) . " -instance " . QbarEsQuoteArg(QbarEsInstanceName())
        . " -startup -config " . QbarEsQuoteArg(dataDir . "\Everything.ini")
        . " -db " . QbarEsQuoteArg(dataDir . "\Everything.db")
    try Run("*RunAs " . command)
    catch {
        DebugLog("Bundled Everything start declined")
        QbarEsHint(QbarText("File search needs admin rights to build the index.", "文件搜索需要管理员权限来建立索引。"))
        QbarEsBundledFailed := true
        QbarEsBundledState := "failed"
        return false
    }
    QbarEsBundledStarted := true
    QbarEsBundledState := "starting"
    QbarEsWarmupDeadline := A_TickCount + 15000
    DebugLog("Bundled Everything starting instance=" . QbarEsInstanceName())
    return QbarEsScheduleRetry(seq, arg, 250)
}

QbarEsStartProbe(kind, seq, arg := "") {
    global QbarEsUseBundled
    useBundled := kind = "bundled" ? 1 : -1
    if QbarEsStartProcess("probe-" . kind, arg, useBundled, seq, 3000)
        return true
    if !QbarEsRequestIsCurrent(seq)
        return false
    if kind = "default" {
        QbarEsUseBundled := 1
        return QbarEsEnsureBundled(arg, seq)
    }
    return QbarEsLaunchBundled(seq, arg)
}

QbarEsStartSearch(arg, useBundled, seq) {
    global QbarEsUseBundled, QbarEsBundledState, QbarEsWarmupDeadline
    if QbarEsStartProcess("search", arg, useBundled, seq, 5000)
        return true
    if !QbarEsRequestIsCurrent(seq)
        return false
    if useBundled = -1 {
        QbarEsUseBundled := 1
        return QbarEsEnsureBundled(arg, seq)
    }
    if QbarEsBundledState = "starting" && A_TickCount < QbarEsWarmupDeadline
        return QbarEsScheduleRetry(seq, arg, 750)
    QbarEsHint(QbarText("Unable to start Everything search.", "无法启动 Everything 搜索。"))
    return false
}

QbarEsStartProcess(kind, arg, useBundled, seq, timeoutMs) {
    global QbarEsJob, QbarEsJobId
    exe := QbarEsExe()
    if exe = ""
        return false
    QbarEsClearJob(true)
    QbarEsJobId += 1
    jobId := QbarEsJobId
    tmp := QbarEsTempPath(seq, jobId)
    instance := useBundled = 1 ? " -instance " . QbarEsQuoteArg(QbarEsInstanceName()) : ""
    limit := SubStr(kind, 1, 6) = "probe-" ? 1 : QbarEsMaxResults()
    query := SubStr(kind, 1, 6) = "probe-" ? "1" : arg
    command := QbarEsQuoteArg(exe) . instance . " -csv -no-header -n " . limit
        . " -full-path-and-name -export-csv " . QbarEsQuoteArg(tmp)
        . " " . QbarEsQuoteArg(query)
    pid := 0
    try Run(command, "", "Hide", &pid)
    catch as launchError {
        try FileDelete(tmp)
        DebugLog("Es client launch failed")
        return false
    }
    handle := DllCall("OpenProcess", "uint", 0x101000, "int", false, "uint", pid, "ptr")
    QbarEsJob := Map(
        "id", jobId,
        "kind", kind,
        "seq", seq,
        "pid", pid,
        "handle", handle,
        "tmpPath", tmp,
        "startedAt", A_TickCount,
        "deadline", A_TickCount + timeoutMs,
        "useBundled", useBundled,
        "arg", arg,
        "owner", "qbar-es-client")
    SetTimer(QbarEsPollJob, -50)
    if !ProcessExist(pid)
        QbarEsPollJob()
    return true
}

QbarEsScheduleRetry(seq, arg, delayMs) {
    global QbarEsJob, QbarEsJobId, QbarEsWarmupDeadline
    QbarEsClearJob(true)
    QbarEsJobId += 1
    QbarEsJob := Map(
        "id", QbarEsJobId,
        "kind", "retry",
        "seq", seq,
        "pid", 0,
        "handle", 0,
        "tmpPath", "",
        "startedAt", A_TickCount,
        "deadline", QbarEsWarmupDeadline,
        "nextAttempt", A_TickCount + delayMs,
        "useBundled", 1,
        "arg", arg,
        "owner", "qbar-timer")
    SetTimer(QbarEsPollJob, -50)
    return true
}

QbarEsPollJob(*) {
    global QbarEsJob, QbarEsBundledState, QbarEsUseBundled
    if !IsObject(QbarEsJob)
        return
    job := QbarEsJob
    if !QbarEsJobIsCurrent(job) {
        QbarEsClearJob(true)
        return
    }
    if job["kind"] = "retry" {
        if A_TickCount >= job["deadline"] {
            QbarEsClearJob(false)
            QbarEsBundledState := "unknown"
            QbarEsUseBundled := 0
            QbarEsHint(QbarText("Everything is still building its index.", "Everything 仍在建立索引。"))
            return
        }
        if A_TickCount < job["nextAttempt"] {
            SetTimer(QbarEsPollJob, -100)
            return
        }
        seq := job["seq"], arg := job["arg"]
        QbarEsClearJob(false)
        QbarEsStartSearch(arg, 1, seq)
        return
    }

    pending := false
    if job["handle"]
        pending := DllCall("WaitForSingleObject", "ptr", job["handle"], "uint", 0, "uint") = 0x102
    else
        pending := ProcessExist(job["pid"]) != 0
    if pending {
        if A_TickCount >= job["deadline"] {
            QbarEsFinishJob(job, -1, true)
            return
        }
        SetTimer(QbarEsPollJob, -50)
        return
    }
    exitCode := QbarEsExitCode(job)
    QbarEsFinishJob(job, exitCode)
}

QbarEsFinishJob(job, exitCode, timedOut := false) {
    global QbarEsUseBundled, QbarEsBundledState, QbarEsWarmupDeadline
    if !QbarEsSameJob(job)
        return
    kind := job["kind"], seq := job["seq"], arg := job["arg"]
    useBundled := job["useBundled"]
    results := (!timedOut && exitCode = 0 && kind = "search")
        ? QbarParseEsCsv(job["tmpPath"])
        : []
    QbarEsClearJob(timedOut)
    if !QbarEsRequestIsCurrent(seq)
        return

    if kind = "probe-default" {
        if !timedOut && exitCode = 0 {
            QbarEsUseBundled := -1
            DebugLog("Es backend=default")
            QbarEsStartSearch(arg, -1, seq)
        } else {
            QbarEsUseBundled := 1
            QbarEsEnsureBundled(arg, seq)
        }
        return
    }
    if kind = "probe-bundled" {
        if !timedOut && exitCode = 0 {
            QbarEsUseBundled := 1
            QbarEsBundledState := "reachable"
            DebugLog("Es backend=bundled-existing")
            QbarEsStartSearch(arg, 1, seq)
        } else
            QbarEsLaunchBundled(seq, arg)
        return
    }

    if useBundled = -1 && (timedOut || exitCode != 0) {
        DebugLog("Es default backend unavailable; switching to bundled")
        QbarEsUseBundled := 1
        QbarEsEnsureBundled(arg, seq)
        return
    }
    if useBundled = 1 && (timedOut || exitCode != 0) {
        if QbarEsBundledState = "starting" && A_TickCount < QbarEsWarmupDeadline {
            QbarEsScheduleRetry(seq, arg, 750)
            return
        }
        QbarEsBundledState := "unknown"
        QbarEsUseBundled := 0
        QbarEsHint(QbarText("Everything search did not respond.", "Everything 搜索未响应。"))
        return
    }
    if useBundled = 1 {
        QbarEsBundledState := "reachable"
        QbarEsWarmupDeadline := 0
    }
    DebugLog("Es search results=" . results.Length)
    QbarEsPublishResults(results, seq)
}

QbarEsPublishResults(results, seq) {
    global QbarEsLastResults
    if !QbarEsRequestIsCurrent(seq)
        return
    QbarEsLastResults := results
    QbarSendResults(results, false)
}

QbarEsCancelJob(reason := "") {
    global QbarEsSeq
    SetTimer(QbarEsFlush, 0)
    QbarEsSeq += 1
    QbarEsClearJob(true)
    if reason != ""
        DebugLog("Es job cancelled")
}

QbarEsClearJob(closeProcess := true) {
    global QbarEsJob
    SetTimer(QbarEsPollJob, 0)
    if !IsObject(QbarEsJob)
        return
    job := QbarEsJob
    QbarEsJob := 0
    if closeProcess && job["owner"] = "qbar-es-client" {
        running := false
        if job["handle"] {
            exitCode := 0
            running := DllCall("GetExitCodeProcess", "ptr", job["handle"], "uint*", &exitCode)
                && exitCode = 259
        } else
            running := job["pid"] && ProcessExist(job["pid"])
        if running && job["pid"]
            try ProcessClose(job["pid"])
    }
    if job["handle"]
        DllCall("CloseHandle", "ptr", job["handle"])
    if job["tmpPath"] != ""
        try FileDelete(job["tmpPath"])
}

QbarEsSameJob(job) {
    global QbarEsJob
    return IsObject(QbarEsJob) && QbarEsJob["id"] = job["id"]
}

QbarEsJobIsCurrent(job) {
    return QbarEsSameJob(job) && QbarEsRequestIsCurrent(job["seq"])
}

QbarEsRequestIsCurrent(seq) {
    global QbarEsSeq, QbarEsMode, QbarVisible
    return seq = QbarEsSeq && QbarEsMode && QbarVisible
}

QbarEsExitCode(job) {
    if !job["handle"]
        return FileExist(job["tmpPath"]) ? 0 : -1
    exitCode := 0
    if !DllCall("GetExitCodeProcess", "ptr", job["handle"], "uint*", &exitCode)
        return -1
    return exitCode
}

QbarEsTempPath(seq, jobId) {
    processId := DllCall("GetCurrentProcessId", "uint")
    return A_Temp . "\capslock-p2-qbar-es-" . processId . "-" . seq . "-" . A_TickCount . "-" . jobId . ".csv"
}

; Quote one argv element according to the standard Windows backslash/quote
; rules used by C/C++ command-line parsers. es.exe is launched directly, so
; shell metacharacters remain data.

QbarEsQuoteArg(value) {
    quote := Chr(34)
    result := quote
    slashes := 0
    Loop Parse, String(value) {
        character := A_LoopField
        if character = "\" {
            slashes += 1
            continue
        }
        if character = quote
            result .= QbarEsRepeat("\", slashes * 2 + 1) . quote
        else
            result .= QbarEsRepeat("\", slashes) . character
        slashes := 0
    }
    return result . QbarEsRepeat("\", slashes * 2) . quote
}

QbarEsRepeat(text, count) {
    result := ""
    Loop count
        result .= text
    return result
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
    candidate := A_ScriptDir . "\resources\es.exe"
    return FileExist(candidate) ? candidate : ""
}

; The bundled copy lives in a versioned folder under resources; the first
; folder that contains everything.exe wins.

QbarEsEverythingExe() {
    Loop Files, A_ScriptDir . "\resources\*", "D" {
        candidate := A_LoopFileFullPath . "\everything.exe"
        if FileExist(candidate)
            return candidate
    }
    return ""
}

QbarEsInstanceName() {
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
