#
# ReadAloud.Settings.ps1
# Panel de ajustes del reproductor: el boton de la tuerca. Lo carga
# read_aloud_daemon.ps1 despues de armar el reproductor, y usa sus variables
# ($ui, $settings, $paths, $engines, $qwenVoice...) y sus funciones.
#
# Lo que se cambia aqui se guarda solo en runtime\ajustes.json, que manda
# sobre config\settings.psd1 (Get-ReadAloudSettings). La apariencia y la
# lectura se aplican al momento. La voz, el rendimiento y la pausa entre
# frases van a los procesos de sintesis, que se abren al arrancar: se aplican
# al reiniciar el lector, y el panel ofrece hacerlo.
#
# Este archivo va guardado con BOM: sin el, Windows PowerShell lo lee como
# ANSI y los acentos de los textos salen rotos.

$xamlAjustes = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Ajustes de Read Aloud"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight" ResizeMode="NoResize">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#E6E6EA"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Fondo" Background="{TemplateBinding Background}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Fondo" Property="Background" Value="#2EFFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Fondo" Property="Background" Value="#4DFFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Cada opcion es una pastilla: se ve de un vistazo cual esta elegida, y
         no hace falta abrir una lista como con un ComboBox, que ademas viene
         claro y desentona sobre el fondo oscuro. -->
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#D8D8DC"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Fondo" Background="#14FFFFFF" BorderBrush="#26FFFFFF" BorderThickness="1"
                    CornerRadius="6" Padding="10,4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Fondo" Property="Background" Value="#26FFFFFF"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Fondo" Property="Background" Value="#334ADE80"/>
                <Setter TargetName="Fondo" Property="BorderBrush" Value="#8C4ADE80"/>
                <Setter Property="Foreground" Value="#C6F6D5"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="MinWidth" Value="6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border Background="#55FFFFFF" CornerRadius="3"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Seccion" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#9AE6B4"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,16,0,4"/>
    </Style>
    <Style x:Key="Etiqueta" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#E6E6EA"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,8,0,5"/>
    </Style>
    <Style x:Key="Valor" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#C8C8CC"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="TextAlignment" Value="Right"/>
    </Style>
    <Style x:Key="Campo" TargetType="TextBox">
      <Setter Property="Background" Value="#14FFFFFF"/>
      <Setter Property="Foreground" Value="#E6E6EA"/>
      <Setter Property="CaretBrush" Value="#E6E6EA"/>
      <Setter Property="BorderBrush" Value="#26FFFFFF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Margin" Value="0,0,0,2"/>
    </Style>
    <Style x:Key="Nota" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8A8A94"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,0,0,2"/>
    </Style>
  </Window.Resources>

  <Border Background="#F71B1B1F" BorderBrush="#33FFFFFF" BorderThickness="1" CornerRadius="10"
          Padding="16,10,8,14" Width="420" Margin="12">
    <Border.Effect>
      <DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.5" Color="#000000"/>
    </Border.Effect>
    <StackPanel>
      <Grid x:Name="Titulo" Background="Transparent" Margin="0,0,8,0" Cursor="SizeAll">
        <TextBlock Text="Ajustes" Foreground="#E6E6EA" FontFamily="Segoe UI" FontSize="15"
                   FontWeight="SemiBold" VerticalAlignment="Center"/>
        <Button x:Name="Cerrar" Content="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="11"
                Width="26" Height="26" HorizontalAlignment="Right" Foreground="#C8C8CC" ToolTip="Cerrar"/>
      </Grid>

      <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="0,0,10,0">

          <TextBlock Style="{StaticResource Seccion}" Text="APARIENCIA"/>

          <TextBlock Style="{StaticResource Etiqueta}" Text="Tema"/>
          <WrapPanel>
            <RadioButton GroupName="Tema" Tag="system" Content="Como Windows"/>
            <RadioButton GroupName="Tema" Tag="dark" Content="Oscuro"/>
            <RadioButton GroupName="Tema" Tag="light" Content="Claro"/>
          </WrapPanel>
          <TextBlock Style="{StaticResource Etiqueta}" Text="Color de acento"/>
          <WrapPanel>
            <RadioButton GroupName="Acento" Tag="green" Content="Verde"/>
            <RadioButton GroupName="Acento" Tag="blue" Content="Azul"/>
            <RadioButton GroupName="Acento" Tag="purple" Content="Violeta"/>
            <RadioButton GroupName="Acento" Tag="pink" Content="Rosa"/>
            <RadioButton GroupName="Acento" Tag="orange" Content="Naranja"/>
            <RadioButton GroupName="Acento" Tag="red" Content="Rojo"/>
            <RadioButton GroupName="Acento" Tag="teal" Content="Turquesa"/>
            <RadioButton GroupName="Acento" Tag="yellow" Content="Amarillo"/>
          </WrapPanel>
          <TextBlock Style="{StaticResource Nota}" Text="El tema y el acento se aplican al reiniciar el lector."/>

          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="150"/><ColumnDefinition Width="*"/><ColumnDefinition Width="56"/>
            </Grid.ColumnDefinitions>
            <TextBlock Style="{StaticResource Etiqueta}" Text="Opacidad en reposo"/>
            <Slider x:Name="Opacidad" Grid.Column="1" Minimum="0.3" Maximum="1" TickFrequency="0.05"
                    IsSnapToTickEnabled="True" VerticalAlignment="Center"/>
            <TextBlock x:Name="OpacidadValor" Grid.Column="2" Style="{StaticResource Valor}"/>
          </Grid>
          <TextBlock Style="{StaticResource Nota}"
                     Text="Al hacer clic sobre el reproductor se vuelve opaco del todo."/>

          <TextBlock Style="{StaticResource Etiqueta}" Text="Tamaño del reproductor"/>
          <WrapPanel>
            <RadioButton GroupName="Escala" Tag="0.9" Content="90 %"/>
            <RadioButton GroupName="Escala" Tag="1" Content="100 %"/>
            <RadioButton GroupName="Escala" Tag="1.15" Content="115 %"/>
            <RadioButton GroupName="Escala" Tag="1.3" Content="130 %"/>
            <RadioButton GroupName="Escala" Tag="1.5" Content="150 %"/>
          </WrapPanel>

          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="150"/><ColumnDefinition Width="*"/><ColumnDefinition Width="56"/>
            </Grid.ColumnDefinitions>
            <TextBlock Style="{StaticResource Etiqueta}" Text="Letra del texto"/>
            <Slider x:Name="Fuente" Grid.Column="1" Minimum="10" Maximum="22" TickFrequency="1"
                    IsSnapToTickEnabled="True" VerticalAlignment="Center"/>
            <TextBlock x:Name="FuenteValor" Grid.Column="2" Style="{StaticResource Valor}"/>
          </Grid>

          <TextBlock Style="{StaticResource Etiqueta}" Text="Panel de texto al aparecer"/>
          <WrapPanel>
            <RadioButton GroupName="Panel" Tag="recordar" Content="Como lo dejé"/>
            <RadioButton GroupName="Panel" Tag="abierto" Content="Abierto"/>
            <RadioButton GroupName="Panel" Tag="cerrado" Content="Cerrado"/>
          </WrapPanel>

          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="150"/><ColumnDefinition Width="*"/><ColumnDefinition Width="56"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
            <TextBlock Style="{StaticResource Etiqueta}" Text="Alto del panel"/>
            <Slider x:Name="PanelAlto" Grid.Column="1" Minimum="80" Maximum="700" TickFrequency="10"
                    IsSnapToTickEnabled="True" VerticalAlignment="Center"/>
            <TextBlock x:Name="PanelAltoValor" Grid.Column="2" Style="{StaticResource Valor}"/>
            <TextBlock Grid.Row="1" Style="{StaticResource Etiqueta}" Text="Ancho del panel"/>
            <Slider x:Name="PanelAncho" Grid.Row="1" Grid.Column="1" Maximum="1400" TickFrequency="10"
                    IsSnapToTickEnabled="True" VerticalAlignment="Center"/>
            <TextBlock x:Name="PanelAnchoValor" Grid.Row="1" Grid.Column="2" Style="{StaticResource Valor}"/>
          </Grid>
          <TextBlock Style="{StaticResource Nota}" Text="También se cambia arrastrando los bordes del reproductor."/>

          <TextBlock Style="{StaticResource Seccion}" Text="VOZ"/>

          <TextBlock Style="{StaticResource Etiqueta}" Text="Motor de voz"/>
          <WrapPanel>
            <RadioButton GroupName="Motor" Tag="auto" Content="Automático"
                         ToolTip="La voz propia si está instalada y la tarjeta alcanza; si no, Piper"/>
            <RadioButton x:Name="MotorQwen" GroupName="Motor" Tag="qwen" Content="Voz propia (Qwen)"/>
            <RadioButton GroupName="Motor" Tag="piper" Content="Piper"/>
          </WrapPanel>
          <TextBlock x:Name="MotorNota" Style="{StaticResource Nota}"/>

          <TextBlock Style="{StaticResource Etiqueta}" Text="Voz de Piper en español"/>
          <WrapPanel x:Name="VocesEs"/>
          <TextBlock Style="{StaticResource Etiqueta}" Text="Voz de Piper en inglés"/>
          <WrapPanel x:Name="VocesEn"/>
          <TextBlock Style="{StaticResource Nota}"
                     Text="Piper lee cuando no hay voz propia y mientras otro paso ocupa la tarjeta gráfica."/>

          <TextBlock Style="{StaticResource Etiqueta}" Text="Rendimiento"/>
          <WrapPanel>
            <RadioButton GroupName="Rendimiento" Tag="rapido" Content="Rápido"/>
            <RadioButton GroupName="Rendimiento" Tag="ahorro" Content="Ahorro de recursos"/>
          </WrapPanel>
          <TextBlock x:Name="RendimientoNota" Style="{StaticResource Nota}"/>
          <StackPanel x:Name="MinutosFila">
            <TextBlock Style="{StaticResource Etiqueta}" Text="Liberar la voz tras este tiempo sin leer"/>
            <WrapPanel>
              <RadioButton GroupName="Minutos" Tag="2" Content="2 min"/>
              <RadioButton GroupName="Minutos" Tag="5" Content="5 min"/>
              <RadioButton GroupName="Minutos" Tag="10" Content="10 min"/>
              <RadioButton GroupName="Minutos" Tag="30" Content="30 min"/>
            </WrapPanel>
          </StackPanel>

          <TextBlock Style="{StaticResource Seccion}" Text="LECTURA"/>

          <TextBlock Style="{StaticResource Etiqueta}" Text="Cerrar el reproductor al terminar"/>
          <WrapPanel>
            <RadioButton GroupName="Cerrar" Tag="True" Content="Sí"/>
            <RadioButton GroupName="Cerrar" Tag="False" Content="No"/>
          </WrapPanel>

          <TextBlock Style="{StaticResource Etiqueta}" Text="Salto de los botones de retroceder y avanzar"/>
          <WrapPanel>
            <RadioButton GroupName="Salto" Tag="5" Content="5 s"/>
            <RadioButton GroupName="Salto" Tag="10" Content="10 s"/>
            <RadioButton GroupName="Salto" Tag="15" Content="15 s"/>
            <RadioButton GroupName="Salto" Tag="30" Content="30 s"/>
          </WrapPanel>

          <TextBlock Style="{StaticResource Etiqueta}" Text="Idioma si el texto es corto o ambiguo"/>
          <WrapPanel>
            <RadioButton GroupName="Idioma" Tag="es" Content="Español"/>
            <RadioButton GroupName="Idioma" Tag="en" Content="Inglés"/>
          </WrapPanel>

          <Grid Margin="0,4,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="150"/><ColumnDefinition Width="*"/><ColumnDefinition Width="56"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
            <TextBlock Style="{StaticResource Etiqueta}" Text="Pausa entre frases"/>
            <Slider x:Name="PausaFrase" Grid.Column="1" Minimum="0" Maximum="1" TickFrequency="0.02"
                    IsSnapToTickEnabled="True" VerticalAlignment="Center"/>
            <TextBlock x:Name="PausaFraseValor" Grid.Column="2" Style="{StaticResource Valor}"/>
            <TextBlock Grid.Row="1" Style="{StaticResource Etiqueta}" Text="Pausa entre párrafos"/>
            <Slider x:Name="PausaParrafo" Grid.Row="1" Grid.Column="1" Minimum="0" Maximum="1.5"
                    TickFrequency="0.05" IsSnapToTickEnabled="True" VerticalAlignment="Center"/>
            <TextBlock x:Name="PausaParrafoValor" Grid.Row="1" Grid.Column="2" Style="{StaticResource Valor}"/>
          </Grid>
          <TextBlock Style="{StaticResource Nota}"
                     Text="La pausa entre párrafos se nota desde la próxima lectura; la de entre frases, al reiniciar."/>

          <TextBlock Style="{StaticResource Seccion}" Text="PRONUNCIACIÓN"/>
          <TextBlock Style="{StaticResource Nota}"
                     Text="Si una palabra en inglés (o una sigla) suena mal, escribe cómo debería sonar con ortografía española y pulsa Probar. Guardar la aplica a las próximas lecturas, sin reiniciar."/>
          <TextBlock Style="{StaticResource Etiqueta}" Text="Palabra"/>
          <TextBox x:Name="TerminoPalabra" Style="{StaticResource Campo}"/>
          <TextBlock Style="{StaticResource Etiqueta}" Text="Cómo se dice (Piper y, si no hay otra, la voz propia)"/>
          <TextBox x:Name="TerminoDice" Style="{StaticResource Campo}"/>
          <TextBlock Style="{StaticResource Etiqueta}" Text="Cómo se dice con la voz propia (opcional)"/>
          <TextBox x:Name="TerminoDiceQwen" Style="{StaticResource Campo}"/>
          <WrapPanel Margin="0,8,0,0">
            <Button x:Name="BtnTerminoProbar" Content="Probar" Padding="12,5" Margin="0,0,6,6" Background="#14FFFFFF"/>
            <Button x:Name="BtnTerminoGuardar" Content="Guardar" Padding="12,5" Margin="0,0,6,6" Background="#333B82F6"/>
            <Button x:Name="BtnTerminoQuitar" Content="Quitar el mío" Padding="12,5" Margin="0,0,6,6" Background="#14FFFFFF"
                    ToolTip="Quita tu corrección y vuelve a la del diccionario de fábrica"/>
          </WrapPanel>
          <TextBlock x:Name="TerminoNota" Style="{StaticResource Nota}" Visibility="Collapsed"/>

          <TextBlock Style="{StaticResource Seccion}" Text="ATAJOS DE TECLADO"/>
          <TextBlock x:Name="AtajosLista" Style="{StaticResource Etiqueta}" FontFamily="Consolas"
                     TextWrapping="Wrap" Margin="0,2,0,6"/>
          <TextBlock Style="{StaticResource Nota}"
                     Text="Selecciona texto en cualquier programa y pulsa el atajo de leer. Para cambiarlos, escribe por ejemplo HotkeyRead = 'Ctrl+Alt+R' en config\settings.local.psd1 y reinicia el lector (ver docs\configuracion.md). Un valor vacío desactiva el atajo."/>
          <TextBlock x:Name="AtajosAviso" Style="{StaticResource Nota}" Foreground="#F6C177"
                     Visibility="Collapsed" Margin="0,4,0,0"/>

          <TextBlock Style="{StaticResource Seccion}" Text="ACERCA DE"/>
          <TextBlock x:Name="AcercaVersion" Style="{StaticResource Etiqueta}" Margin="0,2,0,4"/>
          <TextBlock Style="{StaticResource Nota}"
                     Text="Gratis y de código abierto. ¿Encontraste un error o tienes una idea? Abre una incidencia en GitHub o escribe a duqueortegamutis@gmail.com."/>
          <WrapPanel Margin="0,8,0,0">
            <Button x:Name="BtnDiagnostico" Content="Copiar diagnóstico" Padding="12,5" Margin="0,0,6,6"
                    Background="#14FFFFFF"
                    ToolTip="Copia un resumen (versión, motores, atajos y registro) para pegarlo en una incidencia"/>
            <Button x:Name="BtnActualizar" Content="Buscar actualizaciones" Padding="12,5" Margin="0,0,6,6"
                    Background="#14FFFFFF"
                    ToolTip="Consulta GitHub solo ahora; Read Aloud no consulta nada por su cuenta"/>
            <Button x:Name="BtnGitHub" Content="Abrir GitHub" Padding="12,5" Margin="0,0,6,6"
                    Background="#14FFFFFF"/>
          </WrapPanel>
          <TextBlock x:Name="ActualizarNota" Style="{StaticResource Nota}" Visibility="Collapsed"/>
          <Button x:Name="BtnInstalarUpdate" Content="Descargar e instalar" Padding="12,5" Margin="0,6,0,0"
                  HorizontalAlignment="Left" Background="#333B82F6" Visibility="Collapsed"/>
        </StackPanel>
      </ScrollViewer>

      <Border x:Name="Reinicio" Visibility="Collapsed" Background="#263B82F6" BorderBrush="#663B82F6"
              BorderThickness="1" CornerRadius="6" Padding="10,8" Margin="0,14,8,0">
        <StackPanel>
          <TextBlock Style="{StaticResource Nota}" Foreground="#D0D0D6"
                     Text="Los cambios de voz, rendimiento o pausa entre frases se aplican al reiniciar el lector. Tarda unos segundos; si está leyendo, la lectura se corta."/>
          <Button x:Name="ReiniciarAhora" Content="Reiniciar ahora" Padding="12,5" Margin="0,6,0,0"
                  HorizontalAlignment="Left" Background="#333B82F6"/>
        </StackPanel>
      </Border>

      <Grid Margin="0,14,8,0">
        <Button x:Name="Restablecer" Content="Restablecer todo" Padding="12,5" HorizontalAlignment="Left"
                Background="#14FFFFFF" ToolTip="Vuelve a los valores de config\settings.psd1"/>
        <TextBlock Style="{StaticResource Nota}" Text="Los cambios se guardan solos." HorizontalAlignment="Right"
                   VerticalAlignment="Center" Margin="0"/>
      </Grid>
    </StackPanel>
  </Border>
