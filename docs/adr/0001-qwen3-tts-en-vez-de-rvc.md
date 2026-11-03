# 0001. Qwen3-TTS afinado en vez de Piper con conversión RVC

- **Estado:** aceptada
- **Fecha:** 28 de octubre de 2026

## Contexto

La primera versión de la voz propia leía con Piper y pasaba el audio por un
modelo RVC entrenado con 20 minutos de la voz de prueba. RVC es conversión de voz:
cambia el timbre y deja la entonación, el ritmo y las pausas de la voz que
recibe.

Al comparar la voz entrenada con la voz real diciendo las mismas frases, el
usuario notó tres cosas: las preguntas no subían, las pausas y la velocidad no
eran las suyas, y faltaban los cambios de entonación dentro de las palabras.

Las medidas lo confirmaron. La curva de tono de la voz entrenada se parecía en
0.99 a la de Piper y en 0.35 a la de la voz real (correlación, con las frases
alineadas en el tiempo). RVC no podía arreglarlo: la entonación nunca fue
suya.

## Decisión

Usar un modelo de texto a voz que aprenda también la forma de hablar, y
afinarlo con la voz: **Qwen3-TTS 12Hz 1.7B Base** (Apache-2.0), afinado con
LoRA (ver la [0002](0002-lora-y-correcciones-a-la-receta.md)).

## Alternativas probadas

Con las mismas 10 frases que dijo la voz real en las grabaciones, escuchadas
junto a ella:

- **Piper con RVC:** la de antes, con la entonación de Piper.
- **Chatterbox Multilingual V3**, y su versión afinada para el español de
  México (MIT):
  clonan desde una muestra, sin entrenar.
- **Qwen3-TTS clonando desde una muestra de 8 s**, solo y con RVC encima.

El usuario eligió Qwen3-TTS. Al afinarlo con los clips de la voz, ya no hizo
falta RVC encima.

## Consecuencias

- La voz necesita una tarjeta NVIDIA: el modelo ocupa unos 5 GB de memoria de
  video, y sin optimizar tardaba 3.8 veces lo que dura cada frase. Ver la
  [0004](0004-lectura-en-tiempo-real.md) y la
  [0005](0005-motor-automatico-y-tarjeta-compartida.md).
- El entrenamiento usa el texto de cada clip, así que las transcripciones
  importan: un error se aprende como forma de decir esa frase. Por eso
  existen la revisión de textos y la [0008](0008-transcripcion.md).
- Applio y el modelo RVC ya no se usan. El instalador los sigue ofreciendo con
  `-ConRvc`, para reproducir la primera versión.
