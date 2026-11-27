#
# ReadAloud.Events.Tests.ps1
# El registro de eventos (lib\ReadAloud.Events.ps1) sin el lector: nombre y
# limpieza de los archivos, rasgos de una frase, formato de cada linea,
# medidas del servidor de Qwen y estado de la energia.

BeforeAll {
    Add-Type -AssemblyName System.Windows.Forms
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Events.ps1')
}

Describe 'Get-EventLogPath' {
    It 'un archivo por mes, con el mes en numeros' {
        Get-EventLogPath -RuntimeDir 'C:\rt' -Date ([datetime]'2026-11-27') | Should -Be 'C:\rt\eventos_2026-11.jsonl'
        Get-EventLogPath -RuntimeDir 'C:\rt' -Date ([datetime]'2027-01-03') | Should -Be 'C:\rt\eventos_2027-01.jsonl'
    }
}

Describe 'Remove-OldEventLog' {
    BeforeEach {
        $carpeta = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $carpeta | Out-Null
        foreach ($nombre in @('eventos_2025-10.jsonl', 'eventos_2025-11.jsonl', 'eventos_2025-12.jsonl',
                              'eventos_2026-11.jsonl', 'eventos_2026-13.jsonl', 'eventos_viejo.jsonl', 'daemon.log')) {
            Set-Content -LiteralPath (Join-Path $carpeta $nombre) -Value '{}'
        }
    }

    It 'con 12 meses borra lo anterior a hace 11 meses y deja lo demas' {
        Remove-OldEventLog -RuntimeDir $carpeta -KeepMonths 12 -Now ([datetime]'2026-11-27') | Should -Be 2
        $quedan = @(Get-ChildItem -LiteralPath $carpeta | ForEach-Object Name | Sort-Object)
        $quedan | Should -Be @('daemon.log', 'eventos_2025-12.jsonl', 'eventos_2026-11.jsonl', 'eventos_2026-13.jsonl', 'eventos_viejo.jsonl')
    }

    It 'con 0 meses no borra nada' {
        Remove-OldEventLog -RuntimeDir $carpeta -KeepMonths 0 -Now ([datetime]'2026-11-27') | Should -Be 0
        @(Get-ChildItem -LiteralPath $carpeta).Count | Should -Be 7
    }

    It 'una carpeta que no existe no es un error' {
        Remove-OldEventLog -RuntimeDir (Join-Path $TestDrive 'no_existe') | Should -Be 0
    }
}

Describe 'ConvertTo-EventNumber' {
    It 'redondea' {
        ConvertTo-EventNumber 1.23456 | Should -Be 1.235
        ConvertTo-EventNumber 1.23456 -Digits 1 | Should -Be 1.2
    }

    It 'NaN, infinito y $null quedan en $null' {
        ConvertTo-EventNumber ([double]::NaN) | Should -BeNullOrEmpty
        ConvertTo-EventNumber ([double]::PositiveInfinity) | Should -BeNullOrEmpty
        ConvertTo-EventNumber $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-TextTraits' {
    It 'cuenta caracteres, palabras, cifras, siglas y comas' {
        $r = Get-TextTraits 'Hola, mundo: son las 3:30 en EE. UU. con la ONU.'
        $r.caracteres | Should -Be 48
        $r.palabras | Should -Be 11
        $r.cifras | Should -Be 3
        $r.siglas | Should -Be 3
        $r.comas | Should -Be 3
    }

    It 'una sigla con tilde tambien cuenta' {
        # "AEREO" con la A y la E con tilde: el archivo de pruebas es ASCII.
        $texto = 'Vuelo ' + [char]0xC1 + 'R' + [char]0xC9 + 'O hoy'
        (Get-TextTraits $texto).siglas | Should -Be 1
    }

    It 'un texto vacio o $null da ceros' {
        foreach ($t in @('', $null)) {
            $r = Get-TextTraits $t
            $r.caracteres | Should -Be 0
            $r.palabras | Should -Be 0
            $r.siglas | Should -Be 0
        }
    }
}

Describe 'ConvertTo-EventLine' {
    It 'empieza por la hora y el tipo, y sigue con los datos en su orden' {
        $linea = ConvertTo-EventLine -Type 'espera' -Now ([datetime]'2026-11-27T10:15:30.250') -Data ([ordered]@{ lectura = 4; s = 1.5 })
        $linea | Should -Match '^\{"t":"2026-11-27T10:15:30\.250[+-]\d{2}:\d{2}","tipo":"espera","lectura":4,"s":1\.5\}$'
    }

    It 'un texto con saltos de linea y tildes queda en una sola linea y vuelve igual' {
        $texto = "Primera l" + [char]0xED + "nea`nsegunda`tcon tabulador y " + [char]0xF1
        $linea = ConvertTo-EventLine -Type 'fragmento' -Data ([ordered]@{ texto = $texto })
        $linea | Should -Not -Match "`n"
        ($linea | ConvertFrom-Json).texto | Should -BeExactly $texto
    }

    It 'los decimales usan punto aunque la cultura use coma' {
        $antes = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
            ConvertTo-EventLine -Type 'x' -Data ([ordered]@{ s = 2.25 }) | Should -Match '"s":2\.25'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $antes
        }
    }

    It 'acepta datos anidados y $null' {
        $linea = ConvertTo-EventLine -Type 'grupo' -Data ([ordered]@{ servidor = [ordered]@{ factor = 0.8 }; error = $null; fragmentos = @(3, 4) })
        $objeto = $linea | ConvertFrom-Json
        $objeto.servidor.factor | Should -Be 0.8
        $objeto.error | Should -BeNullOrEmpty
        @($objeto.fragmentos) | Should -Be @(3, 4)
    }
}

