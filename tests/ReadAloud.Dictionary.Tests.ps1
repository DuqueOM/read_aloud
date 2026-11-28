#
# ReadAloud.Dictionary.Tests.ps1
# El diccionario del panel (lib\ReadAloud.Dictionary.ps1, ADR 0017), con un
# WordNet (WNDB) y dos StarDict chicos que se arman en TestDrive con el mismo
# formato que los reales: la palabra bajo el cursor, las formas para buscar,
# la biseccion, morphy, el HTML de WikDict, la traduccion en esta frase, el
# indice inverso y el CSV para Anki.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Dictionary.ps1')

    $script:utf8 = New-Object Text.UTF8Encoding($false)

    function New-TestWordNet {
        # Un WNDB minimo: data.* con las posiciones de byte reales en el
        # primer campo, index.* ordenados por bytes y con 200 palabras de
        # relleno para que la biseccion tenga que trabajar, y .exc.
        param([string]$Dir)

        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $licencia = @('  1 This is a test database, like the license lines of WordNet.  ', '  2 Lines that start with two spaces are skipped.  ')
        $synsets = @{
            noun = @(
                @{ Id = 'bank1'; Words = @('bank'); Gloss = 'sloping land beside a body of water; "they pulled the canoe up on the bank"' }
                @{ Id = 'bank2'; Words = @('bank', 'banking_company'); Gloss = 'a financial institution that accepts deposits; "he cashed a check at the bank"' }
                @{ Id = 'child'; Words = @('child', 'kid'); Gloss = 'a young person of either sex' }
                @{ Id = 'meann'; Words = @('mean', 'average'); Gloss = 'an average of n numbers' }
                @{ Id = 'relleno'; Words = @('filler'); Gloss = 'a word to fill the index' }
            )
            verb = @(
                @{ Id = 'go'; Words = @('go', 'travel'); Gloss = 'change location; move; "We went to the park"' }
                @{ Id = 'run'; Words = @('run'); Gloss = 'move fast by using one''s feet; "Don''t run in the hall"' }
                @{ Id = 'meanv'; Words = @('mean'); Gloss = 'mean or intend to express or convey; "You never understand what I mean!"; "what do his words intend?"' }
                @{ Id = 'leave'; Words = @('leave', 'go_away'); Gloss = 'go away from a place; "At what time does your train leave?"' }
            )
            adj = @(
                @{ Id = 'meana'; Words = @('mean(a)'); Gloss = 'characterized by malice; "a hateful thing to do"' }
                @{ Id = 'lefta'; Words = @('left'); Gloss = 'being on the side of the body to the west when facing north' }
            )
            adv = @()
        }
        $offsets = @{}
        foreach ($pos in 'noun', 'verb', 'adj', 'adv') {
            $tipo = @{ noun = 'n'; verb = 'v'; adj = 's'; adv = 'r' }[$pos]
            $sb = New-Object Text.StringBuilder
            foreach ($l in $licencia) { [void]$sb.Append($l + "`n") }
            foreach ($s in $synsets[$pos]) {
                $offset = $script:utf8.GetByteCount($sb.ToString())
                $offsets[$s.Id] = $offset
                $palabras = ($s.Words | ForEach-Object { "$_ 0" }) -join ' '
                [void]$sb.Append(('{0:d8} 05 {1} {2:x2} {3} 000 | {4}  ' -f $offset, $tipo, $s.Words.Count, $palabras, $s.Gloss) + "`n")
            }
            [IO.File]::WriteAllText((Join-Path $Dir "data.$pos"), $sb.ToString(), $script:utf8)
        }

        $indices = @{
            noun = @{ 'bank' = @('bank1', 'bank2'); 'banking_company' = @('bank2'); 'child' = @('child'); 'kid' = @('child'); 'mean' = @('meann'); 'average' = @('meann') }
            verb = @{ 'go' = @('go'); 'travel' = @('go'); 'run' = @('run'); 'mean' = @('meanv'); 'leave' = @('leave') }
            adj = @{ 'mean' = @('meana'); 'left' = @('lefta') }
            adv = @{}
        }
        for ($k = 0; $k -lt 200; $k++) { $indices.noun[('filler{0:d3}' -f $k)] = @('relleno') }
        foreach ($pos in 'noun', 'verb', 'adj', 'adv') {
            $p = @{ noun = 'n'; verb = 'v'; adj = 'a'; adv = 'r' }[$pos]
            $claves = New-Object System.Collections.Generic.List[string]
            foreach ($c in $indices[$pos].Keys) { $claves.Add($c) }
            $claves.Sort([StringComparer]::Ordinal)
            $sb = New-Object Text.StringBuilder
            foreach ($l in $licencia) { [void]$sb.Append($l + "`n") }
            foreach ($c in $claves) {
                $ids = $indices[$pos][$c]
                $o = ($ids | ForEach-Object { '{0:d8}' -f $offsets[$_] }) -join ' '
                [void]$sb.Append(('{0} {1} {2} 1 @ {2} 0 {3}  ' -f $c, $p, $ids.Count, $o) + "`n")
            }
            [IO.File]::WriteAllText((Join-Path $Dir "index.$pos"), $sb.ToString(), $script:utf8)
        }
        [IO.File]::WriteAllText((Join-Path $Dir 'verb.exc'), "left leave`nmeant mean`nran run`nwent go`n", $script:utf8)
        [IO.File]::WriteAllText((Join-Path $Dir 'noun.exc'), "children child`n", $script:utf8)
        [IO.File]::WriteAllText((Join-Path $Dir 'adj.exc'), "meaner mean`n", $script:utf8)
        [IO.File]::WriteAllText((Join-Path $Dir 'adv.exc'), '', $script:utf8)
    }

    function New-TestStarDict {
        # Un StarDict como los de WikDict: .ifo, .idx (palabra, 0, posicion
        # y largo en big-endian) y .dict sin comprimir.
        param([string]$Dir, [object[]]$Entries)

        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $dict = New-Object IO.MemoryStream
        $idx = New-Object IO.MemoryStream
        foreach ($e in $Entries) {
            $cuerpo = $script:utf8.GetBytes($e.Html)
            $pos = [uint32]$dict.Length
            $dict.Write($cuerpo, 0, $cuerpo.Length)
            $nombre = $script:utf8.GetBytes($e.Word)
            $idx.Write($nombre, 0, $nombre.Length)
            $idx.WriteByte(0)
            foreach ($n in @($pos, [uint32]$cuerpo.Length)) {
                $b = [BitConverter]::GetBytes([uint32]$n)
                if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($b) }
                $idx.Write($b, 0, 4)
            }
        }
        [IO.File]::WriteAllBytes((Join-Path $Dir 'stardict.dict'), $dict.ToArray())
        [IO.File]::WriteAllBytes((Join-Path $Dir 'stardict.idx'), $idx.ToArray())
        $ifo = "StarDict's dict ifo file`nversion=3.0.0`nbookname=Test`nwordcount=$($Entries.Count)`nsametypesequence=h`ndate=2026-11-26`n"
        [IO.File]::WriteAllText((Join-Path $Dir 'stardict.ifo'), $ifo, $script:utf8)
    }

    function New-WikDictHtml {
        param([string]$Pos, [string]$Senses, [string[]]$Ipa = @('test'))
        $gris = ($Ipa | ForEach-Object { '/<font color="gray">' + $_ + '</font>/' }) -join ', '
        return '<div>' + $gris + '<br>' + "`n" + '<div><font class="grammar" color="green">' + $Pos + '</font></div><ol>' + $Senses + '</ol></div>'
    }

    $script:Raiz = Join-Path $TestDrive 'dicc'
    $script:WnDir = Join-Path $script:Raiz 'wordnet'
    New-TestWordNet -Dir $script:WnDir
    $script:Wn = Open-WordNet -Dir $script:WnDir

    $ipaBank = [string][char]0x2C8 + 'ba' + [char]0x14B + 'k'
    $bankNoun = New-WikDictHtml -Pos 'noun' -Ipa @($ipaBank, "[$ipaBank]", ';') -Senses (
        '<li>institution<ol><li><div>banco</div></li><li><div>banca</div></li></ol></li>' +
        '<li>edge of river or lake<ol><li><div>ribera</div></li><li><div>orilla</div></li></ol></li>' +
        '<li>device used to store coins<div>hucha</div></li>')
    $bankVerb = New-WikDictHtml -Pos 'verb' -Senses '<li>to put into bank<ol><li><div>depositar</div></li><li><div>ingresar</div></li></ol></li>'
    $meanVerb = New-WikDictHtml -Pos 'verb' -Senses (
        '<li>to have conviction in what one says<div>decir' + [char]0x200B + '/' + [char]0x200B + 'hablar en serio</div></li>' +
        '<li><ol><li>of a word: to signify</li><li>to convey, indicate</li></ol><ol><li><div>querer decir</div></li><li><div>significar</div></li></ol></li>' +
        '<li>to be important<ol><li><div>importar</div></li><li><div>ser importante (para)</div></li></ol></li>')
    $meanNoun = New-WikDictHtml -Pos 'noun' -Senses '<li><ol><li>arithmetic mean</li><li>the statistical value</li></ol><div>media</div></li>'
    $leave = New-WikDictHtml -Pos 'verb' -Senses '<li>to depart<ol><li><div>salir de</div></li><li><div>salir</div></li><li><div>irse</div></li></ol></li>'
    $script:EnEsDir = Join-Path $script:Raiz 'en-es'
    New-TestStarDict -Dir $script:EnEsDir -Entries @(
        @{ Word = 'bank'; Html = $bankNoun }
        @{ Word = 'bank'; Html = $bankVerb }
        @{ Word = 'mean'; Html = $meanVerb }
        @{ Word = 'mean'; Html = $meanNoun }
        @{ Word = 'go'; Html = (New-WikDictHtml -Pos 'noun' -Senses '<li>attempt<div>intento</div></li>') }
        @{ Word = 'go'; Html = $leave }
        @{ Word = 'count'; Html = (New-WikDictHtml -Pos 'verb' -Senses '<li>to enumerate<div>contar</div></li>') }
        @{ Word = 'left'; Html = (New-WikDictHtml -Pos 'adjective' -Senses '<li>opposite of right<ol><li><div>izquierdo</div></li><li><div>de izquierda</div></li></ol></li>') }
        @{ Word = 'leave'; Html = (New-WikDictHtml -Pos 'verb' -Senses '<li>to depart<ol><li><div>irse</div></li><li><div>salir</div></li></ol></li>') }
        @{ Word = 'child'; Html = (New-WikDictHtml -Pos 'noun' -Senses '<li>young person<ol><li><div>hijo</div></li><li><div>nino</div></li></ol></li>') }
    )
    $script:EsEnDir = Join-Path $script:Raiz 'es-en'
    New-TestStarDict -Dir $script:EsEnDir -Entries @(
        @{ Word = 'banco'; Html = (New-WikDictHtml -Pos 'noun' -Senses '<li>institution<div>bank</div></li><li>seat<div>bench</div></li>') }
    )
    $script:EnEs = Open-StarDict -Dir $script:EnEsDir
    $script:EsEn = Open-StarDict -Dir $script:EsEnDir
    $script:Inverso = Join-Path $script:Raiz 'inverso\es-en.tsv'
    [void](Export-ReverseDictionaryIndex -Dict $script:EnEs -Path $script:Inverso)
}

