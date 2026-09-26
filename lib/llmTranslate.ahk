; LLM translation UI and translation-provider orchestration.
; The UI is hosted by WebView2; API settings are read only from the active
; capslock_p2.ini file, never from the demo/reference INI.

global LLMTranslateGui := 0
global LLMTranslateController := 0
global LLMTranslateWebView := 0
global LLMTranslatePageReady := false
global LLMTranslateVisible := false
global LLMTranslatePendingText := ""
global LLMTranslateRequestRunning := false
global LLMTranslateStreamId := 0
global LLMTranslateStreamAnswer := ""
global LLMTranslateFocusTimer := false
global LLMTranslateTestMessage := ""
global LLMTranslateSettingsOpen := false

; Connection settings live in [LLM]. Translation behavior remains in
; [LLMTranslate], including targetLanguage and systemPrompt.
GetTranslateSetting(key, defaultValue := "") {
    global Config
    if Config.Has("LLMTranslate") && Config["LLMTranslate"].Has(key)
        return Config["LLMTranslate"][key]
    return defaultValue
}

TranslateSettingWith(key, defaultValue, overrides) {
    if IsObject(overrides) && overrides.Has(key)
        return overrides[key]
    return GetTranslateSetting(key, defaultValue)
}

TranslateTargetLanguageName(value) {
    value := Trim(value)
    if value = "" || StrLower(value) = "system"
        return SystemLanguageName()

    static languageNames := Map(
        "zh-cn", "Simplified Chinese", "zh-hans", "Simplified Chinese", "简体中文", "Simplified Chinese",
        "zh-tw", "Traditional Chinese", "zh-hant", "Traditional Chinese", "繁體中文", "Traditional Chinese",
        "en", "English", "english", "English", "ja", "Japanese", "japanese", "Japanese", "日本語", "Japanese",
        "ko", "Korean", "korean", "Korean", "한국어", "Korean", "fr", "French", "french", "French", "français", "French",
        "de", "German", "german", "German", "deutsch", "German", "es", "Spanish", "spanish", "Spanish", "español", "Spanish",
        "ru", "Russian", "russian", "Russian", "русский", "Russian", "it", "Italian", "italian", "Italian", "italiano", "Italian",
        "pt", "Portuguese", "portuguese", "Portuguese", "português", "Portuguese", "ar", "Arabic", "arabic", "Arabic", "العربية", "Arabic",
        "simplified chinese", "Simplified Chinese", "traditional chinese", "Traditional Chinese")
    normalized := StrLower(value)
    return languageNames.Has(normalized) ? languageNames[normalized] : value
}

; True when the engine named in [LLMTranslate] can serve a request. Engines
; are resolved through the registry in lib\translate.ahk; "auto" prefers the
; LLM provider and falls back to any other configured one.
TranslateConfigured() {
    provider := TranslateResolve(GetTranslateProvider())
    return IsObject(provider) && provider["configured"].Call()
}

; The normalized engine setting: a registered provider key, else "auto".
GetTranslateProvider() {
    engine := StrLower(Trim(GetTranslateSetting("engine", "auto")))
    if TranslateProviderExists(engine)
        return engine
    return "auto"
}

LLMTranslateShow(text, allowEmpty := false) {
    global LLMTranslateGui, LLMTranslatePendingText, LLMTranslateVisible, LLMTranslatePageReady, LLMTranslateFocusTimer
    text := Trim(text)
    if text = "" && !allowEmpty
        return

    LLMTranslatePendingText := text
    LLMTranslateVisible := true
    if !LLMTranslateEnsureWebView() {
        LLMTranslateVisible := false
        return
    }
    translateSize := ScreenFitSize(720, 500, 520, 360)
    LLMTranslateGui.Show("w" . translateSize[1] . " h" . translateSize[2] . " Center")
    WinActivate("ahk_id " . LLMTranslateGui.Hwnd)
    ShowSystemCursor()
    SetTimer(LLMTranslateFocusMonitor, 100)
    LLMTranslateFocusTimer := true

    if LLMTranslatePageReady {
        LLMTranslatePushSettings()
        configured := TranslateConfigured()
        LLMTranslateSetSource(text, text != "" && configured)
        if !configured
            LLMTranslateOpenSettings(true)
    }
}

