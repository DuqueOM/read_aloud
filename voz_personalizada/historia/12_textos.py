"""Pagina para corregir a mano las transcripciones del conjunto.

Qwen3-TTS aprende de la pareja texto y audio, asi que un texto equivocado le
ensena una pronunciacion equivocada. La pagina muestra los clips del conjunto
final con su texto editable, empezando por los que tienen la palabra mas
dudosa segun Whisper, que es donde suelen estar los errores.

Al terminar, "Exportar correcciones" descarga solo los textos cambiados.
Guardado como datos/11_qwen/correcciones.json, 11a_datos_qwen.py los usa.

Solo usa la biblioteca estandar:
    python scripts/12_textos.py
"""

import json
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
CONJUNTO = RAIZ / "datos" / "08_final" / "mi_voz_es"
CORTES = RAIZ / "datos" / "04_cortes"
ALINEADO = RAIZ / "datos" / "03_alineado"
PAGINA = RAIZ / "datos" / "11_qwen" / "textos.html"

# Por debajo de esta probabilidad de Whisper, una palabra se marca como dudosa.
DUDOSA = 0.6


def main() -> None:
    final = {a.name for a in CONJUNTO.glob("*.wav")}
    clips = []
    for indice in sorted(CORTES.glob("ep*/indice.json")):
        episodio = indice.parent.name
        palabras = json.loads((ALINEADO / f"{episodio}.json").read_text(encoding="utf-8"))["palabras"]
        for clip in json.loads(indice.read_text(encoding="utf-8"))["clips"]:
            if clip["archivo"] not in final:
                continue
            dentro = [p for p in palabras if p["inicio"] >= clip["inicio"] - 0.05 and p["fin"] <= clip["fin"] + 0.05]
            clips.append(
                {
                    "archivo": clip["archivo"],
                    "texto": clip["texto"],
                    "dudosas": sorted({p["texto"].strip(" ,.¿?¡!") for p in dentro if p["prob"] < DUDOSA}),
                    "minimo": min((p["prob"] for p in dentro), default=1.0),
                }
            )
    clips.sort(key=lambda c: c["minimo"])

    datos = json.dumps(clips, ensure_ascii=False).replace("</", "<\\/")
    PAGINA.write_text(PLANTILLA.replace("/*CLIPS*/[]", datos), encoding="utf-8")
    print(f"{len(clips)} clips, {sum(1 for c in clips if c['dudosas'])} con palabras dudosas")
    print(f"pagina: {PAGINA}")


