# 0012. Votar a ciegas con dos tomas por voz, y quedarse con la voz de los 60 mejores minutos

- **Estado:** aceptada
- **Fecha:** 2 de noviembre de 2026

## Contexto

Tras elegir la voz de los 60 mejores minutos, época 2
([0010](0010-conjunto-final.md)), se probaron dos entrenamientos más
(`33_ronda5.py`), con un punto guardado también a mitad de cada época:

| Entrenamiento | Mejor punto | Validación |
|---|---|---|
| 60 mejores, aprendizaje 3e-5 (la voz de la app) | época 2 | 2.814 |
| 45 mejores, aprendizaje 3e-5 | época 2 | 2.840 |
| 60 mejores, aprendizaje 1.5e-5 | época 3 | 2.815 |

En la página de siempre (`13_comparar.py`), cada voz dice cada frase una vez,
y el usuario encontró que unas frases sonaban mejor con una voz y otras con
otra. La generación tiene azar: con una sola toma, una frase puede ganar por
suerte. Además, las 10 frases de validación no se parecen a lo que lee la app.

## Decisión

**Para decidir entre voces parecidas se vota a ciegas** (`34_votacion.py`):

- 20 frases: las 10 de validación, con la voz real, y 10 como las que lee Read
  Aloud (texto técnico, números, unidades, términos y frases en inglés),
  preparadas igual que en la app (`34_frases.ps1`);
- dos tomas por voz y frase, con dos semillas, generadas como
  `lib\servidor_qwen.py`;
- en cada frase las voces son A, B y C en otro orden, y se vota una o
  «Iguales»;
- Whisper cuenta errores de lectura (una toma "con error" lee notablemente
  peor que la mejor toma de esa frase) y WavLM Large mide el parecido del
  timbre.

**Resultado, y se queda la voz de la app:**

| Voz | Votos | Validación | Textos de la app | Tomas con error | Parecido |
|---|---|---|---|---|---|
| 60 mejores, época 2 (la de la app) | 8 | 5 | 3 | 1 | 0.963 |
| 45 mejores, época 2 | 8 | 3 | 5 | 1 | 0.963 |
| 60 mejores lenta, época 3 | 4 | 2 | 2 | 0 | 0.966 |

(Parecido de la voz real con el mismo centro: 0.978.)

Un empate 8 a 8 en 20 frases no separa a las dos primeras, y las tres leen y
suenan igual por las medidas. La de 45 minutos agregó una palabra que no
estaba en el texto ("con su" → "con su trabajo"); la de la app cambió "ayer"
por algo que Whisper oyó como "allá". Cambiar de voz sin una mejora clara no
vale la pena.

## Alternativas

- **Entrenar los 45 mejores con aprendizaje lento:** se iba a probar si los
  45 minutos ganaban con claridad. Empataron, así que no.
- **Elegir por la validación:** ya falló una vez frente al oído, en la 0010.

## Consecuencias

- Ajustar el aprendizaje o recortar los datos ya no cambia la voz de forma que
  se note: quedan pequeñas variaciones que el azar de cada toma tapa. Una
  mejora clara pediría más voz de buena calidad (falta el capítulo 25
  verdadero) o un modelo base mejor.
- `34_votacion.py` queda como la forma de decidir entre voces parecidas.
- Los puntos de `puntos_v5_45` y `puntos_v5_60_lento` (unos 5 GB) se pueden
  borrar al cerrar el proyecto.
