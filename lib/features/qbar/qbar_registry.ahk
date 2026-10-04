; Qbar in-memory command registry.
;
; The registry is rebuilt after startup and after a configuration transaction.
; Query code reads this object and never asks SQLite for each keystroke.

global QbarRuntimeRegistry := 0
global QbarRuntimeGeneration := 0
global QbarRegistryError := ""

QbarRegistryRebuild() {
    global QbarRuntimeRegistry, QbarRuntimeGeneration, QbarRegistryError, QbarStoreError
    QbarRegistryError := ""
    if !QbarStoreReady && !QbarStoreInit() {
        QbarRegistryError := QbarStoreError
        return false
    }

    rows := QbarStoreLoadRuntimeRows()
    if !IsObject(rows) {
        QbarRegistryError := QbarStoreError != "" ? QbarStoreError : "读取 Qbar 注册表失败"
        return false
    }
    DebugLog("Qbar registry source rows=" . rows.Length)
    settingsByPlugin := QbarStoreLoadPluginSettings()
    next := Map(
        "generation", QbarRuntimeGeneration + 1,
        "byAlias", Map(),
        "byCommandId", Map(),
        "dynamicProviders", [],
        "visibleCommands", [],
        "usage", Map())

    for row in rows {
        if !row.Has("command_id") || row["command_id"] = ""
            continue
        commandId := row["command_id"]
        if !next["byCommandId"].Has(commandId) {
            instanceName := Trim(String(row["display_name"]))
            pluginName := Trim(String(row["plugin_name"]))
            commandTitle := Trim(String(row["command_title"]))
            command := Map(
                "commandId", commandId,
                "pluginId", row["plugin_id"],
                "definitionId", row["definition_id"],
                "source", row["plugin_source"],
                "instanceName", instanceName,
                "pluginName", pluginName,
                "displayName", QbarRegistryPreferredName(instanceName, pluginName, commandTitle),
                "title", commandTitle,
                "kind", row["kind"],
                "handlerId", row["handler_id"],
                "argMode", row["arg_mode"],
                "priority", QbarRegistryInteger(row["priority"], 100),
                "usageKey", row["usage_key"],
                "aliases", [],
                "implicitAliases", [],
                "pluginEnabled", row["plugin_enabled"] != "0",
                "commandEnabled", row["command_enabled"] != "0",
                "enabled", QbarRegistryEnabled(row["plugin_enabled"], row["command_enabled"])
                    && row["plugin_deleted"] = "" && row["command_deleted"] = ""
                    && QbarRegistryEnabled(row["available"], "1"),
                "pluginRetired", row["plugin_deleted"] != "",
                "commandRetired", row["command_deleted"] != "",
                "capabilities", QbarRegistryJsonArray(row["capabilities_json"]),
                "settingsSchema", QbarRegistryJsonMap(row["settings_schema_json"]),
                "settings", settingsByPlugin.Has(row["plugin_id"])
                    ? settingsByPlugin[row["plugin_id"]] : Map(),
                "icon", row["plugin_icon"])
            next["byCommandId"][commandId] := command
            if command["enabled"]
                next["visibleCommands"].Push(command)
            if command["kind"] = "fallback"
                next["dynamicProviders"].Push(command)
        }
        command := next["byCommandId"][commandId]
        if row["alias_enabled"] != "0" && row["normalized_alias"] != "" {
            alias := row["normalized_alias"]
            if !QbarRegistryArrayHas(command["aliases"], alias)
                command["aliases"].Push(alias)
            if command["enabled"] {
                if !next["byAlias"].Has(alias)
                    next["byAlias"][alias] := []
                if !QbarRegistryArrayHas(next["byAlias"][alias], commandId)
                    next["byAlias"][alias].Push(commandId)
            }
        }
    }

    ; User-created commands and multi-instance built-in search/run plugins
    ; without aliases remain invokable through their display name.
    for commandId, command in next["byCommandId"] {
        if command["aliases"].Length || !command["enabled"]
            continue
        if (command["source"] = "builtin"
            && command["definitionId"] != "builtin.search"
            && command["definitionId"] != "builtin.run")
            continue
        fallbackAlias := QbarNormalizeAlias(command["displayName"])
        if fallbackAlias = ""
            continue
        command["aliases"].Push(fallbackAlias)
        command["implicitAliases"].Push(fallbackAlias)
        if !next["byAlias"].Has(fallbackAlias)
            next["byAlias"][fallbackAlias] := []
        if !QbarRegistryArrayHas(next["byAlias"][fallbackAlias], commandId)
            next["byAlias"][fallbackAlias].Push(commandId)
    }

    QbarRegistryLoadUsage(next["usage"])
    QbarRuntimeRegistry := next
    QbarRuntimeGeneration := next["generation"]
    DebugLog("Qbar registry rebuilt commands=" . next["byCommandId"].Count
        . " aliases=" . next["byAlias"].Count . " generation=" . next["generation"])
    return true
}

