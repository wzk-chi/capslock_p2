; AI chat panel (pages\chat.html) and the [QAI] settings section.
;
; [LLM] is the only API configuration shared by translation and QAI. [QAI]
; contains question-answer behavior only. The panel is a multi-turn chat:
; the conversation history is owned by this side, the page only renders what is
; echoed back, and each request sends the system prompt plus recent turns.

global AiChatHost := 0
global AiChatVisible := false
global AiChatHiddenByFocus := false
global AiChatPendingQuestion := ""
global AiChatRequestRunning := false
global AiChatStreamId := 0
global AiChatStreamAnswer := ""
global AiChatRequestSerial := 0
global AiChatActiveRequest := 0
global AiChatStreamDeltaSerial := 0
global AiChatPinned := false
global AiChatWindowInitialized := false
global AiChatHistory := []        ; complete turns plus the active question
global AiChatActiveSessionId := 0
global AiChatActiveSessionTitle := "新对话"
global AiChatActiveTurnId := 0
global AiChatActiveQuestion := ""
global AiChatActiveNeedsTitle := false
global AiChatViewGeneration := 0
global AiChatPageStateGeneration := -1
global AiChatCheckpointScheduled := false
global AiChatLastPersistedAnswerLength := 0
global AiChatPendingAnswerSaves := Map()
global AiChatTitleQueue := []
global AiChatTitleRequestSerial := 0
global AiChatTitleActiveRequest := 0
global AiChatTitleStreamId := 0
global AiChatTitleSessionId := 0
global AiChatTitleAnswer := ""
global AiChatTitleRunning := false

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

LLMAiTrimCompletedTurnsForNextQuestion(history) {
    limit := LLMAiHistoryMessageLimit()
    while history.Length > limit - 2 {
        if history.Length >= 2 {
            history.RemoveAt(1)
            history.RemoveAt(1)
        } else {
            history.RemoveAt(1)
        }
    }
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
    global AiChatPendingQuestion, AiChatHiddenByFocus
    wasVisible := AiChatVisible
    question := Trim(question)
    if question != ""
        AiChatPendingQuestion := question

    if !wasVisible && (!AiChatHiddenByFocus || question != "")
        AiChatStartNewSession(false)
    AiChatVisible := true
    if !AiChatEnsureWebView() {
        AiChatVisible := false
        return
    }
    AiChatHiddenByFocus := false
    aiChatSize := ScreenFitSize(720, 560, 520, 400)
    if AiChatWindowInitialized
        PanelHostShow(AiChatHost, 0, 0, false)
    else {
        PanelHostShow(AiChatHost, aiChatSize[1], aiChatSize[2], true)
        AiChatWindowInitialized := true
    }
    panelGui := PanelHostGui(AiChatHost)
    if IsObject(panelGui)
        WinActivate("ahk_id " . panelGui.Hwnd)
    WindowBarApplyNativeMode(AiChatHost, WindowBarIsNative(AiChatHost))
    AiChatApplyWindowState()

    if PanelHostPageReady(AiChatHost)
        AiChatAfterReady()
    return true
}

; Everything that happens once the page is known to be alive.
AiChatAfterReady() {
    global AiChatPendingQuestion, AiChatPageStateGeneration, AiChatViewGeneration
    if AiChatPageStateGeneration != AiChatViewGeneration {
        AiChatPushLanguage()
        AiChatSetPinned()
        AiChatPublishPageState()
    }
    if AiChatPendingQuestion != "" {
        question := AiChatPendingQuestion
        AiChatPendingQuestion := ""
        if LLMSettingsConfigured()
            AiChatAsk(question)
        else {
            AiChatPendingQuestion := question
            AiChatOpenSettingsForMissingConfig(false)
        }
    }
}

AiChatOpenSettingsForMissingConfig(hidePanel := true) {
    global AiChatPendingQuestion
    if hidePanel {
        AiChatPendingQuestion := ""
        AiChatHide()
    }
    message := LLMText(
        "Configure an LLM API before using AI Q&A.",
        "请先配置LLM API再使用AI问答功能")
    SetTimer(SettingsShow.Bind("llm", message), -1)
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
        "guiOptions", "+Resize +MinSize520x400 +MinimizeBox +MaximizeBox +SysMenu +ToolWindow -Caption",
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
    global AiChatVisible, AiChatActiveTurnId, AiChatViewGeneration
    if !PanelHostPageReady(host) {
        AiChatExec("window.setError(" . LLMJsonQuote(LLMText(
            "WebView2 could not load the AI panel.",
            "WebView2 未能加载 AI 面板。")) . ");")
        return
    }
    if AiChatActiveTurnId
        AiChatInvalidateRequest("interrupted", true, true)
    AiChatViewGeneration += 1
    if AiChatVisible
        WindowBarSyncPageState(host)
    if AiChatVisible
        AiChatAfterReady()
}

