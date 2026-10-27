; Community installer for this fork. Keep AppId and the data-directory identity
; stable across releases. Only installed application files are uninstalled;
; wallet data in AppData is deliberately outside this script's file entries.
#ifndef MyAppVersion
  #define MyAppVersion "6.5.0"
#endif
#ifndef MyBuildNumber
  #define MyBuildNumber "1"
#endif
#ifndef BundlePath
  #define BundlePath "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputPath
  #define OutputPath "..\..\dist"
#endif
#define MyAppName "Cake Wallet Windows"
#define MyAppURL "https://github.com/vitorhubdev/cake_wallet_win"
#define MyAppExeName "CakeWallet.exe"

[Setup]
AppId=vitorhubdev.cake_wallet_win
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion} (build {#MyBuildNumber})
VersionInfoVersion={#MyAppVersion}.{#MyBuildNumber}
AppPublisher=vitorhubdev
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
AppCopyright=Copyright (c) 2018-2025 Cake Labs LLC
DefaultDirName={localappdata}\Programs\Cake Wallet Windows
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir={#OutputPath}
OutputBaseFilename=CakeWallet-Windows-x64-{#MyAppVersion}-{#MyBuildNumber}-Setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
Compression=lzma2/normal
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The validated bundle already contains the Visual C++ runtime. Installation
; does not download dependencies or launch a separate privileged redistributable.
Source: "{#BundlePath}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