Describe 'Write-EventLine' {
    It 'agrega una linea por evento, en UTF-8 sin BOM' {
        $ruta = Join-Path $TestDrive 'eventos_prueba.jsonl'
        Write-EventLine -Path $ruta -Line '{"a":1}' | Should -BeTrue
        Write-EventLine -Path $ruta -Line ('{"b":"' + [char]0xF1 + '"}') | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($ruta)
        $bytes[0] | Should -Be ([byte][char]'{')
        $lineas = [IO.File]::ReadAllLines($ruta, (New-Object Text.UTF8Encoding($false)))
        $lineas.Count | Should -Be 2
        ($lineas[1] | ConvertFrom-Json).b | Should -BeExactly ([string][char]0xF1)
    }

    It 'si no puede escribir devuelve $false sin lanzar' {
        Write-EventLine -Path (Join-Path $TestDrive 'no_existe\eventos.jsonl') -Line '{}' | Should -BeFalse
    }
}

Describe 'ConvertFrom-SynthOutput' {
    It 'la salida de Piper es solo la ruta' {
        $r = ConvertFrom-SynthOutput 'C:\tmp\ra_1_0000.wav'
        $r.Path | Should -Be 'C:\tmp\ra_1_0000.wav'
        $r.Metrics | Should -BeNullOrEmpty
    }

    It 'separa las medidas que agrega el servidor de Qwen' {
        $r = ConvertFrom-SynthOutput ("C:\tmp\ra_1_0000.wav`t" + '{"s":4.2,"audio_s":6.1,"factor":0.69}')
        $r.Path | Should -Be 'C:\tmp\ra_1_0000.wav'
        $r.Metrics.factor | Should -Be 0.69
    }

    It 'unas medidas rotas no impiden leer la ruta' {
        $r = ConvertFrom-SynthOutput "C:\tmp\ra_1_0000.wav`t{no es json"
        $r.Path | Should -Be 'C:\tmp\ra_1_0000.wav'
        $r.Metrics | Should -BeNullOrEmpty
    }

    It 'una linea vacia o $null' {
        (ConvertFrom-SynthOutput '').Metrics | Should -BeNullOrEmpty
        (ConvertFrom-SynthOutput $null).Metrics | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-PowerState' {
    It 'enchufado, con bateria y en maximo rendimiento' {
        $r = ConvertTo-PowerState -LineStatus 'Online' -ChargeStatus 'High' -LifePercent 0.79 `
            -OverlayAc 'DED574B5-45A0-4F42-8737-46345C09C238' -OverlayDc '961cc777-2547-4f9d-8174-7d86181b8a7a'
        $r.corriente | Should -Be 'ac'
        $r.bateria_pct | Should -Be 79
        $r.energia | Should -Be 'rendimiento'
    }

    It 'con bateria usa el modo de la bateria' {
        $r = ConvertTo-PowerState -LineStatus 'Offline' -ChargeStatus 'Low' -LifePercent 0.2 `
            -OverlayAc 'ded574b5-45a0-4f42-8737-46345c09c238' -OverlayDc '961cc777-2547-4f9d-8174-7d86181b8a7a'
        $r.corriente | Should -Be 'bateria'
        $r.energia | Should -Be 'eficiencia'
    }

    It 'un equipo sin bateria no da porcentaje' {
        (ConvertTo-PowerState -LineStatus 'Online' -ChargeStatus 'NoSystemBattery' -LifePercent 1).bateria_pct | Should -BeNullOrEmpty
    }

    It 'un modo que no conoce queda con su identificador; sin datos, ?' {
        (ConvertTo-PowerState -LineStatus 'Online' -OverlayAc 'AAAAAAAA-0000-0000-0000-000000000000').energia | Should -Be 'aaaaaaaa-0000-0000-0000-000000000000'
        $r = ConvertTo-PowerState -LineStatus ''
        $r.corriente | Should -Be '?'
        $r.energia | Should -BeNullOrEmpty
    }
}

Describe 'Get-PowerState' {
    It 'lee el equipo sin fallar y trae los tres campos' {
        $r = Get-PowerState
        @($r.Keys) | Should -Be @('corriente', 'bateria_pct', 'energia')
        $r.corriente | Should -BeIn @('ac', 'bateria', '?')
    }
}

Describe 'Get-Median' {
    It 'impar, par, vacio y con $null' {
        Get-Median @(5, 1, 3) | Should -Be 3
        Get-Median @(4, 1, 3, 2) | Should -Be 2.5
        Get-Median @() | Should -BeNullOrEmpty
        Get-Median @($null, 2, $null) | Should -Be 2
    }
}
