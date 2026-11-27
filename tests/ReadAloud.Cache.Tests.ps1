#
# ReadAloud.Cache.Tests.ps1
# La clave y la caducidad del audio y de las traducciones guardadas
# (lib\ReadAloud.Cache.ps1).

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Cache.ps1')
    $ahora = [DateTime]'2026-11-27T10:00:00'
    $sonido = @{ LengthScale = 1.06; NoiseScale = 0.667; NoiseW = 0.8; SentenceSilence = 0.36 }
}

Describe 'Get-TextHash' {
    It 'es el SHA-256 en hexadecimal' {
        Get-TextHash -Text 'abc' | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }

    It 'las tildes cuentan' {
        Get-TextHash -Text ('canci' + [char]0x00F3 + 'n') | Should -Not -Be (Get-TextHash -Text 'cancion')
    }
}

Describe 'Get-AudioCacheKey' {
    It 'el mismo texto con la misma voz y ajustes da la misma clave' {
        $a = Get-AudioCacheKey -Engine 'piper' -Voice 'es_MX-claude-high' -Lang 'es' -Text 'Hola.' -Sound $sonido
        $b = Get-AudioCacheKey -Engine 'piper' -Voice 'es_MX-claude-high' -Lang 'es' -Text 'Hola.' -Sound @{ SentenceSilence = 0.36; NoiseW = 0.8; NoiseScale = 0.667; LengthScale = 1.06 }
        $a | Should -Be $b
        $a | Should -Match '^[0-9a-f]{64}$'
    }

    It 'cambia con <Cambio>' -ForEach @(
        @{ Cambio = 'el motor'; Motor = 'qwen'; Voz = 'es_MX-claude-high'; Idioma = 'es'; Texto = 'Hola.'; Velocidad = 1.06 }
        @{ Cambio = 'la voz'; Motor = 'piper'; Voz = 'es_MX-otra-high'; Idioma = 'es'; Texto = 'Hola.'; Velocidad = 1.06 }
        @{ Cambio = 'el idioma'; Motor = 'piper'; Voz = 'es_MX-claude-high'; Idioma = 'en'; Texto = 'Hola.'; Velocidad = 1.06 }
        @{ Cambio = 'el texto'; Motor = 'piper'; Voz = 'es_MX-claude-high'; Idioma = 'es'; Texto = 'Hola'; Velocidad = 1.06 }
        @{ Cambio = 'la velocidad'; Motor = 'piper'; Voz = 'es_MX-claude-high'; Idioma = 'es'; Texto = 'Hola.'; Velocidad = 1.1 }
    ) {
        $base = Get-AudioCacheKey -Engine 'piper' -Voice 'es_MX-claude-high' -Lang 'es' -Text 'Hola.' -Sound $sonido
        $s = @{} + $sonido
        $s.LengthScale = $Velocidad
        Get-AudioCacheKey -Engine $Motor -Voice $Voz -Lang $Idioma -Text $Texto -Sound $s | Should -Not -Be $base
    }

    It 'los numeros no dependen del idioma de Windows' {
        $antes = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            $a = Get-AudioCacheKey -Engine 'piper' -Voice 'v' -Lang 'es' -Text 'x' -Sound $sonido
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]'es-ES'
            $b = Get-AudioCacheKey -Engine 'piper' -Voice 'v' -Lang 'es' -Text 'x' -Sound $sonido
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $antes
        }
        $b | Should -Be $a
    }

    It 'un ajuste llamado "keys" no rompe la clave' {
        { Get-AudioCacheKey -Engine 'piper' -Voice 'v' -Lang 'es' -Text 'x' -Sound @{ keys = 1; values = 2 } } | Should -Not -Throw
    }
}

