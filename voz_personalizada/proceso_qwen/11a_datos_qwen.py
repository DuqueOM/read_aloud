"""Prepara el conjunto de la voz para afinar Qwen3-TTS.

Cada clip del conjunto final se convierte en los codigos de audio de Qwen3-TTS
(12.5 por segundo, 16 capas) con su texto. Las 10 frases de la comparacion con
la voz real quedan fuera del entrenamiento: sirven para medir, sin trampa,
como dice el modelo frases que no vio.

Si existe datos/11_qwen/correcciones.json, con {archivo: texto}, sus textos
reemplazan a los de la transcripcion automatica.

Corre en el entorno de Qwen:
    .venv_qwen/Scripts/python.exe scripts/11a_datos_qwen.py
"""

import json
import os
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("HF_HOME", str(RAIZ / "modelos" / "hf"))

import librosa
import soundfile as sf
from qwen_tts import Qwen3TTSTokenizer

import voz

CONJUNTO = RAIZ / "datos" / "08_final" / f"{voz.NOMBRE}_{voz.IDIOMA}"
CORTES = RAIZ / "datos" / "04_cortes"
SALIDA = RAIZ / "datos" / "11_qwen"
MUESTRA = CONJUNTO / "ep03_083269.wav"
LOTE = 16


def main() -> None:
    SALIDA.mkdir(parents=True, exist_ok=True)
    textos = {c["archivo"]: c["texto"] for indice in sorted(CORTES.glob("ep*/indice.json"))
              for c in json.loads(indice.read_text(encoding="utf-8"))["clips"]}
    correcciones = SALIDA / "correcciones.json"
    if correcciones.exists():
        cambios = json.loads(correcciones.read_text(encoding="utf-8"))
        textos.update(cambios)
        print(f"{len(cambios)} textos corregidos a mano")
    prueba = {f["archivo"] for f in json.loads((RAIZ / "datos" / "09_comparar" / "frases.json")
                                                .read_text(encoding="utf-8"))}

    # La huella de voz de Qwen se calcula a 24 kHz.
    referencia = SALIDA / "referencia.wav"
    sf.write(referencia, librosa.load(MUESTRA, sr=24000, mono=True)[0], 24000, subtype="PCM_24")

    tokenizador = Qwen3TTSTokenizer.from_pretrained("Qwen/Qwen3-TTS-Tokenizer-12Hz", device_map="cuda:0")
    archivos = sorted(CONJUNTO.glob("*.wav"))
    grupos = {"entrenamiento": [a for a in archivos if a.name not in prueba],
              "validacion": [a for a in archivos if a.name in prueba]}
    for grupo, lista in grupos.items():
        lineas = []
        for inicio in range(0, len(lista), LOTE):
            lote = lista[inicio:inicio + LOTE]
            codigos = tokenizador.encode([str(a) for a in lote]).audio_codes
            for archivo, codigo in zip(lote, codigos):
                lineas.append(json.dumps({
                    "audio": str(archivo), "text": textos[archivo.name], "language": "spanish",
                    "ref_audio": str(referencia), "audio_codes": codigo.cpu().tolist(),
                }, ensure_ascii=False))
        (SALIDA / f"{grupo}.jsonl").write_text("\n".join(lineas) + "\n", encoding="utf-8")
        print(f"{grupo}: {len(lineas)} clips")


if __name__ == "__main__":
    main()
