; Settings panel facade: lifecycle, message routing, configuration drafts and save receipts.

global SettingsHost := 0
global SettingsVisible := false
global SettingsPendingPage := "general"
global SettingsPendingToast := ""
global SettingsTestGeneration := 0
global SettingsTestOperation := 0
global SettingsSaving := false

SettingsShow(initialPage := "general", toastMessage := "", *) {
    global SettingsHost, SettingsVisible, SettingsPendingPage, SettingsPendingToast
    initialPage := StrLower(Trim(initialPage))
    SettingsPendingPage := SettingsPageIsAllowed(initialPage) ? initialPage : "general"
    SettingsPendingToast := Trim(String(toastMessage))
    SettingsVisible := true
    if !SettingsEnsureWebView() {
        SettingsTestInvalidate()
        SettingsVisible := false
        return
    }
    ; Keep the native window state (including maximize/minimize) between opens.
    PanelHostShow(SettingsHost, 0, 0, false)
    panelGui := PanelHostGui(SettingsHost)
    if IsObject(panelGui)
        WinActivate("ahk_id " . panelGui.Hwnd)
    if PanelHostPageReady(SettingsHost)
        SetTimer(SettingsPushSnapshot, -1)
    return true
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
            DebugLog("settings webview initialization failed stage=existing errorType="
                . Type(existingError))
            ShowMsg(LLMText(
                "Unable to open Settings. Try again or restart the app.",
                "无法打开设置。请重试或重新启动应用。"), 5000)
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
        DebugLog("settings webview initialization failed stage=create errorType="
            . Type(webViewError))
        PanelHostHide(SettingsHost)
        ShowMsg(LLMText(
            "Unable to open Settings. Try again or restart the app.",
            "无法打开设置。请重试或重新启动应用。"), 5000)
        return false
    }
}

SettingsNavigationCompleted(host, sender, args) {
    global SettingsVisible
    SettingsTestInvalidate()
    SettingsInvalidateEditSession()
    if !PanelHostPageReady(host) {
        ShowMsg(LLMText(
            "The Settings page could not be loaded. Try reopening it.",
            "设置页面无法加载，请重新打开设置。"), 3500)
    } else if SettingsVisible
        SetTimer(SettingsPushSnapshot, -1)
}

