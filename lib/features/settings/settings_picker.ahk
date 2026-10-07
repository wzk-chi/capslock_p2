; Settings application/window picker state and lifecycle.

global WindowPickerVisible := false
global WindowPickerKind := ""
global WindowPickerRows := []
global WindowPickerBindingNumber := 0
global WindowPickerBindType := 1
global WindowPickerEditSession := ""

SettingsSelectHotkeyApplication(expectedSession, *) {
    global SettingsHost
    if !SettingsIsEditMessage(Map("sessionId", expectedSession))
        return
    applicationPath := ""
    try applicationPath := FileSelect(1, "", "选择应用程序", "应用程序 (*.exe)")
    catch as pickerError {
        SettingsSendHotkeyApplicationSelected(0, expectedSession)
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
    SettingsSendHotkeyApplicationSelected(profile, expectedSession)
}

SettingsSendHotkeyApplicationSelected(profile, expectedSession) {
    global SettingsHost
    if !SettingsIsEditMessage(Map("sessionId", expectedSession))
        return
    if !IsObject(SettingsHost) || !IsObject(profile)
        return
    DebugLog("Hotkey application profile returned id=" . String(profile["id"]))
    SettingsPost("applicationSelected", Map("profile", profile, "sessionId", expectedSession))
}

SettingsSelectHotkeyApplicationPath(path, expectedSession) {
    if !SettingsIsEditMessage(Map("sessionId", expectedSession))
        return
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
    SettingsSendHotkeyApplicationSelected(profile, expectedSession)
}

SettingsOpenWindowPicker(message) {
    msg := LLMMessageParse(message)
    if !SettingsIsEditMessage(msg)
        return
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
    if !SettingsIsEditMessage(msg)
        return
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
    if !SettingsIsEditMessage(msg)
        return
    numberValid := false
    bindingNumber := LLMMsgNumber(msg, "number", &numberValid, 0, true)
    if !numberValid || bindingNumber < 1 || bindingNumber > 10
        return
    bindTypeValid := false
    bindType := WindowBindingType(LLMMsgNumber(msg, "bindType", &bindTypeValid, 0, true), 0)
    if !bindTypeValid || bindType != 3
        return
    expectedSession := LLMMsgField(msg, "sessionId")
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
    if !SettingsIsEditMessage(msg)
        return
    if applicationPath = "" {
        SettingsShow("windows")
        return
    }
    binding := {bindType: 3, applicationPath: applicationPath,
        items: WindowBindingApplicationItems(applicationPath)}
    SettingsStageWindowBinding(bindingNumber, binding, expectedSession)
}

SettingsShowWindowPicker(bindingNumber, bindType) {
    global WindowPickerEditSession, SettingsEditSessionId
    global SettingsHost, WindowPickerVisible, WindowPickerKind
    global WindowPickerRows, WindowPickerBindingNumber, WindowPickerBindType
    if WindowPickerVisible
        SettingsCloseWindowPicker(false)

    settingsGui := PanelHostGui(SettingsHost)
    excludeHwnd := IsObject(settingsGui) ? settingsGui.Hwnd : 0
    rows := WindowBindingOpenWindows(excludeHwnd)
    for item in rows {
        DllCall("GetWindowThreadProcessId", "Ptr", item.id, "UInt*", &pid := 0, "UInt")
        item.selectionPid := pid
    }
    if !rows.Length {
        SettingsShow("windows")
        ShowMsg("没有找到当前用户已打开的窗口。", 2500)
        return
    }
    WindowPickerEditSession := SettingsEditSessionId
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

SettingsShowHotkeyApplicationPicker(expectedSession, *) {
    if !SettingsIsEditMessage(Map("sessionId", expectedSession))
        return
    DebugLog("Hotkey application picker opening")
    SettingsOpenApplicationPicker("hotkeyApplication")
}

SettingsOpenApplicationPicker(kind, bindingNumber := 0) {
    global WindowPickerEditSession, SettingsEditSessionId
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
    WindowPickerEditSession := SettingsEditSessionId
    WindowPickerKind := kind
    WindowPickerRows := rows
    WindowPickerBindingNumber := bindingNumber
    WindowPickerVisible := true
    SettingsPushWindowPicker()
}

SettingsPushWindowPicker(*) {
    global WindowPickerEditSession, SettingsEditSessionId
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
        "sessionId", WindowPickerEditSession, "kind", WindowPickerKind,
        "title", isApplication ? "选择已打开应用" : "选择已打开窗口",
        "description", isHotkeyApplication ? "选择应用以添加快捷键配置。"
            : isApplication ? "选择应用并绑定它的全部窗口。" : "选择要绑定的窗口。",
        "rows", rows)
    DebugLog("Window picker pushed kind=" . WindowPickerKind . " count=" . rows.Length)
    SettingsPost("windowPicker", payload)
}

SettingsWindowPickerSelect(index, expectedSession) {
    global WindowPickerEditSession
    if expectedSession != WindowPickerEditSession || !SettingsIsEditMessage(Map("sessionId", expectedSession))
        return
    global WindowPickerKind, WindowPickerRows, WindowPickerBindingNumber, WindowPickerBindType
    if ((WindowPickerKind != "application" && WindowPickerKind != "window")
        || index < 1 || index > WindowPickerRows.Length || index != Floor(index)) {
        DebugLog("Window picker selection ignored: invalid kind or index")
        return
    }
    index := Integer(index)
    bindingNumber := WindowPickerBindingNumber
    bindType := WindowPickerBindType
    if WindowPickerKind = "application" {
        application := WindowPickerRows[index]
        applicationItems := WindowBindingApplicationItems(application.path)
        binding := {bindType: 3, applicationPath: application.path, items: applicationItems}
        SettingsCloseWindowPicker(false)
    } else {
        item := WindowPickerRows[index]
        if bindType = 2
            items := SettingsDraftWindowItems(bindingNumber)
        else
            items := []
        if bindType != 2 || !ContainsWindow(items, item.id)
            items.Push(item)
        binding := {bindType: bindType, applicationPath: "", items: items}
        SettingsCloseWindowPicker(false)
    }
    if !SettingsStageWindowBinding(bindingNumber, binding, expectedSession)
        SettingsSendPickerFailure(expectedSession)
}

SettingsSendPickerFailure(expectedSession) {
    global SettingsHost
    if SettingsIsEditMessage(Map("sessionId", expectedSession))
        SettingsPost("pickerFailed", Map("sessionId", expectedSession))
}

SettingsWindowPickerCancel(expectedSession, *) {
    if !SettingsIsEditMessage(Map("sessionId", expectedSession))
        return
    global SettingsHost, WindowPickerKind
    reopenHotkeyApplications := WindowPickerKind = "hotkeyApplication"
    DebugLog("Window picker cancelled kind=" . WindowPickerKind)
    if reopenHotkeyApplications {
        SettingsCloseWindowPicker(false)
        if IsObject(SettingsHost) && PanelHostPageReady(SettingsHost)
            SettingsPost("openApplicationDialog")
        return
    }
    SettingsCloseWindowPicker(true)
}

SettingsCloseWindowPicker(restoreSettings := true) {
    global WindowPickerEditSession, SettingsEditSessionId
    global SettingsHost, WindowPickerVisible, WindowPickerKind
    global WindowPickerRows, WindowPickerBindingNumber, WindowPickerBindType
    WindowPickerVisible := false
    WindowPickerKind := ""
    WindowPickerRows := []
    WindowPickerBindingNumber := 0
    WindowPickerBindType := 1
    WindowPickerEditSession := ""
    if IsObject(SettingsHost) && PanelHostPageReady(SettingsHost)
        SettingsPost("closeWindowPicker")
    if restoreSettings
        SettingsShow("windows")
}

; Host-owned transient window selections; persisted values contain no HWND/PID.
global SettingsWindowSelectionTokens := Map()

SettingsStageWindowBinding(slot, binding, expectedSession) {
    global SettingsHost, SettingsWindowSelectionTokens, SettingsEditSessionId
    if !SettingsIsEditMessage(Map("sessionId", expectedSession)) || !WindowBindingNumber(slot, 0)
        return false
    token := "ws_" . Format("{:08X}", A_TickCount) . "_" . Random(100000, 999999)
    pids := Map()
    items := []
    for item in binding.items {
        if !IsObject(item) || !WindowBindingParsePointer(item.id, &hwnd)
            return false
        DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "UInt*", &pid := 0, "UInt")
        expectedPid := ObjHasOwnProp(item, "selectionPid") ? item.selectionPid : 0
        if binding.bindType != 3 && expectedPid
            && (!WindowIsAlive(hwnd) || !pid || expectedPid != pid)
            return false
        if expectedPid
            pids[String(hwnd)] := pid
        items.Push({id: hwnd, path: String(item.path), exe: String(item.exe),
            windowClass: String(item.windowClass), title: WindowBindingItemTitle(item), selectionPid: expectedPid})
    }
    validated := {bindType: WindowBindingType(binding.bindType, 0),
        applicationPath: String(binding.applicationPath), items: items}
    if !validated.bindType
        return false
    if !SettingsIsEditMessage(Map("sessionId", expectedSession))
        return false
    SettingsDiscardWindowCandidates(slot)
    SettingsWindowSelectionTokens[token] := Map("slot", slot, "binding", validated, "pids", pids)
    row := Map("sessionId", expectedSession, "number", slot, "bindType", validated.bindType,
        "applicationPath", validated.applicationPath, "items", [])
    for item in items
        row["items"].Push(Map("title", item.title,
            "windowClass", item.windowClass, "exe", item.exe, "path", item.path))
    row["selectionToken"] := token
    if IsObject(SettingsHost) && PanelHostPageReady(SettingsHost)
        SettingsPost("bindingCandidate", row)
    return true
}

