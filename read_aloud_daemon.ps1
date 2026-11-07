#
# read_aloud_daemon.ps1
# Proceso residente: mantiene Piper cargado en memoria, escucha ordenes por una
# tuberia con nombre y muestra el reproductor flotante.
#
# No se ejecuta a mano en el uso diario. read_aloud.ps1 lo arranca solo la
# primera vez, o lo arranca Windows al iniciar sesion si instalaste el arranque
# automatico con install_startup.ps1.
#
# Para verlo trabajar mientras depuras:
#   .\read_aloud_daemon.ps1 -Verbose

[CmdletBinding()]
param(
    [switch]$NoWarmup,
    # Lo usa el panel de ajustes para reiniciar el lector: el proceso nuevo
    # espera a que termine el viejo, que todavia tiene la instancia unica.
    [int]$EsperarA = 0
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\ReadAloud.Core.ps1')
. (Join-Path $PSScriptRoot 'lib\ReadAloud.Text.ps1')
. (Join-Path $PSScriptRoot 'lib\ReadAloud.Player.ps1')
. (Join-Path $PSScriptRoot 'lib\ReadAloud.Hotkeys.ps1')
. (Join-Path $PSScriptRoot 'lib\ReadAloud.Update.ps1')
. (Join-Path $PSScriptRoot 'lib\ReadAloud.Theme.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$paths = Get-ReadAloudPaths
$settings = Get-ReadAloudSettings -Paths $paths

# --------------------------------------------------------------------------
# Una sola instancia. Sin esto, dos daemons pelean por la tuberia y el audio
# se escucha duplicado, que es justo el sintoma que se quiere eliminar.
# --------------------------------------------------------------------------
if ($EsperarA -gt 0) {
    try { Wait-Process -Id $EsperarA -Timeout 20 -ErrorAction Stop } catch { }
}

$mutexCreated = $false
$mutex = New-Object Threading.Mutex($true, 'Global\read_aloud_daemon_v2', [ref]$mutexCreated)
if (-not $mutexCreated) {
    Write-Verbose 'Ya hay un proceso residente activo. Salgo.'
    exit 0
}

foreach ($dir in @($paths.RuntimeDir, $paths.TmpDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# Los registros no crecen sin fin: el viejo pasa a .1 al pasar de 1 MB.
[void](Invoke-LogRotation -Path $paths.LogFile)
[void](Invoke-LogRotation -Path (Join-Path $paths.RuntimeDir 'qwen.log') -MaxBytes 2097152)

function Write-DaemonLog {
    param([string]$Message)

    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Verbose $line

    try {
        Add-Content -LiteralPath $paths.LogFile -Value $line -Encoding UTF8
    } catch {
        # El log nunca debe tumbar la lectura.
    }
}

function Get-ConfiguredPauses {
    # Las pausas estructurales salen de los ajustes, con los valores por
    # defecto de la libreria como red de seguridad.
    $pausas = Get-DefaultPauses

    foreach ($par in @(
        @{ Clave = 'Paragraph';     Ajuste = 'PauseParagraph' }
        @{ Clave = 'BeforeHeading'; Ajuste = 'PauseBeforeHeading' }
        @{ Clave = 'AfterHeading';  Ajuste = 'PauseAfterHeading' }
        @{ Clave = 'TableRow';      Ajuste = 'PauseTableRow' }
    )) {
        if ($settings.ContainsKey($par.Ajuste)) {
            $pausas[$par.Clave] = [double]$settings[$par.Ajuste]
        }
    }

    return $pausas
}

$purged = Clear-OldTempAudio -TmpDir $paths.TmpDir -MaxAgeHours $settings.MaxTmpAgeHours
Write-DaemonLog "Inicio. Temporales eliminados: $purged"

function Update-SpeechDictionary {
    Initialize-SpeechTerms -Paths $paths
}
Update-SpeechDictionary

# La expresion regular del diccionario se compila la primera vez que se usa, y
# esa compilacion tardaba cerca de medio segundo justo en la primera lectura
# del dia. Ejercerla aqui la paga por adelantado.
[void](Expand-EnglishTerms -Text 'deploy cache pull request')

$voiceEs = Get-VoiceModelPath -Paths $paths -Settings $settings -Lang 'es'
$voiceEn = Get-VoiceModelPath -Paths $paths -Settings $settings -Lang 'en'

if (-not (Test-PiperInstalled -Paths $paths)) {
    Write-DaemonLog 'Piper no esta instalado. Ejecuta setup.ps1.'
    [Windows.MessageBox]::Show(
        "No encontre Piper en:`n$($paths.PiperDir)`n`nEjecuta setup.ps1 para instalarlo.",
        'Read Aloud', 'OK', 'Warning') | Out-Null
    exit 1
}

if (-not $voiceEs.Ready) {
    Write-DaemonLog "Falta la voz en espanol: $($voiceEs.Model)"
}
if (-not $voiceEn.Ready) {
    Write-DaemonLog "Falta la voz en ingles: $($voiceEn.Model). El texto en ingles se leera con la voz en espanol."
}

# Motor de cada idioma. Sin la voz propia o sin una tarjeta que la mueva, se
# lee con Piper: el lector nunca debe quedarse mudo por la voz personalizada.
$qwenVoice = Get-QwenVoice -Paths $paths -Settings $settings
$vramGB = 0.0
if ($qwenVoice.Ready) { $vramGB = Get-NvidiaVramGB }
$engines = [hashtable]::Synchronized(@{})
foreach ($par in @(@{ Lang = 'es'; Ajuste = 'EngineEs' }, @{ Lang = 'en'; Ajuste = 'EngineEn' })) {
    $resolved = Resolve-VoiceEngine -Requested $settings[$par.Ajuste] -QwenVoice $qwenVoice `
        -VramGB $vramGB -MinVramGB ([double]$settings.QwenMinVramGB)
    if ($resolved.Reason) {
        Write-DaemonLog "Voz Qwen no disponible para '$($par.Lang)' ($($resolved.Reason)): se lee con Piper."
    }
    $engines[$par.Lang] = $resolved.Engine
}
Write-DaemonLog ('Motores: es={0}, en={1}' -f $engines['es'], $engines['en'])

# Rendimiento. 'rapido': la voz de Qwen se carga al arrancar y se queda
# cargada, asi cada lectura empieza en 1 o 2 s, a cambio de unos 5 GB de la
# tarjeta y 2.3 GB de RAM. 'ahorro': no se carga hasta la primera lectura, que
# espera unos 20 s, y se cierra tras SaverIdleMinutes sin leer; sin lecturas
# no ocupa nada.
$ahorro = ([string]$settings.Performance).ToLowerInvariant() -eq 'ahorro'
if ($ahorro) { Write-DaemonLog "Rendimiento: ahorro de recursos ($($settings.SaverIdleMinutes) min sin leer)." }

# --------------------------------------------------------------------------
# Estado compartido entre hilos.
# Generation identifica la lectura actual: cuando llega una orden nueva, sube
# el contador y todo el audio de la lectura anterior se descarta al vuelo.
# --------------------------------------------------------------------------
$sync = [hashtable]::Synchronized(@{})
$sync.Requests  = New-Object 'Collections.Concurrent.ConcurrentQueue[string]'
$sync.SynthJobs = New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
$sync.SynthDone = New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
# Despierta al hilo de sintesis cuando hay trabajo, para que no tenga que mirar
# la cola cada pocos milisegundos mientras no hay nada que leer.
$sync.SynthSignal = New-Object Threading.AutoResetEvent($false)
$sync.Generation = 0
# Fragmento al que el usuario salto y que aun no tiene audio: se genera primero
# (PriorityGen dice a que lectura corresponde).
$sync.Priority = -1
$sync.PriorityGen = 0
$sync.Stopping = $false
$sync.ReloadSynth = $false

$runspaces = New-Object System.Collections.Generic.List[object]

function Start-BackgroundRunspace {
    param(
        [scriptblock]$Script,
        [hashtable]$Variables
    )

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    foreach ($key in $Variables.Keys) {
        $rs.SessionStateProxy.SetVariable($key, $Variables[$key])
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script)
    $handle = $ps.BeginInvoke()

    $runspaces.Add(@{ Runspace = $rs; PowerShell = $ps; Handle = $handle })
}

# --------------------------------------------------------------------------
# Hilo 1: servidor de la tuberia con nombre.
# --------------------------------------------------------------------------
$pipeScript = {
    while (-not $sync.Stopping) {
        $server = $null
        try {
            # La tuberia es de una sola direccion: el servidor solo lee. Cuando
            # tambien respondia, habia que desconectar despues de escribir, y
            # eso descartaba la respuesta antes de que el cliente la leyera.
            # El resultado era que las ordenes se perdian de forma intermitente.
            $server = New-Object IO.Pipes.NamedPipeServerStream(
                $pipeName, [IO.Pipes.PipeDirection]::In, 4,
                [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::None, 4096, 4096)

            $server.WaitForConnection()

            $reader = New-Object IO.StreamReader($server, (New-Object Text.UTF8Encoding($false)))

            # Un cliente puede mandar varias ordenes seguidas antes de cerrar.
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line.Trim() -ne '') {
                    $sync.Requests.Enqueue($line)
                    # El pulso de la ventana puede estar en su ritmo de reposo.
                    if ($sync.Dispatcher) {
                        try { [void]$sync.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Normal, $sync.WakeUi) } catch { }
                    }
                }
            }
        } catch {
            Start-Sleep -Milliseconds 50
        } finally {
            if ($server) {
                try { if ($server.IsConnected) { $server.Disconnect() } } catch { }
                $server.Dispose()
            }
        }
    }
}

Start-BackgroundRunspace -Script $pipeScript -Variables @{
    sync = $sync
    pipeName = $paths.PipeName
}

# --------------------------------------------------------------------------
# Hilo 2: sintesis. Mantiene un proceso Piper vivo por idioma.
# Aqui esta la diferencia de fondo con la version anterior: antes se arrancaba
# piper.exe y se cargaba el modelo de 63 MB en cada fragmento; ahora el modelo
# se carga una vez y queda residente.
#
# Con la voz Qwen hay un solo proceso para los dos idiomas (lib\servidor_qwen.py),
# que habla el mismo protocolo que Piper. En la tarjeta grafica, generar varias
# frases juntas cuesta casi lo mismo que una, asi que se le mandan en grupo
# las que ya esten en cola: las dos primeras juntas, y despues grupos de hasta
# QwenBatch mientras ya hay audio sonando.
# --------------------------------------------------------------------------
$synthScript = {
    # El orden de generacion y el tope de los grupos viven en la biblioteca del
    # reproductor, que se prueba con Pester.
    . $cfg.PlayerLib

    $processes = @{}

    function New-QwenProcess {
        $q = $cfg.Qwen
        # El servidor crea este archivo cuando termina de cargar; uno de una
        # vida anterior no debe hacerlo pasar por listo.
        Remove-Item -LiteralPath $q.ReadyFile -Force -ErrorAction SilentlyContinue
        $qwenArgs = @(
            ('"' + $q.Script + '"')
            '--voz', ('"' + $q.VoiceDir + '"')
            '--hf-home', ('"' + $q.HfHome + '"')
            '--registro', ('"' + $q.Log + '"')
            '--silencio', $cfg.SentenceSilence
            '--inactivo', $q.IdleMinutes
            '--lote', $q.Batch
            '--marca', ('"' + $q.BusyFile + '"')
            '--listo', ('"' + $q.ReadyFile + '"')
        ) -join ' '

        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $q.Python
        $psi.Arguments = $qwenArgs
        $psi.WorkingDirectory = (Split-Path -Parent $q.Script)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        # Los avisos van al registro del propio servidor; una salida de error
        # redirigida que nadie lee terminaria por bloquearlo.
        $psi.RedirectStandardError = $false
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)

        $process = [Diagnostics.Process]::Start($psi)
        $writer = New-Object IO.StreamWriter($process.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
        $writer.AutoFlush = $true

        return @{ Process = $process; Writer = $writer }
    }

    function Test-GpuBusy {
        # Si un paso pesado de la voz personalizada esta usando la tarjeta
        # (deja su numero de proceso en el archivo). Compartir sus 8 GB con
        # Qwen hacia esperar minutos cada frase. La marca de un proceso que ya
        # no existe no cuenta.
        param([string]$BusyFile)
        if (-not (Test-Path -LiteralPath $BusyFile)) { return $false }
        try {
            $owner = [int]((Get-Content -LiteralPath $BusyFile -Raw -ErrorAction Stop).Trim())
            return $null -ne (Get-Process -Id $owner -ErrorAction SilentlyContinue)
        } catch {
            return $false
        }
    }

    function Get-SynthKey {
        param([string]$Lang)
        if ($cfg.Engines[$Lang] -ne 'qwen') { return $Lang }
        # Otro paso pesado tiene la tarjeta: se lee con Piper y, si Qwen esta
        # abierto, se le cierra la entrada para que termine y la deje.
        if (Test-GpuBusy -BusyFile $cfg.Qwen.BusyFile) {
            if ($processes.ContainsKey('qwen')) {
                try { $processes['qwen'].Writer.Close() } catch { }
                $processes.Remove('qwen')
                Write-SynthLog 'La tarjeta grafica esta ocupada por otro paso: se lee con Piper mientras tanto.'
            }
            return $Lang
        }
        if (Test-QwenReady) { return 'qwen' }

        # La voz Qwen aun carga (de 15 a 50 s segun lo fria que este la
        # cache del disco). Se le da un margen corto desde que arranco; pasado
        # ese margen se lee con Piper en vez de dejar la lectura muda, y en
        # cuanto el servidor avisa que esta listo, los fragmentos siguientes
        # vuelven a ser de Qwen.
        $arranque = [DateTime]::Now
        try { $arranque = (Get-PiperProcess -Lang $Lang -Key 'qwen').Process.StartTime } catch { }
        $limite = $arranque.AddSeconds($cfg.Qwen.WaitSeconds)
        while ([DateTime]::Now -lt $limite -and -not $sync.Stopping) {
            if (Test-QwenReady) { return 'qwen' }
            if (-not $processes.ContainsKey('qwen') -or $processes['qwen'].Process.HasExited) { break }
            Start-Sleep -Milliseconds 100
        }
        if (Test-QwenReady) { return 'qwen' }
        Write-SynthLog 'La voz Qwen aun esta cargando: se lee con Piper hasta que termine.'
        return $Lang
    }

    function Test-QwenReady {
        if (-not $processes.ContainsKey('qwen')) { return $false }
        if ($processes['qwen'].Process.HasExited) { return $false }
        return (Test-Path -LiteralPath $cfg.Qwen.ReadyFile)
    }

    function Get-BatchLimit {
        # Una frase sola tarda algo mas de lo que dura; dos juntas, la mitad.
        # Si la primera fuera sola, la segunda no alcanzaria a estar lista
        # cuando la primera termina de sonar; juntas, la lectura empieza un
        # segundo despues pero sin cortes, y el grupo siguiente se genera
        # mientras suenan esas dos.
        param([int]$Index)
        if ($Index -lt 0) { return 1 }
        if ($Index -eq 0) { return [Math]::Min(2, $cfg.Qwen.Batch) }
        return $cfg.Qwen.Batch
    }

    function New-PiperProcess {
        param([string]$Lang)

        $model = $cfg.Models[$Lang]
        if (-not $model) { throw "No hay voz configurada para '$Lang'." }

        $piperArgs = @(
            '--model', ('"' + $model + '"')
            '--espeak_data', ('"' + $cfg.EspeakData + '"')
            '--sentence_silence', $cfg.SentenceSilence
            '--length_scale', $cfg.LengthScale
            '--noise_scale', $cfg.NoiseScale
            '--noise_w', $cfg.NoiseW
            '--json-input'
            '--quiet'
        ) -join ' '

        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $cfg.PiperExe
        $psi.Arguments = $piperArgs
        $psi.WorkingDirectory = $cfg.PiperDir
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)

        $process = [Diagnostics.Process]::Start($psi)

        # Piper lee stdin como UTF-8; sin esto los acentos llegan rotos.
        $writer = New-Object IO.StreamWriter($process.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
        $writer.AutoFlush = $true

        return @{ Process = $process; Writer = $writer }
    }

    function Write-SynthLog {
        param([string]$Message)
        try {
            Add-Content -LiteralPath $cfg.LogFile -Encoding UTF8 `
                -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
        } catch { }
    }

    function Send-SynthDone {
        param($Job, [bool]$Ok, [string]$ErrorText)
        $sync.SynthDone.Enqueue(@{
            Generation = $Job.Generation
            Index      = $Job.Index
            Wav        = $Job.Wav
            Ok         = $Ok
            Error      = $ErrorText
        })
    }

    function Invoke-SynthBatch {
        # Manda el grupo al motor y avisa de cada fragmento que llega. Con
        # Qwen, lo que falle no se da por perdido: vuelve en Batch, para que
        # se lea con Piper, y Error dice si fue el proceso entero el que fallo.
        # Con -Final, o con Piper, lo que falle se marca como fallido.
        param([string]$Key, $Batch, [switch]$Final)

        $keep = ($Key -eq 'qwen') -and -not $Final
        $failed = New-Object System.Collections.Generic.List[object]
        $errorText = ''

        # El servidor de Qwen puede haberse cerrado para dejarle la tarjeta a
        # otro programa; si paso justo al llegar esta orden, se abre de nuevo
        # y se repite una vez.
        for ($attempt = 0; $attempt -lt 2 -and $Batch.Count -gt 0; $attempt++) {
            try {
                $engine = Get-PiperProcess -Lang $Batch[0].Lang -Key $Key

                if ($Key -eq 'qwen') {
                    $items = @(foreach ($b in $Batch) { @{ text = $b.Text; output_file = $b.Wav; lang = $b.Lang } })
                    $payload = ConvertTo-Json -InputObject $items -Compress
                } else {
                    $payload = @{ text = $Batch[0].Text; output_file = $Batch[0].Wav } | ConvertTo-Json -Compress
                }
                $engine.Writer.WriteLine($payload)

                # Piper imprime la ruta del WAV cuando termina el fragmento;
                # el servidor de Qwen, una ruta por fragmento del grupo. Los
                # que ya llegaron salen del grupo, para no repetirlos si hay
                # que reintentar.
                while ($Batch.Count -gt 0) {
                    $b = $Batch[0]
                    $produced = $engine.Process.StandardOutput.ReadLine()
                    if ($null -eq $produced) { throw 'El motor de voz cerro la salida sin generar audio.' }
                    $ok = (-not [string]::IsNullOrWhiteSpace($produced)) -and (Test-Path -LiteralPath $b.Wav)
                    if ($ok) {
                        Send-SynthDone -Job $b -Ok $true -ErrorText ''
                    } elseif ($keep) {
                        $failed.Add($b)
                    } else {
                        Send-SynthDone -Job $b -Ok $false -ErrorText 'El motor de voz no genero el audio.'
                    }
                    $Batch.RemoveAt(0)
                }
                $errorText = ''
            } catch {
                $errorText = $_.Exception.Message
                if ($processes.ContainsKey($Key)) {
                    try { $processes[$Key].Process.Kill() } catch { }
                    $processes.Remove($Key)
                }
            }
        }

        foreach ($b in @($Batch)) {
            if ($keep) { $failed.Add($b) } else { Send-SynthDone -Job $b -Ok $false -ErrorText $errorText }
        }
        return @{ Batch = $failed; Error = $errorText }
    }

    function Get-PiperProcess {
        param([string]$Lang, [string]$Key)

        $key = $Key
        if ([string]::IsNullOrEmpty($key)) { $key = Get-SynthKey -Lang $Lang }
        if ($processes.ContainsKey($key)) {
            $existing = $processes[$key]
            if (-not $existing.Process.HasExited) { return $existing }
            $processes.Remove($key)
        }

        if ($key -eq 'qwen') { $created = New-QwenProcess } else { $created = New-PiperProcess -Lang $Lang }
        $processes[$key] = $created
        return $created
    }

    # Codigos con los que termina lib\servidor_qwen.py.
    # 0: se le cerro la entrada; 4 y 5: cedio la tarjeta; 3: --inactivo.
    $qwenIdleExit = 3
    $qwenCleanExits = @(0, 3, 4, 5)
    $qwenWatch = @{ Next = [DateTime]::UtcNow; LastExit = $null; Failures = 0 }

    function Reset-SynthProcesses {
        # Los ajustes de voz, motor, pausas y rendimiento cambiaron: se cierran
        # todos los procesos de voz y se abren de nuevo con los valores nuevos,
        # sin reiniciar el lector (ni los atajos, ni el reproductor).
        foreach ($key in @($processes.Keys)) {
            try { $processes[$key].Writer.Close() } catch { }
            try { $processes[$key].Process.Kill() } catch { }
            $processes.Remove($key)
        }
        $qwenWatch.LastExit = $null
        $qwenWatch.Failures = 0
        $qwenWatch.Next = [DateTime]::UtcNow.AddSeconds(3)
        Write-SynthLog 'Ajustes de voz cambiados: se recargan los motores.'
    }

    function Get-NvidiaFreeGB {
        if (-not $cfg.Qwen.Smi) { return [double]::MaxValue }
        try {
            $mib = & $cfg.Qwen.Smi '--query-gpu=memory.free' '--format=csv,noheader,nounits' 2>$null |
                ForEach-Object { [double]($_.Trim()) } | Measure-Object -Maximum
            if ($mib.Count -eq 0) { return 0.0 }
            return $mib.Maximum / 1024.0
        } catch {
            return 0.0
        }
    }

    function Restore-QwenProcess {
        # Si el servidor de Qwen cedio la tarjeta (a un paso pesado o a otro
        # programa), se vuelve a abrir en cuanto queda libre, sin esperar a la
        # proxima lectura: asi esa lectura no paga los 20 s de carga. Si
        # termino por --inactivo, se espera a la lectura, que para eso se
        # pidio. Un servidor que se cae al cargar se reintenta cada vez mas
        # espaciado, para no ocupar la tarjeta en vano.
        if (-not $cfg.Qwen.Reopen) { return }
        if (-not ($cfg.Engines.Values -contains 'qwen')) { return }
        if ($processes.ContainsKey('qwen')) {
            $current = $processes['qwen'].Process
            if (-not $current.HasExited) {
                if (([DateTime]::Now - $current.StartTime).TotalMinutes -gt 2) { $qwenWatch.Failures = 0 }
                return
            }
            $processes.Remove('qwen')
            $qwenWatch.LastExit = $current.ExitCode
            if ($qwenCleanExits -contains $current.ExitCode) {
                $qwenWatch.Failures = 0
            } else {
                $qwenWatch.Failures = [Math]::Min(6, $qwenWatch.Failures + 1)
                $qwenWatch.Next = [DateTime]::UtcNow.AddSeconds(30 * [Math]::Pow(2, $qwenWatch.Failures))
                Write-SynthLog "El servidor de Qwen termino con el codigo $($current.ExitCode)."
                return
            }
        }
        if ($qwenWatch.LastExit -eq $qwenIdleExit) { return }
        if (Test-GpuBusy -BusyFile $cfg.Qwen.BusyFile) { return }
        if ((Get-NvidiaFreeGB) -lt $cfg.Qwen.ReopenFreeGB) { return }
        $qwenWatch.LastExit = $null
        $processes['qwen'] = New-QwenProcess
        Write-SynthLog 'La tarjeta grafica quedo libre: se vuelve a cargar la voz Qwen.'
    }

    while (-not $sync.Stopping) {
        $job = $null

        if ($sync.ReloadSynth) {
            $sync.ReloadSynth = $false
            Reset-SynthProcesses
        }

        if (-not $sync.SynthJobs.TryDequeue([ref]$job)) {
            if ([DateTime]::UtcNow -ge $qwenWatch.Next) {
                $qwenWatch.Next = [DateTime]::UtcNow.AddSeconds(30)
                Restore-QwenProcess
            }
            [void]$sync.SynthSignal.WaitOne(5000)
            continue
        }

        # Fragmento de una lectura que ya fue reemplazada: no vale la pena.
        if ($job.Generation -ne $sync.Generation) { continue }

        # Si el usuario salto a un fragmento que aun no existe, ese se genera
        # primero y sigue hacia delante; lo que quedo atras, despues. Se
        # reordena la cola entera, solo con lo de la lectura actual.
        $esSalto = $false
        if ($sync.Priority -ge 0 -and $sync.PriorityGen -eq $sync.Generation) {
            $prioridad = $sync.Priority
            $sync.Priority = -1
            $esSalto = $true

            $todos = New-Object System.Collections.Generic.List[object]
            [void]$todos.Add($job)
            $otro = $null
            while ($sync.SynthJobs.TryDequeue([ref]$otro)) { [void]$todos.Add($otro) }

            $actuales = @($todos | Where-Object { $_.Generation -eq $sync.Generation })
            $porIndice = @{}
            foreach ($a in $actuales) { $porIndice[[int]$a.Index] = $a }
            $orden = @(Get-JobOrder -Pending @($actuales | ForEach-Object { [int]$_.Index }) -Priority $prioridad)

            $job = $null
            foreach ($i in $orden) {
                if ($null -eq $job) { $job = $porIndice[[int]$i]; continue }
                $sync.SynthJobs.Enqueue($porIndice[[int]$i])
            }
            # Lo de otra lectura (llego mientras se vaciaba) conserva su sitio.
            foreach ($t in $todos) {
                if ($t.Generation -ne $sync.Generation) { $sync.SynthJobs.Enqueue($t) }
            }
            if ($null -eq $job) { continue }
        }

        $key = Get-SynthKey -Lang $job.Lang
        $batch = New-Object System.Collections.Generic.List[object]
        $batch.Add($job)
        if ($key -eq 'qwen') {
            # Tras un salto, como al empezar una lectura, lo que importa es que
            # el primer audio llegue pronto: un grupo corto.
            $limit = Get-BatchLimit -Index $job.Index
            if ($esSalto) { $limit = [Math]::Min(2, $cfg.Qwen.Batch) }
            $chars = $job.Text.Length
            $next = $null
            while ($sync.SynthJobs.TryPeek([ref]$next) -and $next.Generation -eq $job.Generation -and
                   (Get-SynthKey -Lang $next.Lang) -eq 'qwen' -and
                   (Test-BatchFits -Count $batch.Count -Chars $chars -NextChars $next.Text.Length -MaxCount $limit -Budget $cfg.Qwen.BatchChars)) {
                [void]$sync.SynthJobs.TryDequeue([ref]$next)
                $batch.Add($next)
                $chars += $next.Text.Length
            }
        }

        # Lo que Qwen no pudo generar se lee con Piper, para no dejar huecos.
        $leftover = Invoke-SynthBatch -Key $key -Batch $batch
        if ($key -eq 'qwen' -and $leftover.Batch.Count -gt 0) {
            if ($leftover.Error) {
                # El proceso no responde ni al reabrirlo: el resto de la sesion
                # se lee con Piper, en vez de esperar a Qwen en cada frase.
                foreach ($lang in @($cfg.Engines.Keys)) { $cfg.Engines[$lang] = 'piper' }
                Write-SynthLog "La voz Qwen no responde ($($leftover.Error)); se sigue con Piper."
            }
            foreach ($b in @($leftover.Batch)) {
                $single = New-Object System.Collections.Generic.List[object]
                $single.Add($b)
                [void](Invoke-SynthBatch -Key $b.Lang -Batch $single -Final)
            }
        }
    }

    foreach ($key in @($processes.Keys)) {
        try { $processes[$key].Process.Kill() } catch { }
    }
}

$models = @{}
if ($voiceEs.Ready) { $models['es'] = $voiceEs.Model }
if ($voiceEn.Ready) { $models['en'] = $voiceEn.Model } elseif ($voiceEs.Ready) { $models['en'] = $voiceEs.Model }

$invariant = [Globalization.CultureInfo]::InvariantCulture

$synthConfig = @{
        PiperExe        = $paths.PiperExe
        PiperDir        = $paths.PiperDir
        EspeakData      = $paths.EspeakData
        PlayerLib       = (Join-Path $paths.LibDir 'ReadAloud.Player.ps1')
        Models          = $models
        SentenceSilence = ([double]$settings.SentenceSilence).ToString($invariant)
        LengthScale     = ([double]$settings.LengthScale).ToString($invariant)
        NoiseScale      = ([double]$settings.NoiseScale).ToString($invariant)
        NoiseW          = ([double]$settings.NoiseW).ToString($invariant)
        Engines         = $engines
        LogFile         = $paths.LogFile
        Qwen            = @{
            Python      = $qwenVoice.Python
            Script      = $qwenVoice.Script
            VoiceDir    = $qwenVoice.VoiceDir
            HfHome      = $qwenVoice.HfHome
            Log         = $qwenVoice.Log
            BusyFile    = $qwenVoice.BusyFile
            ReadyFile   = (Join-Path (Split-Path -Parent $qwenVoice.Log) 'qwen.listo')
            WaitSeconds = [double]$settings.QwenLoadWaitSeconds
            Batch       = [Math]::Max(1, [int]$settings.QwenBatch)
            BatchChars  = [int]$settings.QwenBatchChars
            IdleMinutes = $(if ($ahorro) { [double]$settings.SaverIdleMinutes } else { [double]$settings.QwenIdleMinutes }).ToString($invariant)
            Reopen      = (-not $ahorro) -and [bool]$settings.QwenReopen
            ReopenFreeGB= [double]$settings.QwenReopenFreeGB
            Smi         = $(if ($vramGB -gt 0) { (Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue).Source } else { '' })
        }
}

Start-BackgroundRunspace -Script $synthScript -Variables @{
    sync = $sync
    cfg = $synthConfig
}

function Update-SynthSettings {
    # Aplica en caliente la voz, el motor, las pausas y el rendimiento que se
    # acaban de cambiar en los ajustes ($settings ya tiene los valores nuevos).
    $vEs = Get-VoiceModelPath -Paths $paths -Settings $settings -Lang 'es'
    $vEn = Get-VoiceModelPath -Paths $paths -Settings $settings -Lang 'en'
    if ($vEs.Ready) { $models['es'] = $vEs.Model }
    if ($vEn.Ready) { $models['en'] = $vEn.Model } elseif ($vEs.Ready) { $models['en'] = $vEs.Model }

    foreach ($par in @(@{ Lang = 'es'; Ajuste = 'EngineEs' }, @{ Lang = 'en'; Ajuste = 'EngineEn' })) {
        $resolved = Resolve-VoiceEngine -Requested $settings[$par.Ajuste] -QwenVoice $qwenVoice `
            -VramGB $vramGB -MinVramGB ([double]$settings.QwenMinVramGB)
        $engines[$par.Lang] = $resolved.Engine
    }

    $script:ahorro = ([string]$settings.Performance).ToLowerInvariant() -eq 'ahorro'
    $synthConfig.SentenceSilence = ([double]$settings.SentenceSilence).ToString($invariant)
    $synthConfig.Qwen.IdleMinutes = $(if ($script:ahorro) { [double]$settings.SaverIdleMinutes } else { [double]$settings.QwenIdleMinutes }).ToString($invariant)
    $synthConfig.Qwen.Reopen = (-not $script:ahorro) -and [bool]$settings.QwenReopen

    Write-DaemonLog ('Ajustes de voz aplicados: es={0}, en={1}, rendimiento {2}' -f $engines['es'], $engines['en'], $settings.Performance)
    $sync.ReloadSynth = $true
    [void]$sync.SynthSignal.Set()
    Start-Warmup
}

# --------------------------------------------------------------------------
# Reproductor flotante.
# --------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Read Aloud"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize">
  <Window.Resources>
    <!--
      Estilo propio para todos los botones. El de Windows pinta un fondo claro
      al pasar el cursor, y el texto, que tambien es claro, se perdia encima.
      Aqui el resaltado es un velo blanco translucido sobre el fondo oscuro:
      se nota el cambio y el texto conserva el contraste.
    -->
    <Style TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Fondo" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Fondo" Property="Background" Value="#2EFFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Fondo" Property="Background" Value="#4DFFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Barra de desplazamiento fina y oscura para el panel de texto. La de
         Windows es clara y ancha, y desentona sobre el fondo oscuro. -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="MinWidth" Value="6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border Background="#55FFFFFF" CornerRadius="3"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Fader del volumen: pista fina, tramo de abajo relleno con el color de
         acento y una perilla redonda. Los dos RepeatButton son el trazo de la
         pista a cada lado de la perilla; el de abajo es el relleno. -->
    <Style x:Key="TrazoFader" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="RellenoFader" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="Transparent">
              <Border Width="4" CornerRadius="2" Background="#9AE6B4" HorizontalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Fader" TargetType="Slider">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Background="Transparent">
              <Border Width="4" CornerRadius="2" Background="#3AFFFFFF" HorizontalAlignment="Center"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Style="{StaticResource RellenoFader}"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" Style="{StaticResource TrazoFader}"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="16" Height="16" Cursor="Hand">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Ellipse Fill="White" Stroke="#66000000" StrokeThickness="1"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Bordes para cambiar el tamano. Invisibles, como en cualquier ventana:
         solo el cursor cambia al pasar por encima. El fondo transparente, y no
         vacio, es lo que hace que reciban el raton. Con clave propia y no como
         estilo implicito: uno implicito tambien cambiaria el control de la
         barra de posicion, que por dentro es otro Thumb. -->
    <Style x:Key="Borde" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <!-- La escala agranda o achica todo el reproductor (ajuste "Tamano"). -->
  <Grid x:Name="Escala">
  <Grid.LayoutTransform>
    <ScaleTransform x:Name="Zoom" ScaleX="1" ScaleY="1"/>
  </Grid.LayoutTransform>
  <Grid.RowDefinitions>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>
  <!-- Pestana para agarrar la ventana y moverla. La barra tambien se arrastra
       desde sus huecos, pero entre tantos botones cuesta atinarle. Monta un
       pixel sobre el borde de Root y va por encima, para tapar esa linea y
       verse como parte de la ventana. -->
  <Border x:Name="Asa" Grid.Row="0" Panel.ZIndex="1" HorizontalAlignment="Center"
          Width="72" Height="14" Margin="0,0,0,-1" CornerRadius="7,7,0,0"
          Background="#F21B1B1F" BorderBrush="#33FFFFFF" BorderThickness="1,1,1,0"
          Cursor="SizeAll" ToolTip="Arrastra para mover. Doble clic: volver a la esquina">
    <Border Width="26" Height="3" CornerRadius="1.5" Background="#80FFFFFF"
            VerticalAlignment="Center" Margin="0,2,0,0"/>
  </Border>
  <Border x:Name="Root" Grid.Row="1" CornerRadius="10" Background="#F21B1B1F" BorderBrush="#33FFFFFF"
          BorderThickness="1" Padding="10,7">
    <Border.Effect>
      <DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.45" Color="#000000"/>
    </Border.Effect>
    <StackPanel Orientation="Vertical">
    <!-- Panel con el texto que se esta leyendo. El ancho se ata al de la
         barra de controles: sin limite, el texto no partiria las lineas y la
         ventana creceria a lo ancho sin fin. -->
    <!-- El ancho parte del de la barra y nunca baja de el. Al estirar el
         panel se le pone un ancho propio, que sustituye al enlace. -->
    <Grid x:Name="TextPanel" Visibility="Collapsed" Height="147" Margin="0,2,0,8"
          HorizontalAlignment="Right"
          Width="{Binding ActualWidth, ElementName=Bar}"
          MinWidth="{Binding ActualWidth, ElementName=Bar}">
    <Border CornerRadius="6" Background="#FF26262B" Padding="8,6,2,6">
      <!-- IsUndoEnabled apagado: cada cambio de color del resaltado quedaria
           guardado en el historial de deshacer y la memoria creceria sin fin. -->
      <RichTextBox x:Name="TextView" IsReadOnly="True" IsUndoEnabled="False"
                   Background="Transparent" BorderThickness="0" Padding="0"
                   Foreground="#D0D0D6" FontFamily="Segoe UI" FontSize="13"
                   SelectionBrush="#569CF6" SelectionOpacity="0.45"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <RichTextBox.ContextMenu>
          <ContextMenu>
            <MenuItem Header="Copiar" Command="ApplicationCommands.Copy" InputGestureText="Ctrl+C"
                      CommandTarget="{Binding PlacementTarget, RelativeSource={RelativeSource AncestorType=ContextMenu}}"/>
            <MenuItem Header="Seleccionar todo" Command="ApplicationCommands.SelectAll" InputGestureText="Ctrl+A"
                      CommandTarget="{Binding PlacementTarget, RelativeSource={RelativeSource AncestorType=ContextMenu}}"/>
          </ContextMenu>
        </RichTextBox.ContextMenu>
        <FlowDocument PagePadding="0"/>
      </RichTextBox>
    </Border>
    </Grid>
    <StackPanel x:Name="Bar" Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Right">
      <TextBlock x:Name="LangBadge" Text="ES" Foreground="#9AE6B4" FontFamily="Segoe UI"
                 FontSize="10" FontWeight="Bold" VerticalAlignment="Center" Margin="2,0,8,0"/>
      <Button x:Name="BtnBack" Content="-10" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold"
              Width="28" Height="26" Foreground="White" Background="Transparent"
              BorderThickness="0" Cursor="Hand" ToolTip="Retroceder 10 segundos"/>
      <Button x:Name="BtnPlay" Content="&#xE769;" FontFamily="Segoe MDL2 Assets" FontSize="14"
              Width="30" Height="30" Foreground="White" Background="Transparent"
              BorderThickness="0" Cursor="Hand" ToolTip="Pausar o continuar"/>
      <Button x:Name="BtnFwd" Content="+10" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold"
              Width="28" Height="26" Foreground="White" Background="Transparent"
              BorderThickness="0" Cursor="Hand" ToolTip="Avanzar 10 segundos"/>
      <Button x:Name="BtnSpeed" Content="1x" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold"
              Width="40" Height="26" Foreground="#9AE6B4" Background="Transparent"
              BorderThickness="0" Cursor="Hand" Margin="4,0,0,0"
              ToolTip="Velocidad. Clic: elegir. Rueda: mas rapido o mas lento."/>
      <Button x:Name="BtnVolume" Content="&#xE767;" FontFamily="Segoe MDL2 Assets" FontSize="13"
              Width="30" Height="26" Foreground="#C8C8CC" Background="Transparent"
              BorderThickness="0" Cursor="Hand" Margin="2,0,0,0"
              ToolTip="Volumen. Clic: ajustar. Rueda: subir o bajar."/>
      <Grid Width="170" Height="26" Margin="8,0,8,0" VerticalAlignment="Center">
        <Border Height="4" CornerRadius="2" Background="#3AFFFFFF" VerticalAlignment="Center"/>
        <Border x:Name="BufferBar" Height="4" CornerRadius="2" Background="#55FFFFFF"
                HorizontalAlignment="Left" VerticalAlignment="Center" Width="0"/>
        <Slider x:Name="Seek" Minimum="0" Maximum="100" Value="0" VerticalAlignment="Center"
                Background="Transparent" IsMoveToPointEnabled="True"/>
      </Grid>
      <TextBlock x:Name="TimeLabel" Text="0:00 / 0:00" Foreground="#D8D8DC" FontFamily="Segoe UI"
                 FontSize="11" VerticalAlignment="Center" Width="86" TextAlignment="Right"/>
      <Button x:Name="BtnText" Content="&#x2261;" FontFamily="Segoe UI" FontSize="15"
              Width="26" Height="26" Foreground="#C8C8CC" Background="Transparent"
              BorderThickness="0" Cursor="Hand" Margin="6,0,0,0"
              ToolTip="Mostrar el texto que se esta leyendo"/>
      <Button x:Name="BtnSettings" Content="&#xE713;" FontFamily="Segoe MDL2 Assets" FontSize="13"
              Width="26" Height="26" Foreground="#C8C8CC" Background="Transparent"
              BorderThickness="0" Cursor="Hand" Margin="2,0,0,0" ToolTip="Ajustes"/>
      <Button x:Name="BtnClose" Content="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="12"
              Width="26" Height="26" Foreground="#C8C8CC" Background="Transparent"
              BorderThickness="0" Cursor="Hand" Margin="2,0,0,0" ToolTip="Cerrar"/>
    </StackPanel>
    </StackPanel>
  </Border>
  <!-- Bordes para cambiar el tamano, en el contorno de la ventana como en
       cualquier aplicacion: cada uno mueve su lado y el opuesto queda quieto.
       Caen sobre el relleno de Root, asi que no tapan ningun control. Solo
       se muestran con el panel de texto abierto, que es lo que crece. -->
  <Grid x:Name="Bordes" Grid.Row="1" Visibility="Collapsed">
    <Thumb x:Name="BordeArriba" Style="{StaticResource Borde}" Height="6"
           VerticalAlignment="Top" Margin="12,0" Cursor="SizeNS"/>
    <Thumb x:Name="BordeAbajo" Style="{StaticResource Borde}" Height="6"
           VerticalAlignment="Bottom" Margin="12,0" Cursor="SizeNS"/>
    <Thumb x:Name="BordeIzquierda" Style="{StaticResource Borde}" Width="6"
           HorizontalAlignment="Left" Margin="0,12" Cursor="SizeWE"/>
    <Thumb x:Name="BordeDerecha" Style="{StaticResource Borde}" Width="6"
           HorizontalAlignment="Right" Margin="0,12" Cursor="SizeWE"/>
    <Thumb x:Name="EsquinaArribaIzquierda" Style="{StaticResource Borde}" Width="12" Height="12"
           HorizontalAlignment="Left" VerticalAlignment="Top" Cursor="SizeNWSE"/>
    <Thumb x:Name="EsquinaArribaDerecha" Style="{StaticResource Borde}" Width="12" Height="12"
           HorizontalAlignment="Right" VerticalAlignment="Top" Cursor="SizeNESW"/>
    <Thumb x:Name="EsquinaAbajoIzquierda" Style="{StaticResource Borde}" Width="12" Height="12"
           HorizontalAlignment="Left" VerticalAlignment="Bottom" Cursor="SizeNESW"/>
    <Thumb x:Name="EsquinaAbajoDerecha" Style="{StaticResource Borde}" Width="12" Height="12"
           HorizontalAlignment="Right" VerticalAlignment="Bottom" Cursor="SizeNWSE"/>
  </Grid>
  <!-- Las velocidades, en fila sobre el boton. Se cierra sola al elegir o al
       hacer clic en otra parte. -->
  <Popup x:Name="SpeedPopup" PlacementTarget="{Binding ElementName=BtnSpeed}" Placement="Top"
         VerticalOffset="-6" StaysOpen="False" AllowsTransparency="True" PopupAnimation="Fade">
    <Border Background="#F81B1B1F" BorderBrush="#33FFFFFF" BorderThickness="1" CornerRadius="8" Padding="4">
      <StackPanel x:Name="SpeedList" Orientation="Horizontal"/>
    </Border>
  </Popup>
  <!-- El volumen: un fader vertical sobre el boton, con el porcentaje arriba.
       Se cierra solo al hacer clic en otra parte. -->
  <Popup x:Name="VolumePopup" PlacementTarget="{Binding ElementName=BtnVolume}" Placement="Top"
         VerticalOffset="-6" StaysOpen="False" AllowsTransparency="True" PopupAnimation="Fade">
    <Border Background="#F81B1B1F" BorderBrush="#33FFFFFF" BorderThickness="1" CornerRadius="8"
            Padding="6,8,6,8">
      <StackPanel Orientation="Vertical" HorizontalAlignment="Center">
        <TextBlock x:Name="VolumeLabel" Text="100 %" Foreground="#D8D8DC" FontFamily="Segoe UI"
                   FontSize="11" FontWeight="SemiBold" TextAlignment="Center" Width="42"/>
        <Slider x:Name="VolumeFader" Style="{StaticResource Fader}" Orientation="Vertical"
                Minimum="0" Maximum="100" Value="100" SmallChange="5" LargeChange="10"
                IsMoveToPointEnabled="True" Height="112" Width="28" Margin="0,8,0,0"/>
      </StackPanel>
    </Border>
  </Popup>
  </Grid>
</Window>
'@

# Tema de color (ajustes Theme y Accent): el XAML esta escrito en oscuro y se
# adapta antes de cargarlo.
$script:paleta = Get-ThemePalette -Mode (Resolve-ThemeMode -Mode ([string]$settings.Theme) -SystemLight (Test-SystemLightTheme)) -Accent ([string]$settings.Accent)
$xaml = ConvertTo-DynamicXaml -Xaml $xaml

$reader = New-Object IO.StringReader($xaml)
$xmlReader = [Xml.XmlReader]::Create($reader)
$window = [Windows.Markup.XamlReader]::Load($xmlReader)
Set-ThemeResources -Resources $window.Resources -Palette $script:paleta

$ui = @{}
foreach ($name in @('Root','LangBadge','BtnBack','BtnPlay','BtnFwd','BtnSpeed','BufferBar','Seek','TimeLabel','BtnText','BtnClose','TextPanel','TextView','Bar','Bordes',
                    'Asa','Zoom','BtnSettings','SpeedPopup','SpeedList','Escala',
                    'BtnVolume','VolumePopup','VolumeLabel','VolumeFader')) {
    $ui[$name] = $window.FindName($name)
}

# Opacidad: translucida en reposo, para no tapar del todo lo que hay detras, y
# opaca mientras la usas. Un clic sobre ella la activa y un clic en cualquier
# otra parte la desactiva; Windows avisa de ambos. Al ocultarse tambien se
# desactiva, asi que cada lectura vuelve a aparecer translucida.
$script:opacidadReposo = [Math]::Max(0.3, [Math]::Min(1.0, [double]$settings.PlayerOpacity))
$window.Opacity = $script:opacidadReposo
$window.Add_Activated({ $window.Opacity = 1.0 })
$window.Add_Deactivated({ $window.Opacity = $script:opacidadReposo })

# Tamano de todo el reproductor y de la letra del panel de texto. Los dos se
# cambian desde los ajustes (lib\ReadAloud.Settings.ps1).
function Set-PlayerScale {
    param([double]$Value)
    $escala = [Math]::Max(0.8, [Math]::Min(1.6, $Value))
    $ui.Zoom.ScaleX = $escala
    $ui.Zoom.ScaleY = $escala
}

$script:fuente = [Math]::Max(10, [Math]::Min(22, [double]$settings.TextFontSize))
$ui.TextView.FontSize = $script:fuente
Set-PlayerScale ([double]$settings.PlayerScale)

# Posicion: la ventana se ancla por su esquina inferior derecha. Asi aparece
# abajo a la derecha, y al abrir el panel de texto crece hacia arriba sin que
# la barra de controles se mueva.
#
# Las versiones anteriores guardaban la esquina superior izquierda, y esa
# posicion se descarta a proposito: con el panel la ventana cambia de alto, y
# anclada por arriba la barra se desplazaba hacia abajo o se salia de la vista.
$script:ancla = $null

if (Test-Path -LiteralPath $paths.StateFile) {
    try {
        $savedState = Get-Content -LiteralPath $paths.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $propiedades = $savedState.PSObject.Properties.Name
        if (($propiedades -contains 'Right') -and ($propiedades -contains 'Bottom')) {
            $script:ancla = @{ Right = [double]$savedState.Right; Bottom = [double]$savedState.Bottom }
        }
    } catch { }
}

function Set-PlayerPosition {
    # Coloca la ventana segun su esquina inferior derecha: la de la pantalla si
    # nunca la moviste, o la que dejaste al arrastrarla.
    $ancho = $window.ActualWidth
    $alto = $window.ActualHeight
    if ($ancho -le 0) { $ancho = 480 }
    if ($alto -le 0) { $alto = 50 }

    $area = [Windows.SystemParameters]::WorkArea
    $derecha = $area.Right - 12
    $abajo = $area.Bottom - 12

    if ($null -ne $script:ancla) {
        $derecha = $script:ancla.Right
        $abajo = $script:ancla.Bottom
    }

    $izquierda = $derecha - $ancho
    $arriba = $abajo - $alto

    # La esquina guardada puede ser de un monitor que ya no esta conectado. Si
    # la ventana no cabe entera en el escritorio actual, vuelve a la esquina.
    $pantallaIzq = [Windows.SystemParameters]::VirtualScreenLeft
    $pantallaArr = [Windows.SystemParameters]::VirtualScreenTop
    $pantallaDer = $pantallaIzq + [Windows.SystemParameters]::VirtualScreenWidth
    $pantallaAba = $pantallaArr + [Windows.SystemParameters]::VirtualScreenHeight

    $cabe = ($izquierda -ge $pantallaIzq) -and ($arriba -ge $pantallaArr) -and
            ($derecha -le $pantallaDer) -and ($abajo -le $pantallaAba)

    if (-not $cabe) {
        $script:ancla = $null
        $izquierda = $area.Right - 12 - $ancho
        $arriba = $area.Bottom - 12 - $alto
    }

    $window.Left = $izquierda
    $window.Top = $arriba
}

Set-PlayerPosition

# Dos reproductores en vez de uno. Abrir un archivo cuesta cerca de medio
# segundo, y hacerlo al terminar el fragmento anterior dejaba ese hueco de
# silencio en cada cambio, con lo que todas las transiciones sonaban igual de
# largas. Mientras uno suena, el otro ya tiene cargado el fragmento siguiente
# y el relevo es inmediato. Asi las unicas pausas que se oyen son las que el
# texto pide.
$players = @(
    (New-Object Windows.Media.MediaPlayer),
    (New-Object Windows.Media.MediaPlayer)
)

function Get-ActivePlayer { return $players[$state.Active] }
function Get-IdlePlayer   { return $players[1 - $state.Active] }

# Velocidades de la lista del boton. Se cambia la velocidad de reproduccion, no
# la de sintesis: asi el cambio es inmediato y no hay que regenerar el audio.
$speedSteps = @(0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0)
$script:speed = 1.0

if ($savedState -and $savedState.PSObject.Properties.Name -contains 'Speed') {
    $saved = [double]$savedState.Speed
    if ($speedSteps -contains $saved) { $script:speed = $saved }
}

# Volumen del reproductor (0 a 1). Es el de esta aplicacion: no toca el volumen
# de Windows. El fader del boton da cualquier valor de 0 a 100 %; la rueda y
# las ordenes 'louder' y 'quieter' suben y bajan de a 5 %.
$volumeSteps = @(0..20 | ForEach-Object { $_ / 20.0 })
$script:volumeSincronizando = $false
$script:volumePendiente = $false
$script:volume = 1.0

if ($savedState -and $savedState.PSObject.Properties.Name -contains 'Volume') {
    $saved = [double]$savedState.Volume
    if ($saved -ge 0.0 -and $saved -le 1.0) { $script:volume = $saved }
}

function Save-PlayerState {
    # Se guarda en cada cambio y no solo al cerrar: si el proceso se corta a
    # la fuerza, la velocidad elegida no se pierde.
    try {
        $estado = @{ Speed = $script:speed; Volume = $script:volume; TextPanel = $script:panelVisible }

        if ($script:panelAlto -gt 0) { $estado.PanelHeight = $script:panelAlto }
        if ($script:panelAncho -gt 0) { $estado.PanelWidth = $script:panelAncho }

        # Solo se guarda la esquina si la moviste a mano; si no, se usa la de
        # la pantalla, que sigue siendo valida aunque cambie la resolucion.
        if ($null -ne $script:ancla) {
            $estado.Right = $script:ancla.Right
            $estado.Bottom = $script:ancla.Bottom
        }

        $estado |
            ConvertTo-Json |
            Set-Content -LiteralPath $paths.StateFile -Encoding UTF8
    } catch { }
}

function Set-PlaybackSpeedValue {
    param([double]$Value)

    $script:speed = $Value
    foreach ($p in $players) { $p.SpeedRatio = $script:speed }
    $ui.BtnSpeed.Content = Format-Speed $script:speed
    foreach ($b in $ui.SpeedList.Children) {
        if ([double]$b.Tag -eq $script:speed) {
            $b.Foreground = $colores.Encendido
            $b.Background = $colores.Elegido
        } else {
            $b.Foreground = $colores.Texto
            $b.Background = $colores.Ninguno
        }
    }
    Save-PlayerState
}

function Set-PlaybackSpeed {
    # Un paso mas rapido (1) o mas lento (-1): la rueda sobre el boton y las
    # ordenes 'faster' y 'slower' de read_aloud.ps1.
    param([int]$Direction)

    Set-PlaybackSpeedValue (Get-NextStep -Steps $speedSteps -Current $script:speed -Direction $Direction)
}

foreach ($paso in $speedSteps) {
    $boton = New-Object Windows.Controls.Button
    $boton.Content = Format-Speed $paso
    $boton.Tag = $paso
    $boton.Width = 40
    $boton.Height = 26
    $boton.FontFamily = New-Object Windows.Media.FontFamily('Segoe UI')
    $boton.FontSize = 11
    $boton.FontWeight = [Windows.FontWeights]::SemiBold
    $boton.Add_Click({
        param($sender, $e)
        Set-PlaybackSpeedValue ([double]$sender.Tag)
        $ui.SpeedPopup.IsOpen = $false
    })
    [void]$ui.SpeedList.Children.Add($boton)
}

function Set-PlaybackVolumeValue {
    # -NoSave: mientras se arrastra el fader el valor cambia decenas de veces
    # por segundo; se guarda una sola vez al soltarlo o al cerrar la lista.
    param([double]$Value, [switch]$NoSave)

    $script:volume = [Math]::Max(0.0, [Math]::Min(1.0, $Value))
    foreach ($p in $players) { $p.Volume = $script:volume }

    # El icono dice de un vistazo si esta en silencio; el detalle, en el aviso.
    if ($script:volume -le 0.0) { $ui.BtnVolume.Content = [string][char]0xE74F } else { $ui.BtnVolume.Content = [string][char]0xE767 }
    $ui.BtnVolume.ToolTip = 'Volumen {0}. Clic: ajustar. Rueda: subir o bajar.' -f (Format-VolumePercent $script:volume)
    $ui.VolumeLabel.Text = Format-VolumePercent $script:volume

    # El fader sigue al volumen cuando este cambia por la rueda o por una
    # orden; la guarda evita que ese cambio vuelva a entrar como si lo hubiera
    # movido la persona.
    $script:volumeSincronizando = $true
    try { $ui.VolumeFader.Value = [Math]::Round($script:volume * 100) }
    finally { $script:volumeSincronizando = $false }

    if ($NoSave) { $script:volumePendiente = $true } else { Save-PlayerState; $script:volumePendiente = $false }
}

function Save-PendingVolume {
    if ($script:volumePendiente) { Save-PlayerState; $script:volumePendiente = $false }
}

function Set-PlaybackVolume {
    # Un paso mas alto (1) o mas bajo (-1): la rueda sobre el boton y las
    # ordenes 'louder' y 'quieter'.
    param([int]$Direction)

    Set-PlaybackVolumeValue (Get-NextStep -Steps $volumeSteps -Current $script:volume -Direction $Direction)
}

# El fader: arrastrar la perilla o hacer clic en la pista cambia el volumen al
# instante, sin cerrar la lista. La rueda sobre el fader sube y baja de a 5 %.
$ui.VolumeFader.Add_ValueChanged({
    param($sender, $e)
    if ($script:volumeSincronizando) { return }
    Set-PlaybackVolumeValue ([Math]::Round($e.NewValue) / 100.0) -NoSave
})
$ui.VolumeFader.Add_PreviewMouseLeftButtonUp({ Save-PendingVolume })
$ui.VolumeFader.Add_LostMouseCapture({ Save-PendingVolume })
$ui.VolumeFader.Add_MouseWheel({
    param($sender, $e)
    if ($e.Delta -gt 0) { Set-PlaybackVolume -Direction 1 } else { Set-PlaybackVolume -Direction -1 }
    $e.Handled = $true
})

# Misma colocacion que la fila de la velocidad: centrada sobre el boton, sin
# pasarse del borde izquierdo del reproductor.
$ui.VolumePopup.Add_Opened({
    $ui.VolumePopup.Child.UpdateLayout()
    $centrada = ($ui.BtnVolume.ActualWidth - $ui.VolumePopup.Child.ActualWidth) / 2
    $hastaElBorde = -$ui.BtnVolume.TranslatePoint((New-Object Windows.Point(0, 0)), $ui.Root).X
    $ui.VolumePopup.HorizontalOffset = [Math]::Max($centrada, $hastaElBorde)
})

$script:volumePopupCerrada = [datetime]::MinValue
$ui.VolumePopup.Add_Closed({
    $script:volumePopupCerrada = [datetime]::Now
    Save-PendingVolume
})

# Centrada sobre el boton, que es mas angosto que la fila, pero sin pasarse
# del borde izquierdo del reproductor: el boton esta cerca de ese borde.
$ui.SpeedPopup.Add_Opened({
    $ui.SpeedPopup.Child.UpdateLayout()
    $centrada = ($ui.BtnSpeed.ActualWidth - $ui.SpeedPopup.Child.ActualWidth) / 2
    $hastaElBorde = -$ui.BtnSpeed.TranslatePoint((New-Object Windows.Point(0, 0)), $ui.Root).X
    $ui.SpeedPopup.HorizontalOffset = [Math]::Max($centrada, $hastaElBorde)
})

# Un clic en el boton con la fila abierta primero la cierra (cuenta como clic
# fuera de ella) y despues llegaria al boton, que la volveria a abrir.
$script:speedPopupCerrada = [datetime]::MinValue
$ui.SpeedPopup.Add_Closed({ $script:speedPopupCerrada = [datetime]::Now })

# --------------------------------------------------------------------------
# Estado de la lectura en curso.
# --------------------------------------------------------------------------
$state = [pscustomobject]@{
    Generation    = 0
    Chunks        = New-Object System.Collections.Generic.List[object]
    PlayIndex     = -1
    IsPlaying     = $false
    Active        = 0
    PreloadIndex  = -1
    HighlightIndex = -1
    IsSeeking     = $false
    SyncingSlider = $false
    PendingSlider = $null
    PendingSeek   = $null
    Total         = 0.0
    LastText      = ''
    LastTextAt    = [datetime]::MinValue
    Finished      = $true
    WaitingForNext = $false
    # Fragmento al que se salto y que aun no tiene audio (-1: ninguno). Mientras
    # se espera, la posicion es el comienzo de ese fragmento.
    WaitTarget    = -1
}

function Update-Offsets {
    $state.Total = Update-ChunkOffsets -Chunks $state.Chunks
}

function Get-GlobalPosition {
    if ($state.WaitTarget -ge 0 -and $state.WaitTarget -lt $state.Chunks.Count) {
        return $state.Chunks[$state.WaitTarget].Offset
    }
    if ($state.PlayIndex -lt 0 -or $state.PlayIndex -ge $state.Chunks.Count) { return 0.0 }
    return $state.Chunks[$state.PlayIndex].Offset + (Get-ActivePlayer).Position.TotalSeconds
}

function Open-NextChunk {
    # Deja listo el fragmento siguiente en el reproductor que no esta sonando.
    if ($state.PlayIndex -lt 0) { return }

    $siguiente = $state.PlayIndex + 1
    if ($siguiente -ge $state.Chunks.Count) { return }
    if ($state.PreloadIndex -eq $siguiente) { return }
    if (-not $state.Chunks[$siguiente].Ready) { return }

    try {
        (Get-IdlePlayer).Open([uri]$state.Chunks[$siguiente].Wav)
        $state.PreloadIndex = $siguiente
    } catch {
        $state.PreloadIndex = -1
    }
}

function Set-PlayIcon {
    param([bool]$Playing)
    # E769 = pausa, E768 = reproducir.
    if ($Playing) {
        $ui.BtnPlay.Content = [char]0xE769
    } else {
        $ui.BtnPlay.Content = [char]0xE768
    }
}

# La ventana es translucida (AllowsTransparency) y Windows guarda la ultima
# imagen que dibujo: al volver a mostrarla, ensenaba un cuadro de la lectura
# anterior (su texto, su idioma y su tiempo) antes de dibujar la nueva. Por eso
# primero se vacia y se esconde cuando WPF ya dibujo la ventana vacia; si
# llega otra lectura en ese rato, sigue a la vista.
$script:ocultando = $false
$relojOcultar = New-Object Windows.Threading.DispatcherTimer
$relojOcultar.Interval = [TimeSpan]::FromMilliseconds(120)
$relojOcultar.Add_Tick({
    $relojOcultar.Stop()
    if ($script:ocultando) {
        $script:ocultando = $false
        $window.Hide()
    }
})

function Hide-PlayerWindow {
    $ui.Escala.Visibility = 'Hidden'
    $script:ocultando = $true
    $relojOcultar.Stop()
    $relojOcultar.Start()
}

function Show-PlayerWindow {
    $relojOcultar.Stop()
    $script:ocultando = $false
    $ui.Escala.Visibility = 'Visible'
    $window.Show()
}

function Stop-Playback {
    param([switch]$KeepWindow)

    foreach ($p in $players) {
        $p.Stop()
        try { $p.Close() } catch { }
    }

    $state.PreloadIndex = -1

    $state.IsPlaying = $false
    $state.Finished = $true
    $state.WaitingForNext = $false
    $state.WaitTarget = -1
    $sync.Priority = -1
    $state.PlayIndex = -1
    Set-PlayIcon -Playing $false

    foreach ($chunk in $state.Chunks) {
        if ($chunk.Wav -and (Test-Path -LiteralPath $chunk.Wav)) {
            Remove-Item -LiteralPath $chunk.Wav -Force -ErrorAction SilentlyContinue
        }
    }

    $state.Chunks.Clear()

    $ui.TextView.Document.Blocks.Clear()
    $script:runs.Clear()
    $state.HighlightIndex = -1
    $state.Total = 0.0

    if (-not $KeepWindow) { Hide-PlayerWindow }
}

function Start-Chunk {
    param(
        [int]$Index,
        [double]$Offset = 0.0,
        [bool]$AutoPlay = $true
    )

    if ($Index -lt 0 -or $Index -ge $state.Chunks.Count) { return }

    $chunk = $state.Chunks[$Index]
    if (-not $chunk.Ready) { return }

    $state.PlayIndex = $Index
    $state.WaitingForNext = $false
    $state.WaitTarget = -1
    $state.PendingSeek = $Offset
    $state.IsPlaying = $AutoPlay

    # Lo que hubiera precargado deja de servir: se va a otro punto.
    $state.PreloadIndex = -1
    (Get-IdlePlayer).Stop()

    $ui.LangBadge.Text = $chunk.Lang.ToUpperInvariant()
    (Get-ActivePlayer).Open([uri]$chunk.Wav)
}

function Invoke-SentenceStep {
    # Frase anterior (-1) o siguiente (+1). La anterior, con mas de 2 s de la
    # actual, vuelve primero a su comienzo, como en un reproductor de musica.
    param([int]$Direction)

    $actual = $state.PlayIndex
    if ($state.WaitTarget -ge 0) { $actual = $state.WaitTarget }

    $i = Get-SentenceTarget -Chunks $state.Chunks -PlayIndex $actual -Position (Get-GlobalPosition) -Direction $Direction
    if ($i -lt 0) { return }

    $state.IsPlaying = $true
    Set-PlayIcon -Playing $true
    # El margen minimo asegura que el salto caiga dentro de esa frase.
    Invoke-Seek -TargetSeconds ($state.Chunks[$i].Offset + 0.01)
}

function Switch-ToPreloaded {
    # El fragmento siguiente ya esta abierto en el otro reproductor: pasa a
    # sonar ese, sin volver a abrir ningun archivo. Lo usan el final de cada
    # frase y los saltos a la frase de al lado.
    param([double]$Offset = 0.0)

    $next = $state.PlayIndex + 1
    (Get-ActivePlayer).Stop()

    $state.Active = 1 - $state.Active
    $state.PlayIndex = $next
    $state.PreloadIndex = -1
    $state.WaitingForNext = $false
    $state.WaitTarget = -1

    $nuevo = Get-ActivePlayer
    $ui.LangBadge.Text = $state.Chunks[$next].Lang.ToUpperInvariant()

    try { $nuevo.Position = [timespan]::FromSeconds($Offset) } catch { }
    $nuevo.Volume = $script:volume
    $nuevo.Play()
    $nuevo.SpeedRatio = $script:speed

    Open-NextChunk
}

function Invoke-Seek {
    # Salta a cualquier punto de la lectura, tenga o no el audio ya generado.
    # Con audio: salto inmediato (sin reabrir el archivo si es la misma frase
    # que suena o la siguiente, que ya esta precargada). Sin audio: el sonido
    # actual se detiene, ese fragmento pasa a generarse primero y suena en
    # cuanto llega.
    param([double]$TargetSeconds)

    if ($state.Chunks.Count -eq 0) { return }

    $destino = Get-SeekTarget -Chunks $state.Chunks -Seconds $TargetSeconds
    if ($null -eq $destino) { return }

    Write-DaemonLog ('Salto a {0:N1} s de {1:N1} s, fragmento {2} de {3} (comienza en {4:N1} s){5}' -f `
        $destino.Seconds, $state.Total, ($destino.Index + 1), $state.Chunks.Count, $state.Chunks[$destino.Index].Offset,
        $(if ($destino.Ready) { '' } else { ', sin audio todavia' }))

    $i = $destino.Index

    if ($destino.Ready) {
        $state.WaitTarget = -1
        $activo = Get-ActivePlayer

        if ($i -eq $state.PlayIndex -and $null -eq $state.PendingSeek) {
            # Misma frase: se mueve el punto sin reabrir nada.
            try {
                $activo.Position = [timespan]::FromSeconds($destino.Offset)
                if ($state.IsPlaying) { $activo.Play() }
                return
            } catch { }
        }

        if ($i -eq ($state.PlayIndex + 1) -and $state.PreloadIndex -eq $i -and $state.IsPlaying) {
            Switch-ToPreloaded -Offset $destino.Offset
            return
        }

        Start-Chunk -Index $i -Offset $destino.Offset -AutoPlay $state.IsPlaying
        return
    }

    # Sin audio: se espera a ese fragmento y se genera primero. El pulso lo
    # arranca en cuanto llega (WaitingForNext con PlayIndex justo antes).
    (Get-ActivePlayer).Pause()
    (Get-IdlePlayer).Stop()
    $state.PreloadIndex = -1
    $state.PendingSeek = $null
    $state.PlayIndex = $i - 1
    $state.WaitTarget = $i
    $state.WaitingForNext = $true
    $state.Finished = $false
    # La insignia de idioma marca que se esta esperando; Start-Chunk la repone.
    $ui.LangBadge.Text = '...'

    $sync.PriorityGen = $sync.Generation
    $sync.Priority = $i
    [void]$sync.SynthSignal.Set()
}

# --------------------------------------------------------------------------
# Panel de texto: muestra lo que se esta leyendo y resalta la frase que suena.
#
# Es un RichTextBox de solo lectura y no un TextBlock: un TextBlock no deja
# seleccionar, y el texto tiene que poder copiarse. Un clic sin arrastrar
# salta a esa frase; arrastrar selecciona, y el clic derecho ofrece copiar.
# --------------------------------------------------------------------------
$conversorColor = New-Object Windows.Media.BrushConverter

function New-Brush {
    param([string]$Hex)
    $pincel = $conversorColor.ConvertFromString($Hex)
    $pincel.Freeze()
    return $pincel
}

$colorTema = Get-RuntimeColors $script:paleta
$colores = @{
    Pendiente = New-Brush $colorTema.Pendiente
    Leido     = New-Brush $colorTema.Leido
    Actual    = New-Brush $colorTema.Actual
    Fondo     = New-Brush $colorTema.Fondo
    Ninguno   = [Windows.Media.Brushes]::Transparent
    Encendido = New-Brush $colorTema.Encendido
    Apagado   = New-Brush $colorTema.Apagado
    Texto     = New-Brush $colorTema.Texto
    Elegido   = New-Brush $colorTema.Elegido
}

$script:runs = New-Object System.Collections.Generic.List[object]
$script:panelVisible = $false

if ($savedState -and $savedState.PSObject.Properties.Name -contains 'TextPanel') {
    $script:panelVisible = [bool]$savedState.TextPanel
}

function Build-TextPanel {
    # Un parrafo por bloque y, dentro, un trozo por frase. Cada trozo sabe a
    # que fragmento de audio corresponde.
    $documento = $ui.TextView.Document
    $documento.Blocks.Clear()
    $script:runs.Clear()
    $state.HighlightIndex = -1

    $bloque = -1
    $parrafo = $null

    for ($i = 0; $i -lt $state.Chunks.Count; $i++) {
        $c = $state.Chunks[$i]

        if ($c.Block -ne $bloque) {
            $parrafo = New-Object Windows.Documents.Paragraph
            $parrafo.LineHeight = [Math]::Round($script:fuente * 1.46)

            switch ($c.Kind) {
                'titulo' {
                    $parrafo.FontWeight = [Windows.FontWeights]::SemiBold
                    $parrafo.FontSize = $script:fuente + 1
                    $arriba = 0
                    if ($i -gt 0) { $arriba = 10 }
                    $parrafo.Margin = New-Object Windows.Thickness(0, $arriba, 0, 4)
                }
                'fila'   { $parrafo.Margin = New-Object Windows.Thickness(0, 0, 0, 2) }
                'arbol'  {
                    # Letra de ancho fijo: las ramas del arbol quedan alineadas.
                    $parrafo.Margin = New-Object Windows.Thickness(0, 0, 0, 1)
                    $parrafo.FontFamily = New-Object Windows.Media.FontFamily('Consolas')
                }
                'vineta' { $parrafo.Margin = New-Object Windows.Thickness(6, 0, 0, 2) }
                default  { $parrafo.Margin = New-Object Windows.Thickness(0, 0, 0, 8) }
            }

            $documento.Blocks.Add($parrafo)
            $bloque = $c.Block
        } else {
            $parrafo.Inlines.Add([Windows.Documents.Run]::new(' '))
        }

        $trozo = [Windows.Documents.Run]::new([string]$c.Display)
        $trozo.Tag = $i
        $trozo.Foreground = $colores.Pendiente

        $parrafo.Inlines.Add($trozo)
        [void]$script:runs.Add(@{ Run = $trozo })
    }

    $ui.TextView.ScrollToHome()
}

function Set-TextFont {
    # Cambia la letra del panel sin rearmar el texto, para no perder por donde
    # va la lectura.
    param([double]$Size)

    $script:fuente = [Math]::Max(10, [Math]::Min(22, $Size))
    $ui.TextView.FontSize = $script:fuente
    foreach ($bloque in $ui.TextView.Document.Blocks) {
        $bloque.LineHeight = [Math]::Round($script:fuente * 1.46)
        if ($bloque.FontWeight -eq [Windows.FontWeights]::SemiBold) { $bloque.FontSize = $script:fuente + 1 }
    }
}

function Start-FromChunk {
    # Clic en una frase del panel: se lee desde ahi, aunque estuviera en pausa.
    param([int]$Index)

    if ($Index -lt 0 -or $Index -ge $state.Chunks.Count) { return }

    $state.Finished = $false
    $state.IsPlaying = $true
    Set-PlayIcon -Playing $true

    # El margen minimo asegura que el salto caiga dentro de esa frase y no al
    # final de la anterior.
    Invoke-Seek -TargetSeconds ($state.Chunks[$Index].Offset + 0.01)
}

function Show-ChunkInPanel {
    # Desplaza el panel para que la frase actual quede a la vista. Solo se
    # mueve cuando la frase se sale de la franja comoda, asi el texto no da
    # un salto en cada frase y respeta si estas desplazandote a mano.
    param([int]$Index)

    # Mientras hay texto seleccionado no se mueve nada: estas copiando.
    if (-not $ui.TextView.Selection.IsEmpty) { return }

    try {
        $ui.TextView.UpdateLayout()

        $rect = $script:runs[$Index].Run.ContentStart.GetCharacterRect([Windows.Documents.LogicalDirection]::Forward)
        if ($rect.IsEmpty) { return }

        $vista = $ui.TextView.ViewportHeight
        $desplazado = $ui.TextView.VerticalOffset

        # El rectangulo llega relativo a lo que se ve, no al documento entero.
        if (($rect.Y -lt 4) -or ($rect.Y -gt ($vista * 0.65))) {
            $ui.TextView.ScrollToVerticalOffset([Math]::Max(0, $desplazado + $rect.Y - $vista * 0.25))
        }
    } catch { }
}

function Update-Highlight {
    # Lo ya leido se apaga, la frase actual se resalta y lo pendiente queda
    # en el color normal. Asi se ve de un vistazo por donde va la lectura.
    param([switch]$Force)

    if ($script:runs.Count -eq 0) { return }

    # Mientras se espera un fragmento al que se salto, el destacado es el destino.
    $actual = $state.PlayIndex
    if ($state.WaitTarget -ge 0) { $actual = $state.WaitTarget }
    if ((-not $Force) -and ($actual -eq $state.HighlightIndex)) { return }

    for ($i = 0; $i -lt $script:runs.Count; $i++) {
        $trozo = $script:runs[$i].Run

        if ($i -eq $actual) {
            $trozo.Foreground = $colores.Actual
            $trozo.Background = $colores.Fondo
        } elseif (($actual -ge 0) -and ($i -lt $actual)) {
            $trozo.Foreground = $colores.Leido
            $trozo.Background = $colores.Ninguno
        } else {
            $trozo.Foreground = $colores.Pendiente
            $trozo.Background = $colores.Ninguno
        }
    }

    $state.HighlightIndex = $actual

    if ($script:panelVisible -and ($actual -ge 0) -and ($actual -lt $script:runs.Count)) {
        Show-ChunkInPanel -Index $actual
    }
}

# Clic sin arrastrar: salto a la frase. Si al soltar hay seleccion, fue un
# arrastre para copiar y no se salta.
#
# Se busca la letra mas cercana al clic y se acepta si esta a la altura de esa
# linea. Exigir caer justo encima de una letra hacia que un clic en el
# interlineado, o entre dos palabras de una fila de tabla, no hiciera nada.
$ui.TextView.Add_PreviewMouseLeftButtonUp({
    param($sender, $e)

    if (-not $sender.Selection.IsEmpty) { return }

    $punto = $e.GetPosition($sender)
    $posicion = $sender.GetPositionFromPoint($punto, $true)
    if ($null -eq $posicion) { return }

    $rect = $posicion.GetCharacterRect([Windows.Documents.LogicalDirection]::Forward)
    if ($rect.IsEmpty -or $rect.Height -le 0) { return }

    $centro = $rect.Top + ($rect.Height / 2)
    if ([Math]::Abs($punto.Y - $centro) -gt $rect.Height) { return }

    # El punto puede caer en el espacio que separa dos frases, que no tiene
    # fragmento propio: se toma la frase de al lado.
    $trozo = $posicion.Parent
    foreach ($direccion in @('Forward', 'Backward')) {
        if (($trozo -is [Windows.Documents.Run]) -and ($null -ne $trozo.Tag)) { break }

        $vecina = $posicion.GetNextInsertionPosition([Windows.Documents.LogicalDirection]$direccion)
        if ($null -ne $vecina) { $trozo = $vecina.Parent }
    }

    if (($trozo -is [Windows.Documents.Run]) -and ($null -ne $trozo.Tag)) {
        Start-FromChunk -Index ([int]$trozo.Tag)
    }
})

function Set-TextPanel {
    param([bool]$Visible)

    if ($Visible) {
        $ui.TextPanel.Visibility = 'Visible'
        $ui.Bordes.Visibility = 'Visible'
        $ui.BtnText.Foreground = $colores.Encendido
        $ui.BtnText.ToolTip = 'Ocultar el texto'
    } else {
        $ui.TextPanel.Visibility = 'Collapsed'
        $ui.Bordes.Visibility = 'Collapsed'
        $ui.BtnText.Foreground = $colores.Apagado
        $ui.BtnText.ToolTip = 'Mostrar el texto que se esta leyendo'
    }

    $script:panelVisible = $Visible

    if ($window.IsVisible) {
        # La esquina inferior derecha queda fija: el panel crece hacia arriba
        # y la barra de controles no se mueve de donde estaba.
        $window.UpdateLayout()
        Set-PlayerPosition
    }

    Save-PlayerState

    if ($Visible) { Update-Highlight -Force }
}

if ($script:panelVisible) {
    $ui.TextPanel.Visibility = 'Visible'
    $ui.Bordes.Visibility = 'Visible'
    $ui.BtnText.Foreground = $colores.Encendido
    $ui.BtnText.ToolTip = 'Ocultar el texto'
}

# --------------------------------------------------------------------------
# Tamano: se cambia arrastrando los bordes de la ventana, como en cualquier
# aplicacion. Lo que crece es el panel de texto; la barra de controles tiene
# ancho fijo y la ventana se ajusta sola a los dos.
# --------------------------------------------------------------------------
$script:panelAlto = 0.0
$script:panelAncho = 0.0

if ($savedState) {
    $propiedades = $savedState.PSObject.Properties.Name
    if ($propiedades -contains 'PanelHeight') { $script:panelAlto = [double]$savedState.PanelHeight }
    if ($propiedades -contains 'PanelWidth') { $script:panelAncho = [double]$savedState.PanelWidth }
}

if ($script:panelAlto -gt 0) { $ui.TextPanel.Height = $script:panelAlto }
if ($script:panelAncho -gt 0) { $ui.TextPanel.Width = $script:panelAncho }

function Resize-TextPanel {
    # Cada valor es cuanto se movio ese lado: positivo hacia la derecha o
    # hacia abajo. Un borde mueve un solo lado; una esquina, dos.
    param(
        [double]$Izquierda = 0,
        [double]$Derecha = 0,
        [double]$Arriba = 0,
        [double]$Abajo = 0
    )

    $area = [Windows.SystemParameters]::WorkArea
    $anchoAntes = $ui.TextPanel.ActualWidth
    $altoAntes = $ui.TextPanel.ActualHeight

    # Las medidas del panel van sin la escala del reproductor; las de la
    # pantalla, con ella.
    $escala = $ui.Zoom.ScaleX
    $alto = $altoAntes - $Arriba + $Abajo
    $alto = [Math]::Max(80, [Math]::Min($alto, $area.Height * 0.8 / $escala))

    # Nunca mas estrecho que la barra de controles, que vive debajo.
    $ancho = $anchoAntes - $Izquierda + $Derecha
    $ancho = [Math]::Max($ui.Bar.ActualWidth, [Math]::Min($ancho, $area.Width * 0.9 / $escala))

    # La ventana se coloca por su esquina inferior derecha. Al mover el lado
    # izquierdo o el de arriba, esa esquina queda donde estaba; al mover el
    # derecho o el de abajo, se desplaza con el, sin salirse del escritorio:
    # fuera de el, Set-PlayerPosition la devolveria a la esquina de la pantalla.
    if (($Derecha -ne 0) -or ($Abajo -ne 0)) {
        if ($null -eq $script:ancla) {
            $script:ancla = @{
                Right  = $window.Left + $window.ActualWidth
                Bottom = $window.Top + $window.ActualHeight
            }
        }

        if ($Derecha -ne 0) {
            $limite = [Windows.SystemParameters]::VirtualScreenLeft + [Windows.SystemParameters]::VirtualScreenWidth
            $crece = [Math]::Min($ancho - $anchoAntes, ($limite - $script:ancla.Right) / $escala)
            $ancho = $anchoAntes + $crece
            $script:ancla.Right += $crece * $escala
        }

        if ($Abajo -ne 0) {
            $limite = [Windows.SystemParameters]::VirtualScreenTop + [Windows.SystemParameters]::VirtualScreenHeight
            $crece = [Math]::Min($alto - $altoAntes, ($limite - $script:ancla.Bottom) / $escala)
            $alto = $altoAntes + $crece
            $script:ancla.Bottom += $crece * $escala
        }
    }

    $ui.TextPanel.Height = $alto
    $ui.TextPanel.Width = $ancho
    $script:panelAlto = $alto
    $script:panelAncho = $ancho

    $window.UpdateLayout()
    Set-PlayerPosition
}

# El cambio que informa un borde se mide desde donde empezo a arrastrarse,
# pero como el borde se mueve con la ventana, cada aviso llega ya como el
# tramo recorrido desde el anterior.
$lados = @{
    BordeArriba            = @('Arriba')
    BordeAbajo             = @('Abajo')
    BordeIzquierda         = @('Izquierda')
    BordeDerecha           = @('Derecha')
    EsquinaArribaIzquierda = @('Arriba', 'Izquierda')
    EsquinaArribaDerecha   = @('Arriba', 'Derecha')
    EsquinaAbajoIzquierda  = @('Abajo', 'Izquierda')
    EsquinaAbajoDerecha    = @('Abajo', 'Derecha')
}

foreach ($nombre in $lados.Keys) {
    $borde = $window.FindName($nombre)
    $borde.Tag = $lados[$nombre]

    $borde.Add_DragDelta({
        param($sender, $e)
        $cambio = @{}
        foreach ($lado in $sender.Tag) {
            if (($lado -eq 'Arriba') -or ($lado -eq 'Abajo')) {
                $cambio[$lado] = $e.VerticalChange
            } else {
                $cambio[$lado] = $e.HorizontalChange
            }
        }
        Resize-TextPanel @cambio
    })

    $borde.Add_DragCompleted({
        Save-PlayerState
        Update-Highlight -Force
    })
}

function Start-Speaking {
    param(
        [string]$Text,
        [string]$Requested = 'Auto'
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return }

    # Doble pulsacion del atajo sobre el mismo texto: se ignora en vez de
    # reiniciar, para que no parezca que "sono dos veces".
    $sinceLast = (Get-Date) - $state.LastTextAt
    if (($Text -eq $state.LastText) -and ($sinceLast.TotalMilliseconds -lt 1500)) {
        return
    }

    $state.LastText = $Text
    $state.LastTextAt = Get-Date

    Stop-Playback -KeepWindow

    $sync.Generation = $sync.Generation + 1
    $generation = $sync.Generation
    $state.Generation = $generation
    $state.Finished = $false

    $plan = Build-SpeechPlan -Text $Text -Requested $Requested `
        -MinChunkChars $settings.MinChunkChars `
        -FirstChunkChars $settings.FirstChunkChars -MaxChunkChars $settings.MaxChunkChars `
        -Fallback $settings.FallbackLanguage -Pauses (Get-ConfiguredPauses) -Engine $engines['es'] -EngineEn $engines['en']

    $index = 0
    $pausas = 0.0

    foreach ($item in $plan.Chunks) {
        $wav = Join-Path $paths.TmpDir ('ra_{0}_{1:d4}.wav' -f $generation, $index)
        $pausa = [double]$item.PauseAfter
        $pausas += $pausa

        $state.Chunks.Add([pscustomobject]@{
            Index      = $index
            Lang       = $item.Lang
            Text       = $item.Text
            Wav        = $wav
            Duration   = (Get-EstimatedDuration -Text $item.Text) + $pausa
            PauseAfter = $pausa
            Display    = $item.Display
            Block      = $item.Block
            Kind       = $item.Kind
            Offset     = 0.0
            Ready      = $false
        })

        $sync.SynthJobs.Enqueue(@{
            Generation = $generation
            Index      = $index
            Lang       = $item.Lang
            Text       = $item.Text
            Wav        = $wav
        })

        $index++
    }
    [void]$sync.SynthSignal.Set()

    Update-Offsets
    Build-TextPanel
    $ui.LangBadge.Text = $plan.DocumentLang.ToUpperInvariant()
    # Poner la barra a 0 no es un salto del usuario: la bandera evita que
    # ValueChanged lo tome por uno.
    $state.SyncingSlider = $true
    $ui.Seek.Value = 0
    $state.SyncingSlider = $false
    $ui.TimeLabel.Text = '0:00 / ' + (Format-Time $state.Total)
    Set-PlayIcon -Playing $true
    $state.IsPlaying = $true

    if ($settings.ShowPlayer) {
        # Ajuste "Panel de texto al aparecer": como lo dejaste, o siempre
        # abierto o cerrado. Solo al aparecer, no si ya estaba a la vista.
        if (-not $window.IsVisible -or $script:ocultando) {
            switch ([string]$settings.PanelOnShow) {
                'abierto' { if (-not $script:panelVisible) { Set-TextPanel -Visible $true } }
                'cerrado' { if ($script:panelVisible) { Set-TextPanel -Visible $false } }
            }
        }
        Show-PlayerWindow
        # Se coloca al mostrar, no solo al arrancar: el alto depende de si el
        # panel esta abierto, y el monitor puede cambiar mientras el proceso
        # residente sigue vivo.
        $window.UpdateLayout()
        Set-PlayerPosition
    }

    Write-DaemonLog ("Lectura {0}: {1} fragmentos, {2:N1} s de pausas, idioma {3}" -f $generation, $state.Chunks.Count, $pausas, $plan.DocumentLang)
}

# --------------------------------------------------------------------------
# Eventos del reproductor.
# --------------------------------------------------------------------------
foreach ($instancia in $players) {
    $instancia.add_MediaOpened({
        param($sender, $e)

        # El que no esta sonando solo se esta precargando: no toca nada.
        if (-not [object]::ReferenceEquals($sender, (Get-ActivePlayer))) { return }

        if ($null -ne $state.PendingSeek) {
            $sender.Position = [timespan]::FromSeconds($state.PendingSeek)
            $state.PendingSeek = $null
        }

        if ($state.IsPlaying) {
            $sender.Play()
            Set-PlayIcon -Playing $true
        }

        # MediaPlayer vuelve a 1x con cada archivo nuevo; se reaplica despues
        # de Play porque antes no siempre surte efecto.
        $sender.SpeedRatio = $script:speed
        $sender.Volume = $script:volume

        Open-NextChunk
    })

    $instancia.add_MediaEnded({
        param($sender, $e)

        if (-not [object]::ReferenceEquals($sender, (Get-ActivePlayer))) { return }

        $next = $state.PlayIndex + 1

        if ($next -ge $state.Chunks.Count) {
            $state.Finished = $true
            $state.IsPlaying = $false
            Set-PlayIcon -Playing $false

            if ($settings.PlayerAutoClose) {
                Stop-Playback
            }
            return
        }

        if ($state.PreloadIndex -eq $next) {
            # Relevo inmediato: el siguiente ya esta abierto en el otro.
            Switch-ToPreloaded -Offset 0
            return
        }

        if ($state.Chunks[$next].Ready) {
            Start-Chunk -Index $next -Offset 0 -AutoPlay $true
        } else {
            # El siguiente fragmento aun se esta generando. El pulso lo arranca
            # en cuanto llegue; sin esta bandera la lectura se quedaba muda.
            $state.WaitingForNext = $true
        }
    })
}

# --------------------------------------------------------------------------
# Controles.
# --------------------------------------------------------------------------
function Toggle-Playback {
    if ($state.Chunks.Count -eq 0) { return }

    if ($state.IsPlaying) {
        (Get-ActivePlayer).Pause()
        $state.IsPlaying = $false
        Set-PlayIcon -Playing $false
        return
    }

    # Se salto a un fragmento sin audio y se estaba en pausa: al reanudar se
    # sigue esperando a ese fragmento (o suena, si ya llego), no el sonido
    # viejo que quedo abierto.
    if ($state.WaitTarget -ge 0) {
        $state.IsPlaying = $true
        $destino = $state.WaitTarget
        if ($state.Chunks[$destino].Ready) { Start-Chunk -Index $destino -Offset 0 -AutoPlay $true }
        Set-PlayIcon -Playing $true
        return
    }

    # Si ya termino, el boton vuelve a leer desde el principio.
    if ($state.Finished) {
        $state.Finished = $false
        $state.IsPlaying = $true
        Invoke-Seek -TargetSeconds 0
    } elseif ($state.PlayIndex -lt 0) {
        $state.IsPlaying = $true
        Invoke-Seek -TargetSeconds 0
    } else {
        $state.IsPlaying = $true
        (Get-ActivePlayer).Play()
    }

    Set-PlayIcon -Playing $true
}

$ui.BtnPlay.Add_Click({ Toggle-Playback })

$ui.BtnBack.Add_Click({
    Invoke-Seek -TargetSeconds ((Get-GlobalPosition) - $settings.SkipSeconds)
})

$ui.BtnFwd.Add_Click({
    Invoke-Seek -TargetSeconds ((Get-GlobalPosition) + $settings.SkipSeconds)
})

$ui.BtnSpeed.Add_Click({
    if (([datetime]::Now - $script:speedPopupCerrada).TotalMilliseconds -lt 300) { return }
    $ui.SpeedPopup.IsOpen = -not $ui.SpeedPopup.IsOpen
})
$ui.BtnSpeed.Add_MouseWheel({
    param($sender, $e)
    if ($e.Delta -gt 0) { Set-PlaybackSpeed -Direction 1 } else { Set-PlaybackSpeed -Direction -1 }
    $e.Handled = $true
})
Set-PlaybackSpeedValue $script:speed

$ui.BtnVolume.Add_Click({
    if (([datetime]::Now - $script:volumePopupCerrada).TotalMilliseconds -lt 300) { return }
    $ui.VolumePopup.IsOpen = -not $ui.VolumePopup.IsOpen
})
$ui.BtnVolume.Add_MouseWheel({
    param($sender, $e)
    if ($e.Delta -gt 0) { Set-PlaybackVolume -Direction 1 } else { Set-PlaybackVolume -Direction -1 }
    $e.Handled = $true
})
Set-PlaybackVolumeValue $script:volume

$ui.BtnText.Add_Click({ Set-TextPanel -Visible (-not $script:panelVisible) })

$ui.BtnClose.Add_Click({
    Stop-Playback
})

# El salto se decide por el valor de la barra y no por el evento del raton.
# Con el raton, un clic sobre la linea movia el control pero no llegaba a
# producir el salto; asi funcionan igual el clic, el arrastre y las flechas
# del teclado.
function Complete-SliderSeek {
    # Al soltar el raton se salta a donde quedo el control. Se lee su valor
    # actual, que es el autoritativo, y no el ultimo anotado: si el arrastre
    # termino entre dos avisos de cambio, el valor sigue siendo el bueno.
    $huboCambio = ($null -ne $state.PendingSlider)

    $state.IsSeeking = $false
    $state.PendingSlider = $null

    if ($huboCambio -and $state.Total -gt 0) {
        Invoke-Seek -TargetSeconds (($ui.Seek.Value / 100.0) * $state.Total)
    }
}

$ui.Seek.Add_ValueChanged({
    # Cambio hecho por el reloj de la propia reproduccion, no por el usuario.
    if ($state.SyncingSlider) { return }
    if ($state.Total -le 0) { return }

    $destino = ($ui.Seek.Value / 100.0) * $state.Total

    if ($state.IsSeeking) {
        # Con el raton encima solo se toma nota. El salto se aplica al soltar,
        # porque hacerlo en cada movimiento del arrastre obligaria a reabrir el
        # audio decenas de veces.
        $state.PendingSlider = $destino
        return
    }

    Invoke-Seek -TargetSeconds $destino
})

# La marca se pone desde el borde de la ventana, no desde la barra: WPF mueve
# el control y cambia el valor en su propio manejador, que corre antes que los
# de esta ventana. Puesta aqui, el cambio del valor ya se sabe hecho a raton y
# el salto se aplica solo al soltar, tanto si fue un clic como un arrastre.
$ui.Root.Add_PreviewMouseDown({
    param($sender, $e)

    $nodo = $e.OriginalSource

    while ($null -ne $nodo) {
        if ($nodo -is [Windows.Controls.Slider]) {
            $state.IsSeeking = $true
            return
        }

        if ($nodo -is [Windows.Media.Visual]) {
            $nodo = [Windows.Media.VisualTreeHelper]::GetParent($nodo)
        } else {
            $nodo = $null
        }
    }
})

$ui.Seek.Add_PreviewMouseUp({ Complete-SliderSeek })

# Si otro control se queda con el raton, el arrastre termina igual.
$ui.Seek.Add_LostMouseCapture({ Complete-SliderSeek })

function Move-PlayerWindow {
    param($e)

    # Doble clic: vuelve a la esquina inferior derecha.
    if ($e.ClickCount -eq 2) {
        $script:ancla = $null
        Set-PlayerPosition
        Save-PlayerState
        return
    }

    try { $window.DragMove() } catch { }

    # Donde la dejaste pasa a ser su esquina de referencia.
    $script:ancla = @{
        Right  = $window.Left + $window.ActualWidth
        Bottom = $window.Top + $window.ActualHeight
    }
    Save-PlayerState
}

# La ventana se arrastra desde la pestana de arriba y desde cualquier parte de
# la barra que no sea un control.
#
# El clic sobre la linea de la barra no lo marca nadie como atendido, asi que
# llegaba hasta aqui y arrancaba el arrastre de la ventana. DragMove se queda
# con el raton, y el salto de posicion nunca se completaba: se oia seguir en
# el mismo sitio. Por eso se ignoran los clics nacidos dentro de un control.
$ui.Root.Add_MouseLeftButtonDown({
    param($sender, $e)

    $nodo = $e.OriginalSource

    while ($null -ne $nodo) {
        if (($nodo -is [Windows.Controls.Primitives.ButtonBase]) -or
            ($nodo -is [Windows.Controls.Slider]) -or
            ($nodo -is [Windows.Controls.ScrollViewer]) -or
            ($nodo -is [Windows.Controls.Primitives.TextBoxBase]) -or
            ($nodo -is [Windows.Controls.Primitives.Thumb]) -or
            ($nodo -is [Windows.Documents.TextElement])) {
            return
        }

        if ($nodo -is [Windows.Media.Visual]) {
            $nodo = [Windows.Media.VisualTreeHelper]::GetParent($nodo)
        } else {
            $nodo = $null
        }
    }

    Move-PlayerWindow $e
})

# La pestana de arriba solo sirve para eso.
$ui.Asa.Add_MouseLeftButtonDown({
    param($sender, $e)
    Move-PlayerWindow $e
})

# El panel de ajustes, el boton de la tuerca.
. (Join-Path $PSScriptRoot 'lib\ReadAloud.Settings.ps1')

# La X oculta, no destruye: la ventana se reutiliza en la siguiente lectura.
$window.Add_Closing({
    param($sender, $e)
    $e.Cancel = $true
    Stop-Playback
})

# --------------------------------------------------------------------------
# Pulso: 60 ms. Atiende ordenes, recoge audio generado y refresca la barra.
# Sin nada que leer ni mostrar baja a 250 ms, para no despertar el procesador
# 16 veces por segundo en vano; la tuberia lo vuelve a 60 ms en cuanto llega
# una orden, asi que la lectura no espera ese cuarto de segundo.
# --------------------------------------------------------------------------
$pulseBusy = [timespan]::FromMilliseconds(60)
$pulseIdle = [timespan]::FromMilliseconds(250)
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = $pulseBusy
$sync.WakeUi = [Action]{ if ($timer.Interval -ne $pulseBusy) { $timer.Interval = $pulseBusy } }
$sync.Dispatcher = [Windows.Threading.Dispatcher]::CurrentDispatcher

$timer.Add_Tick({
    # 1. Ordenes que llegaron por la tuberia.
    $line = $null
    while ($sync.Requests.TryDequeue([ref]$line)) {
        try {
            $request = $line | ConvertFrom-Json
        } catch {
            continue
        }

        switch ($request.cmd) {
            'speak' {
                $requested = 'Auto'
                if ($request.PSObject.Properties.Name -contains 'lang' -and $request.lang) {
                    $requested = $request.lang
                }
                Start-Speaking -Text $request.text -Requested $requested
            }
            'stop'   { Stop-Playback }
            'toggle' { Toggle-Playback }
            'back'   { Invoke-Seek -TargetSeconds ((Get-GlobalPosition) - $settings.SkipSeconds) }
            'forward'{ Invoke-Seek -TargetSeconds ((Get-GlobalPosition) + $settings.SkipSeconds) }
            'prev'   { Invoke-SentenceStep -Direction -1 }
            'next'   { Invoke-SentenceStep -Direction 1 }
            'faster' { Set-PlaybackSpeed -Direction 1 }
            'louder' { Set-PlaybackVolume -Direction 1 }
            'quieter'{ Set-PlaybackVolume -Direction -1 }
            'panel'  { Set-TextPanel -Visible (-not $script:panelVisible) }
            'slower' { Set-PlaybackSpeed -Direction -1 }
            'quit'   {
                Stop-Playback
                $sync.Stopping = $true
                $timer.Stop()
                [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
                return
            }
        }
    }

    # 2. Fragmentos recien sintetizados.
    $done = $null
    $changed = $false

    while ($sync.SynthDone.TryDequeue([ref]$done)) {
        if ($done.Generation -ne $state.Generation) {
            if ($done.Wav -and (Test-Path -LiteralPath $done.Wav)) {
                Remove-Item -LiteralPath $done.Wav -Force -ErrorAction SilentlyContinue
            }
            continue
        }

        # Los fragmentos de calentamiento usan indices negativos.
        if ($done.Index -lt 0) {
            if ($done.Wav -and (Test-Path -LiteralPath $done.Wav)) {
                Remove-Item -LiteralPath $done.Wav -Force -ErrorAction SilentlyContinue
            }
            continue
        }

        if ($done.Index -ge $state.Chunks.Count) { continue }

        $chunk = $state.Chunks[$done.Index]

        if (-not $done.Ok) {
            Write-DaemonLog ("Fallo el fragmento {0}: {1}" -f $done.Index, $done.Error)
            $chunk.Duration = 0.0
            $chunk.Ready = $true
            $changed = $true
            continue
        }

        # El silencio del final del bloque se pega al propio audio, para no
        # pagar el arranque de un archivo mas en cada pausa.
        if ($chunk.PauseAfter -gt 0) {
            [void](Add-WavSilence -Path $done.Wav -Seconds $chunk.PauseAfter)
        }

        $chunk.Duration = Get-WavDuration -Path $done.Wav
        $chunk.Ready = $true
        $changed = $true
    }

    # Con audio real, el ritmo de esta voz se mide y lo que falta se estima con
    # el: la barra de posicion no se mueve a saltos cuando llega cada fragmento.
    if ($changed) {
        [void](Update-ChunkEstimates -Chunks $state.Chunks)
        Update-Offsets
    }

    # 3. Arranque del audio y salto al siguiente fragmento cuando ya esta listo.
    if ($state.Chunks.Count -gt 0 -and -not $state.Finished) {
        if ($state.PlayIndex -lt 0 -and $state.Chunks[0].Ready -and $state.IsPlaying) {
            Start-Chunk -Index 0 -Offset 0 -AutoPlay $true
            Open-NextChunk
        } elseif ($state.WaitingForNext -and $state.IsPlaying) {
            $next = $state.PlayIndex + 1
            if ($next -lt $state.Chunks.Count -and $state.Chunks[$next].Ready) {
                $state.WaitingForNext = $false
                Start-Chunk -Index $next -Offset 0 -AutoPlay $true
            }
        } else {
            # El fragmento siguiente puede haberse generado despues de empezar
            # a sonar el actual; aqui se precarga en cuanto esta.
            Open-NextChunk
        }
    }

    # 4. Barra de progreso, reloj y frase resaltada.
    if ($window.IsVisible -and $state.Chunks.Count -gt 0) {
        Update-Highlight

        $position = Get-GlobalPosition

        if (-not $state.IsSeeking -and $state.Total -gt 0) {
            # La bandera evita que este refresco se confunda con un cambio
            # hecho por el usuario y dispare un salto en cada pulso.
            $state.SyncingSlider = $true
            $ui.Seek.Value = [Math]::Min(100, ($position / $state.Total) * 100)
            $state.SyncingSlider = $false
        }

        $ui.TimeLabel.Text = '{0} / {1}' -f (Format-Time $position), (Format-Time $state.Total)

        $readyDuration = 0.0
        foreach ($chunk in $state.Chunks) {
            if (-not $chunk.Ready) { break }
            $readyDuration += $chunk.Duration
        }

        if ($state.Total -gt 0) {
            $ui.BufferBar.Width = 170.0 * [Math]::Min(1.0, $readyDuration / $state.Total)
        }
    }

    # 5. Ritmo del pulso.
    $idle = (-not $window.IsVisible) -and (-not $state.IsPlaying) -and
            $sync.Requests.IsEmpty -and $sync.SynthDone.IsEmpty
    $pulse = $pulseBusy
    if ($idle) { $pulse = $pulseIdle }
    if ($timer.Interval -ne $pulse) { $timer.Interval = $pulse }
})

# --------------------------------------------------------------------------
# Atajos de teclado globales (sin AutoHotkey) e icono en la bandeja.
#
# Los atajos se registran en la ventana del reproductor con RegisterHotKey;
# Windows los avisa con WM_HOTKEY aunque la ventana este oculta. Cada uno se
# encola y se atiende en el hilo de la interfaz, igual que una orden que llega
# por la tuberia. El icono de la bandeja es la forma de ver que Read Aloud
# esta activo y de cerrarlo del todo ("Salir").
# --------------------------------------------------------------------------
# Un error en cualquier manejador de la interfaz cerraba el proceso sin dejar
# rastro: ahora se registra y el proceso sigue vivo.
$window.Dispatcher.add_UnhandledException({
    param($sender, $e)
    Write-DaemonLog ('Error no controlado: {0}' -f $e.Exception.ToString())
    $e.Handled = $true
})

$script:hotkeyQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$script:hotkeyReport = @()
$hotkeyHandle = (New-Object Windows.Interop.WindowInteropHelper($window)).EnsureHandle()

$script:hotkeyDrain = {
    # Una excepcion aqui cortaria el bucle de la interfaz y cerraria el proceso:
    # se registra y se sigue.
    try {
        $nombre = $null
        while ($script:hotkeyQueue.TryDequeue([ref]$nombre)) {
            if ($nombre -eq 'read') {
                $texto = Get-SelectedText
                if (-not [string]::IsNullOrWhiteSpace($texto)) {
                    $sync.Requests.Enqueue((@{ cmd = 'speak'; lang = 'Auto'; text = $texto } | ConvertTo-Json -Compress))
                } else {
                    Write-DaemonLog 'Atajo de leer: no habia texto seleccionado.'
                }
            } else {
                $sync.Requests.Enqueue((@{ cmd = $nombre } | ConvertTo-Json -Compress))
            }
        }
        $sync.WakeUi.Invoke()
    } catch {
        Write-DaemonLog ('Error en un atajo: {0}' -f $_.Exception.Message)
    }
}

$script:hotkeyHook = [Windows.Interop.HwndSourceHook]{
    # $handled llega por valor desde PowerShell y no se puede marcar; no hace
    # falta, WM_HOTKEY puede seguir a la ventana sin efecto.
    param($hwnd, $msg, $wParam, $lParam, $handled)
    if ($msg -eq 0x0312) {
        $id = $wParam.ToInt32()
        foreach ($e in $script:hotkeyReport) {
            if ($e.Active -and $e.Id -eq $id) {
                $script:hotkeyQueue.Enqueue($e.Action)
                [void]$window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Normal, [Action]$script:hotkeyDrain)
                break
            }
        }
    }
    return [IntPtr]::Zero
}
[Windows.Interop.HwndSource]::FromHwnd($hotkeyHandle).AddHook($script:hotkeyHook)

$script:hotkeyReport = Register-ReadAloudHotkeys -Handle $hotkeyHandle -Hotkeys (Get-ConfiguredHotkeys $settings)
$hotkeyFailed = @($script:hotkeyReport | Where-Object { -not $_.Active -and $_.Reason -ne 'disabled' })
foreach ($e in $script:hotkeyReport) {
    if ($e.Active) { Write-DaemonLog ('Atajo {0}: {1}' -f $e.Action, $e.Text) }
    elseif ($e.Reason -ne 'disabled') { Write-DaemonLog ('Atajo {0} ({1}) no disponible: {2}' -f $e.Action, $e.Text, $e.Reason) }
}

# Icono: un circulo con el simbolo de volumen, dibujado aqui para no llevar un
# archivo binario en el repositorio.
function Set-AppTheme {
    # Aplica el tema (ajustes Theme y Accent) al momento: los recursos de las
    # dos ventanas, los colores que se ponen por codigo y el icono de la bandeja.
    $script:paleta = Get-ThemePalette -Mode (Resolve-ThemeMode -Mode ([string]$settings.Theme) -SystemLight (Test-SystemLightTheme)) -Accent ([string]$settings.Accent)
    Set-ThemeResources -Resources $window.Resources -Palette $script:paleta
    if ($ajustesVentana) { Set-ThemeResources -Resources $ajustesVentana.Resources -Palette $script:paleta }

    $nuevo = Get-RuntimeColors $script:paleta
    foreach ($nombre in @('Pendiente', 'Leido', 'Actual', 'Fondo', 'Encendido', 'Apagado', 'Texto', 'Elegido')) {
        $colores[$nombre] = New-Brush $nuevo[$nombre]
    }
    if ($script:panelVisible) { $ui.BtnText.Foreground = $colores.Encendido } else { $ui.BtnText.Foreground = $colores.Apagado }
    Update-Highlight -Force

    if ($script:tray) {
        $anterior = $script:tray.Icon
        $script:tray.Icon = New-TrayIcon
        if ($anterior) { $anterior.Dispose() }
    }
}

function New-TrayIcon {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAlias'
    $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml($script:paleta.AccentBase))), 1, 1, 30, 30)
    $font = New-Object Drawing.Font('Segoe MDL2 Assets', 15)
    $format = New-Object Drawing.StringFormat
    $format.Alignment = 'Center'
    $format.LineAlignment = 'Center'
    $g.DrawString([string][char]0xE767, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, 1, 32, 32)), $format)
    $g.Dispose()
    return [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$readKey = ($script:hotkeyReport | Where-Object { $_.Action -eq 'read' -and $_.Active } | Select-Object -First 1).Text
$script:tray = New-Object Windows.Forms.NotifyIcon
$script:tray.Icon = New-TrayIcon
$script:tray.Text = $(if ($readKey) { 'Read Aloud - {0} para leer' -f $readKey } else { 'Read Aloud' })
$trayMenu = New-Object Windows.Forms.ContextMenuStrip
$itemAjustes = $trayMenu.Items.Add('Ajustes')
$itemAjustes.Add_Click({ Show-SettingsWindow })
[void]$trayMenu.Items.Add('-')
$itemSalir = $trayMenu.Items.Add('Salir de Read Aloud')
$itemSalir.Add_Click({
    $sync.Requests.Enqueue('{"cmd":"quit"}')
    $sync.WakeUi.Invoke()
})
$script:tray.ContextMenuStrip = $trayMenu
$script:tray.Add_DoubleClick({ Show-SettingsWindow })
$script:tray.Visible = $true

if ($hotkeyFailed.Count -gt 0) {
    $lista = ($hotkeyFailed | ForEach-Object { $_.Text }) -join ', '
    $script:tray.ShowBalloonTip(8000, 'Read Aloud', ('Estos atajos no se pudieron activar porque otro programa los usa: {0}. Cambialos en los ajustes.' -f $lista), [Windows.Forms.ToolTipIcon]::Warning)
}

$timer.Start()

# --------------------------------------------------------------------------
# Calentamiento: obliga a cargar los modelos ahora, para que la primera lectura
# real no pague la espera.
# --------------------------------------------------------------------------
function Start-Warmup {
    $warmIndex = 0
    foreach ($lang in @($models.Keys)) {
        # En ahorro, Qwen espera a la primera lectura: calentarlo aqui seria
        # cargarlo igual.
        if ($script:ahorro -and $engines[$lang] -eq 'qwen') { continue }
        $sync.SynthJobs.Enqueue(@{
            Generation = $sync.Generation
            Index      = -1 - $warmIndex
            Lang       = $lang
            Text       = 'Listo.'
            Wav        = (Join-Path $paths.TmpDir ('warmup_{0}.wav' -f $lang))
        })
        $warmIndex++
    }
    [void]$sync.SynthSignal.Set()
}

if (-not $NoWarmup) { Start-Warmup }

Write-DaemonLog 'Proceso residente listo.'

try {
    [Windows.Threading.Dispatcher]::Run()
} finally {
    $sync.Stopping = $true
    [void]$sync.SynthSignal.Set()

    Save-PlayerState

    try { Unregister-ReadAloudHotkeys -Handle $hotkeyHandle -Report $script:hotkeyReport } catch { }
    try { $script:tray.Visible = $false; $script:tray.Dispose() } catch { }

    foreach ($entry in $runspaces) {
        try { $entry.PowerShell.Dispose() } catch { }
        try { $entry.Runspace.Dispose() } catch { }
    }

    Get-Process -Name 'piper' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Write-DaemonLog 'Proceso residente detenido.'
}
