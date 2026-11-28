#
# ReadAloud.Events.ps1
# Registro de eventos: una linea JSON por cada cosa que pasa en el lector (una
# lectura que empieza, un fragmento que llega, un grupo que genera la voz, una
# espera, un salto, el final de una lectura). Con el se ve despues, con datos,
# donde y por que hay pausas, que controles se usan y como rinde cada voz.
#
# Los archivos son read_aloud_piper\runtime\eventos_AAAA-MM.jsonl, uno por mes,
# en UTF-8 sin BOM, y se borran los de hace mas de EventLogMonths meses. La
# lista de eventos y sus campos esta en docs\configuracion.md.
#
# De cada frase se guardan sus rasgos (largo, palabras, cifras, siglas, comas),
# no sus palabras: lo que se lee puede ser privado. Con el ajuste
# EventLogText = $true se guarda tambien el texto.
#
# Sale de read_aloud_daemon.ps1 para poder probarlo con Pester. Todo el archivo
# es ASCII, como ReadAloud.Text.ps1.

$script:RA_EventCulture = [Globalization.CultureInfo]::InvariantCulture

# Los modos de energia de Windows 11 (Configuracion, Sistema, Energia). Un
# portatil en "Maxima eficiencia energetica" o con bateria puede bajar mucho la
# velocidad de la tarjeta grafica, y con ella la de la voz propia.
$script:RA_PowerModes = @{
    '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'eficiencia'
    '00000000-0000-0000-0000-000000000000' = 'equilibrado'
    'ded574b5-45a0-4f42-8737-46345c09c238' = 'rendimiento'
}

function Get-EventLogPath {
    param([string]$RuntimeDir, [datetime]$Date = (Get-Date))
    return (Join-Path $RuntimeDir ('eventos_{0}.jsonl' -f $Date.ToString('yyyy-MM', $script:RA_EventCulture)))
}

