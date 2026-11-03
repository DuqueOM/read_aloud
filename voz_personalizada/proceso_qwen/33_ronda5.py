"""Quinta ronda: dos entrenamientos para mejorar la voz de los 60 mejores minutos.

A ciegas, los 60 mejores minutos le ganaron con claridad a todo lo conservado
(ADR 0010), aunque la validacion los daba empatados. Esta ronda prueba dos
cosas, una a la vez en la tarjeta, con el avance en progreso.html:

1. Los 45 mejores minutos, con lo mismo de antes (aprendizaje 3e-5): si
   recortar mas por calidad sigue ayudando.
2. Los 60 mejores minutos con la mitad de aprendizaje (1.5e-5): en todas las
   rondas la mejor fue la epoca 2 y la validacion salta mucho entre una
   epoca y otra; con pasos mas cortos puede haber un punto mejor.

Los dos guardan tambien la mitad de cada epoca y paran si la validacion
empeora dos epocas seguidas. Al final genera las frases de prueba con el
mejor punto de cada uno por la validacion y arma la pagina de escucha, con la
voz actual de la app (puntos_v4_60, epoca 2) para comparar.

Se lanza aparte, para que no dependa de la sesion que lo abre:
    .venv/Scripts/python.exe scripts/33_ronda5.py
"""

import importlib.util
import json
from pathlib import Path

import voz
from progreso_comun import RAIZ, guardar, marcar, nuevo

spec = importlib.util.spec_from_file_location("revision", Path(__file__).parent / "29_preparar_revision.py")
revision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(revision)

PRINCIPAL = RAIZ / ".venv" / "Scripts" / "python.exe"
QWEN = RAIZ / ".venv_qwen" / "Scripts" / "python.exe"
QWEN_DATOS = RAIZ / "datos" / "31_qwen"
# La version de 11c_probar_qwen.py que usa hoy la app, para comparar.
APP = f"qwen_{voz.NOMBRE}_v4_60_e02"
COMUN = ["--epocas", "8", "--paciencia", "2", "--medias", "--reanudar"]
ENTRENAMIENTOS = [
    ("Entrenamiento con los 45 mejores minutos", "puntos_v5_45", "mejores45", "3e-5", "45 mejores minutos"),
    (
        "Entrenamiento con los 60 mejores, aprendizaje lento",
        "puntos_v5_60_lento",
        "mejores60",
        "1.5e-5",
        "60 mejores, aprendizaje lento",
    ),
]
PRUEBAS = "Frases de prueba y página de escucha"


def puntos(salida: str) -> Path:
    return RAIZ / "datos" / "11_qwen" / salida


def mejor_punto(salida: str) -> str:
    """La epoca, o mitad de epoca, con menos validacion: "2" o "1.5"."""
    registro = json.loads((puntos(salida) / "registro.json").read_text(encoding="utf-8"))
    epoca = min(registro, key=lambda f: f["validacion"])["epoca"]
    return str(int(epoca)) if epoca == int(epoca) else str(epoca)


def version(salida: str, epoca: str) -> str:
    entera, _, fraccion = epoca.partition(".")
    return f"qwen_{voz.NOMBRE}_{salida.removeprefix('puntos_')}_e{int(entera):02d}" + (
        f"_{fraccion}" if fraccion else ""
    )


def main() -> None:
    # La marca queda puesta toda la cadena: si cada paso pusiera la suya, entre
    # uno y otro Read Aloud volveria a cargar la voz para soltarla al minuto.
    import gpu

    gpu.ocupar()
    estado = nuevo(
        f"Voz de {voz.TITULO} · quinta ronda", [e[0] for e in ENTRENAMIENTOS] + [PRUEBAS], ["estado"], finales=[]
    )
    estado["filas"] = "Paso"
    estado["nota"] = (
        "Dos entrenamientos para mejorar la voz actual: los 45 mejores minutos, y los 60 mejores "
        "con aprendizaje más lento. Mientras corren, Read Aloud lee con Piper."
    )
    guardar(estado)
    revision.REGISTRO = RAIZ / "datos" / "33_ronda5.log"

    for nombre, salida, datos, aprendizaje, _ in ENTRENAMIENTOS:
        if (puntos(salida) / "terminado.json").exists():
            marcar(estado, "estado", "listo", nombre)
            continue
        marcar(estado, "estado", "en curso", nombre, f"Empieza: {nombre}")
        ok = revision.correr(
            QWEN,
            [
                "11b_entrenar_qwen.py",
                "--datos",
                str(QWEN_DATOS / datos),
                "--salida",
                salida,
                "--aprendizaje",
                aprendizaje,
                *COMUN,
            ],
            estado,
            nombre,
        )
        marcar(estado, "estado", "listo" if ok else "con error", nombre, f"{nombre}: {'listo' if ok else 'con error'}")
        if not ok:
            estado["nota"] = f"Falló «{nombre}». Detalle en datos/33_ronda5.log."
            guardar(estado)
            return

    marcar(estado, "estado", "en curso", PRUEBAS, f"Empieza: {PRUEBAS}")
    candidatas = []
    for _, salida, _, _, etiqueta in ENTRENAMIENTOS:
        epoca = mejor_punto(salida)
        if not revision.correr(QWEN, ["11c_probar_qwen.py", "--puntos", salida, epoca], estado, PRUEBAS):
            marcar(estado, "estado", "con error", PRUEBAS)
            estado["nota"] = "Fallaron las frases de prueba. Detalle en datos/33_ronda5.log."
            guardar(estado)
            return
        candidatas.append(f"{version(salida, epoca)}={etiqueta}, época {epoca.replace('.', ',')}")
    ok = revision.correr(PRINCIPAL, ["13_comparar.py", "--app", APP, *candidatas], estado, PRUEBAS)
    marcar(estado, "estado", "listo" if ok else "con error", PRUEBAS)
    estado["nota"] = (
        f"Listo. Escucha datos/13_comparar/comparar.html y elige cuál suena más a {voz.TITULO}."
        if ok
        else "Falló la página de escucha. Detalle en datos/33_ronda5.log."
    )
    guardar(estado)


if __name__ == "__main__":
    main()
