# Cómo funciona por dentro

Este documento explica las decisiones de diseño, no solo qué hace cada
archivo. Si vas a modificar algo, empieza por aquí.

## El problema que resuelve la arquitectura

La versión anterior era un script suelto: cada vez que pulsabas el atajo,
Windows arrancaba PowerShell, PowerShell arrancaba `piper.exe`, y `piper.exe`
cargaba un modelo de voz de 63 MB desde el disco. Peor todavía, eso pasaba una
vez por cada fragmento de audio, no una vez por lectura.

El resultado era una espera de varios segundos sin ninguna señal de que algo
estuviera ocurriendo. Al no ver respuesta, lo natural era volver a pulsar el
atajo, y entonces sonaban dos lecturas encima de la otra.

Medido en esta máquina:

| Etapa | Antes | Ahora |
|---|---|---|
| Arranque de PowerShell | 400 a 800 ms | no ocurre |
| Carga del modelo de voz | 440 ms por fragmento | una vez, al iniciar sesión |
| Síntesis del primer fragmento | 300 ms | 60 a 200 ms |
| Orden aceptada | no había confirmación | 20 a 80 ms |

## Las tres piezas

### El proceso residente

`read_aloud_daemon.ps1` se queda vivo en segundo plano. Mantiene un proceso
`piper.exe` por idioma, cada uno con su modelo ya cargado, esperando trabajo
en su entrada estándar. Piper acepta líneas JSON con `--json-input`, y por
cada línea escribe un WAV y responde con su ruta. Eso es lo que permite
reutilizar el proceso en vez de reiniciarlo.

Dentro del residente hay tres hilos:

- **Tubería.** Escucha `\\.\pipe\read_aloud_pipe` y encola lo que llega.
- **Síntesis.** Toma fragmentos de la cola y se los pasa al Piper del idioma
  que corresponda.
- **Interfaz.** El hilo principal, con la ventana del reproductor y un pulso
  cada 60 ms que atiende órdenes, recoge audio terminado y refresca la barra.

Solo puede haber un residente a la vez. Lo garantiza un mutex con nombre; una
segunda instancia se cierra al arrancar. Sin eso, dos residentes se pelean por
la tubería y vuelve a aparecer el audio duplicado.

### El cliente

`read_aloud.ps1` es la puerta de entrada desde la consola. Manda la orden por
la tubería y termina. Si nadie responde, arranca el residente y reintenta. Si
tampoco así, sintetiza y reproduce por su cuenta con `-Direct`, que es más
lento pero no depende de nada.

`read_aloud_hotkey.ahk` no usa PowerShell en absoluto: abre la tubería
directamente desde AutoHotkey y escribe la línea JSON. Ese es el camino
rápido, y es el que usas todo el día.

### El reproductor

Una ventana WPF pequeña, sin bordes, siempre encima, que no roba el foco
(`ShowActivated="False"`). Esto último importa: si robara el foco, leer un
texto te sacaría del programa donde estás escribiendo.

La reproducción se apoya en `MediaPlayer`, que sí permite pausar y saltar,
a diferencia del `SoundPlayer` que usaba la versión anterior y que solo sabía
reproducir de principio a fin.

## Cómo se parte el texto

1. Se detecta el idioma del texto completo.
2. Se parte en frases.
3. Cada frase recibe su propio idioma, con reglas que evitan cambios bruscos.
4. Las frases contiguas del mismo idioma se agrupan en segmentos.
5. Cada segmento se normaliza según su idioma y se parte en fragmentos.

Cada fragmento es una frase. Solo se juntan con la siguiente las frases de
menos de 25 caracteres, que sonarían entrecortadas por sí solas.

Antes los fragmentos acumulaban frases hasta 220 caracteres. Se cambió por el
panel de texto: si un fragmento lleva tres frases, el reproductor sabe que
suena ese fragmento, pero no cuál de las tres. Con una frase por fragmento,
lo resaltado es exactamente lo que se oye.

Dividir más fino no le cuesta naturalidad a la voz, porque Piper ya sintetiza
cada frase por separado aunque le lleguen juntas. Y como los dos
reproductores encadenan los fragmentos sin hueco, tampoco se nota el cambio.
La primera palabra depende de la primera frase: con un título corto al
principio, sonó en 116 milisegundos en las pruebas.

Las frases se separan sobre el texto original y cada una se transforma para
la voz por separado. Hacerlo al revés podía desalinear lo mostrado de lo
oído, cuando una sustitución del diccionario quitaba o agregaba un punto.

