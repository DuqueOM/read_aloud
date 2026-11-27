#
# resumen_eventos.ps1
# Resume el registro de eventos del lector (read_aloud_piper\runtime\
# eventos_AAAA-MM.jsonl): por dia, las lecturas, las esperas y como rindio la
# voz propia; con -Esperas, cada espera con el grupo que la causo; y al final,
# lo que dice la regla del PR #8 sobre grupos mas chicos o pasar a Piper.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\resumen_eventos.ps1
#   ... -Dias 3                 Solo los ultimos 3 dias
#   ... -Esperas                Ademas, una fila por espera
#   ... -Carpeta <ruta>         Otra carpeta con los eventos_*.jsonl
#   ... -Objetos                Devuelve las filas como objetos, sin tablas
#
# Columnas de las lecturas:
#   Lecturas, Terminadas         lecturas empezadas y las que llegaron al final
#   Minutos                      tiempo escuchado (posicion al terminar o al
#                                detener, entre la velocidad)
#   Arranque, ArranqueMax        espera mediana y maxima del primer audio
#   Frase, CadaDiez              esperas entre frases y cuantas por cada 10 lecturas
#   Mas3s, FraseMax              las de mas de 3 s y la mas larga
#   Saltos                       esperas tras saltar a un punto sin audio
# Columnas de la voz propia (grupos que genero Qwen):
#   Grupos, Frases               grupos y frases por grupo, en media
#   Factor, FactorMax, Lentos    generacion / audio (media, maxima y cuantos
#                                pasaron de 1: tardaron mas que lo que suenan)
#   Descartados                  grupos de una lectura que ya se habia reemplazado
#   Cpu, OtrosGB, Mhz            procesador ocupado, memoria de la tarjeta de
#                                otros programas y reloj de la tarjeta, en media
#   Bateria, Energia             grupos con bateria y el modo de energia mas comun
#   APiper                       fragmentos pedidos a Qwen que leyo Piper, por motivo

[CmdletBinding()]
param(
    [string]$Carpeta = '',
    [int]$Dias = 0,
    [switch]$Esperas,
    [switch]$Objetos
)

$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $raiz 'lib\ReadAloud.Events.ps1')
if (-not $Carpeta) { $Carpeta = Join-Path $raiz 'read_aloud_piper\runtime' }
$inv = [Globalization.CultureInfo]::InvariantCulture

$desde = ''
if ($Dias -gt 0) { $desde = (Get-Date).Date.AddDays(1 - $Dias).ToString('yyyy-MM-dd', $inv) }

