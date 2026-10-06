; Settings panel facade: lifecycle, message routing, configuration drafts and save receipts.

global SettingsHost := 0
global SettingsVisible := false
global SettingsPendingPage := "general"
global SettingsPendingToast := ""
global SettingsTestGeneration := 0
global SettingsTestOperation := 0

SettingsShow(initialPage := "general", toastMessage := "", *) {
    global SettingsHost, SettingsVisible, SettingsPendingPage, SettingsPendingToast
    initialPage := StrLower(Trim(initialPage))
    SettingsPendingPage := SettingsPageIsAllowed(initialPage) ? initialPage : "general"
    SettingsPendingToast := Trim(String(toastMessage))
    SettingsVisible := true
    if !SettingsEnsureWebView() {
        SettingsTestInvalidate()
        SettingsVisible := false
        return
    }
    ; Keep the native window state (including maximize/minimize) between opens.
    PanelHostShow(SettingsHost, 0, 0, false)
    panelGui := PanelHostGui(SettingsHost)
    if IsObject(panelGui)
        WinActivate("ahk_id " . panelGui.Hwnd)
    if PanelHostPageReady(SettingsHost)
        SetTimer(SettingsPushSnapshot, -1)
    return true
}

SettingsEnsureWebView() {
    global SettingsHost
    pagePath := A_ScriptDir . "\pages\settings.html"
    if IsObject(SettingsHost) {
        try {
            PanelHostEnsure(SettingsHost)
            return true
        } catch as existingError {
            PanelHostHide(SettingsHost)
            DebugLog("settings webview initialization failed stage=existing errorType="
                . Type(existingError))
            ShowMsg(LLMText(
                "Unable to open Settings. Try again or restart the app.",
                "无法打开设置。请重试或重新启动应用。"), 5000)
            return false
        }
    }

    settingsSize := ScreenFitSize(820, 620, 720, 520)
    SettingsHost := PanelHostCreate(pagePath, "capslock_p2 设置", Map(
        "guiOptions", "+Resize +MinSize720x520 +MinimizeBox +MaximizeBox +SysMenu",
        "dataPath", A_Temp . "\CapsLockPlusSettingsWebView2",
        "initialShow", "w" . settingsSize[1] . " h" . settingsSize[2] . " Center",
        "callbacks", Map(
            "close", SettingsRequestClose,
            "resize", SettingsResize,
            "navigation", SettingsNavigationCompleted,
            "message", SettingsWebMessageReceived,
            "backColor", SettingsIsDarkTheme() ? "20242B" : "F5F7FB")))
    try {
        PanelHostEnsure(SettingsHost)
        return true
    } catch as webViewError {
        DebugLog("settings webview initialization failed stage=create errorType="
            . Type(webViewError))
        PanelHostHide(SettingsHost)
        ShowMsg(LLMText(
            "Unable to open Settings. Try again or restart the app.",
            "无法打开设置。请重试或重新启动应用。"), 5000)
        return false
    }
}

SettingsNavigationCompleted(host, sender, args) {
    global SettingsVisible
    SettingsTestInvalidate()
    if !PanelHostPageReady(host) {
        ShowMsg(LLMText(
            "The Settings page could not be loaded. Try reopening it.",
            "设置页面无法加载，请重新打开设置。"), 3500)
    } else if SettingsVisible
        SetTimer(SettingsPushSnapshot, -1)
}

