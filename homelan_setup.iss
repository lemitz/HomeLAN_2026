; Инсталлятор Windows-клиента HomeLAN (Inno Setup 6).
; Перед сборкой: cd client && flutter build windows --release
#define MyAppName "HomeLAN"
; Версию передаёт CI: iscc /DMyAppVersion=1.2.3
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#define MyAppPublisher "LTZ xWorks"
#define MyAppExeName "homelan_client.exe"
#define BuildDir SourcePath + "client\build\windows\x64\runner\Release"

[Setup]
AppId={{6F2B9C4E-3D1A-4E8B-9F27-5C0A1D7E8B43}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir={#SourcePath}installer
OutputBaseFilename=HomeLAN_Setup_{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
AppMutex=HomeLANClientMutex
CloseApplications=yes

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Flutter-приложению нужен Visual C++ Runtime. Положите vc_redist.x64.exe рядом с этим файлом
; (https://aka.ms/vs/17/release/vc_redist.x64.exe) — он установится, если его нет в системе.
Source: "{#SourcePath}vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall skipifsourcedoesntexist

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Удалить {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Установка Visual C++ Runtime..."; Check: NeedsVCRedist; Flags: skipifdoesntexist waituntilterminated
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
function NeedsVCRedist: Boolean;
begin
  Result := not FileExists(ExpandConstant('{sys}\vcruntime140_1.dll'));
end;
