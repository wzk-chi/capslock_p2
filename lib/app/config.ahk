; Configuration storage and typed access for capslock_p2.
; The root capslock_p2-default.ini is loaded first; capslock_p2.ini overlays it.
; This file owns the UTF-8 user INI document and typed access.

global SettingsFile := A_ScriptDir . "\capslock_p2.ini"
global Config := Map()
global ConfigDefaults := Map()
global SettingsModifyTime := ""

ConfigLoad() {
    global Config, ConfigDefaults, SettingsFile, SettingsModifyTime

    defaultsPath := ConfigDefaultPath()
    defaultsRaw := ConfigParseIni(defaultsPath)
    userRaw := ConfigParseIni(SettingsFile)
    ConfigOverlay(defaultsRaw, userRaw)
    ConfigDefaults := ConfigDecodeDocument(ConfigParseIni(defaultsPath))
    Config := ConfigDecodeDocument(defaultsRaw)
    for section in ConfigSchemaSections() {
        if !Config.Has(section)
            Config[section] := Map()
    }
    SettingsModifyTime := ConfigFileModifyTime()
}

; One metadata boundary for values accepted by the live settings surface. The
; INI files remain the source of defaults; this map only describes type, codec
; and editability. Dynamic sections accept user keys under the generic key
; restrictions enforced by ConfigValidateValue().
ConfigSchema() {
    static schema := Map(
        "Global", Map("kind", "static", "keys", Map(
            "autostart", Map("type", "bool"),
            "mouseSpeed", Map("type", "int", "min", 1, "max", 20),
            "allowClipboard", Map("type", "bool"),
            "debug", Map("type", "bool"),
            "loadingAnimation", Map("type", "bool"),
            "language", Map("type", "enum", "values", ["0", "1", "2"]),
            "runAsAdmin", Map("type", "bool"),
            ; Internal first-run state; it is persisted but intentionally has
            ; no control in the settings page.
            "usageShown", Map("type", "bool"))),
        "LLM", Map("kind", "static", "keys", Map(
            "endpoint", Map("type", "text"),
            "apiKey", Map("type", "secret"),
            "apiKeyHeader", Map("type", "text", "emptyDefault", "Authorization"),
            "apiKeyPrefix", Map("type", "text"),
            "model", Map("type", "text"),
            "thinking", Map("type", "bool"),
            "temperature", Map("type", "optionalNumber"),
            "timeout", Map("type", "int", "min", 1000, "max", 120000),
            "maxInputTokens", Map("type", "optionalPositiveInt"))),
        "LLMTranslate", Map("kind", "static", "keys", Map(
            "systemPrompt", Map("type", "text", "codec", "jsonScalar"))),
        "TTranslate", Map("kind", "static", "keys", Map(
            "mode", Map("type", "enum", "values", ["fixed", "bidirectional"]),
            "languageA", Map("type", "enum", "values", ["zh-CN", "zh-TW", "en", "ja", "ko", "fr", "de", "es", "ru", "it", "pt", "ar"]),
            "languageB", Map("type", "enum", "values", ["zh-CN", "zh-TW", "en", "ja", "ko", "fr", "de", "es", "ru", "it", "pt", "ar"]),
            "targetLanguage", Map("type", "enum", "values", ["system", "zh-CN", "zh-TW", "en", "ja", "ko", "fr", "de", "es", "ru", "it", "pt", "ar"]),
            "engine", Map("type", "enum", "values", ["auto", "llm", "youdao", "volcengine"]))),
        "TYoudao", Map("kind", "static", "keys", Map(
            "appPaidID", Map("type", "secret"),
            "appPaidKey", Map("type", "secret"))),
        "TVolcengine", Map("kind", "static", "keys", Map(
            "accessKey", Map("type", "secret"),
            "secretKey", Map("type", "secret"),
            "region", Map("type", "text"))),
        "QAI", Map("kind", "static", "keys", Map(
            "systemPrompt", Map("type", "text", "codec", "jsonScalar"))),
        "Qbar", Map("kind", "static", "keys", Map(
            "esMaxResults", Map("type", "int", "min", 1, "max", 500))),
        "ClipboardHistory", Map("kind", "static", "keys", Map(
            "enabled", Map("type", "bool"),
            "maxItems", Map("type", "int", "min", 20, "max", 5000),
            "maxCaptureBytes", Map("type", "int", "min", 1048576, "max", 536870912),
            "retentionDays", Map("type", "int", "min", 1, "max", 3650))),
        "Keys", Map("kind", "keys"),
        "TabHotString", Map("kind", "dynamic", "codec", "hotString"),
        "CustomHotkey", Map("kind", "dynamic", "codec", "plain"))
    return schema
}

