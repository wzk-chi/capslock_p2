; Clipboard history WebView2 panel and message protocol.

global ClipboardHistoryHost := 0
global ClipboardHistoryVisible := false
global ClipboardHistoryPageReady := false
global ClipboardHistorySessionSerial := 0
global ClipboardHistorySessionId := ""
global ClipboardHistoryQuerySerial := 0
global ClipboardHistoryTargetHwnd := 0
global ClipboardHistoryTargetPid := 0
global ClipboardHistoryTargetContext := 0
global ClipboardHistoryPendingSearch := ""
global ClipboardHistoryPendingType := "all"
global ClipboardHistoryPendingFavorite := false
global ClipboardHistoryPendingDateFilter := "all"
global ClipboardHistoryPendingSelectedDate := ""
global ClipboardHistoryPendingDateAfter := ""
global ClipboardHistoryPendingDateBefore := ""
global ClipboardHistoryPendingPage := 1
global ClipboardHistoryPendingPageSize := 20
global ClipboardHistoryWidth := ScreenFitSize(860, 640, 720, 480)[1]
global ClipboardHistoryHeight := ScreenFitSize(860, 640, 720, 480)[2]
global ClipboardHistoryPasteBusy := false
global ClipboardHistoryClearTokens := Map()

ClipboardHistoryOpen(*) {
    shown := ClipboardHistoryShow()
    DebugLog("ClipboardHistoryOpen outcome=show result=" . shown)
}

ClipboardHistoryWindowVisible() {
    global ClipboardHistoryHost
    panelGui := PanelHostGui(ClipboardHistoryHost)
    if !IsObject(panelGui)
        return false
    hwnd := panelGui.Hwnd
    if !hwnd || !DllCall("IsWindowVisible", "ptr", hwnd, "int")
        return false
    try return WinGetMinMax("ahk_id " . hwnd) != -1
    catch
        return false
}

ClipboardHistoryShow(initialSearch := "", targetContext := 0, refreshSession := false) {
    global ClipboardHistoryHost, ClipboardHistoryVisible, ClipboardHistoryPageReady
    global ClipboardHistorySessionSerial, ClipboardHistorySessionId
    global ClipboardHistoryTargetHwnd, ClipboardHistoryPendingSearch
    global ClipboardHistoryTargetPid, ClipboardHistoryTargetContext
    global ClipboardHistoryPendingType, ClipboardHistoryPendingFavorite
    global ClipboardHistoryPendingDateFilter, ClipboardHistoryPendingSelectedDate
    global ClipboardHistoryPendingDateAfter, ClipboardHistoryPendingDateBefore
    global ClipboardHistoryPendingPage, ClipboardHistoryPendingPageSize, ClipboardHistoryQuerySerial
    DebugLog("ClipboardHistoryShow enter logicalVisible=" . ClipboardHistoryVisible
        . " windowVisible=" . ClipboardHistoryWindowVisible()
        . " hostExists=" . IsObject(ClipboardHistoryHost))
    if ClipboardHistoryVisible && ClipboardHistoryWindowVisible() {
        panelGui := PanelHostGui(ClipboardHistoryHost)
        if IsObject(panelGui)
            WinActivate("ahk_id " . panelGui.Hwnd)
        if refreshSession {
            ClipboardHistoryResetSession(initialSearch, targetContext, false)
            SetTimer(ClipboardHistorySendState, -1)
        }
        ShowSystemCursor()
        DebugLog("ClipboardHistoryShow reused pageReady=" . PanelHostPageReady(ClipboardHistoryHost))
        return true
    }
    ClipboardHistoryVisible := false

    ClipboardHistoryResetSession(initialSearch, targetContext, !refreshSession)

    if !ClipboardHistoryEnsureWebView() {
        DebugLog("ClipboardHistoryShow failed ensureWebView")
        return false
    }
    ClipboardHistoryVisible := true
    ClipboardHistoryPageReady := PanelHostPageReady(ClipboardHistoryHost)
    PanelHostShow(ClipboardHistoryHost, ClipboardHistoryWidth, ClipboardHistoryHeight, true)
    panelGui := PanelHostGui(ClipboardHistoryHost)
    if IsObject(panelGui)
        WinActivate("ahk_id " . panelGui.Hwnd)
    WindowBarApplyNativeMode(ClipboardHistoryHost, WindowBarIsNative(ClipboardHistoryHost))
    WindowBarApplyPinnedState(ClipboardHistoryHost, WindowBarIsPinned(ClipboardHistoryHost),
        true, ClipboardHistoryHide, Map("autoHide", false))
    WindowBarSetPinnedPage(ClipboardHistoryHost, WindowBarIsPinned(ClipboardHistoryHost))
    ShowSystemCursor()
    SetTimer(ClipboardHistorySendState, -1)
    DebugLog("ClipboardHistoryShow completed pageReady=" . ClipboardHistoryPageReady
        . " windowVisible=" . ClipboardHistoryWindowVisible())
    return true
}

