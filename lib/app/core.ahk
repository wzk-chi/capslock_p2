; capslock_p2 — AHK v2 core services.
; The legacy v1 files are kept in the repository for reference, but the v2
; entry point includes only the v2 modules.

global AppName := "capslock_p2"
global AppVersion := "0.2.0"
global AppInstanceMutex := 0
global DebugLogFile := A_ScriptDir . "\capslock_p2-debug.log"
global DebugLogMaxBytes := 1 * 1024 * 1024
global DebugLogging := false
global SettingsReloadPending := false
global KeySet := Map()
global CapsLockHeld := false
global CapsLockUsed := false
global CtrlZPending := true
global AllowClipboardWatcher := true
global ClipboardWatcherSuspended := false
global ClipboardSuspendDepth := 0
global ClipboardSuspendNextId := 1
global ClipboardSuspendTokens := Map()
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
    local errorText

    SetWorkingDir(A_ScriptDir)
    CoordMode("Mouse", "Screen")
    iconPath := A_ScriptDir . "\resources\capslock_p2-icon.png"
    try TraySetIcon(iconPath)
    try ProcessSetPriority("High")
    try SetStoreCapslockMode("Off")
    SetCapsLockState("Off")

    userDocument := 0
    if !ConfigLoad(&configError, &userDocument) {
        errorText := configError = "defaults_missing"
            ? "应用默认配置文件缺失，无法启动。"
            : configError = "defaults_read"
                ? "应用默认配置文件无法读取，请检查文件后重新启动。"
                : configError = "user_read"
                    ? "应用设置文件无法读取，请检查文件权限后重新启动。"
                    : configError = "user_metadata"
                        ? "无法确认应用设置文件状态，请检查文件权限后重新启动。"
                        : "应用配置无法读取，请检查配置文件后重新启动。"
        MsgBox(errorText, AppName, "Iconx")
        ExitApp()
        return false
    }
    profileChanged := false
    if !AppProfilesLoad(&profileChanged, true, userDocument) {
        MsgBox("应用设置文件无法完整读取，请检查文件后重新启动。", AppName, "Iconx")
        ExitApp()
        return false
    }
    EnsureConfiguredElevation()
    AppInstanceMutex := DllCall("Kernel32\CreateMutexW",
        "ptr", 0, "int", 0, "wstr", "Local\capslock_p2-running", "ptr")
    if !AppInstanceMutex
        DebugLog("Unable to create app instance mutex")
    BuildKeySet()
    ApplyGlobalSettings()
    ; Initialize the plugin store after debug logging is enabled, but before
    ; feature hotkeys are registered, so registration failures are observable.
    try QbarPluginHostInitialize()
    try ClipboardHistoryInitialize()
    TrayMenuInitialize()
    DebugLog("Initialize settings")
    if ConfigGlobalRead("loadingAnimation") != "0"
        ShowLoading()

    InitializeWindowBindings()
    InitializeMouseSpeed()
    RebuildHotStringPattern()
    RegisterCapsHotkeys()
    RegisterCustomHotkeys()
    RegisterFeatureHotkeys()
    OnClipboardChange(HandleClipboardChange)
    DebugLog("Hotkeys and clipboard watcher registered")

    SetTimer(MonitorSettings, 500)

    if ConfigGlobalRead("loadingAnimation") != "0" {
        Sleep(80)
        HideLoading()
    }
    ; Open the local usage guide once for a clean installation. Use a timer so
    ; the browser launch happens after the app has finished registering its
    ; tray menu, hotkeys and feature state.
    SetTimer(OpenUsageOnFirstRun, -1)
    DebugLog("Initialize complete")
}

; Elevate only when the user explicitly enabled the setting. The child process
; inherits the same script/executable and A_IsAdmin prevents a relaunch loop.
EnsureConfiguredElevation() {
    if ConfigGlobalRead("runAsAdmin", "0") != "1" || A_IsAdmin
        return true

    quote := Chr(34)
    command := A_IsCompiled
        ? quote . A_ScriptFullPath . quote
        : quote . A_AhkPath . quote . " " . quote . A_ScriptFullPath . quote
    try {
        Run("*RunAs " . command)
        ExitApp()
    } catch as elevationError {
        DebugLog("Admin elevation failed")
        ShowMsg("无法以管理员身份启动，将继续以普通权限运行。", 5000)
        return true
    }
}

