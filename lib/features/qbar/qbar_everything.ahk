; Shared Everything backend and CSV decoding for the independent Everything page.

; Built-in Everything aliases accepted by the qbar adapter, all equivalent.

QbarEsAlias(token) {
    static aliases := Map("e", true, "everything", true, "find", true, "f", true)
    return aliases.Has(StrLower(token))
}

QbarEsResolveBackend(arg, seq, querySeq) {
    global QbarEsUseBundled
    if !QbarEsRequestIsCurrent(seq, querySeq)
        return false
    exe := QbarEsExe()
    if exe = "" {
        QbarEsHint(QbarText("es.exe is missing from the resources directory.", "资源目录中缺少 es.exe。"), seq, querySeq)
        return false
    }
    if QbarEsUseBundled = -1
        return QbarEsStartSearch(arg, -1, seq, querySeq)
    if QbarEsUseBundled = 1
        return QbarEsEnsureBundled(arg, seq, querySeq)
    if ProcessExist("Everything.exe")
        return QbarEsStartProbe("default", seq, arg, querySeq)
    QbarEsUseBundled := 1
    return QbarEsEnsureBundled(arg, seq, querySeq)
}

; Starts the bundled copy under its own instance name with its own config and
; database. A probe is always attempted first, so shutdown only exits a server
; this session actually launched.

QbarEsEnsureBundled(arg, seq, querySeq) {
    global QbarEsBundledState, QbarEsBundledFailed
    if QbarEsBundledFailed || QbarEsBundledState = "failed" {
        QbarEsHint(QbarText("No Everything backend is available.", "没有可用的 Everything 后端。"), seq, querySeq)
        return false
    }
    if QbarEsBundledState = "reachable"
        return QbarEsStartSearch(arg, 1, seq, querySeq)
    if QbarEsBundledState = "starting"
        return QbarEsScheduleRetry(seq, arg, 250, querySeq)
    if QbarEsEverythingExe() = "" {
        QbarEsBundledState := "failed"
        QbarEsBundledFailed := true
        QbarEsHint(QbarText("No Everything available for file search.", "没有可用的 Everything，文件搜索不可用。"), seq, querySeq)
        return false
    }
    return QbarEsStartProbe("bundled", seq, arg, querySeq)
}

QbarEsLaunchBundled(seq, arg, querySeq) {
    global QbarEsBundledStarted, QbarEsBundledState, QbarEsWarmupDeadline, QbarEsBundledFailed
    exe := QbarEsEverythingExe()
    if exe = "" {
        QbarEsHint(QbarText("No Everything available for file search.", "没有可用的 Everything，文件搜索不可用。"), seq, querySeq)
        QbarEsBundledFailed := true
        QbarEsBundledState := "failed"
        return false
    }
    dataDir := EnvGet("LOCALAPPDATA") . "\capslock_p2\Everything"
    try DirCreate(dataDir)
    command := QbarQuoteArg(exe) . " -instance " . QbarQuoteArg(QbarEsInstanceName())
        . " -startup -config " . QbarQuoteArg(dataDir . "\Everything.ini")
        . " -db " . QbarQuoteArg(dataDir . "\Everything.db")
    try Run("*RunAs " . command)
    catch {
        DebugLog("Bundled Everything start declined")
        QbarEsHint(QbarText("File search needs admin rights to build the index.", "文件搜索需要管理员权限来建立索引。"), seq, querySeq)
        QbarEsBundledFailed := true
        QbarEsBundledState := "failed"
        return false
    }
    QbarEsBundledStarted := true
    QbarEsBundledState := "starting"
    QbarEsWarmupDeadline := A_TickCount + 15000
    DebugLog("Bundled Everything starting instance=" . QbarEsInstanceName())
    return QbarEsScheduleRetry(seq, arg, 250, querySeq)
}

QbarEsStartProbe(kind, seq, arg, querySeq) {
    global QbarEsUseBundled
    if !QbarEsRequestIsCurrent(seq, querySeq)
        return false
    useBundled := kind = "bundled" ? 1 : -1
    if QbarEsStartProcess("probe-" . kind, arg, useBundled, seq, 3000, querySeq)
        return true
    if !QbarEsRequestIsCurrent(seq, querySeq)
        return false
    if kind = "default" {
        QbarEsUseBundled := 1
        return QbarEsEnsureBundled(arg, seq, querySeq)
    }
    return QbarEsLaunchBundled(seq, arg, querySeq)
}

