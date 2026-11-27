# Atajos de teclado globales dentro del proceso residente, sin AutoHotkey.
#
# La logica de texto (leer "Ctrl+Alt+V", validar una lista de atajos) no
# toca Windows y se prueba con Pester. Lo que si lo toca (registrar los
# atajos en una ventana, copiar la seleccion) vive en funciones aparte.
#
# Solo ASCII: el archivo se carga tambien desde Windows PowerShell 5.1.

# Todos los atajos de fabrica son Ctrl+Alt y una tecla, para que sean faciles
# de recordar. En los teclados en espanol Ctrl+Alt es AltGr, asi que se
# evitan las teclas que con AltGr escriben algo: Q (la @ del teclado
# latinoamericano), +, las cifras y la E (en el de Espana). Los corchetes
# piden Mayus en esos teclados, y Ctrl+Alt+Space y Ctrl+Alt+M suelen tenerlos
# otros programas. Por eso: X detener, P pausa, coma y punto para moverse, y
# R (rapido) y L (lento) para la velocidad. Ctrl+Alt+T queda para traducir.
$script:RA_HotkeyActions = [ordered]@{
    read    = @{ Setting = 'HotkeyRead';    Default = 'Ctrl+Alt+V'; Label = 'Leer lo seleccionado' }
    stop    = @{ Setting = 'HotkeyStop';    Default = 'Ctrl+Alt+X'; Label = 'Detener' }
    toggle  = @{ Setting = 'HotkeyToggle';  Default = 'Ctrl+Alt+P'; Label = 'Pausar o continuar' }
    back    = @{ Setting = 'HotkeyBack';    Default = 'Ctrl+Alt+,'; Label = 'Retroceder' }
    forward = @{ Setting = 'HotkeyForward'; Default = 'Ctrl+Alt+.'; Label = 'Avanzar' }
    faster  = @{ Setting = 'HotkeyFaster';  Default = 'Ctrl+Alt+R'; Label = 'Subir la velocidad' }
    slower  = @{ Setting = 'HotkeySlower';  Default = 'Ctrl+Alt+L'; Label = 'Bajar la velocidad' }
    translate = @{ Setting = 'HotkeyTranslate'; Default = 'Ctrl+Alt+T'; Label = 'Traducir lo seleccionado' }
}

# Combinaciones que Windows o casi todos los programas ya usan: registrarlas
# rompe algo ajeno. Ctrl+Shift+flechas es la seleccion por palabras.
$script:RA_ReservedHotkeys = @(
    'Ctrl+Shift+Left', 'Ctrl+Shift+Right', 'Ctrl+Shift+Up', 'Ctrl+Shift+Down',
    'Ctrl+Alt+Delete', 'Ctrl+Shift+Escape', 'Alt+F4', 'Alt+Tab', 'Win+L', 'Win+D'
)

function Get-HotkeyActions {
    return $script:RA_HotkeyActions
}

function Get-DefaultHotkeys {
    $map = [ordered]@{}
    foreach ($name in $script:RA_HotkeyActions.Keys) { $map[$name] = $script:RA_HotkeyActions[$name].Default }
    return $map
}

function Get-ConfiguredHotkeys {
    # Accion -> texto del atajo, segun los ajustes. Un ajuste vacio desactiva la
    # accion; uno que falta usa el valor por defecto.
    param($Settings)

    $map = [ordered]@{}
    foreach ($name in $script:RA_HotkeyActions.Keys) {
        $action = $script:RA_HotkeyActions[$name]
        $value = $action.Default
        if ($null -ne $Settings -and $Settings.ContainsKey($action.Setting) -and $null -ne $Settings[$action.Setting]) {
            $value = [string]$Settings[$action.Setting]
        }
        $map[$name] = $value.Trim()
    }
    return $map
}

