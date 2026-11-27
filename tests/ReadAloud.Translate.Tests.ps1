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

Describe 'Get-InstalledTranslators' {
    BeforeEach {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
    }

    It 'sin la carpeta no hay traductores' {
        @(Get-InstalledTranslators -TranslateDir (Join-Path $dir 'no_existe')).Count | Should -Be 0
    }

    It 'reconoce Bergamot y los GGUF del catalogo, con su tamano' {
        New-Item -ItemType Directory -Path (Join-Path $dir 'translateLocally\models\en-es-base-memory') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'translateLocally\translateLocally.exe') -Value 'x'
        New-Item -ItemType Directory -Path (Join-Path $dir 'llama') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'llama\llama-server.exe') -Value 'x'
        New-Item -ItemType Directory -Path (Join-Path $dir 'modelos') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $dir 'modelos\Hy-MT2-1.8B-Q4_K_M.gguf'), (New-Object byte[] (3MB)))
        Set-Content -LiteralPath (Join-Path $dir 'modelos\otro-modelo.gguf') -Value 'x'

        $t = @(Get-InstalledTranslators -TranslateDir $dir)
        $t.Count | Should -Be 2
        $t[0].Id | Should -Be 'bergamot'
        $t[0].Path | Should -BeLike '*translateLocally.exe'
        $t[1].Id | Should -Be 'hymt2-1.8b'
        $t[1].FileMiB | Should -Be 3
        $t[1].Server | Should -BeLike '*llama-server.exe'
    }

    It 'un GGUF sin llama-server no cuenta' {
        New-Item -ItemType Directory -Path (Join-Path $dir 'modelos') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'modelos\Hy-MT2-7B-Q4_K_M.gguf') -Value 'x'
        @(Get-InstalledTranslators -TranslateDir $dir).Count | Should -Be 0
    }

    It 'no cambia el catalogo' {
        New-Item -ItemType Directory -Path (Join-Path $dir 'translateLocally\models') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'translateLocally\translateLocally.exe') -Value 'x'
        [void](Get-InstalledTranslators -TranslateDir $dir)
        (Get-TranslatorCatalog | Where-Object { $_.Id -eq 'bergamot' }).ContainsKey('Path') | Should -BeFalse
    }
}

