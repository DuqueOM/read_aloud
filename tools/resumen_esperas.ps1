#
# resumen_esperas.ps1
# Resume por dia las esperas que anota el lector: cuantas veces el reproductor
# tuvo que esperar un audio que no estaba listo, cuanto sumaron y la mas larga,
# y cuanto tardo la voz propia en generar cada grupo frente a lo que dura al
# sonar (el factor). Con dos o tres dias de datos se decide si hacen falta
# grupos mas chicos o pasar a Piper tras cierta espera.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\resumen_esperas.ps1
#   ... -Dias 3                 Solo los ultimos 3 dias
#   ... -Carpeta <ruta>         Otra carpeta con daemon.log y qwen.log
#
# Lee daemon.log y qwen.log de read_aloud_piper\runtime, y sus copias .1 (el
# registro viejo que queda al pasar de cierto tamano).
#
# Columnas de las esperas (las de clase 'frase': termino una frase y la
# siguiente no estaba; las de arranque y las de un salto van aparte):
#   Esperas, Total, Max, Media   cuantas, segundos en total, la mas larga, media
#   Mas2s, Mas5s                 cuantas pasaron de 2 y de 5 segundos
#   Qwen, Piper                  cuantas fueron de cada motor
#   Arranque, ArranqueMax        espera media y maxima del primer audio
# Columnas de la voz propia (qwen.log):
#   Grupos, PorFrase             grupos generados y segundos de generacion por frase
#   Factor, FactorMax            generacion / audio, media y maxima (mas de 1:
#                                el grupo tarda mas en generarse que en sonar)
#   Lentos                       grupos con factor mayor que 1
# Un dia sin lineas de resumen de lecturas es anterior a este registro: sus
# columnas de esperas quedan vacias.

[CmdletBinding()]
param(
    [string]$Carpeta = '',
    [int]$Dias = 0
)

$ErrorActionPreference = 'Stop'

if (-not $Carpeta) { $Carpeta = Join-Path (Split-Path -Parent $PSScriptRoot) 'read_aloud_piper\runtime' }
$inv = [Globalization.CultureInfo]::InvariantCulture

function Read-LogLines {
    # El registro viejo (.1) primero, para que las lineas queden en orden.
    param([string]$Name)
    foreach ($archivo in @("$Name.1", $Name)) {
        $ruta = Join-Path $Carpeta $archivo
        if (Test-Path -LiteralPath $ruta) { Get-Content -LiteralPath $ruta -Encoding UTF8 }
    }
}

function ConvertTo-Number {
    param([string]$Text)
    return [double]::Parse($Text, $inv)
}

$desde = [datetime]::MinValue
if ($Dias -gt 0) { $desde = (Get-Date).Date.AddDays(1 - $Dias) }

$porDia = @{}
function Get-Day {
    param([string]$Fecha)
    if (-not $porDia.ContainsKey($Fecha)) {
        $porDia[$Fecha] = @{
            Lecturas = 0; ConResumen = 0
            Esperas = New-Object System.Collections.Generic.List[double]
            Qwen = 0; Piper = 0
            Arranques = New-Object System.Collections.Generic.List[double]
            Grupos = 0; Frases = 0; Generacion = 0.0
            Factores = New-Object System.Collections.Generic.List[double]
        }
    }
    return $porDia[$Fecha]
}

$reFecha = '^(\d{4}-\d{2}-\d{2}) \d{2}:\d{2}:\d{2}\s+'
$reLectura = $reFecha + 'Lectura \d+: '
$reResumen = $reFecha + 'Esperas de la lectura \d+ '
$reEspera = $reFecha + 'Espera de audio: .*?, ([\d.]+) s \((\w+)[^)]*\), motor (\S+), '
$reGrupo = $reFecha + '(\d+) frase\(s\) en ([\d.]+) s(?:, ([\d.]+) s de audio, factor ([\d.]+|-))?'

