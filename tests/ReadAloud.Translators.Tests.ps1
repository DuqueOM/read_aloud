#
# ReadAloud.Translators.Tests.ps1
# Lo que se puede probar de los procesos de la traduccion
# (lib\ReadAloud.Translators.ps1) sin abrir los traductores: los mensajes de
# translateLocally, sus hilos en el registro, el puerto libre y la foto del
# equipo.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Text.ps1')
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Translate.ps1')
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Translators.ps1')
}

Describe 'Read-BergamotMessage' {
    It 'lee lo que escribe ConvertTo-BergamotMessage, con tildes' {
        $texto = 'Hola, ' + [char]0x00BF + 'que tal?'
        $bytes = ConvertTo-BergamotMessage -Id 7 -Command 'Translate' -Data @{ text = $texto }
        $flujo = New-Object IO.MemoryStream(, $bytes)
        $m = Read-BergamotMessage -Stream $flujo -TimeoutMs 2000
        $m.id | Should -Be 7
        $m.command | Should -Be 'Translate'
        $m.data.text | Should -BeExactly $texto
    }

    It 'lee dos mensajes seguidos en orden' {
        $a = ConvertTo-BergamotMessage -Id 1 -Command 'A' -Data @{}
        $b = ConvertTo-BergamotMessage -Id 2 -Command 'B' -Data @{}
        $flujo = New-Object IO.MemoryStream(, ([byte[]]($a + $b)))
        (Read-BergamotMessage -Stream $flujo).id | Should -Be 1
        (Read-BergamotMessage -Stream $flujo).id | Should -Be 2
    }

    It 'un flujo cerrado a medias es un error' {
        $bytes = ConvertTo-BergamotMessage -Id 1 -Command 'Translate' -Data @{ text = 'abc' }
        $flujo = New-Object IO.MemoryStream(, ([byte[]]$bytes[0..5]))
        { Read-BergamotMessage -Stream $flujo -TimeoutMs 2000 } | Should -Throw
    }

    It 'un largo de cero es un error' {
        $flujo = New-Object IO.MemoryStream(, ([byte[]](0, 0, 0, 0)))
        { Read-BergamotMessage -Stream $flujo -TimeoutMs 2000 } | Should -Throw
    }
}

Describe 'Set-BergamotThreads' {
    BeforeAll {
        $subclave = 'Software\Pester\ReadAloud_' + [guid]::NewGuid().ToString('N')
    }
    AfterAll {
        try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($subclave, $false) } catch { }
    }

    It 'deja los hilos como DWORD en cpu_cores' {
        Set-BergamotThreads -Threads 4 -SubKey $subclave | Should -BeTrue
        $clave = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subclave)
        try {
            $clave.GetValue('cpu_cores') | Should -Be 4
            $clave.GetValueKind('cpu_cores') | Should -Be ([Microsoft.Win32.RegistryValueKind]::DWord)
        } finally { $clave.Dispose() }
    }

    It 'cambia el valor si se piden otros hilos' {
        Set-BergamotThreads -Threads 2 -SubKey $subclave | Should -BeTrue
        $clave = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subclave)
        try { $clave.GetValue('cpu_cores') | Should -Be 2 } finally { $clave.Dispose() }
    }
}

Describe 'Get-FreeTcpPort' {
    It 'da un puerto que se puede abrir en 127.0.0.1' {
        $puerto = Get-FreeTcpPort
        $puerto | Should -BeGreaterThan 0
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $puerto)
        { $l.Start() } | Should -Not -Throw
        $l.Stop()
    }
}

Describe 'La foto del equipo' {
    It 'la RAM disponible y los nucleos fisicos tienen valores razonables' {
        Get-RamAvailableMiB | Should -BeGreaterThan 0
        Get-PhysicalCoreCount | Should -BeGreaterOrEqual 1
    }

    It 'sin nvidia-smi no hay tarjeta' {
        $d = Get-TranslateDeviceSnapshot -Smi '' -BusyFile '' -PhysicalCores 8
        $d.GpuFreeMiB | Should -Be -1
        $d.GpuBusy | Should -BeFalse
        $d.PhysicalCores | Should -Be 8
        $d.RamAvailableMiB | Should -BeGreaterThan 0
    }
}

Describe 'Set-GpuReserveFile' {
    It 'anota el proceso y los MiB, y los borra sin proceso' {
        $f = Join-Path $TestDrive 'traductor_tarjeta'
        Set-GpuReserveFile -Path $f -Process (Get-Process -Id $PID) -MiB 4321.2
        (Get-Content -LiteralPath $f -Raw).Trim() | Should -BeExactly ('{0} 4322' -f $PID)
        Set-GpuReserveFile -Path $f
        Test-Path -LiteralPath $f | Should -BeFalse
    }
}
