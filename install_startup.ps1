#
# install_startup.ps1
# Deja Read Aloud funcionando desde que inicias sesion en Windows.
#
#   .\install_startup.ps1              Instala el arranque automatico
#   .\install_startup.ps1 -Uninstall   Lo quita
#   .\install_startup.ps1 -DaemonOnly  Sin atajos de teclado, solo el motor
#
# No necesita permisos de administrador: todo queda en la carpeta de Inicio
# de tu usuario.

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$DaemonOnly
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

function Find-AutoHotkey {
    # Se busca AutoHotkey v2 en los sitios habituales. Si no aparece, los
    # atajos no se instalan pero el motor de voz si.
    $candidates = @(
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe')
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey32.exe')
        (Join-Path $env:ProgramFiles 'AutoHotkey\AutoHotkey.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'AutoHotkey\v2\AutoHotkey64.exe')
        (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe')
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }

    $command = Get-Command 'AutoHotkey64.exe', 'AutoHotkey.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($command) { return $command.Source }

    return $null
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

if (-not $DaemonOnly) {
    $ahk = Find-AutoHotkey

    if ($ahk) {
        $ahkScript = Join-Path $paths.Root 'read_aloud_hotkey.ahk'
        New-Shortcut -Path $hotkeyLink -Target $ahk -Arguments ('"' + $ahkScript + '"') `
            -Description 'Atajos de teclado de Read Aloud'

        Write-Host ('    instalado: {0}' -f (Split-Path -Leaf $hotkeyLink)) -ForegroundColor Gray
        Write-Host ('    AutoHotkey: {0}' -f $ahk) -ForegroundColor DarkGray
    } else {
        Write-Host '    AutoHotkey v2 no esta instalado: los atajos no quedaron activos.' -ForegroundColor Yellow
        Write-Host '    Instalalo desde autohotkey.com y vuelve a ejecutar este script.' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'Arrancando ahora para no tener que reiniciar...' -ForegroundColor Cyan

if (Start-ReadAloudDaemon -Paths $paths) {
    Write-Host '    motor de voz activo' -ForegroundColor Green
} else {
    Write-Host '    el motor no respondio. Revisa read_aloud_piper\runtime\daemon.log' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Atajos disponibles:' -ForegroundColor White
Write-Host '  Ctrl+Shift+V        leer lo seleccionado'
Write-Host '  Ctrl+Shift+Q        detener'
Write-Host '  Ctrl+Shift+Espacio  pausar o continuar'
Write-Host '  Ctrl+Shift+,        retroceder 10 segundos'
Write-Host '  Ctrl+Shift+.        avanzar 10 segundos'
