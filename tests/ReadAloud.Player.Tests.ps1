#
# ReadAloud.Player.Tests.ps1
# La logica del reproductor (lib\ReadAloud.Player.ps1) sin ventana ni audio:
# duraciones, saltos, orden de generacion y pasos de velocidad y volumen.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Player.ps1')

    function New-TestChunk {
        param([string]$Text = 'texto', [double]$Duration = 2.0, [double]$Pause = 0.0, [bool]$Ready = $false)
        [pscustomobject]@{ Text = $Text; Duration = $Duration; PauseAfter = $Pause; Offset = 0.0; Ready = $Ready }
    }

    function New-TestChunkList {
        param($Chunks)
        $lista = New-Object System.Collections.Generic.List[object]
        foreach ($c in $Chunks) { [void]$lista.Add($c) }
        return , $lista
    }
}

Describe 'Format-Time, Format-Speed y Format-VolumePercent' {
    It 'Format-Time: <Segundos> s es "<Esperado>"' -ForEach @(
        @{ Segundos = 0; Esperado = '0:00' }
        @{ Segundos = 5.9; Esperado = '0:05' }
        @{ Segundos = 65; Esperado = '1:05' }
        @{ Segundos = 30; Esperado = '0:30' }
        @{ Segundos = 45; Esperado = '0:45' }
        @{ Segundos = 90; Esperado = '1:30' }
        @{ Segundos = 163.2; Esperado = '2:43' }
        @{ Segundos = 3599; Esperado = '59:59' }
        @{ Segundos = 3600; Esperado = '60:00' }
        @{ Segundos = -4; Esperado = '0:00' }
    ) {
        Format-Time $Segundos | Should -BeExactly $Esperado
    }

    It 'Format-Speed: <Valor> es "<Esperado>"' -ForEach @(
        @{ Valor = 1; Esperado = '1x' }
        @{ Valor = 1.25; Esperado = '1.25x' }
        @{ Valor = 0.5; Esperado = '0.5x' }
        @{ Valor = 2; Esperado = '2x' }
    ) {
        Format-Speed $Valor | Should -BeExactly $Esperado
    }

    It 'Format-VolumePercent: <Valor> es "<Esperado>"' -ForEach @(
        @{ Valor = 1; Esperado = '100 %' }
        @{ Valor = 0.5; Esperado = '50 %' }
        @{ Valor = 0; Esperado = '0 %' }
        @{ Valor = 0.85; Esperado = '85 %' }
    ) {
        Format-VolumePercent $Valor | Should -BeExactly $Esperado
    }
}

Describe 'Get-EstimatedDuration' {
    It 'a 14 caracteres por segundo por defecto' {
        Get-EstimatedDuration -Text ('a' * 140) | Should -Be 10
    }

    It 'con otro ritmo' {
        Get-EstimatedDuration -Text ('a' * 140) -CharsPerSecond 20 | Should -Be 7
    }

    It 'nunca menos de 0.6 s' {
        Get-EstimatedDuration -Text 'Si.' | Should -Be 0.6
    }

    It 'un ritmo no valido usa el de por defecto' {
        Get-EstimatedDuration -Text ('a' * 140) -CharsPerSecond 0 | Should -Be 10
    }
}

Describe 'Get-SpeechRate' {
    It 'sin audio medido, el ritmo por defecto' {
        $c = New-TestChunkList @((New-TestChunk -Text ('a' * 60)), (New-TestChunk -Text ('a' * 60)))
        Get-SpeechRate -Chunks $c | Should -Be 14
    }

    It 'con muy poco audio medido tampoco se fia' {
        $c = New-TestChunkList @((New-TestChunk -Text ('a' * 30) -Duration 1.5 -Ready $true))
        Get-SpeechRate -Chunks $c | Should -Be 14
    }

    It 'mide los caracteres por segundo de lo ya generado, sin contar las pausas' {
        $c = New-TestChunkList @(
            (New-TestChunk -Text ('a' * 60) -Duration 3.5 -Pause 0.5 -Ready $true)
            (New-TestChunk -Text ('a' * 60) -Duration 3.0 -Ready $true)
            (New-TestChunk -Text ('a' * 60) -Duration 3.0 -Ready $true)
            (New-TestChunk -Text ('a' * 900) -Duration 64 -Ready $false)
        )
        Get-SpeechRate -Chunks $c | Should -Be 20
    }

    It 'queda entre 8 y 30' {
        $rapido = New-TestChunkList @((New-TestChunk -Text ('a' * 300) -Duration 1.0 -Ready $true))
        Get-SpeechRate -Chunks $rapido | Should -Be 30
        $lento = New-TestChunkList @((New-TestChunk -Text ('a' * 300) -Duration 300 -Ready $true))
        Get-SpeechRate -Chunks $lento | Should -Be 8
    }
}

