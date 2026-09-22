; Key functions used by the AHK v2 key maps.

keyFunc_doNothing(*) {
}

keyFunc_send(value := "") {
    SendInput(value)
}

keyFunc_run(value := "") {
    if value != ""
        Run(value)
}

keyFunc_toggleCapsLock(*) {
    SetCapsLockState(GetKeyState("CapsLock", "T") ? "Off" : "On")
}

keyFunc_mouseSpeedIncrease(*) {
    global MouseSpeed
    MouseSpeed := Min(20, MouseSpeed + 1)
    SetSettings("Global", "mouseSpeed", MouseSpeed)
    ShowMsg("Mouse speed: " . MouseSpeed, 1000)
}

keyFunc_mouseSpeedDecrease(*) {
    global MouseSpeed
    MouseSpeed := Max(1, MouseSpeed - 1)
    SetSettings("Global", "mouseSpeed", MouseSpeed)
    ShowMsg("Mouse speed: " . MouseSpeed, 1000)
}

SendRepeatedKey(keyName, count := 1, prefix := "") {
    count := Max(1, count + 0)
    sequence := "{" . keyName . (count > 1 ? " " . count : "") . "}"
    SendInput(prefix . sequence)
}

keyFunc_moveLeft(count := 1) {
    SendRepeatedKey("Left", count)
}

keyFunc_moveRight(count := 1) {
    SendRepeatedKey("Right", count)
}

keyFunc_moveUp(count := 1) {
    SendRepeatedKey("Up", count)
}

keyFunc_moveDown(count := 1) {
    SendRepeatedKey("Down", count)
}

keyFunc_moveWordLeft(count := 1) {
    SendRepeatedKey("Left", count, "^")
}

keyFunc_moveWordRight(count := 1) {
    SendRepeatedKey("Right", count, "^")
}

keyFunc_backspace(*) {
    SendInput("{Backspace}")
}

keyFunc_delete(*) {
    SendInput("{Delete}")
}

keyFunc_deleteAll(*) {
    SendInput("^a{Delete}")
}

keyFunc_deleteWord(*) {
    SendInput("+^{Left}{Delete}")
}

keyFunc_forwardDeleteWord(*) {
    SendInput("+^{Right}{Delete}")
}

keyFunc_end(*) {
    SendInput("{End}")
}

keyFunc_home(*) {
    SendInput("{Home}")
}

keyFunc_moveToPageBeginning(*) {
    SendInput("^{Home}")
}

keyFunc_moveToPageEnd(*) {
    SendInput("^{End}")
}

keyFunc_deleteLine(*) {
    SendInput("{End}+{Home}{Backspace}")
}

keyFunc_deleteToLineBeginning(*) {
    SendInput("+{Home}{Backspace}")
}

keyFunc_deleteToLineEnd(*) {
    SendInput("+{End}{Backspace}")
}

keyFunc_deleteToPageBeginning(*) {
    SendInput("+^{Home}{Backspace}")
}

keyFunc_deleteToPageEnd(*) {
    SendInput("+^{End}{Backspace}")
}

keyFunc_enterWherever(*) {
    SendInput("{End}{Enter}")
}

keyFunc_esc(*) {
    SendInput("{Esc}")
}

keyFunc_enter(*) {
    SendInput("{Enter}")
}

keyFunc_doubleChar(firstCharacter, secondCharacter := "") {
    if secondCharacter = ""
        secondCharacter := firstCharacter
    selectedText := GetSelectedText()
    if selectedText != "" {
        SetClipboardText(firstCharacter . selectedText . secondCharacter)
        return
    }
    SendText(firstCharacter . secondCharacter)
    SendRepeatedKey("Left", StrLen(secondCharacter))
}

keyFunc_sendChar(character := "") {
    SendText(character)
}

keyFunc_doubleAngle(*) {
    if !QbarUpperFolderPath()
        keyFunc_doubleChar("<", ">")
}

keyFunc_doubleQuote(*) {
    keyFunc_doubleChar(Chr(34), Chr(34))
}

keyFunc_pageUp(*) {
    SendInput("{PgUp}")
}

keyFunc_pageDown(*) {
    SendInput("{PgDn}")
}

keyFunc_pageMoveUp(*) {
    SendInput("^{PgUp}")
}

