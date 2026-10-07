; Settings editor: one baseline, complete draft validation and one database commit.

global SettingsEditData := 0
global SettingsEditSessionId := ""
global SettingsEditGeneration := 0
global SettingsLastRequestId := 0

SettingsSectionSnapshot(section, document) {
    result := Map()
    values := document[section]
    for key, value in values {
        if ConfigIsDynamicSection(section) && String(value) = ""
            continue
        field := ConfigField(section, key)
        if IsObject(field) && field.Has("type") && field["type"] = "secret" {
            result[key] := Map("op", "keep", "present", String(value) != "" ? JSON.true : JSON.false)
            continue
        }
        result[key] := String(value)
    }
    if section = "TTranslate" {
        languageA := TranslateNormalizeLanguage(result.Has("languageA") ? result["languageA"] : "")
        languageB := TranslateNormalizeLanguage(result.Has("languageB") ? result["languageB"] : "")
        target := TranslateNormalizeLanguage(result.Has("targetLanguage") ? result["targetLanguage"] : "", true)
        result["languageA"] := languageA
        result["languageB"] := languageB
        result["targetLanguage"] := target
    }
    return result
}

SettingsBindingSnapshot(bindings) {
    result := []
    Loop 10 {
        bindingNumber := A_Index
        row := Map("number", bindingNumber, "bindType", 0, "applicationPath", "", "items", [])
        if bindings.Has(bindingNumber) {
            binding := bindings[bindingNumber]
            row["bindType"] := WindowBindingType(binding.bindType, 0)
            row["applicationPath"] := WindowBindingApplicationPath(binding)
            items := []
            for item in binding.items
                items.Push(Map("title", "",
                    "windowClass", item.windowClass, "exe", item.exe, "path", item.path))
            row["items"] := items
        }
        result.Push(row)
    }
    return result
}

SettingsPushSnapshot(*) {
    global SettingsHost, SettingsVisible, SettingsPendingPage, SettingsPendingToast
    global SettingsEditData, SettingsEditSessionId, SettingsEditGeneration, SettingsLastRequestId
    if !SettingsVisible || !IsObject(SettingsHost) || !PanelHostPageReady(SettingsHost)
        return
    try {
        captureStartedAt := A_TickCount
        reused := IsObject(SettingsEditData)
        if !IsObject(SettingsEditData) {
            SettingsEditData := SettingsCaptureEditData()
            SettingsEditGeneration += 1
            SettingsEditSessionId := "settings_" . SettingsEditGeneration . "_" . A_TickCount
            SettingsLastRequestId := 0
        }
        SettingsLogTiming("capture", captureStartedAt, " reused=" . (reused ? 1 : 0))
        buildStartedAt := A_TickCount
        snapshot := SettingsBuildSnapshot(SettingsEditData)
        SettingsLogTiming("snapshot-build", buildStartedAt)
        postStartedAt := A_TickCount
        sent := SettingsPost("snapshot", snapshot)
        SettingsLogTiming("snapshot-post", postStartedAt, " sent=" . (sent ? 1 : 0))
        SettingsPendingToast := ""
    } catch as loadError {
        DiagnosticLogAlways("Settings snapshot failed errorType=" . Type(loadError)
            . " detail=" . loadError.Message)
        SettingsInvalidateEditSession()
        SettingsPost("loadFailed")
    }
}

SettingsInvalidateEditSession() {
    global SettingsEditData, SettingsEditSessionId, SettingsWindowSelectionTokens
    global WindowPickerVisible
    if WindowPickerVisible
        SettingsCloseWindowPicker(false)
    SettingsStopShortcutCapture()
    SettingsTestInvalidate()
    SettingsEditData := 0
    SettingsEditSessionId := ""
    SettingsWindowSelectionTokens := Map()
}

SettingsIsEditMessage(msg, duringSave := false) {
    global SettingsEditSessionId, SettingsEditData, SettingsVisible, SettingsSaving
    return SettingsVisible && IsObject(SettingsEditData) && SettingsEditSessionId != ""
        && LLMMsgField(msg, "sessionId") = SettingsEditSessionId && (duringSave || !SettingsSaving)
}

SettingsCaptureEditData() {
    data := 0
    if !AppStoreTransaction("settings-snapshot", (*) => (data := SettingsReadCurrentData()))
        throw Error("无法读取完整的设置快照")
    return data
}

