# 0006. Cortar por frases completas, no por palabras

- **Estado:** aceptada; reemplaza los cortes por palabras de `04_cortar.py`
- **Fecha:** 29 de octubre de 2026

## Contexto

La primera versión cortaba los clips palabra por palabra. Cuando un borde no
caía en silencio, soltaba la palabra del extremo y probaba con la siguiente.
Para RVC daba igual, porque RVC no aprende la entonación. Para Qwen3-TTS sí
importa: aprende cómo empieza y cómo termina una frase, y una que se corta a
la mitad le enseña un final que no existe.

Al medir los 516 clips del primer conjunto, solo el **48 %** empezaba y
terminaba donde empieza y termina la frase. Había clips a los que les faltaba
la última palabra, o los signos de exclamación del principio.

## Decisión

En `25_cortar_frases.py`:

- La unidad es la **frase**: termina en un punto, signo de pregunta o
  exclamación, o en una pausa de más de 0.7 s (Whisper no siempre puntúa).
- Quien dice cada frase se decide con la **frase entera** (ver la
  [0007](0007-reconocer-la-voz-con-wavlm.md)). Una frase con un tramo de otra
  voz se descarta: es una interrupción o dos voces encimadas.
- Un clip son **una o varias frases seguidas** de la voz, con su pausa natural,
  de hasta 15 s. Si un borde no cae en silencio, se prueba con una frase
  menos, **nunca con una palabra menos**.
- Se quitan las **canciones de entrada y salida**: tiras de cuatro palabras que
  aparecen en cinco capítulos o más, casi en el mismo momento desde el inicio
  o desde el final. Las frases que la voz repite cada capítulo
  también se repiten, pero en momentos distintos, y se conservan.

## Resultado

De los mismos 22 capítulos salieron 29.7 minutos de candidatos, todos de
frases enteras, frente a 30.8 minutos de los que la mitad estaban cortados.
581 de 630 clips terminan en un signo de puntuación y el resto en una pausa.

## Consecuencias

- Hubo que revisar de nuevo los 22 primeros capítulos junto con los nuevos,
  en una sola pasada.
- Los clips cortos que quedan son frases completas, como una pregunta o una
  exclamación de dos palabras. Solo se quitan los de menos de 1 s (ver la
  [0010](0010-conjunto-final.md)).
