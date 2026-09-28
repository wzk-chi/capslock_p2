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
    EnsureConfiguredElevation()
    BuildKeySet()
    ApplyGlobalSettings()
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

    SettingsModifyTime := ConfigFileModifyTime()
    SetTimer(MonitorSettings, 500)

    if ConfigGlobalRead("loadingAnimation") != "0" {
        Sleep(80)
        HideLoading()
    }
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
    try SetTimer(MouseSpeedTick, 0)
    try RestoreMouseSpeed()
    try LLMTranslateShutdown()
    try SettingsShutdown()
    try DictionaryShutdown()
    try AiChatShutdown()
    try EverythingShutdown()
    try QbarShutdown()
    try ShowSystemCursor()
    try HideLoading()
}

ReloadSettings(notifySettingsPage := true, *) {
    global SettingsVisible
    previous := ConfigSnapshot()
    ConfigLoad()
    ApplyConfigChanges(ConfigEffectiveDiff(previous, Config))
    if notifySettingsPage && SettingsVisible
        SetTimer(SettingsPushSnapshot, -1)
    DebugLog("Settings reloaded")
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
    parsedValue := Integer(value)
    return Max(minimum, Min(maximum, parsedValue))
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
    normalized := ""
    if !ConfigValidateValue(section, key, value, &normalized) {
        ShowMsg("Invalid setting value: " . section . "/" . key, 2500)
        return false
    }
    try {
        ConfigWriteValue(SettingsFile, section, key, normalized)
    } catch as writeError {
        ShowMsg("Unable to write settings: " . writeError.Message, 2500)
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

ApplyConfigChanges(changes) {
    global AllowClipboardWatcher, DebugLogging, MouseSpeed, Config
    if !IsObject(changes) || !changes.Count
        return

    rebuildKeys := false
    rebuildCustomHotkeys := false
    rebuildHotStrings := false
    refreshQbarIndex := false
    refreshTranslation := false
    refreshAi := false

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
                    }
                }
                TrayMenuRefresh()
            case "Keys":
                rebuildKeys := true
            case "CustomHotkey":
                rebuildCustomHotkeys := true
            case "TabHotString":
                rebuildHotStrings := true
            case "QSearch", "QRun", "QWeb":
                rebuildHotStrings := true
                refreshQbarIndex := true
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
    if rebuildCustomHotkeys
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
    ; The CapsLock+Tab tail match draws from all three value sections, like the
    ; reference CLhotString: a configured run or web entry can be expanded in an
    ; editor too. QRun/QWeb keys carry a "<display>" suffix, so they are matched
    ; by their short key; TabHotString keys have none and pass through unchanged.
    for section in ["TabHotString", "QRun", "QWeb"] {
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

; The value a hotstring key expands to, searched TabHotString -> QRun -> QWeb.
; TabHotString decoding happens once at the configuration boundary; Run and
; web values are used as written.
HotStringValue(key) {
    value := ConfigRead("TabHotString", key, "")
    if value != ""
        return value
    for section in ["QRun", "QWeb"] {
        for candidate, value in ConfigSection(section) {
            if QbarShortKey(candidate) = key && Trim(value) != ""
                return value
        }
    }
    return ""
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

    DebugLog("Action invoked")

    try functionObject := %functionName%
    catch as functionError {
        DebugLog("Unknown key function")
        ShowMsg("Unknown key function: " . functionName, 2500)
        return
    }

    if !HasMethod(functionObject, "Call") {
        DebugLog("Non-callable key function")
        ShowMsg("Unknown key function: " . functionName, 2500)
        return
    }

    arguments := SplitActionArguments(argumentText)
    try functionObject.Call(arguments*)
    catch as functionError {
        DebugLog("Action failed")
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

; Copies the active selection and restores the clipboard only after a
; successful copy. A failed copy leaves the clipboard untouched. A copy that ends
; with a newline is ambiguous — a real line-wise selection, or an editor
; copying the current line because nothing is selected (the reference's
; getSelText discarded both; its comment names the trailing newline). The
; mode picks the trade-off:
;   "strict"    keep the reference behavior; a trailing newline means "no
;               real selection". UI Automation returns an empty result
;               directly for a supported control with no active selection;
;               the clipboard path is used only when UIA is unsupported.
;   "multiline" keep certain selections: a copy with an interior newline is
;               a real multi-line selection, a bare line-copy is discarded.
;   "any"       keep everything and just drop the trailing newline; used
;               where a wrong guess is visible and editable (qbar prefill).
GetSelectedText(mode := "strict", waitSeconds := 0.15, allowCtrlCFallback := false) {
    global A_Clipboard, ClipboardWatcherSuspended, CapsLockHeld

    ; Prefer UI Automation so reading a selection does not touch the system
    ; clipboard.
    uiaSupported := false
    uiaText := GetSelectedTextViaUIA(&uiaSupported)
    if uiaSupported {
        return NormalizeSelectedText(uiaText, mode)
    }

    oldClipboard := ClipboardAll()
    result := ""
    success := false
    copySequence := 0
    ClipboardWatcherSuspended := true
    try {
        sequenceBefore := ClipboardSequenceNumber()
        SendInput("^{Insert}")
        success := WaitClipboardSequenceChange(sequenceBefore, waitSeconds, &copySequence)
        if !success && allowCtrlCFallback {
            ; Chrome accepts Ctrl+C more consistently in this state. The
            ; CapsLock layer is briefly stood down so this synthetic C cannot
            ; be routed to caps_c; the original clipboard is restored below only
            ; when this fallback actually produces a new clipboard sequence.
            previousCapsLockHeld := CapsLockHeld
            CapsLockHeld := false
            try {
                sequenceBefore := ClipboardSequenceNumber()
                SendInput("^c")
                success := WaitClipboardSequenceChange(sequenceBefore, waitSeconds, &copySequence)
            } finally {
                CapsLockHeld := previousCapsLockHeld && GetKeyState("CapsLock", "P")
            }
        }
        if success {
            result := A_Clipboard
            result := NormalizeSelectedText(result, mode)
        }
    } finally {
        ; A failed copy must not change the clipboard. On success, restore only
        ; while the clipboard still contains this copy; otherwise preserve the
        ; user's newer clipboard contents.
        if success && copySequence && ClipboardSequenceNumber() = copySequence
            A_Clipboard := oldClipboard
        ClipboardWatcherSuspended := false
    }
    return result
}

NormalizeSelectedText(text, mode) {
    if SubStr(text, -1) != "`n"
        return text
    if mode = "any"
        return RTrim(text, "`r`n")
    if mode = "multiline" && InStr(text, "`n", , 1, 2)
        return text
    return ""
}

; Returns the selected text through IUIAutomationTextPattern. `supported` is
; true when the focused control exposes TextPattern, even when its selection
; is empty. No clipboard fallback is performed here; callers can decide
; whether they want to use the compatibility path below.
GetSelectedTextViaUIA(&supported := false, &hasSelection := false) {
    supported := false
    hasSelection := false
    automation := UIASelectedTextAutomation()
    if !automation
        return ""

    activeHwnd := WinExist("A")
    ; Chromium/Electron creates its accessibility provider lazily. The first
    ; WM_GETOBJECT request can therefore expose the tree before the focused
    ; editor range is populated. Give that provider a couple of short retries;
    ; this keeps the normal native-control path immediate.
    retryCount := 1
    try if WinGetClass("ahk_id " . activeHwnd) = "Chrome_WidgetWin_1"
        retryCount := 3

    sawSupported := false
    Loop retryCount {
        attempt := A_Index
        if attempt > 1
            Sleep(20)
        UIAActivateChromiumAccessibility(activeHwnd, automation, attempt > 1)
        attemptSupported := false
        attemptHasSelection := false
        text := UIAReadFocusedSelection(automation, &attemptSupported, &attemptHasSelection)
        if attemptSupported
            sawSupported := true
        if attemptHasSelection
            hasSelection := true
        if attemptSupported && text != "" {
            supported := true
            return text
        }
    }
    supported := sawSupported
    return ""
}

UIAReadFocusedSelection(automation, &supported := false, &hasSelection := false) {
    supported := false
    hasSelection := false

    focused := 0
    pattern := 0
    ranges := 0
    range := 0
    bstr := 0
    try {
        ComCall(8, automation, "ptr*", &focused := 0)
        if !focused
            return ""
        ComCall(16, focused, "int", 10014, "ptr*", &pattern := 0)
        if !pattern
            return ""
        controlType := UIAElementControlType(focused)
        if !UIAElementSupportsTextSelection(controlType)
            return ""
        supported := true
        ComCall(5, pattern, "ptr*", &ranges := 0)
        if !ranges
            return ""
        count := 0
        ComCall(3, ranges, "int*", &count := 0)
        if count < 1
            return ""
        ComCall(4, ranges, "int", 0, "ptr*", &range := 0)
        if !range
            return ""
        ComCall(12, range, "int", -1, "ptr*", &bstr := 0)
        if !bstr
            return ""
        text := StrGet(bstr, "UTF-16")
        hasSelection := text != ""
        return text
    } catch as uiaError {
        supported := false
        return ""
    } finally {
        if bstr
            try DllCall("oleaut32\SysFreeString", "ptr", bstr)
        if range
            try ObjRelease(range)
        if ranges
            try ObjRelease(ranges)
        if pattern
            try ObjRelease(pattern)
        if focused
            try ObjRelease(focused)
    }
}

UIAElementControlType(element) {
    controlType := 0
    try ComCall(10, element, "int*", &controlType := 0)
    return controlType
}

UIAElementSupportsTextSelection(controlType) {
    ; UIA_TextPattern is meaningful for these controls. Chromium's render host
    ; can expose a non-null TextPattern while still reporting control type 0;
    ; treating that provider as supported turns a real selection into an empty
    ; result and prevents the standard copy fallback from running.
    return controlType = 50004 ; UIA_EditControlTypeId
        || controlType = 50020 ; UIA_TextControlTypeId
        || controlType = 50030 ; UIA_DocumentControlTypeId
}

UIAActivateChromiumAccessibility(hwnd, automation, force := false) {
    static activatedHwnds := Map()
    if !hwnd || (!force && activatedHwnds.Has(hwnd))
        return
    childWindows := []
    try {
        for childHwnd in WinGetControlsHwnd("ahk_id " . hwnd) {
            try className := WinGetClass("ahk_id " . childHwnd)
            catch
                continue
            if InStr(className, "Chrome_RenderWidgetHostHWND")
                childWindows.Push(childHwnd)
        }
    } catch {
    }
    ; Older WebView2 builds expose the host through ControlGetHwnd even when
    ; WinGetControlsHwnd does not return it, so keep the named lookup as a
    ; compatibility fallback.
    try {
        namedChild := ControlGetHwnd("Chrome_RenderWidgetHostHWND1", "ahk_id " . hwnd)
        if namedChild && !HasValue(childWindows, namedChild)
            childWindows.Push(namedChild)
    } catch {
    }
    for childHwnd in childWindows {
        try {
            ; UiaRootObjectId := 1. This asks Chromium/Electron to publish its
            ; accessibility tree before GetFocusedElement is queried.
            DllCall("user32\SendMessageW", "ptr", childHwnd, "uint", 0x003D
                , "ptr", 0, "ptr", 1, "ptr")
            root := 0
            ComCall(6, automation, "ptr", childHwnd, "ptr*", &root := 0)
            if root {
                ObjRelease(root)
                activatedHwnds[hwnd] := true
                return
            }
        } catch {
        }
    }
}

HasValue(values, needle) {
    for value in values
        if value = needle
            return true
    return false
}

UIASelectedTextAutomation() {
    static automation := 0
    if automation
        return automation
    clsid := Buffer(16, 0)
    iid := Buffer(16, 0)
    if DllCall("ole32\CLSIDFromString", "wstr", "{FF48DBA4-60EF-4201-AA87-54103EEF594E}", "ptr", clsid.Ptr) != 0
        return 0
    if DllCall("ole32\CLSIDFromString", "wstr", "{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}", "ptr", iid.Ptr) != 0
        return 0
    hr := DllCall("ole32\CoCreateInstance", "ptr", clsid.Ptr, "ptr", 0
        , "uint", 1, "ptr", iid.Ptr, "ptr*", &automation := 0, "hresult")
    return hr = 0 ? automation : 0
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

    success := false
    copySequence := 0
    ClipboardWatcherSuspended := true
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
            SaveClipboardSlot(slot)
            WhichClipboardNow := slot
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
    previousSuspension := ClipboardWatcherSuspended
    ownedSequence := 0
    ClipboardWatcherSuspended := true
    try {
        A_Clipboard := text
        ownedSequence := ClipboardSequenceNumber()
        SendInput("^v")
        Sleep(60)
    } finally {
        ; Do not put an older snapshot back over clipboard data the user
        ; supplied while the paste was in flight.
        if ownedSequence && ClipboardSequenceNumber() = ownedSequence
            A_Clipboard := oldClipboard
        ClipboardWatcherSuspended := previousSuspension
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
