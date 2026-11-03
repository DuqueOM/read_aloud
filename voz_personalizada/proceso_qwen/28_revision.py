"""Arma la pagina de revision unica: conservar o descartar y corregir el texto.

Junta, para cada clip de 25_cortar_frases.py:
- el puntaje y los avisos de 26_puntuar.py, para ordenar de mas a menos
  probable de conservar y marcar lo sospechoso;
- tres lecturas del texto: la del video y las de 27_transcribir_clips.py.
  Se propone LECTURA_PREFERIDA y se muestran las otras cuando dicen algo
  distinto, con un aviso;
- lo que el usuario decidio en la primera revision, si el clip nuevo cae
  sobre uno viejo: su decision como marca y, si cubren las mismas palabras,
  su texto corregido como propuesta.

La pagina guarda el avance en el navegador y exporta revision.json, con las
decisiones y los textos corregidos.

Escribe datos/28_revision/revision.html.

Corre en el entorno principal:
    .venv/Scripts/python.exe scripts/28_revision.py
"""

import html
import importlib.util
import json
import re
from pathlib import Path

spec = importlib.util.spec_from_file_location("textos", Path(__file__).parent / "22_textos.py")
textos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(textos)

RAIZ = textos.RAIZ
DATOS = RAIZ / "datos"
SALIDA = DATOS / "28_revision"
LECTURA_PREFERIDA = "whisper"
META_S = round(textos.voz.MINUTOS_FINALES * 60)
# Un clip nuevo hereda la decision de uno viejo si lo cubre en esta parte; y su
# texto corregido, si ademas el viejo no tiene mas que el nuevo.
CUBRE_DECISION = 0.7
CUBRE_TEXTO = 0.9


def solape(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))


def main() -> None:
    puntajes = {c["nombre"]: c for c in json.loads((DATOS / "26_puntaje" / "clips.json").read_text(encoding="utf-8"))}
    lecturas = {m: json.loads((DATOS / "27_textos" / f"{m}.json").read_text(encoding="utf-8"))
                for m in ("whisper", "qwen") if (DATOS / "27_textos" / f"{m}.json").exists()}
    primera = DATOS / "05_revision" / "decisiones.json"
    decisiones = json.loads(primera.read_text(encoding="utf-8"))["decisiones"] if primera.exists() else {}
    corregidos = textos.referencias()
    viejos = {}
    for indice in (DATOS / "04_cortes").glob("ep*/indice.json"):
        viejos[indice.parent.name] = json.loads(indice.read_text(encoding="utf-8"))["clips"]

    clips = []
    for indice in sorted((DATOS / "25_cortes").glob("ep*/indice.json")):
        episodio = indice.parent.name
        for clip in json.loads(indice.read_text(encoding="utf-8"))["clips"]:
            nombre = clip["archivo"].removesuffix(".wav")
            puntaje = puntajes.get(nombre, {"puntaje": 0.5, "avisos": []})
            opciones = {"episodio": clip["texto"], **{m: l[nombre] for m, l in lecturas.items() if nombre in l}}
            propuesta = opciones.get(LECTURA_PREFERIDA, clip["texto"])
            avisos = list(puntaje["avisos"])

            antes = None
            for viejo in viejos.get(episodio, []):
                comun = solape(clip["inicio"], clip["fin"], viejo["inicio"], viejo["fin"])
                id_viejo = viejo["archivo"].removesuffix(".wav")
                if comun >= CUBRE_DECISION * clip["duracion"] and id_viejo in decisiones:
                    antes = decisiones[id_viejo]
                    if comun >= CUBRE_TEXTO * (viejo["fin"] - viejo["inicio"]) and id_viejo in corregidos:
                        propuesta = corregidos[id_viejo]
                        opciones["tu correccion"] = propuesta

            distintas = []
            for fuente, texto in opciones.items():
                if texto and textos.normalizar(texto) != textos.normalizar(propuesta) and \
                        all(textos.normalizar(texto) != textos.normalizar(d["texto"]) for d in distintas):
                    distintas.append({"fuente": fuente, "texto": texto})
            if distintas:
                avisos.append("lecturas distintas")

            clips.append({"id": nombre, "ep": episodio, "ruta": f"../25_cortes/{episodio}/{clip['archivo']}",
                          "inicio": clip["inicio"], "dur": clip["duracion"], "texto": propuesta,
                          "alternativas": distintas, "marcas": avisos, "antes": antes,
                          "puntaje": puntaje["puntaje"]})

    clips.sort(key=lambda c: -c["puntaje"])
    SALIDA.mkdir(parents=True, exist_ok=True)
    plantilla = (Path(__file__).parent / "revision2_plantilla.html").read_text(encoding="utf-8")
    pagina = (plantilla.replace("/*DATOS*/[]", json.dumps(clips, ensure_ascii=False))
              .replace("/*META*/3600", str(META_S))
              .replace("/*TITULO*/", html.escape(textos.voz.TITULO))
              # Va dentro de una cadena de JavaScript: solo letras, numeros y _.
              .replace("/*NOMBRE*/", re.sub(r"\W", "_", textos.voz.NOMBRE)))
    (SALIDA / "revision.html").write_text(pagina, encoding="utf-8")
    total = sum(c["dur"] for c in clips) / 60
    print(f"{len(clips)} clips, {total:.1f} min; con aviso {sum(bool(c['marcas']) for c in clips)}; "
          f"con decision anterior {sum(c['antes'] is not None for c in clips)}")
    print(f"pagina: {SALIDA / 'revision.html'}")


if __name__ == "__main__":
    main()