# Nombre de la tecla -> codigo virtual. Los signos llevan tambien su caracter,
# para resolverlos con la distribucion del teclado al registrar.
function Get-HotkeyKeyTable {
    $t = @{}
    foreach ($c in 65..90) { $t[[string][char]$c] = @{ Vk = $c } }
    foreach ($c in 48..57) { $t[[string][char]$c] = @{ Vk = $c } }
    foreach ($n in 1..24) { $t["F$n"] = @{ Vk = 0x6F + $n } }
    $t['Space'] = @{ Vk = 0x20 }
    $t['Enter'] = @{ Vk = 0x0D }
    $t['Tab'] = @{ Vk = 0x09 }
    $t['Escape'] = @{ Vk = 0x1B }
    $t['Backspace'] = @{ Vk = 0x08 }
    $t['Insert'] = @{ Vk = 0x2D }
    $t['Delete'] = @{ Vk = 0x2E }
    $t['Home'] = @{ Vk = 0x24 }
    $t['End'] = @{ Vk = 0x23 }
    $t['PageUp'] = @{ Vk = 0x21 }
    $t['PageDown'] = @{ Vk = 0x22 }
    $t['Left'] = @{ Vk = 0x25 }
    $t['Up'] = @{ Vk = 0x26 }
    $t['Right'] = @{ Vk = 0x27 }
    $t['Down'] = @{ Vk = 0x28 }
    $t['MediaPlayPause'] = @{ Vk = 0xB3 }
    $t['MediaStop'] = @{ Vk = 0xB2 }
    $t['MediaNext'] = @{ Vk = 0xB0 }
    $t['MediaPrevious'] = @{ Vk = 0xB1 }
    $t[','] = @{ Vk = 0xBC; Char = ',' }
    $t['.'] = @{ Vk = 0xBE; Char = '.' }
    $t['['] = @{ Vk = 0xDB; Char = '[' }
    $t[']'] = @{ Vk = 0xDD; Char = ']' }
    $t['-'] = @{ Vk = 0xBD; Char = '-' }
    $t['='] = @{ Vk = 0xBB; Char = '=' }
    return $t
}

function ConvertFrom-HotkeySpec {
    # "Ctrl+Alt+V" -> @{ Modifiers; Vk; Char; Text }, o $null si no se entiende.
    # Modificadores de RegisterHotKey: Alt 1, Ctrl 2, Shift 4, Win 8.
    param([string]$Spec)

    if ([string]::IsNullOrWhiteSpace($Spec)) { return $null }

    $mods = 0
    $key = $null
    $tokens = @($Spec.Trim() -split '\s*\+\s*(?=.)')

    foreach ($raw in $tokens) {
        $token = $raw.Trim()
        if ($token -eq '') { return $null }
        switch -Regex ($token.ToLowerInvariant()) {
            '^(ctrl|control|ctl)$' { $mods = $mods -bor 2; continue }
            '^alt$'                { $mods = $mods -bor 1; continue }
            '^shift$'              { $mods = $mods -bor 4; continue }
            '^(win|windows|super)$'{ $mods = $mods -bor 8; continue }
            default {
                if ($null -ne $key) { return $null }
                $key = $token
            }
        }
    }

    if ($null -eq $key) { return $null }

    $table = Get-HotkeyKeyTable
    $match = $null
    foreach ($name in $table.Keys) {
        if ($name -ieq $key) { $match = $name; break }
    }
    if ($null -eq $match) { return $null }

    # Una letra o cifra sin modificador se comeria la tecla en todos los
    # programas; las teclas de funcion y multimedia pueden ir solas.
    $solaOk = ($match -match '^F\d+$') -or ($match -like 'Media*')
    if ($mods -eq 0 -and -not $solaOk) { return $null }

    $entry = $table[$match]
    $char = ''
    if ($entry.ContainsKey('Char')) { $char = $entry.Char }

    return @{
        Modifiers = $mods
        Vk        = [int]$entry.Vk
        Char      = $char
        Text      = (Format-HotkeySpec -Modifiers $mods -KeyName $match)
    }
}

function Get-HotkeyKeyNameFromVk {
    # Codigo virtual de una tecla pulsada (y, para los signos, el caracter que
    # escribe con el teclado actual) -> nombre de la tecla en un atajo, o ''.
    param([int]$Vk, [string]$Char = '')

    $table = Get-HotkeyKeyTable
    if ($Char -ne '' -and $table.ContainsKey($Char) -and $table[$Char].ContainsKey('Char')) { return $Char }
    foreach ($name in $table.Keys) {
        if ($table[$name].ContainsKey('Char')) { continue }
        if ([int]$table[$name].Vk -eq $Vk) { return $name }
    }
    return ''
}

