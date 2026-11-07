#
# ReadAloud.Segmentacion.Tests.ps1
# Como se parte el texto en fragmentos: lineas de arbol, frases largas con un
# tope que crece (el primer fragmento corto para que la voz empiece pronto) y
# lo que se quita para que la voz no lo lea. Los simbolos se construyen con
# [char] para que este archivo sea ASCII y se lea igual en 5.1 y en 7.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Text.ps1')
    Set-SpeechTerms $null

    $te = [string][char]0x251C    # +-
    $ele = [string][char]0x2514   # L
    $raya = [string][char]0x2500  # -
    $barra = [string][char]0x2502 # |
    $ramaTe = $te + $raya + $raya
    $ramaEle = $ele + $raya + $raya
    $flechaIzq = [string][char]0x2190
    $flechaDer = [string][char]0x2192
    $rayaLarga = [string][char]0x2013
    $rangoArbol = '[' + [string][char]0x2500 + '-' + [string][char]0x257F + ']'
}

Describe 'Test-TreeLine' {
    It 'reconoce una linea con trazos de arbol' {
        Test-TreeLine -Line ($ramaTe + ' src/') | Should -BeTrue
        Test-TreeLine -Line ($barra + '   ' + $ramaEle + ' main.ps1') | Should -BeTrue
    }

    It 'no confunde el texto normal ni las tablas con barras' {
        Test-TreeLine -Line 'Una linea cualquiera - con guion' | Should -BeFalse
        Test-TreeLine -Line '| a | b |' | Should -BeFalse
    }
}

Describe 'Get-ChunkLimit' {
    It 'el primero es corto, el segundo intermedio y el resto el maximo' {
        Get-ChunkLimit -Index 0 -First 70 -Max 180 | Should -Be 70
        Get-ChunkLimit -Index 1 -First 70 -Max 180 | Should -Be 105
        Get-ChunkLimit -Index 2 -First 70 -Max 180 | Should -Be 180
        Get-ChunkLimit -Index 40 -First 70 -Max 180 | Should -Be 180
    }

    It 'sin maximo no hay limite, y un primero mayor que el maximo no lo supera' {
        Get-ChunkLimit -Index 0 -First 70 -Max 0 | Should -Be ([int]::MaxValue)
        Get-ChunkLimit -Index 0 -First 300 -Max 180 | Should -Be 180
    }
}

Describe 'Split-LongText' {
    It 'no toca un texto que cabe' {
        $piezas = @(Split-LongText -Text 'Hola mundo.' -Limits @(70))
        $piezas.Count | Should -Be 1
        $piezas[0] | Should -BeExactly 'Hola mundo.'
    }

    It 'corta antes en ; o : que en una coma' {
        $texto = 'uno dos tres cuatro cinco, seis siete ocho nueve; diez once doce trece catorce quince'
        $piezas = @(Split-LongText -Text $texto -Limits @(60))
        $piezas.Count | Should -Be 2
        $piezas[0] | Should -BeExactly 'uno dos tres cuatro cinco, seis siete ocho nueve;'
        $piezas[1] | Should -BeExactly 'diez once doce trece catorce quince'
    }

    It 'sin ; ni :, corta en la ultima coma que cabe' {
        $texto = 'uno dos tres cuatro cinco seis siete, ocho nueve diez once doce trece catorce quince dieciseis'
        $piezas = @(Split-LongText -Text $texto -Limits @(60))
        $piezas[0] | Should -BeExactly 'uno dos tres cuatro cinco seis siete,'
        $piezas.Count | Should -Be 2
    }

    It 'no corta una coma entre cifras' {
        $texto = ('a' * 32) + ' 2,5 ' + ('b' * 60) + ' ' + ('c' * 20)
        $piezas = @(Split-LongText -Text $texto -Limits @(40))
        @($piezas | Where-Object { $_ -match '\d,$' }).Count | Should -Be 0
    }

    It 'corta en una raya' {
        $texto = 'aaa bbb ccc ddd eee fff ' + $rayaLarga + ' ggg hhh iii jjj kkk lll mmm nnn ooo ppp qqq'
        $piezas = @(Split-LongText -Text $texto -Limits @(40))
        $piezas[0].EndsWith($rayaLarga) | Should -BeTrue
    }

    It 'sin ninguna pausa natural no parte una frase que pasa poco del tope' {
        $texto = 'palabra ' * 11   # 88 caracteres con un tope de 70
        @(Split-LongText -Text $texto -Limits @(70)).Count | Should -Be 1
    }

    It 'sin pausas naturales parte en un espacio una frase de verdad larga' {
        $texto = ('palabra ' * 40).Trim()   # 319 caracteres
        $piezas = @(Split-LongText -Text $texto -Limits @(70, 105, 180))
        $piezas.Count | Should -BeGreaterThan 2
        $piezas[0].Length | Should -BeLessOrEqual 70
        ($piezas -join ' ') | Should -BeExactly $texto
    }

    It 'ningun trozo pasa de una vez y media el tope, y no se pierde nada' {
        $texto = ('Una frase con palabras corrientes y sin ninguna pausa en todo el recorrido ' * 12).Trim()
        $piezas = @(Split-LongText -Text $texto -Limits @(70, 105, 180))
        @($piezas | Where-Object { $_.Length -gt 270 }).Count | Should -Be 0
        (($piezas -join ' ') -replace '\s+', ' ') | Should -BeExactly ($texto -replace '\s+', ' ')
    }
}

