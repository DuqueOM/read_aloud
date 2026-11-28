# 0017. Diccionario en el panel: WordNet abierto y WikDict, sin conexión

- **Estado:** propuesta. Falta medir con los archivos reales y la aprobación
  del usuario.
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

## Candidatos

Datos de las páginas oficiales, consultadas el 28 de noviembre de 2026:

| Fuente | Qué da | Licencia | Descarga | Tamaño |
|---|---|---|---|---|
| [Open English WordNet](https://en-word.net/downloads) 2025, formato WNDB | Definiciones en inglés, ejemplos, sinónimos y categoría (sustantivo, verbo...) | CC BY 4.0 | `english-wordnet-2025.zip` | 9.2 MB |
| [WikDict](https://www.wikdict.com/page/download) en-es, StarDict | Traducciones inglés → español, sacadas de Wiktionary | CC BY-SA 4.0 | `wikdict-en-es.zip` | 4 MB |
| WikDict es-en, StarDict | Traducciones español → inglés | CC BY-SA 4.0 | `wikdict-es-en.zip` | 964 KB |
| Bergamot (ya instalado, 0016) | La frase traducida entera | MPL 2.0 | Nada nuevo | 0 |
| Hy-MT2 1.8B o 7B (ya instalado en el nivel alto, 0016) | Explicación del sentido en esa frase | Apache 2.0 | Nada nuevo | 0 |

En total, unos **14 MB** de descarga. Falta medir cuánto ocupa una vez
descomprimido.

Descartados:

- **Princeton WordNet 3.1:** no cambia desde 2011. Open English WordNet sale
  de él, se corrige cada año y tiene el mismo formato.
- **FreeDict eng-spa** (2025.11.23, 64 258 entradas): hoy se arma con los
  datos de WikDict, así que es la misma fuente con otro empaque.
- **Wiktionary entero** (kaikki.org, JSONL): trae mucho más, pero pesa cientos
  de MB, y habría que filtrarlo en cada equipo.
- **Solo el modelo de lenguaje:** necesita el nivel alto (1.17 GB y unos
  2.9 GB de RAM libre). El diccionario tiene que funcionar también en el nivel
  básico.

## Probado: Bergamot no dice qué palabra va con cuál

El motor de Bergamot puede devolver el alineamiento entre las palabras del
original y las de la traducción. translateLocally `-p` no lo devuelve: con
`alignments = true` en la petición responde solo `target.text` (probado el
28 nov con los modelos `en-es-base-memory` y `es-en-base-memory`). Por eso la
traducción «en su frase» se arma de otra forma (ver abajo).

## Propuesta

### Qué muestra la ventana

1. La palabra, su categoría y la forma base si es otra («went», del verbo
   «go»).
2. **En esta frase:** la traducción que corresponde a esta frase, resaltada, y
   debajo las otras traducciones del diccionario.
3. **Definición:** las dos o tres primeras acepciones de WordNet de esa
   categoría, con un ejemplo.
4. «Escuchar», «Guardar» y, en el nivel alto, «Explicar en esta frase».
5. Al pie, en letra chica, las fuentes y sus licencias.

### Cómo se elige la traducción en su frase

1. Se traduce la frase entera con Bergamot (0.01 s por frase, y muchas veces
   ya está guardada en la memoria del proceso residente).
2. Se buscan en WikDict las traducciones de la palabra.
3. Se elige la que aparece en la frase traducida, sin distinguir tildes y
   comparando el comienzo de la palabra (para que «informe» coincida con
   «informes»). Ejemplo: con «The bank of the river was covered with snow»,
   Bergamot da «La orilla del río...», y de las traducciones de «bank»
   (banco, orilla, ribera...) gana «orilla».
4. Si ninguna aparece, se muestra la primera de WikDict y se avisa que no
   depende de la frase.

En el nivel alto, si el modelo ya está abierto, se le pregunta directamente:
traducción de la palabra en esa frase y una explicación corta. Si no está
abierto, el botón «Explicar en esta frase» lo abre solo cuando se pide, para
no cargar 1.17 GB en cada búsqueda.

### Palabras en español

Para una palabra en español: la traducción al inglés con WikDict es-en,
elegida en la frase igual que arriba, y la definición en inglés de esa
traducción, sacada de WordNet. Así también se aprende vocabulario en inglés.
Limitación: WikDict trae solo la forma base, así que «corrió» no aparece; en
ese caso se traduce la palabra sola con Bergamot.

### Cómo se busca sin cargar todo en memoria

- **WordNet (WNDB):** los archivos `index.noun`, `index.verb`... están
  ordenados, así que se busca por bisección directamente en el disco, y la
  definición se lee de `data.noun`... en la posición que da el índice. Las
  formas irregulares salen de `noun.exc`, `verb.exc`... y las regulares, de
  las reglas de WordNet (`morphy`: «running» → «run»). No hace falta
  convertir nada al instalar.
- **WikDict (StarDict):** el `.idx` (el número de entradas, a medir) se carga una vez,
  en la primera búsqueda, y el `.dict.dz` se descomprime al instalar, para
  leer cada entrada por su posición.

Todo en PowerShell, sin Python ni SQLite, igual que el resto del nivel
básico.

### Instalación

- Una pieza nueva en `config/traduccion.psd1` (o un `config/diccionario.psd1`
  aparte) con origen, tamaño, sha256 y destino, como las de la 0016.
- `setup.ps1` la instala por defecto, con `-SkipDictionary` para no
  hacerlo, y la deja en `read_aloud_piper\diccionario`.
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
del archivo de Anki.

## Medidas pendientes

Con la descarga aprobada (los 3 archivos, unos 14 MB):

- Cuánto ocupa todo descomprimido.
- Cuánto tarda la primera búsqueda y las siguientes en PowerShell 5.1.
- Cobertura: qué parte de las palabras de textos reales en inglés tiene
  definición y traducción.
- Aciertos de la traducción en su frase, con unas 30 palabras de varios
  sentidos (bank, bill, charge, run, set...), contra la elección del modelo
  del nivel alto.

## Consecuencias

- Unos 14 MB más de descarga y un clic más en el asistente.
- Hay que mostrar la atribución de WordNet y de WikDict en la ventana, en
  «Acerca de» y en la documentación. CC BY-SA obliga a compartir igual solo a
  quien redistribuya los datos cambiados: la app los baja de su origen y no
  los cambia.
- El clic izquierdo cambia un poco: con Ctrl ya no lee desde la frase.