SettingsWebMessageReceived(sender, args) {
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    messageType := LLMMsgField(msg, "type")
    if messageType = "hide"
        SettingsHide()
    else if messageType = "getSettings"
        SetTimer(SettingsPushSnapshot, -1)
    else if messageType = "setSettingsPage"
        SettingsSetPendingPage(LLMMsgField(msg, "page"))
    else if messageType = "saveSettings" {
        DebugLog("Settings save message received")
        SetTimer(SettingsApplyDraft.Bind(message), -1)
    }
    else if messageType = "saveQbarPlugin" {
        DebugLog("Settings received saveQbarPlugin")
        SetTimer(SettingsApplyQbarPlugin.Bind(message), -1)
    }
    else if messageType = "deleteQbarPlugin"
        SetTimer(SettingsDeleteQbarPlugin.Bind(message), -1)
    else if messageType = "createPlugin"
        SetTimer(SettingsCreatePlugin.Bind(message), -1)
    else if messageType = "selectHotkeyApplication"
        SetTimer(SettingsSelectHotkeyApplication, -1)
    else if messageType = "selectHotkeyOpenApplication" {
        DebugLog("Hotkey application picker requested")
        SetTimer(SettingsShowHotkeyApplicationPicker, -1)
    } else if messageType = "selectHotkeyApplicationPath"
        SetTimer(SettingsSelectHotkeyApplicationPath.Bind(LLMMsgField(msg, "path")), -1)
    else if messageType = "hotkeyPickerTrace" {
        stage := RegExReplace(LLMMsgField(msg, "stage"), "[^A-Za-z0-9_-]", "")
        rowCountValid := false
        rowCount := LLMMsgNumber(msg, "rowCount", &rowCountValid, 0, true)
        indexValid := false
        index := LLMMsgNumber(msg, "index", &indexValid, 0, true)
        DebugLog("Hotkey picker UI stage=" . stage
            . (rowCountValid ? " rows=" . rowCount : "")
            . (indexValid ? " index=" . index : ""))
    }
    else if messageType = "testSettings"
        SettingsStartTest(message)
    else if messageType = "startShortcutRecording"
        SettingsQueueShortcutCapture(message)
    else if messageType = "stopShortcutRecording"
        SettingsStopShortcutCaptureMessage(message)
    else if messageType = "selectOpenWindow"
        SetTimer(SettingsOpenWindowPicker.Bind(message), -1)
    else if messageType = "selectOpenApplication"
        SetTimer(SettingsOpenOpenApplicationPicker.Bind(message), -1)
    else if messageType = "selectOtherApplication"
        SetTimer(SettingsOpenOtherApplicationPicker.Bind(message), -1)
    else if messageType = "selectWindowPicker" {
        indexValid := false
        index := LLMMsgNumber(msg, "index", &indexValid, 0, true)
        if indexValid
            SetTimer(SettingsWindowPickerSelect.Bind(index), -1)
    } else if messageType = "cancelWindowPicker"
        SetTimer(SettingsWindowPickerCancel, -1)
}

SettingsCreatePlugin(message) {
    msg := LLMMessageParse(message)
    if !msg.Has("kind") || Type(msg["kind"]) != "String"
        || !msg.Has("displayName") || Type(msg["displayName"]) != "String"
        || (msg.Has("aliases") && Type(msg["aliases"]) != "Array")
        || (msg.Has("settings") && Type(msg["settings"]) != "Map") {
        SettingsSendQbarPluginCreated(false, LLMText("Tool data is invalid.", "工具数据无效。"))
        return
    }
    kind := msg["kind"]
    displayName := msg["displayName"]
    aliases := msg.Has("aliases") ? msg["aliases"] : []
    settings := msg.Has("settings") ? msg["settings"] : Map()
    DebugLog("Settings create Qbar plugin kind=" . kind)
    ok := QbarPluginHostCreateUserPlugin(kind, displayName, aliases, settings)
    if ok {
        receipt := SettingsBuildSaveReceipt(false, false, true)
        SettingsSendQbarPluginCreated(true, LLMText("Plugin created.", "插件已创建。"), receipt)
        SettingsPushSnapshot()
    } else {
        DebugLog("Settings create Qbar plugin failed kind=" . kind)
        SettingsSendQbarPluginCreated(false, LLMText("Plugin could not be created.", "插件创建失败。"))
    }
}

