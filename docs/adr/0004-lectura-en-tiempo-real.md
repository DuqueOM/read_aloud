# 0004. Leer en tiempo real: LoRA fundido, CUDA graph y frases en grupo

- **Estado:** aceptada
- **Fecha:** 29 de octubre de 2026

## Contexto

Read Aloud lee fragmento por fragmento. Si un fragmento tarda en generarse
más de lo que dura el anterior, la lectura se corta. Qwen3-TTS afinado, tal
como lo usa su librería, tardaba **3.76 veces** lo que dura cada frase, con la
tarjeta a un 15 % de uso: el límite era Python, no la tarjeta.

Por cada sonido (80 ms de audio), el modelo grande elige un código y un modelo
chico de 5 capas elige los otros 15, uno tras otro. La librería llama para eso
al `generate()` de transformers en cada sonido, y cada llamada prepara caché,
procesadores y criterios de parada desde cero.

## Decisión

Tres cambios en `lib\servidor_qwen.py` y `lib\qwen_rapido.py`, que hacen el
mismo cálculo:

1. **Fundir las capas LoRA en los pesos.** Cada paso pasa a ser una
   multiplicación en vez de tres. Redondea los pesos a bf16.
2. **Grabar los 15 pasos del modelo chico como un CUDA graph** y repetirlo en
   cada sonido. Sin caché: recalcula las 16 posiciones con la máscara causal,
   así que cada una ve solo las anteriores, igual que con caché.
3. **Generar varias frases juntas.** En la tarjeta, varias cuestan casi lo
   mismo que una. Las dos primeras de cada lectura van juntas y las siguientes
   en grupos de hasta `QwenBatch`, mientras suenan las anteriores.

## Medidas

Tiempo de generación sobre la duración del audio, con 10 frases:

| | Una frase | Dos | Cuatro | Ocho |
|---|---|---|---|---|
| Librería tal cual | 3.76 | 2.20 | 1.56 | 1.07 |
| LoRA fundido | 2.43 | 1.68 | 1.09 | 0.67 |
| Fundido y CUDA graph | 1.12 | 0.54 | **0.34** | 0.25 |

Que el cálculo sea el mismo se comprobó así:

- **Fundir:** la divergencia KL media de la primera predicción de las 10
  frases fue de 0.0018, con el mismo código más probable en todas.
- **CUDA graph:** con muestreo apagado, se aleja de la librería lo mismo que la
  librería con caché se aleja de ella sin caché (KL de 0.0017 frente a 0.0016).
  Los códigos que cambian son empates casi exactos: el primero y el segundo
  candidato quedan a 0.25 % de probabilidad.

## Alternativas

- **flash-attn o torch.compile:** en Windows no se instalan con facilidad.
- **Cuantizar el modelo:** cambia el cálculo y habría que volver a evaluar la
  voz de oído.

## Consecuencias

- La lectura empieza tras generar las dos primeras frases (unos segundos) y
  después no se corta.
- `qwen_rapido.py` depende de la estructura interna de `qwen_tts` 0.1.1. Si se
  actualiza el paquete, hay que repetir las comprobaciones de
  `voz_personalizada\proceso_qwen\14b_rapido.py` y `14c_ruido_bf16.py`.
