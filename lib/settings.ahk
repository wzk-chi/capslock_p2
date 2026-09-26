; Standalone settings window shell. The page is intentionally a placeholder for
; now; configuration data and save messages will be added in a later pass.

global SettingsHost := 0
global SettingsGui := 0
global SettingsController := 0
global SettingsWebView := 0
global SettingsPageReady := false
global SettingsVisible := false
global SettingsPendingPage := "general"

SettingsShow(initialPage := "general", *) {
    global SettingsHost, SettingsGui, SettingsVisible, SettingsPendingPage
    allowedPages := Map("general", true, "llm", true, "translate", true, "ai", true,
        "shortcuts", true, "tab", true, "qbar", true, "windows", true)
    initialPage := StrLower(Trim(initialPage))
    SettingsPendingPage := allowedPages.Has(initialPage) ? initialPage : "general"
    SettingsVisible := true
    if !SettingsEnsureWebView() {
        SettingsVisible := false
        return
    }
    ; Keep the native window state (including maximize/minimize) between opens.
    PanelHostShow(SettingsHost, 0, 0, false)
    SettingsSyncHost()
    WinActivate("ahk_id " . SettingsGui.Hwnd)
    ShowSystemCursor()
    if SettingsPageReady
        SetTimer(SettingsPushSnapshot, -1)
}

SettingsEnsureWebView() {
    global SettingsHost, SettingsGui, SettingsController, SettingsWebView, SettingsPageReady
    pagePath := A_ScriptDir . "\pages\settings.html"
    if IsObject(SettingsHost) {
        try {
            PanelHostEnsure(SettingsHost)
            SettingsSyncHost()
            return true
        } catch as existingError {
            PanelHostHide(SettingsHost)
            DebugLog("settings webview failed: " . existingError.Message)
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
            "close", SettingsHide,
            "resize", SettingsResize,
            "navigation", SettingsNavigationCompleted,
            "message", SettingsWebMessageReceived,
            "backColor", SettingsIsDarkTheme() ? "20242B" : "F5F7FB")))
    SettingsSyncHost()

    try {
        PanelHostEnsure(SettingsHost)
        SettingsSyncHost()
        return true
    } catch as webViewError {
        DebugLog("settings webview failed: " . webViewError.Message)
        PanelHostHide(SettingsHost)
        SettingsSyncHost()
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

SettingsSyncHost() {
    global SettingsHost, SettingsGui, SettingsController, SettingsWebView, SettingsPageReady
    if !IsObject(SettingsHost) {
        SettingsGui := 0
        SettingsController := 0
        SettingsWebView := 0
        SettingsPageReady := false
        return
    }
    SettingsGui := SettingsHost["gui"]
    SettingsController := SettingsHost["controller"]
    SettingsWebView := SettingsHost["webView"]
    SettingsPageReady := SettingsHost["pageReady"]
}

SettingsNavigationCompleted(sender, args) {
    global SettingsHost, SettingsPageReady, SettingsVisible
    try success := args.IsSuccess
    catch
        success := false
    SettingsPageReady := success
    if IsObject(SettingsHost)
        SettingsHost["pageReady"] := success
    if !success
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
    else if messageType = "saveSettings"
        SetTimer(() => SettingsApplyDraft(message), -1)
    else if messageType = "testSettings"
        SetTimer(() => SettingsRunTest(message), -1)
    else if messageType = "captureWindow"
        SetTimer(() => SettingsCaptureWindow(message), -1)
}

SettingsConfigSections() {
    return ["Global", "LLM", "LLMTranslate", "TTranslate", "TVolcengine", "QAI",
        "TabHotString", "Keys", "QSearch", "QRun", "QWeb", "Qbar"]
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
    return section = "TabHotString" || section = "QSearch" || section = "QRun" || section = "QWeb"
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
        mode := WindowBindingDisplay(row["bindType"])
        row["modeLabel"] := mode["label"]
        row["modeDescription"] := mode["description"]
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
        "bindings", SettingsBindingSnapshot())
    PanelHostExecute(SettingsHost, "window.receiveSnapshot(" . JSON.stringify(payload, 0) . ");")
}

SettingsAllowedKey(section, key) {
    if RegExMatch(key, "[\[\]=`r`n]") || StrLen(key) > 120
        return false
    switch section {
        case "Global":
            return SettingsKeyIn(["autostart", "mouseSpeed", "allowClipboard", "debug",
                "loadingAnimation", "language"], key)
        case "LLM":
            return SettingsKeyIn(["endpoint", "apiKey", "apiKeyHeader", "apiKeyPrefix", "model", "thinking",
                "temperature", "timeout", "maxInputTokens"], key)
        case "LLMTranslate":
            return SettingsKeyIn(["targetLanguage", "engine", "systemPrompt"], key)
        case "TTranslate":
            return SettingsKeyIn(["appPaidID", "appPaidKey", "targetLanguage"], key)
        case "TVolcengine":
            return SettingsKeyIn(["accessKey", "secretKey", "targetLanguage", "region"], key)
        case "QAI":
            return SettingsKeyIn(["systemPrompt", "hideOnBlur"], key)
        case "Qbar":
            return SettingsKeyIn(["esPath", "everythingPath", "esInstance", "esMaxResults"], key)
        case "Keys":
            return RegExMatch(key, "i)^(press_caps|caps(_lalt|_win)?_[A-Za-z0-9_]+)$")
        default:
            return SettingsIsDynamicSection(section)
    }
}

SettingsKeyIn(values, target) {
    for value in values
        if value = target
            return true
    return false
}

SettingsWriteSection(section, values) {
    global SettingsFile
    if !IsObject(values)
        return
    for key, value in values {
        if IsObject(value) || !SettingsAllowedKey(section, String(key))
            continue
        ConfigWriteValue(SettingsFile, section, String(key), String(value))
    }
}

SettingsApplyDraft(message) {
    msg := LLMMessageParse(message)
    if !msg.Has("draft") || !IsObject(msg["draft"])
        return
    draft := msg["draft"]
    if !draft.Has("sections") || !IsObject(draft["sections"])
        return
    try {
        for section in SettingsConfigSections() {
            if draft["sections"].Has(section)
                SettingsWriteSection(section, draft["sections"][section])
        }
        ReloadSettings()
        AiChatOnSettingsSaved()
        LLMTranslateOnSettingsSaved()
        SettingsSendSaved(true, LLMText("Settings saved.", "设置已保存。"))
        SettingsPushSnapshot()
    } catch as saveError {
        SettingsSendSaved(false, LLMText("Save failed: ", "保存失败：") . saveError.Message)
    }
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
    numberText := LLMMsgField(msg, "number")
    if !RegExMatch(numberText, "^\d+$")
        return
    bindingNumber := Integer(numberText)
    if bindingNumber < 1 || bindingNumber > 10
        return
    bindType := WindowBindingType(LLMMsgField(msg, "bindType"))
    SettingsHide()
    SetTimer(() => SettingsCompleteCapture(bindingNumber, bindType), -180)
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
    SettingsVisible := false
    PanelHostHide(SettingsHost)
}

SettingsShutdown(*) {
    global SettingsHost, SettingsGui, SettingsController, SettingsWebView
    global SettingsPageReady, SettingsVisible, SettingsPendingPage
    SettingsVisible := false
    SettingsPendingPage := "general"
    PanelHostDestroy(SettingsHost)
    SettingsHost := 0
    SettingsGui := 0
    SettingsController := 0
    SettingsWebView := 0
    SettingsPageReady := false
}
