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

Set-SpeechTerms (Import-SpeechTerms -Path $paths.TermsFile)

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
                if ($line.Trim() -ne '') { $sync.Requests.Enqueue($line) }
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
  </Window.Resources>
  <Border x:Name="Root" CornerRadius="10" Background="#F21B1B1F" BorderBrush="#33FFFFFF"
          BorderThickness="1" Padding="10,7">
    <Border.Effect>
      <DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.45" Color="#000000"/>
    </Border.Effect>
    <StackPanel Orientation="Vertical">
    <!-- Panel con el texto que se esta leyendo. El ancho se ata al de la
         barra de controles: sin limite, el texto no partiria las lineas y la
         ventana crecería a lo ancho sin fin. -->
    <Border x:Name="TextPanel" Visibility="Collapsed" Height="210" Margin="0,2,0,8"
            CornerRadius="6" Background="#FF26262B" Padding="12,8,6,8"
            Width="{Binding ActualWidth, ElementName=Bar}">
      <ScrollViewer x:Name="TextScroll" VerticalScrollBarVisibility="Auto"
                    HorizontalScrollBarVisibility="Disabled">
        <StackPanel x:Name="TextHost" Margin="0,0,8,0"/>
      </ScrollViewer>
    </Border>
    <StackPanel x:Name="Bar" Orientation="Horizontal" VerticalAlignment="Center">
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
              ToolTip="Velocidad. Clic: mas rapido. Clic derecho: mas lento."/>
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
      <Button x:Name="BtnClose" Content="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="12"
              Width="26" Height="26" Foreground="#C8C8CC" Background="Transparent"
              BorderThickness="0" Cursor="Hand" Margin="2,0,0,0" ToolTip="Cerrar"/>
    </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

$reader = New-Object IO.StringReader($xaml)
$xmlReader = [Xml.XmlReader]::Create($reader)
$window = [Windows.Markup.XamlReader]::Load($xmlReader)

$ui = @{}
foreach ($name in @('Root','LangBadge','BtnBack','BtnPlay','BtnFwd','BtnSpeed','BufferBar','Seek','TimeLabel','BtnText','BtnClose','TextPanel','TextScroll','TextHost','Bar')) {
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
        $window.Left = $savedState.Left
        $window.Top = $savedState.Top
    } catch { }
}

function Move-PlayerOnScreen {
    # La posicion guardada puede venir de un monitor que ya no esta conectado.
    # Antes solo se comprobaba el borde superior izquierdo, y la ventana podia
    # abrirse por completo fuera de la pantalla visible. Si no cabe entera en
    # el escritorio actual, vuelve a la esquina inferior derecha.
    $izquierda = [Windows.SystemParameters]::VirtualScreenLeft
    $arriba = [Windows.SystemParameters]::VirtualScreenTop
    $derecha = $izquierda + [Windows.SystemParameters]::VirtualScreenWidth
    $abajo = $arriba + [Windows.SystemParameters]::VirtualScreenHeight

    $ancho = $window.ActualWidth
    $alto = $window.ActualHeight
    if ($ancho -le 0) { $ancho = 480 }
    if ($alto -le 0) { $alto = 50 }

    $cabe = ($window.Left -ge $izquierda) -and ($window.Top -ge $arriba) -and
            (($window.Left + $ancho) -le $derecha) -and (($window.Top + $alto) -le $abajo)

    if (-not $cabe) {
        $area = [Windows.SystemParameters]::WorkArea
        $window.Left = $area.Right - $ancho - 12
        $window.Top = $area.Bottom - $alto - 12
    }
}

Move-PlayerOnScreen

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

# Velocidades que recorre el boton. Se cambia la velocidad de reproduccion, no
# la de sintesis: asi el cambio es inmediato y no hay que regenerar el audio.
$speedSteps = @(0.75, 1.0, 1.25, 1.5, 1.75, 2.0)
$script:speed = 1.0

if ($savedState -and $savedState.PSObject.Properties.Name -contains 'Speed') {
    $saved = [double]$savedState.Speed
    if ($speedSteps -contains $saved) { $script:speed = $saved }
}

function Save-PlayerState {
    # Se guarda en cada cambio y no solo al cerrar: si el proceso se corta a
    # la fuerza, la velocidad elegida no se pierde.
    try {
        @{ Left = $window.Left; Top = $window.Top; Speed = $script:speed; TextPanel = $script:panelVisible } |
            ConvertTo-Json |
            Set-Content -LiteralPath $paths.StateFile -Encoding UTF8
    } catch { }
}

function Format-Speed {
    param([double]$Value)
    return ($Value.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + 'x')
}

