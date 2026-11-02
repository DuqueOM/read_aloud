"""Transcribe cada clip nuevo con dos motores, para la pagina de revision.

Los clips de 25_cortar_frases.py traen el texto de la transcripcion del
episodio. Aqui cada clip se vuelve a transcribir solo, con Whisper large-v3 y
con Qwen3-ASR-1.7B, los dos con el contexto de voz.toml: de que es la
grabacion y sus nombres propios (ver 22_textos.py, que comparo los motores
con las correcciones del usuario).
Cuando los tres textos coinciden, el texto es casi seguro; cuando no, la
pagina muestra las lecturas distintas para elegir con un clic.

Escribe datos/27_textos/whisper.json y qwen.json.

Uso:
    .venv/Scripts/python.exe     scripts/27_transcribir_clips.py whisper
    .venv_asr/Scripts/python.exe scripts/27_transcribir_clips.py qwen
"""

import importlib.util
import json
import os
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("textos", Path(__file__).parent / "22_textos.py")
textos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(textos)

RAIZ = textos.RAIZ
CORTES = RAIZ / "datos" / "25_cortes"
SALIDA = RAIZ / "datos" / "27_textos"


def clips():
    rutas = {}
    for indice in sorted(CORTES.glob("ep*/indice.json")):
        for clip in json.loads(indice.read_text(encoding="utf-8"))["clips"]:
            rutas[clip["archivo"].removesuffix(".wav")] = indice.parent / clip["archivo"]
    return rutas


def guardar(motor, resultado):
    SALIDA.mkdir(parents=True, exist_ok=True)
    destino = SALIDA / f"{motor}.json"
    previo = json.loads(destino.read_text(encoding="utf-8")) if destino.exists() else {}
    previo.update(resultado)
    destino.write_text(json.dumps(previo, ensure_ascii=False, indent=1), encoding="utf-8")


def pendientes(motor):
    destino = SALIDA / f"{motor}.json"
    hechos = json.loads(destino.read_text(encoding="utf-8")) if destino.exists() else {}
    return {k: v for k, v in clips().items() if k not in hechos}


def con_whisper():
    os.environ["PATH"] = str(RAIZ / "herramientas") + os.pathsep + os.environ["PATH"]
    import whisper
    # Media precision, como 03_transcribir.py: igual de preciso medido contra las
    # correcciones del usuario, y cabe en la tarjeta sin pasar memoria a la RAM.
    import torch
    modelo = whisper.load_model("large-v3", device="cpu", download_root=str(RAIZ / "modelos" / "whisper")).half()
    for capa in modelo.modules():
        if isinstance(capa, torch.nn.LayerNorm):
            capa.float()
    modelo = modelo.cuda()
    from progreso_comun import avance
    lista = list(pendientes("whisper").items())
    total, hechos = len(clips()), len(clips()) - len(lista)
    resultado = {}
    for n, (clave, ruta) in enumerate(lista):
        # Se guarda cada tanto: si algo lo corta, la proxima vez sigue de ahi.
        if n % 50 == 0:
            guardar("whisper", resultado)
            avance("Whisper", hechos + n, total)
        resultado[clave] = modelo.transcribe(whisper.load_audio(str(ruta)), language=textos.voz.IDIOMA,
                                             beam_size=5, best_of=5,
                                             fp16=True, condition_on_previous_text=False,
                                             initial_prompt=textos.CONTEXTO)["text"].strip()
    guardar("whisper", resultado)


def con_qwen():
    import torch
    from qwen_asr import Qwen3ASRModel
    modelo = Qwen3ASRModel.from_pretrained("Qwen/Qwen3-ASR-1.7B", dtype=torch.bfloat16, device_map="cuda:0",
                                           max_inference_batch_size=16)
    lista = list(pendientes("qwen").items())
    resultado = {}
    from progreso_comun import avance
    total, hechos = len(clips()), len(clips()) - len(lista)
    for i in range(0, len(lista), 16):
        if i % 64 == 0:
            guardar("qwen", resultado)
            avance("Qwen3-ASR", hechos + i, total)
        grupo = lista[i:i + 16]
        for (clave, _), r in zip(grupo, modelo.transcribe([str(ruta) for _, ruta in grupo], context=textos.CONTEXTO,
                                                          language=textos.voz.IDIOMA_TEXTO)):
            resultado[clave] = r.text.strip()
    guardar("qwen", resultado)


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).parent))
    import gpu
    gpu.ocupar()
    {"whisper": con_whisper, "qwen": con_qwen}[sys.argv[1]]()
    print(f"{sys.argv[1]}: listo")
