#

# ReadAloud.Text.ps1
# Deteccion de idioma, segmentacion por idioma y normalizacion del texto.
# Se carga con dot-sourcing desde read_aloud.ps1 y read_aloud_daemon.ps1.
#
# Todo el archivo es ASCII a proposito, salvo el diccionario de terminos que
# vive en config\terms_es.tsv. Asi el script funciona igual sin importar la
# codificacion con que lo abra Windows PowerShell.

# --------------------------------------------------------------------------
# Palabras funcionales. Solo se incluyen palabras claramente de un idioma.
# Las ambiguas ("a", "no", "me", "son", "van") se omiten a proposito: en la
# version anterior inflaban el puntaje del espanol en textos que eran ingles.
# --------------------------------------------------------------------------

$script:RA_SpanishStops = @(
    'que','de','la','el','en','los','se','del','las','un','por','con','una','su','para','es','al','lo',
    'como','mas','pero','sus','le','ya','este','esta','esto','estos','estas','tambien','cuando','muy',
    'todo','todos','toda','todas','porque','hay','ser','fue','han','sin','sobre','quien','donde','desde',
    'hasta','ni','nos','les','ellos','ella','aunque','entre','cada','mismo','tiene','tienen','hacer',
    'puede','pueden','debe','deben','asi','entonces','ademas','sino','segun','ante','tras','durante',
    'mientras','siempre','nunca','tanto','cual','cuales','otro','otra','otros','otras','algun','alguna',
    'nuestro','nuestra','vamos','estan','estaba','habia','seria','sera','hacia','dentro','fuera','luego',
    'ahora','antes','despues','aqui','alli','solamente','tal','vez','poco','mucho','bien','mejor'
)

$script:RA_EnglishStops = @(
    'the','be','to','of','and','in','that','have','it','for','not','on','with','as','you','do','at',
    'this','but','his','by','from','they','we','say','her','she','or','an','will','my','one','all',
    'would','there','their','is','are','what','which','when','can','if','about','more','use','how',
    'was','were','has','had','been','being','into','than','then','them','its','our','your','who','why',
    'because','should','could','also','only','just','like','make','need','want','get','these','those',
    'each','other','some','any','most','such','through','while','after','before','between','both',
    'does','did','doing','here','where','very','much','many','few','first','next','last','new','same',
    'over','under','again','still','even','well','back','down','out','off','own','said','made','does'
)

# Marcas ortograficas exclusivas del espanol, construidas por codigo.
$script:RA_SpanishChars = @(
    [char]0x00E1, [char]0x00E9, [char]0x00ED, [char]0x00F3, [char]0x00FA,
    [char]0x00C1, [char]0x00C9, [char]0x00CD, [char]0x00D3, [char]0x00DA,
    [char]0x00F1, [char]0x00D1, [char]0x00BF, [char]0x00A1
)

$script:RA_TermMap = $null
$script:RA_TermLookup = @{}
$script:RA_TermRegex = $null

