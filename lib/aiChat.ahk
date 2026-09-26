; AI chat panel (pages\chat.html) and the [QAI] settings section.
;
; [LLM] is the only API configuration shared by translation and QAI. [QAI]
; contains question-answer behavior only. The panel is a multi-turn chat:
; the conversation history is owned by this side, the page only renders what is
; echoed back, and each request sends the system prompt plus recent turns.

global AiChatGui := 0
global AiChatController := 0
global AiChatWebView := 0
global AiChatPageReady := false
global AiChatVisible := false
global AiChatFocusTimer := false
global AiChatPendingQuestion := ""
global AiChatRequestRunning := false
global AiChatStreamId := 0
global AiChatStreamAnswer := ""
global AiChatSettingsOpen := false
global AiChatSeenActive := false  ; the focus monitor grants a grace period
                                  ; until the first activation, so a slow
                                  ; WinActivate cannot flash-hide the panel
global AiChatHistory := []        ; {role, content} maps, without the system prompt

; ---- [QAI] behavior ----------------------------------------------------------

; QAI stores behavior that is specific to the assistant, such as its system
; prompt. All connection and sampling settings live in [LLM].
GetQAISetting(key, defaultValue := "") {
    global Config
    if Config.Has("QAI") && Config["QAI"].Has(key)
        return Config["QAI"][key]
    return defaultValue
}

