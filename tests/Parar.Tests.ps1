#
# Parar.Tests.ps1
# parar_read_aloud.ps1: cierra los piper.exe de una carpeta de instalacion y
# solo esos. Se usa un piper.exe de mentira (una copia de ping.exe) para no
# depender del motor real.

BeforeAll {
    $script:parar = Join-Path $PSScriptRoot '..\parar_read_aloud.ps1'

    function New-FalsoPiper {
        param([string]$Raiz)
        $dir = Join-Path $Raiz 'read_aloud_piper\bin\piper'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\ping.exe') -Destination (Join-Path $dir 'piper.exe')
        return Start-Process -FilePath (Join-Path $dir 'piper.exe') -ArgumentList '-n', '120', '127.0.0.1' -WindowStyle Hidden -PassThru
    }
}

Describe 'parar_read_aloud.ps1' {
    It 'cierra el piper.exe de la carpeta indicada y deja el de otra carpeta' {
        $a = Join-Path $TestDrive 'a'
        $b = Join-Path $TestDrive 'b'
        $pa = New-FalsoPiper $a
        $pb = New-FalsoPiper $b
        try {
            Start-Sleep -Milliseconds 400
            # -ListOnly: dice cual cerraria, sin cerrar nada
            $lista = @(& $script:parar -Root $a -ListOnly)
            $lista.Count | Should -Be 1
            $lista[0] | Should -Match ('^{0} piper.exe' -f $pa.Id)
            $pa.HasExited | Should -BeFalse

            & $script:parar -Root $a -OnlyPiper | Out-Null
            $pa.WaitForExit(8000) | Should -BeTrue
            $pb.HasExited | Should -BeFalse
        } finally {
            foreach ($p in $pa, $pb) { if (-not $p.HasExited) { $p.Kill() } }
        }
    }

    It 'sin nada que cerrar no hace nada ni falla' {
        $vacia = Join-Path $TestDrive 'vacia'
        New-Item -ItemType Directory -Path $vacia | Out-Null
        @(& $script:parar -Root $vacia).Count | Should -Be 0
    }
}
