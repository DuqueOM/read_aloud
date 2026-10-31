"""Deja los mejores 60 minutos de los clips que el usuario conservo.

Parte de revision.json (la revision unica de 28_revision.py) y quita, en este
orden, anotando el motivo de cada clip:

1. El capitulo duplicado: ep25 resulto ser una segunda descarga de ep24 (el
   100 % de su texto propio coincide, y sus clips son la misma grabacion:
   parecido 1.00). Repetir un clip identico solo le da doble peso.
2. Los clips de menos de MIN_S: casi no tienen entonacion de la que aprender.
3. Las tomas de mas de una misma frase: una misma frase aparece 21 veces. No son el mismo audio reciclado (parecido entre
   0.49 y 0.93, contra 1.00 de una copia), son tomas distintas, y unas pocas
   ensenan variedad; veinte inclinan al modelo hacia esa frase. Se dejan
   MAX_TOMAS, las de mejor calidad.
4. Lo de menos calidad hasta quedar en META_MIN minutos.

La calidad de un clip es el promedio de su posicion (percentil) en cinco
medidas de 26_puntuar.py: PESQ y SI-SDR (mas es mejor) y el sonido en las
pausas, el eco y el ruido del borde (menos es mejor). Promediar posiciones y
no valores evita que una sola medida extrema decida.

El nivel de volumen no se usa para quitar: el conjunto final se iguala a un
mismo nivel (como 06_conjunto.py), y los gritos y susurros, que salen con
niveles distintos, son justo la expresividad que se busca.

Escribe datos/30_final/seleccion.json (los elegidos con su texto, y los
quitados con su motivo).

Corre en el entorno principal:
    .venv/Scripts/python.exe scripts/30_seleccion_final.py
"""

import json
import re
from collections import defaultdict
from pathlib import Path

import numpy as np

RAIZ = Path(__file__).resolve().parent.parent
DATOS = RAIZ / "datos"
SALIDA = DATOS / "30_final"
META_MIN = 60.0
MIN_S = 1.0
MAX_TOMAS = 3
DUPLICADOS = {"ep25": "ep24"}  # capitulo copia: capitulo original
MEDIDAS = {"pesq": +1, "si_sdr": +1, "pausas": -1, "eco": -1, "borde": -1}


def normalizar(texto: str) -> str:
    return " ".join(re.sub(r"[^a-záéíóúüñ ]", "", texto.lower()).split())


def main() -> None:
    revision = json.loads((DATOS / "28_revision" / "revision.json").read_text(encoding="utf-8"))
    medidas = json.loads((DATOS / "26_puntaje" / "medidas.json").read_text(encoding="utf-8"))
    clips = {}
    for indice in sorted((DATOS / "25_cortes").glob("ep*/indice.json")):
        for c in json.loads(indice.read_text(encoding="utf-8"))["clips"]:
            clave = c["archivo"].removesuffix(".wav")
            clips[clave] = {"clave": clave, "episodio": indice.parent.name, "duracion": c["duracion"],
                            "texto": revision["textos"].get(clave, c["texto"]),
                            "ruta": str(indice.parent / c["archivo"])}
    conservados = [clips[k] for k, v in revision["decisiones"].items() if v == "si"]

    # Calidad: promedio de percentiles, sobre todos los conservados.
    for nombre, signo in MEDIDAS.items():
        valores = np.array([signo * medidas[c["clave"]][nombre] for c in conservados])
        posicion = valores.argsort().argsort() / (len(valores) - 1)
        for c, p in zip(conservados, posicion):
            c.setdefault("posiciones", {})[nombre] = float(p)
    for c in conservados:
        c["calidad"] = round(float(np.mean(list(c.pop("posiciones").values()))), 4)

    quitados, quedan = [], []
    for c in conservados:
        if c["episodio"] in DUPLICADOS:
            quitados.append(dict(c, motivo=f"copia de {DUPLICADOS[c['episodio']]}"))
        elif c["duracion"] < MIN_S:
            quitados.append(dict(c, motivo=f"dura menos de {MIN_S:g} s"))
        else:
            quedan.append(c)

    por_texto = defaultdict(list)
    for c in quedan:
        por_texto[normalizar(c["texto"])].append(c)
    quedan = []
    for grupo in por_texto.values():
        grupo.sort(key=lambda c: -c["calidad"])
        quedan += grupo[:MAX_TOMAS]
        quitados += [dict(c, motivo=f"frase repetida, hay {MAX_TOMAS} tomas mejores") for c in grupo[MAX_TOMAS:]]

    quedan.sort(key=lambda c: -c["calidad"])
    elegidos, total = [], 0.0
    for c in quedan:
        if total + c["duracion"] <= META_MIN * 60:
            elegidos.append(c)
            total += c["duracion"]
        else:
            quitados.append(dict(c, motivo="menos calidad que los 60 minutos elegidos"))

    SALIDA.mkdir(parents=True, exist_ok=True)
    (SALIDA / "seleccion.json").write_text(json.dumps({"elegidos": elegidos, "quitados": quitados},
                                                      ensure_ascii=False, indent=1), encoding="utf-8")
    minutos = lambda lista: sum(c["duracion"] for c in lista) / 60
    print(f"conservados por el usuario: {len(conservados)} clips, {minutos(conservados):.1f} min")
    motivos = defaultdict(list)
    for c in quitados:
        motivos[c["motivo"]].append(c)
    for motivo, lista in motivos.items():
        print(f"  quitados, {motivo}: {len(lista)} clips, {minutos(lista):.1f} min")
    print(f"elegidos: {len(elegidos)} clips, {minutos(elegidos):.1f} min; "
          f"calidad del peor elegido {min(c['calidad'] for c in elegidos):.2f}")
    duraciones = np.array([c["duracion"] for c in elegidos])
    print(f"  duracion: mediana {np.median(duraciones):.1f} s; 1-2 s {(duraciones < 2).sum()}, "
          f"2-5 s {((duraciones >= 2) & (duraciones < 5)).sum()}, mas de 5 s {(duraciones >= 5).sum()}")
    for nombre in MEDIDAS:
        todos = np.median([medidas[c["clave"]][nombre] for c in conservados])
        elegido = np.median([medidas[c["clave"]][nombre] for c in elegidos])
        print(f"  {nombre:7s} mediana: conservados {todos:7.2f} -> elegidos {elegido:7.2f}")


if __name__ == "__main__":
    main()
