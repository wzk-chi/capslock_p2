; Qbar in-memory command registry.
;
; The registry is rebuilt after startup and after a configuration transaction.
; Query code reads this object and never asks SQLite for each keystroke.
; Build constructs a candidate from the current store snapshot; Publish swaps it
; into service only after the surrounding database transaction commits.

global QbarRuntimeRegistry := 0
global QbarRuntimeGeneration := 0
global QbarRegistryError := ""

QbarRegistryBuild(&next) {
    global QbarRuntimeGeneration, QbarRegistryError, QbarStoreError, QbarStoreReady
    QbarRegistryError := ""
    next := 0
    try {
        if !QbarStoreReady
            throw Error(QbarStoreError != "" ? QbarStoreError : "Qbar 数据库不可用")
        if !QbarStoreLoadRuntimeRows(&rows)
            throw Error(QbarStoreError != "" ? QbarStoreError : "读取 Qbar 注册表失败")
        if !QbarStoreLoadPluginSettings(&settingsByPlugin, &invalidPluginSettings)
            throw Error(QbarStoreError != "" ? QbarStoreError : "读取 Qbar 插件设置失败")
        if !QbarStoreLoadUsageRows(&usageRows)
            throw Error(QbarStoreError != "" ? QbarStoreError : "读取 Qbar 使用记录失败")
        DebugLog("Qbar registry source rows=" . rows.Length)
        candidate := Map(
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
            if !candidate["byCommandId"].Has(commandId) {
                pluginId := row["plugin_id"]
                definitionId := row["definition_id"]
                definition := QbarPluginCatalogDefinitionById(definitionId)
                catalogCommand := QbarRegistryCatalogCommand(
                    definition, pluginId, commandId, row["handler_id"])
                definitionValid := IsObject(definition) && IsObject(catalogCommand)
                    && QbarRegistryDefinitionDataMatches(definition, row)
                settingsValid := definitionValid && !invalidPluginSettings.Has(pluginId)
                settings := Map()
                if settingsValid {
                    rawSettings := settingsByPlugin.Has(pluginId) ? settingsByPlugin[pluginId] : Map()
                    if !QbarPluginHostNormalizeSettings(definition, rawSettings,
                        &settings, &settingsError) {
                        settingsValid := false
                        DebugLog("Qbar plugin settings rejected by schema plugin=" . pluginId)
                    }
                }
                if !settingsValid {
                    settings := Map()
                    DebugLog("Qbar plugin command disabled by invalid definition/settings plugin="
                        . pluginId)
                }
                instanceName := Trim(String(row["display_name"]))
                pluginName := Trim(String(row["plugin_name"]))
                commandTitle := IsObject(catalogCommand)
                    ? String(catalogCommand["title"]) : Trim(String(row["command_title"]))
                command := Map(
                    "commandId", commandId,
                    "pluginId", pluginId,
                    "definitionId", definitionId,
                    "source", row["plugin_source"],
                    "instanceName", instanceName,
                    "pluginName", pluginName,
                    "displayName", QbarRegistryPreferredName(instanceName, pluginName, commandTitle),
                    "title", commandTitle,
                    "kind", IsObject(catalogCommand) ? catalogCommand["kind"] : "disabled",
                    "handlerId", IsObject(catalogCommand) ? catalogCommand["handlerId"] : "",
                    "argMode", IsObject(catalogCommand) ? catalogCommand["argMode"] : "none",
                    "priority", IsObject(catalogCommand)
                        ? QbarRegistryInteger(catalogCommand["priority"], 100) : 0,
                    "usageKey", row["usage_key"],
                    "aliases", [],
                    "implicitAliases", [],
                    "pluginEnabled", row["plugin_enabled"] != "0",
                    "commandEnabled", row["command_enabled"] != "0",
                    "enabled", QbarRegistryEnabled(row["plugin_enabled"], row["command_enabled"])
                        && row["plugin_deleted"] = "" && row["command_deleted"] = ""
                        && QbarRegistryEnabled(row["available"], "1")
                        && settingsValid,
                    "pluginRetired", row["plugin_deleted"] != "",
                    "commandRetired", row["command_deleted"] != "",
                    "definitionValid", definitionValid,
                    "settingsValid", settingsValid,
                    "capabilities", IsObject(definition) ? definition["capabilities"] : [],
                    "settingsSchema", IsObject(definition) ? definition["settingsSchema"] : Map(),
                    "settings", settings,
                    "icon", row["plugin_icon"])
                candidate["byCommandId"][commandId] := command
                if command["enabled"] {
                    candidate["visibleCommands"].Push(command)
                    if command["kind"] = "fallback"
                        candidate["dynamicProviders"].Push(command)
                }
            }
            command := candidate["byCommandId"][commandId]
            if row["alias_enabled"] != "0" && row["normalized_alias"] != "" {
                alias := row["normalized_alias"]
                if !QbarRegistryArrayHas(command["aliases"], alias)
                    command["aliases"].Push(alias)
                if command["enabled"] {
                    if !candidate["byAlias"].Has(alias)
                        candidate["byAlias"][alias] := []
                    if !QbarRegistryArrayHas(candidate["byAlias"][alias], commandId)
                        candidate["byAlias"][alias].Push(commandId)
                }
            }
        }

        ; User-created commands and multi-instance built-in search/run plugins
        ; without aliases remain invokable through their display name.
        for commandId, command in candidate["byCommandId"] {
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
            if !candidate["byAlias"].Has(fallbackAlias)
                candidate["byAlias"][fallbackAlias] := []
            if !QbarRegistryArrayHas(candidate["byAlias"][fallbackAlias], commandId)
                candidate["byAlias"][fallbackAlias].Push(commandId)
        }

        QbarRegistryLoadUsage(candidate["usage"], usageRows)
        next := candidate
        return true
    } catch as buildError {
        QbarRegistryError := buildError.Message
        DebugLog("Qbar registry build failed: " . QbarRegistryError)
        return false
    }
}

