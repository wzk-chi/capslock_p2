; Youdao Smart Cloud (有道智云) translation client, v3 signed API (POST form).
; Reference: capslock-plus\lib\lib_ydTrans.ahk (AHK v1). Credentials live in
; [TYoudao]; targetLanguage is supplied by the resolved request from [TTranslate]. The translate
; panel prefers [LLM] and falls back to Youdao when it is configured.

GetYoudaoSetting(key, defaultValue := "") {
    return ConfigRead("TYoudao", key, defaultValue)
}

YoudaoSettingWith(key, defaultValue, overrides) {
    if IsObject(overrides) && overrides.Has(key)
        return overrides[key]
    return GetYoudaoSetting(key, defaultValue)
}

YoudaoConfigured() {
    return Trim(GetYoudaoSetting("appPaidID", "")) != ""
        && Trim(GetYoudaoSetting("appPaidKey", "")) != ""
}

; Start one signed form request without blocking the message loop. Validation
; failures are scheduled through the same asynchronous callback contract.
YoudaoTranslateAsync(text, onFinished, overrides := 0) {
    text := Trim(text)
    if text = ""
        return LLMScheduleAsyncCallback(LLMAsyncOperation(), onFinished, "", false, "")

    appID := Trim(YoudaoSettingWith("appPaidID", "", overrides))
    appKey := Trim(YoudaoSettingWith("appPaidKey", "", overrides))
    if appID = "" || appKey = "" {
        errorText := LLMText(
            "Youdao translation is not configured. Open Settings in the translate panel.",
            "尚未配置有道翻译，请点翻译面板里的「设置」填写。"
        )
        return LLMScheduleAsyncCallback(LLMAsyncOperation(), onFinished, "", false, errorText)
    }
    ; Keep line breaks: the POST form body is percent-encoded, so they
    ; survive the request, and youdao translates multi-line text line by
    ; line — the translation array then holds one entry per source line,
    ; which YoudaoFormatResult rejoins with newlines. (The reference
    ; implementation collapsed all whitespace because it sent the text in a
    ; signed GET URL, where a raw newline breaks the request.)
    text := StrReplace(StrReplace(text, "`r`n", "`n"), "`r", "`n")

    ; Youdao v3 caps a single request at 6000 bytes of UTF-8 text.
    if StrPut(text, "UTF-8") - 1 > 6000 {
        errorText := LLMText(
            "The text is too long for the Youdao API (max 6000 bytes).",
            "要翻译的文本过长（有道 API 上限 6000 字节）。"
        )
        return LLMScheduleAsyncCallback(LLMAsyncOperation(), onFinished, "", false, errorText)
    }

    ; Source language stays auto; the dispatcher has already resolved the
    ; request target and passes it through this override map.
    toLang := YoudaoTargetCode(TranslateSettingWith("targetLanguage", "", overrides))
    if toLang = "" {
        errorText := LLMText("The selected target language is not supported by Youdao.", "有道翻译不支持当前目标语言。")
        return LLMScheduleAsyncCallback(LLMAsyncOperation(), onFinished, "", false, errorText)
    }

    salt := YoudaoSalt()
    if salt = ""
        salt := Format("{:d}{:04d}", A_TickCount, Random(1000, 9999))
    curtime := DateDiff(A_NowUTC, "19700101000000", "Seconds")
    input := text
    if StrLen(text) > 20
        input := SubStr(text, 1, 10) . StrLen(text) . SubStr(text, -10)
    sign := CryptoSha256Hex(appID . input . salt . curtime . appKey)
    DebugLog("youdao request chars=" . StrLen(text))

    ; Send the parameters as a urlencoded form body (the reference flow and
    ; the official docs prefer POST; it also keeps long text out of the URL).
    ; Everything is percent-encoded, so the body stays pure ASCII.
    body := "q=" . UrlEncodeUtf8(text)
        . "&from=auto"
        . "&to=" . UrlEncodeUtf8(toLang)
        . "&appKey=" . UrlEncodeUtf8(appID)
        . "&salt=" . UrlEncodeUtf8(salt)
        . "&curtime=" . UrlEncodeUtf8(curtime)
        . "&signType=v3"
        . "&sign=" . UrlEncodeUtf8(sign)

    headers := Map("Content-Type", "application/x-www-form-urlencoded")
    return LLMHttpRequestAsync("POST", "https://openapi.youdao.com/api", body,
        headers, 20000, YoudaoTranslateResponse.Bind(onFinished))
}

