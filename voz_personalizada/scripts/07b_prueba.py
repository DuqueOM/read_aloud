"""Prueba a ciegas: ¿algun modelo de mejora deja mejor la voz?

Elige ocho clips del conjunto y prepara cuatro versiones de cada uno:

- el clip tal como esta;
- sin reverberacion, del paso 07a;
- con resemble-enhance, que quita ruido y reconstruye los agudos que la
  compresion del video corto, por encima de 15 kHz si es AAC a 128 kbps;
- sin reverberacion y despues con resemble-enhance.

Las cuatro versiones se igualan en volumen, porque la que suena mas fuerte
parece mejor aunque no lo sea, y se presentan con letras al azar distintas en
cada clip. La clave queda en clave.json, que la pagina no lee.

De la muestra, tres clips son los de mas reverberacion medida, donde mas
puede notarse el modelo que la quita; los otros cinco cubren voces fuertes y
suaves de distintas grabaciones.

Al terminar, se exportan las respuestas desde la pagina y se comparan con la
clave para decidir que entra en el conjunto final (07c_conjunto_final.py).

Corre en el entorno .venv_mejora de la carpeta de trabajo, que tiene
resemble-enhance:
    .venv_mejora/Scripts/python.exe <repo>/voz_personalizada/scripts/07b_prueba.py
"""

import json
import pathlib
import random
import shutil
import sys
import types
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

from comun import DATOS, NOMBRE

CONJUNTO = DATOS / "06_conjunto" / NOMBRE
CORTES = DATOS / "04_cortes"
MEJORA = DATOS / "07_mejora"
PRUEBA = MEJORA / "prueba"

CLIPS = 8
CON_MAS_ECO = 3
DURACION_S = (2.0, 6.0)
NIVEL_DB = -20.0
PICO_DB = -1.0

# Ajustes de resemble-enhance: 64 pasos del integrador, el doble que el valor
# por defecto, con fuerza de limpieza y temperatura intermedias.
PASOS = 64
LIMPIEZA = 0.5
TEMPERATURA = 0.5


def sin_deepspeed() -> None:
    """resemble-enhance importa deepspeed en modulos que solo usa para entrenar.

    En Windows deepspeed no se instala con facilidad, y para inferencia no hace
    falta: se registran modulos vacios con los nombres que esos imports piden.
    """
    raiz = types.ModuleType("deepspeed")
    acelerador = types.ModuleType("deepspeed.accelerator")
    runtime = types.ModuleType("deepspeed.runtime")
    motor = types.ModuleType("deepspeed.runtime.engine")
    utilidades = types.ModuleType("deepspeed.runtime.utils")
    acelerador.get_accelerator = lambda: None
    motor.DeepSpeedEngine = type("DeepSpeedEngine", (), {})
    utilidades.clip_grad_norm_ = None
    raiz.DeepSpeedConfig = type("DeepSpeedConfig", (), {})
    raiz.accelerator, raiz.runtime = acelerador, runtime
    runtime.engine, runtime.utils = motor, utilidades
    for nombre, modulo in [
        ("deepspeed", raiz),
        ("deepspeed.accelerator", acelerador),
        ("deepspeed.runtime", runtime),
        ("deepspeed.runtime.engine", motor),
        ("deepspeed.runtime.utils", utilidades),
    ]:
        sys.modules[nombre] = modulo


def igualar(audio: np.ndarray) -> np.ndarray:
    audio = audio * (10 ** (NIVEL_DB / 20) / (np.sqrt(np.mean(audio**2)) + 1e-9))
    pico = np.max(np.abs(audio)) + 1e-9
    limite = 10 ** (PICO_DB / 20)
    return audio * (limite / pico) if pico > limite else audio