keyFunc_pageMoveDown(*) {
    SendInput("^{PgDn}")
}

keyFunc_switchClipboard(*) {
    enabled := ClipboardEnabled()
    SetSettings("Global", "allowClipboard", enabled ? "0" : "1")
    ShowMsg(enabled ? "Clipboard OFF" : "Clipboard ON", 1500)
}

keyFunc_pasteSystem(*) {
    PasteSystemClipboard()
}

keyFunc_cut_1(*) {
    CopyToClipboardSlot(1, true)
}

keyFunc_copy_1(*) {
    DebugLog("keyFunc_copy_1")
    CopyToClipboardSlot(1, false)
}

keyFunc_paste_1(*) {
    PasteClipboardSlot(1)
}

keyFunc_undoRedo(*) {
    global CtrlZPending
    if CtrlZPending {
        SendInput("^z")
        CtrlZPending := false
    } else {
        SendInput("^y")
        CtrlZPending := true
    }
}

keyFunc_cut_2(*) {
    CopyToClipboardSlot(2, true)
}

keyFunc_copy_2(*) {
    DebugLog("keyFunc_copy_2")
    CopyToClipboardSlot(2, false)
}

keyFunc_paste_2(*) {
    PasteClipboardSlot(2)
}

keyFunc_qbar(*) {
    global AiChatGui, LLMTranslateGui, DictionaryGui
    ; The chat and translate panels are typing surfaces: CapsLock+Q there is
    ; an uppercase letter, not a qbar summons landing on top of the panel.
    if IsObject(AiChatGui) && WinActive("ahk_id " . AiChatGui.Hwnd)
        return
    if IsObject(LLMTranslateGui) && WinActive("ahk_id " . LLMTranslateGui.Hwnd)
        return
    if IsObject(DictionaryGui) && WinActive("ahk_id " . DictionaryGui.Hwnd)
        return
    QbarToggle()
}

keyFunc_translate(*) {
    DebugLog("keyFunc_translate")
    global A_Clipboard, ClipboardWatcherSuspended
    ; "multiline": a real multi-paragraph selection ends with a newline, which
    ; strict mode would discard and turn into the one-word fallback below; an
    ; editor's no-selection line-copy has no interior newline, so the fallback
    ; still fires for it.
    selectedText := GetSelectedText("multiline")
    if selectedText = "" {
        oldClipboard := ClipboardAll()
        ClipboardWatcherSuspended := true
        try {
            A_Clipboard := ""
            SendInput("^{Left}+^{Right}^{Insert}")
            if ClipWait(0.15)
                selectedText := A_Clipboard
        } finally {
            A_Clipboard := oldClipboard
            ClipboardWatcherSuspended := false
        }
    }
    if selectedText != "" {
        ; A single English word the local dictionary knows opens the
        ; dictionary card; everything else goes to the translate panel.
        if DictionaryTryShow(selectedText)
            return
        LLMTranslateShow(selectedText)
    } else
        ShowMsg("Select text or place the cursor inside a word first.", 2000)
}

keyFunc_tabPrve(*) {
    SendInput("^+{Tab}")
}

keyFunc_tabNext(*) {
    SendInput("^{Tab}")
}

keyFunc_jumpPageTop(*) {
    SendInput("^{Home}")
}

keyFunc_jumpPageBottom(*) {
    SendInput("^{End}")
}

keyFunc_selectUp(count := 1) {
    SendRepeatedKey("Up", count, "+")
}

keyFunc_selectDown(count := 1) {
    SendRepeatedKey("Down", count, "+")
}

keyFunc_selectLeft(count := 1) {
    SendRepeatedKey("Left", count, "+")
}

keyFunc_selectRight(count := 1) {
    SendRepeatedKey("Right", count, "+")
}

keyFunc_selectHome(*) {
    SendInput("+{Home}")
}

keyFunc_selectEnd(*) {
    SendInput("+{End}")
}

keyFunc_selectToPageBeginning(*) {
    SendInput("+^{Home}")
}

keyFunc_selectToPageEnd(*) {
    SendInput("+^{End}")
}

keyFunc_selectCurrentWord(*) {
    SendInput("^{Left}+^{Right}")
}

keyFunc_selectCurrentLine(*) {
    SendInput("{Home}+{End}")
}

keyFunc_selectWordLeft(count := 1) {
    SendRepeatedKey("Left", count, "+^")
}

