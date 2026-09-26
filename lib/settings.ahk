; Standalone settings window shell. The page is intentionally a placeholder for
; now; configuration data and save messages will be added in a later pass.

global SettingsGui := 0
global SettingsController := 0
global SettingsWebView := 0
global SettingsPageReady := false
global SettingsVisible := false

SettingsShow(*) {
    global SettingsGui, SettingsVisible
    SettingsVisible := true
    if !SettingsEnsureWebView() {
        SettingsVisible := false
        return
    }
    ; Keep the native window state (including maximize/minimize) between opens.
    SettingsGui.Show()
    WinActivate("ahk_id " . SettingsGui.Hwnd)
    ShowSystemCursor()
}

SettingsEnsureWebView() {
    global SettingsGui, SettingsController, SettingsWebView, SettingsPageReady
    if IsObject(SettingsGui) && IsObject(SettingsWebView)
        return true

    pagePath := A_ScriptDir . "\pages\settings.html"
    loaderPath := A_ScriptDir . "\WebView2\" . (A_PtrSize = 8 ? "64bit" : "32bit") . "\WebView2Loader.dll"
    if !FileExist(pagePath) {
        ShowMsg("pages\settings.html is missing.", 3500)
        return false
    }
    if !FileExist(loaderPath) {
        ShowMsg("WebView2Loader.dll is missing: " . loaderPath, 5000)
        return false
    }

    if !IsObject(SettingsGui) {
        SettingsGui := Gui(
            "+Resize +MinSize720x520 +MinimizeBox +MaximizeBox +SysMenu",
            "capslock_p2 设置"
        )
        SettingsGui.MarginX := 0
        SettingsGui.MarginY := 0
        SettingsGui.OnEvent("Close", SettingsHide)
        SettingsGui.OnEvent("Size", SettingsResize)
        SettingsGui.BackColor := SettingsIsDarkTheme() ? "20242B" : "F5F7FB"
        settingsSize := ScreenFitSize(820, 620, 720, 520)
        SettingsGui.Show("w" . settingsSize[1] . " h" . settingsSize[2] . " Center")
    }

    try {
        dataPath := A_Temp . "\CapsLockPlusSettingsWebView2"
        SettingsController := WebView2.CreateControllerAsync(
            SettingsGui.Hwnd, 0, dataPath, "", loaderPath
        ).await2(15000)
        SettingsController.Fill()
        SettingsWebView := SettingsController.CoreWebView2
        SettingsWebView.add_NavigationCompleted(SettingsNavigationCompleted)
        SettingsWebView.add_WebMessageReceived(SettingsWebMessageReceived)
        SettingsPageReady := false
        pageUrl := "file:///" . StrReplace(pagePath, "\", "/")
        SettingsWebView.Navigate(pageUrl)
        return true
    } catch as webViewError {
        DebugLog("settings webview failed: " . webViewError.Message)
        SettingsPageReady := false
        SettingsWebView := 0
        SettingsController := 0
        SettingsGui.Hide()
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

SettingsNavigationCompleted(sender, args) {
    global SettingsPageReady, SettingsVisible
    try success := args.IsSuccess
    catch
        success := false
    SettingsPageReady := success
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
    global SettingsWebView, SettingsPageReady
    if !SettingsPageReady || !IsObject(SettingsWebView)
        return
    sections := Map()
    for section in SettingsConfigSections()
        sections[section] := SettingsSectionSnapshot(section)
    payload := Map(
        "uiLanguage", LLMUiLanguage(),
        "sections", sections,
        "keys", SettingsKeySnapshot(),
        "bindings", SettingsBindingSnapshot())
    try SettingsWebView.ExecuteScriptAsync("window.receiveSnapshot(" . JSON.stringify(payload, 0) . ");")
    catch
        return
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
            return SettingsKeyIn(["systemPrompt"], key)
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
        SettingsSendSaved(true, LLMText("Settings saved.", "设置已保存。"))
        SettingsPushSnapshot()
    } catch as saveError {
        SettingsSendSaved(false, LLMText("Save failed: ", "保存失败：") . saveError.Message)
    }
}

SettingsSendSaved(ok, text) {
    global SettingsWebView, SettingsPageReady
    if !SettingsPageReady || !IsObject(SettingsWebView)
        return
    script := "window.settingsSaved(" . (ok ? "true" : "false") . "," . LLMJsonQuote(text) . ");"
    try SettingsWebView.ExecuteScriptAsync(script)
    catch
        return
}

SettingsRunTest(message) {
    msg := LLMMessageParse(message)
    target := StrLower(LLMMsgField(msg, "target"))
    ok := false
    resultText := ""
    try {
        if target = "translate" {
            engine := StrLower(Trim(LLMMsgField(msg, "engine")))
            if engine = "auto" {
                if Trim(LLMMsgField(msg, "endpoint")) != "" && LLMMsgField(msg, "apiKey") != ""
                    engine := "llm"
                else if LLMMsgField(msg, "appId") != "" && LLMMsgField(msg, "appKey") != ""
                    engine := "youdao"
                else
                    engine := "volcengine"
            }
            provider := TranslateGetProvider(engine)
            if !IsObject(provider)
                resultText := LLMText("Unknown translation engine.", "未知翻译引擎。")
            else if provider.Has("test")
                provider["test"].Call(msg, &ok, &resultText)
        } else if target = "ai" {
            overrides := LLMMessageOverrides(msg, [
                "endpoint", "apiKey", "apiKeyHeader", "apiKeyPrefix", "model",
                "temperature", "timeout", "thinking", "maxInputTokens"])
            answer := LLMAiChatComplete(
                [Map("role", "user", "content", "Hello! This is a capslock_p2 connection test.")],
                &ok, &resultText, overrides)
            if ok
                resultText := LLMText("Connection OK → ", "连接正常 → ") . SubStr(answer, 1, 120)
        }
    } catch as testError {
        ok := false
        resultText := testError.Message
    }
    SettingsSendTestResult(ok, resultText)
}

SettingsSendTestResult(ok, text) {
    global SettingsWebView, SettingsPageReady
    if !SettingsPageReady || !IsObject(SettingsWebView)
        return
    script := "window.settingsTestResult(" . (ok ? "true" : "false") . "," . LLMJsonQuote(text) . ");"
    try SettingsWebView.ExecuteScriptAsync(script)
    catch
        return
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
    SettingsShow()
    SetTimer(SettingsPushSnapshot, -1)
}

SettingsResize(targetGui, minMax, width, height) {
    global SettingsController
    if minMax != -1 && IsObject(SettingsController)
        try SettingsController.Fill()
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
    global SettingsGui, SettingsVisible
    SettingsVisible := false
    if IsObject(SettingsGui)
        SettingsGui.Hide()
}

SettingsShutdown(*) {
    global SettingsGui, SettingsController, SettingsWebView, SettingsPageReady, SettingsVisible
    SettingsVisible := false
    SettingsPageReady := false
    try SettingsWebView := 0
    try SettingsController := 0
    if IsObject(SettingsGui) {
        try SettingsGui.Destroy()
        SettingsGui := 0
    }
}
