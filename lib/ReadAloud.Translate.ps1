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
