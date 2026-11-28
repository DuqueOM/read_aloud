#
# ReadAloud.Translate.ps1
# Logica de la traduccion rapida (ADR 0016), sin procesos ni ventanas: la
# direccion, el troceo en parrafos, las peticiones a cada motor, la eleccion
# del traductor y de donde corre, la regla de memoria y la vuelta a la voz
# propia. Todo se prueba con Pester (tests\ReadAloud.Translate.Tests.ps1).
#
# Necesita lib\ReadAloud.Text.ps1 cargado antes (deteccion de idioma, frases
# y bloques).
#
# Solo ASCII: el archivo se carga tambien desde Windows PowerShell 5.1.

# --------------------------------------------------------------------------
# Catalogo de traductores conocidos.
#
# Quality es la media de los dos jueces a ciegas de la fase 0 (ADR 0016,
# escala de 1 a 5). CacheMiB es lo que ocupa su cache de contexto con 4096
# posiciones, aparte del archivo. Pattern reconoce el archivo GGUF en la
# carpeta de modelos. Un GGUF que no esta aqui no se usa: no se sabe su
# plantilla ni su calidad.
# --------------------------------------------------------------------------
$script:RA_TranslatorCatalog = @(
    @{ Id = 'bergamot';          Engine = 'bergamot'; Family = 'bergamot'; Quality = 2.455; CacheMiB = 0;   Pattern = '' }
    @{ Id = 'hymt2-1.8b';        Engine = 'llama';    Family = 'hymt2';    Quality = 3.515; CacheMiB = 256; Pattern = '^Hy-MT2-1\.8B.*\.gguf$' }
    @{ Id = 'hymt2-7b';          Engine = 'llama';    Family = 'hymt2';    Quality = 4.43;  CacheMiB = 512; Pattern = '^Hy-MT2-7B.*\.gguf$' }
    @{ Id = 'translategemma-4b'; Engine = 'llama';    Family = 'tgemma';   Quality = 4.225; CacheMiB = 256; Pattern = '^translategemma-4b.*\.gguf$' }
)

# Nota de cada voz en la misma escala que la traduccion. No se midio con
# jueces: la voz propia es la que el usuario eligio de oido, y Piper la voz
# por defecto. Con estas notas, en el equipo del ADR la prioridad Automatica
# elige la voz propia con Hy-MT2 1.8B en el procesador (7.6 frente a 6.9).
$script:RA_VoiceQuality = @{ qwen = 5.0; piper = 2.5 }

# Penalizaciones de la nota: por cada segundo hasta el primer sonido por
# encima de 1 s, y por cuanto se frena la voz (1.0 = el doble de lenta).
$script:RA_FirstSoundPenalty = 0.3
$script:RA_FirstSoundFree = 1.0
$script:RA_SlowdownPenalty = 2.0

# Tiempos medidos en la fase 0 (ADR 0016), para cuando no hay un perfil del
# equipo: segundos hasta el primer sonido (la mediana de 40, 150 y 500
# palabras) y cuanto se frena la voz. La clave es voz+traductor@donde.
$script:RA_DefaultComboMetrics = @{
    'qwen+bergamot@cpu'           = @{ FirstSound = 4.7;  Slowdown = 0.0 }
    'qwen+hymt2-1.8b@cpu'         = @{ FirstSound = 3.9;  Slowdown = 0.04 }
    'qwen+translategemma-4b@cpu'  = @{ FirstSound = 5.5;  Slowdown = 0.06 }
    'qwen+hymt2-7b@cpu'           = @{ FirstSound = 10.3; Slowdown = 1.42 }
    'piper+bergamot@cpu'          = @{ FirstSound = 1.2;  Slowdown = 0.0 }
    'piper+hymt2-1.8b@cpu'        = @{ FirstSound = 2.5;  Slowdown = 0.0 }
    'piper+hymt2-1.8b@gpu'        = @{ FirstSound = 0.6;  Slowdown = 0.0 }
    'piper+hymt2-7b@gpu'          = @{ FirstSound = 0.7;  Slowdown = 0.0 }
    'piper+translategemma-4b@gpu' = @{ FirstSound = 0.7;  Slowdown = 0.0 }
}

# Regla de memoria (ADR 0016). En la tarjeta: lo libre, menos lo que la voz
# propia toma al leer, debe cubrir el modelo, su cache, el calculo y un
# margen. En el procesador: 1.25 veces el archivo mas 1.5 GB de RAM.
$script:RA_GpuComputeMiB = 400
$script:RA_GpuMarginMiB = 600
$script:RA_RamFactor = 1.25
$script:RA_RamMarginMiB = 1536

$script:RA_LanguageNames = @{ es = 'Spanish'; en = 'English' }

function Get-TranslatorCatalog {
    return $script:RA_TranslatorCatalog
}

# --------------------------------------------------------------------------
# Direccion y troceo.
# --------------------------------------------------------------------------

function Get-TranslationDirection {
    # Ingles -> espanol y espanol -> ingles, con la misma deteccion de idioma
    # que la lectura. Un texto ambiguo usa el idioma de respaldo como origen.
    param(
        [string]$Text,
        [string]$Fallback = 'es'
    )

    $origen = Get-DocumentLanguage -Text $Text -Fallback $Fallback
    $destino = 'es'
    if ($origen -eq 'es') { $destino = 'en' }
    return @{ Source = $origen; Target = $destino }
}

