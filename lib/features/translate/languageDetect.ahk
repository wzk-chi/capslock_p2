; Windows ELS supplies language candidates in relevance order. Choose the first
; candidate matching the configured A/B pair; the API exposes no numeric score.
; An empty candidate list can still select a pair with distinct writing systems.
; Native layouts and ownership follow the Microsoft ELS documentation.

TranslateDetectLanguage(text, languageA, languageB) {
    text := Trim(String(text))
    result := Map("status", "ambiguous", "language", "", "reason", "", "candidates", [])
    if text = "" {
        result["status"] := "unsupported"
        result["reason"] := "empty"
        return result
    }
    if !RegExMatch(text, "\p{L}") {
        result["status"] := "unsupported"
        result["reason"] := "no-letters"
        return result
    }

    try {
        service := TranslateElsDetector.GetService()
        if !service {
            result["status"] := "unavailable"
            result["reason"] := TranslateElsDetector.unavailableReason
            return result
        }
        normalized := TranslateElsDetector.Normalize(text)
        candidates := TranslateElsDetector.Recognize(service, normalized)
        result["candidates"] := candidates
        result["reason"] := candidates.Length ? "els-no-pair-candidate" : "els-no-candidates"
        if !candidates.Length {
            source := TranslateElsPairScriptLanguage(normalized, languageA, languageB)
            if source != "" {
                result["status"] := "recognized"
                result["language"] := source
                result["reason"] := "els-empty-pair-script"
            }
            return result
        }
        distinguishChinese := InStr(languageA, "zh-") = 1 && InStr(languageB, "zh-") = 1
        for candidate in candidates {
            matchesA := TranslateElsCandidateMatches(candidate, languageA, distinguishChinese)
            matchesB := TranslateElsCandidateMatches(candidate, languageB, distinguishChinese)
            if matchesA && matchesB {
                result["reason"] := "els-shared-chinese-candidate"
                return result
            }
            if matchesA || matchesB {
                result["status"] := "recognized"
                result["language"] := matchesA ? languageA : languageB
                result["reason"] := "els-pair-candidate"
                return result
            }
        }
    } catch as detectionError {
        result["status"] := "unavailable"
        result["reason"] := "els-recognition-error"
        DebugLog("translate ELS recognition failed type=" . Type(detectionError)
            . " where=" . detectionError.What . " detail=" . detectionError.Message)
    }
    return result
}

TranslateElsPairScriptLanguage(text, languageA, languageB) {
    patternA := TranslateElsPairScriptPattern(languageA)
    patternB := TranslateElsPairScriptPattern(languageB)
    if patternA = patternB
        return ""
    ; All letters must fit exactly one side. Shared scripts or mixed letters
    ; remain uncertain; punctuation and numbers do not determine direction.
    letters := RegExReplace(text, "[^\p{L}]", "")
    matchesA := RegExMatch(letters, "^" . patternA . "+$") != 0
    matchesB := RegExMatch(letters, "^" . patternB . "+$") != 0
    return matchesA = matchesB ? "" : (matchesA ? languageA : languageB)
}

TranslateElsPairScriptPattern(language) {
    switch language {
        case "zh-CN", "zh-TW":
            return "[\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{F900}-\x{FAFF}]"
        case "ja":
            return "[\x{3040}-\x{30FF}\x{31F0}-\x{31FF}\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{F900}-\x{FAFF}]"
        case "ko":
            return "[\x{AC00}-\x{D7AF}\x{1100}-\x{11FF}\x{3130}-\x{318F}]"
        case "ru":
            return "[\x{0400}-\x{04FF}\x{0500}-\x{052F}]"
        case "ar":
            return "[\x{0600}-\x{06FF}\x{0750}-\x{077F}\x{08A0}-\x{08FF}]"
        default:
            return "[A-Za-zÀ-ÖØ-öø-ɏ]"
    }
}

TranslateElsCandidateMatches(candidate, language, distinguishChinese) {
    tag := StrLower(candidate)
    base := StrSplit(tag, "-")[1]
    if base != "zh"
        return base = language
    if InStr(language, "zh-") != 1
        return false
    if !distinguishChinese
        return true

    variant := TranslateNormalizeLanguage(tag)
    if variant = "" {
        if RegExMatch(tag, "^zh-hans(?:-|$)")
            variant := "zh-CN"
        else if RegExMatch(tag, "^zh-hant(?:-|$)")
            variant := "zh-TW"
        else if RegExMatch(tag, "^zh-(?:cn|sg)(?:-|$)")
            variant := "zh-CN"
        else if RegExMatch(tag, "^zh-(?:tw|hk|mo)(?:-|$)")
            variant := "zh-TW"
    }
    ; Neutral Chinese fits both variants and cannot select their direction.
    return variant = "" || variant = language
}

class TranslateElsDetector {
    static module := 0
    static services := 0
    static initialized := false
    static unavailableReason := ""

