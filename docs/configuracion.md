# Configuración

Todo lo ajustable vive en `config/settings.psd1`. Si borras el archivo, el
programa sigue funcionando con estos mismos valores.

Lo más común se cambia sin editar nada, desde el **panel de ajustes**: el
botón de la tuerca del reproductor (ver [Panel de ajustes](#panel-de-ajustes)).
Lo que elijas ahí se guarda en `read_aloud_piper\runtime\ajustes.json` y manda
sobre `settings.psd1`.

Lo que es de tu equipo, como la carpeta de la voz propia (`QwenWorkDir`), va
en `config\settings.local.psd1`: el mismo formato que `settings.psd1`, solo
con las claves que cambian. No se versiona, manda sobre `settings.psd1` y el
botón "Restablecer todo" del panel no lo toca:

```powershell
@{
    QwenWorkDir = 'D:\voces\mi_voz'
}
```

El orden, de menos a más prioridad: los valores por defecto,
`settings.psd1`, `settings.local.psd1` y `ajustes.json`.

Después de cambiar algo en `settings.psd1`, reinicia el proceso residente:
ciérralo desde la consola y la próxima lectura lo vuelve a arrancar con los
ajustes nuevos. (Los cambios hechos en el panel ofrecen su propio botón
"Reiniciar ahora".)

```powershell
. .\lib\ReadAloud.Core.ps1
Send-ReadAloudCommand -PipeName 'read_aloud_pipe' -Command @{ cmd = 'quit' }
```

`.\read_aloud.ps1 -Stop` no sirve para esto: solo detiene la lectura. Y
arrancar `read_aloud_daemon.ps1` con el proceso abierto tampoco: el nuevo ve
que ya hay uno y se cierra.

## Voces

| Valor | Por defecto | Qué hace |
|---|---|---|
| `VoiceEs` | `es_MX-claude-high` | Modelo para el español, sin la extensión `.onnx` |
| `VoiceEn` | `en_US-lessac-high` | Modelo para el inglés |

El archivo debe existir en `read_aloud_piper\voices`. Consulta las opciones en
[idiomas.md](idiomas.md).

### Voz propia con Qwen3-TTS

| Valor | Por defecto | Qué hace |
|---|---|---|
| `EngineEs` | `auto` | Motor del español: `auto`, `piper` o `qwen` |
| `EngineEn` | `auto` | Motor del inglés |
| `QwenWorkDir` | vacío | Carpeta de trabajo de la voz propia ([voz-personalizada.md](voz-personalizada.md)) |
| `QwenMinVramGB` | `7` | Memoria mínima de la tarjeta NVIDIA para usar Qwen |
| `QwenBatch` | `4` | Frases que se generan juntas |
| `QwenBatchChars` | `320` | Tope de caracteres por grupo, para que unas frases largas no retrasen a las que esperan detrás. `0` = sin tope |
| `QwenIdleMinutes` | `0` | Minutos sin leer tras los que Qwen se cierra; `0` es nunca |
| `QwenReopen` | `$true` | Volver a cargar Qwen en cuanto la tarjeta queda libre, tras cederla |
| `QwenReopenFreeGB` | `6` | Memoria libre de la tarjeta que hace falta para volver a cargarlo |
| `Performance` | `'rapido'` | `'rapido'` deja la voz cargada; `'ahorro'` la carga al leer y la libera tras `SaverIdleMinutes` (ver [Panel de ajustes](#panel-de-ajustes)) |
| `SaverIdleMinutes` | `5` | En ahorro, minutos sin leer tras los que se libera la voz |

Read Aloud lee con Piper en cualquier equipo. Si además tienes una voz propia
entrenada con [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) y una tarjeta
NVIDIA con al menos `QwenMinVramGB` de memoria, `auto` la usa; si falta
cualquiera de las dos cosas, sigue con Piper sin que tengas que cambiar nada.
`piper` fuerza Piper; `qwen` es igual que `auto`, pero deja en `daemon.log`
por qué no se pudo usar Qwen. Si Qwen falla en medio de una lectura, la frase
se lee con Piper, y si el proceso no responde ni al reabrirlo, el resto de la
sesión también.

Para instalar lo que la voz necesita en un equipo nuevo, con una voz ya
entrenada, basta `voz_personalizada\instalar.ps1 -Trabajo D:\voces\mi_voz
-SoloLectura` y copiar la voz a `modelos\voz_app`. Cómo entrenar una voz, en
[voz-personalizada.md](voz-personalizada.md).

La voz la genera `lib\servidor_qwen.py`, un proceso de Python que habla el
mismo protocolo que Piper y que usa, de la carpeta de trabajo, el entorno
`.venv_qwen`, la cache del modelo base en `modelos\hf` y la voz elegida en
`modelos\voz_app` (`ajuste.json`, `voz.safetensors` y `lora.safetensors`). Lo
que pasa dentro queda en `read_aloud_piper\runtime\qwen.log`.

Qwen tarda unos 20 s en cargar (hasta un minuto si Windows no tiene sus
librerías en la cache del disco) y ocupa unos 5 GB de la tarjeta y 2.3 GB de
RAM. Para que ninguna lectura espere esa carga, se abre con el proceso
residente y se queda abierto. Se cierra solo cuando otro programa empieza a
usar 1.5 GB más de la tarjeta que cuando cargó, tras un minuto sin leer, y se
vuelve a cargar en cuanto la tarjeta tiene `QwenReopenFreeGB` libres. Si se
cerró por `QwenIdleMinutes`, en cambio, espera a la lectura siguiente.

Mientras un paso pesado de la voz personalizada (transcribir, separar,
entrenar) usa la tarjeta, deja su número de proceso en `gpu_ocupada`, en la
carpeta de trabajo. Mientras ese proceso siga vivo, Read Aloud lee con Piper y
Qwen se cierra para dejarle la tarjeta entera: compartir los 8 GB hacía
esperar minutos cada frase. Al terminar el paso, la voz de Qwen se vuelve a
cargar sola, en los 30 s siguientes.

En una RTX 5070 de portátil, una frase sola tarda 1.1 veces lo que dura, y
dos juntas 0.54 veces y cuatro juntas 0.34 veces: más rápido que tiempo real.
Por eso las dos primeras frases de cada lectura se generan juntas, y las
siguientes en grupos de hasta `QwenBatch` mientras suenan las anteriores. Con
la primera sola, la segunda llegaba un segundo tarde. Los
valores de abajo, salvo `SentenceSilence`, son solo de Piper.

## Voz y ritmo

| Valor | Por defecto | Qué hace |
|---|---|---|
| `LengthScale` | `1.06` | Velocidad. Más alto es más lento. `1.00` es la velocidad base del modelo |
| `SentenceSilence` | `0.36` | Segundos de silencio después de cada frase |
| `NoiseScale` | `0.667` | Variación de la entonación |
| `NoiseW` | `0.8` | Variación de la duración de cada sonido |

`LengthScale` es el que vas a querer tocar. Para escuchar más rápido, prueba
`0.95`. Para textos densos que quieres seguir con calma, `1.15`.

Los dos valores de ruido son los que trae Piper de fábrica. Bajarlos produce
una voz más plana y predecible; subirlos, más variada y a veces inestable.

## Fragmentos

| Valor | Por defecto | Qué hace |
|---|---|---|
| `MinChunkChars` | `25` | Frases más cortas que esto se juntan con la siguiente |
| `FirstChunkChars` | `70` | Largo máximo del primer fragmento de una lectura. Corto, para que la voz empiece pronto |
| `MaxChunkChars` | `180` | Largo máximo del resto. Una frase más larga se parte en una pausa (`;` `:` coma, raya). `0` no parte nada |

El segundo fragmento usa uno y medio de `FirstChunkChars`. El tope crece porque
un fragmento largo retrasa a los que vienen detrás: la voz propia genera por
grupos y cada grupo tarda lo que su frase más larga. Es igual para Piper y para
la voz propia.

Cada frase es un fragmento de audio, y cada fragmento es lo que se resalta en
el panel de texto. Solo las frases muy cortas, como un `OK.` suelto, se juntan
con la siguiente para que no suenen entrecortadas.

Subir el valor agrupa más frases en cada fragmento. El resaltado del panel se
vuelve menos preciso, porque marca el fragmento entero, y la primera palabra
tarda más en sonar, porque el primer fragmento es más largo.

## Pausas entre bloques

El texto se divide en bloques antes de leerlo: títulos, párrafos, filas de
tabla y viñetas. Al final de cada bloque se añade un silencio para que el
cambio se oiga.

| Valor | Por defecto | Dónde se aplica |
|---|---|---|
| `PauseParagraph` | `0.35` | Entre un párrafo y el siguiente |
| `PauseBeforeHeading` | `0.55` | Antes de un título |
| `PauseAfterHeading` | `0.30` | Entre el título y lo que viene debajo |
| `PauseTableRow` | `0.18` | Entre filas de una tabla o viñetas de una lista |

Están en segundos y se suman al silencio normal de fin de frase, que es
`SentenceSilence`. Por eso valores pequeños ya se notan: una fila de tabla
termina con unos seis décimas de silencio en total, y un título llega después
de casi un segundo.

Con `0` se desactiva cada una por separado. Si quieres el comportamiento
anterior, pon las cuatro en `0`.

Para ver qué bloques detecta en un texto concreto, sin escucharlo:

```powershell
.\read_aloud.ps1 -ShowPlan
```

Debajo de cada fragmento aparece la pausa que lo sigue.

## Idioma

| Valor | Por defecto | Qué hace |
|---|---|---|
| `FallbackLanguage` | `'es'` | Idioma que se usa cuando el texto es demasiado corto o ambiguo |

Si trabajas más en inglés que en español, cámbialo a `'en'`.

## Reproductor

| Valor | Por defecto | Qué hace |
|---|---|---|
| `ShowPlayer` | `$true` | Muestra la ventana flotante durante la lectura |
| `PlayerAutoClose` | `$true` | La cierra sola al terminar |
| `PlayerOpacity` | `0.8` | Opacidad en reposo, de `0.3` a `1.0` |
| `SkipSeconds` | `10` | Segundos que saltan los botones y los atajos |
| `PlayerScale` | `1.0` | Tamaño de todo el reproductor, de `0.8` a `1.6` |
| `TextFontSize` | `13` | Tamaño de la letra del panel de texto, de `10` a `22` |
| `PanelOnShow` | `'recordar'` | Panel de texto al aparecer: `'recordar'` (como lo dejaste), `'abierto'` o `'cerrado'` |

Con `PlayerAutoClose = $false` la barra se queda visible al terminar, y el
botón de reproducir vuelve a leer el mismo texto desde el principio.

La ventana aparece translúcida, con la opacidad de `PlayerOpacity`, para no
tapar del todo lo que tiene detrás. Un clic sobre ella la vuelve opaca
mientras la usas, y un clic en cualquier otra parte la devuelve a la
opacidad de reposo.

La ventana aparece en la esquina inferior derecha de la pantalla y se ancla
por esa esquina: al abrir el panel de texto crece hacia arriba, y la barra de
controles se queda donde estaba.

Se mueve arrastrando la pestaña de arriba, o desde cualquier parte de la
barra que no sea un botón, la barra de posición o el texto, y recuerda dónde
la dejaste. Un doble clic sobre la pestaña o la barra la devuelve a la
esquina. La posición se guarda en `read_aloud_piper\runtime\player.json`.

### Panel de texto

El botón `≡` de la barra despliega el texto que se está leyendo, encima de
los controles. La frase que suena aparece resaltada en azul, lo ya leído se
atenúa y lo pendiente queda en el color normal. El panel se desplaza solo
para mantener la frase actual a la vista, pero únicamente cuando se sale de
la franja visible, así que puedes desplazarte a mano sin que te lo quite.

Un clic sobre cualquier frase salta a ella y sigue leyendo desde ahí, incluso
si estaba en pausa. Arrastrar en cambio selecciona texto, sin saltar, y el
clic derecho sobre la selección ofrece copiarla. También funcionan `Ctrl+C` y
`Ctrl+A`.

Con el panel abierto, el tamaño se cambia como el de cualquier ventana,
arrastrando su contorno: cada lado mueve solo ese lado y deja quieto el
opuesto, y cada esquina mueve los dos lados que la forman. Lo que crece es el
panel; la barra de controles conserva su tamaño. No baja de 80 píxeles de
alto ni de lo ancha que es la barra, y no se estira más allá del escritorio.

El panel recuerda si lo dejaste abierto y el tamaño que le diste. Se muestra el texto original, no el
que se pronuncia: verás `deploy`, aunque la voz diga `diplói`.

### Velocidad de reproducción

El botón verde junto a `+10` muestra la velocidad actual. Un clic despliega
encima, en fila, todas las velocidades: 0.5x, 0.75x, 0.9x, 1x, 1.1x, 1.25x,
1.5x, 1.75x y 2x, con la actual marcada; un clic en una la elige y cierra la
fila. La rueda del ratón sobre el botón la sube o la baja un paso, igual que
`Ctrl+Shift+]` y `Ctrl+Shift+[`.

El cambio es inmediato porque acelera la reproducción del audio ya generado,
sin volver a sintetizar nada. La velocidad elegida se recuerda para las
siguientes lecturas, en el mismo `player.json`.

No es lo mismo que `LengthScale`. Ese ajuste cambia el ritmo con que la voz
genera el audio y requiere reiniciar el proceso residente; el botón actúa
encima de eso. El reloj del reproductor cuenta tiempo del audio, así que a 2x
avanza dos segundos por cada segundo real.

### Panel de ajustes

El botón de la tuerca abre los ajustes que no son de reproducción. Los
cambios se guardan solos en `read_aloud_piper\runtime\ajustes.json`, que manda
sobre `settings.psd1`, y "Restablecer todo" lo borra y vuelve a los de
`settings.psd1`.

| Sección | Ajuste | Cuándo se nota |
|---|---|---|
| Apariencia | Opacidad en reposo, tamaño del reproductor, letra del texto, panel de texto al aparecer y su alto y ancho | Al momento |
| Voz | Motor (automático, voz propia o Piper), voz de Piper en español y en inglés | Al reiniciar el lector |
| Voz | Rendimiento: rápido o ahorro de recursos, y en ahorro, a los cuántos minutos sin leer se libera la voz | Al reiniciar el lector |
| Lectura | Cerrar al terminar, salto de los botones, idioma de los textos ambiguos, pausa entre párrafos | Al momento o en la próxima lectura |
| Lectura | Pausa entre frases | Al reiniciar el lector |

Los ajustes de voz van a los procesos de síntesis, que se abren al arrancar.
Cuando cambias uno, el panel ofrece "Reiniciar ahora": el lector se cierra y
vuelve a abrir solo en unos segundos, y corta la lectura en curso.

**Rendimiento**, solo con la voz propia de Qwen3-TTS:

| | Rápido (`Performance = 'rapido'`) | Ahorro de recursos (`'ahorro'`) |
|---|---|---|
| Voz cargada | Al arrancar el lector, y otra vez en cuanto la tarjeta queda libre | Con la primera lectura |
| Primera frase | 1 o 2 s | Unos 20 s la primera vez; después, 1 o 2 s mientras siga cargada |
| Sin leer | Ocupa unos 5 GB de la tarjeta y 2.3 GB de RAM, que cede si otro programa los pide | Se libera tras `SaverIdleMinutes` (5 por defecto) sin leer, y no ocupa nada |

## Limpieza

| Valor | Por defecto | Qué hace |
|---|---|---|
| `MaxTmpAgeHours` | `6` | Horas que se conservan los WAV temporales |

El borrado ocurre al arrancar el proceso residente, es decir, normalmente una
vez al día cuando inicias sesión.

## Atajos de teclado

Los atajos están en `read_aloud_hotkey.ahk`, arriba del todo. La sintaxis de
AutoHotkey usa `^` para Ctrl, `+` para Shift y `!` para Alt.

```autohotkey
^+v:: ReadSelection()                    ; Ctrl+Shift+V
^+q:: SendCommand('{"cmd":"stop"}')      ; Ctrl+Shift+Q
^+Space:: SendCommand('{"cmd":"toggle"}')
```

Después de editarlos, recarga el script desde el icono de AutoHotkey en la
bandeja del sistema, o cierra sesión y vuelve a entrar.

## Órdenes disponibles

Si quieres controlar el lector desde otro programa, escribe una línea JSON en
`\\.\pipe\read_aloud_pipe`:

| Orden | Efecto |
|---|---|
| `{"cmd":"speak","text":"...","lang":"Auto"}` | Lee ese texto |
| `{"cmd":"stop"}` | Detiene y esconde el reproductor |
| `{"cmd":"toggle"}` | Pausa o continúa |
| `{"cmd":"back"}` | Retrocede (`SkipSeconds`) |
| `{"cmd":"forward"}` | Avanza (`SkipSeconds`) |
| `{"cmd":"louder"}` | Sube el volumen un paso (10 %) |
| `{"cmd":"quieter"}` | Baja el volumen un paso (10 %) |
| `{"cmd":"prev"}` | Frase anterior; con más de 2 s de la actual, vuelve primero a su comienzo |
| `{"cmd":"next"}` | Frase siguiente |
| `{"cmd":"faster"}` | Sube la velocidad un paso |
| `{"cmd":"panel"}` | Muestra u oculta el panel de texto |
| `{"cmd":"slower"}` | Baja la velocidad un paso |
| `{"cmd":"ping"}` | No hace nada, sirve para probar la conexión |
| `{"cmd":"quit"}` | Cierra el proceso residente |

`lang` acepta `Auto`, `Spanish` o `English`.

La tubería es de una sola dirección: el proceso residente lee pero nunca
responde. Saber si está vivo consiste en abrir la tubería, porque solo existe
mientras él escucha. Abre con `GENERIC_WRITE` y `OPEN_EXISTING`, escribe la
línea terminada en salto de línea y cierra.
