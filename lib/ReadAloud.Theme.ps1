# Temas de color del reproductor y del panel de ajustes: sistema, oscuro o
# claro, mas un color de acento.
#
# Los dos XAML estan escritos con los colores del tema oscuro. Para el claro, y
# para los acentos, no se duplican: Convert-XamlTheme sustituye esos colores
# (una sola pasada) por los del tema elegido antes de cargar la ventana. Todo
# lo de aqui es texto en, texto fuera, y se prueba con Pester.
#
# Solo ASCII: el archivo se carga tambien desde Windows PowerShell 5.1.

# Acentos: Text se ve sobre fondo oscuro, TextLight sobre claro, Base es el
# color pleno (relleno de pastillas, fader) y Soft el texto sobre el relleno.
$script:RA_Accents = [ordered]@{
    green  = @{ Label = 'Verde';    Text = '#9AE6B4'; TextLight = '#1E7A4D'; Base = '#4ADE80'; BaseLight = '#16A34A'; Soft = '#C6F6D5'; SoftLight = '#14532D' }
    blue   = @{ Label = 'Azul';     Text = '#93C5FD'; TextLight = '#1D4ED8'; Base = '#60A5FA'; BaseLight = '#2563EB'; Soft = '#DBEAFE'; SoftLight = '#1E3A8A' }
    purple = @{ Label = 'Violeta';  Text = '#D8B4FE'; TextLight = '#7E22CE'; Base = '#A855F7'; BaseLight = '#9333EA'; Soft = '#F3E8FF'; SoftLight = '#581C87' }
    pink   = @{ Label = 'Rosa';     Text = '#F9A8D4'; TextLight = '#BE185D'; Base = '#EC4899'; BaseLight = '#DB2777'; Soft = '#FCE7F3'; SoftLight = '#831843' }
    orange = @{ Label = 'Naranja';  Text = '#FDBA74'; TextLight = '#C2410C'; Base = '#F97316'; BaseLight = '#EA580C'; Soft = '#FFEDD5'; SoftLight = '#7C2D12' }
    red    = @{ Label = 'Rojo';     Text = '#FCA5A5'; TextLight = '#B91C1C'; Base = '#EF4444'; BaseLight = '#DC2626'; Soft = '#FEE2E2'; SoftLight = '#7F1D1D' }
    teal   = @{ Label = 'Turquesa'; Text = '#5EEAD4'; TextLight = '#0F766E'; Base = '#14B8A6'; BaseLight = '#0D9488'; Soft = '#CCFBF1'; SoftLight = '#134E4A' }
    yellow = @{ Label = 'Amarillo'; Text = '#FDE68A'; TextLight = '#A16207'; Base = '#EAB308'; BaseLight = '#CA8A04'; Soft = '#FEF9C3'; SoftLight = '#713F12' }
}

function Get-ThemeAccents {
    return $script:RA_Accents
}

function Resolve-ThemeMode {
    # 'system' sigue a Windows; cualquier otra cosa que no sea 'light' es oscuro.
    param([string]$Mode, [bool]$SystemLight = $false)

    switch ($Mode.Trim().ToLowerInvariant()) {
        'light' { return 'light' }
        'system' { if ($SystemLight) { return 'light' } else { return 'dark' } }
        default { return 'dark' }
    }
}

function Test-SystemLightTheme {
    # Windows guarda 1 en AppsUseLightTheme cuando las aplicaciones usan el tema claro.
    try {
        $v = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
        return ($v -eq 1)
    } catch {
        return $false
    }
}

