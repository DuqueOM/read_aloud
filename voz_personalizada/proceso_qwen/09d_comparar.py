"""La voz real frente a la voz entrenada, diciendo las mismas palabras.

Toma frases reales del conjunto, hace que Piper las lea y las convierte con el
modelo. Asi se oye, frase por frase, lo que dijo la voz real y lo que produce la
voz entrenada con el mismo texto. Todo queda al mismo volumen.

Corre en el entorno de Applio:
    applio/.venv/Scripts/python.exe scripts/09d_comparar.py
"""

import html
import json
import os
import random
import subprocess
import sys
from pathlib import Path

import librosa
import numpy as np
import soundfile as sf

import voz

RAIZ = Path(__file__).resolve().parent.parent
APPLIO = RAIZ / "applio"
NOMBRE = f"{voz.NOMBRE}_{voz.IDIOMA}"
MODELO = APPLIO / "logs" / NOMBRE
CONJUNTO = RAIZ / "datos" / "08_final" / NOMBRE
CORTES = RAIZ / "datos" / "04_cortes"
SALIDA = RAIZ / "datos" / "09_comparar"
PIPER = voz.lector() / "read_aloud_piper"
VOZ_PIPER = "es_MX-claude-high"
PESOS = MODELO / f"{NOMBRE}_375e_31500s.pth"

FRASES = 10
MIN_S, MAX_S = 2.5, 7.0
INDICE = 0.5
PROTECCION = 0.33
NIVEL_DB = -20.0
PICO_DB = -1.0


def igualar(audio: np.ndarray) -> np.ndarray:
    audio = audio * (10 ** (NIVEL_DB / 20) / (np.sqrt(np.mean(audio ** 2)) + 1e-9))
    pico = np.max(np.abs(audio)) + 1e-9
    limite = 10 ** (PICO_DB / 20)
    return audio * (limite / pico) if pico > limite else audio


def tono_mediano(audios) -> float:
    valores = []
    for audio in audios:
        f0, sonoro, _ = librosa.pyin(audio, fmin=70, fmax=900, sr=16000)
        valores.append(f0[sonoro])
    return float(np.median(np.concatenate(valores)))


def elegir() -> list:
    """Frases del conjunto final, mitad preguntas o exclamaciones."""
    final = {a.name for a in CONJUNTO.glob("*.wav")}
    clips = [c for indice in sorted(CORTES.glob("ep*/indice.json"))
             for c in json.loads(indice.read_text(encoding="utf-8"))["clips"]
             if c["archivo"] in final and MIN_S <= c["duracion"] <= MAX_S]
    azar = random.Random(0)
    expresivas = [c for c in clips if any(s in c["texto"] for s in "¿?¡!")]
    llanas = [c for c in clips if c not in expresivas]
    return azar.sample(expresivas, FRASES // 2) + azar.sample(llanas, FRASES - FRASES // 2)


def main() -> None:
    audio_dir = SALIDA / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)

    azar = random.Random(0)
    tono_voz = tono_mediano([librosa.load(a, sr=16000)[0] for a in azar.sample(sorted(CONJUNTO.glob("*.wav")), 40)])

    sys.path.insert(0, str(APPLIO))
    os.chdir(APPLIO)
    from rvc.infer.infer import VoiceConverter

    convertidor = VoiceConverter()
    indice = str(next(MODELO.glob("*.index")))

    frases = []
    for n, clip in enumerate(elegir(), 1):
        piper = audio_dir / f"f{n}_piper.wav"
        subprocess.run([str(PIPER / "bin" / "piper" / "piper.exe"),
                        "--model", str(PIPER / "voices" / f"{VOZ_PIPER}.onnx"), "--output_file", str(piper)],
                       input=clip["texto"].encode("utf-8"), check=True, capture_output=True)
        semitonos = int(np.clip(round(12 * np.log2(tono_voz / tono_mediano([librosa.load(piper, sr=16000)[0]]))),
                                -24, 24))
        crudo = audio_dir / f"f{n}_crudo.wav"
        convertidor.convert_audio(
            audio_input_path=str(piper), audio_output_path=str(crudo),
            model_path=str(PESOS), index_path=indice, pitch=semitonos,
            f0_method="rmvpe", index_rate=INDICE, protect=PROTECCION,
        )
        for origen, destino in ((CONJUNTO / clip["archivo"], "real"), (piper, "piper"), (crudo, "entrenada")):
            audio, tasa = sf.read(origen, dtype="float32", always_2d=False)
            audio = audio if audio.ndim == 1 else audio.mean(axis=1)
            sf.write(audio_dir / f"f{n}_{destino}.wav", igualar(audio), tasa, subtype="PCM_24")
        crudo.unlink()
        frases.append({"n": n, "texto": clip["texto"], "archivo": clip["archivo"], "semitonos": semitonos})
        print(f"f{n}: {clip['archivo']} {semitonos:+d} st")

    filas = "".join(
        f'<div class="par"><b>{html.escape(f["texto"])}</b>'
        f'<div class="fila"><span>Voz real</span><audio controls preload="none" src="audio/f{f["n"]}_real.wav"></audio></div>'
        f'<div class="fila"><span>Voz entrenada</span><audio controls preload="none" src="audio/f{f["n"]}_entrenada.wav"></audio></div>'
        f'<div class="fila"><span>Piper, la fuente</span><audio controls preload="none" src="audio/f{f["n"]}_piper.wav"></audio></div>'
        f'</div>' for f in frases)
    (SALIDA / "comparar.html").write_text(f"""<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Voz real y voz entrenada</title>
<style>
 body {{ margin:0; background:#16161a; color:#e6e6ea; font:15px/1.5 "Segoe UI",system-ui,sans-serif; }}
 main {{ max-width:760px; margin:0 auto; padding:28px 20px; }}
 h1 {{ font-size:20px; margin:0 0 6px; }}
 p {{ color:#a8a8b2; margin:4px 0 18px; }}
 .par {{ background:#1f1f25; border:1px solid #2e2e36; border-radius:8px; padding:12px 14px; margin-bottom:12px; }}
 .par b {{ display:block; margin-bottom:8px; font-weight:600; }}
 .fila {{ display:grid; grid-template-columns:130px 1fr; gap:8px; align-items:center; margin:4px 0; }}
 .fila span {{ color:#8a8a94; font-size:13px; }} audio {{ width:100%; height:34px; }}
</style></head><body><main>
<h1>Voz real y voz entrenada</h1>
<p>Cada frase la dijo la voz real en las grabaciones. La voz entrenada dice el mismo texto: Piper lo lee
y el modelo le pone el timbre de la voz. Abajo está Piper solo, para oír de dónde sale. Todo al mismo volumen.</p>
{filas}
</main></body></html>""", encoding="utf-8")
    (SALIDA / "frases.json").write_text(json.dumps(frases, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"pagina: {SALIDA / 'comparar.html'}")


if __name__ == "__main__":
    main()