Shutdown(*) {
    try ClipboardHistoryShutdown()
    try SetTimer(MouseSpeedTick, 0)
    try RestoreMouseSpeed()
    try LLMTranslateShutdown()
    try SettingsShutdown()
    try DictionaryShutdown()
    try AiChatShutdown()
    try EverythingShutdown()
    try NotesShutdown()
    try QbarShutdown()
    try QbarPluginHostShutdown()
    try HideLoading()
}

ClipboardSuspendBegin(reason := "unspecified") {
    global ClipboardSuspendDepth, ClipboardSuspendNextId, ClipboardSuspendTokens, ClipboardWatcherSuspended
    token := "clip-suspend-" . ClipboardSuspendNextId . "-" . A_TickCount
    order := ClipboardSuspendNextId
    ClipboardSuspendNextId += 1
    ClipboardSuspendTokens[token] := Map("reason", String(reason), "active", true, "order", order)
    ClipboardSuspendDepth += 1
    ClipboardWatcherSuspended := true
    return token
}

ClipboardSuspendEnd(token) {
    global ClipboardSuspendDepth, ClipboardSuspendTokens, ClipboardWatcherSuspended
    if token = "" || !ClipboardSuspendTokens.Has(token)
        return false
    state := ClipboardSuspendTokens[token]
    if !state["active"]
        return false
    state["active"] := false
    ClipboardSuspendDepth := Max(0, ClipboardSuspendDepth - 1)
    ClipboardWatcherSuspended := ClipboardSuspendDepth > 0
    ClipboardSuspendTokens.Delete(token)
    return true
}

ClipboardSuspendActive() {
    global ClipboardSuspendDepth
    return ClipboardSuspendDepth > 0
}

ClipboardSuspendReason() {
    global ClipboardSuspendTokens
    reason := ""
    newestOrder := 0
    for token, state in ClipboardSuspendTokens {
        if state["active"] && state["order"] >= newestOrder {
            reason := state["reason"]
            newestOrder := state["order"]
        }
    }
    return reason
}

ReloadSettings(notifySettingsPage := true, rebuildCustomHotkeys := false,
    &loadSucceeded := true, *) {
    global SettingsVisible, SettingsReloadPending, Config, ConfigDefaults, SettingsModifyTime
    loadSucceeded := false
    previous := ConfigSnapshot()
    previousConfig := Config
    previousDefaults := ConfigDefaults
    previousModifyTime := SettingsModifyTime
    loadError := ""
    loadedUserDocument := 0
    if !ConfigLoad(&loadError, &loadedUserDocument) {
        SettingsReloadPending := true
        return []
    }
    appProfilesChanged := false
    if !AppProfilesLoad(&appProfilesChanged, true, loadedUserDocument) {
        Config := previousConfig
        ConfigDefaults := previousDefaults
        SettingsModifyTime := previousModifyTime
        SettingsReloadPending := true
        return []
    }
    SettingsReloadPending := false
    loadSucceeded := true
    changes := ConfigEffectiveDiff(previous, Config)
    ; Apply other settings first, then register once against the combined state.
    ApplyConfigChanges(changes, true)
    registrationErrors := []
    if appProfilesChanged || rebuildCustomHotkeys || changes.Has("CustomHotkey")
        registrationErrors := RegisterCustomHotkeys()
    if notifySettingsPage && SettingsVisible
        SetTimer(SettingsPushSnapshot, -1)
    DebugLog("Settings reloaded")
    return registrationErrors
}

ApplyGlobalSettings() {
    global AllowClipboardWatcher, DebugLogging
    AllowClipboardWatcher := ConfigGlobalRead("allowClipboard") != "0"
    DebugLogging := ConfigGlobalRead("debug") = "1"
    DebugLog("Global settings applied")
    EnsureAutostartShortcut(ConfigGlobalRead("autostart") = "1")
    TrayMenuRefresh()
}

