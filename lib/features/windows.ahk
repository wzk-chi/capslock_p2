; Window binding, transparency and mouse-speed features.

global WindowBindingFile := A_ScriptDir . "\capslock_p2-winsInfosRecorder.ini"
global WinBindings := Map()
global PendingBindingNumber := -1
global PendingBindingCount := 0
global PendingBindingTime := 0
global LastActiveWinId := 0
global MinimizeWinStack := []
global WinTransparentActive := false
global WinTransparentId := 0
global WinTransparentValue := 255
global WinTransparentStartedAt := 0
global AllowWinTransparentToggle := true
global MouseSpeed := 3
global OriginalMouseSpeed := 0
global MouseSpeedChanged := false

InitializeWindowBindings() {
    LoadWindowBindings()
}

LoadWindowBindings() {
    global WinBindings, WindowBindingFile
    loaded := true
    try sections := ConfigParseIni(WindowBindingFile, &loaded)
    catch as loadError {
        DebugLog("Window binding load failed errorType=" . Type(loadError))
        return false
    }
    if !loaded {
        DebugLog("Window binding load failed: unable to read file")
        return false
    }

    candidateBindings := Map()
    for sectionName, values in sections {
        if !RegExMatch(sectionName, "^\d+$")
            continue
        bindingNumber := WindowBindingNumber(sectionName, 0)
        if !bindingNumber
            continue

        bindType := values.Has("bindType") ? WindowBindingType(values["bindType"], 0) : 0
        if values.Has("bindType") && !bindType
            DebugLog("Window binding data rejected binding=" . bindingNumber . " field=bindType")
        applicationPath := values.Has("applicationPath") ? Trim(String(values["applicationPath"])) : ""
        if bindType = 2 && applicationPath != ""
            bindType := 3
        items := []
        hasCount := values.Has("count")
        count := 0
        countValid := !hasCount || WindowBindingParseUnsigned(values["count"], &count)
        if hasCount && !countValid
            DebugLog("Window binding data rejected binding=" . bindingNumber . " field=count")
        if countValid {
            itemKeys := WindowBindingItemKeys(values, hasCount, count, bindingNumber)
            for itemKey in itemKeys {
                item := ReadWindowBindingItem(values, itemKey.suffix, bindingNumber, itemKey.idKey)
                if item
                    items.Push(item)
            }
        }
        if bindType = 3 && applicationPath = "" && items.Length
            applicationPath := items[1].path
        if bindType && (items.Length || applicationPath != "")
            candidateBindings[bindingNumber] := {bindType: bindType, applicationPath: applicationPath, items: items}
    }
    WinBindings := candidateBindings
    return true
}

WindowBindingType(value, fallback := 1) {
    value := Trim(String(value))
    if !RegExMatch(value, "^[1-3]$")
        return fallback
    return Integer(value)
}

WindowBindingNumber(value, fallback := 0) {
    value := Trim(String(value))
    if !RegExMatch(value, "^(?:[1-9]|10)$")
        return fallback
    return Integer(value)
}

WindowBindingModes() {
    return [
        Map("id", 1, "label", "窗口", "description", "绑定一个已打开窗口"),
        Map("id", 2, "label", "窗口组", "description", "添加已打开窗口到窗口组"),
        Map("id", 3, "label", "应用", "description", "自动绑定应用的全部窗口")]
}

WindowBindingDisplay(bindType) {
    bindType := WindowBindingType(bindType, 0)
    if !bindType
        return Map("id", 0, "label", "未绑定", "description", "尚未选择窗口")
    for mode in WindowBindingModes() {
        if mode["id"] = bindType
            return mode
    }
    return Map("id", 0, "label", "未绑定", "description", "尚未选择窗口")
}

WindowBindingParseUnsigned(value, &number, maximum := 9223372036854775807) {
    number := 0
    text := Trim(String(value))
    if !RegExMatch(text, "^\d+$")
        return false
    text := RegExReplace(text, "^0+(?=\d)")
    if StrLen(text) > 19
        return false
    try parsed := Integer(text)
    catch
        return false
    if parsed < 0 || parsed > maximum
        return false
    number := parsed
    return true
}