</Window>
'@

$xamlAjustes = Convert-XamlTheme -Xaml $xamlAjustes -Palette $script:paleta
$ajustesVentana = [Windows.Markup.XamlReader]::Load([Xml.XmlReader]::Create((New-Object IO.StringReader($xamlAjustes))))
$aj = @{}
foreach ($nombre in @('Titulo', 'Cerrar', 'Scroll', 'Opacidad', 'OpacidadValor', 'Fuente', 'FuenteValor',
                      'PanelAlto', 'PanelAltoValor', 'PanelAncho', 'PanelAnchoValor', 'MotorQwen', 'MotorNota',
                      'VocesEs', 'VocesEn', 'RendimientoNota', 'MinutosFila', 'PausaFrase', 'PausaFraseValor',
                      'PausaParrafo', 'PausaParrafoValor', 'Reinicio', 'ReiniciarAhora', 'Restablecer',
                      'AtajosLista', 'AtajosAviso', 'AcercaVersion', 'BtnDiagnostico', 'BtnActualizar', 'BtnGitHub',
                      'ActualizarNota', 'BtnInstalarUpdate',
                      'TerminoPalabra', 'TerminoDice', 'TerminoDiceQwen', 'BtnTerminoProbar', 'BtnTerminoGuardar',
                      'BtnTerminoQuitar', 'TerminoNota')) {
    $aj[$nombre] = $ajustesVentana.FindName($nombre)
}

