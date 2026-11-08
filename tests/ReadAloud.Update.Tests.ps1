#
# ReadAloud.Update.Tests.ps1
# Version, actualizaciones y diagnostico (lib\ReadAloud.Update.ps1), sin red.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Update.ps1')
}

Describe 'Test-NewerVersion' {
    It '<Latest> frente a <Current>: <Esperado>' -ForEach @(
        @{ Current = '1.1.0'; Latest = 'v1.2.0'; Esperado = $true }
        @{ Current = '1.2.0'; Latest = 'v1.2.0'; Esperado = $false }
        @{ Current = '1.2.1'; Latest = 'v1.2.0'; Esperado = $false }
        @{ Current = '1.2.0-dev'; Latest = 'v1.2.0'; Esperado = $true }
        @{ Current = '1.2.0'; Latest = 'v1.2.0-dev'; Esperado = $false }
        @{ Current = '1.9.0'; Latest = 'v1.10.0'; Esperado = $true }
        @{ Current = '1.2.0'; Latest = 'basura'; Esperado = $false }
    ) {
        Test-NewerVersion -Current $Current -Latest $Latest | Should -Be $Esperado
    }
}

Describe 'Get-ReadAloudVersion' {
    It 'lee VERSION y, si falta, da 0.0.0' {
        Set-Content -LiteralPath (Join-Path $TestDrive 'VERSION') -Value "1.3.0-dev`r`n" -Encoding ASCII
        Get-ReadAloudVersion -Root $TestDrive | Should -BeExactly '1.3.0-dev'
        Get-ReadAloudVersion -Root (Join-Path $TestDrive 'nada') | Should -BeExactly '0.0.0'
    }
}

Describe 'Select-InstallerAsset' {
    It 'elige el instalador y su suma entre los archivos del release' {
        $release = [pscustomobject]@{ assets = @(
            [pscustomobject]@{ name = 'Source.zip'; browser_download_url = 'u0'; size = 1 }
            [pscustomobject]@{ name = 'ReadAloud-Setup-1.3.0.exe.sha256'; browser_download_url = 'u2'; size = 90 }
            [pscustomobject]@{ name = 'ReadAloud-Setup-1.3.0.exe'; browser_download_url = 'u1'; size = 2200000 }
        ) }
        $a = Select-InstallerAsset $release
        $a.Name | Should -BeExactly 'ReadAloud-Setup-1.3.0.exe'
        $a.Url | Should -BeExactly 'u1'
        $a.ShaUrl | Should -BeExactly 'u2'
    }

    It 'sin instalador devuelve nulo' {
        Select-InstallerAsset ([pscustomobject]@{ assets = @() }) | Should -BeNullOrEmpty
    }
}

Describe 'Suma SHA-256' {
    It 'Get-ExpectedHash saca el hash del archivo .sha256' {
        $h = ('ab' * 32)
        Get-ExpectedHash "$h  ReadAloud-Setup-1.3.0.exe" | Should -BeExactly $h
        Get-ExpectedHash 'sin hash' | Should -BeExactly ''
    }

    It 'Test-FileHash acepta el hash correcto y rechaza otro o uno vacio' {
        $f = Join-Path $TestDrive 'a.bin'
        [IO.File]::WriteAllBytes($f, [byte[]](1, 2, 3))
        $real = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        Test-FileHash -Path $f -Expected $real | Should -BeTrue
        Test-FileHash -Path $f -Expected $real.ToLowerInvariant() | Should -BeTrue
        Test-FileHash -Path $f -Expected ('0' * 64) | Should -BeFalse
        Test-FileHash -Path $f -Expected '' | Should -BeFalse
    }
}

Describe 'Get-ReleaseNotesSummary' {
    It 'quita el formato y corta en el maximo de lineas' {
        $body = "## Added`n`n- **Uno** con ``codigo```n- Dos`n- Tres"
        $r = Get-ReleaseNotesSummary -Body $body -MaxLines 3
        $r | Should -BeExactly "Added`n- Uno con codigo`n- Dos"
    }
}

Describe 'Get-DiagnosticText' {
    It 'lleva version, motores y atajos, y no la ruta del usuario' {
        $report = @(
            [pscustomobject]@{ Action = 'read'; Text = 'Ctrl+Alt+V'; Active = $true; Reason = '' }
            [pscustomobject]@{ Action = 'stop'; Text = 'Ctrl+Shift+Q'; Active = $false; Reason = 'in-use' }
        )
        $t = Get-DiagnosticText -Version '1.2.0' -Engines @{ es = 'qwen'; en = 'piper' } -HotkeyReport $report `
            -LogTail @("error en $env:USERPROFILE\algo")
        $t | Should -Match 'Read Aloud 1.2.0'
        $t | Should -Match 'Motores: es=qwen, en=piper'
        $t | Should -Match 'stop: Ctrl\+Shift\+Q \(in-use\)'
        $t | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
    }
}

Describe 'Calendario del aviso de versiones' {
    It 'Test-UpdateCheckDue: nunca consultado, hace <Horas> h, futuro' -ForEach @(
        @{ Ultima = $null; Horas = 0; Esperado = $true }
        @{ Ultima = '2026-11-07T10:00:00Z'; Horas = 2; Esperado = $false }
        @{ Ultima = '2026-11-06T10:00:00Z'; Horas = 25; Esperado = $true }
        @{ Ultima = '2026-11-08T10:00:00Z'; Horas = 0; Esperado = $true }
        @{ Ultima = 'basura'; Horas = 0; Esperado = $true }
    ) {
        $ahora = [datetime]::Parse('2026-11-07T12:00:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        Test-UpdateCheckDue -LastCheckUtc $Ultima -NowUtc $ahora -Hours 24 | Should -Be $Esperado
    }

    It 'el estado se guarda y se lee, y un archivo roto da el estado vacio' {
        $f = Join-Path $TestDrive 'act.json'
        $s = Read-UpdateState -Path $f
        $s.LastCheckUtc | Should -BeNullOrEmpty
        $s.LastCheckUtc = [datetime]::UtcNow
        $s.NotifiedVersion = 'v9.9.9'
        Write-UpdateState -Path $f -State $s
        $r = Read-UpdateState -Path $f
        $r.NotifiedVersion | Should -BeExactly 'v9.9.9'
        [Math]::Abs(($r.LastCheckUtc - $s.LastCheckUtc).TotalSeconds) | Should -BeLessThan 2
        Set-Content -LiteralPath $f -Value '{ no es json'
        (Read-UpdateState -Path $f).NotifiedVersion | Should -BeExactly ''
    }
}
