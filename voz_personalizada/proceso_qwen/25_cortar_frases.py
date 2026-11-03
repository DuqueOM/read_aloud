"""Corta cada grabacion en clips de frases completas de la voz.

Lo que cambia frente a 04_cortar.py, y por que:

- La unidad es la frase, no la palabra. Con la voz de prueba, solo el 48 % de los 516 clips
  conservados empezaba y terminaba donde empieza y termina la frase: el
  corte soltaba palabras de los extremos para encontrar silencio, y asi
  quedaban frases sin su ultima palabra. Para entrenar una
  voz eso enseña un final de frase que no existe. Aqui un clip son una o
  varias frases enteras seguidas; si un borde no cae en silencio, se prueba
  con una frase menos, nunca con una palabra menos.
- Una frase termina en un punto, signo de pregunta o exclamacion, o en una
  pausa de mas de PAUSA_FRASE_S (Whisper no siempre puntua).
- Quien habla sale de WavLM Large con el clasificador entrenado con las
  decisiones del usuario (24_curva_wavlm.py), mirando cada frase entera (ver
  UMBRAL_FRASE). Una frase con un tramo de otra voz se descarta: es una
  interrupcion o dos voces encimadas.
- Las canciones de entrada y salida se quitan: son las frases que se repiten
  en muchos videos en el mismo momento.
- Los clips pueden ser mas largos (hasta MAX_CLIP_S) y juntar frases con su
  pausa natural: el modelo aprende como enlaza la voz una frase con otra.

Deja datos/25_cortes/epNN/*.wav y su indice.json.

Corre en el entorno principal:
    .venv/Scripts/python.exe scripts/25_cortar_frases.py            todos
    .venv/Scripts/python.exe scripts/25_cortar_frases.py ep01 ep02  algunos
"""

import importlib.util
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
import soundfile as sf

RAIZ = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("cortar", Path(__file__).parent / "04_cortar.py")
cortar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cortar)

DATOS = RAIZ / "datos"
SALIDA = DATOS / "25_cortes"
CURVAS = DATOS / "24_curvas"

FIN_FRASE = re.compile(r"[.?!…]+[»\"']?$")
PAUSA_FRASE_S = 0.7
MAX_PAUSA_ENTRE_FRASES_S = 1.2
MIN_CLIP_S = 0.8
MAX_CLIP_S = 15.0
# Quien dice cada frase se decide con la frase entera: el clasificador de
# 24_curva_wavlm.py sobre el promedio de las huellas de sus ventanas. Palabra
# por palabra no servia: en los clips que el usuario conservo, el 21 % de las
# palabras quedaba por debajo de 0.7 por las ventanas que tocan otra voz al
# lado, asi que casi ninguna frase pasaba. Con la frase entera, con 0.5 se
# conservan el 84 % de las frases de esos clips y el 15 % de las de clips
# descartados. Ademas, si mas de un tercio de sus ventanas parecen de otra voz
# (menos de 0.2), la frase tiene una interrupcion y se descarta.
UMBRAL_FRASE = 0.5
VENTANA_AJENA = 0.2
MAX_VENTANAS_AJENAS = 1 / 3
# Canciones: una tira de 4 palabras que aparece en al menos CANCION_EPISODIOS
# videos, casi en el mismo momento desde el inicio o desde el final.
CANCION_EPISODIOS = 5
CANCION_DISPERSION_S = 15.0


class Hablante:
    """Probabilidad de que un tramo del video sea de la voz."""

    def __init__(self, episodio):
        datos = np.load(CURVAS / f"{episodio}.npz")
        modelo = np.load(CURVAS / "clasificador.npz")
        self.centros = datos["centros"]
        self.x = (datos["huellas"].astype(np.float32) - modelo["media"]) / modelo["escala"]
        self.pesos, self.sesgo = modelo["pesos"], modelo["sesgo"][0]
        self.prob = 1 / (1 + np.exp(-(self.x @ self.pesos + self.sesgo)))

    def tramo(self, inicio, fin):
        """Probabilidad del tramo entero y parte de sus ventanas que parecen de otra voz."""
        dentro = np.where((self.centros >= inicio + 0.3) & (self.centros <= fin - 0.3))[0]
        if not len(dentro):
            dentro = np.array([int(np.argmin(np.abs(self.centros - (inicio + fin) / 2)))])
        prob = 1 / (1 + np.exp(-(self.x[dentro].mean(0) @ self.pesos + self.sesgo)))
        return float(prob), float((self.prob[dentro] < VENTANA_AJENA).mean())