QbarRegistryLoadUsage(target) {
    rows := QbarStoreLoadUsageRows()
    for row in rows {
        if !row.Has("usage_key") || row["usage_key"] = ""
            continue
        target[row["usage_key"]] := Map(
            "score", QbarRegistryFloat(row["score"], 0),
            "useCount", QbarRegistryInteger(row["use_count"], 0),
            "lastUsedAt", row["last_used_at"])
    }
}

QbarRegistryResolve(text) {
    global QbarRuntimeRegistry
    result := Map("matchedAlias", "", "args", "", "candidates", [])
    if !IsObject(QbarRuntimeRegistry) || !QbarRuntimeRegistry.Has("byAlias")
        return result
    input := Trim(String(text), " `t")
    if input = ""
        return result
    lower := StrLower(input)
    bestAlias := ""
    for alias, commandIds in QbarRuntimeRegistry["byAlias"] {
        aliasLength := StrLen(alias)
        if StrLen(lower) < aliasLength
            continue
        if SubStr(lower, 1, aliasLength) != alias
            continue
        if StrLen(lower) > aliasLength && SubStr(lower, aliasLength + 1, 1) != " "
            continue
        if StrLen(alias) > StrLen(bestAlias)
            bestAlias := alias
    }
    if bestAlias = ""
        return result
    args := Trim(SubStr(input, StrLen(bestAlias) + 1), " `t")
    result["matchedAlias"] := bestAlias
    result["args"] := args
    result["candidates"] := QbarRegistryCandidateCommands(bestAlias, args)
    return result
}

QbarRegistryCandidateCommands(alias, args := "") {
    global QbarRuntimeRegistry
    candidates := []
    if !IsObject(QbarRuntimeRegistry) || !QbarRuntimeRegistry["byAlias"].Has(alias)
        return candidates
    for commandId in QbarRuntimeRegistry["byAlias"][alias] {
        if !QbarRuntimeRegistry["byCommandId"].Has(commandId)
            continue
        command := QbarRuntimeRegistry["byCommandId"][commandId]
        if !command["enabled"]
            continue
        usage := QbarRegistryUsage(command["usageKey"])
        candidates.Push(Map(
            "commandId", commandId,
            "pluginId", command["pluginId"],
            "definitionId", command["definitionId"],
            "instanceName", command["instanceName"],
            "pluginName", command["pluginName"],
            "displayName", command["displayName"],
            "title", command["title"],
            "kind", command["kind"],
            "handlerId", command["handlerId"],
            "args", args,
            "matchedAlias", alias,
            "priority", command["priority"],
            "usageScore", usage["score"],
            "usageLastUsedAt", usage["lastUsedAt"],
            "conflict", false))
    }
    for candidate in candidates
        candidate["conflict"] := candidates.Length > 1
    return QbarRegistrySortCandidates(candidates)
}

QbarRegistrySortCandidates(candidates) {
    sorted := []
    for candidate in candidates {
        insertAt := sorted.Length + 1
        for index, existing in sorted {
            if QbarRegistryCandidateBefore(candidate, existing) {
                insertAt := index
                break
            }
        }
        sorted.InsertAt(insertAt, candidate)
    }
    return sorted
}

