#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn
; The VarUnset check reports helper calls that cross an #Include boundary
; (DebugLog, ShowMsg, ...) as unassigned locals, even though they resolve fine
; at runtime -- the debug log has the "QbarToggle visible=" line this flagged.
; Keep the other warnings, drop the one that only ever fires on working code.
#Warn VarUnset, Off

A_MaxHotkeysPerInterval := 500
A_HotkeyInterval := 2000

; capslock_p2 AHK v2 entry point.
; Qbar and LLM translation are both hosted in WebView2 panels.

#Include lib\core.ahk
#Include lib\windows.ahk
#Include lib\math.ahk
#Include lib\jsEval.ahk
#Include lib\WebView2.ahk
#Include lib\JSON.ahk
#Include lib\crypto.ahk
#Include lib\CSQLite.ahk
#Include lib\translate.ahk
#Include lib\llmTranslate.ahk
#Include lib\youdaoTranslate.ahk
#Include lib\volcengineTranslate.ahk
#Include lib\dictionary.ahk
#Include lib\aiChat.ahk
#Include lib\qbar.ahk
#Include lib\icons.ahk
#Include lib\keys.ahk
#Include lib\keymap.ahk
#Include userAHK\main.ahk

Persistent()
OnExit(Shutdown)
Initialize()
