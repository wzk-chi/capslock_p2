; Shared LLM configuration, token estimation, request transport, streaming, and response helpers.
; Translation and AI panels consume this module but own their feature-specific orchestration.

global LLMStreamNextId := 0
global LLMStreamStates := Map()
GetLLMSetting(key, defaultValue := "") {
    return ConfigRead("LLM", key, defaultValue)
}

LLMSettingsConfigured() {
    return Trim(GetLLMSetting("endpoint", "")) != "" && Trim(GetLLMSetting("apiKey", "")) != ""
}

LLMUiLanguage() {
    return IsChineseLanguage() ? "zh" : "en"
}

LLMText(english, chinese) {
    return LLMUiLanguage() = "zh" ? chinese : english
}

LLMSettingWith(key, defaultValue, overrides) {
    if IsObject(overrides) && overrides.Has(key)
        return overrides[key]
    return GetLLMSetting(key, defaultValue)
}

; Render prompt templates stored in the ini files. AHK has no separate
; template engine, so keep the syntax deliberately small and predictable:
; {{name}} is replaced by the matching scalar value in the variables Map.
; Unknown placeholders remain visible, which makes misspelled variables easy
; to spot in the final prompt instead of silently dropping instructions.
LLMRenderPromptTemplate(template, variables := 0) {
    template := String(template)
    if !IsObject(variables)
        return template
    for key, value in variables
        if !IsObject(value)
            template := StrReplace(template, "{{" . key . "}}", String(value))
    return template
}

LLMInputTokenBudget(overrides := 0) {
    value := Trim(LLMSettingWith("maxInputTokens", "", overrides))
    if !RegExMatch(value, "^\d+$") || value + 0 < 1
        return 0
    return value + 0
}

LLMSettingInteger(key, fallback, minimum, maximum, overrides := 0, &valid := false) {
    valid := false
    raw := Trim(String(LLMSettingWith(key, "", overrides)))
    if raw = "" {
        valid := true
        return fallback
    }
    if !RegExMatch(raw, "^\d+$")
        return fallback
    parsedSettingInteger := raw + 0
    if parsedSettingInteger < minimum || parsedSettingInteger > maximum
        return fallback
    valid := true
    return parsedSettingInteger
}

LLMLogErrorKind(errorText, status := 0) {
    if status >= 400
        return "http"
    lower := StrLower(String(errorText))
    if InStr(lower, "timeout")
        return "timeout"
    if InStr(lower, "network") || InStr(lower, "connect")
        return "network"
    if InStr(lower, "decode") || InStr(lower, "parse")
        return "decode"
    return errorText = "" ? "" : "request"
}

LLMEstimateTokens(text) {
    text := String(text)
    if text = ""
        return 0
    cjk := StrLen(RegExReplace(text, "[^\p{Han}]", ""))
    other := StrLen(RegExReplace(text, "\p{Han}", ""))
    return cjk + Ceil(other / 4)
}

LLMTrimToTokens(text, tokenLimit) {
    text := String(text)
    tokenLimit := Max(0, tokenLimit + 0)
    if tokenLimit = 0
        return ""
    if LLMEstimateTokens(text) <= tokenLimit
        return text

    low := 1
    high := StrLen(text)
    best := ""
    while low <= high {
        middle := Floor((low + high) / 2)
        candidate := SubStr(text, -middle)
        if LLMEstimateTokens(candidate) <= tokenLimit {
            best := candidate
            low := middle + 1
        } else {
            high := middle - 1
        }
    }
    return best
}

LLMLimitInputText(text, systemPrompt, overrides := 0) {
    budget := LLMInputTokenBudget(overrides)
    if budget <= 0
        return text
    remaining := Max(1, budget - LLMEstimateTokens(systemPrompt) - 4)
    if LLMEstimateTokens(text) <= remaining
        return text
    return LLMTrimToTokens(text, remaining)
}

LLMMessageParse(message) {
    ; Keep WebView booleans as JSON.true/JSON.false ComValues so numeric 1/0
    ; cannot be mistaken for a boolean by the text compatibility reader.
    try return JSON.Parse(message, true)
    catch
        return Map()
}

