"""Comprueba que cada version diga el texto y mide su parecido con la voz real.

Los motores que generan la entonacion a veces inventan, repiten o se comen
palabras. Whisper transcribe cada version y se compara con el texto pedido:
el error de caracteres dice cuanto se aparto. La huella de voz da, como en
09c_medir.py, la probabilidad de ser la voz. Junto con la forma de la curva
de tono de 10b_pagina.py queda una tabla por version.

Corre en el entorno principal:
    .venv/Scripts/python.exe scripts/10c_medir.py
"""

import importlib.util
import json
import re
import unicodedata
from collections import defaultdict
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
import whisper

RAIZ = Path(__file__).resolve().parent.parent
SALIDA = RAIZ / "datos" / "10_motores"
ESCUCHA = SALIDA / "escucha"
MODELOS = RAIZ / "modelos" / "whisper"

especificacion = importlib.util.spec_from_file_location("cortar", RAIZ / "scripts" / "04_cortar.py")
cortar = importlib.util.module_from_spec(especificacion)
especificacion.loader.exec_module(cortar)


def normalizar(texto: str) -> str:
    texto = unicodedata.normalize("NFD", texto.lower())
    texto = "".join(c for c in texto if unicodedata.category(c) != "Mn")
    return re.sub(r"[^a-z0-9 ]+", "", re.sub(r"\s+", " ", texto)).strip()


def error_caracteres(esperado: str, obtenido: str) -> float:
    a, b = normalizar(esperado), normalizar(obtenido)
    fila = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        anterior, fila[0] = fila[0], i
        for j, cb in enumerate(b, 1):
            anterior, fila[j] = fila[j], min(fila[j] + 1, fila[j - 1] + 1, anterior + (ca != cb))
    return fila[-1] / max(1, len(a))


def main() -> None:
    import voz

    frases = json.loads((RAIZ / "datos" / "09_comparar" / "frases.json").read_text(encoding="utf-8"))
    textos = {f"{voz.IDIOMA}{f['n']}": f["texto"] for f in frases}
    textos.update(
        {
            "en1": "Wait, are you serious? I can't believe we actually made it!",
            "en2": "The function returns a list of results, sorted by date.",
        }
    )

    huella = cortar.cargar_modelo()
    centro, refs = cortar.referencias(huella)
    probabilidad = cortar.cargar_calibracion()
    oido = whisper.load_model("large-v3", device="cuda", download_root=str(MODELOS))

    por_version = defaultdict(lambda: {"prob": [], "error": []})
    detalle = {}
    for archivo in sorted(ESCUCHA.glob("*.wav")):
        clave, version = archivo.stem.split("_", 1)
        audio, tasa = sf.read(archivo, dtype="float32", always_2d=False)
        audio16 = cortar.a_16k(cortar.mono(audio), tasa)
        with torch.no_grad():
            h = huella.encode_batch(torch.from_numpy(audio16)[None].to(huella.device)).squeeze().cpu().numpy()
        h /= np.linalg.norm(h) + 1e-9
        prob = float(probabilidad(0.6 * float(h @ centro) + 0.4 * float((refs @ h).max())))
        dicho = oido.transcribe(audio16, language=clave[:2], fp16=False, temperature=0.0)["text"].strip()
        error = error_caracteres(textos[clave], dicho)
        por_version[version]["prob"].append(prob)
        por_version[version]["error"].append(error)
        detalle[archivo.stem] = {"prob": prob, "error": error, "dicho": dicho}

    forma = json.loads((SALIDA / "forma.json").read_text(encoding="utf-8"))
    print(f"{'version':34s}{'forma':>7s}{'voz':>8s}{'error':>7s}")
    for version, datos in sorted(por_version.items(), key=lambda x: -forma.get(x[0], -1)):
        f = forma.get(version)
        print(
            f"{version:34s}{(f'{f:+.2f}' if f is not None else '  -'):>7s}"
            f"{np.mean(datos['prob']):>8.0%}{np.mean(datos['error']):>7.0%}"
        )
    print("\nfrases con mas de 15 % de error:")
    for nombre, d in detalle.items():
        if d["error"] > 0.15:
            print(f"  {d['error']:4.0%}  {nombre}: {d['dicho']}")
    (SALIDA / "medicion.json").write_text(json.dumps(detalle, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