YoudaoTranslateResponse(onFinished, status, response, transportError) {
    translated := ""
    success := false
    errorText := ""
    if transportError != "" {
        DebugLog("youdao request failed (network)")
        errorText := LLMText(
            "Request failed; the network may be disconnected.",
            "发送异常，可能是网络已断开。"
        )
    } else if status != 200 {
        DebugLog("youdao response status=" . status)
        errorText := LLMText(
            "Youdao API returned HTTP " . status . ".",
            "有道 API 返回 HTTP " . status . "。"
        )
    } else {
        DebugLog("youdao response status=" . status . " len=" . StrLen(response))
        try {
            parsed := JSON.Parse(response)
            if Type(parsed) != "Map"
                throw Error("Invalid response shape")
            errorCode := parsed.Has("errorCode") ? Trim(parsed["errorCode"] "") : ""
            if errorCode != "" && errorCode != "0" {
                errorText := YoudaoErrorText(errorCode)
            } else {
                translated := YoudaoFormatResult(parsed)
                if translated = "" {
                    errorText := LLMText(
                        "The Youdao response did not contain a translation.",
                        "有道接口返回内容里没有找到译文。"
                    )
                } else {
                    success := true
                }
            }
        } catch {
            errorText := LLMText(
                "The Youdao response could not be parsed.",
                "有道接口返回内容解析失败。"
            )
        }
    }
    try onFinished.Call(translated, success, errorText)
}

