#ifndef MyAppVersion
  #define MyAppVersion "0.3.0-alpha.2"
#endif
#ifndef MyNumericVersion
  #define MyNumericVersion "0.3.0.2"
#endif
#ifndef SourceDir
  #define SourceDir "."
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
AppId={{4B03778F-AC48-46BB-88FC-A0C86E65594A}
AppName=PS5PCEM
AppVersion={#MyAppVersion}
AppVerName=PS5PCEM {#MyAppVersion}
AppPublisher=PS5PCEM Project
AppPublisherURL=https://github.com/iStark/PS5PCEM
AppSupportURL=https://github.com/iStark/PS5PCEM/issues
AppUpdatesURL=https://github.com/iStark/PS5PCEM/releases
VersionInfoVersion={#MyNumericVersion}
VersionInfoCompany=PS5PCEM Project
VersionInfoDescription=PS5PCEM Installer
VersionInfoProductName=PS5PCEM
DefaultDirName={localappdata}\Programs\PS5PCEM
DefaultGroupName=PS5PCEM
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputDir={#OutputDir}
OutputBaseFilename=PS5PCEM-{#MyAppVersion}-windows-x64-setup
SetupIconFile=..\..\assets\windows\ps5pcem.ico
UninstallDisplayIcon={app}\ps5pcem.exe
LicenseFile={#SourceDir}\LICENSE
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no
UsePreviousAppDir=yes
UsePreviousLanguage=yes
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\ps5pcem.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\game-run.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README-PORTABLE.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\VERSION"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\ps5pcem-icon.png"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\assets\branding\*"; DestDir: "{app}\assets\branding"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\PS5PCEM"; Filename: "{app}\ps5pcem.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\PS5PCEM"; Filename: "{app}\ps5pcem.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\ps5pcem.exe"; Description: "{cm:LaunchProgram,PS5PCEM}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
