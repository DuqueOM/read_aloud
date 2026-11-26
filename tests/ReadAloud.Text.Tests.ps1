#
# ReadAloud.Text.Tests.ps1
# Pruebas de lib\ReadAloud.Text.ps1: deteccion de idioma, segmentacion,
# normalizacion para la voz y partido en bloques. Fijan lo que hace el codigo
# hoy; si una cambia, que sea porque se quiso cambiar la lectura.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Text.ps1')
}

Describe 'Remove-Diacritics' {
    It 'quita las tildes y deja la ñ como n' {
        Remove-Diacritics 'Canción del ñandú' | Should -BeExactly 'Cancion del nandu'
    }

    It 'devuelve igual un texto vacío' {
        Remove-Diacritics '' | Should -BeExactly ''
    }
}

Describe 'Get-LanguageProfile' {
    It 'reconoce una frase en español' {
        (Get-LanguageProfile 'Esta es una frase que está escrita en español para la prueba.').Lang | Should -Be 'es'
    }

    It 'reconoce una frase en inglés' {
        (Get-LanguageProfile 'This is a sentence that was written in English for the test.').Lang | Should -Be 'en'
    }

    It 'no decide con solo números' {
        $perfil = Get-LanguageProfile '12345 678'
        $perfil.Lang | Should -Be 'unknown'
        $perfil.Tokens | Should -Be 2
    }

    It 'no cuenta palabras en un texto sin letras ni números' {
        (Get-LanguageProfile '... !!!').Tokens | Should -Be 0
    }
}

Describe 'Get-DocumentLanguage' {
    It 'respeta el idioma pedido aunque el texto sea de otro' {
        Get-DocumentLanguage -Text 'This is clearly written in English.' -Requested 'Spanish' | Should -Be 'es'
        Get-DocumentLanguage -Text 'Esto está escrito en español.' -Requested 'English' | Should -Be 'en'
    }

    It 'usa el idioma de respaldo si no puede decidir' {
        Get-DocumentLanguage -Text '12345' -Fallback 'en' | Should -Be 'en'
    }
}