function Format-HotkeySpec {
    # Forma canonica: Ctrl+Alt+Shift+Win+Tecla.
    param([int]$Modifiers, [string]$KeyName)

    $parts = New-Object System.Collections.Generic.List[string]
    if ($Modifiers -band 2) { $parts.Add('Ctrl') }
    if ($Modifiers -band 1) { $parts.Add('Alt') }
    if ($Modifiers -band 4) { $parts.Add('Shift') }
    if ($Modifiers -band 8) { $parts.Add('Win') }
    if ($KeyName.Length -eq 1) { $KeyName = $KeyName.ToUpperInvariant() }
    $parts.Add($KeyName)
    return ($parts -join '+')
}

function Test-HotkeySet {
    # Revisa un mapa accion -> texto. Devuelve un objeto por accion con sus
    # problemas: no se entiende, es una combinacion reservada o la repite otra
    # accion. Una accion con el texto vacio esta desactivada y no cuenta.
    param($Hotkeys)

    $reserved = @{}
    foreach ($r in $script:RA_ReservedHotkeys) {
        $p = ConvertFrom-HotkeySpec $r
        if ($p) { $reserved[$p.Text] = $true }
    }

    $seen = @{}
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($name in $Hotkeys.Keys) {
        $text = [string]$Hotkeys[$name]
        $problem = ''
        $canon = ''

        if ($text.Trim() -ne '') {
            $parsed = ConvertFrom-HotkeySpec $text
            if ($null -eq $parsed) {
                $problem = 'invalid'
            } else {
                $canon = $parsed.Text
                if ($reserved.ContainsKey($canon)) {
                    $problem = 'reserved'
                } elseif ($seen.ContainsKey($canon)) {
                    $problem = 'duplicate'
                } else {
                    $seen[$canon] = $name
                }
            }
        }

        $results.Add([pscustomobject]@{ Action = $name; Text = $text; Canonical = $canon; Problem = $problem })
    }

    return ,$results.ToArray()
}

# ---------------------------------------------------------------------------
# Windows: registrar los atajos y copiar la seleccion.
# ---------------------------------------------------------------------------

function Initialize-HotkeyNative {
    if ('ReadAloud.NativeKeys' -as [type]) { return }

    Add-Type -Namespace ReadAloud -Name NativeKeys -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool RegisterHotKey(System.IntPtr hWnd, int id, uint fsModifiers, uint vk);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool UnregisterHotKey(System.IntPtr hWnd, int id);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern short VkKeyScan(char ch);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern short GetAsyncKeyState(int vKey);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint MapVirtualKey(uint uCode, uint uMapType);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetKeyboardLayoutList(int nBuff, System.IntPtr[] lpList);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint MapVirtualKeyEx(uint uCode, uint uMapType, System.IntPtr dwhkl);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int ToUnicodeEx(uint wVirtKey, uint wScanCode, byte[] lpKeyState, System.Text.StringBuilder pwszBuff, int cchBuff, uint wFlags, System.IntPtr dwhkl);
'@
}

function Test-AltGrCombination {
    # Ctrl+Alt (con o sin Mayus, sin Win) es lo mismo que AltGr en los
    # teclados que lo tienen, como los de espanol.
    param([int]$Modifiers)
    return (($Modifiers -band 3) -eq 3) -and (($Modifiers -band 8) -eq 0)
}

function Get-KeyboardLayoutHandles {
    # Las distribuciones de teclado instaladas (HKL). La palabra alta es la
    # distribucion: 0x080A la latinoamericana, 0x040A la de Espana.
    Initialize-HotkeyNative
    $lista = New-Object System.IntPtr[] 32
    $n = [ReadAloud.NativeKeys]::GetKeyboardLayoutList(32, $lista)
    if ($n -le 0) { return @() }
    return $lista[0..($n - 1)]
}