QbarRegistryCandidateBefore(left, right) {
    if left["usageScore"] != right["usageScore"]
        return left["usageScore"] > right["usageScore"]
    if left["usageLastUsedAt"] != right["usageLastUsedAt"]
        return left["usageLastUsedAt"] > right["usageLastUsedAt"]
    if left["priority"] != right["priority"]
        return left["priority"] > right["priority"]
    return StrCompare(left["commandId"], right["commandId"]) < 0
}

QbarRegistryUsage(usageKey) {
    global QbarRuntimeRegistry
    info := Map("score", 0, "lastUsedAt", "", "useCount", 0)
    if !IsObject(QbarRuntimeRegistry) || !QbarRuntimeRegistry["usage"].Has(usageKey)
        return info
    stored := QbarRuntimeRegistry["usage"][usageKey]
    score := stored["score"]
    lastUsedAt := stored["lastUsedAt"]
    if lastUsedAt != "" {
        try {
            elapsed := DateDiff(A_NowUTC, QbarRegistryCompactUtc(lastUsedAt), "Seconds")
            if elapsed > 0
                score *= 2 ** (0 - elapsed / 604800)
        } catch
            score := 0
    }
    info["score"] := score
    info["lastUsedAt"] := lastUsedAt
    info["useCount"] := stored["useCount"]
    return info
}

QbarRegistryRememberUsage(usageKey) {
    global QbarRuntimeRegistry
    if !IsObject(QbarRuntimeRegistry) || usageKey = ""
        return false
    if !QbarRuntimeRegistry["usage"].Has(usageKey)
        QbarRuntimeRegistry["usage"][usageKey] := Map("score", 0, "useCount", 0, "lastUsedAt", "")
    current := QbarRegistryUsage(usageKey)
    QbarRuntimeRegistry["usage"][usageKey] := Map(
        "score", current["score"] + 1,
        "useCount", current["useCount"] + 1,
        "lastUsedAt", QbarStoreNow())
    return true
}

QbarRegistryCompactUtc(value) {
    value := StrReplace(String(value), "-", "")
    value := StrReplace(value, "T", "")
    value := StrReplace(value, ":", "")
    return StrReplace(value, "Z", "")
}

QbarRegistryCommand(commandId) {
    global QbarRuntimeRegistry
    if !IsObject(QbarRuntimeRegistry) || !QbarRuntimeRegistry["byCommandId"].Has(commandId)
        return 0
    return QbarRuntimeRegistry["byCommandId"][commandId]
}

QbarRegistryHasAlias(alias) {
    global QbarRuntimeRegistry
    normalized := QbarNormalizeAlias(alias)
    return IsObject(QbarRuntimeRegistry)
        && normalized != ""
        && QbarRuntimeRegistry["byAlias"].Has(normalized)
}

QbarRegistryPluginSnapshot() {
    global QbarRuntimeRegistry
    plugins := Map()
    if !IsObject(QbarRuntimeRegistry)
        return []
    for commandId, command in QbarRuntimeRegistry["byCommandId"] {
        if command["pluginRetired"] || command["commandRetired"]
            continue
        pluginId := command["pluginId"]
        if !plugins.Has(pluginId) {
            toolSettings := Map()
            if pluginId = "builtin.everything"
                toolSettings["esMaxResults"] := SettingInteger("Qbar", "esMaxResults", 50, 1, 500)
            plugins[pluginId] := Map(
                "pluginId", pluginId,
                "definitionId", command["definitionId"],
                "source", command["source"],
                "name", command["displayName"],
                "deletable", (command["source"] != "builtin"
                    || command["definitionId"] = "builtin.search"
                    || command["definitionId"] = "builtin.run"),
                "settings", command["settings"],
                "settingsSchema", command["settingsSchema"],
                "toolSettings", toolSettings,
                "enabled", command["pluginEnabled"],
                "commands", [])
        }
        usage := QbarRegistryUsage(command["usageKey"])
        conflictAliases := []
        for alias in command["aliases"] {
            if QbarRuntimeRegistry["byAlias"].Has(alias)
                && QbarRuntimeRegistry["byAlias"][alias].Length > 1
                conflictAliases.Push(alias)
        }
        editableAliases := []
        for alias in command["aliases"]
            if !QbarRegistryArrayHas(command["implicitAliases"], alias)
                editableAliases.Push(alias)
        plugins[pluginId]["commands"].Push(Map(
            "commandId", commandId,
            "title", command["title"],
            "enabled", command["commandEnabled"],
            "aliases", editableAliases,
            "conflictAliases", conflictAliases,
            "usageScore", usage["score"],
            "useCount", usage["useCount"]))
    }
    result := []
    for pluginId, plugin in plugins
        result.Push(plugin)
    return result
}

