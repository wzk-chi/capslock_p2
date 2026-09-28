; LLM translation UI and translation-provider orchestration.
; The UI is hosted by WebView2; API settings are read only from the active
; capslock_p2.ini file, never from the demo/reference INI.

global LLMTranslateHost := 0
global LLMTranslateVisible := false
global LLMTranslatePinned := false
global LLMTranslatePendingText := ""
global LLMTranslateRequestRunning := false
global LLMTranslateStreamId := 0
global LLMTranslateStreamAnswer := ""

; Connection settings live in [LLM]. Translation-wide behavior lives in
; [TTranslate]. The LLM provider's prompt stays in [LLMTranslate].

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

; True when the engine named in [TTranslate] can serve a request. Engines
; are resolved through the registry in lib\features\translate\translate.ahk; "auto" prefers the
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
    global LLMTranslateHost, LLMTranslatePendingText, LLMTranslateVisible
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
    PanelHostShow(LLMTranslateHost, translateSize[1], translateSize[2], true)
    panelGui := PanelHostGui(LLMTranslateHost)
    if IsObject(panelGui)
        WinActivate("ahk_id " . panelGui.Hwnd)
    LLMTranslateApplyWindowState()
    ShowSystemCursor()

    if PanelHostPageReady(LLMTranslateHost) {
        LLMTranslatePushLanguage()
        LLMTranslateSetPinned()
        configured := TranslateConfigured()
        LLMTranslateSetSource(text, text != "" && configured)
        if !configured
            SetTimer(() => SettingsShow("llm"), -1)
    }
}