SettingsApplyQbarPlugin(message) {
    global SettingsFile, QbarStoreError, QbarPluginHostError, QbarRegistryError
    iniCommitted := false
    runtimeApplied := true
    settingsSubmitted := false
    pluginCommitted := false
    effectiveChanges := Map()
    plugin := 0
    pluginId := ""
    msg := LLMMessageParse(message)
    if !msg.Has("plugin") || Type(msg["plugin"]) != "Map" || !msg["plugin"].Has("pluginId") {
        DebugLog("Settings Qbar save rejected: invalid plugin payload")
        SettingsSendQbarPluginSaved(false, LLMText("Tool data is invalid.", "工具数据无效。"))
        return
    }
    if !QbarPluginHostPreparePluginChanges([msg["plugin"]], &preparedPlugins, &validationError) {
        DebugLog("Settings Qbar save rejected: plugin validation")
        SettingsSendQbarPluginSaved(false, validationError)
        return
    }
    plugin := preparedPlugins[1]
    pluginId := String(plugin["pluginId"])
    commandCount := plugin.Has("commands") && Type(plugin["commands"]) = "Array"
        ? plugin["commands"].Length : 0
    DebugLog("Settings Qbar save start plugin=" . pluginId . " commands=" . commandCount)
    if msg.Has("toolSettings") && Type(msg["toolSettings"]) != "Map" {
        SettingsSendQbarPluginSaved(false, "文件搜索设置格式无效。")
        return
    }
    toolSettings := msg.Has("toolSettings") ? msg["toolSettings"] : Map()
    maxResults := ""
    for key, value in toolSettings {
        if key != "esMaxResults" || pluginId != "builtin.everything" {
            SettingsSendQbarPluginSaved(false, "文件搜索设置项无效。")
            return
        }
        if !QbarPluginHostInteger(value, &parsedMaxResults)
            || parsedMaxResults < 1 || parsedMaxResults > 500 {
            DebugLog("Settings Qbar save rejected plugin=" . pluginId . " invalid esMaxResults")
            SettingsSendQbarPluginSaved(false, "文件搜索数量必须是 1 到 500 之间的整数。")
            return
        }
        maxResults := String(parsedMaxResults)
    }
    try {
        if maxResults != "" {
            settingsSubmitted := true
            changes := Map("Qbar", Map("esMaxResults", maxResults))
            originalContent := FileExist(SettingsFile) ? FileRead(SettingsFile, "UTF-8") : ""
            originalContent := StrReplace(originalContent, "`r`n", "`n")
            candidateContent := ""
            invalidChange := ""
            effectiveChanges := ConfigPrepareUserOverrides(
                changes, originalContent, &candidateContent, &invalidChange)
            settingsSubmitted := effectiveChanges.Count > 0
            if invalidChange != "" {
                DebugLog("Settings Qbar save rejected plugin=" . pluginId
                    . " invalid config=" . invalidChange)
                SettingsSendQbarPluginSaved(false, "文件搜索设置无效：" . invalidChange)
                return
            }
            if effectiveChanges.Count
                runtimeApplied := false
            if candidateContent != originalContent {
                ConfigAtomicWrite(SettingsFile, candidateContent)
                iniCommitted := true
            }
            if effectiveChanges.Count {
                loadSucceeded := false
                ReloadSettings(false, false, &loadSucceeded)
                if !loadSucceeded {
                    errorText := iniCommitted
                        ? "文件搜索数量已写入，但尚未应用。请检查配置文件并重新载入设置。"
                        : "文件搜索设置无法应用。请检查应用配置文件后重试。"
                    receipt := SettingsBuildSaveReceipt(false, false, false,
                        iniCommitted, false)
                    SettingsSendQbarPluginSaved(false, errorText, receipt)
                    return
                }
                runtimeApplied := true
            }
        }
        if !QbarPluginHostApplyPluginChanges([plugin]) {
            DebugLog("Settings Qbar save failed plugin=" . pluginId
                . " host=" . QbarPluginHostError . " store=" . QbarStoreError
                . " registry=" . QbarRegistryError)
            text := settingsSubmitted && runtimeApplied
                ? "文件搜索数量已保存，但工具设置未保存。请重试保存工具设置。"
                : LLMText("Tool settings could not be saved.", "工具设置保存失败。")
            receipt := SettingsBuildSaveReceipt(settingsSubmitted && runtimeApplied,
                false, false, iniCommitted, runtimeApplied)
            SettingsSendQbarPluginSaved(false, text, receipt)
            return
        }
        pluginCommitted := true
        notificationFailed := false
        if pluginId = "builtin.clipboard" {
            try ClipboardHistoryOnPluginSettingsChanged()
            catch as notificationError {
                notificationFailed := true
                DebugLog("Settings Qbar plugin saved but clipboard notification failed: "
                    . notificationError.Message)
            }
        }
        DebugLog("Settings Qbar save success plugin=" . pluginId)
        text := notificationFailed
            ? "工具设置已保存，但部分状态未能立即刷新。请重新打开相关面板。"
            : LLMText("Tool settings saved.", "工具设置已保存。")
        receipt := SettingsBuildSaveReceipt(settingsSubmitted && runtimeApplied,
            false, true, iniCommitted, runtimeApplied)
        SettingsSendQbarPluginSaved(true, text, receipt)
        try SettingsPushSnapshot()
        catch as snapshotError
            DebugLog("Settings Qbar snapshot push failed plugin=" . pluginId
                . " error=" . snapshotError.Message)
    } catch as saveError {
        DebugLog("Settings Qbar save exception plugin=" . pluginId
            . " error=" . saveError.Message . " host=" . QbarPluginHostError
            . " store=" . QbarStoreError . " registry=" . QbarRegistryError)
        if pluginCommitted {
            receipt := SettingsBuildSaveReceipt(settingsSubmitted && runtimeApplied,
                false, true, iniCommitted, runtimeApplied)
            SettingsSendQbarPluginSaved(true,
                "工具设置已保存，但部分状态未能立即刷新。请重新打开相关面板。", receipt)
        } else {
            if settingsSubmitted && iniCommitted && !runtimeApplied
                text := "文件搜索数量已写入但未应用，工具设置也未保存。请检查配置文件并重新载入设置。"
            else if settingsSubmitted && runtimeApplied
                text := "文件搜索数量已保存，但工具设置未保存。请重试保存工具设置。"
            else
                text := LLMText("Tool settings could not be saved.", "工具设置保存失败。")
            receipt := SettingsBuildSaveReceipt(settingsSubmitted && runtimeApplied,
                false, false, iniCommitted, runtimeApplied)
            SettingsSendQbarPluginSaved(false, text, receipt)
        }
    }
}

