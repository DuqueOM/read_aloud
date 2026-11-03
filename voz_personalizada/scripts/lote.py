"""Prepara de principio a fin todas las grabaciones nuevas, en paralelo.

Cada grabacion pasa por cinco pasos: extraer el audio, separar la voz,
transcribir, alinear las palabras y calcular quien habla. Se reparten asi:

- La tarjeta grafica separa la voz de una grabacion tras otra, y alinea y
  calcula la curva de cada una en cuanto esta transcrita.
- El procesador transcribe cada grabacion en cuanto tiene su voz separada.

Asi el procesador no espera a que se separen todas, y la tarjeta no espera a
que se transcriban todas. El avance se ve en progreso.html, en la carpeta de
trabajo.

Mientras trabaja, revisa la carpeta de origen e incorpora las grabaciones que
terminen de descargarse. Chrome guarda una descarga en curso como .crdownload y
le pone su nombre final solo al completarla, asi que un archivo con su
extension final ya esta entero. El lote no termina mientras quede alguna
descarga en curso.

Uso:
    python lote.py
"""

import subprocess
import sys
import threading
import time
from pathlib import Path

import soundfile as sf

from comun import DATOS, ORIGEN, TRABAJO, grabaciones
from progreso_comun import guardar, marcar, nuevo

PYTHON = sys.executable
SCRIPTS = Path(__file__).resolve().parent
VOZ = DATOS / "02_voz"
TRANSCRIPCION = DATOS / "03_transcripcion"

PASOS = ["extraccion", "separacion", "transcripcion", "alineacion", "curva"]

# Minutos de transcripcion por minuto de audio, para estimar el avance. Medido
# con large-v3 en un Intel Core de 14.a generacion: 21 minutos por cada 22 de
# audio.
FACTOR_TRANSCRIPCION = 0.95

# Una descarga que no avanza en este tiempo se da por abandonada, para que el
# lote no espere para siempre.
DESCARGA_ABANDONADA_S = 30 * 60


