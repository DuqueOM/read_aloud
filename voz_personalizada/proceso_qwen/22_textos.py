"""¿Que transcribe mejor los clips de la voz?

Ademas, CONTEXTO, normalizar() y distancia(), que usan 27_transcribir_clips.py
y 28_revision.py, salen de aqui: el contexto y las variantes de los nombres,
de voz.toml.

Con la voz de prueba, la referencia fueron los textos de los 516 clips del conjunto
final, con las 140 correcciones a mano del usuario. Se comparan:

- hoy: el texto que salio de transcribir el episodio entero con Whisper
  large-v3, antes de las correcciones;
- whisper: Whisper large-v3 sobre cada clip por separado, con busqueda en haz;
- qwen: Qwen3-ASR-1.7B (Apache-2.0) sobre cada clip;
- y las dos ultimas con un contexto que les da los nombres propios, como
  se escriben en las correcciones.

La medida es el error por caracter (CER) sin mayusculas ni signos, y aparte
cuantas veces acierta el signo final (¿pregunta?, ¡exclamacion!, punto), que
para la entonacion importa tanto como las palabras.

La referencia favorece a "hoy": de sus 516 textos, el usuario solo cambio los
140 que estaban mal, asi que en los otros 376 "hoy" coincide por
construccion. Si otro sistema le gana igual, le gana de verdad.

Uso:
    .venv/Scripts/python.exe     scripts/22_textos.py whisper
    .venv_asr/Scripts/python.exe scripts/22_textos.py qwen
    .venv/Scripts/python.exe     scripts/22_textos.py comparar
"""

import json
import os
import re
import sys
import unicodedata
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("HF_HOME", str(RAIZ / "modelos" / "hf"))
sys.path.insert(0, str(Path(__file__).parent))
import voz  # noqa: E402

DATOS = RAIZ / "datos"
SALIDA = DATOS / "22_textos"
FINAL = DATOS / "08_final" / f"{voz.NOMBRE}_{voz.IDIOMA}"

# De que es la grabacion y los nombres propios como deben escribirse: guia a
# los dos transcriptores. Con la voz de prueba: "las grabaciones de prueba, grabaciones.
# Nombres: la voz de prueba, Ana, Ana, ...".
CONTEXTO = voz.CONTEXTO
# Variantes de un mismo nombre que no cuentan como error.
VARIANTES = voz.VARIANTES


def referencias() -> dict[str, str]:
    """Los textos ya corregidos por el usuario en una ronda anterior, si la hubo."""
    textos = {}
    for archivo in ("entrenamiento.jsonl", "validacion.jsonl"):
        if not (DATOS / "11_qwen" / archivo).exists():
            continue
        for linea in (DATOS / "11_qwen" / archivo).read_text(encoding="utf-8").splitlines():
            fila = json.loads(linea)
            textos[Path(fila["audio"]).stem] = fila["text"]
    return textos


def originales() -> dict[str, str]:
    textos = {}
    for indice in (DATOS / "04_cortes").glob("ep*/indice.json"):
        for clip in json.loads(indice.read_text(encoding="utf-8"))["clips"]:
            textos[clip["archivo"].removesuffix(".wav")] = clip["texto"]
    return textos


def guardar(nombre: str, textos: dict) -> None:
    SALIDA.mkdir(parents=True, exist_ok=True)
    (SALIDA / f"{nombre}.json").write_text(json.dumps(textos, ensure_ascii=False, indent=1), encoding="utf-8")


def con_whisper() -> None:
    # whisper.load_audio llama a ffmpeg por su nombre.
    os.environ["PATH"] = str(RAIZ / "herramientas") + os.pathsep + os.environ["PATH"]
    import whisper
    modelo = whisper.load_model("large-v3", device="cuda", download_root=str(RAIZ / "modelos" / "whisper"))
    for nombre, contexto in (("whisper", None), ("whisper_contexto", CONTEXTO)):
        textos = {}
        for clave in sorted(referencias()):
            audio = whisper.load_audio(str(FINAL / f"{clave}.wav"))
            textos[clave] = modelo.transcribe(audio, language=voz.IDIOMA, beam_size=5, best_of=5, fp16=False,
                                              condition_on_previous_text=False, initial_prompt=contexto)["text"].strip()
        guardar(nombre, textos)
        print(f"{nombre}: listo", flush=True)


def con_qwen() -> None:
    import torch
    from qwen_asr import Qwen3ASRModel
    modelo = Qwen3ASRModel.from_pretrained("Qwen/Qwen3-ASR-1.7B", dtype=torch.bfloat16, device_map="cuda:0",
                                           max_inference_batch_size=16)
    claves = sorted(referencias())
    rutas = [str(FINAL / f"{c}.wav") for c in claves]
    for nombre, contexto in (("qwen", ""), ("qwen_contexto", CONTEXTO)):
        textos = {}
        for i in range(0, len(rutas), 16):
            for clave, r in zip(claves[i:i + 16], modelo.transcribe(rutas[i:i + 16], context=contexto,
                                                                    language=voz.IDIOMA_TEXTO)):
                textos[clave] = r.text.strip()
        guardar(nombre, textos)
        print(f"{nombre}: listo", flush=True)


def normalizar(texto: str) -> str:
    texto = unicodedata.normalize("NFC", texto.lower())
    texto = re.sub(r"[^\wáéíóúüñ ]+", " ", texto)
    palabras = [VARIANTES.get(p, p) for p in texto.split()]
    return " ".join(palabras)


def distancia(a: str, b: str) -> int:
    previa = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        actual = [i]
        for j, cb in enumerate(b, 1):
            actual.append(min(previa[j] + 1, actual[j - 1] + 1, previa[j - 1] + (ca != cb)))
        previa = actual
    return previa[-1]


def final(texto: str) -> str:
    texto = texto.strip()
    if texto.endswith("?") or texto.startswith("¿"):
        return "?"
    if texto.endswith("!") or texto.startswith("¡"):
        return "!"
    return "."


def comparar() -> None:
    ref = referencias()
    sistemas = {"hoy": originales()}
    for archivo in sorted(SALIDA.glob("*.json")):
        if archivo.stem != "resultado":
            sistemas[archivo.stem] = json.loads(archivo.read_text(encoding="utf-8"))

    resultado = {}
    for nombre, textos in sistemas.items():
        errores = caracteres = signos = 0
        corregidos = [0, 0]
        for clave, verdad in ref.items():
            v, h = normalizar(verdad), normalizar(textos.get(clave, ""))
            e = distancia(v, h)
            errores += e
            caracteres += len(v)
            signos += final(verdad) == final(textos.get(clave, ""))
            if normalizar(sistemas["hoy"].get(clave, "")) != v:  # los que el usuario corrigio
                corregidos[0] += e
                corregidos[1] += len(v)
        resultado[nombre] = {"cer": errores / caracteres, "cer_en_los_corregidos": corregidos[0] / corregidos[1],
                             "signo_final": signos / len(ref)}
        print(f"{nombre:18s} CER {100 * errores / caracteres:5.2f} %   en los que el usuario corrigio "
              f"{100 * corregidos[0] / corregidos[1]:5.2f} %   signo final {100 * signos / len(ref):5.1f} %")
    (SALIDA / "resultado.json").write_text(json.dumps(resultado, indent=1), encoding="utf-8")


if __name__ == "__main__":
    if sys.argv[1] != "comparar":
        import gpu
        gpu.ocupar()
    {"whisper": con_whisper, "qwen": con_qwen, "comparar": comparar}[sys.argv[1]]()
