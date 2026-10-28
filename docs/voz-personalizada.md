# Voz personalizada

Esta guía explica cómo sacar una voz concreta de grabaciones donde habla junto
a otras, como videos con varias personas, y convertirla en un conjunto de clips limpios
para entrenar un modelo de voz. Todo corre en tu equipo.

El código está en [voz_personalizada/](../voz_personalizada). Lo que pesa
(grabaciones, audio, modelos y entornos de Python) vive fuera del
repositorio, en una carpeta de trabajo por voz.

> **Estado:** documentado y probado hasta el conjunto final de entrenamiento.
> El entrenamiento, la elección del punto de control y la integración con
> Read Aloud se agregarán cuando terminen de validarse.

## Uso responsable

Clonar la voz de una persona, también cuando interpreta un papel,
solo debe hacerse con su permiso o para uso estrictamente personal. No
publiques ni compartas un modelo entrenado con una voz ajena sin
autorización.

## Cómo funciona

```
grabaciones
  → 01 extraer el audio
  → 02 separar la voz de la música y los efectos
  → 03 transcribir con tiempos por palabra
  → 03b afinar esos tiempos con alineación forzada
  → 04 medir quién habla en cada momento
  → 04a calibrar: convertir el parecido en probabilidad
  → 04 cortar clips donde solo habla la voz buscada
  → 05 revisar los clips de oído
  → 06 armar el conjunto con los que conservaste
  → 07 decidir con una prueba a ciegas si mejorarlo
  → conjunto final de entrenamiento
```

La idea central es cortar **entre palabras** y no donde hay silencio.
Cuando dos personas hablan seguido no hay silencio entre ellas, pero sí un
límite entre la última palabra de una y la primera de la otra. Por eso cada
palabra se ubica con precisión de centésimas y recibe una probabilidad de ser
de la voz buscada. Un clip es una racha de palabras suyas, y sus bordes se
llevan al silencio real más cercano.

### Qué aporta el modelo y qué no

El modelo que se entrena es de conversión de voz: RVC. **Copia el timbre, no
la expresión.** La entonación, el ritmo y la emoción vienen de la voz que
recibe. Si el motor de origen lee de forma plana, la voz convertida también
sonará plana. Para una voz expresiva, el motor de origen pesa tanto como el
entrenamiento.

## Qué necesitas

- **Windows con una tarjeta NVIDIA de 8 GB o más.** Se probó en una RTX 5070
  Laptop de 8 GB, con PyTorch 2.11 y CUDA 12.8, que es lo que piden las
  NVIDIA RTX 50.
