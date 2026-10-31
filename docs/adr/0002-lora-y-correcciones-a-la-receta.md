# 0002. Afinar con LoRA, corrigiendo tres errores de la receta oficial

- **Estado:** aceptada
- **Fecha:** 28 de octubre de 2026

## Contexto

Afinar todos los pesos de un modelo de 1.7 B no cabe en una tarjeta de 8 GB:
solo los gradientes y el optimizador de AdamW piden varias veces lo que pesa
el modelo. Además, con 20 a 74 minutos de voz, cambiar todos los pesos lleva
rápido a memorizar las frases.

La primera prueba con la receta oficial de afinado de Qwen3-TTS
(`sft_12hz.py`, commit `022e286`) produjo audio sin sentido. No era por LoRA:
la receta tiene tres errores.

## Decisión

Afinar con **LoRA** y corregir la receta en `11b_entrenar_qwen.py`:

- **LoRA r=64, alfa 64, abandono 0.05**, en las proyecciones de atención (q, k,
  v, o) y de la red (gate, up, down) de todas las capas del modelo grande y
  del modelo chico que predice los otros 15 códigos. Son 76.9 M de parámetros
  en float32, sobre el modelo base congelado en bf16.
- **Lote efectivo de 8** (2 × 4), ritmo coseno con 30 pasos de calentamiento.
  Pico de memoria: 8.4 a 9.3 GB, que en 8 GB pasa en parte a la memoria
  compartida de Windows.

Los tres errores de la receta:

1. **Falta `text_projection` en el canal de texto.** El texto entra al modelo
   sin la proyección con que se preentrenó.
2. **Las etiquetas del modelo grande se desplazan dos veces.** La receta las
   pasa ya corridas una posición (`[:, 1:]`) y la función de pérdida de
   transformers las vuelve a correr.
3. **El modelo chico recibe el estado oculto equivocado.** Debe ser el de la
   posición anterior (`mascara[:, 1:]`), y su pérdida también se desplazaba dos
   veces.

Comprobado sobre el modelo base sin entrenar, que debería predecir bien sus
propios datos: con las correcciones, la pérdida del modelo grande es 1.62 y la
del chico 5.47; sin ellas, 8.7 y 10.9.

El idioma va en el prefijo de códigos (`think, think_bos, idioma, think_eos,
voz, pad, bos`), y se genera con `non_streaming_mode=True`, la misma
disposición del entrenamiento. El modelo afinado queda como `custom_voice`:
la huella de la voz en el lugar 3000 de `codec_embedding`, con `spk_id`
apuntando ahí.

## Alternativas

- **Afinar todos los pesos:** no cabe en 8 GB, y con tan pocos datos
  memorizaría.
- **Clonar desde una muestra, sin entrenar:** probado en la
  [0001](0001-qwen3-tts-en-vez-de-rvc.md), y el usuario prefirió el afinado.

## Consecuencias

- Con LoRA el timbre ya quedó resuelto: 97 a 99 % de probabilidad de ser la
  voz según ECAPA, en todas las épocas válidas. Lo que faltaba después era
  entonación, y para eso se trabajaron los datos (ver la
  [0006](0006-clips-de-frases-completas.md)).
- Hay que llevar la receta corregida, no la oficial. Si Qwen la corrige,
  conviene comparar las dos con el mismo conjunto.
