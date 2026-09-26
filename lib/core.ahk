; capslock_p2 — AHK v2 core services.
; The legacy v1 files are kept in the repository for reference, but the v2
; entry point includes only the v2 modules.

global AppName := "capslock_p2"
global AppVersion := "0.1.1"
global DebugLogFile := A_ScriptDir . "\capslock_p2-debug.log"
global DebugLogging := false
global KeySet := Map()
global CapsLockHeld := false
global CapsLockUsed := false
global CtrlZPending := true
global AllowClipboardWatcher := true
global ClipboardWatcherSuspended := false
global WhichClipboardNow := 0
global SystemClipboard := 0
global CapsClipboard := 0
global CapsAltClipboard := 0
global HotStringKeys := []
global LoadingGui := 0
global LoadingText := 0
global LoadingFrames := []
global LoadingFrameIndex := 1
global TrayMenuObject := 0
global TraySettingsLabel := ""
global TrayAutostartLabel := ""
global TrayLoadingLabel := ""

Initialize() {
    global

    SetWorkingDir(A_ScriptDir)
    CoordMode("Mouse", "Screen")
    iconPath := A_ScriptDir . "\resources\capslock_p2-icon.png"
    try TraySetIcon(iconPath)
    try ProcessSetPriority("High")
    try SetStoreCapslockMode("Off")
    SetCapsLockState("Off")

    ConfigLoad()
    BuildKeySet()
    ApplyGlobalSettings()
    TrayMenuInitialize()
    DebugLog("Initialize settings=" . SettingsFile)
    if ConfigGlobalRead("loadingAnimation") != "0"
        ShowLoading()

    InitializeWindowBindings()
    InitializeMouseSpeed()
    RebuildHotStringPattern()
    RegisterCapsHotkeys()
    RegisterFeatureHotkeys()
    OnClipboardChange(HandleClipboardChange)
    DebugLog("Hotkeys and clipboard watcher registered")

    SettingsModifyTime := ConfigFileModifyTime()
    SetTimer(MonitorSettings, 500)
    SetTimer(HotStringInit, -1)

    if ConfigGlobalRead("loadingAnimation") != "0" {
        Sleep(80)
        HideLoading()
    }
    DebugLog("Initialize complete")
}

Shutdown(*) {
    try SetTimer(MouseSpeedTick, 0)
    try RestoreMouseSpeed()
    try LLMTranslateShutdown()
    try SettingsShutdown()
    try DictionaryShutdown()
    try AiChatShutdown()
    try QbarShutdown()
    try ShowSystemCursor()
    try HideLoading()
}

ReloadSettings(*) {
    ConfigLoad()
    BuildKeySet()
    ApplyGlobalSettings()
    InitializeMouseSpeed()
    RebuildHotStringPattern()
    DebugLog("Settings reloaded")
}

ApplyGlobalSettings() {
    global AllowClipboardWatcher, DebugLogging
    AllowClipboardWatcher := ConfigGlobalRead("allowClipboard") != "0"
    DebugLogging := ConfigGlobalRead("debug") = "1"
    DebugLog("Global settings applied clipboard=" . AllowClipboardWatcher . " debug=" . DebugLogging)
    EnsureAutostartShortcut(ConfigGlobalRead("autostart") = "1")
    TrayMenuRefresh()
}

