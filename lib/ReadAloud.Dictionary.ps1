#
# ReadAloud.Dictionary.ps1
# El diccionario del panel (ADR 0017), sin conexion y sin procesos:
#  - WordNet en formato WNDB (Open English WordNet): definiciones, ejemplos y
#    formas irregulares, buscando por biseccion directamente en el disco.
#  - Diccionarios bilingues en StarDict (WikDict): cada sentido con su glosa
#    y sus traducciones, con el .idx en memoria.
#  - La traduccion de una palabra "en esta frase": la del diccionario que
#    aparece en la frase traducida.
#  - El indice inverso (las traducciones de en-es apuntan a su palabra
#    inglesa) y el archivo CSV para Anki.
#
# Nada aqui dice "ingles" o "espanol": todo va por codigo de idioma (ISO
# 639-1) y por par ('en-es'). Solo las reglas de morphy de WordNet y las
# contracciones son del ingles, y solo se usan con 'en'.
#
# Solo ASCII: el archivo se carga tambien desde Windows PowerShell 5.1.

$script:RA_DictUtf8 = New-Object Text.UTF8Encoding($false)

# --------------------------------------------------------------------------
# Palabras: la que esta en una posicion y las formas para buscarla.
# --------------------------------------------------------------------------

function Test-DictWordChar {
    param([char]$Char)
    return [char]::IsLetterOrDigit($Char) -or [Globalization.CharUnicodeInfo]::GetUnicodeCategory($Char) -eq [Globalization.UnicodeCategory]::NonSpacingMark
}

function Get-WordAtIndex {
    # La palabra que contiene la posicion Index de Text (la del cursor), con
    # su comienzo y su largo. Un apostrofo o un guion entre dos letras es
    # parte de la palabra (didn't, bike-sharing). $null si ahi no hay palabra.
    param(
        [string]$Text,
        [int]$Index
    )

    if ([string]::IsNullOrEmpty($Text) -or $Index -lt 0 -or $Index -gt $Text.Length) { return $null }
    $union = @([char]39, [char]0x2019, [char]45)   # ' (recto y curvo) y -
    $esParte = {
        param([int]$i)
        if ($i -lt 0 -or $i -ge $Text.Length) { return $false }
        $c = $Text[$i]
        if (Test-DictWordChar $c) { return $true }
        if ($union -contains $c) {
            return ($i -gt 0 -and $i + 1 -lt $Text.Length -and (Test-DictWordChar $Text[$i - 1]) -and (Test-DictWordChar $Text[$i + 1]))
        }
        return $false
    }

    $i = $Index
    if (-not (& $esParte $i)) {
        # Justo despues de la ultima letra (el cursor al final de la palabra).
        if (& $esParte ($i - 1)) { $i = $i - 1 } else { return $null }
    }
    $inicio = $i
    while (& $esParte ($inicio - 1)) { $inicio-- }
    $fin = $i
    while (& $esParte ($fin + 1)) { $fin++ }
    return @{ Word = $Text.Substring($inicio, $fin - $inicio + 1); Start = $inicio; Length = $fin - $inicio + 1 }
}

function Get-DictionaryLookupForms {
    # Las formas en que se busca una palabra, de la mas exacta a la menos:
    # en minusculas; sin el posesivo o la contraccion del ingles (city's,
    # didn't, we'll); con guion, entera y despues cada parte.
    param(
        [string]$Word,
        [string]$Lang = ''
    )

    $formas = New-Object System.Collections.Generic.List[string]
    $w = $Word.Trim().Replace([char]0x2019, [char]39).ToLowerInvariant()
    if (-not $w) { return @() }
    $formas.Add($w)

    if ($Lang -eq 'en') {
        $raiz = $null
        if ($w -match "^(.+)n't$") {
            $raiz = $Matches[1]
            $especiales = @{ 'ca' = 'can'; 'wo' = 'will'; 'sha' = 'shall' }
            if ($especiales.ContainsKey($raiz)) { $raiz = $especiales[$raiz] }
        } elseif ($w -match "^(.+)'(s|ll|re|ve|d|m)$") {
            $raiz = $Matches[1]
        } elseif ($w -match "^(.+s)'$") {
            $raiz = $Matches[1]
        }
        if ($raiz) { $formas.Add($raiz) }
    }

    if ($w.Contains('-')) {
        foreach ($parte in $w.Split('-')) { if ($parte) { $formas.Add($parte) } }
    }
    $unicas = New-Object System.Collections.Generic.List[string]
    foreach ($f in $formas) { if (-not $unicas.Contains($f)) { $unicas.Add($f) } }
    return $unicas.ToArray()
}

function ConvertTo-PlainWord {
    # Minusculas y sin tildes ni dieresis: "Orilla" y "orilla", "rio" y su
    # forma con tilde, se comparan igual.
    param([string]$Text)
    $d = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($c in $d.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
    }
    return $sb.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
}

# --------------------------------------------------------------------------
# Archivos de lineas ordenadas: biseccion en el disco.
# --------------------------------------------------------------------------

function Read-DictLineAt {
    # La linea que empieza despues del primer salto de linea a partir de Pos,
    # o la que empieza en Pos con -Exact. Devuelve @{ Start; Text } o $null.
    param(
        [IO.FileStream]$Stream,
        [long]$Pos,
        [switch]$Exact
    )

    [void]$Stream.Seek($Pos, [IO.SeekOrigin]::Begin)
    if (-not $Exact -and $Pos -gt 0) {
        while ($true) {
            $b = $Stream.ReadByte()
            if ($b -lt 0) { return $null }
            if ($b -eq 10) { break }
        }
    }
    $inicio = $Stream.Position
    $ms = New-Object IO.MemoryStream
    $b = 0
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -lt 0 -or $b -eq 10) { break }
        $ms.WriteByte([byte]$b)
    }
    if ($ms.Length -eq 0 -and $b -lt 0) { return $null }
    return @{ Start = $inicio; Text = $script:RA_DictUtf8.GetString($ms.ToArray()).TrimEnd([char]13) }
}

function Compare-DictBytes {
    # Compara dos arreglos de bytes como lo hace un orden de bytes (el de
    # "sort" en C y el de los archivos de WordNet).
    param([byte[]]$A, [byte[]]$B)
    $n = [Math]::Min($A.Length, $B.Length)
    for ($k = 0; $k -lt $n; $k++) {
        if ($A[$k] -ne $B[$k]) { return [int]$A[$k] - [int]$B[$k] }
    }
    return $A.Length - $B.Length
}

function Find-SortedLine {
    # Busca por biseccion la linea cuya primera palabra es Key en un archivo
    # de lineas ordenadas por bytes (los index.* de WordNet, el indice
    # inverso). Separator separa la clave del resto. Las lineas que empiezan
    # con dos espacios (la licencia de WordNet) se saltan. $null si no esta.
    param(
        [string]$Path,
        [string]$Key,
        [string]$Separator = ' '
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $clave = $script:RA_DictUtf8.GetBytes($Key + $Separator)
    $prefijo = $Key + $Separator
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $primera = Read-DictLineAt -Stream $fs -Pos 0 -Exact
        if ($primera -and $primera.Text.StartsWith($prefijo, [StringComparison]::Ordinal)) { return $primera.Text }

        $lo = [long]0
        $hi = $fs.Length
        while ($lo -lt $hi) {
            $mid = [long][Math]::Floor(($lo + $hi) / 2)
            $l = Read-DictLineAt -Stream $fs -Pos $mid
            if ($null -eq $l) { $hi = $mid; continue }
            if ($l.Text.StartsWith('  ')) { $lo = $l.Start + 1; continue }
            if ($l.Text.StartsWith($prefijo, [StringComparison]::Ordinal)) { return $l.Text }
            $cmp = Compare-DictBytes -A ($script:RA_DictUtf8.GetBytes($l.Text + $Separator)) -B $clave
            if ($cmp -lt 0) { $lo = $l.Start + 1 } else { $hi = $mid }
        }
        return $null
    } finally {
        $fs.Dispose()
    }
}

# --------------------------------------------------------------------------
# WordNet (WNDB).
# --------------------------------------------------------------------------

$script:RA_WordNetPos = [ordered]@{ n = 'noun'; v = 'verb'; a = 'adj'; r = 'adv' }

