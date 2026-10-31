# 0003. Elegir la época por la validación y a ciegas, de oído

- **Estado:** aceptada
- **Fecha:** 29 de octubre de 2026

## Contexto

Una época es una pasada por todo el conjunto. Con pocos datos, el modelo
mejora unas pocas épocas y después empieza a memorizar las frases del
entrenamiento: dice mejor esas y peor las nuevas. La primera versión, con
RVC, entrenó 400 épocas; con Qwen3-TTS eso no sirve.

## Decisión

- Guardar las capas LoRA de **cada época**.
- Medir en cada una la **pérdida de validación** con 10 frases que la voz real dijo
  en las grabaciones y que nunca entran al entrenamiento. Son siempre las mismas,
  para comparar rondas.
- Generar esas frases con las mejores épocas, medir entonación (forma y rango
  de la curva de tono frente a la voz real), timbre (ECAPA) y errores de texto
  (Whisper), y elegir **de oído, a ciegas**, en una página con la voz real, la
  voz actual de la app y dos o tres candidatas.

## Resultado

| Ronda | Aprendizaje | Mejor época por validación | Validación |
|---|---|---|---|
| 2.ª | 1e-4 | 1 | 2.845 |
| 3.ª | 3e-5 | 2 | 2.819 |

Con 1e-4 el modelo memorizaba desde la segunda época. Con 3e-5 aprende más
despacio y la validación toca fondo en la segunda. El usuario eligió la **3.ª
ronda, época 2**, que es la voz de Read Aloud hoy.

Las medidas no deciden solas. En la 2.ª ronda el usuario prefirió de oído la
época 1, aunque la 2 medía algo mejor en entonación. Y la 4.ª época de la 3.ª
ronda entonaba bien pero inventaba palabras al final de las frases: más
épocas no es mejor.

## Consecuencias

- Los entrenamientos siguientes usan 3e-5 y guardan cada época. Desde el 31 de
  octubre también guardan, al final de cada época, lo necesario para seguir
  desde ahí si se corta la luz (`--reanudar`).
- Para comparar dos conjuntos, se entrena con los dos usando la misma semilla
  y el mismo ritmo, y se comparan a ciegas.