LLMTranslateEnsureWebView() {
    global LLMTranslateGui, LLMTranslateController, LLMTranslateWebView
    global LLMTranslatePageReady
    if IsObject(LLMTranslateGui) && IsObject(LLMTranslateWebView)
        return true

    pagePath := A_ScriptDir . "\pages\translate.html"
    loaderPath := A_ScriptDir . "\WebView2\" . (A_PtrSize = 8 ? "64bit" : "32bit") . "\WebView2Loader.dll"
    if !FileExist(pagePath) {
        ShowMsg("pages\translate.html is missing.", 3500)
        return false
    }
    if !FileExist(loaderPath) {
        ShowMsg("WebView2Loader.dll is missing: " . loaderPath, 5000)
        return false
    }

    if !IsObject(LLMTranslateGui) {
        LLMTranslateGui := Gui("+AlwaysOnTop +Resize +MinSize520x360 +ToolWindow", "capslock_p2 Translate")
        LLMTranslateGui.MarginX := 0
        LLMTranslateGui.MarginY := 0
        LLMTranslateGui.OnEvent("Close", LLMTranslateHide)
        LLMTranslateGui.OnEvent("Escape", LLMTranslateHide)
        LLMTranslateGui.OnEvent("Size", LLMTranslateResize)
        translateSize := ScreenFitSize(720, 500, 520, 360)
    LLMTranslateGui.Show("w" . translateSize[1] . " h" . translateSize[2] . " Center")
    }

    try {
        dataPath := A_Temp . "\CapsLockPlusWebView2"
        startTick := A_TickCount
        DebugLog("translate webview creating")
        LLMTranslateController := WebView2.CreateControllerAsync(
            LLMTranslateGui.Hwnd, 0, dataPath, "", loaderPath
        ).await2(15000)
        DebugLog("translate webview ready in " . (A_TickCount - startTick) . " ms")
        LLMTranslateController.Fill()
        LLMTranslateWebView := LLMTranslateController.CoreWebView2
        LLMTranslateWebView.add_NavigationCompleted(LLMTranslateNavigationCompleted)
        LLMTranslateWebView.add_WebMessageReceived(LLMTranslateWebMessageReceived)
        LLMTranslatePageReady := false
        pageUrl := "file:///" . StrReplace(pagePath, "\", "/")
        LLMTranslateWebView.Navigate(pageUrl)
        return true
    } catch as webViewError {
        DebugLog("translate webview failed: " . webViewError.Message)
        LLMTranslatePageReady := false
        LLMTranslateWebView := 0
        LLMTranslateController := 0
        LLMTranslateGui.Hide()
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

LLMTranslateNavigationCompleted(sender, args) {
    global LLMTranslatePageReady, LLMTranslatePendingText, LLMTranslateVisible
    try success := args.IsSuccess
    catch
        success := false
    LLMTranslatePageReady := success
    if !success {
        LLMTranslateSetError("WebView2 could not load the translation panel.")
        return
    }
    if LLMTranslateVisible {
        LLMTranslatePushSettings()
        configured := TranslateConfigured()
        LLMTranslateSetSource(LLMTranslatePendingText, LLMTranslatePendingText != "" && configured)
        if !configured
            LLMTranslateOpenSettings(true)
    }
}

LLMTranslateWebMessageReceived(sender, args) {
    global LLMTranslatePendingText, LLMTranslateTestMessage, LLMTranslateSettingsOpen
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    messageType := LLMMsgField(msg, "type")
    if messageType = "translate" {
        text := LLMMsgField(msg, "text")
        if text = ""
            return
        LLMTranslatePendingText := text
        LLMTranslateSetLoading()
        SetTimer(LLMTranslateStartRequest, -1)
    } else if messageType = "openDictionary" {
        text := LLMMsgField(msg, "text")
        SetTimer(() => LLMTranslateOpenDictionary(text), -1)
    } else if messageType = "openSettings" {
        SetTimer(SettingsShow, -1)
    } else if messageType = "hide" {
        LLMTranslateHide()
    } else if messageType = "getSettings" {
        LLMTranslatePushSettings()
    } else if messageType = "saveSettings" {
        LLMTranslateSaveSettings(message)
    } else if messageType = "testSettings" {
        LLMTranslateTestMessage := message
        SetTimer(LLMTranslateRunTest, -1)
    } else if messageType = "cursorMove" {
        ; WebView2 does not always replay the native cursor after Windows'
        ; mouse-vanish-on-typing behavior. Restore it on an actual page mouse
        ; move, matching the behavior of native edit controls.
        ShowSystemCursor()
    } else if messageType = "settings" {
        ; The page tells us which view is shown: while the settings view is
        ; open the window must survive losing focus.
        LLMTranslateSettingsOpen := LLMMsgField(msg, "text") = "open"
    }
}

LLMTranslateOpenDictionary(text) {
    LLMTranslateHide()
    DictionaryShowQuery(text)
}

LLMTranslateSetSource(text, startRequest := false) {
    global LLMTranslateWebView, LLMTranslatePageReady
    if !LLMTranslatePageReady || !IsObject(LLMTranslateWebView)
        return
    script := "window.setSource(" . LLMJsonQuote(text) . ");"
    if startRequest
        script .= "window.startTranslate();"
    try LLMTranslateWebView.ExecuteScriptAsync(script)
    catch
        return
}

LLMTranslateSetLoading() {
    global LLMTranslateWebView, LLMTranslatePageReady
    if !LLMTranslatePageReady || !IsObject(LLMTranslateWebView)
        return
    try LLMTranslateWebView.ExecuteScriptAsync("window.setLoading(true);")
    catch
        return
}

LLMTranslateSetResult(text) {
    global LLMTranslateWebView, LLMTranslatePageReady
    if !LLMTranslatePageReady || !IsObject(LLMTranslateWebView)
        return
    try LLMTranslateWebView.ExecuteScriptAsync(
        "window.setResult(" . LLMJsonQuote(text) . ");window.setLoading(false);"
    )
    catch
        return
}

LLMTranslateSetError(text) {
    global LLMTranslateWebView, LLMTranslatePageReady
    if !LLMTranslatePageReady || !IsObject(LLMTranslateWebView)
        return
    try LLMTranslateWebView.ExecuteScriptAsync(
        "window.setError(" . LLMJsonQuote(text) . ");window.setLoading(false);"
    )
    catch
        return
}

LLMTranslatePushSettings() {
    global LLMTranslateWebView, LLMTranslatePageReady
    if !LLMTranslatePageReady || !IsObject(LLMTranslateWebView)
        return
    payload := Map(
        "engine", GetTranslateProvider(),
        "uiLanguage", LLMUiLanguage(),
        "configured", TranslateConfigured() ? JSON.true : JSON.false)
    ; Each provider contributes its own settings-form fields.
    for key, provider in TranslateProviders()
        if provider.Has("push")
            for fieldKey, fieldValue in provider["push"].Call()
                payload[fieldKey] := fieldValue
    try LLMTranslateWebView.ExecuteScriptAsync("window.setSettings(" . JSON.stringify(payload, 0) . ");")
    catch
        return
}

LLMTranslateOpenSettings(firstRun) {
    global LLMTranslateWebView, LLMTranslatePageReady, LLMTranslateSettingsOpen
    if !LLMTranslatePageReady || !IsObject(LLMTranslateWebView)
        return
    LLMTranslateSettingsOpen := true
    try LLMTranslateWebView.ExecuteScriptAsync("window.openSettings(" . (firstRun ? "true" : "false") . ");")
    catch
        return
}

; The WebView2 pages post their payloads as JSON.stringify'd text, so a full
; parse is always safe; a malformed message just yields no fields.


; Read one field of a parsed message; "" when absent or non-scalar.


; Parse an LLM API response body; 0 when it is not a JSON object.


; The named content field of a chat-completions response, read from
; choices[].message (then the choice, then the top level, for gateway
; variants); "" when absent.


; Pull a human-readable message out of an API error body. OpenAI-style bodies
; nest it at error.message; gateways often put a top-level message. Tries the
; whole body first, then each line, since some callers concatenate several
; SSE events into one buffer.


; One SSE event's JSON → the streamed text delta. Chat-completions streams
; put it at choices[].delta.content; some gateways use a flat content/text.


LLMTranslateSaveSettings(message) {
    global SettingsFile
    msg := LLMMessageParse(message)
    engine := StrLower(Trim(LLMMsgField(msg, "engine")))
    if !TranslateProviderExists(engine)
        engine := "auto"
    ; The form's provider decides which ini fields get written; a missing or
    ; unknown provider falls back to the LLM one.
    provider := TranslateGetProvider(LLMMsgField(msg, "provider"))
    if !IsObject(provider)
        provider := TranslateGetProvider("llm")
    try {
        WriteIniValue(SettingsFile, "LLMTranslate", "engine", engine)
        provider["save"].Call(msg)
    } catch as saveError {
        LLMTranslateSetSaved(false, LLMText("Save failed: ", "保存失败：") . saveError.Message)
        return
    }
    ReloadSettings()
    LLMTranslatePushSettings()
    if provider["configured"].Call()
        LLMTranslateSetSaved(true, LLMText("Settings saved.", "设置已保存。"))
    else
        LLMTranslateSetSaved(false, LLMText(
            "Saved, but " . provider["saveEmpty"][1] . " are still empty.",
            "已保存，但" . provider["saveEmpty"][2] . "仍为空。"
        ))
}

LLMTranslateRunTest(*) {
    global LLMTranslateTestMessage, LLMTranslateRequestRunning
    if LLMTranslateRequestRunning {
        LLMTranslateSetTestResult(false, LLMText(
            "Another request is already running.",
            "已有请求正在执行，请稍候。"
        ))
        return
    }
    LLMTranslateRequestRunning := true
    msg := LLMMessageParse(LLMTranslateTestMessage)
    ; The form posts the provider it belongs to; unknown names test the LLM
    ; provider, same as before.
    provider := TranslateGetProvider(LLMMsgField(msg, "provider"))
    if !IsObject(provider)
        provider := TranslateGetProvider("llm")
    DebugLog("translate settings test provider=" . provider["key"])
    ok := false
    text := ""
    try {
        provider["test"].Call(msg, &ok, &text)
    } catch as requestError {
        ok := false
        text := requestError.Message
    } finally {
        LLMTranslateSetTestResult(ok, text)
        LLMTranslateRequestRunning := false
    }
}

LLMTranslateSetTestResult(ok, text) {
    global LLMTranslateWebView, LLMTranslatePageReady
    if !LLMTranslatePageReady || !IsObject(LLMTranslateWebView)
        return
    try LLMTranslateWebView.ExecuteScriptAsync(
        "window.setTestResult(" . (ok ? "true" : "false") . "," . LLMJsonQuote(text) . ");"
    )
    catch
        return
}

LLMTranslateSetSaved(ok, text) {
    global LLMTranslateWebView, LLMTranslatePageReady
    if !LLMTranslatePageReady || !IsObject(LLMTranslateWebView)
        return
    try LLMTranslateWebView.ExecuteScriptAsync(
        "window.setSaved(" . (ok ? "true" : "false") . "," . LLMJsonQuote(text) . ");"
    )
    catch
        return
}

LLMTranslateStartRequest(*) {
    global LLMTranslatePendingText, LLMTranslateRequestRunning
    global LLMTranslateStreamId, LLMTranslateStreamAnswer
    if LLMTranslateRequestRunning || LLMTranslatePendingText = ""
        return

    LLMTranslateRequestRunning := true
    text := LLMTranslatePendingText
    LLMTranslateSetLoading()
    provider := TranslateResolve(GetTranslateProvider())
    if !IsObject(provider) {
        LLMTranslateSetError(LLMText(
            "No translation API configured. Open Settings.",
            "未配置翻译服务，请点右上角「设置」配置翻译引擎。"
        ))
        LLMTranslateRequestRunning := false
        return
    }
    if !provider["configured"].Call() {
        LLMTranslateSetError(LLMText(provider["notConfigured"][1], provider["notConfigured"][2]))
        LLMTranslateRequestRunning := false
        return
    }
    LLMTranslateStreamAnswer := ""
    if provider["streaming"]
        LLMTranslateStartStreaming()
    try {
        LLMTranslateStreamId := provider["translate"].Call(text, LLMTranslateStreamDelta, LLMTranslateStreamFinished)
    } catch as requestError {
        LLMTranslateStreamFinished("", false, requestError.Message)
    }
}

LLMTranslateStartStreaming() {
    global LLMTranslateWebView, LLMTranslatePageReady
    if !LLMTranslatePageReady || !IsObject(LLMTranslateWebView)
        return
    try LLMTranslateWebView.ExecuteScriptAsync("window.startStreaming();")
    catch
        return
}

LLMTranslateStreamDelta(delta) {
    global LLMTranslateStreamAnswer, LLMTranslateWebView, LLMTranslatePageReady
    LLMTranslateStreamAnswer .= delta
    if !LLMTranslatePageReady || !IsObject(LLMTranslateWebView)
        return
    try LLMTranslateWebView.ExecuteScriptAsync("window.appendStreaming(" . LLMJsonQuote(delta) . ");")
    catch
        return
}

LLMTranslateStreamFinished(answer, success, errorText) {
    global LLMTranslateRequestRunning, LLMTranslateStreamId, LLMTranslateStreamAnswer
    LLMTranslateStreamId := 0
    if success {
        if answer = ""
            answer := LLMTranslateStreamAnswer
        LLMTranslateSetResult(answer)
    } else {
        LLMTranslateSetError(LLMContextLimitHint(errorText))
    }
    LLMTranslateRequestRunning := false
}

; Build the translation-specific messages. Request construction and transport
; are shared by lib\llm.ahk; this module only owns the translation prompt.
TranslateLlmMessages(text, overrides := 0) {
    promptTemplate := TranslateSettingWith("systemPrompt", "", overrides)
    targetLanguage := TranslateTargetLanguageName(
        TranslateSettingWith("targetLanguage", "system", overrides))
    systemPrompt := LLMRenderPromptTemplate(promptTemplate,
        Map("targetLanguage", targetLanguage))
    userPrompt := LLMLimitInputText(text, systemPrompt, overrides)
    return [
        Map("role", "system", "content", systemPrompt),
        Map("role", "user", "content", userPrompt)]
}

TranslateLlmComplete(text, &success := false, &errorText := "", overrides := 0) {
    success := false
    errorText := ""
    messages := TranslateLlmMessages(text, overrides)
    responseText := LLMChatComplete(messages, &success, &errorText, overrides, true)
    if !success
        return ""
    translated := LLMExtractChatText(responseText, "result")
    if translated = "" {
        errorText := LLMText(
            "The LLM response did not contain translation text.",
            "接口返回内容里没有找到译文。"
        )
        return ""
    }
    success := true
    return translated
}

TranslateLlmStartStream(text, onDelta, onFinished, overrides := 0) {
    messages := TranslateLlmMessages(text, overrides)
    return LLMChatStream(messages, onDelta, onFinished, overrides)
}

; ---- "llm" provider glue (registered at the bottom of this file) ----

TranslateProviderLlmTranslate(text, onDelta, onFinished, overrides := 0) {
    return TranslateLlmStartStream(text, onDelta, onFinished, overrides)
}

TranslateProviderLlmTest(msg, &ok, &text) {
    ok := false
    text := ""
    overrides := LLMMessageOverrides(msg, [
        "endpoint", "apiKey", "apiKeyHeader", "apiKeyPrefix", "model",
        "temperature", "timeout", "thinking", "maxInputTokens",
        "targetLanguage", "systemPrompt"])
    translated := TranslateLlmComplete("Hello! This is a capslock_p2 connection test.",
        &ok, &errorText, overrides)
    if ok
        text := LLMText("Connection OK → ", "连接正常 → ") . SubStr(translated, 1, 120)
    else
        text := errorText
}

TranslateProviderLlmSave(msg) {
    global SettingsFile
    LLMSaveSettings(msg)
    WriteIniValue(SettingsFile, "LLMTranslate", "targetLanguage", Trim(LLMMsgField(msg, "targetLanguage")))
}

TranslateProviderLlmPush() {
    payload := LLMSettingsSnapshot()
    payload["targetLanguage"] := GetTranslateSetting("targetLanguage", "")
    return payload
}

LLMTranslateResize(targetGui, minMax, width, height) {
    global LLMTranslateController
    if minMax != -1 && IsObject(LLMTranslateController)
        try LLMTranslateController.Fill()
}

LLMTranslateFocusMonitor(*) {
    global LLMTranslateGui, LLMTranslateVisible, LLMTranslateFocusTimer, LLMTranslateSettingsOpen
    if !LLMTranslateVisible || !IsObject(LLMTranslateGui) {
        SetTimer(LLMTranslateFocusMonitor, 0)
        LLMTranslateFocusTimer := false
        return
    }
    ; Keep the window while the settings view is open so the user can copy
    ; values from elsewhere (endpoint, key, model) without it disappearing.
    if LLMTranslateSettingsOpen {
        return
    }
    if !WinActive("ahk_id " . LLMTranslateGui.Hwnd)
        LLMTranslateHide()
}

LLMTranslateHide(*) {
    global LLMTranslateGui, LLMTranslateVisible, LLMTranslateFocusTimer, LLMTranslateSettingsOpen
    global LLMTranslateStreamId, LLMTranslateRequestRunning
    if LLMTranslateStreamId {
        LLMAbortChatStream(LLMTranslateStreamId)
        LLMTranslateStreamId := 0
    }
    LLMTranslateRequestRunning := false
    LLMTranslateVisible := false
    LLMTranslateSettingsOpen := false
    if IsObject(LLMTranslateGui)
        LLMTranslateGui.Hide()
    SetTimer(LLMTranslateFocusMonitor, 0)
    LLMTranslateFocusTimer := false
}

LLMTranslateShutdown(*) {
    global LLMTranslateGui, LLMTranslateController, LLMTranslateWebView
    global LLMTranslateVisible, LLMTranslatePageReady, LLMTranslateSettingsOpen
    global LLMTranslateStreamId
    if LLMTranslateStreamId {
        LLMAbortChatStream(LLMTranslateStreamId)
        LLMTranslateStreamId := 0
    }
    LLMTranslateVisible := false
    LLMTranslatePageReady := false
    LLMTranslateSettingsOpen := false
    SetTimer(LLMTranslateFocusMonitor, 0)
    try LLMTranslateWebView := 0
    try LLMTranslateController := 0
    if IsObject(LLMTranslateGui) {
        try LLMTranslateGui.Destroy()
        LLMTranslateGui := 0
    }
}

; ---- provider registry: the LLM translation engine ----
; New engines: add a client file with the same three glue functions and
; register it at the bottom of that file (contract in lib\translate.ahk).

TranslateRegisterProvider("llm", Map(
    "streaming", 1,
    "configured", LLMSettingsConfigured,
    "translate", TranslateProviderLlmTranslate,
    "test", TranslateProviderLlmTest,
    "save", TranslateProviderLlmSave,
    "push", TranslateProviderLlmPush,
    "notConfigured", ["No LLM API configured. Open Settings.",
        "未配置 LLM API，请点右上角「设置」填写。"],
    "saveEmpty", ["endpoint and API key", " API 地址和 Key "]))
