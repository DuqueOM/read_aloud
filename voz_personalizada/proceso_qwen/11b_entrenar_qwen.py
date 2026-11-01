"""Afina Qwen3-TTS 1.7B con la voz de prueba usando LoRA.

Parte de la receta oficial (finetuning/sft_12hz.py del repositorio de
Qwen3-TTS, commit 022e286), que tiene tres errores que hacen que el modelo
entrenado no diga el texto. Se comprobaron con el modelo base sin tocar, que
debe predecir bien los codigos de la voz de prueba si la entrada esta bien armada:

- El texto entra sin pasar por text_projection, que la generacion si aplica.
  Con ella, la perdida del base baja de 8.7 a 1.6.
- Las etiquetas de la capa 0 se pasan ya desplazadas y la funcion de perdida
  de transformers las vuelve a desplazar: el modelo aprende a predecir el
  codigo de dos pasos mas adelante.
- El predictor de las otras 15 capas recibe el estado oculto de la misma
  posicion, cuando al generar recibe el de la anterior, y su perdida sufre
  el mismo doble desplazamiento. Corregido, la perdida del base baja de 10.9
  a 5.5.

Y estos cambios a proposito:

- LoRA de rango 64 en todas las capas lineales del modelo principal y del
  predictor de codigos, en vez de ajustar los 1 900 millones de parametros:
  el ajuste completo pide unos 15 GB de tarjeta y aqui hay 8. El modelo base
  queda fijo en bf16, que es su precision original; LoRA va a precision
  completa.
- Cada frase lleva la marca de idioma en la misma posicion en que el modelo
  la recibe al generar. La receta oficial entrena sin ella.
- Mide la perdida en las 10 frases que no entrenan, para ver cuando empieza
  a memorizar en vez de aprender.

Guarda las capas LoRA de cada epoca en datos/11_qwen/<salida>/.

Corre en el entorno de Qwen:
    .venv_qwen/Scripts/python.exe scripts/11b_entrenar_qwen.py --salida puntos_v2 --aprendizaje 3e-5 --epocas 8
"""

import argparse

import json
import math
import os
import random
import sys
import time
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("HF_HOME", str(RAIZ / "modelos" / "hf"))

import librosa
import numpy as np
import torch
from peft import LoraConfig, get_peft_model_state_dict, inject_adapter_in_model, set_peft_model_state_dict
from qwen_tts import Qwen3TTSModel
from qwen_tts.core.models.modeling_qwen3_tts import mel_spectrogram
from safetensors.torch import load_file, save_file

DATOS = RAIZ / "datos" / "11_qwen"
MODELO_BASE = "Qwen/Qwen3-TTS-12Hz-1.7B-Base"

EPOCAS = 12
LOTE = 2
ACUMULAR = 4  # lote efectivo de 8, como la receta oficial (2 x 4)
APRENDIZAJE = 1e-4
CALENTAMIENTO = 30  # pasos
RANGO = 64
ALFA = 64
ABANDONO = 0.05
SEMILLA = 1234

CAPAS = r".*layers\.\d+\.(self_attn\.(q|k|v|o)_proj|mlp\.(gate|up|down)_proj)"


