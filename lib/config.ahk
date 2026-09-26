; Configuration storage and typed access for capslock_p2.
; This file owns the UTF-8 INI document and typed access.

global SettingsFile := A_ScriptDir . "\capslock_p2.ini"
global Config := Map()
global SettingsModifyTime := ""

ConfigLoad() {
    global Config, SettingsFile, SettingsModifyTime

    Config := ConfigParseIni(SettingsFile)
    ConfigApplyDefaults()
    for section in ["Global", "TabHotString", "Keys", "LLM", "LLMTranslate", "QAI", "QSearch", "QRun", "QWeb", "Qbar", "TTranslate", "TYoudao", "TVolcengine"] {
        if !Config.Has(section)
            Config[section] := Map()
    }
    SettingsModifyTime := ConfigFileModifyTime()
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

ConfigApplyDefaults() {
    global Config, SettingsFile
    defaultsPath := A_ScriptDir . "\capslock_p2-defaults.ini"
    if !FileExist(defaultsPath)
        defaultsPath := A_ScriptDir . "\tools\capslock_p2-default.ini"
    if !FileExist(defaultsPath)
        return

    defaults := ConfigParseIni(defaultsPath)
    for section, values in defaults {
        if !Config.Has(section)
            Config[section] := Map()
        for key, value in values {
            if Config[section].Has(key)
                continue
            Config[section][key] := value
            try ConfigWriteValue(SettingsFile, section, key, value)
            catch
                continue
        }
    }
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