function Split-TranslationParts {
    # Parte el texto en lo que se pide al traductor, bloque por bloque (un
    # parrafo, un titulo, una fila o una vineta). El panel muestra cada bloque
    # traducido con su original debajo: frase por frase no sirve, porque las
    # traducciones no cortan en el mismo sitio.
    #
    # Con -FirstSentence (los modelos de lenguaje) la primera frase del primer
    # bloque va sola, para que la voz empiece pronto, y el resto de ese bloque
    # despues. Un bloque mas largo que MaxChars se parte entre frases.
    # Las lineas de un arbol de carpetas no se traducen.
    #
    # Devuelve Blocks (Index, Kind, Prefix, Source, PauseAfter, Translate) y
    # Parts (Block, Text, First), en el orden en que se piden.
    param(
        [string]$Text,
        [switch]$FirstSentence,
        [int]$MaxChars = 1200,
        [hashtable]$Pauses = $null
    )

    if ($null -eq $Pauses) { $Pauses = Get-DefaultPauses }

    $bloques = New-Object System.Collections.Generic.List[object]
    $partes = New-Object System.Collections.Generic.List[object]
    $primeraPendiente = [bool]$FirstSentence
    $indice = 0

    foreach ($b in (Split-IntoBlocks -Text $Text -Pauses $Pauses)) {
        $texto = [string]$b.Text
        $prefijo = ''
        if ($b.Kind -eq 'titulo') { $texto = $texto -replace '^#{1,6}\s+', '' }
        if ($b.Kind -eq 'vineta') {
            $m = [regex]::Match($texto, '^\s*([-*>]|[0-9]+[\.\)])\s+')
            if ($m.Success) {
                $prefijo = $m.Value.Trim()
                $texto = $texto.Substring($m.Length)
            }
        }
        $texto = $texto.Trim()
        $traducir = ($b.Kind -ne 'arbol') -and ($texto -match '\p{L}')

        [void]$bloques.Add(@{
            Index      = $indice
            Kind       = $b.Kind
            Prefix     = $prefijo
            Source     = $texto
            PauseAfter = [double]$b.PauseAfter
            Translate  = $traducir
        })

        if ($traducir) {
            $frases = (Split-IntoSentences -Text $texto).ToArray()
            $piezas = New-Object System.Collections.Generic.List[string]

            if ($primeraPendiente -and $frases.Count -gt 1 -and $texto.StartsWith($frases[0])) {
                [void]$piezas.Add($frases[0])
                $resto = $texto.Substring($frases[0].Length).Trim()
                $frases = (Split-IntoSentences -Text $resto).ToArray()
            }
            $primeraPendiente = $false

            $actual = ''
            foreach ($f in $frases) {
                if ($actual -ne '' -and ($actual.Length + 1 + $f.Length) -gt $MaxChars) {
                    [void]$piezas.Add($actual)
                    $actual = ''
                }
                if ($actual -eq '') { $actual = $f } else { $actual = "$actual $f" }
            }
            if ($actual -ne '') { [void]$piezas.Add($actual) }

            foreach ($p in $piezas) {
                [void]$partes.Add(@{ Block = $indice; Text = $p; First = ($partes.Count -eq 0) })
            }
        }

        $indice++
    }

    return @{ Blocks = $bloques; Parts = $partes }
}

# --------------------------------------------------------------------------
# Peticiones a los motores.
# --------------------------------------------------------------------------

function Get-TranslationMaxTokens {
    param([string]$Text)
    return [int][Math]::Max(64, [Math]::Floor($Text.Length * 0.8) + 64)
}

function Get-TranslationRequest {
    # Ruta y cuerpo de la peticion a llama-server para cada familia, con la
    # plantilla y el muestreo que recomienda la ficha de cada modelo.
    #  - Hy-MT2: chat con la plantilla del propio modelo (llama-server --jinja).
    #  - TranslateGemma: prompt crudo, sin <bos> (llama-server lo agrega), y
    #    <end_of_turn> como fin, porque el GGUF no lo declara.
    param(
        [string]$Family,
        [string]$Text,
        [string]$Source,
        [string]$Target
    )

    $tope = Get-TranslationMaxTokens -Text $Text
    $de = $script:RA_LanguageNames[$Source]
    $a = $script:RA_LanguageNames[$Target]

    switch ($Family) {
        'hymt2' {
            $instruccion = "Translate the following text into $a. Note that you should only output the " +
                "translated result without any additional explanation:`n`n$Text"
            return @{
                Path = '/v1/chat/completions'
                Body = [ordered]@{
                    messages       = @(@{ role = 'user'; content = $instruccion })
                    stream         = $true
                    max_tokens     = $tope
                    seed           = 1234
                    temperature    = 0.7
                    top_p          = 0.6
                    top_k          = 20
                    repeat_penalty = 1.05
                }
            }
        }
        'tgemma' {
            $prompt = "<start_of_turn>user`nYou are a professional $de ($Source) to $a ($Target) translator. Your goal is " +
                "to accurately convey the meaning and nuances of the original $de text while adhering to $a grammar, " +
                "vocabulary, and cultural sensitivities.`nProduce only the $a translation, without any additional " +
                "explanations or commentary. Please translate the following $de text into ${a}:`n`n`n$($Text.Trim())" +
                "<end_of_turn>`n<start_of_turn>model`n"
            return @{
                Path = '/completion'
                Body = [ordered]@{
                    prompt         = $prompt
                    stream         = $true
                    n_predict      = $tope
                    stop           = @('<end_of_turn>', '<start_of_turn>')
                    seed           = 1234
                    temperature    = 0.0
                    top_k          = 1
                    repeat_penalty = 1.0
                }
            }
        }
        default { throw "Familia de traductor desconocida: $Family" }
    }
}

function ConvertFrom-TranslationStreamLine {
    # Una linea del streaming de llama-server ("data: {...}"). Devuelve el
    # texto nuevo, si es el final y los tiempos que informa el servidor, o
    # $null si la linea no trae nada.
    param(
        [string]$Line,
        [string]$Family
    )

    $l = $Line.Trim()
    if (-not $l.StartsWith('data:')) { return $null }
    $carga = $l.Substring(5).Trim()
    if ($carga -eq '[DONE]') { return @{ Text = ''; Done = $true; Timings = $null } }

    try { $d = $carga | ConvertFrom-Json } catch { return $null }

    $texto = ''
    $fin = $false
    if ($Family -eq 'tgemma') {
        if ($null -ne $d.content) { $texto = [string]$d.content }
        if ($d.stop -eq $true) { $fin = $true }
    } else {
        foreach ($c in @($d.choices)) {
            if ($null -eq $c) { continue }
            if ($null -ne $c.delta -and $null -ne $c.delta.content) { $texto += [string]$c.delta.content }
            if ($c.finish_reason) { $fin = $true }
        }
    }
    return @{ Text = $texto; Done = $fin; Timings = $d.timings }
}

function ConvertTo-BergamotMessage {
    # translateLocally -p: un JSON en UTF-8 con su largo delante, en 4 bytes
    # little-endian.
    param(
        [int]$Id,
        [string]$Command,
        [hashtable]$Data
    )

    $json = ConvertTo-Json -InputObject ([ordered]@{ id = $Id; command = $Command; data = $Data }) -Compress -Depth 5
    $cuerpo = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    $largo = [BitConverter]::GetBytes([uint32]$cuerpo.Length)
    if (-not [BitConverter]::IsLittleEndian) { [Array]::Reverse($largo) }
    $mensaje = New-Object byte[] ($largo.Length + $cuerpo.Length)
    [Array]::Copy($largo, 0, $mensaje, 0, 4)
    [Array]::Copy($cuerpo, 0, $mensaje, 4, $cuerpo.Length)
    return ,$mensaje
}

function Get-BergamotTranslateData {
    param([string]$Text, [string]$Source, [string]$Target)
    return [ordered]@{ src = $Source; trg = $Target; text = $Text; html = $false }
}

# --------------------------------------------------------------------------
# Traductores instalados.
#
# Todo vive en read_aloud_piper\traduccion, fuera del repositorio:
#   translateLocally\translateLocally.exe y su carpeta models (Bergamot)
#   llama\llama-server.exe (la version Vulkan de llama.cpp)
#   modelos\*.gguf
# --------------------------------------------------------------------------

