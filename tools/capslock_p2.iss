; capslock_p2 Inno Setup release package.
; Build the AHK payload first:
;   Ahk2Exe.exe /in capslock_p2.ahk /out build\payload\capslock_p2.exe /base AutoHotkey64.exe
; Then compile this file with ISCC.exe. User settings/defaults live in
; data\capslock_p2.db. Legacy INI files are never packaged.

#define MyAppName "capslock_p2"
#define MyAppVersion "0.3.1"
#define ProjectRoot "D:\develop\project\cpaslock_p2"
#define PayloadDir ProjectRoot + "\build\payload"
#define OutputDir ProjectRoot + "\dist"
#ifndef OutputBaseFilename
#define OutputBaseFilename "capslock_p2-setup-0.3.1"
#endif

[Setup]
AppId=capslock_p2
AppMutex=Local\capslock_p2-running
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=capslock_p2
; Match the Windows UI language without showing a language picker.
ShowLanguageDialog=no
DefaultDirName={localappdata}\capslock_p2
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
SetupIconFile={#ProjectRoot}\resources\capslock_p2-icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
Uninstallable=yes
; Use Windows Restart Manager to detect and close apps holding files being updated.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimp"; MessagesFile: "{#ProjectRoot}\tools\Languages\ChineseSimplified.isl"

[Files]
; Compiled AHK v2 runtime.
Source: "{#PayloadDir}\capslock_p2.exe"; DestDir: "{app}"; Flags: ignoreversion

; Live WebView2 panels and the browser-opened usage page. The retired
; settings.js overlay was deleted and is not part of the release payload.
; vditor-eval.html is a local throwaway harness for trying out the Markdown
; editor and must never ship, so it is excluded from the html glob.
Source: "{#ProjectRoot}\pages\*.html"; DestDir: "{app}\pages"; Flags: ignoreversion; Excludes: "vditor-eval.html"
Source: "{#ProjectRoot}\pages\theme.css"; DestDir: "{app}\pages"; Flags: ignoreversion
Source: "{#ProjectRoot}\pages\toast.js"; DestDir: "{app}\pages"; Flags: ignoreversion
Source: "{#ProjectRoot}\pages\dialog.js"; DestDir: "{app}\pages"; Flags: ignoreversion
Source: "{#ProjectRoot}\pages\qbar-search.js"; DestDir: "{app}\pages"; Flags: ignoreversion
Source: "{#ProjectRoot}\pages\icons.js"; DestDir: "{app}\pages"; Flags: ignoreversion
Source: "{#ProjectRoot}\pages\windowbar.js"; DestDir: "{app}\pages"; Flags: ignoreversion
Source: "{#ProjectRoot}\pages\panel.js"; DestDir: "{app}\pages"; Flags: ignoreversion
Source: "{#ProjectRoot}\pages\settings-page.js"; DestDir: "{app}\pages"; Flags: ignoreversion
Source: "{#ProjectRoot}\pages\clipboard-history.js"; DestDir: "{app}\pages"; Flags: ignoreversion
Source: "{#ProjectRoot}\pages\chat.js"; DestDir: "{app}\pages"; Flags: ignoreversion
; Turns Vditor's rendered Markdown into the note card's copyable rows.
Source: "{#ProjectRoot}\pages\notes-preview.js"; DestDir: "{app}\pages"; Flags: ignoreversion

; Markdown renderer used by the AI chat page, plus the vendored Vditor build
; (lute engine, icons, i18n and content themes) that the notes page renders
; through. recursesubdirs is what carries vendor\vditor\dist\** into the package.
Source: "{#ProjectRoot}\vendor\*"; DestDir: "{app}\vendor"; Flags: ignoreversion recursesubdirs createallsubdirs

; Dictionary, SQLite binding, Everything and tray icon.
Source: "{#ProjectRoot}\resources\dictionary.db"; DestDir: "{app}\resources"; Flags: ignoreversion
Source: "{#ProjectRoot}\resources\SQLite3.dll"; DestDir: "{app}\resources"; Flags: ignoreversion
Source: "{#ProjectRoot}\resources\es.exe"; DestDir: "{app}\resources"; Flags: ignoreversion
; The PNG is the runtime tray icon; the ICO is its installer/shortcut form.
Source: "{#ProjectRoot}\resources\capslock_p2-icon.png"; DestDir: "{app}\resources"; Flags: ignoreversion
Source: "{#ProjectRoot}\resources\capslock_p2-icon.ico"; DestDir: "{app}\resources"; Flags: ignoreversion
Source: "{#ProjectRoot}\resources\Everything-1.4.1.1032.x64\*"; DestDir: "{app}\resources\Everything-1.4.1.1032.x64"; Flags: ignoreversion recursesubdirs createallsubdirs

; The application is compiled as 64-bit and selects this loader at runtime.
Source: "{#ProjectRoot}\WebView2\64bit\WebView2Loader.dll"; DestDir: "{app}\WebView2\64bit"; Flags: ignoreversion

; Keep the README and the GPL v2 license text available after installation.
Source: "{#ProjectRoot}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ProjectRoot}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion


[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\capslock_p2.exe"; WorkingDir: "{app}"; IconFilename: "{app}\resources\capslock_p2-icon.ico"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\capslock_p2.exe"; WorkingDir: "{app}"; IconFilename: "{app}\resources\capslock_p2-icon.ico"

[Run]
Filename: "{app}\capslock_p2.exe"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
