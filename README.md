# Read Aloud

Lee en voz alta el texto que tengas seleccionado, con un atajo de teclado y
voces neuronales que corren en tu propia máquina. Sin internet, sin cuentas y
sin enviar nada a ningún servidor.

Está pensado para leer mientras trabajas: distingue el español del inglés
dentro de un mismo texto y pronuncia los términos técnicos como los dirías tú,
no como los leería un lector que no sabe inglés.

```
Ctrl+Shift+V        leer lo que esté seleccionado
Ctrl+Shift+Q        detener
Ctrl+Shift+Espacio  pausar o continuar
Ctrl+Shift+,        retroceder 10 segundos
Ctrl+Shift+.        avanzar 10 segundos
Ctrl+Shift+] y [    subir o bajar la velocidad
```

Mientras lee aparece una barra pequeña sobre todas las ventanas, con pausa,
avance, retroceso, velocidad y posición. Se cierra sola al terminar.

El botón `≡` de esa barra despliega el texto que se está leyendo, con la frase
que suena resaltada y lo ya leído atenuado. Así no te pierdes aunque cambies
de ventana, y un clic sobre cualquier frase salta a ella.

## Qué necesitas

| Requisito | Detalle |
|---|---|
| Windows | 10 u 11, 64 bits |
| Windows PowerShell | 5.1, el que ya viene con Windows |
| AutoHotkey v2 | Solo para los atajos de teclado. [autohotkey.com](https://www.autohotkey.com) |
| Espacio en disco | Unos 150 MB para el motor y las voces |

No hace falta ser administrador. Nada se instala fuera de la carpeta del
repositorio y de tu carpeta de Inicio.

## Instalación

```powershell
git clone https://github.com/DuqueOM/read_aloud.git
cd read_aloud
.\setup.ps1
.\install_startup.ps1
```

`setup.ps1` descarga el motor Piper y los modelos de voz, que no están en el
repositorio porque pesan demasiado para Git. `install_startup.ps1` deja los
atajos y el motor activos cada vez que inicias sesión en Windows.

Si PowerShell se niega a ejecutar los scripts, ábrelos así una sola vez:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Comprueba que todo quedó bien:

```powershell
.\read_aloud.ps1 -Diagnose
```

## Cómo se usa

Selecciona texto en cualquier programa y pulsa `Ctrl+Shift+V`. También
funciona desde la consola:

```powershell
.\read_aloud.ps1                                   # lee el portapapeles
.\read_aloud.ps1 -InputText "Hola, buenos dias"    # lee un texto concreto
.\read_aloud.ps1 -Stop                             # detiene
.\read_aloud.ps1 -Toggle                           # pausa o continua
.\read_aloud.ps1 -Language English                 # fuerza el idioma
.\read_aloud.ps1 -ShowPlan                         # muestra la segmentacion, sin leer
.\read_aloud.ps1 -ListVoices                       # voces instaladas
.\read_aloud.ps1 -Diagnose                         # revisa la instalacion
```

`-ShowPlan` es la herramienta para entender por qué una frase sonó en un
idioma y no en otro. Muestra el texto ya partido, con la voz asignada a cada
parte y sin reproducir nada.

## Cómo está armado

Hay un proceso residente que se queda en segundo plano con los modelos de voz
ya cargados en memoria. El atajo de teclado no arranca PowerShell: le habla
directamente por una tubería con nombre. Por eso la voz empieza casi de
inmediato en lugar de tardar varios segundos.

```
Ctrl+Shift+V                 read_aloud.ps1
  (AutoHotkey)                 (consola)
        |                          |
        +----------+---------------+
                   |
          tuberia read_aloud_pipe
                   |
        read_aloud_daemon.ps1
        proceso residente
                   |
        +----------+----------+
        |                     |
   piper.exe es          piper.exe en
   (modelo cargado)      (modelo cargado)
                   |
        reproductor flotante
```

El texto se parte en fragmentos de una frase cada uno. El primero suena en
cuanto está listo, y los siguientes se generan mientras suena el anterior.
Que cada fragmento sea una frase es lo que permite resaltar en el panel
exactamente lo que se está oyendo.

Antes de partirlo, el texto se lee como lo que es: títulos, párrafos, filas de
tabla y viñetas. Cada cambio de bloque recibe una pausa propia, de modo que se
oye cuándo termina una fila y empieza la siguiente, o cuándo llega un título.

Detalle completo en [docs/como-funciona.md](docs/como-funciona.md).

## Idiomas

El texto se divide en frases y cada frase elige su idioma. Las frases
contiguas del mismo idioma se agrupan y se leen con la voz correspondiente,
así que un párrafo en inglés dentro de un texto en español suena en inglés.

Una palabra suelta en inglés no cambia la voz. Cambiar de voz por una sola
palabra suena peor que ajustar la escritura, así que esos términos se
reescriben con ortografía española antes de leerlos: `deploy` se convierte en
`diplói`, `cache` en `caché`, `pull request` en `pul rikuést`.

Ese diccionario es un archivo de texto que puedes editar:
[config/terms_es.tsv](config/terms_es.tsv). Trae 251 términos de programación
y trabajo. Más detalles en [docs/idiomas.md](docs/idiomas.md).

## Ajustes

Todo lo configurable está en [config/settings.psd1](config/settings.psd1):
velocidad, voces, tamaño de los fragmentos, opacidad del reproductor y
segundos de salto. Después de cambiarlo, reinicia el proceso residente:

```powershell
.\read_aloud.ps1 -Stop
powershell -File .\read_aloud_daemon.ps1
```

Referencia de cada valor en [docs/configuracion.md](docs/configuracion.md).

## Si algo falla

Empieza siempre por `.\read_aloud.ps1 -Diagnose`. El registro del proceso
residente está en `read_aloud_piper\runtime\daemon.log`.

Los casos frecuentes y su solución están en
[docs/problemas.md](docs/problemas.md).

## Estructura del repositorio

```
read_aloud.ps1              Punto de entrada
read_aloud_daemon.ps1       Proceso residente y reproductor
read_aloud_hotkey.ahk       Atajos de teclado
stop_read_aloud.ps1         Detener
setup.ps1                   Instala el motor y las voces
install_startup.ps1         Arranque automatico con Windows
config/settings.psd1        Ajustes
config/terms_es.tsv         Diccionario de pronunciacion
lib/ReadAloud.Core.ps1      Rutas, audio y comunicacion
lib/ReadAloud.Text.ps1      Idioma, segmentacion y normalizacion
docs/                       Documentacion
read_aloud_piper/           Motor y voces (lo crea setup.ps1)
```

## Créditos y licencia

El motor de voz es [Piper](https://github.com/rhasspy/piper), de Rhasspy, con
licencia MIT. Las voces vienen de
[rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices) y cada una
tiene su propia licencia, indicada en su ficha.

Este repositorio contiene únicamente los scripts que orquestan todo eso.