function Set-PlaybackSpeed {
    param([int]$Direction)

    $index = [Array]::IndexOf($speedSteps, $script:speed)
    if ($index -lt 0) { $index = 1 }

    $index = [Math]::Max(0, [Math]::Min($speedSteps.Count - 1, $index + $Direction))
    $script:speed = $speedSteps[$index]

    foreach ($p in $players) { $p.SpeedRatio = $script:speed }
    $ui.BtnSpeed.Content = Format-Speed $script:speed
    Save-PlayerState
}

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
    $state.PlayIndex = -1
    Set-PlayIcon -Playing $false

    foreach ($chunk in $state.Chunks) {
        if ($chunk.Wav -and (Test-Path -LiteralPath $chunk.Wav)) {
            Remove-Item -LiteralPath $chunk.Wav -Force -ErrorAction SilentlyContinue
        }
    }

    $state.Chunks.Clear()

    $ui.TextHost.Children.Clear()
    $script:runs.Clear()
    $state.HighlightIndex = -1
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

    # Lo que hubiera precargado deja de servir: se va a otro punto.
    $state.PreloadIndex = -1
    (Get-IdlePlayer).Stop()

    $ui.LangBadge.Text = $chunk.Lang.ToUpperInvariant()
    (Get-ActivePlayer).Open([uri]$chunk.Wav)
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

    Write-DaemonLog ('Salto a {0:N1} s de {1:N1} s' -f $TargetSeconds, $state.Total)

    for ($i = $lastReady; $i -ge 0; $i--) {
        $chunk = $state.Chunks[$i]
        if ($TargetSeconds -ge $chunk.Offset) {
            Start-Chunk -Index $i -Offset ($TargetSeconds - $chunk.Offset) -AutoPlay $state.IsPlaying
            return
        }
    }

    Start-Chunk -Index 0 -Offset 0 -AutoPlay $state.IsPlaying
}

# --------------------------------------------------------------------------
# Panel de texto: muestra lo que se esta leyendo y resalta la frase que suena.
# --------------------------------------------------------------------------
$conversorColor = New-Object Windows.Media.BrushConverter

function New-Brush {
    param([string]$Hex)
    $pincel = $conversorColor.ConvertFromString($Hex)
    $pincel.Freeze()
    return $pincel
}

$colores = @{
    Pendiente = New-Brush '#D0D0D6'
    Leido     = New-Brush '#7C7C84'
    Actual    = New-Brush '#FFFFFF'
    Fondo     = New-Brush '#663B82F6'
    Ninguno   = [Windows.Media.Brushes]::Transparent
    Encendido = New-Brush '#9AE6B4'
    Apagado   = New-Brush '#C8C8CC'
}

$fuenteTexto = New-Object Windows.Media.FontFamily 'Segoe UI'
$script:runs = New-Object System.Collections.Generic.List[object]
$script:panelVisible = $false

if ($savedState -and $savedState.PSObject.Properties.Name -contains 'TextPanel') {
    $script:panelVisible = [bool]$savedState.TextPanel
}

function Build-TextPanel {
    # Una linea de texto por bloque y, dentro, un trozo por frase. Cada trozo
    # sabe a que fragmento de audio corresponde, y por eso basta un clic en
    # una frase para saltar a ella.
    $ui.TextHost.Children.Clear()
    $script:runs.Clear()
    $state.HighlightIndex = -1

    $bloque = -1
    $parrafo = $null

    for ($i = 0; $i -lt $state.Chunks.Count; $i++) {
        $c = $state.Chunks[$i]

        if ($c.Block -ne $bloque) {
            $parrafo = New-Object Windows.Controls.TextBlock
            $parrafo.TextWrapping = 'Wrap'
            $parrafo.FontFamily = $fuenteTexto
            $parrafo.FontSize = 13
            $parrafo.LineHeight = 19

            switch ($c.Kind) {
                'titulo' {
                    $parrafo.FontWeight = [Windows.FontWeights]::SemiBold
                    $parrafo.FontSize = 14
                    $arriba = 0
                    if ($i -gt 0) { $arriba = 10 }
                    $parrafo.Margin = New-Object Windows.Thickness(0, $arriba, 0, 4)
                }
                'fila'   { $parrafo.Margin = New-Object Windows.Thickness(0, 0, 0, 2) }
                'vineta' { $parrafo.Margin = New-Object Windows.Thickness(6, 0, 0, 2) }
                default  { $parrafo.Margin = New-Object Windows.Thickness(0, 0, 0, 8) }
            }

            [void]$ui.TextHost.Children.Add($parrafo)
            $bloque = $c.Block
        } else {
            $parrafo.Inlines.Add([Windows.Documents.Run]::new(' '))
        }

        $trozo = [Windows.Documents.Run]::new([string]$c.Display)
        $trozo.Tag = $i
        $trozo.Foreground = $colores.Pendiente
        $trozo.Cursor = [Windows.Input.Cursors]::Hand

        $trozo.Add_MouseLeftButtonDown({
            param($sender, $e)
            $e.Handled = $true
            Start-FromChunk -Index ([int]$sender.Tag)
        })

        $parrafo.Inlines.Add($trozo)
        [void]$script:runs.Add(@{ Run = $trozo; Host = $parrafo })
    }

    $ui.TextScroll.ScrollToTop()
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

    try {
        $entrada = $script:runs[$Index]
        $ui.TextScroll.UpdateLayout()

        $rect = $entrada.Run.ContentStart.GetCharacterRect([Windows.Documents.LogicalDirection]::Forward)
        $punto = $entrada.Host.TransformToAncestor($ui.TextHost).Transform((New-Object Windows.Point($rect.X, $rect.Y)))

        $vista = $ui.TextScroll.ViewportHeight
        $arriba = $ui.TextScroll.VerticalOffset

        if (($punto.Y -lt ($arriba + 4)) -or ($punto.Y -gt ($arriba + $vista * 0.65))) {
            $ui.TextScroll.ScrollToVerticalOffset([Math]::Max(0, $punto.Y - $vista * 0.25))
        }
    } catch { }
}

