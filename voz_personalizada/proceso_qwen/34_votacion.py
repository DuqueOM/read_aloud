"""Votacion a ciegas entre las voces candidatas, con dos tomas de cada una.

En la pagina de 13_comparar.py cada voz dice cada frase una sola vez, y como
la generacion tiene azar, una frase puede sonar mejor en una voz solo por
suerte: asi, unas frases ganaban con una voz y otras con otra. Aqui cada voz
dice cada frase dos veces, con dos semillas, y el usuario vota en cada frase
por la voz (A, B o C, en un orden distinto en cada frase) sin saber cual es.

Las frases son 20: las 10 de validacion, que el modelo no vio y
tienen el audio de la voz real, y 10 como las que lee Read Aloud (texto
tecnico, numeros, unidades, terminos y frases en ingles). Pasan por la misma
preparacion que en la app (34_frases.ps1: oraciones, normalizacion e idioma
de cada fragmento) y se generan como lib/servidor_qwen.py de Read Aloud: LoRA
fundido, el CUDA graph de qwen_rapido, la repeticion de las duraciones raras
y el mismo pulido del audio.

Ademas mide cada toma: Whisper la transcribe para contar errores de lectura,
y WavLM Large da su parecido de timbre con la voz real (coseno con el centro de
300 clips del conjunto final, como la huella de 21_hablante.py).

    .venv/Scripts/python.exe scripts/34_votacion.py          todo, con el avance en progreso.html
    .venv_qwen/Scripts/python.exe scripts/34_votacion.py generar
    .venv/Scripts/python.exe scripts/34_votacion.py medir
    .venv/Scripts/python.exe scripts/34_votacion.py pagina

Escribe datos/34_votacion/votar.html.
"""

import html
import importlib.util
import json
import os
import random
import re
import subprocess
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("HF_HOME", str(RAIZ / "modelos" / "hf"))
os.environ.setdefault("TORCH_HOME", str(RAIZ / "modelos" / "torch"))
sys.path.insert(0, str(Path(__file__).parent))

import numpy as np
import soundfile as sf

import voz as config_voz  # "voz" es tambien la huella y cada voz que se compara

DATOS = RAIZ / "datos"
SALIDA = DATOS / "34_votacion"
AUDIO = SALIDA / "audio"
ESCUCHA = SALIDA / "escucha"
# El repositorio de Read Aloud (lector en voz.toml): de ahi salen la
# preparacion del texto y qwen_rapido.
LECTOR = config_voz.lector()

# Las voces que se comparan: carpeta de datos/11_qwen, epoca y etiqueta.
# Cambialas en cada votacion; estas son las de la quinta ronda de la voz de prueba.
VOCES = {
    "app": ("puntos_v4_60", "02", "Voz actual: 60 mejores minutos, época 2"),
    "v5_45": ("puntos_v5_45", "02", "45 mejores minutos, época 2"),
    "v5_lento": ("puntos_v5_60_lento", "03", "60 mejores, aprendizaje lento, época 3"),
}
SEMILLAS = (11, 22)
# Textos como los que lee Read Aloud, en espanol con algo de ingles: si la voz
# es de otro idioma, cambialos por unos de ese idioma.
FRASES_APP = [
    "Para instalar las dependencias, abre la terminal, ejecuta el comando y espera a que termine la descarga.",
    "El archivo de configuración tiene tres secciones: la conexión a la base de datos, el registro de errores "
    "y las credenciales del servidor.",
    "¿Ya revisaste el pull request? Hay un error en la función que calcula el promedio cuando la lista está vacía.",
    "Durante el entrenamiento, la tarjeta gráfica llegó a 7.5 GB de memoria, así que bajamos el lote a 2.",
    "Al principio parecía un problema sencillo, pero después de varias pruebas descubrimos que el retraso no "
    "venía del servidor, sino de la forma en que el navegador guardaba los datos.",
    "La reunión quedó para el martes 14 de noviembre a las 10 de la mañana, en la sala del tercer piso.",
    "¡No puedo creer que por fin funcione! Llevaba toda la semana intentando arreglarlo.",
    "Según el informe, las ventas crecieron un 12 % en el último trimestre, aunque los costos de envío también subieron.",
    "Make sure the cache is cleared before you deploy the new version to production.",
    "I think the problem is in the second loop, where the index goes out of range.",
]
NIVEL_DB = -20.0  # el de 13_comparar.py
PICO_DB = -1.0


