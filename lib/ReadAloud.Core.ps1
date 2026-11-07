#
# ReadAloud.Core.ps1
# Rutas, ajustes, utilidades de audio y comunicacion con el proceso residente.

function Get-ReadAloudRoot {
    # lib\ esta siempre un nivel debajo de la raiz del repositorio.
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-ReadAloudPaths {
    param([string]$PiperBaseDir = '')

    $root = Get-ReadAloudRoot

    if ([string]::IsNullOrWhiteSpace($PiperBaseDir)) {
        $PiperBaseDir = Join-Path $root 'read_aloud_piper'
    }

    $piperDir = Join-Path $PiperBaseDir 'bin\piper'
    $voicesDir = Join-Path $PiperBaseDir 'voices'
    $runtimeDir = Join-Path $PiperBaseDir 'runtime'

    return @{
        Root        = $root
        LibDir      = Join-Path $root 'lib'
        ConfigDir   = Join-Path $root 'config'
        BaseDir     = $PiperBaseDir
        PiperDir    = $piperDir
        PiperExe    = Join-Path $piperDir 'piper.exe'
        EspeakData  = Join-Path $piperDir 'espeak-ng-data'
        VoicesDir   = $voicesDir
        RuntimeDir  = $runtimeDir
        TmpDir      = Join-Path $PiperBaseDir 'tmp'
        LogFile     = Join-Path $runtimeDir 'daemon.log'
        StateFile   = Join-Path $runtimeDir 'player.json'
        UserSettingsFile = Join-Path $runtimeDir 'ajustes.json'
        TermsFile   = Join-Path $root 'config\terms_es.tsv'
        SettingsFile= Join-Path $root 'config\settings.psd1'
        LocalSettingsFile = Join-Path $root 'config\settings.local.psd1'
        DaemonScript= Join-Path $root 'read_aloud_daemon.ps1'
        PipeName    = 'read_aloud_pipe'
    }
}

function Get-ReadAloudSettings {
    # Los ajustes viven en config\settings.psd1 para que se puedan cambiar sin
    # tocar el codigo. Si el archivo falta o esta roto, se usan los valores por
    # defecto: el lector nunca debe quedarse mudo por un error de configuracion.
    param([hashtable]$Paths)

    $defaults = @{
        VoiceEs             = 'es_MX-claude-high'
        VoiceEn             = 'en_US-lessac-high'
        LengthScale         = 1.06
        SentenceSilence     = 0.36
        NoiseScale          = 0.667
        NoiseW              = 0.8
        MinChunkChars       = 25
        FirstChunkChars     = 70
        MaxChunkChars       = 180
        FallbackLanguage    = 'es'
        ShowPlayer          = $true
        PlayerAutoClose     = $true
        PlayerOpacity       = 0.8
        SkipSeconds         = 10
        PauseParagraph      = 0.35
        PauseBeforeHeading  = 0.55
        PauseAfterHeading   = 0.30
        PauseTableRow       = 0.18
        MaxTmpAgeHours      = 6
        EngineEs            = 'auto'
        EngineEn            = 'auto'
        QwenWorkDir         = ''
        QwenBatch           = 4
        QwenBatchChars      = 320
        QwenIdleMinutes     = 0
        QwenMinVramGB       = 7
        QwenReopen          = $true
        QwenReopenFreeGB    = 6
        Performance         = 'rapido'
        SaverIdleMinutes    = 5
        PlayerScale         = 1.0
        TextFontSize        = 13
        PanelOnShow         = 'recordar'
    }

    # settings.local.psd1, ignorado por Git, lleva lo que es de este equipo (la
    # carpeta de la voz propia, por ejemplo) y manda sobre settings.psd1.
    foreach ($archivo in @($Paths.SettingsFile, $Paths.LocalSettingsFile)) {
        if (-not $archivo -or -not (Test-Path -LiteralPath $archivo)) { continue }
        try {
            $loaded = Read-PowerShellDataFile -Path $archivo
            foreach ($key in @($loaded.Keys)) {
                $defaults[$key] = $loaded[$key]
            }
        } catch {
            Write-Warning "No pude leer $(Split-Path -Leaf $archivo); uso los valores anteriores. $($_.Exception.Message)"
        }
    }

    # Lo que se cambia en el panel de ajustes del reproductor manda sobre
    # settings.psd1. Solo se aceptan claves conocidas: un archivo editado a mano
    # con un error no debe meter valores raros.
    $usuario = Get-UserSettings -Paths $Paths
    foreach ($key in @($usuario.Keys)) {
        if ($defaults.ContainsKey($key)) { $defaults[$key] = $usuario[$key] }
    }

    return $defaults
}

function Get-UserSettings {
    # Los ajustes elegidos en el panel del reproductor (runtime\ajustes.json).
    param([hashtable]$Paths)

    $valores = @{}
    if (-not (Test-Path -LiteralPath $Paths.UserSettingsFile)) { return $valores }
    try {
        $json = Get-Content -LiteralPath $Paths.UserSettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $valores[$p.Name] = $p.Value }
    } catch {
        Write-Warning "No pude leer $($Paths.UserSettingsFile); lo ignoro. $($_.Exception.Message)"
    }
    return $valores
}

