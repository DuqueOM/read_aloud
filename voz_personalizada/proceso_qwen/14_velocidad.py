"""Mide cuanto tarda Qwen3-TTS afinado en hablar, para llevarlo a Read Aloud.

Read Aloud necesita generar cada frase en menos tiempo del que dura, o la
lectura se detiene entre frases. Se prueban dos cosas que no deberian cambiar
la voz:

- Fundir las capas LoRA en los pesos del modelo: el resultado es el mismo
  calculo, pero en cada paso se hace una multiplicacion en vez de tres.
- Generar varias frases a la vez: el modelo produce un sonido tras otro, y en
  cada paso la tarjeta grafica espera mas a Python que a la cuenta; con varias
  frases en el mismo paso, el tiempo por paso casi no sube.

Como fundir redondea los pesos a bf16, tambien se compara la salida fundida
con la sin fundir en las mismas frases, con la misma semilla: el parecido de
timbre (ECAPA) y el de entonacion tienen que quedar iguales.

Corre en el entorno de Qwen:
    .venv_qwen/Scripts/python.exe scripts/14_velocidad.py
"""

import importlib.util
import json
import os
import time
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("HF_HOME", str(RAIZ / "modelos" / "hf"))

import numpy as np
import soundfile as sf
import torch
from peft.tuners.lora import LoraLayer
from safetensors.torch import load_file
from peft import set_peft_model_state_dict

spec = importlib.util.spec_from_file_location("probar", Path(__file__).parent / "11c_probar_qwen.py")
probar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probar)

PUNTOS = RAIZ / "datos" / "11_qwen" / "puntos_v2"
EPOCA = 2
SALIDA = RAIZ / "datos" / "14_velocidad"
LOTES = (1, 2, 4, 8)


def fundir(modulo: torch.nn.Module) -> None:
    """Suma cada LoRA a su capa y deja la capa original en su lugar."""
    for nombre, hijo in list(modulo.named_children()):
        if isinstance(hijo, LoraLayer):
            hijo.merge()
            setattr(modulo, nombre, hijo.base_layer)
        else:
            fundir(hijo)


def generar(qwen, textos, semilla=probar.SEMILLA):
    torch.manual_seed(semilla)
    torch.cuda.synchronize()
    inicio = time.perf_counter()
    wavs, sr = qwen.generate_custom_voice(text=textos, language=["Spanish"] * len(textos),
                                          speaker=[probar.VOZ] * len(textos), non_streaming_mode=True)
    torch.cuda.synchronize()
    return wavs, sr, time.perf_counter() - inicio


def medir(qwen, frases, etiqueta, guardar=None):
    resultados = {}
    generar(qwen, frases[:1])  # calentamiento
    for lote in LOTES:
        total_gen = total_audio = 0.0
        for i in range(0, len(frases), lote):
            wavs, sr, segundos = generar(qwen, frases[i:i + lote])
            total_gen += segundos
            total_audio += sum(len(w) for w in wavs) / sr
            if guardar is not None and lote == 1:
                sf.write(guardar / f"f{i + 1}.wav", np.asarray(wavs[0], dtype=np.float32), sr)
        resultados[lote] = {"generacion_s": round(total_gen, 1), "audio_s": round(total_audio, 1),
                            "veces_tiempo_real": round(total_gen / total_audio, 2)}
        print(f"{etiqueta}, lote {lote}: {total_gen:.1f} s para {total_audio:.1f} s de audio "
              f"({total_gen / total_audio:.2f} x)", flush=True)
    return resultados


def main() -> None:
    frases = [f["texto"] for f in json.loads((RAIZ / "datos" / "09_comparar" / "frases.json").read_text(encoding="utf-8"))]
    probar.PUNTOS = PUNTOS
    qwen = probar.preparar()
    estado = load_file(PUNTOS / f"epoca_{EPOCA:02d}.safetensors")
    set_peft_model_state_dict(qwen.model.talker, {k: v.to(qwen.model.device) for k, v in estado.items()})

    for carpeta in ("sin_fundir", "fundido"):
        (SALIDA / carpeta).mkdir(parents=True, exist_ok=True)
    informe = {"sin_fundir": medir(qwen, frases, "sin fundir", SALIDA / "sin_fundir")}
    fundir(qwen.model.talker)
    informe["fundido"] = medir(qwen, frases, "fundido", SALIDA / "fundido")
    informe["memoria_gb"] = round(torch.cuda.max_memory_allocated() / 1e9, 2)
    (SALIDA / "velocidad.json").write_text(json.dumps(informe, indent=1), encoding="utf-8")
    print(json.dumps(informe, indent=1))


if __name__ == "__main__":
    main()
