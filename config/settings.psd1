#
# Ajustes de Read Aloud.
# Cambia lo que quieras aqui y reinicia el proceso residente:
#   .\read_aloud.ps1 -Stop
#   powershell -File .\read_aloud_daemon.ps1
#
# Si borras este archivo, el programa sigue funcionando con estos mismos
# valores por defecto.

@{
    # Nombre del modelo, sin la extension .onnx. Debe existir en
    # read_aloud_piper\voices. Mira las disponibles con -ListVoices.
    VoiceEs = 'es_MX-claude-high'
    VoiceEn = 'en_US-lessac-medium'

    # Motor de cada idioma: 'piper' o 'qwen'. 'qwen' lee con la voz propia
    # entrenada con Qwen3-TTS (docs\voz-personalizada.md); necesita la tarjeta
    # grafica y la carpeta de trabajo de esa voz. Si algo falta, se lee con la
    # voz de Piper de arriba.
    EngineEs = 'qwen'
    EngineEn = 'qwen'
    QwenWorkDir = 'D:\voces\mi_voz'

    # Frases que se generan juntas con Qwen: mas es mas rapido en total, pero
    # cada grupo tarda mas en estar listo.
    QwenBatch = 4

    # Minutos sin leer tras los que Qwen se cierra y libera la memoria de la
    # tarjeta grafica (unos 5 GB). La lectura siguiente espera a que cargue.
    QwenIdleMinutes = 15

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

    # Idioma que se usa cuando el texto es demasiado corto o ambiguo.
    FallbackLanguage = 'es'

    # Reproductor flotante.
    ShowPlayer = $true
    PlayerAutoClose = $true
    # Opacidad en reposo, de 0.3 a 1.0. Al hacer clic sobre el reproductor se
    # vuelve opaco del todo, y al hacer clic fuera regresa a este valor.
    PlayerOpacity = 0.6
    SkipSeconds = 10

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