# Las reglas de morphy de WordNet: quitar el sufijo y poner el otro.
$script:RA_WordNetRules = @{
    n = @(@('s', ''), @('ses', 's'), @('xes', 'x'), @('zes', 'z'), @('ches', 'ch'), @('shes', 'sh'), @('men', 'man'), @('ies', 'y'))
    v = @(@('s', ''), @('ies', 'y'), @('es', 'e'), @('es', ''), @('ed', 'e'), @('ed', ''), @('ing', 'e'), @('ing', ''))
    a = @(@('er', ''), @('est', ''), @('er', 'e'), @('est', 'e'))
    r = @()
}

function Open-WordNet {
    # Abre una carpeta WNDB: lee las excepciones (went -> go) y arma el mapa al
    # reves (go -> went) para mostrar las formas irregulares. Los index.* y
    # data.* se leen en cada busqueda, sin cargarlos.
    param([string]$Dir)

    $exc = @{}
    $irregular = @{}
    foreach ($p in $script:RA_WordNetPos.Keys) {
        $mapa = New-Object 'System.Collections.Generic.Dictionary[string,string[]]' ([StringComparer]::Ordinal)
        $inverso = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' ([StringComparer]::Ordinal)
        $f = Join-Path $Dir ($script:RA_WordNetPos[$p] + '.exc')
        if (Test-Path -LiteralPath $f) {
            foreach ($linea in [IO.File]::ReadAllLines($f, $script:RA_DictUtf8)) {
                $partes = $linea.Split([char]32, [StringSplitOptions]::RemoveEmptyEntries)
                if ($partes.Count -lt 2) { continue }
                $bases = $partes[1..($partes.Count - 1)]
                $mapa[$partes[0]] = [string[]]$bases
                foreach ($b in $bases) {
                    if (-not $inverso.ContainsKey($b)) { $inverso[$b] = New-Object System.Collections.Generic.List[string] }
                    if (-not $inverso[$b].Contains($partes[0])) { $inverso[$b].Add($partes[0]) }
                }
            }
        }
        $exc[$p] = $mapa
        $irregular[$p] = $inverso
    }
    return @{ Dir = $Dir; Exc = $exc; Irregular = $irregular }
}

function Get-WordNetBaseForms {
    # morphy: las formas base posibles de una palabra en una categoria, en
    # orden: las excepciones, la palabra tal cual y las reglas de sufijos.
    param(
        [hashtable]$WordNet,
        [string]$Word,
        [string]$Pos
    )

    $w = $Word.Trim().ToLowerInvariant().Replace(' ', '_')
    $formas = New-Object System.Collections.Generic.List[string]
    $exc = $WordNet.Exc[$Pos]
    if ($null -ne $exc -and $exc.ContainsKey($w)) { foreach ($b in $exc[$w]) { $formas.Add($b) } }
    $formas.Add($w)
    foreach ($r in $script:RA_WordNetRules[$Pos]) {
        if ($w.Length -gt $r[0].Length -and $w.EndsWith($r[0], [StringComparison]::Ordinal)) {
            $formas.Add($w.Substring(0, $w.Length - $r[0].Length) + $r[1])
        }
    }
    $unicas = New-Object System.Collections.Generic.List[string]
    foreach ($f in $formas) { if (-not $unicas.Contains($f)) { $unicas.Add($f) } }
    return $unicas.ToArray()
}

function ConvertFrom-WordNetDataLine {
    # Una linea de data.*: las palabras del synset, la definicion y los
    # ejemplos (lo que va entre comillas en la glosa).
    param(
        [string]$Line,
        [string]$Pos
    )

    $barra = $Line.IndexOf(' | ')
    if ($barra -lt 0) { return $null }
    $campos = $Line.Substring(0, $barra).Split([char]32, [StringSplitOptions]::RemoveEmptyEntries)
    $cuantas = [Convert]::ToInt32($campos[3], 16)
    $palabras = New-Object System.Collections.Generic.List[string]
    for ($k = 0; $k -lt $cuantas; $k++) {
        $palabras.Add(($campos[4 + 2 * $k] -replace '\([a-z]+\)$', '').Replace('_', ' '))
    }
    $glosa = $Line.Substring($barra + 3).Trim()
    $ejemplos = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($glosa, '"([^"]+)"')) { $ejemplos.Add($m.Groups[1].Value.Trim()) }
    $definicion = (($glosa -replace '\s*;?\s*"[^"]*"', '').Trim().TrimEnd(';')).Trim()
    return @{ Pos = $Pos; Words = $palabras.ToArray(); Definition = $definicion; Examples = $ejemplos.ToArray() }
}

function Get-WordNetSynset {
    param(
        [hashtable]$WordNet,
        [string]$Pos,
        [long]$Offset
    )

    $fs = [IO.File]::Open((Join-Path $WordNet.Dir ('data.' + $script:RA_WordNetPos[$Pos])), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $l = Read-DictLineAt -Stream $fs -Pos $Offset -Exact
    } finally {
        $fs.Dispose()
    }
    if ($null -eq $l) { return $null }
    return ConvertFrom-WordNetDataLine -Line $l.Text -Pos $Pos
}

function Get-WordNetBaseHints {
    # Por cada categoria, la primera forma base de morphy que existe en el
    # indice de WordNet: @{ Base; Pos }. "went" da solo @{ go; v }, asi que
    # dice tambien que la palabra se usa como verbo.
    param(
        [hashtable]$WordNet,
        [string]$Word
    )
    $salida = New-Object System.Collections.Generic.List[object]
    foreach ($p in $script:RA_WordNetPos.Keys) {
        $indice = Join-Path $WordNet.Dir ('index.' + $script:RA_WordNetPos[$p])
        foreach ($base in (Get-WordNetBaseForms -WordNet $WordNet -Word $Word -Pos $p)) {
            if (Find-SortedLine -Path $indice -Key $base) {
                $salida.Add(@{ Base = $base.Replace('_', ' '); Pos = $p })
                break
            }
        }
    }
    return $salida.ToArray()
}

function Get-WordNetValidBases {
    # Las formas base de morphy que existen en el indice de WordNet, en
    # orden y sin repetir: sirven para buscar la palabra en otro diccionario
    # ("went" -> "go") sin probar formas inventadas por las reglas ("runn").
    param(
        [hashtable]$WordNet,
        [string]$Word
    )
    $salida = New-Object System.Collections.Generic.List[string]
    foreach ($h in (Get-WordNetBaseHints -WordNet $WordNet -Word $Word)) {
        if (-not $salida.Contains($h.Base)) { $salida.Add($h.Base) }
    }
    return $salida.ToArray()
}

function ConvertTo-WordNetPos {
    # La categoria de un diccionario bilingue ('noun', 'verb', 'adjective',
    # 'adverb') como la de WordNet ('n', 'v', 'a', 'r'). '' si no tiene.
    param([string]$Pos)
    switch -Regex ($Pos.ToLowerInvariant()) {
        '^noun' { return 'n' }
        '^verb' { return 'v' }
        '^adj' { return 'a' }
        '^adv' { return 'r' }
    }
    return ''
}

function Find-WordNetEntries {
    # Las acepciones de una palabra, por categoria (n, v, a, r), con la forma
    # base que se encontro. MaxSenses limita las de cada categoria (0: todas).
    param(
        [hashtable]$WordNet,
        [string]$Word,
        [int]$MaxSenses = 0
    )

    $salida = New-Object System.Collections.Generic.List[object]
    foreach ($p in $script:RA_WordNetPos.Keys) {
        $indice = Join-Path $WordNet.Dir ('index.' + $script:RA_WordNetPos[$p])
        foreach ($base in (Get-WordNetBaseForms -WordNet $WordNet -Word $Word -Pos $p)) {
            $linea = Find-SortedLine -Path $indice -Key $base
            if (-not $linea) { continue }
            # lemma pos synset_cnt p_cnt [ptr...] sense_cnt tagsense_cnt offsets...
            $c = $linea.Split([char]32, [StringSplitOptions]::RemoveEmptyEntries)
            $punteros = [int]$c[3]
            $desde = 6 + $punteros
            $acepciones = New-Object System.Collections.Generic.List[object]
            for ($k = $desde; $k -lt $c.Count; $k++) {
                if ($MaxSenses -gt 0 -and $acepciones.Count -ge $MaxSenses) { break }
                $s = Get-WordNetSynset -WordNet $WordNet -Pos $p -Offset ([long]$c[$k])
                if ($null -ne $s) { $acepciones.Add($s) }
            }
            $salida.Add(@{ Pos = $p; Base = $base.Replace('_', ' '); Senses = $acepciones.ToArray() })
            break
        }
    }
    return $salida.ToArray()
}

