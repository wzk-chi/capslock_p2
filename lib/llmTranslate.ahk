; LLM translation UI and OpenAI-compatible chat API client.
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
global LLMStreamNextId := 0
global LLMStreamStates := Map()

; Connection settings live in [LLM]. Translation behavior remains in
; [LLMTranslate], including targetLanguage and systemPrompt.
GetLLMSetting(key, defaultValue := "") {
    global Config
    if Config.Has("LLM") && Config["LLM"].Has(key)
        return Config["LLM"][key]
    return defaultValue
}

GetTranslateSetting(key, defaultValue := "") {
    global Config
    if Config.Has("LLMTranslate") && Config["LLMTranslate"].Has(key)
        return Config["LLMTranslate"][key]
    return defaultValue
}

; The panels' UI language follows the application language ([Global] language,
; defaulting to the Windows display language). It is deliberately independent
; of the translation target language: a Chinese user translating into English
; still gets a Chinese UI, and the translator, dictionary and settings dialog
; all share this rule.
LLMTranslateUiLanguage() {
    return IsChineseLanguage() ? "zh" : "en"
}

; Pick the message matching the panel language.
LLMText(english, chinese) {
    return LLMTranslateUiLanguage() = "zh" ? chinese : english
}

LLMSettingWith(key, defaultValue, overrides) {
    if IsObject(overrides) && overrides.Has(key)
        return overrides[key]
    return GetLLMSetting(key, defaultValue)
}

TranslateSettingWith(key, defaultValue, overrides) {
    if IsObject(overrides) && overrides.Has(key)
        return overrides[key]
    return GetTranslateSetting(key, defaultValue)
}

