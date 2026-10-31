"""Quien habla en cada momento, con WavLM Large y las decisiones del usuario.

21_hablante.py mostro que, para decidir si un clip es de la voz de prueba, el promedio
de las capas intermedias de WavLM Large con un clasificador entrenado con las
decisiones del usuario (AUC 0.74) supera a las referencias con ECAPA (0.60).
Pero los clips nuevos se cortan palabra por palabra, asi que hace falta la
misma decision en cada momento del episodio, como la curva de 04_cortar.py.

1. Huellas: WavLM Large recorre la voz separada de cada episodio en tramos de
   20 s (con 2 s de solape, para que ningun momento quede en el borde) y deja
   una representacion cada 20 ms. La huella de cada ventana de 1.5 s, cada
   0.25 s, es el promedio de esas representaciones: las mismas ventanas que
   la curva de hoy.
2. Clasificador: aprende con ventanas de los clips que el usuario conservo
   (la voz de prueba sola) frente a ventanas de palabras que la curva de hoy da como de
   otra voz con mucha seguridad (probabilidad menor de 0.05) y ventanas de los
   clips descartados.
3. Prueba: por episodios que no vio, el promedio de la curva nueva dentro de
   cada clip marcado debe separar conservados de descartados mejor que la
   curva de hoy.

Escribe datos/24_curvas/epNN.npz (centros, huellas en float16) y
datos/24_curvas/resultado.json.

Corre en el entorno principal:
    .venv/Scripts/python.exe scripts/24_curva_wavlm.py            huellas y prueba
    .venv/Scripts/python.exe scripts/24_curva_wavlm.py ep23 ep24  solo huellas de esos
"""

import importlib.util
import json
import os
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("TORCH_HOME", str(RAIZ / "modelos" / "torch"))

import numpy as np
import soundfile as sf
import torch
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import GroupKFold
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

spec = importlib.util.spec_from_file_location("hablante", Path(__file__).parent / "21_hablante.py")
hablante = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hablante)
cortar = hablante.cortar

DATOS = RAIZ / "datos"
SALIDA = DATOS / "24_curvas"
TASA = 16000
TRAMO_S, SOLAPE_S = 20.0, 2.0
CUADRO_S = 0.02  # WavLM deja una representacion cada 20 ms
CAPAS = hablante.CAPAS_WAVLM


@torch.no_grad()
def huellas_episodio(modelo, episodio: str):
    destino = SALIDA / f"{episodio}.npz"
    if destino.exists():
        datos = np.load(destino)
        return datos["centros"], datos["huellas"].astype(np.float32)

    audio, tasa = sf.read(DATOS / "02_voz" / f"{episodio}_voz.wav", dtype="float32", always_2d=False)
    audio = cortar.a_16k(cortar.mono(audio), tasa)

    # Representacion cada 20 ms de todo el episodio, por tramos solapados.
    total = int(len(audio) / TASA / CUADRO_S)
    cuadros = np.zeros((total, 1024), dtype=np.float32)
    paso = TRAMO_S - SOLAPE_S
    inicio = 0.0
    while inicio * TASA < len(audio):
        trozo = audio[int(inicio * TASA):int((inicio + TRAMO_S) * TASA)]
        if len(trozo) < TASA // 2:
            break
        capas, _ = modelo.extract_features(torch.from_numpy(trozo)[None].cuda())
        rep = torch.stack([capas[i][0] for i in CAPAS]).mean(0).float().cpu().numpy()
        # Del solape se usa la mitad de cada lado: lo mas lejos del borde.
        desde = 0 if inicio == 0 else int(SOLAPE_S / 2 / CUADRO_S)
        primero = int(inicio / CUADRO_S)
        hasta = min(len(rep), total - primero)
        cuadros[primero + desde:primero + hasta] = rep[desde:hasta]
        inicio += paso

    # Las mismas ventanas que la curva de 04_cortar.py.
    ventana, salto = int(cortar.VENTANA_S / CUADRO_S), int(cortar.PASO_S / CUADRO_S)
    inicios = np.arange(0, max(1, total - ventana), salto)
    acumulado = np.concatenate([np.zeros((1, 1024), np.float32), np.cumsum(cuadros, axis=0)])
    huellas = (acumulado[inicios + ventana] - acumulado[inicios]) / ventana
    centros = (inicios + ventana / 2) * CUADRO_S

    SALIDA.mkdir(parents=True, exist_ok=True)
    np.savez(destino, centros=centros, huellas=huellas.astype(np.float16))
    return centros, huellas


