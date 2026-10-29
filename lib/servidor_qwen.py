"""Proceso residente de Qwen3-TTS para Read Aloud, con una voz afinada.

Habla el mismo protocolo que Piper con --json-input, para que el proceso
residente lo trate igual: lee una orden por linea en la entrada y escribe la
ruta del WAV cuando termina. Una linea puede traer tambien una lista de
ordenes; entonces se generan juntas, que en la tarjeta grafica cuesta casi lo
mismo que una sola, y se escribe una ruta por orden, en el mismo orden.

    {"text": "Hola.", "output_file": "C:\\...\\ra_1_0000.wav", "lang": "es"}

La voz es una carpeta con lo que deja el entrenamiento (ajuste.json,
voz.safetensors y las capas LoRA de la epoca elegida, en lora.safetensors).
El modelo base se toma de la cache de Hugging Face que se indique.

El modelo ocupa unos 5 GB de memoria de video. Si no llega ninguna orden en
--inactivo minutos, el proceso termina y la libera; Read Aloud lo vuelve a
abrir con la siguiente lectura.

Todo lo que no es el protocolo (avisos de las librerias, errores) va a
--registro: si llegara a la salida, Read Aloud lo leeria como una ruta.
"""

import argparse
import json
import os
import queue
import sys
import threading
import time
from pathlib import Path

# La salida del protocolo se separa antes de importar nada: algunas librerias
# escriben avisos en la salida estandar al cargarse.
protocolo = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)

argumentos = argparse.ArgumentParser()
argumentos.add_argument("--voz", required=True, help="carpeta de la voz afinada")
argumentos.add_argument("--hf-home", required=True, help="cache de Hugging Face con el modelo base")
argumentos.add_argument("--registro", required=True)
argumentos.add_argument("--silencio", type=float, default=0.36, help="segundos de silencio al final")
argumentos.add_argument("--inactivo", type=float, default=15.0, help="minutos sin ordenes antes de terminar")
argumentos.add_argument("--lote", type=int, default=4, help="frases que Read Aloud puede mandar juntas")
opciones = argumentos.parse_args()

registro = open(opciones.registro, "a", encoding="utf-8", buffering=1)
os.dup2(registro.fileno(), sys.stdout.fileno())
os.dup2(registro.fileno(), sys.stderr.fileno())
sys.stdout = sys.stderr = registro
os.environ["HF_HOME"] = opciones.hf_home
os.environ["HF_HUB_OFFLINE"] = "1"

import numpy as np
import soundfile as sf
import torch
from huggingface_hub import snapshot_download
from peft import LoraConfig, inject_adapter_in_model, set_peft_model_state_dict
from peft.tuners.lora import LoraLayer
from qwen_tts import Qwen3TTSModel
from safetensors.torch import load_file

sys.path.insert(0, str(Path(__file__).parent))
import qwen_rapido

VOZ = "propia"
ID_VOZ = 3000
IDIOMAS = {"es": "Spanish", "en": "English"}
NIVEL_DB = -19.0  # el de las voces de Piper que usa Read Aloud
PICO_DB = -1.0
UMBRAL_SILENCIO_DB = -45.0
MARGEN_S = 0.05
# Una frase que dura mucho mas o mucho menos de lo esperable por su largo es
# casi siempre un fallo del muestreo (repite, se queda muda o corta): se
# repite una vez. 12.5 codigos por segundo.
SEGUNDOS_POR_LETRA = 0.065
CODIGOS_POR_SEGUNDO = 12.5


def log(mensaje: str) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S"), mensaje, flush=True)


def fundir(modulo: torch.nn.Module) -> None:
    """Suma cada LoRA a su capa y deja la capa original en su lugar."""
    for nombre, hijo in list(modulo.named_children()):
        if isinstance(hijo, LoraLayer):
            hijo.merge()
            setattr(modulo, nombre, hijo.base_layer)
        else:
            fundir(hijo)


def cargar(carpeta: Path):
    ajuste = json.loads((carpeta / "ajuste.json").read_text(encoding="utf-8"))
    # Desde la carpeta local de la cache: con el nombre del modelo, el
    # tokenizador consulta Hugging Face aunque ya tenga todo descargado.
    base = snapshot_download(ajuste["modelo_base"], local_files_only=True)
    qwen = Qwen3TTSModel.from_pretrained(base, device_map="cuda:0", dtype=torch.bfloat16,
                                         attn_implementation="sdpa")
    modelo = qwen.model
    inject_adapter_in_model(LoraConfig(r=ajuste["r"], lora_alpha=ajuste["lora_alpha"], lora_dropout=0.0,
                                       target_modules=ajuste["target_modules"]), modelo.talker)
    estado = load_file(carpeta / "lora.safetensors")
    set_peft_model_state_dict(modelo.talker, {k: v.to(modelo.device) for k, v in estado.items()})
    modelo.talker.eval()
    # Fundir las capas LoRA en los pesos hace cada paso una multiplicacion en
    # vez de tres. Redondea a bf16, pero la prediccion casi no cambia: se midio
    # una divergencia KL media de 0.002 en la primera prediccion de 10 frases,
    # con el mismo codigo mas probable en todas.
    fundir(modelo.talker)

    # Lo mismo que escribe la receta oficial de Qwen en un modelo afinado.
    voz = load_file(carpeta / "voz.safetensors")["voz"]
    with torch.no_grad():
        modelo.talker.model.codec_embedding.weight[ID_VOZ] = voz[0].to(modelo.dtype).to(modelo.device)
    modelo.config.tts_model_type = modelo.tts_model_type = "custom_voice"
    modelo.config.talker_config.spk_id = {VOZ: ID_VOZ}
    modelo.config.talker_config.spk_is_dialect = {VOZ: False}
    modelo.supported_speakers = modelo.config.talker_config.spk_id.keys()

    qwen_rapido.activar(modelo)
    return qwen