DebugLog(message) {
    global DebugLogFile, DebugLogging
    if !DebugLogging
        return
    try FileAppend(
        FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") . " [" . A_TickCount . "] " . message . "`n",
        DebugLogFile,
        "UTF-8"
    )
}

; Private payloads are represented by their length only. Never pass user text,
; clipboard content, API credentials, or local paths directly to DebugLog.
DebugLogPrivate(label, value) {
    DebugLog(label . " length=" . StrLen(String(value)))
}

SettingInteger(section, key, fallback, minimum, maximum) {
    global Config
    value := fallback
    if Config.Has(section) && Config[section].Has(key)
        value := Config[section][key]
    if !RegExMatch(Trim(String(value)), "^-?\d+$")
        return fallback
    number := Integer(value)
    return Max(minimum, Min(maximum, number))
}

SettingNumber(section, key, fallback, minimum, maximum) {
    global Config
    value := fallback
    if Config.Has(section) && Config[section].Has(key)
        value := Config[section][key]
    if !RegExMatch(Trim(String(value)), "^-?(?:\d+\.?\d*|\.\d+)$")
        return fallback
    number := value + 0
    return Max(minimum, Min(maximum, number))
}

MonitorSettings() {
    global SettingsModifyTime
    currentTime := ConfigFileModifyTime()
    if currentTime = SettingsModifyTime
        return
    SettingsModifyTime := currentTime
    ReloadSettings()
}

ConfigSet(section, key, value) {
    global Config, SettingsFile, SettingsModifyTime
    value := String(value)
    try {
        ConfigWriteValue(SettingsFile, section, key, value)
    } catch as writeError {
        ShowMsg("Unable to write settings: " . writeError.Message, 2500)
        return false
    }
    if !Config.Has(section)
        Config[section] := Map()
    Config[section][key] := value
    SettingsModifyTime := ConfigFileModifyTime()
    ApplySettingChange(section, key, value)
    return true
}

ApplySettingChange(section, key, value) {
    global AllowClipboardWatcher, DebugLogging, MouseSpeed
    if section = "Global" {
        switch key {
            case "allowClipboard":
                AllowClipboardWatcher := value != "0"
            case "debug":
                DebugLogging := value = "1"
            case "mouseSpeed":
                MouseSpeed := SettingInteger("Global", "mouseSpeed", 3, 1, 20)
            case "autostart":
                EnsureAutostartShortcut(value = "1")
                TrayMenuRefresh()
            case "loadingAnimation", "language":
                TrayMenuRefresh()
        }
        return
    }

    switch section {
        case "Keys":
            BuildKeySet()
        case "TabHotString", "QRun", "QWeb":
            RebuildHotStringPattern()
    }
}

EnsureAutostartShortcut(enabled) {
    linkPath := A_Startup . "\capslock_p2.lnk"
    legacyLinkPath := A_StartupCommon . "\capslock_p2.lnk"

    ; Older builds used the common Startup folder. Remove only our own legacy
    ; shortcut so an unrelated file with the same name is never touched.
    AutostartRemoveOwnedShortcut(legacyLinkPath)

    if !enabled {
        AutostartRemoveOwnedShortcut(linkPath)
        return
    }

    if FileExist(linkPath) {
        target := ""
        try {
            FileGetShortcut(linkPath, &target)
        } catch {
            ; A non-shortcut file with this name is not ours; leave it alone.
            return
        }
        if target = A_ScriptFullPath
            return
        try FileDelete(linkPath)
    }

    try FileCreateShortcut(A_ScriptFullPath, linkPath, A_ScriptDir)
    catch
        return
}

AutostartRemoveOwnedShortcut(linkPath) {
    if !FileExist(linkPath)
        return
    target := ""
    try FileGetShortcut(linkPath, &target)
    catch
        return
    if target = A_ScriptFullPath
        try FileDelete(linkPath)
}

TrayMenuInitialize() {
    global TrayMenuObject, TraySettingsLabel, TrayAutostartLabel, TrayLoadingLabel
    if IsObject(TrayMenuObject)
        return
    TrayMenuObject := A_TrayMenu
    TraySettingsLabel := TraySettingsText()
    TrayAutostartLabel := TrayAutostartText()
    TrayLoadingLabel := TrayLoadingText()
    ; Insert custom entries before the standard tray items (Open/Exit, ...).
    TrayMenuObject.Insert("1&", TraySettingsLabel, TrayOpenSettings)
    TrayMenuObject.Insert("2&", TrayAutostartLabel, TrayToggleAutostart)
    TrayMenuObject.Insert("3&", TrayLoadingLabel, TrayToggleLoadingAnimation)
    TrayMenuRefresh()
}

TrayMenuRefresh() {
    global TrayMenuObject, TraySettingsLabel, TrayAutostartLabel, TrayLoadingLabel
    if !IsObject(TrayMenuObject)
        return

    newSettingsLabel := TraySettingsText()
    if TraySettingsLabel != "" && newSettingsLabel != TraySettingsLabel {
        try TrayMenuObject.Rename(TraySettingsLabel, newSettingsLabel)
        catch
            return
        TraySettingsLabel := newSettingsLabel
    }
    newAutostartLabel := TrayAutostartText()
    if TrayAutostartLabel != "" && newAutostartLabel != TrayAutostartLabel {
        try TrayMenuObject.Rename(TrayAutostartLabel, newAutostartLabel)
        catch
            return
        TrayAutostartLabel := newAutostartLabel
    }

    newLoadingLabel := TrayLoadingText()
    if TrayLoadingLabel != "" && newLoadingLabel != TrayLoadingLabel {
        try TrayMenuObject.Rename(TrayLoadingLabel, newLoadingLabel)
        catch
            return
        TrayLoadingLabel := newLoadingLabel
    }

    try {
        if ConfigGlobalRead("autostart") = "1"
            TrayMenuObject.Check(TrayAutostartLabel)
        else
            TrayMenuObject.Uncheck(TrayAutostartLabel)
        if ConfigGlobalRead("loadingAnimation") != "0"
            TrayMenuObject.Check(TrayLoadingLabel)
        else
            TrayMenuObject.Uncheck(TrayLoadingLabel)
    } catch {
        return
    }
}

TrayOpenSettings(*) {
    SettingsShow()
}

TraySettingsText() {
    return IsChineseLanguage() ? "设置" : "Settings"
}

TrayAutostartText() {
    return IsChineseLanguage() ? "开机自启动" : "Launch at startup"
}

TrayLoadingText() {
    return IsChineseLanguage() ? "启动动画" : "Startup animation"
}

TrayToggleAutostart(*) {
    enabled := ConfigGlobalRead("autostart") = "1"
    ConfigSet("Global", "autostart", enabled ? "0" : "1")
}

TrayToggleLoadingAnimation(*) {
    enabled := ConfigGlobalRead("loadingAnimation") != "0"
    ConfigSet("Global", "loadingAnimation", enabled ? "0" : "1")
}

HotStringInit(*) {
    RebuildHotStringPattern()
}

RebuildHotStringPattern() {
    global HotStringKeys
    HotStringKeys := []
    ; The CapsLock+Tab tail match draws from all three value sections, like the
    ; reference CLhotString: a configured run or web entry can be expanded in an
    ; editor too. QRun/QWeb keys carry a "<display>" suffix, so they are matched
    ; by their short key; TabHotString keys have none and pass through unchanged.
    for section in ["TabHotString", "QRun", "QWeb"] {
        for key, value in ConfigSection(section) {
            short := QbarShortKey(key)
            if short != ""
                HotStringKeys.Push(short)
        }
    }
}

GetHotStringReplacement(text, &matchedKey := "") {
    global Config, HotStringKeys
    matchedKey := ""
    for key in HotStringKeys {
        if StrLen(text) < StrLen(key) || SubStr(text, -StrLen(key)) != key
            continue
        replacement := HotStringValue(key)
        if replacement = ""
            continue
        matchedKey := key
        return SubStr(text, 1, StrLen(text) - StrLen(key)) . replacement
    }
    return ""
}

; The value a hotstring key expands to, searched TabHotString -> QRun -> QWeb
; like the reference CLhotString. Only TabHotString values take the escapes
; (see HotStringUnescape). Run and web values are used as written.
HotStringValue(key) {
    value := ConfigRead("TabHotString", key, "")
    if value != ""
        return HotStringUnescape(value)
    for section in ["QRun", "QWeb"] {
        for candidate, value in ConfigSection(section) {
            if QbarShortKey(candidate) = key && Trim(value) != ""
                return value
        }
    }
    return ""
}

; TabHotString value escapes, C style: "\n" becomes a real newline and "\\"
; a single backslash -- so a literal "\n" is written "\\n". Any other
; backslash pair is kept as written, so values like "D:\docs" need no escape.
HotStringUnescape(value) {
    result := ""
    index := 1
    length := StrLen(value)
    while index <= length {
        character := SubStr(value, index, 1)
        if character = "\" && index < length {
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

CLhotString() {
    global A_Clipboard
    matched := ""
    replacement := GetHotStringReplacement(A_Clipboard, &matched)
    if matched = ""
        return ""
    A_Clipboard := replacement
    return matched
}

RunConfiguredAction(actionText) {
    actionText := Trim(actionText)
    if actionText = ""
        return

    openPosition := InStr(actionText, "(")
    if !openPosition {
        functionName := actionText
        argumentText := ""
    } else {
        functionName := Trim(SubStr(actionText, 1, openPosition - 1))
        argumentText := SubStr(actionText, openPosition + 1)
        if SubStr(argumentText, -1) = ")"
            argumentText := SubStr(argumentText, 1, StrLen(argumentText) - 1)
    }

    if !RegExMatch(functionName, "i)^[A-Za-z_][A-Za-z0-9_]*$")
        return
    if !RegExMatch(functionName, "i)^keyFunc_")
        return

    DebugLog("Action function=" . functionName)

    try functionObject := %functionName%
    catch as functionError {
        DebugLog("Unknown key function=" . functionName . " error=" . functionError.Message)
        ShowMsg("Unknown key function: " . functionName, 2500)
        return
    }

    if !HasMethod(functionObject, "Call") {
        DebugLog("Non-callable key function=" . functionName)
        ShowMsg("Unknown key function: " . functionName, 2500)
        return
    }

    arguments := SplitActionArguments(argumentText)
    try functionObject.Call(arguments*)
    catch as functionError {
        DebugLog("Action failed function=" . functionName . " error=" . functionError.Message)
        ShowMsg(functionName . ": " . functionError.Message, 3000)
    }
}

SplitActionArguments(argumentText) {
    arguments := []
    if Trim(argumentText) = ""
        return arguments

    quoteCharacter := ""
    current := ""
    index := 1
    length := StrLen(argumentText)
    while index <= length {
        character := SubStr(argumentText, index, 1)
        if quoteCharacter != "" {
            if character = quoteCharacter {
                if index < length && SubStr(argumentText, index + 1, 1) = quoteCharacter {
                    current .= quoteCharacter
                    index += 2
                    continue
                }
                quoteCharacter := ""
            } else {
                current .= character
            }
        } else if character = Chr(34) || character = "'" {
            quoteCharacter := character
        } else if character = "," {
            arguments.Push(Trim(current))
            current := ""
        } else {
            current .= character
        }
        index += 1
    }
    arguments.Push(Trim(current))
    return arguments
}

; Copies the active selection and restores the clipboard. A copy that ends
; with a newline is ambiguous — a real line-wise selection, or an editor
; copying the current line because nothing is selected (the reference's
; getSelText discarded both; its comment names the trailing newline). The
; mode picks the trade-off:
;   "strict"    keep the reference behavior; a trailing newline means "no
;               real selection", so callers' no-selection fallbacks fire.
;   "multiline" keep certain selections: a copy with an interior newline is
;               a real multi-line selection, a bare line-copy is discarded.
;   "any"       keep everything and just drop the trailing newline; used
;               where a wrong guess is visible and editable (qbar prefill).
GetSelectedText(mode := "strict") {
    global A_Clipboard, ClipboardWatcherSuspended
    oldClipboard := ClipboardAll()
    result := ""
    ClipboardWatcherSuspended := true
    try {
        A_Clipboard := ""
        SendInput("^{Insert}")
        if ClipWait(0.15) {
            result := A_Clipboard
            if SubStr(result, -1) = "`n" {
                if mode = "any"
                    result := RTrim(result, "`r`n")
                else if !(mode = "multiline" && InStr(result, "`n", , 1, 2))
                    result := ""
            }
        }
    } finally {
        A_Clipboard := oldClipboard
        ClipboardWatcherSuspended := false
    }
    return result
}