function Get-InstalledTranslators {
    # Los traductores del catalogo que estan instalados, con el tamano real de
    # sus archivos (FileMiB) y su ruta. Un GGUF sin llama-server no sirve.
    param([string]$TranslateDir)

    $lista = New-Object System.Collections.Generic.List[object]
    if (-not $TranslateDir -or -not (Test-Path -LiteralPath $TranslateDir)) { return @() }

    $tl = Join-Path $TranslateDir 'translateLocally'
    $tlExe = Join-Path $tl 'translateLocally.exe'
    $tlModelos = Join-Path $tl 'models'
    if ((Test-Path -LiteralPath $tlExe) -and (Test-Path -LiteralPath $tlModelos)) {
        $bytes = (Get-ChildItem -LiteralPath $tl -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $t = @{} + @($script:RA_TranslatorCatalog | Where-Object { $_.Id -eq 'bergamot' })[0]
        $t.Path = $tlExe
        $t.FileMiB = [Math]::Ceiling([double]$bytes / 1MB)
        [void]$lista.Add($t)
    }

    $servidor = Join-Path $TranslateDir 'llama\llama-server.exe'
    $modelos = Join-Path $TranslateDir 'modelos'
    if ((Test-Path -LiteralPath $servidor) -and (Test-Path -LiteralPath $modelos)) {
        foreach ($f in (Get-ChildItem -LiteralPath $modelos -Filter '*.gguf' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            foreach ($c in $script:RA_TranslatorCatalog) {
                if ($c.Pattern -eq '' -or $f.Name -notmatch $c.Pattern) { continue }
                if (@($lista | Where-Object { $_.Id -eq $c.Id }).Count -gt 0) { break }
                $t = @{} + $c
                $t.Path = $f.FullName
                $t.Server = $servidor
                $t.FileMiB = [Math]::Ceiling([double]$f.Length / 1MB)
                [void]$lista.Add($t)
                break
            }
        }
    }

    return $lista.ToArray()
}

# --------------------------------------------------------------------------
# Eleccion del traductor, de donde corre y de la voz.
#
# Una combinacion es una voz (qwen, la voz propia, o piper) con un traductor
# en un lugar (cpu o gpu): "qwen+hymt2-1.8b@cpu". Cada una tiene una nota:
# la calidad de la traduccion mas la de la voz, menos lo que tarda el primer
# sonido y lo que se frena la voz. Entre las que caben en la memoria, gana la
# de mejor nota, dentro de lo que permitan la calidad, la prioridad de la
# tarjeta y la seccion avanzada de los ajustes.
# --------------------------------------------------------------------------

function Get-TranslatorThreads {
    # min(4, nucleos fisicos / 2): con 8 hilos la voz propia va un 130 % mas
    # lenta; con 4, un 4 % (ADR 0016).
    param([int]$PhysicalCores)
    return [int][Math]::Max(1, [Math]::Min(4, [Math]::Floor($PhysicalCores / 2)))
}

function Get-ComboId {
    param([string]$Voice, [string]$Translator, [string]$Where)
    return ('{0}+{1}@{2}' -f $Voice, $Translator, $Where)
}

function Get-ComboMetrics {
    # Segundos hasta el primer sonido y cuanto se frena la voz. Primero el
    # perfil de este equipo (runtime\perfil_equipo.json), despues las medidas
    # del ADR 0016 y, si la combinacion no se midio, una estimacion.
    param(
        [string]$Voice,
        [hashtable]$Translator,
        [string]$Where,
        $Perfil = $null
    )

    $id = Get-ComboId -Voice $Voice -Translator $Translator.Id -Where $Where

    if ($null -ne $Perfil) {
        $m = $null
        try { $m = $Perfil.combinaciones.$id } catch { $m = $null }
        if ($null -ne $m -and $null -ne $m.primer_sonido_s) {
            $freno = 0.0
            if ($null -ne $m.freno_voz) { $freno = [double]$m.freno_voz }
            return @{ FirstSound = [double]$m.primer_sonido_s; Slowdown = $freno; Source = 'perfil' }
        }
    }

    if ($script:RA_DefaultComboMetrics.ContainsKey($id)) {
        $d = $script:RA_DefaultComboMetrics[$id]
        return @{ FirstSound = [double]$d.FirstSound; Slowdown = [double]$d.Slowdown; Source = 'adr' }
    }

    # Sin medida: el primer sonido de la voz (3.1 s la propia) mas lo que
    # tarda la primera frase en traducirse, que en el procesador crece con el
    # tamano del modelo.
    $voz = 0.5
    if ($Voice -eq 'qwen') { $voz = 3.1 }
    $traductor = 0.5
    $freno = 0.0
    if ($Translator.Engine -eq 'llama') {
        if ($Where -eq 'gpu') {
            $traductor = 0.3
        } else {
            $traductor = 1.0 + ([double]$Translator.FileMiB / 1024)
            if ($Voice -eq 'qwen') { $freno = 0.05 }
        }
    }
    return @{ FirstSound = $voz + $traductor; Slowdown = $freno; Source = 'estimado' }
}

function Get-ComboScore {
    param([double]$Quality, [string]$Voice, [double]$FirstSound, [double]$Slowdown)
    $espera = [Math]::Max(0.0, $FirstSound - $script:RA_FirstSoundFree)
    return $Quality + $script:RA_VoiceQuality[$Voice] - ($script:RA_FirstSoundPenalty * $espera) - ($script:RA_SlowdownPenalty * $Slowdown)
}

function New-VoiceState {
    # Lo que la eleccion necesita saber de la voz propia. Las cifras por
    # defecto son las del ADR 0016: 5.0 GB en la tarjeta en reposo, 1.4 GB mas
    # al leer, y unos 2.3 GB de RAM.
    param(
        [bool]$Available = $false,
        [bool]$Loaded = $false,
        [double]$ResidentMiB = 5120,
        [double]$ReadingMiB = 1434,
        [double]$RamMiB = 2355
    )
    return @{
        QwenAvailable   = $Available
        QwenLoaded      = $Loaded
        QwenResidentMiB = $ResidentMiB
        QwenReadingMiB  = $ReadingMiB
        QwenRamMiB      = $RamMiB
    }
}

function Test-TranslatorFits {
    # La regla de memoria del ADR 0016, antes de cargar un traductor.
    #  - En la tarjeta: lo libre (nvidia-smi), menos lo que la voz propia toma
    #    al leer, igual o mayor que el modelo, su cache, 400 MiB de calculo y
    #    600 MiB de margen. Si la voz propia aun no esta cargada pero va a
    #    leer, tambien se descuenta lo que ocupa en reposo; si va a ceder la
    #    tarjeta, lo suyo cuenta como libre.
    #  - En el procesador: la RAM disponible igual o mayor que 1.25 veces el
    #    archivo mas 1.5 GB (y lo que tomara la voz propia si aun no carga).
    # Devuelve Fits, NeedMiB, HaveMiB y Reason (vacia si cabe).
    param(
        [hashtable]$Translator,
        [string]$Where,
        [hashtable]$Device,
        [hashtable]$Voice,
        [string]$VoiceName = 'piper'
    )

    $r = @{ Fits = $false; NeedMiB = 0.0; HaveMiB = 0.0; Reason = '' }
    $usaQwen = ($VoiceName -eq 'qwen') -and $Voice.QwenAvailable

    if ($Where -eq 'gpu') {
        if ($null -eq $Device.GpuFreeMiB -or [double]$Device.GpuFreeMiB -lt 0) { $r.Reason = 'no hay tarjeta NVIDIA'; return $r }
        if ($Device.GpuBusy) { $r.Reason = 'la tarjeta esta ocupada por otro programa'; return $r }
        $tiene = [double]$Device.GpuFreeMiB
        if ($usaQwen) {
            $tiene -= [double]$Voice.QwenReadingMiB
            if (-not $Voice.QwenLoaded) { $tiene -= [double]$Voice.QwenResidentMiB }
        } elseif ($Voice.QwenAvailable -and $Voice.QwenLoaded) {
            $tiene += [double]$Voice.QwenResidentMiB
        }
        $necesita = [double]$Translator.FileMiB + [double]$Translator.CacheMiB + $script:RA_GpuComputeMiB + $script:RA_GpuMarginMiB
    } else {
        $tiene = [double]$Device.RamAvailableMiB
        if ($usaQwen -and -not $Voice.QwenLoaded) { $tiene -= [double]$Voice.QwenRamMiB }
        $necesita = [Math]::Ceiling($script:RA_RamFactor * [double]$Translator.FileMiB) + $script:RA_RamMarginMiB
    }

    $r.NeedMiB = $necesita
    $r.HaveMiB = $tiene
    $r.Fits = ($tiene -ge $necesita)
    if (-not $r.Fits) {
        $lugar = 'la tarjeta'
        if ($Where -ne 'gpu') { $lugar = 'la RAM' }
        $r.Reason = ('en {0} necesita {1:N0} MiB y hay {2:N0}' -f $lugar, $necesita, $tiene)
    }
    return $r
}

function Select-TranslationCombo {
    # Elige la combinacion para la proxima traduccion.
    #
    # Options: Quality ('auto', 'basic' o 'high'), Priority ('auto', 'voice' o
    # 'translation'; solo cuenta si hay voz propia), Model ('' o el Id de un
    # traductor) y Where ('auto', 'cpu' o 'gpu'). Device: RamAvailableMiB,
    # GpuFreeMiB (-1 sin NVIDIA), GpuBusy y PhysicalCores. Loaded es la
    # combinacion que ya esta cargada: esa cabe sin comprobarla.
    #
    # Devuelve Combo (o $null si no hay traductor), Candidates y Notes, lo que
    # se anota en daemon.log: por que no cupo algo mejor.
    param(
        [object[]]$Translators,
        [hashtable]$Device,
        [hashtable]$Voice,
        [hashtable]$Options,
        $Perfil = $null,
        [string]$Loaded = ''
    )

    $calidad = 'auto'; $prioridad = 'auto'; $modelo = ''; $donde = 'auto'
    if ($Options) {
        if ($Options.Quality) { $calidad = [string]$Options.Quality }
        if ($Options.Priority) { $prioridad = [string]$Options.Priority }
        if ($Options.Model) { $modelo = [string]$Options.Model }
        if ($Options.Where) { $donde = [string]$Options.Where }
    }
    if (-not $Voice) { $Voice = New-VoiceState }
    $conQwen = [bool]$Voice.QwenAvailable

    $voces = @('piper')
    if ($conQwen) { $voces = @('qwen', 'piper') }
    $hilos = Get-TranslatorThreads -PhysicalCores ([int]$Device.PhysicalCores)

    $todos = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($Translators)) {
        if ($null -eq $t) { continue }
        $lugares = @('cpu')
        if ($t.Engine -eq 'llama') { $lugares = @('cpu', 'gpu') }
        foreach ($v in $voces) {
            foreach ($w in $lugares) {
                # Soltar la voz propia solo tiene sentido para dejarle la
                # tarjeta al traductor.
                if ($conQwen -and $v -eq 'piper' -and $w -ne 'gpu') { continue }

                $id = Get-ComboId -Voice $v -Translator $t.Id -Where $w
                $m = Get-ComboMetrics -Voice $v -Translator $t -Where $w -Perfil $Perfil
                if ($id -eq $Loaded) {
                    $cabe = @{ Fits = $true; NeedMiB = 0.0; HaveMiB = 0.0; Reason = '' }
                } else {
                    $cabe = Test-TranslatorFits -Translator $t -Where $w -Device $Device -Voice $Voice -VoiceName $v
                }

                $permitido = $true
                if ($calidad -eq 'basic' -and $t.Engine -ne 'bergamot') { $permitido = $false }
                if ($calidad -eq 'high' -and $t.Engine -ne 'llama') { $permitido = $false }
                if ($t.Engine -eq 'llama' -and $modelo -ne '' -and $t.Id -ne $modelo) { $permitido = $false }
                if ($t.Engine -eq 'llama' -and $donde -ne 'auto' -and $w -ne $donde) { $permitido = $false }
                if ($conQwen -and $prioridad -eq 'voice' -and $v -ne 'qwen') { $permitido = $false }

                [void]$todos.Add(@{
                    Id         = $id
                    Voice      = $v
                    Translator = $t
                    Where      = $w
                    Threads    = $hilos
                    Score      = (Get-ComboScore -Quality $t.Quality -Voice $v -FirstSound $m.FirstSound -Slowdown $m.Slowdown)
                    Metrics    = $m
                    Fits       = [bool]$cabe.Fits
                    Reason     = $cabe.Reason
                    Allowed    = $permitido
                })
            }
        }
    }

    $notas = New-Object System.Collections.Generic.List[string]
    $ordenar = {
        param($Lista)
        return @($Lista | Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { [double]$_.Translator.FileMiB }; Descending = $false })
    }

    $permitidos = @($todos | Where-Object { $_.Allowed })
    $elegibles = @($permitidos | Where-Object { $_.Fits })

    if ($conQwen -and $prioridad -eq 'translation') {
        $sinVoz = @($elegibles | Where-Object { $_.Voice -eq 'piper' })
        if ($sinVoz.Count -gt 0) {
            $elegibles = $sinVoz
        } elseif ($elegibles.Count -gt 0) {
            [void]$notas.Add('Prioridad de traduccion: ningun traductor cabe en la tarjeta; se traduce junto a la voz propia.')
        }
    }

    $elegido = $null
    if ($elegibles.Count -gt 0) {
        $elegido = @(& $ordenar $elegibles)[0]
    } else {
        # Nada de lo permitido cabe: Bergamot ocupa poco y sirve de ultimo
        # recurso, aunque la calidad pidiera la alta.
        $basicos = @($todos | Where-Object { $_.Translator.Engine -eq 'bergamot' -and ($_.Voice -eq 'qwen' -or -not $conQwen) })
        if ($basicos.Count -gt 0) {
            $elegido = $basicos[0]
            [void]$notas.Add('Ningun traductor elegido cabe en la memoria: se usa el basico (Bergamot).')
        } elseif ($permitidos.Count -gt 0) {
            [void]$notas.Add('Ningun traductor cabe en la memoria y no esta instalado el basico.')
        } else {
            [void]$notas.Add('No hay ningun traductor instalado que se pueda usar con estos ajustes.')
        }
    }

    if ($null -ne $elegido) {
        foreach ($c in @(& $ordenar $permitidos)) {
            if ($c.Score -le $elegido.Score) { break }
            if (-not $c.Fits) { [void]$notas.Add(('No cabe {0}: {1}.' -f $c.Id, $c.Reason)) }
        }
    }

    return @{ Combo = $elegido; Candidates = $todos; Notes = $notas }
}