LLMMsgField(msg, key) {
    if !IsObject(msg) || !msg.Has(key)
        return ""
    value := msg[key]
    isJsonTrue := false
    isJsonFalse := false
    if Type(value) = "ComValue" {
        try {
            isJsonTrue := value == JSON.true
            isJsonFalse := value == JSON.false
        } catch as boolCheckError {
            isJsonTrue := false
            isJsonFalse := false
        }
    }
    if isJsonTrue
        return "true"
    if isJsonFalse
        return "false"
    if Type(value) = "ComValue"
        return ""
    if IsObject(value)
        return ""
    ; WebView2 form fields are strings. Keep a numeric-looking string such as
    ; "1" as a string instead of comparing it loosely with boolean true.
    if Type(value) = "String"
        return value
    if Type(value) = "Integer" || Type(value) = "Float"
        return String(value)
    return String(value)
}

LLMMsgNumber(msg, key, &ok := false, defaultValue := 0, integerOnly := false) {
    ok := false
    raw := LLMMsgField(msg, key)
    if raw = ""
        return defaultValue
    pattern := integerOnly ? "^-?\d+$" : "^-?(?:\d+\.?\d*|\.\d+)$"
    if !RegExMatch(Trim(raw), pattern)
        return defaultValue
    try parsedNumber := raw + 0
    catch
        return defaultValue
    ok := true
    return parsedNumber
}

LLMMsgBoolean(msg, key, &ok := false, defaultValue := false) {
    ok := false
    raw := StrLower(Trim(LLMMsgField(msg, key)))
    if raw = "true" || raw = "1" {
        ok := true
        return true
    }
    if raw = "false" || raw = "0" {
        ok := true
        return false
    }
    return defaultValue
}

LLMMessageOverrides(msg, keys) {
    result := Map()
    if !IsObject(msg)
        return result
    for key in keys
        if msg.Has(key) && !IsObject(msg[key])
            result[key] := LLMMsgField(msg, key)
    return result
}

LLMResponseParse(bodyText) {
    try parsed := JSON.Parse(bodyText)
    catch
        return 0
    return IsObject(parsed) ? parsed : 0
}

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

LLMStreamDeltaText(data) {
    return LLMStreamDeltaTextParsed(LLMResponseParse(data))
}

LLMStreamDeltaTextParsed(parsed) {
    if !IsObject(parsed)
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

; Describe a JSON payload without recording any field values. This is used only
; when a gateway returns a successful HTTP response that contains no recognized
; content field, so the debug log can distinguish a schema mismatch from an
; empty stream without exposing the prompt or answer.
LLMStreamPayloadShape(data) {
    data := Trim(String(data))
    if data = ""
        return "empty"
    parsed := LLMResponseParse(data)
    if !IsObject(parsed)
        return "nonjson chars=" . StrLen(data)
    shape := "top=" . LLMStreamObjectKeys(parsed)
    if parsed.Has("choices") && IsObject(parsed["choices"]) {
        choiceCount := 0
        for choice in parsed["choices"] {
            choiceCount += 1
            if choiceCount > 1 || !IsObject(choice)
                continue
            shape .= " choice=" . LLMStreamObjectKeys(choice)
            for section in ["delta", "message"] {
                if !choice.Has(section)
                    continue
                part := choice[section]
                shape .= " " . section . "Type=" . Type(part)
                if IsObject(part)
                    shape .= "[" . LLMStreamObjectKeys(part) . "]"
            }
        }
        shape .= " choices=" . choiceCount
    }
    return shape
}

LLMStreamObjectKeys(value) {
    if !IsObject(value)
        return ""
    result := ""
    count := 0
    for key, item in value {
        if count >= 12
            break
        result .= (result = "" ? "" : ",") . String(key) . ":" . Type(item)
        count += 1
    }
    return result
}

LLMStreamFinishReason(parsed) {
    if !IsObject(parsed)
        return ""
    choices := parsed.Has("choices") && IsObject(parsed["choices"]) ? parsed["choices"] : []
    for choice in choices {
        if !IsObject(choice)
            continue
        reason := LLMMsgField(choice, "finish_reason")
        if reason != ""
            return reason
    }
    return ""
}

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

LLMBuildChatBody(model, messages, temperature, thinking, structuredOn := false, stream := false) {
    payload := Map("model", model, "messages", messages)
    if RegExMatch(temperature, "^-?(?:\d+\.?\d*|\.\d+)$")
        payload["temperature"] := temperature + 0
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
                "name", "connection_test",
                "strict", JSON.true,
                "schema", Map(
                    "type", "object",
                    "properties", Map("result", Map("type", "string")),
                    "required", ["result"],
                    "additionalProperties", JSON.false)))
    if stream
        payload["stream"] := JSON.true
    return JSON.stringify(payload, 0)
}

