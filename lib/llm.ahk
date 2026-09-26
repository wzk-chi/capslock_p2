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

LLMLogEndpoint(url) {
    url := Trim(String(url))
    if url = ""
        return "<empty>"
    url := RegExReplace(url, "[#?].*$")
    if RegExMatch(url, "i)^(https?://[^/]+)(/.*)?$", &match)
        return match[1] . match[2]
    return "<configured>"
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
    try return JSON.Parse(message)
    catch
        return Map()
}

LLMMsgField(msg, key) {
    if !IsObject(msg) || !msg.Has(key)
        return ""
    value := msg[key]
    if IsObject(value)
        return ""
    ; WebView2 form fields are strings. Keep a numeric-looking string such as
    ; "1" as a string instead of comparing it loosely with boolean true.
    if Type(value) = "String"
        return value
    return value = true ? "true" : value = false ? "false" : String(value)
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
    endpoint := LLMNormalizeEndpoint(LLMSettingWith("endpoint", "", overrides))
    apiKey := LLMSettingWith("apiKey", "", overrides)
    model := Trim(LLMSettingWith("model", "", overrides))
    if endpoint = "" {
        errorText := LLMText(
            "No API endpoint configured. Open Settings.",
            "尚未配置 API 地址，请先在设置里填写。")
        return ""
    }

    body := LLMBuildChatBody(model, messages,
        LLMSettingWith("temperature", "", overrides),
        StrLower(Trim(LLMSettingWith("thinking", "", overrides))),
        structuredOn, stream)
    headerName := Trim(LLMSettingWith("apiKeyHeader", "", overrides))
    prefix := LLMSettingWith("apiKeyPrefix", "", overrides)
    headerValue := prefix = "" ? apiKey : prefix . " " . apiKey
    timeout := LLMSettingWith("timeout", "", overrides) + 0
    timeout := Max(1000, Min(120000, timeout))
    return body
}

; Execute a non-streaming chat completion. The raw response is returned so the
; caller can extract the field appropriate to its feature.
LLMChatComplete(messages, &success := false, &errorText := "", overrides := 0, structuredOn := false) {
    success := false
    errorText := ""
    body := LLMBuildRequest(messages, &endpoint, &headerName, &headerValue, &timeout,
        &errorText, overrides, false, structuredOn)
    if body = ""
        return ""
    responseText := LLMSendChatBody(body, endpoint, headerName, headerValue, timeout,
        &success, &errorText)
    if !success
        errorText := LLMContextLimitHint(errorText)
    return responseText
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
        DebugLog("LLM stream started id=" . id . " endpoint=" . LLMLogEndpoint(endpoint))
        return id
    } catch as streamError {
        errorText := "LLM stream " . stage . " failed: " . streamError.Message
        DebugLog("LLM stream failed id=" . id . " stage=" . stage)
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
            DebugLog("LLM stream event error id=" . sink.State["id"])
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

LLMUtf8Bytes(text) {
    byteCount := StrPut(text, "UTF-8") - 1
    byteBuffer := Buffer(byteCount + 1, 0)
    StrPut(text, byteBuffer, "UTF-8")
    bytes := ComObjArray(0x11, byteCount)
    Loop byteCount
        bytes[A_Index - 1] := NumGet(byteBuffer, A_Index - 1, "UChar")
    return bytes
}

LLMResponseText(request) {
    try {
        body := request.ResponseBody
        if !IsObject(body)
            return request.ResponseText
        ; ResponseBody is a VT_UI1 SAFEARRAY. Convert it through the same
        ; SafeArray accessor used by SSE events so NumPut receives plain
        ; integers rather than ComValue wrappers.
        bytes := LLMStreamSafeArrayBytes(body)
        if !bytes.Length
            return ""
        rawBuffer := Buffer(bytes.Length + 1, 0)
        for index, byte in bytes
            NumPut("UChar", byte, rawBuffer, index - 1)
        return StrGet(rawBuffer, "UTF-8")
    } catch
        return request.ResponseText
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