Describe 'Split-IntoSentences' {
    BeforeAll {
        # Split-IntoSentences devuelve la lista con return ,: dentro de @() quedaría
        # anidada. Así se compara frase por frase.
        function Get-Frases([string]$Texto) { return (Split-IntoSentences $Texto).ToArray() }
    }

    It 'parte por punto, pregunta, exclamación y salto de línea' {
        $frases = Split-IntoSentences "Hola. ¿Qué tal? ¡Bien!`r`nOtra línea"
        @($frases) | Should -Be @('Hola.', '¿Qué tal?', '¡Bien!', 'Otra línea')
    }

    It 'no parte un número con punto decimal' {
        $frases = Split-IntoSentences 'La versión 3.5 ya está lista.'
        @($frases) | Should -Be @('La versión 3.5 ya está lista.')
    }

    It 'ignora las líneas vacías' {
        $frases = Split-IntoSentences "Uno.`n`n   `nDos."
        $frases.Count | Should -Be 2
    }

    It 'corta solo en los finales de frase de un texto con abreviaturas' {
        $texto = 'El Dr. García llegó a las 3.30 p. m. con el Sr. López, etc. Luego dijo: "no sé"... y se fue. ' +
            '¿En serio?! Sí. Mide 2,5 m y pesa 1.200 kg; según EE. UU. es mucho, p. ej. en Texas. ' +
            'The U.S. team met Mr. Smith at 5 p.m. on Jan. 3, e.g. before lunch... Really?! Yes. It costs $3.50, i.e. cheap.'
        @(Get-Frases $texto) | Should -Be @(
            'El Dr. García llegó a las 3.30 p. m. con el Sr. López, etc.'
            'Luego dijo: "no sé"... y se fue.'
            '¿En serio?!'
            'Sí.'
            'Mide 2,5 m y pesa 1.200 kg; según EE. UU. es mucho, p. ej. en Texas.'
            'The U.S. team met Mr. Smith at 5 p.m. on Jan. 3, e.g. before lunch...'
            'Really?!'
            'Yes.'
            'It costs $3.50, i.e. cheap.'
        )
    }

    It 'no corta si sigue una minúscula: <Texto>' -ForEach @(
        @{ Texto = 'Llegó a las 3 p. m. con su hermano.' }
        @{ Texto = 'Pensé... y luego dije que sí.' }
        @{ Texto = 'Compré pan, leche, etc. y luego volví.' }
        @{ Texto = '¿Vienes? preguntó Ana.' }
        @{ Texto = 'Le escribí. después me arrepentí.' }
    ) {
        @(Get-Frases $Texto) | Should -Be @($Texto)
    }

    It 'no corta después de una abreviatura: <Texto>' -ForEach @(
        @{ Texto = 'Lo atendió el Dr. García con la Dra. Díaz y la Srta. Ruiz.' }
        @{ Texto = 'Firmaron el Lic. Pérez, el Ing. Gómez y el Prof. Ruiz.' }
        @{ Texto = 'Si Ud. quiere, Uds. pueden venir con el Sr. y la Sra. Vega.' }
        @{ Texto = 'Ver pág. 12, núm. 3 y aprox. 30 casos más.' }
        @{ Texto = 'Hay lenguajes libres, p. ej. Python y Go.' }
        @{ Texto = 'Viajó a EE. UU. En marzo volvió.' }
        @{ Texto = 'Nos vemos a las 8 a. m. Juan trae el café.' }
        @{ Texto = 'Mr. Smith, Mrs. Jones and Ms. Lee met at St. Patrick Church.' }
        @{ Texto = 'It was Spain vs. France, e.g. Real vs. Barcelona, i.e. Madrid.' }
        @{ Texto = 'The U.S. Army and the U.K. Navy met at 5 p.m. Then they left.' }
    ) {
        @(Get-Frases $Texto) | Should -Be @($Texto)
    }

    It 'no corta después de No. o de un mes en inglés si sigue una cifra' {
        @(Get-Frases 'Vive en la casa No. 5 de la calle.') | Should -Be @('Vive en la casa No. 5 de la calle.')
        @(Get-Frases 'It was on Jan. 3 and Feb. 14 of 2026.') | Should -Be @('It was on Jan. 3 and Feb. 14 of 2026.')
    }

    It 'corta después de No. o de un mes si sigue una mayúscula' {
        @(Get-Frases '¿Vienes? No. Luego te llamo.') | Should -Be @('¿Vienes?', 'No.', 'Luego te llamo.')
        @(Get-Frases 'We met in Sept. Then we left.') | Should -Be @('We met in Sept.', 'Then we left.')
    }

    It 'no corta en iniciales sueltas' {
        @(Get-Frases 'J. K. Ramírez lo escribió.') | Should -Be @('J. K. Ramírez lo escribió.')
        @(Get-Frases 'Lo firmó J. R. R. Ortiz. Después lo publicaron.') |
            Should -Be @('Lo firmó J. R. R. Ortiz.', 'Después lo publicaron.')
    }

    It 'corta ante mayúscula, ¿, ¡, comillas o cifra si no es abreviatura' {
        @(Get-Frases 'Uno. ¿Dos? ¡Tres! "Cuatro", dijo. 5 más.') |
            Should -Be @('Uno.', '¿Dos?', '¡Tres!', '"Cuatro", dijo.', '5 más.')
    }

    It 'corta después de etc. y de puntos suspensivos si sigue una mayúscula' {
        @(Get-Frases 'Compré pan, leche, etc. Luego volví.') | Should -Be @('Compré pan, leche, etc.', 'Luego volví.')
        @(Get-Frases 'Pensé... Luego dije que sí.') | Should -Be @('Pensé...', 'Luego dije que sí.')
    }

    It 'corta después de una abreviatura si sigue ¿ o ¡' {
        @(Get-Frases 'Gracias, Sr. ¿Algo más?') | Should -Be @('Gracias, Sr.', '¿Algo más?')
    }

    It 'corta después de una unidad de una letra' {
        @(Get-Frases 'Mide 2 m. Luego crece.') | Should -Be @('Mide 2 m.', 'Luego crece.')
    }
}

