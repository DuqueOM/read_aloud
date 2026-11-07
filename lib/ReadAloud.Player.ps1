#
# ReadAloud.Player.ps1
# La logica del reproductor que no depende de la ventana: duraciones, posicion
# en la linea de tiempo, saltos, orden de generacion y pasos de velocidad y
# volumen. Sale de read_aloud_daemon.ps1 para poder probarla con Pester; la
# ventana solo llama a estas funciones y pinta el resultado.
#
# Un fragmento ($chunk) es un objeto con estas propiedades:
#   Text, Duration, PauseAfter, Offset, Ready
# Duration incluye la pausa del final (PauseAfter). Mientras el audio no se
# genera, Duration es una estimacion; Ready dice cuando ya es la medida real.
#
# Todo el archivo es ASCII, como ReadAloud.Text.ps1.

# Caracteres por segundo de estas voces, mientras no hay audio real que medir.
$script:RA_DefaultCharsPerSecond = 14.0

function Format-Time {
    param([double]$Seconds)

    if ($Seconds -lt 0) { $Seconds = 0 }
    $span = [timespan]::FromSeconds($Seconds)
    # Floor y no [int]: el [int] de PowerShell redondea, y a partir de los 30 s
    # de cada minuto el reloj mostraba un minuto de mas (0:45 como 1:45).
    return ('{0}:{1:00}' -f [int][Math]::Floor($span.TotalMinutes), $span.Seconds)
}

function Format-Speed {
    param([double]$Value)
    return ($Value.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + 'x')
}

function Format-VolumePercent {
    param([double]$Value)
    return ('{0} %' -f [int][Math]::Round($Value * 100))
}

function Get-EstimatedDuration {
    # Estimacion mientras el fragmento aun no se genera; se corrige apenas
    # llega el WAV con su duracion exacta.
    param([string]$Text, [double]$CharsPerSecond = 14.0)

    if ($CharsPerSecond -le 0) { $CharsPerSecond = $script:RA_DefaultCharsPerSecond }
    return [Math]::Max(0.6, $Text.Length / $CharsPerSecond)
}

function Get-SpeechRate {
    # Caracteres por segundo que lleva esta lectura, medidos en los fragmentos
    # que ya tienen audio. Cada voz y cada velocidad de lectura dan un ritmo
    # distinto, y asi la barra de posicion no se mueve a saltos cuando llega el
    # audio real. Con muy poco audio medido (menos de $MinChars caracteres) no
    # hay base para fiarse, y se usa el ritmo por defecto.
    param($Chunks, [double]$Default = 14.0, [int]$MinChars = 120)

    $chars = 0
    $seconds = 0.0
    foreach ($c in $Chunks) {
        if (-not $c.Ready) { continue }
        $habla = $c.Duration - $c.PauseAfter
        if ($habla -le 0.2) { continue }
        $chars += $c.Text.Length
        $seconds += $habla
    }

    if ($chars -lt $MinChars -or $seconds -le 0) { return $Default }
    return [Math]::Max(8.0, [Math]::Min(30.0, $chars / $seconds))
}

function Update-ChunkEstimates {
    # Recalcula la duracion de lo que aun no se genero con el ritmo medido.
    # Devuelve ese ritmo.
    param($Chunks)

    $rate = Get-SpeechRate -Chunks $Chunks
    foreach ($c in $Chunks) {
        if ($c.Ready) { continue }
        $c.Duration = (Get-EstimatedDuration -Text $c.Text -CharsPerSecond $rate) + $c.PauseAfter
    }
    return $rate
}

function Update-ChunkOffsets {
    # Donde empieza cada fragmento en la linea de tiempo. Devuelve el total.
    param($Chunks)

    $offset = 0.0
    foreach ($c in $Chunks) {
        $c.Offset = $offset
        $offset += $c.Duration
    }
    return $offset
}

function Find-ChunkAt {
    # El fragmento que suena en el segundo dado, o -1 si no hay ninguno.
    param($Chunks, [double]$Seconds)

    for ($i = $Chunks.Count - 1; $i -ge 0; $i--) {
        if ($Seconds -ge $Chunks[$i].Offset) { return $i }
    }
    if ($Chunks.Count -gt 0) { return 0 }
    return -1
}