QbarRegistryPublish(next) {
    global QbarRuntimeRegistry, QbarRuntimeGeneration, QbarRegistryError
    QbarRuntimeRegistry := next
    QbarRuntimeGeneration := next["generation"]
    QbarRegistryError := ""
    QbarInvalidateResultSnapshot()
    return true
}

QbarRegistryLoadUsage(target, rows) {
    for row in rows {
        if !row.Has("usage_key") || row["usage_key"] = ""
            continue
        target[row["usage_key"]] := Map(
            "score", QbarRegistryFloat(row["score"], 0),
            "useCount", QbarRegistryInteger(row["use_count"], 0),
            "lastUsedAt", row["last_used_at"])
    }
}

QbarRegistryCatalogCommand(definition, pluginId, commandId, handlerId) {
    if Type(definition) != "Map" || !definition.Has("commands")
        || Type(definition["commands"]) != "Array"
        return 0
    for command in definition["commands"] {
        expectedCommandId := pluginId . "." . command["id"]
        if commandId != expectedCommandId
            continue
        if String(command["handlerId"]) != String(handlerId)
            || !QbarPluginHostHandlerAllowed(String(command["handlerId"]))
            return 0
        return command
    }
    return 0
}

QbarRegistryDefinitionDataMatches(definition, row) {
    try capabilities := JSON.Parse(String(row["capabilities_json"]), false, true)
    catch
        return false
    try settingsSchema := JSON.Parse(String(row["settings_schema_json"]), false, true)
    catch
        return false
    if Type(capabilities) != "Array" || Type(settingsSchema) != "Map"
        return false
    return JSON.stringify(capabilities, 0) = JSON.stringify(definition["capabilities"], 0)
        && JSON.stringify(settingsSchema, 0) = JSON.stringify(definition["settingsSchema"], 0)
}

QbarRegistryResolve(text) {
    global QbarRuntimeRegistry
    result := Map("matchedAlias", "", "args", "", "candidates", [])
    if !IsObject(QbarRuntimeRegistry) || !QbarRuntimeRegistry.Has("byAlias")
        return result
    input := Trim(String(text), " `t`r`n`v`f")
    if input = ""
        return result
    normalizedPrefix := ""
    bestAlias := ""
    bestConsumedLength := 0
    matchPosition := 1
    while RegExMatch(input, "\S+", &wordMatch, matchPosition) {
        word := StrLower(wordMatch[0])
        normalizedPrefix .= (normalizedPrefix = "" ? "" : " ") . word
        matchPosition := wordMatch.Pos(0) + wordMatch.Len(0)
        if QbarRuntimeRegistry["byAlias"].Has(normalizedPrefix) {
            bestAlias := normalizedPrefix
            bestConsumedLength := matchPosition - 1
        }
    }
    if bestAlias = ""
        return result
    args := Trim(SubStr(input, bestConsumedLength + 1), " `t`r`n`v`f")
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

QbarRegistryIsAvailable() {
    global QbarRuntimeRegistry
    return Type(QbarRuntimeRegistry) = "Map"
        && QbarRuntimeRegistry.Has("byAlias")
        && QbarRuntimeRegistry.Has("byCommandId")
}

QbarRegistryDynamicProviderByHandler(handlerId) {
    global QbarRuntimeRegistry
    if !IsObject(QbarRuntimeRegistry) || !QbarRuntimeRegistry.Has("dynamicProviders")
        return 0
    for command in QbarRuntimeRegistry["dynamicProviders"]
        if command["enabled"] && command["handlerId"] = handlerId
            return command
    return 0
}

QbarRegistryDynamicProviderUnavailable(handlerId) {
    global QbarRuntimeRegistry
    return IsObject(QbarRuntimeRegistry)
        && !IsObject(QbarRegistryDynamicProviderByHandler(handlerId))
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
                "definitionValid", command["definitionValid"],
                "settingsValid", command["settingsValid"],
                "settingsSchema", command["settingsSchema"],
                "toolSettings", toolSettings,
                "enabled", command["pluginEnabled"] && command["definitionValid"]
                    && command["settingsValid"],
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

QbarRegistryJsonMap(value) {
    try parsed := JSON.Parse(value, false, true)
    catch
        return Map()
    return Type(parsed) = "Map" ? parsed : Map()
}
