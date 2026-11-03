"""Corta cada grabacion en clips donde solo habla la voz buscada.

Combina dos senales:

1. Quien habla en cada momento. Se recorre la voz de la grabacion con una
   ventana de 1.5 s que avanza de a 0.25 s, y en cada posicion se mide el
   parecido con las referencias. El resultado es una curva: alta mientras
   habla la voz buscada y baja cuando habla cualquier otra.

2. Donde empieza y termina cada palabra, segun la transcripcion de Whisper.

Cada palabra recibe el parecido de la curva en su posicion. Un clip es un
tramo seguido de palabras de la voz buscada, sin pausas largas, cuyos bordes caen en
el silencio real que rodea a su primera y su ultima palabra. Asi se quitan a
la vez las otras voces que hablan en medio y el ruido de los extremos, y nunca
se corta dentro de un sonido. Al final, la huella del clip entero confirma que
es la voz buscada.

Uso:
    python 04_cortar.py              todas las grabaciones transcritas
    python 04_cortar.py ep01         una sola
    python 04_cortar.py --curva      solo muestra el reparto de la curva
    python 04_cortar.py --curvas ep01 solo calcula y guarda la curva
"""

import json
import sys
from math import gcd

import numpy as np
import soundfile as sf
import torch
from scipy.signal import resample_poly
from speechbrain.inference.speaker import EncoderClassifier

from comun import DATOS, MODELOS as RAIZ_MODELOS, REFERENCIAS

VOZ = DATOS / "02_voz"
TRANSCRIPCION = DATOS / "03_transcripcion"
ALINEADO = DATOS / "03_alineado"
SALIDA = DATOS / "04_cortes"
CURVAS = DATOS / "04_curvas"
MODELOS = RAIZ_MODELOS / "ecapa"

TASA = 16000
VENTANA_S = 1.5
PASO_S = 0.25
SILENCIO_DB = -40.0

# Umbrales de probabilidad de ser la voz buscada, calibrada por
# 04a_calibrar.py. Desde ALTO la palabra es suya; por debajo de BAJO es de otra
# voz y corta el clip. Entre ambos se acepta solo si queda rodeada de palabras
# suyas: suele ser la misma voz en otro registro, como un grito o un susurro,
# donde el parecido baja un poco.
ALTO = 0.70
BAJO = 0.30
CALIBRACION = CURVAS / "calibracion.json"

# Una pausa mas larga que esto separa dos clips: en ese hueco puede haber
# ruido, una respiracion fuerte o una voz que Whisper no transcribio.
MAX_PAUSA_S = 0.6
MIN_CLIP_S = 1.0
MAX_CLIP_S = 12.0
# Al menos esta parte del clip, medida en tiempo, debe ser claramente suya.
MIN_PROPORCION_OBJETIVO = 0.7

# Cada borde se lleva al silencio real mas cercano a la palabra del extremo.
# Sin ese silencio el borde caeria dentro de una respiracion, una risa o una
# palabra que Whisper no transcribio; entonces se suelta la palabra del
# extremo y se prueba con la siguiente.
#
# Que cuenta como silencio depende de la escena. Casi siempre la voz separada
# queda en silencio digital entre frases, pero bajo la musica de algunas
# escenas queda un resto constante de -35 a -40 dBFS. Por eso el borde tiene
# que estar SNR_BORDE_DB por debajo del habla del propio clip, sin pasar nunca
# de SILENCIO_MAX_DB; y por debajo de SILENCIO_DB siempre es silencio. Es mas
# estricto que los -42 dB con que RVC decide donde hay silencio.
SNR_BORDE_DB = 25.0
SILENCIO_MAX_DB = -30.0
SILENCIO_DB_BORDE = -45.0
SILENCIO_MIN_S = 0.03
BUSQUEDA_INICIO_S = 0.35
BUSQUEDA_FIN_S = 0.45
RELLENO_S = 0.08
INTENTOS_BORDE = 8
# La busqueda puede entrar un poco en la palabra vecina, porque la alineacion
# suele alargar su final unas centesimas. Es seguro: se toma el silencio mas
# cercano a la palabra propia, asi que lo que suene de la vecina queda fuera.
INVASION_VECINA_S = 0.05

