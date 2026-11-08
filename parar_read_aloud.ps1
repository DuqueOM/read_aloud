#
# parar_read_aloud.ps1
# Cierra los procesos de ESTA copia de Read Aloud que tienen archivos abiertos:
# los piper.exe (cargan las DLL de bin\piper) y, salvo con -OnlyPiper, el proceso
# residente y el servidor de la voz propia. Solo toca los de la carpeta -Root:
# otro Read Aloud en otra carpeta, o cualquier otro programa que use Piper, no
# se ve afectado.
#
# Lo usan el instalador (antes de reemplazar archivos), setup.ps1 (antes de
# reinstalar el motor) y el desinstalador: Windows no deja sobrescribir ni borrar
# una DLL que un proceso tiene cargada, y eso dejaba instalaciones a medias.
#
#   .\parar_read_aloud.ps1                    Cierra todo lo de esta carpeta
#   .\parar_read_aloud.ps1 -OnlyPiper         Solo los piper.exe
#   .\parar_read_aloud.ps1 -Root C:\ruta      Otra carpeta de instalacion
#   .\parar_read_aloud.ps1 -ListOnly          Muestra que cerraria, sin cerrar nada
#
# Este archivo no depende de ningun otro: el instalador lo extrae solo a una
# carpeta temporal para usarlo antes de copiar el resto.

[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [switch]$OnlyPiper,
    [switch]$ListOnly
)

$ErrorActionPreference = 'Continue'

# La ruta con nombres largos: Windows informa asi la de cada proceso, y una carpeta
# dada con nombres cortos (RUNNER~1) no coincidiria.
Add-Type -Namespace RA -Name Ruta -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern uint GetLongPathName(string corta, System.Text.StringBuilder larga, uint n);'
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$larga = New-Object System.Text.StringBuilder 1024
if ([RA.Ruta]::GetLongPathName($Root, $larga, 1024) -gt 0) { $Root = $larga.ToString().TrimEnd('\') }
$prefix = $Root + '\'
$comparison = [StringComparison]::OrdinalIgnoreCase

$targets = New-Object System.Collections.Generic.List[object]

foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
    if ($p.ProcessId -eq $PID) { continue }

    $match = $false
    if ($p.Name -eq 'piper.exe') {
        $match = ($p.ExecutablePath -and $p.ExecutablePath.StartsWith($prefix, $comparison))
    } elseif (-not $OnlyPiper -and $p.CommandLine) {
        if ($p.Name -eq 'powershell.exe' -or $p.Name -eq 'pwsh.exe') {
            $match = ($p.CommandLine.IndexOf($prefix + 'read_aloud_daemon.ps1', $comparison) -ge 0)
        } elseif ($p.Name -eq 'python.exe') {
            $match = ($p.CommandLine.IndexOf($prefix + 'lib\servidor_qwen.py', $comparison) -ge 0)
        }
    }

    if ($match) { $targets.Add($p) }
}

foreach ($t in $targets) {
    Write-Output ('{0} {1}' -f $t.ProcessId, $t.Name)
}

if ($ListOnly -or $targets.Count -eq 0) { return }

foreach ($t in $targets) {
    try { Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop } catch { }
}

# Hasta que Windows suelte los archivos (unos instantes).
$deadline = (Get-Date).AddSeconds(8)
foreach ($t in $targets) {
    while ((Get-Date) -lt $deadline -and (Get-Process -Id $t.ProcessId -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 100
    }
}