$invariante = [Globalization.CultureInfo]::InvariantCulture
# Mientras el panel se llena con los valores actuales, los cambios de los
# controles no se guardan: solo los que hace el usuario.
$script:cargandoAjustes = $false

function Save-Ajuste {
    param([string]$Nombre, $Valor, [switch]$Reinicio)

    $settings[$Nombre] = $Valor
    try {
        Save-UserSetting -Paths $paths -Name $Nombre -Value $Valor
    } catch {
        Write-DaemonLog "No pude guardar el ajuste ${Nombre}: $($_.Exception.Message)"
    }
    if ($Reinicio) { $aj.Reinicio.Visibility = 'Visible' }
}

function Restart-Lector {
    # El proceso nuevo espera a que este termine (-EsperarA), porque solo
    # puede haber uno. Al salir, los procesos de Piper y de Qwen ven cerrada
    # su entrada y terminan solos.
    Save-PlayerState
    Write-DaemonLog 'Reinicio pedido desde los ajustes.'
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $paths.DaemonScript + '"'), '-EsperarA', $PID)
    [Environment]::Exit(0)
}

function Update-SkipLabels {
    $n = [int][double]$settings.SkipSeconds
    $ui.BtnBack.Content = "-$n"
    $ui.BtnFwd.Content = "+$n"
    $ui.BtnBack.ToolTip = "Retroceder $n segundos"
    $ui.BtnFwd.ToolTip = "Avanzar $n segundos"
}

