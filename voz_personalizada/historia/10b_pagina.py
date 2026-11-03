"""Pasa los motores por RVC, mide su entonacion y arma la pagina de escucha.

Cada salida de 10a_motores.py se convierte tambien con el modelo RVC de la
voz: el motor pone la entonacion y RVC afina el timbre. Despues se mide, para
cada frase en espanol, cuanto se parece la curva de tono a la de la voz
real (alineadas en el tiempo, como en 09e_prosodia.py), y se arma una pagina
con todas las versiones al mismo volumen.

Corre en el entorno de Applio:
    applio/.venv/Scripts/python.exe scripts/10b_pagina.py
"""

import html
import json
import os
import random
import re
import sys
from collections import defaultdict
from pathlib import Path

import librosa
import numpy as np
import soundfile as sf

RAIZ = Path(__file__).resolve().parent.parent
APPLIO = RAIZ / "applio"
MODELO = APPLIO / "logs" / "mi_voz_es"
PESOS = MODELO / "mi_voz_es_375e_31500s.pth"
CONJUNTO = RAIZ / "datos" / "08_final" / "mi_voz_es"
COMPARAR = RAIZ / "datos" / "09_comparar"
SALIDA = RAIZ / "datos" / "10_motores"
TASA = 16000
SALTO = 160

NOMBRES = {
    "real": "Voz real",
    "piper_rvc": "Piper + RVC (la actual)",
    "chatterbox": "Chatterbox V3",
    "chatterbox_expresivo": "Chatterbox V3, expresivo",
    "chatterbox_es_mx": "Chatterbox español de México",
    "chatterbox_es_mx_expresivo": "Chatterbox español de México, expresivo",
    "qwen": "Qwen3-TTS",
}
INDICE = 0.5
PROTECCION = 0.33
NIVEL_DB = -20.0
PICO_DB = -1.0


def igualar(audio: np.ndarray) -> np.ndarray:
    audio = audio * (10 ** (NIVEL_DB / 20) / (np.sqrt(np.mean(audio ** 2)) + 1e-9))
    pico = np.max(np.abs(audio)) + 1e-9
    limite = 10 ** (PICO_DB / 20)
    return audio * (limite / pico) if pico > limite else audio


def tono(audio16: np.ndarray) -> np.ndarray:
    f0, sonoro, _ = librosa.pyin(audio16, fmin=70, fmax=1000, sr=TASA, hop_length=SALTO)
    return np.where(sonoro, 12 * np.log2(np.where(sonoro, f0, 1) / 100), np.nan)


def forma(real16: np.ndarray, otra16: np.ndarray) -> float:
    """Correlacion de las curvas de tono tras alinear las dos frases."""
    mfcc = lambda a: librosa.feature.mfcc(y=a, sr=TASA, n_mfcc=20, hop_length=SALTO)
    _, camino = librosa.sequence.dtw(X=mfcc(real16), Y=mfcc(otra16))
    a, b = tono(real16), tono(otra16)
    pares = np.array([(a[min(i, len(a) - 1)], b[min(j, len(b) - 1)]) for i, j in camino[::-1]])
    validos = ~np.isnan(pares).any(axis=1)
    return float(np.corrcoef(pares[validos, 0], pares[validos, 1])[0, 1])