ConfigSchemaSections() {
    return ["Global", "TabHotString", "Keys", "LLM", "LLMTranslate", "QAI",
        "Qbar", "ClipboardHistory", "CustomHotkey", "TTranslate",
        "TYoudao", "TVolcengine"]
}

ConfigField(section, key) {
    schema := ConfigSchema()
    if !schema.Has(section)
        return 0
    record := schema[section]
    if !record.Has("keys") || !record["keys"].Has(key)
        return 0
    return record["keys"][key]
}

ConfigIsDynamicSection(section) {
    schema := ConfigSchema()
    return schema.Has(section) && schema[section].Has("kind")
        && schema[section]["kind"] = "dynamic"
}

ConfigValidateKey(section, key) {
    key := String(key)
    if key = "" || RegExMatch(key, "[=`r`n]") || StrLen(key) > 120
        return false
    if section != "CustomHotkey" && RegExMatch(key, "[\[\]]")
        return false
    if section = "Keys"
        return RegExMatch(key, "i)^(press_caps|caps(_lalt)?_[A-Za-z0-9_]+)$")
    field := ConfigField(section, key)
    return IsObject(field) || ConfigIsDynamicSection(section)
}

ConfigValidateValue(section, key, value, &normalized := "") {
    normalized := ""
    if !ConfigValidateKey(section, key) || IsObject(value)
        return false
    text := String(value)
    field := ConfigField(section, key)
    if !IsObject(field) {
        if section = "Keys" {
            normalized := text
            return !RegExMatch(text, "[`r`n]")
        }
        if ConfigIsDynamicSection(section) {
            normalized := text
            if section = "TabHotString"
                return true
            return !RegExMatch(text, "[`r`n]")
        }
        return false
    }

    valueType := field.Has("type") ? field["type"] : "text"
    switch valueType {
        case "bool":
            lowered := StrLower(Trim(text))
            if lowered = "1" || lowered = "true" || lowered = "on"
                normalized := "1"
            else if lowered = "0" || lowered = "false" || lowered = "off"
                normalized := "0"
            else
                return false
        case "int":
            if !RegExMatch(Trim(text), "^-?\d+$")
                return false
            parsedInteger := Integer(text)
            if field.Has("min") && parsedInteger < field["min"]
                return false
            if field.Has("max") && parsedInteger > field["max"]
                return false
            normalized := String(parsedInteger)
        case "optionalPositiveInt":
            if Trim(text) = "" {
                normalized := ""
            } else {
                if !RegExMatch(Trim(text), "^\d+$") || Integer(text) < 1
                    return false
                normalized := String(Integer(text))
            }
        case "optionalNumber":
            if Trim(text) = "" {
                normalized := ""
            } else {
                if !RegExMatch(Trim(text), "^-?(?:\d+\.?\d*|\.\d+)$")
                    return false
                normalized := Trim(text)
            }
        case "enum":
            normalized := Trim(text)
            enumMatch := false
            for candidate in field["values"] {
                if StrLower(candidate) = StrLower(normalized) {
                    normalized := candidate
                    enumMatch := true
                    break
                }
            }
            if !enumMatch
                return false
        case "text", "secret":
            if (!field.Has("codec") || field["codec"] != "jsonScalar") {
                if RegExMatch(text, "[`r`n]")
                    return false
            }
            normalized := text
        default:
            return false
    }
    return true
}

ConfigDecodeDocument(source) {
    result := Map()
    if !IsObject(source)
        return result
    for section, values in source {
        result[section] := Map()
        if !IsObject(values)
            continue
        for key, value in values
            result[section][key] := ConfigDecodeValue(section, key, value)
    }
    return result
}