ClipboardHistoryResetSession(initialSearch, targetContext, captureMissingTarget := true) {
    global ClipboardHistorySessionSerial, ClipboardHistorySessionId
    global ClipboardHistoryTargetHwnd, ClipboardHistoryTargetPid, ClipboardHistoryTargetContext
    global ClipboardHistoryPendingSearch, ClipboardHistoryPendingType, ClipboardHistoryPendingFavorite
    global ClipboardHistoryPendingDateFilter, ClipboardHistoryPendingSelectedDate
    global ClipboardHistoryPendingDateAfter, ClipboardHistoryPendingDateBefore
    global ClipboardHistoryPendingPage, ClipboardHistoryQuerySerial, ClipboardHistoryClearTokens
    if !IsObject(targetContext) {
        if targetContext
            targetContext := ClipboardHistoryTargetContextFromHwnd(targetContext)
        else if captureMissingTarget
            targetContext := ClipboardHistoryCaptureTargetContext()
    }
    ClipboardHistoryTargetContext := IsObject(targetContext) ? targetContext : 0
    ClipboardHistoryTargetHwnd := IsObject(targetContext) ? targetContext["hwnd"] : 0
    ClipboardHistoryTargetPid := IsObject(targetContext) ? targetContext["pid"] : 0
    ClipboardHistoryPendingSearch := String(initialSearch)
    ClipboardHistoryPendingType := "all"
    ClipboardHistoryPendingFavorite := false
    ClipboardHistoryPendingDateFilter := "all"
    ClipboardHistoryPendingSelectedDate := ""
    ClipboardHistoryPendingDateAfter := ""
    ClipboardHistoryPendingDateBefore := ""
    ClipboardHistoryPendingPage := 1
    ClipboardHistoryQuerySerial := 0
    ClipboardHistoryClearTokens := Map()
    ClipboardHistorySessionSerial += 1
    ClipboardHistorySessionId := "clipboard-history-" . ClipboardHistorySessionSerial . "-" . A_TickCount
}

ClipboardHistoryHide(*) {
    global ClipboardHistoryHost, ClipboardHistoryVisible, ClipboardHistorySessionId, ClipboardHistoryPageReady
    global ClipboardHistoryClearTokens, ClipboardHistoryTargetHwnd
    global ClipboardHistoryTargetPid, ClipboardHistoryTargetContext
    DebugLog("ClipboardHistoryHide session=" . ClipboardHistorySessionId
        . " windowVisible=" . ClipboardHistoryWindowVisible())
    ClipboardHistoryPost(Map("type", "sessionEnd", "sessionId", ClipboardHistorySessionId))
    ClipboardHistoryVisible := false
    ClipboardHistoryPageReady := false
    ClipboardHistorySessionId := ""
    ClipboardHistoryTargetHwnd := 0
    ClipboardHistoryTargetPid := 0
    ClipboardHistoryTargetContext := 0
    ClipboardHistoryClearTokens := Map()
    PanelHostHide(ClipboardHistoryHost)
    return true
}

ClipboardHistoryIsActive() {
    global ClipboardHistoryVisible, ClipboardHistoryHost
    return ClipboardHistoryVisible && PanelHostWindowActive(ClipboardHistoryHost)
}