def ejecutar(*argumentos) -> bool:
    resultado = subprocess.run(
        [str(a) for a in argumentos],
        cwd=str(TRABAJO),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if resultado.returncode != 0:
        detalle = (resultado.stderr or resultado.stdout).strip().splitlines()[-1:] or ["sin detalle"]
        print(f"fallo {argumentos[1:3]}: {detalle[0]}", flush=True)
    return resultado.returncode == 0


def descargas_en_curso() -> bool:
    ahora = time.time()
    return any(ahora - parcial.stat().st_mtime < DESCARGA_ABANDONADA_S for parcial in ORIGEN.glob("*.crdownload"))


def pendientes() -> dict:
    """Grabaciones del origen que aun no estan transcritas."""
    return {e: a for e, a in grabaciones().items() if not (TRANSCRIPCION / f"{e}.json").exists()}


def main() -> None:
    lote = pendientes()
    if not lote:
        print("No hay grabaciones nuevas que procesar.")
        return

    episodios = list(lote)
    estado = nuevo(f"Preparación de la voz · grabaciones {episodios[0][2:]} a {episodios[-1][2:]}", episodios, PASOS)
    estado["eventos"].insert(0, [time.strftime("%H:%M"), f"Lote iniciado con {len(episodios)} grabaciones"])
    guardar(estado)

    cerrojo = threading.Lock()

    def incorporar_nuevas() -> list:
        """Agrega al lote las grabaciones que terminaron de descargarse."""
        nuevas = {e: a for e, a in pendientes().items() if e not in lote}
        if not nuevas:
            return []
        with cerrojo:
            for episodio, archivo in nuevas.items():
                lote[episodio] = archivo
                episodios.append(episodio)
                estado["orden"].append(episodio)
                estado["episodios"][episodio] = {p: "pendiente" for p in PASOS}
            estado["orden"].sort()
            estado["titulo"] = (
                f"Preparación de la voz · grabaciones {estado['orden'][0][2:]} a {estado['orden'][-1][2:]}"
            )
        marcar(estado, "calibracion", "pendiente", evento=f"Descarga completa, se suman: {', '.join(nuevas)}")
        return sorted(nuevas)

    separados = []  # cola de grabaciones listas para transcribir
    transcritos = []  # cola de grabaciones listas para alinear
    fin_separacion = threading.Event()
    fin_transcripcion = threading.Event()

    def tarjeta():
        # Primero extraer y separar todo, que es rapido; la alineacion de lo
        # ya transcrito se intercala entre una separacion y la siguiente.
        pendientes_separar = list(episodios)
        alineados = set()

        while True:
            with cerrojo:
                listos_alinear = [e for e in transcritos if e not in alineados]

            if listos_alinear:
                episodio = listos_alinear[0]
                marcar(estado, "alineacion", "en curso", episodio)
                ok = ejecutar(PYTHON, SCRIPTS / "03b_alinear.py", episodio)
                marcar(
                    estado,
                    "alineacion",
                    "listo" if ok else "con error",
                    episodio,
                    f"{episodio}: alineación {'lista' if ok else 'con error'}",
                )
                if ok:
                    marcar(estado, "curva", "en curso", episodio)
                    ok = ejecutar(PYTHON, SCRIPTS / "04_cortar.py", "--curvas", episodio)
                    marcar(
                        estado,
                        "curva",
                        "listo" if ok else "con error",
                        episodio,
                        f"{episodio}: curva de quién habla {'calculada' if ok else 'con error'}",
                    )
                alineados.add(episodio)
                continue

            pendientes_separar.extend(incorporar_nuevas())

            if pendientes_separar:
                episodio = pendientes_separar.pop(0)
                marcar(estado, "extraccion", "en curso", episodio)
                ok = ejecutar(PYTHON, SCRIPTS / "01_extraer.py", episodio)
                marcar(estado, "extraccion", "listo" if ok else "con error", episodio)
                if not ok:
                    continue

                marcar(estado, "separacion", "en curso", episodio)
                ok = ejecutar(PYTHON, SCRIPTS / "02_separar_voz.py", episodio)
                marcar(
                    estado,
                    "separacion",
                    "listo" if ok else "con error",
                    episodio,
                    f"{episodio}: voz separada" if ok else f"{episodio}: la separación falló",
                )
                if ok:
                    with cerrojo:
                        separados.append(episodio)
                continue

            # No se da por terminada la separacion mientras se este bajando
            # alguna grabacion: llegara mas trabajo.
            if descargas_en_curso():
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
                inicio = time.time()
                previsto_s = FACTOR_TRANSCRIPCION * sf.info(VOZ / f"{episodio}_voz.wav").duration
                marcar(estado, "transcripcion", "en curso", episodio)

                proceso = subprocess.Popen(
                    [PYTHON, str(SCRIPTS / "03_transcribir.py"), episodio],
                    cwd=str(TRABAJO),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                while proceso.poll() is None:
                    pct = min(95, round(100 * (time.time() - inicio) / previsto_s))
                    marcar(estado, "transcripcion", f"en curso, ~{pct} %", episodio)
                    time.sleep(15)

                ok = proceso.returncode == 0 and (TRANSCRIPCION / f"{episodio}.json").exists()
                minutos = (time.time() - inicio) / 60
                marcar(
                    estado,
                    "transcripcion",
                    "listo" if ok else "con error",
                    episodio,
                    f"{episodio}: transcripción {'terminada' if ok else 'con error'} en {minutos:.0f} min",
                )
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

    estado["nota"] = (
        "Las grabaciones están preparadas. Sigue: 04a_calibrar.py con todas juntas, "
        "04_cortar.py y 05_revision.py, que arma la página de revisión."
    )
    marcar(estado, "calibracion", "en curso", evento="Preparación automática terminada")
    print("listo", time.strftime("%H:%M"), flush=True)


if __name__ == "__main__":
    main()