function Remove-Diacritics {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object Text.StringBuilder

    foreach ($ch in $normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($ch)
        }
    }

    return $builder.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function Get-LanguageProfile {
    # Devuelve puntajes normalizados por numero de palabras, no conteos brutos.
    # Normalizar es lo que permite comparar una frase corta contra un parrafo
    # largo, que es justo lo que hace falta para decidir idioma frase por frase.
    param([string]$Text)

    $tokens = @(
        ($Text -split '[^\p{L}\p{N}]+') |
            Where-Object { $_ -ne '' } |
            ForEach-Object { (Remove-Diacritics $_).ToLowerInvariant() }
    )

    $tokenCount = $tokens.Count
    if ($tokenCount -eq 0) {
        return @{ Lang = 'unknown'; EsScore = 0.0; EnScore = 0.0; Tokens = 0 }
    }

    $esHits = 0.0
    $enHits = 0.0

    foreach ($t in $tokens) {
        if ($script:RA_SpanishStops -contains $t) { $esHits += 1.0 }
        if ($script:RA_EnglishStops -contains $t) { $enHits += 1.0 }
    }

    # Senales ortograficas y morfologicas, con tope para que un texto largo no
    # quede decidido por un solo tipo de evidencia.
    $esSignal = 0.0
    foreach ($ch in $script:RA_SpanishChars) {
        if ($Text.IndexOf($ch) -ge 0) { $esSignal += 1.5 }
    }
    if ($esSignal -gt 4.5) { $esSignal = 4.5 }

    $esMorph = ([regex]::Matches($Text, '(?i)\b\p{L}+(cion|ciones|dad|mente|ando|iendo|aron|aban)\b')).Count
    if ($esMorph -gt 4) { $esMorph = 4 }

    $enMorph = ([regex]::Matches($Text, "(?i)\b\p{L}+(ing|tion|ness|ment|ful|less)\b")).Count
    $enMorph += ([regex]::Matches($Text, "\b\p{L}+'s\b")).Count
    if ($enMorph -gt 4) { $enMorph = 4 }

    $esScore = ($esHits + $esSignal + $esMorph) / $tokenCount
    $enScore = ($enHits + $enMorph) / $tokenCount

    $lang = 'unknown'
    if (($esScore -ge 0.10) -and ($esScore -gt ($enScore * 1.3))) {
        $lang = 'es'
    } elseif (($enScore -ge 0.10) -and ($enScore -gt ($esScore * 1.3))) {
        $lang = 'en'
    }

    return @{ Lang = $lang; EsScore = $esScore; EnScore = $enScore; Tokens = $tokenCount }
}

function Get-DocumentLanguage {
    param(
        [string]$Text,
        [string]$Requested = 'Auto',
        [string]$Fallback = 'es'
    )

    if ($Requested -eq 'Spanish') { return 'es' }
    if ($Requested -eq 'English') { return 'en' }

    $profile = Get-LanguageProfile -Text $Text
    if ($profile.Lang -ne 'unknown') { return $profile.Lang }

    return $Fallback
}

function Split-IntoSentences {
    param([string]$Text)

    $t = $Text -replace "`r`n", "`n"
    $t = $t -replace "`r", "`n"
    $sentences = New-Object System.Collections.Generic.List[string]

    foreach ($line in ($t -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '') { continue }

        foreach ($piece in [regex]::Split($trimmed, '(?<=[\.\!\?])\s+')) {
            $p = $piece.Trim()
            if ($p -ne '') { [void]$sentences.Add($p) }
        }
    }

    return ,$sentences
}

function Split-IntoLanguageSegments {
    # Agrupa frases contiguas del mismo idioma. Cambiar de voz cuesta
    # naturalidad, asi que solo se cambia con evidencia fuerte: la frase
    # necesita un minimo de palabras y un idioma claro. Un termino suelto en
    # ingles dentro de una frase en espanol no fuerza el cambio; de eso se
    # encarga el diccionario de terminos.
    param(
        [string]$Text,
        [string]$DocumentLang = 'es',
        [string]$Requested = 'Auto',
        [int]$MinTokensToSwitch = 5
    )

    $segments = New-Object System.Collections.Generic.List[object]
    $sentences = Split-IntoSentences -Text $Text

    if ($sentences.Count -eq 0) {
        [void]$segments.Add(@{ Lang = $DocumentLang; Text = $Text; Sentences = @($Text) })
        return ,$segments
    }

    # Con idioma forzado no hay nada que segmentar: todo va a una sola voz.
    if ($Requested -eq 'Spanish' -or $Requested -eq 'English') {
        [void]$segments.Add(@{ Lang = $DocumentLang; Text = ($sentences -join ' '); Sentences = $sentences.ToArray() })
        return ,$segments
    }

    $currentLang = $DocumentLang
    $buffer = New-Object System.Collections.Generic.List[string]

    foreach ($sentence in $sentences) {
        $profile = Get-LanguageProfile -Text $sentence
        $sentenceLang = $currentLang

        if (($profile.Lang -ne 'unknown') -and ($profile.Tokens -ge $MinTokensToSwitch)) {
            $sentenceLang = $profile.Lang
        }

        if (($sentenceLang -ne $currentLang) -and ($buffer.Count -gt 0)) {
            [void]$segments.Add(@{ Lang = $currentLang; Text = ($buffer -join ' '); Sentences = $buffer.ToArray() })
            $buffer.Clear()
        }

        $currentLang = $sentenceLang
        [void]$buffer.Add($sentence)
    }

    if ($buffer.Count -gt 0) {
        [void]$segments.Add(@{ Lang = $currentLang; Text = ($buffer -join ' '); Sentences = $buffer.ToArray() })
    }

    return ,$segments
}

