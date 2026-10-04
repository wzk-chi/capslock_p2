; Qbar command execution through the plugin host.
;
; This is the executable boundary of the registry. Rows without a commandId
; are dynamic filesystem/start-menu results and are handled by their existing
; host-side resolution path.

QbarExecuteRegistered(commandId, args := "", ctrlHeld := false, registryGeneration := 0) {
    command := QbarRegistryCommand(commandId)
    if !IsObject(command) || !command["enabled"]
        return false
    if registryGeneration && registryGeneration != QbarRegistryGeneration() {
        DebugLog("Qbar registered command rejected: stale registry")
        return false
    }

    handlerId := command["handlerId"]
    if !QbarPluginHostHandlerAllowed(handlerId)
        return false

    switch handlerId {
        case "builtin.ai.ask":
            if QbarAiAsk(args)
                return QbarExecutionRememberRegistered(command, args, QbarHistoryAiEntry(args))
        case "builtin.everything.search":
            QbarHide()
            runQuery := Trim(args) != ""
            if EverythingShow(args, runQuery)
                return QbarExecutionRememberRegistered(command, args,
                    QbarHistoryEverythingEntry(args, runQuery))
        case "builtin.notes.search":
            if QbarScheduleNotes(args, true)
                return QbarExecutionRememberRegistered(command, args, QbarHistoryNotesEntry(args))
        case "builtin.clipboard.open":
            ; Freeze a validated target before QbarHide changes the foreground
            ; window. The history panel must not guess from an old Qbar HWND.
            targetContext := ClipboardHistoryCaptureTargetContext()
            QbarHide()
            if ClipboardHistoryShow(args, targetContext, true)
                return QbarExecutionRememberRegistered(command, args,
                    QbarHistoryClipboardEntry(args))
        case "builtin.settings.open":
            QbarHide()
            QbarScheduleSettingsHistory(QbarHistoryNew("settings", "cl set", "cl set",
                Map("page", "general")))
            return true
        case "builtin.open-path":
            if QbarOpenPath(args)
                return QbarExecutionRememberRegistered(command, args,
                    QbarHistoryNew("path", args, args, Map("path", Trim(args))))
        case "builtin.open-url":
            url := QbarNormalizeUrl(args)
            if QbarOpenUrl(url)
                return QbarExecutionRememberRegistered(command, args, QbarHistoryUrlEntry(args, url))
        case "builtin.start-menu.open":
            return false
        case "builtin.search":
            settings := command["settings"]
            template := settings.Has("template") ? String(settings["template"]) : ""
            if template = ""
                return false
            encodeQuery := !settings.Has("encodeQuery") || QbarExecutionBool(settings["encodeQuery"])
            query := encodeQuery ? UrlEncodeUtf8(args) : args
            url := QbarNormalizeUrl(StrReplace(template, "{q}", query))
            if QbarOpenUrl(url)
                return QbarExecutionRememberRegistered(command, args, QbarHistoryUrlEntry(args, url))
        case "builtin.run":
            settings := command["settings"]
            commandLine := settings.Has("command") ? String(settings["command"]) : ""
            if commandLine = ""
                return false
            if settings.Has("runAs") && QbarExecutionBool(settings["runAs"])
                commandLine := "*RunAs " . commandLine
            if QbarRunCommandAction(QbarRunCommand(commandLine, args), commandLine)
                return QbarExecutionRememberRegistered(command, args,
                    QbarHistoryRunEntry(args, commandLine))
    }
    return false
}

QbarExecutionRememberRegistered(command, args, historyEntry) {
    if IsObject(command) {
        if IsObject(historyEntry) {
            historyEntry["commandId"] := command["commandId"]
            historyEntry["pluginId"] := command["pluginId"]
            historyEntry["args"] := Map("args", args)
            if command["aliases"].Length {
                historyEntry["input"] := command["aliases"][1]
                    . (args = "" ? "" : " " . args)
                historyEntry["label"] := command["displayName"]
            }
        }
    }
    if IsObject(historyEntry)
        QbarHistoryRemember(historyEntry)
    return true
}

QbarExecutionBool(value) {
    if Type(value) = "ComValue" {
        try return value == JSON.true
        catch
            return false
    }
    if Type(value) = "Integer"
        return value != 0
    raw := StrLower(Trim(String(value)))
    return raw = "true" || raw = "1"
}
