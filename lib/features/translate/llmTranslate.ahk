; LLM translation UI and translation-provider orchestration.
; The UI is hosted by WebView2; API settings are read only from the active
; application database.

global LLMTranslateHost := 0
global LLMTranslateVisible := false
global LLMTranslatePinned := false
global LLMTranslateNativeWindow := false
global LLMTranslatePendingText := ""
global LLMTranslateRequestRunning := false
global LLMTranslateRequestOperation := 0
global LLMTranslateStreamAnswer := ""
global LLMTranslatePendingSourceLanguage := ""
global LLMTranslatePendingTargetLanguage := ""
global LLMTranslatePendingDirectionManual := false
global LLMTranslateRequestSerial := 0
global LLMTranslateActiveRequest := 0

; Connection settings live in [LLM]. Translation-wide behavior lives in
; [TTranslate]. The LLM provider's prompt stays in [LLMTranslate].

TranslateTargetLanguageName(value) {
    value := Trim(value)
    if value = "" || StrLower(value) = "system"
        return SystemLanguageName()

    normalized := TranslateNormalizeLanguage(value)
    return normalized = "" ? value : TranslateLanguageName(normalized)
}

; True when the engine named in [TTranslate] can serve a request. Engines
; are resolved through the registry in lib\features\translate\translate.ahk; "auto" prefers the
; LLM provider and falls back to any other configured one.
TranslateConfigured() {
    provider := TranslateResolve(GetTranslateProvider())
    return IsObject(provider) && provider["configured"].Call()
}

LLMTranslateOpenSettingsForMissingConfig() {
    message := LLMText(
        "Configure a translation API or LLM before using translation.",
        "请先配置翻译API或LLM再使用翻译功能")
    LLMTranslateHide()
    SetTimer(SettingsShow.Bind("translate", message), -1)
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
    LLMTranslateApplyNativeWindowMode()
    LLMTranslateApplyWindowState()

    if PanelHostPageReady(LLMTranslateHost) {
        LLMTranslatePushLanguage()
        LLMTranslateSetPinned()
        configured := TranslateConfigured()
        LLMTranslateSetSource(text, text != "" && configured)
        if !configured
            LLMTranslateOpenSettingsForMissingConfig()
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
        "guiOptions", "+Resize +MinSize520x360 +MinimizeBox +MaximizeBox +SysMenu +ToolWindow -Caption",
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
        LLMTranslateApplyNativeWindowMode()
        LLMTranslatePushLanguage()
        LLMTranslateSetPinned()
        configured := TranslateConfigured()
        LLMTranslateSetSource(LLMTranslatePendingText, LLMTranslatePendingText != "" && configured)
        if !configured
            LLMTranslateOpenSettingsForMissingConfig()
    }
}

LLMTranslateWebMessageReceived(sender, args) {
    global LLMTranslatePendingText, LLMTranslatePinned
    global LLMTranslatePendingSourceLanguage, LLMTranslatePendingTargetLanguage
    global LLMTranslatePendingDirectionManual
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    messageType := LLMMsgField(msg, "type")
    if WindowBarHandleDebugMessage(msg, "translate")
        return
    if WindowBarHandleMessage(LLMTranslateHost, messageType, LLMTranslateHide,
        LLMTranslateSetPinnedState, Map("guard", LLMTranslateFocusHideGuard),
        LLMTranslateSetNativeState)
        return
    if messageType = "translate" {
        text := LLMMsgField(msg, "text")
        if text = ""
            return
        LLMTranslatePendingText := text
        LLMTranslatePendingSourceLanguage := LLMMsgField(msg, "sourceLanguage")
        LLMTranslatePendingTargetLanguage := LLMMsgField(msg, "targetLanguage")
        manualValid := false
        LLMTranslatePendingDirectionManual := LLMMsgBoolean(msg, "directionManual", &manualValid, false)
        requestId := LLMTranslateInvalidateRequest()
        LLMTranslateSetLoading()
        SetTimer(LLMTranslateStartRequest.Bind(requestId), -1)
    } else if messageType = "openDictionary" {
        text := LLMMsgField(msg, "text")
        SetTimer(() => LLMTranslateOpenDictionary(text), -1)
    } else if messageType = "openSettings" {
        SetTimer(() => SettingsShow("translate"), -1)
    }
}

LLMTranslateOpenDictionary(text) {
    LLMTranslateHide()
    DictionaryShowQuery(text)
}

