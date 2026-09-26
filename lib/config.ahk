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
    ConfigDefaults := ConfigParseIni(defaultsPath)
    Config := ConfigParseIni(defaultsPath)
    ConfigOverlay(Config, ConfigParseIni(SettingsFile))
    for section in ["Global", "TabHotString", "Keys", "LLM", "LLMTranslate", "QAI", "QSearch", "QRun", "QWeb", "Qbar", "CustomHotkey", "TTranslate", "TYoudao", "TVolcengine"] {
        if !Config.Has(section)
            Config[section] := Map()
    }
    SettingsModifyTime := ConfigFileModifyTime()
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

ConfigHas(section, key) {
    global Config
    return Config.Has(section) && Config[section].Has(key)
}

ConfigSection(section) {
    global Config
    return Config.Has(section) ? Config[section] : Map()
}

ConfigSectionExists(section) {
    global Config
    return Config.Has(section)
}

ConfigFileModifyTime() {
    global SettingsFile
    if !FileExist(SettingsFile)
        return ""
    try return FileGetTime(SettingsFile, "M")
    catch
        return ""
}

ConfigWrite(section, key, value) {
    changes := Map()
    changes[section] := Map()
    changes[section][key] := String(value)
    ConfigWriteBatch(changes)
}

ConfigWriteBatch(changes) {
    global SettingsFile
    ConfigWriteFile(SettingsFile, changes)
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
        for key, value in values
            content := ConfigSetIniValue(content, String(section), String(key), String(value))
    }
    ConfigAtomicWrite(filePath, content)
}

; Save only explicit user overrides. Values equal to the canonical default are
; removed from the user file so a later default update can take effect.
ConfigWriteUserOverrides(changes) {
    global SettingsFile
    if !IsObject(changes)
        return
    original := FileExist(SettingsFile) ? FileRead(SettingsFile, "UTF-8") : ""
    original := StrReplace(original, "`r`n", "`n")
    content := original
    for section, values in changes {
        if !IsObject(values)
            continue
        for key, value in values {
            sectionName := String(section)
            keyName := String(key)
            valueText := String(value)
            if ConfigDefaultHas(sectionName, keyName)
                && valueText = String(ConfigDefaultRead(sectionName, keyName))
                content := ConfigDeleteIniValue(content, sectionName, keyName)
            else
                content := ConfigSetIniValue(content, sectionName, keyName, valueText)
        }
    }
    if content != original
        ConfigAtomicWrite(SettingsFile, content)
}

ConfigSetIniValue(content, section, key, value) {
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

    newContent := ""
    for line in out
        newContent .= line . "`n"
    return newContent
}

ConfigDeleteIniValue(content, section, key) {
    if content = ""
        return content
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
    newContent := ""
    for line in out
        newContent .= line . "`n"
    return newContent
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