SettingsDiscardWindowCandidates(slot) {
    global SettingsWindowSelectionTokens
    stale := []
    for token, candidate in SettingsWindowSelectionTokens
        if candidate["slot"] = slot
            stale.Push(token)
    for token in stale
        SettingsWindowSelectionTokens.Delete(token)
}

SettingsClearWindowCandidate(slot) {
    global SettingsWindowSelectionTokens
    if !WindowBindingNumber(slot, 0)
        return
    SettingsDiscardWindowCandidates(slot)
    ; Keep an empty selection so adding a window cannot restore the saved group.
    ; This marker is internal and is replaced by the next real selection.
    SettingsWindowSelectionTokens["cleared_" . slot] := Map("slot", slot,
        "binding", {bindType: 0, applicationPath: "", items: []}, "pids", Map())
}

SettingsDraftWindowItems(slot) {
    global SettingsWindowSelectionTokens, SettingsEditData, WinBindings
    for token, candidate in SettingsWindowSelectionTokens
        if candidate["slot"] = slot
            return CloneWindowBindingItems(candidate["binding"].items)
    items := []
    for row in SettingsEditData["bindings"]
        if row["number"] = slot {
            if WinBindings.Has(slot) && SettingsBindingRowMatches(row, WinBindings[slot]) {
                items := CloneWindowBindingItems(WinBindings[slot].items)
                for item in items
                    item.selectionPid := 0
                return items
            }
            for item in row["items"]
                items.Push({id: 0, path: item["path"], exe: item["exe"],
                    windowClass: item["windowClass"], title: item["title"]})
        }
    return items
}