def ventanas_en(centros, inicio, fin):
    return np.where((centros - cortar.VENTANA_S / 2 >= inicio - 0.1) & (centros + cortar.VENTANA_S / 2 <= fin + 0.1))[0]


def main() -> None:
    pedidos = sys.argv[1:]
    import torchaudio
    modelo = torchaudio.pipelines.WAVLM_LARGE.get_model().cuda().eval()
    episodios = pedidos or sorted(p.stem for p in (DATOS / "03_alineado").glob("ep*.json"))
    curvas = {}
    for episodio in episodios:
        curvas[episodio] = huellas_episodio(modelo, episodio)
        print(f"{episodio}: huellas listas", flush=True)
    if pedidos:
        return
    del modelo
    torch.cuda.empty_cache()

    # Ejemplos: ventanas dentro de cada clip marcado, y ventanas de otras voces.
    filas = hablante.clips_marcados()
    probabilidad = cortar.cargar_calibracion()
    x, y, grupo, clip_de = [], [], [], []
    for n, f in enumerate(filas):
        clip = next(c for c in json.loads((f["ruta"].parent / "indice.json").read_text(encoding="utf-8"))["clips"]
                    if c["archivo"] == f["ruta"].name)
        centros, huellas = curvas[f["episodio"]]
        for i in ventanas_en(centros, clip["inicio"], clip["fin"]):
            x.append(huellas[i]); y.append(f["conservado"]); grupo.append(f["episodio"]); clip_de.append(n)
    azar = np.random.default_rng(0)
    for episodio, (centros, huellas) in curvas.items():
        vieja = np.load(DATOS / "04_curvas" / f"{episodio}.npz")
        prob = np.array([probabilidad(v) for v in vieja["parecido"]])
        otras = np.where(prob < 0.05)[0]
        for i in azar.choice(otras, size=min(300, len(otras)), replace=False):
            j = int(np.argmin(np.abs(centros - vieja["centros"][i])))
            x.append(huellas[j]); y.append(False); grupo.append(episodio); clip_de.append(-1)
    x, y, grupo, clip_de = np.array(x), np.array(y), np.array(grupo), np.array(clip_de)
    print(f"{len(x)} ventanas para aprender ({y.sum()} de la voz de prueba)", flush=True)

    # Prueba por episodios no vistos: promedio de la curva nueva en cada clip.
    puntaje = np.zeros(len(x))
    for entreno, prueba in GroupKFold(n_splits=5).split(x, y, grupo):
        clasificador = make_pipeline(StandardScaler(), LogisticRegression(C=0.05, max_iter=5000, class_weight="balanced"))
        clasificador.fit(x[entreno], y[entreno])
        puntaje[prueba] = clasificador.predict_proba(x[prueba])[:, 1]
    marcados = [n for n in range(len(filas)) if (clip_de == n).any()]
    nueva = [puntaje[clip_de == n].mean() for n in marcados]
    minima = [puntaje[clip_de == n].min() for n in marcados]
    etiquetas = [filas[n]["conservado"] for n in marcados]
    hoy = [filas[n]["base_confianza"] for n in marcados]
    resultado = {"curva_hoy_confianza": roc_auc_score(etiquetas, hoy),
                 "curva_nueva_promedio": roc_auc_score(etiquetas, nueva),
                 "curva_nueva_minimo": roc_auc_score(etiquetas, minima),
                 "clips": len(marcados)}
    print(json.dumps(resultado, indent=1))

    # El clasificador final, con todo, para cortar los episodios.
    clasificador = make_pipeline(StandardScaler(), LogisticRegression(C=0.05, max_iter=5000, class_weight="balanced"))
    clasificador.fit(x, y)
    escala, regresion = clasificador.named_steps["standardscaler"], clasificador.named_steps["logisticregression"]
    np.savez(SALIDA / "clasificador.npz", media=escala.mean_, escala=escala.scale_,
             pesos=regresion.coef_[0], sesgo=regresion.intercept_)
    (SALIDA / "resultado.json").write_text(json.dumps(resultado, indent=1), encoding="utf-8")


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).parent))
    import gpu
    gpu.ocupar()
    main()