Describe 'Update-ChunkEstimates y Update-ChunkOffsets' {
    BeforeEach {
        $lista = New-TestChunkList @(
            (New-TestChunk -Text ('a' * 60) -Duration 3.0 -Ready $true)
            (New-TestChunk -Text ('a' * 60) -Duration 3.0 -Ready $true)
            (New-TestChunk -Text ('a' * 60) -Duration 3.0 -Ready $true)
            (New-TestChunk -Text ('a' * 100) -Duration 999 -Pause 0.35 -Ready $false)
        )
    }

    It 'lo que falta se estima con el ritmo medido y conserva su pausa' {
        $ritmo = Update-ChunkEstimates -Chunks $lista
        $ritmo | Should -Be 20
        $lista[3].Duration | Should -Be 5.35
    }

    It 'lo que ya tiene audio no se toca' {
        [void](Update-ChunkEstimates -Chunks $lista)
        $lista[0].Duration | Should -Be 3
    }

    It 'los comienzos se acumulan y se devuelve el total' {
        $total = Update-ChunkOffsets -Chunks $lista
        @($lista | ForEach-Object { $_.Offset }) | Should -Be @(0, 3, 6, 9)
        $total | Should -Be 1008
    }
}

Describe 'Find-ChunkAt' {
    BeforeEach {
        $lista = New-TestChunkList @((New-TestChunk -Duration 2), (New-TestChunk -Duration 3), (New-TestChunk -Duration 4))
        [void](Update-ChunkOffsets -Chunks $lista)
    }

    It '<Segundo> s esta en el fragmento <Indice>' -ForEach @(
        @{ Segundo = 0; Indice = 0 }
        @{ Segundo = 1.9; Indice = 0 }
        @{ Segundo = 2; Indice = 1 }
        @{ Segundo = 4.99; Indice = 1 }
        @{ Segundo = 5; Indice = 2 }
        @{ Segundo = 100; Indice = 2 }
        @{ Segundo = -5; Indice = 0 }
    ) {
        Find-ChunkAt -Chunks $lista -Seconds $Segundo | Should -Be $Indice
    }

    It 'sin fragmentos devuelve -1' {
        Find-ChunkAt -Chunks (New-TestChunkList @()) -Seconds 3 | Should -Be -1
    }
}

Describe 'Get-SeekTarget' {
    BeforeEach {
        $lista = New-TestChunkList @(
            (New-TestChunk -Duration 2 -Ready $true)
            (New-TestChunk -Duration 3 -Ready $true)
            (New-TestChunk -Duration 4 -Ready $false)
        )
        [void](Update-ChunkOffsets -Chunks $lista)
    }

    It 'dentro de un fragmento con audio da el punto exacto' {
        $t = Get-SeekTarget -Chunks $lista -Seconds 3.5
        $t.Index | Should -Be 1
        $t.Offset | Should -Be 1.5
        $t.Ready | Should -BeTrue
    }

    It 'se puede saltar a un fragmento que aun no tiene audio: Ready es falso y empieza en 0' {
        $t = Get-SeekTarget -Chunks $lista -Seconds 7
        $t.Index | Should -Be 2
        $t.Offset | Should -Be 0
        $t.Ready | Should -BeFalse
    }

    It 'pasado el final queda en el ultimo fragmento, sin salirse' {
        $t = Get-SeekTarget -Chunks $lista -Seconds 500
        $t.Index | Should -Be 2
        $t.Seconds | Should -Be 8.85
    }

    It 'antes del comienzo es el comienzo' {
        $t = Get-SeekTarget -Chunks $lista -Seconds -10
        $t.Index | Should -Be 0
        $t.Offset | Should -Be 0
    }

    It 'en un fragmento con audio nunca pasa de su duracion menos el margen' {
        $t = Get-SeekTarget -Chunks $lista -Seconds 4.99
        $t.Index | Should -Be 1
        $t.Offset | Should -BeLessOrEqual 2.85
    }

    It 'sin fragmentos no hay destino' {
        Get-SeekTarget -Chunks (New-TestChunkList @()) -Seconds 3 | Should -BeNullOrEmpty
    }
}