Describe 'Get-WordAtIndex' {
    It 'la palabra que contiene la posicion, con su comienzo y largo' {
        $r = Get-WordAtIndex -Text 'The bank of the river.' -Index 6
        $r.Word | Should -Be 'bank'
        $r.Start | Should -Be 4
        $r.Length | Should -Be 4
    }

    It 'justo despues de la ultima letra devuelve esa palabra' {
        (Get-WordAtIndex -Text 'The bank of' -Index 8).Word | Should -Be 'bank'
    }

    It 'un apostrofo o un guion entre letras es parte de la palabra' {
        (Get-WordAtIndex -Text "He didn't go." -Index 5).Word | Should -Be "didn't"
        (Get-WordAtIndex -Text 'A bike-sharing plan' -Index 3).Word | Should -Be 'bike-sharing'
        (Get-WordAtIndex -Text ('it' + [char]0x2019 + 's fine') -Index 0).Word | Should -Be ('it' + [char]0x2019 + 's')
    }

    It 'un signo suelto o un espacio entre signos no es palabra' {
        Get-WordAtIndex -Text 'Hi -- there' -Index 4 | Should -BeNullOrEmpty
        Get-WordAtIndex -Text '' -Index 0 | Should -BeNullOrEmpty
    }

    It 'acepta letras con tilde' {
        $t = 'La orilla del r' + [char]0xED + 'o.'
        (Get-WordAtIndex -Text $t -Index 15).Word | Should -Be ('r' + [char]0xED + 'o')
    }
}