WindowBindingParsePointer(value, &pointer) {
    maximum := A_PtrSize = 8 ? 9223372036854775807 : 4294967295
    return WindowBindingParseUnsigned(value, &pointer, maximum)
}

WindowBindingIndexSortKey(index) {
    return SubStr("0000000000000000000" . String(index), -19)
}

WindowBindingItemKeys(values, hasCount, count, bindingNumber) {
    itemKeys := Map()
    duplicateKeys := Map()
    sortText := ""
    for key, value in values {
        if !RegExMatch(String(key), "i)^id_(\d+)$", &match)
            continue
        suffix := match[1]
        if !WindowBindingParseUnsigned(suffix, &index) {
            DebugLog("Window binding item skipped binding=" . bindingNumber . " reason=invalid-index")
            continue
        }
        if hasCount && (index < 1 || index > count) {
            DebugLog("Window binding item skipped binding=" . bindingNumber . " reason=outside-count")
            continue
        }

        sortKey := WindowBindingIndexSortKey(index)
        if duplicateKeys.Has(sortKey)
            continue
        if itemKeys.Has(sortKey) {
            itemKeys.Delete(sortKey)
            duplicateKeys[sortKey] := true
            DebugLog("Window binding item skipped binding=" . bindingNumber . " reason=duplicate-index")
            continue
        }
        itemKeys[sortKey] := {index: index, suffix: suffix, idKey: String(key)}
        sortText .= sortKey . Chr(10)
    }

    ordered := []
    if sortText = ""
        return ordered
    for sortKey in StrSplit(Sort(RTrim(sortText, Chr(10)), "C", Chr(10)), Chr(10)) {
        if itemKeys.Has(sortKey)
            ordered.Push(itemKeys[sortKey])
    }
    return ordered
}

ReadWindowBindingItem(values, indexSuffix, bindingNumber := 0, idKey := "") {
    if idKey = ""
        idKey := "id_" . indexSuffix
    if !values.Has(idKey)
        return 0
    if !WindowBindingParsePointer(values[idKey], &id) {
        DebugLog("Window binding item skipped binding=" . bindingNumber . " reason=invalid-hwnd")
        return 0
    }
    classKey := "class_" . indexSuffix
    exeKey := "exe_" . indexSuffix
    pathKey := "path_" . indexSuffix
    className := values.Has(classKey) ? String(values[classKey]) : ""
    exeName := values.Has(exeKey) ? String(values[exeKey]) : ""
    path := values.Has(pathKey) ? String(values[pathKey]) : exeName
    return {id: id, windowClass: className, exe: exeName, path: path}
}

WindowBindingApplicationPath(binding) {
    if !IsObject(binding) || !ObjHasOwnProp(binding, "applicationPath")
        return ""
    return Trim(String(binding.applicationPath))
}

GetActiveWindowInfo(hwnd := 0) {
    if !hwnd
        hwnd := WinExist("A")
    if !hwnd
        return 0
    try {
        className := WinGetClass(hwnd)
        path := WinGetProcessPath(hwnd)
        exeName := WinGetProcessName(hwnd)
    } catch
        return 0
    return {id: hwnd, windowClass: className, exe: exeName, path: path}
}

WindowBindingIsVisible(hwnd) {
    try return (WinGetStyle(hwnd) & 0x10000000) != 0
    catch
        return false
}

WindowBindingOpenWindows(excludeHwnd := 0) {
    items := []
    for hwnd in WinGetList() {
        if excludeHwnd && hwnd = excludeHwnd
            continue
        if !WindowBindingIsVisible(hwnd)
            continue
        try {
            title := Trim(String(WinGetTitle(hwnd)))
            className := WinGetClass(hwnd)
        } catch
            continue
        if title = "" && className = ""
            continue
        item := GetActiveWindowInfo(hwnd)
        if !item
            continue
        item.title := title != "" ? title : "（无标题）"
        items.Push(item)
    }
    return items
}