Describe 'Eleccion del traductor' {
    BeforeAll {
        function New-TestTranslator {
            param([string]$Id, [double]$FileMiB)
            $t = @{} + @(Get-TranslatorCatalog | Where-Object { $_.Id -eq $Id })[0]
            $t.FileMiB = $FileMiB
            return $t
        }

        $bergamot = New-TestTranslator 'bergamot' 112
        $hy18 = New-TestTranslator 'hymt2-1.8b' 1081
        $hy7 = New-TestTranslator 'hymt2-7b' 4411
        $todos = @($bergamot, $hy18, $hy7)

        # El equipo del ADR 0016 de noche: 8 GB de tarjeta con la voz propia
        # cargada (2.8 GB libres), 16 nucleos fisicos y unos 6 GB de RAM libre.
        function New-AdrDevice {
            param([double]$Ram = 6000, [double]$Gpu = 2867, [bool]$Busy = $false)
            return @{ RamAvailableMiB = $Ram; GpuFreeMiB = $Gpu; GpuBusy = $Busy; PhysicalCores = 16 }
        }
        $conVoz = New-VoiceState -Available $true -Loaded $true
    }

    Context 'Get-TranslatorThreads' {
        It '<Nucleos> nucleos fisicos usan <Hilos> hilos' -ForEach @(
            @{ Nucleos = 16; Hilos = 4 }
            @{ Nucleos = 8; Hilos = 4 }
            @{ Nucleos = 6; Hilos = 3 }
            @{ Nucleos = 4; Hilos = 2 }
            @{ Nucleos = 2; Hilos = 1 }
            @{ Nucleos = 1; Hilos = 1 }
            @{ Nucleos = 0; Hilos = 1 }
        ) {
            Get-TranslatorThreads -PhysicalCores $Nucleos | Should -Be $Hilos
        }
    }

    Context 'Automatica en el equipo del ADR' {
        It 'elige la voz propia con Hy-MT2 1.8B en el procesador' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice) -Voice $conVoz -Options @{ Priority = 'auto' }
            $r.Combo.Id | Should -Be 'qwen+hymt2-1.8b@cpu'
            $r.Combo.Threads | Should -Be 4
            [Math]::Round($r.Combo.Score, 1) | Should -Be 7.6
        }

        It 'la mejor sin la voz propia es el 7B en la tarjeta, con menos nota' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice) -Voice $conVoz -Options @{}
            $siete = @($r.Candidates | Where-Object { $_.Id -eq 'piper+hymt2-7b@gpu' })[0]
            $siete.Fits | Should -BeTrue
            [Math]::Round($siete.Score, 1) | Should -Be 6.9
        }

        It 'ningun modelo de lenguaje cabe en la tarjeta junto a la voz' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice) -Voice $conVoz -Options @{}
            @($r.Candidates | Where-Object { $_.Voice -eq 'qwen' -and $_.Where -eq 'gpu' -and $_.Fits }).Count | Should -Be 0
        }
    }

    Context 'Prioridad, calidad y seccion avanzada' {
        It 'Traduccion: la voz propia cede la tarjeta al 7B' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice) -Voice $conVoz -Options @{ Priority = 'translation' }
            $r.Combo.Id | Should -Be 'piper+hymt2-7b@gpu'
        }

        It 'Voz propia: lo mejor que cabe a su lado' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice) -Voice $conVoz -Options @{ Priority = 'voice' }
            $r.Combo.Id | Should -Be 'qwen+hymt2-1.8b@cpu'
        }

        It 'Traduccion con la tarjeta ocupada por otro programa: junto a la voz propia y con una nota' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice -Busy $true) -Voice $conVoz -Options @{ Priority = 'translation' }
            $r.Combo.Id | Should -Be 'qwen+hymt2-1.8b@cpu'
            $r.Notes -join ' ' | Should -BeLike '*ningun traductor cabe en la tarjeta*'
        }

        It 'Basica: Bergamot' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice) -Voice $conVoz -Options @{ Quality = 'basic' }
            $r.Combo.Id | Should -Be 'qwen+bergamot@cpu'
        }

        It 'Alta: solo modelos de lenguaje' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice) -Voice $conVoz -Options @{ Quality = 'high' }
            $r.Combo.Translator.Engine | Should -Be 'llama'
        }

        It 'un modelo elegido a mano' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice) -Voice $conVoz -Options @{ Priority = 'translation'; Model = 'hymt2-1.8b' }
            $r.Combo.Id | Should -Be 'piper+hymt2-1.8b@gpu'
        }

        It 'Procesador con prioridad de traduccion: no hay nada en la tarjeta y se traduce junto a la voz' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice) -Voice $conVoz -Options @{ Priority = 'translation'; Where = 'cpu' }
            $r.Combo.Id | Should -Be 'qwen+hymt2-1.8b@cpu'
        }

        It 'Tarjeta grafica con prioridad Voz propia: el modelo no cabe y queda el basico' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice) -Voice $conVoz -Options @{ Priority = 'voice'; Where = 'gpu'; Quality = 'high' }
            $r.Combo.Id | Should -Be 'qwen+bergamot@cpu'
            $r.Notes -join ' ' | Should -BeLike '*se usa el basico*'
        }
    }

    Context 'Regla de memoria y paso a lo mas ligero' {
        It 'con poca RAM, Bergamot, y la nota dice por que no cupo el 1.8B' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice -Ram 2000) -Voice $conVoz -Options @{ Priority = 'voice' }
            $r.Combo.Id | Should -Be 'qwen+bergamot@cpu'
            $r.Notes -join ' ' | Should -BeLike '*No cabe qwen+hymt2-1.8b@cpu: en la RAM necesita 2*888 MiB y hay 2*000*'
        }

        It 'lo que ya esta cargado cabe sin comprobarlo' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice -Ram 500) -Voice $conVoz -Options @{ Priority = 'voice' } -Loaded 'qwen+hymt2-1.8b@cpu'
            $r.Combo.Id | Should -Be 'qwen+hymt2-1.8b@cpu'
        }

        It 'sin el basico y sin memoria no hay traductor' {
            $r = Select-TranslationCombo -Translators @($hy18) -Device (New-AdrDevice -Ram 500 -Gpu -1) -Voice (New-VoiceState) -Options @{}
            $r.Combo | Should -BeNullOrEmpty
            $r.Notes -join ' ' | Should -BeLike '*no esta instalado el basico*'
        }

        It 'sin traductores instalados no hay combinacion' {
            $r = Select-TranslationCombo -Translators @() -Device (New-AdrDevice) -Voice $conVoz -Options @{}
            $r.Combo | Should -BeNullOrEmpty
        }

        It 'tarjeta: 600 MiB de margen sobre el modelo, la cache y 400 MiB, descontando lo que la voz toma al leer' {
            # 1081 + 256 + 400 + 600 = 2337, mas 1434 de la voz al leer.
            $justo = New-AdrDevice -Gpu (2337 + 1434)
            (Test-TranslatorFits -Translator $hy18 -Where 'gpu' -Device $justo -Voice $conVoz -VoiceName 'qwen').Fits | Should -BeTrue
            $falta = New-AdrDevice -Gpu (2337 + 1434 - 1)
            (Test-TranslatorFits -Translator $hy18 -Where 'gpu' -Device $falta -Voice $conVoz -VoiceName 'qwen').Fits | Should -BeFalse
        }

        It 'tarjeta: si la voz propia cede, lo suyo cuenta como libre' {
            $r = Test-TranslatorFits -Translator $hy7 -Where 'gpu' -Device (New-AdrDevice) -Voice $conVoz -VoiceName 'piper'
            $r.HaveMiB | Should -Be (2867 + 5120)
            $r.NeedMiB | Should -Be (4411 + 512 + 400 + 600)
            $r.Fits | Should -BeTrue
        }

        It 'tarjeta: si la voz propia aun no carga pero va a leer, se descuenta todo lo suyo' {
            $sinCargar = New-VoiceState -Available $true -Loaded $false
            $r = Test-TranslatorFits -Translator $hy18 -Where 'gpu' -Device (New-AdrDevice -Gpu 7800) -Voice $sinCargar -VoiceName 'qwen'
            $r.HaveMiB | Should -Be (7800 - 1434 - 5120)
        }

        It 'procesador: 1.25 veces el archivo mas 1.5 GB' {
            $r = Test-TranslatorFits -Translator $hy18 -Where 'cpu' -Device (New-AdrDevice -Ram 2888) -Voice $conVoz -VoiceName 'qwen'
            $r.NeedMiB | Should -Be 2888
            $r.Fits | Should -BeTrue
            (Test-TranslatorFits -Translator $hy18 -Where 'cpu' -Device (New-AdrDevice -Ram 2887) -Voice $conVoz -VoiceName 'qwen').Fits | Should -BeFalse
        }

        It 'sin tarjeta NVIDIA o con la tarjeta ocupada, nada va a la tarjeta' {
            (Test-TranslatorFits -Translator $hy18 -Where 'gpu' -Device (New-AdrDevice -Gpu -1) -Voice $conVoz).Reason | Should -Be 'no hay tarjeta NVIDIA'
            (Test-TranslatorFits -Translator $hy18 -Where 'gpu' -Device (New-AdrDevice -Busy $true) -Voice $conVoz).Fits | Should -BeFalse
        }
    }

    Context 'Equipos sin voz propia' {
        It 'sin NVIDIA: Hy-MT2 1.8B en el procesador, leyendo con Piper' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice -Gpu -1) -Voice (New-VoiceState) -Options @{}
            $r.Combo.Id | Should -Be 'piper+hymt2-1.8b@cpu'
        }

        It 'con NVIDIA y sin voz propia: el 7B en la tarjeta' {
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice -Gpu 7600) -Voice (New-VoiceState) -Options @{ Priority = 'voice' }
            $r.Combo.Id | Should -Be 'piper+hymt2-7b@gpu'
        }

        It 'solo con el basico instalado: Bergamot' {
            $r = Select-TranslationCombo -Translators @($bergamot) -Device (New-AdrDevice -Gpu -1) -Voice (New-VoiceState) -Options @{}
            $r.Combo.Id | Should -Be 'piper+bergamot@cpu'
        }
    }

    Context 'Perfil del equipo' {
        It 'manda sobre las cifras del ADR' {
            $perfil = '{"combinaciones":{"qwen+hymt2-1.8b@cpu":{"primer_sonido_s":12.0,"freno_voz":0.04}}}' | ConvertFrom-Json
            $r = Select-TranslationCombo -Translators $todos -Device (New-AdrDevice) -Voice $conVoz -Options @{ Priority = 'voice' } -Perfil $perfil
            $r.Combo.Id | Should -Be 'qwen+bergamot@cpu'
            (@($r.Candidates | Where-Object { $_.Id -eq 'qwen+hymt2-1.8b@cpu' })[0]).Metrics.Source | Should -Be 'perfil'
        }

        It 'sin la combinacion en el perfil, se usa el ADR y, si no se midio, una estimacion' {
            $perfil = @{ combinaciones = @{} }
            (Get-ComboMetrics -Voice 'qwen' -Translator $hy18 -Where 'cpu' -Perfil $perfil).Source | Should -Be 'adr'
            $e = Get-ComboMetrics -Voice 'qwen' -Translator $hy7 -Where 'gpu' -Perfil $perfil
            $e.Source | Should -Be 'estimado'
            $e.FirstSound | Should -Be 3.4
        }
    }

    Context 'Test-PriorityChoiceNeeded' {
        It 'aparece si el mejor traductor no cabe junto a la voz propia' {
            Test-PriorityChoiceNeeded -Translators $todos -Device (New-AdrDevice) -Voice $conVoz | Should -BeTrue
        }

        It 'no aparece si el mejor cabe a su lado' {
            Test-PriorityChoiceNeeded -Translators @($bergamot, $hy18) -Device (New-AdrDevice) -Voice $conVoz | Should -BeFalse
        }

        It 'no aparece sin voz propia ni sin traductores' {
            Test-PriorityChoiceNeeded -Translators $todos -Device (New-AdrDevice) -Voice (New-VoiceState) | Should -BeFalse
            Test-PriorityChoiceNeeded -Translators @() -Device (New-AdrDevice) -Voice $conVoz | Should -BeFalse
        }
    }
}

