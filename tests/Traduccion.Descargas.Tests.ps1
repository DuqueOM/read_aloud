#
# Traduccion.Descargas.Tests.ps1
# config\traduccion.psd1: lo que setup.ps1 baja para la traduccion. Cada
# pieza se baja de su origen por https, con su tamano y su sha256, y va a una
# carpeta dentro de read_aloud_piper\traduccion. Los modelos tienen el nombre
# que reconoce el catalogo de traductores.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Core.ps1')
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Text.ps1')
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Translate.ps1')
    $script:catalogo = Read-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\config\traduccion.psd1')
    $script:piezas = @($script:catalogo.Basica) + @($script:catalogo.Alta) + @($script:catalogo.Modelo7B)
}

Describe 'config\traduccion.psd1' {
    It 'tiene los tres niveles' {
        $script:catalogo.Keys | Should -Contain 'Basica'
        $script:catalogo.Keys | Should -Contain 'Alta'
        $script:catalogo.Keys | Should -Contain 'Modelo7B'
    }

    It 'cada pieza tiene un origen https, su tamano, un sha256 y un tipo conocido' {
        foreach ($p in $script:piezas) {
            $p.Url | Should -Match '^https://' -Because $p.Id
            [long]$p.Bytes | Should -BeGreaterThan 0 -Because $p.Id
            $p.Sha256 | Should -Match '^[0-9a-f]{64}$' -Because $p.Id
            $p.Tipo | Should -BeIn @('archivo', 'gz', 'zip') -Because $p.Id
        }
    }

    It 'cada pieza va a una carpeta relativa, sin salir de la de la traduccion' {
        foreach ($p in $script:piezas) {
            [IO.Path]::IsPathRooted($p.Destino) | Should -BeFalse -Because $p.Id
            $p.Destino | Should -Not -Match '\.\.' -Because $p.Id
            $p.Destino | Should -Match '^(translateLocally|llama|modelos)' -Because $p.Id
        }
    }

    It 'los identificadores y los destinos no se repiten' {
        @($script:piezas | ForEach-Object { $_.Id } | Select-Object -Unique).Count | Should -Be $script:piezas.Count
        @($script:piezas | ForEach-Object { $_.Destino } | Select-Object -Unique).Count | Should -Be $script:piezas.Count
    }

    It 'la basica pesa unos 112 MB y la alta unos 1.17 GB, como dice el ADR' {
        # Measure-Object no lee las claves de un hashtable en Windows PowerShell 5.1.
        $basica = [long]0; foreach ($p in @($script:catalogo.Basica)) { $basica += [long]$p.Bytes }
        $alta = [long]0; foreach ($p in @($script:catalogo.Alta)) { $alta += [long]$p.Bytes }
        # En megas y gigas decimales, como los muestra el instalador.
        [Math]::Round($basica / 1e6) | Should -BeIn (105..115)
        [Math]::Round($alta / 1e9, 2) | Should -Be 1.17
    }

    It 'la basica trae translateLocally y los dos sentidos de Bergamot' {
        $destinos = @($script:catalogo.Basica | ForEach-Object { $_.Destino })
        $destinos | Should -Contain 'translateLocally\translateLocally.exe'
        foreach ($par in @('en-es', 'es-en')) {
            foreach ($inicio in @('model.', 'lex.', 'vocab.')) {
                @($destinos | Where-Object { $_ -like "translateLocally\models\$par-base-memory\$inicio*" }).Count | Should -Be 1 -Because "$par $inicio"
            }
        }
    }

    It 'la alta trae llama.cpp en llama y el modelo de 1.8B' {
        @($script:catalogo.Alta | Where-Object { $_.Tipo -eq 'zip' -and $_.Destino -eq 'llama' }).Count | Should -Be 1
        @($script:catalogo.Alta | Where-Object { $_.Destino -like 'modelos\*.gguf' }).Count | Should -Be 1
    }

    It 'cada GGUF tiene el nombre que reconoce el catalogo de traductores (<Nivel>)' -ForEach @(
        @{ Nivel = 'Alta'; Id = 'hymt2-1.8b' }
        @{ Nivel = 'Modelo7B'; Id = 'hymt2-7b' }
    ) {
        $gguf = @($script:catalogo[$Nivel] | Where-Object { $_.Destino -like 'modelos\*.gguf' })[0]
        $patron = @(Get-TranslatorCatalog | Where-Object { $_.Id -eq $Id })[0].Pattern
        (Split-Path -Leaf $gguf.Destino) | Should -Match $patron
    }

    It 'el sha256 de translateLocally es el que se fijo en la fase 0' {
        @($script:catalogo.Basica | Where-Object { $_.Id -eq 'translatelocally' })[0].Sha256 | Should -Be 'b7cb0f58369cc508812f049af8c07ed59f2340e8007d31ee672dcef450e53aa4'
    }
}

Describe 'setup.ps1 y la traduccion' {
    BeforeAll {
        $script:setup = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\setup.ps1') -Raw
        $errores = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path (Join-Path $PSScriptRoot '..\setup.ps1')).Path, [ref]$null, [ref]$errores)
        $script:erroresSetup = $errores
    }

    It 'se puede leer sin errores de sintaxis' {
        $script:erroresSetup | Should -BeNullOrEmpty
    }

    It 'tiene los parametros de la traduccion' {
        foreach ($p in @('TranslationHigh', 'Translation7B', 'SkipTranslation', 'OnlyTranslation', 'LocalSource')) {
            $script:setup | Should -Match ('\$' + $p) -Because $p
        }
    }

    It 'comprueba el sha256 antes de instalar cada pieza' {
        $f = [regex]::Match($script:setup, '(?s)function Install-TranslationItem \{.*?\n\}').Value
        $f.IndexOf('Get-FileSha256') | Should -BeGreaterThan 0
        $f.IndexOf('Get-FileSha256') | Should -BeLessThan $f.IndexOf("switch (`$Item.Tipo)")
    }
}