function Update-MotorNota {
    $minimo = [double]$settings.QwenMinVramGB
    if (-not $qwenVoice.Ready) {
        $aj.MotorQwen.IsEnabled = $false
        $aj.MotorNota.Text = 'No hay voz propia instalada (docs\voz-personalizada.md): se lee con Piper.'
    } elseif ($vramGB -lt $minimo) {
        $aj.MotorQwen.IsEnabled = $false
        $aj.MotorNota.Text = ('La tarjeta gráfica tiene {0:N1} GB y la voz propia pide {1}: se lee con Piper.' -f $vramGB, $minimo)
    } elseif ($engines['es'] -eq 'qwen') {
        $aj.MotorNota.Text = 'Ahora lee con la voz propia.'
    } else {
        $aj.MotorNota.Text = 'Ahora lee con Piper.'
    }
}

function Update-RendimientoNota {
    $ahorroElegido = ([string]$settings.Performance) -eq 'ahorro'
    $aj.MinutosFila.Visibility = $(if ($ahorroElegido) { 'Visible' } else { 'Collapsed' })
    if (-not ($qwenVoice.Ready -and $vramGB -ge [double]$settings.QwenMinVramGB)) {
        $aj.RendimientoNota.Text = 'Solo cambia algo con la voz propia: Piper apenas usa recursos.'
    } elseif ($ahorroElegido) {
        $aj.RendimientoNota.Text = 'La voz propia se carga al leer (la primera lectura espera unos 20 s) y se libera tras el tiempo de abajo sin leer. Sin lecturas no ocupa la tarjeta ni la memoria.'
    } else {
        $aj.RendimientoNota.Text = 'La voz propia queda cargada: cada lectura empieza en 1 o 2 s. Ocupa unos 5 GB de la tarjeta y 2,3 GB de RAM, y los cede si otro programa los necesita.'
    }
}

