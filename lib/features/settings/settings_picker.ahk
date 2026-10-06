; Settings application/window picker state and lifecycle.

global WindowPickerVisible := false
global WindowPickerKind := ""
global WindowPickerRows := []
global WindowPickerBindingNumber := 0
global WindowPickerBindType := 1

SettingsSelectHotkeyApplication(*) {
    global SettingsHost
    applicationPath := ""
    try applicationPath := FileSelect(1, "", "选择应用程序", "应用程序 (*.exe)")
    catch as pickerError {
        SettingsSendHotkeyApplicationSelected(0)
        DebugLog("Settings application picker failed errorType=" . Type(pickerError))
        ShowMsg(LLMText(
            "Unable to open the application picker. Reopen Settings and try again.",
            "无法打开应用选择器。请重新打开设置后重试。"), 3000)
        return
    }
    if applicationPath = ""
        return
    profile := AppProfileDraftFromPath(applicationPath)
    if !IsObject(profile)
        return
    SettingsSendHotkeyApplicationSelected(profile)
}

SettingsSendHotkeyApplicationSelected(profile) {
    global SettingsHost
    if !IsObject(SettingsHost) || !IsObject(profile)
        return
    DebugLog("Hotkey application profile returned id=" . String(profile["id"]))
    PanelHostExecute(SettingsHost,
        "window.hotkeyApplicationSelected(" . JSON.stringify(profile, 0) . ");")
}

SettingsSelectHotkeyApplicationPath(path) {
    global WindowPickerKind, WindowPickerVisible, WindowPickerRows
    DebugLog("Hotkey application selection received pathLength=" . StrLen(String(path))
        . " visible=" . WindowPickerVisible . " kind=" . WindowPickerKind)
    if !WindowPickerVisible || WindowPickerKind != "hotkeyApplication" {
        DebugLog("Hotkey application selection ignored: picker state mismatch")
        return
    }
    path := Trim(String(path))
    if path = "" {
        DebugLog("Hotkey application selection ignored: empty path")
        return
    }
    selectedPath := AppProfileNormalizePath(path)
    allowedPath := false
    for item in WindowPickerRows {
        if AppProfileNormalizePath(item.path) = selectedPath {
            allowedPath := true
            break
        }
    }
    if !allowedPath {
        DebugLog("Hotkey application selection ignored: path not in picker snapshot")
        return
    }
    profile := AppProfileDraftFromPath(path)
    if !IsObject(profile) {
        DebugLog("Hotkey application profile creation failed")
        return
    }
    DebugLog("Hotkey application profile created id=" . profile["id"])
    SettingsCloseWindowPicker(false)
    SettingsSendHotkeyApplicationSelected(profile)
}

SettingsOpenWindowPicker(message) {
    msg := LLMMessageParse(message)
    numberValid := false
    bindingNumber := LLMMsgNumber(msg, "number", &numberValid, 0, true)
    if !numberValid || bindingNumber < 1 || bindingNumber > 10
        return
    bindTypeValid := false
    bindType := WindowBindingType(LLMMsgNumber(msg, "bindType", &bindTypeValid, 0, true), 0)
    if !bindTypeValid || bindType < 1 || bindType > 2
        return
    try SettingsShowWindowPicker(bindingNumber, bindType)
    catch as pickerError {
        SettingsShow("windows")
        DebugLog("Settings window picker failed errorType=" . Type(pickerError))
        ShowMsg(LLMText(
            "Unable to open the window picker. Reopen Settings and try again.",
            "无法打开窗口选择器。请重新打开设置后重试。"), 3000)
    }
}

SettingsOpenOpenApplicationPicker(message) {
    msg := LLMMessageParse(message)
    numberValid := false
    bindingNumber := LLMMsgNumber(msg, "number", &numberValid, 0, true)
    if !numberValid || bindingNumber < 1 || bindingNumber > 10
        return
    bindTypeValid := false
    bindType := WindowBindingType(LLMMsgNumber(msg, "bindType", &bindTypeValid, 0, true), 0)
    if !bindTypeValid || bindType != 3
        return
    try SettingsShowApplicationPicker(bindingNumber)
    catch as pickerError {
        SettingsShow("windows")
        DebugLog("Settings application picker failed errorType=" . Type(pickerError))
        ShowMsg(LLMText(
            "Unable to open the application picker. Reopen Settings and try again.",
            "无法打开应用选择器。请重新打开设置后重试。"), 3000)
    }
}

SettingsOpenOtherApplicationPicker(message) {
    msg := LLMMessageParse(message)
    numberValid := false
    bindingNumber := LLMMsgNumber(msg, "number", &numberValid, 0, true)
    if !numberValid || bindingNumber < 1 || bindingNumber > 10
        return
    bindTypeValid := false
    bindType := WindowBindingType(LLMMsgNumber(msg, "bindType", &bindTypeValid, 0, true), 0)
    if !bindTypeValid || bindType != 3
        return
    applicationPath := ""
    try applicationPath := FileSelect(1, "", "选择其他应用", "应用程序 (*.exe)")
    catch as pickerError {
        SettingsShow("windows")
        DebugLog("Settings application picker failed errorType=" . Type(pickerError))
        ShowMsg(LLMText(
            "Unable to open the application picker. Reopen Settings and try again.",
            "无法打开应用选择器。请重新打开设置后重试。"), 3000)
        return
    }
    if applicationPath = "" {
        SettingsShow("windows")
        return
    }
    BindWindowToApplication(bindingNumber, applicationPath)
    SettingsShow("windows")
    SetTimer(SettingsPushSnapshot, -1)
}

