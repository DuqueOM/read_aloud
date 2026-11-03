"""Afina el inicio y el fin de cada palabra con alineacion forzada.

Whisper entrega tiempos por palabra con un error de una o dos decimas. En el
borde de un clip ese error es justo lo que deja entrar un resto de ruido o el
comienzo de otra voz.

Un modelo wav2vec2 entrenado en el idioma de la voz escucha el audio letra por letra. Como
ya se sabe que se dijo, gracias a la transcripcion, basta con encontrar en que
momento suena cada letra: eso es la alineacion forzada, y deja los limites de
cada palabra con precision de centesimas.

Si una palabra no se puede alinear, porque es un numero o porque la alineacion
cae lejos de lo que dijo Whisper, conserva el tiempo de Whisper.

El modelo depende del idioma: comun.py elige uno para los idiomas mas
comunes, y voz.toml puede indicar otro con "alineador".

Uso:
    python 03b_alinear.py            todas las grabaciones transcritas
    python 03b_alinear.py ep01       una sola
"""

import json
import os
import re
import sys
import unicodedata
from math import gcd

from comun import ALINEADOR, DATOS, MODELOS

os.environ.setdefault("HF_HOME", str(MODELOS / "hf"))

import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402
import torch  # noqa: E402
import torchaudio.functional as F  # noqa: E402
from scipy.signal import resample_poly  # noqa: E402
from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor  # noqa: E402

VOZ = DATOS / "02_voz"
TRANSCRIPCION = DATOS / "03_transcripcion"
SALIDA = DATOS / "03_alineado"
TASA = 16000

# Las palabras se alinean en tramos. Un hueco largo separa tramos, y un tramo
# no pasa de 20 s para que el modelo lo procese entero sin perder precision.
HUECO_MAX_S = 1.0
TRAMO_MAX_S = 20.0
MARGEN_S = 0.35

# Si la alineacion se aleja mas que esto de lo que dijo Whisper, es mas
# probable que haya fallado ella que Whisper.
DESVIO_MAX_S = 0.6


def normalizar(palabra: str, vocabulario: set) -> str:
    texto = palabra.lower()
    texto = unicodedata.normalize("NFC", texto)
    texto = re.sub(r"[^\w]", "", texto)
    return "".join(c for c in texto if c in vocabulario)


def tramos(palabras):
    grupo = []
    for i, p in enumerate(palabras):
        if grupo and (
            p["inicio"] - palabras[grupo[-1]]["fin"] > HUECO_MAX_S
            or p["fin"] - palabras[grupo[0]]["inicio"] > TRAMO_MAX_S
        ):
            yield grupo
            grupo = []
        grupo.append(i)
    if grupo:
        yield grupo


def alinear_tramo(indices, palabras, audio16, modelo, proc, vocab, blanco, separador):
    inicio = max(0.0, palabras[indices[0]]["inicio"] - MARGEN_S)
    fin = min(len(audio16) / TASA, palabras[indices[-1]]["fin"] + MARGEN_S)
    trozo = audio16[int(inicio * TASA) : int(fin * TASA)]

    textos = [normalizar(palabras[i]["texto"], set(vocab)) for i in indices]
    alineables = [(i, t) for i, t in zip(indices, textos) if t]
    if not alineables:
        return

    objetivo, rangos = [], []
    for n, (_, texto) in enumerate(alineables):
        if n > 0:
            objetivo.append(separador)
        desde = len(objetivo)
        objetivo.extend(vocab[c] for c in texto)
        rangos.append((desde, len(objetivo) - 1))

    entrada = proc(trozo, sampling_rate=TASA, return_tensors="pt").input_values.to(modelo.device)
    with torch.no_grad():
        emisiones = torch.log_softmax(modelo(entrada).logits.float(), dim=-1)

    cuadros = emisiones.shape[1]
    if cuadros < len(objetivo) * 2:
        return

    alineado, puntos = F.forced_align(
        emisiones, torch.tensor([objetivo], dtype=torch.int32, device=emisiones.device), blank=blanco
    )
    tramos_letra = F.merge_tokens(alineado[0], puntos[0].exp())
    segundos_por_cuadro = (len(trozo) / TASA) / cuadros

    for (indice, _), (desde, hasta) in zip(alineables, rangos):
        letras = tramos_letra[desde : hasta + 1]
        nuevo_inicio = inicio + letras[0].start * segundos_por_cuadro
        nuevo_fin = inicio + letras[-1].end * segundos_por_cuadro
        confianza = float(np.mean([t.score for t in letras]))

        palabra = palabras[indice]
        if abs(nuevo_inicio - palabra["inicio"]) > DESVIO_MAX_S or abs(nuevo_fin - palabra["fin"]) > DESVIO_MAX_S:
            continue

        palabra["inicio_whisper"], palabra["fin_whisper"] = palabra["inicio"], palabra["fin"]
        palabra["inicio"] = round(nuevo_inicio, 3)
        palabra["fin"] = round(nuevo_fin, 3)
        palabra["confianza"] = round(confianza, 3)
        palabra["alineada"] = True


def main() -> None:
    if not ALINEADOR:
        raise SystemExit('No hay alineador para este idioma: indica uno en voz.toml como "alineador".')
    SALIDA.mkdir(parents=True, exist_ok=True)
    pedidos = sys.argv[1:]
    archivos = sorted(TRANSCRIPCION.glob("ep*.json"))
    if pedidos:
        archivos = [a for a in archivos if a.stem in pedidos]

    proc = Wav2Vec2Processor.from_pretrained(ALINEADOR)
    modelo = Wav2Vec2ForCTC.from_pretrained(ALINEADOR).to("cuda" if torch.cuda.is_available() else "cpu").eval()
    vocab = proc.tokenizer.get_vocab()
    blanco = vocab[proc.tokenizer.pad_token]
    separador = vocab["|"]

    for archivo in archivos:
        episodio = archivo.stem
        datos = json.loads(archivo.read_text(encoding="utf-8"))
        palabras = datos["palabras"]

        audio, tasa = sf.read(VOZ / f"{episodio}_voz.wav", dtype="float32", always_2d=False)
        audio = audio.mean(axis=1) if audio.ndim > 1 else audio
        d = gcd(tasa, TASA)
        audio16 = resample_poly(audio, TASA // d, tasa // d).astype(np.float32)

        for p in palabras:
            p["alineada"] = False

        for grupo in tramos(palabras):
            try:
                alinear_tramo(grupo, palabras, audio16, modelo, proc, vocab, blanco, separador)
            except Exception as error:  # un tramo raro no debe frenar el resto
                print(f"  {episodio}: tramo sin alinear ({error})")

        alineadas = sum(p["alineada"] for p in palabras)
        desvios = [abs(p["inicio"] - p["inicio_whisper"]) for p in palabras if p["alineada"]]
        (SALIDA / f"{episodio}.json").write_text(json.dumps(datos, ensure_ascii=False, indent=1), encoding="utf-8")
        print(
            f"{episodio}: {alineadas} de {len(palabras)} palabras alineadas, "
            f"correccion media del inicio {np.mean(desvios) * 1000:.0f} ms"
        )


if __name__ == "__main__":
    main()