WindowBindingApplicationItems(applicationPath) {
    applicationPath := Trim(String(applicationPath))
    items := []
    if applicationPath = ""
        return items
    for item in WindowBindingOpenWindows() {
        if item.path != "" && StrLower(String(item.path)) = StrLower(applicationPath)
            items.Push(item)
    }
    return items
}

WindowBindingOpenApplications(excludeHwnd := 0) {
    applications := Map()
    for item in WindowBindingOpenWindows(excludeHwnd) {
        if item.path = ""
            continue
        key := StrLower(String(item.path))
        if !applications.Has(key)
            applications[key] := {path: item.path, exe: item.exe, items: []}
        applications[key].items.Push(item)
    }
    result := []
    for key, application in applications
        result.Push(application)
    return result
}

WindowBindingItemTitle(item) {
    if IsObject(item) && ObjHasOwnProp(item, "title") && item.title != ""
        return String(item.title)
    if IsObject(item) && WindowIsAlive(item.id) {
        try return Trim(String(WinGetTitle(item.id)))
    }
    return ""
}

WindowIsAlive(hwnd) {
    return hwnd && WinExist("ahk_id " . hwnd)
}

SaveWindowBinding(bindingNumber, binding) {
    global WindowBindingFile
    bindingNumber := WindowBindingNumber(bindingNumber)
    if !binding || !bindingNumber
        return false
    try {
        bindType := IsObject(binding) && ObjHasOwnProp(binding, "bindType")
            ? WindowBindingType(binding.bindType, 0) : 0
        if !bindType || !ObjHasOwnProp(binding, "items") || !(binding.items is Array)
            throw ValueError("Invalid window binding")
        applicationPath := WindowBindingApplicationPath(binding)
        if InStr(applicationPath, Chr(10)) || InStr(applicationPath, Chr(13))
            throw ValueError("Invalid application path")

        lines := ["[" . bindingNumber . "]",
            "bindType=" . bindType,
            "applicationPath=" . applicationPath,
            "count=" . binding.items.Length]
        for index, item in binding.items {
            if !IsObject(item) || !ObjHasOwnProp(item, "id")
                throw ValueError("Invalid window binding item")
            if !WindowBindingParsePointer(item.id, &id)
                throw ValueError("Invalid window handle")
            className := ObjHasOwnProp(item, "windowClass") ? String(item.windowClass) : ""
            exeName := ObjHasOwnProp(item, "exe") ? String(item.exe) : ""
            path := ObjHasOwnProp(item, "path") ? String(item.path) : exeName
            metadata := className . exeName . path
            if InStr(metadata, Chr(10)) || InStr(metadata, Chr(13))
                throw ValueError("Invalid window metadata")
            lines.Push("id_" . index . "=" . id)
            lines.Push("class_" . index . "=" . className)
            lines.Push("exe_" . index . "=" . exeName)
            lines.Push("path_" . index . "=" . path)
        }
        content := FileExist(WindowBindingFile) ? FileRead(WindowBindingFile, "UTF-8") : ""
        content := ConfigDeleteIniSection(content, String(bindingNumber))
        content := RTrim(StrReplace(content, Chr(13), ""), Chr(10))
        if content != ""
            content .= Chr(10) . Chr(10)
        content .= ConfigJoinIniLines(lines)
        ConfigAtomicWrite(WindowBindingFile, content)
        return true
    } catch as bindingError {
        DebugLog("Window binding save failed number=" . bindingNumber
            . " errorType=" . Type(bindingError))
        ShowMsg(LLMText(
            "Unable to save this window binding. Check that the application folder is writable and try again.",
            "无法保存此窗口绑定。请确认安装目录可写后重试。"), 2500)
        return false
    }
}

BindingTap(bindingNumber) {
    global PendingBindingNumber, PendingBindingCount, PendingBindingTime
    bindingNumber := WindowBindingNumber(bindingNumber)
    if !bindingNumber
        return
    now := A_TickCount
    if PendingBindingNumber = bindingNumber && now - PendingBindingTime < 500
        PendingBindingCount := Min(PendingBindingCount + 1, 3)
    else {
        PendingBindingNumber := bindingNumber
        PendingBindingCount := 1
    }
    PendingBindingTime := now
    SetTimer(CompletePendingBinding, -500)
}

