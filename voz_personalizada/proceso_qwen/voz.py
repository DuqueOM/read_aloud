"""Lo que es de cada voz, leido de voz.toml en la carpeta de trabajo.

Los scripts se copian a <trabajo>\\scripts y se corren desde <trabajo>: la
carpeta de trabajo es la padre de la de este archivo, y voz.toml esta ahi
(instalar.ps1 lo crea a partir de voz_personalizada\\voz.ejemplo.toml). Todo
lo que cambia de una voz a otra sale de aqui: como se llama, en que idioma
habla, donde estan las grabaciones, los nombres propios que guian a los
transcriptores y los videos repetidos.
"""

import tomllib
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
_ARCHIVO = RAIZ / "voz.toml"
if not _ARCHIVO.exists():
    raise SystemExit(
        f"No encuentro {_ARCHIVO}. Copia voz_personalizada\\voz.ejemplo.toml ahi y editalo (instalar.ps1 lo hace solo)."
    )
CONFIG = tomllib.loads(_ARCHIVO.read_text(encoding="utf-8"))

# El nombre es el hablante en el modelo de Qwen3-TTS y va en los nombres de las
# versiones (qwen_<nombre>_e02) y de lo que guardan las paginas en el
# navegador. El titulo es como la llaman las paginas.
NOMBRE = CONFIG["nombre"]
TITULO = CONFIG.get("titulo", NOMBRE)

# Codigo de dos letras para Whisper; Qwen3-TTS y Qwen3-ASR usan el nombre del
# idioma en ingles. Qwen3-TTS habla estos diez.
IDIOMA = CONFIG.get("idioma", "es")
_IDIOMAS_QWEN = {
    "es": "spanish",
    "en": "english",
    "pt": "portuguese",
    "fr": "french",
    "it": "italian",
    "de": "german",
    "ru": "russian",
    "ja": "japanese",
    "ko": "korean",
    "zh": "chinese",
}
if IDIOMA not in _IDIOMAS_QWEN:
    raise SystemExit(f"Qwen3-TTS no habla el idioma '{IDIOMA}' de voz.toml. Habla: {', '.join(_IDIOMAS_QWEN)}.")
IDIOMA_QWEN = _IDIOMAS_QWEN[IDIOMA]  # "spanish": la marca de idioma del modelo al entrenar
IDIOMA_TEXTO = IDIOMA_QWEN.capitalize()  # "Spanish": al generar y al transcribir con Qwen3-ASR
# Como lo nombran las paginas.
IDIOMA_NOMBRE = {
    "es": "Español",
    "en": "Inglés",
    "pt": "Portugués",
    "fr": "Francés",
    "it": "Italiano",
    "de": "Alemán",
    "ru": "Ruso",
    "ja": "Japonés",
    "ko": "Coreano",
    "zh": "Chino",
}[IDIOMA]

# Alineador wav2vec2 del idioma (03b_alinear.py).
_ALINEADORES = {
    "es": "jonatasgrosman/wav2vec2-large-xlsr-53-spanish",
    "en": "jonatasgrosman/wav2vec2-large-xlsr-53-english",
    "pt": "jonatasgrosman/wav2vec2-large-xlsr-53-portuguese",
    "fr": "jonatasgrosman/wav2vec2-large-xlsr-53-french",
    "it": "jonatasgrosman/wav2vec2-large-xlsr-53-italian",
    "de": "jonatasgrosman/wav2vec2-large-xlsr-53-german",
}
ALINEADOR = CONFIG.get("alineador") or _ALINEADORES.get(IDIOMA)

# Carpetas donde caen las grabaciones (lote.py). "origen" es la de los pasos
# de la primera version; "origenes", una lista, si son varias.
ORIGENES = [Path(p) for p in (CONFIG.get("origenes") or [CONFIG["origen"]])]
# Solo los archivos cuyo nombre contenga esto, sin distinguir mayusculas: para
# no tomar otros videos de una carpeta como Descargas. Vacio, todos.
FILTRO_NOMBRE = CONFIG.get("filtro_nombre", "")
# Expresion regular que saca de cada nombre de archivo su numero. Sin ella se
# prueba "Episode 22", "Episodio 22", "capitulo 22", un numero al principio y,
# por ultimo, el primer numero del nombre.
PATRON_EPISODIO = CONFIG.get("patron_episodio")

# Para los transcriptores (27_transcribir_clips.py): de que es la grabacion y
# los nombres propios como deben escribirse. Y las variantes de un mismo
# nombre que no cuentan como lecturas distintas.
CONTEXTO = CONFIG.get("contexto", "")
VARIANTES = {k.lower(): v.lower() for k, v in CONFIG.get("variantes", {}).items()}

# Videos que resultaron ser otra copia de uno ya procesado: copia = original.
DUPLICADOS = CONFIG.get("duplicados", {})

# Minutos de voz que se quedan para entrenar, los de mejor calidad.
MINUTOS_FINALES = float(CONFIG.get("minutos_finales", 60))

# La carpeta del repositorio de Read Aloud: de ahi salen qwen_rapido y la
# preparacion del texto de la app.
_LECTOR = CONFIG.get("lector")


def lector() -> Path:
    if not _LECTOR or not (Path(_LECTOR) / "lib" / "qwen_rapido.py").exists():
        raise SystemExit("Falta 'lector' en voz.toml: la carpeta del repositorio de Read Aloud.")
    return Path(_LECTOR)