foreach ($linea in (Read-LogLines 'daemon.log')) {
    $m = [regex]::Match($linea, $reFecha)
    if (-not $m.Success) { continue }
    if ([datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', $inv) -lt $desde) { continue }

    if ($linea -match $reLectura) {
        $dia = Get-Day $Matches[1]
        $dia.Lecturas++
    } elseif ($linea -match $reResumen) {
        $dia = Get-Day $Matches[1]
        $dia.ConResumen++
    } elseif ($linea -match $reEspera) {
        $dia = Get-Day $Matches[1]
        $segundos = ConvertTo-Number $Matches[2]
        switch ($Matches[3]) {
            'arranque' { $dia.Arranques.Add($segundos) }
            'frase' {
                $dia.Esperas.Add($segundos)
                if ($Matches[4] -eq 'qwen') { $dia.Qwen++ } elseif ($Matches[4] -eq 'piper') { $dia.Piper++ }
            }
        }
    }
}

foreach ($linea in (Read-LogLines 'qwen.log')) {
    if ($linea -notmatch $reGrupo) { continue }
    if ([datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $inv) -lt $desde) { continue }
    $dia = Get-Day $Matches[1]
    $dia.Grupos++
    $dia.Frases += [int]$Matches[2]
    $dia.Generacion += ConvertTo-Number $Matches[3]
    if ($Matches[5] -and $Matches[5] -ne '-') { $dia.Factores.Add((ConvertTo-Number $Matches[5])) }
}

function Get-Average {
    param($Values)
    if ($Values.Count -eq 0) { return $null }
    return [Math]::Round((($Values | Measure-Object -Average).Average), 2)
}

function Get-Maximum {
    param($Values)
    if ($Values.Count -eq 0) { return $null }
    return [Math]::Round((($Values | Measure-Object -Maximum).Maximum), 2)
}

$filas = foreach ($fecha in ($porDia.psbase.Keys | Sort-Object)) {
    $d = $porDia[$fecha]
    $conDatos = $d.ConResumen -gt 0 -or $d.Esperas.Count -gt 0
    $e = $d.Esperas
    [pscustomobject]@{
        Dia         = $fecha
        Lecturas    = $d.Lecturas
        Esperas     = $(if ($conDatos) { $e.Count } else { $null })
        Total       = $(if ($conDatos) { [Math]::Round((($e | Measure-Object -Sum).Sum + 0), 1) } else { $null })
        Max         = Get-Maximum $e
        Media       = Get-Average $e
        Mas2s       = $(if ($conDatos) { @($e | Where-Object { $_ -gt 2 }).Count } else { $null })
        Mas5s       = $(if ($conDatos) { @($e | Where-Object { $_ -gt 5 }).Count } else { $null })
        Qwen        = $(if ($conDatos) { $d.Qwen } else { $null })
        Piper       = $(if ($conDatos) { $d.Piper } else { $null })
        Arranque    = Get-Average $d.Arranques
        ArranqueMax = Get-Maximum $d.Arranques
        Grupos      = $d.Grupos
        PorFrase    = $(if ($d.Frases -gt 0) { [Math]::Round($d.Generacion / $d.Frases, 2) } else { $null })
        Factor      = Get-Average $d.Factores
        FactorMax   = Get-Maximum $d.Factores
        Lentos      = $(if ($d.Factores.Count -gt 0) { @($d.Factores | Where-Object { $_ -gt 1 }).Count } else { $null })
    }
}

if (-not $filas) {
    Write-Output "No hay lineas de esperas ni de la voz propia en $Carpeta."
    return
}

# Dos tablas: todas las columnas juntas no caben en una consola.
Write-Output 'Esperas del reproductor (daemon.log), en segundos'
$filas | Format-Table -AutoSize -Property Dia, Lecturas, Esperas, Total, Max, Media, Mas2s, Mas5s, Qwen, Piper, Arranque, ArranqueMax |
    Out-String -Width 200
Write-Output 'Voz propia (qwen.log)'
$filas | Where-Object { $_.Grupos -gt 0 } | Format-Table -AutoSize -Property Dia, Grupos, PorFrase, Factor, FactorMax, Lentos |
    Out-String -Width 200
