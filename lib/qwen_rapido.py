"""Generacion mas rapida para Qwen3-TTS, con el mismo calculo.

Por cada sonido (80 ms de audio) Qwen3-TTS hace dos cosas: el modelo grande
elige el primer codigo, y un modelo chico de 5 capas elige los otros 15, uno
tras otro. La libreria llama para eso al generate() de transformers en cada
sonido, y ese generate() prepara cache, procesadores y criterios de parada
cada vez: la tarjeta pasa la mayor parte del tiempo esperando a Python.

Aqui los 15 pasos del modelo chico se graban una vez como un CUDA graph y se
repiten tal cual. Cada paso pasa por las mismas capas, los mismos pesos y el
mismo muestreo (temperatura, top-k y top-p, como transformers). La unica
diferencia es que no usa cache: en cada paso recalcula las 16 posiciones,
con la mascara causal, asi que cada posicion ve solo las anteriores, como
con cache. Con 16 posiciones el recalculo es casi gratis y deja las formas
fijas, que es lo que permite grabar el grafo.

Uso:
    import qwen_rapido
    qwen_rapido.activar(qwen.model)
"""

from types import SimpleNamespace

import torch

POSICIONES = 16  # el estado del modelo grande, el primer codigo y 14 codigos mas


class PredictorRapido:
    def __init__(self, predictor):
        self.p = predictor
        self.grafos = {}

    def _muestrear(self, logits, muestreo, temperatura, top_k, top_p):
        if not muestreo:
            return logits.argmax(-1)
        logits = logits.float() / temperatura
        if top_k and top_k < logits.shape[-1]:
            corte = torch.topk(logits, top_k, dim=-1).values[..., -1:]
            logits = logits.masked_fill(logits < corte, float("-inf"))
        if top_p < 1.0:
            orden, indices = torch.sort(logits, descending=False, dim=-1)
            acumulada = orden.softmax(-1).cumsum(-1)
            quitar = acumulada <= (1 - top_p)
            quitar[..., -1:] = False
            logits = logits.masked_fill(quitar.scatter(-1, indices, quitar), float("-inf"))
        return torch.multinomial(logits.softmax(-1), 1).squeeze(-1)

    def _pasos(self, g):
        """Los 15 pasos sobre los tensores fijos de g; es lo que se graba."""
        p, modelo = self.p, self.p.model
        entrada = g.entrada
        for paso in range(POSICIONES - 1):
            ocultos = p.small_to_mtp_projection(entrada)
            for capa in modelo.layers:
                ocultos = capa(ocultos, attention_mask=g.mascara, position_ids=g.posiciones,
                               position_embeddings=g.rotacion, use_cache=False)
                ocultos = ocultos[0] if isinstance(ocultos, tuple) else ocultos
            ocultos = modelo.norm(ocultos)
            codigo = self._muestrear(p.lm_head[paso](ocultos[:, paso + 1]), *g.muestreo)
            g.codigos[:, paso] = codigo
            if paso + 2 < POSICIONES:
                entrada = entrada.clone()
                entrada[:, paso + 2] = modelo.codec_embedding[paso](codigo)
        return g.codigos

    def _preparar(self, lote, muestreo, dispositivo, tipo):
        modelo = self.p.model
        tam = self.p.small_to_mtp_projection.in_features if hasattr(self.p.small_to_mtp_projection, "in_features") \
            else modelo.config.hidden_size
        g = SimpleNamespace()
        g.entrada = torch.zeros(lote, POSICIONES, tam, device=dispositivo, dtype=tipo)
        g.codigos = torch.zeros(lote, POSICIONES - 1, device=dispositivo, dtype=torch.long)
        g.posiciones = torch.arange(POSICIONES, device=dispositivo)[None].expand(lote, -1)
        causal = torch.ones(POSICIONES, POSICIONES, device=dispositivo, dtype=torch.bool).tril()
        g.mascara = torch.zeros(POSICIONES, POSICIONES, device=dispositivo, dtype=tipo).masked_fill(
            ~causal, torch.finfo(tipo).min)[None, None].expand(lote, 1, -1, -1)
        g.rotacion = modelo.rotary_emb(g.entrada, g.posiciones)
        g.muestreo = muestreo

        # Calentar fuera del grafo, como pide PyTorch, y despues grabar.
        flujo = torch.cuda.Stream()
        flujo.wait_stream(torch.cuda.current_stream())
        with torch.cuda.stream(flujo):
            for _ in range(2):
                self._pasos(g)
        torch.cuda.current_stream().wait_stream(flujo)
        g.grafo = torch.cuda.CUDAGraph()
        with torch.cuda.graph(g.grafo):
            g.salida = self._pasos(g)
        return g

    @torch.no_grad()
    def generar(self, inputs_embeds, do_sample=True, top_p=1.0, top_k=50, temperature=0.9, **_):
        lote = inputs_embeds.shape[0]
        muestreo = (bool(do_sample), float(temperature), int(top_k or 0), float(top_p))
        clave = (lote, muestreo)
        if clave not in self.grafos:
            self.grafos[clave] = self._preparar(lote, muestreo, inputs_embeds.device, inputs_embeds.dtype)
        g = self.grafos[clave]
        g.entrada.zero_()
        g.entrada[:, :2] = inputs_embeds
        g.grafo.replay()
        return SimpleNamespace(sequences=g.salida.clone())


def activar(modelo) -> None:
    """Cambia el generate() del modelo chico por la version grabada."""
    talker = modelo.talker
    rapido = PredictorRapido(talker.code_predictor)
    talker.code_predictor.generate = lambda inputs_embeds, max_new_tokens=None, do_sample=True, top_p=1.0, \
        top_k=50, temperature=0.9, **kw: rapido.generar(inputs_embeds, do_sample, top_p, top_k, temperature)
    talker._predictor_rapido = rapido