QbarEsStartSearch(arg, useBundled, seq, querySeq) {
    global QbarEsUseBundled, QbarEsBundledState, QbarEsWarmupDeadline
    if !QbarEsRequestIsCurrent(seq, querySeq)
        return false
    if QbarEsStartProcess("search", arg, useBundled, seq, 5000, querySeq)
        return true
    if !QbarEsRequestIsCurrent(seq, querySeq)
        return false
    if useBundled = -1 {
        QbarEsUseBundled := 1
        return QbarEsEnsureBundled(arg, seq, querySeq)
    }
    if QbarEsBundledState = "starting" && A_TickCount < QbarEsWarmupDeadline
        return QbarEsScheduleRetry(seq, arg, 750, querySeq)
    QbarEsHint(QbarText("Unable to start Everything search.", "无法启动 Everything 搜索。"), seq, querySeq)
    return false
}

QbarEsStartProcess(kind, arg, useBundled, seq, timeoutMs, querySeq) {
    global QbarEsJob, QbarEsJobId
    if !QbarEsRequestIsCurrent(seq, querySeq)
        return false
    exe := QbarEsExe()
    if exe = ""
        return false
    criticalState := Critical("On")
    QbarEsJobId += 1
    jobId := QbarEsJobId
    Critical(criticalState)
    tmp := QbarEsTempPath(seq, jobId)
    instance := useBundled = 1 ? " -instance " . QbarQuoteArg(QbarEsInstanceName()) : ""
    limit := SubStr(kind, 1, 6) = "probe-"
        ? 1 : Min(501, QbarEsMaxResults() + 1)
    query := SubStr(kind, 1, 6) = "probe-" ? "1" : arg
    command := QbarQuoteArg(exe) . instance . " -csv -no-header -n " . limit
        . " -full-path-and-name -export-csv " . QbarQuoteArg(tmp)
        . " -search* " . query
    pid := 0
    try Run(command, "", "Hide", &pid)
    catch as launchError {
        try FileDelete(tmp)
        DebugLog("Es client launch failed")
        return false
    }
    handle := DllCall("OpenProcess", "uint", 0x101000, "int", false, "uint", pid, "ptr")
    job := Map(
        "id", jobId,
        "kind", kind,
        "seq", seq,
        "pid", pid,
        "handle", handle,
        "tmpPath", tmp,
        "startedAt", A_TickCount,
        "deadline", A_TickCount + timeoutMs,
        "useBundled", useBundled,
        "querySeq", querySeq,
        "arg", arg,
        "owner", "qbar-es-client")
    criticalState := Critical("On")
    installed := false
    try {
        if QbarEsRequestIsCurrent(seq, querySeq) && !IsObject(QbarEsJob) {
            QbarEsJobId := jobId
            QbarEsJob := job
            SetTimer(QbarEsPollJob, -50)
            installed := true
        }
    } finally {
        Critical(criticalState)
    }
    if !installed {
        if handle
            DllCall("CloseHandle", "ptr", handle)
        if ProcessExist(pid)
            try ProcessClose(pid)
        try FileDelete(tmp)
        return false
    }
    if !ProcessExist(pid)
        QbarEsPollJob()
    return true
}

QbarEsScheduleRetry(seq, arg, delayMs, querySeq) {
    global QbarEsJob, QbarEsJobId, QbarEsWarmupDeadline
    criticalState := Critical("On")
    scheduled := false
    try {
        if !QbarEsRequestIsCurrent(seq, querySeq) || IsObject(QbarEsJob)
            return false
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
            "querySeq", querySeq,
            "arg", arg,
            "owner", "qbar-timer")
        SetTimer(QbarEsPollJob, -50)
        scheduled := true
    } finally {
        Critical(criticalState)
    }
    return scheduled
}