ClipboardHistoryEnsureWebView() {
    global ClipboardHistoryHost, ClipboardHistoryWidth, ClipboardHistoryHeight
    if IsObject(ClipboardHistoryHost) {
        try {
            PanelHostEnsure(ClipboardHistoryHost)
            ClipboardHistoryDisableExternalDrop()
            DebugLog("ClipboardHistoryEnsureWebView existing success pageReady="
                . PanelHostPageReady(ClipboardHistoryHost))
            return true
        } catch as existingError {
            DebugLog("ClipboardHistoryEnsureWebView existing failed: " . existingError.Message)
            PanelHostHide(ClipboardHistoryHost)
            ShowMsg("剪贴板历史页面初始化失败：" . existingError.Message, 5000)
            return false
        }
    }

    ClipboardHistoryHost := PanelHostCreate(
        A_ScriptDir . "\pages\clipboard-history.html", "capslock_p2 剪贴板历史", Map(
            "guiOptions", "+Resize +MinimizeBox +MaximizeBox +SysMenu +ToolWindow -Caption",
            "dataPath", A_Temp . "\CapsLockPlusClipboardHistoryWebView2",
            "initialShow", "x-32000 y-32000 w" . ClipboardHistoryWidth . " h" . ClipboardHistoryHeight . " NA",
            "callbacks", Map(
                "close", ClipboardHistoryHide,
                "escape", ClipboardHistoryEscape,
                "resize", ClipboardHistoryResize,
                "navigation", ClipboardHistoryNavigationCompleted,
                "message", ClipboardHistoryWebMessageReceived)))
    try {
        PanelHostEnsure(ClipboardHistoryHost)
        ClipboardHistoryDisableExternalDrop()
        DebugLog("ClipboardHistoryEnsureWebView created success pageReady="
            . PanelHostPageReady(ClipboardHistoryHost))
        return true
    } catch as webViewError {
        DebugLog("ClipboardHistoryEnsureWebView create failed: " . webViewError.Message)
        PanelHostHide(ClipboardHistoryHost)
        ShowMsg("剪贴板历史页面初始化失败：" . webViewError.Message, 5000)
        return false
    }
}

ClipboardHistoryDisableExternalDrop() {
    global ClipboardHistoryHost
    ; AllowExternalDrop belongs to ICoreWebView2Controller4, not the base controller.
    try {
        controller4 := ComObjQuery(ClipboardHistoryHost["controller"], WebView2.Controller.IID_4)
        if !controller4
            throw Error("ICoreWebView2Controller4 不可用")
        ComCall(37, controller4, "int", 0)
    } catch as dropError {
        DebugLog("Clipboard history external drop disable failed")
    }
}

ClipboardHistoryNavigationCompleted(host, sender, args) {
    global ClipboardHistoryVisible, ClipboardHistoryPageReady
    ClipboardHistoryPageReady := PanelHostPageReady(host)
    if !ClipboardHistoryPageReady {
        try ShowMsg("剪贴板历史页面加载失败（" . args.WebErrorStatus . "）。", 4000)
        return
    }
    WindowBarSyncPageState(host)
    if ClipboardHistoryVisible
        SetTimer(ClipboardHistorySendState, -1)
}

ClipboardHistoryResize(targetGui, minMax, width, height) {
    global ClipboardHistoryHost
    PanelHostResize(ClipboardHistoryHost, minMax)
}

ClipboardHistoryEscape(*) {
    ClipboardHistoryHide()
}

ClipboardHistorySendState(*) {
    global ClipboardHistoryVisible, ClipboardHistoryPageReady
    global ClipboardHistorySessionId, ClipboardHistoryPendingSearch
    global ClipboardHistoryPendingType, ClipboardHistoryPendingFavorite
    global ClipboardHistoryPendingDateFilter, ClipboardHistoryPendingSelectedDate
    global ClipboardHistoryPendingDateAfter, ClipboardHistoryPendingDateBefore
    global ClipboardHistoryPendingPageSize
    if !ClipboardHistoryVisible || !ClipboardHistoryPageReady
        return
    ClipboardHistoryPost(Map("type", "hostState", "sessionId", ClipboardHistorySessionId,
        "search", ClipboardHistoryPendingSearch, "primaryType", ClipboardHistoryPendingType,
        "favoriteOnly", ClipboardHistoryPendingFavorite,
        "dateFilter", ClipboardHistoryPendingDateFilter,
        "selectedDate", ClipboardHistoryPendingSelectedDate,
        "dateAfter", ClipboardHistoryPendingDateAfter,
        "dateBefore", ClipboardHistoryPendingDateBefore,
        "pageSize", ClipboardHistoryPendingPageSize))
}

ClipboardHistoryPanelChanged() {
    global ClipboardHistoryVisible
    if ClipboardHistoryVisible
        SetTimer(ClipboardHistorySendState, -1)
}