def normalizar(texto):
    return re.sub(r"[^a-záéíóúüñ ]", "", texto.lower())


def zonas_de_cancion(todas: dict) -> dict:
    """Intervalos de cada grabacion que son de las canciones de entrada y salida."""
    tiras = defaultdict(list)
    for episodio, palabras in todas.items():
        duracion = palabras[-1]["fin"]
        w = [normalizar(p["texto"]) for p in palabras]
        for i in range(len(w) - 3):
            tiras[" ".join(w[i : i + 4])].append((episodio, i, palabras[i]["inicio"], duracion - palabras[i]["inicio"]))
    zonas = defaultdict(list)
    for apariciones in tiras.values():
        if len({a[0] for a in apariciones}) < CANCION_EPISODIOS:
            continue
        desde_inicio = np.array([a[2] for a in apariciones])
        desde_final = np.array([a[3] for a in apariciones])
        if min(desde_inicio.std(), desde_final.std()) > CANCION_DISPERSION_S:
            continue  # se repite, pero en momentos distintos: es una frase de la voz, no una cancion
        for episodio, i, *_ in apariciones:
            p = todas[episodio]
            zonas[episodio].append((p[i]["inicio"] - 2.0, p[min(i + 3, len(p) - 1)]["fin"] + 2.0))
    return zonas


def frases(palabras):
    """Agrupa las palabras en frases: termina en puntuacion o en una pausa larga."""
    grupos, actual = [], []
    for i, p in enumerate(palabras):
        actual.append(i)
        siguiente = palabras[i + 1] if i + 1 < len(palabras) else None
        if FIN_FRASE.search(p["texto"]) or siguiente is None or siguiente["inicio"] - p["fin"] > PAUSA_FRASE_S:
            grupos.append(actual)
            actual = []
    return grupos


def es_de_la_voz(hablante, palabras, indices):
    prob, ajenas = hablante.tramo(palabras[indices[0]]["inicio"], palabras[indices[-1]]["fin"])
    return prob >= UMBRAL_FRASE and ajenas <= MAX_VENTANAS_AJENAS


def bordes_en_silencio(palabras, indices, nivel):
    """Inicio y fin del clip en el silencio que rodea a las frases, o None."""
    primera, ultima = indices[0], indices[-1]
    tramo = [palabras[i] for i in indices]
    callado = nivel < cortar.umbral_silencio(nivel, tramo)
    limite = palabras[primera]["inicio"] - cortar.BUSQUEDA_INICIO_S
    if primera > 0:
        limite = max(limite, palabras[primera - 1]["fin"] - cortar.INVASION_VECINA_S)
    inicio = cortar.silencio_antes(callado, palabras[primera]["inicio"], max(0.0, limite))
    limite = palabras[ultima]["fin"] + cortar.BUSQUEDA_FIN_S
    if ultima + 1 < len(palabras):
        limite = min(limite, palabras[ultima + 1]["inicio"] + cortar.INVASION_VECINA_S)
    fin = cortar.silencio_despues(callado, palabras[ultima]["fin"], limite)
    return None if inicio is None or fin is None else (inicio, fin)


def clips_del_episodio(hablante, palabras, nivel, en_cancion):
    grupos = [g for g in frases(palabras) if not en_cancion(palabras[g[0]]["inicio"], palabras[g[-1]]["fin"])]
    buenas = [es_de_la_voz(hablante, palabras, g) for g in grupos]

    # Tiras de frases de la voz seguidas, con pausas naturales entre ellas.
    tiras, actual = [], []
    for g, buena in zip(grupos, buenas):
        seguida = actual and palabras[g[0]]["inicio"] - palabras[actual[-1][-1]]["fin"] <= MAX_PAUSA_ENTRE_FRASES_S
        if buena and (not actual or seguida):
            actual.append(g)
            continue
        if actual:
            tiras.append(actual)
        actual = [g] if buena else []
    if actual:
        tiras.append(actual)

    clips = []
    for tira in tiras:
        clips.extend(partir(tira, palabras, nivel))
    return clips