SettingsWebMessageReceived(sender, args) {
    global SettingsSaving, SettingsWindowSelectionTokens
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    messageType := LLMMsgField(msg, "type")
    if messageType = "settingsPageError" {
        phase := RegExReplace(LLMMsgField(msg, "phase"), "[^A-Za-z0-9_-]", "")
        errorType := RegExReplace(LLMMsgField(msg, "errorType"), "[^A-Za-z0-9_-]", "")
        line := LLMMsgNumber(msg, "line", &lineValid, 0, true)
        column := LLMMsgNumber(msg, "column", &columnValid, 0, true)
        DiagnosticLogAlways("Settings page error phase=" . SubStr(phase, 1, 40)
            . " errorType=" . SubStr(errorType, 1, 40)
            . " source=settings-page.js line=" . (lineValid ? line : 0)
            . " column=" . (columnValid ? column : 0))
        return
    }
    if SettingsSaving
        return
    if messageType != "getSettings" && messageType != "hide" && !SettingsIsEditMessage(msg) {
        if messageType = "saveSettings" {
            requestId := LLMMsgNumber(msg, "requestId", &validId, 0, true)
            if validId && requestId > 0
                SettingsSendSaved(false, "设置页面已过期，请取消后重新载入。", 0,
                    requestId, LLMMsgField(msg, "sessionId"))
        }
        return
    }
    if messageType = "revealSecret" || messageType = "copySecret"
        SetTimer(SettingsHandleSecretAction.Bind(message), -1)
    else if messageType = "hide"
        SettingsHide()
    else if messageType = "getSettings"
        SetTimer(SettingsPushSnapshot, -1)
    else if messageType = "setSettingsPage"
        SettingsSetPendingPage(LLMMsgField(msg, "page"))
    else if messageType = "saveSettings" {
        SettingsSaving := true
        SettingsStopShortcutCapture()
        SettingsTestInvalidate()
        DebugLog("Settings save message received")
        SetTimer(SettingsApplyDraft.Bind(message), -1)
    }
    else if messageType = "selectHotkeyApplication"
        SetTimer(SettingsSelectHotkeyApplication.Bind(LLMMsgField(msg, "sessionId")), -1)
    else if messageType = "selectHotkeyOpenApplication" {
        DebugLog("Hotkey application picker requested")
        SetTimer(SettingsShowHotkeyApplicationPicker.Bind(LLMMsgField(msg, "sessionId")), -1)
    } else if messageType = "selectHotkeyApplicationPath"
        SetTimer(SettingsSelectHotkeyApplicationPath.Bind(LLMMsgField(msg, "path"), LLMMsgField(msg, "sessionId")), -1)
    else if messageType = "hotkeyPickerTrace" {
        stage := RegExReplace(LLMMsgField(msg, "stage"), "[^A-Za-z0-9_-]", "")
        rowCountValid := false
        rowCount := LLMMsgNumber(msg, "rowCount", &rowCountValid, 0, true)
        indexValid := false
        index := LLMMsgNumber(msg, "index", &indexValid, 0, true)
        DebugLog("Hotkey picker UI stage=" . stage
            . (rowCountValid ? " rows=" . rowCount : "")
            . (indexValid ? " index=" . index : ""))
    }
    else if messageType = "testSettings"
        SettingsStartTest(message)
    else if messageType = "startShortcutRecording"
        SettingsQueueShortcutCapture(message)
    else if messageType = "stopShortcutRecording"
        SettingsStopShortcutCaptureMessage(message)
    else if messageType = "selectOpenWindow"
        SetTimer(SettingsOpenWindowPicker.Bind(message), -1)
    else if messageType = "selectOpenApplication"
        SetTimer(SettingsOpenOpenApplicationPicker.Bind(message), -1)
    else if messageType = "selectOtherApplication"
        SetTimer(SettingsOpenOtherApplicationPicker.Bind(message), -1)
    else if messageType = "selectWindowPicker" {
        indexValid := false
        index := LLMMsgNumber(msg, "index", &indexValid, 0, true)
        if indexValid
            SetTimer(SettingsWindowPickerSelect.Bind(index, LLMMsgField(msg, "sessionId")), -1)
    } else if messageType = "cancelWindowPicker"
        SetTimer(SettingsWindowPickerCancel.Bind(LLMMsgField(msg, "sessionId")), -1)
    else if messageType = "discardSettingsDraft" {
        SettingsInvalidateEditSession()
    } else if messageType = "clearWindowBindingCandidate" {
        slot := WindowBindingNumber(LLMMsgField(msg, "number"), 0)
        SettingsClearWindowCandidate(slot)
    }
}

SettingsHandleSecretAction(message) {
    global SettingsHost, SettingsVisible
    msg := LLMMessageParse(message)
    if !SettingsIsEditMessage(msg)
        return
    action := LLMMsgField(msg, "type")
    requestId := LLMMsgNumber(msg, "requestId", &requestValid, 0, true)
    section := LLMMsgField(msg, "section")
    key := LLMMsgField(msg, "key")
    field := ConfigField(section, key)
    valid := requestValid && requestId > 0
        && (action = "revealSecret" || action = "copySecret")
        && IsObject(field) && field.Has("type") && field["type"] = "secret"
    if !valid {
        if requestValid && requestId > 0
            SettingsSendSecretResult(Map("requestId", requestId, "ok", false), msg)
        return
    }
    if !SettingsVisible || !IsObject(SettingsHost) || !PanelHostPageReady(SettingsHost)
        return

    if action = "revealSecret" {
        if !SettingsStoreReadSecret(section, key, &value) {
            SettingsSendSecretResult(Map("requestId", requestId, "ok", false), msg)
            return
        }
        SettingsSendSecretResult(Map("requestId", requestId, "ok", true, "value", value), msg)
        return
    }

    if msg.Has("value") {
        if Type(msg["value"]) != "String" || StrLen(msg["value"]) > 65536 {
            SettingsSendSecretResult(Map("requestId", requestId, "ok", false), msg)
            return
        }
        value := String(msg["value"])
    } else if !SettingsStoreReadSecret(section, key, &value) {
        SettingsSendSecretResult(Map("requestId", requestId, "ok", false), msg)
        return
    }
    if value = "" || !SettingsCopySecretToClipboard(value) {
        SettingsSendSecretResult(Map("requestId", requestId, "ok", false), msg)
        return
    }
    SettingsSendSecretResult(Map("requestId", requestId, "ok", true), msg)
}