PLANTILLA = """<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Corregir transcripciones</title>
<style>
 :root { --fondo:#16161a; --panel:#1f1f25; --borde:#2e2e36; --texto:#e6e6ea; --tenue:#8a8a94;
         --si:#4ade80; --aviso:#facc15; --acento:#60a5fa; }
 body { margin:0; background:var(--fondo); color:var(--texto); font:14px/1.45 "Segoe UI",system-ui,sans-serif; }
 header { position:sticky; top:0; z-index:2; background:var(--fondo); border-bottom:1px solid var(--borde);
          padding:12px 20px; }
 h1 { font-size:16px; margin:0 0 6px; font-weight:600; }
 .ayuda { color:var(--tenue); margin:0 0 10px; max-width:900px; }
 .barra { display:flex; flex-wrap:wrap; gap:10px; align-items:center; }
 .barra span { color:var(--tenue); }
 button { font:inherit; border:1px solid var(--borde); background:#2a2a32; color:var(--texto);
          border-radius:6px; padding:5px 12px; cursor:pointer; }
 button.principal { border-color:var(--acento); }
 label { color:var(--tenue); display:flex; gap:6px; align-items:center; }
 main { padding:12px 20px 40px; max-width:980px; }
 .clip { display:grid; grid-template-columns:34px 1fr; gap:4px 10px; padding:8px 10px;
         border:1px solid transparent; border-radius:8px; }
 .clip.activo { background:var(--panel); border-color:var(--borde); }
 .clip.cambiado input { border-color:var(--si); }
 .tocar { width:34px; height:34px; padding:0; border-radius:50%; }
 input[type=text] { width:100%; box-sizing:border-box; font:15px/1.4 inherit; color:var(--texto);
                    background:#121216; border:1px solid var(--borde); border-radius:6px; padding:6px 8px; }
 .info { grid-column:2; color:var(--tenue); font-size:12px; }
 .info b { color:var(--aviso); font-weight:500; }
 .info .original { color:var(--tenue); text-decoration:line-through; }
 kbd { font:12px ui-monospace,Consolas,monospace; background:#2a2a32; border:1px solid var(--borde);
       border-radius:4px; padding:0 4px; }
 @media (max-width:560px) { header, main { padding-left:16px; padding-right:16px; } }
</style></head><body>
<header>
 <h1>Corregir transcripciones</h1>
 <p class="ayuda">Corrige solo lo que esté mal: lo que no toques se queda como está. Arriba van los clips
 con alguna palabra dudosa (en amarillo), donde suelen estar los errores. Al entrar en un texto suena su clip.
 <kbd>Enter</kbd> pasa al siguiente, <kbd>Ctrl</kbd>+<kbd>Espacio</kbd> lo repite, <kbd>Esc</kbd> deshace el cambio.
 Los cambios se guardan solos en este navegador.</p>
 <div class="barra">
  <label><input type="checkbox" id="solo" checked> solo los dudosos</label>
  <label><input type="checkbox" id="auto" checked> sonar al entrar</label>
  <span id="cuenta"></span>
  <button class="principal" id="exportar">Exportar correcciones</button>
 </div>
</header>
<main id="lista"></main>
<audio id="audio"></audio>
<script>
const CLIPS = /*CLIPS*/[];
const CLAVE = 'mi_voz_correcciones_v1';
let cambios = {};
try { cambios = JSON.parse(localStorage.getItem(CLAVE) || '{}'); } catch (e) { cambios = {}; }
const guardar = () => { try { localStorage.setItem(CLAVE, JSON.stringify(cambios)); } catch (e) {} };
const audio = document.getElementById('audio');
const lista = document.getElementById('lista');
const ruta = a => '../08_final/mi_voz_es/' + a;
const tocar = c => { audio.src = ruta(c.archivo); audio.currentTime = 0; audio.play(); };

function contar() {
  const visibles = lista.querySelectorAll('.clip:not([hidden])').length;
  document.getElementById('cuenta').textContent =
    `${visibles} clips a la vista · ${Object.keys(cambios).length} corregidos`;
}

function filtrar() {
  const solo = document.getElementById('solo').checked;
  lista.querySelectorAll('.clip').forEach((f, i) => { f.hidden = solo && !CLIPS[i].dudosas.length; });
  contar();
}

CLIPS.forEach((c, i) => {
  const fila = document.createElement('div');
  fila.className = 'clip';
  fila.innerHTML = '<button class="tocar" title="Escuchar">▶</button><input type="text" spellcheck="true">' +
    '<div class="info"></div>';
  const entrada = fila.querySelector('input');
  const info = fila.querySelector('.info');
  entrada.value = cambios[c.archivo] ?? c.texto;

  const pintar = () => {
    const cambiado = c.archivo in cambios;
    fila.classList.toggle('cambiado', cambiado);
    info.innerHTML = '';
    if (c.dudosas.length) {
      info.append('dudosas: ');
      c.dudosas.forEach((d, k) => { const b = document.createElement('b'); b.textContent = d; info.append(b);
                                    if (k < c.dudosas.length - 1) info.append(', '); });
    }
    if (cambiado) {
      if (c.dudosas.length) info.append(' · ');
      const o = document.createElement('span'); o.className = 'original'; o.textContent = c.texto; info.append(o);
    }
  };
  pintar();

  fila.querySelector('.tocar').onclick = () => tocar(c);
  entrada.onfocus = () => {
    lista.querySelectorAll('.clip.activo').forEach(f => f.classList.remove('activo'));
    fila.classList.add('activo');
    if (document.getElementById('auto').checked) tocar(c);
  };
  entrada.oninput = () => {
    const v = entrada.value.trim();
    if (v && v !== c.texto) cambios[c.archivo] = v; else delete cambios[c.archivo];
    guardar(); pintar(); contar();
  };
  entrada.onkeydown = e => {
    if (e.key === 'Enter') {
      e.preventDefault();
      let siguiente = fila.nextElementSibling;
      while (siguiente && siguiente.hidden) siguiente = siguiente.nextElementSibling;
      if (siguiente) siguiente.querySelector('input').focus();
    } else if (e.key === ' ' && e.ctrlKey) {
      e.preventDefault(); tocar(c);
    } else if (e.key === 'Escape') {
      entrada.value = c.texto; delete cambios[c.archivo]; guardar(); pintar(); contar();
    }
  };
  lista.append(fila);
});

document.getElementById('solo').onchange = filtrar;
document.getElementById('exportar').onclick = () => {
  const datos = JSON.stringify(cambios, null, 1);
  const enlace = document.createElement('a');
  enlace.href = URL.createObjectURL(new Blob([datos], { type: 'application/json' }));
  enlace.download = 'correcciones.json';
  enlace.click();
};
filtrar();
</script>
</body></html>
"""


if __name__ == "__main__":
    main()
