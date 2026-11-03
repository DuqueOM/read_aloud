# Idiomas y pronunciación

## Cómo decide el idioma

Cada frase recibe dos puntajes, uno de español y otro de inglés, y gana el
más alto si le saca al otro un margen suficiente. Los puntajes se dividen
entre el número de palabras, y esa normalización es lo que permite comparar
una frase de seis palabras con un párrafo de sesenta.

Cuentan tres tipos de evidencia:

- **Palabras funcionales.** Listas de palabras que pertenecen claramente a un
  idioma. Las ambiguas se dejaron fuera a propósito: `a`, `no`, `me`, `son` y
  `van` existen en ambos y en la versión anterior inflaban el puntaje del
  español en textos que eran inglés.
- **Ortografía.** Las letras acentuadas, la eñe y los signos de apertura
  suman al español.
- **Terminaciones.** `ción`, `mente`, `ando` y `iendo` suman al español;
  `ing`, `tion`, `ness` y `ment` suman al inglés.

Para que una frase cambie el idioma que se venía leyendo necesita al menos
cinco palabras y un idioma claro. Una frase corta o ambigua hereda el idioma
de la anterior. Así se evita que un `OK, perfecto` en medio de un párrafo
provoque un salto de voz.

Puedes ver la decisión completa sin escuchar nada:

```powershell
.\read_aloud.ps1 -ShowPlan
```

Sale el texto ya partido, con el idioma de cada parte y los puntajes del
texto completo. Es la forma de averiguar por qué algo sonó como sonó.

Si un texto concreto se resiste, fuerza el idioma:

```powershell
.\read_aloud.ps1 -Language English
.\read_aloud.ps1 -Language Spanish
```

Con el idioma forzado no hay segmentación: todo se lee con una sola voz.

## El diccionario de pronunciación

`config/terms_es.tsv` reescribe términos en inglés con ortografía española
antes de pasarlos a la voz española. Es un archivo de texto con un término
por línea, separado por un tabulador:

```
deploy	diplói
pull request	pul rikuést
cache	caché
API	a pe i
```

Reglas del archivo:

- Separa con **un tabulador**, no con espacios.
- No distingue mayúsculas de minúsculas.
- Las líneas que empiezan con `#` son comentarios.
- Guárdalo en UTF-8, porque los acentos marcan dónde cae el énfasis.
- Los términos de varias palabras ganan sobre los de una sola, así que
  `pull request` se aplica antes que `pull`.

### Cómo añadir un término

Prueba primero cómo suena tal cual:

```powershell
.\read_aloud.ps1 -InputText "vamos a revisar el rollout"
```

Si no te convence, añade la línea al archivo, reinicia el proceso residente y
vuelve a probar. Se cierra así y la próxima lectura lo arranca con el
diccionario nuevo:

```powershell
. .\lib\ReadAloud.Core.ps1
Send-ReadAloudCommand -PipeName 'read_aloud_pipe' -Command @{ cmd = 'quit' }
```

Para escribir la pronunciación, piensa cómo la dirías tú hablando español y
escríbela con letras españolas. Estas equivalencias cubren casi todo:

| Sonido inglés | Escríbelo así | Ejemplo |
|---|---|---|
| `sh` | `ch` | `push` → `puch` |
| `j`, `g` suave | `y` | `job` → `yob` |
| `w` | `u` | `workflow` → `uérkflou` |
| `th` | `t` | `throughput` → `trúput` |
| `h` aspirada | `j` | `hardware` → `járduer` |
| `s` inicial + consonante | `es` | `string` → `estrín` |

Pon la tilde donde cae el acento en inglés. Sin tilde, el español acentúa por
sus propias reglas y `deploy` suena `DÍploi` en lugar de `diplói`.

### Si un término sobra

Bórralo. El archivo no necesita estar completo, y una regla de más molesta
más que una de menos. Por ejemplo, si prefieres oír `data` tal cual, no
agregues la línea.

## Cuándo el diccionario y cuándo la voz inglesa

El diccionario es para palabras sueltas dentro de una frase en español. La
voz inglesa entra cuando hay frases enteras en inglés.

Esta división es intencional. Cambiar de voz a mitad de frase produce un
corte audible que molesta más que un acento aproximado, mientras que leer un
párrafo entero en inglés con voz española es justo el problema que se quería
resolver.

## Cambiar de voz

Mira las que tienes instaladas:

```powershell
.\read_aloud.ps1 -ListVoices
```

`setup.ps1` conoce estas y las descarga solas si las pones en los ajustes:

| Voz | Idioma |
|---|---|
| `es_MX-claude-high` | español de México, calidad alta |
| `es_MX-ald-medium` | español de México, más ligera |
| `es_ES-davefx-medium` | español de España |
| `en_US-lessac-medium` | inglés de Estados Unidos |
| `en_US-amy-medium` | inglés de Estados Unidos |
| `en_GB-alba-medium` | inglés británico |

Cambia `VoiceEs` o `VoiceEn` en `config/settings.psd1`, ejecuta `setup.ps1` y
reinicia el proceso residente.

Hay muchas más en
[rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices). Para usar
una que no esté en la lista, descarga el `.onnx` y su `.onnx.json` a
`read_aloud_piper\voices` y escribe su nombre en los ajustes.