AiChatWebMessageReceived(sender, args) {
    global AiChatHost, AiChatPinned, AiChatActiveSessionId
    global AiChatPendingQuestion, AiChatViewGeneration
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    messageType := LLMMsgField(msg, "type")
    if WindowBarHandleDebugMessage(msg, "ai")
        return
    if WindowBarHandleMessage(AiChatHost, messageType, AiChatHide,
        AiChatSetPinnedState, Map("autoHideCallback", AiChatHideOnBlur))
        return
    if messageType = "streamDebug" {
        rawValid := false
        rawLength := LLMMsgNumber(msg, "rawLength", &rawValid, -1, true)
        renderedValid := false
        renderedLength := LLMMsgNumber(msg, "renderedLength", &renderedValid, -1, true)
        rawText := rawValid ? String(rawLength) : "invalid"
        renderedText := renderedValid ? String(renderedLength) : "invalid"
        DebugLog("AI page stream request=" . LLMMsgField(msg, "requestId")
            . " phase=" . LLMMsgField(msg, "phase")
            . " rawChars=" . rawText . " renderedChars=" . renderedText)
        return
    }
    if !AiChatMessageViewCurrent(msg)
        return
    if messageType = "ask" {
        text := LLMMsgField(msg, "text")
        rawSessionId := Trim(LLMMsgField(msg, "sessionId"))
        sessionValid := rawSessionId = "0"
        sessionId := 0
        if !sessionValid
            sessionValid := AiChatStoreParseId(rawSessionId, &sessionId)
        if text = "" || !sessionValid || sessionId != AiChatActiveSessionId
            return
        SetTimer(AiChatAsk.Bind(text, sessionId, AiChatViewGeneration), -1)
    } else if messageType = "newSession" {
        AiChatPendingQuestion := ""
        SetTimer(AiChatStartNewSession, -1)
    } else if messageType = "listSessions" {
        offsetValid := false
        offset := LLMMsgNumber(msg, "offset", &offsetValid, 0, true)
        AiChatPublishSessionPage(offsetValid && offset >= 0 && offset <= 1000000000 ? Integer(offset) : 0)
    } else if messageType = "loadSession" {
        idValid := AiChatStoreParseId(LLMMsgField(msg, "sessionId"), &sessionId)
        if idValid
            SetTimer(AiChatLoadSession.Bind(sessionId, AiChatViewGeneration), -1)
    } else if messageType = "loadOlderMessages" {
        sessionValid := AiChatStoreParseId(LLMMsgField(msg, "sessionId"), &sessionId)
        beforeValid := AiChatStoreParseId(LLMMsgField(msg, "beforeOrdinal"), &beforeOrdinal)
        if sessionValid && beforeValid && sessionId = AiChatActiveSessionId
            AiChatPublishOlderMessages(sessionId, beforeOrdinal)
    } else if messageType = "renameSession" {
        idValid := AiChatStoreParseId(LLMMsgField(msg, "sessionId"), &sessionId)
        title := Trim(LLMMsgField(msg, "title"))
        if idValid && title != ""
            AiChatRenameSession(sessionId, title)
    } else if messageType = "pinSession" {
        pinnedValid := false
        idValid := AiChatStoreParseId(LLMMsgField(msg, "sessionId"), &sessionId)
        pinned := LLMMsgBoolean(msg, "pinned", &pinnedValid)
        if idValid && pinnedValid
            AiChatPinSession(sessionId, pinned)
    } else if messageType = "deleteSessions" {
        sessionIds := IsObject(msg) && msg.Has("sessionIds") ? msg["sessionIds"] : 0
        if Type(sessionIds) = "Array"
            AiChatDeleteSessions(sessionIds)
    } else if messageType = "retrySaveAnswer" {
        turnValid := AiChatStoreParseId(LLMMsgField(msg, "turnId"), &turnId)
        if turnValid
            AiChatRetrySaveAnswer(turnId)
    } else if messageType = "openSettings" {
        SetTimer(() => SettingsShow("llm"), -1)
    } else if messageType = "openUrl" {
        ; Links rendered from markdown answers open in the default browser
        ; instead of navigating the panel away.
        url := LLMMsgField(msg, "text")
        if url != ""
            SetTimer(QbarOpenUrl.Bind(url), -1)
    }
}

AiChatMessageViewCurrent(msg) {
    global AiChatViewGeneration
    valid := false
    generation := LLMMsgNumber(msg, "viewGeneration", &valid, 0, true)
    return valid && generation = AiChatViewGeneration
}

AiChatInvalidateRequest(status := "interrupted", persist := true, scheduleTitle := true) {
    global AiChatRequestSerial, AiChatActiveRequest, AiChatStreamId
    global AiChatRequestRunning, AiChatStreamAnswer, AiChatHistory
    global AiChatActiveSessionId, AiChatActiveTurnId, AiChatActiveQuestion
    global AiChatActiveNeedsTitle, AiChatCheckpointScheduled
    global AiChatLastPersistedAnswerLength
    if !AiChatActiveTurnId {
        AiChatRequestSerial += 1
        AiChatActiveRequest := 0
        if AiChatStreamId {
            LLMAbortChatStream(AiChatStreamId)
            AiChatStreamId := 0
        }
        AiChatRequestRunning := false
        AiChatStreamAnswer := ""
        AiChatCheckpointScheduled := false
        AiChatLastPersistedAnswerLength := 0
        return
    }

    sessionId := AiChatActiveSessionId
    turnId := AiChatActiveTurnId
    question := AiChatActiveQuestion
    answer := AiChatStreamAnswer
    needsTitle := AiChatActiveNeedsTitle
    AiChatRequestSerial += 1
    AiChatActiveRequest := 0
    if AiChatStreamId {
        LLMAbortChatStream(AiChatStreamId)
        AiChatStreamId := 0
    }
    if persist && sessionId && turnId
        if !AiChatStoreSaveAnswer(sessionId, turnId, answer, status, true)
            AiChatRememberPendingSave(sessionId, turnId, answer, status)
    if AiChatHistory.Length && AiChatHistory[AiChatHistory.Length]["role"] = "user"
        AiChatHistory.Pop()
    AiChatRequestRunning := false
    AiChatStreamAnswer := ""
    AiChatActiveTurnId := 0
    AiChatActiveQuestion := ""
    AiChatActiveNeedsTitle := false
    AiChatCheckpointScheduled := false
    AiChatLastPersistedAnswerLength := 0
    if needsTitle && scheduleTitle
        AiChatQueueTitle(sessionId, question)
}

