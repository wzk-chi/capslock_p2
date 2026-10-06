; Qbar plugin host lifecycle.
;
; The host is the only module allowed to turn a registered handlerId into an
; executable handler. Database rows and page messages never contain callable
; AHK function names.

global QbarPluginHostReady := false
global QbarPluginHostError := ""

QbarPluginHostInitialize() {
    global QbarPluginHostReady, QbarPluginHostError, QbarRuntimeRegistry
    if QbarPluginHostReady
        return true

    QbarPluginHostError := ""
    DebugLog("Qbar plugin host initialize")
    if !QbarStoreInit() {
        QbarPluginHostError := QbarStoreError
        DebugLog("Qbar plugin store unavailable: " . QbarPluginHostError)
        return false
    }

    criticalState := Critical("On")
    try {
        if QbarPluginHostReady
            return true
        QbarPluginHostRegisterCatalog(&nextRegistry)
        if !QbarRegistryPublish(nextRegistry)
            throw Error("Qbar 注册表发布失败")
        QbarPluginHostReady := true
        commandCount := IsObject(QbarRuntimeRegistry) ? QbarRuntimeRegistry["byCommandId"].Count : 0
        aliasCount := IsObject(QbarRuntimeRegistry) ? QbarRuntimeRegistry["byAlias"].Count : 0
        DebugLog("Qbar plugin host ready commands=" . commandCount . " aliases=" . aliasCount
            . " generation=" . QbarRegistryGeneration())
        return true
    } catch as initError {
        QbarPluginHostError := initError.Message
        DebugLog("Qbar plugin host initialization failed: " . QbarPluginHostError)
        QbarPluginHostReady := false
        return false
    } finally {
        Critical(criticalState)
    }
}

QbarPluginHostRegisterCatalog(&nextRegistry) {
    definitions := QbarPluginCatalogDefinitions()
    instances := QbarPluginCatalogBuiltinInstances()
    retiredPluginIds := QbarPluginCatalogRetiredBuiltinPluginIds()
    DebugLog("Qbar catalog registration start definitions=" . definitions.Length
        . " instances=" . instances.Length . " retired=" . retiredPluginIds.Length)
    if !QbarStoreBegin()
        throw Error(QbarStoreError != "" ? QbarStoreError : "无法开始 Qbar 插件注册")
    try {
        for definition in definitions {
            DebugLog("Qbar catalog definition id=" . definition["definitionId"])
            if !QbarPluginHostValidateDefinition(definition)
                throw Error("Qbar 插件定义无效：" . definition["definitionId"])
            if !QbarStoreUpsertDefinition(definition)
                throw Error(QbarStoreError != "" ? QbarStoreError : "保存插件定义失败")
        }
        for pluginId in retiredPluginIds {
            DebugLog("Qbar catalog retire instance id=" . pluginId)
            if !QbarStoreRetirePlugin(pluginId)
                throw Error(QbarStoreError != "" ? QbarStoreError : "停用旧插件实例失败")
        }
        for instance in instances {
            DebugLog("Qbar catalog instance id=" . instance["pluginId"])
            if !QbarStoreUpsertPlugin(instance)
                throw Error(QbarStoreError != "" ? QbarStoreError : "保存插件实例失败")
            definition := QbarPluginCatalogDefinitionById(instance["definitionId"])
            if !IsObject(definition)
                throw Error("找不到插件定义：" . instance["definitionId"])
            for command in definition["commands"] {
                commandId := instance["pluginId"] . "." . command["id"]
                commandCopy := QbarPluginHostCommandCopy(command, commandId)
                if commandCopy.Has("usageKey") && commandCopy["usageKey"] = ""
                    commandCopy["usageKey"] := commandId
                if !QbarStoreUpsertCommand(instance["pluginId"], commandCopy)
                    throw Error(QbarStoreError != "" ? QbarStoreError : "保存插件命令失败")
                aliases := command.Has("aliases") ? command["aliases"] : []
                if instance.Has("commandAliases") && instance["commandAliases"].Has(commandId)
                    aliases := instance["commandAliases"][commandId]
                for alias in aliases
                        if !QbarStoreEnsureAlias(commandId, alias, "manifest-default", true)
                            throw Error(QbarStoreError != "" ? QbarStoreError : "保存命令别名失败")
                if commandId = "builtin.clipboard.open"
                    if !QbarStoreRemoveManifestAlias(commandId, "剪贴板历史")
                        throw Error(QbarStoreError != "" ? QbarStoreError : "清理剪贴板历史本名别名失败")
            }
            settings := instance.Has("settings") ? instance["settings"] : Map()
            for key, settingSchema in definition["settingsSchema"] {
                if !settings.Has(key) && settingSchema.Has("default")
                    settings[key] := settingSchema["default"]
            }
            if !QbarStoreEnsurePluginSettings(instance["pluginId"], 1, settings)
                throw Error(QbarStoreError != "" ? QbarStoreError : "保存插件设置失败")
        }
        if !QbarRegistryBuild(&nextRegistry)
            throw Error(QbarRegistryError != "" ? QbarRegistryError : "Qbar 注册表构建失败")
        if !QbarStoreCommit()
            throw Error(QbarStoreError != "" ? QbarStoreError : "提交 Qbar 插件注册失败")
    } catch as registerError {
        try QbarStoreRollback()
        DebugLog("Qbar catalog registration failed: " . registerError.Message)
        throw registerError
    }
    DebugLog("Qbar catalog registration committed")
    return true
}

