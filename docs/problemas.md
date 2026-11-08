# Si algo falla

Antes que nada:

```powershell
.\read_aloud.ps1 -Diagnose
```

Eso revisa el motor, las voces, el diccionario, los ajustes y si el proceso
residente está vivo. El registro está en
`read_aloud_piper\runtime\daemon.log`.

## Instalé Read Aloud y no tiene voz (falta el motor o las voces)

Si la descarga que hace el instalador falló (sin internet, un firewall, un
antivirus, un proxy), Read Aloud lo avisa al abrirse y ofrece descargar el
motor y las voces. También sirve "Instalar o reparar las voces" del menú
Inicio, que abre una ventana con el avance y se puede repetir sin riesgo: lo
que ya está no se vuelve a bajar.

Si `setup.log` dice "Acceso denegado" al reemplazar `espeak-ng.dll` (u otro
archivo de `bin\piper`), es que un `piper.exe` seguía abierto y Windows no deja
sobrescribir sus DLL. Desde la 1.3.2 el instalador y `setup.ps1` lo cierran antes
y el motor se reemplaza de una vez; en la 1.3.1 o anterior, cierra Read Aloud
(bandeja > Salir) y ejecuta `parar_read_aloud.ps1` (o, en PowerShell:
`Get-Process piper | Stop-Process -Force`) y vuelve a abrir "Instalar o
reparar las voces".

Si sigue fallando, mira `read_aloud_piper\runtime\setup.log`: dice qué archivo
no se pudo bajar y por qué. Hacen falta acceso a `github.com` y
`huggingface.co`. Si Piper no arranca aunque esté descargado, suele faltar el
Visual C++ Redistributable de Microsoft: `setup.ps1` lo detecta y lo instala
(Windows pide permiso de administrador una vez); a mano:
https://aka.ms/vs/17/release/vc_redist.x64.exe.

## No suena nada al pulsar el atajo

**Comprueba que Read Aloud está corriendo.** Busca su icono (un círculo verde
con un altavoz) en la bandeja del sistema, junto al reloj. Si no está, el
proceso residente no está activo: arráncalo como se explica abajo.

**Comprueba que el proceso residente está vivo.** El diagnóstico lo dice. Si
no lo está, arráncalo:

```powershell
powershell -File .\read_aloud_daemon.ps1
```

**Comprueba que el atajo no está ocupado.** Si otro programa ya tiene
`Ctrl+Alt+V`, Read Aloud lo avisa con un globo al arrancar y lo anota en
`daemon.log` ("no disponible: in-use"). Prueba a leer desde la consola con
`.ead_aloud.ps1`; si así suena, el problema es el atajo y no el lector.
Cámbialo con los ajustes `Hotkey...` de `config/settings.psd1`.

## Empieza a leer y se corta

Mira el registro. Lo más probable es que el proceso de Piper se haya caído; el
residente lo levanta solo en el siguiente fragmento, pero el que estaba en
curso se pierde.

Si pasa con un texto concreto, búscalo con `.\read_aloud.ps1 -ShowPlan`. Una
frase larguísima, sin puntos, se sintetiza en un solo fragmento, y partirla con
algún punto ayuda.

## Lee el inglés con acento español

**Falta la voz en inglés.** El diagnóstico lo marca en rojo. Instálala:

```powershell
.\setup.ps1
```

**El texto no se detectó como inglés.** Míralo con `.\read_aloud.ps1 -ShowPlan`.
Si son frases sueltas de menos de cinco palabras, se leen en el idioma de la
frase anterior a propósito; es lo que evita que la voz salte a cada momento.
Para ese texto, fuerza el idioma con `-Language English`.

## Un término técnico suena mal

Añádelo a `config/terms_es.tsv` con la pronunciación que quieras. El
procedimiento completo, con la tabla de equivalencias de sonidos, está en
[idiomas.md](idiomas.md).

## Suena dos veces

No debería pasar: una orden nueva reemplaza la anterior, y un texto idéntico
recibido en menos de un segundo y medio se ignora.

Si ocurre, hay dos procesos residentes. Ciérralos todos; la próxima lectura
arranca uno solo:

```powershell
. .\lib\ReadAloud.Core.ps1
Send-ReadAloudCommand -PipeName 'read_aloud_pipe' -Command @{ cmd = 'quit' }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*-File*read_aloud_daemon.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId }
```

## La ventana del reproductor estorba

Arrástrala a donde quieras; recuerda la posición. Para quitarla del todo, pon
`ShowPlayer = $false` en los ajustes: los atajos de pausa y salto siguen
funcionando sin ella.

## PowerShell no deja ejecutar los scripts

Es la política de ejecución de Windows. Llámalos así:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

O permite los scripts de tu usuario de forma permanente:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## setup.ps1 no descarga nada

Suele ser un proxy corporativo o el antivirus bloqueando la conexión. Las
descargas salen de `github.com` y de `huggingface.co`.

Puedes bajar los archivos a mano y dejarlos en su sitio:

- Motor: `piper_windows_amd64.zip` de las
  [versiones de Piper](https://github.com/rhasspy/piper/releases), descomprimido
  en `read_aloud_piper\bin` de modo que quede `read_aloud_piper\bin\piper\piper.exe`.
- Voces: el `.onnx` y su `.onnx.json` de
  [piper-voices](https://huggingface.co/rhasspy/piper-voices), en
  `read_aloud_piper\voices`.

## Ocupa mucho disco

Los WAV temporales se borran al terminar cada lectura, y los que sobrevivan a
un corte se limpian cuando arranca el proceso residente. Para vaciarlos ahora:

```powershell
.\read_aloud.ps1 -Stop
Remove-Item .\read_aloud_piper\tmp\*.wav -Force
```

El diagnóstico te dice cuánto ocupan.

## Quitar el arranque automático

```powershell
.\install_startup.ps1 -Uninstall
```

Eso borra los accesos directos de la carpeta de Inicio y cierra el proceso
residente. Los archivos del repositorio no se tocan.