Describe 'Split-IntoLanguageSegments' {
    It 'cambia de idioma con una frase larga y clara' {
        $texto = 'Hoy probamos la lectura en dos idiomas. The voice should switch when the sentence is clearly in English.'
        $segmentos = Split-IntoLanguageSegments -Text $texto -DocumentLang 'es'
        @($segmentos | ForEach-Object { $_.Lang }) | Should -Be @('es', 'en')
    }

    It 'no cambia de idioma por una frase corta' {
        $texto = 'Hoy probamos la lectura en dos idiomas. Save changes. Y luego seguimos con el resto del texto.'
        $segmentos = Split-IntoLanguageSegments -Text $texto -DocumentLang 'es'
        $segmentos.Count | Should -Be 1
        $segmentos[0].Sentences.Count | Should -Be 3
    }

    It 'deja todo en un segmento si el idioma está forzado' {
        $texto = 'Hoy probamos la lectura en dos idiomas. The voice should switch when the sentence is clearly in English.'
        $segmentos = Split-IntoLanguageSegments -Text $texto -DocumentLang 'es' -Requested 'Spanish'
        $segmentos.Count | Should -Be 1
        $segmentos[0].Lang | Should -Be 'es'
    }
}

Describe 'Diccionario de términos' {
    BeforeAll {
        $tsv = Join-Path $TestDrive 'terminos.tsv'
        $lineas = @(
            '# comentario'
            'pull`tpul'
            'pull request`t`tpul ricuest'
            'API`ta pe i'
            'Git`tGuit'
            'Guit`tno debe aplicarse dos veces'
            'linea sin tabulador'
        ) -replace '`t', "`t"
        Set-Content -LiteralPath $tsv -Value $lineas -Encoding UTF8
        $terminos = Import-SpeechTerms -Path $tsv
        Set-SpeechTerms $terminos
    }

    AfterAll {
        Set-SpeechTerms $null
    }

    It 'carga los términos sin comentarios ni líneas sin tabulador' {
        $terminos.Count | Should -Be 5
        $terminos['pull request'] | Should -BeExactly 'pul ricuest'
    }

    It 'ordena los términos de más largo a más corto' {
        @($terminos.Keys)[0] | Should -BeExactly 'pull request'
    }

    It 'aplica el término más largo antes que el corto' {
        Expand-EnglishTerms 'Abre un pull request y luego un pull.' | Should -BeExactly 'Abre un pul ricuest y luego un pul.'
    }

    It 'no distingue mayúsculas' {
        Expand-EnglishTerms 'la api y la Api' | Should -BeExactly 'la a pe i y la a pe i'
    }

    It 'solo cambia palabras completas' {
        Expand-EnglishTerms 'las APIs y GitHub' | Should -BeExactly 'las APIs y GitHub'
    }

    It 'no vuelve a cambiar lo que ya cambió' {
        Expand-EnglishTerms 'usa Git' | Should -BeExactly 'usa Guit'
    }

    It 'devuelve un diccionario vacío si el archivo no existe' {
        (Import-SpeechTerms -Path (Join-Path $TestDrive 'no_existe.tsv')).Count | Should -Be 0
    }
}

Describe 'Expand-Units' {
    It 'en español: <Texto> -> <Esperado>' -ForEach @(
        @{ Texto = 'tardó 45 s'; Esperado = 'tardó 45 segundos' }
        @{ Texto = 'tardó 1 s'; Esperado = 'tardó 1 segundo' }
        @{ Texto = 'tardó 2,5 s'; Esperado = 'tardó 2,5 segundos' }
        @{ Texto = 'tardó 300 ms'; Esperado = 'tardó 300 milisegundos' }
        @{ Texto = 'tardó 10 min'; Esperado = 'tardó 10 minutos' }
        @{ Texto = 'tardó 1 h'; Esperado = 'tardó 1 hora' }
        @{ Texto = 'pesa 8 GB'; Esperado = 'pesa 8 gigabytes' }
        @{ Texto = 'pesa 1 MB'; Esperado = 'pesa 1 megabyte' }
        @{ Texto = 'pesa 512 kB'; Esperado = 'pesa 512 kilobytes' }
        @{ Texto = 'pesa 2 TB'; Esperado = 'pesa 2 terabytes' }
        @{ Texto = 'pesa 8GB'; Esperado = 'pesa 8 gigabytes' }
        @{ Texto = 'el MB que falta'; Esperado = 'el megabyte que falta' }
        @{ Texto = 'los GB que quedan'; Esperado = 'los gigabytes que quedan' }
        @{ Texto = 'cuantos GB quedan'; Esperado = 'cuantos gigabytes quedan' }
        @{ Texto = 'una s suelta'; Esperado = 'una s suelta' }
        @{ Texto = 'la h de hora'; Esperado = 'la h de hora' }
    ) {
        Expand-Units -Text $Texto -Lang 'es' | Should -BeExactly $Esperado
    }

    It 'en inglés: <Texto> -> <Esperado>' -ForEach @(
        @{ Texto = 'it took 45 s'; Esperado = 'it took 45 s' }
        @{ Texto = 'it is 1 GB'; Esperado = 'it is 1 gigabyte' }
        @{ Texto = 'many GB left'; Esperado = 'many gigabytes left' }
        @{ Texto = 'the MB count'; Esperado = 'the megabytes count' }
    ) {
        Expand-Units -Text $Texto -Lang 'en' | Should -BeExactly $Esperado
    }

    # lib\ReadAloud.Text.ps1 no tiene BOM y Windows PowerShell 5.1 lo lee como
    # ANSI: una tilde escrita tal cual en una regla no coincidiria nunca.
    It 'pone en plural detrás de "<Palabra>"' -ForEach @(
        @{ Palabra = 'Cuántos'; Texto = '¿Cuántos GB quedan?'; Esperado = '¿Cuántos gigabytes quedan?' }
        @{ Palabra = 'CUÁNTOS'; Texto = '¿CUÁNTOS MB son?'; Esperado = '¿CUÁNTOS megabytes son?' }
    ) {
        Expand-Units -Text $Texto -Lang 'es' | Should -BeExactly $Esperado
    }
}