function Import-SpeechTerms {
    # Carga config\terms_es.tsv: termino en ingles <TAB> como se debe pronunciar
    # con voz en espanol. Las lineas que empiezan con # son comentarios.
    param([string]$Path)

    $map = New-Object System.Collections.Specialized.OrderedDictionary

    if (-not (Test-Path -LiteralPath $Path)) {
        return $map
    }

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

        $parts = $trimmed -split "`t+", 2
        if ($parts.Count -lt 2) { continue }

        $term = $parts[0].Trim()
        $spoken = $parts[1].Trim()
        if ($term -eq '' -or $spoken -eq '') { continue }

        # Los terminos mas largos se aplican primero para que "pull request"
        # gane sobre "pull". Por eso se ordena al final de la carga.
        $map[$term] = $spoken
    }

    $ordered = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($key in ($map.Keys | Sort-Object -Property Length -Descending)) {
        $ordered[$key] = $map[$key]
    }

    return $ordered
}

function Set-SpeechTerms {
    # Se compila una sola expresion regular con todos los terminos en vez de
    # aplicar una sustitucion por termino. Ademas de ser mucho mas rapido,
    # evita que el resultado de una sustitucion vuelva a coincidir con otra
    # regla y se deforme dos veces.
    param($Terms)

    $script:RA_TermMap = $Terms
    $script:RA_TermLookup = @{}
    $script:RA_TermRegex = $null

    if ($null -eq $Terms -or $Terms.Count -eq 0) { return }

    $alternatives = New-Object System.Collections.Generic.List[string]

    foreach ($term in $Terms.Keys) {
        $script:RA_TermLookup[$term.ToLowerInvariant()] = $Terms[$term]
        [void]$alternatives.Add([regex]::Escape($term))
    }

    # Las claves llegan ordenadas de mas larga a mas corta, y la alternancia de
    # .NET elige la primera que coincide: por eso "pull request" gana a "pull".
    $pattern = '(?<![\p{L}\p{N}])(?:' + ($alternatives -join '|') + ')(?![\p{L}\p{N}])'

    $script:RA_TermRegex = New-Object regex(
        $pattern,
        ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Compiled))
}

function Get-SpeechTerms {
    return $script:RA_TermMap
}

function Expand-EnglishTerms {
    # Reescribe terminos tecnicos en ingles con grafia espanola para que la voz
    # en espanol los diga bien. Esto resuelve el caso real de trabajo: una frase
    # en espanol con palabras sueltas en ingles, donde cambiar de voz sonaria
    # peor que ajustar la grafia.
    param([string]$Text)

    if ($null -eq $script:RA_TermRegex) { return $Text }

    $lookup = $script:RA_TermLookup

    $evaluator = [Text.RegularExpressions.MatchEvaluator] {
        param($match)

        $key = $match.Value.ToLowerInvariant()
        if ($lookup.ContainsKey($key)) { return $lookup[$key] }
        return $match.Value
    }

    return $script:RA_TermRegex.Replace($Text, $evaluator)
}

