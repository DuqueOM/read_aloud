"""Arma los dos conjuntos de entrenamiento de Qwen3-TTS a partir de 30_seleccion_final.py.

- mejores60 (o los minutos_finales de voz.toml): los minutos de mas calidad.
- todos: esos mismos mas los que quedaron fuera solo por calidad (con la voz de prueba,
  unos 74 minutos). Con las mismas reglas de duplicados, duracion minima y
  tomas repetidas, asi la unica diferencia entre los dos es el corte por
  calidad, y la comparacion a ciegas dice si ese corte ayuda.

Ningun clip que se solape en el tiempo con las 10 frases de validacion
(datos/09_comparar/frases.json) entra en el entrenamiento: con ellas se mide,
sin trampa, como dice el modelo frases que no vio, y son las mismas en todas
las rondas, para comparar. Con la voz de prueba salieron de la primera version del
proceso (09d_comparar.py, con clips de 04_cortes) y ya traian sus codigos
(11a_datos_qwen.py); con una voz nueva las elige 30_seleccion_final.py entre
los clips de 25_cortes, y aqui se limpian y se codifican como los demas.

Pasos, en entornos distintos:

    .venv/Scripts/python.exe      scripts/31_conjunto_qwen.py audio
        Quita la reverberacion (el de-reverb mono de anvuew, el que gano la
        prueba a ciegas de 07b), recorta el silencio de los extremos e iguala
        el volumen, como 06_conjunto.py y 07c_conjunto_final.py.

    .venv_qwen/Scripts/python.exe scripts/31_conjunto_qwen.py codigos
        Convierte cada clip en los codigos de audio de Qwen3-TTS, como
        11a_datos_qwen.py, y escribe datos/31_qwen/<conjunto>/entrenamiento.jsonl
        y validacion.jsonl. Si no hay muestra de referencia
        (datos/11_qwen/referencia.wav), elige el mejor clip de 5 a 10 s.

    .venv_qwen/Scripts/python.exe scripts/31_conjunto_qwen.py mejores 45
        Los 45 minutos de mas calidad de entre los elegidos, con los codigos
        que ya saco el paso anterior. Con la voz de prueba, a ciegas, los 60 mejores le
        ganaron con claridad a los 74 de todo lo conservado; este conjunto mide
        si recortar mas sigue ayudando.
"""

import importlib.util
import json
import os
import shutil
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("HF_HOME", str(RAIZ / "modelos" / "hf"))
os.environ["PATH"] = str(RAIZ / "herramientas") + os.pathsep + os.environ["PATH"]
sys.path.insert(0, str(Path(__file__).parent))

import numpy as np
import soundfile as sf

import voz

DATOS = RAIZ / "datos"
AUDIO = DATOS / "31_final" / "audio"
SALIDA = DATOS / "31_qwen"
QWEN = DATOS / "11_qwen"
SEPARACION_S = 1.0
MEJORES = f"mejores{voz.MINUTOS_FINALES:g}"
FUERA_POR_CALIDAD = f"menos calidad que los {voz.MINUTOS_FINALES:g} minutos elegidos"
REFERENCIA_S = (5.0, 10.0)


def cortes() -> dict:
    """Episodio, inicio y fin de cada clip de 25_cortar_frases.py."""
    resultado = {}
    for indice in (DATOS / "25_cortes").glob("ep*/indice.json"):
        for c in json.loads(indice.read_text(encoding="utf-8"))["clips"]:
            resultado[c["archivo"].removesuffix(".wav")] = (indice.parent.name, c["inicio"], c["fin"])
    return resultado


def frases_validacion() -> list:
    return json.loads((DATOS / "09_comparar" / "frases.json").read_text(encoding="utf-8"))


def validacion_nueva() -> list:
    """Las frases de validacion que eligio 30_seleccion_final.py, con su clip;
    vacio si son las de la primera version (sin "clave")."""
    seleccion = json.loads((DATOS / "30_final" / "seleccion.json").read_text(encoding="utf-8"))
    clips = {c["clave"]: c for c in seleccion["quitados"] if c["motivo"] == "frase de validacion"}
    return [dict(clips[f["clave"]], texto=f["texto"]) for f in frases_validacion() if "clave" in f]


