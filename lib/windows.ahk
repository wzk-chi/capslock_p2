; Window binding, transparency and mouse-speed features.

global WindowBindingFile := A_ScriptDir . "\capslock_p2-winsInfosRecorder.ini"
global WinBindings := Map()
global PendingBindingNumber := -1
global PendingBindingCount := 0
global PendingBindingTime := 0
global WinTapedX := -1
global LastActiveWinId := 0
global GettingWinInfo := false
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
        bindingNumber := sectionName + 0
        if bindingNumber < 1 || bindingNumber > 10
            continue

        bindType := values.Has("bindType") ? WindowBindingType(values["bindType"], 0) : 0
        items := []
        count := values.Has("count") ? values["count"] + 0 : 0
        if count > 0 {
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
        if bindType && items.Length
            WinBindings[bindingNumber] := {bindType: bindType, items: items}
    }
}

WindowBindingType(value, fallback := 1) {
    try number := Integer(value)
    catch
        return fallback
    if number < 1 || number > 3
        return fallback
    return number
}

WindowBindingDisplay(bindType) {
    switch WindowBindingType(bindType, 0) {
        case 1:
            return Map("label", "单个窗口", "description", "只绑定当前激活的窗口")
        case 2:
            return Map("label", "窗口组", "description", "把当前窗口追加到已有窗口组")
        case 3:
            return Map("label", "同应用窗口", "description", "自动匹配同一程序的窗口")
        default:
            return Map("label", "未绑定", "description", "尚未捕获窗口")
    }
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

WindowIsAlive(hwnd) {
    return hwnd && WinExist("ahk_id " . hwnd)
}

SaveWindowBinding(bindingNumber, binding) {
    global WindowBindingFile
    if !binding
        return
    try {
        IniWrite(binding.bindType, WindowBindingFile, bindingNumber, "bindType")
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

ContainsWindow(items, hwnd) {
    for item in items {
        if item.id = hwnd
            return true
    }
    return false
}

CloneWindowItems(items) {
    result := []
    for item in items
        result.Push({id: item.id, windowClass: item.windowClass, exe: item.exe, path: item.path})
    return result
}

BindingTap(bindingNumber) {
    global PendingBindingNumber, PendingBindingCount, PendingBindingTime, GettingWinInfo
    now := A_TickCount
    if PendingBindingNumber = bindingNumber && now - PendingBindingTime < 500 {
        PendingBindingCount := Min(PendingBindingCount + 1, 3)
    } else {
        PendingBindingNumber := bindingNumber
        PendingBindingCount := 1
    }
    PendingBindingTime := now
    GettingWinInfo := true
    SetTimer(CompletePendingBinding, -500)
}

CompletePendingBinding(*) {
    global PendingBindingNumber, PendingBindingCount, GettingWinInfo
    pendingNumber := PendingBindingNumber
    count := PendingBindingCount
    PendingBindingNumber := -1
    PendingBindingCount := 0
    GettingWinInfo := false
    if pendingNumber > 0 && count > 0
        BindWindowFromActive(pendingNumber, count)
}

BindWindowFromActive(bindingNumber, bindType) {
    global WinBindings
    bindType := WindowBindingType(bindType)
    active := GetActiveWindowInfo()
    if !active
        return

    if bindType = 1 {
        binding := {bindType: 1, items: [active]}
    } else if bindType = 2 {
        if WinBindings.Has(bindingNumber) && WinBindings[bindingNumber].bindType != 3
            items := CloneWindowItems(WinBindings[bindingNumber].items)
        else
            items := []
        if !ContainsWindow(items, active.id)
            items.Push(active)
        binding := {bindType: 2, items: items}
    } else {
        items := []
        windowList := WinGetList("ahk_class " . active.windowClass . " ahk_exe " . active.exe)
        for hwnd in windowList {
            item := GetActiveWindowInfo(hwnd)
            if item
                items.Push(item)
        }
        if !items.Length
            items.Push(active)
        binding := {bindType: 3, items: items}
    }

    WinBindings[bindingNumber] := binding
    SaveWindowBinding(bindingNumber, binding)
    ShowMsg("Window binding " . bindingNumber . " saved (mode " . bindType . ")", 1200)
}

FindReplacementWindow(item) {
    if WindowIsAlive(item.id)
        return item.id
    if item.windowClass = "" || item.exe = ""
        return 0
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

RefreshProgramBinding(binding) {
    if !binding.items.Length
        return false
    anchor := binding.items[1]
    for item in binding.items {
        if item.windowClass != "" && item.exe != "" {
            anchor := item
            break
        }
    }
    changed := PruneBindingItems(binding)
    if anchor.windowClass = "" || anchor.exe = ""
        return changed
    windowList := WinGetList("ahk_class " . anchor.windowClass . " ahk_exe " . anchor.exe)
    for hwnd in windowList {
        if !ContainsWindow(binding.items, hwnd) {
            item := GetActiveWindowInfo(hwnd)
            if item {
                binding.items.Push(item)
                changed := true
            }
        }
    }
    return changed
}

ActivateWinId(hwnd) {
    if WindowIsAlive(hwnd)
        WinActivate("ahk_id " . hwnd)
}

activateWinAction(bindingNumber) {
    global WinBindings, LastActiveWinId, WinTapedX
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

    bindingChanged := binding.bindType = 3
        ? RefreshProgramBinding(binding)
        : PruneBindingItems(binding)
    if bindingChanged
        SaveWindowBinding(bindingNumber, binding)
    if !binding.items.Length
        return

    WinTapedX := bindingNumber
    activeId := WinExist("A")
    currentIndex := 0
    for index, item in binding.items {
        if item.id = activeId {
            currentIndex := index
            break
        }
    }
    nextIndex := currentIndex = 0 || currentIndex >= binding.items.Length ? 1 : currentIndex + 1
    ActivateWinId(binding.items[nextIndex].id)
}

winsSort(bindingNumber) {
    global WinBindings, WinTapedX
    if WinBindings.Has(bindingNumber) {
        binding := WinBindings[bindingNumber]
        activeId := WinExist("A")
        for index, item in binding.items {
            if item.id = activeId {
                if index > 1
                    binding.items.InsertAt(1, binding.items.RemoveAt(index))
                break
            }
        }
    }
    WinTapedX := -1
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
