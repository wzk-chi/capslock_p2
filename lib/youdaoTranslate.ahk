; Youdao Smart Cloud (有道智云) translation client, v3 signed API (POST form).
; Reference: capslock-plus\lib\lib_ydTrans.ahk (AHK v1). Config lives in
; [TTranslate] and reuses the legacy field names appPaidID/appPaidKey, so old
; settings keep working; targetLanguage holds the Youdao-only target language
; (independent from [LLMTranslate] targetLanguage). The translate panel
; prefers [LLM] and falls back to Youdao when only [TTranslate] is configured.

GetYoudaoSetting(key, defaultValue := "") {
    global Config
    if Config.Has("TTranslate") && Config["TTranslate"].Has(key)
        return Config["TTranslate"][key]
    return defaultValue
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

; One-shot signed request. The call blocks the message loop for the duration
; of the request (same tradeoff as the reference implementation), so callers
; run it from a SetTimer(fn, -1) callback, never from a WebView2 event.
YoudaoTranslate(text, &success := false, &errorText := "", overrides := 0) {
    success := false
    errorText := ""
    text := Trim(text)
    if text = ""
        return ""

    appID := Trim(YoudaoSettingWith("appPaidID", "", overrides))
    appKey := Trim(YoudaoSettingWith("appPaidKey", "", overrides))
    if appID = "" || appKey = "" {
        errorText := LLMText(
            "Youdao translation is not configured. Open Settings in the translate panel.",
            "尚未配置有道翻译，请点翻译面板里的「设置」填写。"
        )
        return ""
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
        return ""
    }

    ; Source language stays auto; the target follows [TTranslate]
    ; targetLanguage — its own setting, independent from the LLM one.
    toLang := YoudaoTargetCode(YoudaoSettingWith("targetLanguage", "", overrides))

    salt := YoudaoSalt()
    if salt = ""
        salt := Format("{:d}{:04d}", A_TickCount, Random(1000, 9999))
    curtime := DateDiff(A_NowUTC, "19700101000000", "Seconds")
    input := text
    if StrLen(text) > 20
        input := SubStr(text, 1, 10) . StrLen(text) . SubStr(text, -10)
    sign := BCryptSha256Hex(appID . input . salt . curtime . appKey)
    DebugLog("youdao request q=" . StrLen(text) . " chars appId=" . appID . " to=" . toLang)

    ; Send the parameters as a urlencoded form body (the reference flow and
    ; the official docs prefer POST; it also keeps long text out of the URL).
    ; Everything is percent-encoded, so the body stays pure ASCII.
    body := "q=" . YoudaoUrlEncode(text)
        . "&from=auto"
        . "&to=" . YoudaoUrlEncode(toLang)
        . "&appKey=" . YoudaoUrlEncode(appID)
        . "&salt=" . YoudaoUrlEncode(salt)
        . "&curtime=" . YoudaoUrlEncode(curtime)
        . "&signType=v3"
        . "&sign=" . YoudaoUrlEncode(sign)

    try {
        request := ComObject("WinHttp.WinHttpRequest.5.1")
        request.Open("POST", "https://openapi.youdao.com/api", false)
        request.SetTimeouts(20000, 20000, 20000, 20000)
        request.SetRequestHeader("Content-Type", "application/x-www-form-urlencoded")
        request.Send(body)
    } catch {
        DebugLog("youdao request failed (network)")
        errorText := LLMText(
            "Request failed; the network may be disconnected.",
            "发送异常，可能是网络已断开。"
        )
        return ""
    }
    DebugLog("youdao response status=" . request.Status)
    if request.Status != 200 {
        errorText := LLMText(
            "Youdao API returned HTTP " . request.Status . ".",
            "有道 API 返回 HTTP " . request.Status . "。"
        )
        return ""
    }

    response := LLMResponseText(request)
    DebugLog("youdao response len=" . StrLen(response))
    try parsed := JSON.Parse(response)
    catch {
        errorText := LLMText(
            "The Youdao response could not be parsed.",
            "有道接口返回内容解析失败。"
        )
        return ""
    }
    errorCode := parsed.Has("errorCode") ? Trim(parsed["errorCode"] "") : ""
    if errorCode != "" && errorCode != "0" {
        errorText := YoudaoErrorText(errorCode)
        return ""
    }
    result := YoudaoFormatResult(parsed)
    if result = "" {
        errorText := LLMText(
            "The Youdao response did not contain a translation.",
            "有道接口返回内容里没有找到译文。"
        )
        return ""
    }
    success := true
    return result
}

; Map the [TTranslate] targetLanguage setting to a Youdao `to` code. Empty or
; unknown values fall back to auto (Chinese source → en, otherwise zh-CHS).
YoudaoTargetCode(value) {
    value := Trim(value)
    if value = ""
        return "auto"
    lowered := StrLower(value)
    if InStr(lowered, "繁") || InStr(lowered, "traditional")
        return "zh-CHT"
    if InStr(lowered, "中") || InStr(lowered, "chinese") || InStr(lowered, "simplified")
        return "zh-CHS"
    if InStr(lowered, "english") || InStr(lowered, "英文") || InStr(lowered, "英语") || lowered = "en"
        return "en"
    if InStr(lowered, "japanese") || InStr(lowered, "日语") || InStr(lowered, "日文") || lowered = "ja" || lowered = "jp"
        return "ja"
    if InStr(lowered, "korean") || InStr(lowered, "韩") || lowered = "ko" || lowered = "kr"
        return "ko"
    if InStr(lowered, "french") || InStr(lowered, "法语") || InStr(lowered, "法文") || lowered = "fr"
        return "fr"
    if InStr(lowered, "german") || InStr(lowered, "德语") || InStr(lowered, "德文") || lowered = "de"
        return "de"
    if InStr(lowered, "spanish") || InStr(lowered, "西班牙语") || lowered = "es"
        return "es"
    if InStr(lowered, "russian") || InStr(lowered, "俄语") || lowered = "ru"
        return "ru"
    if InStr(lowered, "italian") || InStr(lowered, "意大利语") || lowered = "it"
        return "it"
    if InStr(lowered, "portuguese") || InStr(lowered, "葡萄牙语") || lowered = "pt"
        return "pt"
    if InStr(lowered, "arabic") || InStr(lowered, "阿拉伯语") || lowered = "ar"
        return "ar"
    if InStr(lowered, "thai") || InStr(lowered, "泰语") || lowered = "th"
        return "th"
    ; Already a plain language code (en, ja, pt-BR...)? Pass it through.
    if RegExMatch(lowered, "^[a-z]{2,3}(-[a-z0-9]{2,8})?$")
        return value
    return "auto"
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

BCryptSha256Hex(text) {
    byteLength := StrPut(text, "UTF-8") - 1
    binary := Buffer(byteLength + 1)
    StrPut(text, binary, "UTF-8")

    algorithmHandle := 0
    if DllCall("bcrypt\BCryptOpenAlgorithmProvider", "ptr*", &algorithmHandle := 0, "ptr", StrPtr("SHA256"), "ptr", 0, "uint", 0)
        throw Error("BCryptOpenAlgorithmProvider failed")
    hashHandle := 0
    try {
        ; Query the provider's required object size and hash size, as the
        ; reference implementation (capslock-plus\lib\sha256.ahk) does.
        objectLength := 0
        hashLength := 0
        if DllCall("bcrypt\BCryptGetProperty", "ptr", algorithmHandle, "ptr", StrPtr("ObjectLength"), "uint*", &objectLength := 0, "uint", 4, "uint*", &writtenLength := 0, "uint", 0)
            throw Error("BCryptGetProperty(ObjectLength) failed")
        if DllCall("bcrypt\BCryptGetProperty", "ptr", algorithmHandle, "ptr", StrPtr("HashDigestLength"), "uint*", &hashLength := 0, "uint", 4, "uint*", &writtenLength := 0, "uint", 0)
            throw Error("BCryptGetProperty(HashDigestLength) failed")
        hashObject := Buffer(objectLength, 0)
        digest := Buffer(hashLength, 0)
        if DllCall("bcrypt\BCryptCreateHash", "ptr", algorithmHandle, "ptr*", &hashHandle := 0, "ptr", hashObject, "uint", objectLength, "ptr", 0, "uint", 0, "uint", 0)
            throw Error("BCryptCreateHash failed")
        if DllCall("bcrypt\BCryptHashData", "ptr", hashHandle, "ptr", binary, "uint", byteLength, "uint", 0)
            throw Error("BCryptHashData failed")
        if DllCall("bcrypt\BCryptFinishHash", "ptr", hashHandle, "ptr", digest, "uint", hashLength, "uint", 0)
            throw Error("BCryptFinishHash failed")
    } finally {
        if hashHandle
            DllCall("bcrypt\BCryptDestroyHash", "ptr", hashHandle)
        DllCall("bcrypt\BCryptCloseAlgorithmProvider", "ptr", algorithmHandle, "uint", 0)
    }
    hex := ""
    loop hashLength
        hex .= Format("{:02x}", NumGet(digest, A_Index - 1, "UChar"))
    return hex
}

YoudaoUrlEncode(text) {
    byteLength := StrPut(text, "UTF-8") - 1
    binary := Buffer(byteLength + 1)
    StrPut(text, binary, "UTF-8")
    encoded := ""
    loop byteLength {
        byte := NumGet(binary, A_Index - 1, "UChar")
        if (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || byte = 0x2D || byte = 0x2E || byte = 0x5F || byte = 0x7E
            encoded .= Chr(byte)
        else
            encoded .= "%" . Format("{:02X}", byte)
    }
    return encoded
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
; One-shot engine: no streaming UI, the formatted result arrives through a
; single onFinished call (see lib\translate.ahk for the provider contract).

TranslateProviderYoudaoTranslate(text, onDelta, onFinished, overrides := 0) {
    translated := YoudaoTranslate(text, &ok, &errorText, overrides)
    onFinished.Call(translated, ok, errorText)
    return 0
}

TranslateProviderYoudaoTest(msg, &ok, &text) {
    ok := false
    text := ""
    overrides := Map(
        "appPaidID", Trim(LLMMsgField(msg, "appId")),
        "appPaidKey", LLMMsgField(msg, "appKey"),
        "targetLanguage", Trim(LLMMsgField(msg, "youdaoTargetLanguage"))
    )
    translated := YoudaoTranslate("Hello! This is a capslock_p2 connection test.", &ok, &errorText, overrides)
    if ok
        text := LLMText("Connection OK → ", "连接正常 → ") . SubStr(translated, 1, 120)
    else
        text := errorText
}

TranslateProviderYoudaoSave(msg) {
    global SettingsFile
    WriteIniValue(SettingsFile, "TTranslate", "appPaidID", Trim(LLMMsgField(msg, "appId")))
    WriteIniValue(SettingsFile, "TTranslate", "appPaidKey", LLMMsgField(msg, "appKey"))
    WriteIniValue(SettingsFile, "TTranslate", "targetLanguage", Trim(LLMMsgField(msg, "youdaoTargetLanguage")))
}

TranslateProviderYoudaoPush() {
    return Map(
        "appId", GetYoudaoSetting("appPaidID", ""),
        "appKey", GetYoudaoSetting("appPaidKey", ""),
        "youdaoTargetLanguage", GetYoudaoSetting("targetLanguage", ""))
}

TranslateRegisterProvider("youdao", Map(
    "streaming", 0,
    "configured", YoudaoConfigured,
    "translate", TranslateProviderYoudaoTranslate,
    "test", TranslateProviderYoudaoTest,
    "save", TranslateProviderYoudaoSave,
    "push", TranslateProviderYoudaoPush,
    "notConfigured", ["Youdao translation is not configured. Open Settings.",
        "未配置有道翻译，请点右上角「设置」填写。"],
    "saveEmpty", ["the app ID and app secret", "应用ID和应用密钥"]))
