#
# ReadAloud.Theme.Tests.ps1
# Temas de color (lib\ReadAloud.Theme.ps1): resolver el modo, la paleta y la
# sustitucion de colores en el XAML.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Theme.ps1')
}

Describe 'Resolve-ThemeMode' {
    It '"<Modo>" con Windows claro=<Claro> da <Esperado>' -ForEach @(
        @{ Modo = 'light'; Claro = $false; Esperado = 'light' }
        @{ Modo = 'dark'; Claro = $true; Esperado = 'dark' }
        @{ Modo = 'system'; Claro = $true; Esperado = 'light' }
        @{ Modo = 'system'; Claro = $false; Esperado = 'dark' }
        @{ Modo = 'System '; Claro = $true; Esperado = 'light' }
        @{ Modo = 'cualquiera'; Claro = $true; Esperado = 'dark' }
    ) {
        Resolve-ThemeMode -Mode $Modo -SystemLight $Claro | Should -BeExactly $Esperado
    }
}

Describe 'Convert-XamlTheme' {
    It 'oscuro con acento verde deja el XAML tal cual' {
        $xaml = '<Border Background="#F21B1B1F" BorderBrush="#33FFFFFF"><TextBlock Foreground="#9AE6B4"/><Button Foreground="White"/></Border>'
        Convert-XamlTheme -Xaml $xaml -Palette (Get-ThemePalette -Mode 'dark' -Accent 'green') | Should -BeExactly $xaml
    }

    It 'claro cambia fondos, textos y velos translucidos' {
        $p = Get-ThemePalette -Mode 'light' -Accent 'green'
        $r = Convert-XamlTheme -Xaml '<A Background="#F21B1B1F" B="#33FFFFFF" C="#E6E6EA" Foreground="White"/>' -Palette $p
        $r | Should -BeExactly '<A Background="#F2F6F6F8" B="#33000000" C="#1F1F24" Foreground="#1F1F24"/>'
    }

    It 'el acento cambia el texto de acento y el relleno de la pastilla elegida' {
        $p = Get-ThemePalette -Mode 'dark' -Accent 'purple'
        $r = Convert-XamlTheme -Xaml '<A F="#9AE6B4" G="#334ADE80" H="#8C4ADE80" I="#C6F6D5"/>' -Palette $p
        $r | Should -BeExactly '<A F="#D8B4FE" G="#33A855F7" H="#8CA855F7" I="#F3E8FF"/>'
    }

    It 'es una sola pasada: lo sustituido no se vuelve a sustituir' {
        $p = Get-ThemePalette -Mode 'light' -Accent 'green'
        # El texto claro #1F1F24 no esta en el mapa; #D8D8DC -> #2A2A30 tampoco cambia otra vez.
        (Convert-XamlTheme -Xaml 'X="#D8D8DC"' -Palette $p) | Should -BeExactly 'X="#2A2A30"'
    }

    It 'no toca colores que no son del tema (sombras, azul del resaltado)' {
        $p = Get-ThemePalette -Mode 'light' -Accent 'red'
        $xaml = 'S="#000000" T="#66000000" U="#663B82F6"'
        Convert-XamlTheme -Xaml $xaml -Palette $p | Should -BeExactly $xaml
    }
}

Describe 'Acentos y colores en codigo' {
    It 'un acento desconocido cae en verde' {
        (Get-ThemePalette -Mode 'dark' -Accent 'nada').AccentText | Should -BeExactly '#9AE6B4'
    }

    It 'los ocho acentos tienen todos sus colores' {
        (Get-ThemeAccents).Count | Should -Be 8
        foreach ($k in (Get-ThemeAccents).Keys) {
            foreach ($campo in 'Text', 'TextLight', 'Base', 'BaseLight', 'Soft', 'SoftLight') {
                (Get-ThemeAccents)[$k][$campo] | Should -Match '^#[0-9A-F]{6}$'
            }
        }
    }

    It 'los colores de ejecucion siguen al tema' {
        (Get-RuntimeColors (Get-ThemePalette -Mode 'dark')).Actual | Should -BeExactly '#FFFFFF'
        (Get-RuntimeColors (Get-ThemePalette -Mode 'light')).Actual | Should -BeExactly '#000000'
        (Get-RuntimeColors (Get-ThemePalette -Mode 'light')).Elegido | Should -BeExactly '#2E000000'
    }
}