ClipboardHistoryPanelQuery(searchText, primaryType, favoriteOnly, dateFilter, selectedDate,
    dateAfter, dateBefore, page, pageSize, sessionId, queryId) {
    global ClipboardHistoryVisible, ClipboardHistorySessionId
    global ClipboardHistoryPendingSearch, ClipboardHistoryPendingType
    global ClipboardHistoryPendingFavorite, ClipboardHistoryPendingDateFilter
    global ClipboardHistoryPendingSelectedDate, ClipboardHistoryPendingDateAfter
    global ClipboardHistoryPendingDateBefore, ClipboardHistoryPendingPage, ClipboardHistoryPendingPageSize
    global ClipboardHistoryQuerySerial
    if !ClipboardHistoryVisible || sessionId != ClipboardHistorySessionId
        return
    ClipboardHistoryPendingSearch := String(searchText)
    ClipboardHistoryPendingType := String(primaryType)
    ClipboardHistoryPendingFavorite := !!favoriteOnly
    ClipboardHistoryPendingDateFilter := String(dateFilter)
    ClipboardHistoryPendingSelectedDate := String(selectedDate)
    ClipboardHistoryPendingDateAfter := String(dateAfter)
    ClipboardHistoryPendingDateBefore := String(dateBefore)
    ClipboardHistoryPendingPage := Max(1, Integer(page))
    ClipboardHistoryPendingPageSize := Max(1, Min(100, Integer(pageSize)))
    ClipboardHistoryQuerySerial += 1
    actualQueryId := queryId ? queryId : ClipboardHistoryQuerySerial
    rows := ClipboardHistoryRows(ClipboardHistoryPendingSearch, ClipboardHistoryPendingType,
        ClipboardHistoryPendingFavorite, ClipboardHistoryPendingDateAfter,
        ClipboardHistoryPendingDateBefore,
        ClipboardHistoryPendingPage, ClipboardHistoryPendingPageSize)
    counts := ClipboardHistoryCounts(ClipboardHistoryPendingSearch, ClipboardHistoryPendingType,
        ClipboardHistoryPendingFavorite, ClipboardHistoryPendingDateAfter,
        ClipboardHistoryPendingDateBefore)
    pageCount := Max(1, Ceil(Integer(counts["matching"]) / ClipboardHistoryPendingPageSize))
    if ClipboardHistoryPendingPage > pageCount {
        ClipboardHistoryPendingPage := pageCount
        rows := ClipboardHistoryRows(ClipboardHistoryPendingSearch, ClipboardHistoryPendingType,
            ClipboardHistoryPendingFavorite, ClipboardHistoryPendingDateAfter,
            ClipboardHistoryPendingDateBefore,
            ClipboardHistoryPendingPage, ClipboardHistoryPendingPageSize)
    }
    ClipboardHistoryPost(Map("type", "historyResults", "sessionId", sessionId,
        "queryId", actualQueryId, "rows", rows, "counts", counts,
        "page", ClipboardHistoryPendingPage, "pageSize", ClipboardHistoryPendingPageSize,
        "pageCount", pageCount, "append", JSON.false))
}

ClipboardHistoryPanelImagePreview(id, sessionId, *) {
    global ClipboardHistorySessionId
    if sessionId != ClipboardHistorySessionId
        return
    preview := ClipboardHistoryImagePreview(id)
    ClipboardHistoryPost(Map("type", "imagePreview", "sessionId", sessionId,
        "id", id, "data", preview))
}

