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
        TermsFile   = Join-Path $root 'config\terms_es.tsv'
        SettingsFile= Join-Path $root 'config\settings.psd1'
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
        VoiceEn             = 'en_US-lessac-medium'
        LengthScale         = 1.06
        SentenceSilence     = 0.36
        NoiseScale          = 0.667
        NoiseW              = 0.8
        ChunkTargetChars    = 220
        FirstChunkChars     = 70
        FallbackLanguage    = 'es'
        ShowPlayer          = $true
        PlayerAutoClose     = $true
        PlayerOpacity       = 0.94
        SkipSeconds         = 10
        MaxTmpAgeHours      = 6
    }

    if (-not (Test-Path -LiteralPath $Paths.SettingsFile)) {
        return $defaults
    }

    try {
        $loaded = Read-PowerShellDataFile -Path $Paths.SettingsFile
        foreach ($key in @($loaded.Keys)) {
            $defaults[$key] = $loaded[$key]
        }
    } catch {
        Write-Warning "No pude leer config\settings.psd1; uso los valores por defecto. $($_.Exception.Message)"
    }

    return $defaults
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

function Send-ReadAloudCommand {
    # Manda una orden al proceso residente. Devuelve la respuesta o $null si el
    # proceso no esta escuchando.
    param(
        [string]$PipeName,
        [hashtable]$Command,
        [int]$TimeoutMs = 400
    )

    $client = New-Object IO.Pipes.NamedPipeClientStream('.', $PipeName, [IO.Pipes.PipeDirection]::InOut)

    try {
        $client.Connect($TimeoutMs)

        $writer = New-Object IO.StreamWriter($client, (New-Object Text.UTF8Encoding($false)))
        $writer.AutoFlush = $true
        $writer.WriteLine(($Command | ConvertTo-Json -Compress -Depth 5))

        $reader = New-Object IO.StreamReader($client, (New-Object Text.UTF8Encoding($false)))
        return $reader.ReadLine()
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
