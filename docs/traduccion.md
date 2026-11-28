# Traducción rápida

Selecciona un texto en inglés o en español y pulsa **Ctrl+Alt+T**: Read Aloud
lo traduce al otro idioma, abre el panel con la traducción en grande y el
original en pequeño debajo, párrafo por párrafo, y lo lee con la voz del idioma
de destino. Todo corre en tu equipo: sin conexión, sin cuentas y sin enviar el
texto a ningún servidor.

La primera frase suena enseguida y el panel se llena a medida que llegan los
párrafos siguientes. Un clic en una frase sigue leyendo desde ahí, igual que en
una lectura normal.

El diseño, las mediciones y las alternativas descartadas están en el
[ADR 0016](adr/0016-traduccion-local.md).

## Cómo se usa

| Qué | Cómo |
|---|---|
| Traducir lo seleccionado | `Ctrl+Alt+T` (se cambia en Ajustes, Atajos de teclado) |
| Traducir lo que se está leyendo | El botón de idioma del reproductor, junto a `≡` |
| Copiar la traducción | El botón de copiar del reproductor, mientras se lee una traducción |
| Desde la consola | `.\read_aloud.ps1 -Translate` traduce el portapapeles |

La etiqueta del idioma del reproductor dice **EN › ES** (o **ES › EN**) mientras
se lee una traducción. Al terminar, el reproductor no se cierra solo, para que
puedas leer el panel con calma.

**Modo práctica** (Ajustes, Traducción): con un texto en inglés, lee el
original con la voz inglesa y muestra la traducción debajo, para practicar el
oído. Un texto en español se traduce y se lee en inglés, como siempre.

## Los dos niveles

