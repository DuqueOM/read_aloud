#
# run_pester.ps1
# Corre las pruebas de tests\ con Pester 5. Sale con codigo distinto de 0 si
# alguna falla.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_pester.ps1
#   ... -Resultados pester.xml     Ademas guarda los resultados en JUnit
#
# Pester 5 se instala una sola vez, en el usuario:
#   Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck

[CmdletBinding()]
param([string]$Resultados = '')

$ErrorActionPreference = 'Stop'

# Un proceso lanzado desde PowerShell 7 hereda su ruta de modulos, que no
# incluye la carpeta de modulos del usuario de Windows PowerShell.
$edicion = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
$deUsuario = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "$edicion\Modules"
if (($env:PSModulePath -split ';') -notcontains $deUsuario) { $env:PSModulePath = "$deUsuario;$env:PSModulePath" }

# Windows trae Pester 3.4, que no entiende estas pruebas.
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    Write-Error 'Falta Pester 5: Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck'
    exit 1
}
Import-Module $pester.Path -Force

$config = New-PesterConfiguration
$config.Run.Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests'
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
if ($Resultados) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'JUnitXml'
    $config.TestResult.OutputPath = $Resultados
}

Invoke-Pester -Configuration $config