function Test-PriorityChoiceNeeded {
    # La prioridad de la tarjeta solo aparece en los ajustes cuando hay voz
    # propia y el mejor traductor instalado no cabe a su lado, ni en la
    # tarjeta ni en el procesador.
    param(
        [object[]]$Translators,
        [hashtable]$Device,
        [hashtable]$Voice
    )

    if (-not $Voice -or -not $Voice.QwenAvailable) { return $false }
    $mejor = @($Translators | Where-Object { $null -ne $_ } | Sort-Object -Property @{ Expression = { $_.Quality }; Descending = $true })
    if ($mejor.Count -eq 0) { return $false }
    $t = $mejor[0]
    $lugares = @('cpu')
    if ($t.Engine -eq 'llama') { $lugares = @('cpu', 'gpu') }
    foreach ($w in $lugares) {
        if ((Test-TranslatorFits -Translator $t -Where $w -Device $Device -Voice $Voice -VoiceName 'qwen').Fits) { return $false }
    }
    return $true
}

# --------------------------------------------------------------------------
# Vuelta a la voz propia.
# --------------------------------------------------------------------------

function Get-VoiceReturnState {
    # Si la voz propia cedio la tarjeta al traductor, cuando vuelve.
    #  - Con la prioridad Traduccion o Automatica y "Volver sola a la voz
    #    propia" activada, tras Minutes sin traducir.
    #  - Con la prioridad Voz propia, enseguida (se acaba de cambiar).
    #  - Nunca a mitad de una lectura: espera a que termine.
    # Devuelve Due (volver ya), Active (hay una cuenta atras) y SecondsLeft.
    param(
        [bool]$VoiceYielded,
        [string]$Priority = 'auto',
        [bool]$AutoReturn = $true,
        [double]$Minutes = 15,
        [DateTime]$LastTranslation,
        [DateTime]$Now,
        [bool]$Reading = $false
    )

    $r = @{ Due = $false; Active = $false; SecondsLeft = -1.0 }
    if (-not $VoiceYielded) { return $r }

    if ($Priority -eq 'voice') {
        $r.SecondsLeft = 0.0
        $r.Due = -not $Reading
        return $r
    }
    if (-not $AutoReturn) { return $r }
    if ($Priority -ne 'translation' -and $Priority -ne 'auto') { return $r }

    $r.Active = $true
    $quedan = ([Math]::Max(1.0, $Minutes) * 60.0) - ($Now - $LastTranslation).TotalSeconds
    $r.SecondsLeft = [Math]::Max(0.0, $quedan)
    $r.Due = ($quedan -le 0) -and (-not $Reading)
    return $r
}

