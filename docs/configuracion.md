# Configuración

Todo lo ajustable vive en `config/settings.psd1`. Si borras el archivo, el
programa sigue funcionando con estos mismos valores.

Después de cambiar algo, reinicia el proceso residente:

```powershell
.\read_aloud.ps1 -Stop
powershell -File .\read_aloud_daemon.ps1
```

## Voces

| Valor | Por defecto | Qué hace |
|---|---|---|
| `VoiceEs` | `es_MX-claude-high` | Modelo para el español, sin la extensión `.onnx` |
| `VoiceEn` | `en_US-lessac-medium` | Modelo para el inglés |

El archivo debe existir en `read_aloud_piper\voices`. Consulta las opciones en
[idiomas.md](idiomas.md).

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
| `ChunkTargetChars` | `220` | Tamaño al que se cierran los fragmentos normales |
| `FirstChunkMinChars` | `25` | Mínimo del primer fragmento |

`FirstChunkMinChars` decide cuánto esperas a oír la primera palabra. El primer
fragmento se corta en la primera frase completa que llegue a ese tamaño, así
que con `25` casi siempre es una sola frase.

Subirlo agrupa más frases al principio y retrasa el arranque: pasar de `25` a
`70` subió la espera de 449 a 702 milisegundos en las pruebas, sin ninguna
ganancia a cambio.

`ChunkTargetChars` afecta a la fluidez del resto. Fragmentos grandes suenan
más continuos porque cada uno lleva su entonación completa; fragmentos
pequeños permiten saltar con más precisión con los botones de avance.

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
| `PlayerOpacity` | `0.94` | Opacidad, de `0.3` a `1.0` |
| `SkipSeconds` | `10` | Segundos que saltan los botones y los atajos |

Con `PlayerAutoClose = $false` la barra se queda visible al terminar, y el
botón de reproducir vuelve a leer el mismo texto desde el principio.

La ventana se arrastra desde cualquier parte que no sea un botón, y recuerda
dónde la dejaste: la posición se guarda en
`read_aloud_piper\runtime\player.json`.

### Velocidad de reproducción

El botón verde junto a `+10` muestra la velocidad actual. Un clic la sube un
paso y un clic derecho la baja. También responden `Ctrl+Shift+]` y
`Ctrl+Shift+[`. Los pasos son 0.75x, 1x, 1.25x, 1.5x, 1.75x y 2x.

El cambio es inmediato porque acelera la reproducción del audio ya generado,
sin volver a sintetizar nada. La velocidad elegida se recuerda para las
siguientes lecturas, en el mismo `player.json`.

No es lo mismo que `LengthScale`. Ese ajuste cambia el ritmo con que la voz
genera el audio y requiere reiniciar el proceso residente; el botón actúa
encima de eso. El reloj del reproductor cuenta tiempo del audio, así que a 2x
avanza dos segundos por cada segundo real.

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
| `{"cmd":"back"}` | Retrocede |
| `{"cmd":"forward"}` | Avanza |
| `{"cmd":"faster"}` | Sube la velocidad un paso |
| `{"cmd":"slower"}` | Baja la velocidad un paso |
| `{"cmd":"ping"}` | No hace nada, sirve para probar la conexión |
| `{"cmd":"quit"}` | Cierra el proceso residente |

`lang` acepta `Auto`, `Spanish` o `English`.

La tubería es de una sola dirección: el proceso residente lee pero nunca
responde. Saber si está vivo consiste en abrir la tubería, porque solo existe
mientras él escucha. Abre con `GENERIC_WRITE` y `OPEN_EXISTING`, escribe la
línea terminada en salto de línea y cierra.