function Update-PlayerLayout {
    if ($window.IsVisible) {
        $window.UpdateLayout()
        Set-PlayerPosition
    }
}

function Set-PanelSize {
    param([double]$Alto = 0, [double]$Ancho = 0)
    if ($Alto -gt 0) { $ui.TextPanel.Height = $Alto; $script:panelAlto = $Alto }
    if ($Ancho -gt 0) { $ui.TextPanel.Width = $Ancho; $script:panelAncho = $Ancho }
    Update-PlayerLayout
    Save-PlayerState
}

# --------------------------------------------------------------------------
# Opciones de pastilla: cada grupo es un ajuste. Tag es el valor de cada una.
# --------------------------------------------------------------------------
$gruposAjustes = @{
    Tema        = @{ Clave = 'Theme'; Reinicio = $true }
    Acento      = @{ Clave = 'Accent'; Reinicio = $true }
    Escala      = @{ Clave = 'PlayerScale'; Tipo = 'double'; Aplicar = { param($v) Set-PlayerScale $v; Update-PlayerLayout } }
    Panel       = @{ Clave = 'PanelOnShow' }
    Motor       = @{ Clave = 'EngineEs'; Tambien = 'EngineEn'; Reinicio = $true }
    VozEs       = @{ Clave = 'VoiceEs'; Reinicio = $true }
    VozEn       = @{ Clave = 'VoiceEn'; Reinicio = $true }
    Rendimiento = @{ Clave = 'Performance'; Reinicio = $true; Aplicar = { param($v) Update-RendimientoNota } }
    Minutos     = @{ Clave = 'SaverIdleMinutes'; Tipo = 'double'; Reinicio = $true }
    Cerrar      = @{ Clave = 'PlayerAutoClose'; Tipo = 'bool' }
    Salto       = @{ Clave = 'SkipSeconds'; Tipo = 'double'; Aplicar = { param($v) Update-SkipLabels } }
    Idioma      = @{ Clave = 'FallbackLanguage' }
}

function ConvertTo-ValorAjuste {
    param([string]$Texto, [string]$Tipo)
    switch ($Tipo) {
        'double' { return [double]::Parse($Texto, $invariante) }
        'bool'   { return $Texto -eq 'True' }
        default  { return $Texto }
    }
}

function Test-MismoValor {
    param($Actual, $Valor)
    if (($Actual -is [ValueType]) -and ($Valor -is [double])) {
        return [Math]::Abs([double]$Actual - $Valor) -lt 0.001
    }
    return ([string]$Actual) -ieq ([string]$Valor)
}

function Get-OpcionesAjuste {
    # Todas las pastillas del panel, tambien las que estan dentro de otras cajas.
    param($Nodo)
    foreach ($hijo in [Windows.LogicalTreeHelper]::GetChildren($Nodo)) {
        if ($hijo -is [Windows.Controls.RadioButton]) { $hijo }
        if ($hijo -is [Windows.DependencyObject]) { Get-OpcionesAjuste $hijo }
    }
}

# Las voces de Piper que hay en voices\: "es_MX-claude-high" se muestra como
# "claude · MX · alta".
$calidades = @{ x_low = 'muy baja'; low = 'baja'; medium = 'media'; high = 'alta' }
$instaladas = @(Get-ChildItem -LiteralPath $paths.VoicesDir -Filter '*.onnx' -ErrorAction SilentlyContinue | Sort-Object Name |
    Where-Object { Test-Path -LiteralPath ($_.FullName + '.json') })
