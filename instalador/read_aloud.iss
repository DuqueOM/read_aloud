; Instalador de Read Aloud (Inno Setup 6).
;
; Lo construye el CI al publicar un release (.github/workflows/release.yml), o
; a mano:
;
;     ISCC.exe /DVersion=1.2.0 instalador\read_aloud.iss
;
; Queda en dist\ReadAloud-Setup-<version>.exe. Se instala solo para el usuario,
; en %LOCALAPPDATA%\Programs\Read Aloud, sin pedir permisos de administrador.
; Los binarios de Piper, las voces, la traduccion y el diccionario no van
; dentro: los baja setup.ps1 durante la instalacion, igual que al instalar desde
; el repositorio (la traduccion y el diccionario, segun las tareas que se
; marquen; ver config\traduccion.psd1 y config\idiomas.psd1).
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
es.StatusVoices=Descargando el motor de voz, las voces, y la traducción y el diccionario que elegiste. Puede tardar unos minutos...
en.StatusVoices=Downloading the voice engine, the voices, and the translation and dictionary you chose. This can take a few minutes...
es.VoicesFailed=No se pudieron descargar el motor de voz y las voces (suele ser la conexión a internet, un firewall o un antivirus).%n%nRead Aloud queda instalado: abre «Instalar o reparar las voces» en el menú Inicio para reintentar, o te lo ofrecerá la primera vez que lo abras. El detalle queda en read_aloud_piper\runtime\setup.log.
en.VoicesFailed=The voice engine and voices could not be downloaded (usually the internet connection, a firewall or an antivirus).%n%nRead Aloud is installed: open "Install or repair the voices" in the Start menu to retry, or it will offer to do it the first time you open it. The details are in read_aloud_piper\runtime\setup.log.
es.LockedLeft=Algunos archivos de Read Aloud estaban en uso y no se pudieron borrar. Reinicia el equipo y borra la carpeta de instalacion a mano.
en.LockedLeft=Some Read Aloud files were in use and could not be deleted. Restart the computer and delete the installation folder by hand.
es.RunNow=Iniciar Read Aloud ahora
en.RunNow=Start Read Aloud now
es.GroupTranslation=Traducción rápida entre inglés y español, sin conexión (Ctrl+Alt+T):
en.GroupTranslation=Quick translation between English and Spanish, offline (Ctrl+Alt+T):
es.TaskTransBasic=Básica: Bergamot de Mozilla (licencia MPL 2.0), 112 MB
en.TaskTransBasic=Basic: Bergamot by Mozilla (MPL 2.0 license), 112 MB
es.TaskTransHigh=Mejor calidad: Hy-MT2 1.8B de Tencent (licencia Apache 2.0, huggingface.co/tencent/Hy-MT2-1.8B-GGUF), 1,17 GB
en.TaskTransHigh=Better quality: Hy-MT2 1.8B by Tencent (Apache 2.0 license, huggingface.co/tencent/Hy-MT2-1.8B-GGUF), 1.17 GB
es.TaskTransHighNo=Mejor calidad: Hy-MT2 1.8B (1,17 GB). No recomendada en este equipo: %1
en.TaskTransHighNo=Better quality: Hy-MT2 1.8B (1.17 GB). Not recommended on this computer: %1
es.NoHighRam=tiene %1 GB de RAM y hacen falta 12
en.NoHighRam=it has %1 GB of RAM and it needs 12
es.NoHighAvx2=el procesador no tiene AVX2
en.NoHighAvx2=the processor does not have AVX2
es.TaskTrans7B=La mejor para la tarjeta gráfica: Hy-MT2 7B (licencia Apache 2.0, huggingface.co/tencent/Hy-MT2-7B-GGUF), 4,6 GB
en.TaskTrans7B=The best one for the graphics card: Hy-MT2 7B (Apache 2.0 license, huggingface.co/tencent/Hy-MT2-7B-GGUF), 4.6 GB
es.TaskMeasure=Medir este equipo al terminar, para elegir mejor el traductor (uno o dos minutos)
en.TaskMeasure=Measure this computer at the end, to choose the translator better (one or two minutes)
es.TranslationFailed=La lectura quedó lista, pero alguna parte de la traducción o del diccionario no se pudo instalar.%n%nAbre «Instalar o reparar las voces» en el menú Inicio para reintentar. El detalle queda en read_aloud_piper\runtime\setup.log.
en.TranslationFailed=Reading is ready, but some part of the translation or the dictionary could not be installed.%n%nOpen "Install or repair the voices" in the Start menu to retry. The details are in read_aloud_piper\runtime\setup.log.
es.GroupDictionary=Diccionario en el panel de texto, sin conexión (Ctrl+clic en una palabra):
en.GroupDictionary=Dictionary in the text panel, offline (Ctrl+click a word):
es.TaskDictionary=Diccionario: Open English WordNet (licencia CC BY 4.0) y WikDict (licencia CC BY-SA 4.0), 14 MB
en.TaskDictionary=Dictionary: Open English WordNet (CC BY 4.0 license) and WikDict (CC BY-SA 4.0 license), 14 MB

