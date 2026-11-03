"""Parte la pista de voz de cada video en frases habladas.

El detector de habla trabaja a 16 kHz, que es lo que espera, pero los cortes
se hacen sobre la voz separada en su calidad original de 44.1 kHz: la calidad
del material de entrenamiento no se rebaja en ningun paso.

Cada frase queda como un WAV mono de 24 bits, y un indice JSON por video
guarda de donde salio cada una, para poder volver al video si hace falta.

Uso:
    python scripts/03_segmentar.py            todos los videos separados
    python scripts/03_segmentar.py ep01       uno solo
"""

import json
import sys
from math import gcd
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from scipy.signal import resample_poly
from silero_vad import get_speech_timestamps, load_silero_vad

RAIZ = Path(__file__).resolve().parent.parent
ENTRADA = RAIZ / "datos" / "02_voz"
SALIDA = RAIZ / "datos" / "03_frases"

TASA_VAD = 16000

# Frases muy cortas no aportan al entrenamiento y suelen ser respiraciones o
# restos de musica. Las muy largas se parten, porque casi siempre mezclan dos
# voces que hablan seguido.
MIN_SEGUNDOS = 1.0
MAX_SEGUNDOS = 12.0

# Margen alrededor de cada frase para no comerse la primera consonante ni el
# final de la ultima vocal.
MARGEN_MS = 120


def a_mono(audio: np.ndarray) -> np.ndarray:
    if audio.ndim == 1:
        return audio
    return audio.mean(axis=1)


def remuestrear(audio: np.ndarray, origen: int, destino: int) -> np.ndarray:
    divisor = gcd(origen, destino)
    return resample_poly(audio, destino // divisor, origen // divisor)


def segmentar(archivo: Path, modelo) -> dict:
    episodio = archivo.stem.replace("_voz", "")
    audio, tasa = sf.read(archivo, dtype="float32", always_2d=False)
    mono = a_mono(audio)

    para_vad = remuestrear(mono, tasa, TASA_VAD).astype(np.float32)
    marcas = get_speech_timestamps(
        torch.from_numpy(para_vad),
        modelo,
        sampling_rate=TASA_VAD,
        threshold=0.5,
        min_speech_duration_ms=int(MIN_SEGUNDOS * 1000),
        min_silence_duration_ms=250,
        speech_pad_ms=MARGEN_MS,
        max_speech_duration_s=MAX_SEGUNDOS,
    )

    carpeta = SALIDA / episodio
    carpeta.mkdir(parents=True, exist_ok=True)

    frases = []
    for numero, marca in enumerate(marcas):
        inicio = marca["start"] / TASA_VAD
        fin = marca["end"] / TASA_VAD
        duracion = fin - inicio
        if duracion < MIN_SEGUNDOS:
            continue

        trozo = mono[int(inicio * tasa) : int(fin * tasa)]
        pico = float(np.max(np.abs(trozo))) if trozo.size else 0.0
        nivel = float(np.sqrt(np.mean(trozo**2))) if trozo.size else 0.0

        nombre = f"{episodio}_{numero:04d}.wav"
        sf.write(carpeta / nombre, trozo, tasa, subtype="PCM_24")

        frases.append(
            {
                "archivo": nombre,
                "inicio": round(inicio, 3),
                "fin": round(fin, 3),
                "duracion": round(duracion, 3),
                "pico": round(pico, 4),
                "nivel_db": round(20 * np.log10(nivel + 1e-9), 1),
            }
        )

    indice = {"episodio": episodio, "tasa": tasa, "frases": frases}
    (carpeta / "indice.json").write_text(json.dumps(indice, indent=1), encoding="utf-8")
    return indice


def main() -> None:
    pedidos = sys.argv[1:]
    archivos = sorted(ENTRADA.glob("ep*_voz.wav"))
    if pedidos:
        archivos = [a for a in archivos if a.stem.replace("_voz", "") in pedidos]

    modelo = load_silero_vad()

    for archivo in archivos:
        indice = segmentar(archivo, modelo)
        total = sum(f["duracion"] for f in indice["frases"])
        print(f"{indice['episodio']}: {len(indice['frases'])} frases, {total / 60:.1f} min de voz")


if __name__ == "__main__":
    main()