Describe 'Normalize-ForSpeech' {
    BeforeAll {
        Set-SpeechTerms $null
    }

    It 'cambia comillas, rayas y puntos suspensivos tipográficos' {
        $texto = [char]0x201C + 'hola' + [char]0x201D + ' ' + [char]0x2018 + 'si' + [char]0x2019 + ' a' + [char]0x2014 + 'b' + [char]0x2013 + 'c' + [char]0x2026
        Normalize-ForSpeech -Text $texto -Lang 'es' | Should -BeExactly '"hola" ''si'' a - b - c...'
    }

    It 'ML en modo <Modo> y en <Idioma>: <Esperado>' -ForEach @(
        @{ Modo = 'MachineLearning'; Idioma = 'es'; Esperado = 'un modelo de machine learning' }
        @{ Modo = 'Letters'; Idioma = 'es'; Esperado = 'un modelo de eme ele' }
        @{ Modo = 'Letters'; Idioma = 'en'; Esperado = 'un modelo de M L' }
        @{ Modo = 'Keep'; Idioma = 'es'; Esperado = 'un modelo de ML' }
    ) {
        Normalize-ForSpeech -Text 'un modelo de ML' -Lang $Idioma -MlMode $Modo | Should -BeExactly $Esperado
    }

    It 'no toca ml dentro de otra palabra' {
        Normalize-ForSpeech -Text 'el archivo html' -Lang 'es' | Should -BeExactly 'el archivo html'
    }

    It 'dice las flechas en <Idioma>' -ForEach @(
        @{ Idioma = 'es'; Esperado = 'a  hacia  b y c  produce  d' }
        @{ Idioma = 'en'; Esperado = 'a  to  b y c  produces  d' }
    ) {
        Normalize-ForSpeech -Text 'a -> b y c => d' -Lang $Idioma | Should -BeExactly $Esperado
    }

    It 'dice la barra entre letras y no entre números' {
        Normalize-ForSpeech -Text 'docs/config el 3/11' -Lang 'es' | Should -BeExactly 'docs barra config el 3/11'
        Normalize-ForSpeech -Text 'docs/config' -Lang 'en' | Should -BeExactly 'docs slash config'
    }

    Context 'con diccionario' {
        BeforeAll {
            $terminos = New-Object System.Collections.Specialized.OrderedDictionary
            $terminos['API'] = 'a pe i'
            Set-SpeechTerms $terminos
        }

        AfterAll {
            Set-SpeechTerms $null
        }

        It 'aplica el diccionario solo en español' {
            Normalize-ForSpeech -Text 'la API' -Lang 'es' | Should -BeExactly 'la a pe i'
            Normalize-ForSpeech -Text 'the API' -Lang 'en' | Should -BeExactly 'the API'
        }

        It 'no aplica el diccionario con -SkipTerms' {
            Normalize-ForSpeech -Text 'la API' -Lang 'es' -SkipTerms | Should -BeExactly 'la API'
        }
    }
}