function Get-WordNetIrregularForms {
    # Las formas irregulares de una forma base en una categoria (mean ->
    # meant), de los .exc. Vacio si es regular.
    param(
        [hashtable]$WordNet,
        [string]$Base,
        [string]$Pos
    )
    $inv = $WordNet.Irregular[$Pos]
    $b = $Base.ToLowerInvariant().Replace(' ', '_')
    if ($null -eq $inv -or -not $inv.ContainsKey($b)) { return @() }
    return $inv[$b].ToArray()
}

# --------------------------------------------------------------------------
# StarDict (WikDict).
# --------------------------------------------------------------------------

function Read-StarDictIfo {
    # El .ifo: clave=valor por linea (wordcount, sametypesequence, date...).
    param([string]$Path)
    $info = @{}
    foreach ($linea in [IO.File]::ReadAllLines($Path, $script:RA_DictUtf8)) {
        $i = $linea.IndexOf('=')
        if ($i -gt 0) { $info[$linea.Substring(0, $i)] = $linea.Substring($i + 1) }
    }
    return $info
}

function Open-StarDict {
    # Carga el .idx (palabra en UTF-8, un byte 0, la posicion y el largo en el
    # .dict) en un diccionario sin distinguir mayusculas. Una palabra puede
    # tener varias entradas (una por categoria). El .dict no se carga: se lee
    # cada entrada por su posicion. Solo .dict sin comprimir (WikDict lo da
    # asi); un .dict.dz se descomprime al instalar.
    param(
        [string]$Dir,
        [string]$Name = 'stardict'
    )

    # Rapido en Windows PowerShell 5.1: nada de New-Object ni de llamadas a
    # funciones por entrada (son 68 000). Cada entrada es un solo entero,
    # posicion * 2^32 + largo; si una palabra tiene varias, una lista.
    # Ojo: en un diccionario de PowerShell, $d.Count devuelve la entrada
    # "count" si existe (WikDict la tiene): se usa .psbase.Count.
    $info = Read-StarDictIfo -Path (Join-Path $Dir "$Name.ifo")
    $bytes = [IO.File]::ReadAllBytes((Join-Path $Dir "$Name.idx"))
    $indice = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $i = 0
    $n = $bytes.Length
    $entradas = 0
    while ($i -lt $n) {
        $fin = [Array]::IndexOf($bytes, [byte]0, $i)
        if ($fin -lt 0 -or $fin + 8 -gt $n) { break }
        $palabra = $script:RA_DictUtf8.GetString($bytes, $i, $fin - $i)
        $p = $fin + 1
        $posicion = ([long]$bytes[$p] -shl 24) -bor ([long]$bytes[$p + 1] -shl 16) -bor ([long]$bytes[$p + 2] -shl 8) -bor [long]$bytes[$p + 3]
        $largo = ([long]$bytes[$p + 4] -shl 24) -bor ([long]$bytes[$p + 5] -shl 16) -bor ([long]$bytes[$p + 6] -shl 8) -bor [long]$bytes[$p + 7]
        $par = [long]($posicion * 4294967296 + $largo)
        $previo = $null
        if ($indice.TryGetValue($palabra, [ref]$previo)) {
            if ($previo -is [long]) {
                $lista = New-Object 'System.Collections.Generic.List[long]'
                $lista.Add($previo)
                $lista.Add($par)
                $indice[$palabra] = $lista
            } else {
                $previo.Add($par)
            }
        } else {
            $indice[$palabra] = $par
        }
        $entradas++
        $i = $fin + 9
    }
    return @{ Dir = $Dir; Dict = (Join-Path $Dir "$Name.dict"); Index = $indice; Words = $indice.psbase.Count; Entries = $entradas; Info = $info }
}

function Get-StarDictPairs {
    # Las entradas de una palabra como @{ Pos; Len }, en orden (tablas y no
    # arreglos, para que PowerShell no las desarme al devolverlas).
    param($Value)
    $salida = New-Object System.Collections.Generic.List[object]
    foreach ($par in @($Value)) {
        $salida.Add(@{ Pos = [long][Math]::Floor($par / 4294967296); Len = [int]($par % 4294967296) })
    }
    return $salida.ToArray()
}

function Get-StarDictRaw {
    # El texto (HTML en WikDict) de cada entrada de una palabra.
    param(
        [hashtable]$Dict,
        [string]$Word
    )

    if (-not $Dict.Index.ContainsKey($Word)) { return @() }
    $salida = New-Object System.Collections.Generic.List[string]
    $fs = [IO.File]::Open($Dict.Dict, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        foreach ($par in (Get-StarDictPairs -Value $Dict.Index[$Word])) {
            $buf = New-Object byte[] $par.Len
            [void]$fs.Seek($par.Pos, [IO.SeekOrigin]::Begin)
            $leidos = 0
            while ($leidos -lt $buf.Length) {
                $r = $fs.Read($buf, $leidos, $buf.Length - $leidos)
                if ($r -le 0) { break }
                $leidos += $r
            }
            $salida.Add($script:RA_DictUtf8.GetString($buf, 0, $leidos))
        }
    } finally {
        $fs.Dispose()
    }
    return $salida.ToArray()
}

function ConvertTo-DictHtmlTree {
    # Un arbol minimo del HTML de una entrada: cada nodo es @{ Name; Attr;
    # Children } y el texto va como nodos con Name '#text'. Alcanza para el
    # HTML de WikDict (div, ol, li, font, br), sin depender de que sea XML
    # valido.
    param([string]$Html)

    $raiz = @{ Name = '#root'; Attr = ''; Children = (New-Object System.Collections.Generic.List[object]) }
    $pila = New-Object System.Collections.Generic.List[object]
    $pila.Add($raiz)
    $vacios = @('br', 'hr', 'img', 'meta')
    foreach ($m in [regex]::Matches($Html, '<(/?)([A-Za-z][A-Za-z0-9]*)([^>]*)>|[^<]+')) {
        $actual = $pila[$pila.Count - 1]
        if (-not $m.Groups[2].Success) {
            $texto = [Net.WebUtility]::HtmlDecode($m.Value)
            if ($texto) { $actual.Children.Add(@{ Name = '#text'; Text = $texto }) }
            continue
        }
        $nombre = $m.Groups[2].Value.ToLowerInvariant()
        if ($m.Groups[1].Value -eq '/') {
            for ($k = $pila.Count - 1; $k -ge 1; $k--) {
                if ($pila[$k].Name -eq $nombre) { $pila.RemoveRange($k, $pila.Count - $k); break }
            }
            continue
        }
        $nodo = @{ Name = $nombre; Attr = $m.Groups[3].Value; Children = (New-Object System.Collections.Generic.List[object]) }
        $actual.Children.Add($nodo)
        if (-not ($vacios -contains $nombre) -and -not $m.Groups[3].Value.EndsWith('/')) { $pila.Add($nodo) }
    }
    return $raiz
}

function Get-DictNodeText {
    # Todo el texto de un nodo y sus hijos, con los espacios juntos.
    param([hashtable]$Node)
    if ($Node.Name -eq '#text') { return $Node.Text }
    $sb = New-Object Text.StringBuilder
    foreach ($h in $Node.Children) { [void]$sb.Append((Get-DictNodeText -Node $h)) }
    return $sb.ToString()
}

function Get-DictCleanText {
    param([string]$Text)
    return (($Text -replace [string][char]0x200B, '') -replace '\s+', ' ').Trim()
}

function Find-DictNodes {
    # Los nodos de un nombre dentro de un arbol, en orden (en profundidad).
    param([hashtable]$Node, [string]$Name)
    $salida = New-Object System.Collections.Generic.List[object]
    foreach ($h in $Node.Children) {
        if ($h.Name -eq '#text') { continue }
        if ($h.Name -eq $Name) { $salida.Add($h) }
        foreach ($x in (Find-DictNodes -Node $h -Name $Name)) { $salida.Add($x) }
    }
    return $salida.ToArray()
}

