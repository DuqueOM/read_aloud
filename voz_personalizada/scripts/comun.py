"""Lo que comparten todos los pasos: la carpeta de trabajo y su configuracion.

Cada voz vive en su propia carpeta de trabajo, fuera del repositorio, con un
archivo voz.toml que dice como se llama, en que idioma habla y donde estan los
videos. Ahi quedan tambien los datos, los modelos y los entornos, que pesan
decenas de gigas.

Los pasos buscan esa carpeta en la variable de entorno VOZ_TRABAJO y, si no
esta, en la carpeta desde la que se los llama.
"""

import os
import re
import tomllib
from pathlib import Path


def _carpeta_de_trabajo() -> Path:
    for candidata in (os.environ.get("VOZ_TRABAJO"), os.getcwd()):
        if candidata and (Path(candidata) / "voz.toml").exists():
            return Path(candidata).resolve()
    raise SystemExit(
        "No encuentro voz.toml. Corre los pasos desde la carpeta de trabajo de la voz, "
        "o define la variable VOZ_TRABAJO con su ruta."
    )


TRABAJO = _carpeta_de_trabajo()
CONFIG = tomllib.loads((TRABAJO / "voz.toml").read_text(encoding="utf-8"))
# Los pasos que lanzan a otros, como lote.py, les pasan la carpeta asi.
os.environ.setdefault("VOZ_TRABAJO", str(TRABAJO))

NOMBRE = CONFIG["nombre"]
IDIOMA = CONFIG.get("idioma", "es")
ORIGEN = Path(CONFIG["origen"])
PATRON_EPISODIO = CONFIG.get("patron_episodio", r"(\d+)")

DATOS = TRABAJO / "datos"
MODELOS = TRABAJO / "modelos"
HERRAMIENTAS = TRABAJO / "herramientas"
REFERENCIAS = TRABAJO / "referencias"

# Alineadores wav2vec2 entrenados por idioma. Para otro idioma, se elige uno en
# Hugging Face y se pone en voz.toml como "alineador".
_ALINEADORES = {
    "es": "jonatasgrosman/wav2vec2-large-xlsr-53-spanish",
    "en": "jonatasgrosman/wav2vec2-large-xlsr-53-english",
    "pt": "jonatasgrosman/wav2vec2-large-xlsr-53-portuguese",
    "fr": "jonatasgrosman/wav2vec2-large-xlsr-53-french",
    "it": "jonatasgrosman/wav2vec2-large-xlsr-53-italian",
    "de": "jonatasgrosman/wav2vec2-large-xlsr-53-german",
}
ALINEADOR = CONFIG.get("alineador") or _ALINEADORES.get(IDIOMA)

EXTENSIONES = {".mp4", ".mkv", ".avi", ".mov", ".webm", ".m4a", ".mp3", ".wav", ".flac", ".ogg", ".aac"}


def grabaciones() -> dict:
    """Grabaciones de la carpeta de origen, por identificador: ep01, ep02...

    El numero sale del nombre del archivo con patron_episodio, que por defecto
    toma el primer numero. Asi el identificador no cambia si se agregan
    archivos, y los clips y las decisiones de la revision siguen valiendo.
    """
    encontradas = {}
    for archivo in sorted(ORIGEN.iterdir()):
        if archivo.suffix.lower() not in EXTENSIONES:
            continue
        numero = re.search(PATRON_EPISODIO, archivo.name, re.IGNORECASE)
        if not numero:
            print(f"sin numero, se omite: {archivo.name}")
            continue
        episodio = f"ep{int(numero.group(1)):02d}"
        if episodio in encontradas:
            raise SystemExit(f"Dos archivos dan {episodio}: {encontradas[episodio].name} y {archivo.name}. "
                             "Ajusta patron_episodio en voz.toml.")
        encontradas[episodio] = archivo
    return dict(sorted(encontradas.items()))


# audio-separator y Whisper llaman a "ffmpeg" por su nombre. Se usa la copia
# que el instalador deja en la carpeta de trabajo, para no instalar nada fuera.
os.environ["PATH"] = str(HERRAMIENTAS) + os.pathsep + os.environ["PATH"]