QbarPluginHostValidateDefinition(definition) {
    if !IsObject(definition)
        return false
    for key in ["definitionId", "name", "trustLevel"]
        if !definition.Has(key) || String(definition[key]) = ""
            return false
    if !definition.Has("commands") || Type(definition["commands"]) != "Array"
        return false
    for command in definition["commands"] {
        if Type(command) != "Map"
            return false
        for key in ["id", "handlerId", "kind", "argMode"]
            if !command.Has(key) || String(command[key]) = ""
                return false
        if !QbarPluginHostHandlerAllowed(String(command["handlerId"]))
            return false
    }
    return true
}

QbarPluginHostHandlerAllowed(handlerId) {
    static handlers := Map(
        "builtin.ai.ask", true,
        "builtin.everything.search", true,
        "builtin.notes.search", true,
        "builtin.clipboard.open", true,
        "builtin.settings.open", true,
        "builtin.open-path", true,
        "builtin.open-url", true,
        "builtin.start-menu.open", true,
        "builtin.search", true,
        "builtin.run", true)
    return handlers.Has(handlerId)
}

QbarPluginHostCommandCopy(command, commandId) {
    copy := Map()
    for key, value in command
        copy[key] := value
    copy["id"] := commandId
    return copy
}

QbarPluginHostApplyPluginChanges(plugins) {
    global QbarPluginHostError, QbarStoreError, QbarRegistryError
    QbarPluginHostError := ""
    if !QbarPluginHostPreparePluginChanges(plugins, &preparedPlugins, &validationError) {
        QbarPluginHostError := validationError
        DebugLog("Qbar plugin changes rejected: validation")
        return false
    }
    DebugLog("Qbar plugin changes begin count=" . preparedPlugins.Length)
    criticalState := Critical("On")
    try {
        if !QbarPluginHostPreparePluginChanges(plugins, &preparedPlugins, &validationError) {
            QbarPluginHostError := validationError
            DebugLog("Qbar plugin changes rejected before transaction: validation")
            return false
        }
        if !QbarStoreBegin() {
            QbarPluginHostError := QbarStoreError != "" ? QbarStoreError : "无法开始插件修改事务"
            DebugLog("Qbar plugin changes begin failed: " . QbarPluginHostError)
            return false
        }
        try {
            for plugin in preparedPlugins {
                pluginId := String(plugin["pluginId"])
                DebugLog("Qbar plugin change plugin=" . pluginId)
                if plugin.Has("enabled") {
                    if !QbarPluginHostParseBoolean(plugin["enabled"], &enabled)
                        throw Error("插件启用状态校验失败")
                    if !QbarStoreSetPluginEnabled(pluginId, enabled)
                        throw Error(QbarStoreError != "" ? QbarStoreError : "保存插件状态失败")
                }
                if plugin.Has("displayName") || plugin.Has("name") {
                    displayName := plugin.Has("displayName")
                        ? Trim(String(plugin["displayName"])) : Trim(String(plugin["name"]))
                    if displayName = "" || !QbarStoreSetPluginDisplayName(pluginId, displayName)
                        throw Error(QbarStoreError != "" ? QbarStoreError : "保存工具名称失败")
                }
                if plugin.Has("settings")
                    if !QbarStoreSetPluginSettings(pluginId, plugin["settings"], 1, false)
                        throw Error(QbarStoreError != "" ? QbarStoreError : "保存插件设置失败")
                if plugin.Has("commands") {
                    for command in plugin["commands"] {
                        if command.Has("aliases") {
                            if !QbarStoreApplyCommandAliases(String(command["commandId"]), command["aliases"])
                                throw Error(QbarStoreError != "" ? QbarStoreError : "保存命令别名失败")
                        }
                    }
                }
            }
            if !QbarRegistryBuild(&nextRegistry)
                throw Error(QbarRegistryError != "" ? QbarRegistryError : "插件注册表构建失败")
            if !QbarStoreCommit()
                throw Error(QbarStoreError != "" ? QbarStoreError : "提交插件修改失败")
        } catch as changeError {
            try QbarStoreRollback()
            QbarPluginHostError := changeError.Message
            DebugLog("Qbar plugin settings failed: " . QbarPluginHostError)
            return false
        }
        QbarRegistryPublish(nextRegistry)
    } finally {
        Critical(criticalState)
    }
    QbarPluginHostRefreshIndex()
    DebugLog("Qbar plugin changes committed count=" . plugins.Length
        . " generation=" . QbarRegistryGeneration())
    return true
}

