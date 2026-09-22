; capslock_p2 Inno Setup release package.
; Build the AHK payload first:
;   Ahk2Exe.exe /in capslock_p2.ahk /out build\payload\capslock_p2.exe /base AutoHotkey64.exe
; Then compile this file with ISCC.exe. The installer intentionally uses the
; distribution-safe tools\capslock_p2-default.ini instead of the developer's
; root capslock_p2.ini, which may contain personal API credentials.

#define MyAppName "capslock_p2"
#define MyAppVersion "0.1.0"
#define ProjectRoot "D:\develop\project\cpaslock_p2"
#define PayloadDir ProjectRoot + "\build\payload"
#define OutputDir ProjectRoot + "\dist"
#ifndef OutputBaseFilename
#define OutputBaseFilename "capslock_p2-setup"
#endif

[Setup]
AppId=capslock_p2
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=capslock_p2
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

[Files]
; Compiled AHK v2 runtime.
Source: "{#PayloadDir}\capslock_p2.exe"; DestDir: "{app}"; Flags: ignoreversion

; WebView2 panel pages and shared settings component.
Source: "{#ProjectRoot}\pages\*"; DestDir: "{app}\pages"; Flags: ignoreversion recursesubdirs createallsubdirs

; Markdown renderer used by the AI chat page.
Source: "{#ProjectRoot}\vendor\*"; DestDir: "{app}\vendor"; Flags: ignoreversion recursesubdirs createallsubdirs

; Optional JavaScript extensions loaded by the calculator.
Source: "{#ProjectRoot}\loadScript\*"; DestDir: "{app}\loadScript"; Flags: ignoreversion recursesubdirs createallsubdirs

; Dictionary, SQLite binding, Everything and tray icon.
Source: "{#ProjectRoot}\resources\dictionary.db"; DestDir: "{app}\resources"; Flags: ignoreversion
Source: "{#ProjectRoot}\resources\SQLite3.dll"; DestDir: "{app}\resources"; Flags: ignoreversion
Source: "{#ProjectRoot}\resources\es.exe"; DestDir: "{app}\resources"; Flags: ignoreversion
; The PNG is the runtime tray icon; the ICO is its installer/shortcut form.
Source: "{#ProjectRoot}\resources\capslock_p2-icon.ico"; DestDir: "{app}\resources"; Flags: ignoreversion
Source: "{#ProjectRoot}\resources\Everything-1.4.1.1032.x64\*"; DestDir: "{app}\resources\Everything-1.4.1.1032.x64"; Flags: ignoreversion recursesubdirs createallsubdirs

; The application is compiled as 64-bit and selects this loader at runtime.
Source: "{#ProjectRoot}\WebView2\64bit\WebView2Loader.dll"; DestDir: "{app}\WebView2\64bit"; Flags: ignoreversion

; Keep the example and README available after installation.
Source: "{#ProjectRoot}\capslock_p2-settingsDemo.ini"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ProjectRoot}\README.md"; DestDir: "{app}"; Flags: ignoreversion

; Never overwrite the user's API settings during an upgrade.
Source: "{#ProjectRoot}\tools\capslock_p2-default.ini"; DestDir: "{app}"; DestName: "capslock_p2.ini"; Flags: onlyifdoesntexist ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\capslock_p2.exe"; WorkingDir: "{app}"; IconFilename: "{app}\resources\capslock_p2-icon.ico"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\capslock_p2.exe"; WorkingDir: "{app}"; IconFilename: "{app}\resources\capslock_p2-icon.ico"

[Run]
Filename: "{app}\capslock_p2.exe"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
