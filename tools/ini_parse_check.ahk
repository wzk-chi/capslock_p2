#Requires AutoHotkey v2.0
; Standalone diagnostic: replicate ParseIniFile from core.ahk and dump [Keys].

ParseIniFile(filePath) {
    sections := Map()
    if !FileExist(filePath)
        return sections
    try content := FileRead(filePath, "UTF-8")
    catch as e {
        FileAppend("FileRead FAILED: " . e.Message . "`n", "*", "UTF-8")
        return sections
    }
    content := StrReplace(content, "`r")
    currentSection := ""
    for line in StrSplit(content, "`n") {
        FileAppend("LINE: <" . line . ">`n", "*", "UTF-8")
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

config := ParseIniFile("D:\develop\project\cpaslock_p2\capslock_p2.ini")
FileAppend("Sections: " . config.Count . "`n", "*", "UTF-8")
for name in config
    FileAppend("  section: [" . name . "] count=" . config[name].Count . "`n", "*", "UTF-8")
if config.Has("Keys") {
    for k, v in config["Keys"]
        FileAppend("  Keys." . k . " = <" . v . ">`n", "*", "UTF-8")
} else {
    FileAppend("NO [Keys] section parsed!`n", "*", "UTF-8")
}