function ConvertFrom-WikDictSense {
    # Un <li> de sentido: las glosas (texto propio, o una lista de glosas sin
    # traducciones) y las traducciones (cada <div>, directo o en una lista).
    param([hashtable]$Item)

    $glosas = New-Object System.Collections.Generic.List[string]
    $traducciones = New-Object System.Collections.Generic.List[string]
    $propio = New-Object Text.StringBuilder
    foreach ($h in $Item.Children) {
        switch ($h.Name) {
            '#text' { [void]$propio.Append($h.Text) }
            'div' { $t = Get-DictCleanText (Get-DictNodeText -Node $h); if ($t) { $traducciones.Add($t) } }
            'ol' {
                foreach ($li in $h.Children) {
                    if ($li.Name -ne 'li') { continue }
                    $divs = @($li.Children | Where-Object { $_.Name -eq 'div' })
                    if ($divs.Count) {
                        foreach ($d in $divs) { $t = Get-DictCleanText (Get-DictNodeText -Node $d); if ($t) { $traducciones.Add($t) } }
                    } else {
                        $t = Get-DictCleanText (Get-DictNodeText -Node $li)
                        if ($t) { $glosas.Add($t) }
                    }
                }
            }
            default { [void]$propio.Append((Get-DictNodeText -Node $h)) }
        }
    }
    $p = Get-DictCleanText $propio.ToString()
    if ($p) { $glosas.Insert(0, $p) }
    return @{ Glosses = $glosas.ToArray(); Translations = $traducciones.ToArray() }
}

function Test-DictGrammarDiv {
    # El <div> de la categoria: el que tiene como hijo directo un <font
    # class="grammar"> (no el <div> de fuera, que lo tiene mas adentro).
    param([hashtable]$Node)
    if ($Node.Name -ne 'div') { return $false }
    foreach ($f in $Node.Children) { if ($f.Name -eq 'font' -and $f.Attr -match 'class="grammar"') { return $true } }
    return $false
}

function Find-DictGrammarParent {
    # El nodo que tiene como hijo directo el <div> de la categoria.
    param([hashtable]$Node)
    foreach ($h in $Node.Children) {
        if ($h.Name -eq '#text') { continue }
        if (Test-DictGrammarDiv -Node $h) { return $Node }
        $x = Find-DictGrammarParent -Node $h
        if ($null -ne $x) { return $x }
    }
    return $null
}

function ConvertFrom-WikDictHtml {
    # Una entrada de WikDict: la pronunciacion (lo gris del comienzo), la
    # categoria (font class="grammar") y sus sentidos, que vienen despues del
    # <div> de la categoria de dos formas:
    #  - varios sentidos: una lista <ol>, un <li> por sentido;
    #  - un solo sentido (dos de cada tres entradas): la glosa y sus
    #    traducciones sueltas, sin lista ("socio-economic system...
    #    <div>capitalismo</div>").
    param([string]$Html)

    $arbol = ConvertTo-DictHtmlTree -Html $Html
    $ipa = New-Object System.Collections.Generic.List[string]
    $categoria = ''
    foreach ($f in (Find-DictNodes -Node $arbol -Name 'font')) {
        if ($f.Attr -match 'class="grammar"') {
            if (-not $categoria) { $categoria = Get-DictCleanText (Get-DictNodeText -Node $f) }
        } elseif ($f.Attr -match 'color="gray"') {
            $t = (Get-DictCleanText (Get-DictNodeText -Node $f)).Trim([char[]]@('[', ']', ';', ' '))
            if ($t -and -not $ipa.Contains($t)) { $ipa.Add($t) }
        }
    }

    # Lo que va despues del <div> de la categoria (o todo, si no hay).
    $padre = Find-DictGrammarParent -Node $arbol
    $resto = New-Object System.Collections.Generic.List[object]
    if ($null -ne $padre) {
        $visto = $false
        foreach ($h in $padre.Children) {
            if ($visto) { $resto.Add($h) } elseif ($h.Name -ne '#text' -and (Test-DictGrammarDiv -Node $h)) { $visto = $true }
        }
    } else {
        # Sin categoria (frases como "on the other hand"): lo que hay dentro
        # del <div> que envuelve la entrada.
        # Se baja mientras haya un solo <div> que a su vez tenga etiquetas: un
        # <div> con solo texto es una traduccion ("<div><div>de la cuna a la
        # tumba</div></div>"). La pronunciacion, si esta, termina en <br>.
        $caja = $arbol
        while ($true) {
            $hijos = @($caja.Children | Where-Object { -not ($_.Name -eq '#text' -and -not (Get-DictCleanText $_.Text)) })
            if ($hijos.Count -ne 1 -or $hijos[0].Name -ne 'div') { break }
            $conEtiquetas = @($hijos[0].Children | Where-Object { $_.Name -ne '#text' }).Count -gt 0
            if (-not $conEtiquetas) { break }
            $caja = $hijos[0]
        }
        $tieneBr = @($caja.Children | Where-Object { $_.Name -eq 'br' }).Count -gt 0
        $despuesDelBr = -not $tieneBr
        foreach ($h in $caja.Children) {
            if ($despuesDelBr) { $resto.Add($h) } elseif ($h.Name -eq 'br') { $despuesDelBr = $true }
        }
    }

    # Varios sentidos solo si lo primero que hay es una lista y alguno de sus
    # <li> trae traducciones (un <div> o una lista dentro). Con una glosa
    # delante, o con una lista que es solo de glosas ("path of a body",
    # "course of development"... y despues <div>trayectoria</div>), es un
    # sentido.
    $primero = $null
    foreach ($h in $resto) {
        if ($h.Name -eq '#text' -and -not (Get-DictCleanText $h.Text)) { continue }
        $primero = $h
        break
    }
    $variosSentidos = $false
    if ($null -ne $primero -and $primero.Name -eq 'ol') {
        foreach ($li in $primero.Children) {
            if ($li.Name -ne 'li') { continue }
            foreach ($x in $li.Children) { if ($x.Name -eq 'div' -or $x.Name -eq 'ol') { $variosSentidos = $true } }
        }
    }
    $sentidos = New-Object System.Collections.Generic.List[object]
    if ($variosSentidos) {
        foreach ($li in $primero.Children) {
            if ($li.Name -ne 'li') { continue }
            $s = ConvertFrom-WikDictSense -Item $li
            if ($s.Translations.Count -or $s.Glosses.Count) { $sentidos.Add($s) }
        }
    } elseif ($null -ne $primero) {
        $s = ConvertFrom-WikDictSense -Item @{ Name = 'li'; Attr = ''; Children = $resto }
        if ($s.Translations.Count -or $s.Glosses.Count) { $sentidos.Add($s) }
    }
    return @{ Pos = $categoria; Ipa = $ipa.ToArray(); Senses = $sentidos.ToArray() }
}