ClipboardHistoryWebMessageReceived(sender, args) {
    global ClipboardHistorySessionId, ClipboardHistoryPageReady, ClipboardHistoryHost
    global ClipboardHistoryPendingSearch, ClipboardHistoryPendingType, ClipboardHistoryPendingFavorite
    global ClipboardHistoryPendingDateFilter, ClipboardHistoryPendingSelectedDate
    global ClipboardHistoryPendingDateAfter, ClipboardHistoryPendingDateBefore
    global ClipboardHistoryPendingPageSize
    global ClipboardHistoryClearTokens
    try message := args.TryGetWebMessageAsString()
    catch
        return
    msg := LLMMessageParse(message)
    if WindowBarHandleDebugMessage(msg, "clipboard")
        return
    messageType := LLMMsgField(msg, "type")
    if WindowBarHandleMessage(ClipboardHistoryHost, messageType, ClipboardHistoryHide, 0,
        Map("autoHide", false, "requireActive", false))
        return
    if messageType = "cursorMove" {
        ShowSystemCursor()
        return
    }
    sessionId := LLMMsgField(msg, "sessionId")
    if messageType = "ready" {
        ClipboardHistoryPageReady := true
        ClipboardHistoryPost(Map("type", "hostState", "sessionId", ClipboardHistorySessionId,
            "search", ClipboardHistoryPendingSearch, "primaryType", ClipboardHistoryPendingType,
            "favoriteOnly", ClipboardHistoryPendingFavorite,
            "dateFilter", ClipboardHistoryPendingDateFilter,
            "selectedDate", ClipboardHistoryPendingSelectedDate,
            "dateAfter", ClipboardHistoryPendingDateAfter,
            "dateBefore", ClipboardHistoryPendingDateBefore,
            "pageSize", ClipboardHistoryPendingPageSize))
        return
    }
    if sessionId != ClipboardHistorySessionId
        return
    if messageType = "query" {
        queryId := LLMMsgField(msg, "queryId")
        SetTimer(ClipboardHistoryPanelQuery.Bind(
            LLMMsgField(msg, "search"), LLMMsgField(msg, "primaryType"),
            LLMMsgBoolean(msg, "favoriteOnly", &favoriteValid, false),
            LLMMsgField(msg, "dateFilter"), LLMMsgField(msg, "selectedDate"),
            LLMMsgField(msg, "dateAfter"), LLMMsgField(msg, "dateBefore"),
            LLMMsgNumber(msg, "page", &pageValid, 1, true),
            LLMMsgNumber(msg, "pageSize", &pageSizeValid, 20, true), sessionId,
            LLMMsgNumber(msg, "queryId", &queryValid, 0, true)), -1)
    } else if messageType = "imagePreview" {
        SetTimer(ClipboardHistoryPanelImagePreview.Bind(LLMMsgField(msg, "id"), sessionId), -1)
    } else if messageType = "fileDrag" || messageType = "imageDrag" {
        dragKind := messageType = "fileDrag" ? "files" : "image"
        SetTimer(ClipboardHistoryPanelNativeDrag.Bind(
            LLMMsgField(msg, "id"), sessionId, dragKind), -1)
    } else if messageType = "copy" {
        SetTimer(ClipboardHistoryPanelCopy.Bind(LLMMsgField(msg, "id"), sessionId), -1)
    } else if messageType = "paste" {
        SetTimer(ClipboardHistoryPanelPaste.Bind(LLMMsgField(msg, "id"), sessionId), -1)
    } else if messageType = "favorite" {
        desired := LLMMsgBoolean(msg, "desired", &desiredValid, false)
        SetTimer(ClipboardHistoryPanelFavorite.Bind(LLMMsgField(msg, "id"), desired,
            sessionId), -1)
    } else if messageType = "note" {
        SetTimer(ClipboardHistoryPanelNote.Bind(LLMMsgField(msg, "id"),
            LLMMsgField(msg, "note"), sessionId), -1)
    } else if messageType = "bulkNote" || messageType = "bulkDelete" {
        ids := []
        if msg.Has("ids")
            if Type(msg["ids"]) = "Array"
                ids := msg["ids"]
        if messageType = "bulkNote"
            SetTimer(ClipboardHistoryPanelBulkNote.Bind(ids,
                LLMMsgField(msg, "note"), sessionId), -1)
        else
            SetTimer(ClipboardHistoryPanelBulkDelete.Bind(ids, sessionId), -1)
    } else if messageType = "pin" {
        desired := LLMMsgBoolean(msg, "desired", &desiredValid, false)
        SetTimer(ClipboardHistoryPanelPin.Bind(LLMMsgField(msg, "id"), desired,
            sessionId), -1)
    } else if messageType = "delete" {
        SetTimer(ClipboardHistoryPanelDelete.Bind(LLMMsgField(msg, "id"), sessionId), -1)
    } else if messageType = "prepareClear" {
        ClipboardHistoryPrepareClear(sessionId)
    } else if messageType = "cancelClear" {
        token := LLMMsgField(msg, "token")
        if ClipboardHistoryClearTokens.Has(token)
            ClipboardHistoryClearTokens.Delete(token)
    } else if messageType = "clear" {
        SetTimer(ClipboardHistoryPanelClear.Bind(LLMMsgField(msg, "token"), sessionId), -1)
    }
}