QbarPluginHostDeletePlugin(pluginId) {
    global QbarPluginHostError, QbarStoreError, QbarRegistryError
    QbarPluginHostError := ""
    pluginId := Trim(String(pluginId))
    criticalState := Critical("On")
    try {
        if !QbarPluginHostPluginDeletable(pluginId) {
            QbarPluginHostError := "该工具不存在或不可删除"
            return false
        }
        if !QbarStoreBegin() {
            QbarPluginHostError := QbarStoreError != "" ? QbarStoreError : "无法开始删除工具"
            return false
        }
        try {
            if !QbarStoreRetirePlugin(pluginId)
                throw Error(QbarStoreError != "" ? QbarStoreError : "删除工具失败")
            if !QbarRegistryBuild(&nextRegistry)
                throw Error(QbarRegistryError != "" ? QbarRegistryError : "删除后的注册表构建失败")
            if !QbarStoreCommit()
                throw Error(QbarStoreError != "" ? QbarStoreError : "提交工具删除失败")
        } catch as deleteError {
            try QbarStoreRollback()
            QbarPluginHostError := ""
            diagnostic := deleteError.Message
            DebugLog("Qbar plugin delete failed plugin=" . pluginId
                . " errorType=" . Type(deleteError)
                . " detailLength=" . StrLen(diagnostic))
            return false
        }
        QbarRegistryPublish(nextRegistry)
        QbarHistoryMarkPluginRetired(pluginId)
    } finally {
        Critical(criticalState)
    }
    QbarPluginHostRefreshIndex()
    DebugLog("Qbar plugin deleted plugin=" . pluginId
        . " generation=" . QbarRegistryGeneration())
    return true
}

QbarPluginHostPluginDeletable(pluginId) {
    global QbarRuntimeRegistry
    if pluginId = "" || !IsObject(QbarRuntimeRegistry)
        return false
    for commandId, command in QbarRuntimeRegistry["byCommandId"] {
        if command["pluginId"] != pluginId || command["pluginRetired"] || command["commandRetired"]
            continue
        return (command["source"] != "builtin"
            || command["definitionId"] = "builtin.search"
            || command["definitionId"] = "builtin.run")
    }
    return false
}

QbarPluginHostParseBoolean(value, &parsed := false) {
    if Type(value) = "ComValue" {
        try {
            if value == JSON.true {
                parsed := true
                return true
            }
            if value == JSON.false {
                parsed := false
                return true
            }
        }
        return false
    }
    if Type(value) = "Integer" {
        if value != 0 && value != 1
            return false
        parsed := value = 1
        return true
    }
    if Type(value) != "String"
        return false
    normalized := StrLower(Trim(value))
    if normalized = "true" || normalized = "1" {
        parsed := true
        return true
    }
    if normalized = "false" || normalized = "0" {
        parsed := false
        return true
    }
    return false
}

