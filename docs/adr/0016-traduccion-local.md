# 0016. Traducción local en dos niveles y una prioridad para la tarjeta gráfica

- **Estado:** aceptada e implementada en la versión 1.4.0 (ver
  [Implementación](#implementación-en-la-140)).
- **Fecha:** 26 de noviembre de 2026; implementación, 27 y 28 de noviembre

## Contexto

La traducción rápida traduce lo seleccionado y lo lee con la voz del idioma de
destino. Tiene que funcionar sin cuentas, claves ni conexión, porque la app es
también para gente no técnica. Por eso no se usan Google Cloud, DeepL, Azure
ni el acceso no oficial de Google.

Como con las voces, hay dos niveles: uno básico que corre en cualquier equipo
y uno alto que usa un modelo de lenguaje cuando el equipo puede con él.

El problema es la memoria. En una tarjeta de 8 GB, la voz propia
([0005](0005-motor-automatico-y-tarjeta-compartida.md),
[0011](0011-recargar-qwen-y-reposo.md)) ocupa unos 4.5 GB en reposo y hasta
5.9 GB mientras lee. Si la tarjeta se llena, el controlador de NVIDIA en
Windows no da error: pasa memoria a la RAM y todo se vuelve mucho más lento,
la voz incluida. Si falta RAM, Windows pagina al disco y pasa lo mismo.

## Candidatos

| Motor | Licencia | Descarga sin cuenta | Tamaño |
|---|---|---|---|
| Bergamot `base-memory` de Mozilla, con translateLocally | MPL 2.0 (modelos), MIT (translateLocally) | Sí, del almacenamiento de Mozilla y de GitHub | 52 MB los dos sentidos, 60 MB el programa |
| Hy-MT2 1.8B Q4_K_M (Tencent) | Apache 2.0 | Sí | 1.13 GB |
| Hy-MT2 7B Q4_K_M (Tencent) | Apache 2.0 | Sí | 4.6 GB |
| TranslateGemma 4B Q4_K_M (Google) | Condiciones de Gemma | El repositorio oficial pide cuenta; hay copias de terceros | 2.5 GB |

Bergamot corre con translateLocally, el único Bergamot ya compilado para
Windows. En su modo `-p` recibe mensajes JSON y deja el modelo cargado, igual
que Piper. Los modelos de lenguaje corren con `llama-server` de llama.cpp, sin
Python.

Se descartaron dos opciones:
- **HY-MT1.5:** su licencia excluye la Unión Europea, el Reino Unido y Corea
  del Sur, y prohíbe usar sus salidas para mejorar otros modelos.
- **Hy-MT2 en 2 y 1.25 bits:** necesitan un cambio de llama.cpp que no está
  fusionado, y habría que compilarlo.

## Calidad

Se tradujeron 20 textos variados (correos, documentación técnica, noticias,
conversación informal y modismos), mitad en español y mitad en inglés. Dos
modelos de lenguaje los evaluaron a ciegas, con las traducciones en orden
aleatorio y la misma rúbrica: exactitud, fluidez, formato y registro, cada uno
del 1 al 5.

| Motor | Juez 1 (Claude Opus) | Juez 2 (ChatGPT) |
|---|---|---|
| Hy-MT2 7B | 4.28 | 4.58 |
| TranslateGemma 4B | 4.05 | 4.40 |
| Hy-MT2 1.8B | 3.49 | 3.54 |
| Bergamot | 2.41 | 2.50 |

Los dos jueces eligen el mismo ganador en 17 de los 20 textos. Cuando
discrepan, siempre es entre el 7B y TranslateGemma.

Bergamot traduce literalmente los modismos y rompe nombres de código, como
`config.ejemplo.toml`, que pasa a `config.e.toml`. Hy-MT2 1.8B a veces invierte
el sentido de una frase. Los cuatro traducen «camión» como *truck*, cuando en
México es «autobús».

## Medidas

Equipo: RTX 5070 Laptop de 8 GB, i7-14650HX y 16 GB de RAM. Con la voz propia
cargada quedan 2.8 GB libres en la tarjeta, y la voz toma 1.4 GB más mientras
lee. El primer sonido de la voz sola, sin traducir, es de 3.1 s. Las cifras
son de textos en inglés traducidos al español.

### Con la voz propia en la tarjeta

| Traductor y dónde corre | Primer sonido (40 / 150 / 500 palabras) | 500 palabras | Voz más lenta | RAM libre mínima |
|---|---|---|---|---|
| Bergamot, procesador, 4 hilos | 4.1 / 4.7 / 6.6 s | 0.6 s | no se nota | 3.2 GB |
| Bergamot, todos los hilos | 4.6 / 4.0 / 7.0 s | 0.8 s | +55 % | 2.8 GB |
| Hy-MT2 1.8B, procesador, 4 hilos | 3.5 / 5.2 / 3.9 s | 35 s (33 tok/s) | +4 % | 3.7 GB |
| Hy-MT2 1.8B, procesador, 8 hilos | 4.3 / 9.1 / 7.7 s | 28 s | +130 % | 3.3 GB |
| Hy-MT2 1.8B, 13 de 32 capas en la tarjeta, 4 hilos | 2.9 / 4.8 / 3.5 s | 19 s | +12 % | 2.6 GB |
| TranslateGemma 4B, procesador, 4 hilos | 5.5 / 7.1 / 5.3 s | 65 s | +6 % | 1.3 GB |
| Hy-MT2 7B, procesador, 8 hilos | 8.6 / 14.4 / 10.3 s | 97 s | +142 % | 0.4 GB |
| Cualquiera, por turnos (la voz cede y vuelve) | 25 a 42 s | | | |

Ningún modelo de lenguaje entero cabe en la tarjeta junto a la voz con el
margen de 600 MiB. Lo que frena la voz es el procesador ocupado, no la
tarjeta compartida: con 8 hilos va un 130 % más lenta y con 4, solo un 4 %.

### Con la tarjeta para el traductor y la lectura con Piper

| Traductor | Cambiar a este modo | Primer sonido (40 / 150 / 500) | 500 palabras | Tarjeta | Volver a la voz propia |
|---|---|---|---|---|---|
| Hy-MT2 7B, Vulkan | 5.7 s | 0.7 / 1.1 / 0.6 s | 14 s | 5.2 GB | 17.6 s |
| Hy-MT2 7B, CUDA | 3.8 s | 0.6 / 1.1 / 0.6 s | 13 s | 4.9 GB | 18.0 s |
| TranslateGemma 4B, Vulkan | 4.0 s | 0.7 / 0.9 / 0.5 s | 8 s | 2.9 GB | 18.4 s |

### Otras medidas

- **Vulkan frente a CUDA,** con el traductor solo en la tarjeta: Hy-MT2 1.8B
  hace 133 tok/s con Vulkan y 210 con CUDA; el 7B, 58 a 67 con Vulkan y 52 a
  70 con CUDA. La versión Vulkan de llama.cpp pesa 39 MB, y la de CUDA, 654 MB
  con sus librerías. La de Vulkan en modo procesador (`--device none`) rindió
  igual que la versión solo para procesador.
- **Gráficos Intel integrados:** 8.9 tok/s, cuatro veces menos que el
  procesador.
- **En equipos sin NVIDIA** (traductor en el procesador y lectura con Piper):
  con Bergamot, el primer sonido llega en 0.6 a 1.8 s, y con Hy-MT2 1.8B, en
  1.0 a 4.0 s.
- **La voz propia** queda en 7.0 GB después de leer si PyTorch no suelta su
  caché. Con `torch.cuda.empty_cache()` tras cada grupo vuelve a 5.0 GB, a la
  misma velocidad (factor 0.44 en los dos casos).
- **Un modelo GGUF en el procesador** ocupa en la RAM alrededor de 1.25 veces
  el archivo.

## Decisión

- **Básico: Bergamot con translateLocally.** Usa 4 hilos, que translateLocally
  lee de su clave en `HKCU\Software\translateLocally`. Los modelos van en una
  carpeta `models` junto al programa. Traduce el texto entero de una vez.
- **Alto: `llama-server` de la versión Vulkan de llama.cpp.** Una sola
  descarga sirve para la tarjeta de cualquier marca y para el procesador.
  - **Hy-MT2 1.8B** se descarga por defecto si el equipo puede usarlo, y corre
    en el procesador junto a la voz propia.
  - **Hy-MT2 7B** se ofrece si el equipo puede usarlo, para la prioridad de
    traducción.
  - **TranslateGemma y modelos mayores** son una opción manual para
    desarrolladores, documentada como la voz propia.
- **Prioridad de la tarjeta:** Automática (predeterminada), Voz propia o
  Traducción. Solo aparece cuando la voz propia y el mejor traductor no caben
  juntos.
  - **Voz propia:** la voz se queda cargada. Se traduce con lo mejor que quepa
    a su lado; en este equipo, Hy-MT2 1.8B en el procesador.
  - **Traducción:** la voz propia cede la tarjeta y se lee con Piper. El
    traductor grande se queda cargado hasta volver a la voz propia, igual que
    cuando la tarjeta la pide un juego.
  - **Automática:** de las combinaciones que caben en ese momento, elige la
    más equilibrada entre la calidad de la traducción y la de la voz, con
    penalización por el tiempo hasta el primer sonido y por cuánto se frena la
    voz. Las notas de calidad salen de esta evaluación; los tiempos, del perfil
    del equipo. En este equipo coincide con Voz propia.
  - **Vuelta a la voz propia:** lo que más se usa es leer con la voz propia, y
    la traducción solo cuando se estudia. Por eso, con Traducción, o con
    Automática si eligió una combinación sin la voz propia, se vuelve sola a
    Voz propia tras unos minutos sin traducir. Es una opción propia en
    Ajustes, «Volver sola a la voz propia» (`TranslateAutoReturn`, activada por
    defecto), con los minutos aparte (`TranslateReturnMinutes`, 15), que solo se
    pueden cambiar con la opción activada. Quien la desactiva deja la prioridad
    fija donde la puso. Nunca vuelve a mitad de una lectura. El reproductor
    lo avisa, y el cambio se puede hacer también a mano desde el reproductor
    y la bandeja. Volver cuesta unos 18 s, que la voz carga en segundo plano.
- **Medir el equipo:** una prueba opcional de 3 a 5 minutos, en Ajustes y
  como tarea desmarcada del instalador. Mide cada combinación que cabe y
  guarda el perfil en `runtime\perfil_equipo.json`. Sin perfil, se usan las
  reglas de abajo con las cifras de este ADR.
- **Antes de cargar un modelo:**
  - en la tarjeta: memoria libre, menos lo que la voz toma al leer, igual o
    mayor que el modelo, su caché y 400 MiB de cálculo, más 600 MiB de margen;
  - en el procesador: RAM disponible igual o mayor que 1.25 veces el archivo,
    más 1.5 GB.
  Si no cabe, se usa la siguiente opción más ligera y se anota en
  `daemon.log`.
- **Hilos del traductor:** `min(4, núcleos físicos / 2)`.
- **Traducción por partes con los modelos de lenguaje:** primero la primera
  frase, para que suene pronto, y después párrafo por párrafo. Bergamot no lo
  necesita.
- **La voz propia suelta la caché de PyTorch tras cada grupo** de frases.
- **Reutilizar lo ya hecho:**
  - **El audio.** Hoy cada frase se genera en un WAV de `tmp` que se borra al
    terminar la lectura, y repetir el mismo texto obliga a generarlo otra vez:
    con la voz propia, 1 a 2 minutos de tarjeta para 500 palabras. Cada WAV se
    guarda antes de pegarle la pausa del final del bloque, porque esa pausa
    depende del lugar de la frase. La clave es el motor, la voz, el idioma, el
    texto y los ajustes que cambian el sonido (velocidad, variación, silencio).
    Se guarda `AudioCacheMinutes` (10 por defecto) y con un tope de espacio. Va
    en disco y no en la RAM: copiar un archivo cuesta milisegundos, y la RAM es
    lo que más escasea. Como va por frases, también sirve al releer solo una
    parte de algo ya leído.
  - **La traducción.** Se guarda con la clave del texto, la dirección y el
    modelo, para no traducir dos veces lo mismo.

## Alternativas

- **Por turnos en cada traducción:** recargar la voz cuesta de 18 a 22 s cada
  vez.
- **Repartir las capas entre tarjeta y procesador:** frena la voz entre un 12
  y un 32 % y gana poco tiempo.
- **Más hilos:** traducen un poco más rápido y frenan mucho la voz.
- **CUDA en vez de Vulkan:** 615 MB más de descarga, por una velocidad que no
  hace falta.
- **Entrenar la voz propia sobre Qwen3-TTS 0.6B,** que dejaría unos 2 GB
  libres en la tarjeta. Queda para más adelante.

## Consecuencias

- **Descargas:** el nivel básico, 112 MB; el alto, 1.17 GB, más 4.6 GB del 7B
  si el equipo puede usarlo.
- **Rastros de translateLocally:** deja su clave en
  `HKCU\Software\translateLocally` y una carpeta vacía en
  `%APPDATA%\translateLocally`. Al desinstalar se borran.
- **En la prioridad de traducción,** la lectura suena antes que con la voz
  propia, pero con la voz de Piper. Volver a la voz propia tarda unos 18 s.
- **Las notas de calidad** son de dos jueces automáticos sobre 20 textos.
  Sirven para ordenar los motores, no como una medida exacta.

## Implementación en la 1.4.0

Lo que se decidió al implementar, y lo que se midió en el lector, en el mismo
equipo. El uso está en [docs/traduccion.md](../traduccion.md) y el
funcionamiento, en [docs/como-funciona.md](../como-funciona.md#la-traducción).

**Decisiones**

- **La nota de cada combinación,** para Automática: la calidad de la
  traducción (la media de los dos jueces) más la de la voz, con 5 para la voz
  propia y 2,5 para Piper en la misma escala; menos 0,3 por cada segundo de
  primer sonido por encima de 1 s, y menos 2 por cada vez que se frena la voz
  (1,0 es el doble de lenta). La voz no se midió con jueces: la propia es la que
  el usuario eligió de oído. En este equipo da 7,6 a la voz propia con Hy-MT2
  1.8B en el procesador y 6,9 a Piper con el 7B en la tarjeta; con Piper en 3,
  la diferencia sería de 0,1 y dependería del ruido de las medidas.
- **Lo que se guarda:** las traducciones, en la memoria del proceso residente
  (pesan unos KB y así el texto no queda en el disco); el audio de cada frase,
  en `tmp\cache`, con un tope de 300 MB. Los dos caducan a los 10 minutos sin
  usarse.
- **translateLocally** solo publica una versión de prueba con la etiqueta
  `latest`. Su sha256 queda fijo en `config/traduccion.psd1`; si un día no
  coincide, la instalación lo dice y sigue sin la traducción básica.
- **La prioridad «Traducción» se llama «Traductor»** en el panel de ajustes, y
  aparece si alguna vez la voz propia y el mejor traductor instalado no
  cupieron juntos; entonces queda a la vista toda la sesión, para no aparecer y
  desaparecer con la RAM libre.
- **El traductor que tiene la tarjeta de la voz propia** no se cierra por
  `TranslateIdleMinutes`: se queda hasta que la voz vuelve. La voz propia sabe,
  por un archivo de reserva, que esa memoria es de Read Aloud, y no cede por
  creer que la usa otro programa.
- **«Medir este equipo»** mide solo al traductor: lo que tarda cada uno que
  cabe en traducir tres frases distintas (con la misma frase, translateLocally y
  llama-server reutilizan lo anterior y la medida salía mejor: 0,59 s frente a
  0,83 s con Hy-MT2 1.8B). Al primer sonido se le suma el de la voz en la prueba
  controlada (3,1 s la propia, 0,5 s Piper), porque las combinaciones que no se
  miden usan las cifras de este ADR. Cuánto se frena la voz tampoco se mide.
  Tarda unos 5 s, no los 3 a 5 minutos previstos.
- **Al terminar de leer una traducción,** el reproductor no se cierra solo: el
  panel con la traducción y el original queda a la vista.

**Medidas en el lector (27 y 28 de noviembre)**

| Qué | Medido |
|---|---|
| Hy-MT2 1.8B en el procesador, cargar | 1,2 a 2,2 s |
| Hy-MT2 1.8B, una frase ya cargado | 0,83 s (mediana de 3) |
| Bergamot, una frase | 0,01 s |
| Inglés a español con la voz propia y el 1.8B, primer sonido | 3,1 s, con la carga del modelo |
| La voz propia cede la tarjeta | 1,5 a 3,0 s |
| Hy-MT2 7B en la tarjeta (Vulkan), cargar | 4,5 a 5,6 s; ocupa 5055 MiB |
| Hy-MT2 7B, la primera parte ya cargado | 0,46 a 0,87 s |
| Volver a la voz propia tras el reinicio del equipo | 69 s (caché del disco fría y RAM justa) |

**Lo que se aprendió**

- **El primer sonido de la voz propia en el uso diario** es mayor que en la
  prueba controlada: 7,05 s de mediana en las últimas 20 lecturas normales de
  `daemon.log` (de 2,4 a 14,5 s), frente a 3,1 s. El perfil del equipo lo
  guarda como dato, sin que cuente en la nota.
- **Volver a la voz propia** puede tardar un minuto, no 18 s, con la caché del
  disco fría. Mientras tanto se lee con Piper, así que no deja mudo al lector.
