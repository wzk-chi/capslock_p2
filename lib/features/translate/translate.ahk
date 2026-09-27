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
;   translate      function (text, onDelta, onFinished, overrides) -> stream id
;                  Runs one translation. Must finish by calling
;                  onFinished(answer, success, errorText); `answer` is the
;                  complete text shown in the panel. One-shot engines call it
;                  once and return 0; streaming engines return the id the
;                  panel can abort on hide/shutdown.
;   test           optional function (msg, &ok, &text) -> fixed "Hello" API test
;   notConfigured  [english, chinese] panel error when pinned but unconfigured

global TranslateRegistry := 0

; Translation-wide settings are shared by every provider. Provider-specific
; credentials stay in that provider's own section.
GetTranslateSetting(key, defaultValue := "") {
    return ConfigRead("TTranslate", key, defaultValue)
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