Describe 'Get-DictionaryLookupForms' {
    It 'en ingles quita el posesivo y las contracciones (<Palabra>)' -ForEach @(
        @{ Palabra = "City's"; Esperado = @("city's", 'city') }
        @{ Palabra = "didn't"; Esperado = @("didn't", 'did') }
        @{ Palabra = "can't"; Esperado = @("can't", 'can') }
        @{ Palabra = "won't"; Esperado = @("won't", 'will') }
        @{ Palabra = "we'll"; Esperado = @("we'll", 'we') }
        @{ Palabra = "players'"; Esperado = @("players'", 'players') }
    ) {
        Get-DictionaryLookupForms -Word $Palabra -Lang 'en' | Should -Be $Esperado
    }

    It 'el apostrofo curvo cuenta como recto' {
        Get-DictionaryLookupForms -Word ('city' + [char]0x2019 + 's') -Lang 'en' | Should -Be @("city's", 'city')
    }

    It 'con guion, la palabra entera y despues cada parte' {
        Get-DictionaryLookupForms -Word 'Bike-sharing' -Lang 'en' | Should -Be @('bike-sharing', 'bike', 'sharing')
    }

    It 'en otro idioma no toca los apostrofos' {
        Get-DictionaryLookupForms -Word "l'acqua" -Lang 'it' | Should -Be @("l'acqua")
    }
}

Describe 'ConvertTo-PlainWord' {
    It 'quita tildes y dieresis y pasa a minusculas' {
        ConvertTo-PlainWord ('R' + [char]0xED + 'O') | Should -Be 'rio'
        ConvertTo-PlainWord ('ping' + [char]0xFC + 'ino') | Should -Be 'pinguino'
    }

    It 'la enie pasa a n: solo sirve para comparar, no para mostrar' {
        ConvertTo-PlainWord ('ma' + [char]0xF1 + 'ana') | Should -Be 'manana'
    }
}