; The assistant prompt is configurable in [QAI] systemPrompt; the default is
; supplied by the installed defaults configuration.
LLMAiSystemPrompt() {
    prompt := Trim(GetQAISetting("systemPrompt", ""))
    return prompt
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

; Runs the conversation: system prompt plus the last turns of the history.
; Returns the assistant's reply; success/errorText report the outcome.
LLMAiChatComplete(history, &success := false, &errorText := "", overrides := 0) {
    success := false
    errorText := ""

    messages := LLMAiBuildMessages(history, overrides)
    responseText := LLMChatComplete(messages, &success, &errorText, overrides)
    if !success
        return ""
    answer := LLMExtractChatText(responseText)
    if answer = "" {
        errorText := LLMText("The LLM response did not contain an answer.", "接口返回内容里没有找到回答。")
        return ""
    }
    success := true
    return answer
}

LLMAiStartStream(history, onDelta, onFinished, overrides := 0) {
    messages := LLMAiBuildMessages(history, overrides)
    return LLMChatStream(messages, onDelta, onFinished, overrides)
}

LLMAiBuildMessages(history, overrides := 0) {
    ; Cap the context twice: by rounds (the last 50) and by estimated input
    ; tokens. Walk from the newest message backwards and drop whatever no
    ; longer fits; a single oversized message is clipped to half the budget,
    ; keeping its tail where error messages and logs usually put the point.
    systemPrompt := LLMAiSystemPrompt()
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
    global AiChatGui, AiChatVisible, AiChatPageReady, AiChatFocusTimer
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
    AiChatGui.Show("w" . aiChatSize[1] . " h" . aiChatSize[2] . " Center")
    AiChatSeenActive := false
    WinActivate("ahk_id " . AiChatGui.Hwnd)
    ShowSystemCursor()
    SetTimer(AiChatFocusMonitor, 100)
    AiChatFocusTimer := true

    if AiChatPageReady
        AiChatAfterReady()
}

; Everything that happens once the page is known to be alive.
AiChatAfterReady() {
    global AiChatPendingQuestion
    AiChatPushSettings()
    if !LLMSettingsConfigured() {
        AiChatOpenSettings(true)
        return
    }
    if AiChatPendingQuestion != "" {
        question := AiChatPendingQuestion
        AiChatPendingQuestion := ""
        AiChatAsk(question)
    }
}

AiChatEnsureWebView() {
    global AiChatGui, AiChatController, AiChatWebView, AiChatPageReady
    if IsObject(AiChatGui) && IsObject(AiChatWebView)
        return true

    pagePath := A_ScriptDir . "\pages\chat.html"
    loaderPath := A_ScriptDir . "\WebView2\" . (A_PtrSize = 8 ? "64bit" : "32bit") . "\WebView2Loader.dll"
    if !FileExist(pagePath) {
        ShowMsg("pages\chat.html is missing.", 3500)
        return false
    }
    if !FileExist(loaderPath) {
        ShowMsg("WebView2Loader.dll is missing: " . loaderPath, 5000)
        return false
    }

    if !IsObject(AiChatGui) {
        AiChatGui := Gui("+AlwaysOnTop +Resize +MinSize520x400 +ToolWindow", "capslock_p2 AI")
        AiChatGui.MarginX := 0
        AiChatGui.MarginY := 0
        AiChatGui.OnEvent("Close", AiChatHide)
        AiChatGui.OnEvent("Escape", AiChatHide)
        AiChatGui.OnEvent("Size", AiChatResize)
        aiChatSize := ScreenFitSize(720, 560, 520, 400)
    AiChatGui.Show("w" . aiChatSize[1] . " h" . aiChatSize[2] . " Center")
    }

    try {
        ; A dedicated user data folder keeps this panel's browser process
        ; separate from the translator's, mirroring qbar's isolation.
        dataPath := A_Temp . "\CapsLockPlusAiChatWebView2"
        AiChatController := WebView2.CreateControllerAsync(
            AiChatGui.Hwnd, 0, dataPath, "", loaderPath
        ).await2(15000)
        AiChatController.Fill()
        AiChatWebView := AiChatController.CoreWebView2
        AiChatWebView.add_NavigationCompleted(AiChatNavigationCompleted)
        AiChatWebView.add_WebMessageReceived(AiChatWebMessageReceived)
        AiChatPageReady := false
        pageUrl := "file:///" . StrReplace(pagePath, "\", "/")
        AiChatWebView.Navigate(pageUrl)
        return true
    } catch as webViewError {
        AiChatPageReady := false
        AiChatWebView := 0
        AiChatController := 0
        AiChatGui.Hide()
        ShowMsg("WebView2 initialization failed: " . webViewError.Message, 5000)
        return false
    }
}

AiChatNavigationCompleted(sender, args) {
    global AiChatPageReady, AiChatVisible
    try success := args.IsSuccess
    catch
        success := false
    AiChatPageReady := success
    if !success {
        AiChatExec("window.setError(" . LLMJsonQuote(LLMText(
            "WebView2 could not load the AI panel.",
            "WebView2 未能加载 AI 面板。")) . ");")
        return
    }
    if AiChatVisible
        AiChatAfterReady()
}

AiChatWebMessageReceived(sender, args) {
    global AiChatSettingsOpen, AiChatHistory
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
        SetTimer(SettingsShow, -1)
    } else if messageType = "hide" {
        AiChatHide()
    } else if messageType = "openUrl" {
        ; Links rendered from markdown answers open in the default browser
        ; instead of navigating the panel away.
        url := LLMMsgField(msg, "text")
        if url != ""
            SetTimer(() => QbarOpenUrl(url), -1)
    } else if messageType = "getSettings" {
        AiChatPushSettings()
    } else if messageType = "saveSettings" {
        SetTimer(() => AiChatSaveSettings(message), -1)
    } else if messageType = "testSettings" {
        SetTimer(() => AiChatRunTest(message), -1)
    } else if messageType = "cursorMove" {
        ; WebView2 does not always replay the native cursor after Windows'
        ; mouse-vanish-on-typing behavior. Restore it on an actual page mouse
        ; move, matching the behavior of native edit controls.
        ShowSystemCursor()
    } else if messageType = "settings" {
        ; While the settings view is open the window must survive losing focus.
        AiChatSettingsOpen := LLMMsgField(msg, "text") = "open"
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
    global AiChatWebView, AiChatPageReady
    if !AiChatPageReady || !IsObject(AiChatWebView)
        return
    try AiChatWebView.ExecuteScriptAsync(script)
    catch
        return
}

AiChatPushSettings() {
    global AiChatWebView, AiChatPageReady
    if !AiChatPageReady || !IsObject(AiChatWebView)
        return
    payload := LLMSettingsSnapshot()
    payload["uiLanguage"] := LLMUiLanguage()
    payload["configured"] := LLMSettingsConfigured() ? JSON.true : JSON.false
    try AiChatWebView.ExecuteScriptAsync("window.setSettings(" . JSON.stringify(payload, 0) . ");")
    catch
        return
}

AiChatOpenSettings(firstRun) {
    global AiChatWebView, AiChatPageReady, AiChatSettingsOpen
    if !AiChatPageReady || !IsObject(AiChatWebView)
        return
    AiChatSettingsOpen := true
    try AiChatWebView.ExecuteScriptAsync("window.openSettings(" . (firstRun ? "true" : "false") . ");")
    catch
        return
}

; The chat settings edit the single shared [LLM] configuration.
AiChatSaveSettings(message) {
    msg := LLMMessageParse(message)
    try {
        LLMSaveSettings(msg)
    } catch as saveError {
        AiChatExec("window.setSaved(false," . LLMJsonQuote(LLMText("Save failed: ", "保存失败：") . saveError.Message) . ");")
        return
    }
    ReloadSettings()
    AiChatPushSettings()
    if LLMSettingsConfigured() {
        AiChatExec("window.setSaved(true," . LLMJsonQuote(LLMText("Settings saved.", "设置已保存。")) . ");")
        ; A question that arrived before the API was configured is waiting.
        global AiChatPendingQuestion
        if AiChatPendingQuestion != "" {
            question := AiChatPendingQuestion
            AiChatPendingQuestion := ""
            SetTimer(() => AiChatAsk(question), -1)
        }
    } else {
        AiChatExec("window.setSaved(false," . LLMJsonQuote(LLMText(
            "Saved, but endpoint and API key are still empty.",
            "已保存，但 API 地址和 Key 仍为空。")) . ");")
    }
}

AiChatRunTest(message) {
    global AiChatRequestRunning
    if AiChatRequestRunning {
        AiChatExec("window.setTestResult(false," . LLMJsonQuote(LLMText(
            "Another request is already running.",
            "已有请求正在执行，请稍候。")) . ");")
        return
    }
    AiChatRequestRunning := true
    msg := LLMMessageParse(message)
    overrides := LLMMessageOverrides(msg, [
        "endpoint", "apiKey", "apiKeyHeader", "apiKeyPrefix", "model",
        "temperature", "timeout", "thinking", "maxInputTokens"])
    history := [Map("role", "user", "content", "Hello! This is a capslock_p2 connection test.")]
    try {
        answer := LLMAiChatComplete(history, &ok, &errorText, overrides)
        if ok
            AiChatExec("window.setTestResult(true," . LLMJsonQuote(LLMText("Connection OK → ", "连接正常 → ") . SubStr(answer, 1, 120)) . ");")
        else
            AiChatExec("window.setTestResult(false," . LLMJsonQuote(errorText) . ");")
    } catch as requestError {
        AiChatExec("window.setTestResult(false," . LLMJsonQuote(requestError.Message) . ");")
    } finally {
        AiChatRequestRunning := false
    }
}

AiChatResize(targetGui, minMax, width, height) {
    global AiChatController
    if minMax != -1 && IsObject(AiChatController)
        try AiChatController.Fill()
}

AiChatFocusMonitor(*) {
    global AiChatGui, AiChatVisible, AiChatFocusTimer, AiChatSettingsOpen, AiChatSeenActive
    if !AiChatVisible || !IsObject(AiChatGui) {
        SetTimer(AiChatFocusMonitor, 0)
        AiChatFocusTimer := false
        return
    }
    ; Keep the window while the settings view is open so the user can copy
    ; values from elsewhere (endpoint, key, model) without it disappearing.
    if AiChatSettingsOpen {
        return
    }
    if !WinActive("ahk_id " . AiChatGui.Hwnd) {
        ; Grace: WinActivate may not have landed within the first tick, and
        ; hiding then would flash the panel away before it is reachable.
        if AiChatSeenActive
            AiChatHide()
        return
    }
    AiChatSeenActive := true
}

AiChatHide(*) {
    global AiChatGui, AiChatVisible, AiChatFocusTimer, AiChatPageReady
    global AiChatStreamId, AiChatRequestRunning, AiChatHistory
    if AiChatStreamId {
        LLMAbortChatStream(AiChatStreamId)
        AiChatStreamId := 0
        if AiChatHistory.Length && AiChatHistory[AiChatHistory.Length]["role"] = "user"
            AiChatHistory.Pop()
    }
    AiChatRequestRunning := false
    AiChatVisible := false
    SetTimer(AiChatFocusMonitor, 0)
    AiChatFocusTimer := false
    if IsObject(AiChatGui)
        try AiChatGui.Hide()
}

AiChatShutdown(*) {
    global AiChatGui, AiChatController, AiChatWebView, AiChatVisible, AiChatPageReady
    global AiChatStreamId
    if AiChatStreamId {
        LLMAbortChatStream(AiChatStreamId)
        AiChatStreamId := 0
    }
    AiChatVisible := false
    AiChatPageReady := false
    try AiChatWebView := 0
    try AiChatController := 0
    if IsObject(AiChatGui) {
        try AiChatGui.Destroy()
        AiChatGui := 0
    }
}