[Tasks]
Name: "autostart"; Description: "{cm:TaskAutostart}"
Name: "desktopicon"; Description: "{cm:TaskDesktop}"
; La traduccion (docs\adr\0016-traduccion-local.md). La alta viene marcada solo si
; el equipo puede usarla (12 GB de RAM y AVX2); si no, aparece desmarcada y con la
; razon. El 7B se ofrece con una tarjeta NVIDIA de 8 GB o mas. Medir, desmarcado.
Name: "transbasic"; Description: "{cm:TaskTransBasic}"; GroupDescription: "{cm:GroupTranslation}"
Name: "transhigh"; Description: "{cm:TaskTransHigh}"; GroupDescription: "{cm:GroupTranslation}"; Check: PuedeAlta
Name: "transhighno"; Description: "{code:DescripcionAltaNo}"; GroupDescription: "{cm:GroupTranslation}"; Flags: unchecked; Check: not PuedeAlta
Name: "trans7b"; Description: "{cm:TaskTrans7B}"; GroupDescription: "{cm:GroupTranslation}"; Flags: unchecked; Check: Puede7B
Name: "measure"; Description: "{cm:TaskMeasure}"; GroupDescription: "{cm:GroupTranslation}"; Flags: unchecked
; El diccionario del panel (docs\adr\0017-diccionario-en-el-panel.md), marcado.
Name: "dictionary"; Description: "{cm:TaskDictionary}"; GroupDescription: "{cm:GroupDictionary}"

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
Source: "..\parar_read_aloud.ps1"; DestDir: "{app}"; Flags: ignoreversion
; El mismo, extraible antes de copiar nada: al actualizar desde una version que aun no
; lo tenia, hay que cerrar los procesos de Piper antes de reemplazar archivos.
Source: "..\parar_read_aloud.ps1"; DestDir: "{tmp}"; Flags: dontcopy
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
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\parar_read_aloud.ps1"" -Root ""{app}"""; RunOnceId: "PararReadAloud"; Flags: runhidden waituntilterminated

[Code]
// Lo que el equipo puede usar para la traduccion: RAM, AVX2 y la memoria de la
// tarjeta NVIDIA (nvidia-smi). Se mira una vez al empezar.
type
  TMemoryStatusEx = record
    dwLength: DWORD;
    dwMemoryLoad: DWORD;
    ullTotalPhys: Int64;
    ullAvailPhys: Int64;
    ullTotalPageFile: Int64;
    ullAvailPageFile: Int64;
    ullTotalVirtual: Int64;
    ullAvailVirtual: Int64;
    ullAvailExtendedVirtual: Int64;
  end;

function GlobalMemoryStatusEx(var Estado: TMemoryStatusEx): BOOL;
  external 'GlobalMemoryStatusEx@kernel32.dll stdcall';
function IsProcessorFeaturePresent(Funcion: DWORD): BOOL;
  external 'IsProcessorFeaturePresent@kernel32.dll stdcall';

var
  RamMB: Integer;
  TieneAvx2: Boolean;
  VramMB: Integer;

function LeerVramNvidia: Integer;
var
  Archivo: String;
  Texto: AnsiString;
  Codigo: Integer;
begin
  Result := 0;
  Archivo := ExpandConstant('{tmp}\vram.txt');
  if Exec(ExpandConstant('{cmd}'), '/c nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits > "' + Archivo + '" 2>nul',
    '', SW_HIDE, ewWaitUntilTerminated, Codigo) and (Codigo = 0) then
    if LoadStringFromFile(Archivo, Texto) then
      Result := StrToIntDef(Trim(String(Texto)), 0);
end;

function InitializeSetup: Boolean;
var
  Estado: TMemoryStatusEx;
begin
  Estado.dwLength := SizeOf(Estado);
  RamMB := 0;
  if GlobalMemoryStatusEx(Estado) then
    RamMB := Estado.ullTotalPhys div (1024 * 1024);
  // 40 = PF_AVX2_INSTRUCTIONS_AVAILABLE
  TieneAvx2 := IsProcessorFeaturePresent(40);
  VramMB := LeerVramNvidia;
  Result := True;
end;

// 12 GB de RAM: un equipo de 12 GB informa algo menos (la memoria reservada).
function PuedeAlta: Boolean;
begin
  Result := (RamMB >= 11 * 1024) and TieneAvx2;
end;

function Puede7B: Boolean;
begin
  Result := PuedeAlta and (VramMB >= 7500);
end;

function DescripcionAltaNo(Param: String): String;
var
  Razon: String;
begin
  if not TieneAvx2 then
    Razon := CustomMessage('NoHighAvx2')
  else
    Razon := FmtMessage(CustomMessage('NoHighRam'), [IntToStr((RamMB + 512) div 1024)]);
  Result := FmtMessage(CustomMessage('TaskTransHighNo'), [Razon]);
end;

function ArgumentosTraduccion: String;
var
  Alta: Boolean;
begin
  Alta := WizardIsTaskSelected('transhigh') or WizardIsTaskSelected('transhighno');
  Result := '';
  if not WizardIsTaskSelected('transbasic') and not Alta and not WizardIsTaskSelected('trans7b') then
    Result := ' -SkipTranslation';
  if Alta then Result := Result + ' -TranslationHigh';
  if WizardIsTaskSelected('trans7b') then Result := Result + ' -Translation7B';
end;

function ArgumentosDiccionario: String;
begin
  Result := '';
  if not WizardIsTaskSelected('dictionary') then Result := ' -SkipDictionary';
end;

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

  // Lo que siga vivo (el proceso residente que no alcanzo a cerrarse, los
  // piper.exe que dejo huerfanos) tiene archivos abiertos y Windows no deja
  // sobrescribirlos. Solo se cierran los de esta carpeta.
  if DirExists(ExpandConstant('{app}')) then
  begin
    ExtractTemporaryFile('parar_read_aloud.ps1');
    Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\parar_read_aloud.ps1') + '" -Root "' + ExpandConstant('{app}') + '"',
      '', SW_HIDE, ewWaitUntilTerminated, Codigo);
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
      '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\setup.ps1') + '" -NoStartupPrompt -PauseOnError' + ArgumentosTraduccion + ArgumentosDiccionario,
      ExpandConstant('{app}'), SW_SHOWNORMAL, ewWaitUntilTerminated, Codigo);
    // 2: las voces estan, pero alguna parte de la traduccion o del diccionario no.
    if Ok and (Codigo = 2) then
      SuppressibleMsgBox(CustomMessage('TranslationFailed'), mbInformation, MB_OK, IDOK)
    else if (not Ok) or (Codigo <> 0) then
      SuppressibleMsgBox(CustomMessage('VoicesFailed'), mbError, MB_OK, IDOK);

    // Medir este equipo: el proceso residente arranca oculto y mide en segundo
    // plano; el resultado lo usa la traduccion Automatica.
    if Ok and (Codigo <> 1) and WizardIsTaskSelected('measure') then
      Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
        '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\read_aloud.ps1') + '" -MeasureDevice',
        ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, Codigo);
  end;
end;

// Al desinstalar se borra lo que bajo setup.ps1 (motor, voces, traduccion y
// diccionario del panel). Lo que es del usuario (ajustes y diccionario de
// pronunciacion, en read_aloud_piper\runtime) se conserva si lo pide; en una
// desinstalacion silenciosa se borra todo.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Conservar: Boolean;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    Conservar := False;
    if not UninstallSilent then
      Conservar := MsgBox(CustomMessage('KeepData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON1) = IDYES;
    if not DelTree(ExpandConstant('{app}\read_aloud_piper\bin'), True, True, True) then
    begin
      Sleep(1500);
      DelTree(ExpandConstant('{app}\read_aloud_piper\bin'), True, True, True);
    end;
    DelTree(ExpandConstant('{app}\read_aloud_piper\voices'), True, True, True);
    DelTree(ExpandConstant('{app}\read_aloud_piper\tmp'), True, True, True);
    // Los traductores y sus modelos (hasta unos 6 GB), y los rastros de
    // translateLocally: su clave en el registro (los hilos) y la carpeta vacia
    // que deja en %APPDATA%. RemoveDir solo borra una carpeta vacia.
    if not DelTree(ExpandConstant('{app}\read_aloud_piper\traduccion'), True, True, True) then
    begin
      Sleep(1500);
      DelTree(ExpandConstant('{app}\read_aloud_piper\traduccion'), True, True, True);
    end;
    RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, 'Software\translateLocally');
    RemoveDir(ExpandConstant('{userappdata}\translateLocally'));
    // El diccionario del panel (unos 50 MB): datos que bajo setup.ps1, no
    // del usuario (su archivo de Anki esta en Documentos).
    DelTree(ExpandConstant('{app}\read_aloud_piper\diccionario'), True, True, True);
    DelTree(ExpandConstant('{app}\copia_de_config_anterior'), True, True, True);
    if not Conservar then
    begin
      DelTree(ExpandConstant('{app}\read_aloud_piper'), True, True, True);
      DelTree(ExpandConstant('{app}\config'), True, True, True);
    end;
    RemoveDir(ExpandConstant('{app}'));
    if DirExists(ExpandConstant('{app}\read_aloud_piper\bin')) or DirExists(ExpandConstant('{app}\read_aloud_piper\traduccion')) then
      SuppressibleMsgBox(CustomMessage('LockedLeft'), mbInformation, MB_OK, IDOK);
  end;
end;
