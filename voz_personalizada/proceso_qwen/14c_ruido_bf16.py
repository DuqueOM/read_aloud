"""¿Las diferencias del modelo chico grabado son solo redondeo de bf16?

14b_rapido.py encontro que, paso a paso, el modelo chico grabado elige el
mismo codigo que la libreria el 94.5 % de las veces con muestreo apagado. Para
saber si el resto es redondeo o un error de calculo, se compara contra el
piso de ruido de la propia libreria: la misma libreria con cache y sin cache
(sin cache recalcula todo, como el grabado) tambien difiere un poco en bf16.

Se mide, sobre las mismas entradas reales:
- la divergencia KL entre las distribuciones de cada paso;
- en los pasos donde cambia el codigo elegido, que tan parejos estaban los
  dos primeros candidatos.

Si el grabado se aleja de la libreria lo mismo que la libreria sin cache, el
calculo es el mismo.

Corre en el entorno de Qwen:
    .venv_qwen/Scripts/python.exe scripts/14c_ruido_bf16.py
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

spec = importlib.util.spec_from_file_location("velocidad", Path(__file__).parent / "14_velocidad.py")
velocidad = importlib.util.module_from_spec(spec)
spec.loader.exec_module(velocidad)
probar = velocidad.probar
P = qwen_rapido.POSICIONES


def guiado(predictor, x, codigos):
    """Logits de cada paso del modelo chico grabado, con la historia dada."""
    historia = torch.zeros(x.shape[0], P, x.shape[2], device=x.device, dtype=x.dtype)
    historia[:, :2] = x
    for k in range(P - 2):
        historia[:, k + 2] = predictor.model.codec_embedding[k](codigos[:, k])
    ocultos = predictor.small_to_mtp_projection(historia)
    posiciones = torch.arange(P, device=x.device)[None].expand(x.shape[0], -1)
    causal = torch.ones(P, P, device=x.device, dtype=torch.bool).tril()
    mascara = torch.zeros(causal.shape, device=x.device, dtype=x.dtype).masked_fill(
        ~causal, torch.finfo(x.dtype).min)[None, None].expand(x.shape[0], 1, -1, -1)
    rotacion = predictor.model.rotary_emb(ocultos, posiciones)
    for capa in predictor.model.layers:
        ocultos = capa(ocultos, attention_mask=mascara, position_ids=posiciones,
                       position_embeddings=rotacion, use_cache=False)[0]
    ocultos = predictor.model.norm(ocultos)
    return torch.stack([predictor.lm_head[k](ocultos[:, k + 1]) for k in range(P - 1)], dim=1)


def libreria(predictor, x, cache, codigos=None):
    """Logits de cada paso de la libreria. Con codigos, se le fuerza esa historia."""
    if codigos is None:
        salida = predictor.generate(inputs_embeds=x, max_new_tokens=P - 1, do_sample=False, use_cache=cache,
                                    output_logits=True, return_dict_in_generate=True)
        return torch.stack(salida.logits, dim=1), salida.sequences
    pasos = []
    for k in range(P - 1):
        entrada = x if k == 0 else torch.cat([x] + [predictor.model.codec_embedding[j](codigos[:, j:j + 1])
                                                     for j in range(k)], dim=1)
        # Sin cache, la libreria recalcula todas las posiciones en cada paso.
        ocultos = predictor.model(inputs_embeds=predictor.small_to_mtp_projection(entrada), use_cache=False)
        pasos.append(predictor.lm_head[k](ocultos.last_hidden_state[:, -1]))
    return torch.stack(pasos, dim=1), None


def comparar(a, b):
    la, lb = a.float().log_softmax(-1), b.float().log_softmax(-1)
    kl = (la.exp() * (la - lb)).sum(-1)
    distinto = a.argmax(-1) != b.argmax(-1)
    dos = a.float().softmax(-1).topk(2, dim=-1).values
    brecha = (dos[..., 0] - dos[..., 1])[distinto]
    return {"kl_media": kl.mean().item(), "kl_p99": kl.flatten().quantile(0.99).item(),
            "mismo_codigo": 1 - distinto.float().mean().item(),
            "brecha_media_donde_cambia": brecha.mean().item() if brecha.numel() else 0.0}


def main() -> None:
    frases = [f["texto"] for f in json.loads((RAIZ / "datos" / "09_comparar" / "frases.json").read_text(encoding="utf-8"))]
    probar.PUNTOS = velocidad.PUNTOS
    qwen = probar.preparar()
    estado = load_file(velocidad.PUNTOS / f"epoca_{velocidad.EPOCA:02d}.safetensors")
    set_peft_model_state_dict(qwen.model.talker, {k: v.to(qwen.model.device) for k, v in estado.items()})
    predictor = qwen.model.talker.code_predictor

    entradas = []
    original = predictor.generate

    def espiar(inputs_embeds, **kw):
        entradas.append(inputs_embeds.clone())
        return original(inputs_embeds=inputs_embeds, **kw)

    predictor.generate = espiar
    velocidad.generar(qwen, frases[:2])
    predictor.generate = original
    entradas = entradas[::4]

    resultados = {"libreria_sin_cache": [], "grabado": []}
    with torch.no_grad():
        for x in entradas:
            con_cache, codigos = libreria(predictor, x, cache=True)
            sin_cache, _ = libreria(predictor, x, cache=False, codigos=codigos)
            resultados["libreria_sin_cache"].append((con_cache, sin_cache))
            resultados["grabado"].append((con_cache, guiado(predictor, x, codigos)))

    informe = {}
    for nombre, pares in resultados.items():
        a = torch.cat([p[0] for p in pares]); b = torch.cat([p[1] for p in pares])
        informe[nombre] = comparar(a, b)
        print(nombre, json.dumps({k: round(v, 5) for k, v in informe[nombre].items()}), flush=True)
    (velocidad.SALIDA / "ruido_bf16.json").write_text(json.dumps(informe, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
