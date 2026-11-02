"""Genera las frases de prueba con las epocas de Qwen3-TTS afinado.

Carga el modelo base, le pone las capas LoRA de cada epoca y habla como la
voz "propia", sin muestra de referencia: la voz ya esta en el modelo. Genera
sin streaming, que es la disposicion en que se entrena: todo el texto antes
del audio. La epoca 0 es el modelo base, para comprobar el camino. Las
frases en espanol son las 10 que no entraron al entrenamiento. Prueba tambien
si el modelo obedece indicaciones de estilo.

Deja los audios en datos/10_motores/audio como qwen_mi_voz_eNN, para que
10b_pagina.py los pase por RVC y los ponga en la pagina, y 10c_medir.py los
mida junto a los demas motores.

Corre en el entorno de Qwen:
    .venv_qwen/Scripts/python.exe scripts/11c_probar_qwen.py 4 8 12
    .venv_qwen/Scripts/python.exe scripts/11c_probar_qwen.py --puntos puntos_v2 2 4 6

Las versiones de una salida distinta de "puntos" llevan su nombre: qwen_mi_voz_v2_e04.
Un punto de mitad de epoca se pide como 1.5, y queda como qwen_mi_voz_v2_e01_5.
"""

import json
import os
import sys
import time
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("HF_HOME", str(RAIZ / "modelos" / "hf"))

import numpy as np
import soundfile as sf
import torch
from peft import LoraConfig, inject_adapter_in_model, set_peft_model_state_dict
from qwen_tts import Qwen3TTSModel
from safetensors.torch import load_file

PUNTOS = RAIZ / "datos" / "11_qwen" / "puntos"
SALIDA = RAIZ / "datos" / "10_motores" / "audio"
INGLES = [
    "Wait, are you serious? I can't believe we actually made it!",
    "The function returns a list of results, sorted by date.",
]
INDICACIONES = {
    "alegre": "Habla con mucha alegría y energía, como si estuvieras emocionada.",
    "triste": "Habla en voz baja y triste, casi a punto de llorar.",
}
VOZ = "propia"
ID_VOZ = 3000  # el mismo hueco que usa la receta oficial
SEMILLA = 1234


def preparar():
    ajuste = json.loads((PUNTOS / "ajuste.json").read_text(encoding="utf-8"))
    qwen = Qwen3TTSModel.from_pretrained(ajuste["modelo_base"], device_map="cuda:0", dtype=torch.bfloat16,
                                         attn_implementation="sdpa")
    modelo = qwen.model
    inject_adapter_in_model(LoraConfig(r=ajuste["r"], lora_alpha=ajuste["lora_alpha"], lora_dropout=0.0,
                                       target_modules=ajuste["target_modules"]), modelo.talker)
    modelo.talker.eval()

    # Lo mismo que escribe la receta oficial en el config del modelo afinado.
    voz = load_file(PUNTOS / "voz.safetensors")["voz"]
    with torch.no_grad():
        modelo.talker.model.codec_embedding.weight[ID_VOZ] = voz[0].to(modelo.dtype).to(modelo.device)
    for config in (modelo.config, ):
        config.tts_model_type = "custom_voice"
        config.talker_config.spk_id = {VOZ: ID_VOZ}
        config.talker_config.spk_is_dialect = {VOZ: False}
    modelo.tts_model_type = "custom_voice"
    modelo.supported_speakers = modelo.config.talker_config.spk_id.keys()
    return qwen


def nombre_epoca(epoca: str) -> str:
    """"2" es epoca_02, y "1.5", el punto de mitad de la epoca 2, epoca_01_5."""
    entera, _, fraccion = epoca.partition(".")
    return f"{int(entera):02d}" + (f"_{fraccion}" if fraccion.strip("0") else "")


def main() -> None:
    global PUNTOS
    argumentos = sys.argv[1:]
    prefijo = "qwen_mi_voz"
    if argumentos[:1] == ["--puntos"]:
        PUNTOS = PUNTOS.parent / argumentos[1]
        prefijo += "_" + argumentos[1].removeprefix("puntos_")
        argumentos = argumentos[2:]
    epocas = [nombre_epoca(e) for e in argumentos]
    frases = json.loads((RAIZ / "datos" / "09_comparar" / "frases.json").read_text(encoding="utf-8"))
    lista = ([(f"es{f['n']}", "Spanish", f["texto"]) for f in frases]
             + [(f"en{n}", "English", t) for n, t in enumerate(INGLES, 1)])

    # Ocupa la tarjeta: Read Aloud lee con Piper mientras tanto.
    sys.path.insert(0, str(Path(__file__).parent))
    import gpu
    gpu.ocupar()
    qwen = preparar()
    tiempos = {}
    for epoca in epocas:
        # La epoca 0 es el modelo base: las capas LoRA recien creadas no cambian nada.
        if epoca != "00":
            estado = load_file(PUNTOS / f"epoca_{epoca}.safetensors")
            set_peft_model_state_dict(qwen.model.talker, {k: v.to(qwen.model.device) for k, v in estado.items()})
        version = f"{prefijo}_e{epoca}"
        for clave, idioma, texto in lista:
            torch.manual_seed(SEMILLA)
            torch.cuda.synchronize()
            inicio = time.perf_counter()
            wavs, sr = qwen.generate_custom_voice(text=texto, language=idioma, speaker=VOZ,
                                                    non_streaming_mode=True)
            torch.cuda.synchronize()
            tiempos[f"{clave}_{version}"] = {"generacion_s": time.perf_counter() - inicio,
                                             "duracion_s": len(wavs[0]) / sr}
            sf.write(SALIDA / f"{clave}_{version}.wav", np.asarray(wavs[0], dtype=np.float32), sr)
        print(f"epoca {epoca}: listo", flush=True)

    # Indicaciones de estilo, con la ultima epoca pedida.
    for nombre, indicacion in INDICACIONES.items():
        for clave, idioma, texto in lista[:3]:
            torch.manual_seed(SEMILLA)
            wavs, sr = qwen.generate_custom_voice(text=texto, language=idioma, speaker=VOZ, instruct=indicacion,
                                                    non_streaming_mode=True)
            sf.write(SALIDA / f"{clave}_{prefijo}_e{epocas[-1]}_{nombre}.wav",
                     np.asarray(wavs[0], dtype=np.float32), sr)
    (RAIZ / "datos" / "11_qwen" / "tiempos.json").write_text(json.dumps(tiempos, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