LLMTranslateSetSource(text, startRequest := false) {
    global LLMTranslatePendingSourceLanguage, LLMTranslatePendingTargetLanguage
    global LLMTranslatePendingDirectionManual
    LLMTranslatePendingSourceLanguage := ""
    LLMTranslatePendingTargetLanguage := ""
    LLMTranslatePendingDirectionManual := false
    LLMTranslateInvalidateRequest()
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

LLMTranslateSetDirection(sourceLanguage, targetLanguage, manual := false, fallback := false) {
    LLMTranslateExec("window.setDirection(" . LLMJsonQuote(sourceLanguage) . ","
        . LLMJsonQuote(targetLanguage) . "," . (manual ? "true" : "false") . ","
        . (fallback ? "true" : "false") . ");")
}

LLMTranslatePushLanguage() {
    options := TranslateOptionsSnapshot()
    uiLanguage := LLMUiLanguage()
    DebugLog("translate push language=" . uiLanguage . " ready=" . PanelHostPageReady(LLMTranslateHost))
    payload := Map("uiLanguage", uiLanguage, "translation", options,
        "languageCatalog", TranslateLanguageCatalogSnapshot())
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
    WindowBarApplyPinnedState(LLMTranslateHost, LLMTranslatePinned,
        LLMTranslateVisible, LLMTranslateHide,
        Map("guard", LLMTranslateFocusHideGuard))
}

LLMTranslateApplyNativeWindowMode() {
    global LLMTranslateHost, LLMTranslateNativeWindow
    WindowBarApplyNativeMode(LLMTranslateHost, LLMTranslateNativeWindow)
}

LLMTranslateSetPinnedState(value) {
    global LLMTranslatePinned
    LLMTranslatePinned := !!value
}

LLMTranslateSetNativeState(value) {
    global LLMTranslateNativeWindow
    LLMTranslateNativeWindow := !!value
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


LLMTranslateInvalidateRequest() {
    global LLMTranslateRequestSerial, LLMTranslateActiveRequest
    global LLMTranslateRequestOperation, LLMTranslateRequestRunning
    LLMTranslateRequestSerial += 1
    LLMTranslateActiveRequest := LLMTranslateRequestSerial
    operation := LLMTranslateRequestOperation
    LLMTranslateRequestOperation := 0
    LLMTranslateRequestRunning := false
    if IsObject(operation)
        operation.Cancel()
    return LLMTranslateActiveRequest
}

LLMTranslateStartRequest(requestId) {
    global LLMTranslatePendingText, LLMTranslateRequestRunning
    global LLMTranslateRequestOperation, LLMTranslateStreamAnswer
    global LLMTranslateActiveRequest, LLMTranslatePendingSourceLanguage
    global LLMTranslatePendingTargetLanguage, LLMTranslatePendingDirectionManual
    if requestId != LLMTranslateActiveRequest || LLMTranslateRequestRunning || LLMTranslatePendingText = ""
        return

    LLMTranslateRequestRunning := true
    text := LLMTranslatePendingText
    LLMTranslateSetLoading()
    options := TranslateOptionsSnapshot()
    resolution := TranslateResolveDirection(text, options, LLMTranslatePendingSourceLanguage,
        LLMTranslatePendingTargetLanguage, LLMTranslatePendingDirectionManual)
    if !IsObject(resolution) || resolution["status"] = "error" {
        LLMTranslateSetError(IsObject(resolution) && resolution.Has("message")
            ? resolution["message"] : LLMText("Translation settings are invalid.", "翻译设置无效。"))
        LLMTranslateRequestRunning := false
        return
    }
    LLMTranslateSetDirection(resolution["sourceLanguage"], resolution["targetLanguage"],
        resolution["manual"], resolution["fallback"])
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
    overrides := Map("targetLanguage", resolution["targetLanguage"],
        "sourceLanguage", resolution["sourceLanguage"])
    operation := LLMAsyncOperation()
    LLMTranslateRequestOperation := operation
    try {
        childOperation := provider["translate"].Call(text,
            LLMTranslateStreamDelta.Bind(requestId),
            LLMTranslateStreamFinished.Bind(requestId, operation), overrides)
        if IsObject(childOperation)
            operation.SetCancel(LLMTranslateCancelChild.Bind(childOperation))
        else {
            childOperation := LLMScheduleAsyncCallback(LLMAsyncOperation(),
                LLMTranslateStreamFinished.Bind(requestId, operation), "", false,
                LLMText("The translation request could not be started.", "无法启动翻译请求。"))
            operation.SetCancel(LLMTranslateCancelChild.Bind(childOperation))
        }
    } catch as requestError {
        childOperation := LLMScheduleAsyncCallback(LLMAsyncOperation(),
            LLMTranslateStreamFinished.Bind(requestId, operation), "", false, requestError.Message)
        operation.SetCancel(LLMTranslateCancelChild.Bind(childOperation))
    }
}

LLMTranslateCancelChild(childOperation) {
    childOperation.Cancel()
}

LLMTranslateStartStreaming() {
    LLMTranslateExec("window.startStreaming();")
}

LLMTranslateStreamDelta(requestId, delta) {
    global LLMTranslateStreamAnswer, LLMTranslateActiveRequest
    criticalState := A_IsCritical
    Critical "On"
    try {
        if requestId = LLMTranslateActiveRequest {
            LLMTranslateStreamAnswer .= delta
            LLMTranslateExec("window.appendStreaming(" . LLMJsonQuote(delta) . ");")
        }
    } finally {
        if !criticalState
            Critical "Off"
    }
}

LLMTranslateStreamFinished(requestId, operation, answer, success, errorText) {
    global LLMTranslateRequestRunning, LLMTranslateRequestOperation, LLMTranslateStreamAnswer
    global LLMTranslateActiveRequest
    criticalState := A_IsCritical
    Critical "On"
    try {
        if requestId != LLMTranslateActiveRequest || !operation.Complete()
            return
        LLMTranslateRequestOperation := 0
        if success {
            if answer = ""
                answer := LLMTranslateStreamAnswer
            LLMTranslateSetResult(answer)
        } else {
            LLMTranslateSetError(LLMContextLimitHint(errorText))
        }
        LLMTranslateRequestRunning := false
    } finally {
        if !criticalState
            Critical "Off"
    }
}

; Build the translation-specific messages. Request construction and transport
; are shared by lib\shared\llm.ahk; this module only owns the translation prompt.
TranslateLlmMessages(text, overrides := 0) {
    promptTemplate := ConfigRead("LLMTranslate", "systemPrompt", "")
    targetLanguage := TranslateTargetLanguageName(
        TranslateSettingWith("targetLanguage", "system", overrides))
    systemPrompt := LLMRenderPromptTemplate(promptTemplate,
        Map("targetLanguage", targetLanguage))
    ; Keep a request-scoped target constraint even when a user-provided
    ; template does not contain {{targetLanguage}}.
    systemPrompt .= "`n`nFor this request, output only the translation in " . targetLanguage . "."
    userPrompt := LLMLimitInputText(text, systemPrompt, overrides)
    return [
        Map("role", "system", "content", systemPrompt),
        Map("role", "user", "content", userPrompt)]
}

TranslateLlmStartStream(text, onDelta, onFinished, overrides := 0) {
    messages := TranslateLlmMessages(text, overrides)
    return LLMChatStreamOperation(messages, onDelta, onFinished, overrides)
}

; ---- "llm" provider glue (registered at the bottom of this file) ----

TranslateProviderLlmTranslate(text, onDelta, onFinished, overrides := 0) {
    return TranslateLlmStartStream(text, onDelta, onFinished, overrides)
}

LLMTranslateResize(targetGui, minMax, width, height) {
    global LLMTranslateHost
    PanelHostResize(LLMTranslateHost, minMax)
}

LLMTranslateFocusHideGuard() {
    global SettingsVisible
    return SettingsVisible
}

LLMTranslateHide(*) {
    global LLMTranslateHost, LLMTranslateVisible
    global LLMTranslateRequestOperation, LLMTranslateRequestRunning, LLMTranslateNativeWindow
    LLMTranslateInvalidateRequest()
    LLMTranslateVisible := false
    LLMTranslateNativeWindow := false
    PanelHostHide(LLMTranslateHost)
}

LLMTranslateShutdown(*) {
    global LLMTranslateHost, LLMTranslateVisible
    global LLMTranslateRequestOperation
    LLMTranslateInvalidateRequest()
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
    if !LLMTranslateVisible
        return
    LLMTranslatePushLanguage()
    if !TranslateConfigured() || LLMTranslatePendingText = ""
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
