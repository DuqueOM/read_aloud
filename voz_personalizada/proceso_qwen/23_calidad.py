"""¿Que medidas de calidad separan los clips que el usuario conserva de los que descarta?

Para cada uno de los 717 clips marcados en la revision se mide:

- eco: energia que quita el modelo de-reverb mono de anvuew, respecto al clip
  (la medida de 07a_sin_reverb.py). Mas alta, mas eco.
- stoi, pesq, si_sdr: lo que estima TorchAudio-SQUIM sin referencia limpia:
  inteligibilidad, calidad percibida y relacion entre voz y todo lo demas.
- borde: nivel de los primeros y ultimos 60 ms respecto al habla del clip;
  alto si el corte deja entrar ruido, una respiracion u otra voz.
- pausas: nivel dentro de las pausas entre palabras respecto al habla; alto
  si hay musica o ruido de fondo que la separacion no quito.
- recorte: parte de las muestras saturadas.
- empieza, termina: si el clip empieza y termina donde empieza y termina la
  frase, segun la puntuacion de la transcripcion del video.
- hablante: el puntaje del clasificador de 21_hablante.py (WavLM Large),
  calculado sin ver el video del clip.

Se informa el AUC de cada medida por separado (si conviene alto o bajo) y el
de todas juntas en un clasificador evaluado igual que en 21_hablante.py, por
videos que no vio. Con eso se eligen los filtros y el orden de la pagina
de revision.

Corre en el entorno principal:
    .venv/Scripts/python.exe scripts/23_calidad.py
"""

import importlib.util
import json
import os
import re
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("TORCH_HOME", str(RAIZ / "modelos" / "torch"))
# audio-separator busca ffmpeg por su nombre.
os.environ["PATH"] = str(RAIZ / "herramientas") + os.pathsep + os.environ["PATH"]

import numpy as np
import soundfile as sf
import torch
from sklearn.metrics import roc_auc_score


def cargar(nombre):
    spec = importlib.util.spec_from_file_location(nombre.replace(".py", ""), Path(__file__).parent / nombre)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo


hablante = cargar("21_hablante.py")
cortar = hablante.cortar
DATOS = RAIZ / "datos"
SALIDA = DATOS / "23_calidad"
FIN_FRASE = re.compile(r"[.?!…]$")


def eco(filas) -> dict:
    from audio_separator.separator import Separator
    temporal = SALIDA / "temporal"
    temporal.mkdir(parents=True, exist_ok=True)
    tasa = sf.info(filas[0]["ruta"]).samplerate
    hueco = np.zeros(tasa, dtype=np.float32)
    partes, posiciones, cursor = [hueco], [], tasa
    for f in filas:
        audio, t = sf.read(f["ruta"], dtype="float32", always_2d=False)
        assert t == tasa
        audio = cortar.mono(audio)
        partes += [audio, hueco]
        posiciones.append((f["nombre"], cursor, cursor + len(audio)))
        cursor += len(audio) + tasa
    sf.write(temporal / "todo.wav", np.concatenate(partes), tasa, subtype="FLOAT")
    separador = Separator(output_dir=str(temporal), model_file_dir=str(RAIZ / "modelos"),
                          output_format="WAV", sample_rate=tasa)
    separador.load_model(model_filename="dereverb_mel_band_roformer_mono_anvuew.ckpt")
    from progreso_comun import avance
    avance("eco, todos los clips de una vez", 0, len(filas))
    separador.separate(str(temporal / "todo.wav"), {"noreverb": "seco", "reverb": "eco"})
    seco, _ = sf.read(temporal / "seco.wav", dtype="float32", always_2d=False)
    seco = seco.mean(axis=1) if seco.ndim > 1 else seco
    original = np.concatenate(partes)
    medidas = {}
    for nombre, desde, hasta in posiciones:
        quitado = np.sum((original[desde:hasta] - seco[desde:hasta]) ** 2) / (np.sum(original[desde:hasta] ** 2) + 1e-12)
        medidas[nombre] = float(10 * np.log10(quitado + 1e-12))
    for archivo in temporal.iterdir():
        archivo.unlink()
    temporal.rmdir()
    return medidas


@torch.no_grad()
def squim(filas) -> dict:
    import torchaudio
    modelo = torchaudio.pipelines.SQUIM_OBJECTIVE.get_model().to("cuda").eval()
    from progreso_comun import avance
    medidas = {}
    for n, f in enumerate(filas):
        if n % 50 == 0:
            avance("calidad estimada (SQUIM)", n, len(filas))
        audio = torch.from_numpy(hablante.audio16(f["ruta"]))[None].to("cuda")
        stoi, pesq, si_sdr = modelo(audio)
        medidas[f["nombre"]] = {"stoi": stoi.item(), "pesq": pesq.item(), "si_sdr": si_sdr.item()}
    return medidas