$visibles = @(Select-VisibleVoice -Names @($instaladas | ForEach-Object { $_.BaseName }) -Configured @($settings.VoiceEs, $settings.VoiceEn))
foreach ($modelo in $instaladas) {
    if ($visibles -notcontains $modelo.BaseName) { continue }
    $nombreVoz = $modelo.BaseName
    $caja = $null
    $grupo = ''
    if ($nombreVoz -like 'es_*') { $caja = $aj.VocesEs; $grupo = 'VozEs' }
    elseif ($nombreVoz -like 'en_*') { $caja = $aj.VocesEn; $grupo = 'VozEn' }
    if ($null -eq $caja) { continue }

    $etiqueta = $nombreVoz
    if ($nombreVoz -match '^[a-z]{2}_([A-Z]{2})-(.+)-(x_low|low|medium|high)$') {
        $etiqueta = '{0} · {1} · {2}' -f $Matches[2], $Matches[1], $calidades[$Matches[3]]
    }
    $opcion = New-Object Windows.Controls.RadioButton
    $opcion.GroupName = $grupo
    $opcion.Tag = $nombreVoz
    $opcion.Content = $etiqueta
    $opcion.ToolTip = $nombreVoz
    [void]$caja.Children.Add($opcion)
}

foreach ($opcion in @(Get-OpcionesAjuste $ajustesVentana)) {
    $grupo = $gruposAjustes[$opcion.GroupName]
    if ($null -eq $grupo) { continue }
    $valor = ConvertTo-ValorAjuste ([string]$opcion.Tag) $grupo.Tipo
    if (Test-MismoValor $settings[$grupo.Clave] $valor) { $opcion.IsChecked = $true }

    $opcion.Add_Checked({
        param($sender, $e)
        if ($script:cargandoAjustes) { return }
        $g = $gruposAjustes[$sender.GroupName]
        $v = ConvertTo-ValorAjuste ([string]$sender.Tag) $g.Tipo
        Save-Ajuste $g.Clave $v -Reinicio:([bool]$g.Reinicio)
        if ($g.Tambien) { Save-Ajuste $g.Tambien $v -Reinicio:([bool]$g.Reinicio) }
        if ($g.Aplicar) { & $g.Aplicar $v }
    })
}

# --------------------------------------------------------------------------
# Deslizadores.
# --------------------------------------------------------------------------
function Format-Segundos {
    param([double]$Valor)
    return ($Valor.ToString('0.00', $invariante) + ' s')
}

$aj.Opacidad.Add_ValueChanged({
    $v = [Math]::Round($aj.Opacidad.Value, 2)
    $aj.OpacidadValor.Text = '{0} %' -f [int]($v * 100)
    if ($script:cargandoAjustes) { return }
    # Se ve al momento: con el panel abierto, el reproductor esta en reposo.
    $script:opacidadReposo = $v
    if (-not $window.IsActive) { $window.Opacity = $v }
    Save-Ajuste 'PlayerOpacity' $v
})

$aj.Fuente.Add_ValueChanged({
    $v = [Math]::Round($aj.Fuente.Value)
    $aj.FuenteValor.Text = "$v pt"
    if ($script:cargandoAjustes) { return }
    Set-TextFont $v
    Save-Ajuste 'TextFontSize' $v
})

$aj.PanelAlto.Add_ValueChanged({
    $v = [Math]::Round($aj.PanelAlto.Value)
    $aj.PanelAltoValor.Text = "$v px"
    if ($script:cargandoAjustes) { return }
    Set-PanelSize -Alto $v
})

$aj.PanelAncho.Add_ValueChanged({
    $v = [Math]::Round($aj.PanelAncho.Value)
    $aj.PanelAnchoValor.Text = "$v px"
    if ($script:cargandoAjustes) { return }
    Set-PanelSize -Ancho $v
})

$aj.PausaFrase.Add_ValueChanged({
    $v = [Math]::Round($aj.PausaFrase.Value, 2)
    $aj.PausaFraseValor.Text = Format-Segundos $v
    if ($script:cargandoAjustes) { return }
    Save-Ajuste 'SentenceSilence' $v -Reinicio
})

$aj.PausaParrafo.Add_ValueChanged({
    $v = [Math]::Round($aj.PausaParrafo.Value, 2)
    $aj.PausaParrafoValor.Text = Format-Segundos $v
    if ($script:cargandoAjustes) { return }
    Save-Ajuste 'PauseParagraph' $v
})