function Save-UserSetting {
    # Guarda un ajuste del panel junto a los que ya habia.
    param([hashtable]$Paths, [string]$Name, $Value)

    $valores = Get-UserSettings -Paths $Paths
    $valores[$Name] = $Value
    $json = ConvertTo-Json -InputObject $valores
    [IO.File]::WriteAllText($Paths.UserSettingsFile, $json, (New-Object Text.UTF8Encoding($false)))
}

function Read-PowerShellDataFile {
    # Lee un .psd1 analizando su arbol sintactico en vez de ejecutarlo.
    # No se usa Import-PowerShellDataFile porque ese cmdlet depende de la carga
    # automatica de modulos, y esa carga falla cuando el proceso hereda una
    # ruta de modulos de otra version de PowerShell. Aqui no hay nada que
    # cargar, y el archivo nunca se ejecuta: solo se leen valores literales.
    param([string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        throw "El archivo tiene errores de sintaxis en la linea $($errors[0].Extent.StartLineNumber)."
    }

    $hashtableAst = $ast.Find(
        { param($node) $node -is [Management.Automation.Language.HashtableAst] },
        $false)

    if (-not $hashtableAst) {
        throw 'El archivo no contiene una tabla de valores.'
    }

    return $hashtableAst.SafeGetValue()
}

function Get-VoiceModelPath {
    param(
        [hashtable]$Paths,
        [hashtable]$Settings,
        [string]$Lang
    )

    $name = $Settings.VoiceEs
    if ($Lang -eq 'en') { $name = $Settings.VoiceEn }

    $model = Join-Path $Paths.VoicesDir ($name + '.onnx')

    return @{
        Name    = $name
        Model   = $model
        Config  = ($model + '.json')
        Ready   = ((Test-Path -LiteralPath $model) -and (Test-Path -LiteralPath ($model + '.json')))
    }
}

function Get-QwenVoice {
    # La voz afinada con Qwen3-TTS vive en la carpeta de trabajo de la voz
    # personalizada (docs\voz-personalizada.md), con su propio entorno de
    # Python y la cache del modelo base. Aqui solo se arman las rutas y se
    # comprueba que esten.
    param([hashtable]$Paths, [hashtable]$Settings)

    $work = [string]$Settings.QwenWorkDir
    $voice = @{
        Python  = ''
        Script  = Join-Path $Paths.LibDir 'servidor_qwen.py'
        VoiceDir= ''
        HfHome  = ''
        Log     = Join-Path $Paths.RuntimeDir 'qwen.log'
        # Los pasos pesados de la carpeta de trabajo dejan aqui su numero de
        # proceso mientras usan la tarjeta grafica (scripts\gpu.py); mientras
        # tanto se lee con Piper (Test-GpuBusy, en read_aloud_daemon.ps1).
        BusyFile= ''
        Ready   = $false
    }

    # Sin carpeta de trabajo no hay voz propia: las rutas de la carpeta quedan
    # vacias y la voz, no lista. Se arman con Path.Combine y no con Join-Path,
    # que falla con una ruta vacia o con una unidad que no existe en el equipo,
    # y el proceso residente se caeria al arrancar.
    if (-not [string]::IsNullOrWhiteSpace($work)) {
        $voice.Python   = [IO.Path]::Combine($work, '.venv_qwen\Scripts\python.exe')
        $voice.VoiceDir = [IO.Path]::Combine($work, 'modelos\voz_app')
        $voice.HfHome   = [IO.Path]::Combine($work, 'modelos\hf')
        $voice.BusyFile = [IO.Path]::Combine($work, 'gpu_ocupada')
        $voice.Ready = (
            (Test-Path -LiteralPath $voice.Python) -and
            (Test-Path -LiteralPath $voice.Script) -and
            (Test-Path -LiteralPath ([IO.Path]::Combine($voice.VoiceDir, 'lora.safetensors'))) -and
            (Test-Path -LiteralPath $voice.HfHome)
        )
    }

    return $voice
}

function Get-NvidiaVramGB {
    # Memoria de la tarjeta NVIDIA mas grande del equipo, en GB, o 0 si no hay
    # ninguna. nvidia-smi viene con el controlador de NVIDIA; sin el, no hay
    # tarjeta que pueda mover Qwen3-TTS.
    $smi = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue
    if (-not $smi) { return 0.0 }
    try {
        $mib = & $smi.Source '--query-gpu=memory.total' '--format=csv,noheader,nounits' 2>$null |
            ForEach-Object { [double]($_.Trim()) } | Measure-Object -Maximum
        if ($mib.Count -eq 0) { return 0.0 }
        return $mib.Maximum / 1024.0
    } catch {
        return 0.0
    }
}

function Resolve-VoiceEngine {
    # Que motor lee un idioma. 'piper' siempre es Piper. 'qwen' y 'auto' usan
    # la voz propia de Qwen3-TTS si esta instalada y hay una tarjeta NVIDIA con
    # memoria suficiente; si no, Piper. La diferencia es solo el aviso: con
    # 'qwen' se pidio esa voz y se explica en el log por que no se usa; con
    # 'auto', la que se instala por defecto, quedarse con Piper es lo normal en
    # un equipo sin esa voz o sin esa tarjeta.
    param(
        [string]$Requested,
        [hashtable]$QwenVoice,
        [double]$VramGB,
        [double]$MinVramGB
    )

    $requested = ([string]$Requested).ToLowerInvariant()
    if ($requested -ne 'qwen' -and $requested -ne 'auto') {
        return @{ Engine = 'piper'; Reason = '' }
    }
    if (-not $QwenVoice.Ready) {
        return @{ Engine = 'piper'; Reason = $(if ($requested -eq 'qwen') { 'no encontre la voz Qwen' } else { '' }) }
    }
    if ($VramGB -lt $MinVramGB) {
        return @{ Engine = 'piper'; Reason = ('la tarjeta grafica tiene {0:N1} GB y Qwen pide {1} GB' -f $VramGB, $MinVramGB) }
    }
    return @{ Engine = 'qwen'; Reason = '' }
}

function Test-PiperInstalled {
    param([hashtable]$Paths)

    return (
        (Test-Path -LiteralPath $Paths.PiperExe) -and
        (Test-Path -LiteralPath $Paths.EspeakData)
    )
}

function Get-WavDuration {
    # Lee la cabecera RIFF para saber cuanto dura el fragmento sin reproducirlo.
    # El reproductor necesita esto para dibujar la barra de progreso completa
    # antes de que termine de generarse todo el audio.
    param([string]$Path)

    try {
        $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    } catch {
        return 0.0
    }

    try {
        $reader = New-Object IO.BinaryReader($stream)

        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'RIFF') { return 0.0 }
        [void]$reader.ReadUInt32()
        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'WAVE') { return 0.0 }

        $byteRate = 0
        $dataSize = 0

        while ($stream.Position -lt ($stream.Length - 8)) {
            $chunkId = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
            $chunkSize = $reader.ReadUInt32()

            if ($chunkId -eq 'fmt ') {
                [void]$reader.ReadUInt16()   # formato
                [void]$reader.ReadUInt16()   # canales
                [void]$reader.ReadUInt32()   # frecuencia de muestreo
                $byteRate = $reader.ReadUInt32()
                $remaining = $chunkSize - 12
                if ($remaining -gt 0) { [void]$reader.ReadBytes($remaining) }
            } elseif ($chunkId -eq 'data') {
                $dataSize = $chunkSize
                break
            } else {
                [void]$reader.ReadBytes($chunkSize)
            }

            if ($chunkSize % 2 -eq 1) { [void]$reader.ReadBytes(1) }
        }

        if ($byteRate -le 0) { return 0.0 }
        return [double]$dataSize / [double]$byteRate
    } catch {
        return 0.0
    } finally {
        $stream.Dispose()
    }
}