# --------------------------------------------------------------------------
# Los traductores en el proceso residente: los argumentos de llama-server, la
# memoria de la tarjeta, que abrir o cerrar para cada combinacion, cuando
# cede la tarjeta y el texto traducido entero.
# --------------------------------------------------------------------------

# El traductor en la tarjeta la cede como la voz propia (lib\servidor_qwen.py):
# si tras un minuto sin traducir otro programa usa 1.5 GB mas que al cargar.
$script:RA_YieldQuietSeconds = 60
$script:RA_YieldOthersMiB = 1536

function ConvertFrom-VulkanDeviceList {
    # La salida de "llama-server --list-devices", con lineas como
    # "  Vulkan0: NVIDIA GeForce RTX ... (8151 MiB, 7000 MiB free)". Devuelve
    # el nombre del dispositivo de la NVIDIA, o '' si no hay. Sin fijarlo, la
    # version Vulkan reparte las capas con los graficos integrados, que van
    # cuatro veces mas lentos que el procesador.
    param([string[]]$Lines)

    foreach ($l in @($Lines)) {
        $m = [regex]::Match([string]$l, '^\s*(Vulkan\d+)\s*:\s*(.*)$')
        if ($m.Success -and $m.Groups[2].Value -match 'NVIDIA') { return $m.Groups[1].Value }
    }
    return ''
}

function ConvertFrom-NvidiaSmiMemory {
    # Las lineas de "nvidia-smi --query-gpu=memory.free,memory.used,memory.total
    # --format=csv,noheader,nounits": la tarjeta con mas memoria libre, en
    # MiB. Sin ninguna linea valida, FreeMiB es -1 (no hay NVIDIA).
    param([string[]]$Lines)

    $invariante = [Globalization.CultureInfo]::InvariantCulture
    $r = @{ FreeMiB = -1.0; UsedMiB = 0.0; TotalMiB = 0.0 }
    foreach ($l in @($Lines)) {
        $c = @(([string]$l).Split(',') | ForEach-Object { $_.Trim() })
        if ($c.Count -lt 3) { continue }
        $v = @(0.0, 0.0, 0.0)
        $ok = $true
        for ($i = 0; $i -lt 3; $i++) {
            $n = 0.0
            if (-not [double]::TryParse($c[$i], [Globalization.NumberStyles]::Float, $invariante, [ref]$n)) { $ok = $false; break }
            $v[$i] = $n
        }
        if ($ok -and $v[0] -gt $r.FreeMiB) { $r = @{ FreeMiB = $v[0]; UsedMiB = $v[1]; TotalMiB = $v[2] } }
    }
    return $r
}