SettingsReadCurrentData() {
    readStartedAt := A_TickCount
    if !SettingsStoreLoad(&defaults, &overrides) || !SettingsStoreValidateDefaultSet(defaults, &missing)
        throw Error("无法读取完整的默认设置")
    loadMs := A_TickCount - readStartedAt
    phaseStartedAt := A_TickCount
    effective := ConfigCloneDocument(defaults)
    ConfigOverlay(effective, overrides)
    for section in ConfigSchemaSections()
        if !effective.Has(section)
            effective[section] := Map()
    for section, values in effective
        for key, value in values {
            if !ConfigValidateValue(section, key, value, &normalized)
                throw Error("数据库中的设置值无效 " . section . "/" . key)
            values[key] := normalized
        }
    if !TranslateValidateOptions(effective["TTranslate"], &translationError)
        throw Error("数据库中的翻译选项无效")
    validateMs := A_TickCount - phaseStartedAt
    phaseStartedAt := A_TickCount
    if !AppProfileStoreRead(&profiles)
        throw Error("无法读取应用快捷键或窗口绑定")
    profilesMs := A_TickCount - phaseStartedAt
    phaseStartedAt := A_TickCount
    if !WindowBindingStoreRead(&bindings)
        throw Error("无法读取应用快捷键或窗口绑定")
    bindingsMs := A_TickCount - phaseStartedAt
    phaseStartedAt := A_TickCount
    if !QbarRegistryBuild(&registry, false)
        throw Error("无法读取工具设置")
    plugins := QbarRegistryPluginSnapshot(registry)
    registryMs := A_TickCount - phaseStartedAt
    SettingsLogTiming("store-read", readStartedAt, " loadMs=" . loadMs . " validateMs=" . validateMs
        . " profilesMs=" . profilesMs . " bindingsMs=" . bindingsMs . " registryMs=" . registryMs)

    return Map("effective", effective, "profiles", AppProfilesSnapshot(profiles),
        "bindings", SettingsBindingSnapshot(bindings), "plugins", plugins,
        "settingsRevision", AppStoreSettingsRevision())
}

SettingsBuildSnapshot(data) {
    global SettingsPendingPage, SettingsPendingToast, SettingsEditSessionId, AppVersion
    global SettingsOpenTraceId
    sections := Map(), tools := [], toolMetadata := Map()
    for section in ConfigSchemaSections()
        sections[section] := SettingsSectionSnapshot(section, data["effective"])
    for plugin in data["plugins"] {
        commandEnabled := false
        for command in plugin["commands"]
            if AppProfileBoolean(command["enabled"])
                commandEnabled := true
        tools.Push(SettingsEditablePlugin(plugin))
        toolMetadata[plugin["pluginId"]] := Map("definitionId", plugin["definitionId"],
            "source", plugin["source"], "deletable", plugin["deletable"],
            "commandEnabled", commandEnabled ? JSON.true : JSON.false,
            "definitionValid", plugin["definitionValid"], "settingsValid", plugin["settingsValid"],
            "settingsSchema", plugin["settingsSchema"])
    }
    bindings := []
    for row in data["bindings"] {
        clean := Map("number", row["number"], "bindType", row["bindType"],
            "applicationPath", row["applicationPath"], "items", [])
        for item in row["items"]
            clean["items"].Push(Map("path", item["path"], "exe", item["exe"], "windowClass", item["windowClass"]))
        bindings.Push(clean)
    }
    schema := ConfigEditorSchema()
    schema["tools"] := toolMetadata
    schema["creatableTools"] := Map()
    for kind in ["search", "run"] {
        definition := QbarPluginCatalogDefinitionById("builtin." . kind)
        schema["creatableTools"][kind] := Map("definitionId", definition["definitionId"],
            "source", "user", "deletable", JSON.true, "definitionValid", JSON.true,
            "settingsValid", JSON.true, "settingsSchema", definition["settingsSchema"])
    }
    return Map("sessionId", SettingsEditSessionId, "revision", data["settingsRevision"], "openTraceId", SettingsOpenTraceId,
        "appVersion", AppVersion, "uiLanguage", LLMUiLanguage(),
        "languageCatalog", TranslateLanguageCatalogSnapshot(), "page", SettingsPendingPage,
        "toast", SettingsPendingToast, "schema", schema,
        "customHotkeyActions", CustomHotkeyBuiltinActionSnapshot(), "bindingModes", WindowBindingModes(),
        "config", Map("sections", sections, "profiles", data["profiles"], "plugins", tools, "bindings", bindings))
}

SettingsEditablePlugin(plugin) {
    commands := []
    for command in plugin["commands"]
        commands.Push(Map("commandId", command["commandId"], "aliases", command["aliases"]))
    return Map("pluginId", plugin["pluginId"], "name", plugin.Get("name", plugin.Get("displayName", "")),
        "enabled", plugin["enabled"], "settings", plugin["settings"], "commands", commands)
}

SettingsBuildSaveReceipt() {
    global SettingsEditData
    SettingsEditData := SettingsCaptureEditData()
    return Map("snapshot", SettingsBuildSnapshot(SettingsEditData))
}

