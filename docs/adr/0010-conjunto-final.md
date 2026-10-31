# 0010. Entrenar con los 60 mejores minutos

- **Estado:** propuesta. Se acepta o se cambia según la comparación a ciegas de
  los dos entrenamientos.
- **Fecha:** 31 de octubre de 2026

## Contexto

Con los 70 capítulos de las grabaciones salieron 2094 clips candidatos (107 minutos).
En la revisión el usuario conservó 1529, 76.7 minutos, y corrigió 145 textos.
Entre lo conservado había:

- **un capítulo duplicado:** el 25 descargado era una segunda copia del 24. El
  100 % de su texto propio coincidía, y sus clips son la misma grabación;
- **frases repetidas:** una misma frase aparece 21
  veces;
- **distintas calidades** de audio y de volumen, y clips muy cortos.

## Decisión

`30_seleccion_final.py` quita, en este orden:

1. **Las copias del capítulo duplicado** (30 clips, 1.4 minutos). Repetir un
   clip idéntico solo le da doble peso.
2. **Los clips de menos de 1 s** (27 clips, 0.4 minutos): casi no tienen
   entonación de la que aprender.
3. **Las tomas de más de una misma frase**, dejando las 3 de mejor calidad (26
   clips, 1.1 minutos). No son audio reciclado: el parecido de sus espectros,
   alineados en el tiempo, va de 0.49 a 0.93, contra 1.00 de dos copias de la
   misma grabación. Son tomas distintas, y unas pocas enseñan variedad, pero
   veinte inclinan al modelo hacia esa frase.
4. **Lo de menos calidad, hasta quedar en 60 minutos** (282 clips, 13.8
   minutos).

La **calidad** de un clip es el promedio de su posición, en percentil, en
cinco medidas: PESQ y SI-SDR estimados por TorchAudio-SQUIM (más es mejor), y
el sonido en las pausas, el eco y el ruido del borde (menos es mejor).
Promediar posiciones y no valores evita que una sola medida extrema decida.

**El volumen no se usa para quitar.** El nivel de la voz entre los clips
conservados varía solo 8 dB del 5 % más bajo al 5 % más alto. El conjunto
final se iguala a un mismo nivel, y los gritos y susurros, que salen con otros
niveles, son justo la expresividad que se busca.

## Medidas

En los 60 minutos elegidos mejoran todas las medidas frente a lo conservado:

| Medida (mediana) | Conservado | Elegido |
|---|---|---|
| Sonido en las pausas | −28 dB | −90 dB |
| PESQ | 2.74 | 2.88 |
| SI-SDR | 18.0 dB | 19.3 dB |
| Ruido del borde | −34 dB | −36 dB |
| Eco | −18.9 dB | −19.2 dB |

Las dos fuentes de los capítulos salieron parecidas (PESQ 2.69 y 2.82), así
que no hizo falta descartar ninguna.

## Cómo se valida

Se entrenan dos voces con lo mismo salvo el corte por calidad:

- `mejores60`: 1158 clips, 59.6 minutos;
- `todos`: 1438 clips, 73.4 minutos.

Las dos usan las mismas reglas 1 a 3, sin las 8 frases que se solapan con la
validación, la misma semilla y el aprendizaje de la
[0003](0003-elegir-la-epoca.md). Se comparan a ciegas con la voz real. Si
gana `todos`, esta decisión se reemplaza: más datos pesaron más que la
calidad.

## Consecuencias

- El conjunto queda guardado aparte, listo para cualquier modelo futuro: los
  audios, `metadatos.csv` con el texto, la calidad y si está entre los 60
  mejores, y las 10 frases de validación.
- Faltan el capítulo 25 verdadero y su minuto y medio de voz.
