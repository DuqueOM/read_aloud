#
# check_terms.ps1
# Busca terminos prohibidos: los que delatarian de donde salio una voz de
# prueba, o rutas y datos de un equipo concreto. La lista no se versiona: vive
# en tools\terminos.local.txt (o la que se pase con -Lista), una expresion
# regular por linea, en minusculas y sin acentos. El texto se compara tambien
# en minusculas y sin acentos.
#
#   .\tools\check_terms.ps1 archivo1 archivo2   Esos archivos (asi lo llama pre-commit)
#   .\tools\check_terms.ps1 -Arbol              Todo lo versionado
#   .\tools\check_terms.ps1 -Historial          Parches, mensajes y nombres de todos los commits
#
# Sale con 1 si encuentra algo. Sin lista, avisa y sale con 0: en un equipo que
# no la tiene no hay nada que buscar.

# Sin posiciones: todo lo que llega sin nombre son archivos, como los pasa
# pre-commit.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Archivos = @(),
    [switch]$Arbol,
    [switch]$Historial,
    [string]$Lista = '',
    [string]$Repo = ''
)

$ErrorActionPreference = 'Stop'

# En Windows PowerShell 5.1, $PSScriptRoot no existe todavia en los valores
# por defecto de param: se completan aqui.
if (-not $Lista) { $Lista = Join-Path $PSScriptRoot 'terminos.local.txt' }
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }

if (-not (Test-Path -LiteralPath $Lista)) {
    Write-Host "check_terms: no hay lista de terminos ($Lista); no se revisa nada."
    exit 0
}

$terminos = @(Get-Content -LiteralPath $Lista -Encoding UTF8 |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') })
$opciones = [Text.RegularExpressions.RegexOptions]::CultureInvariant
$expresiones = @($terminos | ForEach-Object { New-Object Text.RegularExpressions.Regex($_, $opciones) })
# Una sola expresion con todos, para descartar rapido las lineas limpias.
$todas = New-Object Text.RegularExpressions.Regex((($terminos | ForEach-Object { "(?:$_)" }) -join '|'), $opciones)

function ConvertTo-Plano {
    param([string]$Texto)
    $descompuesto = $Texto.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($c in $descompuesto.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString()
}

$script:hallados = 0

function Test-Lineas {
    param([string[]]$Lineas, [string]$Donde)
    $n = 0
    foreach ($linea in $Lineas) {
        $n++
        $plano = ConvertTo-Plano $linea
        if (-not $todas.IsMatch($plano)) { continue }
        foreach ($rx in $expresiones) {
            if ($rx.IsMatch($plano)) {
                $script:hallados++
                $corta = $linea.Trim()
                if ($corta.Length -gt 140) { $corta = $corta.Substring(0, 140) }
                Write-Host ("{0}:{1}: [{2}] {3}" -f $Donde, $n, $rx.ToString(), $corta)
            }
        }
    }
}

function Get-Git {
    param([string[]]$Argumentos)
    $salida = & git -C $Repo -c core.quotepath=off @Argumentos
    if ($LASTEXITCODE -ne 0) { throw "Fallo: git $($Argumentos -join ' ')" }
    return $salida
}

# La lista y este script no se revisan a si mismos.
$propios = @($Lista, $PSCommandPath) | ForEach-Object { [IO.Path]::GetFullPath($_) }

if ($Arbol) {
    $Archivos += @(Get-Git @('ls-files') | ForEach-Object { Join-Path $Repo $_ })
}

foreach ($archivo in $Archivos) {
    $ruta = [IO.Path]::GetFullPath($archivo)
    if ($propios -contains $ruta -or -not (Test-Path -LiteralPath $ruta -PathType Leaf)) { continue }
    $bytes = [IO.File]::ReadAllBytes($ruta)
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { continue }   # binario
    $texto = (New-Object Text.UTF8Encoding($false)).GetString($bytes)
    Test-Lineas -Lineas ($texto -split "`r?`n") -Donde $archivo
}

if ($Historial) {
    # Solo las lineas que cada commit agrega o quita, con su commit y archivo.
    $commit = ''; $archivo = ''
    foreach ($linea in (Get-Git @('log', '--all', '-p', '--no-color', '--format=COMMIT %h'))) {
        if ($linea.StartsWith('COMMIT ')) { $commit = $linea.Substring(7); continue }
        if ($linea.StartsWith('+++ b/')) { $archivo = $linea.Substring(6); continue }
        if ($linea.StartsWith('+++') -or $linea.StartsWith('---')) { continue }
        if ($linea.StartsWith('+') -or $linea.StartsWith('-')) {
            Test-Lineas -Lineas @($linea.Substring(1)) -Donde "$commit $archivo"
        }
    }
    Test-Lineas -Lineas (Get-Git @('log', '--all', '--format=%h %B')) -Donde 'mensajes'
    Test-Lineas -Lineas (Get-Git @('log', '--all', '--name-only', '--format=') | Sort-Object -Unique) -Donde 'nombres de archivo'
    Test-Lineas -Lineas (Get-Git @('for-each-ref', '--format=%(refname)')) -Donde 'ramas y etiquetas'
}

if ($script:hallados -gt 0) {
    Write-Host "check_terms: $($script:hallados) coincidencias."
    exit 1
}
Write-Host 'check_terms: sin coincidencias.'
exit 0