Describe 'Get-SentenceTarget' {
    BeforeEach {
        $lista = New-TestChunkList @((New-TestChunk -Duration 4), (New-TestChunk -Duration 4), (New-TestChunk -Duration 4))
        [void](Update-ChunkOffsets -Chunks $lista)
    }

    It 'la anterior, con poco recorrido de la actual, va a la frase de atras' {
        Get-SentenceTarget -Chunks $lista -PlayIndex 1 -Position 5 -Direction -1 | Should -Be 0
    }

    It 'la anterior, con mas de 2 s de la actual, vuelve primero al comienzo de la actual' {
        Get-SentenceTarget -Chunks $lista -PlayIndex 1 -Position 7 -Direction -1 | Should -Be 1
    }

    It 'la anterior en la primera frase se queda en la primera' {
        Get-SentenceTarget -Chunks $lista -PlayIndex 0 -Position 0.5 -Direction -1 | Should -Be 0
    }

    It 'la siguiente' {
        Get-SentenceTarget -Chunks $lista -PlayIndex 0 -Position 1 -Direction 1 | Should -Be 1
    }

    It 'la siguiente en la ultima frase no tiene a donde ir' {
        Get-SentenceTarget -Chunks $lista -PlayIndex 2 -Position 9 -Direction 1 | Should -Be -1
    }

    It 'sin una frase sonando no hay destino' {
        Get-SentenceTarget -Chunks $lista -PlayIndex -1 -Position 0 -Direction 1 | Should -Be -1
    }
}

Describe 'Get-JobOrder' {
    It 'sin prioridad, de primero a ultimo' {
        @(Get-JobOrder -Pending @(5, 2, 9, 1)) | Should -Be @(1, 2, 5, 9)
    }

    It 'con prioridad, ese primero, luego hacia delante y al final lo que quedo atras' {
        @(Get-JobOrder -Pending @(1, 2, 5, 6, 7) -Priority 5) | Should -Be @(5, 6, 7, 1, 2)
    }

    It 'una prioridad que ya no esta pendiente sigue en el siguiente que falte' {
        @(Get-JobOrder -Pending @(1, 2, 7, 8) -Priority 5) | Should -Be @(7, 8, 1, 2)
    }

    It 'una prioridad pasada del final deja el orden normal' {
        @(Get-JobOrder -Pending @(3, 4) -Priority 10) | Should -Be @(3, 4)
    }

    It 'sin pendientes, nada' {
        @(Get-JobOrder -Pending @() -Priority 3).Count | Should -Be 0
    }
}

Describe 'Test-BatchFits' {
    It 'cabe mientras no se pase de fragmentos ni de caracteres' {
        Test-BatchFits -Count 1 -Chars 100 -NextChars 100 -MaxCount 4 -Budget 450 | Should -BeTrue
    }

    It 'no cabe si ya hay el maximo de fragmentos' {
        Test-BatchFits -Count 4 -Chars 40 -NextChars 10 -MaxCount 4 -Budget 450 | Should -BeFalse
    }

    It 'no cabe si se pasa del tope de caracteres' {
        Test-BatchFits -Count 2 -Chars 300 -NextChars 160 -MaxCount 4 -Budget 450 | Should -BeFalse
    }

    It 'con tope 0 solo cuenta el numero de fragmentos' {
        Test-BatchFits -Count 2 -Chars 9000 -NextChars 9000 -MaxCount 4 -Budget 0 | Should -BeTrue
    }
}

Describe 'Get-NextStep' {
    BeforeAll {
        $velocidades = @(0.5, 0.75, 1.0, 1.25, 1.5, 2.0)
    }

    It 'sube un paso' {
        Get-NextStep -Steps $velocidades -Current 1.0 -Direction 1 | Should -Be 1.25
    }

    It 'baja un paso' {
        Get-NextStep -Steps $velocidades -Current 1.0 -Direction -1 | Should -Be 0.75
    }

    It 'no pasa del ultimo ni del primero' {
        Get-NextStep -Steps $velocidades -Current 2.0 -Direction 1 | Should -Be 2
        Get-NextStep -Steps $velocidades -Current 0.5 -Direction -1 | Should -Be 0.5
    }

    It 'un valor que no es un paso parte del paso mas cercano' {
        Get-NextStep -Steps $velocidades -Current 1.1 -Direction 1 | Should -Be 1.25
        Get-NextStep -Steps $velocidades -Current 1.1 -Direction -1 | Should -Be 0.75
    }

    It 'sirve igual para el volumen' {
        $volumen = @(0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0)
        Get-NextStep -Steps $volumen -Current 0.5 -Direction 1 | Should -Be 0.6
        Get-NextStep -Steps $volumen -Current 1.0 -Direction 1 | Should -Be 1
    }
}
