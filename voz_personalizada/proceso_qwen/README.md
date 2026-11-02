# Proceso con Qwen3-TTS

Son los scripts con que se hizo la voz de prueba entre octubre y noviembre
de 2026, generalizados para cualquier voz: lo que cambia de una a otra sale de
`voz.toml`, en la carpeta de trabajo, a través de `voz.py`. La explicación de
cada paso y por qué está en
[docs/voz-personalizada.md](../../docs/voz-personalizada.md), y las decisiones
grandes en [docs/adr/](../../docs/adr).

## Cómo se corren

Cada script calcula la carpeta de trabajo como la carpeta padre de la suya.
`instalar.ps1` copia esta carpeta a `<trabajo>\scripts` (solo los archivos que
falten, para no pisar uno que hayas editado) y crea `voz.toml`. Los pasos se
corren desde `<trabajo>`, cada uno con su entorno:

```powershell
cd D:\voces\mi_voz
.\.venv\Scripts\python.exe scripts\lote.py
```

## Orden

| Paso | Script | Entorno | Qué hace |
|---|---|---|---|
| 1 | `lote.py` | `.venv` | Extrae el audio de cada capítulo, separa la voz (`02`), transcribe (`03`, Whisper en la tarjeta a media precisión), alinea las palabras (`03b`) y calcula las huellas de WavLM (`24`). Va sumando las descargas que terminan y muestra el avance en `progreso.html` |
| 2 | `04a_calibrar.py`, `04_cortar.py` y `voz_personalizada\scripts\05_revision.py` | `.venv` | La primera revisión: cortes por parecido con la referencia (ECAPA), para que el reconocedor aprenda de tus decisiones |
| 3 | `21_hablante.py` (opcional) y `24_curva_wavlm.py` | `.venv` | Compara formas de reconocer la voz y, sin argumentos, entrena el clasificador de quién habla con esas decisiones |
| 4 | `25_cortar_frases.py` | `.venv` | Corta cada capítulo en clips de frases completas de la voz |
| 5 | `29_preparar_revision.py` | `.venv` (lanza los demás) | Puntúa la calidad de cada clip (`26`), lo transcribe con Qwen3-ASR y Whisper (`27`) y arma la página de revisión (`28`) |
| 6 | La página `datos\28_revision\revision.html` | navegador | Revisión única: conservar o descartar y corregir el texto. Se exporta `revision.json` |
| 7 | `30_seleccion_final.py` | `.venv` | Quita duplicados, clips cortos y tomas de más, aparta las 10 frases de validación si aún no las hay, y deja los mejores minutos |
| 8 | `32_entrenar_final.py` | `.venv` (lanza los demás) | Quita el eco, iguala el volumen y saca los códigos de Qwen (`31`), y entrena (`11b`) con los mejores minutos y con todo lo conservado |
| 9 | `11c_probar_qwen.py`, `10c_medir.py`, `13_comparar.py` | `.venv_qwen`, `.venv` | Genera las frases de validación con cada época, mide timbre y errores de texto, y arma la comparación con la voz real |
| 10 | `34_votacion.py` | `.venv` (lanza los demás) | Para decidir entre voces parecidas: dos tomas por voz de 20 frases (las 10 de validación y 10 como las de la app, preparadas por `34_frases.ps1` igual que en Read Aloud), errores de lectura y timbre medidos, y votación a ciegas en `datos\34_votacion\votar.html` |
| — | `33_ronda5.py` (opcional) | `.venv` (lanza los demás) | Más entrenamientos para afinar: menos minutos (`31_conjunto_qwen.py mejores 45`) y aprendizaje más lento, con un punto a mitad de cada época |

Los pasos 5, 8 y 10 se lanzan aparte, como procesos independientes, para que
sigan si se cierra la consola. Se pueden volver a lanzar: siguen donde
quedaron.

## Lo que sale de voz.toml

| Campo | Lo usa | Para qué |
|---|---|---|
| `nombre` | `11c`, `13`, `28`, `34`, `06` | El hablante en el modelo, los nombres de las versiones (`qwen_<nombre>_e02`) y lo que guardan las páginas en el navegador |
| `titulo` | las páginas y `progreso.html` | Cómo se llama la voz en pantalla |
| `idioma` | `03`, `03b`, `11b`, `11c`, `22`, `27`, `31` | Whisper, el alineador, la marca de idioma de Qwen3-TTS y Qwen3-ASR |
| `origenes` u `origen`, `filtro_nombre`, `patron_episodio` | `lote.py` | Dónde caen las grabaciones, cuáles tomar y cómo numerarlas |
| `contexto`, `variantes` | `22`, `27`, `28` | Los nombres propios que guían a los transcriptores |
| `duplicados` | `30` | Episodios descargados dos veces |
| `minutos_finales` | `28`, `30`, `31`, `32` | Cuántos minutos de voz, los mejores, se entrenan |
| `lector` | `34`, `14b`, `14c` | La carpeta de Read Aloud, de donde salen `qwen_rapido` y la preparación del texto |

Los experimentos guardan sus opciones arriba de todo, como constantes, y hay
que cambiarlas en cada uso: `VOCES` y `FRASES_APP` en `34_votacion.py`;
`ENTRENAMIENTOS` y `APP` en `33_ronda5.py`.

## De la primera voz

Estos sirvieron con la voz de prueba y no hacen falta para una voz nueva:

- `09d_comparar.py`, `09e_prosodia.py` y `11a_datos_qwen.py` armaron las
  frases de validación desde la primera versión del proceso, con RVC. Ahora
  las aparta `30_seleccion_final.py`, y `31_conjunto_qwen.py` las codifica.
- `14_velocidad.py`, `14b_rapido.py` y `14c_ruido_bf16.py` midieron la
  velocidad de Qwen y comprobaron que las optimizaciones de Read Aloud no
  cambian el cálculo.
- `22_textos.py comparar` comparó los transcriptores con las correcciones
  del usuario; los demás pasos solo usan su contexto y su normalización.

Los experimentos anteriores (RVC, la comparación de motores con Chatterbox,
la primera segmentación) están en [../historia](../historia).

## Marca de la tarjeta ocupada

Los pasos que usan la tarjeta llaman a `gpu.ocupar()`, que deja el archivo
`gpu_ocupada` en la carpeta de trabajo. Mientras está, Read Aloud lee con
Piper y la voz de Qwen le deja la tarjeta entera. Las cadenas (`29`, `32`,
`33`, `34`) la ponen de principio a fin. Ver la
[ADR 0005](../../docs/adr/0005-motor-automatico-y-tarjeta-compartida.md).