Describe 'Normalize-ForSpeech: lo que la voz no debe leer' {
    It 'quita los trazos de un arbol de carpetas' {
        $r = Normalize-ForSpeech -Text ($barra + '   ' + $ramaEle + ' src/') -Lang 'es'
        ($r -replace '\s+', ' ').Trim() | Should -BeExactly 'src/'
    }

    It 'quita las comillas de codigo y el enfasis de Markdown' {
        Normalize-ForSpeech -Text 'usa `git status` y **mira** esto' -Lang 'es' | Should -BeExactly 'usa git status y mira esto'
    }

    It 'las barras de una fila de tabla pasan a ser pausas' {
        Normalize-ForSpeech -Text '| Voz | Idioma | Calidad |' -Lang 'es' | Should -BeExactly 'Voz, Idioma, Calidad'
    }

    It 'los tabuladores entre celdas tambien' {
        Normalize-ForSpeech -Text "Nombre`tValor" -Lang 'es' | Should -BeExactly 'Nombre, Valor'
    }

    It 'una sola barra suelta no se toca' {
        Normalize-ForSpeech -Text 'a | b' -Lang 'es' | Should -BeExactly 'a | b'
    }

    It 'la flecha hacia la izquierda es una pausa y la de la derecha se dice' {
        $izq = Normalize-ForSpeech -Text ('carpeta ' + $flechaIzq + ' nota') -Lang 'es'
        $izq | Should -BeExactly 'carpeta, nota'
        $der = Normalize-ForSpeech -Text ('a ' + $flechaDer + ' b') -Lang 'es'
        ($der -replace '\s+', ' ') | Should -BeExactly 'a hacia b'
        $en = Normalize-ForSpeech -Text ('a ' + $flechaDer + ' b') -Lang 'en'
        ($en -replace '\s+', ' ') | Should -BeExactly 'a to b'
    }

    It 'un trozo que termina en raya acaba como una coma' {
        Normalize-ForSpeech -Text ('con raya ' + $rayaLarga) -Lang 'es' | Should -BeExactly 'con raya,'
    }
}

Describe 'Prepare-TextForPiper y las comas' {
    It 'una linea que termina en coma no recibe un punto' {
        Prepare-TextForPiper 'esto sigue en el trozo de al lado,' | Should -BeExactly 'esto sigue en el trozo de al lado,'
    }
}

Describe 'Build-SpeechPlan: arboles y frases largas' {
    It 'cada linea de un arbol es un fragmento, sin trazos en lo que dice la voz' {
        $texto = @(
            'proyecto/'
            ($ramaTe + ' src/')
            ($barra + '   ' + $ramaEle + ' main.ps1   <- el punto de entrada')
            ($ramaEle + ' docs/')
        ) -join "`n"
        $plan = Build-SpeechPlan -Text $texto
        @($plan.Chunks | Where-Object { $_.Kind -eq 'arbol' }).Count | Should -Be 3
        @($plan.Chunks | Where-Object { $_.Text -match $rangoArbol }).Count | Should -Be 0
    }

    It 'una frase larga se parte con un tope que crece' {
        $frase = (('un trozo de unas veinte letras, ') * 18).Trim().TrimEnd(',') + '.'
        $plan = Build-SpeechPlan -Text $frase
        $largos = @($plan.Chunks | ForEach-Object { $_.Display.Length })
        $plan.Chunks.Count | Should -BeGreaterThan 3
        $largos[0] | Should -BeLessOrEqual 70
        $largos[1] | Should -BeLessOrEqual 105
        @($largos | Where-Object { $_ -gt 180 }).Count | Should -Be 0
    }

    It 'con -MaxChunkChars 0 no se parte nada' {
        $frase = (('un trozo de unas veinte letras, ') * 18).Trim().TrimEnd(',') + '.'
        (Build-SpeechPlan -Text $frase -MaxChunkChars 0).Chunks.Count | Should -Be 1
    }

    It 'lo que se muestra de los trozos, juntos, es el texto original' {
        $frase = (('un trozo de unas veinte letras, ') * 18).Trim().TrimEnd(',') + '.'
        $plan = Build-SpeechPlan -Text $frase
        (($plan.Chunks | ForEach-Object { $_.Display }) -join ' ') | Should -BeExactly $frase
    }
}

