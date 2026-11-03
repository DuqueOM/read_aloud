#
# run_psscriptanalyzer.ps1
# Corre PSScriptAnalyzer con PSScriptAnalyzerSettings.psd1, de la raiz del
# repositorio, y sale con 1 solo si hay reglas de severidad Error. Las
# advertencias se muestran, pero no bloquean.
#
#   .\tools\run_psscriptanalyzer.ps1 archivo1.ps1 ...   Esos archivos (asi lo llama pre-commit)
#   .\tools\run_psscriptanalyzer.ps1                    Todos los .ps1, .psm1 y .psd1 versionados
#   .\tools\run_psscriptanalyzer.ps1 -Informe ruta.md   Ademas, una tabla de lo encontrado

# Sin posiciones: todo lo que llega sin nombre son archivos.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Archivos = @(),
    [string]$Informe = ''
)

$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $PSScriptRoot
$ajustes = Join-Path $raiz 'PSScriptAnalyzerSettings.psd1'

# Lanzado desde PowerShell 7 (o desde pre-commit dentro de el), Windows
# PowerShell hereda una ruta de modulos sin la carpeta del usuario, donde
# Install-Module -Scope CurrentUser deja PSScriptAnalyzer.
$edicion = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
$deUsuario = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "$edicion\Modules"
if (($env:PSModulePath -split ';') -notcontains $deUsuario) { $env:PSModulePath = "$deUsuario;$env:PSModulePath" }

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Write-Host 'Falta PSScriptAnalyzer: Install-Module PSScriptAnalyzer -Scope CurrentUser'
    exit 1
}
Import-Module PSScriptAnalyzer

if ($Archivos.Count -eq 0) {
    $Archivos = @(& git -C $raiz ls-files '*.ps1' '*.psm1' '*.psd1' | ForEach-Object { Join-Path $raiz $_ })
}

$hallazgos = @(foreach ($archivo in $Archivos) {
    if (Test-Path -LiteralPath $archivo -PathType Leaf) {
        Invoke-ScriptAnalyzer -Path $archivo -Settings $ajustes
    }
})

foreach ($h in $hallazgos) {
    $ruta = Resolve-Path -LiteralPath $h.ScriptPath -Relative
    Write-Host ("{0}:{1}: {2} {3}: {4}" -f $ruta, $h.Line, $h.Severity, $h.RuleName, $h.Message)
}

$errores = @($hallazgos | Where-Object { $_.Severity -eq 'Error' }).Count
$avisos = @($hallazgos | Where-Object { $_.Severity -eq 'Warning' }).Count

if ($Informe) {
    $lineas = @('| Regla | Severidad | Veces | Archivos |', '|---|---|---|---|')
    foreach ($g in ($hallazgos | Group-Object RuleName, Severity | Sort-Object Count -Descending)) {
        $archivosRegla = ($g.Group | ForEach-Object { Split-Path -Leaf $_.ScriptPath } | Sort-Object -Unique) -join ', '
        $lineas += '| {0} | {1} | {2} | {3} |' -f $g.Group[0].RuleName, $g.Group[0].Severity, $g.Count, $archivosRegla
    }
    $lineas += ''
    $lineas += "Errores: $errores. Advertencias: $avisos."
    [IO.File]::WriteAllText($Informe, ($lineas -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
}

Write-Host "PSScriptAnalyzer: $errores errores, $avisos advertencias."
if ($errores -gt 0) { exit 1 }
exit 0