def partir(tira, palabras, nivel):
    """Clips de una tira de frases: la tira entera si cabe y sus bordes son
    silencio; si no, se parte por la pausa mas larga entre frases."""
    if not tira:
        return []
    indices = [i for g in tira for i in g]
    duracion = palabras[indices[-1]]["fin"] - palabras[indices[0]]["inicio"]
    if duracion <= MAX_CLIP_S:
        bordes = bordes_en_silencio(palabras, indices, nivel)
        if bordes is not None:
            inicio, fin = bordes
            return [] if fin - inicio < MIN_CLIP_S else [(indices, inicio, fin)]
    if len(tira) == 1:
        return []
    huecos = [palabras[b[0]]["inicio"] - palabras[a[-1]]["fin"] for a, b in zip(tira, tira[1:])]
    k = int(np.argmax(huecos)) + 1
    return partir(tira[:k], palabras, nivel) + partir(tira[k:], palabras, nivel)


def main() -> None:
    pedidos = sys.argv[1:]
    todas = {
        a.stem: json.loads(a.read_text(encoding="utf-8"))["palabras"]
        for a in sorted((DATOS / "03_alineado").glob("ep*.json"))
    }
    canciones = zonas_de_cancion(todas)
    total_s = 0.0
    for episodio, palabras in todas.items():
        if pedidos and episodio not in pedidos:
            continue
        hablante = Hablante(episodio)
        zonas = canciones.get(episodio, [])
        en_cancion = lambda a, b: any(a < z1 and b > z0 for z0, z1 in zonas)

        audio, tasa = sf.read(DATOS / "02_voz" / f"{episodio}_voz.wav", dtype="float32", always_2d=False)
        audio = cortar.mono(audio)
        carpeta = SALIDA / episodio
        carpeta.mkdir(parents=True, exist_ok=True)
        for viejo in carpeta.glob("*.wav"):
            viejo.unlink()

        indice = []
        for indices, inicio, fin in clips_del_episodio(hablante, palabras, cortar.niveles(audio, tasa), en_cancion):
            trozo = audio[int(inicio * tasa) : int(fin * tasa)].copy()
            fundido = int(cortar.FUNDIDO_S * tasa)
            rampa = np.linspace(0, 1, fundido, dtype=np.float32)
            trozo[:fundido] *= rampa
            trozo[-fundido:] *= rampa[::-1]
            archivo = f"{episodio}_{round(inicio * 100):06d}.wav"
            sf.write(carpeta / archivo, trozo, tasa, subtype="PCM_24")
            prob, ajenas = hablante.tramo(palabras[indices[0]]["inicio"], palabras[indices[-1]]["fin"])
            indice.append(
                {
                    "archivo": archivo,
                    "inicio": round(inicio, 3),
                    "fin": round(fin, 3),
                    "duracion": round(fin - inicio, 3),
                    "texto": " ".join(palabras[i]["texto"] for i in indices),
                    "palabras": [indices[0], indices[-1]],
                    "frases": sum(1 for i in indices if FIN_FRASE.search(palabras[i]["texto"])),
                    "prob": round(prob, 4),
                    "ventanas_ajenas": round(ajenas, 3),
                }
            )
        (carpeta / "indice.json").write_text(
            json.dumps({"episodio": episodio, "clips": indice}, ensure_ascii=False, indent=1), encoding="utf-8"
        )
        minutos = sum(c["duracion"] for c in indice) / 60
        total_s += minutos * 60
        print(f"{episodio}: {len(indice)} clips, {minutos:.1f} min", flush=True)
    print(f"total: {total_s / 60:.1f} min")


if __name__ == "__main__":
    main()