keyFunc_selectWordRight(count := 1) {
    SendRepeatedKey("Right", count, "+^")
}

keyFunc_pageMoveLineUp(count := 1) {
    SendRepeatedKey("Up", count, "^")
}

keyFunc_pageMoveLineDown(count := 1) {
    SendRepeatedKey("Down", count, "^")
}

keyFunc_getJSEvalString(*) {
    selectedText := GetSelectedText()
    inputResult := InputBox("Edit the selected expression or text:", "capslock_p2 Tab", "w600 h180", selectedText)
    if inputResult.Result = "OK"
        SetClipboardText(inputResult.Value)
}

keyFunc_tabScript(*) {
    tabAction()
}

keyFunc_openCpasDocs(*) {
    ; F1 opens the in-app usage page (pages\usage.html) in the default browser.
    ; Installed copies always carry it; fall back to the original Capslock+
    ; docs if the page was stripped from a bare payload.
    usagePath := A_ScriptDir . "\pages\usage.html"
    if FileExist(usagePath)
        Run(usagePath)
    else
        Run(IsChineseLanguage() ? "https://capslox.com/capslock-plus" : "https://capslox.com/capslock-plus/en.html")
}

keyFunc_mediaPrev(*) {
    SendInput("{Media_Prev}")
}

keyFunc_mediaNext(*) {
    SendInput("{Media_Next}")
}

keyFunc_mediaPlayPause(*) {
    SendInput("{Media_Play_Pause}")
}

keyFunc_volumeUp(*) {
    SendInput("{Volume_Up}")
}

keyFunc_volumeDown(*) {
    SendInput("{Volume_Down}")
}

keyFunc_volumeMute(*) {
    SendInput("{Volume_Mute}")
}

keyFunc_reload(*) {
    Reload()
}

keyFunc_send_dot(*) {
    if !QbarLowerFolderPath()
        SendText(".")
}

; Qbar folder navigation. Both return true when they handled the key, so the
; caller falls back to its normal behavior otherwise.
keyFunc_qbar_upperFolderPath(*) {
    return QbarUpperFolderPath()
}

keyFunc_qbar_lowerFolderPath(*) {
    return QbarLowerFolderPath()
}

keyFunc_winbind_activate(bindingNumber) {
    activateWinAction(bindingNumber + 0)
}

keyFunc_winbind_binding(bindingNumber) {
    BindingTap(bindingNumber + 0)
}

keyFunc_winPin(*) {
    hwnd := WinExist("A")
    if !hwnd
        return
    exStyle := WinGetExStyle(hwnd)
    WinSetAlwaysOnTop(!(exStyle & 0x8), "ahk_id " . hwnd)
}

keyFunc_goCjkPage(*) {
    Run("http://cjkis.me")
}

keyFunc_click_left(*) {
    Click("Left")
}

keyFunc_click_right(*) {
    Click("Right")
}

keyFunc_mouse_up(*) {
    MouseMove(0, -dynamic_speed(), 0, "R")
}

keyFunc_mouse_down(*) {
    MouseMove(0, dynamic_speed(), 0, "R")
}

keyFunc_mouse_left(*) {
    MouseMove(-dynamic_speed(), 0, 0, "R")
}

keyFunc_mouse_right(*) {
    MouseMove(dynamic_speed(), 0, 0, "R")
}

keyFunc_wheel_up(*) {
    SendInput("{WheelUp 3}")
}

keyFunc_wheel_down(*) {
    SendInput("{WheelDown 3}")
}

dynamic_speed(initial := 10, acceleration := 0.2, maximum := 80) {
    static count := 0
    if A_ThisHotkey = A_PriorHotkey && A_TimeSincePriorHotkey < 300
        count += acceleration
    else
        count := 0
    return Min(Floor(initial + Exp(count)), maximum)
}

keyFunc_clearWinMinimizeStach(*) {
    ClearWinMinimizeStack()
}

keyFunc_popWinMinimizeStack(*) {
    PopWinMinimizeStack()
}

keyFunc_pushWinMinimizeStack(*) {
    PushWinMinimizeStack()
}

keyFunc_unshiftWinMinimizeStack(*) {
    UnshiftWinMinimizeStack()
}

keyFunc_winTransparent(*) {
    WinTransparentStart()
}
