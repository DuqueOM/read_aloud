"""Prepara la pagina de revision unica con los clips de todos los capitulos.

Corre en orden, uno a la vez en la tarjeta grafica, y muestra el avance en
progreso.html:

1. 26_puntuar.py: medidas de calidad y puntaje de cada clip.
2. 27_transcribir_clips.py qwen: Qwen3-ASR sobre cada clip (en .venv_asr).
3. 27_transcribir_clips.py whisper: Whisper large-v3 sobre cada clip.
4. 28_revision.py: la pagina.

Cada paso guarda lo que hace, asi que si algo lo interrumpe, volver a
correr esto sigue donde quedo (27 solo transcribe lo que falta).

Se lanza aparte, para que no dependa de la sesion que lo abre:
    .venv/Scripts/python.exe scripts/29_preparar_revision.py
"""

import subprocess
import sys
import time
from pathlib import Path

import voz
from progreso_comun import AVANCE, RAIZ, guardar, leer_avance, marcar, nuevo

PASOS = [
    ("Puntaje de calidad de cada clip", RAIZ / ".venv" / "Scripts" / "python.exe", ["26_puntuar.py"]),
    ("Texto con Qwen3-ASR", RAIZ / ".venv_asr" / "Scripts" / "python.exe", ["27_transcribir_clips.py", "qwen"]),
    ("Texto con Whisper", RAIZ / ".venv" / "Scripts" / "python.exe", ["27_transcribir_clips.py", "whisper"]),
]
REGISTRO = RAIZ / "datos" / "29_preparar_revision.log"


def correr(python, argumentos, estado=None, fila=None) -> bool:
    """Corre un paso; mientras dura, muestra en la pagina cuanto lleva."""
    AVANCE.unlink(missing_ok=True)
    with open(REGISTRO, "a", encoding="utf-8") as registro:
        registro.write(f"\n== {time.strftime('%F %T')} {' '.join(argumentos)}\n")
        registro.flush()
        proceso = subprocess.Popen([str(python), str(RAIZ / "scripts" / argumentos[0]), *argumentos[1:]],
                                   cwd=str(RAIZ), stdout=registro, stderr=subprocess.STDOUT)
        while proceso.poll() is None:
            if estado is not None:
                marcar(estado, "estado", leer_avance(), fila)
            time.sleep(15)
        return proceso.returncode == 0


def main() -> None:
    # La marca queda puesta toda la cadena: si cada paso pusiera la suya, entre
    # uno y otro Read Aloud volveria a cargar la voz para soltarla al minuto.
    import gpu
    gpu.ocupar()
    estado = nuevo(f"Voz de {voz.TITULO} · preparación de la revisión", [p[0] for p in PASOS], ["estado"],
                   finales=["pagina"], revision="datos/28_revision/revision.html")
    estado["filas"] = "Paso"
    estado["nota"] = ("Los capítulos ya están separados, transcritos y cortados en frases completas. "
                      "Mientras corren estos pasos, Read Aloud lee con Piper.")
    guardar(estado)
    for nombre, python, argumentos in PASOS:
        inicio = time.time()
        marcar(estado, "estado", "en curso", nombre, f"Empieza: {nombre}")
        ok = correr(python, argumentos, estado, nombre)
        minutos = (time.time() - inicio) / 60
        marcar(estado, "estado", "listo" if ok else "con error", nombre,
               f"{nombre}: {'listo' if ok else 'con error'} en {minutos:.0f} min")
        if not ok:
            estado["nota"] = f"Falló «{nombre}». Detalle en datos/29_preparar_revision.log."
            guardar(estado)
            sys.exit(1)

    marcar(estado, "pagina", "en curso", evento="Armando la página de revisión")
    ok = correr(PASOS[0][1], ["28_revision.py"])
    estado["nota"] = ("Lista. Revisa en una sola pasada: conservar o descartar y corregir el texto. "
                      "Al terminar, exporta revision.json." if ok else
                      "Falló la página. Detalle en datos/29_preparar_revision.log.")
    marcar(estado, "pagina", "listo" if ok else "con error", evento="Página de revisión lista" if ok else "Falló la página")


if __name__ == "__main__":
    main()