Describe 'Get-TranslationCacheKey' {
    It 'cambia con el texto, la direccion y el modelo' {
        $base = Get-TranslationCacheKey -Text 'Hello.' -Source 'en' -Target 'es' -Model 'hymt2-1.8b'
        Get-TranslationCacheKey -Text 'Hello.' -Source 'en' -Target 'es' -Model 'hymt2-1.8b' | Should -Be $base
        Get-TranslationCacheKey -Text 'Hello!' -Source 'en' -Target 'es' -Model 'hymt2-1.8b' | Should -Not -Be $base
        Get-TranslationCacheKey -Text 'Hello.' -Source 'es' -Target 'en' -Model 'hymt2-1.8b' | Should -Not -Be $base
        Get-TranslationCacheKey -Text 'Hello.' -Source 'en' -Target 'es' -Model 'bergamot' | Should -Not -Be $base
    }

    It 'no coincide con la de un audio del mismo texto' {
        Get-TranslationCacheKey -Text 'x' -Source 'en' -Target 'es' -Model 'm' | Should -Not -Be (Get-AudioCacheKey -Engine 'en' -Voice 'es' -Lang 'm' -Text 'x')
    }
}

Describe 'Get-CacheEvictions' {
    It 'quita lo que lleva <Minutos> minutos sin usarse o mas' -ForEach @(
        @{ Minutos = 10; Quitado = $true }
        @{ Minutos = 15; Quitado = $true }
        @{ Minutos = 9.9; Quitado = $false }
    ) {
        $e = @{ Path = 'a'; Bytes = 1; LastUsed = $ahora.AddMinutes(-$Minutos) }
        $fuera = @(Get-CacheEvictions -Entries @($e) -Now $ahora -Minutes 10)
        ($fuera.Count -eq 1) | Should -Be $Quitado
    }

    It 'con el tope de espacio, quita primero lo usado hace mas tiempo' {
        $entradas = @(
            @{ Path = 'vieja'; Bytes = 400; LastUsed = $ahora.AddMinutes(-5) }
            @{ Path = 'nueva'; Bytes = 400; LastUsed = $ahora.AddMinutes(-1) }
            @{ Path = 'media'; Bytes = 400; LastUsed = $ahora.AddMinutes(-3) }
        )
        $fuera = @(Get-CacheEvictions -Entries $entradas -Now $ahora -Minutes 10 -MaxBytes 900)
        $fuera.Count | Should -Be 1
        $fuera[0].Path | Should -Be 'vieja'
    }

    It 'sin tope solo cuenta la edad' {
        $entradas = @(1..5 | ForEach-Object { @{ Path = "$_"; Bytes = 1GB; LastUsed = $ahora } })
        @(Get-CacheEvictions -Entries $entradas -Now $ahora -Minutes 10 -MaxBytes 0).Count | Should -Be 0
    }

    It 'sin entradas no quita nada' {
        @(Get-CacheEvictions -Entries @() -Now $ahora -Minutes 10 -MaxBytes 100).Count | Should -Be 0
    }
}

Describe 'Audio guardado en disco' {
    BeforeEach {
        $cache = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $wav = Join-Path $TestDrive 'frase.wav'
        [IO.File]::WriteAllBytes($wav, [byte[]](1..100))
        $clave = Get-AudioCacheKey -Engine 'piper' -Voice 'v' -Lang 'es' -Text 'Hola.' -Sound $sonido
    }

    It 'se guarda y se copia mientras esta vigente' {
        Save-AudioToCache -Wav $wav -CacheDir $cache -Key $clave -Now $ahora | Should -BeTrue
        $destino = Join-Path $TestDrive 'copia.wav'
        Copy-AudioFromCache -CacheDir $cache -Key $clave -Destination $destino -Minutes 10 -Now $ahora.AddMinutes(9) | Should -BeTrue
        [IO.File]::ReadAllBytes($destino).Length | Should -Be 100
    }

    It 'cada uso renueva el plazo' {
        [void](Save-AudioToCache -Wav $wav -CacheDir $cache -Key $clave -Now $ahora)
        $destino = Join-Path $TestDrive 'copia.wav'
        [void](Copy-AudioFromCache -CacheDir $cache -Key $clave -Destination $destino -Minutes 10 -Now $ahora.AddMinutes(9))
        Copy-AudioFromCache -CacheDir $cache -Key $clave -Destination $destino -Minutes 10 -Now $ahora.AddMinutes(18) | Should -BeTrue
    }

    It 'caducado no se copia' {
        [void](Save-AudioToCache -Wav $wav -CacheDir $cache -Key $clave -Now $ahora)
        Copy-AudioFromCache -CacheDir $cache -Key $clave -Destination (Join-Path $TestDrive 'c.wav') -Minutes 10 -Now $ahora.AddMinutes(10) | Should -BeFalse
    }

    It 'con 0 minutos no se usa' {
        [void](Save-AudioToCache -Wav $wav -CacheDir $cache -Key $clave -Now $ahora)
        Copy-AudioFromCache -CacheDir $cache -Key $clave -Destination (Join-Path $TestDrive 'c.wav') -Minutes 0 -Now $ahora | Should -BeFalse
    }

    It 'sin audio guardado no copia nada' {
        Copy-AudioFromCache -CacheDir $cache -Key $clave -Destination (Join-Path $TestDrive 'c.wav') -Minutes 10 -Now $ahora | Should -BeFalse
    }

    It 'un WAV que no existe no se guarda' {
        Save-AudioToCache -Wav (Join-Path $TestDrive 'no.wav') -CacheDir $cache -Key $clave | Should -BeFalse
    }

    It 'la limpieza borra lo caducado y lo que pasa del tope' {
        foreach ($i in 1..4) {
            [void](Save-AudioToCache -Wav $wav -CacheDir $cache -Key "k$i" -Now $ahora.AddMinutes(-$i * 4))
        }
        # k3 (12 min) y k4 (16 min) caducaron; con 150 bytes de tope solo cabe k1.
        Clear-AudioCache -CacheDir $cache -Minutes 10 -MaxBytes 150 -Now $ahora | Should -Be 3
        @(Get-ChildItem -LiteralPath $cache -Filter '*.wav').Name | Should -Be @('k1.wav')
    }

    It 'la limpieza de una carpeta que no existe no falla' {
        Clear-AudioCache -CacheDir (Join-Path $TestDrive 'nada') -Minutes 10 | Should -Be 0
    }
}