SettingsNormalizeDraft(raw, &document, &errorText) {
    global SettingsEditData
    errorText := ""
    document := Map()
    if Type(raw) != "Map" {
        errorText := "设置内容无效，请重新打开设置。"
        return false
    }
    for section in ConfigSchemaSections() {
        if !raw.Has(section) || Type(raw[section]) != "Map" {
            errorText := "设置内容不完整，请重新打开设置。"
            return false
        }
        document[section] := Map()
        for key, value in raw[section] {
            field := ConfigField(section, key)
            if IsObject(field) && field["type"] = "secret" {
                if Type(value) != "Map" || !value.Has("op") {
                    errorText := "密码修改信息无效。"
                    return false
                }
                switch value["op"] {
                    case "keep":
                        value := SettingsEditData["effective"][section][key]
                    case "clear":
                        value := ""
                    case "set":
                        if !value.Has("value") || Type(value["value"]) != "String" {
                            errorText := "密码修改信息无效。"
                            return false
                        }
                        value := value["value"]
                    default:
                        errorText := "密码修改信息无效。"
                        return false
                }
            }
            if !ConfigValidateValue(section, key, value, &normalized) {
                errorText := "请检查设置项“" . (IsObject(field) ? field.Get("label", key) : key) . "”。"
                return false
            }
            if IsObject(field) && field.Get("hidden", false)
                && normalized != SettingsEditData["effective"][section][key] {
                errorText := "部分设置无法在此页面修改。"
                return false
            }
            document[section][key] := normalized
        }
        definition := ConfigSchema()[section]
        if definition["kind"] = "keys"
            for key in SettingsEditData["effective"][section]
                if !document[section].Has(key) {
                    errorText := "快捷键配置不完整，请重新打开设置。"
                    return false
                }
        if definition["kind"] = "static"
            for key in definition["keys"]
                if !document[section].Has(key) {
                    errorText := "设置内容不完整，请重新打开设置。"
                    return false
                }
    }
    if raw.Count != document.Count {
        errorText := "包含未知的设置分组。"
        return false
    }
    return TranslateValidateOptions(document["TTranslate"], &errorText)
}

SettingsPrepareToolDraft(rows, &prepared, &deleted, &errorText) {
    global SettingsEditData
    prepared := [], deleted := [], errorText := ""
    if Type(rows) != "Array" {
        errorText := "工具列表无效。"
        return false
    }
    base := Map(), seen := Map(), changed := [], reserved := Map()
    for plugin in SettingsEditData["plugins"]
        base[plugin["pluginId"]] := plugin
    for raw in rows {
        if Type(raw) != "Map" {
            errorText := "工具信息无效。"
            return false
        }
        if raw.Has("draftId") {
            if raw.Has("pluginId") || Type(raw["draftId"]) != "String" || raw["draftId"] = ""
                || seen.Has(raw["draftId"]) {
                errorText := "新增工具信息重复或无效。"
                return false
            }
            seen[raw["draftId"]] := true
            if !QbarPluginHostPrepareNewPlugin(raw, &patch, &errorText, reserved)
                return false
            prepared.Push(patch)
        } else {
            if !raw.Has("pluginId") || Type(raw["pluginId"]) != "String"
                || !base.Has(raw["pluginId"]) || seen.Has(raw["pluginId"]) {
                errorText := "工具身份无效，请重新打开设置。"
                return false
            }
            id := raw["pluginId"]
            seen[id] := true
            if JSON.stringify(raw, 0) != JSON.stringify(SettingsEditablePlugin(base[id]), 0)
                changed.Push(raw)
        }
    }
    if !QbarPluginHostPreparePluginChanges(changed, &patches, &errorText)
        return false
    for patch in patches
        prepared.Push(patch)
    for id in base
        if !seen.Has(id)
            deleted.Push(id)
    return QbarPluginHostValidatePluginDeletes(prepared, deleted, &errorText)
}

