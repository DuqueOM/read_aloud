"""Pagina que muestra como va el entrenamiento del modelo RVC.

Lee el registro de Applio cada 30 segundos y reescribe
progreso_entrenamiento.html, que se recarga sola. Basta con dejarla abierta
en el navegador. Termina cuando el entrenamiento acaba o falla.

Solo usa la biblioteca estandar, asi que corre con cualquier Python:
    python scripts/progreso_entrenamiento.py
"""

import html
import re
import time
from datetime import datetime, timedelta
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
MODELO = RAIZ / "applio" / "logs" / "mi_voz_es"
REGISTRO = RAIZ / "applio" / "logs" / "mi_voz_es_entrenamiento.log"
PAGINA = RAIZ / "progreso_entrenamiento.html"

EPOCAS = 400
CADA_S = 30
# Sin novedades en el registro durante este tiempo, algo se detuvo.
QUIETO_S = 10 * 60

LINEA = re.compile(r"epoch=(\d+) \| step=(\d+) \| time=([\d:]+) \| training_speed=(\d+):(\d\d):(\d\d)"
                   r"(?: \| lowest_value=([\d.]+))?")


def leer() -> dict:
    texto = REGISTRO.read_text(encoding="utf-8", errors="replace").replace("\r", "\n") if REGISTRO.exists() else ""
    epocas = {}
    for m in LINEA.finditer(texto):
        h, mi, s = int(m.group(4)), int(m.group(5)), int(m.group(6))
        epocas[int(m.group(1))] = {
            "hora": m.group(3), "duracion": h * 3600 + mi * 60 + s,
            "minimo": float(m.group(7)) if m.group(7) else None,
        }
    error = None
    if "Traceback" in texto:
        error = [l for l in texto.splitlines() if l.strip()][-1][:300]
    # Los puntos completos se llaman G_<paso>.pth; la epoca sale de los pasos
    # que lleva cada una, que el registro informa.
    pasos_por_epoca = 84
    for m in re.finditer(r"epoch=(\d+) \| step=(\d+) \| time", texto):
        pasos_por_epoca = int(m.group(2)) / int(m.group(1))
    guardados = sorted(round(int(re.search(r"G_(\d+)\.pth", p.name).group(1)) / pasos_por_epoca)
                       for p in MODELO.glob("G_*.pth"))
    return {
        "epocas": epocas, "error": error, "guardados": guardados,
        "indice": any(MODELO.glob("*.index")),
        "quieto": REGISTRO.exists() and time.time() - REGISTRO.stat().st_mtime > QUIETO_S,
    }


def grafico(epocas: dict) -> str:
    puntos = [(e, d["minimo"]) for e, d in sorted(epocas.items()) if d["minimo"] is not None]
    if len(puntos) < 2:
        return ""
    ancho, alto = 600, 120
    valores = [v for _, v in puntos]
    bajo, alto_v = min(valores), max(valores)
    rango = (alto_v - bajo) or 1
    trazo = " ".join(
        f"{8 + (e - 1) / max(1, EPOCAS - 1) * (ancho - 16):.1f},{8 + (alto_v - v) / rango * (alto - 16):.1f}"
        for e, v in puntos
    )
    return (f'<svg viewBox="0 0 {ancho} {alto}" class="grafico" role="img" '
            f'aria-label="Pérdida más baja por época">'
            f'<polyline points="{trazo}" fill="none" stroke="#60a5fa" stroke-width="2"/></svg>'
            f'<p class="sub">Pérdida más baja hasta cada época: de {alto_v:.2f} a {bajo:.2f}. '
            f'Mientras baja, el modelo sigue aprendiendo; si se aplana, ya aprendió lo principal.</p>')


