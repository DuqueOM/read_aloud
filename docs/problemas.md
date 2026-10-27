# Si algo falla

Antes que nada:

```powershell
.\read_aloud.ps1 -Diagnose
```

Eso revisa el motor, las voces, el diccionario, los ajustes y si el proceso
residente está vivo. El registro está en
`read_aloud_piper\runtime\daemon.log`.

## No suena nada al pulsar el atajo

**Comprueba que AutoHotkey está corriendo.** Busca su icono verde en la
bandeja del sistema, junto al reloj. Si no está, abre `read_aloud_hotkey.ahk`
con doble clic.

**Comprueba que el proceso residente está vivo.** El diagnóstico lo dice. Si
no lo está, arráncalo:

```powershell
powershell -File .\read_aloud_daemon.ps1
```

**Comprueba que el atajo no está ocupado.** Algunos programas se quedan con
`Ctrl+Shift+V`. Prueba a leer desde la consola con `.\read_aloud.ps1`; si así
suena, el problema es el atajo y no el lector. Cámbialo en el archivo `.ahk`.

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

Si ocurre, hay dos procesos residentes. Ciérralos todos y arranca uno solo:

```powershell
.\read_aloud.ps1 -Stop
Get-Process powershell | Where-Object { $_.MainWindowTitle -eq '' }
powershell -File .\read_aloud_daemon.ps1
```

También revisa que no haya dos copias del script de AutoHotkey activas.

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