; First use: the API endpoint and key have never been configured.
LLMSettingsConfigured() {
    return Trim(GetLLMSetting("endpoint", "")) != "" && Trim(GetLLMSetting("apiKey", "")) != ""
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

LLMTranslateShow(text) {
    global LLMTranslateGui, LLMTranslatePendingText, LLMTranslateVisible, LLMTranslatePageReady, LLMTranslateFocusTimer
    text := Trim(text)
    if text = ""
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
        LLMTranslateSetSource(text, TranslateConfigured())
        if !TranslateConfigured()
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
    if LLMTranslateVisible && LLMTranslatePendingText != "" {
        LLMTranslatePushSettings()
        LLMTranslateSetSource(LLMTranslatePendingText, TranslateConfigured())
        if !TranslateConfigured()
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
        "uiLanguage", LLMTranslateUiLanguage(),
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
LLMMessageParse(message) {
    try return JSON.Parse(message)
    catch
        return Map()
}

; Read one field of a parsed message; "" when absent or non-scalar.
LLMMsgField(msg, key) {
    if !IsObject(msg) || !msg.Has(key)
        return ""
    value := msg[key]
    if IsObject(value)
        return ""
    return value = true ? "true" : value = false ? "false" : String(value)
}

; Parse an LLM API response body; 0 when it is not a JSON object.
LLMResponseParse(bodyText) {
    try parsed := JSON.Parse(bodyText)
    catch
        return 0
    return IsObject(parsed) ? parsed : 0
}

; The named content field of a chat-completions response, read from
; choices[].message (then the choice, then the top level, for gateway
; variants); "" when absent.
LLMResponseContent(responseText, key := "content") {
    parsed := LLMResponseParse(responseText)
    if parsed = 0
        return ""
    choices := parsed.Has("choices") && IsObject(parsed["choices"]) ? parsed["choices"] : []
    for choice in choices {
        if !IsObject(choice)
            continue
        message := choice.Has("message") && IsObject(choice["message"]) ? choice["message"] : 0
        if IsObject(message) && message.Has(key) && !IsObject(message[key])
            return String(message[key])
        if choice.Has(key) && !IsObject(choice[key])
            return String(choice[key])
    }
    if parsed.Has(key) && !IsObject(parsed[key])
        return String(parsed[key])
    return ""
}

; Pull a human-readable message out of an API error body. OpenAI-style bodies
; nest it at error.message; gateways often put a top-level message. Tries the
; whole body first, then each line, since some callers concatenate several
; SSE events into one buffer.
LLMErrorMessageFrom(body) {
    candidates := [body]
    for line in StrSplit(body, "`n", " `t`r")
        if line != ""
            candidates.Push(line)
    for candidate in candidates {
        parsed := LLMResponseParse(candidate)
        if parsed = 0
            continue
        if parsed.Has("error") && IsObject(parsed["error"]) && parsed["error"].Has("message") {
            value := parsed["error"]["message"]
            if !IsObject(value)
                return String(value)
        }
        if parsed.Has("message") && !IsObject(parsed["message"])
            return String(parsed["message"])
    }
    return ""
}

; One SSE event's JSON → the streamed text delta. Chat-completions streams
; put it at choices[].delta.content; some gateways use a flat content/text.
LLMStreamDeltaText(data) {
    parsed := LLMResponseParse(data)
    if parsed = 0
        return ""
    choices := parsed.Has("choices") && IsObject(parsed["choices"]) ? parsed["choices"] : []
    for choice in choices {
        if !IsObject(choice)
            continue
        for section in ["delta", "message"] {
            part := choice.Has(section) && IsObject(choice[section]) ? choice[section] : 0
            if !IsObject(part)
                continue
            for key in ["content", "text"] {
                if part.Has(key) && !IsObject(part[key]) {
                    value := String(part[key])
                    if value != ""
                        return value
                }
            }
        }
        if choice.Has("text") && !IsObject(choice["text"]) {
            value := String(choice["text"])
            if value != ""
                return value
        }
    }
    for key in ["content", "text"] {
        if parsed.Has(key) && !IsObject(parsed[key]) {
            value := String(parsed[key])
            if value != ""
                return value
        }
    }
    return ""
}

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
            "未配置翻译 API，请点右上角「设置」配置翻译引擎。"
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

; Accept a bare base URL (https://host:5443) or a partial path and complete it
; to the OpenAI-compatible chat completions endpoint.
LLMNormalizeEndpoint(url) {
    url := Trim(url)
    if url = ""
        return ""
    url := RegExReplace(url, "#.*$")          ; drop fragment
    url := RTrim(url, "/")                     ; drop trailing slashes
    if !RegExMatch(url, "i)^https?://")
        url := "https://" . url
    url := RTrim(url, "/")
    if RegExMatch(url, "i)/chat/completions/?$")
        return url                             ; already the full endpoint
    if RegExMatch(url, "i)/v\d+[a-z]*$")
        return url . "/chat/completions"       ; …/v1 → add the action only
    return url . "/v1/chat/completions"        ; bare base URL
}

; The translator's chat completions client. The task lives in the system
; message and the user message carries only the text, so a model cannot
; mistake the instruction for content.
LLMChatRequest(text, &success := false, &errorText := "", overrides := 0) {
    success := false
    errorText := ""

    if GetTranslateSetting("enabled", "1") = "0" {
        errorText := LLMText(
            "LLM translation is disabled in [LLMTranslate].",
            "[LLMTranslate] 中已禁用翻译（enabled=0）。"
        )
        return ""
    }

    endpoint := LLMNormalizeEndpoint(LLMSettingWith("endpoint", "", overrides))
    apiKey := LLMSettingWith("apiKey", "", overrides)
    model := Trim(LLMSettingWith("model", "gpt-4o-mini", overrides))
    if model = ""
        model := "gpt-4o-mini"
    if endpoint = "" {
        errorText := LLMText(
            "No API endpoint configured. Open Settings in the translate panel.",
            "尚未配置 API 地址，请点翻译面板里的「设置」填写。"
        )
        return ""
    }

    baseSystem := Trim(TranslateSettingWith("systemPrompt", "You are a precise translation engine.", overrides))
    if baseSystem = ""
        baseSystem := "You are a precise translation engine."
    targetLanguage := Trim(TranslateSettingWith("targetLanguage", "", overrides))
    if targetLanguage = ""
        targetLanguage := "Simplified Chinese if the text is not Chinese, otherwise English"
    ; Structured output ([LLM] structured=1, default): ask for a strict JSON
    ; schema response {"translation": "..."} so parsing is deterministic.
    structured := StrLower(Trim(GetLLMSetting("structured", "1")))
    structuredOn := !(structured = "0" || structured = "false" || structured = "off")
    systemPrompt := baseSystem
        . " Translate the user's message into " . targetLanguage . "."
        . " Preserve meaning, tone, formatting, names and code."
        . " Keep the source text's line breaks and paragraph structure."
        . (structuredOn
            ? " Respond with a JSON object containing a single key " . Chr(34) . "translation" . Chr(34)
                . " whose value is the translation."
            : " Return only the translation, nothing else.")
    userPrompt := text
    thinking := StrLower(Trim(GetLLMSetting("thinking", "0")))
    body := LLMBuildChatBody(model, [
        Map("role", "system", "content", systemPrompt),
        Map("role", "user", "content", userPrompt)
    ], GetLLMSetting("temperature", "0.2"), GetLLMSetting("maxTokens", ""), thinking, structuredOn, false)

    headerName := GetLLMSetting("apiKeyHeader", "Authorization")
    prefix := GetLLMSetting("apiKeyPrefix", "Bearer")
    headerValue := prefix = "" ? apiKey : prefix . " " . apiKey
    timeout := GetLLMSetting("timeout", "30000") + 0
    timeout := Max(1000, Min(120000, timeout ? timeout : 30000))
    responseText := LLMSendChatBody(body, endpoint, headerName, headerValue, timeout, &success, &errorText)
    if !success
        return ""
    translated := LLMExtractTranslation(responseText, structuredOn)
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

LLMTranslateStartStream(text, onDelta, onFinished, overrides := 0) {
    body := LLMTranslateBuildBody(text, overrides, true, &endpoint, &headerName, &headerValue, &timeout, &errorText)
    if body = "" {
        try onFinished.Call("", false, errorText)
        return 0
    }
    return LLMStartChatStream(body, endpoint, headerName, headerValue, timeout, onDelta, onFinished)
}

; ---- "llm" provider glue (registered at the bottom of this file) ----

TranslateProviderLlmTranslate(text, onDelta, onFinished, overrides := 0) {
    return LLMTranslateStartStream(text, onDelta, onFinished, overrides)
}

TranslateProviderLlmTest(msg, &ok, &text) {
    ok := false
    text := ""
    overrides := Map(
        "endpoint", Trim(LLMMsgField(msg, "endpoint")),
        "apiKey", LLMMsgField(msg, "apiKey"),
        "model", Trim(LLMMsgField(msg, "model")),
        "targetLanguage", Trim(LLMMsgField(msg, "targetLanguage"))
    )
    translated := LLMChatRequest("Hello! This is a capslock_p2 connection test.", &ok, &errorText, overrides)
    if ok
        text := LLMText("Connection OK → ", "连接正常 → ") . SubStr(translated, 1, 120)
    else
        text := errorText
}

TranslateProviderLlmSave(msg) {
    global SettingsFile
    WriteIniValue(SettingsFile, "LLM", "endpoint", Trim(LLMMsgField(msg, "endpoint")))
    WriteIniValue(SettingsFile, "LLM", "apiKey", LLMMsgField(msg, "apiKey"))
    WriteIniValue(SettingsFile, "LLM", "model", Trim(LLMMsgField(msg, "model")))
    WriteIniValue(SettingsFile, "LLMTranslate", "targetLanguage", Trim(LLMMsgField(msg, "targetLanguage")))
}

TranslateProviderLlmPush() {
    return Map(
        "endpoint", GetLLMSetting("endpoint", ""),
        "apiKey", GetLLMSetting("apiKey", ""),
        "model", GetLLMSetting("model", ""),
        "targetLanguage", GetTranslateSetting("targetLanguage", ""))
}

LLMTranslateBuildBody(text, overrides, stream, &endpoint, &headerName, &headerValue, &timeout, &errorText) {
    errorText := ""
    if GetTranslateSetting("enabled", "1") = "0" {
        errorText := LLMText(
            "LLM translation is disabled in [LLMTranslate].",
            "[LLMTranslate] 中已禁用翻译（enabled=0）。"
        )
        return ""
    }
    endpoint := LLMNormalizeEndpoint(LLMSettingWith("endpoint", "", overrides))
    apiKey := LLMSettingWith("apiKey", "", overrides)
    model := Trim(LLMSettingWith("model", "gpt-4o-mini", overrides))
    if model = ""
        model := "gpt-4o-mini"
    if endpoint = "" {
        errorText := LLMText(
            "No API endpoint configured. Open Settings in the translate panel.",
            "尚未配置 API 地址，请点翻译面板里的「设置」填写。"
        )
        return ""
    }

    baseSystem := Trim(TranslateSettingWith("systemPrompt", "You are a precise translation engine.", overrides))
    if baseSystem = ""
        baseSystem := "You are a precise translation engine."
    targetLanguage := Trim(TranslateSettingWith("targetLanguage", "", overrides))
    if targetLanguage = ""
        targetLanguage := "Simplified Chinese if the text is not Chinese, otherwise English"
    structured := StrLower(Trim(GetLLMSetting("structured", "1")))
    structuredOn := !stream && !(structured = "0" || structured = "false" || structured = "off")
    systemPrompt := baseSystem
        . " Translate the user's message into " . targetLanguage . "."
        . " Preserve meaning, tone, formatting, names and code."
        . " Keep the source text's line breaks and paragraph structure."
        . (structuredOn
            ? " Respond with a JSON object containing a single key " . Chr(34) . "translation" . Chr(34)
                . " whose value is the translation."
            : " Return only the translation, nothing else.")
    thinking := StrLower(Trim(LLMSettingWith("thinking", "0", overrides)))
    body := LLMBuildChatBody(model, [
        Map("role", "system", "content", systemPrompt),
        Map("role", "user", "content", text)
    ], LLMSettingWith("temperature", "0.2", overrides), LLMSettingWith("maxTokens", "", overrides),
        thinking, structuredOn, stream)

    headerName := LLMSettingWith("apiKeyHeader", "Authorization", overrides)
    prefix := LLMSettingWith("apiKeyPrefix", "Bearer", overrides)
    headerValue := prefix = "" ? apiKey : prefix . " " . apiKey
    timeout := LLMSettingWith("timeout", "30000", overrides) + 0
    timeout := Max(1000, Min(120000, timeout ? timeout : 30000))
    return body
}

; Build a compact chat-completions request body with the official JSON
; serializer. Reasoning mode off by default; providers disagree on the
; parameter name, so send the common disable variants at once and let the
; server ignore the ones it does not know: enable_thinking=false (Qwen/
; DashScope), reasoning_effort=none (OpenAI gpt-5.1+), reasoning.enabled=false
; (OpenRouter), thinking.type=disabled (Anthropic-style),
; chat_template_kwargs.enable_thinking=false (vLLM/SGLang).
LLMBuildChatBody(model, messages, temperature, maxTokens, thinking, structuredOn := false, stream := false) {
    payload := Map("model", model, "messages", messages)
    if RegExMatch(temperature, "^-?(?:\d+\.?\d*|\.\d+)$")
        payload["temperature"] := temperature + 0
    if RegExMatch(maxTokens, "^\d+$") && maxTokens + 0 > 0
        payload["max_tokens"] := maxTokens + 0
    if !(thinking = "1" || thinking = "true" || thinking = "on") {
        payload["enable_thinking"] := JSON.false
        payload["reasoning_effort"] := "none"
        payload["reasoning"] := Map("enabled", JSON.false)
        payload["thinking"] := Map("type", "disabled")
        payload["chat_template_kwargs"] := Map("enable_thinking", JSON.false)
    }
    if structuredOn
        payload["response_format"] := Map(
            "type", "json_schema",
            "json_schema", Map(
                "name", "translation_result",
                "strict", JSON.true,
                "schema", Map(
                    "type", "object",
                    "properties", Map("translation", Map("type", "string")),
                    "required", ["translation"],
                    "additionalProperties", JSON.false)))
    if stream
        payload["stream"] := JSON.true
    return JSON.stringify(payload, 0)
}

; Sends a fully built chat completions body over WinHttp and returns the raw
; response text; transport failures and HTTP errors fill errorText. Shared by
; the translator and the AI chat, which each extract their own fields.
LLMSendChatBody(body, endpoint, authHeaderName, authHeaderValue, timeoutMs, &success, &errorText) {
    success := false
    errorText := ""
    try {
        request := ComObject("WinHttp.WinHttpRequest.5.1")
        request.Open("POST", endpoint, false)
        request.SetTimeouts(timeoutMs, timeoutMs, timeoutMs, timeoutMs)
        request.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
        if authHeaderValue != ""
            request.SetRequestHeader(authHeaderName, authHeaderValue)
        ; Send explicit UTF-8 bytes: WinHttpRequest encodes a string body with the
        ; ANSI code page on some systems, which mangles non-ASCII text.
        request.Send(LLMUtf8Bytes(body))
        status := request.Status + 0
        responseText := LLMResponseText(request)
        if status < 200 || status >= 300 {
            apiError := LLMErrorMessageFrom(responseText)
            errorText := LLMText("LLM API HTTP ", "接口返回 HTTP ") . status
                . (apiError = "" ? "" : ": " . apiError)
            return ""
        }
        success := true
        return responseText
    } catch as apiRequestError {
        errorText := LLMText("LLM request failed: ", "请求失败：") . apiRequestError.Message
        return ""
    }
}

; Starts an OpenAI-compatible chat completion in async mode. The endpoint must
; return SSE data when the request body contains stream=true. onDelta receives
; each content fragment; onFinished receives (text, success, errorText).
;
; WinHttpRequest exposes its events through IWinHttpRequestEvents, which is an
; IUnknown-only interface. AHK's ComObjConnect intentionally supports only
; dispatch event sources, so connecting it directly raises E_NOINTERFACE
; (0x80004002). LLMStreamAttachEvents below uses the documented COM connection
; point interfaces directly instead.
LLMStartChatStream(body, endpoint, authHeaderName, authHeaderValue, timeoutMs, onDelta, onFinished) {
    global LLMStreamNextId, LLMStreamStates
    LLMStreamNextId += 1
    id := LLMStreamNextId
    state := Map(
        "id", id,
        "onDelta", onDelta,
        "onFinished", onFinished,
        "lineBytes", [],
        "eventData", "",
        "rawBody", "",
        "errorBody", "",
        "text", "",
        "status", 0,
        "done", false,
        "finished", false,
        "cancelled", false,
        "request", 0,
        "sink", 0,
        "connectionContainer", 0,
        "connectionPoint", 0,
        "connectionCookie", 0
    )
    stage := "creating WinHTTP request"
    try {
        request := ComObject("WinHttp.WinHttpRequest.5.1")
        state["request"] := request
        LLMStreamStates[id] := state

        stage := "opening asynchronous request"
        request.Open("POST", endpoint, true)

        stage := "creating WinHTTP event sink"
        sink := LLMWinHttpEventSink(state)
        state["sink"] := sink

        stage := "connecting WinHTTP events"
        LLMStreamAttachEvents(request, state)

        stage := "setting request timeouts"
        request.SetTimeouts(timeoutMs, timeoutMs, timeoutMs, timeoutMs)

        stage := "setting request headers"
        request.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
        request.SetRequestHeader("Accept", "text/event-stream")
        if authHeaderValue != ""
            request.SetRequestHeader(authHeaderName, authHeaderValue)

        stage := "sending request"
        request.Send(LLMUtf8Bytes(body))
        DebugLog("LLM stream started id=" . id . " endpoint=" . endpoint)
        return id
    } catch as streamError {
        errorText := "LLM stream " . stage . " failed: " . streamError.Message
        DebugLog("LLM stream failed id=" . id . " stage=" . stage . " error=" . streamError.Message)
        LLMStreamComplete(state, false, errorText)
        return 0
    }
}

LLMAbortChatStream(id) {
    global LLMStreamStates
    if !id || !LLMStreamStates.Has(id)
        return
    state := LLMStreamStates[id]
    state["cancelled"] := true
    state["finished"] := true
    try state["request"].Abort()
    LLMStreamRelease(state)
}

; Raw COM sink for IWinHttpRequestEvents. This interface is declared as
; IUnknown (not IDispatch), so it cannot be passed to ComObjConnect.
class LLMWinHttpEventSink extends Buffer {
    __New(state) {
        callbacks := [
            [QueryInterface, 3],
            [AddRef, 1],
            [Release, 1],
            [OnResponseStart, 3],
            [OnResponseDataAvailable, 2],
            [OnResponseFinished, 1],
            [OnError, 3]
        ]
        super.__New((2 + callbacks.Length) * A_PtrSize)
        this.State := state
        pThis := ObjPtr(this)
        pInterface := this.Ptr
        pVtable := pInterface + 2 * A_PtrSize
        NumPut("ptr", pVtable, "ptr", pThis, this)
        this.Callbacks := []
        offset := 0
        for callbackInfo in callbacks {
            callbackPtr := CallbackCreate(callbackInfo[1], , callbackInfo[2])
            NumPut("ptr", callbackPtr, pVtable, offset)
            this.Callbacks.Push(callbackPtr)
            offset += A_PtrSize
        }

        QueryInterface(interface, riid, ppvObject) {
            if !ppvObject
                return 0x80004003
            DllCall("ole32\StringFromGUID2", "ptr", riid, "ptr", guidText := Buffer(78, 0), "int", 39)
            iid := StrUpper(StrGet(guidText, "UTF-16"))
            DebugLog("LLM event sink QueryInterface iid=" . iid . " out=" . ppvObject)
            if iid = "{00000000-0000-0000-C000-000000000046}"
                || iid = "{F97F4E15-B787-4212-80D1-D380CBBF982E}" {
                ObjAddRef(pThis)
                NumPut("ptr", pInterface, ppvObject)
                return 0
            }
            NumPut("ptr", 0, ppvObject)
            return 0x80004002
        }

        AddRef(interface) => ObjAddRef(pThis)

        Release(interface) => ObjRelease(pThis)

        OnResponseStart(interface, status, contentType) {
            sink := ObjFromPtrAddRef(pThis)
            LLMStreamOnResponseStart(sink.State, status + 0)
        }

        OnResponseDataAvailable(interface, data) {
            sink := ObjFromPtrAddRef(pThis)
            bytes := LLMStreamSafeArrayBytes(data)
            if bytes.Length
                LLMStreamOnData(sink.State, bytes)
        }

        OnResponseFinished(interface) {
            sink := ObjFromPtrAddRef(pThis)
            LLMStreamOnFinished(sink.State)
        }

        OnError(interface, errorNumber, errorDescription) {
            sink := ObjFromPtrAddRef(pThis)
            if errorDescription
                errorText := StrGet(errorDescription, "UTF-16")
            else
                errorText := "WinHTTP stream error"
            if errorNumber
                errorText := "WinHTTP " . (errorNumber + 0) . ": " . errorText
            DebugLog("LLM stream event error id=" . sink.State["id"] . " error=" . errorText)
            LLMStreamComplete(sink.State, false, errorText)
        }
    }

    __Delete() {
        if !IsObject(this.Callbacks)
            return
        for callbackPtr in this.Callbacks
            if callbackPtr
                CallbackFree(callbackPtr)
    }
}

; IConnectionPointContainer::FindConnectionPoint and
; IConnectionPoint::Advise are the official registration path for
; IWinHttpRequestEvents.
LLMStreamAttachEvents(request, state) {
    static connectionPointContainerIid := "{B196B284-BAB4-101A-B69C-00AA00341D07}"
    static eventIid := "{F97F4E15-B787-4212-80D1-D380CBBF982E}"
    container := ComObjQuery(request, connectionPointContainerIid)
    connectionPoint := 0
    ComCall(4, container, "ptr", LLMGuid(eventIid), "ptr*", &connectionPoint := 0)
    if !connectionPoint
        throw Error("WinHTTP did not expose its event connection point.")
    state["connectionContainer"] := container
    state["connectionPoint"] := connectionPoint
    try {
        ComCall(5, connectionPoint, "ptr", state["sink"].Ptr, "uint*", &cookie := 0)
        state["connectionCookie"] := cookie
        DebugLog("LLM stream events connected id=" . state["id"] . " cookie=" . cookie)
    } catch as connectionError {
        ObjRelease(connectionPoint)
        state["connectionPoint"] := 0
        state["connectionContainer"] := 0
        throw connectionError
    }
}

LLMGuid(guidText) {
    guid := Buffer(16, 0)
    if DllCall("ole32\CLSIDFromString", "wstr", guidText, "ptr", guid) != 0
        throw ValueError("Invalid COM GUID", -1, guidText)
    return guid
}

; IWinHttpRequestEvents passes SAFEARRAY(unsigned char)*, which is a pointer
; to the SAFEARRAY pointer. Copy it while the callback owns the event data.
LLMStreamSafeArrayBytes(data) {
    if !data
        return []
    safeArray := NumGet(data, "ptr")
    if !safeArray
        return []
    if DllCall("oleaut32\SafeArrayGetDim", "ptr", safeArray) != 1
        return []
    lower := 0
    upper := -1
    if DllCall("oleaut32\SafeArrayGetLBound", "ptr", safeArray, "uint", 1, "int*", &lower) != 0
        return []
    if DllCall("oleaut32\SafeArrayGetUBound", "ptr", safeArray, "uint", 1, "int*", &upper) != 0
        return []
    count := upper - lower + 1
    if count <= 0
        return []
    dataPtr := 0
    if DllCall("oleaut32\SafeArrayAccessData", "ptr", safeArray, "ptr*", &dataPtr) != 0
        return []
    bytes := []
    Loop count
        bytes.Push(NumGet(dataPtr, A_Index - 1, "UChar"))
    DllCall("oleaut32\SafeArrayUnaccessData", "ptr", safeArray)
    return bytes
}

LLMStreamOnResponseStart(state, status) {
    if !state["finished"] {
        state["status"] := status
        DebugLog("LLM stream response started id=" . state["id"] . " status=" . status)
    }
}

LLMStreamOnData(state, data) {
    if state["finished"] || state["cancelled"]
        return
    ; data is the plain byte array produced by LLMStreamSafeArrayBytes; its
    ; elements are always plain integers 0-255. Raw ComValues or strings must
    ; never reach lineBytes — NumPut in LLMStreamDecode rejects them with
    ; "Invalid parameter(s)", killing the stream mid-response.
    for byte in data {
        if byte = 10 {
            line := LLMStreamDecode(state["lineBytes"])
            state["lineBytes"] := []
            LLMStreamLine(state, line)
        } else if byte != 13 {
            if Type(byte) != "Integer"
                DebugLog("LLM stream pushed non-integer byte type=" . Type(byte))
            state["lineBytes"].Push(byte)
        }
    }
}

LLMStreamDecode(bytes) {
    if !bytes.Length
        return ""
    rawBuffer := Buffer(bytes.Length + 1, 0)
    for index, byte in bytes {
        offset := index - 1
        if offset < 0 || offset >= rawBuffer.Size {
            ; Diagnostics: an index past the buffer means the enumerator
            ; handed us something an AHK Array never produces — log it and
            ; decode the rest instead of killing the stream.
            DebugLog("LLM decode offset skipped index=" . index . " len=" . bytes.Length
                . " arrayType=" . Type(bytes) . " elementType=" . Type(byte))
            continue
        }
        try {
            NumPut("UChar", Integer(byte), rawBuffer, offset)
        } catch {
            DebugLog("LLM decode element skipped index=" . index . " type=" . Type(byte))
        }
    }
    try return StrGet(rawBuffer, "UTF-8")
    catch
        return StrGet(rawBuffer, "CP0")
}

LLMStreamLine(state, line) {
    if line = "" {
        if state["eventData"] != "" {
            data := state["eventData"]
            state["eventData"] := ""
            LLMStreamEvent(state, data)
        }
        return
    }
    if SubStr(line, 1, 1) = ":"
        return
    if SubStr(line, 1, 5) = "data:" {
        piece := SubStr(line, 6)
        if SubStr(piece, 1, 1) = " "
            piece := SubStr(piece, 2)
        state["eventData"] .= (state["eventData"] = "" ? "" : "`n") . piece
    } else {
        state["rawBody"] .= line . "`n"
    }
}

LLMStreamEvent(state, data) {
    data := Trim(data)
    state["rawBody"] .= data . "`n"
    if data = "[DONE]" {
        state["done"] := true
        return
    }
    if state["status"] < 200 || state["status"] >= 300 {
        state["errorBody"] .= data
        return
    }
    delta := LLMStreamDeltaText(data)
    if delta != "" {
        state["text"] .= delta
        try state["onDelta"].Call(delta)
        catch
            return
    }
}

LLMStreamOnFinished(state) {
    if state["finished"] || state["cancelled"]
        return
    if state["lineBytes"].Length
        LLMStreamLine(state, LLMStreamDecode(state["lineBytes"]))
    if state["eventData"] != "" {
        data := state["eventData"]
        state["eventData"] := ""
        LLMStreamEvent(state, data)
    }
    if state["status"] < 200 || state["status"] >= 300 {
        errorText := LLMErrorMessageFrom(state["errorBody"] . "`n" . state["rawBody"])
        if errorText = ""
            errorText := "HTTP " . state["status"]
        LLMStreamComplete(state, false, errorText)
        return
    }
    if state["text"] = "" {
        ; Non-streaming body despite stream:true — read the content field
        ; from the raw response.
        fallback := LLMStreamDeltaText(state["rawBody"])
        if fallback != "" {
            state["text"] := fallback
            try state["onDelta"].Call(fallback)
        }
    }
    if state["text"] = ""
        LLMStreamComplete(state, false, "The streaming response did not contain content.")
    else
        LLMStreamComplete(state, true, "")
}

LLMStreamComplete(state, success, errorText) {
    if state["finished"]
        return
    state["finished"] := true
    text := state["text"]
    callback := state["onFinished"]
    DebugLog("LLM stream completed id=" . state["id"] . " success=" . success
        . " chars=" . StrLen(text) . (errorText = "" ? "" : " error=" . errorText))
    LLMStreamRelease(state)
    try callback.Call(text, success, errorText)
}

LLMStreamRelease(state) {
    global LLMStreamStates
    id := state["id"]
    cookie := state["connectionCookie"]
    connectionPoint := state["connectionPoint"]
    if connectionPoint {
        if cookie {
            try ComCall(6, connectionPoint, "uint", cookie)
        }
        try ObjRelease(connectionPoint)
    }
    state["connectionCookie"] := 0
    state["connectionPoint"] := 0
    state["connectionContainer"] := 0
    if LLMStreamStates.Has(id)
        LLMStreamStates.Delete(id)
    state["request"] := 0
    state["sink"] := 0
}

; Encode a request body as a VT_UI1 SafeArray holding UTF-8 bytes.
LLMUtf8Bytes(text) {
    byteCount := StrPut(text, "UTF-8") - 1
    byteBuffer := Buffer(byteCount + 1, 0)
    StrPut(text, byteBuffer, "UTF-8")
    bytes := ComObjArray(0x11, byteCount)
    Loop byteCount
        bytes[A_Index - 1] := NumGet(byteBuffer, A_Index - 1, "UChar")
    return bytes
}

; ResponseText decodes with the Content-Type charset and falls back to the ANSI
; code page, which garbles UTF-8 JSON. Decode the raw bytes as UTF-8 instead.
LLMResponseText(request) {
    try {
        body := request.ResponseBody
        if !IsObject(body)
            return request.ResponseText
        bytes := []
        for byte in body
            bytes.Push(byte)
        if !bytes.Length
            return ""
        rawBuffer := Buffer(bytes.Length + 1, 0)
        for index, byte in bytes
            NumPut("UChar", byte, rawBuffer, index - 1)
        return StrGet(rawBuffer, "UTF-8")
    } catch
        return request.ResponseText
}

LLMExtractTranslation(responseText, structured := false) {
    ; Structured request: the message content is expected to be a JSON object
    ; {"translation": "..."} — unwrap it. If the gateway ignored response_format
    ; and returned plain text, fall back to using the content as-is.
    if structured {
        content := LLMResponseContent(responseText)
        if content != "" {
            inner := LLMMsgField(LLMMessageParse(content), "translation")
            if inner != ""
                return Trim(inner)
            return Trim(content)
        }
    }
    for key in ["content", "text", "translation", "translatedText", "result"] {
        value := LLMResponseContent(responseText, key)
        if value != ""
            return Trim(value)
    }
    return ""
}

; Context-window errors arrive as bare English API messages; append a hint
; that says what to do about it. Anything else passes through unchanged.
LLMContextLimitHint(errorText) {
    lower := StrLower(errorText)
    if InStr(lower, "context length") || InStr(lower, "context_length")
        || InStr(lower, "maximum context") || InStr(lower, "too many tokens") {
        return errorText . " — " . (IsChineseLanguage()
            ? "输入超出模型上下文上限。请缩短内容，或在聊天面板新建会话。"
            : "The input exceeded the model's context window. Shorten it, or start a new chat session.")
    }
    return errorText
}

; Escape a single value for embedding in a JavaScript call string. thqby's
; stringify serializes Maps/Arrays/Objects only — a scalar goes through it as
; a one-element array and the brackets are stripped, so the escaping still
; happens in the library. Non-objects are coerced to strings so numeric
; values stay quoted, matching the original hand-written escaper.
LLMJsonQuote(value) {
    return IsObject(value) ? JSON.stringify(value, 0)
        : SubStr(JSON.stringify([String(value)], 0), 2, -1)
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