# --------------------------------------------------------------------------
# Ventana.
# --------------------------------------------------------------------------
function Show-SettingsWindow {
    if ($ajustesVentana.IsVisible) {
        $ajustesVentana.Hide()
        return
    }

    $script:cargandoAjustes = $true
    try {
        $aj.Opacidad.Value = $script:opacidadReposo
        $aj.Fuente.Value = $script:fuente
        $aj.PanelAncho.Minimum = [Math]::Max(300, $ui.Bar.ActualWidth)
        $aj.PanelAlto.Value = $(if ($script:panelAlto -gt 0) { $script:panelAlto } else { $ui.TextPanel.Height })
        $aj.PanelAncho.Value = $(if ($script:panelAncho -gt 0) { $script:panelAncho } else { $aj.PanelAncho.Minimum })
        $aj.PausaFrase.Value = [double]$settings.SentenceSilence
        $aj.PausaParrafo.Value = [double]$settings.PauseParagraph
    } finally {
        $script:cargandoAjustes = $false
    }
    Update-MotorNota
    Update-RendimientoNota
    Update-AtajosLista
    $aj.AcercaVersion.Text = 'Read Aloud ' + (Get-ReadAloudVersion -Root $paths.Root)

    $area = [Windows.SystemParameters]::WorkArea
    $aj.Scroll.MaxHeight = [Math]::Max(240, $area.Height - 200)
    $ajustesVentana.Show()
    $ajustesVentana.UpdateLayout()

    # Encima del reproductor y alineada con su borde derecho, para no taparlo
    # y ver los cambios en el. Si arriba no cabe, a su izquierda, con los
    # bordes de abajo alineados. Y si tampoco, donde quepa en el escritorio.
    $ancho = $ajustesVentana.ActualWidth
    $alto = $ajustesVentana.ActualHeight
    $izquierda = $window.Left + $window.ActualWidth - $ancho
    $arriba = $window.Top - $alto
    if ($arriba -lt $area.Top) {
        $izquierda = $window.Left - $ancho
        $arriba = $window.Top + $window.ActualHeight - $alto
    }
    if (-not $window.IsVisible) {
        $izquierda = $area.Right - $ajustesVentana.ActualWidth - 12
        $arriba = $area.Bottom - $ajustesVentana.ActualHeight - 12
    }
    $ajustesVentana.Left = [Math]::Max($area.Left, [Math]::Min($izquierda, $area.Right - $ajustesVentana.ActualWidth))
    $ajustesVentana.Top = [Math]::Max($area.Top, [Math]::Min($arriba, $area.Bottom - $ajustesVentana.ActualHeight))
    $ajustesVentana.Activate() | Out-Null
}

$aj.Cerrar.Add_Click({ $ajustesVentana.Hide() })
$ajustesVentana.Add_Closing({ param($sender, $e); $e.Cancel = $true; $ajustesVentana.Hide() })
$ajustesVentana.Add_KeyDown({ param($sender, $e); if ($e.Key -eq 'Escape') { $ajustesVentana.Hide() } })
$aj.Titulo.Add_MouseLeftButtonDown({ try { $ajustesVentana.DragMove() } catch { } })

$aj.ReiniciarAhora.Add_Click({ Restart-Lector })

# --------------------------------------------------------------------------
# Atajos y "Acerca de". La red solo se toca al pulsar "Buscar actualizaciones"
# y "Descargar e instalar"; Read Aloud no consulta nada por su cuenta.
# --------------------------------------------------------------------------
function Update-AtajosLista {
    $acciones = Get-HotkeyActions
    $filas = New-Object System.Collections.Generic.List[string]
    $fallidos = New-Object System.Collections.Generic.List[string]
    foreach ($e in $script:hotkeyReport) {
        $etiqueta = $acciones[$e.Action].Label
        if ($e.Active) {
            $filas.Add(('{0,-18} {1}' -f $e.Text, $etiqueta))
        } elseif ($e.Reason -eq 'disabled') {
            $filas.Add(('{0,-18} {1}' -f '(desactivado)', $etiqueta))
        } else {
            $filas.Add(('{0,-18} {1}' -f $e.Text, ($etiqueta + ' - NO DISPONIBLE')))
            $fallidos.Add($e.Text)
        }
    }
    $aj.AtajosLista.Text = ($filas -join "`n")
    if ($fallidos.Count -gt 0) {
        $aj.AtajosAviso.Text = 'Otro programa usa ya: ' + ($fallidos -join ', ') + '. Cambia esos atajos o cierra ese programa y reinicia el lector.'
        $aj.AtajosAviso.Visibility = 'Visible'
    } else {
        $aj.AtajosAviso.Visibility = 'Collapsed'
    }
}

function Set-ActualizarNota {
    param([string]$Texto)
    $aj.ActualizarNota.Text = $Texto
    $aj.ActualizarNota.Visibility = $(if ($Texto) { 'Visible' } else { 'Collapsed' })
}

$script:actualizacion = $null

# --------------------------------------------------------------------------
# Pronunciacion: el diccionario del usuario (runtime\terminos_usuario.tsv).
# --------------------------------------------------------------------------
function Set-TerminoNota {
    param([string]$Texto)
    $aj.TerminoNota.Text = $Texto
    $aj.TerminoNota.Visibility = $(if ($Texto) { 'Visible' } else { 'Collapsed' })
}

# Al salir del campo de la palabra, se muestra como se dice hoy.
$aj.TerminoPalabra.Add_LostFocus({
    $actual = Find-SpeechTerm $aj.TerminoPalabra.Text
    if ($null -eq $actual) {
        if ($aj.TerminoPalabra.Text.Trim() -ne '') { Set-TerminoNota 'Esa palabra no está en el diccionario: se lee como viene.' }
        return
    }
    $aj.TerminoDice.Text = $actual.Piper
    $aj.TerminoDiceQwen.Text = $actual.Qwen
    Set-TerminoNota 'Así suena hoy. Cámbialo y pulsa Probar.'
})

$aj.BtnTerminoProbar.Add_Click({
    # Se lee la pronunciacion tal cual, con el motor que este en uso para el
    # espanol: si hay voz propia y se dio una grafia para ella, esa.
    $texto = $aj.TerminoDice.Text.Trim()
    if ($engines['es'] -eq 'qwen' -and $aj.TerminoDiceQwen.Text.Trim() -ne '') { $texto = $aj.TerminoDiceQwen.Text.Trim() }
    if ($texto -eq '') { Set-TerminoNota 'Escribe cómo se dice para poder probarlo.'; return }
    $sync.Requests.Enqueue((@{ cmd = 'speak'; lang = 'Spanish'; text = ('Se dice: ' + $texto + '.') } | ConvertTo-Json -Compress))
    $sync.WakeUi.Invoke()
    Set-TerminoNota ''
})