QbarRegistryUserItems() {
    global QbarRuntimeRegistry
    items := []
    if !IsObject(QbarRuntimeRegistry)
        return items
    for commandId, command in QbarRuntimeRegistry["byCommandId"] {
        if !command["enabled"] || (command["handlerId"] != "builtin.search"
            && command["handlerId"] != "builtin.run")
            continue
        if !command["aliases"].Length
            continue
        short := command["aliases"][1]
        settings := command["settings"]
        if command["handlerId"] = "builtin.search" {
            template := settings.Has("template") ? String(settings["template"]) : ""
            if template = ""
                continue
            items.Push(Map(
                "short", short,
                "label", command["displayName"],
                "type", "search",
                "value", template,
                "usageKey", command["usageKey"],
                "commandId", commandId,
                "pluginId", command["pluginId"],
                "aliases", command["aliases"]))
        } else {
            commandLine := settings.Has("command") ? String(settings["command"]) : ""
            if commandLine = ""
                continue
            resolved := QbarResolveCommandIconPath(commandLine)
            isFolder := resolved != "" && CheckStringType(resolved) = "folder"
            items.Push(Map(
                "short", short,
                "label", command["displayName"],
                "type", isFolder ? "folder" : "file",
                "value", commandLine,
                "usageKey", command["usageKey"],
                "commandId", commandId,
                "pluginId", command["pluginId"],
                "aliases", command["aliases"],
                "icon", QbarRegistryCommandIconKey(command)))
        }
    }
    return items
}

QbarRegistryCommandIconKey(command) {
    if !IsObject(command) || command["handlerId"] != "builtin.run"
        return ""
    settings := command["settings"]
    commandLine := settings.Has("command") ? String(settings["command"]) : ""
    if commandLine = ""
        return ""
    resolved := QbarResolveCommandIconPath(commandLine)
    if resolved = ""
        return ""
    return CheckStringType(resolved) = "folder" ? "folder" : IconKeyForPath(resolved)
}

QbarRegistryPreferredName(instanceName, pluginName, commandTitle := "") {
    for value in [instanceName, pluginName, commandTitle] {
        value := Trim(String(value))
        if value != ""
            return value
    }
    return ""
}

QbarRegistryGeneration() {
    global QbarRuntimeGeneration
    return QbarRuntimeGeneration
}

QbarRegistryArrayHas(values, target) {
    for value in values
        if value = target
            return true
    return false
}

QbarRegistryEnabled(pluginEnabled, commandEnabled) {
    return String(pluginEnabled) != "0" && String(commandEnabled) != "0"
}

QbarRegistryInteger(value, fallback := 0) {
    try return Integer(value)
    catch
        return fallback
}

QbarRegistryFloat(value, fallback := 0) {
    try return Float(value)
    catch
        return fallback
}

QbarRegistryJsonArray(value) {
    try parsed := JSON.Parse(value, false, true)
    catch
        return []
    return Type(parsed) = "Array" ? parsed : []
}

QbarRegistryJsonMap(value) {
    try parsed := JSON.Parse(value, false, true)
    catch
        return Map()
    return Type(parsed) = "Map" ? parsed : Map()
}
