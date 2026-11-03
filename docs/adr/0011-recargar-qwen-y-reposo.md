# 0011. Volver a cargar Qwen en cuanto la tarjeta queda libre, y un reposo sin sondeo

- **Estado:** aceptada. Cambia una consecuencia de la [0005](0005-motor-automatico-y-tarjeta-compartida.md).
- **Fecha:** 1 de noviembre de 2026

## Contexto

Con la [0005](0005-motor-automatico-y-tarjeta-compartida.md), Qwen se queda
cargado y cede la tarjeta a los pasos pesados y a otros programas. Después,
la lectura siguiente lo abría de nuevo, y esa lectura pagaba la carga entera:

| Parte de la carga | Disco en cache | Disco frío |
|---|---|---|
| Importar torch, transformers, peft y qwen_tts | 5 s | 56 s |
| Pesos del modelo base | 5 a 7 s | |
| LoRA: cargarlo y fundirlo | 2 s | |
| Calentar los grupos de 1, 2 y 4 frases | 8 s | |

El registro del servidor decía "16 s" porque contaba desde que las librerías ya
estaban importadas. La espera real era de unos 22 s, y de más de un minuto la
primera vez tras un rato sin usar la carpeta.

Además, en reposo el proceso residente gastaba 25 ms de procesador por
segundo: el hilo de síntesis miraba su cola cada 15 ms, y el pulso de la
ventana corría cada 60 ms aunque no hubiera nada que leer ni mostrar.

## Decisión

- **El proceso residente vuelve a abrir Qwen por su cuenta.** El servidor
  termina con un código que dice por qué (`lib\servidor_qwen.py`): 3 por
  `--inactivo`, 4 por la marca `gpu_ocupada`, 5 porque otro programa usa la
  tarjeta. Cada 30 s sin trabajo, si Qwen no está abierto, no terminó por
  inactividad, no hay marca y la tarjeta tiene `QwenReopenFreeGB` (6 GB)
  libres, se abre y se carga. Si un servidor se cae sin uno de esos códigos,
  el reintento se espacia: 1, 2, 4 minutos, hasta 32.
- **El hilo de síntesis duerme hasta que hay trabajo**, con un evento que
  activa quien encola, en vez de mirar la cola cada 15 ms.
- **El pulso de la ventana baja a 250 ms en reposo** (ventana oculta, nada
  sonando, nada en cola). La tubería lo vuelve a 60 ms en cuanto llega una
  orden, a través del despachador de la ventana, así que empezar a leer no
  espera ese cuarto de segundo.

## Medidas

| | Antes | Después |
|---|---|---|
| Procesador del proceso residente en reposo | 500 ms cada 20 s | 16 ms cada 20 s |
| Qwen tras quitar la marca `gpu_ocupada` | se cargaba con la lectura siguiente | cargado a los 17 s, solo |
| Pedir una lectura con Qwen cargado → primera frase lista | | 1.5 s |

## Alternativas

- **Leer con Piper mientras Qwen carga:** cambiar de voz a media lectura se
  nota más que esperar, y con la recarga sola casi nunca hace falta.
- **Guardar el modelo ya fundido** para saltarse peft y la fusión: ahorra unos
  4 s de una carga que ahora pasa en segundo plano, a cambio de 3.4 GB más en
  disco y de rehacerlo con cada voz nueva. No vale la pena por ahora.
- **Dejar Qwen en la RAM al ceder la tarjeta** y subirlo de nuevo en 1 s: sus
  2.3 GB de RAM pesan en un equipo de 16 GB, y el CUDA graph habría que
  grabarlo otra vez de todos modos.

## Consecuencias

- Tras un entrenamiento, una prueba o un juego en la tarjeta NVIDIA, la voz
  propia vuelve sola en unos 30 s y la lectura siguiente empieza en 1 o 2 s.
- Mientras Read Aloud está abierto, Qwen ocupa casi siempre unos 5 GB de la
  tarjeta y 2.3 GB de RAM. Quien prefiera liberarlos usa `QwenIdleMinutes`, y
  paga la carga en la lectura siguiente, o `QwenReopen = $false`.
- Mientras Qwen no está cargado, `nvidia-smi` corre una vez cada 30 s.
