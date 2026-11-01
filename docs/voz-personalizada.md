# Voz personalizada

Esta guía explica cómo sacar una voz concreta de grabaciones donde habla junto
a otras, como videos con varias personas, entrenar con ella un modelo de texto a voz y
leer con esa voz en Read Aloud. Todo corre en tu equipo.

El código está en [voz_personalizada/](../voz_personalizada). Lo que pesa
(grabaciones, audio, modelos y entornos de Python) vive fuera del
repositorio, en una carpeta de trabajo por voz. Por qué el proceso es así está
en el [registro de decisiones](adr/README.md).

> **Estado:** probado de punta a punta con una voz, la de la voz de prueba de las grabaciones
> es_mx: 70 capítulos, 1438 clips revisados de oído y una voz que Read Aloud
> ya usa. Falta comparar a ciegas los dos últimos entrenamientos (ver la
> [ADR 0010](adr/0010-conjunto-final.md)) y generalizar los scripts de
> [proceso_qwen/](../voz_personalizada/proceso_qwen), que todavía traen
> fijas algunas cosas de esa voz.

## Uso responsable

Clonar la voz de una persona, también cuando interpreta un papel,
solo debe hacerse con su permiso o para uso estrictamente personal. No
publiques ni compartas un modelo ni un conjunto de datos hechos con una voz
ajena sin autorización.

## Cómo funciona

```
grabaciones
  → separar la voz de la música y los efectos         Mel-Band RoFormer
  → transcribir con tiempos por palabra               Whisper large-v3
  → afinar esos tiempos con alineación forzada        wav2vec2
  → saber quién habla en cada momento                 WavLM Large + tus decisiones
  → cortar clips de frases completas
  → medir la calidad y transcribir cada clip dos veces   SQUIM, Whisper y Qwen3-ASR
  → revisarlos de oído en una sola pasada, con su texto
  → quedarse con los mejores 60 minutos, sin eco y nivelados
  → entrenar Qwen3-TTS con LoRA y elegir la época a ciegas
  → leer con esa voz en Read Aloud
```

Dos ideas lo atraviesan:

- **El modelo aprende todo lo que hay en el clip:** el timbre, pero también la
  entonación, las pausas, el ruido y los errores del texto. Por eso cada clip
  es una frase completa, limpia y con su texto exacto.
- **Tú eres el filtro final.** Las medidas ordenan y avisan; las decisiones
  de oído deciden. Y las primeras decisiones entrenan el reconocedor de la voz.

## Qué necesitas

- **Windows con una tarjeta NVIDIA de 8 GB o más.** Se probó en una RTX 5070
  Laptop de 8 GB, con PyTorch 2.11 y CUDA 12.8, que es lo que piden las
  NVIDIA RTX 50.
