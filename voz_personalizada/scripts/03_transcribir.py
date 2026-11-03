"""Transcribe la voz separada de cada grabacion con tiempos por palabra.

Los tiempos de cada palabra son lo que permite cortar entre palabras en vez
de cortar donde hay silencio: cuando dos personas hablan seguido no hay
silencio entre ellas, pero si un limite entre la ultima palabra de una y la
primera de la otra.

Se usa large-v3, el modelo mas preciso de Whisper, sobre la voz ya separada:
sin musica, la transcripcion y los tiempos salen mejores. El idioma sale de
voz.toml.

Uso:
    python 03_transcribir.py            todas las grabaciones
    python 03_transcribir.py ep01       una sola
"""

import json
import sys
import time
from math import gcd
from pathlib import Path

import numpy as np
import soundfile as sf
import whisper
from scipy.signal import resample_poly

from comun import DATOS, IDIOMA, MODELOS as RAIZ_MODELOS

ENTRADA = DATOS / "02_voz"
SALIDA = DATOS / "03_transcripcion"
MODELOS = RAIZ_MODELOS / "whisper"

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

    # large-v3, el modelo mas preciso, a precision completa y en el
    # procesador. En una tarjeta de 8 GB, a precision completa, casi no cabe y
    # fue cuatro veces mas lento: 150 s de audio en 457 s, frente a 112 s en el
    # procesador, con la misma transcripcion y los mismos tiempos. La media
    # precision no es una salida: con .half() falla con "expected scalar type
    # Float but found Half". Ademas deja la tarjeta libre para los demas pasos.
    modelo = whisper.load_model("large-v3", device="cpu", download_root=str(MODELOS))

    for archivo in archivos:
        episodio = archivo.stem.replace("_voz", "")
        destino = SALIDA / f"{episodio}.json"
        if destino.exists():
            print(f"{episodio}: ya estaba transcrito")
            continue

        inicio = time.time()
        resultado = modelo.transcribe(
            cargar_16k(archivo),
            language=IDIOMA,
            word_timestamps=True,
            # Sin arrastrar el texto anterior: con silencios largos entre
            # voces, arrastrarlo hace que Whisper repita o invente frases.
            condition_on_previous_text=False,
            temperature=0.0,
            fp16=False,
        )

        palabras = []
        for segmento in resultado["segments"]:
            for p in segmento.get("words", []):
                palabras.append(
                    {
                        "texto": p["word"].strip(),
                        "inicio": round(float(p["start"]), 3),
                        "fin": round(float(p["end"]), 3),
                        "prob": round(float(p.get("probability", 0.0)), 3),
                    }
                )

        destino.write_text(
            json.dumps({"episodio": episodio, "palabras": palabras}, ensure_ascii=False, indent=1),
            encoding="utf-8",
        )
        print(f"{episodio}: {len(palabras)} palabras en {time.time() - inicio:.0f} s")


if __name__ == "__main__":
    main()