def lote_tensores(items, procesador, config, idioma_id, voz):
    """Arma un lote igual que el collate oficial, con la marca de idioma.

    Prefijo del canal de codigos, como en la generacion con idioma:
    think, think_bos, idioma, think_eos, voz, pad, bos y despues el audio.
    """
    tc = config.talker_config
    # Sin idioma queda el prefijo de la receta oficial: nothink, think_bos, think_eos.
    etiquetas = ([tc.codec_nothink_id, tc.codec_think_bos_id, tc.codec_think_eos_id] if idioma_id is None
                 else [tc.codec_think_id, tc.codec_think_bos_id, idioma_id, tc.codec_think_eos_id])
    pos_voz = 3 + len(etiquetas)  # 7; en la receta oficial, sin idioma, es 6
    inicio_texto = pos_voz + 2

    textos = [procesador(text=f"<|im_start|>assistant\n{i['text']}<|im_end|>\n<|im_start|>assistant\n",
                         return_tensors="pt")["input_ids"][0][:-5] for i in items]
    codigos = [torch.tensor(i["audio_codes"], dtype=torch.long) for i in items]
    largo = max(t.shape[0] + c.shape[0] for t, c in zip(textos, codigos)) + inicio_texto + 2
    b = len(items)

    input_ids = torch.zeros((b, largo, 2), dtype=torch.long)
    codec_ids = torch.zeros((b, largo, 16), dtype=torch.long)
    mascara_texto = torch.zeros((b, largo), dtype=torch.bool)
    mascara_codec = torch.zeros((b, largo), dtype=torch.bool)
    mascara_audio = torch.zeros((b, largo), dtype=torch.bool)
    atencion = torch.zeros((b, largo), dtype=torch.long)
    etiquetas_0 = torch.full((b, largo), -100, dtype=torch.long)

    for i, (t, c) in enumerate(zip(textos, codigos)):
        nt, nc = t.shape[0], c.shape[0]
        fin_texto = inicio_texto + nt - 3  # eos de texto; el bos de codigos va justo despues
        inicio_audio = fin_texto + 2

        # canal de texto
        input_ids[i, :3, 0] = t[:3]
        input_ids[i, 3:pos_voz + 1, 0] = config.tts_pad_token_id
        input_ids[i, pos_voz + 1, 0] = config.tts_bos_token_id
        input_ids[i, inicio_texto:fin_texto, 0] = t[3:]
        input_ids[i, fin_texto, 0] = config.tts_eos_token_id
        input_ids[i, fin_texto + 1:inicio_audio + nc + 1, 0] = config.tts_pad_token_id
        mascara_texto[i, :inicio_audio + nc + 1] = True

        # canal de codigos
        input_ids[i, 3:pos_voz, 1] = torch.tensor(etiquetas)
        input_ids[i, pos_voz + 1, 1] = tc.codec_pad_id
        input_ids[i, inicio_texto:fin_texto + 1, 1] = tc.codec_pad_id
        input_ids[i, fin_texto + 1, 1] = tc.codec_bos_id
        input_ids[i, inicio_audio:inicio_audio + nc, 1] = c[:, 0]
        input_ids[i, inicio_audio + nc, 1] = tc.codec_eos_token_id
        etiquetas_0[i, inicio_audio:inicio_audio + nc] = c[:, 0]
        etiquetas_0[i, inicio_audio + nc] = tc.codec_eos_token_id
        codec_ids[i, inicio_audio:inicio_audio + nc, :] = c
        mascara_codec[i, 3:inicio_audio + nc + 1] = True
        mascara_codec[i, pos_voz] = False
        mascara_audio[i, inicio_audio:inicio_audio + nc] = True
        atencion[i, :inicio_audio + nc + 1] = 1

    return {
        "input_ids": input_ids, "codec_ids": codec_ids, "atencion": atencion,
        "mascara_texto": mascara_texto.unsqueeze(-1), "mascara_codec": mascara_codec.unsqueeze(-1),
        "mascara_audio": mascara_audio, "etiquetas_0": etiquetas_0, "pos_voz": pos_voz,
    }


def perdida(modelo, lote, voz):
    """Capa 0 mas 0.3 por las otras 15, como la receta oficial, sin sus errores."""
    d = modelo.talker.device
    input_ids = lote["input_ids"].to(d)
    codec_ids = lote["codec_ids"].to(d)
    mascara_audio = lote["mascara_audio"].to(d)

    emb_texto = (modelo.talker.text_projection(modelo.talker.model.text_embedding(input_ids[:, :, 0]))
                 * lote["mascara_texto"].to(d))
    emb_codec = modelo.talker.model.codec_embedding(input_ids[:, :, 1]) * lote["mascara_codec"].to(d)
    emb_codec[:, lote["pos_voz"], :] = voz
    entrada = emb_texto + emb_codec
    for i in range(1, 16):
        entrada = entrada + (modelo.talker.code_predictor.get_input_embeddings()[i - 1](codec_ids[:, :, i])
                             * mascara_audio.unsqueeze(-1))

    # La funcion de perdida desplaza las etiquetas una posicion por su cuenta:
    # la salida de la posicion i se compara con la etiqueta i + 1.
    salida = modelo.talker(inputs_embeds=entrada[:, :-1, :], attention_mask=lote["atencion"][:, :-1].to(d),
                           labels=lote["etiquetas_0"][:, :-1].to(d), output_hidden_states=True)
    # Al generar, el cuadro p sale del estado oculto de la posicion p - 1.
    ocultos = salida.hidden_states[0][-1][mascara_audio[:, 1:]]
    codigos = codec_ids[mascara_audio]
    logits_sub, _ = modelo.talker.forward_sub_talker_finetune(codigos, ocultos)
    # Sus logits ya estan alineados con las capas 1 a 15: sin desplazar.
    perdida_sub = torch.nn.functional.cross_entropy(logits_sub.float().reshape(-1, logits_sub.shape[-1]),
                                                    codigos[:, 1:].reshape(-1))
    return salida.loss + 0.3 * perdida_sub, salida.loss, perdida_sub


