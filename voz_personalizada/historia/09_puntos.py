"""Prueba a ciegas de puntos de control del modelo RVC.

Con pocos minutos de voz, entrenar de mas hace que el modelo copie hasta los
defectos del conjunto y la voz empieza a sonar metalica; entrenar de menos la
deja borrosa. El punto justo se elige de oido: cinco puntos de control
convierten las mismas frases y se comparan sin saber cual es cual.

Las frases las lee Piper con las voces que usa Read Aloud, porque esa es la
fuente real del lector. El tono se sube lo necesario para llevar la mediana
de Piper a la de la voz, medida en el conjunto.

Corre en el entorno de Applio:
    applio/.venv/Scripts/python.exe scripts/09_puntos.py
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
SALIDA = RAIZ / "datos" / "09_puntos"
PIPER = Path(r"C:\ruta\a\read_aloud\read_aloud_piper")  # la carpeta de Piper de Read Aloud

FRASES = [
    ("es_MX-claude-high", "¡No puede ser! ¿De verdad encontraste las llaves debajo de la cama?"),
    ("es_MX-claude-high", "Hoy aprendí que la paciencia también es una forma de valentía."),
    ("es_MX-claude-high", "El archivo de configuración se guarda en la carpeta del proyecto, junto al README."),
    ("en_US-lessac-medium", "Wait, are you serious? I can't believe we actually made it!"),
    ("en_US-lessac-medium", "The function returns a list of results, sorted by date."),
]
EPOCAS = [100, 175, 250, 325, 400]

# Ajustes de conversion, iguales para todos los puntos de control.
INDICE = 0.5
PROTECCION = 0.33
NIVEL_DB = -20.0
PICO_DB = -1.0


def igualar(audio: np.ndarray) -> np.ndarray:
    audio = audio * (10 ** (NIVEL_DB / 20) / (np.sqrt(np.mean(audio ** 2)) + 1e-9))
    pico = np.max(np.abs(audio)) + 1e-9
    limite = 10 ** (PICO_DB / 20)
    return audio * (limite / pico) if pico > limite else audio


def tono_mediano(archivos) -> float:
    valores = []
    for archivo in archivos:
        audio, tasa = librosa.load(archivo, sr=16000)
        f0, sonoro, _ = librosa.pyin(audio, fmin=70, fmax=900, sr=tasa)
        valores.append(f0[sonoro])
    return float(np.median(np.concatenate(valores)))


def puntos_de_control() -> dict:
    disponibles = {}
    for archivo in MODELO.glob("mi_voz_es_*e_*s.pth"):
        epoca = int(re.search(r"_(\d+)e_", archivo.name).group(1))
        disponibles[epoca] = archivo
    if not disponibles:
        raise SystemExit("Todavia no hay puntos de control guardados.")
    return {e: disponibles[min(disponibles, key=lambda d: abs(d - e))] for e in EPOCAS}


def main() -> None:
    fuente = SALIDA / "fuente"
    prueba = SALIDA / "prueba"
    fuente.mkdir(parents=True, exist_ok=True)
    (prueba / "audio").mkdir(parents=True, exist_ok=True)

    for n, (voz, texto) in enumerate(FRASES, 1):
        destino = fuente / f"frase{n}.wav"
        if not destino.exists():
            subprocess.run([str(PIPER / "bin" / "piper" / "piper.exe"), "--model", str(PIPER / "voices" / f"{voz}.onnx"),
                            "--output_file", str(destino)], input=texto.encode("utf-8"), check=True,
                           capture_output=True)

    azar = random.Random(0)
    tono_voz = tono_mediano(azar.sample(sorted(CONJUNTO.glob("*.wav")), 40))
    print(f"tono mediano de la voz: {tono_voz:.0f} Hz")

    sys.path.insert(0, str(APPLIO))
    os.chdir(APPLIO)
    from rvc.infer.infer import VoiceConverter

    convertidor = VoiceConverter()
    indices = sorted(MODELO.glob("*.index"))
    indice = str(indices[0]) if indices else ""
    puntos = puntos_de_control()
    print("puntos de control:", {e: p.name for e, p in puntos.items()}, "indice:", Path(indice).name)

    letras = "ABCDEFGH"[:len(puntos)]
    clave, clips = {}, []
    for n, (voz, texto) in enumerate(FRASES, 1):
        origen = fuente / f"frase{n}.wav"
        semitonos = int(np.clip(round(12 * np.log2(tono_voz / tono_mediano([origen]))), -24, 24))
        orden = list(letras)
        azar.shuffle(orden)
        clave[f"clip{n}"] = {"texto": texto, "voz": voz, "semitonos": semitonos}
        for letra, (epoca, pesos) in zip(orden, puntos.items()):
            temporal = prueba / "audio" / f"clip{n}_{letra}_crudo.wav"
            convertidor.convert_audio(
                audio_input_path=str(origen), audio_output_path=str(temporal),
                model_path=str(pesos), index_path=indice, pitch=semitonos,
                f0_method="rmvpe", index_rate=INDICE, protect=PROTECCION,
            )
            audio, tasa = sf.read(temporal, dtype="float32")
            sf.write(prueba / "audio" / f"clip{n}_{letra}.wav", igualar(audio), tasa, subtype="PCM_24")
            temporal.unlink()
            clave[f"clip{n}"][letra] = epoca
        clips.append({"n": n, "texto": texto})
        print(f"clip{n}: {semitonos:+d} semitonos")

    (prueba / "clave.json").write_text(json.dumps(clave, ensure_ascii=False, indent=1), encoding="utf-8")
    plantilla = (Path(__file__).parent / "prueba_plantilla.html").read_text(encoding="utf-8")
    pagina = (plantilla
              .replace("/*CLIPS*/[]", json.dumps(clips, ensure_ascii=False))
              .replace("/*TITULO*/'Prueba a ciegas de mejora de audio'", "'Prueba a ciegas de puntos de control'")
              .replace("/*VERSIONES*/4", str(len(letras)))
              .replace("/*CLAVE*/'mi_voz_prueba_mejora_v1'", "'mi_voz_prueba_puntos_v1'"))
    (prueba / "prueba.html").write_text(pagina, encoding="utf-8")
    print(f"pagina: {prueba / 'prueba.html'}")


if __name__ == "__main__":
    main()
