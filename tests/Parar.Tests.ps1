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

    # Asi lo corre una persona a mano. En Windows PowerShell 5.1, $PSScriptRoot
    # esta vacio en los valores por defecto de param: GetFullPath fallaba, el
    # prefijo quedaba en '\' y se cerraba el proceso residente de cualquier
    # carpeta, pero no el piper.exe de la propia.
    It 'sin -Root, en Windows PowerShell 5.1, usa su propia carpeta y no falla' {
        $propia = Join-Path $TestDrive 'propia'
        $otra = Join-Path $TestDrive 'otra'
        $pa = New-FalsoPiper $propia
        $pb = New-FalsoPiper $otra
        try {
            $copia = Join-Path $propia 'parar_read_aloud.ps1'
            Copy-Item -LiteralPath $script:parar -Destination $copia
            Start-Sleep -Milliseconds 400

            $info = New-Object System.Diagnostics.ProcessStartInfo
            $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ListOnly' -f $copia
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $proceso = [System.Diagnostics.Process]::Start($info)
            $errores = $proceso.StandardError.ReadToEndAsync()
            $salida = $proceso.StandardOutput.ReadToEnd()
            $proceso.WaitForExit()

            $errores.Result.Trim() | Should -BeNullOrEmpty
            $proceso.ExitCode | Should -Be 0
            $lineas = @($salida -split "`r?`n" | Where-Object { $_.Trim() })
            $lineas.Count | Should -Be 1
            $lineas[0] | Should -Match ('^{0} piper.exe' -f $pa.Id)
            $pa.HasExited | Should -BeFalse
            $pb.HasExited | Should -BeFalse
        } finally {
            foreach ($p in $pa, $pb) { if (-not $p.HasExited) { $p.Kill() } }
        }
    }
}