; Persist the submitted turn before calling the LLM. The page callback returns
; immediately; the network stream starts on the timer.
AiChatAsk(text, expectedSessionId := -1, expectedGeneration := -1) {
    global AiChatHistory, AiChatRequestRunning, AiChatActiveSessionId
    global AiChatActiveSessionTitle, AiChatActiveTurnId, AiChatActiveQuestion
    global AiChatActiveNeedsTitle, AiChatViewGeneration, AiChatStoreError, AiChatRequestSerial
    text := Trim(text)
    if text = ""
        return
    if (expectedGeneration >= 0
        && (expectedGeneration != AiChatViewGeneration || expectedSessionId != AiChatActiveSessionId)) {
        AiChatPageCall("restoreInput", Map("text", text))
        AiChatPageCall("showStorageError", Map("message", LLMText(
            "The chat changed before the question was sent. Review it and send again.",
            "会话已切换，问题尚未发送。请检查后重新发送。")))
        return false
    }
    if AiChatRequestRunning {
        AiChatPageCall("restoreInput", Map("text", text))
        return
    }

    if !LLMSettingsConfigured() {
        AiChatPageCall("restoreInput", Map("text", text))
        AiChatPageCall("showStorageError", Map("message", LLMText(
            "Configure an LLM API before sending a question.",
            "请先配置 LLM API，再发送问题。")))
        SetTimer(SettingsShow.Bind("llm"), -1)
        return
    }

    fallbackTitle := AiChatTitleFallback(text)
    firstTurn := false
    if !AiChatStoreBeginTurn(AiChatActiveSessionId, fallbackTitle, text,
        &sessionId, &turnId, &firstTurn) {
        AiChatPageCall("restoreInput", Map("text", text))
        AiChatPageCall("showStorageError", Map("message", AiChatFriendlyStoreError()))
        DebugLog("AI chat turn save refused before request")
        return
    }

    AiChatActiveSessionId := sessionId
    AiChatActiveTurnId := turnId
    AiChatActiveQuestion := text
    AiChatActiveNeedsTitle := firstTurn
    if firstTurn
        AiChatActiveSessionTitle := fallbackTitle
    AiChatPublishSessionPage(0)
    LLMAiTrimCompletedTurnsForNextQuestion(AiChatHistory)
    AiChatHistory.Push(Map("role", "user", "content", text))
    AiChatRequestRunning := true
    AiChatPageCall("appendUserQuestion", Map(
        "text", text,
        "title", AiChatActiveSessionTitle,
        "sessionId", sessionId,
        "turnId", turnId,
        "requestId", AiChatRequestSerial + 1,
        "viewGeneration", AiChatViewGeneration))
    SetTimer(AiChatStartRequest.Bind(sessionId, turnId, AiChatViewGeneration), -1)
}

AiChatStartRequest(expectedSessionId, expectedTurnId, expectedGeneration) {
    global AiChatHistory, AiChatRequestRunning, AiChatStreamId, AiChatStreamAnswer
    global AiChatRequestSerial, AiChatActiveRequest, AiChatStreamDeltaSerial, AiChatActiveTurnId
    global AiChatActiveSessionId, AiChatViewGeneration, AiChatLastPersistedAnswerLength
    if (expectedGeneration != AiChatViewGeneration
        || expectedSessionId != AiChatActiveSessionId
        || expectedTurnId != AiChatActiveTurnId
        || !AiChatRequestRunning || !AiChatHistory.Length)
        return
    AiChatRequestSerial += 1
    requestId := AiChatRequestSerial
    AiChatActiveRequest := requestId
    AiChatStreamDeltaSerial := 0
    AiChatStreamAnswer := ""
    AiChatLastPersistedAnswerLength := 0
    AiChatPageCall("startStreamingMessage", Map(
        "requestId", requestId,
        "turnId", AiChatActiveTurnId,
        "viewGeneration", AiChatViewGeneration))
    try AiChatStreamId := LLMAiStartStream(AiChatHistory,
        AiChatStreamDelta.Bind(requestId), AiChatStreamFinished.Bind(requestId))
    catch as streamError {
        AiChatStreamFinished(requestId, "", false, streamError.Message)
    }
}