SettingsValidateBindingDraft(rows, &normalized, &errorText := "") {
    global SettingsWindowSelectionTokens, WinBindings, SettingsEditData
    normalized := []
    errorText := ""
    if Type(rows) != "Array" || rows.Length != 10 {
        errorText := "窗口绑定数据无效。"
        return false
    }
    baseBySlot := Map()
    for base in SettingsEditData["bindings"]
        baseBySlot[base["number"]] := base
    seenSlots := Map()
    for raw in rows {
        if Type(raw) != "Map" {
            errorText := "窗口绑定数据无效。"
            return false
        }
        slot := raw.Has("number") ? WindowBindingNumber(raw["number"], 0) : 0
        if !raw.Has("bindType") || !RegExMatch(String(raw["bindType"]), "^[0-3]$") {
            errorText := "窗口绑定模式无效，请重新选择。"
            return false
        }
        mode := Integer(raw["bindType"])
        if !slot || seenSlots.Has(slot) {
            errorText := "窗口绑定槽位或模式无效。"
            return false
        }
        seenSlots[slot] := true
        token := raw.Has("selectionToken") ? String(raw["selectionToken"]) : ""
        if token = "" && JSON.stringify(SettingsBindingLogicalValue(raw), 0)
            = JSON.stringify(SettingsBindingLogicalValue(baseBySlot[slot]), 0)
            continue
        if !mode {
            normalized.Push(Map("number", slot, "binding", 0))
            continue
        }
        if token != "" {
            if !SettingsWindowSelectionTokens.Has(token)
                || SettingsWindowSelectionTokens[token]["slot"] != slot {
                errorText := "窗口选择已过期，请重新选择。"
                return false
            }
            candidate := SettingsWindowSelectionTokens[token]
            binding := CloneWindowBinding(candidate["binding"])
            for item in binding.items {
                if mode = 3 || !candidate["pids"].Has(String(item.id))
                    continue
                if !WindowIsAlive(item.id) {
                    errorText := "所选窗口已关闭，请重新选择。"
                    return false
                }
                DllCall("GetWindowThreadProcessId", "Ptr", item.id, "UInt*", &pid := 0, "UInt")
                if candidate["pids"][String(item.id)] != pid {
                    errorText := "所选窗口已变化，请重新选择。"
                    return false
                }
            }
        } else {
            if !WinBindings.Has(slot) {
                errorText := "请先选择有效窗口或应用。"
                return false
            }
            existing := WinBindings[slot]
            if !SettingsBindingRowMatches(raw, existing) {
                errorText := "窗口选择已过期，请重新选择。"
                return false
            }
            binding := CloneWindowBinding(existing)
        }
        binding.bindType := mode
        if mode = 3 && binding.applicationPath = "" && binding.items.Length
            binding.applicationPath := binding.items[1].path
        if mode = 3 && binding.applicationPath = "" {
            errorText := "请选择有效的应用程序。"
            return false
        }
        if mode != 3 && !binding.items.Length {
            errorText := "请选择至少一个窗口。"
            return false
        }
        normalized.Push(Map("number", slot, "binding", binding))
    }
    return true
}

SettingsBindingRowMatches(raw, binding) {
    applicationPath := raw.Has("applicationPath") ? String(raw["applicationPath"]) : ""
    if applicationPath != WindowBindingApplicationPath(binding)
        return false
    if !raw.Has("items") || Type(raw["items"]) != "Array"
        || raw["items"].Length != binding.items.Length
        return false
    for index, item in binding.items {
        submitted := raw["items"][index]
        if Type(submitted) != "Map"
            return false
        if String(submitted.Get("path", "")) != String(item.path)
            || String(submitted.Get("exe", "")) != String(item.exe)
            || String(submitted.Get("windowClass", "")) != String(item.windowClass)
            return false
    }
    return true
}