def pagina(datos: dict) -> tuple[str, bool]:
    epocas = datos["epocas"]
    actual = max(epocas) if epocas else 0
    pct = round(100 * actual / EPOCAS)
    recientes = [epocas[e]["duracion"] for e in sorted(epocas)[-10:] if e > 1]
    por_epoca = sum(recientes) / len(recientes) if recientes else 0
    restante = timedelta(seconds=round(por_epoca * (EPOCAS - actual)))
    fin = (datetime.now() + restante).strftime("%H:%M") if por_epoca else "—"

    if datos["error"]:
        estado, clase = f"Se detuvo con un error: {datos['error']}", "error"
    elif datos["indice"]:
        estado, clase = "Terminado. Claude prepara ahora la prueba a ciegas de puntos de control.", "listo"
    elif actual >= EPOCAS:
        estado, clase = "Épocas completas; generando el índice de la voz.", "curso"
    elif datos["quieto"]:
        estado, clase = "Sin novedades desde hace más de 10 minutos: puede haberse detenido.", "error"
    elif actual == 0:
        estado, clase = "Arrancando: cargando el modelo base y los datos.", "curso"
    else:
        estado, clase = f"Entrenando. Termina hacia las {fin} (faltan {str(restante)[:-3]} h).", "curso"

    guardados = ", ".join(str(e) for e in datos["guardados"]) or "todavía ninguno"
    final = datos["error"] is not None or datos["indice"]
    refresco = "" if final else f'<meta http-equiv="refresh" content="{CADA_S}">'
    minimo = next((epocas[e]["minimo"] for e in sorted(epocas, reverse=True) if epocas[e]["minimo"]), None)

    return f"""<!doctype html>
<html lang="es"><head><meta charset="utf-8">{refresco}
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Entrenamiento · voz propia</title>
<style>
 body {{ margin:0; background:#16161a; color:#e6e6ea; font:15px/1.5 "Segoe UI",system-ui,sans-serif; }}
 main {{ max-width:760px; margin:0 auto; padding:28px 20px; }}
 h1 {{ font-size:20px; margin:0 0 4px; }}
 .sub {{ color:#8a8a94; margin:4px 0 18px; }}
 .grande {{ font-size:34px; font-weight:600; font-variant-numeric:tabular-nums; margin:14px 0 2px; }}
 .barra {{ height:10px; background:#2e2e36; border-radius:5px; overflow:hidden; margin:10px 0 18px; }}
 .barra i {{ display:block; height:100%; width:{pct}%; background:#4ade80; }}
 .estado {{ background:#1f1f25; border:1px solid #2e2e36; border-radius:8px; padding:12px 14px; margin-bottom:18px; }}
 .estado.listo {{ border-color:#2f6b45; }} .estado.error {{ border-color:#7a3434; color:#fca5a5; }}
 .cifras {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin-bottom:18px; }}
 .cifra {{ background:#1f1f25; border:1px solid #2e2e36; border-radius:8px; padding:10px 12px; }}
 .cifra b {{ display:block; font-size:18px; font-variant-numeric:tabular-nums; }}
 .cifra span {{ color:#8a8a94; font-size:13px; }}
 .grafico {{ width:100%; height:auto; background:#1f1f25; border:1px solid #2e2e36; border-radius:8px; }}
</style></head><body><main>
<h1>Entrenamiento de la voz propia</h1>
<p class="sub">Se actualiza sola cada {CADA_S} s · última lectura {datetime.now():%H:%M:%S}</p>
<div class="grande">Época {actual} de {EPOCAS} · {pct} %</div>
<div class="barra"><i></i></div>
<div class="estado {clase}">{html.escape(estado)}</div>
<div class="cifras">
 <div class="cifra"><b>{round(por_epoca)} s</b><span>por época, media reciente</span></div>
 <div class="cifra"><b>{fin}</b><span>hora estimada de fin</span></div>
 <div class="cifra"><b>{f"{minimo:.2f}" if minimo else "—"}</b><span>pérdida más baja</span></div>
 <div class="cifra"><b>{len(datos["guardados"])}</b><span>puntos de control guardados</span></div>
</div>
{grafico(epocas)}
<p class="sub">Puntos de control guardados en las épocas: {guardados}. Se guarda uno cada 25 épocas;
al final se comparan cinco a ciegas para elegir el que suene mejor.</p>
</main></body></html>""", final


def main() -> None:
    while True:
        contenido, final = pagina(leer())
        PAGINA.write_text(contenido, encoding="utf-8")
        if final:
            return
        time.sleep(CADA_S)


if __name__ == "__main__":
    main()