function Remove-OldEventLog {
    # Borra los meses que quedaron fuera de los ultimos $KeepMonths, contando
    # el actual. Con 0 o menos no borra nada. Devuelve cuantos borro.
    param([string]$RuntimeDir, [int]$KeepMonths = 12, [datetime]$Now = (Get-Date))

    if ($KeepMonths -le 0 -or -not (Test-Path -LiteralPath $RuntimeDir)) { return 0 }
    $limite = (New-Object DateTime($Now.Year, $Now.Month, 1)).AddMonths(1 - $KeepMonths)
    $borrados = 0
    foreach ($archivo in @(Get-ChildItem -LiteralPath $RuntimeDir -Filter 'eventos_*.jsonl' -File -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($archivo.Name, '^eventos_(\d{4})-(\d{2})\.jsonl$')
        if (-not $m.Success) { continue }
        try {
            $mes = New-Object DateTime([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, 1)
        } catch {
            continue
        }
        if ($mes -lt $limite) {
            try {
                Remove-Item -LiteralPath $archivo.FullName -Force -ErrorAction Stop
                $borrados++
            } catch { }
        }
    }
    return $borrados
}

function ConvertTo-EventNumber {
    # Un numero redondeado para el registro. NaN o infinito no son JSON valido:
    # quedan en $null.
    param($Value, [int]$Digits = 3)

    if ($null -eq $Value) { return $null }
    $d = [double]$Value
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
    return [Math]::Round($d, $Digits)
}

function Get-TextTraits {
    # Lo que se puede saber de una frase sin guardar sus palabras: el largo,
    # las palabras, las cifras, las siglas (dos mayusculas o mas) y las comas,
    # puntos y comas y dos puntos, que son donde la voz suele hacer pausas.
    param([string]$Text)

    if ($null -eq $Text) { $Text = '' }
    return [ordered]@{
        caracteres = $Text.Length
        palabras   = ([regex]::Matches($Text, '\S+')).Count
        cifras     = ([regex]::Matches($Text, '\d')).Count
        siglas     = ([regex]::Matches($Text, '\b\p{Lu}{2,}\b')).Count
        comas      = ([regex]::Matches($Text, '[,;:]')).Count
    }
}

function ConvertTo-EventLine {
    # Una linea JSON: la hora (con milisegundos y zona), el tipo y los datos,
    # en ese orden. ConvertTo-Json escapa los saltos de linea, asi que cada
    # evento ocupa siempre una sola linea.
    param(
        [string]$Type,
        [System.Collections.IDictionary]$Data,
        [datetime]$Now = (Get-Date)
    )

    $evento = [ordered]@{
        t    = $Now.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', $script:RA_EventCulture)
        tipo = $Type
    }
    if ($null -ne $Data) {
        foreach ($clave in @($Data.Keys)) { $evento[[string]$clave] = $Data[$clave] }
    }
    return (ConvertTo-Json -InputObject $evento -Compress -Depth 6)
}

function Write-EventLine {
    # Agrega la linea al archivo, sin BOM. Un fallo (disco lleno, archivo
    # bloqueado) se ignora: el registro nunca debe tumbar la lectura.
    param([string]$Path, [string]$Line)

    try {
        [IO.File]::AppendAllText($Path, $Line + "`n", (New-Object Text.UTF8Encoding($false)))
        return $true
    } catch {
        return $false
    }
}

function ConvertFrom-SynthOutput {
    # El servidor de Qwen agrega a la primera ruta de cada grupo, tras un
    # tabulador, las medidas del grupo en JSON. Piper devuelve solo la ruta.
    param([string]$Line)

    $resultado = @{ Path = $Line; Metrics = $null }
    if ([string]::IsNullOrEmpty($Line)) { return $resultado }
    $tab = $Line.IndexOf([char]9)
    if ($tab -lt 0) { return $resultado }
    $resultado.Path = $Line.Substring(0, $tab)
    try { $resultado.Metrics = $Line.Substring($tab + 1) | ConvertFrom-Json } catch { }
    return $resultado
}

function ConvertTo-PowerState {
    # 'ac' (enchufado), 'bateria' o '?'; el porcentaje de la bateria si hay
    # bateria; y el modo de energia que Windows aplica con esa corriente.
    param(
        [string]$LineStatus,
        [string]$ChargeStatus = '',
        [double]$LifePercent = -1,
        [string]$OverlayAc = '',
        [string]$OverlayDc = ''
    )

    $corriente = switch ($LineStatus) {
        'Online'  { 'ac' }
        'Offline' { 'bateria' }
        default   { '?' }
    }

    $porcentaje = $null
    if ($ChargeStatus -notmatch 'NoSystemBattery|Unknown' -and $LifePercent -ge 0 -and $LifePercent -le 1) {
        $porcentaje = [int][Math]::Round($LifePercent * 100)
    }

    $overlay = $(if ($corriente -eq 'bateria') { $OverlayDc } else { $OverlayAc })
    $modo = $null
    if ($overlay) {
        $clave = $overlay.ToLowerInvariant()
        if ($script:RA_PowerModes.ContainsKey($clave)) { $modo = $script:RA_PowerModes[$clave] } else { $modo = $clave }
    }

    return [ordered]@{ corriente = $corriente; bateria_pct = $porcentaje; energia = $modo }
}

function Get-PowerState {
    # Lee la corriente y el modo de energia del equipo. Necesita
    # System.Windows.Forms cargado; si algo falla, devuelve '?'.
    $estado = $null
    $ac = ''
    $dc = ''
    try { $estado = [Windows.Forms.SystemInformation]::PowerStatus } catch { }
    try {
        $esquemas = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -ErrorAction Stop
        $ac = [string]$esquemas.ActiveOverlayAcPowerScheme
        $dc = [string]$esquemas.ActiveOverlayDcPowerScheme
    } catch { }

    if ($null -eq $estado) { return (ConvertTo-PowerState -LineStatus '' -OverlayAc $ac -OverlayDc $dc) }
    return (ConvertTo-PowerState -LineStatus ([string]$estado.PowerLineStatus) -ChargeStatus ([string]$estado.BatteryChargeStatus) `
            -LifePercent ([double]$estado.BatteryLifePercent) -OverlayAc $ac -OverlayDc $dc)
}

function Get-Median {
    param($Values)
    $orden = @($Values | Where-Object { $null -ne $_ } | Sort-Object)
    if ($orden.Count -eq 0) { return $null }
    $medio = [int][Math]::Floor($orden.Count / 2)
    if ($orden.Count % 2 -eq 1) { return [double]$orden[$medio] }
    return ([double]$orden[$medio - 1] + [double]$orden[$medio]) / 2.0
}