def frases_crudas() -> list[dict]:
    serie = json.loads((DATOS / "09_comparar" / "frases.json").read_text(encoding="utf-8"))
    return [{"clave": f"serie{f['n']:02d}", "grupo": "serie", "texto": f["texto"], "n": f["n"]} for f in serie] + [
        {"clave": f"app{i:02d}", "grupo": "app", "texto": t} for i, t in enumerate(FRASES_APP, 1)
    ]


def frases() -> list[dict]:
    destino = SALIDA / "frases.json"
    if not destino.exists():
        SALIDA.mkdir(parents=True, exist_ok=True)
        crudas = SALIDA / "crudas.json"
        crudas.write_text(json.dumps(frases_crudas(), ensure_ascii=False, indent=1), encoding="utf-8")
        subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(Path(__file__).parent / "34_frases.ps1"),
                str(LECTOR),
                str(crudas),
                str(destino),
            ],
            check=True,
        )
    lista = json.loads(destino.read_text(encoding="utf-8-sig"))
    numeros = {f["clave"]: f.get("n") for f in frases_crudas()}
    for f in lista:
        f["n"] = numeros[f["clave"]]
    return lista


def archivo(clave: str, voz: str, toma: int) -> Path:
    return AUDIO / f"{clave}_{voz}_t{toma}.wav"


# --------------------------------------------------------------------------
# Generar, como lib/servidor_qwen.py
# --------------------------------------------------------------------------
SILENCIO_S = 0.36
NIVEL_APP_DB = -19.0
UMBRAL_SILENCIO_DB = -45.0
MARGEN_S = 0.05
SEGUNDOS_POR_LETRA = 0.065
CODIGOS_POR_SEGUNDO = 12.5
IDIOMAS = {"es": "Spanish", "en": "English"}


def cargar_voz(carpeta: Path, epoca: str):
    import torch
    from huggingface_hub import snapshot_download
    from peft import LoraConfig, inject_adapter_in_model, set_peft_model_state_dict
    from peft.tuners.lora import LoraLayer
    from qwen_tts import Qwen3TTSModel
    from safetensors.torch import load_file

    sys.path.insert(0, str(LECTOR / "lib"))
    import qwen_rapido

    def fundir(modulo):
        for nombre, hijo in list(modulo.named_children()):
            if isinstance(hijo, LoraLayer):
                hijo.merge()
                setattr(modulo, nombre, hijo.base_layer)
            else:
                fundir(hijo)

    ajuste = json.loads((carpeta / "ajuste.json").read_text(encoding="utf-8"))
    qwen = Qwen3TTSModel.from_pretrained(
        snapshot_download(ajuste["modelo_base"], local_files_only=True),
        device_map="cuda:0",
        dtype=torch.bfloat16,
        attn_implementation="sdpa",
    )
    modelo = qwen.model
    inject_adapter_in_model(
        LoraConfig(
            r=ajuste["r"], lora_alpha=ajuste["lora_alpha"], lora_dropout=0.0, target_modules=ajuste["target_modules"]
        ),
        modelo.talker,
    )
    estado = load_file(carpeta / f"epoca_{epoca}.safetensors")
    set_peft_model_state_dict(modelo.talker, {k: v.to(modelo.device) for k, v in estado.items()})
    modelo.talker.eval()
    fundir(modelo.talker)
    voz = load_file(carpeta / "voz.safetensors")["voz"]
    with torch.no_grad():
        modelo.talker.model.codec_embedding.weight[3000] = voz[0].to(modelo.dtype).to(modelo.device)
    modelo.config.tts_model_type = modelo.tts_model_type = "custom_voice"
    modelo.config.talker_config.spk_id = {config_voz.NOMBRE: 3000}
    modelo.config.talker_config.spk_is_dialect = {config_voz.NOMBRE: False}
    modelo.supported_speakers = modelo.config.talker_config.spk_id.keys()
    qwen_rapido.activar(modelo)
    return qwen


