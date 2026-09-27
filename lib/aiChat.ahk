; AI chat panel (pages\chat.html) and the [QAI] settings section.
;
; [LLM] is the only API configuration shared by translation and QAI. [QAI]
; contains question-answer behavior only. The panel is a multi-turn chat:
; the conversation history is owned by this side, the page only renders what is
; echoed back, and each request sends the system prompt plus recent turns.

global AiChatHost := 0
global AiChatVisible := false
global AiChatPendingQuestion := ""
global AiChatRequestRunning := false
global AiChatStreamId := 0
global AiChatStreamAnswer := ""
global AiChatSeenActive := false  ; the focus monitor grants a grace period
                                  ; until the first activation, so a slow
                                  ; WinActivate cannot flash-hide the panel
global AiChatWindowInitialized := false
global AiChatHistory := []        ; {role, content} maps, without the system prompt

; ---- [QAI] behavior ----------------------------------------------------------

; QAI stores behavior that is specific to the assistant, such as its system
; prompt. All connection and sampling settings live in [LLM].
GetQAISetting(key, defaultValue := "") {
    return ConfigRead("QAI", key, defaultValue)
}

; The assistant prompt is configurable in [QAI] systemPrompt; the default is
; supplied by the installed defaults configuration.
LLMAiSystemPrompt() {
    prompt := Trim(GetQAISetting("systemPrompt", ""))
    return prompt
}

LLMAiHideOnBlur() {
    return GetQAISetting("hideOnBlur", "1") != "0"
}

LLMAiPromptVariables() {
    return Map(
        "uiLanguage", LLMUiLanguage() = "zh" ? "Simplified Chinese" : "English")
}

; Keep at most 50 user/assistant rounds in memory and in the page mirror.
LLMAiMaxHistoryTurns() {
    return 50
}

LLMAiHistoryMessageLimit() {
    return LLMAiMaxHistoryTurns() * 2
}

LLMAiTrimHistory(history) {
    limit := LLMAiHistoryMessageLimit()
    while history.Length > limit
        history.RemoveAt(1)
}

; ---- one chat completion over the shared [LLM] connection ---------------------

LLMAiStartStream(history, onDelta, onFinished, overrides := 0) {
    messages := LLMAiBuildMessages(history, overrides)
    return LLMChatStream(messages, onDelta, onFinished, overrides)
}