Describe 'Get-VoiceReturnState' {
    BeforeAll {
        $ultima = [DateTime]'2026-11-27T10:00:00'
    }

    It 'si la voz propia no cedio la tarjeta no hay nada que hacer' {
        $r = Get-VoiceReturnState -VoiceYielded $false -Priority 'translation' -LastTranslation $ultima -Now $ultima.AddHours(2)
        $r.Due | Should -BeFalse
        $r.Active | Should -BeFalse
    }

    It 'con <Prioridad>, cuenta los minutos desde la ultima traduccion' -ForEach @(
        @{ Prioridad = 'translation' }
        @{ Prioridad = 'auto' }
    ) {
        $r = Get-VoiceReturnState -VoiceYielded $true -Priority $Prioridad -Minutes 15 -LastTranslation $ultima -Now $ultima.AddMinutes(10)
        $r.Active | Should -BeTrue
        $r.Due | Should -BeFalse
        $r.SecondsLeft | Should -Be 300
        (Get-VoiceReturnState -VoiceYielded $true -Priority $Prioridad -Minutes 15 -LastTranslation $ultima -Now $ultima.AddMinutes(15)).Due | Should -BeTrue
    }

    It 'nunca vuelve a mitad de una lectura' {
        $r = Get-VoiceReturnState -VoiceYielded $true -Priority 'translation' -Minutes 15 -LastTranslation $ultima -Now $ultima.AddMinutes(40) -Reading $true
        $r.Due | Should -BeFalse
        $r.SecondsLeft | Should -Be 0
    }

    It 'con la opcion desactivada se queda donde esta' {
        $r = Get-VoiceReturnState -VoiceYielded $true -Priority 'translation' -AutoReturn $false -LastTranslation $ultima -Now $ultima.AddHours(5)
        $r.Due | Should -BeFalse
        $r.Active | Should -BeFalse
    }

    It 'con la prioridad Voz propia vuelve enseguida, aunque la opcion este desactivada' {
        (Get-VoiceReturnState -VoiceYielded $true -Priority 'voice' -AutoReturn $false -LastTranslation $ultima -Now $ultima).Due | Should -BeTrue
        (Get-VoiceReturnState -VoiceYielded $true -Priority 'voice' -LastTranslation $ultima -Now $ultima -Reading $true).Due | Should -BeFalse
    }

    It 'menos de un minuto cuenta como uno' {
        $r = Get-VoiceReturnState -VoiceYielded $true -Priority 'translation' -Minutes 0 -LastTranslation $ultima -Now $ultima.AddSeconds(30)
        $r.SecondsLeft | Should -Be 30
    }
}
