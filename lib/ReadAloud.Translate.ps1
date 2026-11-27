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