AiChatStreamDelta(requestId, delta) {
    global AiChatActiveRequest, AiChatStreamAnswer, AiChatStreamDeltaSerial
    global AiChatActiveTurnId, AiChatCheckpointScheduled
    if requestId != AiChatActiveRequest
        return
    AiChatStreamAnswer .= delta
    AiChatStreamDeltaSerial += 1
    if !AiChatExec("window.appendStreaming(" . LLMJsonQuote(requestId) . ","
        . AiChatStreamDeltaSerial . "," . LLMJsonQuote(delta) . ");")
        DebugLog("AI page stream append rejected request=" . requestId
            . " sequence=" . AiChatStreamDeltaSerial
            . " totalChars=" . StrLen(AiChatStreamAnswer))
    if !AiChatCheckpointScheduled && AiChatActiveTurnId {
        AiChatCheckpointScheduled := true
        SetTimer(AiChatCheckpointRequest.Bind(requestId, AiChatActiveTurnId), -1000)
    }
}

AiChatCheckpointRequest(requestId, turnId) {
    global AiChatActiveRequest, AiChatActiveSessionId, AiChatActiveTurnId
    global AiChatRequestRunning, AiChatCheckpointScheduled, AiChatStreamAnswer
    global AiChatLastPersistedAnswerLength
    if requestId != AiChatActiveRequest || turnId != AiChatActiveTurnId || !AiChatRequestRunning
        return
    AiChatCheckpointScheduled := false
    length := StrLen(AiChatStreamAnswer)
    if length > AiChatLastPersistedAnswerLength {
        if AiChatStoreSaveAnswer(AiChatActiveSessionId, turnId, AiChatStreamAnswer, "generating", false)
            AiChatLastPersistedAnswerLength := length
    }
    if StrLen(AiChatStreamAnswer) > AiChatLastPersistedAnswerLength && !AiChatCheckpointScheduled {
        AiChatCheckpointScheduled := true
        SetTimer(AiChatCheckpointRequest.Bind(requestId, turnId), -1000)
    }
}

AiChatStreamFinished(requestId, answer, success, errorText) {
    global AiChatHistory, AiChatRequestRunning, AiChatStreamId, AiChatStreamAnswer
    global AiChatActiveRequest, AiChatActiveSessionId, AiChatActiveTurnId
    global AiChatActiveQuestion, AiChatActiveNeedsTitle, AiChatCheckpointScheduled
    global AiChatLastPersistedAnswerLength, AiChatPendingAnswerSaves
    global AiChatViewGeneration
    if requestId != AiChatActiveRequest
        return
    sessionId := AiChatActiveSessionId
    turnId := AiChatActiveTurnId
    question := AiChatActiveQuestion
    needsTitle := AiChatActiveNeedsTitle
    AiChatStreamId := 0
    AiChatActiveRequest := 0
    AiChatRequestRunning := false
    AiChatCheckpointScheduled := false
    DebugLog("AI stream finished request=" . requestId . " success=" . success
        . " answerChars=" . StrLen(String(answer))
        . " accumulatedChars=" . StrLen(AiChatStreamAnswer))
    if success {
        if answer = ""
            answer := AiChatStreamAnswer
        AiChatHistory.Push(Map("role", "assistant", "content", answer))
        LLMAiTrimHistory(AiChatHistory)
        if !AiChatStoreSaveAnswer(sessionId, turnId, answer, "complete", true)
            AiChatRememberPendingSave(sessionId, turnId, answer, "complete")
        AiChatPageCall("finishStreamingMessage", Map(
            "requestId", requestId, "turnId", turnId, "status", "complete", "answer", answer))
        if AiChatPendingAnswerSaves.Has(turnId)
            AiChatPageCall("showSaveRetry", Map("turnId", turnId,
                "message", LLMText("The answer could not be saved. Check the data folder and retry.",
                    "回答已生成，但保存失败。请检查数据目录后重试。")))
    } else {
        if AiChatHistory.Length && AiChatHistory[AiChatHistory.Length]["role"] = "user"
            AiChatHistory.Pop()
        answer := AiChatStreamAnswer
        if !AiChatStoreSaveAnswer(sessionId, turnId, answer, "failed", true)
            AiChatRememberPendingSave(sessionId, turnId, answer, "failed")
        if answer != ""
            AiChatPageCall("finishStreamingMessage", Map(
                "requestId", requestId, "turnId", turnId, "status", "failed", "answer", answer))
        else
            AiChatPageCall("removeStreamingMessage", Map(
                "requestId", requestId, "turnId", turnId, "status", "failed"))
        AiChatPageCall("showAnswerError", Map(
            "turnId", turnId,
            "message", LLMContextLimitHint(errorText)))
        if AiChatPendingAnswerSaves.Has(turnId)
            AiChatPageCall("showSaveRetry", Map("turnId", turnId,
                "message", LLMText("The question is saved, but its answer status could not be updated.",
                    "问题已保存，但回答状态未能更新。请检查数据目录后重试。")))
    }
    AiChatStreamAnswer := ""
    AiChatActiveTurnId := 0
    AiChatActiveQuestion := ""
    AiChatActiveNeedsTitle := false
    AiChatLastPersistedAnswerLength := 0
    if needsTitle
        AiChatQueueTitle(sessionId, question)
    AiChatPublishSessionPage(0)
}