# Probabilidad minima de la primera y la ultima palabra de un clip.
PROB_EXTREMO = 0.7
CUADRO_S = 0.01
FUNDIDO_S = 0.005

# Comprobacion final: la huella del clip entero tambien tiene que parecerse a
# la voz buscada. Atrapa los clips cortos donde la curva, que mira ventanas de 1.5 s,
# se dejo arrastrar por las palabras de alrededor.
MIN_PROB_CLIP = 0.5


def a_16k(audio: np.ndarray, tasa: int) -> np.ndarray:
    divisor = gcd(tasa, TASA)
    return resample_poly(audio, TASA // divisor, tasa // divisor).astype(np.float32)


def mono(audio: np.ndarray) -> np.ndarray:
    return audio if audio.ndim == 1 else audio.mean(axis=1)


def cargar_modelo():
    return EncoderClassifier.from_hparams(
        source="speechbrain/spkrec-ecapa-voxceleb",
        savedir=str(MODELOS),
        run_opts={"device": "cuda:0" if torch.cuda.is_available() else "cpu"},
    )


def huellas_por_ventana(modelo, audio16: np.ndarray, paso_s: float):
    """Huella normalizada de cada ventana con voz; NaN donde hay silencio."""
    ventana = int(VENTANA_S * TASA)
    paso = int(paso_s * TASA)
    inicios = np.arange(0, max(1, len(audio16) - ventana), paso)
    centros = (inicios + ventana / 2) / TASA

    umbral = 10 ** (SILENCIO_DB / 20)
    con_voz = np.array([np.sqrt(np.mean(audio16[i : i + ventana] ** 2)) > umbral for i in inicios])

    huellas = np.full((len(inicios), 192), np.nan, dtype=np.float32)
    indices = np.where(con_voz)[0]

    for lote in range(0, len(indices), 128):
        elegidos = indices[lote : lote + 128]
        senal = np.stack([audio16[inicios[i] : inicios[i] + ventana] for i in elegidos])
        with torch.no_grad():
            vectores = modelo.encode_batch(torch.from_numpy(senal).to(modelo.device)).squeeze(1).cpu().numpy()
        vectores /= np.linalg.norm(vectores, axis=1, keepdims=True) + 1e-9
        huellas[elegidos] = vectores

    return centros, huellas


def referencias(modelo):
    """Huellas de referencia con la misma ventana que la curva."""
    vectores = []
    for archivo in sorted(REFERENCIAS.glob("*.wav")):
        audio, tasa = sf.read(archivo, dtype="float32", always_2d=False)
        _, huellas = huellas_por_ventana(modelo, a_16k(mono(audio), tasa), paso_s=0.5)
        vectores.append(huellas[~np.isnan(huellas[:, 0])])

    if not vectores:
        raise SystemExit("No hay referencias: separa antes la voz de referencia con 02_separar_voz.py referencias")

    todas = np.concatenate(vectores)
    centro = todas.mean(axis=0)
    centro /= np.linalg.norm(centro) + 1e-9
    return centro, todas


def curva(modelo, episodio: str, centro, refs):
    """Parecido con la voz buscada a lo largo de la grabacion. Se guarda en disco."""
    CURVAS.mkdir(parents=True, exist_ok=True)
    destino = CURVAS / f"{episodio}.npz"
    if destino.exists():
        datos = np.load(destino)
        return datos["centros"], datos["parecido"]

    audio, tasa = sf.read(VOZ / f"{episodio}_voz.wav", dtype="float32", always_2d=False)
    centros, huellas = huellas_por_ventana(modelo, a_16k(mono(audio), tasa), PASO_S)

    parecido = np.full(len(centros), np.nan, dtype=np.float32)
    validas = ~np.isnan(huellas[:, 0])
    h = huellas[validas]
    parecido[validas] = 0.6 * (h @ centro) + 0.4 * (h @ refs.T).max(axis=1)

    np.savez(destino, centros=centros, parecido=parecido)
    return centros, parecido


def parecido_palabra(centros, parecido, inicio, fin):
    medio = (inicio + fin) / 2
    radio = max(PASO_S, (fin - inicio) / 2)
    cerca = np.abs(centros - medio) <= radio
    valores = parecido[cerca]
    valores = valores[~np.isnan(valores)]
    return float(valores.mean()) if valores.size else float("nan")


def cargar_calibracion():
    if not CALIBRACION.exists():
        raise SystemExit("Falta la calibracion: corre antes 04a_calibrar.py")
    datos = json.loads(CALIBRACION.read_text(encoding="utf-8"))
    malla, probabilidad = np.array(datos["malla"]), np.array(datos["probabilidad"])
    return lambda x: float("nan") if np.isnan(x) else float(np.interp(x, malla, probabilidad))


def clase(probabilidad: float) -> str:
    if np.isnan(probabilidad) or probabilidad < BAJO:
        return "otro"
    return "objetivo" if probabilidad >= ALTO else "duda"


def niveles(audio: np.ndarray, tasa: int) -> np.ndarray:
    """Nivel en dBFS cada 10 ms, medido en la ventana de 20 ms que empieza ahi."""
    salto, ancho = int(CUADRO_S * tasa), int(2 * CUADRO_S * tasa)
    acumulada = np.concatenate([[0.0], np.cumsum(audio.astype(np.float64) ** 2)])
    inicios = np.arange(0, len(audio) - ancho, salto)
    energia = (acumulada[inicios + ancho] - acumulada[inicios]) / ancho
    return 10 * np.log10(energia + 1e-18)


def umbral_silencio(nivel, tramo):
    habla = np.concatenate([nivel[int(p["inicio"] / CUADRO_S) : int(p["fin"] / CUADRO_S)] for p in tramo])
    return max(SILENCIO_DB_BORDE, min(SILENCIO_MAX_DB, float(np.median(habla)) - SNR_BORDE_DB))


def silencio_antes(callado, inicio_voz, limite):
    """Comienzo del silencio que precede a la voz, o None si no lo hay."""
    largo = round(SILENCIO_MIN_S / CUADRO_S)
    tope = max(0, int(np.ceil(limite / CUADRO_S)))
    i = int(inicio_voz / CUADRO_S)
    while i - largo >= tope and not callado[i - largo : i].all():
        i -= 1
    if i - largo < tope:
        return None
    j = i - largo
    while j - 1 >= tope and i - j < round(RELLENO_S / CUADRO_S) + largo and callado[j - 1]:
        j -= 1
    return j * CUADRO_S


def silencio_despues(callado, fin_voz, limite):
    """Final del silencio que sigue a la voz, o None si no lo hay."""
    largo = round(SILENCIO_MIN_S / CUADRO_S)
    tope = min(len(callado), int(limite / CUADRO_S))
    i = int(np.ceil(fin_voz / CUADRO_S))
    while i + largo <= tope and not callado[i : i + largo].all():
        i += 1
    if i + largo > tope:
        return None
    j = i + largo
    while j < tope and j - i < round(RELLENO_S / CUADRO_S) + largo and callado[j]:
        j += 1
    return j * CUADRO_S


def recortar_extremos(tramo):
    # Los extremos piden mas confianza que el interior, donde lo dudoso se
    # acepta rodeado de palabras suyas.
    while tramo and not tramo[0]["prob"] >= PROB_EXTREMO:
        tramo = tramo[1:]
    while tramo and not tramo[-1]["prob"] >= PROB_EXTREMO:
        tramo = tramo[:-1]
    return tramo


def bordes(tramo, palabras, nivel):
    """Lleva cada extremo del tramo al silencio; suelta palabras si hace falta."""
    callado = nivel < umbral_silencio(nivel, tramo)
    inicio = fin = None
    for _ in range(INTENTOS_BORDE):
        tramo = recortar_extremos(tramo)
        if not tramo:
            return None
        primera = tramo[0]["indice"]
        limite = tramo[0]["inicio"] - BUSQUEDA_INICIO_S
        if primera > 0:
            limite = max(limite, palabras[primera - 1]["fin"] - INVASION_VECINA_S)
        inicio = silencio_antes(callado, tramo[0]["inicio"], max(0.0, limite))
        if inicio is not None:
            break
        tramo = tramo[1:]
    if inicio is None:
        return None

    for _ in range(INTENTOS_BORDE):
        tramo = recortar_extremos(tramo)
        if not tramo:
            return None
        ultima = tramo[-1]["indice"]
        limite = tramo[-1]["fin"] + BUSQUEDA_FIN_S
        if ultima + 1 < len(palabras):
            limite = min(limite, palabras[ultima + 1]["inicio"] + INVASION_VECINA_S)
        fin = silencio_despues(callado, tramo[-1]["fin"], limite)
        if fin is not None:
            break
        tramo = tramo[:-1]
    if fin is None:
        return None

    return tramo, inicio, fin


def dividir(tramo):
    """Parte un tramo largo por su pausa mas larga hasta que ninguno pase de
    MAX_CLIP_S. Cortar al llegar al tope caeria a mitad de frase."""
    if len(tramo) < 2 or tramo[-1]["fin"] - tramo[0]["inicio"] <= MAX_CLIP_S:
        return [tramo]
    huecos = [tramo[k + 1]["inicio"] - tramo[k]["fin"] for k in range(len(tramo) - 1)]
    k = int(np.argmax(huecos))
    return dividir(tramo[: k + 1]) + dividir(tramo[k + 1 :])


def armar_clips(palabras, nivel):
    """Agrupa palabras seguidas en tramos y se queda con los de la voz buscada."""
    tramos, actual = [], []

    for i, p in enumerate(palabras):
        corta = p["clase"] == "otro" or (actual and p["inicio"] - actual[-1]["fin"] > MAX_PAUSA_S)
        if corta and actual:
            tramos.extend(dividir(actual))
            actual = []
        if p["clase"] != "otro":
            actual.append(dict(p, indice=i))

    if actual:
        tramos.extend(dividir(actual))

    clips = []
    for tramo in tramos:
        ajuste = bordes(tramo, palabras, nivel)
        if ajuste is None:
            continue
        tramo, inicio, fin = ajuste

        seguro = sum(p["fin"] - p["inicio"] for p in tramo if p["clase"] == "objetivo")
        hablado = sum(p["fin"] - p["inicio"] for p in tramo) + 1e-9
        if seguro / hablado < MIN_PROPORCION_OBJETIVO:
            continue

        if fin - inicio < MIN_CLIP_S:
            continue

        pesos = np.array([p["fin"] - p["inicio"] for p in tramo])
        parecidos = np.array([p["parecido"] for p in tramo])
        probabilidades = np.array([p["prob"] for p in tramo])
        clips.append(
            {
                "inicio": round(max(0.0, inicio), 3),
                "fin": round(fin, 3),
                "texto": " ".join(p["texto"] for p in tramo),
                "puntaje": round(float((parecidos * pesos).sum() / pesos.sum()), 4),
                "confianza": round(float((probabilidades * pesos).sum() / pesos.sum()), 4),
                "minimo": round(float(probabilidades.min()), 4),
            }
        )

    return clips


def mostrar_curva(modelo, centro, refs):
    todos = []
    for archivo in sorted(TRANSCRIPCION.glob("ep*.json")):
        _, parecido = curva(modelo, archivo.stem, centro, refs)
        todos.append(parecido[~np.isnan(parecido)])
    valores = np.concatenate(todos)
    print(f"{len(valores)} ventanas con voz")
    for lo in np.arange(0.0, 0.9, 0.05):
        n = ((valores >= lo) & (valores < lo + 0.05)).sum()
        print(f"  {lo:.2f}-{lo + 0.05:.2f}  {'#' * int(200 * n / len(valores))} {n}")


def main() -> None:
    argumentos = sys.argv[1:]
    modelo = cargar_modelo()
    centro, refs = referencias(modelo)

    if argumentos == ["--curva"]:
        mostrar_curva(modelo, centro, refs)
        return

    if argumentos[:1] == ["--curvas"]:
        for episodio in argumentos[1:]:
            curva(modelo, episodio, centro, refs)
            print(f"{episodio}: curva calculada")
        return

    probabilidad = cargar_calibracion()

    transcritos = sorted(TRANSCRIPCION.glob("ep*.json"))
    if argumentos:
        transcritos = [t for t in transcritos if t.stem in argumentos]

    for archivo in transcritos:
        episodio = archivo.stem
        centros, parecido = curva(modelo, episodio, centro, refs)

        # Los tiempos afinados por la alineacion forzada, si existen.
        fuente = ALINEADO / archivo.name
        if not fuente.exists():
            fuente = archivo
            print(f"{episodio}: sin alinear, uso los tiempos de Whisper")
        palabras = json.loads(fuente.read_text(encoding="utf-8"))["palabras"]
        for p in palabras:
            p["parecido"] = parecido_palabra(centros, parecido, p["inicio"], p["fin"])
            p["prob"] = probabilidad(p["parecido"])
            p["clase"] = clase(p["prob"])

        audio, tasa = sf.read(VOZ / f"{episodio}_voz.wav", dtype="float32", always_2d=False)
        audio = mono(audio)

        candidatos = armar_clips(palabras, niveles(audio, tasa))

        clips = []
        for clip in candidatos:
            trozo = audio[int(clip["inicio"] * tasa) : int(clip["fin"] * tasa)].copy()
            senal = torch.from_numpy(a_16k(trozo, tasa))[None].to(modelo.device)
            with torch.no_grad():
                huella = modelo.encode_batch(senal).squeeze().cpu().numpy()
            huella /= np.linalg.norm(huella) + 1e-9
            parecido_clip = 0.6 * float(huella @ centro) + 0.4 * float((refs @ huella).max())
            clip["prob_clip"] = round(probabilidad(parecido_clip), 4)
            if clip["prob_clip"] < MIN_PROB_CLIP:
                continue

            fundido = int(FUNDIDO_S * tasa)
            rampa = np.linspace(0, 1, fundido, dtype=np.float32)
            trozo[:fundido] *= rampa
            trozo[-fundido:] *= rampa[::-1]
            clip["audio"] = trozo
            clips.append(clip)

        carpeta = SALIDA / episodio
        carpeta.mkdir(parents=True, exist_ok=True)
        for viejo in carpeta.glob("*.wav"):
            viejo.unlink()

        for clip in clips:
            # El nombre sale del instante de inicio, en centesimas: asi un clip
            # conserva su nombre, y su decision en la revision, si se vuelve a
            # cortar la grabacion con otra calibracion.
            clip["archivo"] = f"{episodio}_{round(clip['inicio'] * 100):06d}.wav"
            clip["duracion"] = round(clip["fin"] - clip["inicio"], 3)
            sf.write(carpeta / clip["archivo"], clip.pop("audio"), tasa, subtype="PCM_24")

        (carpeta / "indice.json").write_text(
            json.dumps({"episodio": episodio, "clips": clips}, ensure_ascii=False, indent=1),
            encoding="utf-8",
        )

        total = sum(c["duracion"] for c in clips)
        print(
            f"{episodio}: {len(clips)} clips, {total / 60:.1f} min "
            f"({len(candidatos) - len(clips)} descartados por la huella del clip)"
        )


if __name__ == "__main__":
    main()