    static GetService() {
        if this.initialized
            return this.services
        this.initialized := true
        this.unavailableReason := "els-service-unavailable"
        try {
            this.module := DllCall("Kernel32\LoadLibraryW",
                "wstr", A_WinDir . "\System32\elscore.dll", "ptr")
            if !this.module
                throw OSError(A_LastError, -1, "LoadLibraryW(elscore)")
            guid := LLMGuid("{CF7E00B1-909B-4D95-A8F4-611F7C377702}")
            ; MAPPING_ENUM_OPTIONS: nine pointer-sized fields, then bit flags.
            options := Buffer(A_PtrSize = 8 ? 80 : 40, 0)
            NumPut("uptr", options.Size, options, 0)
            NumPut("ptr", guid.Ptr, options, 8 * A_PtrSize)
            services := 0
            count := 0
            hr := DllCall("Elscore\MappingGetServices", "ptr", options,
                "ptr*", &services, "uint*", &count, "int")
            if hr != 0
                throw Error("MappingGetServices hr=" . Format("0x{:08X}", hr & 0xFFFFFFFF))
            this.services := services
            if !services || !count {
                this.unavailableReason := "els-service-missing"
                this.Release()
                DebugLog("translate ELS service missing count=" . count)
                return 0
            }
            DebugLog("translate ELS service ready count=" . count . " ptrSize=" . A_PtrSize)
        } catch as serviceError {
            this.Release()
            DebugLog("translate ELS initialization failed type=" . Type(serviceError)
                . " where=" . serviceError.What . " detail=" . serviceError.Message)
        }
        return this.services
    }

    static Normalize(text) {
        ; ELS language detection requires NFC-normalized UTF-16 text.
        required := DllCall("Normaliz\NormalizeString", "int", 1, "wstr", text,
            "int", StrLen(text), "ptr", 0, "int", 0, "int")
        if required <= 0
            throw OSError(A_LastError, -1, "NormalizeString(size)")
        Loop 10 {
            normalizedBuffer := Buffer(required * 2, 0)
            written := DllCall("Normaliz\NormalizeString", "int", 1, "wstr", text,
                "int", StrLen(text), "ptr", normalizedBuffer, "int", required, "int")
            if written > 0
                return StrGet(normalizedBuffer, written, "UTF-16")
            if A_LastError != 122 || written = 0
                throw OSError(A_LastError, -1, "NormalizeString")
            required := -written
        }
        throw Error("NormalizeString buffer estimate did not converge")
    }

    static Recognize(service, text) {
        ; MAPPING_PROPERTY_BAG: 64 bytes on x64, 32 bytes on x86.
        bag := Buffer(A_PtrSize = 8 ? 64 : 32, 0)
        NumPut("uptr", bag.Size, bag, 0)
        hr := DllCall("Elscore\MappingRecognizeText", "ptr", service, "wstr", text,
            "uint", StrLen(text), "uint", 0, "ptr", 0, "ptr", bag, "int")
        if hr != 0
            throw Error("MappingRecognizeText hr=" . Format("0x{:08X}", hr & 0xFFFFFFFF))
        ; The input text remains alive until this bag has been freed.
        try {
            count := NumGet(bag, 2 * A_PtrSize, "uint")
            if !count {
                DebugLog("translate ELS no candidates chars=" . StrLen(text) . " ranges=0")
                return []
            }
            ranges := NumGet(bag, A_PtrSize, "ptr")
            if count != 1 || !ranges
                throw Error("ELS language detection returned unexpected range count=" . count)
            ; MAPPING_DATA_RANGE.pData is at 24/16; dwDataSize follows it.
            dataOffset := A_PtrSize = 8 ? 24 : 16
            data := NumGet(ranges, dataOffset, "ptr")
            bytes := NumGet(ranges, dataOffset + A_PtrSize, "uint")
            candidates := this.ReadCandidates(data, bytes)
            if !candidates.Length
                DebugLog("translate ELS no candidates chars=" . StrLen(text) . " bytes=" . bytes)
            return candidates
        } finally {
            hr := DllCall("Elscore\MappingFreePropertyBag", "ptr", bag, "int")
            if hr != 0
                DebugLog("translate ELS property bag release hr=" . Format("0x{:08X}", hr & 0xFFFFFFFF))
        }
    }

    static ReadCandidates(data, bytes) {
        ; Parse MULTI_SZ within the service-reported byte count.
        if !data || bytes < 2 || Mod(bytes, 2)
            throw Error("ELS language candidate buffer is invalid bytes=" . bytes)
        ; An empty MULTI_SZ may contain only the terminating empty string (2
        ; bytes). Microsoft samples stop at the first NUL, including this case.
        if NumGet(data, 0, "ushort") = 0
            return []
        if bytes < 4 || NumGet(data, bytes - 2, "ushort") != 0 || NumGet(data, bytes - 4, "ushort") != 0
            throw Error("ELS language candidate buffer is not double-null terminated")
        candidates := []
        offset := 0
        characters := bytes // 2
        while offset < characters {
            length := 0
            while offset + length < characters && NumGet(data, (offset + length) * 2, "ushort") != 0
                length++
            if !length
                return candidates
            tag := StrGet(data + offset * 2, length, "UTF-16")
            if !RegExMatch(tag, "i)^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$")
                throw Error("ELS returned an invalid language tag")
            candidates.Push(tag)
            offset += length + 1
        }
        return candidates
    }

    static Release() {
        if this.services {
            hr := DllCall("Elscore\MappingFreeServices", "ptr", this.services, "int")
            this.services := 0
            if hr != 0
                DebugLog("translate ELS service release hr=" . Format("0x{:08X}", hr & 0xFFFFFFFF))
        }
        if this.module {
            DllCall("Kernel32\FreeLibrary", "ptr", this.module)
            this.module := 0
        }
    }
}

TranslateLanguageDetectShutdown(*) {
    TranslateElsDetector.Release()
}