AiChatPageCall(functionName, payload) {
    if !IsObject(payload)
        return false
    script := "window." . functionName . "(" . JSON.stringify(payload, 0) . ");"
    return AiChatExec(script)
}

AiChatFriendlyStoreError() {
    global AiChatStoreError
    if InStr(StrLower(AiChatStoreError), "newer") || InStr(AiChatStoreError, "较新版本")
        return LLMText(
            "This chat database was created by a newer app version. Update the app before opening it.",
            "会话数据库由较新版本创建，请更新程序后再打开。")
    return LLMText(
        "AI chat history is unavailable. Check that the installation folder is writable, then retry.",
        "AI 会话暂时无法访问。请检查安装目录是否可写，然后重试。")
}

AiChatTitleFallback(question) {
    title := Trim(RegExReplace(String(question), "\s+", " "))
    if StrLen(title) > 36
        title := SubStr(title, 1, 35) . "…"
    return title != "" ? title : LLMText("New chat", "新对话")
}

AiChatPublishPageState() {
    global AiChatActiveSessionId, AiChatActiveSessionTitle, AiChatViewGeneration
    global AiChatPinned, AiChatPendingAnswerSaves, AiChatPageStateGeneration
    storageAvailable := AiChatStoreInit()
    turns := []
    hasOlder := false
    if storageAvailable && AiChatActiveSessionId {
        turns := AiChatStoreReadTurns(AiChatActiveSessionId, 0, 100, &hasOlder)
        if !IsObject(turns) {
            turns := []
            storageAvailable := false
        }
        if IsObject(turns)
            for turn in turns
                if AiChatPendingAnswerSaves.Has(turn["id"]) {
                    pending := AiChatPendingAnswerSaves[turn["id"]]
                    turn["answer"] := pending["answer"]
                    turn["status"] := pending["status"]
                    turn["savePending"] := JSON.true
                }
    }
    state := Map(
        "viewGeneration", AiChatViewGeneration,
        "sessionId", AiChatActiveSessionId,
        "title", AiChatActiveSessionTitle,
        "pinned", AiChatPinned ? JSON.true : JSON.false,
        "uiLanguage", LLMUiLanguage(),
        "turns", turns,
        "hasOlder", hasOlder ? JSON.true : JSON.false,
        "storageAvailable", storageAvailable ? JSON.true : JSON.false,
        "storageMessage", storageAvailable ? "" : AiChatFriendlyStoreError())
    if AiChatPageCall("onHostState", state) {
        AiChatPageStateGeneration := AiChatViewGeneration
        AiChatPublishSessionPage(0)
    }
}

AiChatPublishSessionPage(offset := 0) {
    global AiChatActiveSessionId, AiChatViewGeneration
    offset := Max(0, Integer(offset))
    rows := AiChatStoreListSessions(51, offset)
    if !IsObject(rows) {
        AiChatPageCall("setSessionPage", Map(
            "viewGeneration", AiChatViewGeneration,
            "offset", offset,
            "sessions", [],
            "hasMore", JSON.false,
            "storageAvailable", JSON.false,
            "message", AiChatFriendlyStoreError()))
        return false
    }
    hasMore := rows.Length > 50
    if hasMore
        rows.Pop()
    sessions := []
    for row in rows
        sessions.Push(Map(
            "id", row["id"],
            "title", row["title"],
            "pinned", row["pinned"] ? JSON.true : JSON.false,
            "lastChatAt", row["lastChatAt"],
            "current", Integer(row["id"]) = AiChatActiveSessionId ? JSON.true : JSON.false))
    AiChatPageCall("setSessionPage", Map(
        "viewGeneration", AiChatViewGeneration,
        "offset", offset,
        "sessions", sessions,
        "hasMore", hasMore ? JSON.true : JSON.false,
        "storageAvailable", JSON.true,
        "message", ""))
    return true
}

AiChatPublishOlderMessages(sessionId, beforeOrdinal) {
    global AiChatActiveSessionId, AiChatViewGeneration, AiChatPendingAnswerSaves
    if sessionId != AiChatActiveSessionId
        return false
    turns := AiChatStoreReadTurns(sessionId, beforeOrdinal, 100, &hasOlder)
    if !IsObject(turns) {
        AiChatPageCall("olderMessagesFailed", Map("viewGeneration", AiChatViewGeneration))
        AiChatPageCall("showStorageError", Map("message", AiChatFriendlyStoreError()))
        return false
    }
    for turn in turns
        if AiChatPendingAnswerSaves.Has(turn["id"]) {
            pending := AiChatPendingAnswerSaves[turn["id"]]
            turn["answer"] := pending["answer"]
            turn["status"] := pending["status"]
            turn["savePending"] := JSON.true
        }
    AiChatPageCall("prependSessionTurns", Map(
        "sessionId", sessionId,
        "viewGeneration", AiChatViewGeneration,
        "turns", turns,
        "hasOlder", hasOlder ? JSON.true : JSON.false))
    return true
}