| Nivel | Motor | Descarga | Cuándo |
|---|---|---|---|
| Básico | [Bergamot](https://browser.mt/) de Mozilla, con [translateLocally](https://github.com/XapaJIaMnu/translateLocally) | 112 MB | En cualquier equipo. Traduce al instante, pero literal: los modismos salen palabra por palabra. |
| Alto | [Hy-MT2 1.8B](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF) de Tencent, con [llama.cpp](https://github.com/ggml-org/llama.cpp) | 1,17 GB | Con 12 GB de RAM y un procesador con AVX2. Mucho más natural. |
| Alto, en la tarjeta | [Hy-MT2 7B](https://huggingface.co/tencent/Hy-MT2-7B-GGUF) | 4,6 GB más | Con una tarjeta gráfica de 8 GB o más. La mejor calidad. |

Con la calidad **Automática** (la de fábrica), Read Aloud elige en cada
traducción lo mejor que cabe en la memoria en ese momento. Si un traductor no
cabe, usa el siguiente más ligero y lo anota en
`read_aloud_piper\runtime\daemon.log`.

Las notas de calidad, de dos jueces automáticos a ciegas sobre 20 textos: Hy-MT2
7B 4,28 y 4,58; Hy-MT2 1.8B 3,49 y 3,54; Bergamot 2,41 y 2,50 (de 5).

## La voz propia y la tarjeta gráfica

La [voz propia](voz-personalizada.md) ocupa unos 5 GB de una tarjeta de 8 GB,
así que no cabe con el traductor grande. Si tienes los dos, los ajustes muestran
la **prioridad de la tarjeta gráfica**:

- **Voz propia:** la voz se queda. Se traduce con lo que quepa a su lado (en
  una RTX de 8 GB, Hy-MT2 1.8B en el procesador).
- **Traductor:** la voz propia cede la tarjeta al traductor grande y se lee con
  Piper. Cambiar tarda unos 5 s.
- **Automática:** elige la combinación más equilibrada entre la calidad de la
  traducción y la de la voz, el tiempo hasta el primer sonido y cuánto se frena
  la voz.

**Volver sola a la voz propia** (activada de fábrica): si la voz cedió la
tarjeta, vuelve tras unos minutos sin traducir (15 de fábrica). Nunca a mitad de
una lectura. El reproductor lo avisa, con un botón **Volver ahora**, y el icono
de la bandeja tiene **Volver a la voz propia** mientras tanto. Volver tarda de
18 s a un minuto, según lo fría que esté la caché del disco; mientras tanto se
lee con Piper.

## Medir este equipo

El botón **Medir este equipo** de los ajustes (o `.\read_aloud.ps1
-MeasureDevice`, o la tarea del instalador) mide cuánto tarda cada traductor que
cabe en tu equipo en traducir una frase, y lo guarda en
`read_aloud_piper\runtime\perfil_equipo.json`. Automática usa esas cifras en vez
de las de un equipo de referencia. Tarda unos segundos por traductor y no hace
ceder la voz propia.

## Instalación

El instalador muestra la traducción en la página de tareas, con el tamaño y la
licencia de cada parte: la básica marcada, la alta marcada si el equipo puede
usarla (si no, desmarcada y con la razón) y el 7B ofrecido si hay una tarjeta
NVIDIA de 8 GB o más.

Desde el repositorio:

```powershell
.\setup.ps1                     # la básica (y repara lo que ya estuviera)
.\setup.ps1 -TranslationHigh    # también Hy-MT2 1.8B y llama.cpp
.\setup.ps1 -Translation7B      # también Hy-MT2 7B
.\setup.ps1 -SkipTranslation    # sin traducción
.\setup.ps1 -OnlyTranslation -TranslationHigh   # solo la traducción
```

Todo se baja de su origen y se comprueba con sha256 antes de usarlo (la lista
está en [config/traduccion.psd1](../config/traduccion.psd1)); lo que no coincide
no se instala. Con `-LocalSource C:\carpeta`, setup toma los archivos de esa
carpeta (con su nombre original) en vez de bajarlos, para instalar sin
conexión. El acceso directo **Instalar o reparar las voces** del menú Inicio
también instala o repara la traducción.

Todo queda en `read_aloud_piper\traduccion`:

```
traduccion\
  translateLocally\translateLocally.exe
  translateLocally\models\en-es-base-memory\   (y es-en-base-memory)
  llama\llama-server.exe                        (la versión Vulkan de llama.cpp)
  modelos\Hy-MT2-1.8B-Q4_K_M.gguf               (y Hy-MT2-7B-Q4_K_M.gguf)
```

translateLocally guarda cuántos hilos usar en
`HKCU\Software\translateLocally` (Read Aloud le pone 4, para no frenar la voz)
y deja una carpeta vacía en `%APPDATA%\translateLocally`. Al desinstalar se
borran la carpeta `traduccion`, esa clave y esa carpeta.

## Otros modelos, a mano (para desarrolladores)

Read Aloud reconoce también **TranslateGemma 4B** (Google), que en la prueba a
ciegas quedó entre los dos Hy-MT2 (4,05 y 4,40). No se baja solo: el
repositorio oficial pide una cuenta y aceptar las
[condiciones de Gemma](https://ai.google.dev/gemma/terms), y las copias sin
cuenta son de terceros.

1. Baja el GGUF Q4_K_M, por ejemplo `translategemma-4b-it.Q4_K_M.gguf` de
   [mradermacher/translategemma-4b-it-GGUF](https://huggingface.co/mradermacher/translategemma-4b-it-GGUF)
   (2,5 GB), y lee sus condiciones.
2. Comprueba el sha256 del archivo que bajaste:

   ```powershell
   (Get-FileHash .\translategemma-4b-it.Q4_K_M.gguf -Algorithm SHA256).Hash
   ```

   El de esa copia, cuando se probó (noviembre de 2026), era
   `81200d03e843d2ec1ece6eeafe7d13cb6e5211e1fcd336ade55790b683a08330`.
3. Ponlo en `read_aloud_piper\traduccion\modelos`, con un nombre que empiece
   por `translategemma-4b` y termine en `.gguf`. Hace falta llama.cpp del nivel
   alto (`.\setup.ps1 -OnlyTranslation -TranslationHigh`).
4. Elígelo en Ajustes, Traducción, **Avanzado: modelo**, o deja que Automática
   lo use cuando quepa.

Un GGUF con otro nombre no se usa: Read Aloud no sabría su plantilla ni su
calidad. Para añadir otra familia hace falta su plantilla en
`Get-TranslationRequest` y su entrada en el catálogo de
`lib/ReadAloud.Translate.ps1`.

## Ajustes

| Ajuste | De fábrica | Qué hace |
|---|---|---|
| `Translate` | `$true` | Traducción activada |
| `TranslateQuality` | `'auto'` | `'auto'`, `'basic'` (Bergamot) o `'high'` (un modelo de lenguaje) |
| `TranslatePriority` | `'auto'` | `'auto'`, `'voice'` o `'translation'`, cuando la voz propia y el mejor traductor no caben juntos |
| `TranslateAutoReturn` | `$true` | Volver sola a la voz propia |
| `TranslateReturnMinutes` | `15` | Minutos sin traducir antes de volver |
| `TranslatePractice` | `$false` | Modo práctica |
| `TranslateModel` | `''` | El modelo de la sección avanzada (`'hymt2-1.8b'`, `'hymt2-7b'`, `'translategemma-4b'`) |
| `TranslateDevice` | `'auto'` | Dónde corre el modelo: `'auto'`, `'gpu'` o `'cpu'` |
| `TranslateIdleMinutes` | `10` | Minutos sin traducir tras los que se cierra el traductor (salvo el que tiene la tarjeta de la voz propia) |
| `HotkeyTranslate` | `'Ctrl+Alt+T'` | El atajo |

Las traducciones se guardan `AudioCacheMinutes` (10) en la memoria del proceso
residente, para no traducir dos veces lo mismo; no se escriben en el disco. Ver
[configuracion.md](configuracion.md#audio-guardado).

## Si algo falla

- **"No hay ningún traductor instalado"** en los ajustes: abre **Instalar o
  reparar las voces** en el menú Inicio, o `.\setup.ps1 -OnlyTranslation`.
- **"no es el archivo esperado (sha256 …)"** al instalar la básica:
  translateLocally solo publica una versión de prueba con la etiqueta
  `latest`, y si su autor la cambia, el sha256 ya no coincide. La lectura sigue
  funcionando; abre una incidencia para que se actualice el sha256.
- **Traduce con la básica aunque pediste la alta:** el modelo no cupo en la
  memoria en ese momento. `daemon.log` dice cuánto necesitaba y cuánto había.