SettingsApplyDraft(message) {
    global SettingsSaving, SettingsWindowSelectionTokens
    global SettingsEditData, SettingsLastRequestId, WinBindings
    msg := LLMMessageParse(message)
    requestId := LLMMsgNumber(msg, "requestId", &requestValid, 0, true)
    sessionId := LLMMsgField(msg, "sessionId")
    committed := false
    try {
        revision := LLMMsgNumber(msg, "revision", &revisionValid, -1, true)
        if !SettingsIsEditMessage(msg, true) || !requestValid || requestId < 1
            || requestId <= SettingsLastRequestId || !revisionValid
            || revision != SettingsEditData["settingsRevision"] {
            SettingsSendSaved(false, "设置页面已过期，请取消后重新载入。", 0, requestId, sessionId)
            return
        }
        SettingsLastRequestId := requestId
        if msg.Has("page")
            SettingsSetPendingPage(LLMMsgField(msg, "page"))
        if !msg.Has("draft") || Type(msg["draft"]) != "Map"
            throw Error("设置草稿格式无效")
        draft := msg["draft"]
        for domain in ["sections", "profiles", "bindings", "plugins"]
            if !draft.Has(domain)
                throw Error("设置草稿缺少必要分组")
        if !SettingsNormalizeDraft(draft["sections"], &document, &errorText)
            || !AppProfilesNormalizeDraft(draft["profiles"], &profiles, &errorText)
            || !SettingsValidateBindingDraft(draft["bindings"], &bindings, &errorText)
            || !SettingsPrepareToolDraft(draft["plugins"], &plugins, &deleted, &errorText) {
            SettingsSendSaved(false, errorText, 0, requestId, sessionId)
            return
        }
        changes := ConfigEffectiveDiff(SettingsEditData["effective"], document)
        if JSON.stringify(profiles, 0) = JSON.stringify(SettingsEditData["profiles"], 0)
            profiles := 0
        commitError := ""
        candidateRegistry := 0
        if !AppStoreTransaction("settings", (*) => SettingsCommitDraft(
            revision, changes, profiles, bindings, plugins, deleted, &candidateRegistry, &commitError)) {
            SettingsSendSaved(false, commitError != "" ? commitError
                : "保存失败，修改仍保留在当前页面。", 0, requestId, sessionId)
            return
        }
        committed := true
        if IsObject(candidateRegistry) {
            QbarRegistryPublish(candidateRegistry)
            QbarPluginHostRefreshIndex()
            ClipboardHistoryOnPluginSettingsChanged()
        }
        for row in bindings {
            slot := row["number"]
            if IsObject(row["binding"]) {
                WinBindings[slot] := CloneWindowBinding(row["binding"])
                for item in WinBindings[slot].items
                    if !item.id
                        item.id := FindReplacementWindow(item)
            } else if WinBindings.Has(slot)
                WinBindings.Delete(slot)
        }
        SettingsWindowSelectionTokens := Map()
        loadSucceeded := false
        errors := ReloadSettings(false, false, &loadSucceeded)
        text := loadSucceeded && !errors.Length
            ? "设置已保存。" : "设置已保存，但部分功能尚未应用；请重新启动应用。"
        SettingsSendSaved(true, text, SettingsBuildSaveReceipt(), requestId, sessionId)
    } catch as saveError {
        DiagnosticLogAlways("Settings save exception committed=" . (committed ? 1 : 0)
            . " errorType=" . Type(saveError) . " detail=" . saveError.Message)
        receipt := 0
        if committed {
            try receipt := SettingsBuildSaveReceipt()
            SettingsSendSaved(true, "设置已保存，但部分功能尚未应用；请重新启动应用。", receipt, requestId, sessionId)
        } else
            SettingsSendSaved(false, "保存失败，修改仍保留在当前页面。", 0, requestId, sessionId)
    } finally {
        SettingsSaving := false
    }
}

SettingsBindingLogicalValue(row) {
    mode := row.Has("bindType") ? WindowBindingType(row["bindType"], 0) : 0
    result := Map("bindType", mode,
        "applicationPath", row.Has("applicationPath") ? String(row["applicationPath"]) : "",
        "items", [])
    if mode != 3 && row.Has("items") && Type(row["items"]) = "Array"
        for item in row["items"]
            if Type(item) = "Map"
                result["items"].Push(Map("path", String(item.Get("path", "")),
                    "exe", String(item.Get("exe", "")),
                    "windowClass", String(item.Get("windowClass", ""))))
    return result
}

SettingsCommitDraft(revision, changes, profiles, bindings, plugins, deleted, &candidateRegistry, &commitError) {
    global AppStoreDb
    if AppStoreSettingsRevision() != revision {
        commitError := "设置已在其他位置变化，请取消后重新载入。"
        DiagnosticLogAlways("Settings save rejected reason=revision-conflict")
        return false
    }
    if !changes.Count && !IsObject(profiles) && !bindings.Length && !plugins.Length && !deleted.Length
        return true
    if !SettingsStoreWriteChanges(changes, profiles)
        return false
    if bindings.Length && !WindowBindingStoreApplyDraft(bindings)
        return false
    if (plugins.Length || deleted.Length)
        && !QbarPluginHostApplyPluginChanges(plugins, deleted, &candidateRegistry)
        return false
    return AppStoreIncrementSettingsRevision(AppStoreDb)
}

SettingsSendSaved(ok, text, receipt := 0, requestId := 0, sessionId := "") {
    SettingsPost("saved", Map("ok", ok ? JSON.true : JSON.false, "text", text,
        "snapshot", IsObject(receipt) ? receipt["snapshot"] : JSON.null,
        "requestId", requestId, "sessionId", sessionId))
}
