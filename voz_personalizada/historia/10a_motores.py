"""Genera las frases de la prueba con motores que imitan una muestra de voz.

A diferencia de Piper con RVC, estos motores deciden la entonacion, el ritmo y
las pausas, y la toman en parte de la muestra. Cada motor vive en su propio
entorno, asi que el script recibe el motor:

    .venv_chatterbox/Scripts/python.exe scripts/10a_motores.py chatterbox
    .venv_qwen/Scripts/python.exe scripts/10a_motores.py qwen

Las frases en espanol son las de 09d_comparar.py, para oirlas junto a la voz de prueba
real; las de ingles no tienen original. Mide tambien cuanto tarda cada frase
frente a lo que dura, que es lo que decide si sirve para Read Aloud.

Los modelos se descargan en modelos/hf (HF_HOME).
"""

import json
import os
import random
import sys
import time
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("HF_HOME", str(RAIZ / "modelos" / "hf"))

import numpy as np
import soundfile as sf
import torch

SALIDA = RAIZ / "datos" / "10_motores"
MUESTRA = RAIZ / "datos" / "08_final" / "mi_voz_es" / "ep03_083269.wav"
# Lo que se dice en MUESTRA, palabra por palabra y con sus signos: los motores
# que clonan desde una muestra lo necesitan para alinear el audio con el texto.
MUESTRA_TEXTO = "Escribe aqui, palabra por palabra, lo que se dice en la muestra."
INGLES = [
    "Wait, are you serious? I can't believe we actually made it!",
    "The function returns a list of results, sorted by date.",
]
SEMILLA = 1234


def frases() -> list:
    espanol = json.loads((RAIZ / "datos" / "09_comparar" / "frases.json").read_text(encoding="utf-8"))
    return ([(f"es{f['n']}", "es", f["texto"]) for f in espanol]
            + [(f"en{n}", "en", t) for n, t in enumerate(INGLES, 1)])


def semilla() -> None:
    random.seed(SEMILLA)
    np.random.seed(SEMILLA)
    torch.manual_seed(SEMILLA)
    torch.cuda.manual_seed_all(SEMILLA)


def chatterbox():
    """Chatterbox Multilingual V3 y su version afinada para espanol de Mexico."""
    from huggingface_hub import snapshot_download
    from safetensors.torch import load_file
    from chatterbox.mtl_tts import ChatterboxMultilingualTTS, Conditionals
    from chatterbox.models.s3gen import S3Gen
    from chatterbox.models.t3 import T3
    from chatterbox.models.t3.modules.t3_config import T3Config
    from chatterbox.models.tokenizers import MTLTokenizer
    from chatterbox.models.voice_encoder import VoiceEncoder

    base = Path(snapshot_download("ResembleAI/chatterbox", allow_patterns=[
        "ve.pt", "t3_mtl23ls_v3.safetensors", "s3gen.pt", "grapheme_mtl_merged_expanded_v1.json",
        "conds.pt", "Cangjie5_TC.json"]))
    es_mx = Path(snapshot_download("ResembleAI/Chatterbox-Multilingual-es-mx-latam", allow_patterns=[
        "t3_es_mx_latam.safetensors", "s3gen_v3.pt"]))

    def cargar(t3_archivo: Path, s3gen_archivo: Path):
        # Igual que ChatterboxMultilingualTTS.from_local, pero con archivos de
        # dos repositorios: la libreria 0.1.x aun no carga el paquete es_mx.
        ve = VoiceEncoder()
        ve.load_state_dict(torch.load(base / "ve.pt", weights_only=True))
        t3 = T3(T3Config.multilingual())
        estado = load_file(t3_archivo)
        t3.load_state_dict(estado["model"][0] if "model" in estado else estado)
        s3gen = S3Gen()
        # s3gen_v3.pt no guarda los filtros mel ni la ventana del tokenizador,
        # que S3Gen calcula al crearse. Cualquier otra ausencia es un error.
        faltan, sobran = s3gen.load_state_dict(torch.load(s3gen_archivo, weights_only=True), strict=False)
        if sobran or set(faltan) - {"tokenizer._mel_filters", "tokenizer.window"}:
            raise RuntimeError(f"{s3gen_archivo.name} no encaja: faltan {faltan}, sobran {sobran}")
        modelo = ChatterboxMultilingualTTS(
            t3.eval(), s3gen.eval(), ve.eval(), MTLTokenizer(str(base / "grapheme_mtl_merged_expanded_v1.json")),
            "cuda", conds=Conditionals.load(base / "conds.pt").to("cuda"))
        modelo.t3.to("cuda"); modelo.s3gen.to("cuda"); modelo.ve.to("cuda")
        return modelo

    ajustes = {"normal": {"exaggeration": 0.5, "cfg_weight": 0.5},
               "expresivo": {"exaggeration": 0.7, "cfg_weight": 0.3}}
    for nombre, t3_archivo, s3gen_archivo, idiomas in (
        ("chatterbox", base / "t3_mtl23ls_v3.safetensors", base / "s3gen.pt", {"es", "en"}),
        ("chatterbox_es_mx", es_mx / "t3_es_mx_latam.safetensors", es_mx / "s3gen_v3.pt", {"es"}),
    ):
        modelo = cargar(t3_archivo, s3gen_archivo)

        def generar(texto, idioma, ajuste, modelo=modelo):
            semilla()
            wav = modelo.generate(texto, language_id=idioma, audio_prompt_path=str(MUESTRA),
                                  **ajustes[ajuste])
            return wav.squeeze(0).cpu().numpy(), modelo.sr

        yield nombre, generar, idiomas, list(ajustes)
        del modelo
        torch.cuda.empty_cache()


