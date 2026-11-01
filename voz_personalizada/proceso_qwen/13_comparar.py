"""Pagina corta de escucha: la voz real, la voz actual de la app y candidatas.

Cada frase muestra solo tres cosas: lo que dijo la voz real, como lo lee hoy Read
Aloud y las candidatas que se pasen, todo al mismo volumen. La voz de la app
es Piper tal cual, o con --app la version que se indique. Las candidatas son
versiones de datos/10_motores/audio, con su etiqueta:

    python scripts/13_comparar.py --app qwen_mi_voz_v2_e02 qwen_mi_voz_v4_60_e02="60 mejores, época 2"

Escribe datos/13_comparar/comparar.html.
"""

import html
import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

RAIZ = Path(__file__).resolve().parent.parent
MOTORES = RAIZ / "datos" / "10_motores" / "audio"
COMPARAR = RAIZ / "datos" / "09_comparar"
SALIDA = RAIZ / "datos" / "13_comparar"
INGLES = {
    "en1": ("Wait, are you serious? I can't believe we actually made it!", "frase4"),
    "en2": ("The function returns a list of results, sorted by date.", "frase5"),
}
NIVEL_DB = -20.0
PICO_DB = -1.0


def igualar(origen: Path, destino: Path) -> None:
    audio, tasa = sf.read(origen, dtype="float32", always_2d=False)
    audio = audio if audio.ndim == 1 else audio.mean(axis=1)
    audio = audio * (10 ** (NIVEL_DB / 20) / (np.sqrt(np.mean(audio ** 2)) + 1e-9))
    pico = np.max(np.abs(audio)) + 1e-9
    limite = 10 ** (PICO_DB / 20)
    sf.write(destino, audio * (limite / pico) if pico > limite else audio, tasa, subtype="PCM_24")


def main() -> None:
    argumentos = sys.argv[1:]
    # Con --app VERSION, la voz actual de la app es esa version de
    # datos/10_motores/audio (la app ya no lee con Piper tal cual).
    app_version = None
    if argumentos[:1] == ["--app"]:
        app_version, argumentos = argumentos[1], argumentos[2:]
    candidatas = [a.split("=", 1) for a in argumentos]
    audio_dir = SALIDA / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)

    frases = [(f"es{f['n']}", f["texto"], COMPARAR / "audio" / f"f{f['n']}_real.wav",
               COMPARAR / "audio" / f"f{f['n']}_piper.wav")
              for f in json.loads((COMPARAR / "frases.json").read_text(encoding="utf-8"))]
    frases += [(clave, texto, None, RAIZ / "datos" / "09_puntos" / "fuente" / f"{fuente}.wav")
               for clave, (texto, fuente) in INGLES.items()]

    bloques = {"es": [], "en": []}
    for clave, texto, real, app in frases:
        if app_version:
            app = MOTORES / f"{clave}_{app_version}.wav"
        filas = []
        for etiqueta, origen, clase in ([("Voz real", real, "real")] if real else []) + \
                [("Voz actual de la app", app, "app")] + \
                [(e, MOTORES / f"{clave}_{v}.wav", "") for v, e in candidatas]:
            nombre = f"{clave}_{origen.stem.split('_', 1)[-1] if clase == '' else clase}.wav"
            igualar(origen, audio_dir / nombre)
            filas.append(f'<div class="fila {clase}"><span>{html.escape(etiqueta)}</span>'
                         f'<audio controls preload="none" src="audio/{nombre}"></audio></div>')
        bloques[clave[:2]].append(f'<div class="par"><b>{html.escape(texto)}</b>{"".join(filas)}</div>')

    (SALIDA / "comparar.html").write_text(f"""<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Voz de la voz de prueba</title>
<style>
 body {{ margin:0; background:#16161a; color:#e6e6ea; font:15px/1.5 "Segoe UI",system-ui,sans-serif; }}
 main {{ max-width:760px; margin:0 auto; padding:28px 20px; }}
 h1 {{ font-size:20px; margin:0 0 6px; }} h2 {{ font-size:16px; margin:26px 0 8px; }}
 p {{ color:#a8a8b2; margin:4px 0 18px; }}
 .par {{ background:#1f1f25; border:1px solid #2e2e36; border-radius:8px; padding:12px 14px; margin-bottom:12px; }}
 .par b {{ display:block; margin-bottom:8px; font-weight:600; }}
 .fila {{ display:grid; grid-template-columns:190px 1fr; gap:8px; align-items:center; margin:3px 0; }}
 .fila span {{ color:#c8c8d0; font-size:13px; }}
 .fila.real span {{ color:#4ade80; }} .fila.app span {{ color:#8a8a94; }}
 audio {{ width:100%; height:32px; }}
 @media (max-width:560px) {{ main {{ padding:20px 16px; }} .fila {{ grid-template-columns:1fr; gap:2px; }} }}
</style></head><body><main>
<h1>Voz de la voz de prueba</h1>
<p>Frases que dijo la voz real en las grabaciones y que el modelo no vio al entrenar. Todo al mismo volumen.</p>
<h2>Español</h2>
{"".join(bloques["es"])}
<h2>Inglés</h2>
<p>Sin original: la voz real no habla inglés en las grabaciones.</p>
{"".join(bloques["en"])}
</main></body></html>""", encoding="utf-8")
    print(f"pagina: {SALIDA / 'comparar.html'}")


if __name__ == "__main__":
    main()
