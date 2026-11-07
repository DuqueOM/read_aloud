# Version, actualizaciones y diagnostico.
#
# La logica (comparar versiones, elegir el instalador de un release, comprobar
# su SHA-256, armar el texto del diagnostico) no toca la red ni la ventana y se
# prueba con Pester. Lo que si toca la red se limita a Get-LatestRelease y a
# Save-ReleaseInstaller, y solo se llaman cuando el usuario pulsa el boton:
# Read Aloud no consulta nada por su cuenta ni envia ningun dato.
#
# Solo ASCII: el archivo se carga tambien desde Windows PowerShell 5.1.

$script:RA_Repo = 'DuqueOM/read_aloud'

function Get-ReadAloudVersion {
    # El archivo VERSION de la raiz tiene el numero ("1.2.0"; con "-dev" entre
    # releases). Si falta, 0.0.0.
    param([string]$Root)

    $file = Join-Path $Root 'VERSION'
    if (Test-Path -LiteralPath $file) {
        $text = (Get-Content -LiteralPath $file -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($text) { return ([string]$text).Trim() }
    }
    return '0.0.0'
}

function ConvertTo-ReleaseVersion {
    # "v1.2.0" o "1.2.0-dev" -> @{ Version = [version]'1.2.0'; Pre = '-dev' }
    param([string]$Text)

    if ($Text -match '^\s*v?(\d+)\.(\d+)\.(\d+)(.*)$') {
        return @{ Version = [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3]); Pre = $Matches[4].Trim() }
    }
    return $null
}

function Test-NewerVersion {
    # Verdadero si $Latest es posterior a $Current. Una version con sufijo
    # ("1.2.0-dev") va antes que la misma sin sufijo ("1.2.0").
    param([string]$Current, [string]$Latest)

    $c = ConvertTo-ReleaseVersion $Current
    $l = ConvertTo-ReleaseVersion $Latest
    if ($null -eq $c -or $null -eq $l) { return $false }

    if ($l.Version -gt $c.Version) { return $true }
    if ($l.Version -lt $c.Version) { return $false }
    return ($c.Pre -ne '' -and $l.Pre -eq '')
}

function Select-InstallerAsset {
    # De un release de GitHub (ya convertido desde JSON) saca el instalador y
    # su suma SHA-256. Devuelve $null si el release no trae instalador.
    param($Release)

    $exe = $null
    $sha = $null
    foreach ($a in @($Release.assets)) {
        if ($a.name -like 'ReadAloud-Setup-*.exe') { $exe = $a }
        elseif ($a.name -like 'ReadAloud-Setup-*.exe.sha256') { $sha = $a }
    }
    if ($null -eq $exe) { return $null }
    return @{ Name = $exe.name; Url = $exe.browser_download_url; Size = [long]$exe.size; ShaUrl = $(if ($sha) { $sha.browser_download_url } else { '' }) }
}

function Get-ExpectedHash {
    # El .sha256 tiene "hash  nombre". Devuelve el hash en minusculas, o ''.
    param([string]$Text)

    if ($Text -match '(?i)\b([0-9a-f]{64})\b') { return $Matches[1].ToLowerInvariant() }
    return ''
}

function Test-FileHash {
    param([string]$Path, [string]$Expected)

    if ($Expected -eq '' -or -not (Test-Path -LiteralPath $Path)) { return $false }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return ($actual -eq $Expected.ToLowerInvariant())
}

function Get-ReleaseNotesSummary {
    # Las primeras lineas de las notas, sin el formato de Markdown.
    param([string]$Body, [int]$MaxLines = 12)

    if ([string]::IsNullOrWhiteSpace($Body)) { return '' }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($raw in ($Body -split "`r?`n")) {
        $line = ($raw -replace '^\s*#{1,6}\s*', '' -replace '\*\*', '' -replace '`', '').TrimEnd()
        if ($line.Trim() -eq '') { continue }
        $lines.Add($line)
        if ($lines.Count -ge $MaxLines) { break }
    }
    return ($lines -join "`n")
}

function Get-LatestRelease {
    # Consulta el ultimo release publicado. Solo al pulsar "Buscar
    # actualizaciones". Devuelve el objeto de la API o lanza el error.
    param([string]$Repo = $script:RA_Repo, [int]$TimeoutSec = 10)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'ReadAloud'; 'Accept' = 'application/vnd.github+json' }
    return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers -TimeoutSec $TimeoutSec
}

function Save-ReleaseInstaller {
    # Descarga el instalador a la carpeta temporal y comprueba su SHA-256 con el
    # .sha256 del release. Devuelve la ruta; si la suma no coincide (o no hay),
    # borra el archivo y lanza el error: nunca se ejecuta algo sin verificar.
    param($Asset, [int]$TimeoutSec = 120)

    if ($Asset.ShaUrl -eq '') { throw 'El release no trae la suma SHA-256 del instalador; no se descarga.' }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'ReadAloud' }

    $dir = Join-Path ([IO.Path]::GetTempPath()) ('ReadAloud-update-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir $Asset.Name

    $shaText = Invoke-RestMethod -Uri $Asset.ShaUrl -Headers $headers -TimeoutSec 20
    $expected = Get-ExpectedHash ([string]$shaText)

    Invoke-WebRequest -Uri $Asset.Url -Headers $headers -OutFile $file -TimeoutSec $TimeoutSec -UseBasicParsing

    if (-not (Test-FileHash -Path $file -Expected $expected)) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        throw 'La suma SHA-256 del instalador no coincide: se descarto la descarga.'
    }
    return $file
}

function Get-DiagnosticText {
    # Texto para pegar en una incidencia: version, sistema, motores, atajos y
    # el final del registro. No lleva textos leidos ni rutas personales.
    param(
        [string]$Version,
        $Engines,
        $HotkeyReport,
        [string[]]$LogTail = @()
    )

    $os = [Environment]::OSVersion.Version
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Read Aloud $Version")
    $lines.Add(('Windows {0}.{1}.{2}, PowerShell {3}' -f $os.Major, $os.Minor, $os.Build, $PSVersionTable.PSVersion))
    if ($null -ne $Engines) {
        $lines.Add(('Motores: es={0}, en={1}' -f $Engines['es'], $Engines['en']))
    }
    if ($null -ne $HotkeyReport) {
        $lines.Add('Atajos:')
        foreach ($e in $HotkeyReport) {
            $state = if ($e.Active) { 'activo' } elseif ($e.Reason) { $e.Reason } else { 'no' }
            $lines.Add(('  {0}: {1} ({2})' -f $e.Action, $e.Text, $state))
        }
    }
    if ($LogTail.Count -gt 0) {
        $lines.Add('Registro (ultimas lineas):')
        foreach ($l in $LogTail) { $lines.Add('  ' + $l) }
    }

    # Las rutas de usuario no hacen falta para diagnosticar.
    $text = $lines -join "`r`n"
    if ($env:USERPROFILE) { $text = $text.Replace($env:USERPROFILE, '%USERPROFILE%') }
    return $text
}