CompletePendingBinding(*) {
    global PendingBindingNumber, PendingBindingCount
    bindingNumber := WindowBindingNumber(PendingBindingNumber)
    bindType := PendingBindingCount
    PendingBindingNumber := -1
    PendingBindingCount := 0
    if bindingNumber && bindType >= 1
        BindWindowFromActive(bindingNumber, bindType)
}

BindWindowFromActive(bindingNumber, bindType) {
    bindingNumber := WindowBindingNumber(bindingNumber)
    if !bindingNumber
        return
    bindType := WindowBindingType(bindType, 0)
    if !bindType
        return
    active := GetActiveWindowInfo()
    if !active
        return
    if bindType = 1
        BindWindowToItem(bindingNumber, active)
    else if bindType = 2
        AddWindowToGroup(bindingNumber, active)
    else if active.path != ""
        BindWindowToApplication(bindingNumber, active.path)
}

BindWindowToItem(bindingNumber, item) {
    global WinBindings
    bindingNumber := WindowBindingNumber(bindingNumber)
    if !bindingNumber || !IsObject(item)
        return false
    binding := {bindType: 1, applicationPath: "", items: [item]}
    if !SaveWindowBinding(bindingNumber, binding)
        return false
    WinBindings[bindingNumber] := binding
    ShowMsg("Window binding " . bindingNumber . " saved (window)", 1200)
    return true
}

BindWindowItemSelection(bindingNumber, item, bindType) {
    bindType := WindowBindingType(bindType, 0)
    if !bindType
        return false
    if bindType = 1
        return BindWindowToItem(bindingNumber, item)
    if bindType = 2
        return AddWindowToGroup(bindingNumber, item)
    return false
}

CloneWindowBindingItems(items) {
    result := []
    for item in items {
        clone := {id: item.id, windowClass: item.windowClass, exe: item.exe, path: item.path}
        if ObjHasOwnProp(item, "title")
            clone.title := item.title
        result.Push(clone)
    }
    return result
}

WindowBindingSameApplicationPath(item, applicationPath) {
    return IsObject(item) && item.path != "" && applicationPath != "" && StrLower(String(item.path)) = StrLower(String(applicationPath))
}

AddWindowToGroup(bindingNumber, item) {
    global WinBindings
    bindingNumber := WindowBindingNumber(bindingNumber)
    if !bindingNumber || !IsObject(item)
        return false

    items := []
    applicationPath := ""
    if WinBindings.Has(bindingNumber) {
        existing := WinBindings[bindingNumber]
        items := CloneWindowBindingItems(existing.items)
        applicationPath := WindowBindingApplicationPath(existing)
        if existing.bindType != 2
            applicationPath := ""
    }
    if applicationPath != "" && !WindowBindingSameApplicationPath(item, applicationPath)
        applicationPath := ""
    if !ContainsWindow(items, item.id)
        items.Push(item)

    binding := {bindType: 2, applicationPath: applicationPath, items: items}
    if !SaveWindowBinding(bindingNumber, binding)
        return false
    WinBindings[bindingNumber] := binding
    ShowMsg("Window binding " . bindingNumber . " saved (group)", 1200)
    return true
}

BindWindowToApplication(bindingNumber, applicationPath) {
    global WinBindings
    bindingNumber := WindowBindingNumber(bindingNumber)
    applicationPath := Trim(String(applicationPath))
    if !bindingNumber || applicationPath = "" || !FileExist(applicationPath)
        return false
    items := WindowBindingApplicationItems(applicationPath)
    binding := {bindType: 3, applicationPath: applicationPath, items: items}
    if !SaveWindowBinding(bindingNumber, binding)
        return false
    WinBindings[bindingNumber] := binding
    ShowMsg("Window binding " . bindingNumber . " saved (application)", 1200)
    return true
}