LLMTranslateEnsureWebView() {
    global LLMTranslateHost
    pagePath := A_ScriptDir . "\pages\translate.html"
    if IsObject(LLMTranslateHost) {
        try {
            PanelHostEnsure(LLMTranslateHost)
            return true
        } catch as existingError {
            PanelHostHide(LLMTranslateHost)
            DebugLog("translate webview failed")
            ShowMsg("WebView2 initialization failed: " . existingError.Message, 5000)
            return false
        }
    }

    translateSize := ScreenFitSize(720, 500, 520, 360)
    LLMTranslateHost := PanelHostCreate(pagePath, "capslock_p2 Translate", Map(
        "guiOptions", "+Caption +Resize +MinSize520x360",
        "dataPath", A_Temp . "\CapsLockPlusWebView2",
        "initialShow", "x-32000 y-32000 w" . translateSize[1] . " h" . translateSize[2] . " NA",
        "callbacks", Map(
            "close", LLMTranslateHide,
            "escape", LLMTranslateHide,
            "resize", LLMTranslateResize,
            "navigation", LLMTranslateNavigationCompleted,
            "message", LLMTranslateWebMessageReceived)))

    try {
        startTick := A_TickCount
        DebugLog("translate webview creating")
        PanelHostEnsure(LLMTranslateHost)
        DebugLog("translate webview ready in " . (A_TickCount - startTick) . " ms")
        return true
    } catch as webViewError {
        DebugLog("translate webview failed")
        PanelHostHide(LLMTranslateHost)
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

LLMTranslateNavigationCompleted(host, sender, args) {
    global LLMTranslatePendingText, LLMTranslateVisible
    if !PanelHostPageReady(host) {
        LLMTranslateSetError("WebView2 could not load the translation panel.")
        return
    }
    if LLMTranslateVisible {
        LLMTranslatePushLanguage()
        LLMTranslateSetPinned()
        configured := TranslateConfigured()
        LLMTranslateSetSource(LLMTranslatePendingText, LLMTranslatePendingText != "" && configured)
        if !configured
            SetTimer(() => SettingsShow("llm"), -1)
    }
}

LLMTranslateWebMessageReceived(sender, args) {
    global LLMTranslatePendingText, LLMTranslatePinned
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
        SetTimer(() => SettingsShow("llm"), -1)
    } else if messageType = "togglePinned" {
        LLMTranslatePinned := !LLMTranslatePinned
        LLMTranslateApplyWindowState()
        LLMTranslateSetPinned()
    } else if messageType = "hide" {
        LLMTranslateHide()
    } else if messageType = "cursorMove" {
        ; WebView2 does not always replay the native cursor after Windows'
        ; mouse-vanish-on-typing behavior. Restore it on an actual page mouse
        ; move, matching the behavior of native edit controls.
        ShowSystemCursor()
    }
}

LLMTranslateOpenDictionary(text) {
    LLMTranslateHide()
    DictionaryShowQuery(text)
}

LLMTranslateSetSource(text, startRequest := false) {
    script := "window.setSource(" . LLMJsonQuote(text) . ");"
    if startRequest
        script .= "window.startTranslate();"
    LLMTranslateExec(script)
}

LLMTranslateSetLoading() {
    LLMTranslateExec("window.setLoading(true);")
}

LLMTranslateSetResult(text) {
    LLMTranslateExec("window.setResult(" . LLMJsonQuote(text) . ");window.setLoading(false);")
}

LLMTranslateSetError(text) {
    LLMTranslateExec("window.setError(" . LLMJsonQuote(text) . ");window.setLoading(false);")
}

LLMTranslatePushLanguage() {
    payload := Map("uiLanguage", LLMUiLanguage())
    LLMTranslateExec("window.onHostSettings(" . JSON.stringify(payload, 0) . ");")
}

LLMTranslateExec(script) {
    global LLMTranslateHost
    PanelHostExecute(LLMTranslateHost, script)
}

LLMTranslateSetPinned() {
    global LLMTranslatePinned
    pinned := LLMTranslatePinned ? "true" : "false"
    LLMTranslateExec("window.setPinned(" . pinned . ");")
}

LLMTranslateApplyWindowState() {
    global LLMTranslateHost, LLMTranslatePinned, LLMTranslateVisible
    panelGui := PanelHostGui(LLMTranslateHost)
    if !IsObject(panelGui)
        return
    WinSetAlwaysOnTop(LLMTranslatePinned, "ahk_id " . panelGui.Hwnd)
    if LLMTranslatePinned
        PanelHostStopFocusMonitor(LLMTranslateHost)
    else if LLMTranslateVisible
        PanelHostStartFocusMonitor(LLMTranslateHost, LLMTranslateFocusMonitor)
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
    LLMTranslateExec("window.startStreaming();")
}

LLMTranslateStreamDelta(delta) {
    global LLMTranslateStreamAnswer
    LLMTranslateStreamAnswer .= delta
    LLMTranslateExec("window.appendStreaming(" . LLMJsonQuote(delta) . ");")
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
; are shared by lib\shared\llm.ahk; this module only owns the translation prompt.
TranslateLlmMessages(text, overrides := 0) {
    promptTemplate := ConfigRead("LLMTranslate", "systemPrompt", "")
    targetLanguage := TranslateTargetLanguageName(
        TranslateSettingWith("targetLanguage", "system", overrides))
    systemPrompt := LLMRenderPromptTemplate(promptTemplate,
        Map("targetLanguage", targetLanguage))
    userPrompt := LLMLimitInputText(text, systemPrompt, overrides)
    return [
        Map("role", "system", "content", systemPrompt),
        Map("role", "user", "content", userPrompt)]
}

TranslateLlmStartStream(text, onDelta, onFinished, overrides := 0) {
    messages := TranslateLlmMessages(text, overrides)
    return LLMChatStream(messages, onDelta, onFinished, overrides)
}

; ---- "llm" provider glue (registered at the bottom of this file) ----

TranslateProviderLlmTranslate(text, onDelta, onFinished, overrides := 0) {
    return TranslateLlmStartStream(text, onDelta, onFinished, overrides)
}

LLMTranslateResize(targetGui, minMax, width, height) {
    global LLMTranslateHost
    PanelHostResize(LLMTranslateHost, minMax)
}

LLMTranslateFocusMonitor(*) {
    global LLMTranslateHost, LLMTranslateVisible, LLMTranslatePinned, SettingsVisible
    if !LLMTranslateVisible || !IsObject(PanelHostGui(LLMTranslateHost)) {
        PanelHostStopFocusMonitor(LLMTranslateHost)
        return
    }
    if LLMTranslatePinned {
        PanelHostStopFocusMonitor(LLMTranslateHost)
        return
    }
    if SettingsVisible {
        return
    }
    if !PanelHostWindowActive(LLMTranslateHost)
        LLMTranslateHide()
}

LLMTranslateHide(*) {
    global LLMTranslateHost, LLMTranslateVisible
    global LLMTranslateStreamId, LLMTranslateRequestRunning
    if LLMTranslateStreamId {
        LLMAbortChatStream(LLMTranslateStreamId)
        LLMTranslateStreamId := 0
    }
    LLMTranslateRequestRunning := false
    LLMTranslateVisible := false
    PanelHostHide(LLMTranslateHost)
    PanelHostStopFocusMonitor(LLMTranslateHost)
}

LLMTranslateShutdown(*) {
    global LLMTranslateHost, LLMTranslateVisible
    global LLMTranslateStreamId
    if LLMTranslateStreamId {
        LLMAbortChatStream(LLMTranslateStreamId)
        LLMTranslateStreamId := 0
    }
    LLMTranslateVisible := false
    PanelHostDestroy(LLMTranslateHost)
    LLMTranslateHost := 0
}

LLMTranslateIsActive() {
    global LLMTranslateHost
    return PanelHostWindowActive(LLMTranslateHost)
}

LLMTranslateOnSettingsSaved() {
    global LLMTranslateVisible, LLMTranslatePendingText
    if !LLMTranslateVisible || !TranslateConfigured() || LLMTranslatePendingText = ""
        return
    LLMTranslateSetSource(LLMTranslatePendingText, true)
}

; ---- provider registry: the LLM translation engine ----
; New engines: add a client file with the same three glue functions and
; register it at the bottom of that file (contract in lib\features\translate\translate.ahk).

TranslateRegisterProvider("llm", Map(
    "streaming", 1,
    "configured", LLMSettingsConfigured,
    "translate", TranslateProviderLlmTranslate,
    "notConfigured", ["No LLM API configured. Open Settings.",
        "未配置 LLM API，请点右上角「设置」填写。"]))
