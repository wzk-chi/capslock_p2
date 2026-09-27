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
    WinBindings := Map()
    sections := ConfigParseIni(WindowBindingFile)
    for sectionName, values in sections {
        if !RegExMatch(sectionName, "^\d+$")
            continue
        bindingNumber := WindowBindingNumber(sectionName, 0)
        if !bindingNumber
            continue

        bindType := values.Has("bindType") ? WindowBindingType(values["bindType"], 0) : 0
        applicationPath := values.Has("applicationPath") ? Trim(String(values["applicationPath"])) : ""
        if bindType = 2 && applicationPath != ""
            bindType := 3
        items := []
        hasCount := values.Has("count")
        count := hasCount ? values["count"] + 0 : 0
        if hasCount {
            Loop count {
                index := A_Index
                item := ReadWindowBindingItem(values, index)
                if item
                    items.Push(item)
            }
        } else {
            ; Read the v1 recorder format as well (it used index 0).
            index := 0
            while values.Has("id_" . index) {
                item := ReadWindowBindingItem(values, index)
                if item
                    items.Push(item)
                index += 1
            }
        }
        if bindType = 3 && applicationPath = "" && items.Length
            applicationPath := items[1].path
        if bindType && (items.Length || applicationPath != "")
            WinBindings[bindingNumber] := {bindType: bindType, applicationPath: applicationPath, items: items}
    }
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

ReadWindowBindingItem(values, index) {
    idKey := "id_" . index
    if !values.Has(idKey)
        return 0
    className := values.Has("class_" . index) ? values["class_" . index] : ""
    exeName := values.Has("exe_" . index) ? values["exe_" . index] : ""
    path := values.Has("path_" . index) ? values["path_" . index] : exeName
    return {id: values[idKey] + 0, windowClass: className, exe: exeName, path: path}
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
        return
    try {
        IniWrite(binding.bindType, WindowBindingFile, bindingNumber, "bindType")
        IniWrite(WindowBindingApplicationPath(binding), WindowBindingFile, bindingNumber, "applicationPath")
        IniWrite(binding.items.Length, WindowBindingFile, bindingNumber, "count")
        for index, item in binding.items {
            IniWrite(item.id, WindowBindingFile, bindingNumber, "id_" . index)
            IniWrite(item.windowClass, WindowBindingFile, bindingNumber, "class_" . index)
            IniWrite(item.exe, WindowBindingFile, bindingNumber, "exe_" . index)
            IniWrite(item.path, WindowBindingFile, bindingNumber, "path_" . index)
        }
    } catch as bindingError {
        ShowMsg("Unable to save window binding: " . bindingError.Message, 2500)
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
    WinBindings[bindingNumber] := binding
    SaveWindowBinding(bindingNumber, binding)
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
    WinBindings[bindingNumber] := binding
    SaveWindowBinding(bindingNumber, binding)
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
    WinBindings[bindingNumber] := binding
    SaveWindowBinding(bindingNumber, binding)
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
        if bindingChanged
            SaveWindowBinding(bindingNumber, binding)
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
    if bindingChanged
        SaveWindowBinding(bindingNumber, binding)
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

ShowSystemCursor() {
    ; ShowCursor() keeps a per-thread display counter. Calling it with TRUE
    ; once is not enough when another component has taken the counter below
    ; zero, while calling it repeatedly without compensating would make the
    ; counter grow every time a panel gets focus. Bring a hidden cursor back
    ; to zero, and leave an already-visible counter unchanged.
    count := DllCall("ShowCursor", "Int", 1)
    if count < 0 {
        while count < 0
            count := DllCall("ShowCursor", "Int", 1)
    } else {
        DllCall("ShowCursor", "Int", -1)
    }
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

winTransparent() {
    WinTransparentStart()
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