SettingsDeleteQbarPlugin(message) {
    msg := LLMMessageParse(message)
    pluginId := Trim(LLMMsgField(msg, "pluginId"))
    if pluginId = "" {
        SettingsSendQbarPluginDeleted(false, "工具信息无效。", "")
        return
    }
    if QbarPluginHostDeletePlugin(pluginId) {
        receipt := SettingsBuildSaveReceipt(false, false, true)
        SettingsSendQbarPluginDeleted(true, "工具已删除。", pluginId, receipt)
        SetTimer(SettingsPushSnapshot, -1)
        return
    }
    DebugLog("Settings Qbar plugin delete failed plugin=" . pluginId)
    SettingsSendQbarPluginDeleted(false, LLMText(
        "Unable to delete this tool. Please try again.",
        "无法删除此工具，请重试。"), pluginId, 0)
}

SettingsPageIsAllowed(page) {
    return page = "general" || page = "mouse" || page = "llm" || page = "translate"
        || page = "ai" || page = "shortcuts" || page = "tab" || page = "qbar" || page = "windows"
}

SettingsSetPendingPage(page) {
    global SettingsPendingPage
    page := StrLower(Trim(String(page)))
    if SettingsPageIsAllowed(page)
        SettingsPendingPage := page
}

SettingsConfigSections() {
    return ConfigSchemaSections()
}

SettingsSectionSnapshot(section) {
    result := Map()
    for key, value in ConfigSection(section) {
        if SettingsIsDynamicSection(section) && Trim(String(value)) = ""
            continue
        result[key] := String(value)
    }
    if section = "TTranslate" {
        languageA := TranslateNormalizeLanguage(result.Has("languageA") ? result["languageA"] : "")
        languageB := TranslateNormalizeLanguage(result.Has("languageB") ? result["languageB"] : "")
        target := TranslateNormalizeLanguage(result.Has("targetLanguage") ? result["targetLanguage"] : "", true)
        result["languageA"] := languageA = "" ? "zh-CN" : languageA
        result["languageB"] := languageB = "" ? "en" : languageB
        result["targetLanguage"] := target = "" ? "system" : target
    }
    return result
}

SettingsIsDynamicSection(section) {
    return ConfigIsDynamicSection(section)
}

SettingsKeySnapshot() {
    global KeySet
    result := Map()
    for key, value in KeySet
        result[key] := String(value)
    return result
}

SettingsBindingSnapshot() {
    global WinBindings
    result := []
    Loop 10 {
        bindingNumber := A_Index
        row := Map("number", bindingNumber, "bindType", 0, "applicationPath", "", "items", [])
        if WinBindings.Has(bindingNumber) {
            binding := WinBindings[bindingNumber]
            row["bindType"] := WindowBindingType(binding.bindType, 0)
            row["applicationPath"] := WindowBindingApplicationPath(binding)
            items := []
            for item in binding.items
                items.Push(Map("id", String(item.id), "title", WindowBindingItemTitle(item),
                    "windowClass", item.windowClass, "exe", item.exe, "path", item.path))
            row["items"] := items
        }
        result.Push(row)
    }
    return result
}

SettingsPushSnapshot(*) {
    global SettingsHost, SettingsPendingToast
    if !IsObject(SettingsHost)
        return
    payload := SettingsBuildSnapshot()
    PanelHostExecute(SettingsHost, "window.receiveSnapshot(" . JSON.stringify(payload, 0) . ");")
    SettingsPendingToast := ""
}

SettingsBuildSnapshot() {
    global SettingsPendingPage, SettingsPendingToast
    sections := Map()
    for section in SettingsConfigSections()
        sections[section] := SettingsSectionSnapshot(section)
    return Map(
        "uiLanguage", LLMUiLanguage(),
        "languageCatalog", TranslateLanguageCatalogSnapshot(),
        "page", SettingsPendingPage,
        "toast", SettingsPendingToast,
        "sections", sections,
        "keys", SettingsKeySnapshot(),
        "profiles", AppProfilesSnapshot(),
        "profileStamp", AppProfilesStampValue(),
        "bindings", SettingsBindingSnapshot(),
        "bindingModes", WindowBindingModes(),
        "plugins", QbarRegistryPluginSnapshot())
}