function Find-BilingualEntry {
    # Las entradas de una palabra en un diccionario bilingue. Junta las de la
    # primera de sus formas que este (Get-DictionaryLookupForms: "city's" ->
    # "city") y, en ingles, las de sus formas base de WordNet: "left" trae
    # "left" (izquierda) y tambien "leave" (salir), y la frase decide.
    # Devuelve @{ Lookup; Lemmas; Ipa; Groups; PosHint } o $null:
    #   Lookup   la forma principal (la primera encontrada)
    #   Ipa      la pronunciacion de Lookup
    #   Groups   @{ Lemma; Pos; Senses }, por forma y por categoria
    #   PosHint  'forma|categoria' de WordNet ('go|v'): las categorias en que
    #            la palabra lleva a cada forma ("went" -> "go" solo como verbo)
    param(
        [hashtable]$Dict,
        [string]$Word,
        [string]$Lang = '',
        [hashtable]$WordNet = $null
    )

    $busqueda = @(Get-DictionaryLookupForms -Word $Word -Lang $Lang)
    $bases = New-Object System.Collections.Generic.List[string]
    $pistas = @{}
    if ($null -ne $WordNet) {
        foreach ($f in $busqueda) {
            foreach ($h in (Get-WordNetBaseHints -WordNet $WordNet -Word $f)) {
                if (-not $bases.Contains($h.Base)) { $bases.Add($h.Base) }
                if (-not $pistas.ContainsKey($h.Base)) { $pistas[$h.Base] = New-Object System.Collections.Generic.List[string] }
                if (-not $pistas[$h.Base].Contains($h.Pos)) { $pistas[$h.Base].Add($h.Pos) }
            }
        }
    }

    $lemas = New-Object System.Collections.Generic.List[string]
    foreach ($f in $busqueda) {
        if ($Dict.Index.ContainsKey($f)) { $lemas.Add($f); break }
    }
    foreach ($b in $bases) {
        if (-not $lemas.Contains($b) -and $Dict.Index.ContainsKey($b)) { $lemas.Add($b) }
    }
    if (-not $lemas.Count) { return $null }

    $grupos = New-Object System.Collections.Generic.List[object]
    $ipa = New-Object System.Collections.Generic.List[string]
    foreach ($lema in $lemas) {
        foreach ($c in (Get-StarDictRaw -Dict $Dict -Word $lema)) {
            $e = ConvertFrom-WikDictHtml -Html $c
            if ($lema -eq $lemas[0]) { foreach ($x in $e.Ipa) { if (-not $ipa.Contains($x)) { $ipa.Add($x) } } }
            if ($e.Senses.Count) { $grupos.Add(@{ Lemma = $lema; Pos = $e.Pos; Senses = $e.Senses }) }
        }
    }
    if (-not $grupos.Count) { return $null }
    $pista = New-Object System.Collections.Generic.List[string]
    foreach ($lema in $lemas) {
        if ($pistas.ContainsKey($lema)) { foreach ($p in $pistas[$lema]) { $pista.Add("$lema|$p") } }
    }
    return @{ Lookup = $lemas[0]; Lemmas = $lemas.ToArray(); Ipa = $ipa.ToArray(); Groups = $grupos.ToArray(); PosHint = $pista.ToArray() }
}

# --------------------------------------------------------------------------
# La traduccion en esta frase.
# --------------------------------------------------------------------------

function Get-TranslationAlternatives {
    # "decir/hablar en serio" -> "decir en serio", "hablar en serio"; sin lo
    # que va entre parentesis. Para comparar, no para mostrar.
    param([string]$Translation)

    # La barra puede separar dos traducciones ("intencionar/querer decir") o
    # dos palabras de una ("decir/hablar en serio"): se dan las dos lecturas.
    $t = (($Translation -replace [string][char]0x200B, '') -replace '\([^)]*\)', ' ' -replace '\s+', ' ').Trim()
    if (-not $t.Contains('/')) { return @($t) }
    $salida = New-Object System.Collections.Generic.List[string]
    foreach ($parte in $t.Split('/')) { $x = $parte.Trim(); if ($x -and -not $salida.Contains($x)) { $salida.Add($x) } }
    $palabras = $t.Split([char]32)
    for ($k = 0; $k -lt $palabras.Count; $k++) {
        if (-not $palabras[$k].Contains('/')) { continue }
        $antes = ''
        if ($k -gt 0) { $antes = $palabras[0..($k - 1)] -join ' ' }
        $despues = ''
        if ($k + 1 -lt $palabras.Count) { $despues = $palabras[($k + 1)..($palabras.Count - 1)] -join ' ' }
        foreach ($alt in $palabras[$k].Split('/')) {
            if (-not $alt) { continue }
            $x = ("$antes $alt $despues" -replace '\s+', ' ').Trim()
            if (-not $salida.Contains($x)) { $salida.Add($x) }
        }
        break
    }
    return $salida.ToArray()
}

function Get-TranslationMatchScore {
    # Cuanto aparece una traduccion en la frase traducida (Tokens: sus
    # palabras ya con ConvertTo-PlainWord). Cada palabra de la traduccion de 3
    # letras o mas tiene que estar: igual, 100 puntos; si no, las letras del
    # comienzo que comparte, si son al menos el largo menos 2 y al menos 4
    # (significar ~ significa). Cuenta la peor de sus palabras, menos 1 por
    # cada palabra corta de relleno ("de", "a"), mas 0.1 por cada palabra que
    # coincide despues de la primera: "querer decir" le gana a "decir" en
    # "puede querer decir". 0: no aparece.
    param(
        [string]$Translation,
        [string[]]$Tokens
    )

    $todas = @((ConvertTo-PlainWord $Translation).Split([char]32, [StringSplitOptions]::RemoveEmptyEntries))
    $palabras = @($todas | Where-Object { $_.Length -ge 3 })
    if ($palabras.Count -eq 0) {
        # Una traduccion corta ("luz" tiene 3; "da", "ir"): solo igual.
        if ($todas.Count -eq 1 -and $Tokens -contains $todas[0]) { return 100 }
        return 0
    }
    $peor = 1000
    foreach ($p in $palabras) {
        $mejor = 0
        foreach ($t in $Tokens) {
            if ($t -eq $p) { $mejor = 100; break }
            $k = 0
            while ($k -lt $p.Length -and $k -lt $t.Length -and $p[$k] -eq $t[$k]) { $k++ }
            if ($k -ge [Math]::Max(4, $p.Length - 2) -and $k -gt $mejor) { $mejor = $k }
        }
        if ($mejor -lt $peor) { $peor = $mejor }
        if ($peor -eq 0) { return 0 }
    }
    return $peor - ($todas.Count - $palabras.Count) + 0.1 * ($palabras.Count - 1)
}

function Get-SentenceTokens {
    param([string]$Text)
    $plano = ConvertTo-PlainWord $Text
    return @([regex]::Split($plano, '[^\p{L}\p{Nd}]+') | Where-Object { $_ })
}

function Select-InSentenceTranslation {
    # Elige, de las traducciones de una entrada (Groups de
    # Find-BilingualEntry), la que aparece en la frase traducida. Gana la de
    # mas puntos y, a igualdad, la que viene antes. Si ninguna aparece, la
    # primera de un grupo de PosHint ('go|v' para "went": la primera del verbo
    # "go") o, si no hay, la primera de todas, con FromSentence = $false.
    # Devuelve tambien Lemma, la forma de la que sale la traduccion.
    param(
        [object[]]$Groups,
        [string]$TranslatedSentence,
        [string[]]$PosHint = @()
    )

    $tokens = Get-SentenceTokens -Text $TranslatedSentence
    $mejor = $null
    $primera = $null
    $primeraPista = $null
    for ($g = 0; $g -lt $Groups.Count; $g++) {
        $enPista = ($PosHint.Count -gt 0) -and ($PosHint -contains ('{0}|{1}' -f [string]$Groups[$g].Lemma, (ConvertTo-WordNetPos -Pos ([string]$Groups[$g].Pos))))
        for ($s = 0; $s -lt $Groups[$g].Senses.Count; $s++) {
            foreach ($t in $Groups[$g].Senses[$s].Translations) {
                if ($null -eq $primera) { $primera = @{ Translation = $t; Pos = $Groups[$g].Pos; Lemma = [string]$Groups[$g].Lemma; Group = $g; Sense = $s; Score = 0; FromSentence = $false } }
                if ($enPista -and $null -eq $primeraPista) { $primeraPista = @{ Translation = $t; Pos = $Groups[$g].Pos; Lemma = [string]$Groups[$g].Lemma; Group = $g; Sense = $s; Score = 0; FromSentence = $false } }
                if (-not $TranslatedSentence) { continue }
                $puntos = 0
                foreach ($alt in (Get-TranslationAlternatives -Translation $t)) {
                    $x = Get-TranslationMatchScore -Translation $alt -Tokens $tokens
                    if ($x -gt $puntos) { $puntos = $x }
                }
                if ($puntos -gt 0 -and ($null -eq $mejor -or $puntos -gt $mejor.Score)) {
                    $mejor = @{ Translation = $t; Pos = $Groups[$g].Pos; Lemma = [string]$Groups[$g].Lemma; Group = $g; Sense = $s; Score = $puntos; FromSentence = $true }
                }
            }
        }
    }
    if ($null -ne $mejor) { return $mejor }
    if ($null -ne $primeraPista) { return $primeraPista }
    return $primera
}