AiChatStartNewSession(*) {
    global AiChatActiveSessionId, AiChatActiveSessionTitle, AiChatHistory
    global AiChatActiveTurnId, AiChatViewGeneration
    AiChatInvalidateRequest("interrupted", true, true)
    AiChatActiveSessionId := 0
    AiChatActiveSessionTitle := LLMText("New chat", "新对话")
    AiChatHistory := []
    AiChatActiveTurnId := 0
    AiChatViewGeneration += 1
    AiChatPublishPageState()
}

AiChatLoadSession(sessionId, expectedGeneration) {
    global AiChatActiveSessionId, AiChatActiveSessionTitle, AiChatHistory
    global AiChatActiveTurnId, AiChatViewGeneration, AiChatStoreError
    if expectedGeneration != AiChatViewGeneration || !AiChatStoreParseId(sessionId, &parsedSessionId)
        return false
    sessionId := parsedSessionId
    AiChatInvalidateRequest("interrupted", true, true)
    session := AiChatStoreGetSession(sessionId)
    if !IsObject(session) {
        if AiChatStoreError != ""
            AiChatPageCall("showStorageError", Map("message", AiChatFriendlyStoreError()))
        else
            AiChatPageCall("showStorageError", Map("message", LLMText(
                "That conversation is no longer available.", "这条会话已不存在。")))
        AiChatPublishPageState()
        return false
    }
    history := AiChatStoreLoadContext(sessionId)
    if AiChatStoreError != "" {
        AiChatPageCall("showStorageError", Map("message", AiChatFriendlyStoreError()))
        AiChatPublishPageState()
        return false
    }
    AiChatActiveSessionId := Integer(sessionId)
    AiChatActiveSessionTitle := session["title"]
    AiChatHistory := history
    AiChatActiveTurnId := 0
    AiChatViewGeneration += 1
    AiChatPublishPageState()
    return true
}

AiChatRenameSession(sessionId, title) {
    global AiChatActiveSessionId, AiChatActiveSessionTitle
    title := Trim(StrReplace(String(title), Chr(0), ""))
    if title = "" || StrLen(title) > 80 {
        AiChatPageCall("showStorageError", Map("message", LLMText(
            "Conversation names must contain 1 to 80 characters.",
            "会话名称需为 1 到 80 个字符。")))
        return false
    }
    if !AiChatStoreRenameSession(sessionId, title) {
        AiChatPageCall("showStorageError", Map("message", AiChatFriendlyStoreError()))
        return false
    }
    if sessionId = AiChatActiveSessionId
        AiChatActiveSessionTitle := title
    AiChatPageCall("updateSessionTitle", Map(
        "sessionId", sessionId,
        "title", title,
        "viewGeneration", AiChatViewGeneration))
    AiChatPublishSessionPage(0)
    return true
}

AiChatPinSession(sessionId, pinned) {
    if !AiChatStoreSetPinned(sessionId, pinned) {
        AiChatPageCall("showStorageError", Map("message", AiChatFriendlyStoreError()))
        return false
    }
    AiChatPublishSessionPage(0)
    return true
}

AiChatDeleteSessions(sessionIds) {
    global AiChatActiveSessionId, AiChatActiveSessionTitle, AiChatHistory
    global AiChatActiveTurnId, AiChatViewGeneration, AiChatPendingAnswerSaves
    global AiChatTitleRunning, AiChatTitleSessionId, AiChatTitleStreamId
    global AiChatTitleActiveRequest, AiChatTitleRequestSerial, AiChatTitleAnswer
    ids := []
    seen := Map()
    for rawId in sessionIds {
        if !AiChatStoreParseId(rawId, &id)
            continue
        if !seen.Has(id) {
            seen[id] := true
            ids.Push(id)
        }
    }
    if !ids.Length
        return false
    deletesCurrent := AiChatActiveSessionId && seen.Has(AiChatActiveSessionId)
    if deletesCurrent
        AiChatInvalidateRequest("interrupted", true, false)
    if !AiChatStoreDeleteSessions(ids) {
        AiChatPageCall("showStorageError", Map("message", AiChatFriendlyStoreError()))
        AiChatPublishPageState()
        return false
    }
    removePending := []
    for turnId, pending in AiChatPendingAnswerSaves
        if seen.Has(pending["sessionId"])
            removePending.Push(turnId)
    for turnId in removePending
        AiChatPendingAnswerSaves.Delete(turnId)
    for id in ids
        AiChatRemoveQueuedTitle(id)
    if AiChatTitleRunning && seen.Has(AiChatTitleSessionId) {
        titleStreamId := AiChatTitleStreamId
        AiChatTitleRequestSerial += 1
        AiChatTitleActiveRequest := 0
        AiChatTitleStreamId := 0
        AiChatTitleSessionId := 0
        AiChatTitleAnswer := ""
        AiChatTitleRunning := false
        if titleStreamId
            LLMAbortChatStream(titleStreamId)
        SetTimer(AiChatStartNextTitle, -1)
    }
    if deletesCurrent {
        AiChatActiveSessionId := 0
        AiChatActiveSessionTitle := LLMText("New chat", "新对话")
        AiChatHistory := []
        AiChatActiveTurnId := 0
        AiChatViewGeneration += 1
        AiChatPageCall("exitMultiSelect", Map("viewGeneration", AiChatViewGeneration))
        AiChatPublishPageState()
    } else
        AiChatPublishSessionPage(0)
    return true
}