function Expand-Units {
    # Unidades abreviadas que la voz leeria letra por letra. "45 s" en espanol
    # sonaba "cuarenta y cinco ese", y "MB" como "eme be" en los dos idiomas.
    # Las de tiempo solo cuentan pegadas a un numero: una "s" o una "h" sueltas
    # pueden ser cualquier cosa. Las de tamano siempre, porque "MB" o "GB" no
    # significan otra cosa. Con 1 va en singular.
    param([string]$Text, [string]$Lang)

    $units = @(
        @{ Pattern = 'TB';  Es = 'terabyte';  En = 'terabyte' }
        @{ Pattern = 'GB';  Es = 'gigabyte';  En = 'gigabyte' }
        @{ Pattern = 'MB';  Es = 'megabyte';  En = 'megabyte' }
        @{ Pattern = '[kK]B'; Es = 'kilobyte'; En = 'kilobyte' }
    )
    if ($Lang -eq 'es') {
        $units += @(
            @{ Pattern = 'ms';  Es = 'milisegundo'; NumberOnly = $true }
            @{ Pattern = 's';   Es = 'segundo';     NumberOnly = $true }
            @{ Pattern = 'min'; Es = 'minuto';      NumberOnly = $true }
            @{ Pattern = 'h';   Es = 'hora';        NumberOnly = $true }
        )
    }

    $t = $Text
    foreach ($unit in $units) {
        $word = if ($Lang -eq 'es') { $unit.Es } else { $unit.En }

        # Con numero delante: singular solo si el numero es exactamente 1.
        $t = [regex]::Replace($t, "(?<![\p{L}\p{N}.,])(\d+(?:[.,]\d+)?)\s?$($unit.Pattern)(?![\p{L}\p{N}])", {
            param($m)
            $number = $m.Groups[1].Value
            $plural = if ($number -eq '1') { '' } else { 's' }
            return "$number $word$plural"
        }.GetNewClosure())

        # Sin numero: en singular ("el MB"), salvo detras de una palabra que
        # pide plural ("los MB", "many GB").
        if (-not $unit.NumberOnly) {
            $t = [regex]::Replace($t, "(?<![\p{L}\p{N}])$($unit.Pattern)(?![\p{L}\p{N}])", {
                param($m)
                $before = $t.Substring(0, $m.Index)
                # La tilde va como \u00e1: el archivo es ASCII (ver arriba).
                $plural = $before -match '(?i)\b(los|unos|varios|muchos|pocos|cu[a\u00e1]ntos|the|many|few|several|some)\s+$'
                return $word + $(if ($plural) { 's' } else { '' })
            }.GetNewClosure())
        }
    }

    return $t
}

function Normalize-ForSpeech {
    param(
        [string]$Text,
        [string]$Lang,
        [string]$MlMode = 'MachineLearning',
        [switch]$SkipTerms
    )

    $t = $Text

    $t = $t -replace ([string][char]0x201C), '"'
    $t = $t -replace ([string][char]0x201D), '"'
    $t = $t -replace ([string][char]0x2018), "'"
    $t = $t -replace ([string][char]0x2019), "'"
    $t = $t -replace ([string][char]0x2013), ' - '
    $t = $t -replace ([string][char]0x2014), ' - '
    $t = $t -replace ([string][char]0x2026), '...'

    # Lo que la voz leeria como ruido o con rarezas: los trazos de un arbol de
    # carpetas, las comillas de codigo y el enfasis de Markdown. Las barras de
    # una tabla y los tabuladores son separadores de celda: pasan a ser pausas.
    $t = [regex]::Replace($t, '[\u2500-\u257F]+', ' ')
    # Un trozo que termina en raya ("... con raya -") se dice como una coma.
    $t = [regex]::Replace($t, '\s+-\s*$', ',')
    $t = $t.Replace('`', '')
    $t = $t.Replace('**', '').Replace('__', '')
    if (([regex]::Matches($t, '\|')).Count -ge 2 -or $t.Contains("`t")) {
        $t = [regex]::Replace($t, '^\s*\|\s*|\s*\|\s*$', '')
        $t = [regex]::Replace($t, '\s*[\|\t]+\s*', ', ')
    }

    if ($MlMode -eq 'MachineLearning') {
        $t = [regex]::Replace($t, '(?<![\p{L}\p{N}])ml(?![\p{L}\p{N}])', 'machine learning', 'IgnoreCase')
    } elseif ($MlMode -eq 'Letters') {
        $replacement = 'M L'
        if ($Lang -eq 'es') { $replacement = 'eme ele' }
        $t = [regex]::Replace($t, '(?<![\p{L}\p{N}])ml(?![\p{L}\p{N}])', $replacement, 'IgnoreCase')
    }

    $t = Expand-Units -Text $t -Lang $Lang

    if ($Lang -eq 'es' -and -not $SkipTerms) {
        $t = Expand-EnglishTerms -Text $t
    }

    if ($Lang -eq 'es') {
        $t = $t -replace '=>', ' produce '
        $t = $t -replace '->', ' hacia '
        $t = $t.Replace([string][char]0x2192, ' hacia ')
    } else {
        $t = $t -replace '=>', ' produces '
        $t = $t -replace '->', ' to '
        $t = $t.Replace([string][char]0x2192, ' to ')
    }

    # La flecha que apunta al texto que sigue introduce un comentario
    # ("carpeta  <- nota"): se dice como una pausa. Sin espacio antes de la coma.
    $t = $t.Replace([string][char]0x2190, ', ')
    $t = [regex]::Replace($t, '\s+,', ',')
    $t = [regex]::Replace($t, ',[ \t]{2,}', ', ')

    # Las barras de rutas se leen mejor dichas. Se limita a barras entre letras
    # para no romper fechas ni fracciones numericas.
    $spokenSlash = ' slash '
    if ($Lang -eq 'es') { $spokenSlash = ' barra ' }
    $t = [regex]::Replace($t, '(?<=\p{L})/(?=\p{L})', $spokenSlash)

    return $t
}

