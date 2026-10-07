; Volcengine Translate (火山引擎机器翻译) client. TranslateText is a one-shot
; V4-signed API (an HMAC-SHA256 chain, same shape as AWS SigV4): the signature
; covers a canonical request of method, path, query, lowercase sorted headers
; (content-type / host / x-content-sha256 / x-date) and the body hash. Config
; lives in [TVolcengine] (accessKey / secretKey / region); the target language
; is shared in [TTranslate]. Reference flow: the TranslateText docs sample against
; translate.volcengineapi.com, Action=TranslateText, Version=2020-06-01.

GetVolcengineSetting(key, defaultValue := "") {
    return ConfigRead("TVolcengine", key, defaultValue)
}

VolcengineSettingWith(key, defaultValue, overrides) {
    if IsObject(overrides) && overrides.Has(key)
        return overrides[key]
    return GetVolcengineSetting(key, defaultValue)
}

VolcengineConfigured() {
    return Trim(GetVolcengineSetting("accessKey", "")) != ""
        && Trim(GetVolcengineSetting("secretKey", "")) != ""
}

; Translate a whole text in sequential signed batches while retaining its line
; breaks. The outer operation owns cancellation; at most one HTTP batch is in
; flight, and a failed batch prevents all later batches from starting.
VolcengineTranslateAsync(text, onFinished, overrides := 0) {
    text := Trim(text)
    if text = ""
        return LLMScheduleAsyncCallback(LLMAsyncOperation(), onFinished, "", false, "")

    accessKey := Trim(VolcengineSettingWith("accessKey", "", overrides))
    secretKey := Trim(VolcengineSettingWith("secretKey", "", overrides))
    if accessKey = "" || secretKey = "" {
        errorText := LLMText(
            "Volcengine translation is not configured. Open Settings in the translate panel.",
            "尚未配置火山翻译，请点翻译面板里的「设置」填写。"
        )
        return LLMScheduleAsyncCallback(LLMAsyncOperation(), onFinished, "", false, errorText)
    }
    region := Trim(VolcengineSettingWith("region", "", overrides))
    targetCode := VolcengineTargetCode(TranslateSettingWith("targetLanguage", "", overrides))
    if targetCode = "" {
        errorText := LLMText("The selected target language is not supported by Volcengine.", "火山翻译不支持当前目标语言。")
        return LLMScheduleAsyncCallback(LLMAsyncOperation(), onFinished, "", false, errorText)
    }

    normalizedText := StrReplace(StrReplace(text, "`r`n", "`n"), "`r", "`n")
    lines := StrSplit(normalizedText, "`n")
    segments := []
    for line in lines
        if Trim(line) != ""
            segments.Push(Trim(line))
    state := Map(
        "lines", lines,
        "segments", segments,
        "translated", [],
        "index", 1,
        "targetCode", targetCode,
        "accessKey", accessKey,
        "secretKey", secretKey,
        "region", region,
        "onFinished", onFinished,
        "request", 0,
        "operation", 0)
    operation := LLMAsyncOperation(VolcengineTranslateCancel.Bind(state))
    state["operation"] := operation
    SetTimer(VolcengineTranslateNextBatch.Bind(state), -1)
    return operation
}

VolcengineTranslateNextBatch(state, *) {
    operation := state["operation"]
    if !operation.IsActive()
        return
    if state["index"] > state["segments"].Length {
        if state["translated"].Length != state["segments"].Length {
            DebugLog("volcengine translation item count mismatch expected="
                . state["segments"].Length . " actual=" . state["translated"].Length)
            VolcengineTranslateFinish(state, "", false, LLMText(
                "The Volcengine response did not match the submitted text.",
                "火山引擎接口返回的分段数量与原文不匹配。"))
            return
        }
        VolcengineTranslateFinish(state, VolcengineTranslateRebuild(state), true, "")
        return
    }

    batch := []
    batchChars := 0
    while state["index"] <= state["segments"].Length && batch.Length < 16 {
        segment := state["segments"][state["index"]]
        ; Entry cap is 16, character budget 5000; leave a margin so the
        ; JSON envelope remains comfortably below the service limit.
        if batch.Length && batchChars + StrLen(segment) > 4500
            break
        batch.Push(segment)
        batchChars += StrLen(segment)
        state["index"] += 1
    }
    try {
        childOperation := VolcengineTranslateBatchAsync(batch,
            state["targetCode"], state["accessKey"], state["secretKey"], state["region"],
            VolcengineTranslateBatchFinished.Bind(state))
        if IsObject(childOperation) {
            criticalState := A_IsCritical
            Critical "On"
            try {
                if operation.IsActive()
                    state["request"] := childOperation
                else
                    childOperation.Cancel()
            } finally {
                if !criticalState
                    Critical "Off"
            }
        }
    } catch as batchStartError {
        DebugLog("volcengine batch setup failed")
        VolcengineTranslateFinish(state, "", false, batchStartError.Message)
    }
}

