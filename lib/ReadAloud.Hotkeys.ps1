# Atajos de teclado globales dentro del proceso residente, sin AutoHotkey.
#
# La logica de texto (leer "Ctrl+Alt+V", validar una lista de atajos) no
# toca Windows y se prueba con Pester. Lo que si lo toca (registrar los
# atajos en una ventana, copiar la seleccion) vive en funciones aparte.
#
# Solo ASCII: el archivo se carga tambien desde Windows PowerShell 5.1.

$script:RA_HotkeyActions = [ordered]@{
    read    = @{ Setting = 'HotkeyRead';    Default = 'Ctrl+Alt+V';       Label = 'Leer lo seleccionado' }
    stop    = @{ Setting = 'HotkeyStop';    Default = 'Ctrl+Shift+Q';     Label = 'Detener' }
    toggle  = @{ Setting = 'HotkeyToggle';  Default = 'Ctrl+Shift+Space'; Label = 'Pausar o continuar' }
    back    = @{ Setting = 'HotkeyBack';    Default = 'Ctrl+Shift+,';     Label = 'Retroceder' }
    forward = @{ Setting = 'HotkeyForward'; Default = 'Ctrl+Shift+.';     Label = 'Avanzar' }
    faster  = @{ Setting = 'HotkeyFaster';  Default = 'Ctrl+Shift+]';     Label = 'Subir la velocidad' }
    slower  = @{ Setting = 'HotkeySlower';  Default = 'Ctrl+Shift+[';     Label = 'Bajar la velocidad' }
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
'@
}

function Register-ReadAloudHotkeys {
    # Registra cada atajo en la ventana. Devuelve, por accion, si quedo activo y
    # el motivo si no: 1409 es que otro programa ya lo tiene.
    param([IntPtr]$Handle, $Hotkeys)

    Initialize-HotkeyNative
    $report = New-Object System.Collections.Generic.List[object]
    $checks = @{}
    foreach ($c in (Test-HotkeySet $Hotkeys)) { $checks[$c.Action] = $c }

    $id = 1
    foreach ($name in $Hotkeys.Keys) {
        $check = $checks[$name]
        $entry = [pscustomobject]@{ Action = $name; Text = $check.Text; Id = $id; Active = $false; Reason = '' }

        if ($check.Text.Trim() -eq '') {
            $entry.Reason = 'disabled'
        } elseif ($check.Problem -ne '') {
            $entry.Reason = $check.Problem
        } else {
            $parsed = ConvertFrom-HotkeySpec $check.Text
            $vk = $parsed.Vk
            if ($parsed.Char -ne '') {
                $scan = [ReadAloud.NativeKeys]::VkKeyScan([char]$parsed.Char)
                if ($scan -ne -1) { $vk = $scan -band 0xFF }
            }
            # 0x4000: MOD_NOREPEAT, para que mantener pulsado no repita la orden.
            if ([ReadAloud.NativeKeys]::RegisterHotKey($Handle, $id, ([uint32]($parsed.Modifiers -bor 0x4000)), [uint32]$vk)) {
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
