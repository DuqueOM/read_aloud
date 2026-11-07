#
# crear_icono.ps1
# Dibuja el icono de Read Aloud en read_aloud_piper\read_aloud.ico, para los
# accesos directos. Lo ejecuta el instalador; no hace falta hacerlo a mano.

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\ReadAloud.Core.ps1')
. (Join-Path $PSScriptRoot 'lib\ReadAloud.Theme.ps1')

$paths = Get-ReadAloudPaths
Save-AppIconFile -Path (Join-Path $paths.BaseDir 'read_aloud.ico')
