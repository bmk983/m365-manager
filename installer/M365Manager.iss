; M365 Manager – Installer (Inno Setup)
; Bauen: .\publish.ps1 -Version 1.2.3 -Setup

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppName "M365 Manager"
#define AppExe "M365Manager.exe"

[Setup]
AppId={{6F3B2C1A-8E4D-4B7A-9C51-2D7E9A0B4F63}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=bmk983
AppPublisherURL=https://github.com/bmk983/m365-manager
AppSupportURL=https://github.com/bmk983/m365-manager/issues
AppUpdatesURL=https://github.com/bmk983/m365-manager/releases
VersionInfoVersion={#AppVersion}
; Standard: nur für den aktuellen Benutzer, keine Adminrechte (%LOCALAPPDATA%\Programs\M365 Manager)
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DefaultDirName={autopf}\M365 Manager
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=M365Manager-Setup-{#AppVersion}
SetupIconFile=..\src\M365Manager\Assets\app.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
MinVersion=10.0.17763

[Languages]
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
de.DeleteData=Sollen auch deine Profile, gespeicherten Browser-Anmeldungen und die heruntergeladenen PowerShell-Module gelöscht werden?
en.DeleteData=Do you also want to delete your profiles, saved browser sign-ins and the downloaded PowerShell modules?

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\dist\M365Manager.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Code]
// Beim Deinstallieren fragen, ob auch die Daten (Profile, Anmeldungen, Module) weg sollen.
// Bei einer Installation pro Benutzer liegen sie neben der EXE, sonst unter %LOCALAPPDATA%\M365Manager.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  AppData, LocalData: String;
begin
  if CurUninstallStep <> usPostUninstall then Exit;
  AppData := ExpandConstant('{app}\M365Manager-Data');
  LocalData := ExpandConstant('{localappdata}\M365Manager');
  if not (DirExists(AppData) or DirExists(LocalData)) then Exit;
  if UninstallSilent then Exit;
  if MsgBox(CustomMessage('DeleteData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
  begin
    if DirExists(AppData) then DelTree(AppData, True, True, True);
    if DirExists(LocalData) then DelTree(LocalData, True, True, True);
    RemoveDir(ExpandConstant('{app}'));
  end;
end;