VolcengineTranslateBatchFinished(state, pieces, success, errorText) {
    if !state["operation"].IsActive()
        return
    state["request"] := 0
    if !success {
        VolcengineTranslateFinish(state, "", false, errorText)
        return
    }
    for piece in pieces
        state["translated"].Push(piece)
    SetTimer(VolcengineTranslateNextBatch.Bind(state), -1)
}

VolcengineTranslateRebuild(state) {
    translated := state["translated"]
    if translated.Length != state["segments"].Length
        return ""
    result := ""
    translatedIndex := 1
    for lineIndex, line in state["lines"] {
        if lineIndex > 1
            result .= "`n"
        if Trim(line) != "" {
            result .= translated[translatedIndex]
            translatedIndex += 1
        }
    }
    return result
}

VolcengineTranslateFinish(state, translated, success, errorText) {
    operation := state["operation"]
    if !operation.IsActive()
        return
    state["request"] := 0
    if success && translated = "" {
        success := false
        errorText := LLMText(
            "The Volcengine response did not contain a translation.",
            "火山引擎接口返回内容里没有找到译文。"
        )
    }
    if !operation.Complete()
        return
    try state["onFinished"].Call(translated, success, errorText)
}

VolcengineTranslateCancel(state) {
    request := state["request"]
    state["request"] := 0
    if IsObject(request)
        request.Cancel()
}

; Build one signed TranslateText batch and send it through the shared WinHTTP
; event transport. Content-Type remains exactly as covered by the signature.
VolcengineTranslateBatchAsync(texts, targetCode, accessKey, secretKey, region, onFinished) {
    body := JSON.stringify(Map("TargetLanguage", targetCode, "TextList", texts), 0)
    bodyHash := CryptoSha256Hex(body)
    now := A_NowUTC
    xDate := FormatTime(now, "yyyyMMdd'T'HHmmss'Z'")
    shortDate := SubStr(now, 1, 8)
    host := "translate.volcengineapi.com"
    query := "Action=TranslateText&Version=2020-06-01"
    signedHeaders := "content-type;host;x-content-sha256;x-date"
    canonicalHeaders := "content-type:application/json`n"
        . "host:" . host . "`n"
        . "x-content-sha256:" . bodyHash . "`n"
        . "x-date:" . xDate . "`n"
    canonicalRequest := "POST`n/`n" . query . "`n" . canonicalHeaders . "`n"
        . signedHeaders . "`n" . bodyHash
    credentialScope := shortDate . "/" . region . "/translate/request"
    stringToSign := "HMAC-SHA256`n" . xDate . "`n" . credentialScope . "`n"
        . CryptoSha256Hex(canonicalRequest)
    kDate := CryptoHmacSha256(secretKey, shortDate)
    kRegion := CryptoHmacSha256(kDate, region)
    kService := CryptoHmacSha256(kRegion, "translate")
    kSigning := CryptoHmacSha256(kService, "request")
    signature := CryptoHmacSha256Hex(kSigning, stringToSign)
    authorization := "HMAC-SHA256 Credential=" . accessKey . "/" . credentialScope
        . ", SignedHeaders=" . signedHeaders . ", Signature=" . signature
    DebugLog("volcengine request texts=" . texts.Length . " chars=" . StrLen(body))
    headers := Map(
        "Content-Type", "application/json",
        "X-Date", xDate,
        "X-Content-Sha256", bodyHash,
        "Authorization", authorization)
    return LLMHttpRequestAsync("POST", "https://" . host . "/?" . query,
        body, headers, 20000, VolcengineTranslateBatchResponse.Bind(onFinished))
}

