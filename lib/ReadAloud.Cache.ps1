#
# ReadAloud.Cache.ps1
# Reutilizar lo ya hecho (ADR 0016): el audio de cada frase y cada
# traduccion se guardan unos minutos para no generarlos otra vez al releer el
# mismo texto o una parte.
#
#  - El audio va en disco (read_aloud_piper\tmp\cache), un WAV por frase, sin
#    la pausa del final del bloque: esa pausa depende del lugar de la frase.
#    Copiar un archivo cuesta milisegundos, y la RAM es lo que mas escasea.
#  - Las traducciones van en la memoria del proceso residente: pesan unos
#    pocos KB y asi el texto no queda en el disco.
#
# Las dos caducan tras AudioCacheMinutes sin usarse; el audio tiene ademas un
# tope de espacio (AudioCacheMB). Cada uso renueva el plazo.
#
# Solo ASCII: el archivo se carga tambien desde Windows PowerShell 5.1.

function Get-TextHash {
    # SHA-256 del texto en UTF-8, en hexadecimal y minusculas.
    param([string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes([string]$Text))
    } finally {
        $sha.Dispose()
    }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function ConvertTo-CacheValue {
    # Un numero se escribe siempre igual, con punto y sin depender del idioma
    # de Windows: 1.06 no debe dar una clave distinta en un equipo con coma.
    param($Value)
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return ([double]$Value).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [bool]) { return ([string]$Value).ToLowerInvariant() }
    return [string]$Value
}

function Get-AudioCacheKey {
    # La clave del audio de una frase: el motor, la voz, el idioma, el texto
    # tal como se le manda a la voz y los ajustes que cambian el sonido
    # (velocidad, variacion, silencio), en orden alfabetico.
    param(
        [string]$Engine,
        [string]$Voice,
        [string]$Lang,
        [string]$Text,
        [hashtable]$Sound = @{}
    )

    $partes = New-Object System.Collections.Generic.List[string]
    foreach ($p in @('audio', 'v1', $Engine, $Voice, $Lang)) { [void]$partes.Add([string]$p) }
    if ($null -ne $Sound) {
        foreach ($k in @($Sound.psbase.Keys | Sort-Object)) {
            [void]$partes.Add(('{0}={1}' -f $k, (ConvertTo-CacheValue $Sound[$k])))
        }
    }
    [void]$partes.Add($Text)
    return Get-TextHash -Text ($partes -join "`n")
}

function Get-TranslationCacheKey {
    # La clave de una traduccion: el texto, la direccion y el modelo.
    param(
        [string]$Text,
        [string]$Source,
        [string]$Target,
        [string]$Model
    )
    return Get-TextHash -Text ((@('traduccion', 'v1', $Source, $Target, $Model, $Text)) -join "`n")
}

function Test-CacheFresh {
    # Sigue vigente si se uso hace menos de Minutes.
    param([DateTime]$LastUsed, [DateTime]$Now, [double]$Minutes)
    return ($Now - $LastUsed).TotalMinutes -lt $Minutes
}

function Get-CacheEvictions {
    # Lo que hay que borrar: lo caducado y, si lo vigente pasa de MaxBytes, lo
    # usado hace mas tiempo hasta quedar por debajo. Cada entrada lleva Bytes
    # y LastUsed. MaxBytes 0 o menos es sin tope.
    param(
        [object[]]$Entries,
        [DateTime]$Now,
        [double]$Minutes,
        [long]$MaxBytes = 0
    )

    $fuera = New-Object System.Collections.Generic.List[object]
    $vigentes = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($Entries)) {
        if ($null -eq $e) { continue }
        if (Test-CacheFresh -LastUsed $e.LastUsed -Now $Now -Minutes $Minutes) { [void]$vigentes.Add($e) } else { [void]$fuera.Add($e) }
    }

    if ($MaxBytes -gt 0) {
        $total = [long]0
        foreach ($e in @($vigentes | Sort-Object -Property @{ Expression = { $_.LastUsed }; Descending = $true })) {
            $total += [long]$e.Bytes
            if ($total -gt $MaxBytes) { [void]$fuera.Add($e) }
        }
    }

    return $fuera.ToArray()
}

# --------------------------------------------------------------------------
# Audio en disco. La fecha de modificacion de cada WAV es su ultimo uso.
# --------------------------------------------------------------------------

function Get-AudioCachePath {
    param([string]$CacheDir, [string]$Key)
    return (Join-Path $CacheDir ($Key + '.wav'))
}

function Save-AudioToCache {
    # Copia el WAV recien generado a la cache. Devuelve $true si quedo.
    param(
        [string]$Wav,
        [string]$CacheDir,
        [string]$Key,
        [DateTime]$Now = (Get-Date)
    )

    # Con las clases de .NET y no con los cmdlets: al empezar una lectura se
    # consulta una vez por frase, y cada cmdlet cuesta milisegundos.
    if (-not $Wav -or -not $Key -or -not [IO.File]::Exists($Wav)) { return $false }
    $parcial = $null
    try {
        [void][IO.Directory]::CreateDirectory($CacheDir)
        $destino = Get-AudioCachePath -CacheDir $CacheDir -Key $Key
        # Se copia con otro nombre y se renombra: quien lo lea a la vez nunca
        # ve un WAV a medias.
        $parcial = $destino + '.part'
        [IO.File]::Copy($Wav, $parcial, $true)
        [IO.File]::SetLastWriteTime($parcial, $Now)
        if ([IO.File]::Exists($destino)) { [IO.File]::Delete($destino) }
        [IO.File]::Move($parcial, $destino)
        return $true
    } catch {
        if ($parcial) { try { [IO.File]::Delete($parcial) } catch { } }
        return $false
    }
}

