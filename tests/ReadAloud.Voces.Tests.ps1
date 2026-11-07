#
# ReadAloud.Voces.Tests.ps1
# Que voces de Piper ofrece el panel de ajustes y cuales instala setup.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Core.ps1')
}

Describe 'Select-VisibleVoice' {
    BeforeAll {
        $instaladas = @('en_GB-cori-high', 'en_US-lessac-high', 'en_US-lessac-medium', 'es_MX-claude-high', 'es_MX-ald-medium')
    }

    It 'solo ofrece las de calidad alta cuando ninguna otra esta elegida' {
        $r = @(Select-VisibleVoice -Names $instaladas -Configured @('es_MX-claude-high', 'en_US-lessac-high'))
        $r | Should -Be @('en_GB-cori-high', 'en_US-lessac-high', 'es_MX-claude-high')
    }

    It 'una media que quedo de una version anterior no aparece junto a la alta' {
        $r = @(Select-VisibleVoice -Names $instaladas -Configured @('es_MX-claude-high', 'en_US-lessac-high'))
        $r -contains 'en_US-lessac-medium' | Should -BeFalse
    }

    It 'la voz elegida se ofrece aunque no sea de calidad alta' {
        $r = @(Select-VisibleVoice -Names $instaladas -Configured @('es_MX-ald-medium', 'en_US-lessac-high'))
        $r -contains 'es_MX-ald-medium' | Should -BeTrue
    }

    It 'sin voces instaladas no devuelve nada' {
        @(Select-VisibleVoice -Names @() -Configured @('es_MX-claude-high')).Count | Should -Be 0
    }
}

Describe 'setup.ps1' {
    BeforeAll {
        $texto = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\setup.ps1') -Raw -Encoding UTF8
        $catalogo = [regex]::Matches($texto, "'((?:es|en)_[A-Z]{2}-[a-z]+-(?:x_low|low|medium|high))'\s*=") | ForEach-Object { $_.Groups[1].Value }
    }

    It 'sabe instalar las dos voces que usa por defecto' {
        $ajustes = Get-ReadAloudSettings -Paths @{ SettingsFile = ''; LocalSettingsFile = ''; UserSettingsFile = 'C:\no\existe.json' }
        $catalogo -contains $ajustes.VoiceEs | Should -BeTrue
        $catalogo -contains $ajustes.VoiceEn | Should -BeTrue
    }

    It 'ya no ofrece la voz inglesa media: la inglesa por defecto es la alta' {
        $catalogo -contains 'en_US-lessac-medium' | Should -BeFalse
        $catalogo -contains 'en_US-lessac-high' | Should -BeTrue
    }
}