def pulir(audio: np.ndarray, tasa: int) -> np.ndarray:
    audio = np.asarray(audio, dtype=np.float32)
    cuadro = int(0.01 * tasa)
    niveles = 20 * np.log10(np.sqrt(np.convolve(audio**2, np.ones(cuadro) / cuadro, mode="same")) + 1e-9)
    con_voz = np.where(niveles > UMBRAL_SILENCIO_DB)[0]
    if con_voz.size:
        margen = int(MARGEN_S * tasa)
        audio = audio[max(0, con_voz[0] - margen) : con_voz[-1] + margen]
        habla = audio[np.abs(audio) > 10 ** (UMBRAL_SILENCIO_DB / 20)]
        audio = audio * (10 ** (NIVEL_APP_DB / 20) / (np.sqrt(np.mean(habla**2)) + 1e-9))
        pico = np.max(np.abs(audio))
        if pico > 10 ** (PICO_DB / 20):
            audio = audio * (10 ** (PICO_DB / 20) / pico)
    return np.concatenate([audio, np.zeros(int(SILENCIO_S * tasa), dtype=np.float32)])


def decir(qwen, texto: str, idioma: str):
    esperado = max(0.6, len(texto) * SEGUNDOS_POR_LETRA)
    tope = int(CODIGOS_POR_SEGUNDO * (2.5 * len(texto) * SEGUNDOS_POR_LETRA + 3))
    for intento in range(2):
        wavs, tasa = qwen.generate_custom_voice(
            text=[texto],
            language=[IDIOMAS.get(idioma, "Spanish")],
            speaker=[config_voz.NOMBRE],
            non_streaming_mode=True,
            max_new_tokens=tope,
        )
        segundos = len(wavs[0]) / tasa
        if 0.35 * esperado <= segundos <= 2.5 * esperado + 1.0:
            break
    return pulir(wavs[0], tasa), tasa


def generar() -> None:
    import torch
    import gpu
    from progreso_comun import avance

    gpu.ocupar()
    lista = frases()
    AUDIO.mkdir(parents=True, exist_ok=True)
    total, hechos = len(VOCES) * len(lista) * len(SEMILLAS), 0
    for voz, (carpeta, epoca, _) in VOCES.items():
        faltan = [
            (f, t, s) for f in lista for t, s in enumerate(SEMILLAS, 1) if not archivo(f["clave"], voz, t).exists()
        ]
        hechos += len(lista) * len(SEMILLAS) - len(faltan)
        if not faltan:
            continue
        qwen = cargar_voz(DATOS / "11_qwen" / carpeta, epoca)
        for f, toma, semilla in faltan:
            avance("tomas", hechos, total)
            torch.manual_seed(semilla)
            partes = [decir(qwen, frag["texto"], frag["idioma"]) for frag in f["fragmentos"]]
            sf.write(
                archivo(f["clave"], voz, toma), np.concatenate([p for p, _ in partes]), partes[0][1], subtype="PCM_16"
            )
            hechos += 1
        del qwen
        torch.cuda.empty_cache()
        print(f"{voz}: listo", flush=True)