; Compatibility helpers for existing user extensions.
getSelText() {
    return GetSelectedText()
}

runFunc(actionText) {
    RunConfiguredAction(actionText)
}

clipSaver(clipX) {
    global WhichClipboardNow
    slot := clipX = "s" ? 0 : (clipX = "c" ? 1 : 2)
    SaveClipboardSlot(slot)
    WhichClipboardNow := slot
}

HandleClipboardChange(dataType) {
    global AllowClipboardWatcher, ClipboardWatcherSuspended, CapsLockHeld, WhichClipboardNow, SystemClipboard
    DebugLog("ClipboardChange type=" . dataType . " suspended=" . ClipboardWatcherSuspended . " capsHeld=" . CapsLockHeld . " allowed=" . AllowClipboardWatcher)
    if ClipboardWatcherSuspended || CapsLockHeld || !AllowClipboardWatcher
        return
    try {
        SystemClipboard := ClipboardAll()
        WhichClipboardNow := 0
    } catch
        return
}

SaveClipboardSlot(slot) {
    global CapsClipboard, CapsAltClipboard, SystemClipboard
    savedClipboard := ClipboardAll()
    if slot = 0
        SystemClipboard := savedClipboard
    else if slot = 1
        CapsClipboard := savedClipboard
    else
        CapsAltClipboard := savedClipboard
}

