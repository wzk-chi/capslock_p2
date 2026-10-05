; Translation provider registry. Every translation engine is one client file
; (lib\features\translate\*Translate.ahk) plus a registration entry at the bottom of that file;
; the translate panel (lib\features\translate\llmTranslate.ahk) talks to engines only through
; this registry, so adding an engine means adding one file and one
; registration — translation dispatch routes by engine name;
; the central settings page writes configuration sections directly.
;
; A provider is a Map with:
;   key            engine name as written in [TTranslate] engine (lowercase)
;   streaming      1 when the engine reports fragments via onDelta before
;                  completion (the panel shows the streaming UI for these)
;   configured     function () -> true when the engine is ready to translate
;   translate      function (text, onDelta, onFinished, overrides) -> operation
;                  Starts one translation without blocking. Must call
;                  onFinished(answer, success, errorText) exactly once unless
;                  cancelled, and return an idempotent operation.Cancel().
;                  `answer` is the complete text shown in the panel. One-shot
;                  engines call onFinished once; streaming engines may first
;                  report fragments through onDelta.
;   test           optional function (msg, onFinished) -> operation
;                  Starts a fixed "Hello" API check and calls
;                  onFinished(success, text) once unless cancelled. It also
;                  returns an idempotent operation.Cancel().
;   notConfigured  [english, chinese] panel error when pinned but unconfigured

global TranslateRegistry := 0

; Translation-wide settings are shared by every provider. Provider-specific
; credentials stay in that provider's own section.
GetTranslateSetting(key, defaultValue := "") {
    return ConfigRead("TTranslate", key, defaultValue)
}

; The language list is shared by the settings page, direction resolver and
; provider adapters. Keep the stored values as stable BCP-47-like codes and
; translate them to each provider's own code only at the transport boundary.
TranslateLanguageCodes() {
    return ["zh-CN", "zh-TW", "en", "ja", "ko", "fr", "de", "es", "ru", "it", "pt", "ar"]
}

TranslateLanguageName(value) {
    normalized := TranslateNormalizeLanguage(value, true)
    static names := Map(
        "zh-cn", "Simplified Chinese", "zh-tw", "Traditional Chinese",
        "en", "English", "ja", "Japanese", "ko", "Korean", "fr", "French",
        "de", "German", "es", "Spanish", "ru", "Russian", "it", "Italian",
        "pt", "Portuguese", "ar", "Arabic", "system", "System language")
    lowered := StrLower(normalized)
    return names.Has(lowered) ? names[lowered] : String(value)
}

TranslateNormalizeLanguage(value, allowSystem := false) {
    raw := Trim(String(value))
    lowered := StrLower(raw)
    static aliases := Map(
        "zh-cn", "zh-CN", "zh-hans", "zh-CN", "zh-chs", "zh-CN",
        "简体中文", "zh-CN", "simplified chinese", "zh-CN",
        "zh-tw", "zh-TW", "zh-hant", "zh-TW", "zh-cht", "zh-TW",
        "繁體中文", "zh-TW", "traditional chinese", "zh-TW",
        "en", "en", "english", "en", "英文", "en", "英语", "en",
        "ja", "ja", "japanese", "ja", "日本語", "ja", "日语", "ja", "日文", "ja",
        "ko", "ko", "korean", "ko", "한국어", "ko", "韩语", "ko",
        "fr", "fr", "french", "fr", "français", "fr", "法语", "fr", "法文", "fr",
        "de", "de", "german", "de", "deutsch", "de", "德语", "de", "德文", "de",
        "es", "es", "spanish", "es", "español", "es", "西班牙语", "es",
        "ru", "ru", "russian", "ru", "русский", "ru", "俄语", "ru",
        "it", "it", "italian", "it", "italiano", "it", "意大利语", "it",
        "pt", "pt", "portuguese", "pt", "português", "pt", "葡萄牙语", "pt",
        "ar", "ar", "arabic", "ar", "العربية", "ar", "阿拉伯语", "ar")
    if allowSystem && lowered = "system"
        return "system"
    return aliases.Has(lowered) ? aliases[lowered] : ""
}

TranslateSystemLanguageCode() {
    code := TranslateNormalizeLanguage(SystemLanguageName())
    return code = "" ? "en" : code
}

TranslateLanguageSupported(value) {
    code := TranslateNormalizeLanguage(value)
    if code = ""
        return false
    for candidate in TranslateLanguageCodes()
        if candidate = code
            return true
    return false
}

TranslateOptionsSnapshot() {
    return Map(
        "mode", Trim(GetTranslateSetting("mode", "")),
        "languageA", Trim(GetTranslateSetting("languageA", "")),
        "languageB", Trim(GetTranslateSetting("languageB", "")),
        "targetLanguage", Trim(GetTranslateSetting("targetLanguage", "")))
}