; Build one OpenAI-compatible chat request from the shared [LLM] settings.
; Feature modules provide only their messages and whether a request should use
; the fixed structured response format used by connection checks.
LLMBuildRequest(messages, &endpoint, &headerName, &headerValue, &timeout, &errorText,
    overrides := 0, stream := false, structuredOn := false) {
    errorText := ""
    endpointRaw := Trim(String(LLMSettingWith("endpoint", "", overrides)))
    apiKey := Trim(String(LLMSettingWith("apiKey", "", overrides)))
    model := Trim(String(LLMSettingWith("model", "", overrides)))
    if RegExMatch(endpointRaw . apiKey . model, "[`r`n]") {
        errorText := LLMText("LLM settings contain an invalid line break.",
            "LLM 配置包含非法换行。")
        return ""
    }
    endpoint := LLMNormalizeEndpoint(endpointRaw)
    if endpoint = "" {
        errorText := LLMText(
            "No API endpoint configured. Open Settings.",
            "尚未配置 API 地址，请先在设置里填写。")
        return ""
    }
    if apiKey = "" {
        errorText := LLMText(
            "No API key configured. Open Settings.",
            "尚未配置 API Key，请先在设置里填写。")
        return ""
    }
    temperature := Trim(String(LLMSettingWith("temperature", "", overrides)))
    if temperature != "" && !RegExMatch(temperature, "^-?(?:\d+\.?\d*|\.\d+)$") {
        errorText := LLMText("Temperature must be a number.", "Temperature 必须是数字。")
        return ""
    }
    thinking := StrLower(Trim(String(LLMSettingWith("thinking", "", overrides))))
    if thinking != "" && (thinking != "0" && thinking != "1"
        && thinking != "true" && thinking != "false" && thinking != "on" && thinking != "off") {
        errorText := LLMText("Thinking must be a boolean.", "思考模式必须是布尔值。")
        return ""
    }
    maxInputTokens := Trim(String(LLMSettingWith("maxInputTokens", "", overrides)))
    if maxInputTokens != "" && (!RegExMatch(maxInputTokens, "^\d+$") || maxInputTokens + 0 < 1) {
        errorText := LLMText("Maximum input tokens must be a positive integer.",
            "最大输入 Token 必须是正整数。")
        return ""
    }

    body := LLMBuildChatBody(model, messages,
        temperature,
        thinking,
        structuredOn, stream)
    headerName := Trim(String(LLMSettingWith("apiKeyHeader", "", overrides)))
    if headerName = ""
        headerName := "Authorization"
    prefix := Trim(String(LLMSettingWith("apiKeyPrefix", "", overrides)))
    if RegExMatch(headerName . prefix, "[`r`n]") {
        errorText := LLMText("LLM header settings contain an invalid line break.",
            "LLM 请求头配置包含非法换行。")
        return ""
    }
    headerValue := prefix = "" ? apiKey : prefix . " " . apiKey
    timeoutValid := false
    timeout := LLMSettingInteger("timeout", 30000, 1000, 120000, overrides, &timeoutValid)
    if !timeoutValid {
        errorText := LLMText(
            "The LLM timeout must be an integer from 1000 to 120000 ms.",
            "LLM 超时必须是 1000 到 120000 毫秒之间的整数。")
        return ""
    }
    return body
}

