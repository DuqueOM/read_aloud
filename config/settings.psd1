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

    # Velocidad. Mas alto es mas lento. 1.00 es la velocidad base del modelo.
    LengthScale = 1.06

    # Silencio en segundos despues de cada frase.
    SentenceSilence = 0.36

    # Variacion de la voz. Cambialos solo si quieres experimentar.
    NoiseScale = 0.667
    NoiseW = 0.8

    # Tamano de los fragmentos de audio, en caracteres.
    # El primero es corto a proposito: es el que decide cuanto tardas en oir
    # la primera palabra.
    ChunkTargetChars = 220
    FirstChunkChars = 70

    # Idioma que se usa cuando el texto es demasiado corto o ambiguo.
    FallbackLanguage = 'es'

    # Reproductor flotante.
    ShowPlayer = $true
    PlayerAutoClose = $true
    PlayerOpacity = 0.94
    SkipSeconds = 10

    # Horas que se conservan los WAV temporales antes de borrarlos.
    MaxTmpAgeHours = 6
}
