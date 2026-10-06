; Qbar command execution through the plugin host.
;
; This is the executable boundary of the registry. Rows without a commandId
; are only handled by the static fallback path when the registry is unavailable.
; Registered filesystem/start-menu providers receive payloads from the host's
; current result snapshot.

QbarExecuteRegistered(commandId, args := "", ctrlHeld := false, registryGeneration := 0,
    payload := 0) {
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
            historyEntry := QbarExecutionPrepareHistoryEntry(
                command, args, QbarHistoryNotesEntry(args))
            return QbarScheduleNotesHistory(historyEntry)
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
            path := QbarExecutionPayloadString(payload, "path", args)
            if path = ""
                return false
            candidateKey := QbarExecutionPayloadString(payload, "candidateKey")
            if ctrlHeld {
                if QbarLocateInExplorer(path)
                    return QbarExecutionRememberRegistered(command, args,
                        QbarHistoryNew("reveal", path, path,
                            Map("path", path, "action", "reveal")), candidateKey)
            } else if QbarOpenPath(path)
                return QbarExecutionRememberRegistered(command, args,
                    QbarHistoryNew("path", path, path, Map("path", path)), candidateKey)
        case "builtin.open-url":
            url := QbarExecutionPayloadString(payload, "url", args)
            url := QbarNormalizeUrl(url)
            if url = ""
                return false
            candidateKey := QbarExecutionPayloadString(payload, "candidateKey")
            if QbarOpenUrl(url)
                return QbarExecutionRememberRegistered(command, args,
                    QbarHistoryUrlEntry(args, url), candidateKey)
        case "builtin.start-menu.open":
            if !IsObject(payload) || Type(payload) != "Map"
                return false
            shortcutPath := QbarExecutionPayloadString(payload, "value")
            shortcutExe := QbarExecutionPayloadString(payload, "exe")
            shortcutLabel := QbarExecutionPayloadString(payload, "label")
            if shortcutPath = "" || shortcutExe = "" || shortcutLabel = ""
                return false
            shortcut := Map("value", shortcutPath, "exe", shortcutExe, "label", shortcutLabel)
            candidateKey := QbarExecutionPayloadString(payload, "candidateKey")
            if QbarRunShortcut(shortcut)
                return QbarExecutionRememberRegistered(command, args,
                    QbarHistoryShortcutEntry(shortcut), candidateKey)
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

QbarExecutionRememberRegistered(command, args, historyEntry, candidateKey := "") {
    QbarExecutionPrepareHistoryEntry(command, args, historyEntry, candidateKey)
    if IsObject(historyEntry)
        QbarHistoryRemember(historyEntry)
    return true
}

QbarExecutionPrepareHistoryEntry(command, args, historyEntry, candidateKey := "") {
    if IsObject(command) {
        if IsObject(historyEntry) {
            historyEntry["commandId"] := command["commandId"]
            historyEntry["pluginId"] := command["pluginId"]
            historyEntry["args"] := Map("args", args)
            if candidateKey != ""
                historyEntry["candidateKey"] := candidateKey
            if command["aliases"].Length {
                historyEntry["input"] := command["aliases"][1]
                    . (args = "" ? "" : " " . args)
                historyEntry["label"] := command["displayName"]
            }
        }
    }
    return historyEntry
}

QbarExecutionPayloadString(payload, key, fallback := "") {
    if Type(payload) = "Map" && payload.Has(key) && Type(payload[key]) = "String"
        return payload[key]
    return fallback
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