VolcengineTranslateBatchResponse(onFinished, status, response, transportError) {
    success := false
    errorText := ""
    pieces := []
    if transportError != "" {
        DebugLog("volcengine request failed (network)")
        errorText := LLMText(
            "Request failed; the network may be disconnected.",
            "发送异常，可能是网络已断开。"
        )
    } else if status != 200 {
        DebugLog("volcengine response status=" . status)
        errorText := LLMText(
            "Volcengine API returned HTTP " . status . ".",
            "火山引擎 API 返回 HTTP " . status . "。"
        )
    } else {
        DebugLog("volcengine response len=" . StrLen(response))
        try {
            parsed := JSON.Parse(response)
            if Type(parsed) != "Map"
                throw Error("Invalid response shape")
            metadata := parsed.Has("ResponseMetadata") && Type(parsed["ResponseMetadata"]) = "Map"
                ? parsed["ResponseMetadata"] : 0
            apiError := IsObject(metadata) && metadata.Has("Error") && Type(metadata["Error"]) = "Map"
                ? metadata["Error"] : 0
            if IsObject(apiError) {
                code := apiError.Has("Code") ? Trim(apiError["Code"] "") : ""
                message := apiError.Has("Message") ? Trim(apiError["Message"] "") : ""
                errorText := LLMText("Volcengine API error ", "火山引擎接口错误 ") . code
                    . (message = "" ? "" : ": " . message)
            } else {
                translations := parsed.Has("TranslationList") && Type(parsed["TranslationList"]) = "Array"
                    ? parsed["TranslationList"] : []
                for entry in translations
                    pieces.Push(Type(entry) = "Map" && entry.Has("Translation")
                        ? Trim(entry["Translation"] "") : "")
                success := true
            }
        } catch {
            errorText := LLMText(
                "The Volcengine response could not be parsed.",
                "火山引擎接口返回内容解析失败。"
            )
        }
    }
    try onFinished.Call(pieces, success, errorText)
}

; Map a canonical target language to a TranslateText target code. Unknown
; values are rejected by the caller instead of silently falling back to zh.
VolcengineTargetCode(value) {
    value := TranslateNormalizeLanguage(value, true)
    if value = "system"
        value := TranslateSystemLanguageCode()
    switch value {
        case "zh-TW":
            return "zh-Hant"
        case "zh-CN":
            return "zh"
        case "en":
            return "en"
        case "ja":
            return "ja"
        case "ko":
            return "ko"
        case "fr":
            return "fr"
        case "de":
            return "de"
        case "es":
            return "es"
        case "ru":
            return "ru"
        case "it":
            return "it"
        case "pt":
            return "pt"
        case "ar":
            return "ar"
    }
    return ""
}

; ---- "volcengine" provider glue ----
; One-shot engine: no streaming UI, the result arrives through a single
; asynchronous callback; every request returns an idempotent cancel operation.

TranslateProviderVolcengineTranslate(text, onDelta, onFinished, overrides := 0) {
    return VolcengineTranslateAsync(text, onFinished, overrides)
}

TranslateProviderVolcengineTest(msg, onFinished) {
    overrides := Map("targetLanguage", Trim(LLMMsgField(msg, "targetLanguage")))
    ; Missing credentials keep the saved value; an explicit empty value clears it.
    if msg.Has("volcAccessKey")
        overrides["accessKey"] := Trim(LLMMsgField(msg, "volcAccessKey"))
    if msg.Has("volcSecretKey")
        overrides["secretKey"] := LLMMsgField(msg, "volcSecretKey")
    if msg.Has("volcRegion")
        overrides["region"] := Trim(LLMMsgField(msg, "volcRegion"))
    return VolcengineTranslateAsync("Hello",
        TranslateProviderVolcengineTestFinished.Bind(onFinished), overrides)
}

TranslateProviderVolcengineTestFinished(onFinished, translated, success, errorText) {
    text := success ? LLMText("Connection OK", "连接正常") : errorText
    try onFinished.Call(success, text)
}

TranslateRegisterProvider("volcengine", Map(
    "streaming", 0,
    "configured", VolcengineConfigured,
    "translate", TranslateProviderVolcengineTranslate,
    "test", TranslateProviderVolcengineTest,
    "notConfigured", ["Volcengine translation is not configured. Open Settings.",
        "未配置火山翻译，请点右上角「设置」填写。"]))
