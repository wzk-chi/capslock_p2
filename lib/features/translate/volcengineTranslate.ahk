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

; Translate a whole text while keeping its line structure: the text is split
; into lines and translated as separate TextList entries (a single text is
; translated as one block, so paragraph breaks would be lost); blank lines
; are skipped in the requests and rebuilt locally. TranslateText takes at
; most 16 entries / 5000 characters per request, so longer texts go out as
; several sequential signed requests. Calls block the message loop like
; YoudaoTranslate, so callers run this from a SetTimer(fn, -1) callback,
; never from a WebView2 event.
VolcengineTranslate(text, &success := false, &errorText := "", overrides := 0) {
    success := false
    errorText := ""
    text := Trim(text)
    if text = ""
        return ""

    accessKey := Trim(VolcengineSettingWith("accessKey", "", overrides))
    secretKey := Trim(VolcengineSettingWith("secretKey", "", overrides))
    if accessKey = "" || secretKey = "" {
        errorText := LLMText(
            "Volcengine translation is not configured. Open Settings in the translate panel.",
            "尚未配置火山翻译，请点翻译面板里的「设置」填写。"
        )
        return ""
    }
    region := Trim(VolcengineSettingWith("region", "", overrides))
    ; TranslateText requires an explicit target language; the source language
    ; is detected server-side.
    targetCode := VolcengineTargetCode(TranslateSettingWith("targetLanguage", "", overrides))
    if targetCode = "" {
        errorText := LLMText("The selected target language is not supported by Volcengine.", "火山翻译不支持当前目标语言。")
        return ""
    }

    lines := StrSplit(StrReplace(StrReplace(text, "`r`n", "`n"), "`r", "`n"), "`n")
    segments := []
    for line in lines
        if Trim(line) != ""
            segments.Push(Trim(line))
    translated := []
    index := 1
    while index <= segments.Length {
        batch := []
        batchChars := 0
        while index <= segments.Length && batch.Length < 16 {
            ; Entry cap is 16, character budget 5000; leave a margin so the
            ; JSON envelope keeps the whole request comfortably under it.
            if batch.Length && batchChars + StrLen(segments[index]) > 4500
                break
            batch.Push(segments[index])
            batchChars += StrLen(segments[index])
            index++
        }
        pieces := VolcengineTranslateBatch(batch, targetCode, accessKey, secretKey, region, &ok, &batchError)
        if !ok {
            errorText := batchError
            return ""
        }
        for piece in pieces
            translated.Push(piece)
    }

    ; Rebuild the original line layout — blank lines stay blank, translations
    ; slot back in order. On a count mismatch, fall back to a plain join.
    result := ""
    if translated.Length = segments.Length {
        index := 1
        for line in lines {
            piece := (Trim(line) = "") ? "" : translated[index++]
            result .= (result = "" ? "" : "`n") . piece
        }
    } else {
        for piece in translated
            result .= (result = "" ? "" : "`n") . piece
    }
    if result = "" {
        errorText := LLMText(
            "The Volcengine response did not contain a translation.",
            "火山引擎接口返回内容里没有找到译文。"
        )
        return ""
    }
    success := true
    return result
}