Describe 'Diccionario por motor' {
    BeforeAll {
        $tsv = Join-Path $TestDrive 'terms.tsv'
        $lineas = @(
            "GitHub`tGuit jab`tGuit jap"
            "deploy`tdiploi"
        )
        Set-Content -LiteralPath $tsv -Value $lineas -Encoding UTF8
        Set-SpeechTerms (Import-SpeechTerms -Path $tsv) (Import-SpeechTerms -Path $tsv -Engine 'qwen')
    }

    AfterAll {
        Set-SpeechTerms $null
    }

    It 'Piper usa la segunda columna' {
        Expand-EnglishTerms 'Sube a GitHub' | Should -BeExactly 'Sube a Guit jab'
        Expand-EnglishTerms 'Sube a GitHub' -Engine 'piper' | Should -BeExactly 'Sube a Guit jab'
    }

    It 'la voz propia usa la tercera si existe' {
        Expand-EnglishTerms 'Sube a GitHub' -Engine 'qwen' | Should -BeExactly 'Sube a Guit jap'
    }

    It 'sin tercera columna, las dos voces usan la segunda' {
        Expand-EnglishTerms 'haz deploy' -Engine 'qwen' | Should -BeExactly 'haz diploi'
        Expand-EnglishTerms 'haz deploy' | Should -BeExactly 'haz diploi'
    }

    It 'el plan usa la grafia del motor pedido' {
        (Build-SpeechPlan -Text 'Sube el proyecto a GitHub hoy.' -Engine 'qwen').Chunks[0].Text | Should -Match 'Guit jap'
        (Build-SpeechPlan -Text 'Sube el proyecto a GitHub hoy.').Chunks[0].Text | Should -Match 'Guit jab'
    }
}

Describe 'Diccionario del usuario' {
    BeforeAll {
        $base = Join-Path $TestDrive 'base.tsv'
        $user = Join-Path $TestDrive 'usuario.tsv'
        Set-Content -LiteralPath $base -Value @("deploy`tdiploi", "GitHub`tGuit jab`tGuit jap") -Encoding UTF8
    }

    AfterAll {
        Set-SpeechTerms $null
    }

    It 'guardar agrega, y volver a guardar reemplaza' {
        Set-UserSpeechTerm -Path $user -Term 'cache' -Spoken 'cash' | Should -BeTrue
        Set-UserSpeechTerm -Path $user -Term 'CACHE' -Spoken 'cache2' | Should -BeTrue
        @(Get-Content -LiteralPath $user -Encoding UTF8).Count | Should -Be 1
        (Import-SpeechTerms -Path $user)['CACHE'] | Should -BeExactly 'cache2'
    }

    It 'rechaza lo que no sirve' {
        Set-UserSpeechTerm -Path $user -Term '' -Spoken 'x' | Should -BeFalse
        Set-UserSpeechTerm -Path $user -Term 'x' -Spoken '' | Should -BeFalse
        Set-UserSpeechTerm -Path $user -Term "a`tb" -Spoken 'x' | Should -BeFalse
    }

    It 'el del usuario manda sobre el de fabrica, tambien con la voz propia' {
        Set-UserSpeechTerm -Path $user -Term 'github' -Spoken 'Guitjab' -SpokenQwen 'Guit-jap' | Should -BeTrue
        Set-SpeechTerms (Import-AllSpeechTerms -BasePath $base -UserPath $user) (Import-AllSpeechTerms -BasePath $base -UserPath $user -Engine 'qwen')
        Expand-EnglishTerms 'Sube a GitHub' | Should -BeExactly 'Sube a Guitjab'
        Expand-EnglishTerms 'Sube a GitHub' -Engine 'qwen' | Should -BeExactly 'Sube a Guit-jap'
        Expand-EnglishTerms 'haz deploy' | Should -BeExactly 'haz diploi'
        (Find-SpeechTerm 'DEPLOY').Piper | Should -BeExactly 'diploi'
        (Find-SpeechTerm 'github').Qwen | Should -BeExactly 'Guit-jap'
        Find-SpeechTerm 'nada' | Should -BeNullOrEmpty
    }

    It 'quitar devuelve el de fabrica' {
        Remove-UserSpeechTerm -Path $user -Term 'GITHUB' | Should -BeTrue
        Remove-UserSpeechTerm -Path $user -Term 'GITHUB' | Should -BeFalse
        Set-SpeechTerms (Import-AllSpeechTerms -BasePath $base -UserPath $user) (Import-AllSpeechTerms -BasePath $base -UserPath $user -Engine 'qwen')
        Expand-EnglishTerms 'Sube a GitHub' -Engine 'qwen' | Should -BeExactly 'Sube a Guit jap'
    }

    It 'sin archivo del usuario, solo el de fabrica' {
        (Import-AllSpeechTerms -BasePath $base -UserPath (Join-Path $TestDrive 'no.tsv')).Count | Should -Be 2
    }
}