function Add-WavSilence {
    # Alarga un WAV con silencio al final.
    #
    # Las pausas entre bloques no se reproducen como un archivo aparte: cada
    # cambio de archivo cuesta cerca de medio segundo de arranque, asi que una
    # pausa de 0.18 s acababa durando mas de medio segundo y sonaba a corte.
    # Pegado al final del audio anterior, el silencio dura exactamente lo
    # pedido y no agrega ningun cambio de archivo.
    param(
        [string]$Path,
        [double]$Seconds
    )

    if ($Seconds -le 0) { return 0.0 }

    $stream = [IO.File]::Open($Path, 'Open', 'ReadWrite')

    try {
        $lector = New-Object IO.BinaryReader($stream)

        if ([Text.Encoding]::ASCII.GetString($lector.ReadBytes(4)) -ne 'RIFF') { return 0.0 }
        [void]$lector.ReadUInt32()
        if ([Text.Encoding]::ASCII.GetString($lector.ReadBytes(4)) -ne 'WAVE') { return 0.0 }

        $byteRate = 0
        $alineacion = 2
        $posTamanoDatos = -1
        $tamanoDatos = 0

        while ($stream.Position -lt ($stream.Length - 8)) {
            $id = [Text.Encoding]::ASCII.GetString($lector.ReadBytes(4))
            $posTamano = $stream.Position
            $tamano = $lector.ReadUInt32()

            if ($id -eq 'fmt ') {
                [void]$lector.ReadUInt16()
                [void]$lector.ReadUInt16()
                [void]$lector.ReadUInt32()
                $byteRate = $lector.ReadUInt32()
                $alineacion = $lector.ReadUInt16()
                $resto = $tamano - 14
                if ($resto -gt 0) { [void]$lector.ReadBytes($resto) }
            } elseif ($id -eq 'data') {
                $posTamanoDatos = $posTamano
                $tamanoDatos = $tamano
                break
            } else {
                [void]$lector.ReadBytes($tamano)
            }

            if ($tamano % 2 -eq 1) { [void]$lector.ReadBytes(1) }
        }

        if ($byteRate -le 0 -or $posTamanoDatos -lt 0) { return 0.0 }

        # Solo se alarga si los datos llegan hasta el final del archivo; con
        # cualquier otra cosa detras, anadir al final lo corromperia.
        if (($stream.Position + $tamanoDatos) -ne $stream.Length) { return 0.0 }

        if ($alineacion -lt 1) { $alineacion = 2 }
        $aAnadir = [int]([Math]::Round($Seconds * $byteRate))
        $aAnadir = $aAnadir - ($aAnadir % $alineacion)
        if ($aAnadir -lt $alineacion) { return 0.0 }

        $escritor = New-Object IO.BinaryWriter($stream)

        $stream.Seek(0, 'End') | Out-Null
        $escritor.Write((New-Object byte[] $aAnadir))

        $stream.Seek($posTamanoDatos, 'Begin') | Out-Null
        $escritor.Write([uint32]($tamanoDatos + $aAnadir))

        $stream.Seek(4, 'Begin') | Out-Null
        $escritor.Write([uint32]($stream.Length - 8))

        $escritor.Flush()

        return [double]$aAnadir / [double]$byteRate
    } catch {
        return 0.0
    } finally {
        $stream.Dispose()
    }
}

