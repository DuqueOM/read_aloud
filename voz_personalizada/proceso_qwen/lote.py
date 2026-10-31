"""Procesa un lote de capitulos nuevos de principio a fin, en paralelo.

Cada capitulo pasa por cinco pasos: extraer el audio, separar la voz,
transcribir, alinear las palabras y calcular quien habla (las huellas de
WavLM de 24_curva_wavlm.py). Todos menos el primero usan la tarjeta, de a uno:
con dos a la vez no caben en sus 8 GB, Windows pasa memoria a la RAM y todo
va mucho mas lento. Whisper corre a media precision (03_transcribir.py), unos
2 minutos por capitulo; en el procesador llego a tardar 174. Un hilo separa
los capitulos uno tras otro y alinea lo ya transcrito; el otro transcribe lo
ya separado, y se turnan la tarjeta. El avance se ve en progreso.html.

Mientras la tarjeta tiene trabajo, el lote deja la marca de gpu.py: Read
Aloud lee con Piper y no le disputa la memoria. Mientras solo espera
descargas, la quita, y la voz de Qwen vuelve.

Mientras trabaja, revisa la carpeta de origen e incorpora los capitulos que
terminen de descargarse. Chrome guarda una descarga en curso como .crdownload y
le pone su nombre final solo al completarla, asi que un .mp4 ya esta entero. El
lote no termina mientras quede alguna descarga en curso.

Uso:
    python scripts/lote.py                origenes por defecto (ORIGENES), capitulos nuevos
    python scripts/lote.py RUTA_ORIGEN
"""

import re
import subprocess
import sys
import threading
import time
from pathlib import Path

import gpu
from progreso_comun import RAIZ, guardar, marcar, nuevo

PYTHON = sys.executable
SCRIPTS = RAIZ / "scripts"
FFMPEG = RAIZ / "herramientas" / "ffmpeg.exe"
AUDIO = RAIZ / "datos" / "01_audio"
VOZ = RAIZ / "datos" / "02_voz"
TRANSCRIPCION = RAIZ / "datos" / "03_transcripcion"

# Donde caen las descargas: la carpeta de los primeros capitulos y Descargas.
ORIGENES = [
    Path(r"\\wsl.localhost\Ubuntu\home\usuario\videos"),
    Path.home() / "Downloads",
]
PASOS = ["extraccion", "separacion", "transcripcion", "alineacion", "curva"]

# Medido en los capitulos 1 a 3, en la tarjeta a media precision.
MINUTOS_TRANSCRIPCION = 2

# Una descarga que no avanza en este tiempo se da por abandonada, para que el
# lote no espere para siempre.
DESCARGA_ABANDONADA_S = 30 * 60


