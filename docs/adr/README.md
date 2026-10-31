# Registro de decisiones

Cada archivo es un ADR (*Architecture Decision Record*): una decisión
importante, el problema que resolvía, las alternativas que se probaron y lo que
implica. Sirven para entender por qué el proyecto es como es sin tener que
repetir los experimentos. Si una decisión cambia, se escribe un ADR nuevo que
reemplaza al anterior y se marca el viejo como reemplazado.

Todas son de la voz personalizada, hecha entre octubre de 2026 y hoy con la voz
de una voz de prueba tomada de distintos videos para uso personal. Las cifras son de esas pruebas, en una RTX 5070
Laptop de 8 GB.

| ADR | Decisión | Estado |
|---|---|---|
| [0001](0001-qwen3-tts-en-vez-de-rvc.md) | Qwen3-TTS afinado en vez de Piper con conversión RVC | Aceptada |
| [0002](0002-lora-y-correcciones-a-la-receta.md) | Afinar con LoRA, corrigiendo tres errores de la receta oficial | Aceptada |
| [0003](0003-elegir-la-epoca.md) | Elegir la época por la validación y a ciegas, de oído | Aceptada |
| [0004](0004-lectura-en-tiempo-real.md) | Leer en tiempo real: LoRA fundido, CUDA graph y frases en grupo | Aceptada |
| [0005](0005-motor-automatico-y-tarjeta-compartida.md) | Motor automático con respaldo a Piper, y la tarjeta compartida | Aceptada |
| [0006](0006-clips-de-frases-completas.md) | Cortar por frases completas, no por palabras | Aceptada |
| [0007](0007-reconocer-la-voz-con-wavlm.md) | Reconocer la voz con WavLM y las decisiones del usuario | Aceptada |
| [0008](0008-transcripcion.md) | Whisper en la tarjeta a media precisión, y una segunda lectura con Qwen3-ASR | Aceptada |
| [0009](0009-limpieza-del-audio.md) | Quitar el eco, pero no "mejorar" la voz | Aceptada |
| [0010](0010-conjunto-final.md) | Entrenar con los 60 mejores minutos | Propuesta: falta la comparación a ciegas |
