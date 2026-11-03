#
# SpeechPlan.Tests.ps1
# El plan de lectura completo de cada texto de fixtures\textos, contra el que
# esta guardado en fixtures\planes. Si un cambio debe cambiar la lectura, se
# regeneran con tests\actualizar_planes.ps1 y se revisa el git diff.
#
# Al final, una prueba de humo de read_aloud.ps1 -ShowPlan en un proceso
# aparte, como lo corre el usuario.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Plan.ps1')
    $casos = @(Get-PlanCases)
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Text.ps1')
    . (Join-Path $PSScriptRoot 'Plan.ps1')
    Set-SpeechTerms (Import-SpeechTerms -Path (Join-Path $PSScriptRoot '..\config\terms_es.tsv'))
}

AfterAll {
    Set-SpeechTerms $null
}

Describe 'Plan de lectura de <Nombre>' -ForEach $casos {
    It 'coincide con fixtures\planes\<Nombre>.txt' {
        Test-Path -LiteralPath $Plan | Should -BeTrue -Because 'cada texto necesita su plan; se crea con tests\actualizar_planes.ps1'
        $esperado = (Get-Content -LiteralPath $Plan -Raw -Encoding UTF8) -replace "`r`n", "`n"
        $actual = Get-TestPlan -Path $Texto
        # Linea por linea: si falla, Pester dice cual es la primera distinta.
        ($actual -split "`n") | Should -Be ($esperado -split "`n")
    }
}

Describe 'read_aloud.ps1 -ShowPlan' {
    It 'muestra el plan de un texto sin leerlo' {
        $script = Join-Path $PSScriptRoot '..\read_aloud.ps1'
        $exe = (Get-Process -Id $PID).Path
        $salida = & $exe -NoProfile -ExecutionPolicy Bypass -File $script -ShowPlan -InputText 'Esta frase está escrita en español. This sentence is written in English for the test.' 2>&1
        $LASTEXITCODE | Should -Be 0
        ($salida -join "`n") | Should -Match 'Idioma del texto: '
        ($salida -join "`n") | Should -Match '\] EN  This sentence is written in English for the test\.'
    }
}