QbarPluginHostInteger(value, &number := 0) {
    if Type(value) = "Integer" {
        number := value
        return true
    }
    if Type(value) = "Float" {
        if value != Floor(value)
            return false
        try number := Integer(value)
        catch
            return false
        return true
    }
    if Type(value) != "String"
        return false
    text := Trim(value)
    if !RegExMatch(text, "^-?\d+$")
        return false
    try number := Integer(text)
    catch
        return false
    return true
}

QbarPluginHostNormalizeSettings(definition, rawSettings, &normalized := 0,
    &errorText := "") {
    normalized := Map()
    errorText := ""
    if Type(definition) != "Map" || !definition.Has("settingsSchema")
        || Type(definition["settingsSchema"]) != "Map" {
        errorText := "工具设置定义不可用。"
        return false
    }
    if Type(rawSettings) != "Map" {
        errorText := "工具设置格式无效。"
        return false
    }

    schema := definition["settingsSchema"]
    for key, value in rawSettings {
        if Type(key) != "String" || !schema.Has(key) {
            errorText := "包含不支持的工具设置项。"
            return false
        }
    }
    for key, field in schema {
        if Type(field) != "Map" || !field.Has("type") {
            errorText := "工具设置定义无效。"
            return false
        }
        label := field.Has("label") && Type(field["label"]) = "String"
            ? field["label"] : key
        if rawSettings.Has(key)
            value := rawSettings[key]
        else if field.Has("default")
            value := field["default"]
        else {
            required := false
            if field.Has("required")
                if !QbarPluginHostParseBoolean(field["required"], &required) {
                    errorText := "工具设置定义无效。"
                    return false
                }
            if required {
                errorText := "缺少设置项：“" . label . "”。"
                return false
            }
            continue
        }

        switch field["type"] {
            case "boolean":
                if !QbarPluginHostParseBoolean(value, &booleanValue) {
                    errorText := "设置项“" . label . "”必须是开关。"
                    return false
                }
                normalized[key] := booleanValue ? JSON.true : JSON.false
            case "integer":
                if !QbarPluginHostInteger(value, &integerValue) {
                    errorText := "设置项“" . label . "”必须是整数。"
                    return false
                }
                minimum := field.Has("min") ? Integer(field["min"]) : integerValue
                maximum := field.Has("max") ? Integer(field["max"]) : integerValue
                step := field.Has("step") ? Integer(field["step"]) : 1
                if step < 1 || integerValue < minimum || integerValue > maximum
                    || Mod(integerValue - minimum, step) != 0 {
                    errorText := "设置项“" . label . "”超出允许范围。"
                    return false
                }
                normalized[key] := integerValue
            case "url-template":
                if Type(value) != "String" || !InStr(value, "{q}") {
                    errorText := "设置项“" . label . "”必须包含 {q}。"
                    return false
                }
                normalized[key] := Trim(value)
            case "command-line":
                if Type(value) != "String" || Trim(value) = ""
                    || InStr(value, "`n") || InStr(value, "`r") {
                    errorText := "设置项“" . label . "”不能为空或包含换行。"
                    return false
                }
                normalized[key] := Trim(value)
            case "enum":
                if Type(value) != "String" || !field.Has("values")
                    || Type(field["values"]) != "Array" {
                    errorText := "设置项“" . label . "”不是可用选项。"
                    return false
                }
                allowed := false
                for option in field["values"]
                    if Type(option) = "String" && value = option {
                        allowed := true
                        break
                    }
                if !allowed {
                    errorText := "设置项“" . label . "”不是可用选项。"
                    return false
                }
                normalized[key] := value
            default:
                errorText := "工具设置包含不支持的字段类型。"
                return false
        }
    }
    return true
}

