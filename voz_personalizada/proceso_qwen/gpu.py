"""Marca la tarjeta grafica como ocupada mientras corre un paso pesado.

Read Aloud lee con la voz de Qwen3-TTS, que vive en esta carpeta de trabajo y
ocupa unos 5 GB de la tarjeta. Si un paso del proceso (Whisper, la
separacion, WavLM, un entrenamiento) corre a la vez, los dos se reparten 8 GB
y Windows pasa memoria a la RAM: en una prueba, la voz tardo 7 minutos en
cargar y Whisper termino con un error de CUDA.

Con la marca puesta, Read Aloud lee con Piper y el servidor de Qwen se
cierra para dejar la tarjeta; al quitarla, la voz de Qwen vuelve sola. La
marca es el archivo gpu_ocupada en la carpeta de trabajo, con el numero de
proceso dentro: si el proceso muere sin quitarla, Read Aloud la ignora.

Uso:
    import gpu
    gpu.ocupar()   # al empezar; se quita sola al terminar el proceso
    gpu.liberar()  # antes, si el proceso sigue pero ya no usa la tarjeta
"""

import atexit
import os
import subprocess
import time
from pathlib import Path

MARCA = Path(__file__).resolve().parent.parent / "gpu_ocupada"


def liberar() -> None:
    try:
        if MARCA.read_text(encoding="ascii").strip() == str(os.getpid()):
            MARCA.unlink()
    except OSError:
        pass


def libre_mib() -> int:
    try:
        salida = subprocess.run(["nvidia-smi", "--query-gpu=memory.free", "--format=csv,noheader,nounits"],
                                capture_output=True, text=True, timeout=10).stdout
        return max(int(x) for x in salida.split())
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0


def vivo(pid: int) -> bool:
    import ctypes
    proceso = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not proceso:
        return False
    codigo = ctypes.c_ulong()
    ctypes.windll.kernel32.GetExitCodeProcess(proceso, ctypes.byref(codigo))
    ctypes.windll.kernel32.CloseHandle(proceso)
    return codigo.value == 259  # STILL_ACTIVE


def ocupar(necesita_mib: int = 6000, espera_s: float = 60.0) -> None:
    """Pone la marca y espera a que el servidor de Qwen suelte la tarjeta.

    Si ya la puso otro proceso vivo (lote.py, que lanza este paso), se deja la
    suya: asi no se quita al terminar este paso mientras el lote sigue."""
    try:
        dueno = int(MARCA.read_text(encoding="ascii").strip())
        if dueno == os.getpid() or vivo(dueno):
            return
    except (OSError, ValueError):
        pass
    MARCA.write_text(str(os.getpid()), encoding="ascii")
    atexit.register(liberar)
    limite = time.monotonic() + espera_s
    while libre_mib() < necesita_mib and time.monotonic() < limite:
        time.sleep(2)
