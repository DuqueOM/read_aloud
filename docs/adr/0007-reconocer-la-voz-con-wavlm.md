# 0007. Reconocer la voz con WavLM y las decisiones del usuario

- **Estado:** aceptada; reemplaza la curva de ECAPA con referencias
- **Fecha:** 29 de octubre de 2026

## Contexto

La primera versión decidía quién habla comparando cada ventana de 1.5 s con
unas pocas grabaciones de referencia, con huellas ECAPA (entrenadas con
VoxCeleb, voces adultas en entrevistas), y calibrando el parecido en una
probabilidad.

Después de la primera revisión había algo mucho mejor que las referencias: 717
clips que el usuario escuchó y marcó, 516 como conservados y 201 como
descartados.

## Decisión

- La huella es el **promedio de las capas 4 a 12 de WavLM Large** (torchaudio).
- Un **clasificador lineal** (regresión logística sobre las huellas
  estandarizadas), entrenado con esas decisiones, da la probabilidad de que sea
  la voz. Para cortar, se aplica sobre ventanas de 1.5 s cada 0.25 s.
- La decisión se toma con la **frase entera**, promediando sus ventanas, no
  palabra por palabra.

## Medidas

Todas con grabaciones que el clasificador no vio (5 grupos de grabaciones). El AUC
es la probabilidad de que un clip conservado reciba más puntaje que uno
descartado:

| Método | AUC |
|---|---|
| Lo de antes: ECAPA con referencias, mejor de sus puntajes | 0.60 |
| ECAPA con el clasificador | 0.61 |
| WavLM base plus SV con el clasificador | 0.59 |
| **WavLM Large con el clasificador** | **0.74** |
| WavLM Large y las medidas de calidad de la [0010](0010-conjunto-final.md) | 0.80 |

Palabra por palabra no servía: en los clips conservados, el 21 % de las
palabras quedaba por debajo de 0.7, porque sus ventanas tocan la voz de al
lado. Con la frase entera y un umbral de 0.5 se conservan el 84 % de las
frases de clips conservados y el 15 % de las de descartados. Esa cifra es
optimista, porque el clasificador aprendió de esos mismos clips.

## Consecuencias

- Antes de cortar con este método hace falta una revisión inicial con los
  cortes viejos de `04_cortar.py`, que da las decisiones para entrenar el
  clasificador.
- Las decisiones también recogen otros motivos de descarte (ruido, cortes), y
  el clasificador aprende un poco de eso. Para ordenar la revisión es una
  ventaja.
