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

Dentro del residente hay cuatro hilos:

- **Tubería.** Escucha `\\.\pipe\read_aloud_pipe` y encola lo que llega.
- **Síntesis.** Toma fragmentos de la cola y se los pasa al Piper del idioma
  que corresponda.
- **Traducción.** Abre los traductores cuando hacen falta, traduce por partes
  y avisa de cada una (ver [La traducción](#la-traducción)).
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

Los atajos de teclado no pasan por la tubería: el propio proceso residente
los registra en Windows (`RegisterHotKey`, en `lib/ReadAloud.Hotkeys.ps1`) y
Windows le avisa al pulsarlos. No hay ningún otro programa corriendo para los
atajos, y la orden se atiende al instante. Para leer lo seleccionado, el
residente espera a que sueltes las teclas, manda Ctrl+C a la ventana activa y
devuelve el portapapeles a como estaba. El icono de la bandeja del sistema,
junto al reloj, muestra que está activo y tiene "Salir de Read Aloud", que
cierra el residente y libera los atajos.

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

Una frase termina en un punto, una pregunta o una exclamación seguidos de
espacio, salvo que la palabra siguiente empiece en minúscula ("a las 3 p. m.
con", "no sé... y se fue") o que el punto sea de una abreviatura: títulos
(Sr., Dra., Lic., Mr., Mrs.), formas como p. ej., EE. UU., a. m., e.g., i.e.,
U.S., pág. o aprox., iniciales sueltas ("J. K.") y "No." o un mes en inglés
delante de una cifra. "etc." delante de una mayúscula sí cierra la frase. Un
corte de más es un fragmento de audio aparte, con su silencio y su tono de
final en medio de la frase; uno de menos solo junta dos frases en un
fragmento, y la voz lee el punto igual. Por eso, ante la duda, no se corta.

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

Antes de pegarle la pausa del final del bloque, el hilo de síntesis guarda una
copia de cada WAV en `tmp\cache`, con una clave hecha del motor que de verdad lo
generó, la voz, el idioma, el texto y los ajustes que cambian el sonido. La
pausa no va en la copia porque depende del lugar de la frase. Al empezar una
lectura, cada frase con copia vigente se copia a su WAV y llega al reproductor
por el mismo camino que lo recién generado, sin pasar por la cola de la voz.
Copiar un archivo cuesta milisegundos y no ocupa RAM, que es lo que más escasea
con la voz propia cargada. Lo guardado caduca a los `AudioCacheMinutes` sin
usarse y tiene un tope de `AudioCacheMB`.

## La traducción

El atajo de traducir copia lo seleccionado igual que el de leer y se lo pasa al
hilo de traducción, que hace todo lo lento: elegir el traductor, abrirlo y
traducir. El hilo de la interfaz solo recibe lo que va saliendo.

**La elección.** Cada traducción toma una foto del equipo: la memoria libre de
la tarjeta (nvidia-smi), la RAM disponible, los núcleos y si la voz propia está
cargada. Con ella, `Select-TranslationCombo` puntúa cada combinación de voz,
traductor y lugar que cabe en la memoria: la calidad de la traducción y la de la
voz, menos lo que tarda el primer sonido y lo que se frena la voz. Las reglas de
memoria, las cifras y el porqué están en el
[ADR 0016](adr/0016-traduccion-local.md).

**Los procesos.** Bergamot corre en `translateLocally.exe -p`, que recibe
mensajes JSON con su largo en cuatro bytes delante y deja el modelo cargado,
como Piper. Los modelos de lenguaje corren en `llama-server.exe`, que escucha
solo en 127.0.0.1 y responde en streaming. Los dos se abren con la primera
traducción y se cierran tras `TranslateIdleMinutes` sin uso. Si la voz propia
tiene que ceder la tarjeta, el hilo de síntesis la cierra entre dos grupos y lee
con Piper hasta que vuelva; la voz propia sabe, por un archivo de reserva, que
la memoria que toma el traductor es de Read Aloud y no de otro programa, y no
cede por error.

**Por partes.** Con los modelos de lenguaje la primera frase se traduce sola y
después, párrafo por párrafo. Cada parte que llega se añade a la lectura en
curso: se planifica con la voz del idioma de destino, sus frases entran al final
de la lista de fragmentos y a la cola de la voz, y su párrafo aparece en el
panel. Por eso la primera frase suena mientras se traduce el resto. Si la
lectura llega al final antes que la traducción, espera la parte siguiente. El
panel se arma con el comienzo de la traducción: un párrafo por bloque con el
original en pequeño debajo, que se llena a medida que llegan las partes.

Pasar a otra lectura corta la traducción en la parte siguiente: el hilo de
traducción mira, antes de cada parte, si el reproductor todavía la quiere.

## Por qué el diccionario y no el cambio de voz

Detectar idioma palabra por palabra es poco fiable y suena mal: la voz salta
en mitad de una frase y el oído lo nota como un corte. Por eso el cambio de
voz solo ocurre en frases completas con evidencia clara, y los términos
sueltos se resuelven reescribiéndolos.

Reescribir `deploy` como `diplói` hace que la voz española lo pronuncie como
lo pronuncias tú al hablar. Es una solución de ortografía, no de fonética, y
tiene la ventaja de que puedes corregirla tú mismo editando un archivo de
texto.