def pulir(audio: np.ndarray, tasa: int) -> np.ndarray:
    """Quita el silencio de los extremos, iguala el volumen y agrega la pausa final."""
    audio = np.asarray(audio, dtype=np.float32)
    cuadro = int(0.01 * tasa)
    niveles = 20 * np.log10(np.sqrt(np.convolve(audio ** 2, np.ones(cuadro) / cuadro, mode="same")) + 1e-9)
    con_voz = np.where(niveles > UMBRAL_SILENCIO_DB)[0]
    if con_voz.size:
        margen = int(MARGEN_S * tasa)
        audio = audio[max(0, con_voz[0] - margen):con_voz[-1] + margen]
        habla = audio[np.abs(audio) > 10 ** (UMBRAL_SILENCIO_DB / 20)]
        audio = audio * (10 ** (NIVEL_DB / 20) / (np.sqrt(np.mean(habla ** 2)) + 1e-9))
        pico = np.max(np.abs(audio))
        if pico > 10 ** (PICO_DB / 20):
            audio = audio * (10 ** (PICO_DB / 20) / pico)
    return np.concatenate([audio, np.zeros(int(opciones.silencio * tasa), dtype=np.float32)])


def razonable(texto: str, segundos: float) -> bool:
    esperado = max(0.6, len(texto) * SEGUNDOS_POR_LETRA)
    return 0.35 * esperado <= segundos <= 2.5 * esperado + 1.0


def generar(qwen, ordenes: list[dict]) -> None:
    textos = [o["text"] for o in ordenes]
    idiomas = [IDIOMAS.get(o.get("lang", "es"), "Spanish") for o in ordenes]
    tope = int(CODIGOS_POR_SEGUNDO * (2.5 * max(len(t) for t in textos) * SEGUNDOS_POR_LETRA + 3))
    pendientes = list(range(len(ordenes)))
    for intento in range(2):
        wavs, tasa = qwen.generate_custom_voice(text=[textos[i] for i in pendientes],
                                                language=[idiomas[i] for i in pendientes],
                                                speaker=[VOZ] * len(pendientes),
                                                non_streaming_mode=True, max_new_tokens=tope)
        repetir = []
        for i, wav in zip(pendientes, wavs):
            if intento == 0 and not razonable(textos[i], len(wav) / tasa):
                log(f"duracion rara ({len(wav) / tasa:.1f} s), se repite: {textos[i]!r}")
                repetir.append(i)
                continue
            sf.write(ordenes[i]["output_file"], pulir(wav, tasa), tasa, subtype="PCM_16")
        pendientes = repetir
        if not pendientes:
            break


def leer_entrada(cola: queue.Queue) -> None:
    for linea in open(sys.stdin.fileno(), encoding="utf-8", closefd=False):
        if linea.strip():
            cola.put(linea)
    cola.put(None)


def main() -> None:
    inicio = time.perf_counter()
    qwen = cargar(Path(opciones.voz))
    # El modelo chico se graba una vez por tamano de grupo; se hace aqui para
    # que ninguna lectura pague esa espera.
    for lote in sorted({1, min(2, opciones.lote), opciones.lote}):
        qwen.generate_custom_voice(text=["Hola."] * lote, language=["Spanish"] * lote, speaker=[VOZ] * lote,
                                   non_streaming_mode=True, max_new_tokens=40)
    log(f"modelo cargado en {time.perf_counter() - inicio:.1f} s")

    cola: queue.Queue = queue.Queue()
    threading.Thread(target=leer_entrada, args=(cola,), daemon=True).start()
    while True:
        try:
            linea = cola.get(timeout=opciones.inactivo * 60)
        except queue.Empty:
            log("sin ordenes, termino para liberar la tarjeta grafica")
            return
        if linea is None:
            return
        try:
            datos = json.loads(linea)
            ordenes = datos if isinstance(datos, list) else [datos]
            inicio = time.perf_counter()
            generar(qwen, ordenes)
            log(f"{len(ordenes)} frase(s) en {time.perf_counter() - inicio:.1f} s")
        except Exception as error:  # una orden mala no debe tumbar el proceso
            log(f"error: {error!r}")
            ordenes = ordenes if "ordenes" in locals() else []
        # Una ruta por orden, como Piper, aunque haya fallado: Read Aloud
        # comprueba que el WAV exista.
        for orden in ordenes:
            protocolo.write(orden.get("output_file", "") + "\n")
        protocolo.flush()


if __name__ == "__main__":
    main()
