# Proceso con Qwen3-TTS

Son los scripts con que se hizo la voz de prueba entre octubre de 2026 y hoy,
copiados tal como corrieron. La explicación de cada paso y por qué está en
[docs/voz-personalizada.md](../../docs/voz-personalizada.md), y las decisiones
grandes en [docs/adr/](../../docs/adr).

> **Estado:** probados de punta a punta con una voz. Todavía no están
> generalizados como los de [scripts/](../scripts), que leen `voz.toml`: estos
> traen fijas algunas cosas de esta voz y de este equipo, listadas abajo.
> Generalizarlos es el siguiente paso pendiente.

## Cómo se corren

Cada script calcula la carpeta de trabajo como la carpeta padre de la suya.
Por eso esta carpeta se copia a `<trabajo>\scripts` y los pasos se corren
desde `<trabajo>`, cada uno con su entorno:

```powershell
cd D:\voces\mi_voz
Copy-Item C:\ruta\a\read_aloud\voz_personalizada\proceso_qwen\* .\scripts\
.\.venv\Scripts\python.exe scripts\lote.py
```

## Orden

| Paso | Script | Entorno | Qué hace |
|---|---|---|---|
| 1 | `lote.py` | `.venv` | Extrae el audio de cada capítulo, separa la voz (`02`), transcribe (`03`, Whisper en la tarjeta a media precisión), alinea las palabras (`03b`) y calcula las huellas de WavLM (`24`). Va sumando las descargas que terminan y muestra el avance en `progreso.html` |
| 2 | `21_hablante.py` | `.venv` | Compara formas de reconocer la voz con las decisiones de una revisión anterior. La primera vez hace falta una revisión inicial con los cortes de `04_cortar.py`; ver la guía |
| 3 | `24_curva_wavlm.py` | `.venv` | Sin argumentos, entrena el clasificador de quién habla con esas decisiones |
| 4 | `25_cortar_frases.py` | `.venv` | Corta cada capítulo en clips de frases completas de la voz |
| 5 | `29_preparar_revision.py` | `.venv` (lanza los demás) | Puntúa la calidad de cada clip (`26`), lo transcribe con Qwen3-ASR y Whisper (`27`) y arma la página de revisión (`28`) |
| 6 | La página `datos\28_revision\revision.html` | navegador | Revisión única: conservar o descartar y corregir el texto. Se exporta `revision.json` |
| 7 | `30_seleccion_final.py` | `.venv` | Quita duplicados, clips cortos y tomas de más, y deja los mejores 60 minutos |
| 8 | `32_entrenar_final.py` | `.venv` (lanza los demás) | Quita el eco, iguala el volumen y saca los códigos de Qwen (`31`), y entrena (`11b`) con los 60 mejores minutos y con todo lo conservado |
| 9 | `11c_probar_qwen.py`, `09e_prosodia.py`, `10c_medir.py`, `13_comparar.py` | `.venv_qwen`, `applio\.venv`*, `.venv` | Genera las frases de prueba con cada época, mide entonación, timbre y errores de texto, y arma la comparación a ciegas con la voz real |

\* `09e_prosodia.py` usaba librosa del entorno de Applio; corre igual en `.venv`.

Los pasos 5 y 8 se lanzan aparte, como procesos independientes, para que
sigan si se cierra la consola. Se pueden volver a lanzar: siguen donde quedaron.

`11a_datos_qwen.py` arma `datos\11_qwen\validacion.jsonl`, las 10 frases de
validación, a partir de `09d_comparar.py`. Los pasos de entrenamiento la
reusan para que todas las rondas se midan igual.

`14_velocidad.py`, `14b_rapido.py` y `14c_ruido_bf16.py` midieron la velocidad
de Qwen y comprobaron que las optimizaciones de Read Aloud no cambian el
cálculo. No hacen falta para entrenar.

## Lo que hay que cambiar para otra voz

| Dónde | Qué |
|---|---|
| `lote.py`, `ORIGENES` | Carpetas donde caen las grabaciones |
| `22_textos.py`, `CONTEXTO` y `VARIANTES` | Los nombres propios, como se escriben en las correcciones: guían a los dos transcriptores |
| `30_seleccion_final.py`, `DUPLICADOS` | Capítulos descargados dos veces |
| `09d_comparar.py`, `PIPER` | La carpeta de Piper de Read Aloud, para la voz de comparación |
| `14b_rapido.py` y `14c_ruido_bf16.py` | La carpeta `lib` de Read Aloud, de donde importan `qwen_rapido` |
| Los nombres de la voz en las carpetas de datos | Se pueden dejar: son solo nombres |

## Marca de la tarjeta ocupada

Los pasos que usan la tarjeta llaman a `gpu.ocupar()`, que deja el archivo
`gpu_ocupada` en la carpeta de trabajo. Mientras está, Read Aloud lee con
Piper y la voz de Qwen le deja la tarjeta entera. Ver la
[ADR 0005](../../docs/adr/0005-motor-automatico-y-tarjeta-compartida.md).