# --------------------------------------------------------------------------
# Indice inverso: de las traducciones de un diccionario a su palabra.
# --------------------------------------------------------------------------

function Export-ReverseDictionaryIndex {
    # Recorre todas las entradas de un diccionario bilingue (en-es) y escribe
    # un archivo "traduccion<TAB>palabra1|palabra2", ordenado por bytes, para
    # buscar con Find-SortedLine (es -> en). Las traducciones van en
    # minusculas; las de varias palabras tambien entran. Devuelve cuantas
    # claves escribio.
    #
    # Rapido: lee el .dict una vez y saca las traducciones con una expresion
    # (cada traduccion de WikDict es un <div> sin etiquetas dentro), sin armar
    # el arbol de cada entrada: armarlo tardaba 7 minutos en 5.1.
    param(
        [hashtable]$Dict,
        [string]$Path
    )

    $bytes = [IO.File]::ReadAllBytes($Dict.Dict)
    $rx = New-Object Text.RegularExpressions.Regex('<div>([^<]+)</div>')
    $zw = [string][char]0x200B
    $mapa = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' ([StringComparer]::Ordinal)
    foreach ($palabra in @($Dict.Index.psbase.Keys)) {
        foreach ($par in (Get-StarDictPairs -Value $Dict.Index[$palabra])) {
            $texto = $script:RA_DictUtf8.GetString($bytes, [int]$par.Pos, $par.Len)
            foreach ($m in $rx.Matches($texto)) {
                $t = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value).Replace($zw, '').Trim()
                if (-not $t) { continue }
                $alternativas = $t
                if ($t.IndexOf('/') -ge 0 -or $t.IndexOf('(') -ge 0) { $alternativas = Get-TranslationAlternatives -Translation $t }
                foreach ($alt in @($alternativas)) {
                    $clave = ($alt -replace '\s+', ' ').Trim().ToLowerInvariant()
                    if (-not $clave -or $clave.IndexOf([char]9) -ge 0) { continue }
                    $lista = $null
                    if (-not $mapa.TryGetValue($clave, [ref]$lista)) {
                        $lista = New-Object System.Collections.Generic.List[string]
                        $mapa[$clave] = $lista
                    }
                    if (-not $lista.Contains($palabra)) { $lista.Add($palabra) }
                }
            }
        }
    }
    $claves = New-Object System.Collections.Generic.List[string]
    foreach ($k in $mapa.psbase.Keys) { $claves.Add($k) }
    $claves.Sort([StringComparer]::Ordinal)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $w = New-Object IO.StreamWriter($Path, $false, $script:RA_DictUtf8)
    try {
        $w.NewLine = "`n"
        foreach ($k in $claves) { $w.WriteLine($k + [char]9 + ($mapa[$k].ToArray() -join '|')) }
    } finally {
        $w.Dispose()
    }
    return $claves.Count
}

function Find-ReverseTranslations {
    # Las palabras del otro idioma que tienen a Word entre sus traducciones,
    # segun el indice inverso. Vacio si no esta.
    param(
        [string]$Path,
        [string]$Word
    )
    $linea = Find-SortedLine -Path $Path -Key $Word.Trim().ToLowerInvariant() -Separator ([string][char]9)
    if (-not $linea) { return @() }
    return @($linea.Substring($linea.IndexOf([char]9) + 1).Split('|') | Where-Object { $_ })
}

# --------------------------------------------------------------------------
# Guardar para Anki.
# --------------------------------------------------------------------------

function Get-AnkiHeader {
    $tr = 'Traducci' + [char]0xF3 + 'n'
    $de = 'Definici' + [char]0xF3 + 'n'
    return @('#separator:Comma', '#html:false', "#columns:Palabra,Frase,$tr,$de,Fecha")
}

function ConvertTo-AnkiCsvField {
    param([string]$Value)
    $v = ([string]$Value -replace '[\r\n\t]+', ' ').Trim()
    return '"' + $v.Replace('"', '""') + '"'
}

function ConvertFrom-AnkiCsvLine {
    # Una fila del CSV (campos entre comillas, separados por comas).
    param([string]$Line)
    $campos = New-Object System.Collections.Generic.List[string]
    $sb = New-Object Text.StringBuilder
    $dentro = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($dentro) {
            if ($c -eq '"') {
                if ($i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '"') { [void]$sb.Append('"'); $i++ } else { $dentro = $false }
            } else { [void]$sb.Append($c) }
        } elseif ($c -eq '"') {
            $dentro = $true
        } elseif ($c -eq ',') {
            $campos.Add($sb.ToString()); [void]$sb.Clear()
        } else { [void]$sb.Append($c) }
    }
    $campos.Add($sb.ToString())
    return $campos.ToArray()
}