SettingsBuildSaveReceipt(sectionsCommitted := false, profilesCommitted := false,
    pluginsCommitted := false, settingsFileCommitted := false,
    runtimeApplied := true) {
    receipt := Map(
        "sectionsCommitted", sectionsCommitted,
        "profilesCommitted", profilesCommitted,
        "pluginsCommitted", pluginsCommitted,
        "settingsFileCommitted", settingsFileCommitted,
        "runtimeApplied", runtimeApplied)
    if sectionsCommitted || profilesCommitted || pluginsCommitted {
        snapshot := SettingsBuildSnapshot()
        receipt["uiLanguage"] := snapshot["uiLanguage"]
        receipt["bindings"] := snapshot["bindings"]
        receipt["bindingModes"] := snapshot["bindingModes"]
        if sectionsCommitted {
            receipt["sections"] := snapshot["sections"]
            receipt["keys"] := snapshot["keys"]
            for plugin in snapshot["plugins"]
                if plugin["pluginId"] = "builtin.everything" {
                    receipt["toolSettingsCommitted"] := true
                    receipt["toolSettings"] := plugin["toolSettings"]
                    break
            }
        }
        if profilesCommitted {
            receipt["profiles"] := snapshot["profiles"]
            receipt["profileStamp"] := snapshot["profileStamp"]
        }
        if pluginsCommitted
            receipt["plugins"] := snapshot["plugins"]
    }
    return receipt
}

SettingsAllowedKey(section, key) {
    return ConfigValidateKey(section, key)
}

SettingsCollectSectionChanges(changes, section, values) {
    if !IsObject(values)
        return
    if !changes.Has(section)
        changes[section] := Map()
    for key, value in values {
        if IsObject(value) || !SettingsAllowedKey(section, String(key))
            continue
        changes[section][String(key)] := String(value)
    }
}