ClipboardHistoryPanelCopy(id, sessionId, *) {
    global ClipboardHistorySessionId
    if sessionId != ClipboardHistorySessionId
        return
    ok := ClipboardHistoryCopyItem(id)
    ClipboardHistoryActionResult("copy", ok, ok ? "已复制" : "复制失败", "", false, sessionId)
}

ClipboardHistoryPanelNativeDrag(id, sessionId, dragKind, *) {
    global ClipboardHistorySessionId, ClipboardHistoryHost
    if sessionId != ClipboardHistorySessionId
        return
    item := ClipboardHistoryStoreGetItem(id)
    expectedType := dragKind = "files" ? "file" : "image"
    action := dragKind = "files" ? "fileDrag" : "imageDrag"
    if !IsObject(item) || item["primary_type"] != expectedType {
        ClipboardHistoryActionResult(action, false, "该记录不支持此类拖放", id, false, sessionId)
        return
    }
    if !ClipboardHistoryCopyPrepared(item, dragKind) {
        ClipboardHistoryActionResult(action, false, "无法准备拖放数据", id, false, sessionId)
        return
    }

    ; Give Windows Shell an IDataObject containing only the requested native format.
    dataObject := 0
    try {
        result := DllCall("ole32\OleGetClipboard", "ptr*", &dataObject, "int")
        if result < 0 || !dataObject
            throw Error("无法读取文件拖放数据对象")
        panelGui := PanelHostGui(ClipboardHistoryHost)
        if !IsObject(panelGui)
            throw Error("剪贴板历史窗口不可用")
        effect := 0
        result := DllCall("shell32\SHDoDragDrop", "ptr", panelGui.Hwnd,
            "ptr", dataObject, "ptr", 0, "uint", 1, "uint*", &effect, "int")
        if result < 0
            throw Error("Windows Shell 拖放失败（HRESULT " . Format("0x{:08X}", result & 0xFFFFFFFF) . "）")
    } catch as dragError {
        ClipboardHistoryActionResult(action, false,
            "无法拖出内容：" . dragError.Message, id, false, sessionId)
    } finally {
        if dataObject
            ObjRelease(dataObject)
        ClipboardHistoryPost(Map("type", "nativeDragFinished", "sessionId", sessionId, "id", id))
    }
}