function Get-ThemePalette {
    # Los colores del tema en una tabla. Con modo oscuro y acento verde (lo de
    # fabrica) son exactamente los de siempre.
    param([string]$Mode = 'dark', [string]$Accent = 'green')

    $a = $script:RA_Accents[$Accent.Trim().ToLowerInvariant()]
    if ($null -eq $a) { $a = $script:RA_Accents['green'] }
    $light = ($Mode -eq 'light')

    if ($light) {
        return @{
            Mode = 'light'
            PanelBg = '#F2F6F6F8'; PopupBg = '#F8F6F6F8'; SettingsBg = '#F7F6F6F8'; TextPanelBg = '#FFFFFFFF'
            Text1 = '#1F1F24'; Text2 = '#2A2A30'; Text3 = '#33333A'; Text4 = '#4A4A52'
            TextDim = '#8A8A94'; TextNote = '#6B6B75'; TextCurrent = '#000000'; TextOnButton = '#1F1F24'
            Overlay = '000000'
            AccentText = $a.TextLight; AccentBase = $a.BaseLight; AccentSoft = $a.SoftLight
            Warning = '#B45309'
        }
    }
    return @{
        Mode = 'dark'
        PanelBg = '#F21B1B1F'; PopupBg = '#F81B1B1F'; SettingsBg = '#F71B1B1F'; TextPanelBg = '#FF26262B'
        Text1 = '#E6E6EA'; Text2 = '#D8D8DC'; Text3 = '#D0D0D6'; Text4 = '#C8C8CC'
        TextDim = '#7C7C84'; TextNote = '#8A8A94'; TextCurrent = '#FFFFFF'; TextOnButton = 'White'
        Overlay = 'FFFFFF'
        AccentText = $a.Text; AccentBase = $a.Base; AccentSoft = $a.Soft
        Warning = '#F6C177'
    }
}

function Get-ThemeColorMap {
    # Color escrito en el XAML (tema oscuro, acento verde) -> color del tema.
    param($Palette)

    $m = @{}
    $m['#F21B1B1F'] = $Palette.PanelBg
    $m['#F81B1B1F'] = $Palette.PopupBg
    $m['#F71B1B1F'] = $Palette.SettingsBg
    $m['#FF26262B'] = $Palette.TextPanelBg
    $m['#E6E6EA'] = $Palette.Text1
    $m['#D8D8DC'] = $Palette.Text2
    $m['#D0D0D6'] = $Palette.Text3
    $m['#C8C8CC'] = $Palette.Text4
    $m['#7C7C84'] = $Palette.TextDim
    $m['#8A8A94'] = $Palette.TextNote
    $m['#FFFFFF'] = $Palette.TextCurrent
    $m['#F6C177'] = $Palette.Warning
    $m['#9AE6B4'] = $Palette.AccentText
    $m['#C6F6D5'] = $Palette.AccentSoft

    # Los velos translucidos (blanco sobre oscuro) pasan a negro sobre claro,
    # con la misma transparencia.
    foreach ($alpha in '14', '26', '2E', '33', '3A', '4D', '55', '80') {
        $m["#${alpha}FFFFFF"] = "#$alpha$($Palette.Overlay)"
    }

    # El relleno de la pastilla elegida: el verde de fabrica con transparencia.
    $base = $Palette.AccentBase.TrimStart('#')
    $m['#334ADE80'] = "#33$base"
    $m['#8C4ADE80'] = "#8C$base"
    return $m
}

function Convert-XamlTheme {
    # Una sola pasada: el resultado de una sustitucion no vuelve a sustituirse.
    param([string]$Xaml, $Palette)

    $map = Get-ThemeColorMap $Palette

    $text = [regex]::Replace($Xaml, '#[0-9A-Fa-f]{6,8}\b', [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $key = $match.Value.ToUpperInvariant()
        if ($map.ContainsKey($key)) { return $map[$key] }
        return $match.Value
    })

    # Los textos de los botones del reproductor estan escritos con "White".
    $text = [regex]::Replace($text, '(Foreground|Fill)="White"', ('$1="' + $Palette.TextOnButton + '"'))
    return $text
}

function Get-RuntimeColors {
    # Los colores que el programa pone por codigo (texto leido, por leer...).
    param($Palette)

    $light = ($Palette.Mode -eq 'light')
    $elegido = $(if ($light) { '#2E000000' } else { '#2EFFFFFF' })
    return @{
        Pendiente = $Palette.Text3
        Leido     = $Palette.TextDim
        Actual    = $Palette.TextCurrent
        Fondo     = '#663B82F6'
        Encendido = $Palette.AccentText
        Apagado   = $Palette.Text4
        Texto     = $Palette.Text2
        Elegido   = $elegido
    }
}

