# 0013. Un pyproject.toml y un uv.lock para los tres entornos

- **Estado:** aceptada
- **Fecha:** 2 de noviembre de 2026

## Contexto

Los entornos del proceso se instalaban con tres listas cerradas
(`requisitos\principal.txt`, `qwen.txt` y `asr.txt`): cada una con todos los
paquetes del entorno, transitivos incluidos, su versión y su sha256, instalada
con `uv pip install --no-deps --require-hashes`. Reproducían bien lo probado,
pero:

- no decían qué paquetes se usan de verdad y cuáles solo llegan como
  dependencia de otro: 238 líneas para 27 paquetes directos;
- cambiar una versión obligaba a resolver a mano y regenerar la lista con un
  comando largo, sin nada que comprobara que las tres seguían siendo
  coherentes;
- `--no-deps` escondía lo que faltaba o sobraba: en `.venv_asr` estaba gradio
  con 32 dependencias que nada usa.

No pueden ser un solo entorno: el principal usa transformers 5.21, qwen-tts
pide exactamente 4.57.3 y qwen-asr exactamente 4.57.6.

## Decisión

- **`voz_personalizada\pyproject.toml`**, sin paquete propio (`package =
  false`), con un grupo de dependencias por entorno: `principal`, `qwen` y
  `asr`, cada uno con sus paquetes directos en la versión probada.
- **Los tres grupos, declarados en conflicto** (`[tool.uv] conflicts`): uv
  resuelve cada uno por su lado, y un solo `uv.lock` guarda los tres.
- **PyTorch desde su índice de CUDA 12.8**, explícito: solo torch, torchaudio
  y torchvision salen de ahí.
- **gradio, fuera** con un marcador que nunca se cumple
  (`override-dependencies`): qwen-tts y qwen-asr lo piden solo para su demo.
- **`exclude-newer` en la fecha en que se armaron los entornos** (29 de
  octubre de 2026), para que las dependencias transitivas salgan con las
  versiones de entonces. Las 9 que igual cambiaban (8 del principal, que se
  armó antes, y pillow, que sin gradio subía a la 13) se fijan a mano en su
  grupo, con un comentario.
- **`instalar.ps1` crea cada entorno con `uv sync --frozen`** y
  `UV_PROJECT_ENVIRONMENT`, en la misma carpeta de siempre: Read Aloud no
  cambia.

Los opcionales (Applio, con Python 3.12 y los requisitos de otro proyecto, y
resemble-enhance, con Python 3.11) siguen con sus listas de `requisitos\`.

## Cómo se validó

- **Versiones:** `uv export` de cada grupo contra la lista probada: los 90
  paquetes del principal y los 53 de qwen, iguales; asr, igual salvo gradio y
  sus 33 paquetes.
- **Archivos:** para cada paquete, al menos un sha256 del lock coincide con
  los de la lista probada. La única excepción fue jinja2 en `asr.txt`, que no
  traía su hash; en el lock tiene los mismos que en `qwen.txt`.
- **Instalación desde cero** con `instalar.ps1` en una carpeta nueva, con
  Python propio: 1.7 minutos con los paquetes ya en la caché de uv. Y trabajo
  real en la tarjeta con cada entorno nuevo: `.venv_qwen` generó una frase con
  la voz de la app por `lib\servidor_qwen.py`, `.venv` la transcribió con
  Whisper large-v3 y `.venv_asr` con Qwen3-ASR, las dos sin errores.

## Alternativas

- **Seguir con las listas:** reproducen igual, pero no se pueden mantener sin
  volver a resolver a mano.
- **Un pyproject.toml por entorno:** tres locks que no se ven entre sí, y
  tres veces la configuración del índice de PyTorch.
- **conda o pixi:** otra herramienta más, cuando uv ya es la que crea los
  entornos y baja Python.

## Consecuencias

- Para cambiar una versión: editar el grupo, `uv lock`, probar el paso que la
  usa.
- Volver a correr `instalar.ps1` deja cada entorno igual al lock: en
  `.venv_asr` existente, eso quita gradio y lo que lo acompañaba.
- `uv.lock` solo trae Windows de 64 bits (`environments`), que es donde se
  probó.