function Send-ReadAloudCommand {
    # Manda una orden al proceso residente. Devuelve 'ok' si la entrego, o
    # $null si nadie estaba escuchando.
    #
    # El envio es de una sola direccion a proposito. Cuando el servidor
    # respondia, tenia que desconectar despues de escribir, y esa desconexion
    # descartaba la respuesta antes de que el cliente alcanzara a leerla: las
    # ordenes se perdian de forma intermitente. Conectar ya demuestra que hay
    # alguien escuchando, asi que la respuesta sobraba.
    param(
        [string]$PipeName,
        [hashtable]$Command,
        [int]$TimeoutMs = 400
    )

    $client = New-Object IO.Pipes.NamedPipeClientStream('.', $PipeName, [IO.Pipes.PipeDirection]::Out)

    try {
        $client.Connect($TimeoutMs)

        $writer = New-Object IO.StreamWriter($client, (New-Object Text.UTF8Encoding($false)))
        $writer.AutoFlush = $true
        # Un texto leido con Get-Content trae propiedades ocultas de
        # PowerShell, y ConvertTo-Json lo enviaria como un objeto en vez de
        # como texto: el lector acababa diciendo "arroba value igual" al
        # principio. Pasar cada valor a texto puro lo evita.
        $limpio = @{}
        foreach ($clave in $Command.Keys) {
            $valor = $Command[$clave]
            if ($valor -is [string]) { $valor = [string]$valor.ToString() }
            $limpio[$clave] = $valor
        }

        $writer.WriteLine(($limpio | ConvertTo-Json -Compress -Depth 5))
        $writer.Flush()

        return 'ok'
    } catch {
        return $null
    } finally {
        $client.Dispose()
    }
}