; Async non-streaming completion. This uses the same WinHTTP event sink as
; streaming requests, but accumulates and parses the complete JSON body rather
; than advertising or decoding server-sent events.
LLMChatCompleteAsync(messages, onFinished, overrides := 0, structuredOn := false) {
    body := LLMBuildRequest(messages, &endpoint, &headerName, &headerValue, &timeout,
        &errorText, overrides, false, structuredOn)
    if body = ""
        return LLMScheduleAsyncCallback(LLMAsyncOperation(), onFinished, "", false,
            LLMContextLimitHint(errorText))
    headers := Map("Content-Type", "application/json; charset=utf-8")
    if headerValue != ""
        headers[headerName] := headerValue
    return LLMHttpRequestAsync("POST", endpoint, body, headers, timeout,
        LLMChatCompleteHttpFinished.Bind(onFinished))
}

LLMChatCompleteHttpFinished(onFinished, status, responseText, transportError) {
    success := false
    errorText := ""
    if transportError != "" {
        errorText := LLMText("LLM request failed.", "请求失败。")
    } else if status < 200 || status >= 300 {
        apiError := LLMErrorMessageFrom(responseText)
        errorText := LLMText("LLM API HTTP ", "接口返回 HTTP ") . status
            . (apiError = "" ? "" : ": " . apiError)
    } else {
        success := true
    }
    if !success
        errorText := LLMContextLimitHint(errorText)
    try onFinished.Call(success ? responseText : "", success, errorText)
}

; Streaming variant that returns a cancellable operation and guarantees that
; request-building failures are delivered after this function returns.
LLMChatStreamOperation(messages, onDelta, onFinished, overrides := 0, structuredOn := false) {
    operation := LLMAsyncOperation()
    body := LLMBuildRequest(messages, &endpoint, &headerName, &headerValue, &timeout,
        &errorText, overrides, true, structuredOn)
    if body = ""
        return LLMScheduleAsyncCallback(operation, onFinished, "", false, errorText)
    streamId := LLMStartChatStream(body, endpoint, headerName, headerValue, timeout,
        onDelta, LLMChatStreamOperationFinished.Bind(operation, onFinished), true)
    operation.SetCancel(LLMAbortChatStream.Bind(streamId))
    return operation
}

LLMChatStreamOperationFinished(operation, onFinished, text, success, errorText) {
    if !operation.Complete()
        return
    try onFinished.Call(text, success, errorText)
}

; Generic asynchronous HTTP transport used by non-SSE API clients. The shared
; connection point, callback queue, UTF-8 decoding, timeout and release path
; are the same as LLMChatStream; consumers own only request-specific parsing.
LLMHttpRequestAsync(method, url, body, headers, timeoutMs, onFinished) {
    global LLMStreamNextId, LLMStreamStates
    LLMStreamNextId += 1
    id := LLMStreamNextId
    operation := LLMAsyncOperation(LLMAbortChatStream.Bind(id))
    state := Map(
        "id", id,
        "mode", "http",
        "operation", operation,
        "onHttpFinished", onFinished,
        "eventQueue", [],
        "draining", false,
        "drainScheduled", false,
        "finalizeScheduled", false,
        "dispatchEvents", 0,
        "transportFinished", false,
        "transportError", "",
        "responseBodyBytes", [],
        "status", 0,
        "finished", false,
        "cancelled", false,
        "request", 0,
        "sink", 0,
        "connectionContainer", 0,
        "connectionPoint", 0,
        "connectionCookie", 0
    )
    LLMStreamStates[id] := state
    LLMStartWinHttpTransport(state, method, url, body, headers, timeoutMs, "HTTP")
    return operation
}

LLMStartWinHttpTransport(state, method, url, body, headers, timeoutMs, label) {
    stage := "creating WinHTTP request"
    try {
        request := ComObject("WinHttp.WinHttpRequest.5.1")
        state["request"] := request
        stage := "opening asynchronous request"
        request.Open(method, url, true)
        stage := "creating WinHTTP event sink"
        state["sink"] := LLMWinHttpEventSink(state)
        stage := "connecting WinHTTP events"
        LLMStreamAttachEvents(request, state)
        stage := "setting request timeouts"
        request.SetTimeouts(timeoutMs, timeoutMs, timeoutMs, timeoutMs)
        stage := "setting request headers"
        for name, value in headers
            request.SetRequestHeader(name, value)
        stage := "sending request"
        request.Send(LLMUtf8Bytes(body))
        DebugLog("LLM " . label . " request started id=" . state["id"])
    } catch as requestError {
        DebugLog("LLM " . label . " request setup failed id=" . state["id"] . " stage=" . stage)
        if IsObject(state["request"])
            try state["request"].Abort()
        errorPrefix := label = "stream" ? "LLM stream " : "HTTP "
        LLMStreamQueueEvent(state, Map("kind", "error", "text", errorPrefix . stage . " failed."))
        return false
    }
    return true
}