FindReplacementWindow(item) {
    if WindowIsAlive(item.id)
        return item.id
    if item.exe = ""
        return 0
    if item.windowClass = ""
        windowList := WinGetList("ahk_exe " . item.exe)
    else
        windowList := WinGetList("ahk_class " . item.windowClass . " ahk_exe " . item.exe)
    if windowList.Length {
        item.id := windowList[1]
        return item.id
    }
    return 0
}

PruneBindingItems(binding) {
    changed := false
    kept := []
    for item in binding.items {
        if WindowIsAlive(item.id)
            kept.Push(item)
        else
            changed := true
    }
    binding.items := kept
    return changed
}

ContainsWindow(items, hwnd) {
    for item in items {
        if item.id = hwnd
            return true
    }
    return false
}

RefreshWindowGroup(binding) {
    changed := PruneBindingItems(binding)
    if binding.bindType != 3
        return changed
    applicationPath := WindowBindingApplicationPath(binding)
    if applicationPath = ""
        return changed
    for item in WindowBindingApplicationItems(applicationPath) {
        if !ContainsWindow(binding.items, item.id) {
            binding.items.Push(item)
            changed := true
        }
    }
    return changed
}

ActivateWinId(hwnd) {
    if WindowIsAlive(hwnd)
        WinActivate("ahk_id " . hwnd)
}

activateWinAction(bindingNumber) {
    global WinBindings, LastActiveWinId
    bindingNumber := WindowBindingNumber(bindingNumber)
    if !bindingNumber
        return
    if !WinBindings.Has(bindingNumber)
        return
    binding := WinBindings[bindingNumber]
    if binding.bindType = 1 {
        if !binding.items.Length
            return
        item := binding.items[1]
        replacement := FindReplacementWindow(item)
        if !replacement {
            if item.path != "" && FileExist(item.path) {
                try Run(item.path)
                catch as launchError
                    DebugLog("Window binding launch failed")
            }
            return
        }
        bindingChanged := item.id != replacement
        item.id := replacement
        if bindingChanged && !SaveWindowBinding(bindingNumber, binding)
            DebugLog("Window binding refresh persistence failed number=" . bindingNumber)
        if WinActive("ahk_id " . replacement) {
            WinMinimize("ahk_id " . replacement)
            if LastActiveWinId
                ActivateWinId(LastActiveWinId)
        } else {
            LastActiveWinId := WinExist("A")
            ActivateWinId(replacement)
        }
        return
    }

    bindingChanged := binding.bindType = 3 ? RefreshWindowGroup(binding) : PruneBindingItems(binding)
    if bindingChanged && !SaveWindowBinding(bindingNumber, binding)
        DebugLog("Window binding refresh persistence failed number=" . bindingNumber)
    if !binding.items.Length {
        applicationPath := WindowBindingApplicationPath(binding)
        if binding.bindType = 3 && applicationPath != "" && FileExist(applicationPath) {
            try Run(applicationPath)
            catch as launchError
                DebugLog("Window group launch failed")
        }
        return
    }

    activeId := WinExist("A")
    currentIndex := 0
    for index, item in binding.items {
        if item.id = activeId {
            currentIndex := index
            break
        }
    }
    ; Keep the saved order stable: next item, wrap after the last, or first
    ; item when the active window is outside this group.
    nextIndex := currentIndex = 0 || currentIndex >= binding.items.Length ? 1 : currentIndex + 1
    ActivateWinId(binding.items[nextIndex].id)
}

ClearWinMinimizeStack() {
    global MinimizeWinStack
    MinimizeWinStack := []
}

PopWinMinimizeStack() {
    global MinimizeWinStack
    if !MinimizeWinStack.Length
        return
    id := MinimizeWinStack.Pop()
    if WindowIsAlive(id)
        WinActivate("ahk_id " . id)
}

PushWinMinimizeStack() {
    InWinMinimizeStack(false)
}

UnshiftWinMinimizeStack() {
    InWinMinimizeStack(true)
}

InWinMinimizeStack(atBeginning := false) {
    global MinimizeWinStack
    id := WinExist("A")
    if !id
        return
    WinMinimize("ahk_id " . id)
    if atBeginning
        MinimizeWinStack.InsertAt(1, id)
    else
        MinimizeWinStack.Push(id)
}

