# Historia: experimentos de la primera voz

Scripts con que se probaron caminos para la voz de prueba en octubre de 2026,
antes de quedarse con Qwen3-TTS. Se guardan porque de sus
resultados salieron decisiones que siguen vigentes, sobre todo la
[ADR 0001](../../docs/adr/0001-qwen3-tts-en-vez-de-rvc.md), y porque algunos
scripts de [proceso_qwen](../proceso_qwen) los citan.

**No se mantienen.** Son la copia tal cual de la carpeta de trabajo de la voz de prueba
(los respaldó la rama `wip/voz-entrenamiento`, ya borrada): hablan de la voz de prueba,
toman sus rutas de la carpeta padre de la suya y no leen `voz.toml`. Para
hacer una voz nueva, el camino es [proceso_qwen](../proceso_qwen) y la guía
[docs/voz-personalizada.md](../../docs/voz-personalizada.md).

| Script | Entorno | Qué hizo |
|---|---|---|
| `03_segmentar.py` | `.venv` | Partía la voz de cada capítulo en frases habladas |
| `04_huellas.py` | `.venv` | Huella de voz (ECAPA) de cada frase y de cada referencia; ver la [ADR 0007](../../docs/adr/0007-reconocer-la-voz-con-wavlm.md) |
| `08b_pesos.py` | `applio\.venv` | Sacaba los pesos de inferencia de los puntos de control completos de RVC |
| `09_puntos.py` | `applio\.venv` | Prueba a ciegas de los puntos de control de RVC; sus frases de origen (`datos\09_puntos\fuente`) las reusa `13_comparar.py` |
| `09b_diagnostico.py` | `applio\.venv` | Convertía varias fuentes con todos los puntos de control, para medirlas |
| `09c_medir.py` | `.venv` | Medía cuánto se parecía a la voz de prueba cada conversión; `10c_medir.py` usa la misma medida |
| `10a_motores.py` | `.venv_chatterbox` / `.venv_qwen` | Generaba las frases de prueba con motores que imitan una muestra de voz: Chatterbox Multilingual y Qwen3-TTS |
| `10b_pagina.py` | `applio\.venv` | Pasaba esos motores por RVC, medía la forma de su entonación y armaba la página de escucha |
| `12_textos.py` | — | Página para corregir a mano las transcripciones del conjunto; hoy se corrigen en la revisión única de `28_revision.py` |
| `progreso_entrenamiento.py` | — | Página del avance del entrenamiento de RVC |

## Chatterbox

`chatterbox.txt` es la lista exacta del entorno `.venv_chatterbox` (Python
3.11) que corrió `10a_motores.py chatterbox`, con el sha256 de cada paquete.
Chatterbox mismo se instala desde un commit fijo de git
(`resemble-ai/chatterbox@65b1843`), y uv no admite hash para dependencias de
git: la lista no se puede instalar con `--require-hashes` tal cual. Sin esa
opción, uv igual verifica los hashes que sí están:

```powershell
uv venv .venv_chatterbox --python 3.11 --managed-python
uv pip install --python .venv_chatterbox\Scripts\python.exe --no-deps `
  -r <repo>\voz_personalizada\historia\chatterbox.txt `
  --extra-index-url https://download.pytorch.org/whl/cu128 --index-strategy unsafe-best-match
```

`instalar.ps1` no lo crea: Chatterbox quedó descartado (ADR 0001).