QbarPluginHostPreparePluginChanges(plugins, &prepared := 0, &errorText := "") {
    global QbarRuntimeRegistry
    prepared := []
    errorText := ""
    if Type(plugins) != "Array" {
        errorText := "插件修改列表无效。"
        return false
    }
    if !IsObject(QbarRuntimeRegistry) || !QbarRuntimeRegistry.Has("byCommandId") {
        errorText := "插件列表尚未准备好，请重试。"
        return false
    }

    seenPlugins := Map()
    for rawPlugin in plugins {
        if Type(rawPlugin) != "Map" || !rawPlugin.Has("pluginId")
            || Type(rawPlugin["pluginId"]) != "String" {
            errorText := "插件修改数据无效。"
            return false
        }
        pluginId := rawPlugin["pluginId"]
        if pluginId = "" || Trim(pluginId) != pluginId || seenPlugins.Has(pluginId) {
            errorText := "插件身份无效或重复。"
            return false
        }
        seenPlugins[pluginId] := true

        definitionId := ""
        currentSettingsValid := true
        currentDefinitionValid := true
        for commandId, command in QbarRuntimeRegistry["byCommandId"] {
            if command["pluginId"] != pluginId || command["pluginRetired"]
                || command["commandRetired"]
                continue
            if definitionId != "" && definitionId != command["definitionId"] {
                errorText := "插件命令归属不一致。"
                return false
            }
            definitionId := command["definitionId"]
            if !command["definitionValid"]
                currentDefinitionValid := false
            if !command["settingsValid"]
                currentSettingsValid := false
        }
        if !currentDefinitionValid {
            errorText := "工具定义无效，暂时无法修改。"
            return false
        }
        definition := definitionId != "" ? QbarPluginCatalogDefinitionById(definitionId) : 0
        if !IsObject(definition) {
            errorText := "工具不存在或已停用。"
            return false
        }

        patch := Map("pluginId", pluginId)
        if rawPlugin.Has("enabled") {
            if !QbarPluginHostParseBoolean(rawPlugin["enabled"], &enabled) {
                errorText := "工具启用状态无效。"
                return false
            }
            patch["enabled"] := enabled ? JSON.true : JSON.false
        }
        if rawPlugin.Has("displayName") || rawPlugin.Has("name") {
            rawName := rawPlugin.Has("displayName")
                ? rawPlugin["displayName"] : rawPlugin["name"]
            if Type(rawName) != "String" || Trim(rawName) = "" || StrLen(Trim(rawName)) > 80 {
                errorText := "工具名称不能为空且不能超过 80 个字符。"
                return false
            }
            patch["displayName"] := Trim(rawName)
        }
        if rawPlugin.Has("settings") {
            if !QbarPluginHostNormalizeSettings(definition, rawPlugin["settings"],
                &normalizedSettings, &settingsError) {
                if currentSettingsValid || Type(rawPlugin["settings"]) != "Map"
                    || rawPlugin["settings"].Count != 0 {
                    errorText := settingsError
                    return false
                }
                ; An untouched corrupt baseline is omitted from the patch so an
                ; unrelated tool edit can proceed. The command stays disabled
                ; until its own settings are repaired.
            } else {
                patch["settings"] := normalizedSettings
            }
        }
        if rawPlugin.Has("commands") {
            if Type(rawPlugin["commands"]) != "Array" {
                errorText := "插件命令修改数据无效。"
                return false
            }
            commands := []
            seenCommands := Map()
            for rawCommand in rawPlugin["commands"] {
                if Type(rawCommand) != "Map" || !rawCommand.Has("commandId")
                    || Type(rawCommand["commandId"]) != "String" {
                    errorText := "插件命令身份无效。"
                    return false
                }
                commandId := rawCommand["commandId"]
                command := QbarRegistryCommand(commandId)
                if !IsObject(command) || command["pluginId"] != pluginId
                    || command["pluginRetired"] || command["commandRetired"]
                    || seenCommands.Has(commandId) {
                    errorText := "命令不存在或不属于当前工具。"
                    return false
                }
                seenCommands[commandId] := true
                commandPatch := Map("commandId", commandId)
                if rawCommand.Has("aliases") {
                    if !QbarPluginHostNormalizeAliases(rawCommand["aliases"],
                        &aliases, &aliasError) {
                        errorText := aliasError
                        return false
                    }
                    commandPatch["aliases"] := aliases
                }
                commands.Push(commandPatch)
            }
            patch["commands"] := commands
        }
        if patch.Count = 1 {
            errorText := "没有可保存的工具修改。"
            return false
        }
        prepared.Push(patch)
    }
    return true
}

QbarPluginHostNormalizeAliases(rawAliases, &aliases := 0, &errorText := "") {
    aliases := []
    errorText := ""
    if Type(rawAliases) != "Array" {
        errorText := "命令别名列表无效。"
        return false
    }
    seen := Map()
    for value in rawAliases {
        if Type(value) != "String" {
            errorText := "命令别名必须是文字。"
            return false
        }
        alias := Trim(value)
        normalized := QbarNormalizeAlias(alias)
        if alias = "" || normalized = "" || InStr(alias, "`n") || InStr(alias, "`r") {
            errorText := "命令别名不能为空或包含换行。"
            return false
        }
        if seen.Has(normalized)
            continue
        seen[normalized] := true
        aliases.Push(alias)
    }
    return true
}