Describe 'Find-SortedLine' {
    BeforeAll {
        $script:Ordenado = Join-Path $TestDrive 'ordenado.txt'
        $lineas = New-Object System.Collections.Generic.List[string]
        $lineas.Add('  licencia que se salta')
        $claves = New-Object System.Collections.Generic.List[string]
        for ($k = 0; $k -lt 500; $k++) { $claves.Add(('w{0:d4}' -f $k)) }
        $claves.Add('mean'); $claves.Add('mean_value'); $claves.Add('meander')
        $claves.Sort([StringComparer]::Ordinal)
        foreach ($c in $claves) { $lineas.Add("$c datos de $c") }
        [IO.File]::WriteAllText($script:Ordenado, (($lineas.ToArray() -join "`n") + "`n"), $script:utf8)
    }

    It 'encuentra la primera, la ultima y una del medio' {
        Find-SortedLine -Path $script:Ordenado -Key 'mean' | Should -Be 'mean datos de mean'
        Find-SortedLine -Path $script:Ordenado -Key 'w0000' | Should -Be 'w0000 datos de w0000'
        Find-SortedLine -Path $script:Ordenado -Key 'w0499' | Should -Be 'w0499 datos de w0499'
        Find-SortedLine -Path $script:Ordenado -Key 'w0250' | Should -Be 'w0250 datos de w0250'
    }

    It 'no confunde una clave con otra que empieza igual' {
        Find-SortedLine -Path $script:Ordenado -Key 'mean_value' | Should -Be 'mean_value datos de mean_value'
        Find-SortedLine -Path $script:Ordenado -Key 'meand' | Should -BeNullOrEmpty
        Find-SortedLine -Path $script:Ordenado -Key 'zzz' | Should -BeNullOrEmpty
        Find-SortedLine -Path $script:Ordenado -Key 'a' | Should -BeNullOrEmpty
    }

    It 'sin archivo, nada' {
        Find-SortedLine -Path (Join-Path $TestDrive 'no_existe.txt') -Key 'x' | Should -BeNullOrEmpty
    }
}

Describe 'WordNet' {
    It 'morphy: las excepciones van primero (<Palabra> -> <Base>)' -ForEach @(
        @{ Palabra = 'went'; Pos = 'v'; Base = 'go' }
        @{ Palabra = 'children'; Pos = 'n'; Base = 'child' }
        @{ Palabra = 'meant'; Pos = 'v'; Base = 'mean' }
    ) {
        (Get-WordNetBaseForms -WordNet $script:Wn -Word $Palabra -Pos $Pos)[0] | Should -Be $Base
    }

    It 'morphy: las reglas de sufijos dan la base regular' {
        Get-WordNetBaseForms -WordNet $script:Wn -Word 'banks' -Pos 'n' | Should -Contain 'bank'
        Get-WordNetBaseForms -WordNet $script:Wn -Word 'running' -Pos 'v' | Should -Contain 'runn'
        Get-WordNetValidBases -WordNet $script:Wn -Word 'banks' | Should -Be @('bank')
    }

    It 'las acepciones por categoria, con definicion y ejemplos' {
        $r = @(Find-WordNetEntries -WordNet $script:Wn -Word 'mean')
        @($r | ForEach-Object { $_.Pos }) | Should -Be @('n', 'v', 'a')
        $v = @($r | Where-Object { $_.Pos -eq 'v' })[0]
        $v.Senses[0].Definition | Should -Be 'mean or intend to express or convey'
        $v.Senses[0].Examples | Should -Be @('You never understand what I mean!', 'what do his words intend?')
        @($r | Where-Object { $_.Pos -eq 'a' })[0].Senses[0].Words | Should -Be @('mean')
    }

    It 'una forma irregular se busca por su base' {
        $r = @(Find-WordNetEntries -WordNet $script:Wn -Word 'went')
        $r.Count | Should -Be 1
        $r[0].Base | Should -Be 'go'
        $r[0].Senses[0].Definition | Should -Be 'change location; move'
        $r[0].Senses[0].Words | Should -Be @('go', 'travel')
    }

    It 'MaxSenses limita las acepciones de cada categoria' {
        $r = @(Find-WordNetEntries -WordNet $script:Wn -Word 'bank' -MaxSenses 1)
        $r[0].Senses.Count | Should -Be 1
        (@(Find-WordNetEntries -WordNet $script:Wn -Word 'bank'))[0].Senses.Count | Should -Be 2
    }

    It 'las formas irregulares de una base' {
        Get-WordNetIrregularForms -WordNet $script:Wn -Base 'mean' -Pos 'v' | Should -Be @('meant')
        Get-WordNetIrregularForms -WordNet $script:Wn -Base 'bank' -Pos 'n' | Should -BeNullOrEmpty
    }

    It 'una palabra que no esta no devuelve nada' {
        @(Find-WordNetEntries -WordNet $script:Wn -Word 'zzzz').Count | Should -Be 0
    }
}

