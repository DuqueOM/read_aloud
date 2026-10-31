"""Mide y puntua los clips nuevos de 25_cortar_frases.py para la revision.

Cada clip recibe las mismas medidas que 23_calidad.py (eco, SQUIM, borde,
pausas, recorte, duracion) y la huella de WavLM Large de 21_hablante.py. Con
eso, un clasificador entrenado con las 717 decisiones de la primera revision
da su puntaje: la probabilidad de que el usuario conserve el clip (AUC 0.80
en episodios que no vio). La pagina de revision se ordena por ese puntaje,
de mas a menos, y lo que el usuario no llegue a revisar es lo de menos valor.

Ademas cada clip lleva avisos legibles cuando una medida cae donde casi solo
caen clips descartados: eco fuerte, ruido o voces en las pausas, borde con
ruido, calidad baja.

Escribe datos/26_puntaje/clips.json.

Corre en el entorno principal:
    .venv/Scripts/python.exe scripts/26_puntuar.py
"""

import importlib.util
import json
import os
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("TORCH_HOME", str(RAIZ / "modelos" / "torch"))

import numpy as np
import torch
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler


def cargar(nombre):
    spec = importlib.util.spec_from_file_location(nombre.replace(".py", ""), Path(__file__).parent / nombre)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo


calidad = cargar("23_calidad.py")
hablante = calidad.hablante
DATOS = RAIZ / "datos"
SALIDA = DATOS / "26_puntaje"
MEDIDAS = ["eco", "stoi", "pesq", "si_sdr", "borde", "pausas", "recorte", "empieza", "termina", "duracion", "hablante"]
# Avisos: umbrales donde, en la primera revision, casi todo lo que caia era descartado.
AVISOS = [
    ("eco", lambda v: v > -14, "eco fuerte"),
    ("pausas", lambda v: v > -25, "sonido en las pausas"),
    ("borde", lambda v: v > -15, "borde con ruido"),
    ("pesq", lambda v: v < 1.8, "calidad baja"),
    ("hablante", lambda v: v < 0.3, "¿otra voz?"),
]


@torch.no_grad()
def huellas_wavlm(filas):
    import torchaudio
    modelo = torchaudio.pipelines.WAVLM_LARGE.get_model().to("cuda").eval()
    from progreso_comun import avance
    vectores = []
    for n, f in enumerate(filas):
        if n % 50 == 0:
            avance("huella de voz (WavLM)", n, len(filas))
        audio = torch.from_numpy(hablante.audio16(f["ruta"]))[None].to("cuda")
        capas, _ = modelo.extract_features(audio)
        vectores.append(torch.stack([capas[i].mean(dim=1).squeeze(0) for i in hablante.CAPAS_WAVLM]).mean(0).cpu().numpy())
    v = np.stack(vectores)
    return v / (np.linalg.norm(v, axis=1, keepdims=True) + 1e-9)


def medir(filas, palabras_de):
    medidas = {f["nombre"]: {} for f in filas}
    for nombre, valor in calidad.eco(filas).items():
        medidas[nombre]["eco"] = valor
    for nombre, valores in calidad.squim(filas).items():
        medidas[nombre].update(valores)
    for f in filas:
        n = calidad.niveles_de_clip(f, palabras_de[f["episodio"]])
        n.pop("dentro")
        medidas[f["nombre"]].update(n)
        medidas[f["nombre"]]["empieza"] = medidas[f["nombre"]]["termina"] = 1.0  # cortados por frases
        medidas[f["nombre"]]["duracion"] = f["fin"] - f["inicio"]
    return medidas


def main() -> None:
    SALIDA.mkdir(parents=True, exist_ok=True)
    nuevos = []
    for indice in sorted((DATOS / "25_cortes").glob("ep*/indice.json")):
        for clip in json.loads(indice.read_text(encoding="utf-8"))["clips"]:
            nuevos.append(dict(clip, nombre=clip["archivo"].removesuffix(".wav"), episodio=indice.parent.name,
                               ruta=indice.parent / clip["archivo"]))
    palabras_de = {ep: json.loads((DATOS / "03_alineado" / f"{ep}.json").read_text(encoding="utf-8"))["palabras"]
                   for ep in {f["episodio"] for f in nuevos}}
    print(f"{len(nuevos)} clips nuevos", flush=True)

    cache = SALIDA / "medidas.json"
    medidas = json.loads(cache.read_text(encoding="utf-8")) if cache.exists() else medir(nuevos, palabras_de)
    cache.write_text(json.dumps(medidas, indent=1), encoding="utf-8")
    huellas_nuevas = huellas_wavlm(nuevos)

    # Lo aprendido de la primera revision: hablante con la huella, y despues
    # todas las medidas con la huella.
    marcados = hablante.clips_marcados()
    y = np.array([f["conservado"] for f in marcados])
    viejas = json.loads((DATOS / "23_calidad" / "medidas.json").read_text(encoding="utf-8"))
    huellas_viejas = np.load(DATOS / "21_hablante" / "huellas.npz")["wavlm_large"]
    huellas_viejas = huellas_viejas / (np.linalg.norm(huellas_viejas, axis=1, keepdims=True) + 1e-9)

    def modelo():
        return make_pipeline(StandardScaler(), LogisticRegression(C=0.1, max_iter=5000, class_weight="balanced"))

    voz = modelo().fit(huellas_viejas, y)
    grupos = np.array([f["episodio"] for f in marcados])
    for f, p in zip(marcados, hablante.evaluar(huellas_viejas, y, grupos)):
        viejas[f["nombre"]]["hablante"] = float(p)
    for f, p in zip(nuevos, voz.predict_proba(huellas_nuevas)[:, 1]):
        medidas[f["nombre"]]["hablante"] = float(p)

    def tabla(filas, m):
        x = np.array([[m[f["nombre"]].get(n, np.nan) for n in MEDIDAS] for f in filas], dtype=float)
        return np.where(np.isnan(x), np.nanmedian(x, axis=0), x)

    final = modelo().fit(np.hstack([tabla(marcados, viejas), huellas_viejas]), y)
    puntaje = final.predict_proba(np.hstack([tabla(nuevos, medidas), huellas_nuevas]))[:, 1]

    salida = []
    for f, p in zip(nuevos, puntaje):
        m = medidas[f["nombre"]]
        salida.append({"nombre": f["nombre"], "episodio": f["episodio"], "puntaje": round(float(p), 4),
                       "avisos": [texto for clave, regla, texto in AVISOS if regla(m[clave])],
                       "medidas": {k: round(v, 3) for k, v in m.items()}})
    (SALIDA / "clips.json").write_text(json.dumps(salida, ensure_ascii=False, indent=1), encoding="utf-8")
    p = np.array([s["puntaje"] for s in salida])
    d = np.array([f["duracion"] for f in nuevos])
    for u in (0.3, 0.5, 0.7):
        print(f"  puntaje >= {u}: {(p >= u).sum()} clips, {d[p >= u].sum() / 60:.1f} min", flush=True)


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).parent))
    import gpu
    gpu.ocupar()
    main()