Describe 'Traducciones en memoria' {
    It 'se guardan y se recuperan mientras estan vigentes' {
        $m = New-TranslationMemory
        Set-CachedTranslation -Memory $m -Key 'k' -Text 'Hola.' -Now $ahora
        Get-CachedTranslation -Memory $m -Key 'k' -Minutes 10 -Now $ahora.AddMinutes(5) | Should -Be 'Hola.'
    }

    It 'cada uso renueva el plazo' {
        $m = New-TranslationMemory
        Set-CachedTranslation -Memory $m -Key 'k' -Text 'Hola.' -Now $ahora
        [void](Get-CachedTranslation -Memory $m -Key 'k' -Minutes 10 -Now $ahora.AddMinutes(8))
        Get-CachedTranslation -Memory $m -Key 'k' -Minutes 10 -Now $ahora.AddMinutes(16) | Should -Be 'Hola.'
    }

    It 'caducada no se devuelve y se quita' {
        $m = New-TranslationMemory
        Set-CachedTranslation -Memory $m -Key 'k' -Text 'Hola.' -Now $ahora
        Get-CachedTranslation -Memory $m -Key 'k' -Minutes 10 -Now $ahora.AddMinutes(11) | Should -BeNullOrEmpty
        $m.Count | Should -Be 0
    }

    It 'la limpieza quita solo las caducadas, aunque una clave se llame "keys"' {
        $m = New-TranslationMemory
        Set-CachedTranslation -Memory $m -Key 'keys' -Text 'a' -Now $ahora.AddMinutes(-20)
        Set-CachedTranslation -Memory $m -Key 'nueva' -Text 'b' -Now $ahora
        Clear-ExpiredTranslations -Memory $m -Minutes 10 -Now $ahora | Should -Be 1
        $m.ContainsKey('nueva') | Should -BeTrue
        $m.ContainsKey('keys') | Should -BeFalse
    }

    It 'sin memoria o sin la clave devuelve $null' {
        Get-CachedTranslation -Memory $null -Key 'k' -Minutes 10 | Should -BeNullOrEmpty
        Get-CachedTranslation -Memory (New-TranslationMemory) -Key 'k' -Minutes 10 | Should -BeNullOrEmpty
    }
}