Describe 'StarDict y el HTML de WikDict' {
    It 'carga el indice, sin distinguir mayusculas, con varias entradas por palabra' {
        # Tiene la palabra "count": con $indice.Count saldria esa entrada.
        $script:EnEs.Words | Should -Be 7
        $script:EnEs.Entries | Should -Be 10
        $script:EnEs.Info.sametypesequence | Should -Be 'h'
        @(Get-StarDictRaw -Dict $script:EnEs -Word 'BANK').Count | Should -Be 2
        @(Get-StarDictRaw -Dict $script:EnEs -Word 'nada').Count | Should -Be 0
    }

    It 'categoria, pronunciacion sin repetir y cada sentido con sus traducciones' {
        $e = ConvertFrom-WikDictHtml -Html (@(Get-StarDictRaw -Dict $script:EnEs -Word 'bank'))[0]
        $e.Pos | Should -Be 'noun'
        $e.Ipa | Should -Be @([string][char]0x2C8 + 'ba' + [char]0x14B + 'k')
        $e.Senses.Count | Should -Be 3
        $e.Senses[1].Glosses | Should -Be @('edge of river or lake')
        $e.Senses[1].Translations | Should -Be @('ribera', 'orilla')
        $e.Senses[2].Translations | Should -Be @('hucha')
    }

    It 'un sentido con varias glosas en lista y las traducciones en otra lista' {
        $e = ConvertFrom-WikDictHtml -Html (@(Get-StarDictRaw -Dict $script:EnEs -Word 'mean'))[0]
        $e.Senses[1].Glosses | Should -Be @('of a word: to signify', 'to convey, indicate')
        $e.Senses[1].Translations | Should -Be @('querer decir', 'significar')
        $e.Senses[0].Translations | Should -Be @('decir/hablar en serio')
    }

    It 'un solo sentido sin lista: la glosa y la traduccion sueltas (2 de cada 3 entradas)' {
        $h = '<div>/<font color="gray">x</font>/<br>' + "`n" + '<div><font class="grammar" color="green">noun</font></div>socio-economic system based on private property rights<div>capitalismo</div></div>'
        $e = ConvertFrom-WikDictHtml -Html $h
        $e.Pos | Should -Be 'noun'
        $e.Senses.Count | Should -Be 1
        $e.Senses[0].Glosses | Should -Be @('socio-economic system based on private property rights')
        $e.Senses[0].Translations | Should -Be @('capitalismo')
    }

    It 'un solo sentido sin pronunciacion, y uno con la glosa delante de una lista de traducciones' {
        $h = '<div><div><font class="grammar" color="green">verb</font></div>defeat and make submit to orders<div>arrodillar a alguien</div></div>'
        $e = ConvertFrom-WikDictHtml -Html $h
        $e.Ipa.Count | Should -Be 0
        $e.Senses[0].Translations | Should -Be @('arrodillar a alguien')
        $h2 = '<div><div><font class="grammar" color="green">noun</font></div>young person<ol><li><div>hijo</div></li><li><div>nino</div></li></ol></div>'
        $e2 = ConvertFrom-WikDictHtml -Html $h2
        $e2.Senses.Count | Should -Be 1
        $e2.Senses[0].Glosses | Should -Be @('young person')
        $e2.Senses[0].Translations | Should -Be @('hijo', 'nino')
    }

    It 'un solo sentido con sus glosas en lista y las traducciones despues' {
        $h = '<div><div><font class="grammar" color="green">noun</font></div><ol><li>path of a body</li><li>course of development</li></ol><div>trayectoria</div></div>'
        $e = ConvertFrom-WikDictHtml -Html $h
        $e.Senses.Count | Should -Be 1
        $e.Senses[0].Glosses | Should -Be @('path of a body', 'course of development')
        $e.Senses[0].Translations | Should -Be @('trayectoria')
        $h2 = '<div><div><font class="grammar" color="green">noun</font></div><ol><li>one who informs</li><li>person who tells authorities</li></ol><ol><li><div>informador</div></li><li><div>informadora</div></li></ol></div>'
        (ConvertFrom-WikDictHtml -Html $h2).Senses[0].Translations | Should -Be @('informador', 'informadora')
    }

    It 'una frase sin categoria, con uno o varios sentidos' {
        $h = '<div>from another point of view<ol><li><div>por otra parte</div></li><li><div>por otro lado</div></li></ol></div>'
        $e = ConvertFrom-WikDictHtml -Html $h
        $e.Pos | Should -Be ''
        $e.Senses.Count | Should -Be 1
        $e.Senses[0].Glosses | Should -Be @('from another point of view')
        $e.Senses[0].Translations | Should -Be @('por otra parte', 'por otro lado')
        $h2 = '<div><ol><li>written down<div>escrito</div></li><li>published<ol><li><div>impreso</div></li><li><div>publicado</div></li></ol></li></ol></div>'
        $e2 = ConvertFrom-WikDictHtml -Html $h2
        $e2.Senses.Count | Should -Be 2
        $e2.Senses[1].Translations | Should -Be @('impreso', 'publicado')
    }

    It 'una traduccion sola, sin glosa, y una frase con pronunciacion pero sin categoria' {
        $e = ConvertFrom-WikDictHtml -Html '<div><div>de la cuna a la tumba</div></div>'
        $e.Senses.Count | Should -Be 1
        $e.Senses[0].Translations | Should -Be @('de la cuna a la tumba')
        $h = '<div>/<font color="gray">x</font>/<br>' + "`n" + '<ol><li>eagerly<ol><li><div>pasmado</div></li></ol></li><li>holding breath<div>conteniendo el aliento</div></li></ol></div>'
        $e2 = ConvertFrom-WikDictHtml -Html $h
        $e2.Ipa | Should -Be @('x')
        $e2.Senses.Count | Should -Be 2
        $e2.Senses[1].Translations | Should -Be @('conteniendo el aliento')
    }

    It 'junta la palabra y sus formas base: "left" trae "left" y "leave", y la frase decide' {
        $e = Find-BilingualEntry -Dict $script:EnEs -Word 'left' -Lang 'en' -WordNet $script:Wn
        $e.Lookup | Should -Be 'left'
        $e.Lemmas | Should -Be @('left', 'leave')
        @($e.Groups | ForEach-Object { $_.Lemma }) | Should -Be @('left', 'leave')
        $e.PosHint | Should -Contain 'leave|v'
        $r = Select-InSentenceTranslation -Groups $e.Groups -TranslatedSentence 'Salio de la habitacion temprano.' -PosHint $e.PosHint
        $r.Translation | Should -Be 'salir'
        $r.Lemma | Should -Be 'leave'
        (Select-InSentenceTranslation -Groups $e.Groups -TranslatedSentence 'Gire a la izquierda.' -PosHint $e.PosHint).Translation | Should -Be 'de izquierda'
    }

    It 'Find-BilingualEntry busca por la base de WordNet y junta las categorias' {
        $r = Find-BilingualEntry -Dict $script:EnEs -Word 'Banks' -Lang 'en' -WordNet $script:Wn
        $r.Lookup | Should -Be 'bank'
        @($r.Groups | ForEach-Object { $_.Pos }) | Should -Be @('noun', 'verb')
        (Find-BilingualEntry -Dict $script:EnEs -Word 'went' -Lang 'en' -WordNet $script:Wn).Lookup | Should -Be 'go'
        Find-BilingualEntry -Dict $script:EnEs -Word 'zzzz' -Lang 'en' -WordNet $script:Wn | Should -BeNullOrEmpty
    }
}

