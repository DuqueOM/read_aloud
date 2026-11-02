"""Comprueba que qwen_rapido.py calcula lo mismo y mide cuanto acelera.

1. Mismo calculo: con muestreo apagado (siempre el codigo mas probable), el
   modelo chico de la libreria y el grabado reciben las mismas entradas
   reales, sacadas de una frase, y tienen que elegir los mismos codigos. Por
   redondeo de bf16 puede cambiar alguno muy parejo, pero deben coincidir casi
   todos.
2. Fundir LoRA en los pesos: la primera prediccion del modelo grande en cada
   frase, antes y despues de fundir, tiene que ser practicamente la misma
   distribucion (divergencia KL cercana a cero).
3. Velocidad: las 10 frases de prueba, de a 1 y de a varias, como en
   14_velocidad.py, con LoRA fundido y el modelo chico grabado, y los audios
   para escucharlos y medirlos.

Corre en el entorno de Qwen:
    .venv_qwen/Scripts/python.exe scripts/14b_rapido.py
"""

import importlib.util
import json
import os
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
os.environ.setdefault("HF_HOME", str(RAIZ / "modelos" / "hf"))
import voz  # noqa: E402
sys.path.insert(0, str(voz.lector() / "lib"))  # qwen_rapido vive con el servidor de Read Aloud

import torch
from peft import set_peft_model_state_dict
from safetensors.torch import load_file

import qwen_rapido


def cargar(nombre):
    spec = importlib.util.spec_from_file_location(nombre, Path(__file__).parent / f"{nombre}.py")
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo


velocidad = cargar("14_velocidad")
probar = velocidad.probar


def main() -> None:
    frases = [f["texto"] for f in json.loads((RAIZ / "datos" / "09_comparar" / "frases.json").read_text(encoding="utf-8"))]
    probar.PUNTOS = velocidad.PUNTOS
    qwen = probar.preparar()
    estado = load_file(velocidad.PUNTOS / f"epoca_{velocidad.EPOCA:02d}.safetensors")
    set_peft_model_state_dict(qwen.model.talker, {k: v.to(qwen.model.device) for k, v in estado.items()})
    predictor = qwen.model.talker.code_predictor

    # 1. Se guardan las entradas reales del modelo chico durante una frase.
    entradas = []
    original = predictor.generate

    def espiar(inputs_embeds, **kw):
        entradas.append(inputs_embeds.clone())
        return original(inputs_embeds=inputs_embeds, **kw)

    predictor.generate = espiar
    velocidad.generar(qwen, frases[:2])
    predictor.generate = original

    # Un codigo distinto cambia todos los que vienen despues en ese sonido, asi
    # que se mide de dos formas: la generacion completa, y paso por paso con
    # los codigos de la libreria como historia (lo que de verdad dice si el
    # calculo es el mismo).
    rapido = qwen_rapido.PredictorRapido(predictor)
    iguales = total = guiados = 0
    with torch.no_grad():
        for x in entradas:
            libreria = original(inputs_embeds=x, max_new_tokens=15, do_sample=False,
                                output_hidden_states=True, return_dict_in_generate=True).sequences
            grabado = rapido.generar(x, do_sample=False).sequences
            iguales += (libreria == grabado).sum().item()
            total += libreria.numel()

            historia = torch.zeros(x.shape[0], qwen_rapido.POSICIONES, x.shape[2], device=x.device, dtype=x.dtype)
            historia[:, :2] = x
            for k in range(qwen_rapido.POSICIONES - 2):
                historia[:, k + 2] = predictor.model.codec_embedding[k](libreria[:, k])
            ocultos = predictor.small_to_mtp_projection(historia)
            posiciones = torch.arange(qwen_rapido.POSICIONES, device=x.device)[None].expand(x.shape[0], -1)
            causal = torch.ones(qwen_rapido.POSICIONES, qwen_rapido.POSICIONES, device=x.device, dtype=torch.bool).tril()
            mascara = torch.zeros(causal.shape, device=x.device, dtype=x.dtype).masked_fill(
                ~causal, torch.finfo(x.dtype).min)[None, None].expand(x.shape[0], 1, -1, -1)
            rotacion = predictor.model.rotary_emb(ocultos, posiciones)
            for capa in predictor.model.layers:
                ocultos = capa(ocultos, attention_mask=mascara, position_ids=posiciones,
                               position_embeddings=rotacion, use_cache=False)[0]
            ocultos = predictor.model.norm(ocultos)
            for k in range(qwen_rapido.POSICIONES - 1):
                guiados += (predictor.lm_head[k](ocultos[:, k + 1]).argmax(-1) == libreria[:, k]).sum().item()
    print(f"mismos codigos con muestreo apagado: generacion completa {100 * iguales / total:.2f} %, "
          f"paso a paso {100 * guiados / total:.2f} % de {total}", flush=True)
    informe = {"coincidencia_completa": iguales / total, "coincidencia_paso_a_paso": guiados / total}

    # 2. Fundir LoRA redondea los pesos a bf16. Se compara lo que predice el
    # modelo grande antes y despues, con las mismas entradas: la primera
    # prediccion de cada frase, sin muestreo.
    def primeras_predicciones():
        salidas = []
        gancho = qwen.model.talker.codec_head.register_forward_hook(
            lambda m, entrada, salida: salidas.append(salida[:, -1].float().log_softmax(-1)))
        qwen.generate_custom_voice(text=frases, language=["Spanish"] * len(frases), speaker=[probar.VOZ] * len(frases),
                                   non_streaming_mode=True, max_new_tokens=4, do_sample=False)
        gancho.remove()
        return salidas[0]

    antes = primeras_predicciones()
    velocidad.fundir(qwen.model.talker)
    despues = primeras_predicciones()
    kl = (antes.exp() * (antes - despues)).sum(-1)
    informe["fundir_kl_media"] = kl.mean().item()
    informe["fundir_kl_max"] = kl.max().item()
    informe["fundir_mismo_primero"] = (antes.argmax(-1) == despues.argmax(-1)).float().mean().item()
    informe["fundir_prob_elegida"] = [round(p, 4) for p in antes.exp().max(-1).values.tolist()]
    print(f"fundir: KL media {informe['fundir_kl_media']:.5f}, max {informe['fundir_kl_max']:.5f}, "
          f"mismo codigo mas probable {100 * informe['fundir_mismo_primero']:.0f} %", flush=True)

    # 3. Velocidad con LoRA fundido y el modelo chico grabado.
    qwen_rapido.activar(qwen.model)
    (velocidad.SALIDA / "rapido").mkdir(parents=True, exist_ok=True)
    informe["rapido"] = velocidad.medir(qwen, frases, "rapido", velocidad.SALIDA / "rapido")
    informe["memoria_gb"] = round(torch.cuda.max_memory_allocated() / 1e9, 2)
    (velocidad.SALIDA / "rapido.json").write_text(json.dumps(informe, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