QbarPluginHostCreateUserPlugin(kind, displayName, aliases, settings) {
    if Type(kind) != "String" || Type(displayName) != "String"
        return false
    kind := StrLower(Trim(String(kind)))
    if kind != "search" && kind != "run"
        return false
    definitionId := "builtin." . kind
    definition := QbarPluginCatalogDefinitionById(definitionId)
    if !IsObject(definition) || Type(settings) != "Map"
        return false
    displayName := Trim(String(displayName))
    if displayName = "" || StrLen(displayName) > 80
        return false
    if !QbarPluginHostNormalizeAliases(aliases, &userAliases, &aliasError)
        return false
    if !QbarPluginHostNormalizeSettings(definition, settings, &normalizedSettings, &settingsError)
        return false
    settings := normalizedSettings
    suffixSeed := userAliases.Length ? userAliases[1] : displayName
    suffix := QbarPluginHostUniqueSuffix(suffixSeed)
    pluginId := "user." . kind . "." . suffix
    commandId := pluginId . ".execute"
    command := 0
    for candidate in definition["commands"] {
        command := QbarPluginHostCommandCopy(candidate, commandId)
        break
    }
    if !IsObject(command)
        return false
    instance := Map("definitionId", definitionId, "pluginId", pluginId, "source", "user",
        "displayName", displayName)
    criticalState := Critical("On")
    try {
        if !QbarStoreBegin()
            return false
        try {
            if !QbarStoreUpsertPlugin(instance)
                throw Error(QbarStoreError != "" ? QbarStoreError : "保存用户插件失败")
            if !QbarStoreUpsertCommand(pluginId, command)
                throw Error(QbarStoreError != "" ? QbarStoreError : "保存用户命令失败")
            for alias in userAliases
                if !QbarStoreEnsureAlias(commandId, alias, "user", false)
                    throw Error(QbarStoreError != "" ? QbarStoreError : "保存用户别名失败")
            if !QbarStoreSetPluginSettings(pluginId, settings, 1, false)
                throw Error(QbarStoreError != "" ? QbarStoreError : "保存用户插件设置失败")
            if !QbarRegistryBuild(&nextRegistry)
                throw Error(QbarRegistryError != "" ? QbarRegistryError : "创建后的注册表构建失败")
            if !QbarStoreCommit()
                throw Error(QbarStoreError != "" ? QbarStoreError : "提交用户插件失败")
        } catch as createError {
            try QbarStoreRollback()
            DebugLog("Qbar user plugin creation failed: " . createError.Message)
            return false
        }
        QbarRegistryPublish(nextRegistry)
    } finally {
        Critical(criticalState)
    }
    QbarPluginHostRefreshIndex()
    DebugLog("Qbar user plugin created plugin=" . pluginId
        . " generation=" . QbarRegistryGeneration())
    return true
}

; Persistence and registry publication have already succeeded here. Keep a
; derived-index refresh error from turning a committed save into a false
; failure, and retry a few times without repeating the database transaction.
QbarPluginHostRefreshIndex(attempt := 0, *) {
    try {
        QbarInvalidateConfigIndex()
        return true
    } catch as refreshError {
        DebugLog("Qbar committed change index refresh failed attempt=" . (attempt + 1)
            . " error=" . refreshError.Message)
        if attempt < 2 {
            try SetTimer(QbarPluginHostRefreshIndex.Bind(attempt + 1), -500)
            catch
                DebugLog("Qbar index refresh retry could not be scheduled")
        }
        return false
    }
}

QbarPluginHostUniqueSuffix(alias) {
    base := RegExReplace(StrLower(alias), "[^a-z0-9]+", "-")
    base := Trim(base, "-")
    if base = ""
        base := "command"
    return base . "-" . A_TickCount . "-" . Random(1000, 9999)
}

QbarPluginHostShutdown() {
    global QbarPluginHostReady, QbarPluginHostError
    QbarPluginHostReady := false
    QbarPluginHostError := ""
    QbarStoreClose()
}