RestoreClipboard(data) {
    global A_Clipboard
    if IsObject(data)
        A_Clipboard := data
    else
        A_Clipboard := ""
}

ClipboardEnabled() {
    return ConfigGlobalRead("allowClipboard") != "0"
}

CopyToClipboardSlot(slot, isCut := false) {
    global A_Clipboard, ClipboardWatcherSuspended, WhichClipboardNow
    if !ClipboardEnabled()
        return

    oldClipboard := ClipboardAll()
    success := false
    ClipboardWatcherSuspended := true
    try {
        A_Clipboard := ""
        SendInput(isCut ? "^x" : "^{Insert}")
        success := ClipWait(0.15)
        if !success {
            SendInput("{Home}+{End}" . (isCut ? "^x" : "^{Insert}") . (isCut ? "" : "{End}"))
            success := ClipWait(0.15)
        }
        if success {
            SaveClipboardSlot(slot)
            WhichClipboardNow := slot
        } else {
            RestoreClipboard(oldClipboard)
        }
    } finally {
        ClipboardWatcherSuspended := false
    }
}

PasteClipboardSlot(slot) {
    global A_Clipboard, CapsClipboard, CapsAltClipboard, WhichClipboardNow, ClipboardWatcherSuspended
    if !ClipboardEnabled()
        return
    savedClipboard := slot = 1 ? CapsClipboard : CapsAltClipboard
    if !IsObject(savedClipboard)
        return

    if WhichClipboardNow != slot {
        ClipboardWatcherSuspended := true
        try A_Clipboard := savedClipboard
        finally ClipboardWatcherSuspended := false
        WhichClipboardNow := slot
    }
    SendInput("^v")
}