TranslateValidateOptions(options, &errorText := "") {
    errorText := ""
    if !IsObject(options) {
        errorText := LLMText("Translation settings are unavailable.", "翻译设置不可用。")
        return false
    }
    mode := StrLower(Trim(options.Has("mode") ? String(options["mode"]) : ""))
    if mode != "fixed" && mode != "bidirectional" {
        errorText := LLMText("Choose a valid translation mode.", "请选择有效的翻译方式。")
        return false
    }
    if mode = "fixed" {
        target := TranslateNormalizeLanguage(options.Has("targetLanguage") ? options["targetLanguage"] : "", true)
        if target = "" {
            errorText := LLMText("Choose a valid target language.", "请选择有效的目标语言。")
            return false
        }
        return true
    }
    languageA := TranslateNormalizeLanguage(options.Has("languageA") ? options["languageA"] : "")
    languageB := TranslateNormalizeLanguage(options.Has("languageB") ? options["languageB"] : "")
    if languageA = "" || languageB = "" {
        errorText := LLMText("Choose both languages for bidirectional translation.", "互译模式需要选择两种语言。")
        return false
    }
    if languageA = languageB {
        errorText := LLMText("The two translation languages must be different.", "互译的两种语言不能相同。")
        return false
    }
    return true
}

TranslateMatchLanguage(detected, languageA, languageB) {
    rawDetected := StrLower(Trim(String(detected)))
    detected := TranslateNormalizeLanguage(detected)
    if detected = "" && rawDetected = "zh"
        detected := "zh"
    if detected = languageA
        return languageA
    if detected = languageB
        return languageB
    ; A detector may know that text is Chinese without enough evidence to
    ; distinguish simplified and traditional variants. That is safe only when
    ; the configured pair contains one Chinese option.
    if detected = "zh" {
        aChinese := InStr(StrLower(languageA), "zh-") = 1
        bChinese := InStr(StrLower(languageB), "zh-") = 1
        if aChinese && !bChinese
            return languageA
        if bChinese && !aChinese
            return languageB
    }
    return ""
}

; Resolve one request's source and target before a provider is called. The
; returned map is a request snapshot: providers must consume its target rather
; than re-reading the global mode or trying to detect the source themselves.
TranslateResolveDirection(text, options, sourceOverride := "", targetOverride := "", manual := false) {
    result := Map("status", "error", "sourceLanguage", "", "targetLanguage", "",
        "manual", manual ? true : false, "fallback", false, "message", "")
    if !TranslateValidateOptions(options, &validationError) {
        result["message"] := validationError
        return result
    }
    mode := StrLower(Trim(String(options["mode"])))
    if mode = "fixed" {
        target := TranslateNormalizeLanguage(options["targetLanguage"], true)
        if target = "system"
            target := TranslateSystemLanguageCode()
        result["status"] := "ready"
        result["sourceLanguage"] := "auto"
        result["targetLanguage"] := target
        result["manual"] := false
        return result
    }

    languageA := TranslateNormalizeLanguage(options["languageA"])
    languageB := TranslateNormalizeLanguage(options["languageB"])
    if manual {
        source := TranslateNormalizeLanguage(sourceOverride)
        target := TranslateNormalizeLanguage(targetOverride)
        if source = "" || target = "" || source = target
            || !TranslateLanguageSupported(source)
            || !TranslateLanguageSupported(target) {
            result["message"] := LLMText("Choose two different supported languages.", "请选择两种不同的支持语言。")
            return result
        }
        result["status"] := "ready"
        result["sourceLanguage"] := source
        result["targetLanguage"] := target
        return result
    }

    detected := TranslateDetectLanguage(text)
    if !IsObject(detected) || detected["status"] != "recognized" {
        ; Short identifiers, code, and mixed text may not contain enough
        ; evidence for the local detector. Fall back to B -> A so the
        ; configured first language remains the default target.
        result["status"] := "ready"
        result["sourceLanguage"] := languageB
        result["targetLanguage"] := languageA
        result["manual"] := false
        result["fallback"] := true
        return result
    }
    source := TranslateMatchLanguage(detected["language"], languageA, languageB)
    if source = "" {
        ; A recognized language outside the configured pair cannot select a
        ; valid automatic direction. Use the same safe default target A.
        result["status"] := "ready"
        result["sourceLanguage"] := languageB
        result["targetLanguage"] := languageA
        result["manual"] := false
        result["fallback"] := true
        return result
    }
    target := source = languageA ? languageB : languageA
    result["status"] := "ready"
    result["sourceLanguage"] := source
    result["targetLanguage"] := target
    result["manual"] := false
    return result
}

TranslateSettingWith(key, defaultValue, overrides) {
    if IsObject(overrides) && overrides.Has(key)
        return overrides[key]
    return GetTranslateSetting(key, defaultValue)
}

TranslateRegisterProvider(key, provider) {
    global TranslateRegistry
    if !IsObject(TranslateRegistry)
        TranslateRegistry := Map()
    provider["key"] := key
    TranslateRegistry[key] := provider
}

TranslateProviders() {
    global TranslateRegistry
    if !IsObject(TranslateRegistry)
        TranslateRegistry := Map()
    return TranslateRegistry
}

TranslateProviderExists(key) {
    return TranslateProviders().Has(StrLower(Trim(key)))
}

TranslateGetProvider(key) {
    providers := TranslateProviders()
    key := StrLower(Trim(key))
    if providers.Has(key)
        return providers[key]
    return 0
}

; Resolve the provider a request should run on. A pinned engine is returned
; as-is even when unconfigured so the caller can show its notConfigured
; message; "auto" picks the first configured provider, preferring "llm".
TranslateResolve(engine) {
    providers := TranslateProviders()
    if engine != "auto" {
        if providers.Has(engine)
            return providers[engine]
        return 0
    }
    if providers.Has("llm") && providers["llm"]["configured"].Call()
        return providers["llm"]
    for key, provider in providers
        if provider["configured"].Call()
            return provider
    return 0
}