ConfigDecodeValue(section, key, storedValue) {
    field := ConfigField(section, key)
    codec := IsObject(field) && field.Has("codec") ? field["codec"]
        : (ConfigSchema().Has(section) && ConfigSchema()[section].Has("codec")
            ? ConfigSchema()[section]["codec"] : "plain")
    if codec = "hotString"
        return ConfigDecodeHotString(storedValue)
    if codec = "jsonScalar"
        return ConfigDecodeJsonScalar(storedValue)
    return String(storedValue)
}

ConfigEncodeValue(section, key, logicalValue) {
    field := ConfigField(section, key)
    codec := IsObject(field) && field.Has("codec") ? field["codec"]
        : (ConfigSchema().Has(section) && ConfigSchema()[section].Has("codec")
            ? ConfigSchema()[section]["codec"] : "plain")
    if codec = "hotString"
        return ConfigEncodeHotString(logicalValue)
    if codec = "jsonScalar"
        return ConfigEncodeJsonScalar(logicalValue)
    return String(logicalValue)
}

ConfigDecodeHotString(storedValue) {
    value := String(storedValue)
    result := ""
    index := 1
    while index <= StrLen(value) {
        character := SubStr(value, index, 1)
        if character = "\" && index < StrLen(value) {
            nextCharacter := SubStr(value, index + 1, 1)
            if nextCharacter = "n" {
                result .= "`n"
                index += 2
                continue
            }
            if nextCharacter = "\" {
                result .= "\"
                index += 2
                continue
            }
        }
        result .= character
        index += 1
    }
    return result
}