class LLMAsyncOperation {
    __New(cancelCallback := 0) {
        this.CancelCallback := cancelCallback
        this.Cancelled := false
        this.Completed := false
    }

    IsActive() => !this.Cancelled && !this.Completed

    SetCancel(callback) {
        criticalState := A_IsCritical
        Critical "On"
        cancelNow := false
        if this.Cancelled
            cancelNow := true
        else if !this.Completed
            this.CancelCallback := callback
        if !criticalState
            Critical "Off"
        if cancelNow
            try callback.Call()
    }

    Cancel() {
        criticalState := A_IsCritical
        Critical "On"
        if this.Completed || this.Cancelled {
            if !criticalState
                Critical "Off"
            return false
        }
        this.Cancelled := true
        callback := this.CancelCallback
        this.CancelCallback := 0
        if !criticalState
            Critical "Off"
        if IsObject(callback)
            try callback.Call()
        return true
    }

    Complete() {
        criticalState := A_IsCritical
        Critical "On"
        if this.Completed || this.Cancelled {
            if !criticalState
                Critical "Off"
            return false
        }
        this.Completed := true
        this.CancelCallback := 0
        if !criticalState
            Critical "Off"
        return true
    }
}

LLMScheduleAsyncCallback(operation, callback, args*) {
    SetTimer(LLMInvokeAsyncCallback.Bind(operation, callback, args*), -1)
    return operation
}

LLMInvokeAsyncCallback(operation, callback, args*) {
    if !operation.Complete()
        return
    try callback.Call(args*)
}

; Start an asynchronous streaming chat completion using the same request
; construction and transport as non-streaming calls.
LLMChatStream(messages, onDelta, onFinished, overrides := 0, structuredOn := false) {
    body := LLMBuildRequest(messages, &endpoint, &headerName, &headerValue, &timeout,
        &errorText, overrides, true, structuredOn)
    if body = "" {
        try onFinished.Call("", false, errorText)
        return 0
    }
    return LLMStartChatStream(body, endpoint, headerName, headerValue, timeout,
        onDelta, onFinished)
}