SettingsShowWindowPicker(bindingNumber, bindType) {
    global SettingsHost, WindowPickerVisible, WindowPickerKind
    global WindowPickerRows, WindowPickerBindingNumber, WindowPickerBindType
    if WindowPickerVisible
        SettingsCloseWindowPicker(false)

    settingsGui := PanelHostGui(SettingsHost)
    excludeHwnd := IsObject(settingsGui) ? settingsGui.Hwnd : 0
    rows := WindowBindingOpenWindows(excludeHwnd)
    if !rows.Length {
        SettingsShow("windows")
        ShowMsg("没有找到当前用户已打开的窗口。", 2500)
        return
    }
    WindowPickerKind := "window"
    WindowPickerRows := rows
    WindowPickerBindingNumber := bindingNumber
    WindowPickerBindType := bindType
    WindowPickerVisible := true
    SettingsPushWindowPicker()
}

SettingsShowApplicationPicker(bindingNumber) {
    SettingsOpenApplicationPicker("application", bindingNumber)
}

SettingsShowHotkeyApplicationPicker(*) {
    DebugLog("Hotkey application picker opening")
    SettingsOpenApplicationPicker("hotkeyApplication")
}

SettingsOpenApplicationPicker(kind, bindingNumber := 0) {
    global SettingsHost, WindowPickerVisible, WindowPickerKind
    global WindowPickerRows, WindowPickerBindingNumber
    if WindowPickerVisible
        SettingsCloseWindowPicker(false)

    settingsGui := PanelHostGui(SettingsHost)
    excludeHwnd := IsObject(settingsGui) ? settingsGui.Hwnd : 0
    rows := WindowBindingOpenApplications(excludeHwnd)
    if !rows.Length {
        DebugLog("Application picker found no open applications kind=" . kind)
        if kind != "hotkeyApplication"
            SettingsShow("windows")
        ShowMsg("没有找到当前用户已打开的应用。", 2500)
        return
    }
    DebugLog("Application picker results kind=" . kind . " count=" . rows.Length)
    WindowPickerKind := kind
    WindowPickerRows := rows
    WindowPickerBindingNumber := bindingNumber
    WindowPickerVisible := true
    SettingsPushWindowPicker()
}

SettingsPushWindowPicker(*) {
    global SettingsHost, WindowPickerVisible, WindowPickerKind, WindowPickerRows
    if !WindowPickerVisible || !IsObject(SettingsHost) || !PanelHostPageReady(SettingsHost)
        return

    isApplication := WindowPickerKind = "application" || WindowPickerKind = "hotkeyApplication"
    isHotkeyApplication := WindowPickerKind = "hotkeyApplication"
    rows := []
    for item in WindowPickerRows {
        if isApplication
            rows.Push(Map("name", item.exe, "count", item.items.Length, "path", item.path))
        else
            rows.Push(Map("title", item.title, "exe", item.exe, "class", item.windowClass))
    }
    payload := Map(
        "kind", WindowPickerKind,
        "title", isApplication ? "选择已打开应用" : "选择已打开窗口",
        "description", isHotkeyApplication ? "选择应用以添加快捷键配置。"
            : isApplication ? "选择应用并绑定它的全部窗口。" : "选择要绑定的窗口。",
        "rows", rows)
    DebugLog("Window picker pushed kind=" . WindowPickerKind . " count=" . rows.Length)
    PanelHostExecute(SettingsHost, "window.receiveWindowPicker(" . JSON.stringify(payload, 0) . ");")
}

SettingsWindowPickerSelect(index) {
    global WindowPickerKind, WindowPickerRows, WindowPickerBindingNumber, WindowPickerBindType
    if ((WindowPickerKind != "application" && WindowPickerKind != "window")
        || index < 1 || index > WindowPickerRows.Length || index != Floor(index)) {
        DebugLog("Window picker selection ignored: invalid kind or index")
        return
    }
    index := Integer(index)
    bindingNumber := WindowPickerBindingNumber
    if WindowPickerKind = "application" {
        application := WindowPickerRows[index]
        SettingsCloseWindowPicker(false)
        BindWindowToApplication(bindingNumber, application.path)
    } else {
        item := WindowPickerRows[index]
        bindType := WindowPickerBindType
        SettingsCloseWindowPicker(false)
        BindWindowItemSelection(bindingNumber, item, bindType)
    }
    SettingsShow("windows")
    SetTimer(SettingsPushSnapshot, -1)
}

SettingsWindowPickerCancel(*) {
    global SettingsHost, WindowPickerKind
    reopenHotkeyApplications := WindowPickerKind = "hotkeyApplication"
    DebugLog("Window picker cancelled kind=" . WindowPickerKind)
    if reopenHotkeyApplications {
        SettingsCloseWindowPicker(false)
        if IsObject(SettingsHost) && PanelHostPageReady(SettingsHost)
            PanelHostExecute(SettingsHost, "window.openHotkeyApplicationDialog();")
        return
    }
    SettingsCloseWindowPicker(true)
}

SettingsCloseWindowPicker(restoreSettings := true) {
    global SettingsHost, WindowPickerVisible, WindowPickerKind
    global WindowPickerRows, WindowPickerBindingNumber, WindowPickerBindType
    WindowPickerVisible := false
    WindowPickerKind := ""
    WindowPickerRows := []
    WindowPickerBindingNumber := 0
    WindowPickerBindType := 1
    if IsObject(SettingsHost) && PanelHostPageReady(SettingsHost)
        PanelHostExecute(SettingsHost, "window.closeWindowPicker();")
    if restoreSettings
        SettingsShow("windows")
}
