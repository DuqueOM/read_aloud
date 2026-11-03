"""Calcula la huella de voz de cada frase y de cada clip de referencia.

La huella es un vector de 192 numeros que resume como suena una voz, sin
importar lo que dice. Dos frases de la misma persona dan vectores parecidos,
y eso es lo que permite encontrar una voz entre todas las demas.

Se usa ECAPA-TDNN de SpeechBrain, entrenado para verificar hablantes. Las
huellas se guardan en disco: calcularlas es lo lento, compararlas es
instantaneo, asi que se pueden probar referencias distintas sin repetir esto.

Uso:
    python scripts/04_huellas.py
"""

import json
from math import gcd
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from scipy.signal import resample_poly
from speechbrain.inference.speaker import EncoderClassifier

RAIZ = Path(__file__).resolve().parent.parent
FRASES = RAIZ / "datos" / "03_frases"
REFERENCIAS = RAIZ / "referencias"
HUELLAS = RAIZ / "datos" / "04_huellas"
MODELOS = RAIZ / "modelos" / "ecapa"

TASA = 16000


def cargar(archivo: Path) -> np.ndarray:
    audio, tasa = sf.read(archivo, dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if tasa != TASA:
        divisor = gcd(tasa, TASA)
        audio = resample_poly(audio, TASA // divisor, tasa // divisor).astype(np.float32)
    return audio


def huella(modelo, audio: np.ndarray) -> np.ndarray:
    with torch.no_grad():
        senal = torch.from_numpy(audio).unsqueeze(0).to(modelo.device)
        vector = modelo.encode_batch(senal).squeeze().cpu().numpy()
    return vector / (np.linalg.norm(vector) + 1e-9)


def main() -> None:
    HUELLAS.mkdir(parents=True, exist_ok=True)

    dispositivo = "cuda:0" if torch.cuda.is_available() else "cpu"
    modelo = EncoderClassifier.from_hparams(
        source="speechbrain/spkrec-ecapa-voxceleb",
        savedir=str(MODELOS),
        run_opts={"device": dispositivo},
    )

    for carpeta in sorted(p for p in FRASES.iterdir() if p.is_dir()):
        destino = HUELLAS / f"{carpeta.name}.npy"
        if destino.exists():
            print(f"{carpeta.name}: huellas ya calculadas")
            continue

        indice = json.loads((carpeta / "indice.json").read_text(encoding="utf-8"))
        vectores = [huella(modelo, cargar(carpeta / f["archivo"])) for f in indice["frases"]]
        np.save(destino, np.stack(vectores))
        print(f"{carpeta.name}: {len(vectores)} huellas")

    referencias = sorted(REFERENCIAS.glob("*.wav")) if REFERENCIAS.exists() else []
    if referencias:
        vectores = []
        for ref in referencias:
            audio = cargar(ref)
            # Una referencia larga se trocea: varias huellas de 4 s describen
            # mejor una voz que una sola de dos minutos.
            paso = 4 * TASA
            trozos = [audio[i : i + paso] for i in range(0, len(audio), paso)]
            for trozo in trozos:
                if len(trozo) >= TASA * 1.5:
                    vectores.append(huella(modelo, trozo))
        np.save(HUELLAS / "referencias.npy", np.stack(vectores))
        print(f"referencias: {len(vectores)} huellas de {len(referencias)} archivos")
    else:
        print("sin referencias todavia: deja los clips en la carpeta referencias")


if __name__ == "__main__":
    main()
