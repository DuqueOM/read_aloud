# 0009. Quitar el eco, pero no "mejorar" la voz

- **Estado:** aceptada
- **Fecha:** 28 de octubre de 2026

## Contexto

El audio de las grabaciones viene comprimido (AAC de 112 a 128 kbps), mezclado con
música y efectos, y algunas escenas tienen eco: recuerdos, sueños, lugares
grandes. Todo lo que hay en un clip, el modelo lo aprende como parte de la
voz.

## Decisión

- **Separar la voz** de la música y los efectos con **Mel-Band RoFormer**
  (`vocals_mel_band_roformer`), el de mejor calidad medida para voces en
  audio-separator.
- **Quitar el eco** de cada clip final con el **de-reverb mono de anvuew**
  (`dereverb_mel_band_roformer_mono_anvuew.ckpt`). Los modelos estéreo, aun
  los de mejor puntuación, devuelven intacto un audio mono como este: se
  comprobó agregando un eco artificial fuerte a un clip.
- **No usar resemble-enhance** ni reducción de ruido ni ecualización.
- Recortar el silencio de los extremos, dejando 60 ms, e **igualar el
  volumen** a −20 dB RMS, con el pico limitado a −1 dB.

## Medidas

Prueba a ciegas con ocho clips, cuatro versiones de cada uno al mismo volumen
y con letras al azar: original, sin eco, con resemble-enhance y con las dos
cosas.

- **Sin eco** fue la mejor, sola o seguida de resemble-enhance, en cuatro de
  los seis clips donde hubo preferencia, y nunca sonó artificial.
- El **original** sonó artificial en cuatro clips: el eco que dejó la
  separación.
- **resemble-enhance** sonó artificial en cuatro de los dieciséis clips en que
  se usó, solo o combinado.

## Consecuencias

- Un defecto que agregue un "mejorador" se aprende como timbre. Ante la duda,
  se quita el clip en vez de arreglarlo.
- Con otra voz conviene repetir la prueba (`07b_prueba.py`, con
  `instalar.ps1 -ConMejora`).