function Prepare-TextForPiper {
    # Piper corta por frases. Los encabezados y vinetas sin puntuacion suenan
    # atropellados, asi que se les agrega un punto.
    param([string]$Text)

    $t = $Text -replace "`r`n", "`n"
    $t = $t -replace "`r", "`n"
    $t = $t -replace "[`t ]+", ' '

    $out = New-Object System.Collections.Generic.List[string]

    # Sin limite: con -1, PowerShell 7 cuenta desde la derecha y devuelve el
    # texto entero en una sola parte.
    foreach ($line in ($t -split "`n")) {
        $trimmed = $line.Trim()

        if ($trimmed -eq '') {
            $out.Add('')
            continue
        }

        $trimmed = $trimmed -replace '^\s*[-*]\s+', ''

        if (($trimmed.Length -lt 140) -and ($trimmed -notmatch '[\.\!\?\:\;\,]$')) {
            $trimmed = "$trimmed."
        }

        $out.Add($trimmed)
    }

    return ($out -join "`n")
}

function Split-SentencesIntoUnits {
    # Agrupa frases en unidades de lectura: cada unidad es un fragmento de
    # audio y, a la vez, lo que se resalta en el panel de texto. Por eso cada
    # unidad es una sola frase, y el resaltado coincide con lo que se oye.
    #
    # Solo se juntan las frases muy cortas con la siguiente, porque un
    # fragmento de una o dos palabras sonaria entrecortado. Esa misma regla
    # hace que el primer fragmento sea corto y la voz arranque enseguida.
    param(
        [string[]]$Sentences,
        [int]$MinChars = 25
    )

    $units = New-Object System.Collections.Generic.List[string]
    $actual = ''

    foreach ($frase in $Sentences) {
        $t = $frase.Trim()
        if ($t -eq '') { continue }

        if ($actual -eq '') { $actual = $t } else { $actual = "$actual $t" }

        if ($actual.Length -ge $MinChars) {
            [void]$units.Add($actual)
            $actual = ''
        }
    }

    if ($actual -ne '') { [void]$units.Add($actual) }

    return ,$units
}

function Format-DisplayText {
    # Texto tal como se muestra en el panel: el original, sin las
    # transformaciones que solo sirven para la voz.
    param(
        [string]$Text,
        [string]$Kind
    )

    $t = $Text -replace "`t+", '    '

    if ($Kind -eq 'vineta') {
        $t = $t -replace '^\s*[-*>]\s+', ([string][char]0x2022 + '  ')
    }

    return $t
}

function Test-TableRow {
    # Una fila de tabla copiada del portapapeles llega con tabuladores entre
    # columnas, o con barras verticales si viene de Markdown.
    param([string]$Line)

    if ($Line -match "`t") { return $true }
    return (([regex]::Matches($Line, '\|')).Count -ge 2)
}

