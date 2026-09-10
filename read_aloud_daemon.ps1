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
    [switch]$NoWarmup
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\ReadAloud.Core.ps1')
. (Join-Path $PSScriptRoot 'lib\ReadAloud.Text.ps1')

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$paths = Get-ReadAloudPaths
$settings = Get-ReadAloudSettings -Paths $paths

# --------------------------------------------------------------------------
# Una sola instancia. Sin esto, dos daemons pelean por la tuberia y el audio
# se escucha duplicado, que es justo el sintoma que se quiere eliminar.
# --------------------------------------------------------------------------
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

$purged = Clear-OldTempAudio -TmpDir $paths.TmpDir -MaxAgeHours $settings.MaxTmpAgeHours
Write-DaemonLog "Inicio. Temporales eliminados: $purged"

Set-SpeechTerms (Import-SpeechTerms -Path $paths.TermsFile)

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

# --------------------------------------------------------------------------
# Estado compartido entre hilos.
# Generation identifica la lectura actual: cuando llega una orden nueva, sube
# el contador y todo el audio de la lectura anterior se descarta al vuelo.
# --------------------------------------------------------------------------
$sync = [hashtable]::Synchronized(@{})
$sync.Requests  = New-Object 'Collections.Concurrent.ConcurrentQueue[string]'
$sync.SynthJobs = New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
$sync.SynthDone = New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
$sync.Generation = 0
$sync.Stopping = $false

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
            $server = New-Object IO.Pipes.NamedPipeServerStream(
                $pipeName, [IO.Pipes.PipeDirection]::InOut, 1,
                [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::None, 4096, 4096)

            $server.WaitForConnection()

            $encoding = New-Object Text.UTF8Encoding($false)
            $reader = New-Object IO.StreamReader($server, $encoding)
            $writer = New-Object IO.StreamWriter($server, $encoding)
            $writer.AutoFlush = $true

            $line = $reader.ReadLine()
            if ($line) {
                $sync.Requests.Enqueue($line)
                $writer.WriteLine('ok')
            } else {
                $writer.WriteLine('empty')
            }

            $server.WaitForPipeDrain()
        } catch {
            Start-Sleep -Milliseconds 50
        } finally {
            if ($server) { $server.Dispose() }
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
# --------------------------------------------------------------------------
$synthScript = {
    $processes = @{}

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

    function Get-PiperProcess {
        param([string]$Lang)

        if ($processes.ContainsKey($Lang)) {
            $existing = $processes[$Lang]
            if (-not $existing.Process.HasExited) { return $existing }
            $processes.Remove($Lang)
        }

        $created = New-PiperProcess -Lang $Lang
        $processes[$Lang] = $created
        return $created
    }

    while (-not $sync.Stopping) {
        $job = $null

        if (-not $sync.SynthJobs.TryDequeue([ref]$job)) {
            Start-Sleep -Milliseconds 15
            continue
        }

        # Fragmento de una lectura que ya fue reemplazada: no vale la pena.
        if ($job.Generation -ne $sync.Generation) { continue }

        try {
            $piper = Get-PiperProcess -Lang $job.Lang

            $payload = @{ text = $job.Text; output_file = $job.Wav } | ConvertTo-Json -Compress
            $piper.Writer.WriteLine($payload)

            # Piper imprime la ruta del WAV cuando termina el fragmento.
            $produced = $piper.Process.StandardOutput.ReadLine()

            if ([string]::IsNullOrWhiteSpace($produced)) {
                throw 'Piper cerro la salida sin generar audio.'
            }

            $sync.SynthDone.Enqueue(@{
                Generation = $job.Generation
                Index      = $job.Index
                Wav        = $job.Wav
                Ok         = $true
                Error      = ''
            })
        } catch {
            if ($processes.ContainsKey($job.Lang)) { $processes.Remove($job.Lang) }

            $sync.SynthDone.Enqueue(@{
                Generation = $job.Generation
                Index      = $job.Index
                Wav        = $job.Wav
                Ok         = $false
                Error      = $_.Exception.Message
            })
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

Start-BackgroundRunspace -Script $synthScript -Variables @{
    sync = $sync
    cfg = @{
        PiperExe        = $paths.PiperExe
        PiperDir        = $paths.PiperDir
        EspeakData      = $paths.EspeakData
        Models          = $models
        SentenceSilence = ([double]$settings.SentenceSilence).ToString($invariant)
        LengthScale     = ([double]$settings.LengthScale).ToString($invariant)
        NoiseScale      = ([double]$settings.NoiseScale).ToString($invariant)
        NoiseW          = ([double]$settings.NoiseW).ToString($invariant)
    }
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
  <Border x:Name="Root" CornerRadius="10" Background="#F21B1B1F" BorderBrush="#33FFFFFF"
          BorderThickness="1" Padding="10,7">
    <Border.Effect>
      <DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.45" Color="#000000"/>
    </Border.Effect>
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
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
      <Grid Width="170" Height="26" Margin="8,0,8,0" VerticalAlignment="Center">
        <Border Height="4" CornerRadius="2" Background="#3AFFFFFF" VerticalAlignment="Center"/>
        <Border x:Name="BufferBar" Height="4" CornerRadius="2" Background="#55FFFFFF"
                HorizontalAlignment="Left" VerticalAlignment="Center" Width="0"/>
        <Slider x:Name="Seek" Minimum="0" Maximum="100" Value="0" VerticalAlignment="Center"
                Background="Transparent" IsMoveToPointEnabled="True"/>
      </Grid>
      <TextBlock x:Name="TimeLabel" Text="0:00 / 0:00" Foreground="#D8D8DC" FontFamily="Segoe UI"
                 FontSize="11" VerticalAlignment="Center" Width="86" TextAlignment="Right"/>
      <Button x:Name="BtnClose" Content="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="12"
              Width="26" Height="26" Foreground="#C8C8CC" Background="Transparent"
              BorderThickness="0" Cursor="Hand" Margin="6,0,0,0" ToolTip="Cerrar"/>
    </StackPanel>
  </Border>
</Window>
'@

$reader = New-Object IO.StringReader($xaml)
$xmlReader = [Xml.XmlReader]::Create($reader)
$window = [Windows.Markup.XamlReader]::Load($xmlReader)

$ui = @{}
foreach ($name in @('Root','LangBadge','BtnBack','BtnPlay','BtnFwd','BufferBar','Seek','TimeLabel','BtnClose')) {
    $ui[$name] = $window.FindName($name)
}

$window.Opacity = [double]$settings.PlayerOpacity

# Posicion recordada entre sesiones; si no hay, abajo a la derecha.
$screen = [Windows.SystemParameters]::WorkArea
$window.Left = $screen.Right - 480
$window.Top = $screen.Bottom - 70

if (Test-Path -LiteralPath $paths.StateFile) {
    try {
        $savedState = Get-Content -LiteralPath $paths.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($savedState.Left -ge $screen.Left -and $savedState.Top -ge $screen.Top) {
            $window.Left = $savedState.Left
            $window.Top = $savedState.Top
        }
    } catch { }
}

$player = New-Object Windows.Media.MediaPlayer

# --------------------------------------------------------------------------
# Estado de la lectura en curso.
# --------------------------------------------------------------------------
$state = [pscustomobject]@{
    Generation    = 0
    Chunks        = New-Object System.Collections.Generic.List[object]
    PlayIndex     = -1
    IsPlaying     = $false
    IsSeeking     = $false
    PendingSeek   = $null
    Total         = 0.0
    LastText      = ''
    LastTextAt    = [datetime]::MinValue
    Finished      = $true
    WaitingForNext = $false
}

function Format-Time {
    param([double]$Seconds)

    if ($Seconds -lt 0) { $Seconds = 0 }
    $span = [timespan]::FromSeconds($Seconds)
    return ('{0}:{1:00}' -f [int]$span.TotalMinutes, $span.Seconds)
}

function Get-EstimatedDuration {
    # Estimacion mientras el fragmento aun no se genera. 14 caracteres por
    # segundo se acerca al ritmo real de estas voces; se corrige apenas llega
    # el WAV con su duracion exacta.
    param([string]$Text)
    return [Math]::Max(0.6, $Text.Length / 14.0)
}

function Update-Offsets {
    $offset = 0.0
    foreach ($chunk in $state.Chunks) {
        $chunk.Offset = $offset
        $offset += $chunk.Duration
    }
    $state.Total = $offset
}

function Get-GlobalPosition {
    if ($state.PlayIndex -lt 0 -or $state.PlayIndex -ge $state.Chunks.Count) { return 0.0 }
    return $state.Chunks[$state.PlayIndex].Offset + $player.Position.TotalSeconds
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

function Stop-Playback {
    param([switch]$KeepWindow)

    $player.Stop()
    try { $player.Close() } catch { }

    $state.IsPlaying = $false
    $state.Finished = $true
    $state.WaitingForNext = $false
    $state.PlayIndex = -1
    Set-PlayIcon -Playing $false

    foreach ($chunk in $state.Chunks) {
        if ($chunk.Wav -and (Test-Path -LiteralPath $chunk.Wav)) {
            Remove-Item -LiteralPath $chunk.Wav -Force -ErrorAction SilentlyContinue
        }
    }

    $state.Chunks.Clear()
    $state.Total = 0.0

    if (-not $KeepWindow) { $window.Hide() }
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
    $state.PendingSeek = $Offset
    $state.IsPlaying = $AutoPlay

    $ui.LangBadge.Text = $chunk.Lang.ToUpperInvariant()
    $player.Open([uri]$chunk.Wav)
}

function Invoke-Seek {
    param([double]$TargetSeconds)

    if ($state.Chunks.Count -eq 0) { return }

    # No se puede saltar a audio que todavia no existe: se limita al final de
    # lo ya generado.
    $lastReady = -1
    for ($i = 0; $i -lt $state.Chunks.Count; $i++) {
        if ($state.Chunks[$i].Ready) { $lastReady = $i } else { break }
    }
    if ($lastReady -lt 0) { return }

    $maxSeekable = $state.Chunks[$lastReady].Offset + $state.Chunks[$lastReady].Duration - 0.15
    if ($TargetSeconds -gt $maxSeekable) { $TargetSeconds = $maxSeekable }
    if ($TargetSeconds -lt 0) { $TargetSeconds = 0 }

    for ($i = $lastReady; $i -ge 0; $i--) {
        $chunk = $state.Chunks[$i]
        if ($TargetSeconds -ge $chunk.Offset) {
            Start-Chunk -Index $i -Offset ($TargetSeconds - $chunk.Offset) -AutoPlay $state.IsPlaying
            return
        }
    }

    Start-Chunk -Index 0 -Offset 0 -AutoPlay $state.IsPlaying
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
        -TargetChars $settings.ChunkTargetChars -FirstChunkChars $settings.FirstChunkChars `
        -Fallback $settings.FallbackLanguage

    $index = 0
    foreach ($item in $plan.Chunks) {
        $wav = Join-Path $paths.TmpDir ('ra_{0}_{1:d4}.wav' -f $generation, $index)

        $state.Chunks.Add([pscustomobject]@{
            Index    = $index
            Lang     = $item.Lang
            Text     = $item.Text
            Wav      = $wav
            Duration = (Get-EstimatedDuration -Text $item.Text)
            Offset   = 0.0
            Ready    = $false
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

    Update-Offsets
    $ui.LangBadge.Text = $plan.DocumentLang.ToUpperInvariant()
    $ui.Seek.Value = 0
    $ui.TimeLabel.Text = '0:00 / ' + (Format-Time $state.Total)
    Set-PlayIcon -Playing $true
    $state.IsPlaying = $true

    if ($settings.ShowPlayer) { $window.Show() }

    Write-DaemonLog ("Lectura {0}: {1} fragmentos, idioma {2}" -f $generation, $state.Chunks.Count, $plan.DocumentLang)
}

# --------------------------------------------------------------------------
# Eventos del reproductor.
# --------------------------------------------------------------------------
$player.add_MediaOpened({
    if ($null -ne $state.PendingSeek) {
        $player.Position = [timespan]::FromSeconds($state.PendingSeek)
        $state.PendingSeek = $null
    }

    if ($state.IsPlaying) {
        $player.Play()
        Set-PlayIcon -Playing $true
    }
})

$player.add_MediaEnded({
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

    if ($state.Chunks[$next].Ready) {
        Start-Chunk -Index $next -Offset 0 -AutoPlay $true
    } else {
        # El siguiente fragmento aun se esta generando. El pulso lo arranca en
        # cuanto llegue; sin esta bandera la lectura se quedaba muda ahi.
        $state.WaitingForNext = $true
    }
})

# --------------------------------------------------------------------------
# Controles.
# --------------------------------------------------------------------------
function Toggle-Playback {
    if ($state.Chunks.Count -eq 0) { return }

    if ($state.IsPlaying) {
        $player.Pause()
        $state.IsPlaying = $false
        Set-PlayIcon -Playing $false
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
        $player.Play()
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

$ui.BtnClose.Add_Click({
    Stop-Playback
})

$ui.Seek.Add_PreviewMouseDown({ $state.IsSeeking = $true })

$ui.Seek.Add_PreviewMouseUp({
    $state.IsSeeking = $false
    if ($state.Total -gt 0) {
        Invoke-Seek -TargetSeconds (($ui.Seek.Value / 100.0) * $state.Total)
    }
})

# La ventana se arrastra desde cualquier parte que no sea un control.
$ui.Root.Add_MouseLeftButtonDown({
    try { $window.DragMove() } catch { }
})

# La X oculta, no destruye: la ventana se reutiliza en la siguiente lectura.
$window.Add_Closing({
    param($sender, $e)
    $e.Cancel = $true
    Stop-Playback
})

# --------------------------------------------------------------------------
# Pulso: 60 ms. Atiende ordenes, recoge audio generado y refresca la barra.
# --------------------------------------------------------------------------
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [timespan]::FromMilliseconds(60)

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

        $chunk.Duration = Get-WavDuration -Path $done.Wav
        $chunk.Ready = $true
        $changed = $true
    }

    if ($changed) { Update-Offsets }

    # 3. Arranque del audio y salto al siguiente fragmento cuando ya esta listo.
    if ($state.Chunks.Count -gt 0 -and -not $state.Finished) {
        if ($state.PlayIndex -lt 0 -and $state.Chunks[0].Ready -and $state.IsPlaying) {
            Start-Chunk -Index 0 -Offset 0 -AutoPlay $true
        } elseif ($state.WaitingForNext -and $state.IsPlaying) {
            $next = $state.PlayIndex + 1
            if ($next -lt $state.Chunks.Count -and $state.Chunks[$next].Ready) {
                $state.WaitingForNext = $false
                Start-Chunk -Index $next -Offset 0 -AutoPlay $true
            }
        }
    }

    # 4. Barra de progreso y reloj.
    if ($window.IsVisible -and $state.Chunks.Count -gt 0) {
        $position = Get-GlobalPosition

        if (-not $state.IsSeeking -and $state.Total -gt 0) {
            $ui.Seek.Value = [Math]::Min(100, ($position / $state.Total) * 100)
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
})

$timer.Start()

# --------------------------------------------------------------------------
# Calentamiento: obliga a cargar los modelos ahora, para que la primera lectura
# real no pague la espera.
# --------------------------------------------------------------------------
if (-not $NoWarmup) {
    $warmIndex = 0
    foreach ($lang in @($models.Keys)) {
        $sync.SynthJobs.Enqueue(@{
            Generation = 0
            Index      = -1 - $warmIndex
            Lang       = $lang
            Text       = 'Listo.'
            Wav        = (Join-Path $paths.TmpDir ('warmup_{0}.wav' -f $lang))
        })
        $warmIndex++
    }
}

Write-DaemonLog 'Proceso residente listo.'

try {
    [Windows.Threading.Dispatcher]::Run()
} finally {
    $sync.Stopping = $true

    try {
        @{ Left = $window.Left; Top = $window.Top } |
            ConvertTo-Json |
            Set-Content -LiteralPath $paths.StateFile -Encoding UTF8
    } catch { }

    foreach ($entry in $runspaces) {
        try { $entry.PowerShell.Dispose() } catch { }
        try { $entry.Runspace.Dispose() } catch { }
    }

    Get-Process -Name 'piper' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Write-DaemonLog 'Proceso residente detenido.'
}