ClipboardHistoryPanelPaste(id, sessionId, *) {
    global ClipboardHistoryHost, ClipboardHistoryWidth, ClipboardHistoryHeight
    global ClipboardHistorySessionId, ClipboardHistoryTargetHwnd, ClipboardHistoryVisible
    global ClipboardHistoryTargetPid, ClipboardHistoryTargetContext
    global ClipboardHistoryPasteBusy
    if sessionId != ClipboardHistorySessionId || ClipboardHistoryPasteBusy
        return
    ClipboardHistoryPasteBusy := true
    item := ClipboardHistoryStoreGetItem(id)
    if sessionId != ClipboardHistorySessionId {
        ClipboardHistoryPasteBusy := false
        return
    }
    targetContext := ClipboardHistoryTargetContext
    targetHwnd := ClipboardHistoryTargetHwnd
    targetPid := ClipboardHistoryTargetPid
    if !IsObject(item) {
        ClipboardHistoryActionResult("paste", false, "历史内容已不可用", "", false, sessionId)
        ClipboardHistoryPasteBusy := false
        return
    }
    if !IsObject(targetContext) || !ClipboardHistoryTargetContextValid(targetContext) {
        if sessionId != ClipboardHistorySessionId
            return ClipboardHistoryPanelPasteFailure(item, sessionId)
        ok := ClipboardHistoryCopyPrepared(item)
        ClipboardHistoryActionResult("paste", ok,
            ok ? "已复制，请切换到目标窗口粘贴" : "复制失败，未发送粘贴", "", false, sessionId)
        ClipboardHistoryPasteBusy := false
        return
    }
    if !ClipboardHistoryTargetWindowValid(targetHwnd, targetPid) {
        ClipboardHistoryActionResult("paste", false, "目标窗口已失效，未发送粘贴", "", false, sessionId)
        ClipboardHistoryPasteBusy := false
        return
    }
    WinActivate("ahk_id " . targetHwnd)
    if !WinWaitActive("ahk_id " . targetHwnd, , 0.4) {
        if sessionId != ClipboardHistorySessionId
            return ClipboardHistoryPanelPasteFailure(item, sessionId)
        ok := ClipboardHistoryCopyPrepared(item)
        ClipboardHistoryActionResult("paste", ok,
            ok ? "已复制，请切换到目标窗口粘贴" : "复制失败，未发送粘贴", "", false, sessionId)
        ClipboardHistoryPasteBusy := false
        return
    }
    if sessionId != ClipboardHistorySessionId
        return ClipboardHistoryPanelPasteFailure(item, sessionId)
    if WinActive("ahk_id " . targetHwnd) != targetHwnd
        return ClipboardHistoryPanelPasteFailure(item, sessionId)
    canProceed := false
    Critical("On")
    try {
        if sessionId = ClipboardHistorySessionId
            && ClipboardHistoryTargetContextValid(targetContext) {
            clipboardSequenceBeforePaste := ClipboardSequenceNumber()
            sessionBeforeHide := ClipboardHistorySessionId
            ClipboardHistoryVisible := false
            PanelHostHide(ClipboardHistoryHost)
            canProceed := true
        }
    } finally {
        Critical("Off")
    }
    if !canProceed
        return ClipboardHistoryPanelPasteFailure(item, sessionId)
    ok := ClipboardHistoryPastePrepared(item, targetContext, false,
        clipboardSequenceBeforePaste, sessionId)
    if !ok && ClipboardHistorySessionId = sessionBeforeHide {
        ClipboardHistoryVisible := true
        PanelHostShow(ClipboardHistoryHost, ClipboardHistoryWidth, ClipboardHistoryHeight, false)
        SetTimer(ClipboardHistorySendState, -1)
    }
    if !ok
        ClipboardHistoryActionResult("paste", false, "粘贴失败，面板已恢复", "", false, sessionId)
    ClipboardHistoryPasteBusy := false
}

ClipboardHistoryPanelPasteFailure(item, expectedSessionId) {
    global ClipboardHistoryVisible, ClipboardHistorySessionId, ClipboardHistoryPasteBusy
    global ClipboardHistoryHost, ClipboardHistoryWidth, ClipboardHistoryHeight
    if ClipboardHistorySessionId = expectedSessionId {
        ClipboardHistoryVisible := true
        PanelHostShow(ClipboardHistoryHost, ClipboardHistoryWidth, ClipboardHistoryHeight, false)
        SetTimer(ClipboardHistorySendState, -1)
        ok := ClipboardHistoryCopyPrepared(item)
        ClipboardHistoryActionResult("paste", ok,
            ok ? "已复制，请切换到目标窗口粘贴" : "复制失败，未发送粘贴",
            "", false, expectedSessionId)
    }
    ClipboardHistoryPasteBusy := false
    return false
}

ClipboardHistoryPanelFavorite(id, desiredState, sessionId, *) {
    global ClipboardHistorySessionId
    if sessionId != ClipboardHistorySessionId
        return
    ok := ClipboardHistorySetFavoriteItem(id, desiredState)
    ClipboardHistoryActionResult("favorite", ok, ok ? "已更新收藏" : "收藏更新失败",
        id, desiredState, sessionId)
}

ClipboardHistoryPanelNote(id, noteText, sessionId, *) {
    global ClipboardHistorySessionId
    if sessionId != ClipboardHistorySessionId
        return
    noteText := SubStr(String(noteText), 1, 4000)
    ok := ClipboardHistorySetNoteItem(id, noteText)
    ClipboardHistoryActionResult("note", ok, ok ? "备注已保存" : "备注保存失败",
        id, noteText, sessionId)
}

ClipboardHistoryPanelBulkNote(ids, noteText, sessionId, *) {
    global ClipboardHistorySessionId
    if sessionId != ClipboardHistorySessionId || Type(ids) != "Array" || !ids.Length
        return
    ok := ClipboardHistorySetNotesItems(ids, noteText)
    ClipboardHistoryActionResult("bulkNote", ok,
        ok ? "已为所选 " . ids.Length . " 项添加备注" : "批量备注保存失败",
        "", false, sessionId)
}

