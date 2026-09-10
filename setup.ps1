#
# setup.ps1
# Instala todo lo que Read Aloud necesita y que no cabe en el repositorio:
# el motor Piper y los modelos de voz.
#
#   .\setup.ps1                  Instala el motor y las voces en espanol e ingles
#   .\setup.ps1 -SkipEnglish     Solo la voz en espanol
#   .\setup.ps1 -Force           Vuelve a descargar aunque ya este todo
#
# Se descargan unos 150 MB la primera vez. Despues, nada.

[CmdletBinding()]
param(
    [switch]$SkipEnglish,
    [switch]$Force,
    [switch]$NoStartupPrompt
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\ReadAloud.Core.ps1')

$paths = Get-ReadAloudPaths
$settings = Get-ReadAloudSettings -Paths $paths

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$piperRelease = '2023.11.14-2'
$piperUrl = "https://github.com/rhasspy/piper/releases/download/$piperRelease/piper_windows_amd64.zip"

# Cada voz apunta a su ruta en el repositorio oficial de voces de Piper.
$voiceCatalog = @{
    'es_MX-claude-high'     = 'es/es_MX/claude/high/es_MX-claude-high'
    'es_MX-ald-medium'      = 'es/es_MX/ald/medium/es_MX-ald-medium'
    'es_ES-davefx-medium'   = 'es/es_ES/davefx/medium/es_ES-davefx-medium'
    'en_US-lessac-medium'   = 'en/en_US/lessac/medium/en_US-lessac-medium'
    'en_US-amy-medium'      = 'en/en_US/amy/medium/en_US-amy-medium'
    'en_GB-alba-medium'     = 'en/en_GB/alba/medium/en_GB-alba-medium'
}

$voicesBaseUrl = 'https://huggingface.co/rhasspy/piper-voices/resolve/main'

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-RemoteFile {
    param(
        [string]$Url,
        [string]$Destination
    )

    $name = Split-Path -Leaf $Destination
    Write-Host ("    descargando {0}" -f $name) -ForegroundColor Gray

    $directory = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temp = "$Destination.part"
    $client = New-Object Net.WebClient

    try {
        $client.DownloadFile($Url, $temp)
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    } finally {
        $client.Dispose()
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }

    $size = (Get-Item -LiteralPath $Destination).Length / 1MB
    Write-Host ("    listo  {0:N1} MB" -f $size) -ForegroundColor DarkGray
}

function Install-Piper {
    if ((Test-PiperInstalled -Paths $paths) -and -not $Force) {
        Write-Host '    ya estaba instalado' -ForegroundColor DarkGray
        return
    }

    $binDir = Join-Path $paths.BaseDir 'bin'
    $zipPath = Join-Path $env:TEMP 'piper_windows_amd64.zip'

    Get-RemoteFile -Url $piperUrl -Destination $zipPath

    if (-not (Test-Path -LiteralPath $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }

    Write-Host '    descomprimiendo' -ForegroundColor Gray
    Expand-Archive -LiteralPath $zipPath -DestinationPath $binDir -Force
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    if (-not (Test-PiperInstalled -Paths $paths)) {
        throw "El paquete se descomprimio pero no encuentro piper.exe en $($paths.PiperDir)."
    }
}

function Install-Voice {
    param([string]$Name)

    if (-not $voiceCatalog.ContainsKey($Name)) {
        Write-Host ("    no conozco la voz '{0}'. Descargala a mano desde huggingface.co/rhasspy/piper-voices" -f $Name) -ForegroundColor Yellow
        return
    }

    $model = Join-Path $paths.VoicesDir ($Name + '.onnx')
    $config = $model + '.json'

    if ((Test-Path -LiteralPath $model) -and (Test-Path -LiteralPath $config) -and -not $Force) {
        Write-Host ("    {0} ya estaba instalada" -f $Name) -ForegroundColor DarkGray
        return
    }

    $remote = $voiceCatalog[$Name]
    Get-RemoteFile -Url "$voicesBaseUrl/$remote.onnx" -Destination $model
    Get-RemoteFile -Url "$voicesBaseUrl/$remote.onnx.json" -Destination $config
}

function Test-Installation {
    $probe = Join-Path $paths.TmpDir 'setup_probe.wav'

    if (-not (Test-Path -LiteralPath $paths.TmpDir)) {
        New-Item -ItemType Directory -Path $paths.TmpDir -Force | Out-Null
    }

    $voice = Get-VoiceModelPath -Paths $paths -Settings $settings -Lang 'es'
    if (-not $voice.Ready) {
        Write-Host '    no puedo probar: falta la voz en espanol' -ForegroundColor Yellow
        return $false
    }

    $arguments = @(
        '--model', ('"' + $voice.Model + '"')
        '--espeak_data', ('"' + $paths.EspeakData + '"')
        '--output_file', ('"' + $probe + '"')
        '--quiet'
    ) -join ' '

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $paths.PiperExe
    $psi.Arguments = $arguments
    $psi.WorkingDirectory = $paths.PiperDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true

    $process = [Diagnostics.Process]::Start($psi)
    $process.StandardInput.WriteLine('Instalacion completa.')
    $process.StandardInput.Close()
    [void]$process.StandardOutput.ReadToEnd()
    $process.WaitForExit(30000)

    $ok = (Test-Path -LiteralPath $probe) -and ((Get-Item -LiteralPath $probe).Length -gt 1000)

    if ($ok) {
        $duration = Get-WavDuration -Path $probe
        Write-Host ("    prueba correcta: {0:N1} segundos de audio" -f $duration) -ForegroundColor Green
    } else {
        Write-Host '    la prueba no genero audio' -ForegroundColor Red
    }

    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    return $ok
}

Write-Host 'Read Aloud - instalacion' -ForegroundColor White
Write-Host ("Carpeta destino: {0}" -f $paths.BaseDir) -ForegroundColor Gray

Write-Step 'Motor Piper'
Install-Piper

Write-Step 'Voz en espanol'
Install-Voice -Name $settings.VoiceEs

if (-not $SkipEnglish) {
    Write-Step 'Voz en ingles'
    Write-Host '    sin esta voz, el texto en ingles se lee con acento espanol' -ForegroundColor DarkGray
    Install-Voice -Name $settings.VoiceEn
}

Write-Step 'Prueba de funcionamiento'
$ok = Test-Installation

Write-Host ''

if (-not $ok) {
    Write-Host 'La instalacion quedo incompleta. Revisa los mensajes de arriba.' -ForegroundColor Red
    exit 1
}

Write-Host 'Todo listo.' -ForegroundColor Green
Write-Host ''
Write-Host 'Siguiente paso:' -ForegroundColor White
Write-Host '  .\install_startup.ps1     deja los atajos activos al iniciar Windows'
Write-Host ''
Write-Host 'O pruebalo ahora mismo:'
Write-Host '  .\read_aloud.ps1 -InputText "Hola, ya quedo funcionando."'