$aj.BtnTerminoGuardar.Add_Click({
    $ok = Set-UserSpeechTerm -Path $paths.UserTermsFile -Term $aj.TerminoPalabra.Text -Spoken $aj.TerminoDice.Text -SpokenQwen $aj.TerminoDiceQwen.Text
    if (-not $ok) { Set-TerminoNota 'Escribe la palabra y cómo se dice (sin tabuladores).'; return }
    Update-SpeechDictionary
    Set-TerminoNota 'Guardado: se aplica desde la próxima lectura.'
})

$aj.BtnTerminoQuitar.Add_Click({
    if (Remove-UserSpeechTerm -Path $paths.UserTermsFile -Term $aj.TerminoPalabra.Text) {
        Update-SpeechDictionary
        Set-TerminoNota 'Quitado: vuelve a sonar como en el diccionario de fábrica.'
    } else {
        Set-TerminoNota 'Esa palabra no tiene una corrección tuya.'
    }
})

$aj.BtnDiagnostico.Add_Click({
    try {
        $log = @(Get-Content -LiteralPath $paths.LogFile -Tail 25 -ErrorAction SilentlyContinue)
        $texto = Get-DiagnosticText -Version (Get-ReadAloudVersion -Root $paths.Root) -Engines $engines `
            -HotkeyReport $script:hotkeyReport -LogTail $log
        [Windows.Clipboard]::SetText($texto)
        Set-ActualizarNota 'Diagnóstico copiado: pégalo en la incidencia o en el correo.'
    } catch {
        Set-ActualizarNota ('No se pudo copiar el diagnóstico: ' + $_.Exception.Message)
    }
})

$aj.BtnGitHub.Add_Click({ Start-Process 'https://github.com/DuqueOM/read_aloud' })

$aj.BtnActualizar.Add_Click({
    $aj.BtnInstalarUpdate.Visibility = 'Collapsed'
    $script:actualizacion = $null
    $ajustesVentana.Cursor = 'Wait'
    Set-ActualizarNota 'Consultando GitHub...'
    $ajustesVentana.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
    try {
        $release = Get-LatestRelease
        $actual = Get-ReadAloudVersion -Root $paths.Root
        if (Test-NewerVersion -Current $actual -Latest $release.tag_name) {
            $asset = Select-InstallerAsset $release
            $notas = Get-ReleaseNotesSummary -Body $release.body -MaxLines 10
            if ($null -eq $asset) {
                Set-ActualizarNota ("Hay una versión nueva ($($release.tag_name)), pero todavía no tiene instalador: mira " + $release.html_url)
            } else {
                $script:actualizacion = $asset
                $mb = [Math]::Round($asset.Size / 1MB, 1)
                Set-ActualizarNota ("Hay una versión nueva: $($release.tag_name) (tú tienes $actual). El instalador pesa $mb MB.`n`n$notas")
                $aj.BtnInstalarUpdate.Visibility = 'Visible'
            }
        } else {
            Set-ActualizarNota "Ya tienes la última versión ($actual)."
        }
    } catch {
        Set-ActualizarNota 'No se pudo consultar GitHub. Revisa tu conexión a internet e inténtalo de nuevo.'
        Write-DaemonLog ('Buscar actualizaciones: ' + $_.Exception.Message)
    } finally {
        $ajustesVentana.Cursor = $null
    }
})

$aj.BtnInstalarUpdate.Add_Click({
    if ($null -eq $script:actualizacion) { return }
    $respuesta = [Windows.MessageBox]::Show($ajustesVentana,
        'Se descargará el instalador, se comprobará su suma SHA-256 y se abrirá. Read Aloud se cerrará para actualizarse. ¿Seguir?',
        'Read Aloud', 'YesNo', 'Question')
    if ($respuesta -ne 'Yes') { return }

    $ajustesVentana.Cursor = 'Wait'
    Set-ActualizarNota 'Descargando y verificando el instalador...'
    $ajustesVentana.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
    try {
        $instalador = Save-ReleaseInstaller -Asset $script:actualizacion
        Write-DaemonLog ('Actualizacion: se abre ' + $instalador)
        Start-Process -FilePath $instalador
        Set-ActualizarNota 'Instalador abierto. Sigue sus pasos; Read Aloud se cerrará.'
    } catch {
        Set-ActualizarNota ('No se pudo actualizar: ' + $_.Exception.Message)
    } finally {
        $ajustesVentana.Cursor = $null
    }
})

$aj.Restablecer.Add_Click({
    $respuesta = [Windows.MessageBox]::Show($ajustesVentana,
        'Los ajustes del panel vuelven a los de config\settings.psd1 y el lector se reinicia. ¿Seguir?',
        'Read Aloud', 'YesNo', 'Question')
    if ($respuesta -ne 'Yes') { return }
    Remove-Item -LiteralPath $paths.UserSettingsFile -ErrorAction SilentlyContinue
    Restart-Lector
})

$ui.BtnSettings.Add_Click({ Show-SettingsWindow })
Update-SkipLabels