- **[uv](https://docs.astral.sh/uv/).** Y git con git-lfs si vas a instalar
  las herramientas de la primera versión (`-ConRvc`, `-ConMejora`).
- **Espacio en disco:** unos 25 GB de entornos y modelos, y cerca de 1 GB por
  capítulo de 25 minutos mientras se procesa.
- **Muchas grabaciones de la voz.** Como referencia: con una voz que habla mucho, cada
  capítulo de 25 minutos dio 1.4 minutos de candidatos y algo más de 1 minuto
  conservado tras la revisión. Para una hora de voz hicieron falta los 70
  capítulos de las grabaciones.
- **Una referencia de la voz:** uno o varios WAV con solo esa voz, unos
  minutos, sacados de escenas limpias. Sirve para la primera revisión.

## 1. Instalar

```powershell
.\voz_personalizada\instalar.ps1 -Trabajo D:\voces\mi_voz
```

Crea la carpeta de trabajo con tres entornos de Python, todos con las
versiones exactas de [voz_personalizada/requisitos/](../voz_personalizada/requisitos)
y el sha256 de cada paquete. El instalador no acepta un paquete que no
coincida con lo que se probó.

| Entorno | Lista | Para qué |
|---|---|---|
| `.venv` | `principal.txt` | Separar, transcribir, alinear, reconocer la voz, cortar y medir |
| `.venv_qwen` | `qwen.txt` | Entrenar con Qwen3-TTS, y leer con la voz en Read Aloud |
| `.venv_asr` | `asr.txt` | La segunda transcripción, con Qwen3-ASR. Va aparte porque pide otra versión de transformers |

También baja a `modelos\hf` los modelos de Hugging Face que se usan sin
conexión: Qwen3-TTS 12Hz 1.7B Base, su tokenizador de audio y Qwen3-ASR 1.7B.
El resto (Whisper, WavLM, wav2vec2, los separadores) se baja la primera vez
que cada paso lo usa, también dentro de `modelos\`.

Nada se instala fuera de la carpeta de trabajo, tampoco Python: los entornos
usan uno propio de uv, en `herramientas\python`.

Otras formas:

| Opción | Qué instala |
|---|---|
| `-SoloLectura` | Solo lo que Read Aloud necesita para leer con una voz ya entrenada: `.venv_qwen` y el modelo base, unos 9 GB |
| `-ConMejora` | Además resemble-enhance, para repetir la prueba a ciegas de la [ADR 0009](adr/0009-limpieza-del-audio.md) |
| `-ConRvc` | Además Applio, para la primera versión, con RVC |

## 2. Preparar la carpeta de trabajo

Copia los scripts del proceso a la carpeta de trabajo y corre todo desde ahí:

```powershell
cd D:\voces\mi_voz
Copy-Item C:\ruta\a\read_aloud\voz_personalizada\proceso_qwen\* .\scripts\
```

Antes de empezar, ajusta lo que es de cada voz (la tabla está en
[proceso_qwen/README.md](../voz_personalizada/proceso_qwen/README.md)): las
carpetas donde caen las grabaciones, los nombres propios de las grabaciones y los
capítulos duplicados.

Pon la referencia de la voz en `referencias\original\` y sepárala con el mismo
separador que las grabaciones:

```powershell
.\.venv\Scripts\python.exe scripts\02_separar_voz.py referencias
```

## 3. Preparar las grabaciones

```powershell
.\.venv\Scripts\python.exe scripts\lote.py
```

Lleva cada capítulo por cinco pasos: extraer el audio, separar la voz,
transcribir, alinear las palabras y calcular las huellas de voz. Todos menos
el primero usan la tarjeta, uno a la vez. Con dos a la vez no caben en 8 GB,
Windows pasa memoria a la RAM y todo va mucho más lento.

- **Cada capítulo recibe un identificador fijo** por el número de su nombre:
  `ep01`, `ep02`... Entiende "Episode 22", "capítulo 1" y "42 - titulo...". Así
  se pueden agregar capítulos después sin desordenar lo hecho.
- **Suma las descargas que terminan mientras corre.** Chrome guarda una
  descarga a medias como `.crdownload`; un `.mp4` ya está entero. Antes de
  extraer cada video lo busca de nuevo, por si lo moviste de carpeta.
- **El avance se ve en `progreso.html`**, que se recarga solo cada 15 s.
- **Tiempo:** unos 6 minutos por capítulo; 70 capítulos, unas 8 horas.

Mientras corre, Read Aloud lee con Piper (ver
[Read Aloud y la tarjeta](#read-aloud-y-la-tarjeta)).

## 4. La primera revisión

El reconocedor de la voz aprende de tus decisiones, así que la primera vez
hace falta una revisión con el método anterior, sobre unos 20 capítulos:

```powershell
.\.venv\Scripts\python.exe scripts\04a_calibrar.py
.\.venv\Scripts\python.exe scripts\04_cortar.py
.\.venv\Scripts\python.exe C:\ruta\a\read_aloud\voz_personalizada\scripts\05_revision.py
```

`04_cortar.py` compara cada momento con la referencia (huellas ECAPA) y corta
clips palabra por palabra. Revísalos en `datos\05_revision\revision.html`,
conservando solo los de la voz sola, y exporta `decisiones.json` a
`datos\05_revision\`. Con la voz de prueba fueron 717 clips, 516 conservados.

## 5. Saber quién habla

```powershell
.\.venv\Scripts\python.exe scripts\21_hablante.py
.\.venv\Scripts\python.exe scripts\24_curva_wavlm.py
```

`21_hablante.py` compara formas de reconocer la voz con tus decisiones, por
episodios que no vio. `24_curva_wavlm.py` entrena con ellas el clasificador
que se usa al cortar: WavLM Large, el que ganó (AUC 0.74 frente a 0.60 de las
referencias con ECAPA). Por qué, en la [ADR 0007](adr/0007-reconocer-la-voz-con-wavlm.md).

## 6. Cortar en frases completas

```powershell
.\.venv\Scripts\python.exe scripts\25_cortar_frases.py
```

Un clip son una o varias frases enteras de la voz, de hasta 15 s, con sus
bordes en silencio. Quien dice cada frase se decide con la frase entera; una
frase con un tramo de otra voz se descarta. Se quitan las canciones de entrada
y salida. Por qué, en la [ADR 0006](adr/0006-clips-de-frases-completas.md).

Cada clip se nombra por su capítulo y su instante de inicio, como
`ep04_052310.wav`.

## 7. Medir y transcribir cada clip

```powershell
Start-Process .\.venv\Scripts\python.exe scripts\29_preparar_revision.py -WindowStyle Hidden
```

Se lanza aparte, para que siga aunque se cierre la consola. Hace tres cosas,
con el avance en `progreso.html`:

1. **Mide cada clip** (`26_puntuar.py`): eco, calidad estimada (PESQ, SI-SDR y
   STOI de TorchAudio-SQUIM), sonido en las pausas, ruido en los bordes y la
   huella de voz. Con eso, un clasificador entrenado con tus decisiones da un
   puntaje: la probabilidad de que conserves el clip (AUC 0.80).
2. **Transcribe cada clip dos veces** (`27_transcribir_clips.py`), con Qwen3-ASR
   y con Whisper, los dos con los nombres propios como contexto. Ver la
   [ADR 0008](adr/0008-transcripcion.md).
3. **Arma la página de revisión** (`28_revision.py`).

Con 2094 clips tardó algo más de una hora.

## 8. Revisar en una sola pasada

Abre `datos\28_revision\revision.html` en el navegador. Los clips vienen de
más a menos probables de conservar, y cada uno suena al llegar a él.

| Tecla | Acción |
|---|---|
| `1` o `Enter` | Conservar con el texto que se ve |
| `2` o `Supr` | Descartar |
| `E` | Corregir el texto; `Enter` lo guarda y conserva el clip, `Esc` sale sin decidir |
| `Espacio` | Repetir |
| `Z` | Deshacer |
| Flechas | Moverse sin decidir |

Cada clip muestra:

- **Avisos en amarillo:** eco fuerte, sonido en las pausas, borde con ruido,
  calidad baja, otra voz posible o lecturas distintas del texto.
- **Lo que decidiste en la primera revisión**, si el clip cae sobre uno viejo.
- **Las otras lecturas del texto**, si los motores no coinciden: un clic la
  copia al texto.

Qué conservar:

- **Solo la voz sola**, sin música, efectos, eco marcado ni otra voz, aunque
  sea breve o de fondo.
- **Solo frases completas**, que empiecen y terminen enteras.
- **El texto tiene que decir exactamente lo que se oye**, con sus signos:
  ¿pregunta?, ¡exclamación!, comas donde hace una pausa. Los nombres van como
  suenan en la grabación. El modelo aprende la entonación de los signos.

Las decisiones se guardan solas en el navegador. Para cerrar y seguir otro
día, abre la misma página en el mismo navegador. Se pierden si borras los
datos del sitio o usas una ventana privada. **Exporta de vez en cuando:** el
botón descarga `revision.json`, que es lo que lee el paso siguiente. Cópialo a
`datos\28_revision\`.

## 9. Elegir el conjunto final

```powershell
.\.venv\Scripts\python.exe scripts\30_seleccion_final.py
```

De lo que conservaste quita los capítulos duplicados, los clips de menos de
1 s y las tomas de más de una misma frase, y deja los mejores 60 minutos por
calidad. Por qué y con qué medidas, en la
[ADR 0010](adr/0010-conjunto-final.md). El detalle de cada clip quitado, con
su motivo, queda en `datos\30_final\seleccion.json`.

## 10. Entrenar

```powershell
Start-Process .\.venv\Scripts\python.exe scripts\32_entrenar_final.py -WindowStyle Hidden
```

1. **Prepara el audio** (`31_conjunto_qwen.py`): quita el eco con el de-reverb
   mono de anvuew, recorta el silencio de los extremos e iguala el volumen. Ver
   la [ADR 0009](adr/0009-limpieza-del-audio.md).
2. **Saca los códigos de audio** de Qwen3-TTS de cada clip.
3. **Entrena dos voces** (`11b_entrenar_qwen.py`): con los 60 mejores minutos y
   con todo lo conservado, para comparar si el corte por calidad ayuda.

El entrenamiento es LoRA sobre Qwen3-TTS 12Hz 1.7B Base, con la receta oficial
corregida (tiene tres errores, ver la
[ADR 0002](adr/0002-lora-y-correcciones-a-la-receta.md)): aprendizaje 3e-5,
lote efectivo de 8, hasta 8 épocas. Se para antes si la validación empeora dos
épocas seguidas (`--paciencia 2`): con 60 minutos tocó fondo en la segunda y
las siguientes solo empeoraban. Ningún clip que se solape con las 10 frases de
validación entra al entrenamiento.

- **Tiempo:** unos 20 minutos por época con 60 minutos de voz.
- **Se puede cortar.** Al final de cada época se guarda todo lo necesario para
  seguir desde ahí. Si la computadora se apaga, vuelve a lanzar el mismo
  comando: salta lo hecho y sigue desde la última época.

## 11. Elegir la voz

```powershell
.\.venv_qwen\Scripts\python.exe scripts\11c_probar_qwen.py --puntos puntos_v4_60 1 2 3
.\.venv\Scripts\python.exe scripts\13_comparar.py "qwen_mi_voz_v4_60_e02=60 mejores, época 2" ...
```

`11c_probar_qwen.py` genera las 10 frases de validación, más dos en inglés,
con cada época. `09e_prosodia.py` y `10c_medir.py` miden entonación, timbre y
errores de texto. `13_comparar.py` arma la página de escucha
(`datos\13_comparar\comparar.html`). Pon solo la voz real, la voz actual de
la app y dos o tres candidatas: más versiones cansan y se distinguen peor.

La época se elige con la validación como guía y de oído como decisión final
([ADR 0003](adr/0003-elegir-la-epoca.md)). Con 20 minutos de voz y aprendizaje
3e-5, la mejor fue la segunda; con 60 minutos, la validación también tocó
fondo en la segunda.

La validación no siempre separa lo que el oído sí. Las dos voces finales, con
los 60 mejores minutos y con todo lo conservado, quedaron en 2.814 y 2.812 en
la época 2, y aun así la de 60 minutos ganó con claridad a ciegas
([ADR 0010](adr/0010-conjunto-final.md)). Es la que usa la app desde el 1 de
noviembre de 2026.

## 12. Leer con la voz en Read Aloud

Copia la época elegida a la carpeta de la voz de la app:

```powershell
$p = 'D:\voces\mi_voz\datos\11_qwen\puntos_v4_60'
$v = 'D:\voces\mi_voz\modelos\voz_app'
Copy-Item "$p\ajuste.json", "$p\voz.safetensors" $v
Copy-Item "$p\epoca_02.safetensors" "$v\lora.safetensors"
```

Y en `config\settings.psd1` de Read Aloud, apunta a la carpeta de trabajo:

```powershell
EngineEs = 'auto'
EngineEn = 'auto'
QwenWorkDir = 'D:\voces\mi_voz'
```

Reinicia el proceso residente. Con `auto`, la voz se usa si está instalada y
hay una tarjeta NVIDIA de al menos 7 GB; si no, se lee con Piper. Todos los
ajustes, en [configuracion.md](configuracion.md#voz-propia-con-qwen3-tts).

Para usar en otro equipo una voz ya entrenada, basta con
`instalar.ps1 -SoloLectura` y copiar esos tres archivos.

### Read Aloud y la tarjeta

La voz ocupa unos 5 GB de la tarjeta y se queda cargada, porque cargarla
tarda unos 20 s, y hasta un minuto si Windows no tiene las librerías en la
cache del disco. Mientras un paso pesado del proceso usa la tarjeta, deja una
marca (`gpu_ocupada`, en la carpeta de trabajo). Mientras exista, Read Aloud
lee con Piper y la voz le deja la tarjeta entera. Compartirla hacía esperar
minutos cada frase. Cuando la marca desaparece, la voz se vuelve a cargar
sola, sin esperar a la lectura siguiente. Ver las ADR
[0005](adr/0005-motor-automatico-y-tarjeta-compartida.md) y
[0011](adr/0011-recargar-qwen-y-reposo.md).

## Herramientas

| Para qué | Herramienta | Licencia |
|---|---|---|
| Separar la voz y quitar el eco | [audio-separator](https://github.com/nomadkaraoke/python-audio-separator), con Mel-Band RoFormer de voces y el de-reverb mono de anvuew | MIT el programa; cada modelo, la de su ficha |
| Transcribir | [Whisper](https://github.com/openai/whisper) large-v3 | MIT |
| Segunda transcripción | [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) 1.7B | Apache-2.0 |
| Alinear las palabras | [wav2vec2-large-xlsr-53-spanish](https://huggingface.co/jonatasgrosman/wav2vec2-large-xlsr-53-spanish) | Ver su ficha |
| Reconocer la voz | WavLM Large de [torchaudio](https://pytorch.org/audio); ECAPA de [SpeechBrain](https://speechbrain.github.io) para la primera revisión | Ver la ficha de cada modelo |
| Estimar la calidad | TorchAudio-SQUIM | Ver torchaudio |
| Modelo de voz | [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) 12Hz 1.7B Base, afinado con [PEFT](https://github.com/huggingface/peft) | Apache-2.0 |
| Entornos de Python | [uv](https://docs.astral.sh/uv/) | MIT o Apache-2.0 |

Los modelos se bajan de sus fuentes oficiales y no van en el repositorio.

## Problemas conocidos

**Un paso largo se corta al cerrar la sesión o la consola.** Lánzalo con
`Start-Process`, como en los pasos 7 y 10. Los dos siguen donde quedaron si se
vuelven a lanzar.

**El lote no encuentra capítulos en una carpeta de WSL.** El acceso a
`\\wsl.localhost` falla a veces por un rato. El lote los suma cuando la
carpeta vuelve a responder.

**Whisper falla con "expected scalar type Float but found Half".** Pasa al
pasar todo el modelo a media precisión. Las LayerNorm tienen que quedar en
float32, como hace `03_transcribir.py`. Y el modelo se pasa a media precisión
antes de llevarlo a la tarjeta: si no, quedan reservados los 6 GB de float32 y
el resto no cabe.

**El de-reverb devuelve el audio intacto.** Los modelos estéreo de
audio-separator, aun los de mejor puntuación, no cambian un audio mono. Usa
`dereverb_mel_band_roformer_mono_anvuew.ckpt`.

**El entrenamiento usa más de 8 GB.** Con 60 minutos de voz llega a 9.2 GB y
Windows pasa una parte a la memoria compartida. Va más lento, pero el
resultado es el mismo. No corras otros pasos que usen la tarjeta a la vez.

**El texto de un clip trae un nombre escrito de varias formas.** Decide una
forma, como suena en la grabación, y úsala siempre: el modelo aprende la
pronunciación de lo que lee.

**Al buscar procesos para detenerlos, filtra por el script concreto.** Un
filtro amplio por `python.exe` puede cerrar la voz de Read Aloud o la consola
desde la que trabajas.

## Limpieza

Lo que vale la pena conservar:

- **El conjunto final**, listo para cualquier modelo futuro: los audios
  limpios, su texto y su calidad. Con la voz de prueba quedó en `conjunto_mi_voz\`, con
  un `LEEME.md` que explica cómo se hizo.
- **La voz que usa Read Aloud:** `modelos\voz_app`, `.venv_qwen`,
  `modelos\hf` (el modelo base y el tokenizador) y `herramientas\python`.

Una vez elegida la voz, se puede borrar todo lo demás: `datos\01_audio` y
`datos\02_voz` (casi todo el espacio), las grabaciones originales, `.venv`,
`.venv_asr`, `modelos\whisper`, `modelos\torch` y los modelos de Qwen3-ASR,
WavLM y wav2vec2 de `modelos\hf`. Para repetir el proceso, el instalador los
vuelve a crear iguales.

## Carpeta de trabajo

```
referencias\original\     La referencia de la voz, tal cual
referencias\              La referencia con la voz separada
scripts\                  Copia de voz_personalizada\proceso_qwen
datos\01_audio\           Audio de cada capitulo
datos\02_voz\             Voz separada
datos\03_transcripcion\   Palabras con sus tiempos, segun Whisper
datos\03_alineado\        Los mismos tiempos, afinados
datos\04_cortes\          Cortes de la primera revision
datos\05_revision\        Pagina y decisiones de la primera revision
datos\08_final\           Las 10 frases de validacion (y el primer conjunto)
datos\09_comparar\        Esas frases dichas por la voz real
datos\21_hablante\        Comparacion de formas de reconocer la voz
datos\24_curvas\          Huellas de WavLM y el clasificador de quien habla
datos\25_cortes\          Clips de frases completas
datos\26_puntaje\         Medidas y puntaje de cada clip
datos\27_textos\          Las dos transcripciones de cada clip
datos\28_revision\        Pagina de revision y revision.json
datos\30_final\           La seleccion final, con el motivo de cada quitado
datos\31_final\           Los clips sin eco y nivelados
datos\31_qwen\            Los codigos de Qwen de cada conjunto
datos\11_qwen\            Validacion, referencia y cada entrenamiento
conjunto_<voz>\           El conjunto final, para conservar
progreso.html             Avance del paso en curso
gpu_ocupada               Marca de la tarjeta ocupada, mientras dura un paso
modelos\                  Modelos descargados, y voz_app, la voz de Read Aloud
herramientas\             ffmpeg y el Python de los entornos
.venv\, .venv_qwen\, .venv_asr\   Entornos de Python
```

## La primera versión

La primera voz se hizo con Piper y un modelo de conversión RVC, con los
scripts generalizados de [voz_personalizada/scripts/](../voz_personalizada/scripts),
que leen la configuración de `voz.toml`. RVC copia el timbre pero no la
entonación, que sigue siendo la de Piper, y por eso se reemplazó (ver la
[ADR 0001](adr/0001-qwen3-tts-en-vez-de-rvc.md)). Esos scripts siguen
sirviendo para la primera revisión, y con `instalar.ps1 -ConRvc` se puede
reproducir aquella versión entera.
