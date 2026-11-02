"""Arma los dos conjuntos de entrenamiento de Qwen3-TTS a partir de 30_seleccion_final.py.

- mejores60: los 60 minutos de mas calidad.
- todos: esos mismos mas los que quedaron fuera solo por calidad, unos 74
  minutos. Con las mismas reglas de duplicados, duracion minima y tomas
  repetidas, asi la unica diferencia entre los dos es el corte por calidad, y
  la comparacion a ciegas dice si ese corte ayuda.

Ningun clip que se solape en el tiempo con las 10 frases de validacion
(datos/09_comparar/frases.json) entra en el entrenamiento: con ellas se mide,
sin trampa, como dice el modelo frases que no vio, y son las mismas de las
rondas anteriores, para comparar.

Pasos, en entornos distintos:

    .venv/Scripts/python.exe      scripts/31_conjunto_qwen.py audio
        Quita la reverberacion (el de-reverb mono de anvuew, el que gano la
        prueba a ciegas de 07b), recorta el silencio de los extremos e iguala
        el volumen, como 06_conjunto.py y 07c_conjunto_final.py.

    .venv_qwen/Scripts/python.exe scripts/31_conjunto_qwen.py codigos
        Convierte cada clip en los codigos de audio de Qwen3-TTS, como
        11a_datos_qwen.py, y escribe datos/31_qwen/<conjunto>/entrenamiento.jsonl
        y validacion.jsonl.

    .venv_qwen/Scripts/python.exe scripts/31_conjunto_qwen.py mejores45
        Los 45 minutos de mas calidad de entre los 60, con los codigos que ya
        saco el paso anterior. A ciegas, los 60 mejores le ganaron con claridad
        a los 74 de todo lo conservado; este conjunto mide si recortar mas
        sigue ayudando.
"""

import importlib.util
import json
import os
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("HF_HOME", str(RAIZ / "modelos" / "hf"))
os.environ["PATH"] = str(RAIZ / "herramientas") + os.pathsep + os.environ["PATH"]
sys.path.insert(0, str(Path(__file__).parent))

import numpy as np
import soundfile as sf

DATOS = RAIZ / "datos"
AUDIO = DATOS / "31_final" / "audio"
SALIDA = DATOS / "31_qwen"
SEPARACION_S = 1.0
FUERA_POR_CALIDAD = "menos calidad que los 60 minutos elegidos"


def conjuntos() -> dict:
    seleccion = json.loads((DATOS / "30_final" / "seleccion.json").read_text(encoding="utf-8"))
    mejores = seleccion["elegidos"]
    resto = [c for c in seleccion["quitados"] if c["motivo"] == FUERA_POR_CALIDAD]

    # Fuera lo que se solape con las frases de validacion.
    viejos = {}
    for indice in (DATOS / "04_cortes").glob("ep*/indice.json"):
        for c in json.loads(indice.read_text(encoding="utf-8"))["clips"]:
            viejos[c["archivo"]] = (indice.parent.name, c["inicio"], c["fin"])
    prueba = [viejos[f["archivo"]] for f in json.loads((DATOS / "09_comparar" / "frases.json").read_text(encoding="utf-8"))]
    cortes = {}
    for indice in (DATOS / "25_cortes").glob("ep*/indice.json"):
        for c in json.loads(indice.read_text(encoding="utf-8"))["clips"]:
            cortes[c["archivo"].removesuffix(".wav")] = (indice.parent.name, c["inicio"], c["fin"])

    def libre(c):
        ep, a, b = cortes[c["clave"]]
        return not any(ep == pe and a < pb and b > pa for pe, pa, pb in prueba)

    fuera = [c["clave"] for c in mejores + resto if not libre(c)]
    if fuera:
        print(f"fuera por solaparse con la validacion: {', '.join(fuera)}")
    return {"mejores60": [c for c in mejores if libre(c)], "todos": [c for c in mejores + resto if libre(c)]}


def audio() -> None:
    from audio_separator.separator import Separator

    spec = importlib.util.spec_from_file_location("conjunto", Path(__file__).parent / "06_conjunto.py")
    conjunto = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(conjunto)

    clips = {c["clave"]: c for lista in conjuntos().values() for c in lista}
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


def codigos() -> None:
    from qwen_tts import Qwen3TTSTokenizer
    tokenizador = Qwen3TTSTokenizer.from_pretrained("Qwen/Qwen3-TTS-Tokenizer-12Hz", device_map="cuda:0")
    referencia = DATOS / "11_qwen" / "referencia.wav"  # la misma muestra de voz que las rondas anteriores
    hechos = {}
    for nombre, lista in conjuntos().items():
        lineas = []
        for inicio in range(0, len(lista), 16):
            lote = lista[inicio:inicio + 16]
            faltan = [c for c in lote if c["clave"] not in hechos]
            if faltan:
                for c, codigo in zip(faltan, tokenizador.encode([str(AUDIO / f"{c['clave']}.wav") for c in faltan]).audio_codes):
                    hechos[c["clave"]] = codigo.cpu().tolist()
            for c in lote:
                lineas.append(json.dumps({"audio": str(AUDIO / f"{c['clave']}.wav"), "text": c["texto"],
                                          "language": "spanish", "ref_audio": str(referencia),
                                          "audio_codes": hechos[c["clave"]]}, ensure_ascii=False))
        carpeta = SALIDA / nombre
        carpeta.mkdir(parents=True, exist_ok=True)
        (carpeta / "entrenamiento.jsonl").write_text("\n".join(lineas) + "\n", encoding="utf-8")
        # La validacion de siempre, la de 11a_datos_qwen.py.
        (carpeta / "validacion.jsonl").write_text((DATOS / "11_qwen" / "validacion.jsonl").read_text(encoding="utf-8"),
                                                  encoding="utf-8")
        minutos = sum(c["duracion"] for c in lista) / 60
        print(f"{nombre}: {len(lineas)} clips, {minutos:.1f} min", flush=True)


def mejores45() -> None:
    elegidos = sorted(conjuntos()["mejores60"], key=lambda c: -c["calidad"])
    claves, total = set(), 0.0
    for c in elegidos:
        if total + c["duracion"] <= 45 * 60:
            claves.add(c["clave"])
            total += c["duracion"]
    origen, carpeta = SALIDA / "mejores60", SALIDA / "mejores45"
    lineas = [l for l in (origen / "entrenamiento.jsonl").read_text(encoding="utf-8").splitlines()
              if Path(json.loads(l)["audio"]).stem in claves]
    assert len(lineas) == len(claves)
    carpeta.mkdir(parents=True, exist_ok=True)
    (carpeta / "entrenamiento.jsonl").write_text("\n".join(lineas) + "\n", encoding="utf-8")
    (carpeta / "validacion.jsonl").write_text((origen / "validacion.jsonl").read_text(encoding="utf-8"),
                                              encoding="utf-8")
    print(f"mejores45: {len(lineas)} clips, {total / 60:.1f} min, calidad del peor "
          f"{min(c['calidad'] for c in elegidos if c['clave'] in claves):.2f}", flush=True)


if __name__ == "__main__":
    if sys.argv[1] != "mejores45":  # ese no usa la tarjeta
        import gpu
        gpu.ocupar()
    {"audio": audio, "codigos": codigos, "mejores45": mejores45}[sys.argv[1]]()