SettingsCopySecretToClipboard(value) {
    global A_Clipboard
    suspendToken := ClipboardSuspendBegin("settings-secret-copy")
    try {
        A_Clipboard := String(value)
        ClipboardHistoryMarkOwnedSequence(ClipboardSequenceNumber(), "settings-secret-copy")
        return true
    } catch {
        return false
    } finally {
        ClipboardSuspendEnd(suspendToken)
    }
}

SettingsPost(messageType, payload := 0) {
    global SettingsHost, SettingsEditSessionId
    if !IsObject(SettingsHost) || !PanelHostPageReady(SettingsHost)
        return false
    if !IsObject(payload)
        payload := Map()
    if !payload.Has("sessionId")
        payload["sessionId"] := SettingsEditSessionId
    try {
        SettingsHost["webView"].PostWebMessageAsJson(JSON.stringify(
            Map("type", messageType, "payload", payload), 0))
        return true
    } catch as deliveryError {
        DiagnosticLogAlways("Settings message delivery failed type=" . messageType
            . " errorType=" . Type(deliveryError))
        return false
    }
}

SettingsSendSecretResult(result, msg) {
    if !SettingsIsEditMessage(msg)
        return
    result["sessionId"] := LLMMsgField(msg, "sessionId")
    SettingsPost("secretResult", result)
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

SettingsStartTest(message) {
    global SettingsTestGeneration, SettingsTestOperation
    SettingsTestGeneration += 1
    generation := SettingsTestGeneration
    previousOperation := SettingsTestOperation
    SettingsTestOperation := 0
    if IsObject(previousOperation)
        previousOperation.Cancel()
    SetTimer(SettingsRunTest.Bind(message, generation), -1)
}

SettingsRunTest(message, generation) {
    global SettingsTestOperation
    if !SettingsTestIsCurrent(generation)
        return
    msg := LLMMessageParse(message)
    target := StrLower(LLMMsgField(msg, "target"))
    if target != "llm" && target != "youdao" && target != "volcengine"
        return
    operation := LLMAsyncOperation()
    SettingsTestOperation := operation
    try {
        if target = "llm" {
            overrides := LLMMessageOverrides(msg, [
                "endpoint", "apiKey", "apiKeyHeader", "apiKeyPrefix", "model",
                "temperature", "timeout", "thinking", "maxInputTokens"])
            childOperation := LLMChatCompleteAsync(
                [Map("role", "user", "content", "Hello! This is a capslock_p2 connection test.")],
                SettingsTestLlmFinished.Bind(generation, operation), overrides)
            SettingsTestAttachChild(operation, childOperation)
        } else {
            provider := TranslateGetProvider(target)
            if !IsObject(provider) || !provider.Has("test") {
                childOperation := LLMScheduleAsyncCallback(LLMAsyncOperation(),
                    SettingsTestComplete.Bind(generation, operation), false,
                    LLMText("Translation test is unavailable.", "翻译测试不可用。"))
                SettingsTestAttachChild(operation, childOperation)
            } else {
                childOperation := provider["test"].Call(msg,
                    SettingsTestProviderFinished.Bind(generation, operation))
                if IsObject(childOperation)
                    SettingsTestAttachChild(operation, childOperation)
                else {
                    childOperation := LLMScheduleAsyncCallback(LLMAsyncOperation(),
                        SettingsTestComplete.Bind(generation, operation), false,
                        LLMText("The connection test could not be started.", "无法启动连接测试。"))
                    SettingsTestAttachChild(operation, childOperation)
                }
            }
        }
    } catch {
        DebugLog("Settings connection test setup failed generation=" . generation)
        childOperation := LLMScheduleAsyncCallback(LLMAsyncOperation(),
            SettingsTestComplete.Bind(generation, operation), false,
            LLMText("The connection test could not be started.", "无法启动连接测试。"))
        SettingsTestAttachChild(operation, childOperation)
    }
}

SettingsTestLlmFinished(generation, operation, responseText, success, errorText) {
    resultText := success ? LLMText("Connection OK", "连接正常") : errorText
    SettingsTestComplete(generation, operation, success, resultText)
}

SettingsTestProviderFinished(generation, operation, success, text) {
    SettingsTestComplete(generation, operation, success, text)
}

SettingsTestComplete(generation, operation, ok, text) {
    global SettingsTestOperation
    criticalState := A_IsCritical
    Critical "On"
    try {
        if !SettingsTestIsCurrent(generation) || !operation.Complete()
            return
        SettingsTestOperation := 0
        SettingsSendTestResult(generation, ok, text)
    } finally {
        if !criticalState
            Critical "Off"
    }
}

SettingsTestAttachChild(operation, childOperation) {
    if IsObject(childOperation)
        operation.SetCancel(SettingsCancelTestChild.Bind(childOperation))
}

SettingsCancelTestChild(childOperation) {
    childOperation.Cancel()
}

SettingsTestIsCurrent(generation) {
    global SettingsTestGeneration, SettingsVisible, SettingsHost
    return generation = SettingsTestGeneration && SettingsVisible
        && IsObject(SettingsHost) && PanelHostPageReady(SettingsHost)
}

SettingsTestInvalidate() {
    global SettingsTestGeneration, SettingsTestOperation
    SettingsTestGeneration += 1
    operation := SettingsTestOperation
    SettingsTestOperation := 0
    if IsObject(operation)
        operation.Cancel()
}

SettingsSendTestResult(generation, ok, text) {
    if SettingsTestIsCurrent(generation)
        SettingsPost("testResult", Map("ok", ok ? JSON.true : JSON.false, "text", text))
}

SettingsResize(targetGui, minMax, width, height) {
    global SettingsHost
    PanelHostResize(SettingsHost, minMax)
}

SettingsRequestClose(*) {
    global SettingsHost, SettingsSaving
    if SettingsSaving
        return true
    if !IsObject(SettingsHost) || !PanelHostPageReady(SettingsHost)
        return true
    SettingsPost("requestClose")
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
    global SettingsHost, SettingsVisible, WindowPickerVisible
    if WindowPickerVisible
        SettingsCloseWindowPicker(false)
    SettingsStopShortcutCapture()
    SettingsTestInvalidate()
    SettingsInvalidateEditSession()
    SettingsVisible := false
    PanelHostHide(SettingsHost)
}

SettingsShutdown(*) {
    global SettingsHost, SettingsVisible, SettingsPendingPage, WindowPickerVisible
    global SettingsWindowSelectionTokens, SettingsSaving
    if WindowPickerVisible
        SettingsCloseWindowPicker(false)
    SettingsStopShortcutCapture()
    SettingsTestInvalidate()
    SettingsInvalidateEditSession()
    SettingsVisible := false
    SettingsSaving := false
    SettingsWindowSelectionTokens := Map()
    SettingsPendingPage := "general"
    PanelHostDestroy(SettingsHost)
    SettingsHost := 0
}
