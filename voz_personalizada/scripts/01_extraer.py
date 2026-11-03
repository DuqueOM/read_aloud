"""Extrae el audio de cada grabacion de la carpeta de origen.

Copia la primera pista de audio, sin tocarla, a datos/01_audio/epNN.wav en
coma flotante de 32 bits y a su frecuencia original. Cualquier conversion de
calidad, si hace falta, la hacen despues los pasos que la necesitan.

Uso:
    python 01_extraer.py            todas las grabaciones
    python 01_extraer.py ep01       una sola
"""

import subprocess
import sys

from comun import DATOS, HERRAMIENTAS, grabaciones

SALIDA = DATOS / "01_audio"


def main() -> None:
    SALIDA.mkdir(parents=True, exist_ok=True)
    pedidos = sys.argv[1:]

    for episodio, archivo in grabaciones().items():
        if pedidos and episodio not in pedidos:
            continue
        destino = SALIDA / f"{episodio}.wav"
        if destino.exists():
            print(f"{episodio}: ya estaba extraido")
            continue
        subprocess.run(
            [
                str(HERRAMIENTAS / "ffmpeg.exe"),
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-i",
                str(archivo),
                "-vn",
                "-map",
                "0:a:0",
                "-c:a",
                "pcm_f32le",
                str(destino),
            ],
            check=True,
        )
        print(f"{episodio}: {archivo.name}")


if __name__ == "__main__":
    main()