DebugLog(message) {
    global DebugLogFile, DebugLogMaxBytes, DebugLogging
    if !DebugLogging
        return
    line := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") . " [" . A_TickCount . "] " . message . "`n"
    try {
        lineBytes := StrPut(line, "UTF-8") - 1
        if lineBytes > DebugLogMaxBytes || !DebugLogEnsureCapacity(lineBytes)
            return
        FileAppend(line, DebugLogFile, "UTF-8")
    } catch {
        return
    }
}

DebugLogEnsureCapacity(lineBytes) {
    global DebugLogFile, DebugLogMaxBytes
    currentBytes := FileExist(DebugLogFile) ? FileGetSize(DebugLogFile) : 0
    while currentBytes + lineBytes > DebugLogMaxBytes {
        if !DebugLogTrimFront()
            return false
        newBytes := FileExist(DebugLogFile) ? FileGetSize(DebugLogFile) : 0
        if newBytes >= currentBytes
            return false
        currentBytes := newBytes
    }
    return true
}

; Keep the newer two thirds of the file and discard the oldest third. The
; first complete line after the byte cut is used so a UTF-8 character or log
; record is not left partially at the start of the compacted file.
DebugLogTrimFront() {
    global DebugLogFile
    currentBytes := FileGetSize(DebugLogFile)
    if currentBytes <= 0
        return true

    trimBytes := Max(1, Floor(currentBytes / 3))
    source := 0
    target := 0
    try {
        source := FileOpen(DebugLogFile, "r", "UTF-8")
        if !IsObject(source)
            return false
        source.Pos := trimBytes
        tail := source.Read()
        source.Close()
        source := 0

        newlinePosition := InStr(tail, "`n")
        if newlinePosition
            tail := SubStr(tail, newlinePosition + 1)

        target := FileOpen(DebugLogFile, "w", "UTF-8-RAW")
        if !IsObject(target)
            return false
        target.Write(tail)
        target.Close()
        target := 0
        return true
    } catch {
        if IsObject(source)
            try source.Close()
        if IsObject(target)
            try target.Close()
        return false
    }
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
    parsedValue := Integer(value)
    return Max(minimum, Min(maximum, parsedValue))
}

MonitorSettings() {
    global SettingsModifyTime, SettingsVisible, SettingsReloadPending, SettingsFile
    if SettingsReloadPending {
        ReloadSettings()
        return
    }
    currentTime := ConfigFileModifyTime()
    if currentTime = "" && FileExist(SettingsFile) {
        SettingsReloadPending := true
        ReloadSettings()
        return
    }
    if currentTime != SettingsModifyTime {
        ReloadSettings()
        return
    }
    ; Check application profile content even when the coarse file timestamp did
    ; not change. Profile-only external edits should take effect immediately.
    appProfilesChanged := false
    if !AppProfilesLoad(&appProfilesChanged, false) {
        SettingsReloadPending := true
        ReloadSettings()
        return
    }
    if appProfilesChanged {
        ; The probe did not publish; reload reads and publishes the full state.
        loadSucceeded := false
        ReloadSettings(false, true, &loadSucceeded)
        if loadSucceeded && SettingsVisible
            SetTimer(SettingsPushSnapshot, -1)
    }
}

ConfigSet(section, key, value) {
    global Config, SettingsFile, SettingsModifyTime
    normalized := ""
    if !ConfigValidateValue(section, key, value, &normalized) {
        ShowMsg(LLMText("The setting value is invalid. Check the selected option and try again.",
            "设置值无效，请检查选项后重试。"), 2500)
        return false
    }
    try {
        ConfigWriteValue(SettingsFile, section, key, normalized)
    } catch as writeError {
        DebugLog("Config write failed section=" . section . " key=" . key
            . " errorType=" . Type(writeError))
        ShowMsg(LLMText(
            "Unable to save the setting. Check that the application folder is writable and try again.",
            "设置无法保存。请确认安装目录可写后重试。"), 2500)
        return false
    }
    if !Config.Has(section)
        Config[section] := Map()
    Config[section][key] := normalized
    SettingsModifyTime := ConfigFileModifyTime()
    ApplySettingChange(section, key, normalized)
    return true
}

