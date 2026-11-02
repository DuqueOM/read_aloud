# 0014. Un solo proceso para cualquier voz: voz.toml y la validación elegida por el proceso

- **Estado:** aceptada
- **Fecha:** 2 de noviembre de 2026

## Contexto

Los scripts de `voz_personalizada\proceso_qwen` se copiaron tal como
corrieron con la voz de prueba, y traían fijo lo de esa voz:

- la carpeta de WSL y Descargas donde caían los videos, y que el nombre dijera
  "la voz de prueba";
- los nombres propios para los transcriptores, el capítulo duplicado, el
  nombre del hablante del modelo y el idioma español en cinco lugares;
- la ruta del repositorio de Read Aloud, y la cantidad de clips de la voz de prueba
  (1438) para saber si un paso había terminado.

Y algo más de fondo: las 10 frases de validación, con su audio real y sus
códigos, salieron del proceso anterior con RVC (`08_final`, `09d_comparar.py`
y `11a_datos_qwen.py`). Una voz nueva no tenía de dónde sacarlas.

## Decisión

- **`voz.toml` en la carpeta de trabajo, leído por `proceso_qwen\voz.py`**,
  como ya hacían los scripts de la primera versión con `comun.py`. Campos
  nuevos: `titulo`, `origenes`, `filtro_nombre`, `contexto`, `variantes`,
  `duplicados`, `minutos_finales` y `lector`. Los anteriores (`nombre`,
  `idioma`, `origen`, `patron_episodio`, `alineador`) siguen igual, así que
  un `voz.toml` viejo sirve.
- **`30_seleccion_final.py` aparta las frases de validación** si aún no hay:
  de 2 a 6 s, de buena calidad, de episodios distintos, con un texto que no
  se repite en otro clip, y al menos una pregunta y una exclamación.
  `31_conjunto_qwen.py` las limpia y codifica como al resto, y elige la
  muestra de referencia (el mejor clip de 5 a 10 s) si falta.
- **Los entrenamientos de `32_entrenar_final.py` se llaman por su conjunto**
  (`puntos_mejores60`, `puntos_todos`), no por la ronda de la voz de prueba (`v4`).
- **`instalar.ps1` copia los scripts a `<trabajo>\scripts`** (solo los que
  faltan) y llena `lector` en `voz.toml`.
- **Los experimentos (`33`, `34`) guardan sus opciones arriba de todo**, como
  constantes: cambian en cada uso, y un archivo de configuración para eso
  solo escondería qué se está comparando.

## Cómo se validó

Con un `voz.toml` de la voz de prueba, las versiones generalizadas dieron lo mismo que
las que corrieron: `seleccion.json`, el conjunto de 45 minutos, la página de
revisión y la de votación, idénticos byte a byte; la página de escucha, igual
salvo dos frases que ya no nombran el origen de las grabaciones. La elección de validación,
probada sobre los clips de la voz de prueba, dio 10 frases de 10 episodios, sin textos
repetidos, con pregunta y exclamación. `lote.py` lee los tres formatos de
nombre de los videos de la voz de prueba y descarta los de otro origen.

## Consecuencias

- Una voz nueva se hace sin editar ningún script.
- Con la voz de prueba, las frases de validación siguen siendo las de siempre: el
  formato viejo (`archivo` de `04_cortes`) y el nuevo (`clave` de
  `25_cortes`) se leen los dos.
- Volver a correr `32_entrenar_final.py` en la carpeta de la voz de prueba entrenaría
  de nuevo, con los nombres nuevos.
- `09d_comparar.py`, `09e_prosodia.py`, `11a_datos_qwen.py` y los `14*`
  quedan como historia de la primera voz.
- `FRASES_APP` de `34_votacion.py` está en español: para una voz de otro
  idioma hay que cambiarla.
