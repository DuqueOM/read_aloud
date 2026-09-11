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
        [void]$segments.Add(@{ Lang = $DocumentLang; Text = $Text })
        return ,$segments
    }

    # Con idioma forzado no hay nada que segmentar: todo va a una sola voz.
    if ($Requested -eq 'Spanish' -or $Requested -eq 'English') {
        [void]$segments.Add(@{ Lang = $DocumentLang; Text = ($sentences -join ' ') })
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
            [void]$segments.Add(@{ Lang = $currentLang; Text = ($buffer -join ' ') })
            $buffer.Clear()
        }

        $currentLang = $sentenceLang
        [void]$buffer.Add($sentence)
    }

    if ($buffer.Count -gt 0) {
        [void]$segments.Add(@{ Lang = $currentLang; Text = ($buffer -join ' ') })
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

    if ($MlMode -eq 'MachineLearning') {
        $t = [regex]::Replace($t, '(?<![\p{L}\p{N}])ml(?![\p{L}\p{N}])', 'machine learning', 'IgnoreCase')
    } elseif ($MlMode -eq 'Letters') {
        $replacement = 'M L'
        if ($Lang -eq 'es') { $replacement = 'eme ele' }
        $t = [regex]::Replace($t, '(?<![\p{L}\p{N}])ml(?![\p{L}\p{N}])', $replacement, 'IgnoreCase')
    }

    if ($Lang -eq 'es' -and -not $SkipTerms) {
        $t = Expand-EnglishTerms -Text $t
    }

    if ($Lang -eq 'es') {
        $t = $t -replace '=>', ' produce '
        $t = $t -replace '->', ' hacia '
    } else {
        $t = $t -replace '=>', ' produces '
        $t = $t -replace '->', ' to '
    }

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

    foreach ($line in ($t -split "`n", -1)) {
        $trimmed = $line.Trim()

        if ($trimmed -eq '') {
            $out.Add('')
            continue
        }

        $trimmed = $trimmed -replace '^\s*[-*]\s+', ''

        if (($trimmed.Length -lt 140) -and ($trimmed -notmatch '[\.\!\?\:\;]$')) {
            $trimmed = "$trimmed."
        }

        $out.Add($trimmed)
    }

    return ($out -join "`n")
}

function Split-SegmentIntoChunks {
    # Divide un segmento de un solo idioma en fragmentos para sintetizar.
    #
    # El primer fragmento decide cuanto tardas en oir la primera palabra, y
    # sintetizar cuesta alrededor del siete por ciento de lo que dura su audio.
    # Por eso el primero se cierra en cuanto tiene una frase completa con un
    # minimo de texto, sin esperar a llenar el cupo: acumular dos frases
    # duplicaba la espera inicial sin ninguna ganancia.
    param(
        [string]$Text,
        [int]$TargetChars = 220,
        [int]$FirstChunkMinChars = 25,
        [switch]$IsFirstSegment
    )

    # Una frase mas corta que esto no justifica un fragmento propio: el corte
    # se oiria como un tropiezo.
    $minimoPrimerFragmento = $FirstChunkMinChars

    $pieces = [regex]::Split($Text, '(?<=[\.\!\?\:;])\s+|\r?\n+')

    $chunks = New-Object System.Collections.Generic.List[string]
    $current = ''

    foreach ($piece in $pieces) {
        $p = $piece.Trim()
        if ($p -eq '') { continue }

        if ($current -eq '') {
            $current = $p
        } else {
            $current = "$current $p"
        }

        $esPrimerFragmento = ($IsFirstSegment -and $chunks.Count -eq 0)

        if ($esPrimerFragmento) {
            # Cada vuelta del bucle agrega una frase completa, asi que basta
            # con comprobar que ya hay texto suficiente.
            $cerrar = ($current.Length -ge $minimoPrimerFragmento)
        } else {
            $cerrar = ($current.Length -ge $TargetChars)
        }

        if ($cerrar) {
            [void]$chunks.Add($current)
            $current = ''
        }
    }

    if ($current.Trim() -ne '') { [void]$chunks.Add($current) }
    if ($chunks.Count -eq 0) { [void]$chunks.Add($Text) }

    return ,$chunks
}

function Build-SpeechPlan {
    # Punto de entrada unico: texto crudo -> lista de fragmentos listos para
    # sintetizar, cada uno con su idioma y su voz.
    param(
        [string]$Text,
        [string]$Requested = 'Auto',
        [string]$MlMode = 'MachineLearning',
        [int]$TargetChars = 220,
        [int]$FirstChunkMinChars = 25,
        [string]$Fallback = 'es'
    )

    $docLang = Get-DocumentLanguage -Text $Text -Requested $Requested -Fallback $Fallback
    $segments = Split-IntoLanguageSegments -Text $Text -DocumentLang $docLang -Requested $Requested

    $plan = New-Object System.Collections.Generic.List[object]
    $isFirst = $true

    foreach ($segment in $segments) {
        $normalized = Normalize-ForSpeech -Text $segment.Text -Lang $segment.Lang -MlMode $MlMode
        $prepared = Prepare-TextForPiper -Text $normalized

        $chunks = Split-SegmentIntoChunks -Text $prepared -TargetChars $TargetChars -FirstChunkMinChars $FirstChunkMinChars -IsFirstSegment:$isFirst

        foreach ($chunk in $chunks) {
            [void]$plan.Add(@{ Lang = $segment.Lang; Text = $chunk })
        }

        $isFirst = $false
    }

    return @{ DocumentLang = $docLang; Chunks = $plan }
}