def conjuntos() -> dict:
    seleccion = json.loads((DATOS / "30_final" / "seleccion.json").read_text(encoding="utf-8"))
    mejores = seleccion["elegidos"]
    resto = [c for c in seleccion["quitados"] if c["motivo"] == FUERA_POR_CALIDAD]

    # Fuera lo que se solape con las frases de validacion: las de la primera
    # version son clips de 04_cortes; las nuevas, de 25_cortes.
    viejos = {}
    for indice in (DATOS / "04_cortes").glob("ep*/indice.json"):
        for c in json.loads(indice.read_text(encoding="utf-8"))["clips"]:
            viejos[c["archivo"]] = (indice.parent.name, c["inicio"], c["fin"])
    tramos = cortes()
    prueba = [tramos[f["clave"]] if "clave" in f else viejos[f["archivo"]] for f in frases_validacion()]

    def libre(c):
        ep, a, b = tramos[c["clave"]]
        return not any(ep == pe and a < pb and b > pa for pe, pa, pb in prueba)

    fuera = [c["clave"] for c in mejores + resto if not libre(c)]
    if fuera:
        print(f"fuera por solaparse con la validacion: {', '.join(fuera)}")
    return {MEJORES: [c for c in mejores if libre(c)], "todos": [c for c in mejores + resto if libre(c)]}


def audio() -> None:
    from audio_separator.separator import Separator

    spec = importlib.util.spec_from_file_location("conjunto", Path(__file__).parent / "06_conjunto.py")
    conjunto = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(conjunto)

    # Las frases de validacion nuevas pasan por la misma limpieza que lo que
    # se entrena: si no, se mediria al modelo contra un audio distinto.
    clips = {c["clave"]: c for lista in [*conjuntos().values(), validacion_nueva()] for c in lista}
    AUDIO.mkdir(parents=True, exist_ok=True)
    temporal = AUDIO.parent / "temporal"
    temporal.mkdir(exist_ok=True)

    # El de-reverb tiene un costo fijo por archivo: se unen todos los clips,
    # separados por silencio, y se procesa una vez (como 07a_sin_reverb.py).
    tasa = sf.info(next(iter(clips.values()))["ruta"]).samplerate
    hueco = np.zeros(int(SEPARACION_S * tasa), dtype=np.float32)
    partes, posiciones, cursor = [hueco], [], len(hueco)
    for clave, c in clips.items():
        a, t = sf.read(c["ruta"], dtype="float32", always_2d=False)
        assert t == tasa
        a = a if a.ndim == 1 else a.mean(axis=1)
        partes += [a, hueco]
        posiciones.append((clave, cursor, cursor + len(a)))
        cursor += len(a) + len(hueco)
    sf.write(temporal / "todo.wav", np.concatenate(partes), tasa, subtype="FLOAT")

    separador = Separator(output_dir=str(temporal), model_file_dir=str(RAIZ / "modelos"), output_format="WAV",
                          sample_rate=tasa)
    separador.load_model(model_filename="dereverb_mel_band_roformer_mono_anvuew.ckpt")
    separador.separate(str(temporal / "todo.wav"), {"noreverb": "seco", "reverb": "eco"})
    seco, _ = sf.read(temporal / "seco.wav", dtype="float32", always_2d=False)
    seco = seco.mean(axis=1) if seco.ndim > 1 else seco

    for clave, desde, hasta in posiciones:
        limpio = conjunto.igualar_volumen(conjunto.recortar_silencio(seco[desde:hasta], tasa))
        sf.write(AUDIO / f"{clave}.wav", limpio, tasa, subtype="PCM_24")
    for archivo in temporal.iterdir():
        archivo.unlink()
    temporal.rmdir()
    print(f"{len(posiciones)} clips sin eco y con el volumen igualado en {AUDIO}")


