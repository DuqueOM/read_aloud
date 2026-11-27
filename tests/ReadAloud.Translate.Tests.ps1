#
# ReadAloud.Translate.Tests.ps1
# La logica de la traduccion rapida (lib\ReadAloud.Translate.ps1), sin
# procesos: direccion, troceo, peticiones a los motores, eleccion del
# traductor, regla de memoria y vuelta a la voz propia.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Text.ps1')
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Translate.ps1')
}

Describe 'Get-TranslationDirection' {
    It 'ingles va a espanol' {
        $d = Get-TranslationDirection -Text 'The meeting was moved to Thursday because the room is not available.'
        $d.Source | Should -Be 'en'
        $d.Target | Should -Be 'es'
    }

    It 'espanol va a ingles' {
        $d = Get-TranslationDirection -Text 'La reunion se movio al jueves porque la sala no esta disponible.'
        $d.Source | Should -Be 'es'
        $d.Target | Should -Be 'en'
    }

    It 'un texto ambiguo usa el idioma de respaldo como origen (<Respaldo>)' -ForEach @(
        @{ Respaldo = 'es'; Destino = 'en' }
        @{ Respaldo = 'en'; Destino = 'es' }
    ) {
        $d = Get-TranslationDirection -Text 'OK 42' -Fallback $Respaldo
        $d.Source | Should -Be $Respaldo
        $d.Target | Should -Be $Destino
    }
}

Describe 'Split-TranslationParts' {
    It 'un bloque por parrafo, en orden' {
        $r = Split-TranslationParts -Text "First paragraph here.`n`nSecond paragraph here."
        $r.Blocks.Count | Should -Be 2
        $r.Parts.Count | Should -Be 2
        $r.Parts[0].Text | Should -Be 'First paragraph here.'
        $r.Parts[0].Block | Should -Be 0
        $r.Parts[1].Block | Should -Be 1
        $r.Parts[0].First | Should -BeTrue
        $r.Parts[1].First | Should -BeFalse
    }

    It 'con -FirstSentence la primera frase va sola y el resto del parrafo despues' {
        $texto = "The first sentence is short. The second one follows. And a third.`n`nAnother paragraph."
        $r = Split-TranslationParts -Text $texto -FirstSentence
        $r.Parts.Count | Should -Be 3
        $r.Parts[0].Text | Should -Be 'The first sentence is short.'
        $r.Parts[1].Text | Should -Be 'The second one follows. And a third.'
        $r.Parts[0].Block | Should -Be 0
        $r.Parts[1].Block | Should -Be 0
        $r.Parts[2].Block | Should -Be 1
    }

    It 'sin -FirstSentence el primer parrafo va entero' {
        $r = Split-TranslationParts -Text 'One sentence. Two sentences.'
        $r.Parts.Count | Should -Be 1
        $r.Parts[0].Text | Should -Be 'One sentence. Two sentences.'
    }

    It 'un parrafo de una sola frase no se parte' {
        $r = Split-TranslationParts -Text 'Only one sentence here.' -FirstSentence
        $r.Parts.Count | Should -Be 1
    }

    It 'un parrafo mas largo que MaxChars se parte entre frases' {
        $frases = 1..10 | ForEach-Object { "This is sentence number $_ of the text." }
        $r = Split-TranslationParts -Text ($frases -join ' ') -MaxChars 120
        $r.Parts.Count | Should -BeGreaterThan 3
        foreach ($p in $r.Parts) { $p.Text.Length | Should -BeLessOrEqual 120 }
        ($r.Parts | ForEach-Object { $_.Text }) -join ' ' | Should -Be ($frases -join ' ')
    }

    It 'los titulos pierden las almohadillas y las vinetas guardan su marca aparte' {
        $r = Split-TranslationParts -Text "## Getting started`n`n- Install the program`n- Open the settings"
        $r.Blocks[0].Kind | Should -Be 'titulo'
        $r.Blocks[0].Source | Should -Be 'Getting started'
        $r.Blocks[1].Kind | Should -Be 'vineta'
        $r.Blocks[1].Prefix | Should -Be '-'
        $r.Blocks[1].Source | Should -Be 'Install the program'
        $r.Parts[1].Text | Should -Be 'Install the program'
    }

    It 'las lineas de un arbol y los bloques sin letras no se traducen' {
        $arbol = [string][char]0x251C + [string][char]0x2500 + ' src'
        $r = Split-TranslationParts -Text "Project layout:`n$arbol`n`n12345"
        @($r.Blocks | Where-Object { $_.Kind -eq 'arbol' })[0].Translate | Should -BeFalse
        $r.Blocks[$r.Blocks.Count - 1].Translate | Should -BeFalse
        @($r.Parts | Where-Object { $_.Text -match 'src|12345' }).Count | Should -Be 0
    }

    It 'la pausa de cada bloque es la de la lectura' {
        $r = Split-TranslationParts -Text "One paragraph.`n`nAnother one."
        $r.Blocks[0].PauseAfter | Should -Be 0.35
        $r.Blocks[1].PauseAfter | Should -Be 0.0
    }

    It 'un texto vacio no tiene partes' {
        $r = Split-TranslationParts -Text "  `n  "
        $r.Parts.Count | Should -Be 0
        $r.Blocks.Count | Should -Be 0
    }
}