SettingsApplyDraft(message) {
    global SettingsFile
    msg := LLMMessageParse(message)
    sections := 0
    if msg.Has("sections") && IsObject(msg["sections"])
        sections := msg["sections"]
    else if msg.Has("draft") && IsObject(msg["draft"])
        && msg["draft"].Has("sections") && IsObject(msg["draft"]["sections"])
        sections := msg["draft"]["sections"]
    if !IsObject(sections)
        return
    saveIdValid := false
    saveId := LLMMsgNumber(msg, "saveId", &saveIdValid, 0, true)
    if !saveIdValid || saveId < 1
        saveId := 0
    if msg.Has("page")
        SettingsSetPendingPage(LLMMsgField(msg, "page"))
    savePhase := "collect settings"
    sectionsSubmitted := false
    profilesDirty := false
    pluginsSubmitted := false
    pluginsCommitted := false
    settingsFileWritten := false
    runtimeApplied := true
    try {
        changes := Map()
        for section in SettingsConfigSections() {
            if sections.Has(section)
                SettingsCollectSectionChanges(changes, section, sections[section])
        }
        savePhase := "check external settings changes"
        if msg.Has("base") && IsObject(msg["base"]) {
            conflict := SettingsFindDraftConflict(changes, msg["base"])
            if conflict != "" {
                SettingsSendSaved(false, LLMText(
                    "The setting changed outside the settings page: " . conflict,
                    "设置页外部已修改该字段：" . conflict), 0, saveId)
                return
            }
        }
        savePhase := "validate translation settings"
        if !SettingsValidateTranslationChanges(changes, &translationError) {
            SettingsSendSaved(false, translationError, 0, saveId)
            return
        }

        savePhase := "read application profile changes"
        profilesDirty := msg.Has("profilesDirty") && AppProfileBoolean(msg["profilesDirty"], false)
        profiles := []
        if profilesDirty {
            if !msg.Has("profiles") || Type(msg["profiles"]) != "Array" {
                SettingsSendSaved(false, "应用配置数据无效。", 0, saveId)
                return
            }
            profiles := msg["profiles"]
        }
        DebugLog("Settings save request sections=" . changes.Count
            . " profilesDirty=" . profilesDirty . " profileCount=" . profiles.Length)
        if profilesDirty {
            savePhase := "load application profiles"
            ; Compare a candidate without publishing it. This catches profile
            ; edits within the same timestamp second and keeps the live state
            ; intact if the following complete reload cannot read the file.
            profilesChanged := false
            if !AppProfilesLoad(&profilesChanged, false) {
                SettingsSendSaved(false, "无法读取应用配置文件，请检查后重试。", 0, saveId)
                return
            }
            baseProfileStamp := msg.Has("baseProfileStamp") ? String(msg["baseProfileStamp"]) : ""
            if profilesChanged || baseProfileStamp != AppProfilesStampValue() {
                ; Reload the changed external state before asking the user to
                ; discard this stale profile draft.
                loadSucceeded := false
                ReloadSettings(false, true, &loadSucceeded)
                if !loadSucceeded {
                    SettingsSendSaved(false,
                        "外部配置已变化，但当前配置文件无法完整读取。请检查文件后重试。",
                        0, saveId)
                    return
                }
                SettingsSendSaved(false, "应用配置在设置页外发生了变化，请取消后重新载入。",
                    0, saveId)
                return
            }
            savePhase := "normalize application profiles"
            if !AppProfilesNormalizeDraft(profiles, &normalizedProfiles, &profileError) {
                SettingsSendSaved(false, profileError, 0, saveId)
                return
            }
        }
        if msg.Has("plugins") {
            pluginsSubmitted := true
            savePhase := "validate plugin changes"
            if !QbarPluginHostPreparePluginChanges(msg["plugins"],
                &preparedPlugins, &pluginValidationError) {
                SettingsSendSaved(false, LLMText(
                    "Plugin settings are invalid.", pluginValidationError), 0, saveId)
                return
            }
            msg["plugins"] := preparedPlugins
        }
        invalidChange := ""
        candidateContent := ""
        originalContent := FileExist(SettingsFile) ? FileRead(SettingsFile, "UTF-8") : ""
        originalContent := StrReplace(originalContent, "`r`n", "`n")
        savePhase := "prepare global settings"
        effectiveChanges := ConfigPrepareUserOverrides(
            changes, originalContent, &candidateContent, &invalidChange)
        sectionsSubmitted := effectiveChanges.Count > 0
        if invalidChange != "" {
            SettingsSendSaved(false, LLMText(
                "Invalid setting value: " . invalidChange,
                "设置值无效：" . invalidChange), 0, saveId)
            return
        }
        if profilesDirty {
            savePhase := "prepare application profiles"
            if !AppProfilePrepareDraftContent(normalizedProfiles, candidateContent,
                &candidateContent, &profileError) {
                SettingsSendSaved(false, profileError, 0, saveId)
                return
            }
        }
        if effectiveChanges.Count || profilesDirty
            runtimeApplied := false
        if candidateContent != originalContent {
            savePhase := "write settings file"
            ConfigAtomicWrite(SettingsFile, candidateContent)
            settingsFileWritten := true
        }
        registrationErrors := []
        loadSucceeded := true
        if effectiveChanges.Count || profilesDirty {
            savePhase := "reload settings"
            loadSucceeded := false
            registrationErrors := ReloadSettings(false, false, &loadSucceeded)
            runtimeApplied := loadSucceeded
            if !loadSucceeded {
                errorText := settingsFileWritten
                    ? "设置已写入，但未能应用。请检查应用配置文件后重试。"
                    : "设置无法应用。请检查应用配置文件后重试。"
                receipt := SettingsBuildSaveReceipt(false, false, false,
                    settingsFileWritten, false)
                SettingsSendSaved(false, errorText, receipt, saveId)
                return
            }
            runtimeApplied := true
        }
        if msg.Has("plugins") && Type(msg["plugins"]) = "Array" {
            savePhase := "save plugin settings"
            if !QbarPluginHostApplyPluginChanges(msg["plugins"]) {
                receipt := SettingsBuildSaveReceipt(sectionsSubmitted,
                    profilesDirty, false, settingsFileWritten, loadSucceeded)
                SettingsSendSaved(false,
                    "应用配置已保存，但工具设置未保存。请重试保存工具设置。",
                    receipt, saveId)
                return
            }
            pluginsCommitted := true
        }
        if registrationErrors.Length {
            failedTriggers := ""
            for trigger in registrationErrors
                failedTriggers .= (failedTriggers = "" ? "" : "、") . trigger
            text := "设置已保存，但以下触发键无法启用：" . failedTriggers
        } else {
            text := LLMText("Settings saved.", "设置已保存。")
        }
        receipt := SettingsBuildSaveReceipt(sectionsSubmitted,
            profilesDirty, pluginsCommitted, settingsFileWritten, loadSucceeded)
        SettingsSendSaved(true, text, receipt, saveId)
        ; The save receipt updates committed baselines without replacing edits
        ; the user may have made while this request was in flight.
    } catch as saveError {
        DebugLog("Settings save exception phase=" . savePhase
            . " errorType=" . Type(saveError))
        configCommitted := runtimeApplied && (sectionsSubmitted || profilesDirty)
        if settingsFileWritten && !runtimeApplied {
            receipt := SettingsBuildSaveReceipt(false, false, pluginsCommitted,
                settingsFileWritten, false)
            text := pluginsSubmitted && !pluginsCommitted
                ? "设置已写入但未应用，工具设置也未保存。请检查配置文件并重新载入设置。"
                : "设置已写入，但尚未应用。请检查配置文件并重新载入设置。"
            SettingsSendSaved(false, text, receipt, saveId)
        } else if configCommitted && pluginsSubmitted && !pluginsCommitted {
            receipt := SettingsBuildSaveReceipt(sectionsSubmitted,
                profilesDirty, false, settingsFileWritten, runtimeApplied)
            SettingsSendSaved(false,
                "应用配置已保存，但工具设置未保存。请重试保存工具设置。",
                receipt, saveId)
        } else if (configCommitted || pluginsCommitted) {
            receipt := SettingsBuildSaveReceipt(sectionsSubmitted && runtimeApplied,
                profilesDirty && runtimeApplied, pluginsCommitted,
                settingsFileWritten, runtimeApplied)
            SettingsSendSaved(true,
                "设置已保存，但页面状态未能立即刷新。请重新打开设置页。",
                receipt, saveId)
        } else {
            SettingsSendSaved(false, LLMText("Save failed.", "保存失败。"), 0, saveId)
        }
    }
}