# --------------------------------------------------------------------------
# Medir
# --------------------------------------------------------------------------
def modulo(nombre: str, archivo_py: str):
    spec = importlib.util.spec_from_file_location(nombre, Path(__file__).parent / archivo_py)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def medir() -> None:
    import torch
    import torchaudio
    import whisper
    import gpu
    from progreso_comun import avance

    gpu.ocupar()
    os.environ["PATH"] = str(RAIZ / "herramientas") + os.pathsep + os.environ["PATH"]
    cortar = modulo("cortar", "04_cortar.py")
    medida = modulo("medir", "10c_medir.py")
    lista = frases()

    def a16(ruta):
        audio, tasa = sf.read(ruta, dtype="float32", always_2d=False)
        return cortar.a_16k(cortar.mono(audio), tasa)

    # Timbre: WavLM Large, el promedio de las capas 4 a 12 (21_hablante.py).
    grande = torchaudio.pipelines.WAVLM_LARGE.get_model().to("cuda:0").eval()

    @torch.no_grad()
    def huella(ruta):
        # ruff ve el "del grande" de mas abajo; huella no se llama despues de el.
        capas, _ = grande.extract_features(torch.from_numpy(a16(ruta))[None].to("cuda:0"))  # noqa: F821
        v = torch.stack([capas[i].mean(dim=1).squeeze(0) for i in range(4, 13)]).mean(0).cpu().numpy()
        return v / (np.linalg.norm(v) + 1e-9)

    conjunto = sorted((DATOS / "31_final" / "audio").glob("*.wav"))
    centro = np.mean([huella(r) for r in conjunto[:: max(1, len(conjunto) // 300)]], axis=0)
    centro /= np.linalg.norm(centro)
    reales = [DATOS / "09_comparar" / "audio" / f"f{f['n']}_real.wav" for f in lista if f["grupo"] == "serie"]
    resultado = {"_real": float(np.mean([huella(r) @ centro for r in reales]))}
    for ruta in sorted(AUDIO.glob("*.wav")):
        resultado[ruta.stem] = {"parecido": float(huella(ruta) @ centro)}
    del grande
    torch.cuda.empty_cache()

    # Errores de lectura: Whisper large-v3 a media precision, como 27_transcribir_clips.py.
    oido = whisper.load_model("large-v3", device="cpu", download_root=str(RAIZ / "modelos" / "whisper")).half()
    for capa in oido.modules():
        if isinstance(capa, torch.nn.LayerNorm):
            capa.float()
    oido = oido.cuda()
    por_clave = {f["clave"]: f for f in lista}
    rutas = sorted(AUDIO.glob("*.wav"))
    for n, ruta in enumerate(rutas):
        avance("Whisper", n, len(rutas))
        f = por_clave[ruta.stem.split("_", 1)[0]]
        idioma = "en" if all(g["idioma"] == "en" for g in f["fragmentos"]) else "es"
        esperado = " ".join(g["texto"] for g in f["fragmentos"])
        dicho = oido.transcribe(
            whisper.load_audio(str(ruta)), language=idioma, fp16=True, temperature=0.0, condition_on_previous_text=False
        )["text"].strip()
        resultado[ruta.stem].update({"error": medida.error_caracteres(esperado, dicho), "dicho": dicho})
    (SALIDA / "medicion.json").write_text(json.dumps(resultado, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"medidas: {len(rutas)} tomas", flush=True)


# --------------------------------------------------------------------------
# Pagina
# --------------------------------------------------------------------------
def igualar(origen: Path, destino: Path) -> None:
    audio, tasa = sf.read(origen, dtype="float32", always_2d=False)
    audio = audio if audio.ndim == 1 else audio.mean(axis=1)
    audio = audio * (10 ** (NIVEL_DB / 20) / (np.sqrt(np.mean(audio**2)) + 1e-9))
    pico = np.max(np.abs(audio)) + 1e-9
    limite = 10 ** (PICO_DB / 20)
    sf.write(destino, audio * (limite / pico) if pico > limite else audio, tasa, subtype="PCM_24")


def pagina() -> None:
    lista = frases()
    medicion = (
        json.loads((SALIDA / "medicion.json").read_text(encoding="utf-8"))
        if (SALIDA / "medicion.json").exists()
        else {}
    )
    ESCUCHA.mkdir(parents=True, exist_ok=True)
    azar = random.Random(2026)
    mapa, tarjetas = {}, []
    for f in lista:
        voces = list(VOCES)
        azar.shuffle(voces)
        letras = dict(zip("ABC", voces))
        mapa[f["clave"]] = letras
        filas = []
        if f["grupo"] == "serie":
            igualar(DATOS / "09_comparar" / "audio" / f"f{f['n']}_real.wav", ESCUCHA / f"{f['clave']}_real.wav")
            filas.append(
                f'<div class="fila real"><span>{html.escape(config_voz.TITULO)} real</span>'
                f'<audio controls preload="none" src="escucha/{f["clave"]}_real.wav"></audio></div>'
            )
        for letra, voz in letras.items():
            tomas = []
            for toma in (1, 2):
                # Nombres que no dicen la voz: la letra de esta frase y la toma.
                nombre = f"{f['clave']}_{letra}{toma}.wav"
                igualar(archivo(f["clave"], voz, toma), ESCUCHA / nombre)
                tomas.append(f'<audio controls preload="none" src="escucha/{nombre}"></audio>')
            filas.append(f'<div class="fila"><span>{letra}</span><div class="tomas">{"".join(tomas)}</div></div>')
        botones = "".join(f'<button data-voto="{v}">{v}</button>' for v in ("A", "B", "C", "Iguales"))
        tarjetas.append(
            f'<div class="par" data-clave="{f["clave"]}" data-grupo="{f["grupo"]}">'
            f'<b>{html.escape(f["texto"])}</b>{"".join(filas)}<div class="votos">{botones}</div></div>'
        )

    resumen = {}
    for voz in VOCES:
        tomas = [
            v for k, v in medicion.items() if not k.startswith("_") and k.split("_", 1)[1].rsplit("_t", 1)[0] == voz
        ]
        resumen[voz] = {
            "parecido": float(np.mean([t["parecido"] for t in tomas])) if tomas else None,
            "error": float(np.mean([t["error"] for t in tomas])) if tomas and "error" in tomas[0] else None,
        }
    # Una toma "con error" lee notablemente peor que la mejor toma de esa frase:
    # asi no cuenta lo que Whisper transcribe distinto en todas por igual (cifras, siglas).
    errores = {voz: [] for voz in VOCES}
    for f in lista:
        tomas = {(voz, t): medicion.get(archivo(f["clave"], voz, t).stem, {}) for voz in VOCES for t in (1, 2)}
        valores = [m["error"] for m in tomas.values() if "error" in m]
        if not valores:
            continue
        for (voz, t), m in tomas.items():
            if "error" in m and m["error"] - min(valores) > 0.08:
                errores[voz].append(
                    {"frase": f["texto"], "toma": t, "dicho": m["dicho"], "error": round(m["error"], 3)}
                )
    datos = {
        "mapa": mapa,
        "voces": {v: e for v, (_, _, e) in VOCES.items()},
        "resumen": resumen,
        # "_real", o "_<nombre>_real" en las mediciones de versiones anteriores.
        "errores": errores,
        "real": next((v for k, v in medicion.items() if k.startswith("_") and k.endswith("_real")), None),
    }

    (SALIDA / "votar.html").write_text(
        PLANTILLA.replace("{{TARJETAS}}", "".join(tarjetas))
        .replace("{{TITULO}}", html.escape(config_voz.TITULO))
        .replace("{{NOMBRE}}", re.sub(r"\W", "_", config_voz.NOMBRE))
        .replace("{{DATOS}}", json.dumps(datos, ensure_ascii=False)),
        encoding="utf-8",
    )
    print(f"pagina: {SALIDA / 'votar.html'}", flush=True)


PLANTILLA = """<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Votación de voces</title>
<style>
 body { margin:0; background:#16161a; color:#e6e6ea; font:15px/1.5 "Segoe UI",system-ui,sans-serif; }
 main { max-width:780px; margin:0 auto; padding:28px 20px 80px; }
 h1 { font-size:20px; margin:0 0 6px; } h2 { font-size:16px; margin:26px 0 8px; }
 p { color:#a8a8b2; margin:4px 0 14px; }
 .par { background:#1f1f25; border:1px solid #2e2e36; border-radius:8px; padding:12px 14px; margin-bottom:12px; }
 .par.votada { border-color:#3b5b46; }
 .par b { display:block; margin-bottom:8px; font-weight:600; }
 .fila { display:grid; grid-template-columns:90px 1fr; gap:8px; align-items:center; margin:4px 0; }
 .fila span { color:#c8c8d0; font-weight:600; } .fila.real span { color:#4ade80; font-weight:400; font-size:13px; }
 .tomas { display:grid; grid-template-columns:1fr 1fr; gap:6px; }
 audio { width:100%; height:32px; }
 .votos { display:flex; gap:8px; margin-top:10px; flex-wrap:wrap; }
 button { background:#2a2a32; color:#e6e6ea; border:1px solid #3a3a44; border-radius:6px; padding:6px 14px;
          font:inherit; cursor:pointer; }
 button:hover { background:#34343e; } button.elegido { background:#2f6b45; border-color:#4ade80; }
 #barra { position:sticky; top:0; background:#16161aee; padding:10px 0; display:flex; gap:10px; align-items:center;
          flex-wrap:wrap; z-index:2; }
 #resultado { display:none; } table { border-collapse:collapse; width:100%; margin:8px 0 16px; }
 td, th { border-bottom:1px solid #2e2e36; padding:6px 8px; text-align:left; } th { color:#a8a8b2; font-weight:400; }
 .err { color:#a8a8b2; font-size:13px; margin:2px 0; }
 @media (max-width:560px) { main { padding:20px 16px 80px; } .fila { grid-template-columns:1fr; gap:2px; }
                            .tomas { grid-template-columns:1fr; } }
</style></head><body><main>
<h1>Votación de voces</h1>
<p>En cada frase hay tres voces, A, B y C, en un orden distinto cada vez. Cada una dice la frase dos veces, y cada
toma sale distinta: escucha las dos antes de votar. Elige la que suene más a {{TITULO}} y más natural; si no
distingues, marca «Iguales». Tus votos se guardan en este navegador aunque cierres la página.</p>
<div id="barra"><span id="cuenta"></span><button id="ver">Ver resultado</button>
<button id="bajar">Descargar votos</button></div>
<div id="resultado"></div>
<h2>Frases de validación</h2>
<p>Las 10 que el modelo no vio al entrenar, con lo que dijo {{TITULO}}.</p>
<div id="serie"></div>
<h2>Textos como los que lee Read Aloud</h2>
<p>Sin original: {{TITULO}} nunca los dijo.</p>
<div id="app"></div>
<template id="tarjetas">{{TARJETAS}}</template>
<script>
const DATOS = {{DATOS}};
const CLAVE = "{{NOMBRE}}_votacion_v1";
let votos = {};
try { votos = JSON.parse(localStorage.getItem(CLAVE) || "{}"); } catch (e) {}
const plantilla = document.getElementById("tarjetas").content;
for (const par of plantilla.querySelectorAll(".par")) document.getElementById(par.dataset.grupo).appendChild(par.cloneNode(true));
const pares = [...document.querySelectorAll("main .par")];
function pintar() {
  for (const par of pares) {
    const v = votos[par.dataset.clave];
    par.classList.toggle("votada", !!v);
    for (const b of par.querySelectorAll("button")) b.classList.toggle("elegido", b.dataset.voto === v);
  }
  document.getElementById("cuenta").textContent = `${Object.keys(votos).length} de ${pares.length} frases votadas`;
}
for (const par of pares) for (const b of par.querySelectorAll("button")) b.onclick = () => {
  votos[par.dataset.clave] = b.dataset.voto;
  try { localStorage.setItem(CLAVE, JSON.stringify(votos)); } catch (e) {}
  pintar();
};
// Solo se escucha una a la vez.
document.addEventListener("play", e => { for (const a of document.querySelectorAll("audio")) if (a !== e.target) a.pause(); }, true);
function deVoz(clave, voto) { return voto === "Iguales" ? "iguales" : DATOS.mapa[clave][voto]; }
function resultado() {
  const voces = Object.keys(DATOS.voces);
  const cuenta = g => { const c = Object.fromEntries([...voces, "iguales"].map(v => [v, 0]));
    for (const par of pares) if ((!g || par.dataset.grupo === g) && votos[par.dataset.clave]) c[deVoz(par.dataset.clave, votos[par.dataset.clave])]++;
    return c; };
  const total = cuenta(), serie = cuenta("serie"), app = cuenta("app");
  const pct = x => x == null ? "–" : (100 * x).toFixed(1) + " %";
  let h = `<h2>Resultado</h2><table><tr><th>Voz</th><th>Votos</th><th>Validación</th><th>Textos de la app</th>
    <th>Error de lectura</th><th>Tomas con error</th><th>Parecido con {{TITULO}}</th></tr>`;
  for (const v of [...voces].sort((a, b) => total[b] - total[a])) {
    const r = DATOS.resumen[v];
    h += `<tr><td>${DATOS.voces[v]}</td><td>${total[v]}</td><td>${serie[v]}</td><td>${app[v]}</td>
      <td>${pct(r.error)}</td><td>${DATOS.errores[v].length}</td><td>${r.parecido == null ? "–" : r.parecido.toFixed(3)}</td></tr>`;
  }
  h += `<tr><td>Iguales</td><td>${total.iguales}</td><td>${serie.iguales}</td><td>${app.iguales}</td><td></td><td></td><td></td></tr></table>`;
  if (DATOS.real != null) h += `<p>Parecido de {{TITULO}} real con el mismo centro: ${DATOS.real.toFixed(3)}. Más alto es más parecido.</p>`;
  for (const v of voces) for (const e of DATOS.errores[v])
    h += `<div class="err"><b>${DATOS.voces[v]}</b>, toma ${e.toma}: «${e.frase}» → se oyó «${e.dicho}»</div>`;
  const div = document.getElementById("resultado");
  div.innerHTML = h; div.style.display = "block"; div.scrollIntoView({ behavior: "smooth" });
}
document.getElementById("ver").onclick = () => {
  const faltan = pares.length - Object.keys(votos).length;
  if (faltan && !confirm(`Faltan ${faltan} frases. ¿Ver el resultado igual? Saber cuál es cuál puede influir en los votos que faltan.`)) return;
  resultado();
};
document.getElementById("bajar").onclick = () => {
  const salida = { votos, por_voz: Object.fromEntries(Object.entries(votos).map(([k, v]) => [k, deVoz(k, v)])) };
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([JSON.stringify(salida, null, 1)], { type: "application/json" }));
  a.download = "votacion.json"; a.click();
};
pintar();
</script>
</main></body></html>"""


# --------------------------------------------------------------------------
# Todo en cadena
# --------------------------------------------------------------------------
def cadena() -> None:
    import gpu
    from progreso_comun import guardar, marcar, nuevo

    revision = modulo("revision", "29_preparar_revision.py")
    gpu.ocupar()  # toda la cadena: si no, entre paso y paso Read Aloud recargaria la voz
    qwen = RAIZ / ".venv_qwen" / "Scripts" / "python.exe"
    principal = RAIZ / ".venv" / "Scripts" / "python.exe"
    pasos = [
        ("Dos tomas de cada voz", qwen, "generar"),
        ("Errores de lectura y parecido", principal, "medir"),
        ("Página de votación", principal, "pagina"),
    ]
    estado = nuevo(f"Voz de {config_voz.TITULO} · votación a ciegas", [p[0] for p in pasos], ["estado"], finales=[])
    estado["filas"] = "Paso"
    estado["nota"] = "Se generan las tomas para votar. Mientras tanto, Read Aloud lee con Piper."
    guardar(estado)
    revision.REGISTRO = DATOS / "34_votacion.log"
    for nombre, python, paso in pasos:
        marcar(estado, "estado", "en curso", nombre, f"Empieza: {nombre}")
        ok = revision.correr(python, ["34_votacion.py", paso], estado, nombre)
        marcar(estado, "estado", "listo" if ok else "con error", nombre)
        if not ok:
            estado["nota"] = f"Falló «{nombre}». Detalle en datos/34_votacion.log."
            guardar(estado)
            return
    estado["nota"] = "Lista: abre datos/34_votacion/votar.html y vota."
    guardar(estado)
    gpu.liberar()
    os.startfile(SALIDA / "votar.html")


if __name__ == "__main__":
    {"generar": generar, "medir": medir, "pagina": pagina}.get(sys.argv[1] if len(sys.argv) > 1 else "", cadena)()
