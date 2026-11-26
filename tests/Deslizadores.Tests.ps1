#
# Deslizadores.Tests.ps1
# Los deslizadores del reproductor y del panel de ajustes, leídos del XAML de
# read_aloud_daemon.ps1 y lib\ReadAloud.Settings.ps1. Sin IsMoveToPointEnabled,
# un clic en la pista movía el valor un paso grande (LargeChange, 1 por
# defecto) en vez de llevarlo al punto: en una pausa de 0 a 1 s, cada clic lo
# mandaba a un extremo.

BeforeDiscovery {
    $raiz = Split-Path -Parent $PSScriptRoot
    $deslizadores = foreach ($archivo in @('read_aloud_daemon.ps1', 'lib\ReadAloud.Settings.ps1')) {
        $texto = Get-Content -LiteralPath (Join-Path $raiz $archivo) -Raw -Encoding UTF8
        foreach ($m in [regex]::Matches($texto, '<Slider\s[^>]*>')) {
            $atributos = @{}
            foreach ($a in [regex]::Matches($m.Value, '([\w:.]+)="([^"]*)"')) { $atributos[$a.Groups[1].Value] = $a.Groups[2].Value }
            @{ Archivo = $archivo; Nombre = $atributos['x:Name']; Atributos = $atributos }
        }
    }
    $delPanel = @($deslizadores | Where-Object { $_.Archivo -like 'lib*' })
}

Describe 'El deslizador <Nombre> (<Archivo>)' -ForEach $deslizadores {
    It 'lleva el valor al punto donde se hace clic' {
        $Atributos['IsMoveToPointEnabled'] | Should -Be 'True'
    }

    It 'no salta más de un cuarto del recorrido con RePág o AvPág' {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $minimo = $(if ($Atributos.ContainsKey('Minimum')) { [double]::Parse($Atributos['Minimum'], $inv) } else { 0.0 })
        $maximo = [double]::Parse($Atributos['Maximum'], $inv)
        # 1 es el valor por defecto de WPF.
        $paso = $(if ($Atributos.ContainsKey('LargeChange')) { [double]::Parse($Atributos['LargeChange'], $inv) } else { 1.0 })
        $paso | Should -BeLessOrEqual (($maximo - $minimo) / 4)
    }
}

Describe 'Arrastrar desde la pista en el panel de ajustes' {
    BeforeAll {
        $texto = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\ReadAloud.Settings.ps1') -Raw -Encoding UTF8
        $bucle = [regex]::Match($texto, 'foreach \(\$deslizador in @\(([^)]*)\)\) \{\s*Enable-SliderTrackDrag \$deslizador').Groups[1].Value
    }

    It 'pasa por Enable-SliderTrackDrag el deslizador <Nombre>' -ForEach $delPanel {
        $bucle | Should -Match ('\$aj\.' + $Nombre + '\b')
    }
}
