"""¿Hay una forma mejor de reconocer la voz de prueba que la de hoy?

Hoy cada fragmento se compara con unas pocas grabaciones de referencia
(ECAPA, parecido coseno, calibrado en 04a_calibrar.py). Ahora tenemos algo
mucho mejor que las referencias: 717 clips que el usuario escucho y marco,
516 como la voz de prueba sola y 201 como descartados. Con esas marcas se puede
entrenar un clasificador sobre la huella de cada clip, y probar huellas de
otros modelos, ademas de ECAPA:

- WavLM base plus SV (Microsoft), un modelo de huella de voz entrenado
  sobre WavLM;
- WavLM Large (de torchaudio), sin entrenar para huellas: el promedio de sus
  capas intermedias, que guardan mucho de quien habla.

Para que la prueba sea justa, se evalua con episodios que el clasificador no
vio: se reparten los 22 episodios en 5 grupos, se entrena con 4 y se mide en
el quinto. La medida es el AUC: la probabilidad de que un clip conservado
reciba mas puntaje que uno descartado. La de hoy es la base.

Ojo: algunos descartes fueron por ruido o por cortes, no por la voz. Eso
afecta a todos los metodos por igual, asi que la comparacion vale.

Escribe datos/21_hablante/resultado.json y guarda las huellas para reusarlas.

Corre en el entorno principal:
    .venv/Scripts/python.exe scripts/21_hablante.py
"""

import importlib.util
import json
import os
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("HF_HOME", str(RAIZ / "modelos" / "hf"))
os.environ.setdefault("TORCH_HOME", str(RAIZ / "modelos" / "torch"))

import numpy as np
import soundfile as sf
import torch
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import GroupKFold
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

spec = importlib.util.spec_from_file_location("cortar", Path(__file__).parent / "04_cortar.py")
cortar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cortar)

DATOS = RAIZ / "datos"
SALIDA = DATOS / "21_hablante"
DISPOSITIVO = "cuda:0"
CAPAS_WAVLM = range(4, 13)


def clips_marcados():
    decisiones = json.loads((DATOS / "05_revision" / "decisiones.json").read_text(encoding="utf-8"))["decisiones"]
    filas = []
    for indice in sorted((DATOS / "04_cortes").glob("ep*/indice.json")):
        for clip in json.loads(indice.read_text(encoding="utf-8"))["clips"]:
            nombre = clip["archivo"].removesuffix(".wav")
            if nombre in decisiones:
                filas.append({"nombre": nombre, "episodio": nombre.split("_")[0],
                              "ruta": indice.parent / clip["archivo"],
                              "conservado": decisiones[nombre] == "si",
                              **{f"base_{k}": clip[k] for k in ("prob_clip", "confianza", "minimo")}})
    return filas


def audio16(ruta):
    audio, tasa = sf.read(ruta, dtype="float32", always_2d=False)
    return cortar.a_16k(cortar.mono(audio), tasa)


@torch.no_grad()
def huellas(filas):
    destino = SALIDA / "huellas.npz"
    if destino.exists():
        datos = np.load(destino)
        return {k: datos[k] for k in datos.files}

    sonidos = [audio16(f["ruta"]) for f in filas]
    resultado = {}

    ecapa = cortar.cargar_modelo()
    resultado["ecapa"] = np.stack([ecapa.encode_batch(torch.from_numpy(s)[None].to(ecapa.device)).squeeze().cpu().numpy()
                                   for s in sonidos])
    del ecapa

    from transformers import AutoFeatureExtractor, WavLMForXVector
    extractor = AutoFeatureExtractor.from_pretrained("microsoft/wavlm-base-plus-sv")
    sv = WavLMForXVector.from_pretrained("microsoft/wavlm-base-plus-sv").to(DISPOSITIVO).eval()
    vectores = []
    for s in sonidos:
        entrada = extractor(s, sampling_rate=16000, return_tensors="pt").to(DISPOSITIVO)
        vectores.append(sv(**entrada).embeddings.squeeze().cpu().numpy())
    resultado["wavlm_sv"] = np.stack(vectores)
    del sv

    import torchaudio
    paquete = torchaudio.pipelines.WAVLM_LARGE
    grande = paquete.get_model().to(DISPOSITIVO).eval()
    vectores = []
    for s in sonidos:
        capas, _ = grande.extract_features(torch.from_numpy(s)[None].to(DISPOSITIVO))
        vectores.append(torch.stack([capas[i].mean(dim=1).squeeze(0) for i in CAPAS_WAVLM]).mean(0).cpu().numpy())
    resultado["wavlm_large"] = np.stack(vectores)

    SALIDA.mkdir(parents=True, exist_ok=True)
    np.savez(destino, **resultado)
    return resultado


def evaluar(x, y, grupos):
    """Puntaje de cada clip predicho por un clasificador que no vio su episodio."""
    puntaje = np.zeros(len(y))
    for entreno, prueba in GroupKFold(n_splits=5).split(x, y, grupos):
        modelo = make_pipeline(StandardScaler(), LogisticRegression(C=0.1, max_iter=5000, class_weight="balanced"))
        modelo.fit(x[entreno], y[entreno])
        puntaje[prueba] = modelo.predict_proba(x[prueba])[:, 1]
    return puntaje


def main() -> None:
    filas = clips_marcados()
    y = np.array([f["conservado"] for f in filas])
    grupos = np.array([f["episodio"] for f in filas])
    print(f"{len(filas)} clips marcados: {y.sum()} conservados, {(~y).sum()} descartados", flush=True)

    todas = huellas(filas)
    todas = {k: v / (np.linalg.norm(v, axis=1, keepdims=True) + 1e-9) for k, v in todas.items()}
    candidatos = dict(todas)
    candidatos["ecapa+wavlm_sv"] = np.hstack([todas["ecapa"], todas["wavlm_sv"]])
    candidatos["las_tres"] = np.hstack([todas["ecapa"], todas["wavlm_sv"], todas["wavlm_large"]])

    # La base son los puntajes que ya guarda 04_cortar.py para cada clip.
    resultado = {f"hoy_{k}": roc_auc_score(y, [f[f"base_{k}"] for f in filas]) for k in ("prob_clip", "confianza", "minimo")}
    for nombre, x in candidatos.items():
        resultado[nombre] = roc_auc_score(y, evaluar(x, y, grupos))
    for nombre, auc in sorted(resultado.items(), key=lambda par: -par[1]):
        print(f"  AUC {auc:.3f}  {nombre}")
    (SALIDA / "resultado.json").write_text(json.dumps(resultado, indent=1), encoding="utf-8")


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).parent))
    import gpu
    gpu.ocupar()
    main()