PasteSystemClipboard() {
    global A_Clipboard, SystemClipboard, WhichClipboardNow, ClipboardWatcherSuspended
    if WhichClipboardNow != 0 && IsObject(SystemClipboard) {
        ClipboardWatcherSuspended := true
        try A_Clipboard := SystemClipboard
        finally ClipboardWatcherSuspended := false
        WhichClipboardNow := 0
    }
    SendInput("^v")
}

ShowMsg(message, duration := 2000) {
    ToolTip(message)
    SetTimer(ClearToolTip, -duration)
}

ClearToolTip(*) {
    ToolTip()
}

FixDpi(dpiValue) {
    return Ceil(dpiValue / 96 * A_ScreenDPI)
}

; Panel default sizes in logical px, scaled with the primary screen — 1x at
; 1920x1080, larger on bigger displays, clamped to the panel's minimums and
; to 90%/85% of the work area so nothing overflows small screens. Screen dims
; are physical px; dividing by the DPI ratio brings them into the same logical
; space FixDpi maps back out of.
ScreenFitSize(defaultWidth, defaultHeight, minWidth := 0, minHeight := 0) {
    dpiRatio := A_ScreenDPI / 96
    screenW := A_ScreenWidth / dpiRatio
    screenH := A_ScreenHeight / dpiRatio
    scale := Min(screenW / 1920, screenH / 1080)
    width := Max(minWidth, Min(defaultWidth * scale, screenW * 0.9))
    height := Max(minHeight, Min(defaultHeight * scale, screenH * 0.85))
    return [Round(width), Round(height)]
}

CheckStringType(value, fuzzy := false) {
    if FileExist(value)
        return InStr(FileExist(value), "D") ? "folder" : "file"
    if RegExMatch(value, "i)^ftp://")
        return "ftp"
    if RegExMatch(value, "i)^(https?://|www\.)")
        return "web"
    return fuzzy ? "fileOrFolder" : "unknown"
}

ExtractSetString(value, &runString := "", &runAsAdmin := false, &parameters := "") {
    value := Trim(value)
    if value = ""
        return ""
    if RegExMatch(value, "i)^\*RunAs\s+(.+)$", &adminMatch) {
        runAsAdmin := true
        value := Trim(adminMatch[1])
    }

    if SubStr(value, 1, 1) = Chr(34) {
        closingQuote := InStr(value, Chr(34), false, 2)
        if closingQuote {
            runString := SubStr(value, 1, closingQuote)
            parameters := Trim(SubStr(value, closingQuote + 1))
            executable := SubStr(value, 2, closingQuote - 2)
        } else {
            executable := value
            runString := value
        }
    } else {
        pieces := StrSplit(value, A_Space, A_Space)
        executable := pieces.Length ? pieces[1] : value
        runString := value
    }
    return FileExist(executable) ? executable : ""
}