Describe 'Get-StarDictPairs' {
    It 'una entrada sola y varias dan tablas con su posicion y largo' {
        $uno = @(Get-StarDictPairs -Value ([long](5 * 4294967296 + 7)))
        $uno.Count | Should -Be 1
        $uno[0].Pos | Should -Be 5
        $uno[0].Len | Should -Be 7
        $lista = New-Object 'System.Collections.Generic.List[long]'
        $lista.Add([long](1 * 4294967296 + 2)); $lista.Add([long](3 * 4294967296 + 4))
        $dos = @(Get-StarDictPairs -Value $lista)
        $dos.Count | Should -Be 2
        $dos[1].Pos | Should -Be 3
        $dos[1].Len | Should -Be 4
    }
}

Describe 'La traduccion en esta frase' {
    It 'Get-TranslationAlternatives da las dos lecturas de la barra y quita los parentesis' {
        $a = Get-TranslationAlternatives -Translation ('decir' + [char]0x200B + '/' + [char]0x200B + 'hablar en serio')
        $a | Should -Contain 'decir en serio'
        $a | Should -Contain 'hablar en serio'
        Get-TranslationAlternatives -Translation 'intencionar/querer decir' | Should -Contain 'querer decir'
        Get-TranslationAlternatives -Translation 'ser importante (para)' | Should -Be @('ser importante')
    }

    It 'Get-TranslationMatchScore: igual vale 100, el comienzo comun vale sus letras' {
        $t = Get-SentenceTokens -Text 'Que significa esta palabra?'
        Get-TranslationMatchScore -Translation 'palabra' -Tokens $t | Should -Be 100
        Get-TranslationMatchScore -Translation 'significar' -Tokens $t | Should -Be 9
        Get-TranslationMatchScore -Translation 'importar' -Tokens $t | Should -Be 0
    }

    It 'sin tildes: "rio" coincide con la palabra con tilde' {
        $t = Get-SentenceTokens -Text ('La orilla del r' + [char]0xED + 'o')
        Get-TranslationMatchScore -Translation 'rio' -Tokens $t | Should -Be 100
    }

    It 'elige la que aparece en la frase traducida (<Frase>)' -ForEach @(
        @{ Frase = 'La orilla del rio estaba cubierta de nieve.'; Esperada = 'orilla' }
        @{ Frase = 'Necesito ir al banco para depositar este cheque.'; Esperada = 'banco' }
        @{ Frase = 'Hay que ingresar el dinero.'; Esperada = 'ingresar' }
    ) {
        $g = (Find-BilingualEntry -Dict $script:EnEs -Word 'bank' -Lang 'en' -WordNet $script:Wn).Groups
        $r = Select-InSentenceTranslation -Groups $g -TranslatedSentence $Frase
        $r.Translation | Should -Be $Esperada
        $r.FromSentence | Should -BeTrue
    }

    It 'la palabra exacta le gana a otra que empieza igual (banco frente a banca)' {
        $g = (Find-BilingualEntry -Dict $script:EnEs -Word 'bank' -Lang 'en').Groups
        (Select-InSentenceTranslation -Groups $g -TranslatedSentence 'Fui al banco.').Translation | Should -Be 'banco'
        (Select-InSentenceTranslation -Groups $g -TranslatedSentence 'Trabaja en la banca.').Translation | Should -Be 'banca'
    }

    It 'a igualdad, la de menos palabras de relleno ("salir" frente a "salir de")' {
        $g = (Find-BilingualEntry -Dict $script:EnEs -Word 'go' -Lang 'en').Groups
        $r = Select-InSentenceTranslation -Groups $g -TranslatedSentence 'Salio de la habitacion temprano.'
        $r.Translation | Should -Be 'salir'
        $r.Pos | Should -Be 'verb'
    }

    It 'una traduccion de varias palabras y una con barra' {
        $g = (Find-BilingualEntry -Dict $script:EnEs -Word 'mean' -Lang 'en').Groups
        (Select-InSentenceTranslation -Groups $g -TranslatedSentence 'Eso puede querer decir otra cosa.').Translation | Should -Be 'querer decir'
        (Select-InSentenceTranslation -Groups $g -TranslatedSentence 'Lo dijo para hablar en serio.').Translation | Should -Be 'decir/hablar en serio'
    }

    It 'si ninguna aparece y la forma dice la categoria, la primera de esa categoria' {
        $e = Find-BilingualEntry -Dict $script:EnEs -Word 'went' -Lang 'en' -WordNet $script:Wn
        $e.PosHint | Should -Be @('go|v')
        $r = Select-InSentenceTranslation -Groups $e.Groups -TranslatedSentence 'Fuimos al parque.' -PosHint $e.PosHint
        $r.Translation | Should -Be 'salir de'
        $r.Pos | Should -Be 'verb'
        $r.FromSentence | Should -BeFalse
        (Select-InSentenceTranslation -Groups $e.Groups -TranslatedSentence 'Fuimos al parque.').Translation | Should -Be 'intento'
    }

    It 'si ninguna aparece, la primera, y avisa que no depende de la frase' {
        $g = (Find-BilingualEntry -Dict $script:EnEs -Word 'bank' -Lang 'en').Groups
        $r = Select-InSentenceTranslation -Groups $g -TranslatedSentence 'Nada que ver.'
        $r.Translation | Should -Be 'banco'
        $r.FromSentence | Should -BeFalse
        (Select-InSentenceTranslation -Groups $g -TranslatedSentence '').FromSentence | Should -BeFalse
    }
}