function Get-LlamaServerArgs {
    # Los argumentos de llama-server para un traductor (ADR 0016):
    #  - en el procesador, --device none y los hilos de Get-TranslatorThreads;
    #  - en la tarjeta, todas las capas en la NVIDIA (su dispositivo Vulkan) y
    #    sin mapear el archivo, que si no se queda tambien en la RAM;
    #  - --fit off, porque la regla de memoria ya decidio que cabe;
    #  - 4096 posiciones y una sola ranura;
    #  - --cache-ram 0: la cache de prompts en la RAM llega a 8 GB por defecto;
    #  - --jinja para Hy-MT2, que usa la plantilla del propio modelo;
    #  - solo en 127.0.0.1 y --offline: nunca sale a internet.
    param(
        [hashtable]$Translator,
        [string]$Where,
        [int]$Threads,
        [int]$Port,
        [string]$Device = '',
        [string]$LogFile = '',
        [int]$Context = 4096
    )

    $a = New-Object System.Collections.Generic.List[string]
    foreach ($x in @(
        '-m', $Translator.Path, '-c', $Context, '-np', 1, '-t', $Threads, '-tb', $Threads,
        '--host', '127.0.0.1', '--port', $Port, '--no-webui', '--offline',
        '--fit', 'off', '--cache-ram', 0, '--log-colors', 'off'
    )) { [void]$a.Add([string]$x) }

    if ($Where -eq 'gpu') {
        if (-not $Device) { throw 'Falta el dispositivo Vulkan de la tarjeta NVIDIA.' }
        foreach ($x in @('-dev', $Device, '-ngl', 99, '-lm', 'none')) { [void]$a.Add([string]$x) }
    } else {
        foreach ($x in @('-dev', 'none', '-ngl', 0)) { [void]$a.Add([string]$x) }
    }
    if ($Translator.Family -eq 'hymt2') { [void]$a.Add('--jinja') }
    if ($LogFile) { [void]$a.Add('--log-file'); [void]$a.Add($LogFile) }
    return $a.ToArray()
}

function ConvertTo-CommandLine {
    # Une los argumentos en una linea de ordenes de Windows, con comillas en
    # los que tienen espacios (las rutas).
    param([string[]]$Arguments)

    $partes = foreach ($x in @($Arguments)) {
        $s = [string]$x
        if ($s -eq '' -or $s -match '[\s"]') { '"' + ($s -replace '"', '\"') + '"' } else { $s }
    }
    return (@($partes) -join ' ')
}

