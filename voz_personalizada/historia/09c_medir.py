"""Mide cuanto se parece a la voz real cada conversion de 09b_diagnostico.py.

Usa la misma huella de voz y la misma calibracion con que se eligieron los
clips: la probabilidad de ser la voz de un clip entero. Como referencia mide
tambien clips reales del conjunto, que marcan el techo, y las fuentes sin
convertir, que marcan el suelo.

Corre en el entorno principal:
    .venv/Scripts/python.exe scripts/09c_medir.py
"""

import importlib.util
import json
import random
import re
from collections import defaultdict
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

RAIZ = Path(__file__).resolve().parent.parent
DIAGNOSTICO = RAIZ / "datos" / "09_diagnostico"
CONJUNTO = RAIZ / "datos" / "08_final" / "mi_voz_es"

especificacion = importlib.util.spec_from_file_location("cortar", RAIZ / "scripts" / "04_cortar.py")
cortar = importlib.util.module_from_spec(especificacion)
especificacion.loader.exec_module(cortar)


def main() -> None:
    modelo = cortar.cargar_modelo()
    centro, refs = cortar.referencias(modelo)
    probabilidad = cortar.cargar_calibracion()

    def medir(archivo: Path) -> float:
        audio, tasa = sf.read(archivo, dtype="float32", always_2d=False)
        senal = torch.from_numpy(cortar.a_16k(cortar.mono(audio), tasa))[None].to(modelo.device)
        with torch.no_grad():
            huella = modelo.encode_batch(senal).squeeze().cpu().numpy()
        huella /= np.linalg.norm(huella) + 1e-9
        return float(probabilidad(0.6 * float(huella @ centro) + 0.4 * float((refs @ huella).max())))

    fuentes = json.loads((DIAGNOSTICO / "fuentes.json").read_text(encoding="utf-8"))["fuentes"]
    reales = [medir(a) for a in random.Random(1).sample(sorted(CONJUNTO.glob("*.wav")), 60)]

    sin_convertir = defaultdict(list)
    por_epoca = defaultdict(lambda: defaultdict(list))
    detalle = {}
    for nombre, datos in fuentes.items():
        sin_convertir[datos["tipo"]].append(medir(Path(datos["origen"])))
        detalle[nombre] = {"origen": sin_convertir[datos["tipo"]][-1]}
        for archivo in (DIAGNOSTICO / "convertido").glob(f"{nombre}_e*.wav"):
            epoca = int(re.search(r"_e(\d+)\.wav$", archivo.name).group(1))
            valor = medir(archivo)
            por_epoca[datos["tipo"]][epoca].append(valor)
            detalle[nombre][epoca] = valor

    print(f"Voz real, {len(reales)} clips del conjunto: mediana {np.median(reales):.0%}, minimo {min(reales):.0%}")
    tipos = list(por_epoca)
    print("\nprobabilidad media de ser la voz")
    print("epoca     " + "".join(f"{t:>11s}" for t in tipos))
    print("sin conv. " + "".join(f"{np.mean(sin_convertir[t]):>11.0%}" for t in tipos))
    for epoca in sorted(por_epoca[tipos[0]]):
        print(f"{epoca:<10d}" + "".join(f"{np.mean(por_epoca[t][epoca]):>11.0%}" for t in tipos))

    print("\npor fuente, epoca 400")
    for nombre, valores in detalle.items():
        print(
            f"  {nombre:20s} {fuentes[nombre]['semitonos']:+3d} st  sin conv. {valores['origen']:.0%}  "
            f"convertida {valores.get(400, float('nan')):.0%}"
        )

    (DIAGNOSTICO / "medicion.json").write_text(
        json.dumps({"reales": reales, "detalle": detalle}, ensure_ascii=False, indent=1), encoding="utf-8"
    )


if __name__ == "__main__":
    main()