def ejecutar(*argumentos) -> bool:
    resultado = subprocess.run(
        [str(a) for a in argumentos], cwd=str(RAIZ),
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    if resultado.returncode != 0:
        detalle = (resultado.stderr or resultado.stdout).strip().splitlines()[-1:] or ["sin detalle"]
        print(f"fallo {argumentos[1:3]}: {detalle[0]}", flush=True)
    return resultado.returncode == 0


def descargas_en_curso(origenes: list) -> bool:
    ahora = time.time()
    return any(
        ahora - parcial.stat().st_mtime < DESCARGA_ABANDONADA_S
        for origen in origenes for parcial in origen.glob("*.crdownload")
    )


def numero_de_capitulo(nombre: str):
    """El numero de capitulo de un video, o None.

    Los nombres vienen de distintos sitios: "las grabaciones de prueba Episode 22 en
    Espanol...", "...captulo 1 - ..." o "42 las grabaciones de prueba en
    Espanol ... otro sitio". Se exige "la voz de prueba" para no tomar
    otros videos de Descargas."""
    if "propia" not in nombre.lower():
        return None
    numero = (re.search(r"(?:Episode|cap[ií]?tulo)\s*(\d+)", nombre, re.IGNORECASE)
              or re.match(r"\s*(\d+)\D", nombre))
    return int(numero.group(1)) if numero else None


def buscar_capitulos(origenes: list) -> dict:
    """Capitulos de los origenes que aun no estan procesados, por numero."""
    encontrados = {}
    for video in (v for origen in origenes for v in origen.glob("*.mp4")):
        numero = numero_de_capitulo(video.name)
        if numero is None:
            continue
        episodio = f"ep{numero:02d}"
        if not (TRANSCRIPCION / f"{episodio}.json").exists():
            encontrados[episodio] = video
    return dict(sorted(encontrados.items()))


def main() -> None:
    origen = [Path(sys.argv[1])] if len(sys.argv) > 1 else ORIGENES
    capitulos = buscar_capitulos(origen)
    if not capitulos:
        print("No hay capitulos nuevos que procesar.")
        return

    episodios = list(capitulos)
    estado = nuevo(f"Preparación de la voz de prueba · capítulos {episodios[0][2:]} a {episodios[-1][2:]}",
                   episodios, PASOS)
    estado["eventos"].insert(0, [time.strftime("%H:%M"), f"Lote iniciado con {len(episodios)} capítulos"])
    guardar(estado)

    cerrojo = threading.Lock()

    def incorporar_nuevos() -> list:
        """Agrega al lote los capitulos que terminaron de descargarse."""
        nuevos = {e: v for e, v in buscar_capitulos(origen).items() if e not in capitulos}
        if not nuevos:
            return []
        with cerrojo:
            for episodio, video in nuevos.items():
                capitulos[episodio] = video
                episodios.append(episodio)
                estado["orden"].append(episodio)
                estado["episodios"][episodio] = {p: "pendiente" for p in PASOS}
            estado["orden"].sort()
            estado["titulo"] = (f"Preparación de la voz de prueba · capítulos "
                                f"{estado['orden'][0][2:]} a {estado['orden'][-1][2:]}")
        marcar(estado, "calibracion", "pendiente",
               evento=f"Descarga completa, se suman: {', '.join(nuevos)}")
        return sorted(nuevos)

    separados = []          # cola de capitulos listos para transcribir
    transcritos = []        # cola de capitulos listos para alinear
    fin_separacion = threading.Event()
    fin_transcripcion = threading.Event()
    # Separar, transcribir, alinear y calcular la curva usan la tarjeta: uno a
    # la vez, para que ninguno pase memoria a la RAM y todos vayan rapido.
    uso_tarjeta = threading.Lock()
    transcribiendo = threading.Event()

    def tarjeta():
        # Primero extraer y separar todo, que es rapido; la alineacion de lo
        # ya transcrito se intercala entre una separacion y la siguiente.
        pendientes_separar = list(episodios)
        alineados = set()

        while True:
            with cerrojo:
                listos_alinear = [e for e in transcritos if e not in alineados]

            if listos_alinear:
                gpu.ocupar()
                episodio = listos_alinear[0]
                with uso_tarjeta:
                    marcar(estado, "alineacion", "en curso", episodio)
                    ok = ejecutar(PYTHON, SCRIPTS / "03b_alinear.py", episodio)
                    marcar(estado, "alineacion", "listo" if ok else "con error", episodio,
                           f"{episodio}: alineación {'lista' if ok else 'con error'}")
                    if ok:
                        marcar(estado, "curva", "en curso", episodio)
                        ok = ejecutar(PYTHON, SCRIPTS / "24_curva_wavlm.py", episodio)
                        marcar(estado, "curva", "listo" if ok else "con error", episodio,
                               f"{episodio}: curva de quién habla {'calculada' if ok else 'con error'}")
                alineados.add(episodio)
                continue

            pendientes_separar.extend(incorporar_nuevos())

            if pendientes_separar:
                gpu.ocupar()
                episodio = pendientes_separar.pop(0)
                destino = AUDIO / f"{episodio}.wav"
                # El video puede haberse movido de carpeta desde que se encontro
                # (de Descargas a la de los capitulos): se busca donde esta ahora.
                capitulos[episodio] = buscar_capitulos(origen).get(episodio, capitulos[episodio])
                marcar(estado, "extraccion", "en curso", episodio)
                ok = destino.exists() or ejecutar(
                    FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", capitulos[episodio],
                    "-vn", "-map", "0:a:0", "-c:a", "pcm_f32le", destino)
                marcar(estado, "extraccion", "listo" if ok else "con error", episodio)
                if not ok:
                    continue

                marcar(estado, "separacion", "en curso", episodio)
                with uso_tarjeta:
                    ok = ejecutar(PYTHON, SCRIPTS / "02_separar_voz.py", episodio)
                marcar(estado, "separacion", "listo" if ok else "con error", episodio,
                       f"{episodio}: voz separada" if ok else f"{episodio}: la separación falló")
                if ok:
                    with cerrojo:
                        separados.append(episodio)
                continue

            if not transcribiendo.is_set():
                gpu.liberar()

            # No se da por terminada la separacion mientras se este bajando
            # algun capitulo: llegara mas trabajo.
            if descargas_en_curso(origen):
                time.sleep(10)
                continue

            fin_separacion.set()
            if fin_transcripcion.is_set() and len(alineados) >= len(transcritos):
                return
            time.sleep(10)

    def procesador():
        hechos = set()
        while True:
            with cerrojo:
                listos = [e for e in separados if e not in hechos]
            if listos:
                episodio = listos[0]
                transcribiendo.set()
                gpu.ocupar()
                with uso_tarjeta:
                    inicio = time.time()
                    marcar(estado, "transcripcion", "en curso", episodio)
                    proceso = subprocess.Popen(
                        [PYTHON, str(SCRIPTS / "03_transcribir.py"), episodio], cwd=str(RAIZ),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    while proceso.poll() is None:
                        pct = min(95, round(100 * (time.time() - inicio) / 60 / MINUTOS_TRANSCRIPCION))
                        marcar(estado, "transcripcion", f"en curso, ~{pct} %", episodio)
                        time.sleep(15)
                transcribiendo.clear()

                ok = proceso.returncode == 0 and (TRANSCRIPCION / f"{episodio}.json").exists()
                minutos = (time.time() - inicio) / 60
                marcar(estado, "transcripcion", "listo" if ok else "con error", episodio,
                       f"{episodio}: transcripción {'terminada' if ok else 'con error'} en {minutos:.0f} min")
                hechos.add(episodio)
                if ok:
                    with cerrojo:
                        transcritos.append(episodio)
                continue

            if fin_separacion.is_set() and len(hechos) >= len(separados):
                fin_transcripcion.set()
                return
            time.sleep(10)

    hilos = [threading.Thread(target=tarjeta), threading.Thread(target=procesador)]
    for h in hilos:
        h.start()
    for h in hilos:
        h.join()

    estado["nota"] = ("Los capítulos nuevos están preparados. Claude recalibra ahora con todos los "
                      "capítulos juntos y revisa una muestra de cortes antes de armar la página.")
    marcar(estado, "calibracion", "en curso (Claude)", evento="Preparación automática terminada")
    print("listo", time.strftime("%H:%M"), flush=True)


if __name__ == "__main__":
    main()