function Get-SeekTarget {
    # A donde lleva un salto al segundo dado: el fragmento, el punto dentro de
    # el y si ya tiene audio. Se puede saltar a cualquier parte, tenga o no
    # audio ya generado: si no lo tiene, Ready es falso y la ventana espera a
    # que llegue (la generacion de ese fragmento pasa a ser la primera).
    param($Chunks, [double]$Seconds, [double]$Margin = 0.15)

    $n = $Chunks.Count
    if ($n -eq 0) { return $null }

    $ultimo = $Chunks[$n - 1]
    $total = $ultimo.Offset + $ultimo.Duration
    $limite = [Math]::Max(0.0, $total - $Margin)
    $Seconds = [Math]::Max(0.0, [Math]::Min($Seconds, $limite))

    $i = Find-ChunkAt -Chunks $Chunks -Seconds $Seconds
    $c = $Chunks[$i]

    $dentro = 0.0
    if ($c.Ready) {
        $dentro = [Math]::Max(0.0, [Math]::Min($Seconds - $c.Offset, $c.Duration - $Margin))
    }

    return @{ Index = $i; Offset = $dentro; Seconds = $Seconds; Ready = [bool]$c.Ready }
}

function Get-SentenceTarget {
    # La frase anterior (-1) o la siguiente (+1), como en un reproductor de
    # musica: la anterior, si ya llevas mas de $Restart segundos de la frase
    # actual, vuelve primero a su comienzo. Devuelve -1 si no hay a donde ir.
    param($Chunks, [int]$PlayIndex, [double]$Position, [int]$Direction, [double]$Restart = 2.0)

    if ($Chunks.Count -eq 0 -or $PlayIndex -lt 0 -or $PlayIndex -ge $Chunks.Count) { return -1 }

    if ($Direction -lt 0) {
        if (($Position - $Chunks[$PlayIndex].Offset) -gt $Restart) { return $PlayIndex }
        return [Math]::Max(0, $PlayIndex - 1)
    }

    if ($PlayIndex + 1 -ge $Chunks.Count) { return -1 }
    return $PlayIndex + 1
}

function Get-JobOrder {
    # En que orden se generan los fragmentos que faltan. Normalmente, de
    # primero a ultimo. Si el usuario salta a un fragmento que aun no existe
    # ($Priority), se genera ese primero y sigue hacia delante; lo que quedo
    # atras se genera despues, para poder volver.
    param([int[]]$Pending = @(), [int]$Priority = -1)

    $orden = @($Pending | Sort-Object)
    if ($Priority -lt 0) { return $orden }

    $desde = @($orden | Where-Object { $_ -ge $Priority })
    $antes = @($orden | Where-Object { $_ -lt $Priority })
    return @($desde) + @($antes)
}

function Test-BatchFits {
    # Si otro fragmento cabe en el grupo que se manda junto a la voz propia:
    # hasta $MaxCount fragmentos y hasta $Budget caracteres (0 = sin tope).
    # Generar en grupo es mas rapido por frase, pero cada grupo tarda lo que su
    # frase mas larga; el tope evita que un grupo de frases largas retrase a las
    # que esperan detras.
    param([int]$Count, [int]$Chars, [int]$NextChars, [int]$MaxCount, [int]$Budget = 0)

    if ($Count -ge $MaxCount) { return $false }
    if ($Budget -gt 0 -and ($Chars + $NextChars) -gt $Budget) { return $false }
    return $true
}

function Get-NextStep {
    # Un paso mas arriba (+1) o mas abajo (-1) en una lista de valores, partiendo
    # del paso mas cercano al valor actual: sirve aunque el valor guardado no
    # sea exactamente uno de los pasos.
    param([double[]]$Steps, [double]$Current, [int]$Direction)

    $mejor = 0
    $distancia = [double]::MaxValue
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $d = [Math]::Abs($Steps[$i] - $Current)
        if ($d -lt $distancia) {
            $distancia = $d
            $mejor = $i
        }
    }

    $nuevo = [Math]::Max(0, [Math]::Min($Steps.Count - 1, $mejor + $Direction))
    return $Steps[$nuevo]
}