function Update-Highlight {
    # Lo ya leido se apaga, la frase actual se resalta y lo pendiente queda
    # en el color normal. Asi se ve de un vistazo por donde va la lectura.
    param([switch]$Force)

    if ($script:runs.Count -eq 0) { return }

    $actual = $state.PlayIndex
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

function Set-TextPanel {
    param([bool]$Visible)

    $abajo = $window.Top + $window.ActualHeight
    $estabaVisible = $window.IsVisible

    if ($Visible) {
        $ui.TextPanel.Visibility = 'Visible'
        $ui.BtnText.Foreground = $colores.Encendido
        $ui.BtnText.ToolTip = 'Ocultar el texto'
    } else {
        $ui.TextPanel.Visibility = 'Collapsed'
        $ui.BtnText.Foreground = $colores.Apagado
        $ui.BtnText.ToolTip = 'Mostrar el texto que se esta leyendo'
    }

    $script:panelVisible = $Visible

    if ($estabaVisible) {
        # El panel crece hacia arriba: la barra de controles se queda donde
        # estaba y no se sale por el borde inferior de la pantalla.
        $window.UpdateLayout()
        $window.Top = $abajo - $window.ActualHeight
        Move-PlayerOnScreen
    }

    Save-PlayerState

    if ($Visible) { Update-Highlight -Force }
}

if ($script:panelVisible) {
    $ui.TextPanel.Visibility = 'Visible'
    $ui.BtnText.Foreground = $colores.Encendido
    $ui.BtnText.ToolTip = 'Ocultar el texto'
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
        -Fallback $settings.FallbackLanguage -Pauses (Get-ConfiguredPauses)

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

    Update-Offsets
    Build-TextPanel
    $ui.LangBadge.Text = $plan.DocumentLang.ToUpperInvariant()
    $ui.Seek.Value = 0
    $ui.TimeLabel.Text = '0:00 / ' + (Format-Time $state.Total)
    Set-PlayIcon -Playing $true
    $state.IsPlaying = $true

    if ($settings.ShowPlayer) {
        $window.Show()
        # Se revisa al mostrar, no solo al arrancar: el monitor puede cambiar
        # mientras el proceso residente sigue vivo.
        Move-PlayerOnScreen
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
            $sender.Stop()

            $state.Active = 1 - $state.Active
            $state.PlayIndex = $next
            $state.PreloadIndex = -1
            $state.WaitingForNext = $false

            $nuevo = Get-ActivePlayer
            $ui.LangBadge.Text = $state.Chunks[$next].Lang.ToUpperInvariant()

            try { $nuevo.Position = [timespan]::Zero } catch { }
            $nuevo.Play()
            $nuevo.SpeedRatio = $script:speed

            Open-NextChunk
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

$ui.BtnSpeed.Add_Click({ Set-PlaybackSpeed -Direction 1 })
$ui.BtnSpeed.Add_MouseRightButtonUp({ Set-PlaybackSpeed -Direction -1 })
$ui.BtnSpeed.Content = Format-Speed $script:speed

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

# La ventana se arrastra desde cualquier parte que no sea un control.
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
            ($nodo -is [Windows.Documents.TextElement])) {
            return
        }

        if ($nodo -is [Windows.Media.Visual]) {
            $nodo = [Windows.Media.VisualTreeHelper]::GetParent($nodo)
        } else {
            $nodo = $null
        }
    }

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
            'faster' { Set-PlaybackSpeed -Direction 1 }
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

    if ($changed) { Update-Offsets }

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

    Save-PlayerState

    foreach ($entry in $runspaces) {
        try { $entry.PowerShell.Dispose() } catch { }
        try { $entry.Runspace.Dispose() } catch { }
    }

    Get-Process -Name 'piper' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Write-DaemonLog 'Proceso residente detenido.'
}
