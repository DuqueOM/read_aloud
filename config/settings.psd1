#
# Ajustes de Read Aloud.
# Cambia lo que quieras aqui y reinicia el proceso residente: se cierra asi y
# la proxima lectura lo arranca con los ajustes nuevos (docs\configuracion.md).
#   . .\lib\ReadAloud.Core.ps1
#   Send-ReadAloudCommand -PipeName 'read_aloud_pipe' -Command @{ cmd = 'quit' }
#
# Si borras este archivo, el programa sigue funcionando con estos mismos
# valores por defecto.

@{
    # Nombre del modelo, sin la extension .onnx. Debe existir en
    # read_aloud_piper\voices. Mira las disponibles con -ListVoices.
    VoiceEs = 'es_MX-claude-high'
    VoiceEn = 'en_US-lessac-high'

    # Motor de cada idioma: 'auto', 'piper' o 'qwen'. Con 'auto' se lee con
    # la voz propia entrenada con Qwen3-TTS (docs\voz-personalizada.md) si
    # esta en QwenWorkDir y el equipo tiene una tarjeta NVIDIA de al menos
    # QwenMinVramGB; si no, con la voz de Piper de arriba. 'piper' fuerza
    # Piper. Si Qwen falla mientras lee, se sigue con Piper.
    EngineEs = 'auto'
    EngineEn = 'auto'
    # La carpeta de trabajo de la voz propia es de cada equipo: ponla en
    # config\settings.local.psd1, que no se versiona y manda sobre este
    # archivo. Vacia, no hay voz propia.
    QwenWorkDir = ''
    QwenMinVramGB = 7

    # Frases que se generan juntas con Qwen: mas es mas rapido en total, pero
    # cada grupo tarda mas en estar listo.
    QwenBatch = 4

    # Tope de caracteres por grupo: un grupo de frases largas tardaria en
    # estar listo y retrasaria a las que esperan detras. 0 = sin tope.
    QwenBatchChars = 320

    # Qwen tarda unos 20 s en cargar, asi que se queda abierto (ocupa unos
    # 5 GB de la tarjeta grafica y 2.3 GB de RAM) y se cierra solo cuando otro
    # programa necesita la tarjeta. Con un numero mayor que 0, tambien se
    # cierra tras esos minutos sin leer, y entonces espera a la lectura
    # siguiente para volver a cargar.
    QwenIdleMinutes = 0

    # Si la lectura llega cuando Qwen aun esta cargando, espera hasta esos
    # segundos desde que arranco; pasados, lee con Piper hasta que Qwen
    # termine de cargar, en vez de dejar la lectura muda.
    QwenLoadWaitSeconds = 6

    # Si Qwen cedio la tarjeta, se vuelve a cargar en cuanto queden libres
    # QwenReopenFreeGB, para que la lectura siguiente no espere la carga.
    QwenReopen = $true
    QwenReopenFreeGB = 6

    # Rendimiento de la voz propia. 'rapido' la deja cargada: cada lectura
    # empieza en 1 o 2 s. 'ahorro' la carga con la primera lectura (unos 20 s)
    # y la libera tras SaverIdleMinutes sin leer. Tambien se cambia desde el
    # panel de ajustes del reproductor (la tuerca), que manda sobre esto.
    Performance = 'rapido'
    SaverIdleMinutes = 5

    # Velocidad. Mas alto es mas lento. 1.00 es la velocidad base del modelo.
    LengthScale = 1.06

    # Silencio en segundos despues de cada frase.
    SentenceSilence = 0.36

    # Variacion de la voz. Cambialos solo si quieres experimentar.
    NoiseScale = 0.667
    NoiseW = 0.8

    # Cada frase es un fragmento de audio, y es lo que se resalta en el panel
    # de texto. Las frases mas cortas que esto se juntan con la siguiente para
    # que no suenen entrecortadas.
    MinChunkChars = 25

    # Una frase mas larga que esto se parte donde se haria una pausa (; : una
    # coma, una raya). El primer fragmento de cada lectura usa FirstChunkChars,
    # el segundo uno y medio de eso, y el resto MaxChunkChars: asi la voz
    # empieza pronto y no hay un fragmento largo que retrase a los demas.
    # MaxChunkChars = 0 desactiva el partido.
    FirstChunkChars = 70
    MaxChunkChars = 180

    # Idioma que se usa cuando el texto es demasiado corto o ambiguo.
    FallbackLanguage = 'es'

    # Reproductor flotante.
    ShowPlayer = $true
    PlayerAutoClose = $true
    # Opacidad en reposo, de 0.3 a 1.0. Al hacer clic sobre el reproductor se
    # vuelve opaco del todo, y al hacer clic fuera regresa a este valor.
    PlayerOpacity = 0.75
    # Tema de color del reproductor y de los ajustes: 'system' (el de Windows),
    # 'dark' o 'light'. Acento: green, blue, purple, pink, orange, red, teal o
    # yellow. Se aplican al reiniciar el lector.
    # Idioma de la interfaz: 'auto' (el de Windows), 'es' o 'en'.
    Language = 'auto'
    Theme = 'system'
    Accent = 'green'
    SkipSeconds = 10

    # Atajos de teclado globales. Formato: modificadores y tecla unidos con +,
    # por ejemplo 'Ctrl+Alt+V'. Modificadores: Ctrl, Alt, Shift, Win. Teclas:
    # letras, cifras, F1 a F24, Space, Enter, Left, Right, Up, Down, Home, End,
    # PageUp, PageDown, coma, punto, [ ], y las multimedia (MediaPlayPause,
    # MediaNext, MediaPrevious, MediaStop). Vacio ('') desactiva el atajo.
    # Ctrl+Shift+V se evita: muchos programas lo usan para pegar sin formato.
    HotkeyRead = 'Ctrl+Alt+V'
    HotkeyStop = 'Ctrl+Shift+Q'
    HotkeyToggle = 'Ctrl+Shift+Space'
    HotkeyBack = 'Ctrl+Shift+,'
    HotkeyForward = 'Ctrl+Shift+.'
    HotkeyFaster = 'Ctrl+Shift+]'
    HotkeySlower = 'Ctrl+Shift+['
    # Tamano de todo el reproductor (0.8 a 1.6) y de la letra del panel de
    # texto (10 a 22). Panel de texto al aparecer: 'recordar' (como lo
    # dejaste), 'abierto' o 'cerrado'.
    PlayerScale = 1.0
    TextFontSize = 13
    PanelOnShow = 'recordar'

    # Pausas, en segundos, que se agregan donde el texto cambia de bloque.
    # Van encima del silencio normal de fin de frase, asi que valores
    # pequenos ya se notan. Con 0 se desactiva cada una.
    PauseParagraph = 0.35      # entre un parrafo y el siguiente
    PauseBeforeHeading = 0.55  # antes de un titulo
    PauseAfterHeading = 0.30   # entre el titulo y lo que viene debajo
    PauseTableRow = 0.18       # entre filas de una tabla o vinetas de una lista

    # Horas que se conservan los WAV temporales antes de borrarlos.
    MaxTmpAgeHours = 6
}
