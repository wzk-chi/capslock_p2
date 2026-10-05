; Shared custom title-bar host behavior for WebView2 windows.
; Feature modules keep their own pinned/native state and call these helpers
; when a page uses pages/windowbar.js.

WindowBarApplyNativeMode(host, nativeWindow, pageSetter := "setNativeWindowMode") {
    panelGui := PanelHostGui(host)
    if !IsObject(panelGui)
        return false

    hwnd := panelGui.Hwnd
    windowTitle := "ahk_id " . hwnd
    if !host.Has("windowBarOriginalStyle") {
        host["windowBarOriginalStyle"] := WindowBarGetLong(hwnd, -16) ; GWL_STYLE
        host["windowBarOriginalExStyle"] := WindowBarGetLong(hwnd, -20) ; GWL_EXSTYLE
        host["windowBarOriginalOwner"] := DllCall("GetWindow", "ptr", hwnd,
            "uint", 4, "ptr") ; GW_OWNER
    }
    host["windowBarNative"] := !!nativeWindow

    originalStyle := host["windowBarOriginalStyle"]
    originalExStyle := host["windowBarOriginalExStyle"]
    originalOwner := host["windowBarOriginalOwner"]
    wasVisible := DllCall("IsWindowVisible", "ptr", hwnd, "int")
    wasActive := WinActive(windowTitle)
    wasMinimized := DllCall("IsIconic", "ptr", hwnd, "int")
    if nativeWindow {
        ; Turn the borderless host into a normal application window.
        ; WS_CAPTION alone is not enough: the box styles are what make the
        ; native minimize/maximize buttons appear in the standard title bar.
        style := originalStyle | 0x00C00000 | 0x00020000 | 0x00010000 | 0x00080000
        exStyle := (originalExStyle & ~0x00000080) | 0x00040000 ; APPWINDOW, not TOOLWINDOW
        owner := 0
    } else {
        ; Restore exactly what the host used before entering native mode.
        style := originalStyle
        exStyle := originalExStyle
        owner := originalOwner
    }

    ; A taskbar button is affected by both the extended style and ownership.
    ; Set them through Win32 so the shell sees one consistent transition.
    WindowBarSetLong(hwnd, -16, style) ; GWL_STYLE
    WindowBarSetLong(hwnd, -20, exStyle) ; GWL_EXSTYLE
    WindowBarSetLong(hwnd, -8, owner) ; GWLP_HWNDPARENT / owner

    ; SWP_FRAMECHANGED recalculates the non-client frame. Hiding and showing
    ; an already visible window makes Explorer rebuild its taskbar entry after
    ; the TOOLWINDOW -> APPWINDOW transition instead of retaining old state.
    if wasVisible
        DllCall("ShowWindow", "ptr", hwnd, "int", 0) ; SW_HIDE
    try DllCall("SetWindowPos", "ptr", panelGui.Hwnd, "ptr", 0,
        "int", 0, "int", 0, "int", 0, "int", 0,
        "uint", 0x37)
    if wasVisible
        DllCall("ShowWindow", "ptr", hwnd, "int", wasMinimized ? 7 : 8) ; SW_SHOWMINNOACTIVE/SW_SHOWNA
    if wasActive && !wasMinimized {
        WinActivate(windowTitle)
        ShowSystemCursor()
    }

    PanelHostFill(host)
    if pageSetter != ""
        PanelHostExecute(host, "window." . pageSetter . "(" . (nativeWindow ? "true" : "false") . ");")
    return true
}

WindowBarGetLong(hwnd, index) {
    api := A_PtrSize = 8 ? "GetWindowLongPtr" : "GetWindowLong"
    return DllCall(api, "ptr", hwnd, "int", index, "ptr")
}

WindowBarSetLong(hwnd, index, value) {
    api := A_PtrSize = 8 ? "SetWindowLongPtr" : "SetWindowLong"
    return DllCall(api, "ptr", hwnd, "int", index, "ptr", value, "ptr")
}

WindowBarBeginDrag(host) {
    panelGui := PanelHostGui(host)
    if !IsObject(panelGui)
        return false

    ; The page owns the custom title bar. Hand the mouse press back to the
    ; window manager so both custom and native hosts follow normal dragging.
    try DllCall("ReleaseCapture")
    try PostMessage(0xA1, 2, 0, , "ahk_id " . panelGui.Hwnd) ; WM_NCLBUTTONDOWN/HTCAPTION
    return true
}

WindowBarIsNative(host) {
    return IsObject(host) && host.Has("windowBarNative") && host["windowBarNative"]
}

WindowBarIsPinned(host) {
    return IsObject(host) && host.Has("windowBarPinned") && host["windowBarPinned"]
}

WindowBarSetPinnedPage(host, pinned) {
    if !IsObject(host)
        return false
    return PanelHostExecute(host, "window.setPinned(" . (pinned ? "true" : "false") . ");")
}

WindowBarSyncPageState(host) {
    if !IsObject(host)
        return false
    native := WindowBarIsNative(host) ? "true" : "false"
    pinned := WindowBarIsPinned(host) ? "true" : "false"
    return PanelHostExecute(host, "window.setNativeWindowMode(" . native
        . ");window.setPinned(" . pinned . ");")
}

WindowBarHandleMessage(host, messageType, hideCallback, pinnedCallback := 0,
    options := 0, nativeCallback := 0) {
    if messageType = "windowDragStart" {
        WindowBarBeginDrag(host)
        return true
    }
    if messageType = "windowToggleNative" {
        native := !WindowBarIsNative(host)
        WindowBarApplyNativeMode(host, native)
        if IsObject(nativeCallback)
            nativeCallback.Call(native)
        return true
    }
    if messageType = "togglePinned" {
        pinned := !WindowBarIsPinned(host)
        WindowBarApplyPinnedState(host, pinned, host["visible"], hideCallback, options)
        WindowBarSetPinnedPage(host, pinned)
        if IsObject(pinnedCallback)
            pinnedCallback.Call(pinned)
        return true
    }
    if messageType = "hide" {
        if IsObject(hideCallback)
            hideCallback.Call()
        return true
    }
    return false
}

WindowBarHandleDebugMessage(msg, feature) {
    if !IsObject(msg) || LLMMsgField(msg, "type") != "uiDebug"
        return false
    source := LLMMsgField(msg, "source")
    stage := LLMMsgField(msg, "stage")
    detail := LLMMsgField(msg, "detail")
    DebugLog("ui-debug feature=" . feature . " source=" . source
        . " stage=" . stage . (detail != "" ? " detail=" . detail : ""))
    return true
}

WindowBarApplyPinnedState(host, pinned, visible, focusCallback, options := 0) {
    panelGui := PanelHostGui(host)
    if !IsObject(panelGui)
        return false

    host["windowBarPinned"] := !!pinned
    WinSetAlwaysOnTop(pinned, "ahk_id " . panelGui.Hwnd)
    options := IsObject(options) ? options : Map()
    autoHide := !options.Has("autoHide") || options["autoHide"]
    if !autoHide || pinned || !visible
        PanelHostStopAutoHide(host)
    else if IsObject(focusCallback)
        PanelHostStartAutoHide(host, focusCallback, options)
    return true
}