def main() -> None:
    global EPOCAS, APRENDIZAJE
    argumentos = argparse.ArgumentParser()
    argumentos.add_argument("--salida", default="puntos")
    argumentos.add_argument("--aprendizaje", type=float, default=APRENDIZAJE)
    argumentos.add_argument("--epocas", type=int, default=EPOCAS)
    argumentos.add_argument("--datos", default=str(DATOS),
                            help="carpeta con entrenamiento.jsonl y validacion.jsonl (31_conjunto_qwen.py)")
    argumentos.add_argument("--reanudar", action="store_true",
                            help="seguir despues de la ultima epoca guardada, si la hay")
    argumentos.add_argument("--paciencia", type=int, default=0,
                            help="parar cuando la validacion empeore esta cantidad de epocas seguidas; 0 es nunca")
    a = argumentos.parse_args()
    EPOCAS, APRENDIZAJE = a.epocas, a.aprendizaje
    datos = Path(a.datos)
    PUNTOS = DATOS / a.salida

    # Entrenar ocupa toda la tarjeta: Read Aloud lee con Piper mientras tanto.
    sys.path.insert(0, str(Path(__file__).parent))
    import gpu
    gpu.ocupar()

    random.seed(SEMILLA)
    np.random.seed(SEMILLA)
    torch.manual_seed(SEMILLA)
    PUNTOS.mkdir(parents=True, exist_ok=True)

    qwen = Qwen3TTSModel.from_pretrained(MODELO_BASE, device_map="cuda:0", dtype=torch.bfloat16,
                                         attn_implementation="sdpa")
    modelo, procesador, config = qwen.model, qwen.processor, qwen.model.config
    idioma_id = config.talker_config.codec_language_id["spanish"]

    entrenamiento = [json.loads(l) for l in (datos / "entrenamiento.jsonl").read_text(encoding="utf-8").splitlines()]
    validacion = [json.loads(l) for l in (datos / "validacion.jsonl").read_text(encoding="utf-8").splitlines()]

    # Huella de voz de la muestra, la misma para todos los clips (como
    # recomienda la receta). Queda guardada para el modelo final.
    referencia = librosa.load(entrenamiento[0]["ref_audio"], sr=24000)[0]
    mel = mel_spectrogram(torch.from_numpy(referencia)[None], n_fft=1024, num_mels=128, sampling_rate=24000,
                          hop_size=256, win_size=1024, fmin=0, fmax=12000).transpose(1, 2)
    with torch.no_grad():
        voz = modelo.speaker_encoder(mel.to(modelo.device).to(modelo.dtype)).detach()
    save_file({"voz": voz.cpu().float().contiguous()}, PUNTOS / "voz.safetensors")

    for p in modelo.parameters():
        p.requires_grad_(False)
    ajuste = LoraConfig(r=RANGO, lora_alpha=ALFA, lora_dropout=ABANDONO, target_modules=CAPAS)
    inject_adapter_in_model(ajuste, modelo.talker)
    entrenables = [p for p in modelo.talker.parameters() if p.requires_grad]
    for p in entrenables:
        p.data = p.data.float()
    print(f"parametros LoRA: {sum(p.numel() for p in entrenables) / 1e6:.1f} M", flush=True)
    (PUNTOS / "ajuste.json").write_text(json.dumps({
        "r": RANGO, "lora_alpha": ALFA, "lora_dropout": ABANDONO, "target_modules": CAPAS,
        "modelo_base": MODELO_BASE, "idioma": "spanish",
        "aprendizaje": APRENDIZAJE, "epocas": EPOCAS, "datos": str(datos),
        "clips": len(entrenamiento)}, indent=1), encoding="utf-8")

    optimizador = torch.optim.AdamW(entrenables, lr=APRENDIZAJE, weight_decay=0.01)
    pasos_epoca = math.ceil(len(entrenamiento) / LOTE / ACUMULAR)
    total = pasos_epoca * EPOCAS

    def ritmo(paso):
        if paso < CALENTAMIENTO:
            return (paso + 1) / CALENTAMIENTO
        avance = (paso - CALENTAMIENTO) / max(1, total - CALENTAMIENTO)
        return 0.1 + 0.9 * 0.5 * (1 + math.cos(math.pi * avance))

    planificador = torch.optim.lr_scheduler.LambdaLR(optimizador, ritmo)
    registro = []

    def validar():
        modelo.talker.eval()
        valores = []
        with torch.no_grad(), torch.autocast("cuda", dtype=torch.bfloat16):
            for i in range(0, len(validacion), LOTE):
                valores.append(perdida(modelo, lote_tensores(validacion[i:i + LOTE], procesador, config,
                                                             idioma_id, voz), voz)[0].item())
        modelo.talker.train()
        return float(np.mean(valores))

    # Para retomar si la computadora se apaga: al final de cada epoca se guarda
    # todo lo que hace falta para seguir desde ahi como si nada (el optimizador,
    # el ritmo de aprendizaje y el azar), no solo los pesos.
    reanudar = PUNTOS / "reanudar.pt"
    primera = 1
    paso = 0
    if a.reanudar and reanudar.exists():
        guardado = torch.load(reanudar, weights_only=False)
        set_peft_model_state_dict(modelo.talker, {k: v.to(modelo.device) for k, v in
                                                  load_file(PUNTOS / f"epoca_{guardado['epoca']:02d}.safetensors").items()})
        optimizador.load_state_dict(guardado["optimizador"])
        planificador.load_state_dict(guardado["planificador"])
        random.setstate(guardado["azar"]["random"])
        np.random.set_state(guardado["azar"]["numpy"])
        torch.set_rng_state(guardado["azar"]["torch"])
        torch.cuda.set_rng_state(guardado["azar"]["cuda"])
        paso, registro, primera = guardado["paso"], guardado["registro"], guardado["epoca"] + 1
        print(f"retomado despues de la epoca {guardado['epoca']}", flush=True)

    from progreso_comun import avance
    if primera == 1:
        print(f"epoca 0  validacion {validar():.4f}", flush=True)
    modelo.talker.train()
    for epoca in range(primera, EPOCAS + 1):
        inicio = time.time()
        random.shuffle(entrenamiento)
        acumulado = []
        for n in range(0, len(entrenamiento), LOTE):
            if n % (LOTE * 20) == 0:
                avance(f"época {epoca} de {EPOCAS}, clips", n, len(entrenamiento))
            lote = lote_tensores(entrenamiento[n:n + LOTE], procesador, config, idioma_id, voz)
            with torch.autocast("cuda", dtype=torch.bfloat16):
                total_l, _, _ = perdida(modelo, lote, voz)
            (total_l / ACUMULAR).backward()
            acumulado.append(total_l.item())
            if (n // LOTE + 1) % ACUMULAR == 0 or n + LOTE >= len(entrenamiento):
                torch.nn.utils.clip_grad_norm_(entrenables, 1.0)
                optimizador.step()
                planificador.step()
                optimizador.zero_grad(set_to_none=True)
                paso += 1

        val = validar()
        fila = {"epoca": epoca, "entrenamiento": float(np.mean(acumulado)), "validacion": val,
                "segundos": round(time.time() - inicio), "memoria_gb": round(torch.cuda.max_memory_allocated() / 2**30, 1)}
        registro.append(fila)
        print(f"epoca {epoca}  entrenamiento {fila['entrenamiento']:.4f}  validacion {val:.4f}  "
              f"{fila['segundos']} s  {fila['memoria_gb']} GB", flush=True)
        estado = {k: v.detach().cpu().contiguous() for k, v in get_peft_model_state_dict(modelo.talker).items()}
        save_file(estado, PUNTOS / f"epoca_{epoca:02d}.safetensors")
        (PUNTOS / "registro.json").write_text(json.dumps(registro, indent=1), encoding="utf-8")
        # Primero a un temporal: si se corta la luz justo al escribir, el
        # guardado anterior sigue entero.
        torch.save({"epoca": epoca, "paso": paso, "registro": registro, "optimizador": optimizador.state_dict(),
                    "planificador": planificador.state_dict(),
                    "azar": {"random": random.getstate(), "numpy": np.random.get_state(),
                             "torch": torch.get_rng_state(), "cuda": torch.cuda.get_rng_state()}},
                   reanudar.with_suffix(".tmp"))
        os.replace(reanudar.with_suffix(".tmp"), reanudar)

        # Pasado su mejor punto, el modelo memoriza: la validacion sube epoca
        # tras epoca. Cada epoca queda guardada, asi que parar no pierde nada.
        mejor = min(f["validacion"] for f in registro)
        peores = 0
        for f in reversed(registro):
            if f["validacion"] <= mejor:
                break
            peores += 1
        if a.paciencia and peores >= a.paciencia:
            print(f"la validacion empeoro {peores} epocas seguidas: termina en la epoca {epoca}", flush=True)
            break

    # Terminado, completo o por la paciencia: al relanzar no hay que seguir.
    (PUNTOS / "terminado.json").write_text(json.dumps({"epocas": len(registro)}), encoding="utf-8")


if __name__ == "__main__":
    main()