ApplySettingChange(section, key, value) {
    changes := Map()
    changes[section] := Map(key, value)
    ApplyConfigChanges(changes)
}

ApplyConfigChanges(changes, deferCustomHotkeys := false) {
    global AllowClipboardWatcher, DebugLogging, MouseSpeed, Config
    if !IsObject(changes) || !changes.Count
        return

    rebuildKeys := false
    rebuildCustomHotkeys := false
    rebuildHotStrings := false
    refreshQbarIndex := false
    refreshTranslation := false
    refreshAi := false
    refreshPanelDestroySchedule := false

    for section, values in changes {
        if !IsObject(values)
            continue
        switch section {
            case "Global":
                for key, value in values {
                    switch key {
                        case "allowClipboard":
                            AllowClipboardWatcher := value != "0"
                        case "debug":
                            DebugLogging := value = "1"
                        case "mouseSpeed":
                            MouseSpeed := SettingInteger("Global", "mouseSpeed", 3, 1, 20)
                        case "autostart":
                            EnsureAutostartShortcut(value = "1")
                        case "language":
                            refreshQbarIndex := true
                        case "webViewDestroyMinutes":
                            refreshPanelDestroySchedule := true
                    }
                }
                TrayMenuRefresh()
            case "Keys":
                rebuildKeys := true
            case "CustomHotkey":
                rebuildCustomHotkeys := true
            case "TabHotString":
                rebuildHotStrings := true
            case "LLM":
                refreshTranslation := true
                refreshAi := true
            case "LLMTranslate", "TTranslate", "TYoudao", "TVolcengine":
                refreshTranslation := true
            case "QAI":
                refreshAi := true
            case "Qbar":
                ; esMaxResults is read at query time; no index rebuild is needed.
        }
    }

    if rebuildKeys
        BuildKeySet()
    if rebuildCustomHotkeys && !deferCustomHotkeys
        RegisterCustomHotkeys()
    if rebuildHotStrings
        RebuildHotStringPattern()
    if refreshQbarIndex
        QbarInvalidateConfigIndex()
    if refreshAi {
        try AiChatOnSettingsSaved()
    }
    if refreshTranslation {
        try LLMTranslateOnSettingsSaved()
    }
    if refreshPanelDestroySchedule
        PanelHostRefreshDestroySchedule()
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

RebuildHotStringPattern() {
    global HotStringKeys
    HotStringKeys := []
    seen := Map()
    ; The CapsLock+Tab tail match draws only from TabHotString. Keys carry a
    ; "<display>" suffix only when the user chooses to include one; matching is
    ; still based on the short key.
    for section in ["TabHotString"] {
        for key, value in ConfigSection(section) {
            short := QbarShortKey(key)
            if short = "" || seen.Has(short)
                continue
            ; Longer suffixes must win; insertion retains the section/key
            ; order when two candidates have the same length.
            insertAt := 1
            while insertAt <= HotStringKeys.Length && StrLen(HotStringKeys[insertAt]) >= StrLen(short)
                insertAt += 1
            HotStringKeys.InsertAt(insertAt, short)
            seen[short] := true
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

; The value a hotstring key expands to comes from TabHotString. Decoding happens
; once at the configuration boundary.
HotStringValue(key) {
    value := ConfigRead("TabHotString", key, "")
    return value
}

CLhotString() {
    global A_Clipboard
    matched := ""
    replacement := GetHotStringReplacement(A_Clipboard, &matched)
    if matched = ""
        return ""
    token := ClipboardSuspendBegin("temporary-hotstring")
    try {
        A_Clipboard := replacement
        ClipboardHistoryMarkOwnedSequence(ClipboardSequenceNumber(), "temporary-hotstring")
    } finally ClipboardSuspendEnd(token)
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

    DebugLog("Action invoked")

    try functionObject := %functionName%
    catch as functionError {
        DebugLog("Unknown key function")
        ShowMsg(LLMText(
            "This shortcut action is unavailable. Check the shortcut settings.",
            "此快捷键操作不可用，请检查快捷键设置。"), 2500)
        return
    }

    if !HasMethod(functionObject, "Call") {
        DebugLog("Non-callable key function")
        ShowMsg(LLMText(
            "This shortcut action is unavailable. Check the shortcut settings.",
            "此快捷键操作不可用，请检查快捷键设置。"), 2500)
        return
    }

    arguments := SplitActionArguments(argumentText)
    try functionObject.Call(arguments*)
    catch as functionError {
        DebugLog("Action failed function=" . functionName
            . " errorType=" . Type(functionError))
        ShowMsg(LLMText(
            "This shortcut action could not be completed. Review its settings and try again.",
            "快捷键操作未能完成，请检查对应设置后重试。"), 3000)
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

ClipboardSequenceNumber() {
    return DllCall("GetClipboardSequenceNumber", "uint")
}

WaitClipboardSequenceChange(previousSequence, waitSeconds, &sequence := 0) {
    sequence := ClipboardSequenceNumber()
    deadline := A_TickCount + Max(1, Round(waitSeconds * 1000))
    while sequence = previousSequence {
        if A_TickCount >= deadline
            return false
        Sleep(5)
        sequence := ClipboardSequenceNumber()
    }
    return sequence != 0
}

; Compatibility helpers for existing user extensions.
getSelText() {
    return GetSelectedText()
}

clipSaver(clipX) {
    global WhichClipboardNow
    slot := clipX = "s" ? 0 : (clipX = "c" ? 1 : 2)
    SaveClipboardSlot(slot)
    WhichClipboardNow := slot
}

HandleClipboardChange(dataType) {
    global AllowClipboardWatcher, ClipboardWatcherSuspended, CapsLockHeld, WhichClipboardNow, SystemClipboard
    sequence := ClipboardSequenceNumber()
    eventId := ClipboardHistoryNotify(dataType, "", sequence)
    DebugLog("ClipboardChange type=" . dataType . " suspended=" . ClipboardWatcherSuspended . " capsHeld=" . CapsLockHeld . " allowed=" . AllowClipboardWatcher)
    try {
        if !ClipboardSuspendActive() && !CapsLockHeld && AllowClipboardWatcher {
            ; Keep the local snapshot detached from the global slot until the
            ; sequence is confirmed. The same object is then offered to history
            ; so the delayed whitelist capture does not read the clipboard again.
            snapshot := ClipboardAll()
            sequenceAfter := ClipboardSequenceNumber()
            if sequence && sequenceAfter = sequence {
                SystemClipboard := snapshot
                WhichClipboardNow := 0
                ClipboardHistoryOfferSlotSnapshot(eventId, sequenceAfter, snapshot, 0)
            }
        }
    } catch {
        ; Keep the existing system-slot state when a clipboard snapshot fails.
    } finally {
        ClipboardHistoryFinalizeNotify(eventId)
    }
}

SaveClipboardSlot(slot, expectedSequence := 0) {
    global CapsClipboard, CapsAltClipboard, SystemClipboard
    savedClipboard := ClipboardAll()
    if expectedSequence && ClipboardSequenceNumber() != expectedSequence
        return 0
    if slot = 0
        SystemClipboard := savedClipboard
    else if slot = 1
        CapsClipboard := savedClipboard
    else
        CapsAltClipboard := savedClipboard
    return savedClipboard
}

RestoreClipboard(data) {
    global A_Clipboard
    suspendToken := ClipboardSuspendBegin("slot-restore")
    try {
        if IsObject(data)
            A_Clipboard := data
        else
            A_Clipboard := ""
        ClipboardHistoryMarkOwnedSequence(ClipboardSequenceNumber(), "slot-restore")
    } finally {
        ClipboardSuspendEnd(suspendToken)
    }
}

ClipboardEnabled() {
    return ConfigGlobalRead("allowClipboard") != "0"
}

CopyToClipboardSlot(slot, isCut := false) {
    global A_Clipboard, WhichClipboardNow
    if !ClipboardEnabled()
        return

    success := false
    copySequence := 0
    copiedSnapshot := 0
    suspendToken := ClipboardSuspendBegin(isCut ? "user-cut" : "user-copy")
    try {
        sequenceBefore := ClipboardSequenceNumber()
        SendInput(isCut ? "^x" : "^{Insert}")
        success := WaitClipboardSequenceChange(sequenceBefore, 0.15, &copySequence)
        if !success {
            ; VSCode and several editor controls do not treat Ctrl+Insert as
            ; copy. Try the standard Ctrl+C before changing the selection.
            sequenceBefore := ClipboardSequenceNumber()
            SendInput(isCut ? "^x" : "^c")
            success := WaitClipboardSequenceChange(sequenceBefore, 0.15, &copySequence)
        }
        if !success {
            sequenceBefore := ClipboardSequenceNumber()
            SendInput("{Home}+{End}")
            SendInput(isCut ? "^x" : "^c")
            if !isCut
                SendInput("{End}")
            success := WaitClipboardSequenceChange(sequenceBefore, 0.15, &copySequence)
        }
        if success {
            copiedSnapshot := SaveClipboardSlot(slot, copySequence)
            if !IsObject(copiedSnapshot) || ClipboardSequenceNumber() != copySequence {
                success := false
                copiedSnapshot := 0
            } else {
                ClipboardHistoryMarkOwnedSequence(copySequence, isCut ? "user-cut" : "user-copy")
                WhichClipboardNow := slot
            }
        }
    } finally {
        ClipboardSuspendEnd(suspendToken)
    }
    if success
        ClipboardHistoryPublishExplicit(copySequence, copiedSnapshot,
            isCut ? "user-cut" : "user-copy")
}

PasteClipboardSlot(slot) {
    global A_Clipboard, CapsClipboard, CapsAltClipboard, WhichClipboardNow
    if !ClipboardEnabled()
        return
    savedClipboard := slot = 1 ? CapsClipboard : CapsAltClipboard
    if !IsObject(savedClipboard)
        return

    if WhichClipboardNow != slot {
        suspendToken := ClipboardSuspendBegin("slot-restore")
        try {
            A_Clipboard := savedClipboard
            ClipboardHistoryMarkOwnedSequence(ClipboardSequenceNumber(), "slot-restore")
        }
        finally ClipboardSuspendEnd(suspendToken)
        WhichClipboardNow := slot
    }
    SendInput("^v")
}

PasteSystemClipboard() {
    global A_Clipboard, SystemClipboard, WhichClipboardNow
    if WhichClipboardNow != 0 && IsObject(SystemClipboard) {
        suspendToken := ClipboardSuspendBegin("slot-restore")
        try {
            A_Clipboard := SystemClipboard
            ClipboardHistoryMarkOwnedSequence(ClipboardSequenceNumber(), "slot-restore")
        }
        finally ClipboardSuspendEnd(suspendToken)
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
    global A_Clipboard
    oldClipboard := ClipboardAll()
    ownedSequence := 0
    suspendToken := ClipboardSuspendBegin("temporary-paste")
    try {
        A_Clipboard := text
        ownedSequence := ClipboardSequenceNumber()
        ClipboardHistoryMarkOwnedSequence(ownedSequence, "temporary-paste")
        SendInput("^v")
        Sleep(60)
    } finally {
        ; Do not put an older snapshot back over clipboard data the user
        ; supplied while the paste was in flight.
        if ownedSequence && ClipboardSequenceNumber() = ownedSequence {
            A_Clipboard := oldClipboard
            ClipboardHistoryMarkOwnedSequence(ClipboardSequenceNumber(), "temporary-paste")
        }
        ClipboardSuspendEnd(suspendToken)
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

; Restore the system pointer without increasing ShowCursor's display count when
; Windows already considers it visible.
ShowSystemCursor() {
    count := DllCall("User32\ShowCursor", "Int", 1, "Int")
    if count > 0 {
        DllCall("User32\ShowCursor", "Int", -1, "Int")
        return count - 1
    }
    while count < 0
        count := DllCall("User32\ShowCursor", "Int", 1, "Int")
    return count
}