AiChatRememberPendingSave(sessionId, turnId, answer, status) {
    global AiChatPendingAnswerSaves
    AiChatPendingAnswerSaves[Integer(turnId)] := Map(
        "sessionId", Integer(sessionId),
        "answer", String(answer),
        "status", String(status))
}

AiChatRetrySaveAnswer(turnId) {
    global AiChatPendingAnswerSaves
    if !AiChatStoreParseId(turnId, &parsedTurnId) || !AiChatPendingAnswerSaves.Has(parsedTurnId)
        return false
    pending := AiChatPendingAnswerSaves[parsedTurnId]
    if !AiChatStoreSaveAnswer(pending["sessionId"], parsedTurnId,
        pending["answer"], pending["status"], false) {
        AiChatPageCall("showStorageError", Map("message", AiChatFriendlyStoreError()))
        return false
    }
    AiChatPendingAnswerSaves.Delete(parsedTurnId)
    AiChatPageCall("hideSaveRetry", Map("turnId", parsedTurnId))
    AiChatPublishSessionPage(0)
    return true
}

AiChatTitlePrompt() {
    return LLMUiLanguage() = "zh"
        ? "请将用户的首个问题概括成简短的会话标题。只输出标题，不加引号或解释，最多 24 个汉字。"
        : "Summarize the user's first question as a short chat title. Return only the title, without quotes or explanation, in at most 8 words."
}