Describe 'Prepare-TextForPiper' {
    It 'le pone punto a una línea corta sin puntuación final' {
        Prepare-TextForPiper 'Instalación' | Should -BeExactly 'Instalación.'
    }

    It 'deja la puntuación que ya tiene' {
        Prepare-TextForPiper 'Ya termina.' | Should -BeExactly 'Ya termina.'
        Prepare-TextForPiper '¿Pregunta?' | Should -BeExactly '¿Pregunta?'
        Prepare-TextForPiper 'Lista:' | Should -BeExactly 'Lista:'
    }

    It 'quita la marca de viñeta' {
        Prepare-TextForPiper '- un elemento' | Should -BeExactly 'un elemento.'
        Prepare-TextForPiper '* otro elemento' | Should -BeExactly 'otro elemento.'
    }

    It 'junta espacios y tabuladores' {
        Prepare-TextForPiper "a`t`t b" | Should -BeExactly 'a b.'
    }

    It 'conserva las líneas vacías' {
        Prepare-TextForPiper "uno`r`n`r`ndos" | Should -BeExactly "uno.`n`ndos."
    }

    It 'no le pone punto a una línea de 140 caracteres o más' {
        $larga = 'a' * 140
        Prepare-TextForPiper $larga | Should -BeExactly $larga
    }
}

Describe 'Split-SentencesIntoUnits' {
    It 'junta las frases cortas con la siguiente' {
        $unidades = Split-SentencesIntoUnits -Sentences @('Sí.', 'Bien.', 'Esta frase ya es bastante larga.') -MinChars 25
        @($unidades) | Should -Be @('Sí. Bien. Esta frase ya es bastante larga.')
    }

    It 'deja sola cada frase larga y guarda la última aunque sea corta' {
        $unidades = Split-SentencesIntoUnits -Sentences @('Una frase con más de veinticinco letras.', 'Corta.') -MinChars 25
        @($unidades) | Should -Be @('Una frase con más de veinticinco letras.', 'Corta.')
    }

    It 'ignora las frases vacías' {
        $unidades = Split-SentencesIntoUnits -Sentences @('', '  ', 'Hola.') -MinChars 25
        @($unidades) | Should -Be @('Hola.')
    }
}

Describe 'Format-DisplayText' {
    It 'cambia los tabuladores por cuatro espacios' {
        Format-DisplayText -Text "a`tb" -Kind 'fila' | Should -BeExactly 'a    b'
    }

    It 'dibuja la viñeta solo en una viñeta' {
        Format-DisplayText -Text '- uno' -Kind 'vineta' | Should -BeExactly ([string][char]0x2022 + '  uno')
        Format-DisplayText -Text '- uno' -Kind 'parrafo' | Should -BeExactly '- uno'
    }
}

Describe 'Reconocer la estructura' {
    It 'Test-TableRow: "<Linea>" es <Esperado>' -ForEach @(
        @{ Linea = "a`tb"; Esperado = $true }
        @{ Linea = '| a | b |'; Esperado = $true }
        @{ Linea = 'a | b'; Esperado = $false }
        @{ Linea = 'texto normal'; Esperado = $false }
    ) {
        Test-TableRow -Line $Linea | Should -Be $Esperado
    }

    It 'Test-TableSeparator: "<Linea>" es <Esperado>' -ForEach @(
        @{ Linea = '|---|:---:|'; Esperado = $true }
        @{ Linea = '+-----+'; Esperado = $true }
        @{ Linea = '==='; Esperado = $true }
        @{ Linea = ''; Esperado = $false }
        @{ Linea = 'abc'; Esperado = $false }
        @{ Linea = '| : |'; Esperado = $true }
    ) {
        Test-TableSeparator -Line $Linea | Should -Be $Esperado
    }

    It 'Test-ListItem: "<Linea>" es <Esperado>' -ForEach @(
        @{ Linea = '- uno'; Esperado = $true }
        @{ Linea = '* uno'; Esperado = $true }
        @{ Linea = '> cita'; Esperado = $true }
        @{ Linea = '1. uno'; Esperado = $true }
        @{ Linea = '2) dos'; Esperado = $true }
        @{ Linea = '-uno'; Esperado = $false }
        @{ Linea = '1.5 GB'; Esperado = $false }
    ) {
        Test-ListItem -Line $Linea | Should -Be $Esperado
    }

    It 'Test-Heading: "<Linea>" abriendo bloque <Abre> es <Esperado>' -ForEach @(
        @{ Linea = '# Título'; Abre = $false; Esperado = $true }
        @{ Linea = 'Resumen'; Abre = $true; Esperado = $true }
        @{ Linea = 'Resumen'; Abre = $false; Esperado = $false }
        @{ Linea = 'Termina con punto.'; Abre = $true; Esperado = $false }
        @{ Linea = '- viñeta'; Abre = $true; Esperado = $false }
        @{ Linea = "a`tb"; Abre = $true; Esperado = $false }
        @{ Linea = ('x' * 71); Abre = $true; Esperado = $false }
    ) {
        Test-Heading -Line $Linea -AbreBloque $Abre | Should -Be $Esperado
    }
}

