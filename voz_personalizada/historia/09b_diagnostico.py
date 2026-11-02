"""Convierte varias fuentes con todos los puntos de control, para medirlas.

La prueba de oido no distinguio los puntos de control y el resultado no
convencio. Para saber si falla el modelo o la fuente, se convierten tres tipos
de audio con cada punto de control:

  piper     las frases de la prueba, voces graves de Piper, +10 a +13 semitonos
  femenina  voces femeninas de Piper en ingles, con menos cambio de tono
  natural   habla real de otras voces de los capitulos, con su entonacion

Si las fuentes naturales quedan mucho mas parecidas a la voz de prueba que las de Piper,
el modelo esta bien y el limite es la fuente. 09c_medir.py mide el parecido.

Corre en el entorno de Applio:
    applio/.venv/Scripts/python.exe scripts/09b_diagnostico.py
"""

import json
import os
import random
import re
import subprocess
import sys
from pathlib import Path

import librosa
import numpy as np
import soundfile as sf

RAIZ = Path(__file__).resolve().parent.parent
APPLIO = RAIZ / "applio"
MODELO = APPLIO / "logs" / "mi_voz_es"
CONJUNTO = RAIZ / "datos" / "08_final" / "mi_voz_es"
VOZ = RAIZ / "datos" / "02_voz"
CURVAS = RAIZ / "datos" / "04_curvas"
SALIDA = RAIZ / "datos" / "09_diagnostico"
PIPER = Path(r"C:\ruta\a\read_aloud\read_aloud_piper")

FEMENINAS = [
    ("en_GB-cori-high", "Wait, are you serious? I can't believe we actually made it!"),
    ("en_GB-cori-high", "The function returns a list of results, sorted by date."),
    ("en_US-ljspeech-high", "Wait, are you serious? I can't believe we actually made it!"),
    ("en_US-ljspeech-high", "The function returns a list of results, sorted by date."),
]

# Tramos de otras voces: parecido con la voz de prueba por debajo de esto en todas
# las ventanas, durante al menos MIN_S segundos seguidos.
PARECIDO_OTRO = 0.25
MIN_S, MAX_S = 3.0, 6.0
# Voces agudas, de mujer o de nino, para que el cambio de tono sea pequeno.
MIN_TONO_HZ = 200
NATURALES = 6

INDICE = 0.5
PROTECCION = 0.33


def tono_mediano(audios) -> float:
    valores = []
    for audio in audios:
        f0, sonoro, _ = librosa.pyin(audio, fmin=70, fmax=900, sr=16000)
        valores.append(f0[sonoro])
    valores = np.concatenate(valores)
    return float(np.median(valores)) if len(valores) else 0.0


def leer16(archivo) -> np.ndarray:
    return librosa.load(archivo, sr=16000)[0]


def tramos_naturales(fuente: Path) -> list:
    """Busca tramos largos de otras voces, uno por capitulo."""
    elegidos = []
    for curva in sorted(CURVAS.glob("ep*.npz")):
        datos = np.load(curva)
        centros, parecido = datos["centros"], datos["parecido"]
        otro = ~np.isnan(parecido) & (parecido < PARECIDO_OTRO)
        inicio = None
        for i, es_otro in enumerate(np.append(otro, False)):
            if es_otro and inicio is None:
                inicio = i
            elif not es_otro and inicio is not None:
                # Cada ventana dura 1.5 s; se recorta su mitad en los bordes
                # para no tocar la voz vecina.
                desde, hasta = centros[inicio], centros[i - 1]
                if hasta - desde >= MIN_S:
                    elegidos.append((curva.stem, float(desde), float(min(hasta, desde + MAX_S))))
                    break
                inicio = None

    tramos = []
    for episodio, desde, hasta in elegidos:
        archivo = VOZ / f"{episodio}_voz.wav"
        tasa = sf.info(archivo).samplerate
        audio, _ = sf.read(archivo, dtype="float32", always_2d=False,
                           start=int(desde * tasa), stop=int(hasta * tasa))
        audio = audio if audio.ndim == 1 else audio.mean(axis=1)
        if tono_mediano([librosa.resample(audio, orig_sr=tasa, target_sr=16000)]) < MIN_TONO_HZ:
            continue
        destino = fuente / f"natural_{episodio}_{round(desde)}.wav"
        sf.write(destino, audio, tasa, subtype="PCM_24")
        tramos.append(destino)
        if len(tramos) == NATURALES:
            break
    return tramos


def main() -> None:
    fuente = SALIDA / "fuente"
    convertido = SALIDA / "convertido"
    fuente.mkdir(parents=True, exist_ok=True)
    convertido.mkdir(parents=True, exist_ok=True)

    fuentes = {}
    for n in range(1, 6):
        fuentes[f"piper_{n}"] = ("piper", RAIZ / "datos" / "09_puntos" / "fuente" / f"frase{n}.wav")
    for n, (voz, texto) in enumerate(FEMENINAS, 1):
        destino = fuente / f"femenina_{n}.wav"
        if not destino.exists():
            subprocess.run([str(PIPER / "bin" / "piper" / "piper.exe"),
                            "--model", str(PIPER / "voices" / f"{voz}.onnx"), "--output_file", str(destino)],
                           input=texto.encode("utf-8"), check=True, capture_output=True)
        fuentes[f"femenina_{n}"] = ("femenina", destino)
    for destino in tramos_naturales(fuente):
        fuentes[destino.stem] = ("natural", destino)

    azar = random.Random(0)
    tono_voz = tono_mediano([leer16(a) for a in azar.sample(sorted(CONJUNTO.glob("*.wav")), 40)])
    print(f"tono mediano de la voz de prueba: {tono_voz:.0f} Hz")

    sys.path.insert(0, str(APPLIO))
    os.chdir(APPLIO)
    from rvc.infer.infer import VoiceConverter

    convertidor = VoiceConverter()
    indice = str(next(MODELO.glob("*.index")))
    pesos = sorted(MODELO.glob("mi_voz_es_*e_*s.pth"), key=lambda p: int(re.search(r"_(\d+)e_", p.name).group(1)))

    resumen = {"tono_voz": tono_voz, "fuentes": {}}
    for nombre, (tipo, origen) in fuentes.items():
        tono = tono_mediano([leer16(origen)])
        semitonos = int(np.clip(round(12 * np.log2(tono_voz / tono)), -24, 24))
        resumen["fuentes"][nombre] = {"tipo": tipo, "origen": str(origen), "semitonos": semitonos}
        print(f"{nombre}: {tono:.0f} Hz, {semitonos:+d} semitonos")
        for archivo in pesos:
            epoca = int(re.search(r"_(\d+)e_", archivo.name).group(1))
            destino = convertido / f"{nombre}_e{epoca}.wav"
            if destino.exists():
                continue
            convertidor.convert_audio(
                audio_input_path=str(origen), audio_output_path=str(destino),
                model_path=str(archivo), index_path=indice, pitch=semitonos,
                f0_method="rmvpe", index_rate=INDICE, protect=PROTECCION,
            )

    (SALIDA / "fuentes.json").write_text(json.dumps(resumen, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
