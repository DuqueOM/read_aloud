"""Prepara los dos conjuntos finales y entrena Qwen3-TTS con cada uno.

En orden, uno a la vez en la tarjeta, con el avance en progreso.html:

1. 31_conjunto_qwen.py audio: sin eco y con el volumen igualado.
2. 31_conjunto_qwen.py codigos: los codigos de Qwen3-TTS de cada clip.
3. 11b_entrenar_qwen.py con los 60 mejores minutos.
4. 11b_entrenar_qwen.py con todo lo conservado (unos 74 minutos).

Los dos entrenamientos usan lo del tercero, el que el usuario eligio
(aprendizaje 3e-5, LoRA r=64), con la misma semilla, y guardan cada epoca:
la mejor se elige por la validacion y despues a ciegas, de oido.

Se lanza aparte, para que no dependa de la sesion que lo abre:
    .venv/Scripts/python.exe scripts/32_entrenar_final.py
"""

import importlib.util
import json
from pathlib import Path

from progreso_comun import RAIZ, guardar, marcar, nuevo

spec = importlib.util.spec_from_file_location("revision", Path(__file__).parent / "29_preparar_revision.py")
revision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(revision)

PRINCIPAL = RAIZ / ".venv" / "Scripts" / "python.exe"
QWEN = RAIZ / ".venv_qwen" / "Scripts" / "python.exe"
EPOCAS = "8"
APRENDIZAJE = "3e-5"
# Con 60 minutos, la validacion toco fondo en la epoca 2 y subio en cada una
# de las siguientes: se para cuando empeora dos epocas seguidas.
PACIENCIA = "2"
PASOS = [
    ("Audio sin eco y volumen igualado", PRINCIPAL, ["31_conjunto_qwen.py", "audio"]),
    ("Códigos de audio de Qwen3-TTS", QWEN, ["31_conjunto_qwen.py", "codigos"]),
    ("Entrenamiento con los 60 mejores minutos", QWEN,
     ["11b_entrenar_qwen.py", "--datos", str(RAIZ / "datos" / "31_qwen" / "mejores60"), "--salida", "puntos_v4_60",
      "--aprendizaje", APRENDIZAJE, "--epocas", EPOCAS]),
    ("Entrenamiento con todo lo conservado", QWEN,
     ["11b_entrenar_qwen.py", "--datos", str(RAIZ / "datos" / "31_qwen" / "todos"), "--salida", "puntos_v4_todos",
      "--aprendizaje", APRENDIZAJE, "--epocas", EPOCAS]),
]


def hecho(argumentos) -> bool:
    """Si el paso ya termino en una corrida anterior: asi, si la computadora se
    apaga, volver a lanzar esto sigue donde quedo."""
    datos = RAIZ / "datos"
    if argumentos[:2] == ["31_conjunto_qwen.py", "audio"]:
        return len(list((datos / "31_final" / "audio").glob("*.wav"))) >= 1438
    if argumentos[:2] == ["31_conjunto_qwen.py", "codigos"]:
        return all((datos / "31_qwen" / c / "entrenamiento.jsonl").exists() for c in ("mejores60", "todos"))
    puntos = datos / "11_qwen" / argumentos[argumentos.index("--salida") + 1]
    registro = json.loads((puntos / "registro.json").read_text(encoding="utf-8")) if (puntos / "registro.json").exists() else []
    if len(registro) >= int(EPOCAS) or (puntos / "terminado.json").exists():
        return True
    # El primer entrenamiento empezo antes de que se pudiera retomar: si se
    # corto, lo que guardo alcanza, porque su validacion ya habia tocado fondo
    # en la epoca 2 y subia en la 3.
    return not (puntos / "reanudar.pt").exists() and len(registro) >= 3


def main() -> None:
    # La marca queda puesta toda la cadena: si cada paso pusiera la suya, entre
    # uno y otro Read Aloud volveria a cargar la voz para soltarla al minuto.
    import gpu
    gpu.ocupar()
    estado = nuevo("Voz de la voz de prueba · entrenamiento final", [p[0] for p in PASOS], ["estado"], finales=[])
    estado["filas"] = "Paso"
    estado["nota"] = ("Dos entrenamientos para comparar a ciegas: los 60 mejores minutos contra todo lo que "
                      "conservaste. Mientras corren, Read Aloud lee con Piper.")
    guardar(estado)
    revision.REGISTRO = RAIZ / "datos" / "32_entrenar_final.log"
    for nombre, python, argumentos in PASOS:
        if hecho(argumentos):
            marcar(estado, "estado", "listo", nombre)
            continue
        if argumentos[0] == "11b_entrenar_qwen.py":
            argumentos = argumentos + ["--reanudar", "--paciencia", PACIENCIA]
        marcar(estado, "estado", "en curso", nombre, f"Empieza: {nombre}")
        ok = revision.correr(python, argumentos, estado, nombre)
        marcar(estado, "estado", "listo" if ok else "con error", nombre, f"{nombre}: {'listo' if ok else 'con error'}")
        if not ok:
            estado["nota"] = f"Falló «{nombre}». Detalle en datos/32_entrenar_final.log; Claude lo revisa."
            guardar(estado)
            return
    estado["nota"] = "Los dos entrenamientos terminaron. Claude elige las mejores épocas y arma la comparación a ciegas."
    guardar(estado)


if __name__ == "__main__":
    main()
