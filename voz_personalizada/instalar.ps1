#
# instalar.ps1
# Prepara la carpeta de trabajo de una voz personalizada: los entornos de
# Python con las versiones exactas que funcionaron, ffmpeg, Applio y los
# modelos base. Ver docs\voz-personalizada.md.
#
#   .\instalar.ps1 -Trabajo D:\voces\mi_voz              Todo
#   .\instalar.ps1 -Trabajo D:\voces\mi_voz -SinMejora   Sin la prueba de resemble-enhance
#   .\instalar.ps1 -Trabajo D:\voces\mi_voz -SinApplio   Sin el entrenamiento
#
# Necesita uv y git con git-lfs. Descarga unos 15 GB entre paquetes y modelos,
# todo dentro de la carpeta de trabajo: nada se instala fuera de ella, y
# borrarla deja el equipo como estaba.
#
# Las versiones de requisitos\ se probaron con PyTorch 2.11 y CUDA 12.8, que
# es lo que piden las NVIDIA RTX 50. Las listas se instalan
# con --no-deps: estan completas, y asi no entra ninguna version distinta.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Trabajo,
    [switch]$SinMejora,
    [switch]$SinApplio
)

$ErrorActionPreference = 'Stop'

$requisitos = Join-Path $PSScriptRoot 'requisitos'
$indicePytorch = 'https://download.pytorch.org/whl/cu128'

# Applio en una version fija, la que se probo, para que un cambio suyo no
# rompa el proceso.
$applioUrl = 'https://github.com/IAHispano/Applio'
$applioVersion = 'fb427aa388a954a387da7034fbbc08313f7ffe8c'

# Pesos de resemble-enhance, del repositorio oficial de Resemble AI.
$resembleUrl = 'https://huggingface.co/ResembleAI/resemble-enhance'

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-Checked {
    # Los programas externos no lanzan excepciones al fallar: se mira su
    # codigo de salida. Su salida va a la consola, para que no se mezcle con
    # lo que devuelven las funciones que los llaman.
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Fallo: $Program $($Arguments -join ' ')"
    }
}

function New-Entorno {
    param([string]$Ruta, [string]$Python, [string]$Lista)

    $ejecutable = Join-Path $Ruta 'Scripts\python.exe'
    if (Test-Path -LiteralPath $ejecutable) {
        Write-Host "    ya existe: $Ruta" -ForegroundColor Gray
        return $ejecutable
    }
    Invoke-Checked 'uv' @('venv', $Ruta, '--python', $Python)
    Invoke-Checked 'uv' @('pip', 'install', '--python', $ejecutable, '--no-deps',
                          '-r', (Join-Path $requisitos $Lista),
                          '--extra-index-url', $indicePytorch, '--index-strategy', 'unsafe-best-match')
    return $ejecutable
}

foreach ($programa in @('uv', 'git')) {
    if (-not (Get-Command $programa -ErrorAction SilentlyContinue)) {
        throw "Falta $programa. Instalalo y vuelve a correr este script."
    }
}
& git lfs version *> $null
if ($LASTEXITCODE -ne 0) { throw 'Falta git-lfs: instalalo con "git lfs install".' }

Write-Step "Carpeta de trabajo: $Trabajo"
foreach ($carpeta in @('datos', 'modelos', 'herramientas', 'referencias\original')) {
    New-Item -ItemType Directory -Path (Join-Path $Trabajo $carpeta) -Force | Out-Null
}
$config = Join-Path $Trabajo 'voz.toml'
if (-not (Test-Path -LiteralPath $config)) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'voz.ejemplo.toml') -Destination $config
    Write-Host '    creado voz.toml: editalo antes de empezar' -ForegroundColor Yellow
}

Write-Step 'Entorno principal: separacion, transcripcion, alineacion y cortes'
$principal = New-Entorno (Join-Path $Trabajo '.venv') '3.12' 'principal.txt'

# audio-separator y Whisper llaman a "ffmpeg" por su nombre. Se usa la copia
# que trae imageio-ffmpeg, que ya esta en el entorno, en vez de instalar otra.
$ffmpeg = Join-Path $Trabajo 'herramientas\ffmpeg.exe'
if (-not (Test-Path -LiteralPath $ffmpeg)) {
    $origen = & $principal -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())'
    Copy-Item -LiteralPath $origen.Trim() -Destination $ffmpeg
}

if (-not $SinMejora) {
    Write-Step 'Entorno de mejora: resemble-enhance, para la prueba a ciegas'
    # Python 3.11 y NumPy 1.26: resemble-enhance es de 2023 y falla con NumPy 2.
    $mejora = New-Entorno (Join-Path $Trabajo '.venv_mejora') '3.11' 'mejora.txt'
    $pesos = Join-Path $Trabajo '.venv_mejora\Lib\site-packages\resemble_enhance\model_repo'
    if (-not (Test-Path -LiteralPath (Join-Path $pesos '.git'))) {
        $env:GIT_LFS_SKIP_SMUDGE = '1'
        Invoke-Checked 'git' @('clone', '-q', $resembleUrl, $pesos)
        Remove-Item Env:\GIT_LFS_SKIP_SMUDGE
        Invoke-Checked 'git' @('-C', $pesos, 'lfs', 'pull')
    }
}

if (-not $SinApplio) {
    Write-Step 'Applio: entrenamiento de la voz con RVC'
    $applio = Join-Path $Trabajo 'applio'
    if (-not (Test-Path -LiteralPath (Join-Path $applio '.git'))) {
        Invoke-Checked 'git' @('clone', '-q', $applioUrl, $applio)
    }
    Invoke-Checked 'git' @('-C', $applio, 'checkout', '-q', $applioVersion)
    $python = New-Entorno (Join-Path $applio '.venv') '3.12' 'applio.txt'

    # Applio guarda su configuracion en %APPDATA% y entrena en media precision
    # si no se le dice otra cosa. Con este archivo, dentro de la carpeta de
    # trabajo, entrena a precision completa. Los pasos le indican su ruta con
    # APPLIO_CONFIG_FILE.
    $configApplio = Join-Path $applio 'configuracion_voz.json'
    if (-not (Test-Path -LiteralPath $configApplio)) {
        Set-Content -LiteralPath $configApplio -Value '{ "precision": "fp32" }' -Encoding ASCII
    }

    # Modelos base oficiales de RVC v2, el extractor de tono RMVPE y
    # ContentVec, del repositorio de Applio en Hugging Face. Sin --exe: no
    # hacen falta sus ejecutables.
    Push-Location $applio
    try {
        Invoke-Checked $python @('core.py', 'prerequisites', '--pretraineds-hifigan', '--models', '--no-exe')
    } finally {
        Pop-Location
    }
}

Write-Step 'Listo'
Write-Host "    Siguiente: edita $config y sigue docs\voz-personalizada.md." -ForegroundColor Green