Describe 'Get-TranslationRequest' {
    It 'Hy-MT2 usa el chat con la instruccion de su ficha' {
        $p = Get-TranslationRequest -Family 'hymt2' -Text 'Hola mundo' -Source 'es' -Target 'en'
        $p.Path | Should -Be '/v1/chat/completions'
        $p.Body.messages[0].role | Should -Be 'user'
        $p.Body.messages[0].content | Should -BeLike 'Translate the following text into English.*Hola mundo'
        $p.Body.stream | Should -BeTrue
        $p.Body.temperature | Should -Be 0.7
        $p.Body.top_k | Should -Be 20
    }

    It 'TranslateGemma usa el prompt crudo, sin <bos>, y para en <end_of_turn>' {
        $p = Get-TranslationRequest -Family 'tgemma' -Text '  Good morning  ' -Source 'en' -Target 'es'
        $p.Path | Should -Be '/completion'
        $p.Body.prompt | Should -BeLike '<start_of_turn>user*English (en) to Spanish (es)*Good morning<end_of_turn>*<start_of_turn>model*'
        $p.Body.prompt | Should -Not -BeLike '*<bos>*'
        $p.Body.stop | Should -Contain '<end_of_turn>'
        $p.Body.temperature | Should -Be 0.0
    }

    It 'el tope de tokens es 0.8 por caracter mas 64, con un minimo de 64' {
        Get-TranslationMaxTokens -Text '' | Should -Be 64
        Get-TranslationMaxTokens -Text ('x' * 100) | Should -Be 144
        Get-TranslationMaxTokens -Text ('x' * 101) | Should -Be 144
    }

    It 'una familia desconocida es un error' {
        { Get-TranslationRequest -Family 'otra' -Text 'x' -Source 'en' -Target 'es' } | Should -Throw
    }

    It 'el cuerpo se serializa a JSON' {
        $p = Get-TranslationRequest -Family 'hymt2' -Text 'Hi' -Source 'en' -Target 'es'
        $json = ConvertTo-Json -InputObject $p.Body -Compress -Depth 5
        ($json | ConvertFrom-Json).messages[0].content | Should -BeLike '*into Spanish*'
    }
}

Describe 'ConvertFrom-TranslationStreamLine' {
    It 'lee el trozo de texto del chat' {
        $r = ConvertFrom-TranslationStreamLine -Family 'hymt2' -Line 'data: {"choices":[{"delta":{"content":"Hola"},"finish_reason":null}]}'
        $r.Text | Should -Be 'Hola'
        $r.Done | Should -BeFalse
    }

    It 'reconoce el final del chat y sus tiempos' {
        $r = ConvertFrom-TranslationStreamLine -Family 'hymt2' -Line 'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"timings":{"predicted_n":12}}'
        $r.Done | Should -BeTrue
        $r.Timings.predicted_n | Should -Be 12
    }

    It 'lee el texto de /completion' {
        $r = ConvertFrom-TranslationStreamLine -Family 'tgemma' -Line 'data: {"content":" mundo","stop":false}'
        $r.Text | Should -Be ' mundo'
        $r.Done | Should -BeFalse
        (ConvertFrom-TranslationStreamLine -Family 'tgemma' -Line 'data: {"content":"","stop":true}').Done | Should -BeTrue
    }

    It '[DONE] es el final' {
        (ConvertFrom-TranslationStreamLine -Family 'hymt2' -Line 'data: [DONE]').Done | Should -BeTrue
    }

    It 'una linea vacia, un comentario o un JSON roto no traen nada' -ForEach @(
        @{ Linea = '' }
        @{ Linea = ': ping' }
        @{ Linea = 'data: {roto' }
    ) {
        ConvertFrom-TranslationStreamLine -Family 'hymt2' -Line $Linea | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-BergamotMessage' {
    It 'lleva el largo del JSON delante, en 4 bytes little-endian' {
        $m = ConvertTo-BergamotMessage -Id 7 -Command 'Translate' -Data (Get-BergamotTranslateData -Text 'Hola' -Source 'es' -Target 'en')
        $largo = [BitConverter]::ToUInt32($m, 0)
        $largo | Should -Be ($m.Length - 4)
        $json = [Text.Encoding]::UTF8.GetString($m, 4, $m.Length - 4)
        $d = $json | ConvertFrom-Json
        $d.id | Should -Be 7
        $d.command | Should -Be 'Translate'
        $d.data.src | Should -Be 'es'
        $d.data.trg | Should -Be 'en'
        $d.data.html | Should -BeFalse
    }

    It 'cuenta bytes, no caracteres, con tildes' {
        $texto = 'Canci' + [char]0x00F3 + 'n'
        $m = ConvertTo-BergamotMessage -Id 1 -Command 'Translate' -Data (Get-BergamotTranslateData -Text $texto -Source 'es' -Target 'en')
        [BitConverter]::ToUInt32($m, 0) | Should -Be ($m.Length - 4)
        ([Text.Encoding]::UTF8.GetString($m, 4, $m.Length - 4) | ConvertFrom-Json).data.text | Should -Be $texto
    }
}
