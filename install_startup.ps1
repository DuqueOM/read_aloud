#
# install_startup.ps1
# Deja Read Aloud funcionando desde que inicias sesion en Windows.
#
#   .\install_startup.ps1              Instala el arranque automatico
#   .\install_startup.ps1 -Uninstall   Lo quita
#
# Los atajos de teclado ya no necesitan AutoHotkey: los registra el propio
# proceso residente, que ademas pone su icono en la bandeja del sistema.
# No necesita permisos de administrador: todo queda en la carpeta de Inicio
# de tu usuario.

[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\ReadAloud.Core.ps1')

$paths = Get-ReadAloudPaths
$startupDir = [Environment]::GetFolderPath('Startup')

$hotkeyLink = Join-Path $startupDir 'Read Aloud (atajos).lnk'
$daemonLink = Join-Path $startupDir 'Read Aloud (motor de voz).lnk'
$launcherVbs = Join-Path $paths.RuntimeDir 'start_daemon_hidden.vbs'

function Remove-StartupEntries {
    foreach ($link in @($hotkeyLink, $daemonLink)) {
        if (Test-Path -LiteralPath $link) {
            Remove-Item -LiteralPath $link -Force
            Write-Host ("    quitado: {0}" -f (Split-Path -Leaf $link)) -ForegroundColor Gray
        }
    }
}

function Remove-LegacyHotkeys {
    # Hasta la 1.1 los atajos los daba un script de AutoHotkey con su propio
    # acceso directo en Inicio. Se quita para que no pelee con los nuevos por
    # las mismas teclas.
    if (Test-Path -LiteralPath $hotkeyLink) {
        Remove-Item -LiteralPath $hotkeyLink -Force
        Write-Host '    quitado el acceso directo de AutoHotkey (ya no hace falta)' -ForegroundColor Gray
    }

    Get-CimInstance Win32_Process |
        Where-Object { $_.CommandLine -like '*read_aloud_hotkey.ahk*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function New-Shortcut {
    param(
        [string]$Path,
        [string]$Target,
        [string]$Arguments,
        [string]$Description
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $Target
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $paths.Root
    $shortcut.Description = $Description
    $shortcut.WindowStyle = 7
    $shortcut.Save()
}

if ($Uninstall) {
    Write-Host 'Quitando el arranque automatico' -ForegroundColor Cyan
    Remove-StartupEntries

    if (Test-Path -LiteralPath $launcherVbs) {
        Remove-Item -LiteralPath $launcherVbs -Force
    }

    Send-ReadAloudCommand -PipeName $paths.PipeName -Command @{ cmd = 'quit' } | Out-Null

    Write-Host 'Listo. Read Aloud ya no se inicia solo.' -ForegroundColor Green
    exit 0
}

Write-Host 'Instalando el arranque automatico' -ForegroundColor Cyan
Remove-StartupEntries

if (-not (Test-Path -LiteralPath $paths.RuntimeDir)) {
    New-Item -ItemType Directory -Path $paths.RuntimeDir -Force | Out-Null
}

# PowerShell con -WindowStyle Hidden todavia parpadea una consola al arrancar.
# Este lanzador de una linea la evita del todo.
$vbsContent = @"
' Arranca el proceso residente de Read Aloud sin mostrar ninguna ventana.
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$($paths.DaemonScript)""", 0, False
"@

Set-Content -LiteralPath $launcherVbs -Value $vbsContent -Encoding ASCII

New-Shortcut -Path $daemonLink -Target 'wscript.exe' -Arguments ('"' + $launcherVbs + '"') `
    -Description 'Mantiene las voces cargadas para que la lectura empiece al instante'

Write-Host ('    instalado: {0}' -f (Split-Path -Leaf $daemonLink)) -ForegroundColor Gray

Remove-LegacyHotkeys

Write-Host ''
Write-Host 'Arrancando ahora para no tener que reiniciar...' -ForegroundColor Cyan

if (Start-ReadAloudDaemon -Paths $paths) {
    Write-Host '    motor de voz activo' -ForegroundColor Green
} else {
    Write-Host '    el motor no respondio. Revisa read_aloud_piper\runtime\daemon.log' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Atajos disponibles:' -ForegroundColor White
Write-Host '  Ctrl+Alt+V          leer lo seleccionado'
Write-Host '  Ctrl+Shift+Q        detener'
Write-Host '  Ctrl+Shift+Espacio  pausar o continuar'
Write-Host '  Ctrl+Shift+,        retroceder 10 segundos'
Write-Host '  Ctrl+Shift+.        avanzar 10 segundos'
Write-Host '  Ctrl+Shift+] y [    subir o bajar la velocidad'
