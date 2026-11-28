#
# ResumenEventos.Tests.ps1
# tools\resumen_eventos.ps1 sobre un registro de ejemplo
# (fixtures\eventos\eventos_2026-11.jsonl): dos sesiones del lector cuyas
# lecturas se numeran igual, una lectura reemplazada con su grupo descartado,
# una voz propia que aun cargaba y una linea rota.

BeforeAll {
    $script:resumen = Join-Path $PSScriptRoot '..\tools\resumen_eventos.ps1'
    $script:datos = & $script:resumen -Carpeta (Join-Path $PSScriptRoot 'fixtures\eventos') -Objetos
}

Describe 'resumen_eventos.ps1' {
    It 'una fila de lecturas por dia, con las esperas de ese dia' {
        $d20 = $datos.Lecturas | Where-Object Dia -eq '2026-11-20'
        $d20.Lecturas | Should -Be 3
        $d20.Terminadas | Should -Be 2
        $d20.Minutos | Should -Be 1.4
        $d20.Arranque | Should -Be 5.6
        $d20.ArranqueMax | Should -Be 8
        $d20.Frase | Should -Be 1
        $d20.CadaDiez | Should -Be 3.3
        $d20.Mas3s | Should -Be 1
        $d20.FraseMax | Should -Be 4.5

        $d21 = $datos.Lecturas | Where-Object Dia -eq '2026-11-21'
        $d21.Lecturas | Should -Be 1
        $d21.Terminadas | Should -Be 0
        $d21.Frase | Should -Be 1
        $d21.Mas3s | Should -Be 0
    }

    It 'la voz propia por dia, con lo que se leyo con Piper y por que' {
        $v20 = $datos.Voz | Where-Object Dia -eq '2026-11-20'
        $v20.Grupos | Should -Be 4
        $v20.Frases | Should -Be 2.25
        $v20.Factor | Should -Be 0.8
        $v20.FactorMax | Should -Be 1.2
        $v20.Lentos | Should -Be 1
        $v20.Descartados | Should -Be 1
        $v20.Bateria | Should -Be 1
        $v20.Energia | Should -Be 'rendimiento'

        ($datos.Voz | Where-Object Dia -eq '2026-11-21').APiper | Should -Be 'qwen_cargando:1'
    }

    It 'cada espera se une al grupo de su propia sesion' {
        $esperas = @($datos.Esperas)
        $esperas.Count | Should -Be 5
        $frase20 = $esperas | Where-Object { $_.Cuando -like '11-20*' -and $_.Clase -eq 'frase' }
        $frase20.Factor | Should -Be 1.2
        $frase20.Corriente | Should -Be 'bateria'
        $frase20.Caracteres | Should -Be 150
        $frase21 = $esperas | Where-Object { $_.Cuando -like '11-21*' -and $_.Clase -eq 'frase' }
        $frase21.Factor | Should -Be 0.4
        $frase21.MandadoS | Should -Be 6.2
        ($esperas | Where-Object { $_.Cuando -like '11-20 10:00:03' }).Texto | Should -Be 'Primera frase.'
    }

    It 'aplica la regla del PR #8 y explica los arranques largos' {
        $regla = @($datos.Regla)
        $regla[0] | Should -Match '^4 lecturas; 2 esperas entre frases \(5\.0 cada 10 lecturas\), la mas larga de 4\.5 s; factor medio de la voz propia: 0\.72\.$'
        $regla | Should -Contain 'Hay menos de 10 lecturas: es poco para decidir.'
        ($regla -join "`n") | Should -Match 'Grupos mas chicos'
        ($regla -join "`n") | Should -Match 'leer con Piper ese fragmento'
        ($regla -join "`n") | Should -Match 'Arranque: mediana de 7\.0 s\. De los 2 de mas de 6 s, 1 esperaron a que terminara un grupo de una lectura ya reemplazada y 1 a que cargara la voz propia\.'
    }

    It 'sin eventos en el periodo lo dice' {
        & $script:resumen -Carpeta (Join-Path $TestDrive 'vacia') | Should -Match '^No hay eventos'
    }
}
