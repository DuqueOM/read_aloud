"""Transcribe la voz separada de cada capitulo con tiempos por palabra.

Los tiempos de cada palabra son lo que permite cortar entre palabras en vez
de cortar donde hay silencio: cuando dos personas hablan seguido no hay
silencio entre ellos, pero si un limite entre la ultima palabra de uno y la
primera del otro.

Se usa large-v3, el modelo mas preciso de Whisper, sobre la voz ya separada:
sin musica, la transcripcion y los tiempos salen mejores.

Uso:
    python scripts/03_transcribir.py            todos los capitulos
    python scripts/03_transcribir.py ep01       uno solo
"""

import json
import sys
import time
from math import gcd
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
import whisper
from scipy.signal import resample_poly

RAIZ = Path(__file__).resolve().parent.parent
ENTRADA = RAIZ / "datos" / "02_voz"
SALIDA = RAIZ / "datos" / "03_transcripcion"
MODELOS = RAIZ / "modelos" / "whisper"

TASA = 16000


def cargar_16k(archivo: Path) -> np.ndarray:
    audio, tasa = sf.read(archivo, dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    divisor = gcd(tasa, TASA)
    return resample_poly(audio, TASA // divisor, tasa // divisor).astype(np.float32)


def main() -> None:
    SALIDA.mkdir(parents=True, exist_ok=True)
    MODELOS.mkdir(parents=True, exist_ok=True)

    pedidos = sys.argv[1:]
    archivos = sorted(ENTRADA.glob("ep*_voz.wav"))
    if pedidos:
        archivos = [a for a in archivos if a.stem.replace("_voz", "") in pedidos]

    # large-v3, el modelo mas preciso, en la tarjeta y a media precision, que
    # es como lo corre OpenAI en una tarjeta. A precision completa casi no
    # cabia en sus 8 GB y fue cuatro veces mas lento que el procesador; pero
    # en el procesador, con la computadora en uso, un capitulo llego a tardar
    # 174 minutos. A media precision los pesos ocupan 3 GB en vez de 6. Las
    # LayerNorm se quedan en float32: Whisper las calcula asi de todos modos.
    sys.path.insert(0, str(Path(__file__).parent))
    import gpu
    gpu.ocupar()
    # Se carga en el procesador y se pasa a la tarjeta ya en media precision:
    # cargarlo directo en la tarjeta deja reservados los 6 GB de float32 y el
    # resto no cabe (un capitulo tardo 19 minutos en vez de 2).
    modelo = whisper.load_model("large-v3", device="cpu", download_root=str(MODELOS)).half()
    for capa in modelo.modules():
        if isinstance(capa, torch.nn.LayerNorm):
            capa.float()
    modelo = modelo.cuda()

    for archivo in archivos:
        episodio = archivo.stem.replace("_voz", "")
        destino = SALIDA / f"{episodio}.json"
        if destino.exists():
            print(f"{episodio}: ya estaba transcrito")
            continue

        inicio = time.time()
        resultado = modelo.transcribe(
            cargar_16k(archivo),
            language="es",
            word_timestamps=True,
            # Sin arrastrar el texto anterior: con silencios largos entre
            # voces, arrastrarlo hace que Whisper repita o invente frases.
            condition_on_previous_text=False,
            temperature=0.0,
            fp16=True,
        )

        palabras = []
        for segmento in resultado["segments"]:
            for p in segmento.get("words", []):
                palabras.append({
                    "texto": p["word"].strip(),
                    "inicio": round(float(p["start"]), 3),
                    "fin": round(float(p["end"]), 3),
                    "prob": round(float(p.get("probability", 0.0)), 3),
                })

        destino.write_text(
            json.dumps({"episodio": episodio, "palabras": palabras}, ensure_ascii=False, indent=1),
            encoding="utf-8",
        )
        print(f"{episodio}: {len(palabras)} palabras en {time.time() - inicio:.0f} s")


if __name__ == "__main__":
    main()
