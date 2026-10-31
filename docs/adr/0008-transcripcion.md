# 0008. Whisper en la tarjeta a media precisión, y una segunda lectura con Qwen3-ASR

- **Estado:** aceptada; reemplaza Whisper en el procesador
- **Fecha:** 30 de octubre de 2026

## Contexto

Con Qwen3-TTS, el texto de cada clip entra al entrenamiento: un error se
aprende. En la primera revisión, el usuario corrigió a mano 140 de 516 textos.

La transcripción corría en el procesador, porque en la tarjeta, a precisión
completa, Whisper large-v3 casi no cabía en 8 GB y era cuatro veces más
lento. Pero en el procesador, con la computadora en uso, un capítulo llegó a
tardar 174 minutos.

## Decisión

1. **Whisper large-v3 en la tarjeta, a media precisión**, sobre el capítulo
   entero, con tiempos por palabra. Es como lo corre OpenAI en una tarjeta. El
   modelo se pasa a media precisión en el procesador y después a la tarjeta;
   las LayerNorm quedan en float32, como las calcula Whisper de todos modos.
   Cargarlo directo en la tarjeta deja reservados los 6 GB de float32 y el
   resto no cabe.
2. **Cada clip se vuelve a transcribir solo, con dos motores**: Whisper
   large-v3 y Qwen3-ASR-1.7B (Apache-2.0). Los dos reciben como contexto los
   nombres propios, escritos como en las correcciones. La página de
   revisión propone una lectura y muestra las otras cuando dicen algo
   distinto.

## Medidas

**Media precisión frente a precisión completa**, en tres capítulos, contra los
textos corregidos a mano:

| | Error por carácter | Tiempo por capítulo de 25 min | Memoria |
|---|---|---|---|
| Procesador, float32 | 12.2 % | 21 a 174 min | — |
| Tarjeta, media precisión | 12.0 % | 2 min | 4.2 GB |

Los tiempos de las palabras que coinciden difieren 0 ms en la mediana.

**Segunda lectura**, en los clips que el usuario corrigió, que es donde
estaban los errores:

| | Error por carácter | Signo final correcto |
|---|---|---|
| Whisper sobre el capítulo entero | 9.3 % | 96 % |
| Qwen3-ASR | 4.3 % | 74 % |
| Qwen3-ASR con los nombres de contexto | **3.0 %** | 73 % |

Qwen3-ASR acierta más palabras, pero pone peor los signos de pregunta y
exclamación, que importan para la entonación. Por eso no reemplaza a Whisper:
las dos lecturas van a la revisión. Whisper clip por clip quedó sin medir de
la misma forma; la medida se detuvo para dejar la tarjeta al lote.

## Consecuencias

- `.venv_asr` es un entorno aparte, porque qwen-asr pide transformers 4.57.
- La revisión es más rápida: cuando los textos coinciden, casi siempre están
  bien.