AiChatTitleFallbackQuestion(question, tokenLimit := 240) {
    text := Trim(String(question))
    tokenLimit := Max(16, tokenLimit)
    while StrLen(text) > 1 && LLMEstimateTokens(text) > tokenLimit
        text := SubStr(text, 1, Max(1, StrLen(text) // 2))
    return text
}

AiChatQueueTitle(sessionId, question) {
    global AiChatTitleQueue, AiChatTitleSessionId, AiChatTitleRunning
    if !sessionId || !AiChatStoreInit()
        return
    session := AiChatStoreGetSession(sessionId)
    if !IsObject(session) || session["titleState"] != "pending"
        return
    if AiChatTitleRunning && AiChatTitleSessionId = sessionId
        return
    for queued in AiChatTitleQueue
        if queued["sessionId"] = sessionId
            return
    AiChatTitleQueue.Push(Map("sessionId", Integer(sessionId), "question", String(question)))
    SetTimer(AiChatStartNextTitle, -1)
}

AiChatStartNextTitle(*) {
    global AiChatTitleQueue, AiChatTitleRunning, AiChatTitleRequestSerial
    global AiChatTitleActiveRequest, AiChatTitleSessionId, AiChatTitleAnswer
    global AiChatTitleStreamId
    if AiChatTitleRunning || !AiChatTitleQueue.Length
        return
    item := AiChatTitleQueue.RemoveAt(1)
    sessionId := item["sessionId"]
    session := AiChatStoreGetSession(sessionId)
    if !IsObject(session) || session["titleState"] != "pending" {
        SetTimer(AiChatStartNextTitle, -1)
        return
    }
    prompt := AiChatTitlePrompt()
    overrides := Map("thinking", "false", "temperature", "0.2", "maxInputTokens", "512")
    questionBudget := Max(16, LLMInputTokenBudget(overrides) - LLMEstimateTokens(prompt) - 12)
    question := AiChatTitleFallbackQuestion(item["question"], questionBudget)
    messages := [
        Map("role", "system", "content", prompt),
        Map("role", "user", "content", question)]
    AiChatTitleRequestSerial += 1
    requestId := AiChatTitleRequestSerial
    AiChatTitleActiveRequest := requestId
    AiChatTitleSessionId := sessionId
    AiChatTitleAnswer := ""
    AiChatTitleRunning := true
    try AiChatTitleStreamId := LLMChatStream(messages,
        AiChatTitleDelta.Bind(requestId), AiChatTitleFinished.Bind(requestId, sessionId), overrides)
    catch as titleError {
        DebugLog("AI chat title request setup failed")
        AiChatTitleFinished(requestId, sessionId, "", false, titleError.Message)
    }
}

AiChatTitleDelta(requestId, delta) {
    global AiChatTitleActiveRequest, AiChatTitleAnswer
    if requestId = AiChatTitleActiveRequest
        AiChatTitleAnswer .= delta
}

AiChatNormalizeTitle(value) {
    title := RegExReplace(String(value), "[\r\n\t]+", " ")
    title := StrReplace(title, Chr(96) . Chr(96) . Chr(96), "")
    title := Trim(title, " " . Chr(34) . "'“”‘’")
    title := RegExReplace(title, "(?i)^(?:标题|title)\s*[:：]\s*")
    title := RegExReplace(title, "^#+\s*", "")
    title := Trim(title, " " . Chr(34) . "'“”‘’，。.!！?？:：-")
    if StrLen(title) > 36
        title := SubStr(title, 1, 35) . "…"
    return title
}

AiChatTitleFinished(requestId, sessionId, answer, success, errorText) {
    global AiChatTitleActiveRequest, AiChatTitleRunning, AiChatTitleStreamId
    global AiChatTitleSessionId, AiChatTitleAnswer, AiChatActiveSessionId
    global AiChatActiveSessionTitle, AiChatViewGeneration
    if requestId != AiChatTitleActiveRequest
        return
    AiChatTitleActiveRequest := 0
    AiChatTitleStreamId := 0
    AiChatTitleRunning := false
    if answer = ""
        answer := AiChatTitleAnswer
    title := success ? AiChatNormalizeTitle(answer) : ""
    if title != ""
        AiChatStoreResolveTitle(sessionId, title, true)
    else {
        session := AiChatStoreGetSession(sessionId)
        if IsObject(session)
            AiChatStoreResolveTitle(sessionId, session["title"], false)
    }
    session := AiChatStoreGetSession(sessionId)
    if IsObject(session) {
        if sessionId = AiChatActiveSessionId
            AiChatActiveSessionTitle := session["title"]
        AiChatPageCall("updateSessionTitle", Map(
            "sessionId", sessionId,
            "title", session["title"],
            "viewGeneration", AiChatViewGeneration))
    }
    AiChatTitleSessionId := 0
    AiChatTitleAnswer := ""
    AiChatPublishSessionPage(0)
    SetTimer(AiChatStartNextTitle, -1)
}

AiChatRemoveQueuedTitle(sessionId) {
    global AiChatTitleQueue
    index := AiChatTitleQueue.Length
    while index >= 1 {
        if AiChatTitleQueue[index]["sessionId"] = sessionId
            AiChatTitleQueue.RemoveAt(index)
        index -= 1
    }
}

AiChatExec(script) {
    global AiChatHost
    return PanelHostExecute(AiChatHost, script)
}

AiChatSetPinned() {
    global AiChatPinned
    AiChatExec("window.setPinned(" . (AiChatPinned ? "true" : "false") . ");")
}

AiChatApplyWindowState() {
    global AiChatHost, AiChatPinned, AiChatVisible
    WindowBarApplyPinnedState(AiChatHost, AiChatPinned, AiChatVisible, AiChatHide,
        Map("autoHideCallback", AiChatHideOnBlur))
}

AiChatSetPinnedState(value) {
    global AiChatPinned
    AiChatPinned := !!value
    AiChatPageCall("setPinned", Map("pinned", AiChatPinned ? JSON.true : JSON.false))
}

AiChatPushLanguage() {
    payload := Map("uiLanguage", LLMUiLanguage())
    AiChatExec("window.onHostSettings(" . JSON.stringify(payload, 0) . ");")
}

AiChatOnSettingsSaved() {
    global AiChatPendingQuestion, AiChatVisible, AiChatActiveSessionId, AiChatViewGeneration
    AiChatUpdateFocusBehavior()
    if !AiChatVisible
        return
    AiChatPushLanguage()
    if !LLMSettingsConfigured() || AiChatPendingQuestion = ""
        return
    question := AiChatPendingQuestion
    AiChatPendingQuestion := ""
    SetTimer(AiChatAsk.Bind(question, AiChatActiveSessionId, AiChatViewGeneration), -1)
}

AiChatUpdateFocusBehavior() {
    global AiChatHost, AiChatVisible
    if !AiChatVisible || !IsObject(AiChatHost)
        return
    AiChatApplyWindowState()
}

AiChatResize(targetGui, minMax, width, height) {
    global AiChatHost
    PanelHostResize(AiChatHost, minMax)
}

AiChatHideOnBlur(*) {
    global AiChatHost, AiChatVisible, AiChatHiddenByFocus
    ; Focus loss only hides the UI. Keep the current conversation, draft and
    ; generation alive so an empty reopen resumes the same page.
    AiChatHiddenByFocus := true
    AiChatVisible := false
    PanelHostHide(AiChatHost)
}

AiChatHide(*) {
    global AiChatHost, AiChatVisible, AiChatPendingQuestion, AiChatHiddenByFocus
    AiChatInvalidateRequest("interrupted", true, true)
    AiChatPendingQuestion := ""
    AiChatHiddenByFocus := false
    AiChatVisible := false
    PanelHostHide(AiChatHost)
}

AiChatShutdown(*) {
    global AiChatHost, AiChatVisible, AiChatWindowInitialized
    global AiChatHiddenByFocus
    global AiChatTitleStreamId, AiChatTitleActiveRequest, AiChatTitleRunning
    global AiChatTitleRequestSerial, AiChatTitleSessionId, AiChatTitleAnswer
    global AiChatPendingQuestion
    AiChatInvalidateRequest("interrupted", true, false)
    AiChatPendingQuestion := ""
    AiChatHiddenByFocus := false
    AiChatVisible := false
    titleStreamId := AiChatTitleStreamId
    AiChatTitleRequestSerial += 1
    AiChatTitleActiveRequest := 0
    AiChatTitleStreamId := 0
    AiChatTitleSessionId := 0
    AiChatTitleAnswer := ""
    AiChatTitleRunning := false
    if titleStreamId
        LLMAbortChatStream(titleStreamId)
    AiChatStoreClose()
    PanelHostDestroy(AiChatHost)
    AiChatHost := 0
    AiChatWindowInitialized := false
}

AiChatIsActive() {
    global AiChatHost
    return PanelHostWindowActive(AiChatHost)
}