def qwen():
    """Qwen3-TTS 1.7B Base, clonando con la muestra y su transcripcion."""
    from qwen_tts import Qwen3TTSModel

    modelo = Qwen3TTSModel.from_pretrained("Qwen/Qwen3-TTS-12Hz-1.7B-Base", device_map="cuda:0",
                                           dtype=torch.bfloat16, attn_implementation="sdpa")
    audio, tasa = sf.read(MUESTRA, dtype="float32")
    indicacion = modelo.create_voice_clone_prompt(ref_audio=(audio, tasa), ref_text=MUESTRA_TEXTO)
    idiomas = {"es": "Spanish", "en": "English"}

    def generar(texto, idioma, ajuste):
        semilla()
        wavs, sr = modelo.generate_voice_clone(text=texto, language=idiomas[idioma],
                                               voice_clone_prompt=indicacion)
        return wavs[0], sr

    yield "qwen", generar, {"es", "en"}, ["normal"]


def main() -> None:
    motor = sys.argv[1]
    audio_dir = SALIDA / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    tiempos_archivo = SALIDA / f"tiempos_{motor}.json"
    tiempos = {}

    for nombre, generar, idiomas, ajustes in {"chatterbox": chatterbox, "qwen": qwen}[motor]():
        generar("Hola.", "es", ajustes[0])  # calentamiento: la primera llamada compila y reserva memoria
        for ajuste in ajustes:
            version = nombre if ajuste == "normal" else f"{nombre}_{ajuste}"
            for clave, idioma, texto in frases():
                if idioma not in idiomas:
                    continue
                torch.cuda.synchronize()
                inicio = time.perf_counter()
                audio, tasa = generar(texto, idioma, ajuste)
                torch.cuda.synchronize()
                segundos = time.perf_counter() - inicio
                sf.write(audio_dir / f"{clave}_{version}.wav", np.asarray(audio, dtype=np.float32), tasa)
                duracion = len(audio) / tasa
                tiempos[f"{clave}_{version}"] = {"generacion_s": segundos, "duracion_s": duracion}
                print(f"{clave}_{version}: {segundos:.1f} s para {duracion:.1f} s de audio", flush=True)
        tiempos_archivo.write_text(json.dumps(tiempos, indent=1), encoding="utf-8")

    print(f"memoria maxima de la tarjeta: {torch.cuda.max_memory_allocated() / 2**30:.1f} GB")


if __name__ == "__main__":
    main()