Describe 'Indice inverso' {
    It 'cada traduccion apunta a su palabra, en un archivo ordenado' {
        Find-ReverseTranslations -Path $script:Inverso -Word 'Orilla' | Should -Be @('bank')
        Find-ReverseTranslations -Path $script:Inverso -Word 'querer decir' | Should -Be @('mean')
        Find-ReverseTranslations -Path $script:Inverso -Word 'hablar en serio' | Should -Be @('mean')
        Find-ReverseTranslations -Path $script:Inverso -Word 'nada' | Should -BeNullOrEmpty
    }

    It 'el archivo queda ordenado por bytes, para la biseccion' {
        $claves = @([IO.File]::ReadAllLines($script:Inverso, $script:utf8) | ForEach-Object { $_.Split([char]9)[0] })
        $ordenadas = New-Object System.Collections.Generic.List[string]
        foreach ($c in $claves) { $ordenadas.Add($c) }
        $ordenadas.Sort([StringComparer]::Ordinal)
        $claves | Should -Be $ordenadas.ToArray()
    }
}

Describe 'Add-AnkiCard' {
    BeforeEach {
        $script:Csv = Join-Path $TestDrive ('anki\palabras_' + [guid]::NewGuid().ToString('N') + '.csv')
    }

    It 'crea el archivo con la cabecera de Anki y la fila entre comillas' {
        Add-AnkiCard -Path $script:Csv -Word 'bank' -Sentence 'The bank of the river.' -Translation 'orilla' -Definition 'sloping land' -Date ([DateTime]'2026-11-28') | Should -Be 'added'
        $l = [IO.File]::ReadAllLines($script:Csv, $script:utf8)
        $l[0] | Should -Be '#separator:Comma'
        $l[1] | Should -Be '#html:false'
        $l[2] | Should -BeLike '#columns:Palabra,Frase,Traducci*n,Definici*n,Fecha'
        $l[3] | Should -Be '"bank","The bank of the river.","orilla","sloping land","2026-11-28"'
    }

    It 'UTF-8 sin BOM' {
        [void](Add-AnkiCard -Path $script:Csv -Word 'x' -Sentence 'y' -Translation 'z' -Definition '')
        $b = [IO.File]::ReadAllBytes($script:Csv)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB) | Should -BeFalse
    }

    It 'no repite la misma palabra con la misma frase, sin mirar mayusculas ni tildes' {
        Add-AnkiCard -Path $script:Csv -Word 'bank' -Sentence 'The bank of the river.' -Translation 'orilla' -Definition '' | Should -Be 'added'
        Add-AnkiCard -Path $script:Csv -Word 'Bank' -Sentence 'The  bank of the river.' -Translation 'ribera' -Definition '' | Should -Be 'duplicate'
        Add-AnkiCard -Path $script:Csv -Word 'bank' -Sentence 'I went to the bank.' -Translation 'banco' -Definition '' | Should -Be 'added'
        @([IO.File]::ReadAllLines($script:Csv, $script:utf8) | Where-Object { -not $_.StartsWith('#') }).Count | Should -Be 2
    }

    It 'comas, comillas y saltos de linea no rompen la fila' {
        [void](Add-AnkiCard -Path $script:Csv -Word 'mean' -Sentence "He said ""no"", then left.`nOK" -Translation 'querer decir, significar' -Definition 'a, b')
        $fila = @([IO.File]::ReadAllLines($script:Csv, $script:utf8) | Where-Object { -not $_.StartsWith('#') })[0]
        $c = ConvertFrom-AnkiCsvLine -Line $fila
        $c.Count | Should -Be 5
        $c[1] | Should -Be 'He said "no", then left. OK'
        $c[2] | Should -Be 'querer decir, significar'
    }
}

