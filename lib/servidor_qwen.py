"""Proceso residente de Qwen3-TTS para Read Aloud, con una voz afinada.

Habla el mismo protocolo que Piper con --json-input, para que el proceso
residente lo trate igual: lee una orden por linea en la entrada y escribe la
ruta del WAV cuando termina. Una linea puede traer tambien una lista de
ordenes; entonces se generan juntas, que en la tarjeta grafica cuesta casi lo
mismo que una sola, y se escribe una ruta por orden, en el mismo orden.

    {"text": "Hola.", "output_file": "C:\\...\\ra_1_0000.wav", "lang": "es", "grupo": "1-0"}

"grupo" es opcional: el nombre con que Read Aloud anota ese grupo en su
registro de eventos. A la primera ruta de cada grupo se le agregan, tras un
tabulador, las medidas del grupo en JSON (cuanto tardo, el audio que salio, la
carga del procesador y de la tarjeta). Piper no las da; Read Aloud acepta las
dos formas.

La voz es una carpeta con lo que deja el entrenamiento (ajuste.json,
voz.safetensors y las capas LoRA de la epoca elegida, en lora.safetensors).
El modelo base se toma de la cache de Hugging Face que se indique.

El modelo ocupa unos 5 GB de memoria de video. El proceso se queda abierto,
para que ninguna lectura espere a que cargue, hasta que otro programa
necesite la tarjeta grafica o pasen --inactivo minutos sin ordenes (0 es
nunca). Entonces termina y la libera. Read Aloud lo vuelve a abrir en cuanto
la tarjeta queda libre, o con la siguiente lectura si termino por --inactivo.

Todo lo que no es el protocolo (avisos de las librerias, errores) va a
--registro: si llegara a la salida, Read Aloud lo leeria como una ruta.
"""

import argparse
import atexit
import ctypes
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

# La salida del protocolo se separa antes de importar nada: algunas librerias
# escriben avisos en la salida estandar al cargarse.
protocolo = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)

argumentos = argparse.ArgumentParser()
argumentos.add_argument("--voz", required=True, help="carpeta de la voz afinada")
argumentos.add_argument("--hf-home", required=True, help="cache de Hugging Face con el modelo base")
argumentos.add_argument("--registro", required=True)
argumentos.add_argument("--silencio", type=float, default=0.36, help="segundos de silencio al final")
# El tope de 0.3 s se eligio de oido (26 de noviembre de 2026) entre 0.6, 0.45
# y 0.3, con ocho frases en espanol e ingles de la voz propia.
argumentos.add_argument(
    "--pausa-maxima",
    type=float,
    default=0.3,
    help="segundos que puede durar, como mucho, un silencio dentro de la frase; 0 los deja como salen",
)
argumentos.add_argument("--inactivo", type=float, default=0.0, help="minutos sin ordenes antes de terminar; 0 es nunca")
argumentos.add_argument("--lote", type=int, default=4, help="frases que Read Aloud puede mandar juntas")
argumentos.add_argument("--marca", default="", help="archivo que otro paso deja mientras usa la tarjeta grafica")
argumentos.add_argument(
    "--listo", default="", help="archivo que se crea cuando el modelo ya esta cargado y se borra al terminar"
)
opciones = argumentos.parse_args()

registro = open(opciones.registro, "a", encoding="utf-8", buffering=1)
os.dup2(registro.fileno(), sys.stdout.fileno())
os.dup2(registro.fileno(), sys.stderr.fileno())
sys.stdout = sys.stderr = registro
os.environ["HF_HOME"] = opciones.hf_home
os.environ["HF_HUB_OFFLINE"] = "1"

import numpy as np
import soundfile as sf
import torch
from huggingface_hub import snapshot_download
from peft import LoraConfig, inject_adapter_in_model, set_peft_model_state_dict
from peft.tuners.lora import LoraLayer
from qwen_tts import Qwen3TTSModel
from safetensors.torch import load_file

sys.path.insert(0, str(Path(__file__).parent))
import qwen_rapido

