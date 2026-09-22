#Requires AutoHotkey v2.0
; Standalone diagnostic: exercise WriteIniValue (copied from core.ahk) on a temp copy.

WriteIniValue(filePath, section, key, value) {
    content := FileExist(filePath) ? FileRead(filePath, "UTF-8") : ""
    content := StrReplace(content, "`r`n", "`n")
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
    fileObject := FileOpen(filePath, "w", "UTF-8-RAW")
    if !IsObject(fileObject)
        throw Error("Cannot open settings file for writing: " . filePath)
    fileObject.Write(newContent)
    fileObject.Close()
}

testFile := A_Temp . "\capslock_p2_ini_test.ini"
FileCopy("D:\develop\project\cpaslock_p2\capslock_p2.ini", testFile, true)

; 1. create [LLMTranslate] with Chinese value
WriteIniValue(testFile, "LLMTranslate", "targetLanguage", "简体中文")
; 2. replace existing key in [Keys]
WriteIniValue(testFile, "Keys", "press_caps", "keyFunc_send(^{Space})")
; 3. append new key into existing [Global]
WriteIniValue(testFile, "Global", "mouseSpeed", "5")
; 4. replace key created in step 1
WriteIniValue(testFile, "LLMTranslate", "targetLanguage", "English")

content := FileRead(testFile, "UTF-8")
FileAppend(content, "*", "UTF-8")
FileDelete(testFile)