Describe 'Find-DictionaryEntry' {
    BeforeAll {
        $script:Fuentes = @{
            Definitions = @{ en = $script:Wn }
            Bilingual   = @{ 'en-es' = $script:EnEs; 'es-en' = $script:EsEn }
            Reverse     = @{ 'es-en' = $script:Inverso }
        }
    }

    It 'una palabra inglesa: traduccion en la frase, definiciones e IPA' {
        $r = Find-DictionaryEntry -Word 'banks' -From 'en' -To 'es' -Sources $script:Fuentes -TranslatedSentence 'Las orillas estaban cubiertas de nieve.'
        $r.Lookup | Should -Be 'bank'
        $r.InSentence.Translation | Should -Be 'orilla'
        $r.InSentence.FromSentence | Should -BeTrue
        $r.DefinitionsLang | Should -Be 'en'
        $r.Definitions[0].Senses[0].Definition | Should -Be 'sloping land beside a body of water'
        $r.Ipa.Count | Should -BeGreaterThan 0
    }

    It 'la definicion de arriba es la de la categoria de la traduccion elegida' {
        $r = Find-DictionaryEntry -Word 'mean' -From 'en' -To 'es' -Sources $script:Fuentes -TranslatedSentence 'Que significa esta palabra?'
        $r.InSentence.Translation | Should -Be 'significar'
        $r.DefinitionPos | Should -Be 'v'
        $r.Definition | Should -Be 'mean or intend to express or convey'
        $r2 = Find-DictionaryEntry -Word 'mean' -From 'en' -To 'es' -Sources $script:Fuentes -TranslatedSentence 'Calcule la media.'
        $r2.DefinitionPos | Should -Be 'n'
        $r2.Definition | Should -Be 'an average of n numbers'
    }

    It 'las formas irregulares de lo que se encontro' {
        $r = Find-DictionaryEntry -Word 'meant' -From 'en' -To 'es' -Sources $script:Fuentes
        $r.Lookup | Should -Be 'mean'
        $r.Irregular | Should -Contain 'meant'
    }

    It 'una palabra espanola con entrada directa, y la definicion de su traduccion' {
        $r = Find-DictionaryEntry -Word 'banco' -From 'es' -To 'en' -Sources $script:Fuentes -TranslatedSentence 'I sat on a bench.'
        $r.InSentence.Translation | Should -Be 'bench'
        $r.DefinitionsLang | Should -Be ''
    }

    It 'una palabra espanola sin entrada directa usa el indice inverso' {
        $r = Find-DictionaryEntry -Word 'orilla' -From 'es' -To 'en' -Sources $script:Fuentes -TranslatedSentence 'The bank was covered with snow.'
        $r.Lookup | Should -Be 'orilla'
        $r.InSentence.Translation | Should -Be 'bank'
        $r.DefinitionsLang | Should -Be 'en'
        $r.Definitions[0].Base | Should -Be 'bank'
    }

    It 'un par que no esta instalado o una palabra desconocida: nada' {
        Find-DictionaryEntry -Word 'zzzz' -From 'en' -To 'es' -Sources $script:Fuentes | Should -BeNullOrEmpty
        Find-DictionaryEntry -Word 'Haus' -From 'de' -To 'es' -Sources $script:Fuentes | Should -BeNullOrEmpty
    }
}
