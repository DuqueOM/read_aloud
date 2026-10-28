"""Arma el conjunto de entrenamiento con los clips sin reverberacion.

Es lo que decidio la prueba a ciegas de 07b_prueba.py la primera vez que se
hizo este proceso, en octubre de 2026, con ocho clips:

- Sin reverberacion fue la mejor, sola o seguida de resemble-enhance, en cuatro
  de los seis clips donde hubo preferencia, y nunca sono artificial. El
  original sono artificial en cuatro clips: el eco que dejo la separacion.
- resemble-enhance sono artificial en cuatro de los dieciseis clips en que se
  uso, solo o combinado. Un defecto en el conjunto, el modelo de voz lo
  aprende como parte del timbre, asi que se descarta.

Con otra voz conviene repetir la prueba: si el resultado cambia, aqui se
cambia la carpeta de entrada.

Los clips de 07_mejora/sin_reverb se vuelven a igualar en volumen, porque
quitar la reverberacion baja un poco el nivel, con la misma regla que
06_conjunto.py.

Uso:
    python 07c_conjunto_final.py
"""

import importlib.util
from pathlib import Path

import soundfile as sf

from comun import DATOS, NOMBRE

ENTRADA = DATOS / "07_mejora" / "sin_reverb"
SALIDA = DATOS / "08_final" / NOMBRE

_spec = importlib.util.spec_from_file_location("conjunto", Path(__file__).parent / "06_conjunto.py")
conjunto = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(conjunto)


def main() -> None:
    SALIDA.mkdir(parents=True, exist_ok=True)
    for viejo in SALIDA.glob("*.wav"):
        viejo.unlink()

    total = 0.0
    archivos = sorted(ENTRADA.glob("*.wav"))
    for archivo in archivos:
        audio, tasa = sf.read(archivo, dtype="float32")
        audio = conjunto.igualar_volumen(audio)
        sf.write(SALIDA / archivo.name, audio, tasa, subtype="PCM_24")
        total += len(audio) / tasa

    print(f"{len(archivos)} clips, {total / 60:.1f} min en {SALIDA}")


if __name__ == "__main__":
    main()
