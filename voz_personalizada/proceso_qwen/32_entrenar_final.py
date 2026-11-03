"""Prepara los dos conjuntos finales y entrena Qwen3-TTS con cada uno.

En orden, uno a la vez en la tarjeta, con el avance en progreso.html:

1. 31_conjunto_qwen.py audio: sin eco y con el volumen igualado.
2. 31_conjunto_qwen.py codigos: los codigos de Qwen3-TTS de cada clip.
3. 11b_entrenar_qwen.py con los mejores minutos (minutos_finales de voz.toml,
   60 por defecto): en datos/11_qwen/puntos_mejores60.
4. 11b_entrenar_qwen.py con todo lo conservado: en datos/11_qwen/puntos_todos.

Los dos entrenamientos usan lo que funciono con la voz de prueba (aprendizaje 3e-5,
LoRA r=64), con la misma semilla, y guardan cada epoca: la mejor se elige por
la validacion y despues a ciegas, de oido. Con la voz de prueba fueron puntos_v4_60 y
puntos_v4_todos.

Se lanza aparte, para que no dependa de la sesion que lo abre:
    .venv/Scripts/python.exe scripts/32_entrenar_final.py
"""

import importlib.util
import json
from pathlib import Path

from progreso_comun import RAIZ, guardar, marcar, nuevo


def modulo(nombre: str, archivo: str):
    spec = importlib.util.spec_from_file_location(nombre, Path(__file__).parent / archivo)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


revision = modulo("revision", "29_preparar_revision.py")
conjunto = modulo("conjunto_qwen", "31_conjunto_qwen.py")

PRINCIPAL = RAIZ / ".venv" / "Scripts" / "python.exe"
QWEN = RAIZ / ".venv_qwen" / "Scripts" / "python.exe"
DATOS = RAIZ / "datos"
EPOCAS = "8"
APRENDIZAJE = "3e-5"
# Con 60 minutos de la voz de prueba, la validacion toco fondo en la epoca 2 y subio en
# cada una de las siguientes: se para cuando empeora dos epocas seguidas.
PACIENCIA = "2"
MEJORES = conjunto.MEJORES
PASOS = [
    ("Audio sin eco y volumen igualado", PRINCIPAL, ["31_conjunto_qwen.py", "audio"]),
    ("Códigos de audio de Qwen3-TTS", QWEN, ["31_conjunto_qwen.py", "codigos"]),
    (
        f"Entrenamiento con los {conjunto.voz.MINUTOS_FINALES:g} mejores minutos",
        QWEN,
        [
            "11b_entrenar_qwen.py",
            "--datos",
            str(DATOS / "31_qwen" / MEJORES),
            "--salida",
            f"puntos_{MEJORES}",
            "--aprendizaje",
            APRENDIZAJE,
            "--epocas",
            EPOCAS,
        ],
    ),
    (
        "Entrenamiento con todo lo conservado",
        QWEN,
        [
            "11b_entrenar_qwen.py",
            "--datos",
            str(DATOS / "31_qwen" / "todos"),
            "--salida",
            "puntos_todos",
            "--aprendizaje",
            APRENDIZAJE,
            "--epocas",
            EPOCAS,
        ],
    ),
]


def hecho(argumentos) -> bool:
    """Si el paso ya termino en una corrida anterior: asi, si la computadora se
    apaga, volver a lanzar esto sigue donde quedo."""
    if argumentos[:2] == ["31_conjunto_qwen.py", "audio"]:
        claves = {c["clave"] for lista in [*conjunto.conjuntos().values(), conjunto.validacion_nueva()] for c in lista}
        return all((conjunto.AUDIO / f"{c}.wav").exists() for c in claves)
    if argumentos[:2] == ["31_conjunto_qwen.py", "codigos"]:
        return all((DATOS / "31_qwen" / c / "entrenamiento.jsonl").exists() for c in (MEJORES, "todos"))
    puntos = DATOS / "11_qwen" / argumentos[argumentos.index("--salida") + 1]
    registro = (
        json.loads((puntos / "registro.json").read_text(encoding="utf-8"))
        if (puntos / "registro.json").exists()
        else []
    )
    return len(registro) >= int(EPOCAS) or (puntos / "terminado.json").exists()


def main() -> None:
    # La marca queda puesta toda la cadena: si cada paso pusiera la suya, entre
    # uno y otro Read Aloud volveria a cargar la voz para soltarla al minuto.
    import gpu

    gpu.ocupar()
    estado = nuevo(f"Voz de {conjunto.voz.TITULO} · entrenamiento final", [p[0] for p in PASOS], ["estado"], finales=[])
    estado["filas"] = "Paso"
    estado["nota"] = (
        f"Dos entrenamientos para comparar a ciegas: los {conjunto.voz.MINUTOS_FINALES:g} mejores "
        "minutos contra todo lo que conservaste. Mientras corren, Read Aloud lee con Piper."
    )
    guardar(estado)
    revision.REGISTRO = DATOS / "32_entrenar_final.log"
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
            estado["nota"] = f"Falló «{nombre}». Detalle en datos/32_entrenar_final.log."
            guardar(estado)
            return
    estado["nota"] = (
        "Los dos entrenamientos terminaron. Sigue con 11c_probar_qwen.py y 13_comparar.py para "
        "elegir la época de oído (docs\\voz-personalizada.md)."
    )
    guardar(estado)


if __name__ == "__main__":
    main()
