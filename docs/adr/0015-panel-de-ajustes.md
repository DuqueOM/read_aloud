# 0015. Panel de ajustes en el reproductor, guardado aparte de settings.psd1, y dos modos de rendimiento

- **Estado:** aceptada. Agrega a la [0011](0011-recargar-qwen-y-reposo.md) el modo de ahorro.
- **Fecha:** 2 de noviembre de 2026

## Contexto

Todo lo ajustable estaba en `config\settings.psd1`: cambiar la opacidad o la
voz pedía editar el archivo y reiniciar el proceso residente a mano. Y la
[0011](0011-recargar-qwen-y-reposo.md) dejó la voz propia siempre cargada,
lo mejor para leer al instante, pero con 5 GB de la tarjeta y 2.3 GB de RAM
ocupados aunque no se lea en horas.

## Decisión

- **Un botón de tuerca en el reproductor abre un panel de ajustes**
  (`lib\ReadAloud.Settings.ps1`): apariencia, voz y lectura. Las opciones
  son pastillas y deslizadores, no listas desplegables, que en WPF vienen
  claras y desentonan sobre el fondo oscuro.
- **Lo que se elige ahí va a `runtime\ajustes.json`**, que
  `Get-ReadAloudSettings` aplica encima de `settings.psd1`, y solo con las
  claves que ya conoce. Reescribir `settings.psd1` desde el programa perdería
  sus comentarios y cambiaría un archivo del repositorio con cada clic.
- **La apariencia y la lectura se aplican al momento.** La voz, el
  rendimiento y la pausa entre frases van a los procesos de síntesis, que se
  abren al arrancar: el panel ofrece reiniciar el lector, que lanza otro
  proceso con `-EsperarA` (espera a que termine este, que tiene la instancia
  única) y sale.
- **Dos modos de rendimiento** (`Performance`):
  - `rapido`, el de la 0011: la voz se carga al arrancar y vuelve en cuanto
    la tarjeta queda libre. Primera frase en 1 o 2 s.
  - `ahorro`: no se carga al arrancar ni se recarga sola; la primera lectura
    la carga (medido: 27 s hasta la primera frase) y se libera tras
    `SaverIdleMinutes` sin leer.

## Alternativas

- **Una ventana de configuración aparte, fuera del reproductor:** otro
  programa que abrir. El reproductor ya está a mano mientras se lee.
- **Aplicar los cambios de voz sin reiniciar:** habría que cerrar y abrir los
  procesos de Piper y de Qwen desde el hilo de síntesis a mitad de una
  lectura; reiniciar el lector entero es más simple y tarda unos segundos.

## Consecuencias

- Para volver a lo de `settings.psd1`, el panel tiene "Restablecer todo", que
  borra `ajustes.json`.
- `settings.psd1` sigue siendo la base y la documentación de cada valor.
- La pestaña de arriba y la fila de velocidades (0.5x a 2x) no son ajustes:
  van en [configuracion.md](../configuracion.md#reproductor).
