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

; Stable codes, display labels, request names and aliases live here. Pages
; receive only codes and labels; provider-specific transport codes stay in
; each provider adapter.
TranslateLanguageCatalog() {
    static catalog := [
        Map("code", "zh-CN", "labelZh", "简体中文", "labelEn", "Simplified Chinese",
            "aliases", ["zh-CN", "zh-Hans", "zh-CHS", "简体中文", "Simplified Chinese"]),
        Map("code", "zh-TW", "labelZh", "繁體中文", "labelEn", "Traditional Chinese",
            "aliases", ["zh-TW", "zh-Hant", "zh-CHT", "繁體中文", "traditional Chinese"]),
        Map("code", "en", "labelZh", "English", "labelEn", "English",
            "aliases", ["en", "English", "英文", "英语"]),
        Map("code", "ja", "labelZh", "日本語", "labelEn", "Japanese",
            "aliases", ["ja", "Japanese", "日本語", "日语", "日文"]),
        Map("code", "ko", "labelZh", "한국어", "labelEn", "Korean",
            "aliases", ["ko", "Korean", "한국어", "韩语"]),
        Map("code", "fr", "labelZh", "Français", "labelEn", "French",
            "aliases", ["fr", "French", "français", "法语", "法文"]),
        Map("code", "de", "labelZh", "Deutsch", "labelEn", "German",
            "aliases", ["de", "German", "Deutsch", "德语", "德文"]),
        Map("code", "es", "labelZh", "Español", "labelEn", "Spanish",
            "aliases", ["es", "Spanish", "español", "西班牙语"]),
        Map("code", "ru", "labelZh", "Русский", "labelEn", "Russian",
            "aliases", ["ru", "Russian", "русский", "俄语"]),
        Map("code", "it", "labelZh", "Italiano", "labelEn", "Italian",
            "aliases", ["it", "Italian", "italiano", "意大利语"]),
        Map("code", "pt", "labelZh", "Português", "labelEn", "Portuguese",
            "aliases", ["pt", "Portuguese", "português", "葡萄牙语"]),
        Map("code", "ar", "labelZh", "العربية", "labelEn", "Arabic",
            "aliases", ["ar", "Arabic", "العربية", "阿拉伯语"])]
    return catalog
}

TranslateLanguageCatalogSnapshot() {
    snapshot := []
    for language in TranslateLanguageCatalog()
        snapshot.Push(Map("code", language["code"], "labelZh", language["labelZh"],
            "labelEn", language["labelEn"]))
    return snapshot
}

TranslateLanguageCodes() {
    codes := []
    for language in TranslateLanguageCatalog()
        codes.Push(language["code"])
    return codes
}

TranslateLanguageName(value) {
    normalized := TranslateNormalizeLanguage(value, true)
    if normalized = "system"
        return "System language"
    for language in TranslateLanguageCatalog()
        if language["code"] = normalized
            return language["labelEn"]
    return String(value)
}

TranslateLanguageAliasMap() {
    static aliases := TranslateBuildLanguageAliasMap()
    return aliases
}

TranslateBuildLanguageAliasMap() {
    aliases := Map()
    for language in TranslateLanguageCatalog()
        for alias in language["aliases"]
            aliases[StrLower(Trim(String(alias)))] := language["code"]
    return aliases
}

TranslateNormalizeLanguage(value, allowSystem := false) {
    lowered := StrLower(Trim(String(value)))
    if allowSystem && lowered = "system"
        return "system"
    aliases := TranslateLanguageAliasMap()
    return aliases.Has(lowered) ? aliases[lowered] : ""
}

TranslateSystemLanguageCode() {
    code := TranslateNormalizeLanguage(SystemLanguageName())
    return code = "" ? "en" : code
}

TranslateLanguageSupported(value) {
    return TranslateNormalizeLanguage(value) != ""
}

TranslateOptionsSnapshot() {
    languageA := TranslateNormalizeLanguage(GetTranslateSetting("languageA", ""))
    languageB := TranslateNormalizeLanguage(GetTranslateSetting("languageB", ""))
    target := TranslateNormalizeLanguage(GetTranslateSetting("targetLanguage", ""), true)
    return Map(
        "mode", Trim(GetTranslateSetting("mode", "")),
        "languageA", languageA = "" ? "zh-CN" : languageA,
        "languageB", languageB = "" ? "en" : languageB,
        "targetLanguage", target = "" ? "system" : target)
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

    detected := TranslateDetectLanguage(text, languageA, languageB)
    result["fallback"] := detected["status"] != "recognized"
    source := result["fallback"] ? languageB : detected["language"]
    target := source = languageA ? languageB : languageA
    result["status"] := "ready"
    result["sourceLanguage"] := source
    result["targetLanguage"] := target
    result["manual"] := false
    candidates := ""
    for candidate in detected["candidates"]
        candidates .= (candidates = "" ? "" : ",") . candidate
    DebugLog("translate direction pair=" . languageA . "/" . languageB
        . " status=" . detected["status"] . " reason=" . detected["reason"]
        . " candidates=" . candidates . " source=" . source . " target=" . target)
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