; ConfigSchema validates each scalar field. Translation mode additionally has
; a relationship between mode, the language pair and the fixed target, so
; validate the merged draft before touching the INI file.
SettingsValidateTranslationChanges(changes, &errorText := "") {
    errorText := ""
    if !IsObject(changes) || !changes.Has("TTranslate")
        return true
    options := TranslateOptionsSnapshot()
    values := changes["TTranslate"]
    if IsObject(values) {
        for key in ["mode", "languageA", "languageB", "targetLanguage"]
            if values.Has(key)
                options[key] := values[key]
    }
    if TranslateValidateOptions(options, &validationError)
        return true
    errorText := validationError
    return false
}

SettingsFindDraftConflict(changes, base) {
    if !IsObject(changes) || !IsObject(base)
        return ""
    for section, values in changes {
        if !IsObject(values)
            continue
        baseValues := base.Has(section) && IsObject(base[section]) ? base[section] : Map()
        for key, value in values {
            expected := baseValues.Has(key) ? String(baseValues[key]) : ConfigDefaultRead(section, key, "")
            current := ConfigRead(section, key, ConfigDefaultRead(section, key, ""))
            if section = "TabHotString" && baseValues.Has(key)
                expected := String(expected)
            if String(current) != expected
                return section . "/" . key
        }
    }
    return ""
}

SettingsSendSaved(ok, text, receipt := 0, requestId := 0) {
    global SettingsHost
    receiptJson := IsObject(receipt) ? JSON.stringify(receipt, 0) : "null"
    requestIdJson := requestId > 0 && requestId = Floor(requestId)
        ? String(Integer(requestId)) : "null"
    script := "window.settingsSaved(" . (ok ? "true" : "false") . ","
        . LLMJsonQuote(text) . "," . receiptJson . "," . requestIdJson . ");"
    PanelHostExecute(SettingsHost, script)
}

SettingsSendQbarPluginSaved(ok, text, receipt := 0) {
    global SettingsHost
    DebugLog("Settings Qbar save response ok=" . (ok ? "1" : "0"))
    receiptJson := IsObject(receipt) ? JSON.stringify(receipt, 0) : "null"
    script := "window.qbarPluginSaved(" . (ok ? "true" : "false") . ","
        . LLMJsonQuote(text) . "," . receiptJson . ");"
    try PanelHostExecute(SettingsHost, script)
    catch as responseError
        DebugLog("Settings Qbar save response delivery failed: " . responseError.Message)
}

SettingsSendQbarPluginCreated(ok, text, receipt := 0) {
    global SettingsHost
    DebugLog("Settings Qbar create response ok=" . (ok ? "1" : "0"))
    receiptJson := IsObject(receipt) ? JSON.stringify(receipt, 0) : "null"
    script := "window.qbarPluginCreated(" . (ok ? "true" : "false") . ","
        . LLMJsonQuote(text) . "," . receiptJson . ");"
    try PanelHostExecute(SettingsHost, script)
    catch as responseError
        DebugLog("Settings Qbar create response delivery failed: " . responseError.Message)
}

SettingsSendQbarPluginDeleted(ok, text, pluginId, receipt := 0) {
    global SettingsHost
    receiptJson := IsObject(receipt) ? JSON.stringify(receipt, 0) : "null"
    script := "window.qbarPluginDeleted(" . (ok ? "true" : "false") . ","
        . LLMJsonQuote(text) . "," . LLMJsonQuote(pluginId) . "," . receiptJson . ");"
    try PanelHostExecute(SettingsHost, script)
    catch as responseError
        DebugLog("Settings Qbar delete response delivery failed: " . responseError.Message)
}

SettingsStartTest(message) {
    global SettingsTestGeneration, SettingsTestOperation
    SettingsTestGeneration += 1
    generation := SettingsTestGeneration
    previousOperation := SettingsTestOperation
    SettingsTestOperation := 0
    if IsObject(previousOperation)
        previousOperation.Cancel()
    SetTimer(SettingsRunTest.Bind(message, generation), -1)
}