function Get-AltGrCharacter {
    # Lo que escribe AltGr (Ctrl+Alt, y Mayus si se pide) con esa tecla en
    # alguna de las distribuciones de teclado instaladas, o '' si en ninguna
    # escribe nada. Un atajo Ctrl+Alt con esa tecla le quitaria ese caracter al
    # usuario en todos los programas: en el teclado latinoamericano,
    # Ctrl+Alt+Q dejaria sin la @. Una tecla muerta (un acento) tambien cuenta.
    param([int]$Vk, [bool]$Shift = $false)

    Initialize-HotkeyNative
    $estado = New-Object byte[] 256
    foreach ($k in 0x11, 0xA2, 0x12, 0xA5) { $estado[$k] = 0x80 }
    if ($Shift) { foreach ($k in 0x10, 0xA0) { $estado[$k] = 0x80 } }

    foreach ($hkl in (Get-KeyboardLayoutHandles)) {
        $buffer = New-Object Text.StringBuilder 8
        $scan = [ReadAloud.NativeKeys]::MapVirtualKeyEx([uint32]$Vk, 0, $hkl)
        # 4: no cambia el estado de las teclas muertas del teclado.
        $n = [ReadAloud.NativeKeys]::ToUnicodeEx([uint32]$Vk, $scan, $estado, $buffer, 8, 4, $hkl)
        if ($n -eq 0) { continue }
        $texto = $buffer.ToString()
        if ($n -gt 0 -and $texto.Length -ge $n) { $texto = $texto.Substring(0, $n) }
        # Los caracteres de control (Ctrl+letra en un teclado sin AltGr) no
        # se escriben.
        if ($texto -ne '' -and [int][char]$texto[0] -ge 0x20) { return $texto }
    }
    return ''
}

function ConvertFrom-VkKeyScan {
    # El resultado de VkKeyScan (tecla en el byte bajo; en el alto, los
    # modificadores que hacen falta para escribir ese caracter con el teclado
    # actual: 1 Mayus, 2 Ctrl, 4 Alt) -> @{ Vk; Modifiers } con los modificadores
    # de RegisterHotKey (Alt 1, Ctrl 2, Shift 4). En un teclado latinoamericano,
    # "[" se escribe con Mayus: el atajo Ctrl+Alt+[ es entonces Ctrl+Alt+Mayus+tecla.
    param([int]$Scan)

    $state = ($Scan -shr 8) -band 7
    $mods = 0
    if ($state -band 1) { $mods = $mods -bor 4 }
    if ($state -band 2) { $mods = $mods -bor 2 }
    if ($state -band 4) { $mods = $mods -bor 1 }
    return @{ Vk = ($Scan -band 0xFF); Modifiers = $mods }
}

function Register-ReadAloudHotkeys {
    # Registra cada atajo en la ventana. Devuelve, por accion, si quedo activo y
    # el motivo si no: 1409 es que otro programa ya lo tiene; 'altgr', que en
    # el teclado esa combinacion escribe un caracter (Writes).
    param([IntPtr]$Handle, $Hotkeys)

    Initialize-HotkeyNative
    $report = New-Object System.Collections.Generic.List[object]
    $checks = @{}
    foreach ($c in (Test-HotkeySet $Hotkeys)) { $checks[$c.Action] = $c }

    $id = 1
    foreach ($name in $Hotkeys.Keys) {
        $check = $checks[$name]
        $entry = [pscustomobject]@{ Action = $name; Text = $check.Text; Id = $id; Active = $false; Reason = ''; Writes = '' }

        if ($check.Text.Trim() -eq '') {
            $entry.Reason = 'disabled'
        } elseif ($check.Problem -ne '') {
            $entry.Reason = $check.Problem
        } else {
            $parsed = ConvertFrom-HotkeySpec $check.Text
            $vk = $parsed.Vk
            $mods = $parsed.Modifiers
            if ($parsed.Char -ne '') {
                $scan = [ReadAloud.NativeKeys]::VkKeyScan([char]$parsed.Char)
                if ($scan -ne -1) {
                    $layout = ConvertFrom-VkKeyScan -Scan $scan
                    $vk = $layout.Vk
                    $mods = $mods -bor $layout.Modifiers
                }
            }
            # Un Ctrl+Alt que con AltGr escribe un caracter no se registra:
            # el usuario dejaria de poder escribirlo en todos los programas.
            # 0x4000 es MOD_NOREPEAT, para que mantener pulsado no repita la
            # orden.
            $escribe = ''
            if (Test-AltGrCombination -Modifiers $mods) { $escribe = Get-AltGrCharacter -Vk $vk -Shift (($mods -band 4) -ne 0) }
            if ($escribe -ne '') {
                $entry.Reason = 'altgr'
                $entry.Writes = $escribe
            } elseif ([ReadAloud.NativeKeys]::RegisterHotKey($Handle, $id, ([uint32]($mods -bor 0x4000)), [uint32]$vk)) {
                $entry.Active = $true
            } else {
                $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                if ($code -eq 1409) { $entry.Reason = 'in-use' } else { $entry.Reason = "error $code" }
            }
        }

        $report.Add($entry)
        $id++
    }

    return ,$report.ToArray()
}