def elegir() -> list:
    eco = json.loads((MEJORA / "reverberacion.json").read_text(encoding="utf-8"))
    candidatos = []
    for archivo in sorted(CONJUNTO.glob("*.wav")):
        duracion = sf.info(archivo).duration
        if not DURACION_S[0] <= duracion <= DURACION_S[1]:
            continue
        episodio = archivo.stem.split("_")[0]
        crudo, _ = sf.read(CORTES / episodio / archivo.name, dtype="float32")
        nivel = 20 * np.log10(np.sqrt(np.mean(crudo**2)) + 1e-9)
        candidatos.append({"id": archivo.stem, "ep": episodio, "eco": eco[archivo.stem], "nivel": nivel})

    candidatos.sort(key=lambda c: c["eco"], reverse=True)
    elegidos = candidatos[:CON_MAS_ECO]

    # El resto, repartido entre la voz mas suave y la mas fuerte, sin repetir
    # grabacion.
    resto = sorted((c for c in candidatos[CON_MAS_ECO:]), key=lambda c: c["nivel"])
    usados = {c["ep"] for c in elegidos}
    faltan = CLIPS - CON_MAS_ECO
    for k in range(faltan):
        objetivo = round(k * (len(resto) - 1) / (faltan - 1))
        libres = [i for i, c in enumerate(resto) if c["ep"] not in usados]
        if libres:
            elegido = resto[min(libres, key=lambda i: abs(i - objetivo))]
            elegidos.append(elegido)
            usados.add(elegido["ep"])
    return elegidos


def main() -> None:
    sin_deepspeed()
    # La configuracion del modelo se guardo en Linux y trae rutas PosixPath,
    # que Windows no deja crear. Esas rutas son del entrenamiento y no se usan.
    pathlib.PosixPath = pathlib.WindowsPath
    from resemble_enhance.enhancer.inference import enhance

    dispositivo = "cuda" if torch.cuda.is_available() else "cpu"
    elegidos = elegir()

    if PRUEBA.exists():
        shutil.rmtree(PRUEBA)
    (PRUEBA / "audio").mkdir(parents=True)

    azar = random.Random(20261028)
    clave, clips = {}, []
    for n, clip in enumerate(elegidos, 1):
        original, tasa = sf.read(CONJUNTO / f"{clip['id']}.wav", dtype="float32")
        seco, _ = sf.read(MEJORA / "sin_reverb" / f"{clip['id']}.wav", dtype="float32")

        versiones = {"original": (original, tasa), "sin_reverb": (seco, tasa)}
        for nombre, base in [("resemble", original), ("sin_reverb+resemble", seco)]:
            salida, tasa_salida = enhance(
                torch.from_numpy(base), tasa, dispositivo, nfe=PASOS, solver="midpoint", lambd=LIMPIEZA, tau=TEMPERATURA
            )
            versiones[nombre] = (salida.cpu().numpy().astype(np.float32), tasa_salida)

        letras = list("ABCD")
        azar.shuffle(letras)
        clave[f"clip{n}"] = {"id": clip["id"], **dict(zip(letras, versiones))}
        for letra, (audio, tasa_v) in zip(letras, versiones.values()):
            sf.write(PRUEBA / "audio" / f"clip{n}_{letra}.wav", igualar(audio), tasa_v, subtype="PCM_24")

        texto = ""
        indice = json.loads((CORTES / clip["ep"] / "indice.json").read_text(encoding="utf-8"))
        for c in indice["clips"]:
            if c["archivo"] == f"{clip['id']}.wav":
                texto = c["texto"]
        clips.append({"n": n, "texto": texto})
        print(f"clip{n}: {clip['id']}  eco {clip['eco']:.1f} dB  nivel {clip['nivel']:.0f} dBFS")

    (PRUEBA / "clave.json").write_text(json.dumps(clave, ensure_ascii=False, indent=1), encoding="utf-8")
    plantilla = (Path(__file__).parent / "prueba_plantilla.html").read_text(encoding="utf-8")
    pagina = plantilla.replace("/*CLIPS*/[]", json.dumps(clips, ensure_ascii=False)).replace(
        "/*CLAVE*/'prueba_mejora'", json.dumps(f"prueba_mejora_{NOMBRE}")
    )
    (PRUEBA / "prueba.html").write_text(pagina, encoding="utf-8")
    print(f"pagina: {PRUEBA / 'prueba.html'}")


if __name__ == "__main__":
    main()
