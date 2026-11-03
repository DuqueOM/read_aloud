"""Quita la reverberacion de cada clip del conjunto y mide cuanta tenia.

Usa el Mel-Band RoFormer de-reverb mono de anvuew. Las versiones estereo, aun
las de mejor puntuacion, devuelven intacto un audio mono como el nuestro: se
comprobo agregando un eco artificial fuerte a un clip. La mono lo reduce de
-5 a -10 dB de error frente a la voz seca.

La energia que quita es la medida de eco de cada clip: sirve para elegir la
muestra de la prueba a ciegas y, si la prueba lo aconseja, para aplicar el
modelo solo donde hace falta.

El modelo tiene un costo fijo por archivo de varios segundos, asi que los
clips se unen en un solo archivo, separados por silencio, se procesa una vez
y se vuelve a partir.

Uso:
    python 07a_sin_reverb.py
"""

import json

import numpy as np
import soundfile as sf

# comun va primero: pone en el PATH el ffmpeg de la carpeta de trabajo, que
# audio-separator busca por su nombre.
from comun import DATOS, MODELOS, NOMBRE

from audio_separator.separator import Separator  # noqa: E402

CONJUNTO = DATOS / "06_conjunto" / NOMBRE
SALIDA = DATOS / "07_mejora"
MODELO = "dereverb_mel_band_roformer_mono_anvuew.ckpt"

# Silencio entre clips: mas largo que la cola de reverberacion que el modelo
# pueda arrastrar de un clip al siguiente.
SEPARACION_S = 1.0


def main() -> None:
    temporal = SALIDA / "temporal"
    destino = SALIDA / "sin_reverb"
    temporal.mkdir(parents=True, exist_ok=True)
    destino.mkdir(parents=True, exist_ok=True)

    archivos = sorted(CONJUNTO.glob("*.wav"))
    tasa = sf.info(archivos[0]).samplerate
    hueco = np.zeros(int(SEPARACION_S * tasa), dtype=np.float32)

    partes, posiciones, cursor = [hueco], [], len(hueco)
    for archivo in archivos:
        audio, _ = sf.read(archivo, dtype="float32")
        partes += [audio, hueco]
        posiciones.append((archivo.stem, cursor, cursor + len(audio)))
        cursor += len(audio) + len(hueco)
    sf.write(temporal / "todo.wav", np.concatenate(partes), tasa, subtype="FLOAT")

    separador = Separator(
        output_dir=str(temporal),
        model_file_dir=str(MODELOS),
        output_format="WAV",
        sample_rate=tasa,
    )
    separador.load_model(model_filename=MODELO)
    separador.separate(str(temporal / "todo.wav"), {"noreverb": "seco", "reverb": "eco"})

    seco, _ = sf.read(temporal / "seco.wav", dtype="float32", always_2d=False)
    seco = seco.mean(axis=1) if seco.ndim > 1 else seco
    original, _ = sf.read(temporal / "todo.wav", dtype="float32")

    medidas = {}
    for nombre, desde, hasta in posiciones:
        clip_seco = seco[desde:hasta]
        clip_original = original[desde:hasta]
        quitado = np.sum((clip_original - clip_seco) ** 2) / (np.sum(clip_original**2) + 1e-12)
        medidas[nombre] = round(float(10 * np.log10(quitado + 1e-12)), 2)
        sf.write(destino / f"{nombre}.wav", clip_seco, tasa, subtype="PCM_24")

    (SALIDA / "reverberacion.json").write_text(json.dumps(medidas, indent=1), encoding="utf-8")
    for archivo in temporal.iterdir():
        archivo.unlink()
    temporal.rmdir()

    valores = np.array(list(medidas.values()))
    print(f"{len(medidas)} clips sin reverberacion en {destino}")
    print(
        "energia quitada respecto al clip, dB: "
        f"mediana {np.median(valores):.1f}, p90 {np.percentile(valores, 90):.1f}, max {valores.max():.1f}"
    )


if __name__ == "__main__":
    main()
