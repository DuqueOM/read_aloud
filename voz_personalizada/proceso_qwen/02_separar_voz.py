"""Separa la voz de la musica y los efectos en cada video.

Usa un modelo Mel-Band RoFormer, el de mejor calidad medida para voces en la
lista de audio-separator. La salida es solo la pista de voz, que es la que se
segmenta y se compara despues.

Uso:
    python scripts/02_separar_voz.py              todos los videos
    python scripts/02_separar_voz.py ep01         uno solo
    python scripts/02_separar_voz.py referencias  los clips de referencia

Las referencias pasan por el mismo separador que los videos. Si no, sus
huellas llevarian restos de musica que las frases ya no tienen, y la
comparacion seria entre cosas distintas.
"""

import os
import sys
import time
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent

# audio-separator llama a "ffmpeg" por su nombre. Se usa la copia que vive
# dentro del proyecto, para no instalar nada fuera de esta carpeta.
os.environ["PATH"] = str(RAIZ / "herramientas") + os.pathsep + os.environ["PATH"]

from audio_separator.separator import Separator  # noqa: E402
ENTRADA = RAIZ / "datos" / "01_audio"
SALIDA = RAIZ / "datos" / "02_voz"
MODELOS = RAIZ / "modelos"

MODELO = "vocals_mel_band_roformer.ckpt"


def main() -> None:
    MODELOS.mkdir(parents=True, exist_ok=True)

    pedidos = sys.argv[1:]

    if pedidos == ["referencias"]:
        entrada = RAIZ / "referencias" / "original"
        salida = RAIZ / "referencias"
        archivos = sorted(entrada.glob("*.wav"))
    else:
        salida = SALIDA
        archivos = sorted(ENTRADA.glob("ep*.wav"))
        if pedidos:
            archivos = [a for a in archivos if a.stem in pedidos]

    salida.mkdir(parents=True, exist_ok=True)

    separador = Separator(
        output_dir=str(salida),
        model_file_dir=str(MODELOS),
        output_format="WAV",
        output_single_stem="Vocals",
        sample_rate=44100,
    )
    separador.load_model(model_filename=MODELO)

    for archivo in archivos:
        destino = salida / f"{archivo.stem}_voz.wav"
        if destino.exists():
            print(f"{archivo.stem}: ya estaba separado")
            continue

        inicio = time.time()
        generados = separador.separate(str(archivo), {"Vocals": f"{archivo.stem}_voz"})
        print(f"{archivo.stem}: {time.time() - inicio:.0f} s -> {generados}")


if __name__ == "__main__":
    main()