; Map a canonical target language to the Youdao `to` code. Unknown values are
; rejected by the caller instead of silently changing the translation target.
YoudaoTargetCode(value) {
    value := TranslateNormalizeLanguage(value, true)
    if value = "system"
        value := TranslateSystemLanguageCode()
    switch value {
        case "zh-TW":
            return "zh-CHT"
        case "zh-CN":
            return "zh-CHS"
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

; Translation first, then phonetic, dictionary explains and web phrases.
; `parsed` is the JSON.Parse'd response: a Map whose values are arrays, maps
; and scalars; missing optional fields (basic/web) are simply skipped.
YoudaoFormatResult(parsed) {
    result := ""
    translations := parsed.Has("translation") && IsObject(parsed["translation"]) ? parsed["translation"] : []
    for translation in translations {
        translation := Trim(translation)
        if translation = ""
            continue
        result .= (result = "" ? "" : "`n") . translation
    }
    if result = ""
        return ""

    basic := parsed.Has("basic") && IsObject(parsed["basic"]) ? parsed["basic"] : 0
    phonetic := IsObject(basic) && basic.Has("phonetic") ? Trim(basic["phonetic"] "") : ""
    if phonetic != ""
        result .= "`n`n[" . phonetic . "]"

    if IsObject(basic) && basic.Has("explains") && IsObject(basic["explains"]) {
        result .= "`n`n" . LLMText("Dictionary", "词典释义")
        for explain in basic["explains"]
            result .= "`n" . Trim(explain)
    }

    web := parsed.Has("web") && IsObject(parsed["web"]) ? parsed["web"] : []
    if web.Length {
        result .= "`n`n" . LLMText("Phrases", "短语")
        for entry in web {
            key := IsObject(entry) && entry.Has("key") ? Trim(entry["key"] "") : ""
            if key = ""
                continue
            joined := ""
            if IsObject(entry) && entry.Has("value") && IsObject(entry["value"]) {
                for value in entry["value"] {
                    value := Trim(value)
                    if value = ""
                        continue
                    joined .= (joined = "" ? "" : "; ") . value
                }
            }
            result .= "`n" . key . (joined = "" ? "" : ": " . joined)
        }
    }
    return result
}

YoudaoErrorText(code) {
    errorMap := Map(
        "101", ["Missing required parameters.", "缺少必填参数。"],
        "102", ["Unsupported language type.", "不支持的语言类型。"],
        "103", ["The text to translate is too long.", "要翻译的文本过长。"],
        "108", ["The app ID (appKey) is invalid.", "应用ID（appKey）无效。"],
        "110", ["No related data.", "无相关数据。"],
        "111", ["Invalid developer account.", "开发者账号无效。"],
        "113", ["The text to translate is empty.", "要翻译的文本不能为空。"],
        "202", ["Signature verification failed; check the app ID and app secret.",
            "签名校验失败，请检查应用ID和应用密钥。"],
        "203", ["The requesting IP is not in the allowed list.",
            "访问 IP 地址不在可访问 IP 列表。"],
        "205", ["The app secret is invalid.", "认证的应用密钥无效。"],
        "301", ["Dictionary query failed.", "词典查询失败。"],
        "302", ["Translation query failed.", "翻译查询失败。"],
        "303", ["Service error.", "服务异常。"],
        "401", ["The account is in arrears.", "账户余额不足。"],
        "411", ["Access frequency is limited; try again later.",
            "访问频率受限，请稍后再试。"])
    if errorMap.Has(code) {
        pair := errorMap[code]
        return IsChineseLanguage() ? pair[2] : pair[1]
    }
    return LLMText("Youdao API error " . code, "有道翻译错误 " . code)
}

YoudaoSalt() {
    ; Scriptlet.TypeLib.Guid is a cheap GUID source, but the BSTR it returns
    ; is known to carry stray bytes after the GUID (embedded NULs included).
    ; Those bytes would truncate the request URL mid-way and corrupt the
    ; signature, so extract exactly the 36-character GUID body.
    try {
        guid := ComObject("Scriptlet.TypeLib").Guid
        if RegExMatch(guid, "i)^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$", &match)
            return match[0]
        if RegExMatch(guid, "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", &match)
            return match[0]
    } catch {
        ; fall through to the numeric salt below
    }
    return Format("{:d}{:04d}", A_TickCount, Random(1000, 9999))
}

; ---- "youdao" provider glue ----
; One-shot engine: no streaming UI, the formatted result arrives through one
; asynchronous callback. Every provider returns an idempotent cancel operation.

TranslateProviderYoudaoTranslate(text, onDelta, onFinished, overrides := 0) {
    return YoudaoTranslateAsync(text, onFinished, overrides)
}

TranslateProviderYoudaoTest(msg, onFinished) {
    overrides := Map("targetLanguage", Trim(LLMMsgField(msg, "targetLanguage")))
    ; Missing credentials keep the saved value; an explicit empty value clears it.
    if msg.Has("appId")
        overrides["appPaidID"] := Trim(LLMMsgField(msg, "appId"))
    if msg.Has("appKey")
        overrides["appPaidKey"] := LLMMsgField(msg, "appKey")
    return YoudaoTranslateAsync("Hello", TranslateProviderYoudaoTestFinished.Bind(onFinished), overrides)
}

TranslateProviderYoudaoTestFinished(onFinished, translated, success, errorText) {
    text := success ? LLMText("Connection OK", "连接正常") : errorText
    try onFinished.Call(success, text)
}

TranslateRegisterProvider("youdao", Map(
    "streaming", 0,
    "configured", YoudaoConfigured,
    "translate", TranslateProviderYoudaoTranslate,
    "test", TranslateProviderYoudaoTest,
    "notConfigured", ["Youdao translation is not configured. Open Settings.",
        "未配置有道翻译，请点右上角「设置」填写。"]))
