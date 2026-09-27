; Standalone settings window shell. The page is intentionally a placeholder for
; now; configuration data and save messages will be added in a later pass.

global SettingsHost := 0
global SettingsVisible := false
global SettingsPendingPage := "general"
global SettingsShortcutHook := 0
global SettingsShortcutTarget := ""

SettingsShow(initialPage := "general", *) {
    global SettingsHost, SettingsVisible, SettingsPendingPage
    initialPage := StrLower(Trim(initialPage))
    SettingsPendingPage := SettingsPageIsAllowed(initialPage) ? initialPage : "general"
    SettingsVisible := true
    if !SettingsEnsureWebView() {
        SettingsVisible := false
        return
    }
    ; Keep the native window state (including maximize/minimize) between opens.
    PanelHostShow(SettingsHost, 0, 0, false)
    panelGui := PanelHostGui(SettingsHost)
    if IsObject(panelGui)
        WinActivate("ahk_id " . panelGui.Hwnd)
    ShowSystemCursor()
    if PanelHostPageReady(SettingsHost)
        SetTimer(SettingsPushSnapshot, -1)
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
            DebugLog("settings webview failed")
            ShowMsg("WebView2 initialization failed: " . existingError.Message, 5000)
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
        DebugLog("settings webview failed")
        PanelHostHide(SettingsHost)
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

SettingsNavigationCompleted(host, sender, args) {
    global SettingsVisible
    if !PanelHostPageReady(host)
        ShowMsg("The settings page could not be loaded.", 3500)
    else if SettingsVisible
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
    else if messageType = "saveSettings"
        SetTimer(SettingsApplyDraft.Bind(message), -1)
    else if messageType = "testSettings"
        SetTimer(SettingsRunTest.Bind(message), -1)
    else if messageType = "startShortcutRecording"
        SetTimer(SettingsStartShortcutCapture.Bind(message), -1)
    else if messageType = "stopShortcutRecording"
        SettingsStopShortcutCapture()
    else if messageType = "captureWindow"
        SetTimer(SettingsCaptureWindow.Bind(message), -1)
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
        row := Map("number", bindingNumber, "bindType", 0, "items", [])
        if WinBindings.Has(bindingNumber) {
            binding := WinBindings[bindingNumber]
            row["bindType"] := WindowBindingType(binding.bindType, 0)
            items := []
            for item in binding.items
                items.Push(Map("id", String(item.id), "windowClass", item.windowClass,
                    "exe", item.exe, "path", item.path))
            row["items"] := items
        }
        result.Push(row)
    }
    return result
}

SettingsPushSnapshot(*) {
    global SettingsHost
    if !IsObject(SettingsHost)
        return
    sections := Map()
    for section in SettingsConfigSections()
        sections[section] := SettingsSectionSnapshot(section)
    payload := Map(
        "uiLanguage", LLMUiLanguage(),
        "page", SettingsPendingPage,
        "sections", sections,
        "keys", SettingsKeySnapshot(),
        "bindings", SettingsBindingSnapshot(),
        "bindingModes", WindowBindingModes())
    PanelHostExecute(SettingsHost, "window.receiveSnapshot(" . JSON.stringify(payload, 0) . ");")
}

SettingsAllowedKey(section, key) {
    return ConfigValidateKey(section, key)
}

SettingsKeyIn(values, target) {
    for value in values
        if value = target
            return true
    return false
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
    try {
        changes := Map()
        for section in SettingsConfigSections() {
            if sections.Has(section)
                SettingsCollectSectionChanges(changes, section, sections[section])
        }
        if msg.Has("base") && IsObject(msg["base"]) {
            conflict := SettingsFindDraftConflict(changes, msg["base"])
            if conflict != "" {
                SettingsSendSaved(false, LLMText(
                    "The setting changed outside the settings page: " . conflict,
                    "设置页外部已修改该字段：" . conflict))
                return
            }
        }
        fileChanged := false
        invalidChange := ""
        effectiveChanges := ConfigWriteUserOverrides(changes, &fileChanged, &invalidChange)
        if invalidChange != "" {
            SettingsSendSaved(false, LLMText(
                "Invalid setting value: " . invalidChange,
                "设置值无效：" . invalidChange))
            return
        }
        if effectiveChanges.Count {
            ReloadSettings(false)
        }
        SettingsSendSaved(true, LLMText("Settings saved.", "设置已保存。"))
        SettingsPushSnapshot()
    } catch as saveError {
        SettingsSendSaved(false, LLMText("Save failed.", "保存失败。"))
    }
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

SettingsSendSaved(ok, text) {
    global SettingsHost
    script := "window.settingsSaved(" . (ok ? "true" : "false") . "," . LLMJsonQuote(text) . ");"
    PanelHostExecute(SettingsHost, script)
}

SettingsRunTest(message) {
    msg := LLMMessageParse(message)
    target := StrLower(LLMMsgField(msg, "target"))
    if target != "llm" && target != "youdao" && target != "volcengine"
        return
    ok := false
    resultText := ""
    try {
        if target = "llm" {
            overrides := LLMMessageOverrides(msg, [
                "endpoint", "apiKey", "apiKeyHeader", "apiKeyPrefix", "model",
                "temperature", "timeout", "thinking", "maxInputTokens"])
            responseText := LLMChatComplete(
                [Map("role", "user", "content", "Hello! This is a capslock_p2 connection test.")],
                &ok, &resultText, overrides)
            if ok {
                resultText := LLMText("Connection OK", "连接正常")
            }
        } else {
            provider := TranslateGetProvider(target)
            if !IsObject(provider) || !provider.Has("test") {
                resultText := LLMText("Translation test is unavailable.", "翻译测试不可用。")
            } else {
                provider["test"].Call(msg, &ok, &resultText)
            }
        }
        if ok
            resultText := LLMText("Connection OK", "连接正常")
    } catch as testError {
        ok := false
        resultText := testError.Message
    }
    SettingsSendTestResult(ok, resultText)
}

SettingsSendTestResult(ok, text) {
    global SettingsHost
    script := "window.settingsTestResult(" . (ok ? "true" : "false") . "," . LLMJsonQuote(text) . ");"
    PanelHostExecute(SettingsHost, script)
}

SettingsCaptureWindow(message) {
    msg := LLMMessageParse(message)
    numberValid := false
    bindingNumber := LLMMsgNumber(msg, "number", &numberValid, 0, true)
    if !numberValid || bindingNumber < 1 || bindingNumber > 10
        return
    bindTypeValid := false
    bindType := WindowBindingType(LLMMsgNumber(msg, "bindType", &bindTypeValid, 0, true))
    if !bindTypeValid || bindType < 1 || bindType > 3
        return
    SettingsHide()
    SetTimer(SettingsCompleteCapture.Bind(bindingNumber, bindType), -180)
}

SettingsCompleteCapture(bindingNumber, bindType) {
    bindType := WindowBindingType(bindType)
    BindWindowFromActive(bindingNumber, bindType)
    SettingsShow("windows")
    SetTimer(SettingsPushSnapshot, -1)
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
    global SettingsHost, SettingsVisible
    SettingsStopShortcutCapture()
    SettingsVisible := false
    PanelHostHide(SettingsHost)
}

SettingsShutdown(*) {
    global SettingsHost, SettingsVisible, SettingsPendingPage
    SettingsStopShortcutCapture()
    SettingsVisible := false
    SettingsPendingPage := "general"
    PanelHostDestroy(SettingsHost)
    SettingsHost := 0
}