- **[uv](https://docs.astral.sh/uv/), git y git-lfs.**
- **Espacio en disco.** Unos 15 GB de entornos y modelos, más cerca de 1 GB
  por cada 20 minutos de grabación.
- **Grabaciones con mucha presencia de la voz.** Como referencia: 22 capítulos
  de 22 minutos, donde la voz era la voz, dieron 31 minutos de
  candidatos y 20 minutos tras la revisión. Una voz secundaria pide muchas
  más grabaciones.
- **Una referencia de la voz.** Uno o varios WAV con solo esa voz, unos
  minutos en total, sacados de escenas limpias. Sirven para reconocerla. Cuanto
  más variados sean el tono y la emoción, mejor la reconoce en todos sus
  registros.

## 1. Instalar

```powershell
.\voz_personalizada\instalar.ps1 -Trabajo D:\voces\mi_voz
```

Crea la carpeta de trabajo con tres entornos de Python, todos con las versiones
exactas de [voz_personalizada/requisitos/](../voz_personalizada/requisitos):

| Entorno | Para qué |
|---|---|
| `.venv` | Separación, transcripción, alineación y cortes |
| `.venv_mejora` | La prueba de resemble-enhance, que no funciona con las librerías actuales |
| `applio\.venv` | El entrenamiento, con [Applio](https://github.com/IAHispano/Applio) en una versión fija |

Nada se instala fuera de la carpeta de trabajo. Los modelos que faltan se
descargan la primera vez que cada paso los usa, y quedan en `modelos\`.

## 2. Configurar

Edita `voz.toml` en la carpeta de trabajo; el instalador lo crea a partir de
[voz.ejemplo.toml](../voz_personalizada/voz.ejemplo.toml):

| Valor | Qué es |
|---|---|
| `nombre` | Nombre corto, sin espacios |
| `idioma` | Idioma de las grabaciones, en dos letras: `es`, `en`... |
| `origen` | Carpeta con las grabaciones, videos o audios |
| `patron_episodio` | Cómo sacar el número de cada archivo; por defecto, el primer número del nombre |
| `alineador` | Solo para idiomas que no estén en `comun.py` |

Cada grabación recibe un identificador fijo por su número, `ep01`, `ep02`...
Así se pueden agregar grabaciones después sin desordenar lo ya hecho.

Pon la referencia en `referencias\original\`.

## 3. Preparar las grabaciones

Todos los pasos se corren desde la carpeta de trabajo:

```powershell
cd D:\voces\mi_voz
$s = 'C:\ruta\a\read_aloud\voz_personalizada\scripts'
.\.venv\Scripts\python.exe $s\02_separar_voz.py referencias
.\.venv\Scripts\python.exe $s\lote.py
```

El primero separa la voz de la referencia. Pasa por el mismo separador que
las grabaciones: si no, sus huellas tendrían restos de música que los clips ya
no tienen, y se compararían cosas distintas.

`lote.py` lleva cada grabación por los pasos 01 a 04: extraer, separar,
transcribir, alinear y medir quién habla. Reparte el trabajo: la tarjeta
gráfica separa y alinea mientras el procesador transcribe, así ninguno espera
al otro. El avance se ve en `progreso.html`, que se recarga solo.

Si mientras corre llegan más grabaciones a la carpeta de origen, las suma. No
termina mientras haya una descarga de Chrome a medias.

**Tiempo:** la transcripción manda, con casi un minuto por cada minuto de
audio. Para 22 capítulos de 22 minutos, unas 8 horas.

Cada paso también se puede correr suelto, para una sola grabación o para
todas: `01_extraer.py ep03`, `03_transcribir.py`...

## 4. Calibrar y cortar

```powershell
.\.venv\Scripts\python.exe $s\04a_calibrar.py
.\.venv\Scripts\python.exe $s\04_cortar.py
```

`04a_calibrar.py` convierte el parecido con la referencia en una probabilidad.
Ajusta tres campanas a todas las ventanas de audio: dos para el resto de voces
y una para la voz buscada. Revisa lo que imprime:

- **El peso de la voz buscada.** Fue del 18 % al 22 % con una voz que habla mucho.
  Por debajo del 5 % habla demasiado poco para separarla bien.
- **Los umbrales.** Conviene recalibrar cada vez que se suman grabaciones. Con
  más datos el ajuste es más fiable.

`04_cortar.py` arma los clips con estas reglas:

- Las palabras con más del 70 % de probabilidad son de la voz. Las de menos
  del 30 % cortan el clip. Las intermedias se aceptan solo rodeadas de
  palabras seguras: suele ser la misma voz gritando o susurrando.
- Una pausa de más de 0,6 s separa dos clips.
- Un clip dura de 1 a 12 s. Un tramo largo se parte por su pausa más larga,
  nunca a mitad de frase.
- **Cada borde cae en un silencio real**, al menos 25 dB por debajo del habla
  del propio clip. Si no hay silencio cerca, se suelta la palabra del extremo
  y se prueba con la siguiente.
- Al final, la huella de voz del clip entero tiene que confirmar que es la voz
  buscada.

Cada clip se nombra por su instante de inicio, como `ep04_052310.wav`. Así
conserva su nombre, y su decisión en la revisión, si se vuelve a cortar con
otra calibración.

## 5. Revisar

```powershell
.\.venv\Scripts\python.exe $s\05_revision.py
```

Abre `datos\05_revision\revision.html` en el navegador. Los clips vienen
ordenados de más a menos confianza, y cada uno suena al llegar a él:

| Tecla | Acción |
|---|---|
| `1` o `Enter` | Conservar |
| `2` o `Supr` | Descartar |
| `Espacio` | Repetir |
| `Z` | Deshacer |
| Flechas | Moverse sin decidir |

Las decisiones se guardan solas en el navegador. Al terminar, **Exportar**
descarga `decisiones.json`.

Qué descartar y qué no:

- **Descarta** el clip si se oye otra voz, aunque sea de fondo o breve, o si
  hay música o efectos encima. También si suena distorsionado o metálico, o
  si tiene eco marcado, como recuerdos, sueños o gimnasios. El modelo aprende
  como parte de la voz todo lo que hay en el clip.
- **Consérvalo** aunque la transcripción esté mal: RVC no usa el texto. Pero
  un texto muy errado merece una escucha atenta, porque a veces Whisper se
  equivoca porque hay algo más en el clip.
- **Consérvalo** aunque la primera o la última palabra estén cortadas, si el
  resto está limpio. Si pasa seguido, es un problema del corte; ver
  [Problemas conocidos](#problemas-conocidos).
- **Consérvalo** si solo tiene el ambiente normal de una habitación.

## 6. Armar el conjunto

```powershell
.\.venv\Scripts\python.exe $s\06_conjunto.py
```

Toma `decisiones.json` de `datos\05_revision\` o, si no está, el más reciente
de Descargas. Copia los clips conservados a `datos\06_conjunto\<nombre>` con
un tratamiento mínimo:

- recorta el silencio de los extremos, dejando 60 ms;
- iguala el volumen;
- limita los picos a −1 dB.

No aplica reducción de ruido ni ecualización.

## 7. Decidir la mejora con una prueba a ciegas

```powershell
.\.venv\Scripts\python.exe $s\07a_sin_reverb.py
.\.venv_mejora\Scripts\python.exe $s\07b_prueba.py
```

`07a_sin_reverb.py` quita la reverberación de todos los clips y mide cuánta
tenía cada uno. `07b_prueba.py` elige ocho clips, empezando por los de más eco,
y arma cuatro versiones de cada uno:

- original;
- sin reverberación;
- con resemble-enhance;
- con las dos cosas.

Todas van al mismo volumen y con letras al azar. Se escuchan en
`datos\07_mejora\prueba\prueba.html`. Para cada clip se marca la mejor y las
que suenan artificiales. La clave está en `clave.json`.

La primera vez que se hizo este proceso ganó **solo quitar la reverberación**:

- nunca sonó artificial;
- fue la mejor en cuatro de los seis clips donde hubo preferencia.

resemble-enhance sonó artificial en una de cada cuatro pruebas. Eso pesa
mucho, porque el modelo aprendería esos defectos. Por eso
`07c_conjunto_final.py` arma el conjunto con los clips sin reverberación:

```powershell
.\.venv\Scripts\python.exe $s\07c_conjunto_final.py
```

El resultado queda en `datos\08_final\<nombre>`. Con otra voz conviene repetir
la prueba. Si gana otra versión, se cambia la carpeta de entrada de
`07c_conjunto_final.py`.

## 8. Entrenar y usar la voz

*Pendiente de documentar.* Se agregarán:

- el entrenamiento con Applio, a precisión completa;
- la prueba a ciegas para elegir el punto de control;
- la elección del motor de origen;
- la integración con Read Aloud.

## Decisiones y por qué

| Decisión | Por qué |
|---|---|
| Separar la voz con Mel-Band RoFormer | Es el de mejor calidad medida para voces en audio-separator |
| Whisper large-v3 en el procesador, a precisión completa | En 8 GB de tarjeta casi no cabe y fue 4 veces más lento, con el mismo resultado |
| Alineación forzada con wav2vec2 | Whisper ubica las palabras con una o dos décimas de error, y en el borde de un clip eso deja entrar a otra voz |
| Huellas ECAPA en ventanas de 1,5 s cada 0,25 s | Dan una curva continua de quién habla |
| Calibración con tres campanas | El parecido no es una probabilidad: un 0,6 no significa 60 % |
| Bordes en silencio relativo al clip | Bajo la música de algunas escenas queda un resto constante de −35 a −40 dBFS, así que un umbral fijo descartaría buenos clips o aceptaría malos |
| Nombre del clip por su instante de inicio | Las decisiones de la revisión sobreviven a un nuevo corte |
| Dereverb mono de anvuew | Los modelos estéreo no hacen nada con audio mono |
| Sin resemble-enhance | Sonó artificial en la prueba a ciegas |

## Problemas conocidos

**El modelo de reverberación devuelve el audio intacto.** Los modelos estéreo
de audio-separator, aun los de mejor puntuación, no cambian un audio mono. Se
comprobó agregando un eco artificial fuerte a un clip. Usa
`dereverb_mel_band_roformer_mono_anvuew.ckpt`, que es el que usa
`07a_sin_reverb.py`.

**Whisper falla con "expected scalar type Float but found Half".** Pasa al
forzar media precisión con `.half()`. Usa precisión completa en el procesador,
que además es más rápido en tarjetas de 8 GB.

**Muchos clips empiezan o terminan con sonido.** Si al revisar notas bordes
sucios o palabras cortadas, mide la energía de los primeros y últimos 40 ms
de cada clip. Los parámetros están comentados al inicio de `04_cortar.py`:
`SNR_BORDE_DB` fija cuánto más bajo que el habla debe estar el borde, y
`SILENCIO_MIN_S` el silencio mínimo. Un silencio mínimo de unos 120 ms evita
confundirlo con el cierre de una consonante como la "t" o la "p".

**resemble-enhance no carga.** Es de 2023 y choca con las librerías actuales
de cuatro maneras, que `07b_prueba.py` resuelve sin tocar el paquete:

- importa deepspeed, que en Windows no se instala con facilidad y que solo
  usa para entrenar; el script registra módulos vacíos con esos nombres;
- su configuración trae rutas de Linux, que se cambian por rutas de Windows;
- necesita NumPy 1.26, pandas 2.2 y scipy 1.14, que es lo que fija
  `requisitos\mejora.txt`;
- sus pesos se bajan con git-lfs desde Hugging Face, y de eso se encarga el
  instalador.

**Applio entrena en media precisión.** Lo hace por defecto, y guarda su
configuración en `%APPDATA%\Applio`. El instalador crea
`applio\configuracion_voz.json`, que pide precisión completa. Para usarlo,
define `APPLIO_CONFIG_FILE` con esa ruta antes de entrenar.

**Applio no guarda los modelos de cada punto de control.** En la versión fija,
la opción `--save-every-weights` viene activada por defecto, y pasarla la
apaga. No la pases. Y si usas `--save-only-latest`, cada punto completo pisa
al anterior, así que solo queda el último.

**El entrenamiento se cae con "CUDA error: out of memory".** Pasa si otro
proceso usa la tarjeta mientras se entrena, aunque sea poco. Con 8 GB, el
entrenamiento a precisión completa la ocupa casi entera. No corras pasos que
la usen mientras tanto: separar, alinear, quitar la reverberación. Ocultar la
tarjeta con `CUDA_VISIBLE_DEVICES` no basta para audio-separator. Si se cae,
se retoma desde el último punto completo, `G_*.pth` y `D_*.pth`, volviendo a
lanzar el entrenamiento sin `--cleanup`.

**El proceso de un paso no termina al cerrarlo.** Al buscar procesos para
detenerlos, filtra por el nombre `python.exe` y por el script concreto. Un
filtro amplio puede cerrar la consola desde la que trabajas.

## Limpieza

Al terminar, lo único que vale la pena conservar es el conjunto final y el
modelo entrenado. Los entornos y los modelos se pueden borrar:

```powershell
Remove-Item -Recurse -Force D:\voces\mi_voz\.venv, D:\voces\mi_voz\.venv_mejora, D:\voces\mi_voz\applio\.venv
Remove-Item -Recurse -Force D:\voces\mi_voz\modelos, D:\voces\mi_voz\herramientas
```

Para repetir el proceso, el instalador los vuelve a crear iguales.

## Carpeta de trabajo

```
voz.toml                  Configuracion de la voz
referencias\original\     La referencia, tal cual
referencias\              La referencia con la voz separada
datos\01_audio\           Audio de cada grabacion
datos\02_voz\             Voz separada
datos\03_transcripcion\   Palabras con sus tiempos, segun Whisper
datos\03_alineado\        Los mismos tiempos, afinados
datos\04_curvas\          Quien habla en cada momento, y la calibracion
datos\04_cortes\          Clips candidatos e indice de cada grabacion
datos\05_revision\        Pagina de revision y decisiones
datos\06_conjunto\        Clips conservados
datos\07_mejora\          Clips sin reverberacion y prueba a ciegas
datos\08_final\           Conjunto final de entrenamiento
progreso.html             Avance del lote
modelos\                  Modelos descargados
herramientas\             ffmpeg
.venv\, .venv_mejora\     Entornos de Python
applio\                   Applio y su entorno
```