def niveles_de_clip(f, palabras):
    audio, tasa = sf.read(f["ruta"], dtype="float32", always_2d=False)
    audio = cortar.mono(audio)
    nivel = cortar.niveles(audio, tasa)  # dB cada 10 ms
    dentro = [p for p in palabras if p["inicio"] >= f["inicio"] - 0.05 and p["fin"] <= f["fin"] + 0.05]
    habla = np.concatenate([nivel[max(0, int((p["inicio"] - f["inicio"]) / 0.01)):int((p["fin"] - f["inicio"]) / 0.01)]
                            for p in dentro] or [nivel])
    referencia = float(np.median(habla))
    borde = max(float(np.max(nivel[:6])), float(np.max(nivel[-6:]))) - referencia
    pausas = [nivel[int((a["fin"] - f["inicio"]) / 0.01) + 2:int((b["inicio"] - f["inicio"]) / 0.01) - 2]
              for a, b in zip(dentro, dentro[1:]) if b["inicio"] - a["fin"] > 0.12]
    pausas = np.concatenate([p for p in pausas if p.size] or [np.array([-120.0])])
    return {"borde": borde, "pausas": float(np.percentile(pausas, 90)) - referencia,
            "recorte": float(np.mean(np.abs(audio) > 0.99)), "dentro": dentro}


def main() -> None:
    SALIDA.mkdir(parents=True, exist_ok=True)
    filas = hablante.clips_marcados()
    for f in filas:
        indice = json.loads((f["ruta"].parent / "indice.json").read_text(encoding="utf-8"))
        clip = next(c for c in indice["clips"] if c["archivo"] == f["ruta"].name)
        f["inicio"], f["fin"] = clip["inicio"], clip["fin"]

    cache = SALIDA / "medidas.json"
    if cache.exists():
        medidas = json.loads(cache.read_text(encoding="utf-8"))
    else:
        medidas = {f["nombre"]: {} for f in filas}
        for nombre, valor in eco(filas).items():
            medidas[nombre]["eco"] = valor
        for nombre, valores in squim(filas).items():
            medidas[nombre].update(valores)
        transcripciones = {}
        for f in filas:
            ep = f["episodio"]
            if ep not in transcripciones:
                transcripciones[ep] = json.loads((DATOS / "03_alineado" / f"{ep}.json").read_text(encoding="utf-8"))["palabras"]
            palabras = transcripciones[ep]
            n = niveles_de_clip(f, palabras)
            dentro = n.pop("dentro")
            medidas[f["nombre"]].update(n)
            if dentro:
                a = palabras.index(dentro[0])
                previa = palabras[a - 1] if a else None
                medidas[f["nombre"]]["empieza"] = float(previa is None or bool(FIN_FRASE.search(previa["texto"]))
                                                        or dentro[0]["inicio"] - previa["fin"] > 1.0)
                medidas[f["nombre"]]["termina"] = float(bool(FIN_FRASE.search(dentro[-1]["texto"])))
            medidas[f["nombre"]]["duracion"] = f["fin"] - f["inicio"]
        cache.write_text(json.dumps(medidas, indent=1), encoding="utf-8")

    # El puntaje del hablante, sin ver el video del clip.
    huellas = np.load(DATOS / "21_hablante" / "huellas.npz")["wavlm_large"]
    huellas = huellas / (np.linalg.norm(huellas, axis=1, keepdims=True) + 1e-9)
    y = np.array([f["conservado"] for f in filas])
    grupos = np.array([f["episodio"] for f in filas])
    puntaje_hablante = hablante.evaluar(huellas, y, grupos)
    for f, p in zip(filas, puntaje_hablante):
        medidas[f["nombre"]]["hablante"] = float(p)

    nombres = ["eco", "stoi", "pesq", "si_sdr", "borde", "pausas", "recorte", "empieza", "termina", "duracion", "hablante"]
    x = np.array([[medidas[f["nombre"]].get(n, np.nan) for n in nombres] for f in filas])
    x = np.where(np.isnan(x), np.nanmedian(x, axis=0), x)
    resultado = {}
    print(f"{len(filas)} clips; AUC de cada medida (0.5 es azar; menos de 0.5, mejor si es baja):")
    for i, n in enumerate(nombres):
        resultado[n] = roc_auc_score(y, x[:, i])
        print(f"  {n:9s} {resultado[n]:.3f}   mediana conservados {np.median(x[y, i]):8.3f}   "
              f"descartados {np.median(x[~y, i]):8.3f}")
    resultado["todas"] = roc_auc_score(y, hablante.evaluar(x, y, grupos))
    resultado["todas_y_huella"] = roc_auc_score(y, hablante.evaluar(np.hstack([x, huellas]), y, grupos))
    print(f"  todas juntas {resultado['todas']:.3f}; con la huella de WavLM entera {resultado['todas_y_huella']:.3f}")
    (SALIDA / "resultado.json").write_text(json.dumps(resultado, indent=1), encoding="utf-8")


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).parent))
    import gpu
    gpu.ocupar()
    main()
