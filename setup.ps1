#
# setup.ps1
# Instala todo lo que Read Aloud necesita y que no cabe en el repositorio:
# el motor Piper y los modelos de voz.
#
#   .\setup.ps1                  Instala el motor y las voces en espanol e ingles
#   .\setup.ps1 -SkipEnglish     Solo la voz en espanol
#   .\setup.ps1 -Force           Vuelve a descargar aunque ya este todo
#   .\setup.ps1 -PauseOnError    Si algo falla, espera una tecla antes de cerrar
#                                (lo usan el instalador y el aviso del programa,
#                                que abren esta ventana y no queremos que el
#                                error desaparezca antes de poder leerlo)
#
# Se descargan unos 200 MB la primera vez. Despues, nada. Todo lo que se ve aqui
# queda tambien en read_aloud_piper\runtime\setup.log.
#
# Si algo falla, se puede volver a ejecutar sin riesgo: lo que ya esta no se
# descarga otra vez.

[CmdletBinding()]
param(
    [switch]$SkipEnglish,
    [switch]$Force,
    [switch]$NoStartupPrompt,
    [switch]$PauseOnError
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\ReadAloud.Core.ps1')

$paths = Get-ReadAloudPaths
$settings = Get-ReadAloudSettings -Paths $paths

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$piperRelease = '2023.11.14-2'
$piperUrl = "https://github.com/rhasspy/piper/releases/download/$piperRelease/piper_windows_amd64.zip"
$vcRedistUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'

# Cada voz apunta a su ruta en el repositorio oficial de voces de Piper.
$voiceCatalog = @{
    'es_MX-claude-high'     = 'es/es_MX/claude/high/es_MX-claude-high'
    'es_MX-ald-medium'      = 'es/es_MX/ald/medium/es_MX-ald-medium'
    'es_ES-davefx-medium'   = 'es/es_ES/davefx/medium/es_ES-davefx-medium'
    'en_US-lessac-high'     = 'en/en_US/lessac/high/en_US-lessac-high'
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
    # Descarga con hasta tres intentos (una red que parpadea no debe dejar la
    # instalacion a medias) y respetando el proxy del sistema.
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
    $last = $null

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $client = New-Object Net.WebClient
        try {
            $proxy = [Net.WebRequest]::GetSystemWebProxy()
            if ($proxy) {
                $proxy.Credentials = [Net.CredentialCache]::DefaultCredentials
                $client.Proxy = $proxy
            }
            $client.DownloadFile($Url, $temp)
            if ((Get-Item -LiteralPath $temp).Length -lt 1024) { throw 'El archivo descargado esta vacio.' }
            Move-Item -LiteralPath $temp -Destination $Destination -Force
            $last = $null
            break
        } catch {
            $last = $_.Exception.Message
            if ($attempt -lt 3) {
                Write-Host ("    fallo ({0}); reintento {1} de 3" -f $last, ($attempt + 1)) -ForegroundColor Yellow
                Start-Sleep -Seconds (3 * $attempt)
            }
        } finally {
            $client.Dispose()
            if (Test-Path -LiteralPath $temp) {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($null -ne $last) {
        throw ("No pude descargar {0}: {1}`nRevisa tu conexion a internet y que ningun firewall, proxy o antivirus bloquee github.com y huggingface.co." -f $name, $last)
    }

    $size = (Get-Item -LiteralPath $Destination).Length / 1MB
    Write-Host ("    listo  {0:N1} MB" -f $size) -ForegroundColor DarkGray
}

function Stop-PiperInUse {
    # Un piper.exe que sigue vivo (hijo del proceso residente, o huerfano de una
    # instalacion anterior) tiene cargadas las DLL de bin\piper, y Windows no deja
    # sobrescribirlas: la extraccion fallaba con "Acceso denegado" a medias y la
    # instalacion quedaba sin motor. Se cierran antes; el proceso residente los
    # vuelve a abrir solo cuando hace falta.
    $script = Join-Path $PSScriptRoot 'parar_read_aloud.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return }
    $cerrados = @(& $script -Root $PSScriptRoot -OnlyPiper)
    if ($cerrados.Count -gt 0) {
        Write-Host ("    se cerraron {0} proceso(s) de Piper que estaban en uso" -f $cerrados.Count) -ForegroundColor DarkGray
    }
}

function Install-Piper {
    if ((Test-PiperInstalled -Paths $paths) -and -not $Force) {
        Write-Host '    ya estaba instalado' -ForegroundColor DarkGray
        return
    }

    $binDir = Join-Path $paths.BaseDir 'bin'
    $zipPath = Join-Path $env:TEMP 'piper_windows_amd64.zip'
    $trabajo = Join-Path $env:TEMP ('piper_extraer_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))

    Get-RemoteFile -Url $piperUrl -Destination $zipPath

    try {
        # Se extrae primero a una carpeta temporal: si algo sale mal, lo que habia
        # no se toca, y el motor nunca queda a medias.
        Write-Host '    descomprimiendo' -ForegroundColor Gray
        New-Item -ItemType Directory -Path $trabajo -Force | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $trabajo -Force

        $nuevo = Join-Path $trabajo 'piper'
        if (-not (Test-Path -LiteralPath (Join-Path $nuevo 'piper.exe')) -or -not (Test-Path -LiteralPath (Join-Path $nuevo 'espeak-ng-data'))) {
            throw 'El paquete descargado no trae piper.exe y espeak-ng-data donde se esperaba.'
        }

        Stop-PiperInUse

        if (-not (Test-Path -LiteralPath $binDir)) {
            New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        }

        $destino = Join-Path $binDir 'piper'
        $anterior = $destino + '.anterior'
        if (Test-Path -LiteralPath $anterior) { Remove-Item -LiteralPath $anterior -Recurse -Force -ErrorAction SilentlyContinue }

        $apartado = $false
        if (Test-Path -LiteralPath $destino) {
            try {
                Move-Item -LiteralPath $destino -Destination $anterior -Force -ErrorAction Stop
                $apartado = $true
            } catch {
                throw ("No pude reemplazar el motor Piper porque algo lo esta usando ({0}). Cierra Read Aloud (icono de la bandeja > Salir) y vuelve a intentarlo." -f $_.Exception.Message)
            }
        }

        try {
            Move-Item -LiteralPath $nuevo -Destination $destino -ErrorAction Stop
        } catch {
            if ($apartado -and -not (Test-Path -LiteralPath $destino)) {
                Move-Item -LiteralPath $anterior -Destination $destino -ErrorAction SilentlyContinue
            }
            throw ("No pude instalar el motor Piper: {0}" -f $_.Exception.Message)
        }

        if ($apartado) { Remove-Item -LiteralPath $anterior -Recurse -Force -ErrorAction SilentlyContinue }
    } finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $trabajo) { Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if (-not (Test-PiperInstalled -Paths $paths)) {
        throw "El motor se instalo pero no encuentro piper.exe en $($paths.PiperDir)."
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

function Install-VcRuntime {
    # piper.exe necesita el Visual C++ Redistributable de Microsoft. Casi todos
    # los Windows lo traen (lo instalan muchos programas), pero uno recien
    # instalado puede no tenerlo y entonces piper.exe ni arranca. Si falta, se
    # baja el instalador oficial, se comprueba que esta firmado por Microsoft y
    # se ejecuta (Windows pide permiso de administrador una vez).
    if (Test-VcRuntime) {
        Write-Host '    ya estaba instalado' -ForegroundColor DarkGray
        return
    }

    Write-Host '    falta el Visual C++ Redistributable que necesita Piper' -ForegroundColor Yellow
    $exe = Join-Path $env:TEMP 'vc_redist.x64.exe'
    Get-RemoteFile -Url $vcRedistUrl -Destination $exe

    $firma = Get-AuthenticodeSignature -LiteralPath $exe
    if ($firma.Status -ne 'Valid' -or $firma.SignerCertificate.Subject -notlike '*Microsoft Corporation*') {
        Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
        throw 'El instalador descargado del Visual C++ no esta firmado por Microsoft: no se ejecuta.'
    }

    Write-Host '    instalando (Windows pedira permiso de administrador)' -ForegroundColor Gray
    try {
        $proceso = Start-Process -FilePath $exe -ArgumentList '/install', '/quiet', '/norestart' -Verb RunAs -Wait -PassThru
    } catch {
        Write-Host ("    no se pudo ejecutar: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host '    instalalo a mano desde https://aka.ms/vs/17/release/vc_redist.x64.exe y vuelve a ejecutar esto' -ForegroundColor Yellow
        return
    } finally {
        Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
    }

    # 3010: instalado, pide reiniciar Windows (no hace falta para probar).
    if ($proceso.ExitCode -ne 0 -and $proceso.ExitCode -ne 3010) {
        Write-Host ("    el instalador del Visual C++ termino con el codigo {0}" -f $proceso.ExitCode) -ForegroundColor Yellow
    }
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

    try {
        $process = [Diagnostics.Process]::Start($psi)
        $process.StandardInput.WriteLine('Instalacion completa.')
        $process.StandardInput.Close()
        [void]$process.StandardOutput.ReadToEnd()
        [void]$process.WaitForExit(30000)
    } catch {
        Write-Host ("    piper.exe no arranco: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }

    $ok = (Test-Path -LiteralPath $probe) -and ((Get-Item -LiteralPath $probe).Length -gt 1000)

    if ($ok) {
        $duration = Get-WavDuration -Path $probe
        Write-Host ("    prueba correcta: {0:N1} segundos de audio" -f $duration) -ForegroundColor Green
    } else {
        Write-Host '    la prueba no genero audio' -ForegroundColor Red
        if (-not (Test-VcRuntime)) {
            Write-Host '    probable causa: falta el Visual C++ Redistributable (https://aka.ms/vs/17/release/vc_redist.x64.exe)' -ForegroundColor Yellow
        }
    }

    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    return $ok
}

# Lo que se ve aqui queda tambien en un archivo, para poder ver despues que fallo
# (por ejemplo, en el equipo de otra persona).
if (-not (Test-Path -LiteralPath $paths.RuntimeDir)) {
    New-Item -ItemType Directory -Path $paths.RuntimeDir -Force | Out-Null
}
$logFile = Join-Path $paths.RuntimeDir 'setup.log'
[void](Invoke-LogRotation -Path $logFile -MaxBytes 524288)
$transcript = $false
try { Start-Transcript -Path $logFile -Append -Force | Out-Null; $transcript = $true } catch { }

$exitCode = 0
try {
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

    Write-Step 'Visual C++ (lo que necesita Piper para arrancar)'
    Install-VcRuntime

    Write-Step 'Prueba de funcionamiento'
    if (-not (Test-Installation)) { throw 'La prueba de funcionamiento no genero audio.' }

    Write-Host ''
    Write-Host 'Todo listo.' -ForegroundColor Green
    if (-not $NoStartupPrompt) {
        Write-Host ''
        Write-Host 'Siguiente paso:' -ForegroundColor White
        Write-Host '  .\install_startup.ps1     deja los atajos activos al iniciar Windows'
        Write-Host ''
        Write-Host 'O pruebalo ahora mismo:'
        Write-Host '  .\read_aloud.ps1 -InputText "Hola, ya quedo funcionando."'
    }
} catch {
    $exitCode = 1
    Write-Host ''
    Write-Host 'La instalacion quedo incompleta:' -ForegroundColor Red
    Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    Write-Host 'Se puede reintentar: menu Inicio, "Instalar o reparar las voces", o .\setup.ps1' -ForegroundColor Yellow
    Write-Host ("El detalle queda en {0}" -f $logFile) -ForegroundColor Yellow
} finally {
    if ($transcript) { try { Stop-Transcript | Out-Null } catch { } }
}

if ($exitCode -ne 0 -and $PauseOnError) {
    Write-Host ''
    [void](Read-Host 'Pulsa Enter para cerrar esta ventana')
}
exit $exitCode