SetClipboardText(text) {
    global A_Clipboard, ClipboardWatcherSuspended
    oldClipboard := ClipboardAll()
    ClipboardWatcherSuspended := true
    try {
        A_Clipboard := text
        SendInput("^v")
        Sleep(60)
    } finally {
        A_Clipboard := oldClipboard
        ClipboardWatcherSuspended := false
    }
}

IsChineseLanguage() {
    languageSetting := ConfigGlobalRead("language")
    if languageSetting = "1"
        return true
    if languageSetting = "2"
        return false

    return IsChineseSystemLanguage()
}

IsChineseSystemLanguage() {
    switch A_Language {
        case "0804", "1004", "7c04":
            return true
        case "0404", "0c04", "1404":
            return true
        default:
            return false
    }
}

SystemLanguageName() {
    try languageId := Integer("0x" . A_Language)
    catch
        return "English"

    primary := languageId & 0x3ff
    subLanguage := (languageId >> 10) & 0x3f
    switch primary {
        case 0x04:
            return (subLanguage = 1 || subLanguage = 3 || subLanguage = 5) ? "Traditional Chinese" : "Simplified Chinese"
        case 0x09:
            return "English"
        case 0x0a:
            return "Spanish"
        case 0x0c:
            return "French"
        case 0x07:
            return "German"
        case 0x10:
            return "Italian"
        case 0x11:
            return "Japanese"
        case 0x12:
            return "Korean"
        case 0x16:
            return "Portuguese"
        case 0x19:
            return "Russian"
        case 0x01:
            return "Arabic"
        default:
            return "English"
    }
}

ShowLoading() {
    global LoadingGui, LoadingText, LoadingFrames, LoadingFrameIndex
    if IsObject(LoadingGui)
        return

    dark := LoadingIsDarkTheme()
    background := dark ? "20242B" : "F7F8FC"
    foreground := dark ? "F4F7FB" : "20242B"
    muted := dark ? "AAB4C4" : "697386"
    accent := dark ? "8DB0F5" : "356AE6"
    LoadingFrames := ["", " ·", " ··", " ···"]
    LoadingFrameIndex := 1

    LoadingGui := Gui("-Caption +AlwaysOnTop +ToolWindow", "capslock_p2")
    LoadingGui.OnEvent("Escape", HideLoading)
    LoadingGui.BackColor := background
    LoadingGui.SetFont("s15 c" . foreground, "Segoe UI Semibold")
    LoadingGui.AddText("x28 y22 w284 h28", "capslock_p2")
    LoadingGui.SetFont("s9 c" . muted, "Segoe UI")
    LoadingGui.AddText("x28 y54 w284 h18", IsChineseLanguage() ? "正在准备工作区" : "Preparing workspace")
    LoadingGui.SetFont("s9 c" . accent, "Segoe UI")
    LoadingGui.AddText("x28 y80 w14 h18", "●")
    LoadingGui.SetFont("s9 c" . muted, "Segoe UI")
    LoadingText := LoadingGui.AddText("x48 y80 w264 h18", (IsChineseLanguage() ? "正在启动" : "Starting") . LoadingFrames[1])
    LoadingGui.Show("w340 h126 Center NA")
    LoadingApplyRegion()
    try WinSetTransparent(248, "ahk_id " . LoadingGui.Hwnd)
    SetTimer(AnimateLoading, 220)
}

LoadingIsDarkTheme() {
    try return RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) = 0
    catch
        return false
}

LoadingApplyRegion() {
    global LoadingGui
    if !IsObject(LoadingGui)
        return
    region := DllCall("CreateRoundRectRgn", "int", 0, "int", 0, "int", 341, "int", 127, "int", 24, "int", 24, "ptr")
    if !region
        return
    if !DllCall("SetWindowRgn", "ptr", LoadingGui.Hwnd, "ptr", region, "int", 1)
        DllCall("DeleteObject", "ptr", region)
}

HideLoading(*) {
    global LoadingGui, LoadingText
    SetTimer(AnimateLoading, 0)
    if IsObject(LoadingGui) {
        try LoadingGui.Destroy()
        LoadingGui := 0
        LoadingText := 0
    }
}

AnimateLoading(*) {
    global LoadingGui, LoadingText, LoadingFrames, LoadingFrameIndex
    if !IsObject(LoadingGui) || !IsObject(LoadingText)
        return
    LoadingFrameIndex := Mod(LoadingFrameIndex, LoadingFrames.Length) + 1
    LoadingText.Text := (IsChineseLanguage() ? "正在启动" : "Starting") . LoadingFrames[LoadingFrameIndex]
}
