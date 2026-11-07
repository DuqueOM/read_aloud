#
# ReadAloud.Hotkeys.Tests.ps1
# La logica de los atajos (lib\ReadAloud.Hotkeys.ps1) sin registrar nada en
# Windows: leer "Ctrl+Alt+V", validar una lista y los valores por defecto.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Hotkeys.ps1')
}

Describe 'ConvertFrom-HotkeySpec' {
    It '"<Spec>" da modificadores <Mods>, tecla <Vk> y forma "<Texto>"' -ForEach @(
        @{ Spec = 'Ctrl+Alt+V'; Mods = 3; Vk = 0x56; Texto = 'Ctrl+Alt+V' }
        @{ Spec = 'ctrl + shift + space'; Mods = 6; Vk = 0x20; Texto = 'Ctrl+Shift+Space' }
        @{ Spec = 'Shift+Ctrl+,'; Mods = 6; Vk = 0xBC; Texto = 'Ctrl+Shift+,' }
        @{ Spec = 'Win+Alt+F5'; Mods = 9; Vk = 0x74; Texto = 'Alt+Win+F5' }
        @{ Spec = 'control+alt+9'; Mods = 3; Vk = 0x39; Texto = 'Ctrl+Alt+9' }
        @{ Spec = 'MediaPlayPause'; Mods = 0; Vk = 0xB3; Texto = 'MediaPlayPause' }
        @{ Spec = 'F9'; Mods = 0; Vk = 0x78; Texto = 'F9' }
    ) {
        $p = ConvertFrom-HotkeySpec $Spec
        $p.Modifiers | Should -Be $Mods
        $p.Vk | Should -Be $Vk
        $p.Text | Should -BeExactly $Texto
    }

    It '"<Spec>" no es valido' -ForEach @(
        @{ Spec = '' }
        @{ Spec = 'Ctrl+Alt' }
        @{ Spec = 'V' }
        @{ Spec = 'Ctrl+Alt+V+B' }
        @{ Spec = 'Ctrl+Alt+Nada' }
        @{ Spec = 'Ctrl++V' }
    ) {
        ConvertFrom-HotkeySpec $Spec | Should -BeNullOrEmpty
    }

    It 'los signos llevan su caracter para resolverlos con el teclado' {
        (ConvertFrom-HotkeySpec 'Ctrl+Shift+[').Char | Should -BeExactly '['
        (ConvertFrom-HotkeySpec 'Ctrl+Shift+V').Char | Should -BeExactly ''
    }
}

Describe 'Valores por defecto' {
    It 'todos son validos y no se repiten' {
        $set = Test-HotkeySet (Get-DefaultHotkeys)
        @($set | Where-Object { $_.Problem -ne '' }).Count | Should -Be 0
        $set.Count | Should -Be (Get-HotkeyActions).Count
    }

    It 'leer es Ctrl+Alt+V, que conserva el aire de pegar' {
        (Get-DefaultHotkeys)['read'] | Should -BeExactly 'Ctrl+Alt+V'
    }

    It 'ninguno pisa Ctrl+Shift+V, el de pegar sin formato' {
        foreach ($v in (Get-DefaultHotkeys).Values) { $v | Should -Not -BeExactly 'Ctrl+Shift+V' }
    }
}

Describe 'Get-ConfiguredHotkeys' {
    It 'sin ajustes usa los de fabrica' {
        $h = Get-ConfiguredHotkeys @{}
        $h['read'] | Should -BeExactly 'Ctrl+Alt+V'
    }

    It 'un ajuste cambia solo su accion; vacio la desactiva' {
        $h = Get-ConfiguredHotkeys @{ HotkeyRead = 'Ctrl+Alt+R'; HotkeyStop = '' }
        $h['read'] | Should -BeExactly 'Ctrl+Alt+R'
        $h['stop'] | Should -BeExactly ''
        $h['toggle'] | Should -BeExactly 'Ctrl+Shift+Space'
    }
}

Describe 'Test-HotkeySet' {
    It 'avisa de un atajo repetido, aunque se escriba distinto' {
        $set = Test-HotkeySet ([ordered]@{ read = 'Ctrl+Alt+V'; stop = 'alt+control+v' })
        ($set | Where-Object Action -eq 'read').Problem | Should -BeExactly ''
        ($set | Where-Object Action -eq 'stop').Problem | Should -BeExactly 'duplicate'
    }

    It 'rechaza lo reservado, como Ctrl+Shift+flecha' {
        $set = Test-HotkeySet ([ordered]@{ back = 'Ctrl+Shift+Left'; forward = 'Ctrl+Alt+Delete' })
        ($set | ForEach-Object Problem) | Should -Be @('reserved', 'reserved')
    }

    It 'distingue lo que no se entiende y deja pasar lo desactivado' {
        $set = Test-HotkeySet ([ordered]@{ read = 'Ctrl+Quien'; stop = '' })
        ($set | Where-Object Action -eq 'read').Problem | Should -BeExactly 'invalid'
        ($set | Where-Object Action -eq 'stop').Problem | Should -BeExactly ''
    }
}

Describe 'Get-HotkeyKeyNameFromVk' {
    It 'VK <Vk> con "<Char>" es "<Esperado>"' -ForEach @(
        @{ Vk = 0x56; Char = 'v'; Esperado = 'V' }
        @{ Vk = 0x20; Char = ' '; Esperado = 'Space' }
        @{ Vk = 0x74; Char = ''; Esperado = 'F5' }
        @{ Vk = 0xBC; Char = ','; Esperado = ',' }
        @{ Vk = 0xDD; Char = ']'; Esperado = ']' }
        @{ Vk = 0x25; Char = ''; Esperado = 'Left' }
        @{ Vk = 0xB3; Char = ''; Esperado = 'MediaPlayPause' }
        @{ Vk = 0xC0; Char = 'n'; Esperado = '' }
        @{ Vk = 0x11; Char = ''; Esperado = '' }
    ) {
        Get-HotkeyKeyNameFromVk -Vk $Vk -Char $Char | Should -BeExactly $Esperado
    }
}

Describe 'ConvertFrom-VkKeyScan' {
    It 'VkKeyScan 0x<Scan> da VK 0x<Vk> y modificadores <Mods>' -ForEach @(
        @{ Scan = 0x00BC; Vk = 0xBC; Mods = 0 }
        @{ Scan = 0x01DE; Vk = 0xDE; Mods = 4 }
        @{ Scan = 0x06DB; Vk = 0xDB; Mods = 3 }
        @{ Scan = 0x0141; Vk = 0x41; Mods = 4 }
    ) {
        $r = ConvertFrom-VkKeyScan -Scan $Scan
        $r.Vk | Should -Be $Vk
        $r.Modifiers | Should -Be $Mods
    }
}