function Test-DaemonRunning {
    param([string]$PipeName)
    return ((Send-ReadAloudCommand -PipeName $PipeName -Command @{ cmd = 'ping' } -TimeoutMs 300) -ne $null)
}

function Start-ReadAloudDaemon {
    # Arranca el proceso residente oculto y espera a que abra la tuberia.
    param(
        [hashtable]$Paths,
        [int]$WaitSeconds = 25
    )

    $arguments = @(
        '-NoProfile'
        '-NonInteractive'
        '-WindowStyle', 'Hidden'
        '-ExecutionPolicy', 'Bypass'
        '-File', ('"' + $Paths.DaemonScript + '"')
    ) -join ' '

    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-DaemonRunning -PipeName $Paths.PipeName) { return $true }
        Start-Sleep -Milliseconds 200
    }

    return $false
}

function Clear-OldTempAudio {
    # Los WAV temporales quedaban huerfanos cada vez que se detenia la lectura
    # a la fuerza. Aqui se limpian por edad al arrancar el proceso residente.
    param(
        [string]$TmpDir,
        [int]$MaxAgeHours = 6
    )

    if (-not (Test-Path -LiteralPath $TmpDir)) { return 0 }

    $cutoff = (Get-Date).AddHours(-1 * $MaxAgeHours)
    $removed = 0

    Get-ChildItem -LiteralPath $TmpDir -Filter '*.wav' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                $removed++
            } catch {
                # Un archivo en uso se limpiara en el siguiente arranque.
            }
        }

    return $removed
}
