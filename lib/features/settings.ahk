; Standalone settings window shell. The page is intentionally a placeholder for
; now; configuration data and save messages will be added in a later pass.

global SettingsHost := 0
global SettingsVisible := false
global SettingsPendingPage := "general"
global SettingsPendingToast := ""
global SettingsShortcutHook := 0
global SettingsShortcutTarget := ""
global SettingsTestGeneration := 0
global SettingsTestOperation := 0
global WindowPickerVisible := false
global WindowPickerKind := ""
global WindowPickerRows := []
global WindowPickerBindingNumber := 0
global WindowPickerBindType := 1

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
        SetTimer(SettingsStartShortcutCapture.Bind(message), -1)
    else if messageType = "stopShortcutRecording"
        SettingsStopShortcutCapture()
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
    global QbarPluginHostError
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
    errorText := QbarPluginHostError != "" ? QbarPluginHostError : "删除工具失败。"
    SettingsSendQbarPluginDeleted(false, errorText, pluginId)
}

SettingsStartShortcutCapture(message) {
    global SettingsShortcutHook, SettingsShortcutTarget
    msg := LLMMessageParse(message)
    target := LLMMsgField(msg, "key")
    SettingsStopShortcutCapture()
    if target = ""
        return
    hook := InputHook("L0")
    hook.KeyOpt("{All}", "+NS")
    hook.OnKeyDown := SettingsShortcutKeyDown
    SettingsShortcutTarget := target
    SettingsShortcutHook := hook
    hook.Start()
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

SettingsStopShortcutCapture(*) {
    global SettingsShortcutHook, SettingsShortcutTarget
    hook := SettingsShortcutHook
    SettingsShortcutHook := 0
    SettingsShortcutTarget := ""
    if IsObject(hook)
        try hook.Stop()
}

SettingsShortcutKeyDown(hook, vk, sc) {
    global SettingsShortcutHook, SettingsShortcutTarget
    if SettingsShortcutIsModifier(vk)
        return
    key := SettingsShortcutKeyInfo(vk, sc)
    if !IsObject(key)
        return
    modifiers := SettingsShortcutModifierInfo()
    target := SettingsShortcutTarget
    value := modifiers["value"] . key["value"]
    label := modifiers["label"]
    if label != ""
        label .= "+"
    label .= key["label"]
    SettingsShortcutHook := 0
    SettingsShortcutTarget := ""
    try hook.Stop()
    SetTimer(SettingsSendShortcutCapture.Bind(target, value, label), -1)
}

SettingsShortcutIsModifier(vk) {
    return vk = 0x10 || vk = 0xA0 || vk = 0xA1
        || vk = 0x11 || vk = 0xA2 || vk = 0xA3
        || vk = 0x12 || vk = 0xA4 || vk = 0xA5
        || vk = 0x5B || vk = 0x5C
}

SettingsShortcutModifierInfo() {
    ctrl := GetKeyState("Ctrl", "P")
    alt := GetKeyState("Alt", "P")
    shift := GetKeyState("Shift", "P")
    win := GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
    value := (ctrl ? "^" : "") . (alt ? "!" : "") . (shift ? "+" : "") . (win ? "#" : "")
    label := (ctrl ? "Ctrl" : "")
    if alt
        label .= (label = "" ? "" : "+") . "Alt"
    if shift
        label .= (label = "" ? "" : "+") . "Shift"
    if win
        label .= (label = "" ? "" : "+") . "Win"
    return Map("value", value, "label", label)
}

SettingsShortcutKeyInfo(vk, sc) {
    keyName := ""
    try keyName := GetKeyName(Format("sc{:03X}", sc))
    if keyName = ""
        try keyName := GetKeyName(Format("vk{:02X}", vk))
    if keyName = ""
        return 0
    normalized := StrLower(keyName)
    if normalized = "space"
        return Map("value", "{Space}", "label", "Space")
    if normalized = "enter" || normalized = "numpadenter"
        return Map("value", normalized = "enter" ? "{Enter}" : "{NumpadEnter}",
            "label", normalized = "enter" ? "Enter" : "Num Enter")
    if normalized = "tab"
        return Map("value", "{Tab}", "label", "Tab")
    if normalized = "escape" || normalized = "esc"
        return Map("value", "{Esc}", "label", "Esc")
    if normalized = "backspace"
        return Map("value", "{Backspace}", "label", "Backspace")
    if normalized = "delete" || normalized = "del"
        return Map("value", "{Delete}", "label", "Delete")
    if normalized = "insert" || normalized = "ins"
        return Map("value", "{Insert}", "label", "Insert")
    if normalized = "home"
        return Map("value", "{Home}", "label", "Home")
    if normalized = "end"
        return Map("value", "{End}", "label", "End")
    if normalized = "pageup" || normalized = "pgup"
        return Map("value", "{PgUp}", "label", "PageUp")
    if normalized = "pagedown" || normalized = "pgdn"
        return Map("value", "{PgDn}", "label", "PageDown")
    if normalized = "up" || normalized = "down" || normalized = "left" || normalized = "right"
        return Map("value", "{" . keyName . "}", "label", keyName)
    if normalized = "capslock"
        return Map("value", "{CapsLock}", "label", "CapsLock")
    if normalized = "printscreen"
        return Map("value", "{PrintScreen}", "label", "PrintScreen")
    if normalized = "scrolllock"
        return Map("value", "{ScrollLock}", "label", "ScrollLock")
    if normalized = "pause"
        return Map("value", "{Pause}", "label", "Pause")
    if normalized = "appskey" || normalized = "contextmenu"
        return Map("value", "{AppsKey}", "label", "ContextMenu")
    if RegExMatch(keyName, "i)^F(?:[1-9]|1[0-9]|2[0-4])$")
        return Map("value", "{" . keyName . "}", "label", keyName)
    if RegExMatch(keyName, "i)^Numpad")
        return Map("value", "{" . keyName . "}", "label", "Num " . SubStr(keyName, 7))
    if StrLen(keyName) = 1 {
        if RegExMatch(keyName, "^[A-Za-z0-9]$")
            return Map("value", StrLower(keyName), "label", StrUpper(keyName))
        return Map("value", "{" . keyName . "}", "label", keyName)
    }
    return Map("value", "{" . keyName . "}", "label", keyName)
}

SettingsSendShortcutCapture(target, value, label) {
    global SettingsHost
    if !IsObject(SettingsHost) || target = ""
        return
    payload := Map("key", target, "value", value, "label", label)
    PanelHostExecute(SettingsHost, "window.receiveShortcutCapture(" . JSON.stringify(payload, 0) . ");")
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

SettingsSelectHotkeyApplication(*) {
    global SettingsHost
    applicationPath := ""
    try applicationPath := FileSelect(1, "", "选择应用程序", "应用程序 (*.exe)")
    catch as pickerError {
        SettingsSendHotkeyApplicationSelected(0)
        DebugLog("Settings application picker failed errorType=" . Type(pickerError))
        ShowMsg(LLMText(
            "Unable to open the application picker. Reopen Settings and try again.",
            "无法打开应用选择器。请重新打开设置后重试。"), 3000)
        return
    }
    if applicationPath = ""
        return
    profile := AppProfileDraftFromPath(applicationPath)
    if !IsObject(profile)
        return
    SettingsSendHotkeyApplicationSelected(profile)
}

SettingsSendHotkeyApplicationSelected(profile) {
    global SettingsHost
    if !IsObject(SettingsHost) || !IsObject(profile)
        return
    DebugLog("Hotkey application profile returned id=" . String(profile["id"]))
    PanelHostExecute(SettingsHost,
        "window.hotkeyApplicationSelected(" . JSON.stringify(profile, 0) . ");")
}

SettingsSelectHotkeyApplicationPath(path) {
    global WindowPickerKind, WindowPickerVisible
    DebugLog("Hotkey application selection received pathLength=" . StrLen(String(path))
        . " visible=" . WindowPickerVisible . " kind=" . WindowPickerKind)
    if !WindowPickerVisible || WindowPickerKind != "hotkeyApplication" {
        DebugLog("Hotkey application selection ignored: picker state mismatch")
        return
    }
    path := Trim(String(path))
    if path = "" {
        DebugLog("Hotkey application selection ignored: empty path")
        return
    }
    profile := AppProfileDraftFromPath(path)
    if !IsObject(profile) {
        DebugLog("Hotkey application profile creation failed")
        return
    }
    DebugLog("Hotkey application profile created id=" . profile["id"])
    SettingsCloseWindowPicker(false)
    SettingsSendHotkeyApplicationSelected(profile)
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
        sectionsSubmitted := SettingsHasChanges(changes)
        savePhase := "check external settings changes"
        if msg.Has("base") && IsObject(msg["base"]) {
            conflict := SettingsFindDraftConflict(changes, msg["base"])
            if conflict != "" {
                SettingsSendSaved(false, LLMText(
                    "The setting changed outside the settings page: " . conflict,
                    "设置页外部已修改该字段：" . conflict))
                return
            }
        }
        savePhase := "validate translation settings"
        if !SettingsValidateTranslationChanges(changes, &translationError) {
            SettingsSendSaved(false, translationError)
            return
        }

        savePhase := "read application profile changes"
        profilesDirty := msg.Has("profilesDirty") && AppProfileBoolean(msg["profilesDirty"], false)
        profiles := msg.Has("profiles") && Type(msg["profiles"]) = "Array" ? msg["profiles"] : []
        DebugLog("Settings save request sections=" . changes.Count
            . " profilesDirty=" . profilesDirty . " profileCount=" . profiles.Length)
        if profilesDirty {
            savePhase := "load application profiles"
            ; Compare a candidate without publishing it. This catches profile
            ; edits within the same timestamp second and keeps the live state
            ; intact if the following complete reload cannot read the file.
            profilesChanged := false
            if !AppProfilesLoad(&profilesChanged, false) {
                SettingsSendSaved(false, "无法读取应用配置文件，请检查后重试。")
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
                        "外部配置已变化，但当前配置文件无法完整读取。请检查文件后重试。")
                    return
                }
                SettingsSendSaved(false, "应用配置在设置页外发生了变化，请取消后重新载入。")
                return
            }
            savePhase := "validate application profiles"
            if !AppProfilesValidateDraft(profiles, &profileError) {
                SettingsSendSaved(false, profileError)
                return
            }
        }
        if msg.Has("plugins") {
            pluginsSubmitted := true
            savePhase := "validate plugin changes"
            if !QbarPluginHostPreparePluginChanges(msg["plugins"],
                &preparedPlugins, &pluginValidationError) {
                SettingsSendSaved(false, LLMText(
                    "Plugin settings are invalid.", pluginValidationError))
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
        if invalidChange != "" {
            SettingsSendSaved(false, LLMText(
                "Invalid setting value: " . invalidChange,
                "设置值无效：" . invalidChange))
            return
        }
        if profilesDirty {
            savePhase := "prepare application profiles"
            if !AppProfilePrepareDraftContent(profiles, candidateContent,
                &candidateContent, &profileError) {
                SettingsSendSaved(false, profileError)
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
                SettingsSendSaved(false, errorText, receipt)
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
                    "应用配置已保存，但工具设置未保存。请重试保存工具设置。", receipt)
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
        SettingsSendSaved(true, text, receipt)
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
            SettingsSendSaved(false, text, receipt)
        } else if configCommitted && pluginsSubmitted && !pluginsCommitted {
            receipt := SettingsBuildSaveReceipt(sectionsSubmitted,
                profilesDirty, false, settingsFileWritten, runtimeApplied)
            SettingsSendSaved(false,
                "应用配置已保存，但工具设置未保存。请重试保存工具设置。", receipt)
        } else if (configCommitted || pluginsCommitted) {
            receipt := SettingsBuildSaveReceipt(sectionsSubmitted && runtimeApplied,
                profilesDirty && runtimeApplied, pluginsCommitted,
                settingsFileWritten, runtimeApplied)
            SettingsSendSaved(true,
                "设置已保存，但页面状态未能立即刷新。请重新打开设置页。", receipt)
        } else {
            SettingsSendSaved(false, LLMText("Save failed.", "保存失败。"))
        }
    }
}

SettingsHasChanges(changes) {
    if Type(changes) != "Map"
        return false
    for section, values in changes
        if Type(values) = "Map" && values.Count
            return true
    return false
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

SettingsSendSaved(ok, text, receipt := 0) {
    global SettingsHost
    receiptJson := IsObject(receipt) ? JSON.stringify(receipt, 0) : "null"
    script := "window.settingsSaved(" . (ok ? "true" : "false") . ","
        . LLMJsonQuote(text) . "," . receiptJson . ");"
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

SettingsOpenWindowPicker(message) {
    msg := LLMMessageParse(message)
    numberValid := false
    bindingNumber := LLMMsgNumber(msg, "number", &numberValid, 0, true)
    if !numberValid || bindingNumber < 1 || bindingNumber > 10
        return
    bindTypeValid := false
    bindType := WindowBindingType(LLMMsgNumber(msg, "bindType", &bindTypeValid, 0, true), 0)
    if !bindTypeValid || bindType < 1 || bindType > 2
        return
    try SettingsShowWindowPicker(bindingNumber, bindType)
    catch as pickerError {
        SettingsShow("windows")
        DebugLog("Settings window picker failed errorType=" . Type(pickerError))
        ShowMsg(LLMText(
            "Unable to open the window picker. Reopen Settings and try again.",
            "无法打开窗口选择器。请重新打开设置后重试。"), 3000)
    }
}

SettingsOpenOpenApplicationPicker(message) {
    msg := LLMMessageParse(message)
    numberValid := false
    bindingNumber := LLMMsgNumber(msg, "number", &numberValid, 0, true)
    if !numberValid || bindingNumber < 1 || bindingNumber > 10
        return
    bindTypeValid := false
    bindType := WindowBindingType(LLMMsgNumber(msg, "bindType", &bindTypeValid, 0, true), 0)
    if !bindTypeValid || bindType != 3
        return
    try SettingsShowApplicationPicker(bindingNumber)
    catch as pickerError {
        SettingsShow("windows")
        DebugLog("Settings application picker failed errorType=" . Type(pickerError))
        ShowMsg(LLMText(
            "Unable to open the application picker. Reopen Settings and try again.",
            "无法打开应用选择器。请重新打开设置后重试。"), 3000)
    }
}

SettingsOpenOtherApplicationPicker(message) {
    msg := LLMMessageParse(message)
    numberValid := false
    bindingNumber := LLMMsgNumber(msg, "number", &numberValid, 0, true)
    if !numberValid || bindingNumber < 1 || bindingNumber > 10
        return
    bindTypeValid := false
    bindType := WindowBindingType(LLMMsgNumber(msg, "bindType", &bindTypeValid, 0, true), 0)
    if !bindTypeValid || bindType != 3
        return
    applicationPath := ""
    try applicationPath := FileSelect(1, "", "选择其他应用", "应用程序 (*.exe)")
    catch as pickerError {
        SettingsShow("windows")
        DebugLog("Settings application picker failed errorType=" . Type(pickerError))
        ShowMsg(LLMText(
            "Unable to open the application picker. Reopen Settings and try again.",
            "无法打开应用选择器。请重新打开设置后重试。"), 3000)
        return
    }
    if applicationPath = "" {
        SettingsShow("windows")
        return
    }
    BindWindowToApplication(bindingNumber, applicationPath)
    SettingsShow("windows")
    SetTimer(SettingsPushSnapshot, -1)
}

SettingsShowWindowPicker(bindingNumber, bindType) {
    global SettingsHost, WindowPickerVisible, WindowPickerKind
    global WindowPickerRows, WindowPickerBindingNumber, WindowPickerBindType
    if WindowPickerVisible
        SettingsCloseWindowPicker(false)

    settingsGui := PanelHostGui(SettingsHost)
    excludeHwnd := IsObject(settingsGui) ? settingsGui.Hwnd : 0
    rows := WindowBindingOpenWindows(excludeHwnd)
    if !rows.Length {
        SettingsShow("windows")
        ShowMsg("没有找到当前用户已打开的窗口。", 2500)
        return
    }
    WindowPickerKind := "window"
    WindowPickerRows := rows
    WindowPickerBindingNumber := bindingNumber
    WindowPickerBindType := bindType
    WindowPickerVisible := true
    SettingsPushWindowPicker()
}

SettingsShowApplicationPicker(bindingNumber) {
    SettingsOpenApplicationPicker("application", bindingNumber)
}

SettingsShowHotkeyApplicationPicker(*) {
    DebugLog("Hotkey application picker opening")
    SettingsOpenApplicationPicker("hotkeyApplication")
}

SettingsOpenApplicationPicker(kind, bindingNumber := 0) {
    global SettingsHost, WindowPickerVisible, WindowPickerKind
    global WindowPickerRows, WindowPickerBindingNumber
    if WindowPickerVisible
        SettingsCloseWindowPicker(false)

    settingsGui := PanelHostGui(SettingsHost)
    excludeHwnd := IsObject(settingsGui) ? settingsGui.Hwnd : 0
    rows := WindowBindingOpenApplications(excludeHwnd)
    if !rows.Length {
        DebugLog("Application picker found no open applications kind=" . kind)
        if kind != "hotkeyApplication"
            SettingsShow("windows")
        ShowMsg("没有找到当前用户已打开的应用。", 2500)
        return
    }
    DebugLog("Application picker results kind=" . kind . " count=" . rows.Length)
    WindowPickerKind := kind
    WindowPickerRows := rows
    WindowPickerBindingNumber := bindingNumber
    WindowPickerVisible := true
    SettingsPushWindowPicker()
}

SettingsPushWindowPicker(*) {
    global SettingsHost, WindowPickerVisible, WindowPickerKind, WindowPickerRows
    if !WindowPickerVisible || !IsObject(SettingsHost) || !PanelHostPageReady(SettingsHost)
        return

    isApplication := WindowPickerKind = "application" || WindowPickerKind = "hotkeyApplication"
    isHotkeyApplication := WindowPickerKind = "hotkeyApplication"
    rows := []
    for item in WindowPickerRows {
        if isApplication
            rows.Push(Map("name", item.exe, "count", item.items.Length, "path", item.path))
        else
            rows.Push(Map("title", item.title, "exe", item.exe, "class", item.windowClass))
    }
    payload := Map(
        "kind", WindowPickerKind,
        "title", isApplication ? "选择已打开应用" : "选择已打开窗口",
        "description", isHotkeyApplication ? "选择应用以添加快捷键配置。"
            : isApplication ? "选择应用并绑定它的全部窗口。" : "选择要绑定的窗口。",
        "rows", rows)
    DebugLog("Window picker pushed kind=" . WindowPickerKind . " count=" . rows.Length)
    PanelHostExecute(SettingsHost, "window.receiveWindowPicker(" . JSON.stringify(payload, 0) . ");")
}

SettingsWindowPickerSelect(index) {
    global WindowPickerKind, WindowPickerRows, WindowPickerBindingNumber, WindowPickerBindType
    bindingNumber := WindowPickerBindingNumber
    if WindowPickerKind = "application" {
        application := WindowPickerRows[index]
        SettingsCloseWindowPicker(false)
        BindWindowToApplication(bindingNumber, application.path)
    } else {
        item := WindowPickerRows[index]
        bindType := WindowPickerBindType
        SettingsCloseWindowPicker(false)
        BindWindowItemSelection(bindingNumber, item, bindType)
    }
    SettingsShow("windows")
    SetTimer(SettingsPushSnapshot, -1)
}

SettingsWindowPickerCancel(*) {
    global SettingsHost, WindowPickerKind
    reopenHotkeyApplications := WindowPickerKind = "hotkeyApplication"
    DebugLog("Window picker cancelled kind=" . WindowPickerKind)
    if reopenHotkeyApplications {
        SettingsCloseWindowPicker(false)
        if IsObject(SettingsHost) && PanelHostPageReady(SettingsHost)
            PanelHostExecute(SettingsHost, "window.openHotkeyApplicationDialog();")
        return
    }
    SettingsCloseWindowPicker(true)
}

SettingsCloseWindowPicker(restoreSettings := true) {
    global SettingsHost, WindowPickerVisible, WindowPickerKind
    global WindowPickerRows, WindowPickerBindingNumber, WindowPickerBindType
    WindowPickerVisible := false
    WindowPickerKind := ""
    WindowPickerRows := []
    WindowPickerBindingNumber := 0
    WindowPickerBindType := 1
    if IsObject(SettingsHost) && PanelHostPageReady(SettingsHost)
        PanelHostExecute(SettingsHost, "window.closeWindowPicker();")
    if restoreSettings
        SettingsShow("windows")
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