function Unregister-ReadAloudHotkeys {
    param([IntPtr]$Handle, $Report)

    Initialize-HotkeyNative
    foreach ($e in $Report) {
        if ($e.Active) { [void][ReadAloud.NativeKeys]::UnregisterHotKey($Handle, $e.Id) }
    }
}

function Get-SelectedText {
    # Copia lo seleccionado en la ventana que tiene el foco: espera a que se
    # suelten las teclas del atajo (con Alt pulsado, Ctrl+C no copiaria), manda
    # Ctrl+C y devuelve el texto, dejando el portapapeles como estaba.
    param([int]$TimeoutMs = 700)

    Initialize-HotkeyNative

    # Teclas del atajo: Ctrl 0x11, Alt 0x12, Shift 0x10, Win 0x5B y 0x5C.
    $limit = [DateTime]::Now.AddMilliseconds(600)
    while ([DateTime]::Now -lt $limit) {
        $down = $false
        foreach ($k in 0x10, 0x11, 0x12, 0x5B, 0x5C) {
            if (([ReadAloud.NativeKeys]::GetAsyncKeyState($k) -band 0x8000) -ne 0) { $down = $true }
        }
        if (-not $down) { break }
        Start-Sleep -Milliseconds 15
    }

    $saved = $null
    try {
        $current = [Windows.Clipboard]::GetDataObject()
        if ($null -ne $current) {
            $saved = New-Object Windows.DataObject
            foreach ($format in $current.GetFormats($false)) {
                try {
                    $data = $current.GetData($format, $false)
                    if ($null -ne $data) { $saved.SetData($format, $data, $false) }
                } catch { }
            }
        }
    } catch { }

    # Marca para saber si el portapapeles cambio: si no cambia, no habia seleccion.
    $marker = 'ReadAloud-' + [Guid]::NewGuid().ToString('N')
    try { [Windows.Clipboard]::SetText($marker) } catch { return '' }

    [ReadAloud.NativeKeys]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [ReadAloud.NativeKeys]::keybd_event(0x43, 0, 0, [UIntPtr]::Zero)
    [ReadAloud.NativeKeys]::keybd_event(0x43, 0, 2, [UIntPtr]::Zero)
    [ReadAloud.NativeKeys]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)

    $text = ''
    $limit = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $limit) {
        Start-Sleep -Milliseconds 20
        try {
            if ([Windows.Clipboard]::ContainsText()) {
                $now = [Windows.Clipboard]::GetText()
                if ($now -ne $marker) { $text = $now; break }
            }
        } catch { }
    }

    try {
        if ($null -ne $saved) { [Windows.Clipboard]::SetDataObject($saved, $true) } else { [Windows.Clipboard]::Clear() }
    } catch { }

    return $text
}

function ConvertTo-HotkeyText {
    # De una tecla pulsada en una ventana (codigo virtual + modificadores de
    # RegisterHotKey: Alt 1, Ctrl 2, Shift 4, Win 8) al texto del atajo. Devuelve
    # '' si la tecla no sirve para un atajo (un modificador solo, un signo raro).
    param([int]$Vk, [int]$Modifiers)

    Initialize-HotkeyNative
    $char = ''
    $code = [ReadAloud.NativeKeys]::MapVirtualKey([uint32]$Vk, 2)
    if ($code -gt 0 -and $code -lt 0xFFFF) { $char = [string][char]($code -band 0x7FFF) }

    $name = Get-HotkeyKeyNameFromVk -Vk $Vk -Char $char
    if ($name -eq '') { return '' }
    $parsed = ConvertFrom-HotkeySpec (Format-HotkeySpec -Modifiers $Modifiers -KeyName $name)
    if ($null -eq $parsed) { return '' }
    return $parsed.Text
}