# El nombre es solo la etiqueta con que se pide la voz al generar: el modelo
# no lo guarda, la voz es la huella de voz.safetensors en el hueco ID_VOZ.
VOZ = "propia"
ID_VOZ = 3000
IDIOMAS = {"es": "Spanish", "en": "English"}
NIVEL_DB = -19.0  # el de las voces de Piper que usa Read Aloud
PICO_DB = -1.0
UMBRAL_SILENCIO_DB = -45.0
MARGEN_S = 0.05
# Al acortar un silencio interno, las dos partes se funden en este tiempo para
# que el corte no haga clic.
FUNDIDO_S = 0.005
# Una frase que dura mucho mas o mucho menos de lo esperable por su largo es
# casi siempre un fallo del muestreo (repite, se queda muda o corta): se
# repite una vez. 12.5 codigos por segundo.
SEGUNDOS_POR_LETRA = 0.065
CODIGOS_POR_SEGUNDO = 12.5


# Cargar el modelo tarda unos 20 s (16 desde que las librerias estan
# importadas), y hasta un minuto si el disco no las tiene en la cache; esa
# espera se nota al pedir una lectura.
# Por eso el proceso se queda abierto mientras nadie mas necesite la tarjeta:
# cada REVISION_S mira cuanta memoria usan los demas programas, y si despues
# de un rato sin leer usan CEDER_SI_OTROS_GB mas que al cargar (o que lo menos
# que se les haya visto usar despues), termina y se la deja. La lectura siguiente lo vuelve a abrir. Se compara con lo que
# habia al cargar, y no con cero, porque Windows y el navegador siempre
# ocupan algo, y porque en Windows la memoria que informa CUDA no coincide
# exactamente con la de nvidia-smi; las diferencias, en cambio, si.
REVISION_S = 10
QUIETO_ANTES_DE_CEDER_S = 60
CEDER_SI_OTROS_GB = 1.5
# Con que codigo termina, para que Read Aloud sepa si volver a abrirlo cuando
# la tarjeta quede libre (si cedio) o esperar a la siguiente lectura (si fue
# por --inactivo).
SALIDA_ENTRADA_CERRADA = 0
SALIDA_INACTIVO = 3
SALIDA_MARCA = 4
SALIDA_OTRO_PROGRAMA = 5