; One signed TranslateText request for a batch of segments; returns the
; translated pieces in request order ("" for entries without a translation,
; so positions stay aligned with the request).
VolcengineTranslateBatch(texts, targetCode, accessKey, secretKey, region, &success, &errorText) {
    success := false
    errorText := ""
    body := JSON.stringify(Map(
        "TargetLanguage", targetCode,
        "TextList", texts), 0)
    bodyHash := CryptoSha256Hex(body)

    now := A_NowUTC
    xDate := FormatTime(now, "yyyyMMdd'T'HHmmss'Z'")
    shortDate := SubStr(now, 1, 8)
    host := "translate.volcengineapi.com"
    query := "Action=TranslateText&Version=2020-06-01"

    ; Canonical request: method, path, query, lowercase sorted headers
    ; (canonicalHeaders already ends in a newline, so a blank line follows),
    ; the signed header list, then the body hash.
    signedHeaders := "content-type;host;x-content-sha256;x-date"
    canonicalHeaders := "content-type:application/json`n"
        . "host:" . host . "`n"
        . "x-content-sha256:" . bodyHash . "`n"
        . "x-date:" . xDate . "`n"
    canonicalRequest := "POST`n"
        . "/`n"
        . query . "`n"
        . canonicalHeaders . "`n"
        . signedHeaders . "`n"
        . bodyHash
    credentialScope := shortDate . "/" . region . "/translate/request"
    stringToSign := "HMAC-SHA256`n"
        . xDate . "`n"
        . credentialScope . "`n"
        . CryptoSha256Hex(canonicalRequest)

    ; The V4 key chain: each round consumes the previous raw digest, so
    ; CryptoHmacSha256 returns binary until the final hex signature.
    kDate := CryptoHmacSha256(secretKey, shortDate)
    kRegion := CryptoHmacSha256(kDate, region)
    kService := CryptoHmacSha256(kRegion, "translate")
    kSigning := CryptoHmacSha256(kService, "request")
    signature := CryptoHmacSha256Hex(kSigning, stringToSign)
    authorization := "HMAC-SHA256 Credential=" . accessKey . "/" . credentialScope
        . ", SignedHeaders=" . signedHeaders
        . ", Signature=" . signature
    DebugLog("volcengine request texts=" . texts.Length . " chars=" . StrLen(body))

    try {
        request := ComObject("WinHttp.WinHttpRequest.5.1")
        request.Open("POST", "https://" . host . "/?" . query, false)
        request.SetTimeouts(20000, 20000, 20000, 20000)
        ; Content-Type must be exactly "application/json": the value takes
        ; part in the signature, so no charset suffix may be appended.
        request.SetRequestHeader("Content-Type", "application/json")
        request.SetRequestHeader("X-Date", xDate)
        request.SetRequestHeader("X-Content-Sha256", bodyHash)
        request.SetRequestHeader("Authorization", authorization)
        request.Send(LLMUtf8Bytes(body))
    } catch {
        DebugLog("volcengine request failed (network)")
        errorText := LLMText(
            "Request failed; the network may be disconnected.",
            "发送异常，可能是网络已断开。"
        )
        return ""
    }
    DebugLog("volcengine response status=" . request.Status)
    if request.Status != 200 {
        errorText := LLMText(
            "Volcengine API returned HTTP " . request.Status . ".",
            "火山引擎 API 返回 HTTP " . request.Status . "。"
        )
        return ""
    }

    response := LLMResponseText(request)
    DebugLog("volcengine response len=" . StrLen(response))
    try parsed := JSON.Parse(response)
    catch {
        errorText := LLMText(
            "The Volcengine response could not be parsed.",
            "火山引擎接口返回内容解析失败。"
        )
        return ""
    }
    ; Business errors arrive with HTTP 200, nested at ResponseMetadata.Error.
    if IsObject(parsed) && parsed.Has("ResponseMetadata") && IsObject(parsed["ResponseMetadata"])
        && parsed["ResponseMetadata"].Has("Error") && IsObject(parsed["ResponseMetadata"]["Error"]) {
        apiError := parsed["ResponseMetadata"]["Error"]
        code := apiError.Has("Code") ? Trim(apiError["Code"] "") : ""
        message := apiError.Has("Message") ? Trim(apiError["Message"] "") : ""
        errorText := LLMText("Volcengine API error ", "火山引擎接口错误 ") . code
            . (message = "" ? "" : ": " . message)
        return ""
    }
    pieces := []
    translations := IsObject(parsed) && parsed.Has("TranslationList") && IsObject(parsed["TranslationList"])
        ? parsed["TranslationList"] : []
    for entry in translations
        pieces.Push(IsObject(entry) && entry.Has("Translation") ? Trim(entry["Translation"] "") : "")
    success := true
    return pieces
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
; onFinished call (contract in lib\features\translate\translate.ahk).

TranslateProviderVolcengineTranslate(text, onDelta, onFinished, overrides := 0) {
    translated := VolcengineTranslate(text, &ok, &errorText, overrides)
    onFinished.Call(translated, ok, errorText)
    return 0
}

TranslateProviderVolcengineTest(msg, &ok, &text) {
    ok := false
    text := ""
    overrides := Map(
        "accessKey", Trim(LLMMsgField(msg, "volcAccessKey")),
        "secretKey", LLMMsgField(msg, "volcSecretKey"),
        "targetLanguage", Trim(LLMMsgField(msg, "targetLanguage")))
    if msg.Has("volcRegion")
        overrides["region"] := Trim(LLMMsgField(msg, "volcRegion"))
    VolcengineTranslate("Hello", &ok, &errorText, overrides)
    if ok
        text := LLMText("Connection OK", "连接正常")
    else
        text := errorText
}

TranslateRegisterProvider("volcengine", Map(
    "streaming", 0,
    "configured", VolcengineConfigured,
    "translate", TranslateProviderVolcengineTranslate,
    "test", TranslateProviderVolcengineTest,
    "notConfigured", ["Volcengine translation is not configured. Open Settings.",
        "未配置火山翻译，请点右上角「设置」填写。"]))
