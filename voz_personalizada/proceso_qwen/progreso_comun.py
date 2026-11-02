"""Estado del proceso y la pagina progreso.html que lo muestra.

Cualquier paso puede marcar su avance con marcar(). La pagina se reescribe en
cada cambio y se recarga sola cada 15 segundos, asi que basta con dejarla
abierta en el navegador.
"""

import html
import json
import threading
from datetime import datetime
from pathlib import Path

import voz

RAIZ = Path(__file__).resolve().parent.parent
ESTADO = RAIZ / "progreso.json"
PAGINA = RAIZ / "progreso.html"

NOMBRES = {
    "extraccion": "Extracción",
    "separacion": "Separación de voz",
    "transcripcion": "Transcripción",
    "alineacion": "Alineación",
    "curva": "Quién habla",
    "calibracion": "Ajuste de umbrales y revisión de los cortes",
    "pagina": "Página de revisión",
    "estado": "Estado",
}
ETAPAS_FINALES = ["calibracion", "pagina"]

_cerrojo = threading.Lock()


def nuevo(titulo: str, episodios: list, pasos: list, finales: list | None = None,
          revision: str = "datos/05_revision/revision.html") -> dict:
    """Las filas son los episodios (u otras tareas) y las columnas, los pasos.
    finales son las etapas de una sola fila al pie; revision, la pagina que
    se enlaza cuando la etapa "pagina" queda lista."""
    finales = ETAPAS_FINALES if finales is None else finales
    return {
        "titulo": titulo,
        "inicio": datetime.now().isoformat(timespec="seconds"),
        "pasos": pasos,
        "orden": episodios,
        "episodios": {ep: {p: "pendiente" for p in pasos} for ep in episodios},
        "etapas": {e: "pendiente" for e in finales},
        "finales": finales,
        "revision": revision,
        "eventos": [],
        "nota": "",
    }


def cargar() -> dict:
    return json.loads(ESTADO.read_text(encoding="utf-8"))


def guardar(estado: dict) -> None:
    with _cerrojo:
        ESTADO.write_text(json.dumps(estado, ensure_ascii=False, indent=1), encoding="utf-8")
        PAGINA.write_text(_pagina(estado), encoding="utf-8")


def marcar(estado: dict, paso: str, valor: str, episodio: str | None = None, evento: str | None = None) -> None:
    with _cerrojo:
        if episodio:
            estado["episodios"][episodio][paso] = valor
        else:
            estado["etapas"][paso] = valor
        if evento:
            estado["eventos"].insert(0, [datetime.now().strftime("%H:%M"), evento])
    guardar(estado)


AVANCE = RAIZ / "datos" / "avance.json"


def avance(detalle: str, hecho: int, total: int) -> None:
    """Para un paso largo que corre como otro proceso: deja cuanto lleva, y el
    proceso que lo lanzo lo muestra en la pagina (ver leer_avance)."""
    try:
        AVANCE.write_text(json.dumps({"detalle": detalle, "hecho": hecho, "total": total}, ensure_ascii=False),
                          encoding="utf-8")
    except OSError:
        pass


def leer_avance() -> str:
    try:
        a = json.loads(AVANCE.read_text(encoding="utf-8"))
        return f"en curso: {a['detalle']}, {a['hecho']} de {a['total']}"
    except (OSError, ValueError, KeyError):
        return "en curso"


def _porcentaje(estado: dict) -> int:
    total = len(estado["orden"]) * len(estado["pasos"]) + len(estado.get("finales", ETAPAS_FINALES))
    hechos = sum(v == "listo" for ep in estado["episodios"].values() for v in ep.values())
    hechos += sum(v == "listo" for v in estado["etapas"].values())
    return round(100 * hechos / total)


def _celda(valor: str) -> str:
    clase = {"listo": "listo", "pendiente": "pendiente"}.get(valor, "curso")
    if valor.startswith("con error"):
        clase = "error"
    return f'<td class="{clase}">{html.escape(valor)}</td>'


def _pagina(estado: dict) -> str:
    pasos = estado["pasos"]
    cabecera = "".join(f"<th>{NOMBRES[p]}</th>" for p in pasos)
    filas = "".join(
        f"<tr><th>{ep}</th>" + "".join(_celda(estado["episodios"][ep][p]) for p in pasos) + "</tr>"
        for ep in estado["orden"]
    )
    finales = "".join(
        f"<tr><th colspan='{len(pasos)}'>{NOMBRES[e]}</th>{_celda(estado['etapas'][e])}</tr>"
        for e in estado.get("finales", ETAPAS_FINALES)
    )
    eventos = "".join(f"<li><b>{h}</b> {html.escape(t)}</li>" for h, t in estado["eventos"][:40])
    revision = estado.get("revision", "datos/05_revision/revision.html")
    lista = estado["etapas"].get("pagina") == "listo" and (RAIZ / revision).exists()
    enlace = (
        f'<a class="boton" href="{revision}">Abrir la página de revisión</a>'
        if lista else ""
    )
    nota = f'<p class="nota">{html.escape(estado["nota"])}</p>' if estado.get("nota") else ""
    refresco = "" if lista else '<meta http-equiv="refresh" content="15">'
    pct = _porcentaje(estado)

    return f"""<!doctype html>
<html lang="es"><head><meta charset="utf-8">{refresco}
<title>Progreso · voz de {html.escape(voz.TITULO)}</title>
<style>
 body {{ margin:0; background:#16161a; color:#e6e6ea; font:15px/1.5 "Segoe UI",system-ui,sans-serif; }}
 main {{ max-width:900px; margin:0 auto; padding:28px 24px; }}
 h1 {{ font-size:20px; margin:0 0 4px; }}
 .sub {{ color:#8a8a94; margin:0 0 18px; }}
 .barra {{ height:10px; background:#2e2e36; border-radius:5px; overflow:hidden; margin:10px 0 22px; }}
 .barra i {{ display:block; height:100%; width:{pct}%; background:#4ade80; }}
 table {{ width:100%; border-collapse:collapse; margin-bottom:22px; }}
 th, td {{ padding:8px 10px; border-bottom:1px solid #26262c; text-align:left; }}
 thead th {{ color:#8a8a94; font-weight:500; }}
 td.listo {{ color:#4ade80; }} td.pendiente {{ color:#6b6b74; }} td.curso {{ color:#fbbf24; }}
 td.error {{ color:#f87171; }}
 ul {{ list-style:none; padding:0; margin:0; color:#c9c9d0; }}
 li {{ padding:3px 0; }} li b {{ color:#8a8a94; font-weight:500; margin-right:8px; }}
 .boton {{ display:inline-block; background:#2f6b45; color:#fff; text-decoration:none;
          padding:12px 20px; border-radius:8px; font-weight:600; margin:4px 0 22px; }}
 .nota {{ background:#1f1f25; border:1px solid #2e2e36; border-radius:8px; padding:12px 14px; }}
</style></head><body><main>
<h1>{html.escape(estado.get("titulo", f"Preparación de la voz de {voz.TITULO}"))}</h1>
<p class="sub">Empezó a las {estado["inicio"][11:16]} · {pct} % completado · se actualiza sola cada 15 s</p>
<div class="barra"><i></i></div>
{enlace}{nota}
<table><thead><tr><th>{html.escape(estado.get("filas", "Capítulo"))}</th>{cabecera}</tr></thead>
<tbody>{filas}{finales}</tbody></table>
<h2 style="font-size:15px;color:#8a8a94;font-weight:500">Últimos eventos</h2>
<ul>{eventos}</ul>
</main></body></html>"""
