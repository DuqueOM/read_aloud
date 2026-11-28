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
# Traduccion (docs\adr\0016-traduccion-local.md), lo que baja config\traduccion.psd1:
#   (sin nada)                   La basica (Bergamot, 112 MB), y repara la alta
#                                o el 7B si ya estaban
#   .\setup.ps1 -TranslationHigh Tambien la alta: Hy-MT2 1.8B y llama.cpp (1.17 GB)
#   .\setup.ps1 -Translation7B   Tambien Hy-MT2 7B (4.6 GB), para la tarjeta grafica
#   .\setup.ps1 -SkipTranslation Sin traduccion
#   .\setup.ps1 -OnlyTranslation Solo la traduccion, sin el motor ni las voces
#
# Diccionario del panel (docs\adr\0017-diccionario-en-el-panel.md), lo que
# baja config\idiomas.psd1:
#   (sin nada)                   Open English WordNet y WikDict en-es y es-en
#                                (14 MB), y arma el indice inverso es-en
#   .\setup.ps1 -SkipDictionary  Sin diccionario
#   .\setup.ps1 -OnlyDictionary  Solo el diccionario
#
#   .\setup.ps1 -LocalSource C:\carpeta   Toma los archivos de esa carpeta (con
#                                su nombre original) en vez de bajarlos; se
#                                comprueban igual
#
# Se descargan unos 200 MB la primera vez, mas la traduccion y el diccionario.
# Despues, nada. Todo lo que se ve aqui queda tambien en
# read_aloud_piper\runtime\setup.log.
#
# Codigo de salida: 0 todo bien; 1 el motor o las voces fallaron; 2 las voces
# estan bien pero alguna parte de la traduccion o del diccionario no se pudo
# instalar.
#
# Si algo falla, se puede volver a ejecutar sin riesgo: lo que ya esta no se
# descarga otra vez.

[CmdletBinding()]
param(
    [switch]$SkipEnglish,
    [switch]$Force,
    [switch]$NoStartupPrompt,
    [switch]$PauseOnError,
    [switch]$TranslationHigh,
    [switch]$Translation7B,
    [switch]$SkipTranslation,
    [switch]$OnlyTranslation,
    [switch]$SkipDictionary,
    [switch]$OnlyDictionary,
    [string]$LocalSource = '',
    # Para probar la instalacion en otra carpeta.
    [string]$PiperBaseDir = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\ReadAloud.Core.ps1')
. (Join-Path $PSScriptRoot 'lib\ReadAloud.Text.ps1')
. (Join-Path $PSScriptRoot 'lib\ReadAloud.Translate.ps1')
. (Join-Path $PSScriptRoot 'lib\ReadAloud.Translators.ps1')
. (Join-Path $PSScriptRoot 'lib\ReadAloud.Dictionary.ps1')

$paths = Get-ReadAloudPaths -PiperBaseDir $PiperBaseDir
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

    $directory = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    # Con -LocalSource, el archivo se toma de esa carpeta, con el nombre que
    # tiene en su origen (instalar sin conexion, o probar sin descargar).
    if ($LocalSource) {
        $local = Join-Path $LocalSource ([Uri]$Url).Segments[-1]
        if (Test-Path -LiteralPath $local) {
            Write-Host ("    copiando {0} de {1}" -f $name, $LocalSource) -ForegroundColor Gray
            Copy-Item -LiteralPath $local -Destination $Destination -Force
            return
        }
    }

    Write-Host ("    descargando {0}" -f $name) -ForegroundColor Gray

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
        throw ("No pude descargar {0}: {1}`nRevisa tu conexion a internet y que ningun firewall, proxy o antivirus bloquee {2}." -f $name, $last, ([Uri]$Url).Host)
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
    # En una carpeta de prueba (-PiperBaseDir) no corre nada nuestro: el lector
    # de esta carpeta sigue con sus procesos.
    if ($PiperBaseDir) { return }
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

# --------------------------------------------------------------------------
# Traduccion (docs\adr\0016-traduccion-local.md).
# --------------------------------------------------------------------------
$translateCatalog = Read-PowerShellDataFile -Path (Join-Path $paths.ConfigDir 'traduccion.psd1')

# Opciones de marian para los modelos de Mozilla (las que usa Firefox).
# translateLocally busca los modelos en una carpeta models junto al .exe; cada
# modelo es una carpeta con model_info.json y config.intgemm8bitalpha.yml.
$bergamotConfig = @'
models:
  - {0}
vocabs:
  - {1}
  - {1}
shortlist:
  - {2}
  - false
beam-size: 1
normalize: 1.0
word-penalty: 0
max-length-break: 128
mini-batch-words: 1024
workspace: 128
max-length-factor: 2.0
skip-cost: true
cpu-threads: 0
quiet: true
quiet-translation: true
gemm-precision: int8shiftAlphaAll
alignment: soft
'@

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-TranslationItem {
    # Si una pieza ya esta instalada. Un archivo copiado tal cual se compara
    # por su tamano; uno descomprimido, solo con que exista; un zip, con que
    # este llama-server.exe.
    param([hashtable]$Item)

    $destino = Join-Path $paths.TranslateDir $Item.Destino
    switch ($Item.Tipo) {
        'zip' { return Test-Path -LiteralPath (Join-Path $destino 'llama-server.exe') }
        'gz' { return Test-Path -LiteralPath $destino }
        default { return (Test-Path -LiteralPath $destino) -and ((Get-Item -LiteralPath $destino).Length -eq [long]$Item.Bytes) }
    }
}

function Assert-FreeSpace {
    # Antes de bajar algo grande: el disco necesita el archivo, lo que ocupa
    # al descomprimirlo y un margen.
    param([long]$Bytes)

    $raiz = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($paths.BaseDir))
    $libre = (New-Object IO.DriveInfo($raiz)).AvailableFreeSpace
    $necesita = (2 * $Bytes) + 512MB
    if ($libre -lt $necesita) {
        throw ('No hay sitio en el disco {0}: hacen falta {1:N1} GB y quedan {2:N1} GB.' -f $raiz, ($necesita / 1GB), ($libre / 1GB))
    }
}