function Test-TableSeparator {
    # La linea de guiones que separa el encabezado de una tabla no se lee.
    param([string]$Line)

    $l = $Line.Trim()
    if ($l -eq '') { return $false }
    return ($l -match '^[\s\|:+_=-]+$') -and ($l -match '[-=_|]')
}

function Test-ListItem {
    param([string]$Line)
    return ($Line -match '^\s*([-*>]|[0-9]+[\.\)])\s+\S')
}

function Test-TreeLine {
    # Una linea de un arbol de carpetas o de un diagrama: lleva los trazos de
    # dibujo de cuadro (U+2500 a U+257F), como en "|-- src/". Cada linea es una
    # entrada aparte, igual que una fila de tabla.
    param([string]$Line)
    return ($Line -match '[\u2500-\u257F]')
}

function Test-Heading {
    # Un titulo es una linea corta, sin puntuacion final, que abre su propio
    # bloque. Se exige que empiece bloque para no confundir un titulo con la
    # primera linea de un parrafo partido a lo ancho, que tambien termina sin
    # punto pero viene seguida de mas texto de la misma frase.
    param(
        [string]$Line,
        [bool]$AbreBloque
    )

    $l = $Line.Trim()
    if ($l -eq '') { return $false }

    if ($l -match '^#{1,6}\s+\S') { return $true }

    if (-not $AbreBloque) { return $false }
    if ($l.Length -gt 70) { return $false }
    if ($l -match '[\.\!\?,;:]$') { return $false }
    if (Test-ListItem -Line $l) { return $false }
    if (Test-TableRow -Line $l) { return $false }
    if (Test-TreeLine -Line $l) { return $false }

    return $true
}

function Split-IntoBlocks {
    # Parte el texto en bloques segun su estructura visible y le asigna a cada
    # uno la pausa que le corresponde despues.
    #
    # Es lo que hace que un cambio de fila, de parrafo o de titulo se oiga como
    # un cambio. Sin esto todo el texto se leia de corrido, con la misma pausa
    # entre dos frases de un parrafo que entre dos filas de una tabla.
    param(
        [string]$Text,
        [hashtable]$Pauses
    )

    $t = $Text -replace "`r`n", "`n"
    $t = $t -replace "`r", "`n"

    $blocks = New-Object System.Collections.Generic.List[object]
    $parrafo = New-Object System.Collections.Generic.List[string]
    $abreBloque = $true

    foreach ($linea in ($t -split "`n")) {
        $l = $linea.Trim()

        if ($l -eq '') {
            if ($parrafo.Count -gt 0) {
                [void]$blocks.Add(@{ Text = ($parrafo -join ' '); Kind = 'parrafo'; PauseAfter = $Pauses.Paragraph })
                $parrafo.Clear()
            }
            $abreBloque = $true
            continue
        }

        if (Test-TableSeparator -Line $l) { continue }

        $tipo = 'parrafo'
        if (Test-TreeLine -Line $l) {
            $tipo = 'arbol'
        } elseif (Test-Heading -Line $l -AbreBloque $abreBloque) {
            $tipo = 'titulo'
        } elseif (Test-TableRow -Line $l) {
            $tipo = 'fila'
        } elseif (Test-ListItem -Line $l) {
            $tipo = 'vineta'
        }

        if ($tipo -ne 'parrafo') {
            # Los titulos, las filas y las vinetas son bloques de una sola
            # linea: cada uno termina donde termina la linea.
            if ($parrafo.Count -gt 0) {
                [void]$blocks.Add(@{ Text = ($parrafo -join ' '); Kind = 'parrafo'; PauseAfter = $Pauses.Paragraph })
                $parrafo.Clear()
            }

            $pausa = $Pauses.TableRow
            if ($tipo -eq 'titulo') { $pausa = $Pauses.AfterHeading }

            [void]$blocks.Add(@{ Text = $l; Kind = $tipo; PauseAfter = $pausa })
            $abreBloque = $true
            continue
        }

        [void]$parrafo.Add($l)
        $abreBloque = $false
    }

    if ($parrafo.Count -gt 0) {
        [void]$blocks.Add(@{ Text = ($parrafo -join ' '); Kind = 'parrafo'; PauseAfter = $Pauses.Paragraph })
    }

    # Un titulo tambien necesita aire antes, para que no parezca la
    # continuacion de lo anterior.
    for ($i = 1; $i -lt $blocks.Count; $i++) {
        if ($blocks[$i].Kind -eq 'titulo' -and $blocks[$i - 1].PauseAfter -lt $Pauses.BeforeHeading) {
            $blocks[$i - 1].PauseAfter = $Pauses.BeforeHeading
        }
    }

    if ($blocks.Count -gt 0) {
        # Al final del texto no hay nada que separar.
        $blocks[$blocks.Count - 1].PauseAfter = 0.0
    }

    return ,$blocks
}