Describe 'Split-IntoBlocks' {
    BeforeAll {
        $pausas = Get-DefaultPauses
        $texto = @(
            '# Título'
            'Un párrafo que sigue en la otra línea,'
            'y aquí termina.'
            ''
            '- uno'
            '- dos'
            ''
            'Cierre'
            '|---|---|'
            'Último párrafo.'
        ) -join "`r`n"
        $bloques = Split-IntoBlocks -Text $texto -Pauses $pausas
    }

    It 'reconoce el tipo de cada bloque' {
        @($bloques | ForEach-Object { $_.Kind }) | Should -Be @('titulo', 'parrafo', 'vineta', 'vineta', 'titulo', 'parrafo')
    }

    It 'junta las líneas de un mismo párrafo' {
        $bloques[1].Text | Should -BeExactly 'Un párrafo que sigue en la otra línea, y aquí termina.'
    }

    It 'pone la pausa de cada tipo, más aire antes de un título y nada al final' {
        @($bloques | ForEach-Object { $_.PauseAfter }) | Should -Be @(0.30, 0.35, 0.18, 0.55, 0.30, 0.0)
    }

    It 'no lee la línea que separa el encabezado de una tabla' {
        @($bloques | Where-Object { $_.Text -like '*---*' }).Count | Should -Be 0
    }
}

Describe 'Build-SpeechPlan' {
    BeforeAll {
        Set-SpeechTerms $null
    }

    It 'quita las almohadillas del título en lo que se dice y en lo que se muestra' {
        $plan = Build-SpeechPlan -Text "## Instalación`n`nEl texto del párrafo sigue aquí."
        $plan.Chunks[0].Text | Should -BeExactly 'Instalación.'
        $plan.Chunks[0].Display | Should -BeExactly 'Instalación'
    }

    It 'pone la pausa del bloque en su último fragmento' {
        $plan = Build-SpeechPlan -Text "Primera frase del párrafo que es larga. Segunda frase del mismo párrafo.`n`nOtro párrafo."
        @($plan.Chunks | ForEach-Object { $_.PauseAfter }) | Should -Be @(0.0, 0.35, 0.0)
        @($plan.Chunks | ForEach-Object { $_.Block }) | Should -Be @(0, 0, 1)
    }

    It 'lee todo con la voz pedida' {
        $plan = Build-SpeechPlan -Text 'Hoy probamos la lectura. The voice should switch when the sentence is clearly in English.' -Requested 'Spanish'
        @($plan.Chunks | ForEach-Object { $_.Lang } | Select-Object -Unique) | Should -Be @('es')
    }

    It 'no devuelve fragmentos con un texto vacío' {
        (Build-SpeechPlan -Text "`n`n   `n").Chunks.Count | Should -Be 0
    }

    It 'con abreviaturas, el panel muestra el texto entero y cada fragmento en su idioma' {
        $texto = 'El Dr. García llegó a las 3.30 p. m. con el Sr. López, etc. Luego dijo: "no sé"... y se fue. ' +
            'The U.S. team met Mr. Smith at 5 p.m. on Jan. 3, e.g. before lunch... Really?! Yes.'
        $plan = Build-SpeechPlan -Text $texto -MinChunkChars 25
        (@($plan.Chunks | ForEach-Object { $_.Display }) -join ' ') | Should -BeExactly $texto
        @($plan.Chunks | ForEach-Object { $_.Display }) | Should -Be @(
            'El Dr. García llegó a las 3.30 p. m. con el Sr. López, etc.'
            'Luego dijo: "no sé"... y se fue.'
            'The U.S. team met Mr. Smith at 5 p.m. on Jan. 3, e.g. before lunch...'
            'Really?! Yes.'
        )
        @($plan.Chunks | ForEach-Object { $_.Lang }) | Should -Be @('es', 'es', 'en', 'en')
    }
}