ConfigEncodeHotString(logicalValue) {
    value := StrReplace(StrReplace(StrReplace(String(logicalValue), "`r`n", "`n"), "`r", ""), "\", "\\")
    return StrReplace(value, "`n", "\n")
}

ConfigEncodeJsonScalar(logicalValue) {
    ; JSON.stringify only accepts objects in the bundled library, so wrap the
    ; scalar in an array and remove the array brackets.
    return "@capslock-json1:" . SubStr(JSON.stringify([String(logicalValue)], 0), 2, -1)
}

ConfigDecodeJsonScalar(storedValue) {
    value := String(storedValue)
    prefix := "@capslock-json1:"
    if SubStr(value, 1, StrLen(prefix)) != prefix
        return value
    try parsed := JSON.Parse("[" . SubStr(value, StrLen(prefix) + 1) . "]")
    catch
        return value
    return IsObject(parsed) && parsed.Length ? String(parsed[1]) : value
}

ConfigDefaultPath() {
    return A_ScriptDir . "\capslock_p2-default.ini"
}

ConfigOverlay(target, overlay) {
    if !IsObject(overlay)
        return
    for section, values in overlay {
        if !target.Has(section)
            target[section] := Map()
        for key, value in values
            target[section][key] := value
    }
}

ConfigRead(section, key, defaultValue := "") {
    global Config
    if Config.Has(section) && Config[section].Has(key)
        return Config[section][key]
    return defaultValue
}

ConfigGlobalRead(key, defaultValue := "") {
    return ConfigRead("Global", key, defaultValue)
}

ConfigSection(section) {
    global Config
    return Config.Has(section) ? Config[section] : Map()
}

ConfigSnapshot() {
    global Config
    return ConfigClone(Config)
}

ConfigClone(document) {
    result := Map()
    if !IsObject(document)
        return result
    for section, values in document {
        result[section] := Map()
        if !IsObject(values)
            continue
        for key, value in values
            result[section][key] := IsObject(value) ? ConfigClone(value) : String(value)
    }
    return result
}

ConfigEffectiveDiff(previous, current) {
    changes := Map()
    sections := Map()
    if IsObject(previous)
        for section, values in previous
            sections[section] := true
    if IsObject(current)
        for section, values in current
            sections[section] := true
    for section in sections {
        oldValues := IsObject(previous) && previous.Has(section) ? previous[section] : Map()
        newValues := IsObject(current) && current.Has(section) ? current[section] : Map()
        keys := Map()
        if IsObject(oldValues)
            for key, value in oldValues
                keys[key] := true
        if IsObject(newValues)
            for key, value in newValues
                keys[key] := true
        for key in keys {
            oldHasKey := IsObject(oldValues) && oldValues.Has(key)
            newHasKey := IsObject(newValues) && newValues.Has(key)
            oldValue := oldHasKey ? String(oldValues[key]) : ""
            newValue := newHasKey ? String(newValues[key]) : ""
            if oldHasKey = newHasKey && oldValue = newValue
                continue
            if !changes.Has(section)
                changes[section] := Map()
            changes[section][key] := newValue
        }
    }
    return changes
}

ConfigFileModifyTime() {
    global SettingsFile
    if !FileExist(SettingsFile)
        return ""
    try return FileGetTime(SettingsFile, "M")
    catch
        return ""
}

ConfigDefaultHas(section, key) {
    global ConfigDefaults
    return ConfigDefaults.Has(section) && ConfigDefaults[section].Has(key)
}

ConfigDefaultRead(section, key, defaultValue := "") {
    global ConfigDefaults
    if ConfigDefaults.Has(section) && ConfigDefaults[section].Has(key)
        return ConfigDefaults[section][key]
    return defaultValue
}

ConfigParseIni(filePath) {
    sections := Map()
    if !FileExist(filePath)
        return sections

    ; Force UTF-8: an ANSI (GBK) decode of a UTF-8 file can swallow the LF
    ; after a multi-byte character, merging the next line into a comment.
    try content := FileRead(filePath, "UTF-8")
    catch
        return sections

    content := StrReplace(content, "`r")
    currentSection := ""
    for line in StrSplit(content, "`n") {
        line := Trim(line)
        if line = "" || SubStr(line, 1, 1) = ";"
            continue

        if SubStr(line, 1, 1) = "[" && SubStr(line, -1) = "]" {
            currentSection := Trim(SubStr(line, 2, StrLen(line) - 2))
            if !sections.Has(currentSection)
                sections[currentSection] := Map()
            continue
        }

        if currentSection = ""
            continue
        equalPosition := InStr(line, "=")
        if !equalPosition
            continue
        key := Trim(SubStr(line, 1, equalPosition - 1))
        value := Trim(SubStr(line, equalPosition + 1))
        if key != ""
            sections[currentSection][key] := value
    }
    return sections
}

; The document is updated in memory and moved into place only after the
; complete file is written to a sibling temporary file.
ConfigWriteValue(filePath, section, key, value) {
    changes := Map()
    changes[section] := Map()
    changes[section][key] := String(value)
    ConfigWriteFile(filePath, changes)
}

ConfigWriteFile(filePath, changes) {
    content := FileExist(filePath) ? FileRead(filePath, "UTF-8") : ""
    content := StrReplace(content, "`r`n", "`n")
    for section, values in changes {
        if !IsObject(values)
            continue
        for key, value in values {
            sectionName := String(section)
            keyName := String(key)
            normalized := ""
            if !ConfigValidateValue(sectionName, keyName, value, &normalized)
                throw ValueError("Invalid setting value", -1, sectionName . "/" . keyName)
            content := ConfigSetIniValue(content, sectionName, keyName,
                ConfigEncodeValue(sectionName, keyName, normalized))
        }
    }
    ConfigAtomicWrite(filePath, content)
}

; Save only explicit user overrides. Values equal to the canonical default are
; removed from the user file so a later default update can take effect.
ConfigWriteUserOverrides(changes, &fileChanged := false, &invalidChange := "") {
    global SettingsFile, SettingsModifyTime, Config
    fileChanged := false
    invalidChange := ""
    effectiveChanges := Map()
    if !IsObject(changes)
        return effectiveChanges
    original := FileExist(SettingsFile) ? FileRead(SettingsFile, "UTF-8") : ""
    original := StrReplace(original, "`r`n", "`n")
    content := original
    for section, values in changes {
        if !IsObject(values)
            continue
        for key, value in values {
            sectionName := String(section)
            keyName := String(key)
            normalized := ""
            if !ConfigValidateValue(sectionName, keyName, value, &normalized) {
                invalidChange := sectionName . "/" . keyName
                return Map()
            }
            currentValue := ConfigRead(sectionName, keyName,
                ConfigDefaultRead(sectionName, keyName, ""))
            if normalized != String(currentValue) {
                if !effectiveChanges.Has(sectionName)
                    effectiveChanges[sectionName] := Map()
                effectiveChanges[sectionName][keyName] := normalized
            }
            if ConfigDefaultHas(sectionName, keyName)
                && normalized = String(ConfigDefaultRead(sectionName, keyName))
                content := ConfigDeleteIniValue(content, sectionName, keyName)
            else
                content := ConfigSetIniValue(content, sectionName, keyName,
                    ConfigEncodeValue(sectionName, keyName, normalized))
        }
    }
    if content != original {
        ConfigAtomicWrite(SettingsFile, content)
        fileChanged := true
        SettingsModifyTime := ConfigFileModifyTime()
    }
    return effectiveChanges
}

ConfigSetIniValue(content, section, key, value) {
    content := StrReplace(content, "`r", "")
    content := RTrim(content, "`n")
    lines := StrSplit(content, "`n")
    out := []
    currentSection := ""
    sectionFound := false
    keyReplaced := false

    for line in lines {
        trimmed := Trim(line)
        if SubStr(trimmed, 1, 1) = "[" && SubStr(trimmed, -1) = "]" {
            if currentSection = section && !keyReplaced {
                out.Push(key . "=" . value)
                keyReplaced := true
            }
            currentSection := SubStr(trimmed, 2, StrLen(trimmed) - 2)
            if currentSection = section
                sectionFound := true
            out.Push(line)
            continue
        }
        if currentSection = section && !keyReplaced {
            equalPosition := InStr(trimmed, "=")
            if equalPosition && SubStr(trimmed, 1, 1) != ";" && Trim(SubStr(trimmed, 1, equalPosition - 1)) = key {
                out.Push(key . "=" . value)
                keyReplaced := true
                continue
            }
        }
        out.Push(line)
    }
    if currentSection = section && !keyReplaced {
        out.Push(key . "=" . value)
        keyReplaced := true
    }
    if !sectionFound {
        if out.Length && Trim(out[out.Length]) != ""
            out.Push("")
        out.Push("[" . section . "]")
        out.Push(key . "=" . value)
    }

    return ConfigJoinIniLines(out)
}

ConfigDeleteIniValue(content, section, key) {
    if content = ""
        return content
    content := StrReplace(content, "`r", "")
    content := RTrim(content, "`n")
    lines := StrSplit(content, "`n")
    out := []
    currentSection := ""
    removed := false
    for line in lines {
        trimmed := Trim(line)
        if SubStr(trimmed, 1, 1) = "[" && SubStr(trimmed, -1) = "]" {
            currentSection := SubStr(trimmed, 2, StrLen(trimmed) - 2)
            out.Push(line)
            continue
        }
        if currentSection = section {
            equalPosition := InStr(trimmed, "=")
            if equalPosition && SubStr(trimmed, 1, 1) != ";"
                && Trim(SubStr(trimmed, 1, equalPosition - 1)) = key {
                removed := true
                continue
            }
        }
        out.Push(line)
    }
    if !removed
        return content
    return ConfigJoinIniLines(out)
}

ConfigJoinIniLines(lines) {
    while lines.Length && lines[lines.Length] = ""
        lines.Pop()
    if !lines.Length
        return ""
    content := ""
    for line in lines
        content .= line . "`n"
    return content
}

ConfigAtomicWrite(filePath, content) {
    tempPath := filePath . ".tmp." . A_TickCount
    fileObject := 0
    try {
        fileObject := FileOpen(tempPath, "w", "UTF-8-RAW")
        if !IsObject(fileObject)
            throw Error("Cannot open settings temp file: " . tempPath)
        fileObject.Write(content)
        fileObject.Close()
        fileObject := 0
        FileMove(tempPath, filePath, true)
    } catch as writeError {
        if IsObject(fileObject)
            try fileObject.Close()
        try FileDelete(tempPath)
        throw writeError
    }
}