function ConvertTo-DynamicXaml {
    # Para cambiar de tema con la ventana abierta: cada color del tema escrito
    # en el XAML pasa a ser un recurso dinamico ({DynamicResource T_...}) y se
    # agrega al diccionario de la ventana con su valor de fabrica. Despues
    # Set-ThemeResources cambia el valor de esos recursos y la ventana se
    # repinta sola. Los colores que no son del tema se dejan como estan.
    param([string]$Xaml)

    $map = Get-ThemeColorMap (Get-ThemePalette -Mode 'dark' -Accent 'green')
    $keys = @{}

    $text = [regex]::Replace($Xaml, '(?<=")#[0-9A-Fa-f]{6,8}(?=")', [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $hex = $match.Value.ToUpperInvariant()
        if ($map.ContainsKey($hex)) {
            $keys[$hex] = $true
            return '{DynamicResource T_' + $hex.TrimStart('#') + '}'
        }
        return $match.Value
    })

    $text = [regex]::Replace($text, '(Foreground|Fill)="White"', [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        return $match.Groups[1].Value + '="{DynamicResource T_White}"'
    })

    $brushes = New-Object System.Collections.Generic.List[string]
    foreach ($hex in $keys.Keys) {
        $brushes.Add(('    <SolidColorBrush x:Key="T_{0}" Color="{1}"/>' -f $hex.TrimStart('#'), $hex))
    }
    $brushes.Add('    <SolidColorBrush x:Key="T_White" Color="#FFFFFF"/>')

    return $text.Replace('<Window.Resources>', ('<Window.Resources>' + [Environment]::NewLine + ($brushes -join [Environment]::NewLine)))
}

function Set-ThemeResources {
    # Cambia el valor de los recursos T_... de una ventana por los del tema.
    param($Resources, $Palette)

    $map = Get-ThemeColorMap $Palette
    $convert = New-Object Windows.Media.BrushConverter
    foreach ($hex in $map.Keys) {
        $key = 'T_' + $hex.TrimStart('#')
        if ($Resources.Contains($key)) { $Resources[$key] = $convert.ConvertFromString($map[$hex]) }
    }
    if ($Resources.Contains('T_White')) {
        $white = $Palette.TextOnButton
        if ($white -eq 'White') { $white = '#FFFFFF' }
        $Resources['T_White'] = $convert.ConvertFromString($white)
    }
}

function Save-AppIconFile {
    # Escribe el icono de Read Aloud (un circulo con el simbolo de volumen) como
    # .ico con imagenes PNG de 16, 32, 48 y 256 px. Se dibuja aqui, igual que el
    # de la bandeja, para no llevar un archivo binario en el repositorio.
    param([string]$Path, [string]$Color = '#2E8B6A')

    Add-Type -AssemblyName System.Drawing

    $images = New-Object System.Collections.Generic.List[object]
    foreach ($size in 16, 32, 48, 256) {
        $bmp = New-Object Drawing.Bitmap $size, $size
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'AntiAlias'
        $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml($Color))), 0.03 * $size, 0.03 * $size, 0.94 * $size, 0.94 * $size)
        $font = New-Object Drawing.Font('Segoe MDL2 Assets', [single](0.47 * $size), [Drawing.GraphicsUnit]::Pixel)
        $format = New-Object Drawing.StringFormat
        $format.Alignment = 'Center'
        $format.LineAlignment = 'Center'
        $g.DrawString([string][char]0xE767, $font, [Drawing.Brushes]::White, ([Drawing.RectangleF]::new(0, 0.03 * $size, $size, $size)), $format)
        $g.Dispose()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $images.Add(@{ Size = $size; Bytes = $ms.ToArray() })
        $bmp.Dispose()
        $ms.Dispose()
    }

    $out = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter $out
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$images.Count)
    $offset = 6 + 16 * $images.Count
    foreach ($img in $images) {
        $dim = $(if ($img.Size -ge 256) { 0 } else { $img.Size })
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$img.Bytes.Length); $w.Write([uint32]$offset)
        $offset += $img.Bytes.Length
    }
    foreach ($img in $images) { $w.Write($img.Bytes) }
    $w.Flush()

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllBytes($Path, $out.ToArray())
}