LLMStartChatStream(body, endpoint, authHeaderName, authHeaderValue, timeoutMs, onDelta, onFinished,
    returnIdOnFailure := false) {
    global LLMStreamNextId, LLMStreamStates
    LLMStreamNextId += 1
    id := LLMStreamNextId
    state := Map(
        "id", id,
        "mode", "stream",
        "onDelta", onDelta,
        "onFinished", onFinished,
        "eventQueue", [],
        "draining", false,
        "drainScheduled", false,
        "finalizeScheduled", false,
        "dispatchEvents", 0,
        "transportFinished", false,
        "transportError", "",
        "lineBytes", [],
        "eventData", "",
        "rawBody", "",
        "errorBody", "",
        "text", "",
        "responseBytes", 0,
        "dataCallbacks", 0,
        "decodedLines", 0,
        "lineErrors", 0,
        "skippedBytes", 0,
        "sseEvents", 0,
        "deltaEvents", 0,
        "emptyDeltaEvents", 0,
        "parseErrors", 0,
        "finishReason", "",
        "fallbackUsed", false,
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
    LLMStreamStates[id] := state
    headers := Map(
        "Content-Type", "application/json; charset=utf-8",
        "Accept", "text/event-stream")
    if authHeaderValue != ""
        headers[authHeaderName] := authHeaderValue
    started := LLMStartWinHttpTransport(state, "POST", endpoint, body,
        headers, timeoutMs, "stream")
    return started || returnIdOnFailure ? id : 0
}

LLMAbortChatStream(id) {
    global LLMStreamStates
    if !id || !LLMStreamStates.Has(id)
        return
    state := LLMStreamStates[id]
    if !LLMClaimTerminal(state, true)
        return
    state["eventQueue"] := []
    if state.Has("operation") && IsObject(state["operation"])
        state["operation"].Cancel()
    try state["request"].Abort()
    LLMStreamRelease(state)
}

LLMClaimTerminal(state, cancelled := false) {
    criticalState := A_IsCritical
    Critical "On"
    if state["finished"] || state["cancelled"] {
        if !criticalState
            Critical "Off"
        return false
    }
    state["finished"] := true
    if cancelled
        state["cancelled"] := true
    if !criticalState
        Critical "Off"
    return true
}

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
            DebugLog("LLM event sink QueryInterface")
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
            LLMStreamQueueEvent(sink.State, Map("kind", "start", "status", status + 0))
        }

        OnResponseDataAvailable(interface, data) {
            sink := ObjFromPtrAddRef(pThis)
            bytes := LLMStreamSafeArrayBytes(data)
            if bytes.Length
                LLMStreamQueueEvent(sink.State, Map("kind", "data", "bytes", bytes))
        }

        OnResponseFinished(interface) {
            sink := ObjFromPtrAddRef(pThis)
            LLMStreamQueueEvent(sink.State, Map("kind", "finished"))
        }

        OnError(interface, errorNumber, errorDescription) {
            sink := ObjFromPtrAddRef(pThis)
            if errorDescription
                errorText := StrGet(errorDescription, "UTF-16")
            else
                errorText := "WinHTTP stream error"
            if errorNumber
                errorText := "WinHTTP " . (errorNumber + 0) . ": " . errorText
            DebugLog("LLM stream event error id=" . sink.State["id"])
            LLMStreamQueueEvent(sink.State, Map("kind", "error", "text", errorText))
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
        DebugLog("LLM stream events connected")
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

LLMStreamQueueEvent(state, event) {
    if !IsObject(state) || state["finished"] || state["cancelled"]
        return
    if state["finalizeScheduled"]
        state["finalizeScheduled"] := false
    state["eventQueue"].Push(event)
    LLMStreamScheduleDrain(state)
}

LLMStreamScheduleDrain(state) {
    if state["finished"] || state["cancelled"] || state["draining"] || state["drainScheduled"]
        return
    state["drainScheduled"] := true
    SetTimer(LLMStreamDrain.Bind(state), -1)
}

LLMStreamDrain(state, *) {
    if state["finished"] || state["cancelled"] {
        state["drainScheduled"] := false
        state["eventQueue"] := []
        return
    }
    if state["draining"]
        return
    state["drainScheduled"] := false
    state["draining"] := true
    while state["eventQueue"].Length && !state["finished"] && !state["cancelled"] {
        event := state["eventQueue"].RemoveAt(1)
        state["dispatchEvents"] += 1
        try {
            kind := event["kind"]
            if kind = "start"
                LLMStreamOnResponseStart(state, event["status"])
            else if kind = "data"
                LLMStreamOnData(state, event["bytes"])
            else if kind = "finished" {
                state["transportFinished"] := true
                DebugLog("LLM stream transport finished id=" . state["id"]
                    . " dispatch=" . state["dispatchEvents"])
            } else if kind = "error" {
                state["transportError"] := event["text"]
                if state["mode"] = "http"
                    LLMHttpComplete(state, 0, "", event["text"])
                else
                    LLMStreamComplete(state, false, event["text"])
            }
        } catch as dispatchError {
            DebugLog("LLM stream dispatch failed id=" . state["id"]
                . " dispatch=" . state["dispatchEvents"]
                . " error=" . StrReplace(StrReplace(dispatchError.Message, "`r", " "), "`n", " "))
        }
    }
    state["draining"] := false
    if state["finished"] || state["cancelled"]
        return
    if state["eventQueue"].Length {
        LLMStreamScheduleDrain(state)
        return
    }
    if state["transportFinished"] && !state["finalizeScheduled"] {
        state["finalizeScheduled"] := true
        SetTimer(LLMStreamFinalize.Bind(state), -1)
    }
}

LLMStreamFinalize(state, *) {
    if state["finished"] || state["cancelled"]
        return
    state["finalizeScheduled"] := false
    if state["draining"] || state["eventQueue"].Length {
        LLMStreamScheduleDrain(state)
        return
    }
    if !state["transportFinished"]
        return
    if state["mode"] = "http"
        LLMHttpFinalizeResponse(state)
    else
        LLMStreamFinalizeResponse(state)
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
    if state["mode"] = "http" {
        for byte in data
            if Type(byte) = "Integer" && byte >= 0 && byte <= 255
                state["responseBodyBytes"].Push(byte)
        return
    }
    state["responseBytes"] += data.Length
    state["dataCallbacks"] += 1
    ; data is the plain byte array produced by LLMStreamSafeArrayBytes; its
    ; elements are always plain integers 0-255. Raw ComValues or strings must
    ; never reach lineBytes — NumPut in LLMStreamDecode rejects them with
    ; "Invalid parameter(s)", killing the stream mid-response.
    for byte in data {
        if Type(byte) != "Integer" || byte < 0 || byte > 255 {
            state["skippedBytes"] += 1
            continue
        }
        if byte = 10 {
            line := LLMStreamDecode(state["lineBytes"])
            state["lineBytes"] := []
            state["decodedLines"] += 1
            try LLMStreamLine(state, line)
            catch as lineError {
                state["lineErrors"] += 1
                DebugLog("LLM stream line failed id=" . state["id"]
                    . " lineChars=" . StrLen(line)
                    . " error=" . StrReplace(StrReplace(lineError.Message, "`r", " "), "`n", " "))
            }
        } else if byte != 13 {
            state["lineBytes"].Push(byte)
        }
    }
}

LLMHttpFinalizeResponse(state) {
    if state["finished"] || state["cancelled"]
        return
    responseText := LLMStreamDecode(state["responseBodyBytes"])
    LLMHttpComplete(state, state["status"], responseText, "")
}

LLMHttpComplete(state, status, responseText, transportError) {
    if !LLMClaimTerminal(state)
        return
    ; Cancellation may win after the transport has claimed its terminal event
    ; but before this callback is dispatched. Let the operation arbitrate that
    ; last race so a cancelled request never calls its consumer.
    if IsObject(state["operation"]) && !state["operation"].Complete() {
        state["eventQueue"] := []
        state["finalizeScheduled"] := false
        LLMStreamRelease(state)
        return
    }
    state["eventQueue"] := []
    state["finalizeScheduled"] := false
    callback := state["onHttpFinished"]
    id := state["id"]
    DebugLog("LLM HTTP request completed id=" . id . " status=" . status
        . " bytes=" . state["responseBodyBytes"].Length
        . " errorKind=" . LLMLogErrorKind(transportError, status))
    LLMStreamRelease(state)
    try callback.Call(status, responseText, transportError)
    catch as callbackError
        DebugLog("LLM HTTP completion callback failed id=" . id)
}

LLMStreamDecode(bytes) {
    if !bytes.Length
        return ""
    rawBuffer := Buffer(bytes.Length + 1, 0)
    for index, byte in bytes {
        offset := index - 1
        if offset < 0 || offset >= rawBuffer.Size {
            continue
        }
        if Type(byte) != "Integer" || byte < 0 || byte > 255
            continue
        try {
            NumPut("UChar", byte, rawBuffer, offset)
        } catch
            continue
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
    state["sseEvents"] += 1
    state["rawBody"] .= data . "`n"
    if data = "[DONE]" {
        state["done"] := true
        return
    }
    if state["status"] < 200 || state["status"] >= 300 {
        state["errorBody"] .= data
        return
    }
    parsed := LLMResponseParse(data)
    if !IsObject(parsed) {
        state["parseErrors"] += 1
        DebugLog("LLM stream SSE JSON parse failed id=" . state["id"]
            . " event=" . state["sseEvents"] . " chars=" . StrLen(data))
        return
    }
    finishReason := LLMStreamFinishReason(parsed)
    if finishReason != ""
        state["finishReason"] := finishReason
    delta := LLMStreamDeltaTextParsed(parsed)
    if delta != "" {
        state["deltaEvents"] += 1
        state["text"] .= delta
        try state["onDelta"].Call(delta)
        catch
            return
    } else {
        state["emptyDeltaEvents"] += 1
        DebugLog("LLM stream empty event id=" . state["id"]
            . " event=" . state["sseEvents"]
            . " shape=" . LLMStreamPayloadShape(data))
    }
}

LLMStreamFinalizeResponse(state) {
    if state["finished"] || state["cancelled"]
        return
    if state["lineBytes"].Length {
        line := LLMStreamDecode(state["lineBytes"])
        state["lineBytes"] := []
        state["decodedLines"] += 1
        try LLMStreamLine(state, line)
        catch as lineError {
            state["lineErrors"] += 1
            DebugLog("LLM stream final line failed id=" . state["id"]
                . " lineChars=" . StrLen(line)
                . " error=" . StrReplace(StrReplace(lineError.Message, "`r", " "), "`n", " "))
        }
    }
    if state["eventData"] != "" {
        data := state["eventData"]
        state["eventData"] := ""
        try LLMStreamEvent(state, data)
        catch as eventError {
            state["lineErrors"] += 1
            DebugLog("LLM stream final event failed id=" . state["id"]
                . " eventChars=" . StrLen(data)
                . " error=" . StrReplace(StrReplace(eventError.Message, "`r", " "), "`n", " "))
        }
    }
    DebugLog("LLM stream payload id=" . state["id"]
        . " dispatch=" . state["dispatchEvents"]
        . " callbacks=" . state["dataCallbacks"]
        . " bytes=" . state["responseBytes"]
        . " lines=" . state["decodedLines"]
        . " lineErrors=" . state["lineErrors"]
        . " skippedBytes=" . state["skippedBytes"]
        . " events=" . state["sseEvents"]
        . " deltaEvents=" . state["deltaEvents"]
        . " emptyDelta=" . state["emptyDeltaEvents"]
        . " parseErrors=" . state["parseErrors"]
        . " rawChars=" . StrLen(state["rawBody"])
        . " parsedChars=" . StrLen(state["text"])
        . " done=" . state["done"]
        . " finishReason=" . state["finishReason"])
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
            state["fallbackUsed"] := true
            state["text"] := fallback
            try state["onDelta"].Call(fallback)
        }
    }
    if state["text"] = "" {
        DebugLog("LLM stream no content id=" . state["id"]
            . " bodyShape=" . LLMStreamPayloadShape(state["rawBody"]))
        LLMStreamComplete(state, false, "The streaming response did not contain content.")
    } else if !state["done"] && state["finishReason"] = "" && !state["fallbackUsed"] {
        DebugLog("LLM stream incomplete id=" . state["id"]
            . " chars=" . StrLen(state["text"]))
        LLMStreamComplete(state, false, LLMText(
            "The streaming response ended before a completion marker.",
            "流式响应在收到完成标记前结束。"))
    } else
        LLMStreamComplete(state, true, "")
}