ClipboardHistoryPanelBulkDelete(ids, sessionId, *) {
    global ClipboardHistorySessionId
    if sessionId != ClipboardHistorySessionId || Type(ids) != "Array" || !ids.Length
        return
    ok := ClipboardHistoryDeleteItems(ids)
    ClipboardHistoryActionResult("bulkDelete", ok,
        ok ? "已删除所选 " . ids.Length . " 项" : "批量删除失败", "", ids, sessionId)
}

ClipboardHistoryPanelPin(id, desiredState, sessionId, *) {
    global ClipboardHistorySessionId
    if sessionId != ClipboardHistorySessionId
        return
    ok := ClipboardHistorySetPinnedItem(id, desiredState)
    ClipboardHistoryActionResult("pin", ok,
        ok ? (desiredState ? "已置顶" : "已取消置顶") : "置顶更新失败",
        id, desiredState, sessionId)
}

ClipboardHistoryPanelDelete(id, sessionId, *) {
    global ClipboardHistorySessionId
    if sessionId != ClipboardHistorySessionId
        return
    ok := ClipboardHistoryDeleteItem(id)
    ClipboardHistoryActionResult("delete", ok, ok ? "已删除" : "删除失败", id, false, sessionId)
}

ClipboardHistoryPrepareClear(sessionId) {
    global ClipboardHistorySessionId, ClipboardHistoryClearTokens, ClipboardHistoryEpoch
    if sessionId != ClipboardHistorySessionId
        return
    counts := ClipboardHistoryCounts()
    token := "clear-" . A_TickCount . "-" . Random(1000, 9999)
    ClipboardHistoryClearTokens[token] := Map("sessionId", sessionId, "epoch", ClipboardHistoryEpoch)
    ClipboardHistoryPost(Map("type", "clearInfo", "sessionId", sessionId, "token", token,
        "nonFavoriteCount", counts["nonFavorite"], "favoriteCount", counts["favorite"]))
}

ClipboardHistoryPanelClear(token, sessionId, *) {
    global ClipboardHistoryClearTokens, ClipboardHistorySessionId, ClipboardHistoryEpoch
    if sessionId != ClipboardHistorySessionId || !ClipboardHistoryClearTokens.Has(token)
        return
    tokenState := ClipboardHistoryClearTokens[token]
    if !IsObject(tokenState) || tokenState["epoch"] != ClipboardHistoryEpoch
        return
    ClipboardHistoryClearTokens.Delete(token)
    ok := ClipboardHistoryClearNonFavorites()
    ClipboardHistoryActionResult("clear", ok, ok ? "已清空未收藏历史" : "清空失败",
        "", false, sessionId)
}

ClipboardHistoryActionResult(action, ok, message, itemId := "", value := false, sessionId := "") {
    payload := Map("type", "actionResult", "action", action,
        "ok", ok ? JSON.true : JSON.false, "message", message,
        "sessionId", String(sessionId))
    if action = "favorite" {
        payload["id"] := itemId
        payload["desired"] := value ? JSON.true : JSON.false
    } else if action = "note" {
        payload["id"] := itemId
        payload["note"] := value
    } else if action = "pin" {
        payload["id"] := itemId
        payload["desired"] := value ? JSON.true : JSON.false
    } else if action = "fileDrag" || action = "imageDrag" {
        payload["id"] := itemId
    } else if action = "delete" {
        payload["id"] := itemId
    } else if action = "bulkDelete" {
        payload["ids"] := value
    }
    ClipboardHistoryPost(payload)
}

ClipboardHistoryPost(payload) {
    global ClipboardHistoryHost, ClipboardHistoryVisible, ClipboardHistoryPageReady
    if !ClipboardHistoryVisible || !ClipboardHistoryPageReady
        return false
    return PanelHostExecute(ClipboardHistoryHost,
        "window.handleHostMessage(" . JSON.stringify(payload, 0) . ");")
}

ClipboardHistoryCurrentExternalTarget() {
    context := ClipboardHistoryCaptureTargetContext()
    return IsObject(context) ? context["hwnd"] : 0
}

ClipboardHistoryShutdownPanel(*) {
    global ClipboardHistoryHost, ClipboardHistoryVisible, ClipboardHistoryPageReady
    ClipboardHistoryVisible := false
    ClipboardHistoryPageReady := false
    PanelHostDestroy(ClipboardHistoryHost)
    ClipboardHistoryHost := 0
}
