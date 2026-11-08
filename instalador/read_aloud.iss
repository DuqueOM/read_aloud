; Instalador de Read Aloud (Inno Setup 6).
;
; Lo construye el CI al publicar un release (.github/workflows/release.yml), o
; a mano:
;
;     ISCC.exe /DVersion=1.2.0 instalador\read_aloud.iss
;
; Queda en dist\ReadAloud-Setup-<version>.exe. Se instala solo para el usuario,
; en %LOCALAPPDATA%\Programs\Read Aloud, sin pedir permisos de administrador.
; Los binarios de Piper y las voces no van dentro: los baja setup.ps1 durante la
; instalacion, igual que al instalar desde el repositorio.
;
; Guardado en UTF-8 con BOM, que Inno Setup entiende (los acentos de los textos).

#ifndef Version
  #define Version "0.0.0-dev"
#endif

[Setup]
AppId={{2F89964E-7048-4278-8544-F7E83EDEB78F}
AppName=Read Aloud
AppVersion={#Version}
AppVerName=Read Aloud {#Version}
AppPublisher=DuqueOM
AppPublisherURL=https://github.com/DuqueOM/read_aloud
AppSupportURL=https://github.com/DuqueOM/read_aloud/issues
AppUpdatesURL=https://github.com/DuqueOM/read_aloud/releases
DefaultDirName={localappdata}\Programs\Read Aloud
DefaultGroupName=Read Aloud
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\LICENSE
OutputDir=..\dist
OutputBaseFilename=ReadAloud-Setup-{#Version}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Read Aloud
CloseApplications=no

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
es.TaskAutostart=Iniciar Read Aloud al encender el equipo (recomendado)
en.TaskAutostart=Start Read Aloud when I sign in (recommended)
es.TaskDesktop=Crear un acceso directo en el escritorio que abre los ajustes
en.TaskDesktop=Create a desktop shortcut that opens the settings
es.IconSettings=Ajustes de Read Aloud
en.IconSettings=Read Aloud settings
es.IconClose=Cerrar Read Aloud
en.IconClose=Close Read Aloud
es.IconVoices=Instalar o reparar las voces
es.IconUninstall=Desinstalar Read Aloud
en.IconUninstall=Uninstall Read Aloud
es.KeepData=Se quitó Read Aloud.%n%n¿Quieres conservar tus ajustes y tu diccionario de pronunciación por si lo instalas de nuevo?
en.KeepData=Read Aloud was removed.%n%nDo you want to keep your settings and pronunciation dictionary in case you install it again?
en.IconVoices=Install or repair the voices
es.StatusVoices=Descargando el motor de voz y las voces (unos 200 MB). Puede tardar unos minutos...
en.StatusVoices=Downloading the voice engine and voices (about 200 MB). This can take a few minutes...
es.VoicesFailed=No se pudieron descargar el motor de voz y las voces (suele ser la conexión a internet, un firewall o un antivirus).%n%nRead Aloud queda instalado: abre «Instalar o reparar las voces» en el menú Inicio para reintentar, o te lo ofrecerá la primera vez que lo abras. El detalle queda en read_aloud_piper\runtime\setup.log.
en.VoicesFailed=The voice engine and voices could not be downloaded (usually the internet connection, a firewall or an antivirus).%n%nRead Aloud is installed: open "Install or repair the voices" in the Start menu to retry, or it will offer to do it the first time you open it. The details are in read_aloud_piper\runtime\setup.log.
es.RunNow=Iniciar Read Aloud ahora
en.RunNow=Start Read Aloud now

[Tasks]
Name: "autostart"; Description: "{cm:TaskAutostart}"
Name: "desktopicon"; Description: "{cm:TaskDesktop}"

[Files]
Source: "..\read_aloud.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\read_aloud_daemon.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\stop_read_aloud.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\setup.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\install_startup.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\iniciar_read_aloud.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\cerrar_read_aloud.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\abrir_ajustes_read_aloud.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\crear_icono.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\VERSION"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\NOTICE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.es.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\CHANGELOG.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\lib\*"; DestDir: "{app}\lib"; Excludes: "__pycache__"; Flags: ignoreversion recursesubdirs
Source: "..\config\*"; DestDir: "{app}\config"; Excludes: "*.local.psd1,settings.psd1"; Flags: ignoreversion
; settings.psd1 se edita a mano (esta documentado): solo se instala si no existe, para no
; borrar lo que la persona haya cambiado al actualizar.
Source: "..\config\settings.psd1"; DestDir: "{app}\config"; Flags: onlyifdoesntexist
Source: "..\docs\*.md"; DestDir: "{app}\docs"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Read Aloud"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\iniciar_read_aloud.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\read_aloud_piper\read_aloud.ico"
Name: "{autoprograms}\{cm:IconSettings}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\abrir_ajustes_read_aloud.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\read_aloud_piper\read_aloud.ico"
Name: "{autodesktop}\Read Aloud"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\abrir_ajustes_read_aloud.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\read_aloud_piper\read_aloud.ico"; Tasks: desktopicon
Name: "{autoprograms}\{cm:IconClose}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\cerrar_read_aloud.vbs"""; WorkingDir: "{app}"
Name: "{autoprograms}\{cm:IconVoices}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\setup.ps1"" -NoStartupPrompt"; WorkingDir: "{app}"
Name: "{autoprograms}\{cm:IconUninstall}"; Filename: "{uninstallexe}"
Name: "{userstartup}\Read Aloud"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\iniciar_read_aloud.vbs"""; WorkingDir: "{app}"; Tasks: autostart

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\crear_icono.ps1"""; WorkingDir: "{app}"; Flags: runhidden waituntilterminated
Filename: "{sys}\wscript.exe"; Parameters: """{app}\iniciar_read_aloud.vbs"""; WorkingDir: "{app}"; Description: "{cm:RunNow}"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\cerrar_read_aloud.vbs"""; RunOnceId: "CerrarReadAloud"; Flags: runhidden waituntilterminated

[Code]
// Al actualizar, el proceso residente tiene los archivos en uso: se cierra antes.
// Y los diccionarios de fabrica se reemplazan por los nuevos: se guarda una copia
// de los actuales por si la persona los habia editado a mano (lo suyo, sus
// ajustes y su diccionario, vive en read_aloud_piper\runtime y no se toca).
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Codigo: Integer;
  Copia: String;
  Nombre: String;
  I: Integer;
begin
  if FileExists(ExpandConstant('{app}\cerrar_read_aloud.vbs')) then
  begin
    Exec(ExpandConstant('{sys}\wscript.exe'), '"' + ExpandConstant('{app}\cerrar_read_aloud.vbs') + '"', '', SW_HIDE, ewWaitUntilTerminated, Codigo);
    Sleep(2500);
  end;

  if DirExists(ExpandConstant('{app}\config')) then
  begin
    Copia := ExpandConstant('{app}\copia_de_config_anterior');
    ForceDirectories(Copia);
    for I := 0 to 1 do
    begin
      if I = 0 then Nombre := 'terms_es.tsv' else Nombre := 'terms_en.tsv';
      if FileExists(ExpandConstant('{app}\config\') + Nombre) then
        FileCopy(ExpandConstant('{app}\config\') + Nombre, Copia + '\' + Nombre, False);
    end;
  end;
  Result := '';
end;

// Despues de copiar los archivos se baja el motor de voz y las voces. Si falla,
// la instalacion no se da por buena en silencio: se avisa y se dice como seguir.
procedure CurStepChanged(CurStep: TSetupStep);
var
  Codigo: Integer;
  Ok: Boolean;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption := CustomMessage('StatusVoices');
    Ok := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\setup.ps1') + '" -NoStartupPrompt -PauseOnError',
      ExpandConstant('{app}'), SW_SHOWNORMAL, ewWaitUntilTerminated, Codigo);
    if (not Ok) or (Codigo <> 0) then
      SuppressibleMsgBox(CustomMessage('VoicesFailed'), mbError, MB_OK, IDOK);
  end;
end;

// Al desinstalar se borra lo que bajo setup.ps1 (motor y voces, unos 200 MB). Lo
// que es del usuario (ajustes y diccionario, en read_aloud_piper\runtime) se
// conserva si lo pide; en una desinstalacion silenciosa se borra todo.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Conservar: Boolean;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    Conservar := False;
    if not UninstallSilent then
      Conservar := MsgBox(CustomMessage('KeepData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON1) = IDYES;
    DelTree(ExpandConstant('{app}\read_aloud_piper\bin'), True, True, True);
    DelTree(ExpandConstant('{app}\read_aloud_piper\voices'), True, True, True);
    DelTree(ExpandConstant('{app}\read_aloud_piper\tmp'), True, True, True);
    DelTree(ExpandConstant('{app}\copia_de_config_anterior'), True, True, True);
    if not Conservar then
    begin
      DelTree(ExpandConstant('{app}\read_aloud_piper'), True, True, True);
      DelTree(ExpandConstant('{app}\config'), True, True, True);
    end;
    RemoveDir(ExpandConstant('{app}'));
  end;
end;
