#
# instalar.ps1
# Prepara la carpeta de trabajo de una voz personalizada: los entornos de
# Python con las versiones exactas que funcionaron, ffmpeg y los modelos base.
# Ver docs\voz-personalizada.md.
#
#   .\instalar.ps1 -Trabajo D:\voces\mi_voz                Todo el proceso: preparar, revisar y entrenar
#   .\instalar.ps1 -Trabajo D:\voces\mi_voz -SoloLectura   Solo lo que Read Aloud necesita para leer
#                                                          con una voz ya entrenada (unos 9 GB)
#   .\instalar.ps1 -Trabajo D:\voces\mi_voz -ConRvc        Ademas Applio, de la primera version (RVC)
#   .\instalar.ps1 -Trabajo D:\voces\mi_voz -ConMejora     Ademas resemble-enhance, para repetir la prueba a ciegas
#
# Necesita uv, y git con git-lfs para -ConRvc y -ConMejora. El proceso
# completo descarga unos 25 GB entre paquetes y modelos, todo dentro de la
# carpeta de trabajo: nada se instala fuera de ella, y borrarla deja el equipo
# como estaba. Eso incluye Python: los entornos usan uno propio de uv, guardado
# en herramientas\python, y no el que tenga instalado el equipo, que al
# actualizarse o desinstalarse los romperia.
#
# Los tres entornos del proceso (principal, Qwen3-TTS y Qwen3-ASR) salen de
# uv.lock, un grupo de pyproject.toml cada uno: versiones exactas, probadas con
# PyTorch 2.11 y CUDA 12.8, que es lo que piden las tarjetas NVIDIA de la
# RTX 50, y el sha256 de cada paquete; uno que no coincida no se instala.
# Volver a correr el script deja cada entorno igual al lock, aunque se haya
# tocado a mano.
#
# Los opcionales, Applio y resemble-enhance, siguen con sus listas de
# requisitos\: tambien completas y con sha256, instaladas con --no-deps.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Trabajo,
    [switch]$SoloLectura,
    [switch]$ConRvc,
    [switch]$ConMejora
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

function Sync-Entorno {
    # Crea o pone al dia un entorno con un grupo de uv.lock. --frozen usa el
    # lock tal cual, sin volver a resolver nada.
    param([string]$Ruta, [string]$Grupo)
    $env:UV_PROJECT_ENVIRONMENT = $Ruta
    try {
        Invoke-Checked 'uv' @('sync', '--project', $PSScriptRoot, '--frozen', '--no-default-groups',
                              '--group', $Grupo, '--managed-python')
    } finally {
        Remove-Item Env:\UV_PROJECT_ENVIRONMENT
    }
    return Join-Path $Ruta 'Scripts\python.exe'
}

function New-Entorno {
    # Para los opcionales, con su lista completa de requisitos\.
    param([string]$Ruta, [string]$Python, [string]$Lista)

    $ejecutable = Join-Path $Ruta 'Scripts\python.exe'
    if (Test-Path -LiteralPath $ejecutable) {
        Write-Host "    ya existe: $Ruta" -ForegroundColor Gray
        return $ejecutable
    }
    Invoke-Checked 'uv' @('venv', $Ruta, '--python', $Python, '--managed-python')
    Invoke-Checked 'uv' @('pip', 'install', '--python', $ejecutable, '--no-deps', '--require-hashes',
                          '-r', (Join-Path $requisitos $Lista),
                          '--extra-index-url', $indicePytorch, '--index-strategy', 'unsafe-best-match')
    return $ejecutable
}

function Get-Modelos {
    # Los modelos de Hugging Face se bajan ahora y no la primera vez que se
    # usan: Read Aloud abre Qwen sin conexion (lib\servidor_qwen.py), asi
    # que tienen que estar ya en modelos\hf.
    param([string]$Python, [string[]]$Repos)
    $env:HF_HOME = Join-Path $Trabajo 'modelos\hf'
    foreach ($repo in $Repos) {
        Write-Host "    $repo"
        Invoke-Checked $Python @('-c', "from huggingface_hub import snapshot_download; snapshot_download('$repo')")
    }
}

$programas = @('uv')
if ($ConRvc -or $ConMejora) { $programas += 'git' }
foreach ($programa in $programas) {
    if (-not (Get-Command $programa -ErrorAction SilentlyContinue)) {
        throw "Falta $programa. Instalalo y vuelve a correr este script."
    }
}
if ($ConRvc -or $ConMejora) {
    & git lfs version *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Falta git-lfs: instalalo con "git lfs install".' }
}

Write-Step "Carpeta de trabajo: $Trabajo"
foreach ($carpeta in @('datos', 'modelos', 'herramientas', 'referencias\original')) {
    New-Item -ItemType Directory -Path (Join-Path $Trabajo $carpeta) -Force | Out-Null
}
# El Python de los entornos se descarga aqui, no en la carpeta de uv del
# usuario: asi queda dentro de la carpeta de trabajo, como todo lo demas.
$env:UV_PYTHON_INSTALL_DIR = Join-Path $Trabajo 'herramientas\python'

$config = Join-Path $Trabajo 'voz.toml'
if (-not (Test-Path -LiteralPath $config)) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'voz.ejemplo.toml') -Destination $config
    Write-Host '    creado voz.toml: editalo antes de empezar' -ForegroundColor Yellow
}

Write-Step 'Entorno de Qwen3-TTS: entrenar la voz y leer con ella en Read Aloud'
$qwen = Sync-Entorno (Join-Path $Trabajo '.venv_qwen') 'qwen'
Get-Modelos $qwen @('Qwen/Qwen3-TTS-12Hz-1.7B-Base', 'Qwen/Qwen3-TTS-Tokenizer-12Hz')
New-Item -ItemType Directory -Path (Join-Path $Trabajo 'modelos\voz_app') -Force | Out-Null

if ($SoloLectura) {
    Write-Step 'Listo para leer'
    Write-Host "    Copia la voz entrenada (ajuste.json, voz.safetensors y lora.safetensors) a" -ForegroundColor Green
    Write-Host "    $(Join-Path $Trabajo 'modelos\voz_app') y pon QwenWorkDir = '$Trabajo'" -ForegroundColor Green
    Write-Host "    en config\settings.psd1. Ver docs\configuracion.md." -ForegroundColor Green
    return
}

Write-Step 'Entorno principal: separacion, transcripcion, alineacion, cortes y medidas'
$principal = Sync-Entorno (Join-Path $Trabajo '.venv') 'principal'

# audio-separator y Whisper llaman a "ffmpeg" por su nombre. Se usa la copia
# que trae imageio-ffmpeg, que ya esta en el entorno, en vez de instalar otra.
$ffmpeg = Join-Path $Trabajo 'herramientas\ffmpeg.exe'
if (-not (Test-Path -LiteralPath $ffmpeg)) {
    $origen = & $principal -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())'
    Copy-Item -LiteralPath $origen.Trim() -Destination $ffmpeg
}

Write-Step 'Entorno de Qwen3-ASR: la segunda transcripcion de cada clip'
$asr = Sync-Entorno (Join-Path $Trabajo '.venv_asr') 'asr'
Get-Modelos $asr @('Qwen/Qwen3-ASR-1.7B')

if ($ConMejora) {
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

if ($ConRvc) {
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