function Add-AnkiCard {
    # Agrega una fila (palabra, frase, traduccion, definicion, fecha) al CSV
    # para Anki, en UTF-8 sin BOM, con las lineas de cabecera que Anki lee al
    # importar. Si la misma palabra con la misma frase ya esta, no la repite.
    # Devuelve 'added' o 'duplicate'.
    param(
        [string]$Path,
        [string]$Word,
        [string]$Sentence,
        [string]$Translation,
        [string]$Definition,
        [DateTime]$Date = [DateTime]::Now
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $clave = (ConvertTo-PlainWord $Word.Trim()) + [char]9 + (ConvertTo-PlainWord (($Sentence -replace '\s+', ' ').Trim()))
    $nuevo = -not (Test-Path -LiteralPath $Path)
    if (-not $nuevo) {
        foreach ($linea in [IO.File]::ReadAllLines($Path, $script:RA_DictUtf8)) {
            if (-not $linea -or $linea.StartsWith('#')) { continue }
            $c = ConvertFrom-AnkiCsvLine -Line $linea
            if ($c.Count -ge 2) {
                $k = (ConvertTo-PlainWord $c[0].Trim()) + [char]9 + (ConvertTo-PlainWord (($c[1] -replace '\s+', ' ').Trim()))
                if ($k -eq $clave) { return 'duplicate' }
            }
        }
    }
    $fila = (@($Word, $Sentence, $Translation, $Definition, $Date.ToString('yyyy-MM-dd')) | ForEach-Object { ConvertTo-AnkiCsvField $_ }) -join ','
    $lineas = New-Object System.Collections.Generic.List[string]
    if ($nuevo) { foreach ($h in (Get-AnkiHeader)) { $lineas.Add($h) } }
    $lineas.Add($fila)
    $texto = ($lineas.ToArray() -join "`r`n") + "`r`n"
    [IO.File]::AppendAllText($Path, $texto, $script:RA_DictUtf8)
    return 'added'
}

# --------------------------------------------------------------------------
# Todo junto: lo que muestra la ventana.
# --------------------------------------------------------------------------

function Find-DictionaryEntry {
    # Lo que muestra la ventana del diccionario para una palabra de una frase.
    #   From, To      idiomas de la palabra y de la traduccion ('en', 'es')
    #   Sources       @{ Definitions = @{ en = <Open-WordNet> };
    #                    Bilingual = @{ 'en-es' = <Open-StarDict>; ... };
    #                    Reverse = @{ 'es-en' = <ruta del indice inverso> } }
    #   TranslatedSentence  la frase traducida (Bergamot), para elegir
    # Devuelve Word, Lookup, Ipa, Groups (los sentidos del bilingue),
    # InSentence (Select-InSentenceTranslation), Definitions (de WordNet, del
    # idioma de la palabra o, si no tiene, de la traduccion elegida),
    # DefinitionsLang, Definition y DefinitionPos (la primera acepcion de la
    # categoria de la traduccion elegida, la que va arriba en la ventana) e
    # Irregular. $null si no hay nada.
    param(
        [string]$Word,
        [string]$From,
        [string]$To,
        [hashtable]$Sources,
        [string]$TranslatedSentence = '',
        [int]$MaxSenses = 0
    )

    $par = "$From-$To"
    $defOrigen = $null
    if ($Sources.Definitions -and $Sources.Definitions.ContainsKey($From)) { $defOrigen = $Sources.Definitions[$From] }

    $entrada = $null
    if ($Sources.Bilingual -and $Sources.Bilingual.ContainsKey($par)) {
        $entrada = Find-BilingualEntry -Dict $Sources.Bilingual[$par] -Word $Word -Lang $From -WordNet $defOrigen
    }
    $grupos = @()
    $ipa = @()
    $lookup = ''
    $pista = @()
    if ($null -ne $entrada) { $grupos = $entrada.Groups; $ipa = $entrada.Ipa; $lookup = $entrada.Lookup; $pista = $entrada.PosHint }

    # Sin entrada directa: el indice inverso (orilla -> bank, shore).
    if (-not $grupos.Count -and $Sources.Reverse -and $Sources.Reverse.ContainsKey($par)) {
        foreach ($f in (Get-DictionaryLookupForms -Word $Word -Lang $From)) {
            $otras = @(Find-ReverseTranslations -Path $Sources.Reverse[$par] -Word $f)
            if ($otras.Count) {
                $lookup = $f
                $grupos = @(@{ Pos = ''; Senses = @(@{ Glosses = @(); Translations = $otras }) })
                break
            }
        }
    }

    $elegida = $null
    if ($grupos.Count) { $elegida = Select-InSentenceTranslation -Groups $grupos -TranslatedSentence $TranslatedSentence -PosHint $pista }

    $definiciones = @()
    $defLang = ''
    $irregulares = @()
    if ($null -ne $defOrigen) {
        $definiciones = @(Find-WordNetEntries -WordNet $defOrigen -Word $Word -MaxSenses $MaxSenses)
        if (-not $definiciones.Count) {
            foreach ($f in (Get-DictionaryLookupForms -Word $Word -Lang $From)) {
                $definiciones = @(Find-WordNetEntries -WordNet $defOrigen -Word $f -MaxSenses $MaxSenses)
                if ($definiciones.Count) { break }
            }
        }
        if ($definiciones.Count) {
            $defLang = $From
            foreach ($d in $definiciones) {
                foreach ($x in (Get-WordNetIrregularForms -WordNet $defOrigen -Base $d.Base -Pos $d.Pos)) { if ($irregulares -notcontains $x) { $irregulares += $x } }
            }
        }
    } elseif ($null -ne $elegida -and $Sources.Definitions -and $Sources.Definitions.ContainsKey($To)) {
        # La palabra no tiene definiciones en su idioma: las de su traduccion.
        $primeraAlt = @(Get-TranslationAlternatives -Translation $elegida.Translation)[0]
        $definiciones = @(Find-WordNetEntries -WordNet $Sources.Definitions[$To] -Word $primeraAlt -MaxSenses $MaxSenses)
        if ($definiciones.Count) { $defLang = $To }
    }

    if (-not $grupos.Count -and -not $definiciones.Count) { return $null }

    # La definicion de arriba: la de la categoria de la traduccion elegida
    # ("significa" es verbo: la del verbo, no la del sustantivo "media").
    $definicion = ''
    $definicionPos = ''
    if ($definiciones.Count) {
        $grupoDef = $definiciones[0]
        if ($null -ne $elegida -and $defLang -eq $From) {
            $p = ConvertTo-WordNetPos -Pos ([string]$elegida.Pos)
            $igual = @($definiciones | Where-Object { $_.Pos -eq $p })
            if ($igual.Count) { $grupoDef = $igual[0] }
        }
        if ($grupoDef.Senses.Count) { $definicion = $grupoDef.Senses[0].Definition; $definicionPos = $grupoDef.Pos }
    }

    return @{
        Definition      = $definicion
        DefinitionPos   = $definicionPos
        Word            = $Word
        From            = $From
        To              = $To
        Lookup          = $lookup
        Ipa             = $ipa
        Groups          = $grupos
        InSentence      = $elegida
        Definitions     = $definiciones
        DefinitionsLang = $defLang
        Irregular       = $irregulares
    }
}

# --------------------------------------------------------------------------
# El catalogo (config\idiomas.psd1) y la instalacion de sus piezas. Lo usan
# setup.ps1 (instalar) y el lector (saber que hay instalado).
# --------------------------------------------------------------------------

# Sube este numero si cambia el formato del indice inverso: setup.ps1 lo
# vuelve a armar en los equipos que tengan el viejo.
$script:RA_DictReverseVersion = 1

function Resolve-DictionaryUrl {
    # '{Origen}/archivo.zip' -> la direccion de ese origen + '/archivo.zip'.
    # Una Url sin llaves queda igual.
    param(
        [string]$Url,
        [hashtable]$Origins
    )
    $m = [regex]::Match($Url, '^\{([A-Za-z0-9]+)\}')
    if (-not $m.Success) { return $Url }
    $nombre = $m.Groups[1].Value
    if ($null -eq $Origins -or -not $Origins.ContainsKey($nombre)) { throw "El origen '$nombre' no esta en Origenes." }
    return ([string]$Origins[$nombre]).TrimEnd('/') + $Url.Substring($m.Length)
}

function Get-DictionaryPieces {
    # Las piezas del catalogo, en orden fijo: las definiciones de cada idioma
    # y despues el diccionario bilingue de cada par. Cada una es una copia con
    # la Url resuelta, Rol ('Definiciones' o 'Bilingue'), Lang y Pair.
    param([hashtable]$Catalog)

    $salida = New-Object System.Collections.Generic.List[object]
    $listas = @(
        @{ Tabla = $Catalog.Idiomas; Rol = 'Definiciones' }
        @{ Tabla = $Catalog.Pares; Rol = 'Bilingue' }
    )
    foreach ($l in $listas) {
        if ($null -eq $l.Tabla) { continue }
        foreach ($clave in @($l.Tabla.Keys | Sort-Object)) {
            $pieza = $l.Tabla[$clave][$l.Rol]
            if ($null -eq $pieza) { continue }
            $copia = @{}
            foreach ($k in $pieza.Keys) { $copia[$k] = $pieza[$k] }
            $copia.Url = Resolve-DictionaryUrl -Url ([string]$pieza.Url) -Origins $Catalog.Origenes
            $copia.Rol = $l.Rol
            $copia.Lang = ''
            $copia.Pair = ''
            if ($l.Rol -eq 'Definiciones') { $copia.Lang = $clave } else { $copia.Pair = $clave }
            $salida.Add($copia)
        }
    }
    return $salida.ToArray()
}

function Get-DictionaryReverseIndexes {
    # Los indices inversos que pide el catalogo: @{ Pair = 'es-en'; From =
    # 'en-es'; Path = <DictionaryDir>\inverso\es-en.tsv }.
    param(
        [hashtable]$Catalog,
        [string]$DictionaryDir
    )
    $salida = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Catalog.Pares) { return $salida.ToArray() }
    foreach ($par in @($Catalog.Pares.Keys | Sort-Object)) {
        $desde = [string]$Catalog.Pares[$par].Inverso
        if (-not $desde) { continue }
        $salida.Add(@{ Pair = $par; From = $desde; Path = (Join-Path $DictionaryDir "inverso\$par.tsv") })
    }
    return $salida.ToArray()
}

function Read-DictionaryMarker {
    # Las lineas clave=valor de una marca de instalacion; $null si no esta.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $marca = @{}
    foreach ($linea in [IO.File]::ReadAllLines($Path, $script:RA_DictUtf8)) {
        $i = $linea.IndexOf('=')
        if ($i -gt 0) { $marca[$linea.Substring(0, $i)] = $linea.Substring($i + 1) }
    }
    return $marca
}

function Write-DictionaryMarker {
    param(
        [string]$Path,
        [System.Collections.Specialized.OrderedDictionary]$Values
    )
    $lineas = foreach ($k in $Values.Keys) { '{0}={1}' -f $k, $Values[$k] }
    [IO.File]::WriteAllText($Path, (($lineas -join "`n") + "`n"), $script:RA_DictUtf8)
}

function Test-DictionaryPiece {
    # Si la pieza esta instalada y es la del catalogo: su carpeta tiene todos
    # los Archivos y su pieza.txt dice el mismo sha256. Si el catalogo pasa a
    # otra version (otro sha256), deja de estarlo y setup.ps1 la reemplaza.
    param(
        [hashtable]$Piece,
        [string]$DictionaryDir
    )
    $dir = Join-Path $DictionaryDir $Piece.Destino
    $marca = Read-DictionaryMarker -Path (Join-Path $dir 'pieza.txt')
    if ($null -eq $marca -or [string]$marca.Sha256 -ne ([string]$Piece.Sha256).ToLowerInvariant()) { return $false }
    foreach ($a in @($Piece.Archivos)) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $a))) { return $false }
    }
    return $true
}

