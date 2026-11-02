"""Convierte el parecido con las referencias en una probabilidad de ser la voz.

El parecido es una medida de distancia entre voces, no una probabilidad: un
0.6 no significa 60 %. Para poder decir "confianza de mas del 70 %" se ajusta
un modelo de dos grupos a todas las ventanas de los capitulos. Un grupo
representa a la voz y el otro al resto de las voces. Con ese modelo, cada
valor de parecido se traduce en la probabilidad de pertenecer al grupo de
la voz.

El grupo del resto mezcla muchas voces y no tiene forma de campana, asi que se
modela con dos campanas; la voz, con una. El ajuste se hace por maxima
verosimilitud con el algoritmo EM.

Guarda la calibracion en datos/04_curvas/calibracion.json, que lee
04_cortar.py.

Uso:
    python scripts/04a_calibrar.py
"""

import json
from pathlib import Path

import numpy as np

RAIZ = Path(__file__).resolve().parent.parent
CURVAS = RAIZ / "datos" / "04_curvas"


def normal(x, media, desvio):
    return np.exp(-0.5 * ((x - media) / desvio) ** 2) / (desvio * np.sqrt(2 * np.pi))


def ajustar(x, medias, desvios, pesos, iteraciones=500):
    medias, desvios, pesos = map(np.array, (medias, desvios, pesos))
    for _ in range(iteraciones):
        dens = np.stack([p * normal(x, m, d) for m, d, p in zip(medias, desvios, pesos)])
        resp = dens / (dens.sum(axis=0) + 1e-300)
        n = resp.sum(axis=1)
        medias = (resp * x).sum(axis=1) / n
        desvios = np.sqrt((resp * (x - medias[:, None]) ** 2).sum(axis=1) / n) + 1e-4
        pesos = n / len(x)
    verosimilitud = np.log(dens.sum(axis=0) + 1e-300).sum()
    return medias, desvios, pesos, verosimilitud


def main() -> None:
    valores = np.concatenate([
        (lambda c: c[~np.isnan(c)])(np.load(f)["parecido"]) for f in sorted(CURVAS.glob("ep*.npz"))
    ])

    # Tres campanas: dos para el resto de las voces y una para la voz, que es
    # la de media mas alta.
    medias, desvios, pesos, lv = ajustar(valores, [0.15, 0.32, 0.62], [0.06, 0.08, 0.07], [0.4, 0.4, 0.2])
    orden = np.argsort(medias)
    medias, desvios, pesos = medias[orden], desvios[orden], pesos[orden]

    print(f"{len(valores)} ventanas")
    for nombre, m, d, p in zip(["resto A", "resto B", "voz"], medias, desvios, pesos):
        print(f"  {nombre:8s} media {m:.3f}  desvio {d:.3f}  peso {p:.2f}")

    def prob(x):
        dens = np.stack([p * normal(x, m, d) for m, d, p in zip(medias, desvios, pesos)])
        return dens[2] / (dens.sum(axis=0) + 1e-300)

    malla = np.linspace(0, 1, 2001)
    pm = prob(malla)
    # Por encima de la media de la voz la probabilidad no debe volver a bajar:
    # mas parecido nunca es menos la voz.
    pico = np.argmax(pm)
    pm[pico:] = np.maximum.accumulate(pm[pico:])

    umbrales = {}
    for objetivo in (0.3, 0.5, 0.7, 0.9):
        umbrales[str(objetivo)] = float(malla[np.argmax(pm >= objetivo)])
        print(f"  probabilidad {objetivo:.0%} desde parecido {umbrales[str(objetivo)]:.3f}")

    print(f"  ventanas con probabilidad > 70 %: {(prob(valores) > 0.7).mean():.1%}")

    CURVAS.mkdir(parents=True, exist_ok=True)
    (CURVAS / "calibracion.json").write_text(json.dumps({
        "medias": medias.tolist(), "desvios": desvios.tolist(), "pesos": pesos.tolist(),
        "malla": malla[::4].round(4).tolist(), "probabilidad": pm[::4].round(4).tolist(),
        "umbrales": umbrales,
    }, indent=1), encoding="utf-8")
    print(f"calibracion guardada en {CURVAS / 'calibracion.json'}")


if __name__ == "__main__":
    main()