SettingsRunTest(message, generation) {
    global SettingsTestOperation
    if !SettingsTestIsCurrent(generation)
        return
    msg := LLMMessageParse(message)
    target := StrLower(LLMMsgField(msg, "target"))
    if target != "llm" && target != "youdao" && target != "volcengine"
        return
    operation := LLMAsyncOperation()
    SettingsTestOperation := operation
    try {
        if target = "llm" {
            overrides := LLMMessageOverrides(msg, [
                "endpoint", "apiKey", "apiKeyHeader", "apiKeyPrefix", "model",
                "temperature", "timeout", "thinking", "maxInputTokens"])
            childOperation := LLMChatCompleteAsync(
                [Map("role", "user", "content", "Hello! This is a capslock_p2 connection test.")],
                SettingsTestLlmFinished.Bind(generation, operation), overrides)
            SettingsTestAttachChild(operation, childOperation)
        } else {
            provider := TranslateGetProvider(target)
            if !IsObject(provider) || !provider.Has("test") {
                childOperation := LLMScheduleAsyncCallback(LLMAsyncOperation(),
                    SettingsTestComplete.Bind(generation, operation), false,
                    LLMText("Translation test is unavailable.", "翻译测试不可用。"))
                SettingsTestAttachChild(operation, childOperation)
            } else {
                childOperation := provider["test"].Call(msg,
                    SettingsTestProviderFinished.Bind(generation, operation))
                if IsObject(childOperation)
                    SettingsTestAttachChild(operation, childOperation)
                else {
                    childOperation := LLMScheduleAsyncCallback(LLMAsyncOperation(),
                        SettingsTestComplete.Bind(generation, operation), false,
                        LLMText("The connection test could not be started.", "无法启动连接测试。"))
                    SettingsTestAttachChild(operation, childOperation)
                }
            }
        }
    } catch {
        DebugLog("Settings connection test setup failed generation=" . generation)
        childOperation := LLMScheduleAsyncCallback(LLMAsyncOperation(),
            SettingsTestComplete.Bind(generation, operation), false,
            LLMText("The connection test could not be started.", "无法启动连接测试。"))
        SettingsTestAttachChild(operation, childOperation)
    }
}

SettingsTestLlmFinished(generation, operation, responseText, success, errorText) {
    resultText := success ? LLMText("Connection OK", "连接正常") : errorText
    SettingsTestComplete(generation, operation, success, resultText)
}

SettingsTestProviderFinished(generation, operation, success, text) {
    SettingsTestComplete(generation, operation, success, text)
}

SettingsTestComplete(generation, operation, ok, text) {
    global SettingsTestOperation
    criticalState := A_IsCritical
    Critical "On"
    try {
        if !SettingsTestIsCurrent(generation) || !operation.Complete()
            return
        SettingsTestOperation := 0
        SettingsSendTestResult(generation, ok, text)
    } finally {
        if !criticalState
            Critical "Off"
    }
}

SettingsTestAttachChild(operation, childOperation) {
    if IsObject(childOperation)
        operation.SetCancel(SettingsCancelTestChild.Bind(childOperation))
}

SettingsCancelTestChild(childOperation) {
    childOperation.Cancel()
}

SettingsTestIsCurrent(generation) {
    global SettingsTestGeneration, SettingsVisible, SettingsHost
    return generation = SettingsTestGeneration && SettingsVisible
        && IsObject(SettingsHost) && PanelHostPageReady(SettingsHost)
}

SettingsTestInvalidate() {
    global SettingsTestGeneration, SettingsTestOperation
    SettingsTestGeneration += 1
    operation := SettingsTestOperation
    SettingsTestOperation := 0
    if IsObject(operation)
        operation.Cancel()
}

SettingsSendTestResult(generation, ok, text) {
    global SettingsHost
    if !SettingsTestIsCurrent(generation)
        return
    script := "window.settingsTestResult(" . (ok ? "true" : "false") . "," . LLMJsonQuote(text) . ");"
    try PanelHostExecute(SettingsHost, script)
    catch as testResultError
        DebugLog("Settings test result delivery failed")
}

SettingsResize(targetGui, minMax, width, height) {
    global SettingsHost
    PanelHostResize(SettingsHost, minMax)
}

SettingsRequestClose(*) {
    global SettingsHost
    if !IsObject(SettingsHost) || !PanelHostPageReady(SettingsHost)
        return true
    PanelHostExecute(SettingsHost, "window.requestCloseSettings();")
    return true
}

SettingsIsDarkTheme() {
    try return RegRead(
        "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
        "AppsUseLightTheme",
        1
    ) = 0
    catch
        return false
}

SettingsHide(*) {
    global SettingsHost, SettingsVisible, WindowPickerVisible
    if WindowPickerVisible
        SettingsCloseWindowPicker(false)
    SettingsStopShortcutCapture()
    SettingsTestInvalidate()
    SettingsVisible := false
    PanelHostHide(SettingsHost)
}

SettingsShutdown(*) {
    global SettingsHost, SettingsVisible, SettingsPendingPage, WindowPickerVisible
    if WindowPickerVisible
        SettingsCloseWindowPicker(false)
    SettingsStopShortcutCapture()
    SettingsTestInvalidate()
    SettingsVisible := false
    SettingsPendingPage := "general"
    PanelHostDestroy(SettingsHost)
    SettingsHost := 0
}