InitializeMouseSpeed() {
    global MouseSpeed
    MouseSpeed := SettingInteger("Global", "mouseSpeed", 3, 1, 20)
    SetTimer(MouseSpeedTick, 50)
}

GetSystemMouseSpeed() {
    speedBuffer := Buffer(4, 0)
    if DllCall("SystemParametersInfoW", "UInt", 0x70, "UInt", 0, "Ptr", speedBuffer, "UInt", 0)
        return NumGet(speedBuffer, 0, "UInt")
    return 10
}

SetSystemMouseSpeed(value) {
    DllCall("SystemParametersInfoW", "UInt", 0x71, "UInt", 0, "Ptr", value, "UInt", 0)
}

MouseSpeedTick(*) {
    global CapsLockHeld, MouseSpeed, OriginalMouseSpeed, MouseSpeedChanged
    if CapsLockHeld && GetKeyState("LAlt", "P") {
        if !MouseSpeedChanged {
            OriginalMouseSpeed := GetSystemMouseSpeed()
            MouseSpeedChanged := true
        }
        SetSystemMouseSpeed(MouseSpeed)
    } else if MouseSpeedChanged {
        RestoreMouseSpeed()
    }
}

RestoreMouseSpeed() {
    global OriginalMouseSpeed, MouseSpeedChanged
    if MouseSpeedChanged && OriginalMouseSpeed
        SetSystemMouseSpeed(OriginalMouseSpeed)
    MouseSpeedChanged := false
}

WinTransparentStart() {
    global WinTransparentActive, WinTransparentId, WinTransparentValue, WinTransparentStartedAt, AllowWinTransparentToggle
    if WinTransparentActive
        return
    WinTransparentActive := true
    AllowWinTransparentToggle := true
    WinTransparentId := WinExist("A")
    WinTransparentValue := WinGetTransparent(WinTransparentId)
    if !WinTransparentValue
        WinTransparentValue := 0
    WinTransparentStartedAt := A_TickCount
    SetTimer(WinTransparentKeyCheck, 50)
    SetTimer(DisableWinTransparentToggle, -300)
}

DisableWinTransparentToggle(*) {
    global AllowWinTransparentToggle
    AllowWinTransparentToggle := false
}

WinTransparentReduce(*) {
    global WinTransparentActive, WinTransparentId, WinTransparentValue
    if !WinTransparentActive
        return
    if !WinTransparentValue
        WinTransparentValue := 245
    WinTransparentValue := Max(15, WinTransparentValue - 10)
    WinSetTransparent(WinTransparentValue, "ahk_id " . WinTransparentId)
}

WinTransparentAdd(*) {
    global WinTransparentActive, WinTransparentId, WinTransparentValue
    if !WinTransparentActive || WinTransparentValue >= 255
        return
    WinTransparentValue := Min(255, WinTransparentValue + 10)
    if WinTransparentValue >= 255
        WinSetTransparent("Off", "ahk_id " . WinTransparentId)
    else
        WinSetTransparent(WinTransparentValue, "ahk_id " . WinTransparentId)
}

WinTransparentKeyCheck(*) {
    global CapsLockHeld, WinTransparentActive, WinTransparentId, WinTransparentValue, WinTransparentStartedAt, AllowWinTransparentToggle
    if GetKeyState("F4", "P") && CapsLockHeld
        return

    SetTimer(WinTransparentKeyCheck, 0)
    if AllowWinTransparentToggle && A_TickCount - WinTransparentStartedAt < 300 {
        if WinTransparentValue
            WinSetTransparent("Off", "ahk_id " . WinTransparentId)
        else
            WinSetTransparent(170, "ahk_id " . WinTransparentId)
    }
    WinTransparentActive := false
}

RegisterFeatureHotkeys() {
    global WinTransparentActive
    HotIf((*) => WinTransparentActive)
    Hotkey("WheelUp", WinTransparentAdd)
    Hotkey("WheelDown", WinTransparentReduce)
    HotIf()
}
