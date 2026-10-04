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

    try {
        QbarPluginHostRegisterCatalog()
        if !QbarRegistryRebuild()
            throw Error(QbarRegistryError != "" ? QbarRegistryError : "Qbar 注册表构建失败")
        QbarPluginHostReady := true
        commandCount := IsObject(QbarRuntimeRegistry) ? QbarRuntimeRegistry["byCommandId"].Count : 0
        aliasCount := IsObject(QbarRuntimeRegistry) ? QbarRuntimeRegistry["byAlias"].Count : 0
        DebugLog("Qbar plugin host ready commands=" . commandCount . " aliases=" . aliasCount)
        return true
    } catch as initError {
        QbarPluginHostError := initError.Message
        DebugLog("Qbar plugin host initialization failed: " . QbarPluginHostError)
        QbarPluginHostReady := false
        return false
    }
}

QbarPluginHostRegisterCatalog() {
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
            }
            settings := instance.Has("settings") ? instance["settings"] : Map()
            if !QbarStoreEnsurePluginSettings(instance["pluginId"], 1, settings)
                throw Error(QbarStoreError != "" ? QbarStoreError : "保存插件设置失败")
        }
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
    if Type(plugins) != "Array" {
        QbarPluginHostError := "插件修改列表无效"
        DebugLog("Qbar plugin changes rejected: invalid list")
        return false
    }
    DebugLog("Qbar plugin changes begin count=" . plugins.Length)
    if !QbarStoreBegin() {
        QbarPluginHostError := QbarStoreError != "" ? QbarStoreError : "无法开始插件修改事务"
        DebugLog("Qbar plugin changes begin failed: " . QbarPluginHostError)
        return false
    }
    try {
        for plugin in plugins {
            if Type(plugin) != "Map" || !plugin.Has("pluginId")
                throw Error("插件修改数据无效")
            pluginId := String(plugin["pluginId"])
            DebugLog("Qbar plugin change plugin=" . pluginId)
            if plugin.Has("enabled")
                if !QbarStoreSetPluginEnabled(pluginId, QbarPluginHostBoolean(plugin["enabled"]))
                    throw Error(QbarStoreError != "" ? QbarStoreError : "保存插件状态失败")
            if plugin.Has("displayName") || plugin.Has("name") {
                displayName := plugin.Has("displayName")
                    ? Trim(String(plugin["displayName"])) : Trim(String(plugin["name"]))
                if displayName = "" || !QbarStoreSetPluginDisplayName(pluginId, displayName)
                    throw Error(QbarStoreError != "" ? QbarStoreError : "保存工具名称失败")
            }
            if plugin.Has("settings") && Type(plugin["settings"]) = "Map"
                if !QbarStoreSetPluginSettings(pluginId, plugin["settings"], 1, false)
                    throw Error(QbarStoreError != "" ? QbarStoreError : "保存插件设置失败")
            if !plugin.Has("commands") || Type(plugin["commands"]) != "Array"
                continue
            for command in plugin["commands"] {
                if Type(command) != "Map" || !command.Has("commandId")
                    throw Error("插件命令修改数据无效")
                if command.Has("aliases") {
                    if !QbarStoreApplyCommandAliases(String(command["commandId"]), command["aliases"])
                        throw Error(QbarStoreError != "" ? QbarStoreError : "保存命令别名失败")
                }
            }
        }
        if !QbarStoreCommit()
            throw Error(QbarStoreError != "" ? QbarStoreError : "提交插件修改失败")
    } catch as changeError {
        try QbarStoreRollback()
        QbarPluginHostError := changeError.Message
        DebugLog("Qbar plugin settings failed: " . QbarPluginHostError)
        return false
    }
    if !QbarRegistryRebuild() {
        QbarPluginHostError := QbarRegistryError != "" ? QbarRegistryError : "插件注册表刷新失败"
        DebugLog("Qbar plugin changes registry rebuild failed: " . QbarPluginHostError)
        return false
    }
    QbarInvalidateConfigIndex()
    DebugLog("Qbar plugin changes committed count=" . plugins.Length)
    return true
}

QbarPluginHostDeletePlugin(pluginId) {
    global QbarPluginHostError, QbarStoreError, QbarRegistryError
    QbarPluginHostError := ""
    pluginId := Trim(String(pluginId))
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
        if !QbarStoreCommit()
            throw Error(QbarStoreError != "" ? QbarStoreError : "提交工具删除失败")
    } catch as deleteError {
        try QbarStoreRollback()
        QbarPluginHostError := deleteError.Message
        DebugLog("Qbar plugin delete failed plugin=" . pluginId . " error=" . QbarPluginHostError)
        return false
    }
    if !QbarRegistryRebuild() {
        QbarPluginHostError := QbarRegistryError != "" ? QbarRegistryError : "插件注册表刷新失败"
        DebugLog("Qbar plugin delete registry rebuild failed plugin=" . pluginId)
        return false
    }
    QbarInvalidateConfigIndex()
    DebugLog("Qbar plugin deleted plugin=" . pluginId)
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

QbarPluginHostBoolean(value, fallback := false) {
    if Type(value) = "ComValue" {
        try return value == JSON.true
        catch
            return fallback
    }
    if Type(value) = "Integer"
        return value != 0
    normalized := StrLower(Trim(String(value)))
    if normalized = "true" || normalized = "1"
        return true
    if normalized = "false" || normalized = "0"
        return false
    return fallback
}

QbarPluginHostCreateUserPlugin(kind, displayName, aliases, settings) {
    kind := StrLower(Trim(String(kind)))
    if kind != "search" && kind != "run"
        return false
    definitionId := "builtin." . kind
    definition := QbarPluginCatalogDefinitionById(definitionId)
    if !IsObject(definition) || !IsObject(settings)
        return false
    if Type(aliases) != "Array"
        return false
    displayName := Trim(String(displayName))
    if displayName = ""
        return false
    userAliases := []
    seenAliases := Map()
    for alias in aliases {
        if Type(alias) != "String"
            return false
        rawAlias := Trim(alias)
        if rawAlias = ""
            continue
        if InStr(rawAlias, "`n") || InStr(rawAlias, "`r")
            return false
        normalizedAlias := QbarNormalizeAlias(rawAlias)
        if normalizedAlias = "" || seenAliases.Has(normalizedAlias)
            continue
        seenAliases[normalizedAlias] := true
        userAliases.Push(rawAlias)
    }
    if kind = "search" {
        if !settings.Has("template") || !InStr(String(settings["template"]), "{q}")
            return false
        settings["template"] := String(settings["template"])
        settings["encodeQuery"] := !settings.Has("encodeQuery")
            || QbarPluginHostBoolean(settings["encodeQuery"], true)
    } else {
        if !settings.Has("command") || Trim(String(settings["command"])) = ""
            return false
        settings["command"] := String(settings["command"])
        settings["runAs"] := settings.Has("runAs")
            && QbarPluginHostBoolean(settings["runAs"])
        settings["argumentMode"] := "append"
    }
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
        if !QbarStoreCommit()
            throw Error(QbarStoreError != "" ? QbarStoreError : "提交用户插件失败")
    } catch as createError {
        try QbarStoreRollback()
        DebugLog("Qbar user plugin creation failed: " . createError.Message)
        return false
    }
    if !QbarRegistryRebuild()
        return false
    QbarInvalidateConfigIndex()
    return true
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