def referencia(elegidos: list) -> Path:
    """La muestra de voz de la que sale la huella del hablante. La de las rondas
    anteriores, si la hay, para que todas se comparen igual; si no, el clip de
    mas calidad de REFERENCIA_S: largo para que la huella sea estable, y sin
    eco, porque ya paso por la limpieza."""
    destino = QWEN / "referencia.wav"
    if not destino.exists():
        aptos = [c for c in elegidos if REFERENCIA_S[0] <= c["duracion"] <= REFERENCIA_S[1]] or elegidos
        mejor = max(aptos, key=lambda c: c["calidad"])
        QWEN.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(AUDIO / f"{mejor['clave']}.wav", destino)
        print(f"muestra de referencia: {mejor['clave']} ({mejor['duracion']:.1f} s)", flush=True)
    return destino


def codigos() -> None:
    from qwen_tts import Qwen3TTSTokenizer
    tokenizador = Qwen3TTSTokenizer.from_pretrained("Qwen/Qwen3-TTS-Tokenizer-12Hz", device_map="cuda:0")
    grupos = conjuntos()
    muestra = referencia(grupos[MEJORES])
    hechos = {}

    def lineas(lista):
        salida = []
        for inicio in range(0, len(lista), 16):
            lote = lista[inicio:inicio + 16]
            faltan = [c for c in lote if c["clave"] not in hechos]
            if faltan:
                for c, codigo in zip(faltan, tokenizador.encode([str(AUDIO / f"{c['clave']}.wav") for c in faltan]).audio_codes):
                    hechos[c["clave"]] = codigo.cpu().tolist()
            for c in lote:
                salida.append(json.dumps({"audio": str(AUDIO / f"{c['clave']}.wav"), "text": c["texto"],
                                          "language": voz.IDIOMA_QWEN, "ref_audio": str(muestra),
                                          "audio_codes": hechos[c["clave"]]}, ensure_ascii=False))
        return salida

    # La validacion se codifica una vez y queda en datos/11_qwen, como la de
    # 11a_datos_qwen.py en la primera voz: todas las rondas la reusan.
    validacion = QWEN / "validacion.jsonl"
    if not validacion.exists():
        validacion.write_text("\n".join(lineas(validacion_nueva())) + "\n", encoding="utf-8")
    for nombre, lista in grupos.items():
        carpeta = SALIDA / nombre
        carpeta.mkdir(parents=True, exist_ok=True)
        (carpeta / "entrenamiento.jsonl").write_text("\n".join(lineas(lista)) + "\n", encoding="utf-8")
        (carpeta / "validacion.jsonl").write_text(validacion.read_text(encoding="utf-8"), encoding="utf-8")
        minutos = sum(c["duracion"] for c in lista) / 60
        print(f"{nombre}: {len(lista)} clips, {minutos:.1f} min", flush=True)


def mejores(minutos: float) -> None:
    elegidos = sorted(conjuntos()[MEJORES], key=lambda c: -c["calidad"])
    claves, total = set(), 0.0
    for c in elegidos:
        if total + c["duracion"] <= minutos * 60:
            claves.add(c["clave"])
            total += c["duracion"]
    nombre = f"mejores{minutos:g}"
    origen, carpeta = SALIDA / MEJORES, SALIDA / nombre
    lineas = [l for l in (origen / "entrenamiento.jsonl").read_text(encoding="utf-8").splitlines()
              if Path(json.loads(l)["audio"]).stem in claves]
    assert len(lineas) == len(claves)
    carpeta.mkdir(parents=True, exist_ok=True)
    (carpeta / "entrenamiento.jsonl").write_text("\n".join(lineas) + "\n", encoding="utf-8")
    (carpeta / "validacion.jsonl").write_text((origen / "validacion.jsonl").read_text(encoding="utf-8"),
                                              encoding="utf-8")
    print(f"{nombre}: {len(lineas)} clips, {total / 60:.1f} min, calidad del peor "
          f"{min(c['calidad'] for c in elegidos if c['clave'] in claves):.2f}", flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "mejores":  # ese no usa la tarjeta
        mejores(float(sys.argv[2]))
    else:
        import gpu
        gpu.ocupar()
        {"audio": audio, "codigos": codigos}[sys.argv[1]]()