def main() -> None:
    audio_dir = SALIDA / "audio"
    escucha = SALIDA / "escucha"
    escucha.mkdir(exist_ok=True)

    azar = random.Random(0)
    tono_voz = np.nanmedian(np.concatenate([tono(librosa.load(a, sr=TASA)[0])
                                          for a in azar.sample(sorted(CONJUNTO.glob("*.wav")), 40)]))

    sys.path.insert(0, str(APPLIO))
    os.chdir(APPLIO)
    from rvc.infer.infer import VoiceConverter

    convertidor = VoiceConverter()
    indice = str(next(MODELO.glob("*.index")))
    for origen in sorted(audio_dir.glob("*.wav")):
        if origen.stem.endswith("_rvc"):
            continue
        destino = audio_dir / f"{origen.stem}_rvc.wav"
        if destino.exists():
            continue
        # Estos motores ya hablan cerca del tono de la voz: solo se corrige
        # la diferencia que quede.
        semitonos = int(np.clip(round(tono_voz - np.nanmedian(tono(librosa.load(origen, sr=TASA)[0]))), -12, 12))
        convertidor.convert_audio(
            audio_input_path=str(origen), audio_output_path=str(destino),
            model_path=str(PESOS), index_path=indice, pitch=semitonos,
            f0_method="rmvpe", index_rate=INDICE, protect=PROTECCION,
        )

    # Las versiones de referencia salen de las pruebas anteriores.
    espanol = json.loads((COMPARAR / "frases.json").read_text(encoding="utf-8"))
    fuentes = {}
    for f in espanol:
        fuentes[(f"es{f['n']}", "real")] = COMPARAR / "audio" / f"f{f['n']}_real.wav"
        fuentes[(f"es{f['n']}", "piper_rvc")] = COMPARAR / "audio" / f"f{f['n']}_entrenada.wav"
    for n, frase in ((1, 4), (2, 5)):
        fuentes[(f"en{n}", "piper_rvc")] = RAIZ / "datos" / "09_diagnostico" / "convertido" / f"piper_{frase}_e375.wav"
    for archivo in audio_dir.glob("*.wav"):
        clave, version = archivo.stem.split("_", 1)
        fuentes[(clave, version)] = archivo

    for (clave, version), archivo in fuentes.items():
        audio, tasa = sf.read(archivo, dtype="float32", always_2d=False)
        audio = audio if audio.ndim == 1 else audio.mean(axis=1)
        sf.write(escucha / f"{clave}_{version}.wav", igualar(audio), tasa, subtype="PCM_24")

    # Medicion: forma de la curva de tono frente a la voz real.
    parecido = defaultdict(list)
    for f in espanol:
        real = librosa.load(escucha / f"es{f['n']}_real.wav", sr=TASA)[0]
        for (clave, version) in fuentes:
            if clave == f"es{f['n']}" and version != "real":
                parecido[version].append(forma(real, librosa.load(escucha / f"{clave}_{version}.wav", sr=TASA)[0]))
    resumen = {v: float(np.mean(c)) for v, c in parecido.items()}
    for version, valor in sorted(resumen.items(), key=lambda x: -x[1]):
        print(f"  {valor:+.2f}  {version}")
    (SALIDA / "forma.json").write_text(json.dumps(resumen, indent=1), encoding="utf-8")

    def nombre(version: str) -> str:
        if version in NOMBRES:
            return NOMBRES[version]
        base = version.removesuffix("_rvc")
        afinado = re.fullmatch(r"qwen_mi_voz(?:_(v\d+))?_e(\d+)(?:_(\w+))?", base)
        if afinado:
            ronda = afinado.group(1) or "v1"
            texto = f"Qwen3-TTS entrenado {ronda}, época {int(afinado.group(2))}"
            texto += f", indicación «{afinado.group(3)}»" if afinado.group(3) else ""
        else:
            texto = NOMBRES.get(base, base)
        return texto + (" + RVC" if version.endswith("_rvc") else "")

    # Primero lo entrenado, que es lo que se esta evaluando; despues los motores sin entrenar.
    afinadas = sorted({v.removesuffix("_rvc") for _, v in fuentes if v.startswith("qwen_mi_voz")})
    orden = (["real"] + [v for base in afinadas for v in (base, f"{base}_rvc")] + ["piper_rvc"]
             + [v for base in list(NOMBRES)[2:] for v in (base, f"{base}_rvc")])
    textos = {f"es{f['n']}": f["texto"] for f in espanol}
    textos.update({"en1": "Wait, are you serious? I can't believe we actually made it!",
                   "en2": "The function returns a list of results, sorted by date."})
    bloques = []
    for clave, texto in textos.items():
        filas = "".join(
            f'<div class="fila{" real" if v == "real" else ""}"><span>{html.escape(nombre(v))}</span>'
            f'<audio controls preload="none" src="escucha/{clave}_{v}.wav"></audio></div>'
            for v in orden if (clave, v) in fuentes)
        bloques.append(f'<div class="par"><b>{html.escape(texto)}</b>{filas}</div>')

    (SALIDA / "motores.html").write_text(f"""<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Motores de voz</title>
<style>
 body {{ margin:0; background:#16161a; color:#e6e6ea; font:15px/1.5 "Segoe UI",system-ui,sans-serif; }}
 main {{ max-width:820px; margin:0 auto; padding:28px 20px; }}
 h1 {{ font-size:20px; margin:0 0 6px; }} h2 {{ font-size:16px; margin:28px 0 8px; }}
 p {{ color:#a8a8b2; margin:4px 0 18px; }}
 .par {{ background:#1f1f25; border:1px solid #2e2e36; border-radius:8px; padding:12px 14px; margin-bottom:12px; }}
 .par b {{ display:block; margin-bottom:8px; font-weight:600; }}
 .fila {{ display:grid; grid-template-columns:260px 1fr; gap:8px; align-items:center; margin:3px 0; }}
 .fila span {{ color:#8a8a94; font-size:13px; }} .fila.real span {{ color:#4ade80; }}
 audio {{ width:100%; height:32px; }}
 @media (max-width:560px) {{ .fila {{ grid-template-columns:1fr; gap:2px; }} }}
</style></head><body><main>
<h1>Motores de voz</h1>
<p>Cada frase en español la dijo la voz real en las grabaciones. Los motores dicen el mismo texto imitando
una muestra de 8 s de la voz que no está entre estas frases. "+ RVC" es la misma salida pasada por el modelo que entrenamos,
que afina el timbre sin cambiar la entonación. Todo al mismo volumen. Las frases en inglés no tienen original.</p>
<h2>Español</h2>
{"".join(b for b, c in zip(bloques, textos) if c.startswith("es"))}
<h2>Inglés</h2>
{"".join(b for b, c in zip(bloques, textos) if c.startswith("en"))}
</main></body></html>""", encoding="utf-8")
    print(f"pagina: {SALIDA / 'motores.html'}")


if __name__ == "__main__":
    main()
