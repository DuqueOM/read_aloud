"""Separa la voz de la musica y los efectos en cada grabacion.

Usa un modelo Mel-Band RoFormer, el de mejor calidad medida para voces en la
lista de audio-separator. La salida es solo la pista de voz, que es la que se
segmenta y se compara despues.

Uso:
    python 02_separar_voz.py              todas las grabaciones
    python 02_separar_voz.py ep01         una sola
    python 02_separar_voz.py referencias  la voz de referencia

Las referencias pasan por el mismo separador que las grabaciones. Si no, sus
huellas llevarian restos de musica que los clips ya no tienen, y la
comparacion seria entre cosas distintas.
"""

import sys
import time

# comun va primero: pone en el PATH el ffmpeg de la carpeta de trabajo, que
# audio-separator busca por su nombre.
from comun import DATOS, MODELOS, REFERENCIAS

from audio_separator.separator import Separator  # noqa: E402

ENTRADA = DATOS / "01_audio"
SALIDA = DATOS / "02_voz"

MODELO = "vocals_mel_band_roformer.ckpt"


def main() -> None:
    MODELOS.mkdir(parents=True, exist_ok=True)

    pedidos = sys.argv[1:]

    if pedidos == ["referencias"]:
        entrada = REFERENCIAS / "original"
        salida = REFERENCIAS
        archivos = sorted(entrada.glob("*.wav"))
        if not archivos:
            raise SystemExit(f"Pon en {entrada} uno o varios WAV con solo la voz buscada.")
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
