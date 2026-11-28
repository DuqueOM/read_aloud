# 0017. Diccionario en el panel: WordNet abierto y WikDict, sin conexión

- **Estado:** propuesta, con medidas. Las fuentes y la descarga para medir
  están aprobadas (28 nov). Falta aprobar el diseño.
- **Fecha:** 28 de noviembre de 2026

## Contexto

La fase 2 de la traducción (ver [0016](0016-traduccion-local.md)) agrega un
diccionario al panel de texto. El usuario aprende inglés: quiere tocar una
palabra de lo que se lee y ver qué significa en esa frase, oírla y guardarla
para repasarla en Anki.

Lo que pide el encargo:

- El clic izquierdo sigue leyendo desde esa frase, y el derecho sigue abriendo
  «Copiar / Seleccionar todo».
- El menú del clic derecho agrega «Buscar «palabra»», con la palabra que está
  bajo el cursor. Ctrl+clic hace lo mismo y no salta de frase. Nada de
  mantener pulsado ni de doble clic.
- Una ventana pequeña junto a la palabra, con la traducción de la palabra en
  su frase, la definición en inglés, «Escuchar» (la palabra con la voz
  inglesa) y «Guardar» (una fila para Anki: palabra, frase, traducción,
  definición y fecha).
- Todo sin conexión, con fuentes libres, y se puede apagar en Ajustes.

Como en la traducción, nada de cuentas, claves ni servicios en línea.

El 28 de noviembre el usuario agregó tres pedidos:

- Una sección «Más significados», como el diccionario de DeepL: los otros
  sentidos de la palabra, por categoría, con sus traducciones y ejemplos.
- Que funcione con cualquier par de idiomas, para agregar más en el futuro.
- Que los idiomas, la traducción y el diccionario se elijan al instalar y se
  activen en Ajustes.

## Candidatos

Datos de las páginas oficiales y de los archivos bajados el 28 de noviembre de
2026:

| Fuente | Qué da | Licencia | Descarga | Descomprimido |
|---|---|---|---|---|
| [Open English WordNet](https://en-word.net/downloads) 2025, formato WNDB | Definiciones en inglés, ejemplos, sinónimos, categoría y formas irregulares | CC BY 4.0 | `english-wordnet-2025.zip`, 9.6 MB | 31.9 MB; 25.4 MB sin `index.sense`, que no hace falta |
| [WikDict](https://www.wikdict.com/page/download) en-es, StarDict | Pronunciación (IPA), categoría y cada sentido con su glosa en inglés y sus traducciones al español | CC BY-SA 4.0 | `wikdict-en-es.zip`, 3.7 MB | 18.0 MB, 68 702 entradas |
| WikDict es-en, StarDict | Lo mismo de español a inglés | CC BY-SA 4.0 | `wikdict-es-en.zip`, 1.0 MB | 4.1 MB, 22 129 entradas |
| Bergamot (ya instalado, 0016) | La frase traducida entera y los ejemplos traducidos | MPL 2.0 | Nada nuevo | 0 |
| Hy-MT2 1.8B o 7B (ya instalado en el nivel alto, 0016) | Explicación del sentido en esa frase | Apache 2.0 | Nada nuevo | 0 |

En total, **14.3 MB** de descarga y unos **47.5 MB** instalados.

Descartados:

- **Princeton WordNet 3.1:** no cambia desde 2011. Open English WordNet sale
  de él, se corrige cada año y tiene el mismo formato.
- **FreeDict eng-spa:** el `.ifo` de WikDict dice «FreeDict+WikDict»: es la
  misma fuente con otro empaque.
- **Wiktionary entero** (kaikki.org, JSONL): trae más, pero pesa cientos de
  MB, y habría que filtrarlo en cada equipo.
- **Solo el modelo de lenguaje:** necesita el nivel alto (1.17 GB y unos
  2.9 GB de RAM libre). El diccionario tiene que funcionar también en el nivel
  básico.

## Medidas (28 nov, prototipo en PowerShell)

Los scripts están en `pruebas_traduccion\scripts` (`prototipo_diccionario.ps1`,
`medir_diccionario.ps1`, `medir_traduccion_en_frase.ps1`,
`medir_cobertura_diccionario.ps1`), fuera del repositorio.

**Velocidad** (Windows PowerShell 5.1, i7-14650HX):

| Paso | Tiempo |
|---|---|
| Cargar el `.idx` de en-es (68 702 entradas) | 205 ms, una vez |
| Cargar el `.idx` de es-en | 54 ms, una vez |
| Primera búsqueda (el .NET compila el código) | 170 ms en WordNet, 470 ms en WikDict |
| Las siguientes, en WordNet (bisección en el disco, con las formas base) | 14 a 37 ms |
| Las siguientes, en WikDict | menos de 1 ms |

El proceso de prueba ocupó 105 MB en total, con los dos índices cargados.

**Cobertura** con 2 753 palabras de textos reales en inglés (el README y los
textos de calidad de la fase 0; 922 distintas):

- Con traducción en WikDict: 90.5 % de las distintas, 93.2 % del total.
- Con definición en WordNet: 86.6 % de las distintas, 70.0 % del total.
  WordNet no tiene palabras funcionales («and», «for», «from»), y esas son
  muchas en el total. Para ellas sirve la traducción de WikDict.
- Lo que falta se arregla casi todo en la parte 1: posesivos («city's»),
  contracciones («didn't»), palabras con guion («bike-sharing»). El resto son
  nombres propios, siglas y términos técnicos.

**La traducción en su frase** (ver abajo cómo se elige), con 32 frases de
palabras con varios sentidos (bank, mean, bill, charge, run, set, light,
left, match, book, fair, plant, stand, trip, bat), hechas para la prueba:

| Resultado | Casos |
|---|---|
| Acierta | 26 (81 %) |
| Se equivoca | 1: Bergamot tradujo mal la frase («El bate salió volando de la cueva») y la elección la siguió |
| No encuentra ninguna | 5: dos frases mal traducidas por Bergamot («Lave encendí con una cerada»), dos traducciones que WikDict no tiene («dirigir», para «runs»; «tropezar», para «trip») y una forma que cambia mucho («póngase de pie» frente a «ponerse de pie») |

Las frases son cortas y las elegí yo: en textos reales el número puede ser
otro. La primera versión de la comparación acertaba 19 de 32; la mejora fue
preferir la palabra exacta, después la que comparte más letras y, a igualdad,
la de menos palabras.

**Probado: Bergamot no dice qué palabra va con cuál.** El motor puede devolver
el alineamiento entre las palabras del original y las de la traducción, pero
translateLocally `-p` no lo hace: con `alignments = true` en la petición
responde solo `target.text`.

**WikDict es-en es chico:** 22 129 entradas, sin «informe» ni «orilla». Las
dos aparecen como traducciones dentro de en-es, así que para el español se
usa también el índice inverso de en-es (ver abajo).

## Propuesta

### Qué muestra la ventana

Arriba, lo de esta frase:

1. La palabra, su pronunciación (IPA, de WikDict), «Escuchar» y sus formas
   irregulares («meant», de los `.exc` de WordNet).
2. **En esta frase:** la traducción elegida y su categoría. Si ninguna
   aparece en la frase traducida, la más común, con la nota «no depende de la
   frase».
3. **Definición:** la primera acepción de WordNet de esa categoría.
4. «Escuchar», «Guardar» y, en el nivel alto, «Explicar en esta frase».

Abajo, **«Más significados»**, cerrado al abrir la ventana (como en DeepL):

- Por categoría (verbo, sustantivo, adjetivo...): cada sentido de WikDict, con
  sus traducciones y la glosa corta en inglés, con «Escuchar» en cada
  traducción (con la voz de su idioma).
- Las definiciones de WordNet de esa categoría, con un ejemplo y su
  traducción. La traducción del ejemplo la hace Bergamot al abrir la sección
  (0.01 s cada uno), y se marca como automática.
- Al pie, en letra chica, las fuentes y sus licencias.

Ejemplo real para «mean» en «What does this word mean?», con los datos del
prototipo, ordenado a mano (WikDict trae tres pronunciaciones; aquí va una):

```
mean  /miːn/  [Escuchar]  (meant)
En esta frase: significar (verbo)    «¿Qué significa esta palabra?»
Definición: mean or intend to express or convey
[Escuchar] [Guardar] [Explicar en esta frase]
Más significados ▾
  verbo       querer decir, significar — to convey, indicate
              pretender — to intend; plan on doing
              significar, importar — to be important
  sustantivo  media — the statistical value
              medio, recurso — method by which something is done
  adjetivo    malo, avieso, ruin — low-minded; acting without consideration
  Ejemplos: You never understand what I mean!
            ¡Nunca entiendes lo que quiero decir! (traducción automática)
```

Lo que DeepL tiene y esto no: ejemplos escritos para cada traducción y
«menos frecuente». Ninguna de las dos fuentes trae frecuencias (los conteos de
WordNet están en 0 en esta edición); se respeta el orden en que vienen.

### Cómo se elige la traducción en su frase

1. Se traduce la frase entera con Bergamot (0.01 s por frase; muchas veces ya
   está guardada en la memoria del proceso residente).
2. Se buscan en WikDict las traducciones de la palabra, por su forma base.
3. Cada traducción recibe puntos por cómo aparece en la frase traducida, sin
   tildes: 100 si una palabra suya está igual, o las letras del comienzo que
   comparte (al menos el largo menos 2, y al menos 4, para que «significar»
   coincida con «significa»). Gana la de más puntos y, a igualdad, la que
   tiene menos palabras de relleno y viene antes en el diccionario.
4. Si ninguna aparece, se muestra la primera y se avisa.

En el nivel alto, si el modelo ya está abierto, se le pregunta directamente:
la traducción de la palabra en esa frase y una explicación corta. Si no está
abierto, el botón «Explicar en esta frase» lo abre solo cuando se pide, para
no cargar 1.17 GB en cada búsqueda. Ahí se arreglan los casos en que Bergamot
traduce mal la frase.

### Palabras en español

Una palabra en español da su traducción al inglés, elegida en la frase igual
que arriba, y la definición en inglés de esa traducción, sacada de WordNet.
Así también se aprende vocabulario en inglés. Las traducciones salen de
WikDict es-en y del índice inverso de en-es (cada traducción española de
en-es apunta a su palabra inglesa), que se arma al instalar. Limitación:
WikDict trae la forma base, así que «corrió» no aparece. En ese caso se
traduce la palabra sola con Bergamot.

### Pensado para cualquier par de idiomas

Ningún código del diccionario dice «inglés» o «español». Todo va por código
de idioma (ISO 639-1) y por par:

- Un catálogo, `config/idiomas.psd1`, dice qué hay para cada idioma (voces de
  Piper, definiciones) y para cada par (traductor, diccionario bilingüe), con
  origen, tamaño y sha256 de cada pieza. Hoy tiene `es`, `en`, `en-es` y
  `es-en`.
- Las funciones reciben el idioma de origen y el de destino: `Find-Definition
  -Lang en`, `Find-Translation -From en -To es`. Si un idioma no tiene
  definiciones (WordNet es solo inglés), la ventana muestra solo la
  traducción.
- WikDict tiene más pares con el mismo formato, así que un idioma nuevo es una
  fila más en el catálogo. Lo que no se resuelve así son las definiciones en
  otros idiomas: cada uno necesita su fuente, y no todos tienen una libre.

Hacer agnóstica la app entera (los ajustes `VoiceEs` y `VoiceEn`, la detección
de idioma, que hoy solo distingue español e inglés, los pares de Bergamot y la
elección de idiomas en el asistente) es un cambio más grande. Se propone como
fase aparte, con su propio ADR (ver «Después»).

### Cómo se busca sin cargar todo en memoria

- **WordNet (WNDB):** los archivos `index.noun`, `index.verb`... están
  ordenados, así que se busca por bisección directamente en el disco, y la
  definición se lee de `data.noun`... en la posición que da el índice. Las
  formas irregulares salen de `noun.exc`, `verb.exc`... y las regulares, de
  las reglas de WordNet (`morphy`: «running» → «run»). Sin conversión al
  instalar.
- **WikDict (StarDict):** el `.dict` viene sin comprimir. El `.idx` se carga
  una vez, en la primera búsqueda, y cada entrada se lee por su posición.

Todo en PowerShell, sin Python ni SQLite, igual que el resto del nivel
básico.

### Instalación

- Las piezas van en el catálogo de idiomas, con origen, tamaño, sha256 y
  destino, como las de la 0016. `setup.ps1` las instala por defecto en
  `read_aloud_piper\diccionario`, con `-SkipDictionary` para no hacerlo.
- **El sha256 de WikDict cambia cada mes,** porque sus archivos se rearman
  (el `.ifo` de los bajados dice 2026-11-26) y no publica sumas. Propuesta:
  subir una copia sin cambios de los dos `.zip` a un release del repositorio
  (`datos-diccionario-2026-11`), con su licencia, y bajarlos de ahí con el
  sha256 fijo. CC BY-SA permite redistribuirlos así, dando la atribución.
  Open English WordNet 2025 es un archivo fijo: se baja de su origen.
- El asistente agrega una tarea «Diccionario (14 MB)», marcada.
- Al desinstalar se borra con el resto.

### Guardar para Anki

- Archivo: `Documentos\Read Aloud\palabras_anki.csv`, que el usuario puede
  cambiar en Ajustes.
- CSV en UTF-8, separado por comas, con las líneas de cabecera que Anki lee
  al importar (`#separator:Comma`, `#html:false`,
  `#columns:Palabra,Frase,Traduccion,Definicion,Fecha`).
- «Guardar» agrega una fila. Si la misma palabra con la misma frase ya está,
  no la repite.

### Ajustes

En la sección TRADUCCIÓN: «Diccionario en el panel», Sí o No, y la carpeta
del archivo de Anki. Solo se muestra si el diccionario está instalado.

**El «Modo práctica» pasa a «Al traducir, leer»**, con dos opciones: «La
traducción» (como hoy) y «El original, con la traducción debajo» (el modo
práctica de hoy). El usuario propuso llamarlo «Modo traducción». Se propone
este nombre porque dice qué se lee, y porque toda la función ya es la
traducción. El ajuste `TranslatePractice` se conserva por compatibilidad. Es
un cambio chico que va en la parte de los ajustes.

## Después: paquetes de idiomas (fase 3, no ahora)

Lo que pidió el usuario para el futuro: al instalar, elegir los idiomas, y
que la traducción y el diccionario de cada par se activen en Ajustes una vez
instalados. Un borrador, para su propio ADR:

- Un «paquete» por idioma: voz de Piper (y la propia si hay), detección de
  idioma y definiciones. Uno por par: traductor y diccionario bilingüe. Todo
  descrito en `config/idiomas.psd1`.
- Una página «Idiomas» en el asistente, con casillas, y en Ajustes la misma
  lista, con «Agregar» (descarga con confirmación) y «Quitar».
- Ajustes por idioma (`Voices = @{ es = ...; en = ... }`) en vez de
  `VoiceEs` y `VoiceEn`, leyendo los viejos para no perder la configuración.
- La detección de idioma generalizada a los idiomas instalados.

Se deja para después de la 1.5.0, porque toca casi todos los archivos del
lector. El diccionario ya nace con esa forma, así que no habrá que
reescribirlo.

## Consecuencias

- 14.3 MB más de descarga (47.5 MB instalados) y un clic más en el asistente.
- Hay que mostrar la atribución de WordNet y de WikDict en la ventana, en
  «Acerca de» y en la documentación. CC BY-SA obliga a compartir igual solo a
  quien redistribuya los datos cambiados: la copia del release va sin cambios.
- El clic izquierdo cambia un poco: con Ctrl ya no lee desde la frase.
- El proceso residente ocupa unos 30 a 40 MB más con los índices cargados
  (a medir en el lector).
