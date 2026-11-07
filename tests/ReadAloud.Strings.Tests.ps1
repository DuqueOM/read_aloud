#
# ReadAloud.Strings.Tests.ps1
# Interfaz en ingles y espanol (lib\ReadAloud.Strings.ps1): resolver el idioma,
# traducir un XAML, los nombres para lectores de pantalla y que todo texto de
# las ventanas tenga su traduccion.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Strings.ps1')
    $script:raiz = Split-Path -Parent $PSScriptRoot
}

Describe 'Resolve-UiLanguage' {
    It '"<Ajuste>" con Windows en "<Cultura>" da <Esperado>' -ForEach @(
        @{ Ajuste = 'es'; Cultura = 'en'; Esperado = 'es' }
        @{ Ajuste = 'en'; Cultura = 'es'; Esperado = 'en' }
        @{ Ajuste = 'auto'; Cultura = 'es'; Esperado = 'es' }
        @{ Ajuste = 'auto'; Cultura = 'fr'; Esperado = 'en' }
        @{ Ajuste = 'Auto'; Cultura = 'en'; Esperado = 'en' }
    ) {
        Resolve-UiLanguage -Setting $Ajuste -UiCulture $Cultura | Should -BeExactly $Esperado
    }
}

Describe 'T y Convert-XamlLanguage' {
    AfterEach { Set-UiLanguage 'es' }

    It 'en espanol devuelve el original' {
        Set-UiLanguage 'es'
        T 'Guardar' | Should -BeExactly 'Guardar'
        Convert-XamlLanguage '<Button Content="Guardar"/>' | Should -BeExactly '<Button Content="Guardar"/>'
    }

    It 'en ingles traduce, y lo que no tiene traduccion queda como esta' {
        Set-UiLanguage 'en'
        T 'Guardar' | Should -BeExactly 'Save'
        T 'Texto que no existe' | Should -BeExactly 'Texto que no existe'
        Convert-XamlLanguage '<Button Content="Guardar" ToolTip="Texto nuevo"/>' | Should -BeExactly '<Button Content="Save" ToolTip="Texto nuevo"/>'
    }

    It 'no toca las expresiones de enlace ni los textos sin traduccion' {
        Set-UiLanguage 'en'
        $x = '<TextBlock Text="{Binding Foo}"/><TextBlock Text="Read Aloud"/>'
        Convert-XamlLanguage $x | Should -BeExactly $x
    }
}

Describe 'Add-AutomationNames' {
    It 'un boton con solo ToolTip recibe ese texto como nombre' {
        Add-AutomationNames '<Button x:Name="B" ToolTip="Pausar" Width="3"/>' | Should -BeExactly '<Button x:Name="B" ToolTip="Pausar" AutomationProperties.Name="Pausar" Width="3"/>'
    }

    It 'no repite un nombre que ya existe' {
        $x = '<Button AutomationProperties.Name="X" ToolTip="Y"/>'
        Add-AutomationNames $x | Should -BeExactly $x
    }
}

Describe 'Cobertura de la traduccion' {
    BeforeAll {
        $fuentes = @('read_aloud_daemon.ps1', 'lib\ReadAloud.Settings.ps1', 'lib\ReadAloud.Hotkeys.ps1')
        $script:textos = New-Object System.Collections.Generic.List[string]
        # Estos no se traducen: nombres propios, numeros y los nombres de idioma.
        $iguales = @('Read Aloud', 'Piper', 'No', 'ES', 'English (EN)')
        foreach ($f in $fuentes) {
            $t = [IO.File]::ReadAllText((Join-Path $script:raiz $f), [Text.Encoding]::UTF8)
            foreach ($m in [regex]::Matches($t, '\b(?:Text|Content|ToolTip|Header|Title|AutomationProperties\.Name)="([^"{][^"]*)"')) {
                $v = $m.Groups[1].Value
                if ($v -notmatch '\p{L}{2}' -or $v -match '^&#' -or $v -match '^\d+ (min|s|%)$' -or $v -match '^[+\-]?\d+$') { continue }
                if (($iguales -contains $v) -or $v -like '*(ES)') { continue }
                [void]$script:textos.Add($v)
            }
            foreach ($m in [regex]::Matches($t, "\(T '((?:[^']|'')+)'\)")) {
                [void]$script:textos.Add($m.Groups[1].Value.Replace("''", "'"))
            }
        }
        $script:textos = @($script:textos | Select-Object -Unique)
    }

    It 'hay textos que revisar' {
        $script:textos.Count | Should -BeGreaterThan 100
    }

    It 'cada texto de las ventanas y del codigo tiene su traduccion al ingles' {
        $tabla = Get-EnglishTable
        $sin = @($script:textos | Where-Object { -not $tabla.ContainsKey($_) })
        $sin | Should -BeNullOrEmpty -Because ("faltan en lib\ReadAloud.Strings.ps1: " + ($sin -join ' | '))
    }

    It 'las traducciones no estan vacias' {
        foreach ($k in (Get-EnglishTable).Keys) { (Get-EnglishTable)[$k] | Should -Not -BeNullOrEmpty }
    }
}
