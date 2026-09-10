#
# Detiene la lectura en curso.
#
# Manda la orden al proceso residente, que corta el audio y esconde el
# reproductor. Si el proceso no responde, cae al metodo antiguo de cerrar
# procesos a la fuerza.

$ErrorActionPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'lib\ReadAloud.Core.ps1')

$paths = Get-ReadAloudPaths
$answer = Send-ReadAloudCommand -PipeName $paths.PipeName -Command @{ cmd = 'stop' } -TimeoutMs 400

if ($null -ne $answer) { exit 0 }

# Se exige que sea un powershell.exe lanzado con -File sobre uno de los
# scripts de esta carpeta. Un filtro mas amplio cierra consolas ajenas que
# solo mencionan la ruta.
$scriptRoot = $paths.Root

Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -eq 'powershell.exe' -and
        $_.ProcessId -ne $PID -and
        $_.CommandLine -like ('*-File*' + $scriptRoot + 'ead_aloud*.ps1*')
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

Get-Process -Name 'piper' | Stop-Process -Force