QbarEsPollJob(*) {
    global QbarEsJob, QbarEsBundledState, QbarEsUseBundled
    if !IsObject(QbarEsJob)
        return
    job := QbarEsJob
    if !QbarEsJobIsCurrent(job) {
        QbarEsClearJob(true, job)
        return
    }
    if job["kind"] = "retry" {
        if A_TickCount >= job["deadline"] {
            if !QbarEsClearJob(false, job)
                return
            QbarEsBundledState := "unknown"
            QbarEsUseBundled := 0
            QbarEsHint(QbarText("Everything is still building its index.", "Everything 仍在建立索引。"),
                job["seq"], job["querySeq"])
            return
        }
        if A_TickCount < job["nextAttempt"] {
            SetTimer(QbarEsPollJob, -100)
            return
        }
        seq := job["seq"], arg := job["arg"], querySeq := job["querySeq"]
        if !QbarEsClearJob(false, job)
            return
        QbarEsStartSearch(arg, 1, seq, querySeq)
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
    querySeq := job["querySeq"]
    useBundled := job["useBundled"]
    results := (!timedOut && exitCode = 0 && kind = "search")
        ? QbarParseEsCsv(job["tmpPath"])
        : []
    if !QbarEsClearJob(timedOut, job) {
        if job["tmpPath"] != ""
            try FileDelete(job["tmpPath"])
        return
    }
    if !QbarEsRequestIsCurrent(seq, querySeq)
        return

    if kind = "probe-default" {
        if !timedOut && exitCode = 0 {
            QbarEsUseBundled := -1
            DebugLog("Es backend=default")
            QbarEsStartSearch(arg, -1, seq, querySeq)
        } else {
            QbarEsUseBundled := 1
            QbarEsEnsureBundled(arg, seq, querySeq)
        }
        return
    }
    if kind = "probe-bundled" {
        if !timedOut && exitCode = 0 {
            QbarEsUseBundled := 1
            QbarEsBundledState := "reachable"
            DebugLog("Es backend=bundled-existing")
            QbarEsStartSearch(arg, 1, seq, querySeq)
        } else
            QbarEsLaunchBundled(seq, arg, querySeq)
        return
    }

    if useBundled = -1 && (timedOut || exitCode != 0) {
        DebugLog("Es default backend unavailable; switching to bundled")
        QbarEsUseBundled := 1
        QbarEsEnsureBundled(arg, seq, querySeq)
        return
    }
    if useBundled = 1 && (timedOut || exitCode != 0) {
        if QbarEsBundledState = "starting" && A_TickCount < QbarEsWarmupDeadline {
            QbarEsScheduleRetry(seq, arg, 750, querySeq)
            return
        }
        QbarEsBundledState := "unknown"
        QbarEsUseBundled := 0
        QbarEsHint(QbarText("Everything search did not respond.", "Everything 搜索未响应。"),
            seq, querySeq)
        return
    }
    if useBundled = 1 {
        QbarEsBundledState := "reachable"
        QbarEsWarmupDeadline := 0
    }
    DebugLog("Es search results=" . results.Length)
    QbarEsPublishResults(results, seq, querySeq)
}

QbarEsPublishResults(results, seq, querySeq) {
    if !QbarEsRequestIsCurrent(seq, querySeq)
        return
    EverythingPublishResults(results, seq, querySeq)
}

QbarEsCancelJob(reason := "") {
    global QbarEsSeq, QbarEsJob
    criticalState := Critical("On")
    try {
        QbarEsSeq += 1
        job := QbarEsJob
        QbarEsJob := 0
        SetTimer(QbarEsPollJob, 0)
    } finally {
        Critical(criticalState)
    }
    if IsObject(job)
        QbarEsReleaseJob(job, true)
    if reason != ""
        DebugLog("Es job cancelled")
}

QbarEsClearJob(closeProcess := true, expectedJob := 0) {
    global QbarEsJob
    job := 0
    criticalState := Critical("On")
    try {
        if !IsObject(QbarEsJob)
            return false
        if IsObject(expectedJob) && QbarEsJob["id"] != expectedJob["id"]
            return false
        job := QbarEsJob
        QbarEsJob := 0
        SetTimer(QbarEsPollJob, 0)
    } finally {
        Critical(criticalState)
    }
    if !IsObject(job)
        return false
    QbarEsReleaseJob(job, closeProcess)
    return true
}

QbarEsReleaseJob(job, closeProcess := true) {
    if !IsObject(job)
        return false
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
    return true
}

QbarEsSameJob(job) {
    global QbarEsJob
    return IsObject(QbarEsJob) && QbarEsJob["id"] = job["id"]
}

QbarEsJobIsCurrent(job) {
    return QbarEsSameJob(job)
        && QbarEsRequestIsCurrent(job["seq"], job["querySeq"])
}

QbarEsRequestIsCurrent(seq, querySeq) {
    global QbarEsSeq, EverythingVisible, EverythingQuerySeq
    return seq = QbarEsSeq && querySeq = EverythingQuerySeq && EverythingVisible
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
    return A_Temp . "\capslock-p2-everything-es-" . processId . "-" . seq . "-" . A_TickCount . "-" . jobId . ".csv"
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
    settings := QbarRegistryPluginSettings("builtin.everything")
    if !IsObject(settings) || !settings.Has("esMaxResults")
        throw Error("文件搜索设置缺失")
    return Integer(settings["esMaxResults"])
}

QbarEsHint(text, seq, querySeq) {
    if !QbarEsRequestIsCurrent(seq, querySeq)
        return
    EverythingSetError(text)
}