# --------------------------------------------------------------------------
# Lectura. El dia y la hora salen del texto de la linea y no del objeto:
# ConvertFrom-Json de PowerShell 7 convierte la hora en fecha, con la zona de
# este equipo. Los numeros de lectura vuelven a 1 cada vez que arranca el
# lector, asi que cada evento lleva tambien la sesion (cuantos 'inicio' van).
# --------------------------------------------------------------------------
$eventos = New-Object System.Collections.Generic.List[object]
$sesion = 0
$archivos = @(Get-ChildItem -LiteralPath $Carpeta -Filter 'eventos_*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name)
foreach ($archivo in $archivos) {
    foreach ($linea in [IO.File]::ReadLines($archivo.FullName)) {
        $m = [regex]::Match($linea, '^\{"t":"(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})')
        if (-not $m.Success) { continue }
        try { $e = $linea | ConvertFrom-Json } catch { continue }
        if ($e.tipo -eq 'inicio') { $sesion++ }
        if ($desde -and $m.Groups[1].Value -lt $desde) { continue }
        $e | Add-Member -NotePropertyName dia -NotePropertyValue $m.Groups[1].Value
        $e | Add-Member -NotePropertyName hora -NotePropertyValue $m.Groups[2].Value
        $e | Add-Member -NotePropertyName sesion -NotePropertyValue $sesion
        $eventos.Add($e)
    }
}

if ($eventos.Count -eq 0) {
    Write-Output "No hay eventos en $Carpeta$(if ($desde) { " desde el $desde" })."
    return
}

function Get-Average {
    param($Values)
    $v = @($Values | Where-Object { $null -ne $_ })
    if ($v.Count -eq 0) { return $null }
    return [Math]::Round((($v | Measure-Object -Average).Average), 2)
}

function Get-Maximum {
    param($Values)
    $v = @($Values | Where-Object { $null -ne $_ })
    if ($v.Count -eq 0) { return $null }
    return [Math]::Round((($v | Measure-Object -Maximum).Maximum), 2)
}

function Get-Round {
    param($Value, [int]$Digits = 2)
    if ($null -eq $Value) { return $null }
    return [Math]::Round([double]$Value, $Digits)
}

$porTipo = @{}
foreach ($e in $eventos) {
    if (-not $porTipo.ContainsKey($e.tipo)) { $porTipo[$e.tipo] = New-Object System.Collections.Generic.List[object] }
    $porTipo[$e.tipo].Add($e)
}
function Get-Tipo {
    param([string]$Nombre)
    if ($porTipo.ContainsKey($Nombre)) { return , $porTipo[$Nombre] }
    return , @()
}

# Grupos y fragmentos por su clave, para unirlos a las esperas.
$grupos = @{}
foreach ($g in (Get-Tipo 'grupo')) { $grupos["$($g.sesion)/$($g.grupo)"] = $g }
$fragmentos = @{}
foreach ($f in (Get-Tipo 'fragmento')) { $fragmentos["$($f.sesion)/$($f.lectura)/$($f.i)"] = $f }

$listaDias = @($eventos | ForEach-Object { $_.dia } | Sort-Object -Unique)
$esperasTodas = Get-Tipo 'espera'
$gruposQwen = @((Get-Tipo 'grupo') | Where-Object { $_.motor -eq 'qwen' })

# --------------------------------------------------------------------------
# Por dia.
# --------------------------------------------------------------------------
$filasLecturas = foreach ($dia in $listaDias) {
    $lect = @((Get-Tipo 'lectura') | Where-Object { $_.dia -eq $dia })
    $fines = @((Get-Tipo 'fin') | Where-Object { $_.dia -eq $dia })
    $esp = @($esperasTodas | Where-Object { $_.dia -eq $dia })
    $frase = @($esp | Where-Object { $_.clase -eq 'frase' } | ForEach-Object { [double]$_.s })
    $arranque = @($esp | Where-Object { $_.clase -eq 'arranque' -and -not $_.cortada } | ForEach-Object { [double]$_.s })
    $minutos = 0.0
    foreach ($f in $fines) {
        $vel = [double]$f.velocidad
        if ($vel -le 0) { $vel = 1.0 }
        $minutos += [double]$f.posicion_s / $vel / 60.0
    }
    [pscustomobject]@{
        Dia         = $dia
        Lecturas    = $lect.Count
        Terminadas  = @($fines | Where-Object { $_.motivo -eq 'terminada' }).Count
        Minutos     = [Math]::Round($minutos, 1)
        Arranque    = Get-Round (Get-Median $arranque)
        ArranqueMax = Get-Maximum $arranque
        Frase       = $frase.Count
        CadaDiez    = $(if ($lect.Count -gt 0) { [Math]::Round($frase.Count * 10.0 / $lect.Count, 1) } else { $null })
        Mas3s       = @($frase | Where-Object { $_ -gt 3 }).Count
        FraseMax    = Get-Maximum $frase
        Saltos      = @($esp | Where-Object { $_.clase -eq 'salto' }).Count
    }
}

$filasVoz = foreach ($dia in $listaDias) {
    $g = @($gruposQwen | Where-Object { $_.dia -eq $dia })
    $aPiper = @((Get-Tipo 'grupo') | Where-Object { $_.dia -eq $dia -and $_.pedido -eq 'qwen' -and $_.motor -eq 'piper' })
    if ($g.Count -eq 0 -and $aPiper.Count -eq 0) { continue }
    $conServidor = @($g | Where-Object { $null -ne $_.servidor })
    $factores = @($conServidor | ForEach-Object { $_.servidor.factor } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    $modos = @($g | ForEach-Object { $_.energia.energia } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending)
    $motivos = @($aPiper | Group-Object { if ($_.motivo) { $_.motivo } else { '?' } } | ForEach-Object { '{0}:{1}' -f $_.Name, (($_.Group | ForEach-Object { $_.tamano } | Measure-Object -Sum).Sum) })
    [pscustomobject]@{
        Dia         = $dia
        Grupos      = $g.Count
        Frases      = Get-Average @($g | ForEach-Object { [double]$_.tamano })
        Factor      = Get-Average $factores
        FactorMax   = Get-Maximum $factores
        Lentos      = @($factores | Where-Object { $_ -gt 1 }).Count
        Descartados = @($g | Where-Object { $_.descartado }).Count
        Cpu         = Get-Average @($conServidor | ForEach-Object { $_.servidor.cpu_pct })
        OtrosGB     = Get-Average @($conServidor | ForEach-Object { $_.servidor.otros_gb })
        Mhz         = Get-Average @($conServidor | Where-Object { $null -ne $_.servidor.tarjeta } | ForEach-Object { $_.servidor.tarjeta.mhz })
        Bateria     = @($g | Where-Object { $_.energia.corriente -eq 'bateria' }).Count
        Energia     = $(if ($modos.Count -gt 0) { $modos[0].Name } else { $null })
        APiper      = ($motivos -join ', ')
    }
}

# --------------------------------------------------------------------------
# Cada espera, con su grupo y su fragmento.
# --------------------------------------------------------------------------
$filasEsperas = foreach ($w in $esperasTodas) {
    $g = $null
    if ($w.grupo) { $g = $grupos["$($w.sesion)/$($w.grupo)"] }
    $f = $fragmentos["$($w.sesion)/$($w.lectura)/$($w.i)"]
    [pscustomobject]@{
        Cuando     = $w.dia.Substring(5) + ' ' + $w.hora
        Lectura    = $w.lectura
        Frag       = $(if ($null -ne $w.i) { [int]$w.i + 1 } else { $null })
        Clase      = $w.clase + $(if ($w.cortada) { '*' } else { '' })
        S          = Get-Round $w.s
        Motor      = $w.motor
        Tamano     = $w.tamano
        Factor     = $(if ($g -and $g.servidor) { Get-Round $g.servidor.factor } else { $null })
        GenS       = $(if ($g) { Get-Round ($g.gen_ms / 1000.0) 1 } else { $null })
        MandadoS   = $(if ($g -and $null -ne $g.ms) { Get-Round ($g.ms / 1000.0) 1 } else { $null })
        Cpu        = $(if ($g -and $g.servidor) { $g.servidor.cpu_pct } else { $null })
        Mhz        = $(if ($g -and $g.servidor -and $g.servidor.tarjeta) { $g.servidor.tarjeta.mhz } else { $null })
        Corriente  = $(if ($g -and $g.energia) { $g.energia.corriente } else { $null })
        Caracteres = $(if ($f) { $f.caracteres } else { $null })
        Texto      = $(if ($f -and $f.texto) { [string]$f.texto } else { $null })
    }
}

# --------------------------------------------------------------------------
# La regla del PR #8, sobre todo el periodo.
# --------------------------------------------------------------------------
$lecturas = (Get-Tipo 'lectura').Count
$frases = @($esperasTodas | Where-Object { $_.clase -eq 'frase' } | ForEach-Object { [double]$_.s })
$cadaDiez = $(if ($lecturas -gt 0) { $frases.Count * 10.0 / $lecturas } else { 0.0 })
$maxFrase = $(if ($frases.Count -gt 0) { ($frases | Measure-Object -Maximum).Maximum } else { 0.0 })
$factorMedio = Get-Average @($gruposQwen | Where-Object { $null -ne $_.servidor -and $null -ne $_.servidor.factor } | ForEach-Object { [double]$_.servidor.factor })

$regla = New-Object System.Collections.Generic.List[string]
$regla.Add([string]::Format($inv, '{0} lecturas; {1} esperas entre frases ({2:0.0} cada 10 lecturas), la mas larga de {3:0.0} s; factor medio de la voz propia: {4}.',
        $lecturas, $frases.Count, $cadaDiez, $maxFrase, $(if ($null -ne $factorMedio) { $factorMedio.ToString('0.00', $inv) } else { 'sin grupos' })))
if ($lecturas -lt 10) { $regla.Add('Hay menos de 10 lecturas: es poco para decidir.') }
if ($cadaDiez -lt 1 -and $maxFrase -le 3) {
    $regla.Add('No cambiar nada: menos de 1 espera cada 10 lecturas y ninguna de mas de 3 s.')
} elseif (($null -ne $factorMedio -and $factorMedio -gt 0.8) -or $cadaDiez -gt 2) {
    $regla.Add('Grupos mas chicos: tras un grupo con factor de mas de 0,8, el siguiente con 2 frases como mucho; de vuelta a 4 tras dos grupos seguidos con factor de menos de 0,5.')
    if ($maxFrase -gt 3) { $regla.Add('Y si aun asi hay esperas de mas de 3 s, leer con Piper ese fragmento.') }
} else {
    $regla.Add('Zona intermedia: no se cumple "no cambiar nada" ni "grupos mas chicos". Mira cada espera con -Esperas.')
}

# Arranque: si su mediana pasa de 6 s, por que fueron largos.
$arranques = @($esperasTodas | Where-Object { $_.clase -eq 'arranque' -and -not $_.cortada })
$medianaArranque = Get-Median @($arranques | ForEach-Object { [double]$_.s })
if ($null -ne $medianaArranque -and $medianaArranque -gt 6) {
    $largos = @($arranques | Where-Object { [double]$_.s -gt 6 })
    $trasDescartado = 0
    $cargando = 0
    foreach ($a in $largos) {
        $anterior = @((Get-Tipo 'grupo') | Where-Object { $_.sesion -eq $a.sesion -and $_.lectura -lt $a.lectura -and $_.descartado })
        $primero = @((Get-Tipo 'grupo') | Where-Object { $_.sesion -eq $a.sesion -and $_.lectura -eq $a.lectura } | Sort-Object ms | Select-Object -First 1)
        if ($primero.Count -gt 0 -and ($primero[0].motivo -eq 'qwen_cargando' -or [double]$primero[0].espera_motor_ms -gt 1000)) {
            $cargando++
        } elseif ($anterior.Count -gt 0 -and $primero.Count -gt 0 -and [double]$primero[0].ms -gt 1000) {
            $trasDescartado++
        }
    }
    $regla.Add([string]::Format($inv, 'Arranque: mediana de {0:0.0} s. De los {1} de mas de 6 s, {2} esperaron a que terminara un grupo de una lectura ya reemplazada y {3} a que cargara la voz propia.',
            $medianaArranque, $largos.Count, $trasDescartado, $cargando))
}

if ($Objetos) {
    [pscustomobject]@{ Lecturas = @($filasLecturas); Voz = @($filasVoz); Esperas = @($filasEsperas); Regla = @($regla) }
    return
}

# Las columnas van nombradas: sin -Property, Format-Table muestra solo las 10
# primeras. Y cada tabla cabe en una consola de 120 columnas.
Write-Output 'Lecturas y esperas, en segundos'
$filasLecturas | Format-Table -AutoSize -Property Dia, Lecturas, Terminadas, Minutos, Arranque, ArranqueMax, Frase, CadaDiez, Mas3s, FraseMax, Saltos |
    Out-String -Width 200
if ($filasVoz) {
    Write-Output 'Voz propia'
    $filasVoz | Format-Table -AutoSize -Property Dia, Grupos, Frases, Factor, FactorMax, Lentos, Descartados | Out-String -Width 200
    Write-Output 'Condiciones de la voz propia (procesador en %, memoria de otros en GB, reloj de la tarjeta en MHz)'
    $filasVoz | Format-Table -AutoSize -Property Dia, Cpu, OtrosGB, Mhz, Bateria, Energia, APiper | Out-String -Width 200
}
if ($Esperas -and $filasEsperas) {
    Write-Output 'Cada espera (* = cortada: saltaste o detuviste antes de que llegara el audio; MandadoS: cuando se mando su grupo, desde que empezo la lectura)'
    $filasEsperas | Format-Table -AutoSize -Property Cuando, Lectura, Frag, Clase, S, Motor, Tamano, Factor, GenS, MandadoS, Cpu, Mhz, Corriente, Caracteres |
        Out-String -Width 200
    $conTexto = @($filasEsperas | Where-Object { $_.Texto })
    if ($conTexto.Count -gt 0) {
        Write-Output 'Texto de cada espera (EventLogText)'
        $conTexto | ForEach-Object { '  {0}  lectura {1}, fragmento {2}: {3}' -f $_.Cuando, $_.Lectura, $_.Frag, $_.Texto }
        Write-Output ''
    }
}
Write-Output 'Regla del PR #8'
$regla | ForEach-Object { "  $_" }