function Get-DefaultPauses {
    return @{
        Paragraph     = 0.35
        BeforeHeading = 0.55
        AfterHeading  = 0.30
        TableRow      = 0.18
    }
}

function Get-ChunkLimit {
    # Caracteres maximos del fragmento numero $Index de una lectura: corto el
    # primero, para que la voz empiece enseguida; intermedio el segundo, y
    # despues el maximo. Un fragmento largo retrasa a los que vienen detras
    # (la voz propia genera por grupos y cada grupo tarda lo que su frase mas
    # larga), y el primero es el que se espera con la ventana ya a la vista.
    param([int]$Index, [int]$First = 70, [int]$Max = 180)

    if ($Max -le 0) { return [int]::MaxValue }
    if ($First -le 0 -or $First -ge $Max) { return $Max }
    if ($Index -le 0) { return $First }
    if ($Index -eq 1) { return [Math]::Min($Max, [int]($First * 1.5)) }
    return $Max
}

function Split-LongText {
    # Parte un texto largo en trozos que no pasen de los limites dados (el
    # primer trozo usa el primer limite, el segundo el segundo, y asi hasta el
    # ultimo, que sirve para todos los que quedan). Corta donde una persona
    # haria una pausa: antes en ; o :, despues en una coma (no la de 2,5) y, si
    # no hay ninguna a una distancia razonable, en un espacio. El signo queda
    # con el trozo de la izquierda.
    param([string]$Text, [int[]]$Limits = @(180))

    $out = New-Object System.Collections.Generic.List[string]
    $rest = $Text.Trim()
    $n = 0

    while ($true) {
        $max = $Limits[[Math]::Min($n, $Limits.Count - 1)]
        if ($max -lt 20) { $max = 20 }
        if ($rest.Length -le $max) { break }

        $minimo = [int][Math]::Floor($max * 0.4)
        $fuerte = -1
        $coma = -1
        $espacio = -1

        for ($i = $max - 1; $i -ge $minimo; $i--) {
            $c = $rest[$i]
            if ($c -eq ';' -or $c -eq ':') {
                $fuerte = $i
                break
            } elseif ($c -eq ',') {
                $entreCifras = ($i + 1 -lt $rest.Length) -and [char]::IsDigit($rest[$i - 1]) -and [char]::IsDigit($rest[$i + 1])
                if ((-not $entreCifras) -and $coma -lt 0) { $coma = $i }
            } elseif ($c -eq [char]0x2014 -or $c -eq [char]0x2013) {
                if ($coma -lt 0) { $coma = $i }
            } elseif ($c -eq ' ') {
                if ($espacio -lt 0) { $espacio = $i }
            }
        }

        # Sin ninguna pausa natural a la vista, partir en un espacio solo vale
        # la pena si la frase es de verdad larga: cortar una de 90 caracteres
        # por un tope de 70 deja "...para" colgando.
        if ($fuerte -lt 0 -and $coma -lt 0 -and $rest.Length -le [int]($max * 1.5)) { break }

        if ($fuerte -ge 0) {
            $pieza = $rest.Substring(0, $fuerte + 1)
            $rest = $rest.Substring($fuerte + 1)
        } elseif ($coma -ge 0) {
            $pieza = $rest.Substring(0, $coma + 1)
            $rest = $rest.Substring($coma + 1)
        } elseif ($espacio -ge 0) {
            $pieza = $rest.Substring(0, $espacio)
            $rest = $rest.Substring($espacio + 1)
        } else {
            $pieza = $rest.Substring(0, $max)
            $rest = $rest.Substring($max)
        }

        $pieza = $pieza.Trim()
        if ($pieza -ne '') { [void]$out.Add($pieza); $n++ }
        $rest = $rest.Trim()
    }

    if ($rest -ne '') { [void]$out.Add($rest) }
    return $out.ToArray()
}