function Expand-DictionaryZip {
    # Extrae un zip entrada por entrada: salta los archivos de Exclude (por
    # nombre) y rechaza las entradas que saldrian de la carpeta (un "..\" o
    # una ruta absoluta dentro del zip).
    param(
        [string]$ZipPath,
        [string]$Destination,
        [string[]]$Exclude = @()
    )
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $base = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($e in $zip.Entries) {
            $completa = [IO.Path]::GetFullPath([IO.Path]::Combine($base, $e.FullName.Replace('/', '\')))
            if (-not $completa.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
                throw ('El zip trae una ruta que sale de la carpeta: {0}' -f $e.FullName)
            }
            if (-not $e.Name) {
                New-Item -ItemType Directory -Path $completa -Force | Out-Null
                continue
            }
            if (@($Exclude) -contains $e.Name) { continue }
            $carpeta = Split-Path -Parent $completa
            if (-not (Test-Path -LiteralPath $carpeta)) { New-Item -ItemType Directory -Path $carpeta -Force | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $completa, $true)
        }
    } finally {
        $zip.Dispose()
    }
}

function Install-DictionaryPiece {
    # Instala una pieza desde su zip ya bajado. Comprueba el sha256 (lo que no
    # coincide no se instala), extrae aparte, sin lo de Excluir, comprueba que
    # esten los Archivos y cambia la carpeta de golpe: si algo falla, lo que
    # habia queda como estaba. Deja pieza.txt con el sha256 y el origen.
    param(
        [string]$ZipPath,
        [hashtable]$Piece,
        [string]$DictionaryDir
    )

    $nombre = Split-Path -Leaf $ZipPath
    if ([string]$Piece.Destino -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw ('Destino no valido para {0}: {1}' -f $Piece.Id, $Piece.Destino) }
    $hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne ([string]$Piece.Sha256).ToLowerInvariant()) {
        throw ('{0} no es el archivo esperado (sha256 {1}, se esperaba {2}). No se instala.' -f $nombre, $hash, $Piece.Sha256)
    }

    if (-not (Test-Path -LiteralPath $DictionaryDir)) { New-Item -ItemType Directory -Path $DictionaryDir -Force | Out-Null }
    $trabajo = Join-Path $DictionaryDir ('_extraer_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        Expand-DictionaryZip -ZipPath $ZipPath -Destination $trabajo -Exclude ([string[]]@($Piece.Excluir))

        # El zip trae una sola carpeta (oewn2025/, wikdict-en-es/): esa es la
        # pieza. Si trae los archivos sueltos, la pieza es todo.
        $contenido = $trabajo
        $hijos = @(Get-ChildItem -LiteralPath $trabajo -Force)
        if ($hijos.Count -eq 1 -and $hijos[0].PSIsContainer) { $contenido = $hijos[0].FullName }
        foreach ($a in @($Piece.Archivos)) {
            if (-not (Test-Path -LiteralPath (Join-Path $contenido $a))) { throw ('{0} no trae {1}. No se instala.' -f $nombre, $a) }
        }
        $marca = [ordered]@{ Id = $Piece.Id; Sha256 = $hash; Url = $Piece.Url; Instalado = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
        Write-DictionaryMarker -Path (Join-Path $contenido 'pieza.txt') -Values $marca

        $destino = Join-Path $DictionaryDir $Piece.Destino
        $anterior = $destino + '.anterior'
        if (Test-Path -LiteralPath $anterior) { Remove-Item -LiteralPath $anterior -Recurse -Force }
        $apartado = $false
        if (Test-Path -LiteralPath $destino) {
            try {
                Move-Item -LiteralPath $destino -Destination $anterior -ErrorAction Stop
                $apartado = $true
            } catch {
                throw ('No pude reemplazar {0} porque algo lo esta usando ({1}). Cierra Read Aloud (icono de la bandeja > Salir) y vuelve a intentarlo.' -f $Piece.Destino, $_.Exception.Message)
            }
        }
        try {
            Move-Item -LiteralPath $contenido -Destination $destino -ErrorAction Stop
        } catch {
            if ($apartado -and -not (Test-Path -LiteralPath $destino)) { Move-Item -LiteralPath $anterior -Destination $destino -ErrorAction SilentlyContinue }
            throw ('No pude instalar {0}: {1}' -f $Piece.Destino, $_.Exception.Message)
        }
        if ($apartado) { Remove-Item -LiteralPath $anterior -Recurse -Force -ErrorAction SilentlyContinue }
    } finally {
        if (Test-Path -LiteralPath $trabajo) { Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Test-DictionaryReverseIndex {
    # Si el indice inverso esta armado con la version de hoy del diccionario
    # de origen (su sha256) y del formato del indice.
    param(
        [hashtable]$Index,
        [hashtable]$Source
    )
    if (-not (Test-Path -LiteralPath $Index.Path)) { return $false }
    $marca = Read-DictionaryMarker -Path ([IO.Path]::ChangeExtension($Index.Path, '.txt'))
    if ($null -eq $marca) { return $false }
    return ([string]$marca.Sha256 -eq ([string]$Source.Sha256).ToLowerInvariant()) -and ([string]$marca.Version -eq [string]$script:RA_DictReverseVersion)
}

function Install-DictionaryReverseIndex {
    # Arma el indice inverso de un par (es-en) con el diccionario instalado
    # de otro (en-es): primero en un .part y despues de golpe. Devuelve
    # cuantas claves escribio.
    param(
        [hashtable]$Index,
        [hashtable]$Source,
        [string]$DictionaryDir
    )
    if ([string]$Source.Formato -ne 'stardict') { throw ('El indice inverso de {0} necesita un StarDict, y {1} es {2}.' -f $Index.Pair, $Source.Id, $Source.Formato) }
    $dict = Open-StarDict -Dir (Join-Path $DictionaryDir $Source.Destino)
    $parcial = $Index.Path + '.part'
    try {
        $claves = Export-ReverseDictionaryIndex -Dict $dict -Path $parcial
        Move-Item -LiteralPath $parcial -Destination $Index.Path -Force
    } finally {
        if (Test-Path -LiteralPath $parcial) { Remove-Item -LiteralPath $parcial -Force -ErrorAction SilentlyContinue }
    }
    $marca = [ordered]@{ Desde = $Index.From; Sha256 = ([string]$Source.Sha256).ToLowerInvariant(); Version = $script:RA_DictReverseVersion; Claves = $claves; Armado = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    Write-DictionaryMarker -Path ([IO.Path]::ChangeExtension($Index.Path, '.txt')) -Values $marca
    return $claves
}

function Get-InstalledDictionary {
    # Lo que esta instalado y sirve, con la forma de Sources de
    # Find-DictionaryEntry pero sin abrir nada: Definitions y Bilingual, por
    # idioma y por par, @{ Dir; Format }; Reverse, la ruta de cada indice.
    # Una pieza a medias o de otra version no cuenta.
    param(
        [hashtable]$Catalog,
        [string]$DictionaryDir
    )
    $definiciones = @{}
    $bilingues = @{}
    $inversos = @{}
    $porPar = @{}
    foreach ($p in (Get-DictionaryPieces -Catalog $Catalog)) {
        if (-not (Test-DictionaryPiece -Piece $p -DictionaryDir $DictionaryDir)) { continue }
        $info = @{ Dir = (Join-Path $DictionaryDir $p.Destino); Format = [string]$p.Formato }
        if ($p.Rol -eq 'Definiciones') { $definiciones[$p.Lang] = $info } else { $bilingues[$p.Pair] = $info; $porPar[$p.Pair] = $p }
    }
    foreach ($i in (Get-DictionaryReverseIndexes -Catalog $Catalog -DictionaryDir $DictionaryDir)) {
        if ($porPar.ContainsKey($i.From) -and (Test-DictionaryReverseIndex -Index $i -Source $porPar[$i.From])) { $inversos[$i.Pair] = $i.Path }
    }
    return @{ Definitions = $definiciones; Bilingual = $bilingues; Reverse = $inversos }
}
