# 0005. Motor automático con respaldo a Piper, y la tarjeta compartida

- **Estado:** aceptada
- **Fecha:** 29 de octubre de 2026

## Contexto

La voz de Qwen3-TTS necesita una tarjeta NVIDIA con memoria suficiente, su
entorno de Python y el modelo base, y una voz entrenada. Quien clone el
repositorio casi nunca tendrá las tres cosas, y el lector no debe quedarse
mudo por eso.

Hubo dos problemas más en el uso real:

- Qwen tarda unos 16 s en cargar. Cerrarlo a los 15 minutos sin leer hacía
  esperar hasta 20 s la lectura siguiente.
- Con otro trabajo usando la tarjeta (transcribir, entrenar), los dos se
  reparten 8 GB y Windows pasa memoria a la RAM. Qwen tardó 7 minutos en
  cargar y 4 en generar cuatro frases, y Whisper terminó con un error de CUDA.

## Decisión

- **`EngineEs` y `EngineEn` valen `auto` por defecto.** Se usa Qwen solo si su
  voz está instalada en `QwenWorkDir` y hay una tarjeta NVIDIA de al menos
  `QwenMinVramGB` (7 GB); si no, Piper, la voz de siempre. `piper` fuerza
  Piper.
- **Si Qwen falla en una lectura, la frase se lee con Piper.** Si el proceso no
  responde ni al reabrirlo, el resto de la sesión también va con Piper.
- **Qwen se queda cargado.** Se cierra solo cuando, tras un minuto sin leer,
  otro programa usa 1.5 GB más de la tarjeta que cuando Qwen cargó. Se
  compara con ese momento, y con lo mínimo que se vio después, porque en
  Windows la memoria que informa CUDA no coincide con la de nvidia-smi; las
  diferencias, en cambio, sí.
- **Los pasos pesados dejan una marca.** Mientras un paso de la voz
  personalizada usa la tarjeta, deja su número de proceso en
  `<trabajo>\gpu_ocupada` (`proceso_qwen\gpu.py`). Mientras ese proceso siga
  vivo, Read Aloud lee con Piper y Qwen se cierra. Una marca de un proceso que
  ya murió no cuenta.

## Alternativas

- **Que el usuario elija el motor a mano:** cualquier configuración rota
  dejaría al lector mudo o esperando.
- **Que Qwen comparta la tarjeta siempre:** probado. Las esperas de minutos
  son peores que leer un rato con Piper.

## Consecuencias

- El repositorio funciona igual que antes en cualquier equipo. La voz propia
  es un agregado.
- Mientras se procesa o entrena una voz, Read Aloud lee con Piper. Al terminar
  vuelve a Qwen en la lectura siguiente, con unos 16 s de carga. (Cambiado
  por la [0011](0011-recargar-qwen-y-reposo.md): ahora se vuelve a cargar
  solo, en cuanto la tarjeta queda libre.)
- Qwen ocupa unos 5 GB de la tarjeta mientras el lector está abierto, salvo
  que otro programa la pida.