Describe 'Get-SynthAudioKey' {
    BeforeAll {
        # Como $synthConfig del proceso residente: los numeros ya van en texto.
        function New-TestSynthConfig {
            param([string]$Carpeta = 'C:\a\voices', [string]$Velocidad = '1.06', [string]$Silencio = '0.36')
            return @{
                Models          = @{ es = "$Carpeta\es_MX-claude-high.onnx"; en = "$Carpeta\en_US-lessac-high.onnx" }
                LengthScale     = $Velocidad
                NoiseScale      = '0.667'
                NoiseW          = '0.8'
                SentenceSilence = $Silencio
                Qwen            = @{ VoiceDir = 'C:\voz\modelos\voz_app' }
            }
        }
    }

    It 'Piper: la voz es el nombre del modelo, no su carpeta' {
        $a = Get-SynthAudioKey -Config (New-TestSynthConfig) -Engine 'piper' -Lang 'es' -Text 'Hola.'
        $b = Get-SynthAudioKey -Config (New-TestSynthConfig -Carpeta 'D:\otra\voices') -Engine 'piper' -Lang 'es' -Text 'Hola.'
        $b | Should -Be $a
        $a | Should -Be (Get-AudioCacheKey -Engine 'piper' -Voice 'es_MX-claude-high' -Lang 'es' -Text 'Hola.' -Sound @{
            LengthScale = '1.06'; NoiseScale = '0.667'; NoiseW = '0.8'; SentenceSilence = '0.36' })
    }

    It 'Piper: cada idioma usa su modelo' {
        $c = New-TestSynthConfig
        Get-SynthAudioKey -Config $c -Engine 'piper' -Lang 'en' -Text 'Hi.' | Should -Not -Be (Get-SynthAudioKey -Config $c -Engine 'piper' -Lang 'es' -Text 'Hi.')
    }

    It 'la voz propia no cambia con la velocidad de Piper, pero si con el silencio final' {
        $a = Get-SynthAudioKey -Config (New-TestSynthConfig) -Engine 'qwen' -Lang 'es' -Text 'Hola.'
        Get-SynthAudioKey -Config (New-TestSynthConfig -Velocidad '1.2') -Engine 'qwen' -Lang 'es' -Text 'Hola.' | Should -Be $a
        Get-SynthAudioKey -Config (New-TestSynthConfig -Silencio '0.5') -Engine 'qwen' -Lang 'es' -Text 'Hola.' | Should -Not -Be $a
    }

    It 'el audio de la voz propia y el de Piper no se confunden' {
        $c = New-TestSynthConfig
        Get-SynthAudioKey -Config $c -Engine 'qwen' -Lang 'es' -Text 'Hola.' | Should -Not -Be (Get-SynthAudioKey -Config $c -Engine 'piper' -Lang 'es' -Text 'Hola.')
    }

    It 'sin voz para ese idioma no hay clave' {
        $c = New-TestSynthConfig
        $c.Models = @{ es = $c.Models.es }
        Get-SynthAudioKey -Config $c -Engine 'piper' -Lang 'en' -Text 'Hi.' | Should -Be ''
        $c.Qwen.VoiceDir = ''
        Get-SynthAudioKey -Config $c -Engine 'qwen' -Lang 'es' -Text 'Hola.' | Should -Be ''
    }
}

Describe 'read_aloud_daemon.ps1 y el audio guardado' {
    BeforeAll {
        $ruta = Join-Path $PSScriptRoot '..\read_aloud_daemon.ps1'
        $errores = $null
        $arbol = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ruta).Path, [ref]$null, [ref]$errores)
        $texto = Get-Content -LiteralPath $ruta -Raw
    }

    It 'se puede leer sin errores de sintaxis' {
        $errores | Should -BeNullOrEmpty
        $arbol | Should -Not -BeNullOrEmpty
    }

    It 'el hilo de voz carga la biblioteca y guarda antes de avisar al reproductor' {
        $texto | Should -Match '\. \$cfg\.CacheLib'
        $envio = [regex]::Match($texto, '(?s)function Send-SynthDone \{.*?\n    \}').Value
        $envio.IndexOf('Save-AudioToCache') | Should -BeGreaterThan 0
        $envio.IndexOf('Save-AudioToCache') | Should -BeLessThan $envio.IndexOf('SynthDone.Enqueue')
    }

    It 'la pausa del bloque se pega despues, en el reproductor, no en lo guardado' {
        $texto | Should -Match 'Add-WavSilence -Path \$done\.Wav'
        $texto | Should -Not -Match 'Add-WavSilence -Path [^\r\n]*AudioCache'
    }
}
