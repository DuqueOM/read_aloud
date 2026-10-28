"""Arma el conjunto de entrenamiento con las frases que conservaste.

Lee decisiones.json, el que descarga la pagina de revision, y copia las
frases conservadas a datos/06_conjunto/<nombre> con un tratamiento minimo:

- Recorta el silencio de los extremos, dejando 60 ms de margen.
- Iguala el volumen entre frases, para que ninguna pese mas en el
  entrenamiento por haber sido grabada mas fuerte.
- Limita el pico a -1 dB, para que el ajuste de volumen no recorte nada.

No se aplica reduccion de ruido ni ecualizacion: cualquier artefacto que
agreguen, el modelo lo aprenderia como parte de la voz.

Busca decisiones.json primero en datos/05_revision y despues en Descargas.

Uso:
    python 06_conjunto.py                       busca decisiones.json
    python 06_conjunto.py ruta\\decisiones.json
"""

import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

from comun import DATOS, NOMBRE

FRASES = DATOS / "04_cortes"
SALIDA = DATOS / "06_conjunto"

NIVEL_DB = -20.0
PICO_DB = -1.0
UMBRAL_SILENCIO_DB = -45.0
MARGEN_S = 0.06


def buscar_decisiones() -> Path:
    if len(sys.argv) > 1:
        return Path(sys.argv[1])

    candidatos = [
        DATOS / "05_revision" / "decisiones.json",
        *sorted((Path.home() / "Downloads").glob("decisiones*.json"), key=lambda p: p.stat().st_mtime, reverse=True),
    ]
    for c in candidatos:
        if c.exists():
            return c
    raise SystemExit("No encuentro decisiones.json. Exportalo desde la pagina de revision.")


def recortar_silencio(audio: np.ndarray, tasa: int) -> np.ndarray:
    ventana = int(0.02 * tasa)
    if len(audio) < ventana * 3:
        return audio

    energia = np.array([
        np.sqrt(np.mean(audio[i:i + ventana] ** 2)) for i in range(0, len(audio) - ventana, ventana)
    ])
    umbral = 10 ** (UMBRAL_SILENCIO_DB / 20)
    activos = np.where(energia > umbral)[0]
    if activos.size == 0:
        return audio

    margen = int(MARGEN_S * tasa)
    inicio = max(0, activos[0] * ventana - margen)
    fin = min(len(audio), (activos[-1] + 1) * ventana + margen)
    return audio[inicio:fin]


def igualar_volumen(audio: np.ndarray) -> np.ndarray:
    nivel = np.sqrt(np.mean(audio ** 2)) + 1e-9
    audio = audio * (10 ** (NIVEL_DB / 20) / nivel)

    pico = np.max(np.abs(audio)) + 1e-9
    limite = 10 ** (PICO_DB / 20)
    if pico > limite:
        audio = audio * (limite / pico)
    return audio


def main() -> None:
    archivo = buscar_decisiones()
    decisiones = json.loads(archivo.read_text(encoding="utf-8"))["decisiones"]
    conservadas = sorted(k for k, v in decisiones.items() if v == "si")

    destino = SALIDA / NOMBRE
    destino.mkdir(parents=True, exist_ok=True)
    for viejo in destino.glob("*.wav"):
        viejo.unlink()

    total = 0.0
    for ident in conservadas:
        episodio = ident.split("_")[0]
        audio, tasa = sf.read(FRASES / episodio / f"{ident}.wav", dtype="float32")
        audio = igualar_volumen(recortar_silencio(audio, tasa))
        sf.write(destino / f"{ident}.wav", audio, tasa, subtype="PCM_24")
        total += len(audio) / tasa

    print(f"decisiones: {archivo}")
    print(f"{len(conservadas)} frases, {total / 60:.1f} min en {destino}")


if __name__ == "__main__":
    main()