function Build-SpeechPlan {
    # Punto de entrada unico: texto crudo -> lista de fragmentos listos para
    # sintetizar. Cada fragmento lleva su idioma, el texto para la voz, el
    # texto original para mostrar, el bloque al que pertenece y la pausa que
    # lo sigue.
    #
    # Las frases se separan sobre el texto original y cada una se transforma
    # para la voz por separado. Hacerlo al reves, transformar y despues
    # partir, podia desalinear lo que se muestra de lo que se oye cuando una
    # sustitucion quitaba o agregaba un punto.
    param(
        [string]$Text,
        [string]$Requested = 'Auto',
        [string]$MlMode = 'MachineLearning',
        [int]$MinChunkChars = 25,
        [string]$Fallback = 'es',
        [hashtable]$Pauses = $null,
        [int]$FirstChunkChars = 70,
        [int]$MaxChunkChars = 180
    )

    if ($null -eq $Pauses) { $Pauses = Get-DefaultPauses }

    $docLang = Get-DocumentLanguage -Text $Text -Requested $Requested -Fallback $Fallback
    $blocks = Split-IntoBlocks -Text $Text -Pauses $Pauses

    $plan = New-Object System.Collections.Generic.List[object]
    $numeroBloque = 0

    foreach ($block in $blocks) {
        $textoBloque = $block.Text
        if ($block.Kind -eq 'titulo') { $textoBloque = $textoBloque -replace '^#{1,6}\s+', '' }

        $delBloque = New-Object System.Collections.Generic.List[object]
        $segments = Split-IntoLanguageSegments -Text $textoBloque -DocumentLang $docLang -Requested $Requested

        foreach ($segment in $segments) {
            $frases = @($segment.Sentences)
            if ($frases.Count -eq 0) { $frases = @($segment.Text) }

            foreach ($unidad in (Split-SentencesIntoUnits -Sentences $frases -MinChars $MinChunkChars)) {
                # Una frase mas larga que el tope del lugar que le toca se parte
                # donde se haria una pausa; cada trozo es un fragmento aparte,
                # con su texto para la voz y el original para mostrar.
                $siguiente = $plan.Count + $delBloque.Count
                $limites = @(
                    (Get-ChunkLimit -Index $siguiente -First $FirstChunkChars -Max $MaxChunkChars)
                    (Get-ChunkLimit -Index ($siguiente + 1) -First $FirstChunkChars -Max $MaxChunkChars)
                    (Get-ChunkLimit -Index ($siguiente + 2) -First $FirstChunkChars -Max $MaxChunkChars)
                )

                foreach ($pieza in @(Split-LongText -Text $unidad -Limits $limites)) {
                    $normalized = Normalize-ForSpeech -Text $pieza -Lang $segment.Lang -MlMode $MlMode
                    $prepared = (Prepare-TextForPiper -Text $normalized).Trim()
                    if ($prepared -eq '') { continue }

                    [void]$delBloque.Add(@{
                        Lang       = $segment.Lang
                        Text       = $prepared
                        Display    = (Format-DisplayText -Text $pieza -Kind $block.Kind)
                        Block      = $numeroBloque
                        Kind       = $block.Kind
                        PauseAfter = 0.0
                    })
                }
            }
        }

        if ($delBloque.Count -gt 0) {
            # La pausa va despues del ultimo fragmento del bloque.
            $delBloque[$delBloque.Count - 1].PauseAfter = [double]$block.PauseAfter
            foreach ($c in $delBloque) { [void]$plan.Add($c) }
        }

        $numeroBloque++
    }

    return @{ DocumentLang = $docLang; Chunks = $plan }
}
