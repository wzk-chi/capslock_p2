#Requires AutoHotkey v2.0
#SingleInstance Force
;@Ahk2Exe-SetFileVersion 0.3.0.0
;@Ahk2Exe-SetProductVersion 0.3.0.0
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

#Include lib\app\config.ahk
#Include lib\app\core.ahk
#Include lib\shared\selection.ahk
#Include lib\features\windows.ahk
#Include lib\input\appProfiles.ahk
#Include lib\vendor\WebView2.ahk
#Include lib\shared\panelHost.ahk
#Include lib\shared\windowBar.ahk
#Include lib\vendor\JSON.ahk
#Include lib\shared\crypto.ahk
#Include lib\vendor\CSQLite.ahk
#Include lib\features\clipboard\clipboard_store.ahk
#Include lib\features\clipboard\clipboard_formats.ahk
#Include lib\features\clipboard\clipboard_history.ahk
#Include lib\features\clipboard\clipboard_panel.ahk
#Include lib\features\translate\translate.ahk
#Include lib\features\translate\languageDetect.ahk
#Include lib\shared\llm.ahk
#Include lib\features\translate\llmTranslate.ahk
#Include lib\features\settings.ahk
#Include lib\features\settings\settings_capture.ahk
#Include lib\features\settings\settings_picker.ahk
#Include lib\features\translate\youdaoTranslate.ahk
#Include lib\features\translate\volcengineTranslate.ahk
#Include lib\features\dictionary.ahk
#Include lib\features\aiChat_store.ahk
#Include lib\features\aiChat.ahk
#Include lib\features\qbar\qbar.ahk
#Include lib\features\qbar\qbar_store.ahk
#Include lib\features\qbar\qbar_plugin_catalog.ahk
#Include lib\features\qbar\qbar_registry.ahk
#Include lib\features\qbar\qbar_plugin_host.ahk
#Include lib\features\qbar\qbar_execution.ahk
#Include lib\features\qbar\qbar_notes.ahk
#Include lib\features\qbar\qbar_notes_actions.ahk
#Include lib\features\qbar\qbar_notes_store.ahk
#Include lib\features\qbar\qbar_history.ahk
#Include lib\features\qbar\qbar_panel.ahk
#Include lib\features\qbar\qbar_search.ahk
#Include lib\features\qbar\qbar_index.ahk
#Include lib\features\qbar\qbar_commands.ahk
#Include lib\features\qbar\qbar_everything.ahk
#Include lib\features\everything\everything.ahk
#Include lib\features\everything\everything_panel.ahk
#Include lib\features\everything\everything_actions.ahk
#Include lib\features\qbar\qbar_navigation.ahk
#Include lib\input\tabHotString.ahk
#Include lib\features\qbar\icons.ahk
#Include lib\input\keys.ahk
#Include lib\input\keymap.ahk
#Include lib\input\customHotkeys.ahk
#Include *i userAHK\main.ahk

Persistent()
OnExit(Shutdown)
Initialize()