function Copy-AudioFromCache {
    # Si la frase tiene audio guardado y vigente, lo copia a Destination y
    # renueva su plazo. Devuelve $true si lo copio.
    param(
        [string]$CacheDir,
        [string]$Key,
        [string]$Destination,
        [double]$Minutes,
        [DateTime]$Now = (Get-Date)
    )

    if ($Minutes -le 0 -or -not $Key) { return $false }
    $origen = Get-AudioCachePath -CacheDir $CacheDir -Key $Key
    try {
        if (-not [IO.File]::Exists($origen)) { return $false }
        if (-not (Test-CacheFresh -LastUsed ([IO.File]::GetLastWriteTime($origen)) -Now $Now -Minutes $Minutes)) { return $false }
        [IO.File]::Copy($origen, $Destination, $true)
        [IO.File]::SetLastWriteTime($origen, $Now)
        return $true
    } catch {
        return $false
    }
}

function Get-SynthAudioKey {
    # La clave del audio de un fragmento segun la configuracion de la sintesis
    # del proceso residente ($synthConfig, la misma tabla que lee el hilo de
    # voz). Piper suena distinto con su modelo, la velocidad, la variacion y
    # el silencio final; la voz propia, con su carpeta y el silencio final.
    # Devuelve '' si no hay voz para ese idioma.
    param(
        [hashtable]$Config,
        [string]$Engine,
        [string]$Lang,
        [string]$Text
    )

    if ($Engine -eq 'qwen') {
        $voz = [string]$Config.Qwen.VoiceDir
        $sonido = @{ SentenceSilence = [string]$Config.SentenceSilence }
    } else {
        $modelo = [string]$Config.Models[$Lang]
        if (-not $modelo) { return '' }
        $voz = [IO.Path]::GetFileNameWithoutExtension($modelo)
        $sonido = @{
            LengthScale     = [string]$Config.LengthScale
            NoiseScale      = [string]$Config.NoiseScale
            NoiseW          = [string]$Config.NoiseW
            SentenceSilence = [string]$Config.SentenceSilence
        }
    }
    if (-not $voz) { return '' }
    return Get-AudioCacheKey -Engine $Engine -Voice $voz -Lang $Lang -Text $Text -Sound $sonido
}

function Clear-AudioCache {
    # Borra lo caducado y lo que pase del tope. Devuelve cuantos borro.
    param(
        [string]$CacheDir,
        [double]$Minutes,
        [long]$MaxBytes = 0,
        [DateTime]$Now = (Get-Date)
    )

    if (-not (Test-Path -LiteralPath $CacheDir)) { return 0 }
    $entradas = @(Get-ChildItem -LiteralPath $CacheDir -Filter '*.wav' -File -ErrorAction SilentlyContinue | ForEach-Object {
        @{ Path = $_.FullName; Bytes = $_.Length; LastUsed = $_.LastWriteTime }
    })
    $borrados = 0
    foreach ($e in @(Get-CacheEvictions -Entries $entradas -Now $Now -Minutes $Minutes -MaxBytes $MaxBytes)) {
        try {
            Remove-Item -LiteralPath $e.Path -Force -ErrorAction Stop
            $borrados++
        } catch {
            # En uso: se borrara en la limpieza siguiente.
        }
    }
    return $borrados
}

# --------------------------------------------------------------------------
# Traducciones en memoria: clave -> @{ Text; LastUsed }.
# --------------------------------------------------------------------------

function New-TranslationMemory {
    return @{}
}

function Get-CachedTranslation {
    # La traduccion guardada, o $null si no hay o caduco (entonces se quita).
    param(
        [hashtable]$Memory,
        [string]$Key,
        [double]$Minutes,
        [DateTime]$Now = (Get-Date)
    )

    if ($null -eq $Memory -or -not $Memory.ContainsKey($Key)) { return $null }
    $e = $Memory[$Key]
    if (-not (Test-CacheFresh -LastUsed $e.LastUsed -Now $Now -Minutes $Minutes)) {
        $Memory.Remove($Key)
        return $null
    }
    $e.LastUsed = $Now
    return $e.Text
}

function Set-CachedTranslation {
    param(
        [hashtable]$Memory,
        [string]$Key,
        [string]$Text,
        [DateTime]$Now = (Get-Date)
    )
    $Memory[$Key] = @{ Text = $Text; LastUsed = $Now }
}

function Clear-ExpiredTranslations {
    # Quita las traducciones caducadas. Devuelve cuantas quito.
    param(
        [hashtable]$Memory,
        [double]$Minutes,
        [DateTime]$Now = (Get-Date)
    )

    $quitadas = 0
    foreach ($k in @($Memory.psbase.Keys)) {
        if (-not (Test-CacheFresh -LastUsed $Memory[$k].LastUsed -Now $Now -Minutes $Minutes)) {
            $Memory.Remove($k)
            $quitadas++
        }
    }
    return $quitadas
}
