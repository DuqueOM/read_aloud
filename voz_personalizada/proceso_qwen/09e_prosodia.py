"""Compara la prosodia de la voz real, la voz entrenada y Piper.

Para cada frase de 09d_comparar.py mide, en las tres versiones:

  rango      variacion del tono, en semitonos (percentil 95 menos 5)
  movilidad  cuanto se mueve el tono de un instante al siguiente, semitonos/s
  final      cuanto sube o baja el tono en el ultimo 20 % de la frase
  silabas/s  velocidad de habla, sin contar las pausas
  pausas     silencios de mas de 120 ms dentro de la frase

Y la correlacion entre la curva de tono de la voz entrenada y la de Piper:
si se acerca a 1, la entonacion de la voz entrenada es la de Piper.

Corre en el entorno de Applio:
    applio/.venv/Scripts/python.exe scripts/09e_prosodia.py
"""

import json
import re
from pathlib import Path

import librosa
import numpy as np

RAIZ = Path(__file__).resolve().parent.parent
COMPARAR = RAIZ / "datos" / "09_comparar"
TASA = 16000
SALTO = 160  # 10 ms


def tono(archivo: Path):
    audio = librosa.load(archivo, sr=TASA)[0]
    f0, sonoro, _ = librosa.pyin(audio, fmin=70, fmax=1000, sr=TASA, hop_length=SALTO)
    semitonos = np.where(sonoro, 12 * np.log2(np.where(sonoro, f0, 1) / 100), np.nan)
    return audio, semitonos


def medir(archivo: Path, silabas: int) -> dict:
    audio, st = tono(archivo)
    validos = st[~np.isnan(st)]
    tramos = librosa.effects.split(audio, top_db=35, frame_length=400, hop_length=SALTO)
    habla = sum(fin - inicio for inicio, fin in tramos) / TASA
    pausas = sum(1 for a, b in zip(tramos[:-1], tramos[1:]) if (b[0] - a[1]) / TASA > 0.12)
    # Movilidad: cambio de tono entre cuadros sonoros contiguos.
    pasos = np.diff(st)
    movilidad = float(np.nanmedian(np.abs(pasos)) * 100) if np.any(~np.isnan(pasos)) else 0.0
    indices = np.where(~np.isnan(st))[0]
    corte = indices[0] + 0.8 * (indices[-1] - indices[0])
    final = float(np.nanmedian(st[indices[indices >= corte]][-15:]) - np.nanmedian(st[indices[indices < corte]]))
    return {
        "rango": float(np.percentile(validos, 95) - np.percentile(validos, 5)),
        "movilidad": movilidad,
        "final": final,
        "silabas_s": silabas / habla,
        "pausas": pausas,
        "curva": st,
    }


def silabas(texto: str) -> int:
    return len(re.findall(r"[aeiouáéíóúü]+", texto.lower()))


def correlacion(a: np.ndarray, b: np.ndarray) -> float:
    n = min(len(a), len(b))
    a, b = a[:n], b[:n]
    ambos = ~np.isnan(a) & ~np.isnan(b)
    return float(np.corrcoef(a[ambos], b[ambos])[0, 1])


def main() -> None:
    frases = json.loads((COMPARAR / "frases.json").read_text(encoding="utf-8"))
    tabla = {v: [] for v in ("real", "entrenada", "piper")}
    corr = []
    preguntas = []
    for f in frases:
        s = silabas(f["texto"])
        medidas = {v: medir(COMPARAR / "audio" / f"f{f['n']}_{v}.wav", s) for v in tabla}
        for v in tabla:
            tabla[v].append(medidas[v])
        corr.append(correlacion(medidas["entrenada"]["curva"], medidas["piper"]["curva"]))
        if "?" in f["texto"]:
            preguntas.append((f["texto"], medidas["real"]["final"], medidas["entrenada"]["final"]))

    print(f"{'':12s}{'rango st':>10s}{'movil st/s':>12s}{'silabas/s':>11s}{'pausas':>8s}")
    for v, filas in tabla.items():
        print(
            f"{v:12s}{np.mean([m['rango'] for m in filas]):>10.1f}"
            f"{np.mean([m['movilidad'] for m in filas]):>12.1f}"
            f"{np.mean([m['silabas_s'] for m in filas]):>11.1f}"
            f"{np.mean([m['pausas'] for m in filas]):>8.1f}"
        )
    print(f"\ncorrelacion de la curva de tono entrenada-Piper: media {np.mean(corr):.2f} (min {min(corr):.2f})")
    print("\npreguntas: subida final del tono, semitonos (real / entrenada)")
    for texto, real, entrenada in preguntas:
        print(f"  {real:+5.1f} / {entrenada:+5.1f}  {texto}")
    print("\npor frase: rango real / entrenada")
    for f, r, e in zip(frases, tabla["real"], tabla["entrenada"]):
        print(f"  {r['rango']:5.1f} / {e['rango']:5.1f}  {f['texto']}")


if __name__ == "__main__":
    main()