function Install-TranslationItem {
    # Baja (o copia de -LocalSource) una pieza, comprueba su sha256 y la deja
    # en su sitio. Lo que no coincide no se instala.
    param([hashtable]$Item)

    $destino = Join-Path $paths.TranslateDir $Item.Destino
    $nombre = ([Uri]$Item.Url).Segments[-1]
    if ((Test-TranslationItem -Item $Item) -and -not $Force) {
        Write-Host ("    {0} ya estaba" -f $nombre) -ForegroundColor DarkGray
        return
    }

    Assert-FreeSpace -Bytes ([long]$Item.Bytes)
    $trabajo = Join-Path $paths.TranslateDir ('_descarga_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $trabajo -Force | Out-Null
    try {
        $bajado = Join-Path $trabajo $nombre
        Get-RemoteFile -Url $Item.Url -Destination $bajado

        Write-Host '    comprobando el sha256' -ForegroundColor Gray
        $hash = Get-FileSha256 -Path $bajado
        if ($hash -ne ([string]$Item.Sha256).ToLowerInvariant()) {
            throw ("{0} no es el archivo esperado (sha256 {1}, se esperaba {2}). No se instala." -f $nombre, $hash, $Item.Sha256)
        }

        $carpeta = Split-Path -Parent $destino
        if ($Item.Tipo -ne 'zip' -and -not (Test-Path -LiteralPath $carpeta)) { New-Item -ItemType Directory -Path $carpeta -Force | Out-Null }

        switch ($Item.Tipo) {
            'gz' {
                $parcial = $destino + '.part'
                $entrada = [IO.File]::OpenRead($bajado)
                try {
                    $gz = New-Object IO.Compression.GZipStream($entrada, [IO.Compression.CompressionMode]::Decompress)
                    $salida = [IO.File]::Create($parcial)
                    try { $gz.CopyTo($salida) } finally { $salida.Dispose(); $gz.Dispose() }
                } finally {
                    $entrada.Dispose()
                }
                Move-Item -LiteralPath $parcial -Destination $destino -Force
            }
            'zip' {
                # Se extrae aparte y se cambia de golpe: un llama.cpp a medias
                # no sirve. Si el lector lo tiene abierto, se cierra antes.
                $extraido = Join-Path $trabajo 'zip'
                Expand-Archive -LiteralPath $bajado -DestinationPath $extraido -Force
                if (-not (Test-Path -LiteralPath (Join-Path $extraido 'llama-server.exe'))) { throw 'El paquete de llama.cpp no trae llama-server.exe.' }
                Stop-TranslatorsInUse
                if (Test-Path -LiteralPath $destino) { Remove-Item -LiteralPath $destino -Recurse -Force }
                Move-Item -LiteralPath $extraido -Destination $destino
            }
            default {
                if ($Item.Id -eq 'translatelocally') { Stop-TranslatorsInUse }
                Move-Item -LiteralPath $bajado -Destination $destino -Force
            }
        }
        Write-Host ("    {0} instalado" -f $nombre) -ForegroundColor DarkGray
    } finally {
        if (Test-Path -LiteralPath $trabajo) { Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Stop-TranslatorsInUse {
    # Un llama-server o translateLocally de esta carpeta tiene sus archivos
    # abiertos: se cierran, y el lector los vuelve a abrir cuando hagan falta.
    try { [void](Stop-OrphanTranslators -TranslateDir $paths.TranslateDir) } catch { }
}

function Initialize-BergamotModels {
    # Los dos modelos de Mozilla como modelos de translateLocally.
    $nombres = @{ en = 'English'; es = 'Spanish' }
    foreach ($par in @('en-es', 'es-en')) {
        $origen, $destino = $par -split '-'
        $carpeta = Join-Path $paths.TranslateDir "translateLocally\models\$par-base-memory"
        $archivos = @(Get-ChildItem -LiteralPath $carpeta -File)
        $modelo = ($archivos | Where-Object { $_.Name -like 'model.*' } | Select-Object -First 1).Name
        $vocab = ($archivos | Where-Object { $_.Name -like 'vocab.*' } | Select-Object -First 1).Name
        $lex = ($archivos | Where-Object { $_.Name -like 'lex.*' } | Select-Object -First 1).Name
        if (-not $modelo -or -not $vocab -or -not $lex) { throw "Faltan archivos del modelo $par de Bergamot." }

        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $carpeta 'config.intgemm8bitalpha.yml'), ($bergamotConfig -f $modelo, $vocab, $lex), $utf8)
        $info = [ordered]@{
            modelName = '{0}-{1} base-memory' -f $nombres[$origen], $nombres[$destino]
            shortName = "$par-base-memory"
            type      = 'base-memory'
            src       = $nombres[$origen]
            trg       = $nombres[$destino]
            srcTags   = @{ $origen = $nombres[$origen] }
            trgTag    = $destino
            version   = 1
            API       = 1
        }
        [IO.File]::WriteAllText((Join-Path $carpeta 'model_info.json'), (ConvertTo-Json -InputObject $info), $utf8)
    }
}

function Test-BergamotWorks {
    # Una traduccion de prueba con translateLocally, como la hara el lector.
    $exe = Join-Path $paths.TranslateDir 'translateLocally\translateLocally.exe'
    $cliente = $null
    try {
        $cliente = Start-BergamotProcess -Exe $exe -Threads (Get-TranslatorThreads -PhysicalCores (Get-PhysicalCoreCount))
        $texto = Invoke-BergamotTranslate -Client $cliente -Text 'The installation is complete.' -Source 'en' -Target 'es' -TimeoutMs 60000
        Write-Host ("    prueba correcta: ""{0}""" -f $texto) -ForegroundColor Green
        return $true
    } catch {
        Write-Host ("    la prueba de la traduccion fallo: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return $false
    } finally {
        if ($null -ne $cliente) { Stop-TranslatorProcess -Process $cliente.Process -Stdin $cliente.In }
    }
}

function Install-TranslationLevel {
    # Instala un nivel entero. Devuelve $true si quedo bien; si algo falla lo
    # dice y sigue: la lectura no depende de la traduccion.
    param([string]$Nombre, [object[]]$Items)

    try {
        foreach ($item in $Items) { Install-TranslationItem -Item $item }
        return $true
    } catch {
        Write-Host ("    no se pudo instalar {0}: {1}" -f $Nombre, $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
}

function Install-Translation {
    # La basica siempre (salvo -SkipTranslation). La alta y el 7B si se piden
    # o si ya estaban, para que "Instalar o reparar" tambien los repare.
    $ok = $true
    if (-not (Test-Path -LiteralPath $paths.TranslateDir)) { New-Item -ItemType Directory -Path $paths.TranslateDir -Force | Out-Null }

    Write-Step 'Traduccion basica (Bergamot, unos 112 MB)'
    if (Install-TranslationLevel -Nombre 'la traduccion basica' -Items @($translateCatalog.Basica)) {
        try {
            Initialize-BergamotModels
            if (-not (Test-BergamotWorks)) { $ok = $false }
        } catch {
            Write-Host ("    no se pudieron preparar los modelos de Bergamot: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            $ok = $false
        }
    } else {
        $ok = $false
    }

    $modelos = Join-Path $paths.TranslateDir 'modelos'
    $tenia18 = Test-Path -LiteralPath (Join-Path $modelos 'Hy-MT2-1.8B-Q4_K_M.gguf')
    $tenia7 = Test-Path -LiteralPath (Join-Path $modelos 'Hy-MT2-7B-Q4_K_M.gguf')
    $teniaLlama = Test-Path -LiteralPath (Join-Path $paths.TranslateDir 'llama\llama-server.exe')

    if ($TranslationHigh -or $Translation7B -or $tenia18 -or $teniaLlama) {
        Write-Step 'Traduccion alta (Hy-MT2 1.8B y llama.cpp, unos 1.17 GB)'
        Write-Host '    Hy-MT2 de Tencent, licencia Apache 2.0: https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF' -ForegroundColor DarkGray
        if (-not (Install-TranslationLevel -Nombre 'la traduccion alta' -Items @($translateCatalog.Alta))) { $ok = $false }
    }
    if ($Translation7B -or $tenia7) {
        Write-Step 'Hy-MT2 7B para la tarjeta grafica (unos 4.6 GB)'
        Write-Host '    licencia Apache 2.0: https://huggingface.co/tencent/Hy-MT2-7B-GGUF' -ForegroundColor DarkGray
        if (-not (Install-TranslationLevel -Nombre 'Hy-MT2 7B' -Items @($translateCatalog.Modelo7B))) { $ok = $false }
    }
    return $ok
}

# --------------------------------------------------------------------------
# Diccionario del panel (docs\adr\0017-diccionario-en-el-panel.md).
# --------------------------------------------------------------------------
$dictionaryCatalog = Read-PowerShellDataFile -Path (Join-Path $paths.ConfigDir 'idiomas.psd1')

function Install-DictionaryItem {
    # Baja (o copia de -LocalSource) una pieza del diccionario y la instala
    # con Install-DictionaryPiece, que comprueba el sha256 antes de extraer:
    # lo que no coincide no se instala.
    param([hashtable]$Item)

    $nombre = ([Uri]$Item.Url).Segments[-1]
    if ((Test-DictionaryPiece -Piece $Item -DictionaryDir $paths.DictionaryDir) -and -not $Force) {
        Write-Host ("    {0} ya estaba" -f $nombre) -ForegroundColor DarkGray
        return
    }

    Assert-FreeSpace -Bytes ([long]$Item.Bytes)
    $trabajo = Join-Path $paths.DictionaryDir ('_descarga_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $trabajo -Force | Out-Null
    try {
        $bajado = Join-Path $trabajo $nombre
        Get-RemoteFile -Url $Item.Url -Destination $bajado
        Write-Host '    comprobando el sha256 y descomprimiendo' -ForegroundColor Gray
        Install-DictionaryPiece -ZipPath $bajado -Piece $Item -DictionaryDir $paths.DictionaryDir
        Write-Host ("    {0} instalado en diccionario\{1}" -f $nombre, $Item.Destino) -ForegroundColor DarkGray
    } finally {
        if (Test-Path -LiteralPath $trabajo) { Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Install-Dictionary {
    # Cada pieza por su lado: si una falla, las otras se instalan igual. Al
    # final, los indices inversos cuyo diccionario de origen quedo instalado.
    # Devuelve $true si quedo todo.
    Write-Step 'Diccionario del panel (Open English WordNet y WikDict, unos 14 MB)'
    Write-Host '    Open English WordNet, licencia CC BY 4.0: https://en-word.net' -ForegroundColor DarkGray
    Write-Host '    WikDict de Karl Bartel, con datos de Wiktionary via DBnary, licencia CC BY-SA 4.0: https://www.wikdict.com' -ForegroundColor DarkGray
    if (-not (Test-Path -LiteralPath $paths.DictionaryDir)) { New-Item -ItemType Directory -Path $paths.DictionaryDir -Force | Out-Null }

    $ok = $true
    $piezas = @(Get-DictionaryPieces -Catalog $dictionaryCatalog)
    foreach ($p in $piezas) {
        try {
            Install-DictionaryItem -Item $p
        } catch {
            Write-Host ("    no se pudo instalar {0}: {1}" -f $p.Id, $_.Exception.Message) -ForegroundColor Yellow
            $ok = $false
        }
    }

    foreach ($i in @(Get-DictionaryReverseIndexes -Catalog $dictionaryCatalog -DictionaryDir $paths.DictionaryDir)) {
        $origen = @($piezas | Where-Object { $_.Pair -eq $i.From })[0]
        if ($null -eq $origen -or -not (Test-DictionaryPiece -Piece $origen -DictionaryDir $paths.DictionaryDir)) {
            Write-Host ("    sin el indice inverso {0}: falta el diccionario {1}" -f $i.Pair, $i.From) -ForegroundColor Yellow
            $ok = $false
            continue
        }
        if ((Test-DictionaryReverseIndex -Index $i -Source $origen) -and -not $Force) {
            Write-Host ("    el indice inverso {0} ya estaba" -f $i.Pair) -ForegroundColor DarkGray
            continue
        }
        Write-Host ("    armando el indice inverso {0} con {1} (unos 20 segundos)" -f $i.Pair, $i.From) -ForegroundColor Gray
        try {
            $reloj = [Diagnostics.Stopwatch]::StartNew()
            $claves = Install-DictionaryReverseIndex -Index $i -Source $origen -DictionaryDir $paths.DictionaryDir
            Write-Host ("    indice inverso {0}: {1} palabras en {2:N1} s" -f $i.Pair, $claves, $reloj.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        } catch {
            Write-Host ("    no se pudo armar el indice inverso {0}: {1}" -f $i.Pair, $_.Exception.Message) -ForegroundColor Yellow
            $ok = $false
        }
    }
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

    if (-not $OnlyTranslation -and -not $OnlyDictionary) {
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
    }

    # La traduccion va despues de las voces: si falla, la lectura funciona.
    if (-not $SkipTranslation -and -not $OnlyDictionary) {
        if (-not (Install-Translation)) {
            $exitCode = 2
            Write-Host ''
            Write-Host 'La lectura funciona, pero alguna parte de la traduccion no se pudo instalar (arriba esta el motivo).' -ForegroundColor Yellow
            Write-Host 'Se puede reintentar: menu Inicio, "Instalar o reparar las voces", o .\setup.ps1' -ForegroundColor Yellow
        }
    }

    # El diccionario, al final: si falla, la lectura y la traduccion funcionan.
    if (-not $SkipDictionary -and -not $OnlyTranslation) {
        if (-not (Install-Dictionary)) {
            $exitCode = 2
            Write-Host ''
            Write-Host 'La lectura funciona, pero alguna parte del diccionario no se pudo instalar (arriba esta el motivo).' -ForegroundColor Yellow
            Write-Host 'Se puede reintentar: menu Inicio, "Instalar o reparar las voces", o .\setup.ps1' -ForegroundColor Yellow
        }
    }

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