LLMStreamComplete(state, success, errorText) {
    if !LLMClaimTerminal(state)
        return
    state["eventQueue"] := []
    state["finalizeScheduled"] := false
    text := state["text"]
    callback := state["onFinished"]
    DebugLog("LLM stream completed id=" . state["id"] . " success=" . success
        . " chars=" . StrLen(text) . " finishReason=" . state["finishReason"]
        . " errorKind=" . LLMLogErrorKind(errorText, state["status"])
        . " errorLength=" . StrLen(String(errorText)))
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

LLMUtf8Bytes(text) {
    byteCount := StrPut(text, "UTF-8") - 1
    byteBuffer := Buffer(byteCount + 1, 0)
    StrPut(text, byteBuffer, "UTF-8")
    bytes := ComObjArray(0x11, byteCount)
    Loop byteCount
        bytes[A_Index - 1] := NumGet(byteBuffer, A_Index - 1, "UChar")
    return bytes
}

LLMExtractChatText(responseText, structuredKey := "") {
    ; A structured connection check may return JSON inside the message content.
    ; If the gateway ignores response_format, the plain content remains valid.
    if structuredKey != "" {
        content := LLMResponseContent(responseText)
        if content != "" {
            inner := LLMMsgField(LLMMessageParse(content), structuredKey)
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

LLMJsonQuote(value) {
    return IsObject(value) ? JSON.stringify(value, 0)
        : SubStr(JSON.stringify([String(value)], 0), 2, -1)
}