function Test-GpuBusyFile {
    # La marca gpu_ocupada (BusyFile de Get-QwenVoice): un paso pesado de la
    # voz personalizada usa la tarjeta mientras su proceso siga vivo. La marca
    # de un proceso que ya termino no cuenta.
    param([string]$BusyFile)

    if (-not $BusyFile -or -not (Test-Path -LiteralPath $BusyFile)) { return $false }
    try {
        $dueno = [int]((Get-Content -LiteralPath $BusyFile -Raw -ErrorAction Stop).Trim())
        return $null -ne (Get-Process -Id $dueno -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Get-TranslatorTransition {
    # Que abrir o cerrar para traducir con la combinacion elegida, segun lo
    # que ya esta cargado. Server es el llama-server abierto (@{ Id; Where })
    # o $null; VoiceHeld, si la voz propia ya le cedio la tarjeta.
    #  - StopServer y StartServer: un llama-server con otro modelo o en otro
    #    lugar se cierra antes de abrir el nuevo. Con Bergamot, el que corre en
    #    el procesador se queda hasta que pase su rato sin uso.
    #  - StartBergamot: translateLocally, si se traduce con el y no esta abierto.
    #  - HoldVoice: la combinacion lee con Piper y hay voz propia, que tiene
    #    que cederle la tarjeta. Hay que esperar a que se cierre antes de
    #    cargar nada en la tarjeta.
    #  - ReleaseVoice: la combinacion vuelve a la voz propia. Con la prioridad
    #    Traduccion no: ahi solo vuelve con Get-VoiceReturnState. Lo que haya
    #    en la tarjeta se cierra antes, para dejarle sitio.
    param(
        [hashtable]$Combo,
        $Server = $null,
        [bool]$BergamotRunning = $false,
        [bool]$VoiceHeld = $false,
        [bool]$QwenAvailable = $false,
        [string]$Priority = 'auto'
    )

    $r = @{ StopServer = $false; StartServer = $false; StartBergamot = $false; HoldVoice = $false; ReleaseVoice = $false }
    if ($null -eq $Combo) { return $r }

    $t = $Combo.Translator
    $mismo = ($null -ne $Server) -and ($t.Engine -eq 'llama') -and ($Server.Id -eq $t.Id) -and ($Server.Where -eq $Combo.Where)
    if ($t.Engine -eq 'llama' -and -not $mismo) {
        $r.StartServer = $true
        if ($null -ne $Server) { $r.StopServer = $true }
    }
    if ($t.Engine -eq 'bergamot' -and -not $BergamotRunning) { $r.StartBergamot = $true }

    if ($QwenAvailable) {
        if ($Combo.Voice -eq 'piper' -and -not $VoiceHeld) { $r.HoldVoice = $true }
        if ($Combo.Voice -eq 'qwen' -and $VoiceHeld -and $Priority -ne 'translation') {
            $r.ReleaseVoice = $true
            if ($null -ne $Server -and $Server.Where -eq 'gpu' -and -not $mismo) { $r.StopServer = $true }
        }
    }
    return $r
}

function Test-GpuServerYield {
    # Si el traductor en la tarjeta debe cederla, como la voz propia: un paso
    # pesado dejo la marca gpu_ocupada, o, tras un minuto sin traducir, otro
    # programa usa 1.5 GB mas que cuando cargo el traductor (o que lo menos
    # que se le vio usar despues). AllowanceMiB es lo que se tolera de mas:
    # lo que la voz propia toma al leer, si esta abierta a la vez.
    # UsedMiB es la memoria usada de la tarjeta (nvidia-smi); BaselineMiB, la
    # base anterior (-1 si aun no hay). Devuelve Yield, Reason y la base
    # nueva.
    param(
        [double]$UsedMiB,
        [double]$BaselineMiB = -1,
        [bool]$Busy = $false,
        [double]$QuietSeconds = 0,
        [double]$AllowanceMiB = 0
    )

    $r = @{ Yield = $false; Reason = ''; Baseline = $BaselineMiB }
    if ($Busy) {
        $r.Yield = $true
        $r.Reason = 'un paso pesado marco la tarjeta como ocupada'
        return $r
    }
    if ($UsedMiB -lt 0) { return $r }
    if ($BaselineMiB -lt 0 -or $UsedMiB -lt $BaselineMiB) { $r.Baseline = $UsedMiB }

    $otros = $UsedMiB - $r.Baseline
    if ($QuietSeconds -ge $script:RA_YieldQuietSeconds -and $otros -ge ($script:RA_YieldOthersMiB + $AllowanceMiB)) {
        $r.Yield = $true
        $r.Reason = ('otro programa usa {0:N0} MiB mas de la tarjeta' -f $otros)
    }
    return $r
}

function Test-TranslatorIdle {
    # El traductor se cierra tras Minutes sin traducir (0 es nunca). Con
    # -Keep no: el que esta en la tarjeta porque la voz propia se la cedio se
    # queda hasta que la voz vuelva.
    param(
        [DateTime]$LastUse,
        [DateTime]$Now,
        [double]$Minutes,
        [bool]$Keep = $false
    )

    if ($Keep -or $Minutes -le 0) { return $false }
    return ($Now - $LastUse).TotalMinutes -ge $Minutes
}

function Format-PartTranslation {
    # Lo que devuelve el traductor para una parte: sin espacios en los bordes
    # y en una sola linea, porque cada parte es de un solo bloque.
    param([string]$Text)
    return ((([string]$Text) -replace '\s*[\r\n]+\s*', ' ').Trim())
}

function Join-TranslatedBlocks {
    # El texto traducido entero, para leerlo: un bloque por parrafo, cada
    # vineta con su marca y lo que no se traduce (los arboles de carpetas),
    # tal cual. Translations lleva el texto de cada bloque por su indice; un
    # bloque sin traduccion se deja en el original.
    param(
        [object[]]$Blocks,
        [hashtable]$Translations
    )

    $salida = New-Object System.Collections.Generic.List[string]
    foreach ($b in @($Blocks)) {
        if ($null -eq $b) { continue }
        $texto = [string]$b.Source
        if ($b.Translate -and $null -ne $Translations -and $Translations.ContainsKey([int]$b.Index)) {
            $texto = [string]$Translations[[int]$b.Index]
        }
        if ($b.Prefix) { $texto = $b.Prefix + ' ' + $texto }
        $texto = $texto.Trim()
        if ($texto -ne '') { [void]$salida.Add($texto) }
    }
    return ($salida -join "`n`n")
}

# --------------------------------------------------------------------------
# La lectura de una traduccion (parte 4): que se lee y como crece.
# --------------------------------------------------------------------------

function Get-TranslationReadingMode {
    # Que se lee de una traduccion y con que voz. Normalmente, la traduccion,
    # con la voz del idioma de destino, y el original va debajo. En el modo
    # practica, si el original es ingles, se lee el original y la traduccion
    # queda debajo: la voz siempre es la inglesa.
    param(
        [string]$Source,
        [string]$Target,
        [bool]$Practice = $false
    )

    if ($Practice -and $Source -eq 'en') {
        return @{ ReadOriginal = $true; Lang = 'en'; Requested = 'English' }
    }
    $pedido = 'Spanish'
    if ($Target -eq 'en') { $pedido = 'English' }
    return @{ ReadOriginal = $false; Lang = $Target; Requested = $pedido }
}

function Test-PartClosesBlock {
    # Si la parte Index es la ultima de su bloque: la que lleva despues la
    # pausa de fin de parrafo. PartBlocks es el bloque de cada parte, en orden.
    param(
        [int[]]$PartBlocks,
        [int]$Index
    )

    if ($null -eq $PartBlocks -or $Index -lt 0 -or $Index -ge $PartBlocks.Count) { return $true }
    if ($Index + 1 -ge $PartBlocks.Count) { return $true }
    return ($PartBlocks[$Index + 1] -ne $PartBlocks[$Index])
}

function ConvertTo-ReadingChunks {
    # Los fragmentos de un trozo de texto (una parte traducida, o el bloque
    # original en el modo practica) para anadirlos a la lectura en curso.
    # PlanChunks sale de Build-SpeechPlan sobre ese trozo: todos pasan al
    # bloque Block del panel, con su tipo, y solo el ultimo lleva la pausa del
    # bloque, si el trozo lo cierra.
    param(
        [object[]]$PlanChunks,
        [int]$Block,
        [string]$Kind = 'parrafo',
        [bool]$ClosesBlock = $true,
        [double]$PauseAfter = 0.0
    )

    $salida = New-Object System.Collections.Generic.List[object]
    foreach ($c in @($PlanChunks)) {
        if ($null -eq $c) { continue }
        $n = @{} + $c
        $n.Block = $Block
        $n.Kind = $Kind
        $n.PauseAfter = 0.0
        [void]$salida.Add($n)
    }
    if ($ClosesBlock -and $salida.Count -gt 0) { $salida[$salida.Count - 1].PauseAfter = $PauseAfter }
    return $salida.ToArray()
}

function Get-PartFirstChunkChars {
    # El primer fragmento de la lectura entera es corto, para que suene
    # pronto. Las partes siguientes ya no empiezan la lectura: con el tope
    # maximo desde su primer fragmento no se trocean de mas.
    param(
        [bool]$StartsReading,
        [int]$FirstChunkChars = 70,
        [int]$MaxChunkChars = 180
    )
    if ($StartsReading) { return $FirstChunkChars }
    return $MaxChunkChars
}

function Format-TranslationBadge {
    # La etiqueta del idioma en el reproductor: "EN > ES" mientras se lee una
    # traduccion.
    param([string]$Source, [string]$Target)
    return ('{0} {1} {2}' -f $Source.ToUpperInvariant(), [char]0x203A, $Target.ToUpperInvariant())
}

function Format-VoiceReturnNotice {
    # El aviso del reproductor cuando la voz propia cedio la tarjeta al
    # traductor. Devuelve el texto en espanol (la clave de la traduccion de
    # la interfaz) y los minutos, o '' si no hay nada que avisar.
    param(
        [bool]$VoiceHeld,
        [bool]$ReturnActive,
        [double]$SecondsLeft = -1
    )

    if (-not $VoiceHeld) { return @{ Text = ''; Minutes = 0 } }
    if ($ReturnActive -and $SecondsLeft -ge 0) {
        $min = [int][Math]::Ceiling($SecondsLeft / 60.0)
        if ($min -le 1) { return @{ Text = 'Voz propia en pausa: vuelve en menos de un minuto'; Minutes = 1 } }
        return @{ Text = 'Voz propia en pausa: vuelve en {0} min'; Minutes = $min }
    }
    return @{ Text = 'Voz propia en pausa mientras traduces'; Minutes = 0 }
}

# --------------------------------------------------------------------------
# Medir este equipo (parte 5): runtime\perfil_equipo.json.
#
# El primer sonido de una combinacion es lo que tarda la voz en dar su primer
# audio mas lo que tarda el traductor en traducir la primera frase. Lo de la
# voz sale de las lecturas normales que ya estan en daemon.log; lo del
# traductor se mide en el momento, con cada traductor que cabe. Cuanto se
# frena la voz no se mide: se toma del ADR 0016 o de la estimacion.
# --------------------------------------------------------------------------

$script:RA_DefaultVoiceFirstSound = @{ qwen = 3.1; piper = 0.5 }

# Tres primeras frases distintas, de un largo parecido: con la misma frase
# tres veces, translateLocally y llama-server reutilizan lo de la vez
# anterior y la medida sale demasiado buena.
$script:RA_MeasureSentences = @(
    'The meeting was moved to Thursday because the room is not available this week.'
    'Please bring your laptop and the latest report before you come to the office.'
    'We will review the deployment plan and the open issues after the short break.'
)

function Get-MeasureSentences {
    return $script:RA_MeasureSentences
}

function Get-Median {
    param([double[]]$Values)
    $v = @($Values | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    $m = [int][Math]::Floor($v.Count / 2)
    if ($v.Count % 2 -eq 1) { return [double]$v[$m] }
    return ([double]$v[$m - 1] + [double]$v[$m]) / 2.0
}

function Get-VoiceFirstSoundFromLog {
    # El primer sonido de cada voz en las lecturas normales del registro: la
    # mediana de las ultimas Last esperas de arranque con ese motor. Las de una
    # traduccion no cuentan (incluyen lo que tarda el traductor) ni las del
    # audio guardado. Con menos de MinSamples, la cifra del ADR 0016.
    param(
        [string[]]$Lines,
        [int]$Last = 20,
        [int]$MinSamples = 3
    )

    $muestras = @{ qwen = New-Object System.Collections.Generic.List[double]; piper = New-Object System.Collections.Generic.List[double] }
    $normales = @{}
    $inv = [Globalization.CultureInfo]::InvariantCulture
    foreach ($l in @($Lines)) {
        if ($null -eq $l) { continue }
        if ($l -match '  Inicio\.') { $normales = @{}; continue }
        $m = [regex]::Match($l, '  Lectura (\d+): ')
        if ($m.Success) { $normales[$m.Groups[1].Value] = $true; continue }
        $m = [regex]::Match($l, 'Espera de audio: lectura (\d+), fragmento 1 de \d+, ([0-9.]+) s \(arranque\), motor (\w+)')
        if ($m.Success -and $normales.ContainsKey($m.Groups[1].Value)) {
            $motor = $m.Groups[3].Value
            if ($muestras.ContainsKey($motor)) { [void]$muestras[$motor].Add([double]::Parse($m.Groups[2].Value, $inv)) }
        }
    }

    $salida = @{}
    foreach ($motor in @('qwen', 'piper')) {
        $lista = $muestras[$motor]
        $desde = [Math]::Max(0, $lista.Count - $Last)
        $ultimas = [double[]]@(for ($i = $desde; $i -lt $lista.Count; $i++) { $lista[$i] })
        if ($ultimas.Count -ge $MinSamples) {
            $salida[$motor] = @{ Seconds = (Get-Median -Values $ultimas); Samples = $ultimas.Count; Source = 'registro' }
        } else {
            $salida[$motor] = @{ Seconds = $script:RA_DefaultVoiceFirstSound[$motor]; Samples = $ultimas.Count; Source = 'adr' }
        }
    }
    return $salida
}

function Get-ReferenceVoiceFirstSound {
    # El primer sonido de cada voz en la prueba controlada del ADR 0016. Es el
    # que se suma al del traductor: las combinaciones que no se miden usan las
    # cifras del ADR, y mezclar con ellas lo que tarda la voz en el uso diario
    # (otros programas, grupos largos) haria parecer peor a la voz propia solo
    # por haberse medido.
    return @{
        qwen  = @{ Seconds = $script:RA_DefaultVoiceFirstSound.qwen; Samples = 0; Source = 'referencia' }
        piper = @{ Seconds = $script:RA_DefaultVoiceFirstSound.piper; Samples = 0; Source = 'referencia' }
    }
}

function New-DeviceProfile {
    # El perfil del equipo con lo medido. Measured: una entrada por traductor
    # y lugar (Translator, el hashtable del catalogo; Where; Seconds, lo que
    # tardo la primera frase). VoiceFirstSound: lo que se suma de la voz
    # (Get-ReferenceVoiceFirstSound). ObservedVoice, opcional, es lo que la
    # voz tarda en el uso diario (Get-VoiceFirstSoundFromLog): queda en el
    # perfil como dato, sin contar en la nota.
    # Solo se escriben las combinaciones que Select-TranslationCombo puede
    # elegir: sin voz propia, todas con Piper; con ella, Piper solo con el
    # traductor en la tarjeta (la voz propia cede la tarjeta).
    param(
        [object[]]$Measured,
        [hashtable]$VoiceFirstSound,
        [bool]$QwenAvailable,
        [hashtable]$ObservedVoice = $null,
        [DateTime]$Now = (Get-Date)
    )

    $combinaciones = [ordered]@{}
    $voces = @('piper')
    if ($QwenAvailable) { $voces = @('qwen', 'piper') }
    foreach ($m in @($Measured)) {
        if ($null -eq $m) { continue }
        foreach ($v in $voces) {
            if ($QwenAvailable -and $v -eq 'piper' -and $m.Where -ne 'gpu') { continue }
            $id = Get-ComboId -Voice $v -Translator $m.Translator.Id -Where $m.Where
            $sinPerfil = Get-ComboMetrics -Voice $v -Translator $m.Translator -Where $m.Where
            $voz = [double]$VoiceFirstSound[$v].Seconds
            $combinaciones[$id] = [ordered]@{
                primer_sonido_s = [Math]::Round($voz + [double]$m.Seconds, 3)
                traductor_s     = [Math]::Round([double]$m.Seconds, 3)
                voz_s           = [Math]::Round($voz, 2)
                freno_voz       = [double]$sinPerfil.Slowdown
                fuente_freno    = [string]$sinPerfil.Source
            }
        }
    }

    $vozPerfil = [ordered]@{}
    foreach ($v in @('qwen', 'piper')) {
        $e = [ordered]@{ primer_sonido_s = [double]$VoiceFirstSound[$v].Seconds; fuente = [string]$VoiceFirstSound[$v].Source }
        if ($null -ne $ObservedVoice -and $null -ne $ObservedVoice[$v]) {
            $e.uso_diario_s = [double]$ObservedVoice[$v].Seconds
            $e.uso_diario_muestras = [int]$ObservedVoice[$v].Samples
            $e.uso_diario_fuente = [string]$ObservedVoice[$v].Source
        }
        $vozPerfil[$v] = $e
    }
    return [ordered]@{
        version       = 1
        fecha         = $Now.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        voz           = $vozPerfil
        combinaciones = $combinaciones
    }
}
