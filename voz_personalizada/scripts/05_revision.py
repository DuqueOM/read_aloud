"""Genera la pagina de revision con los clips candidatos ordenados.

Lee los clips que dejo 04_cortar.py y los ordena de mas a menos confianza de
que sean de la voz buscada. Cada clip muestra su transcripcion, que ayuda a
decidir rapido si habla esa voz sola.

La pagina se abre en el navegador. Cada clip suena solo al llegar a el, y se
decide con una tecla:

    1 o Enter     conservar
    2 o Supr      descartar
    Espacio       repetir
    Z             deshacer
    Flechas       moverse sin decidir

Las decisiones se guardan solas en el navegador. Al terminar, el boton
Exportar descarga decisiones.json, que es lo que lee el paso siguiente.

Uso:
    python 05_revision.py
"""

import json
from pathlib import Path

from comun import DATOS, NOMBRE

CORTES = DATOS / "04_cortes"
SALIDA = DATOS / "05_revision"


def main() -> None:
    candidatas = []
    for carpeta in sorted(p for p in CORTES.iterdir() if p.is_dir()):
        indice = json.loads((carpeta / "indice.json").read_text(encoding="utf-8"))
        for clip in indice["clips"]:
            candidatas.append(
                {
                    "id": clip["archivo"].replace(".wav", ""),
                    "ep": carpeta.name,
                    "ruta": f"../04_cortes/{carpeta.name}/{clip['archivo']}",
                    "inicio": clip["inicio"],
                    "dur": clip["duracion"],
                    "confianza": clip["confianza"],
                    "minimo": clip["minimo"],
                    "clip": clip["prob_clip"],
                    "texto": clip["texto"],
                }
            )

    candidatas.sort(key=lambda c: c["confianza"], reverse=True)

    SALIDA.mkdir(parents=True, exist_ok=True)
    plantilla = (Path(__file__).parent / "revision_plantilla.html").read_text(encoding="utf-8")
    # Cada voz guarda sus decisiones aparte en el navegador.
    pagina = plantilla.replace("/*DATOS*/[]", json.dumps(candidatas, ensure_ascii=False)).replace(
        "/*NOMBRE*/'voz'", json.dumps(NOMBRE)
    )
    destino = SALIDA / "revision.html"
    destino.write_text(pagina, encoding="utf-8")

    total = sum(c["dur"] for c in candidatas) / 60
    print(f"{len(candidatas)} clips, {total:.1f} min en total")
    print(f"pagina: {destino}")


if __name__ == "__main__":
    main()