LLMAiBuildMessages(history, overrides := 0) {
    ; Cap the context twice: by rounds (the last 50) and by estimated input
    ; tokens. Walk from the newest message backwards and drop whatever no
    ; longer fits; a single oversized message is clipped to half the budget,
    ; keeping its tail where error messages and logs usually put the point.
    systemPrompt := LLMRenderPromptTemplate(LLMAiSystemPrompt(), LLMAiPromptVariables())
    budget := LLMInputTokenBudget(overrides)
    systemTokens := LLMEstimateTokens(systemPrompt) + 4
    messageBudget := budget > 0 ? Max(1, budget - systemTokens) : 0
    clipTokens := messageBudget > 0 ? Max(1, messageBudget // 2) : 0
    start := Max(1, history.Length - LLMAiHistoryMessageLimit() + 1)
    keepFrom := history.Length + 1
    used := 0
    index := history.Length
    while index >= start {
        size := LLMEstimateTokens(history[index]["content"]) + 4
        if messageBudget > 0 && index < history.Length && used + size > messageBudget
            break
        used += size
        keepFrom := index
        index -= 1
    }
    messages := [Map("role", "system", "content", systemPrompt)]
    Loop history.Length - keepFrom + 1 {
        entry := history[keepFrom + A_Index - 1]
        content := entry["content"]
        if clipTokens > 0 && LLMEstimateTokens(content) > clipTokens
            content := "…" . LLMTrimToTokens(content, clipTokens)
        messages.Push(Map("role", entry["role"], "content", content))
    }
    return messages
}

; ---- panel ------------------------------------------------------------------

AiChatShow(question) {
    global AiChatHost, AiChatVisible, AiChatWindowInitialized
    global AiChatPendingQuestion, AiChatSeenActive
    question := Trim(question)
    if question != ""
        AiChatPendingQuestion := question

    AiChatVisible := true
    if !AiChatEnsureWebView() {
        AiChatVisible := false
        return
    }
    aiChatSize := ScreenFitSize(720, 560, 520, 400)
    if AiChatWindowInitialized
        PanelHostShow(AiChatHost, 0, 0, false)
    else {
        PanelHostShow(AiChatHost, aiChatSize[1], aiChatSize[2], true)
        AiChatWindowInitialized := true
    }
    AiChatSeenActive := false
    panelGui := PanelHostGui(AiChatHost)
    if IsObject(panelGui)
        WinActivate("ahk_id " . panelGui.Hwnd)
    ShowSystemCursor()
    AiChatUpdateFocusBehavior()

    if PanelHostPageReady(AiChatHost)
        AiChatAfterReady()
}

; Everything that happens once the page is known to be alive.
AiChatAfterReady() {
    global AiChatPendingQuestion
    AiChatPushLanguage()
    if !LLMSettingsConfigured() {
        SetTimer(() => SettingsShow("llm"), -1)
        return
    }
    if AiChatPendingQuestion != "" {
        question := AiChatPendingQuestion
        AiChatPendingQuestion := ""
        AiChatAsk(question)
    }
}

AiChatEnsureWebView() {
    global AiChatHost
    pagePath := A_ScriptDir . "\pages\chat.html"
    if IsObject(AiChatHost) {
        try {
            PanelHostEnsure(AiChatHost)
            return true
        } catch as existingError {
            PanelHostHide(AiChatHost)
            DebugLog("AI chat webview failed")
            ShowMsg("WebView2 initialization failed: " . existingError.Message, 5000)
            return false
        }
    }

    aiChatSize := ScreenFitSize(720, 560, 520, 400)
    AiChatHost := PanelHostCreate(pagePath, "capslock_p2 AI", Map(
        "guiOptions", "+Resize +MinSize520x400 +MinimizeBox +MaximizeBox +SysMenu",
        "dataPath", A_Temp . "\CapsLockPlusAiChatWebView2",
        "initialShow", "x-32000 y-32000 w" . aiChatSize[1] . " h" . aiChatSize[2] . " NA",
        "callbacks", Map(
            "close", AiChatHide,
            "escape", AiChatHide,
            "resize", AiChatResize,
            "navigation", AiChatNavigationCompleted,
            "message", AiChatWebMessageReceived)))

    try {
        PanelHostEnsure(AiChatHost)
        return true
    } catch as webViewError {
        DebugLog("AI chat webview failed")
        PanelHostHide(AiChatHost)
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

AiChatNavigationCompleted(host, sender, args) {
    global AiChatVisible
    if !PanelHostPageReady(host) {
        AiChatExec("window.setError(" . LLMJsonQuote(LLMText(
            "WebView2 could not load the AI panel.",
            "WebView2 未能加载 AI 面板。")) . ");")
        return
    }
    if AiChatVisible
        AiChatAfterReady()
}

AiChatWebMessageReceived(sender, args) {
    global AiChatHistory
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    messageType := LLMMsgField(msg, "type")
    if messageType = "ask" {
        text := LLMMsgField(msg, "text")
        if text = ""
            return
        SetTimer(() => AiChatAsk(text), -1)
    } else if messageType = "newSession" {
        AiChatHistory := []
        AiChatExec("window.newSession();")
    } else if messageType = "openSettings" {
        SetTimer(() => SettingsShow("llm"), -1)
    } else if messageType = "hide" {
        AiChatHide()
    } else if messageType = "openUrl" {
        ; Links rendered from markdown answers open in the default browser
        ; instead of navigating the panel away.
        url := LLMMsgField(msg, "text")
        if url != ""
            SetTimer(() => QbarOpenUrl(url), -1)
    } else if messageType = "cursorMove" {
        ; WebView2 does not always replay the native cursor after Windows'
        ; mouse-vanish-on-typing behavior. Restore it on an actual page mouse
        ; move, matching the behavior of native edit controls.
        ShowSystemCursor()
    }
}

; Adds the question to the history, mirrors it into the page and starts the
; request on the timer, so the message callback returns immediately.
AiChatAsk(text) {
    global AiChatHistory
    text := Trim(text)
    if text = ""
        return
    AiChatHistory.Push(Map("role", "user", "content", text))
    LLMAiTrimHistory(AiChatHistory)
    AiChatExec("window.appendMessage(" . LLMJsonQuote("user") . "," . LLMJsonQuote(text) . ");")
    AiChatExec("window.trimMessages(" . LLMAiHistoryMessageLimit() . ");")
    AiChatExec("window.setThinking(true);")
    SetTimer(AiChatStartRequest, -1)
}

AiChatStartRequest(*) {
    global AiChatHistory, AiChatRequestRunning, AiChatStreamId, AiChatStreamAnswer
    if AiChatRequestRunning || !AiChatHistory.Length
        return
    AiChatRequestRunning := true
    AiChatStreamAnswer := ""
    AiChatExec("window.startStreamingMessage();")
    try AiChatStreamId := LLMAiStartStream(AiChatHistory, AiChatStreamDelta, AiChatStreamFinished)
    catch as streamError {
        AiChatStreamFinished("", false, streamError.Message)
    }
}

AiChatStreamDelta(delta) {
    global AiChatStreamAnswer
    AiChatStreamAnswer .= delta
    AiChatExec("window.appendStreaming(" . LLMJsonQuote(delta) . ");")
}

AiChatStreamFinished(answer, success, errorText) {
    global AiChatHistory, AiChatRequestRunning, AiChatStreamId, AiChatStreamAnswer
    AiChatStreamId := 0
    if success {
        if answer = ""
            answer := AiChatStreamAnswer
        AiChatHistory.Push(Map("role", "assistant", "content", answer))
        LLMAiTrimHistory(AiChatHistory)
        AiChatExec("window.finishStreamingMessage();window.trimMessages(" . LLMAiHistoryMessageLimit() . ");")
    } else {
        if AiChatHistory.Length && AiChatHistory[AiChatHistory.Length]["role"] = "user"
            AiChatHistory.Pop()
        AiChatExec("window.removeStreamingMessage();window.setError(" . LLMJsonQuote(LLMContextLimitHint(errorText)) . ");")
    }
    AiChatRequestRunning := false
}

AiChatExec(script) {
    global AiChatHost
    PanelHostExecute(AiChatHost, script)
}

AiChatPushLanguage() {
    payload := Map("uiLanguage", LLMUiLanguage())
    AiChatExec("window.onHostSettings(" . JSON.stringify(payload, 0) . ");")
}

AiChatOnSettingsSaved() {
    global AiChatPendingQuestion, AiChatVisible
    AiChatUpdateFocusBehavior()
    if !AiChatVisible || !LLMSettingsConfigured() || AiChatPendingQuestion = ""
        return
    question := AiChatPendingQuestion
    AiChatPendingQuestion := ""
    SetTimer(() => AiChatAsk(question), -1)
}

AiChatUpdateFocusBehavior() {
    global AiChatHost, AiChatVisible
    if !AiChatVisible || !IsObject(AiChatHost)
        return
    if !LLMAiHideOnBlur() {
        PanelHostStopFocusMonitor(AiChatHost)
        return
    }
    PanelHostStartFocusMonitor(AiChatHost, AiChatFocusMonitor)
}

AiChatResize(targetGui, minMax, width, height) {
    global AiChatHost
    PanelHostResize(AiChatHost, minMax)
}

AiChatFocusMonitor(*) {
    global AiChatHost, AiChatVisible, AiChatSeenActive, SettingsVisible
    if !AiChatVisible || !IsObject(PanelHostGui(AiChatHost)) {
        PanelHostStopFocusMonitor(AiChatHost)
        return
    }
    if !LLMAiHideOnBlur() {
        PanelHostStopFocusMonitor(AiChatHost)
        return
    }
    if SettingsVisible {
        return
    }
    if !PanelHostWindowActive(AiChatHost) {
        ; Grace: WinActivate may not have landed within the first tick, and
        ; hiding then would flash the panel away before it is reachable.
        if AiChatSeenActive
            AiChatHide()
        return
    }
    AiChatSeenActive := true
}

AiChatHide(*) {
    global AiChatHost, AiChatVisible
    global AiChatStreamId, AiChatRequestRunning, AiChatHistory
    if AiChatStreamId {
        LLMAbortChatStream(AiChatStreamId)
        AiChatStreamId := 0
        if AiChatHistory.Length && AiChatHistory[AiChatHistory.Length]["role"] = "user"
            AiChatHistory.Pop()
    }
    AiChatRequestRunning := false
    AiChatVisible := false
    PanelHostHide(AiChatHost)
    PanelHostStopFocusMonitor(AiChatHost)
}

AiChatShutdown(*) {
    global AiChatHost, AiChatVisible, AiChatWindowInitialized
    global AiChatStreamId
    if AiChatStreamId {
        LLMAbortChatStream(AiChatStreamId)
        AiChatStreamId := 0
    }
    AiChatVisible := false
    PanelHostDestroy(AiChatHost)
    AiChatHost := 0
    AiChatWindowInitialized := false
}

AiChatIsActive() {
    global AiChatHost
    return PanelHostWindowActive(AiChatHost)
}