def tarjeta_pedida() -> bool:
    """Si un paso pesado de la carpeta de trabajo dejo su marca (scripts/gpu.py)
    y ese proceso sigue vivo. Entonces Read Aloud lee con Piper y este proceso
    termina para dejarle la tarjeta entera."""
    if not opciones.marca or not os.path.exists(opciones.marca):
        return False
    try:
        pid = int(Path(opciones.marca).read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return False
    proceso = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not proceso:
        return False
    codigo = ctypes.c_ulong()
    ctypes.windll.kernel32.GetExitCodeProcess(proceso, ctypes.byref(codigo))
    ctypes.windll.kernel32.CloseHandle(proceso)
    return codigo.value == 259  # STILL_ACTIVE


def memoria_de_otros_gb() -> float:
    libre, total = torch.cuda.mem_get_info()
    return (total - libre - torch.cuda.memory_reserved()) / 1e9


# Medidas de cada grupo para el registro de eventos de Read Aloud: con ellas se
# ve despues si un grupo lento coincidio con el procesador ocupado, con otro
# programa en la tarjeta o con la tarjeta a pocos MHz (un portatil con bateria
# o en modo de ahorro).


class _Filetime(ctypes.Structure):
    _fields_ = [("bajo", ctypes.c_uint32), ("alto", ctypes.c_uint32)]


def tiempos_cpu() -> tuple[int, int] | None:
    """(inactivo, total) del procesador desde que arranco Windows, sumando
    todos los nucleos, en unidades de 100 ns."""
    inactivo, nucleo, usuario = _Filetime(), _Filetime(), _Filetime()
    if not ctypes.windll.kernel32.GetSystemTimes(ctypes.byref(inactivo), ctypes.byref(nucleo), ctypes.byref(usuario)):
        return None

    def valor(f: _Filetime) -> int:
        return (f.alto << 32) | f.bajo

    # El tiempo del nucleo ya incluye el inactivo.
    return valor(inactivo), valor(nucleo) + valor(usuario)


def uso_cpu(antes: tuple[int, int] | None, despues: tuple[int, int] | None) -> float | None:
    """Porcentaje del procesador ocupado entre dos lecturas de tiempos_cpu."""
    if not antes or not despues:
        return None
    total = despues[1] - antes[1]
    if total <= 0:
        return None
    return round(100 * (1 - (despues[0] - antes[0]) / total), 1)


NVIDIA_SMI = shutil.which("nvidia-smi")
CAMPOS_TARJETA = ["uso_pct", "temp_c", "mhz", "w", "pstate"]


def leer_tarjeta() -> dict | None:
    """Uso, temperatura, reloj, consumo y estado de energia de la tarjeta, de
    nvidia-smi. Tarda unos 100 ms: se llama desde otro hilo."""
    if not NVIDIA_SMI:
        return None
    try:
        salida = subprocess.run(
            [
                NVIDIA_SMI,
                "--query-gpu=utilization.gpu,temperature.gpu,clocks.sm,power.draw,pstate",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=3,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    lineas = salida.strip().splitlines()
    if not lineas:
        return None
    datos = {}
    for campo, valor in zip(CAMPOS_TARJETA, (v.strip() for v in lineas[0].split(","))):
        if campo == "pstate":
            datos[campo] = valor
            continue
        try:
            datos[campo] = float(valor)
        except ValueError:
            datos[campo] = None
    return datos


class MuestraTarjeta:
    """Lee la tarjeta una vez, un poco despues de empezar el grupo, cuando ya
    esta generando; sin frenar la generacion."""

    RETRASO_S = 0.8

    def __init__(self) -> None:
        self.datos: dict | None = None
        self._hilo = threading.Thread(target=self._medir, daemon=True)
        self._listo = threading.Event()
        self._hilo.start()

    def _medir(self) -> None:
        if not self._listo.wait(self.RETRASO_S):
            self.datos = leer_tarjeta()

    def terminar(self) -> dict | None:
        # Un grupo que termino antes de la muestra no espera por ella.
        self._listo.set()
        self._hilo.join(timeout=0.3)
        return self.datos


def log(mensaje: str) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S"), mensaje, flush=True)


def fundir(modulo: torch.nn.Module) -> None:
    """Suma cada LoRA a su capa y deja la capa original en su lugar."""
    for nombre, hijo in list(modulo.named_children()):
        if isinstance(hijo, LoraLayer):
            hijo.merge()
            setattr(modulo, nombre, hijo.base_layer)
        else:
            fundir(hijo)


def cargar(carpeta: Path):
    ajuste = json.loads((carpeta / "ajuste.json").read_text(encoding="utf-8"))
    # Desde la carpeta local de la cache: con el nombre del modelo, el
    # tokenizador consulta Hugging Face aunque ya tenga todo descargado.
    base = snapshot_download(ajuste["modelo_base"], local_files_only=True)
    qwen = Qwen3TTSModel.from_pretrained(base, device_map="cuda:0", dtype=torch.bfloat16, attn_implementation="sdpa")
    modelo = qwen.model
    inject_adapter_in_model(
        LoraConfig(
            r=ajuste["r"], lora_alpha=ajuste["lora_alpha"], lora_dropout=0.0, target_modules=ajuste["target_modules"]
        ),
        modelo.talker,
    )
    estado = load_file(carpeta / "lora.safetensors")
    set_peft_model_state_dict(modelo.talker, {k: v.to(modelo.device) for k, v in estado.items()})
    modelo.talker.eval()
    # Fundir las capas LoRA en los pesos hace cada paso una multiplicacion en
    # vez de tres. Redondea a bf16, pero la prediccion casi no cambia: se midio
    # una divergencia KL media de 0.002 en la primera prediccion de 10 frases,
    # con el mismo codigo mas probable en todas.
    fundir(modelo.talker)

    # Lo mismo que escribe la receta oficial de Qwen en un modelo afinado.
    voz = load_file(carpeta / "voz.safetensors")["voz"]
    with torch.no_grad():
        modelo.talker.model.codec_embedding.weight[ID_VOZ] = voz[0].to(modelo.dtype).to(modelo.device)
    modelo.config.tts_model_type = modelo.tts_model_type = "custom_voice"
    modelo.config.talker_config.spk_id = {VOZ: ID_VOZ}
    modelo.config.talker_config.spk_is_dialect = {VOZ: False}
    modelo.supported_speakers = modelo.config.talker_config.spk_id.keys()

    qwen_rapido.activar(modelo)
    return qwen


def acortar_pausas(audio: np.ndarray, niveles: np.ndarray, tasa: int, tope: float) -> np.ndarray:
    """Deja en `tope` segundos cada silencio interno que dure mas.

    Qwen a veces calla casi un segundo a mitad de frase, mas que la pausa entre
    dos frases. Se quita el centro del silencio y a cada lado queda la mitad
    del tope, nunca menos que MARGEN_S: el silencio se mide con ventanas de
    10 ms, asi que lo que queda pegado a la voz (una s que se apaga, una
    respiracion) no se toca. Solo cuentan los silencios con voz a los dos
    lados: los extremos ya vienen recortados."""
    tope = max(tope, 2 * MARGEN_S)
    conservar = int(tope * tasa)
    izquierda = conservar // 2
    fundido = int(FUNDIDO_S * tasa)
    rampa = np.linspace(1.0, 0.0, fundido, dtype=np.float32)

    callado = np.concatenate([[False], niveles <= UMBRAL_SILENCIO_DB, [False]])
    bordes = np.diff(callado.astype(np.int8))
    partes = []
    desde = 0
    for inicio, fin in zip(np.flatnonzero(bordes == 1), np.flatnonzero(bordes == -1)):
        if inicio == 0 or fin >= len(audio) or fin - inicio <= conservar:
            continue
        corte = inicio + izquierda
        sigue = fin - (conservar - izquierda)
        partes.append(audio[desde:corte])
        partes.append(audio[corte : corte + fundido] * rampa + audio[sigue : sigue + fundido] * rampa[::-1])
        desde = sigue + fundido
    if not partes:
        return audio
    partes.append(audio[desde:])
    return np.concatenate(partes)


def pulir(audio: np.ndarray, tasa: int) -> tuple[np.ndarray, float]:
    """Quita el silencio de los extremos, acorta los internos largos (con
    --pausa-maxima), iguala el volumen y agrega la pausa final. Devuelve el
    audio y los segundos que se quitaron de los silencios internos."""
    audio = np.asarray(audio, dtype=np.float32)
    cuadro = int(0.01 * tasa)
    niveles = 20 * np.log10(np.sqrt(np.convolve(audio**2, np.ones(cuadro) / cuadro, mode="same")) + 1e-9)
    con_voz = np.where(niveles > UMBRAL_SILENCIO_DB)[0]
    recortado = 0.0
    if con_voz.size:
        margen = int(MARGEN_S * tasa)
        desde, hasta = max(0, con_voz[0] - margen), con_voz[-1] + margen
        audio, niveles = audio[desde:hasta], niveles[desde:hasta]
        if opciones.pausa_maxima > 0:
            antes = len(audio)
            audio = acortar_pausas(audio, niveles, tasa, opciones.pausa_maxima)
            recortado = (antes - len(audio)) / tasa
        habla = audio[np.abs(audio) > 10 ** (UMBRAL_SILENCIO_DB / 20)]
        audio = audio * (10 ** (NIVEL_DB / 20) / (np.sqrt(np.mean(habla**2)) + 1e-9))
        pico = np.max(np.abs(audio))
        if pico > 10 ** (PICO_DB / 20):
            audio = audio * (10 ** (PICO_DB / 20) / pico)
    return np.concatenate([audio, np.zeros(int(opciones.silencio * tasa), dtype=np.float32)]), recortado


def razonable(texto: str, segundos: float) -> bool:
    esperado = max(0.6, len(texto) * SEGUNDOS_POR_LETRA)
    return 0.35 * esperado <= segundos <= 2.5 * esperado + 1.0


def generar(qwen, ordenes: list[dict]) -> dict:
    """Genera el grupo y escribe un WAV por orden. Devuelve los segundos de audio
    escritos (lo que dura al sonar, con la pausa final incluida), cuantas
    frases hubo que repetir y los segundos quitados de los silencios internos."""
    textos = [o["text"] for o in ordenes]
    idiomas = [IDIOMAS.get(o.get("lang", "es"), "Spanish") for o in ordenes]
    tope = int(CODIGOS_POR_SEGUNDO * (2.5 * max(len(t) for t in textos) * SEGUNDOS_POR_LETRA + 3))
    pendientes = list(range(len(ordenes)))
    segundos = 0.0
    repetidas = 0
    recortado = 0.0
    for intento in range(2):
        wavs, tasa = qwen.generate_custom_voice(
            text=[textos[i] for i in pendientes],
            language=[idiomas[i] for i in pendientes],
            speaker=[VOZ] * len(pendientes),
            non_streaming_mode=True,
            max_new_tokens=tope,
        )
        repetir = []
        for i, wav in zip(pendientes, wavs):
            if intento == 0 and not razonable(textos[i], len(wav) / tasa):
                log(f"duracion rara ({len(wav) / tasa:.1f} s), se repite: {textos[i]!r}")
                repetir.append(i)
                continue
            pulido, quitado = pulir(wav, tasa)
            sf.write(ordenes[i]["output_file"], pulido, tasa, subtype="PCM_16")
            segundos += len(pulido) / tasa
            recortado += quitado
        repetidas += len(repetir)
        pendientes = repetir
        if not pendientes:
            break
    return {"audio": segundos, "repetidas": repetidas, "recortado": recortado}


def medir_grupo(qwen, ordenes: list[dict]) -> dict:
    """Genera el grupo, lo anota en el registro y devuelve sus medidas."""
    grupo = ordenes[0].get("grupo") if ordenes else None
    otros_antes = memoria_de_otros_gb()
    cpu_antes = tiempos_cpu()
    muestra = MuestraTarjeta()
    inicio = time.perf_counter()
    try:
        hecho = generar(qwen, ordenes)
    finally:
        gasto = time.perf_counter() - inicio
        tarjeta = muestra.terminar()
    cpu = uso_cpu(cpu_antes, tiempos_cpu())
    otros = memoria_de_otros_gb()
    audio = hecho["audio"]
    # Factor: segundos de generacion por segundo de audio. Por encima de 1, el
    # grupo tarda mas en generarse que en sonar.
    factor = gasto / audio if audio > 0 else None

    # La primera parte de la linea no cambia: la lee tools\resumen_esperas.ps1.
    texto_factor = f"{factor:.2f}" if factor else "-"
    partes = [f"{len(ordenes)} frase(s) en {gasto:.1f} s, {audio:.1f} s de audio, factor {texto_factor}"]
    if grupo:
        partes.append(f"grupo {grupo}")
    if cpu is not None:
        partes.append(f"procesador {cpu:.0f} %")
    partes.append(f"tarjeta de otros {otros:.1f} GB")
    if tarjeta and tarjeta.get("uso_pct") is not None:
        partes.append(f"tarjeta {tarjeta['uso_pct']:.0f} % a {tarjeta.get('mhz') or 0:.0f} MHz")
    log(", ".join(partes))

    return {
        "grupo": grupo,
        "s": round(gasto, 3),
        "audio_s": round(audio, 3),
        "factor": round(factor, 3) if factor else None,
        "repetidas": hecho["repetidas"],
        "recorte_s": round(hecho["recortado"], 3),
        "cpu_pct": cpu,
        "otros_gb": round(otros_antes, 2),
        "otros_gb_despues": round(otros, 2),
        "tarjeta": tarjeta,
    }


def leer_entrada(cola: queue.Queue) -> None:
    for linea in open(sys.stdin.fileno(), encoding="utf-8", closefd=False):
        if linea.strip():
            cola.put(linea)
    cola.put(None)


def marcar_listo() -> None:
    """Avisa a Read Aloud de que ya puede mandar ordenes sin esperar la carga:
    mientras este archivo no exista, lee con Piper. Se borra al terminar."""
    if not opciones.listo:
        return
    Path(opciones.listo).write_text(str(os.getpid()), encoding="ascii")
    atexit.register(lambda: Path(opciones.listo).unlink(missing_ok=True))


def main() -> int:
    inicio = time.perf_counter()
    qwen = cargar(Path(opciones.voz))
    log(f"pesos listos en {time.perf_counter() - inicio:.1f} s")
    # El modelo chico se graba una vez por tamano de grupo; se hace aqui para
    # que ninguna lectura pague esa espera.
    for lote in sorted({1, min(2, opciones.lote), opciones.lote}):
        qwen.generate_custom_voice(
            text=["Hola."] * lote,
            language=["Spanish"] * lote,
            speaker=[VOZ] * lote,
            non_streaming_mode=True,
            max_new_tokens=40,
        )
    log(f"modelo cargado en {time.perf_counter() - inicio:.1f} s")
    marcar_listo()
    otros_al_cargar = memoria_de_otros_gb()
    log(f"memoria de la tarjeta en uso por otros al cargar: {otros_al_cargar:.1f} GB")

    cola: queue.Queue = queue.Queue()
    threading.Thread(target=leer_entrada, args=(cola,), daemon=True).start()
    ultima = time.monotonic()
    while True:
        try:
            linea = cola.get(timeout=REVISION_S)
        except queue.Empty:
            quieto = time.monotonic() - ultima
            if opciones.inactivo > 0 and quieto >= opciones.inactivo * 60:
                log("sin ordenes, termino para liberar la tarjeta grafica")
                return SALIDA_INACTIVO
            if tarjeta_pedida():
                log("otro paso marco la tarjeta grafica como ocupada: termino para dejarsela")
                return SALIDA_MARCA
            # Si al cargar ya habia otro programa usando la tarjeta, la base
            # baja cuando la suelta: asi se cede tambien la proxima vez.
            ahora = memoria_de_otros_gb()
            otros_al_cargar = min(otros_al_cargar, ahora)
            otros = ahora - otros_al_cargar
            if quieto >= QUIETO_ANTES_DE_CEDER_S and otros >= CEDER_SI_OTROS_GB:
                log(f"otro programa usa {otros:.1f} GB mas de la tarjeta grafica: termino para dejarsela")
                return SALIDA_OTRO_PROGRAMA
            continue
        if linea is None:
            return SALIDA_ENTRADA_CERRADA
        ultima = time.monotonic()
        ordenes = []
        medidas: dict = {}
        try:
            # Con la consola de Windows en UTF-8, quien escribe en la entrada
            # puede anteponer una marca BOM a la primera linea.
            datos = json.loads(linea.lstrip("﻿"))
            ordenes = datos if isinstance(datos, list) else [datos]
            medidas = medir_grupo(qwen, ordenes)
        except Exception as error:  # una orden mala no debe tumbar el proceso
            log(f"error: {error!r}")
            medidas["error"] = repr(error)
        # Una ruta por orden, como Piper, aunque haya fallado: Read Aloud
        # comprueba que el WAV exista. La primera lleva las medidas del grupo.
        for n, orden in enumerate(ordenes):
            ruta = orden.get("output_file", "")
            if n == 0 and medidas:
                ruta += "\t" + json.dumps(medidas, ensure_ascii=True)
            protocolo.write(ruta + "\n")
        protocolo.flush()


if __name__ == "__main__":
    sys.exit(main())
