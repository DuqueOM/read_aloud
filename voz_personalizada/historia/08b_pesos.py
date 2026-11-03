"""Saca los pesos de inferencia de los puntos de control completos.

Applio guarda cada 25 epocas el punto de control completo, G_<paso>.pth, con
el estado del optimizador para poder reanudar. Para convertir voz hace falta
el archivo de pesos, <nombre>_<epoca>e_<paso>s.pth, que Applio solo saca al
final si la opcion --save-every-weights queda desactivada por su bandera
invertida. Este paso lo saca de cada G_<paso>.pth con la misma funcion que usa
Applio, y comprueba que el de la ultima epoca coincide con el suyo.

Corre en el entorno de Applio:
    applio/.venv/Scripts/python.exe scripts/08b_pesos.py
"""

import json
import os
import re
import sys
from pathlib import Path

import torch

RAIZ = Path(__file__).resolve().parent.parent
APPLIO = RAIZ / "applio"
NOMBRE = "mi_voz_es"
MODELO = APPLIO / "logs" / NOMBRE
VOCODER = "HiFi-GAN"


def main() -> None:
    sys.path.insert(0, str(APPLIO))
    os.chdir(APPLIO)
    from rvc.train.process.extract_model import extract_model
    from rvc.train.utils import HParams

    hps = HParams(**json.loads((MODELO / "config.json").read_text(encoding="utf-8")))
    pasos = sorted(int(re.fullmatch(r"G_(\d+)\.pth", p.name).group(1)) for p in MODELO.glob("G_*.pth"))
    # El registro informa los pasos por epoca; con un lote fijo son constantes.
    por_epoca = 84

    for paso in pasos:
        epoca = paso // por_epoca
        destino = MODELO / f"{NOMBRE}_{epoca}e_{paso}s.pth"
        if destino.exists():
            continue
        punto = torch.load(MODELO / f"G_{paso}.pth", map_location="cpu", weights_only=True)
        extract_model(
            ckpt=punto["model"],
            sr=hps.data.sample_rate,
            name=NOMBRE,
            model_path=str(destino),
            epoch=epoca,
            step=paso,
            hps=hps,
            vocoder=VOCODER,
        )

    # La epoca final la saco tambien aparte, para compararla con la de Applio.
    final = pasos[-1]
    prueba = MODELO / "comprobacion.pth"
    punto = torch.load(MODELO / f"G_{final}.pth", map_location="cpu", weights_only=True)
    extract_model(
        ckpt=punto["model"],
        sr=hps.data.sample_rate,
        name=NOMBRE,
        model_path=str(prueba),
        epoch=final // por_epoca,
        step=final,
        hps=hps,
        vocoder=VOCODER,
    )
    mio = torch.load(prueba, map_location="cpu", weights_only=False)["weight"]
    suyo = torch.load(
        next(MODELO.glob(f"{NOMBRE}_{final // por_epoca}e_*s.pth")), map_location="cpu", weights_only=False
    )["weight"]
    prueba.unlink()
    distintos = [k for k in suyo if k not in mio or not torch.equal(mio[k], suyo[k])]
    print(f"comprobacion contra el de Applio: {len(suyo)} tensores, {len(distintos)} distintos")
    if distintos or set(mio) != set(suyo):
        raise SystemExit(f"no coinciden: {distintos[:5]}")


if __name__ == "__main__":
    main()