Con un factor de tiempo real de 0.07, generar un fragmento cuesta alrededor
del 7 % de lo que dura su audio. Dicho de otro modo, la síntesis avanza unas
catorce veces más rápido que la reproducción, así que nunca la alcanza.

## Las pausas que marcan la estructura

Leer de corrido un informe con títulos y tablas suena plano: nada distingue el
final de una fila del punto y seguido de un párrafo. Por eso el texto se parte
primero en bloques según su forma visible.

| Bloque | Cómo se reconoce |
|---|---|
| Título | Línea corta sin puntuación final que abre bloque, o prefijo `#` |
| Fila de tabla | Línea con tabuladores, o con dos o más barras verticales |
| Viñeta | Línea que empieza por guion, asterisco o número con punto |
| Párrafo | El resto; las líneas seguidas se unen en uno solo |

La condición de "abre bloque" es la que evita el error obvio: en un texto con
los renglones cortados a lo ancho, cada línea termina sin punto y parecería un
título. Solo se considera título la que empieza un bloque, después de una
línea en blanco o de otro bloque.

El silencio no se reproduce como un archivo aparte. Se añade al final del WAV
del fragmento anterior, reescribiendo su cabecera. Hacerlo con un archivo
propio costaba el arranque de ese archivo, y una pausa de 0.18 s acababa
durando más de medio segundo.

## El panel de texto

Cada fragmento guarda dos textos: el que se pronuncia y el original. El panel
muestra el original, con una línea por bloque y un trozo por frase, y cada
trozo sabe a qué fragmento de audio corresponde. Resaltar la frase actual es
entonces cambiar el color del trozo cuyo fragmento está sonando, y un clic
sobre un trozo es un salto a su fragmento.

El panel se descartó como alternativa a resaltar en la ventana de donde se
copió el texto. Eso exigiría que cada programa expusiera la posición de sus
palabras en pantalla, y la mayoría no lo hace: VS Code, Slack, Teams, las
terminales y los visores de PDF quedarían fuera. El panel funciona igual sea
cual sea el origen del texto.

## Por qué hay dos reproductores

Abrir un archivo de audio cuesta alrededor de medio segundo. Con un solo
reproductor, esa espera caía entre cada par de fragmentos, así que todas las
transiciones sonaban igual de largas y las pausas de estructura se perdían
dentro del ruido.

Ahora hay dos. Mientras uno suena, el otro ya tiene abierto el fragmento
siguiente, y al terminar basta con darle a reproducir. El hueco entre
fragmentos bajó de 0.45 a 0.1 segundos, medido sobre el mismo texto, y las
únicas pausas que se oyen son las que el texto pide.

El reproductor activo se alterna entre los dos. Los eventos llegan a ambos, y
cada manejador comprueba si el que avisa es el que está sonando: al que solo
está precargando no se le hace caso.

## Cómo se descarta una lectura vieja

Cada lectura tiene un número de generación. Cuando llega una orden nueva, el
contador sube. Los fragmentos que estaban en cola siguen su curso, pero al
salir se compara su generación con la actual: si no coincide, se descartan y
se borra su WAV.

Esto es lo que hace que pulsar el atajo dos veces reemplace la lectura en
lugar de superponerla. Además, si el texto es idéntico al anterior y llegó
hace menos de un segundo y medio, se ignora por completo, para que una doble
pulsación involuntaria no reinicie lo que ya estaba sonando.

## Los archivos temporales

Cada fragmento se escribe como WAV en `read_aloud_piper\tmp` y se borra al
terminar de sonar. Cuando la lectura se cortaba a la fuerza, esos archivos
quedaban ahí para siempre: en esta máquina se habían acumulado 814 archivos y
820 MB antes de la limpieza.

Ahora el residente borra al arrancar todo WAV con más de seis horas. El plazo
se cambia con `MaxTmpAgeHours` en los ajustes.

## Por qué el diccionario y no el cambio de voz

Detectar idioma palabra por palabra es poco fiable y suena mal: la voz salta
en mitad de una frase y el oído lo nota como un corte. Por eso el cambio de
voz solo ocurre en frases completas con evidencia clara, y los términos
sueltos se resuelven reescribiéndolos.

Reescribir `deploy` como `diplói` hace que la voz española lo pronuncie como
lo pronuncias tú al hablar. Es una solución de ortografía, no de fonética, y
tiene la ventaja de que puedes corregirla tú mismo editando un archivo de
texto.
