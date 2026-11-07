#
# READ ALOUD - Lee en voz alta el texto del portapapeles.
# Windows 10 y 11, Windows PowerShell 5.1.
#
# Este archivo es el punto de entrada. El trabajo pesado lo hace el proceso
# residente (read_aloud_daemon.ps1), que mantiene los modelos de voz cargados
# en memoria. Por eso la lectura empieza casi al instante.
#
# Uso normal:
#   Selecciona texto y pulsa Ctrl+Alt+V.
#
# Uso desde la consola:
#   .\read_aloud.ps1                       Lee el portapapeles
#   .\read_aloud.ps1 -InputText "Hola"     Lee un texto concreto
#   .\read_aloud.ps1 -Stop                 Detiene la lectura
#   .\read_aloud.ps1 -Toggle               Pausa o continua
#   .\read_aloud.ps1 -Quit                 Cierra Read Aloud del todo
#   .\read_aloud.ps1 -Language English     Fuerza el idioma
#   .\read_aloud.ps1 -ShowPlan             Muestra como se va a segmentar, sin leer
#   .\read_aloud.ps1 -Diagnose             Revisa la instalacion
#   .\read_aloud.ps1 -ListVoices           Lista las voces disponibles
#   .\read_aloud.ps1 -Direct               Lee sin usar el proceso residente

[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Spanish', 'English')]
    [string]$Language = 'Auto',

    [string]$InputText = '',

    [switch]$Stop,
    [switch]$Toggle,
    [switch]$Quit,
    [switch]$ShowPlan,
    [switch]$Diagnose,
    [switch]$ListVoices,
    [switch]$Direct,
    [switch]$NoPreview,

    [ValidateSet('MachineLearning', 'Letters', 'Keep')]
    [string]$MlMode = 'MachineLearning',

    [string]$PiperBaseDir = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\ReadAloud.Core.ps1')
. (Join-Path $PSScriptRoot 'lib\ReadAloud.Text.ps1')

$paths = Get-ReadAloudPaths -PiperBaseDir $PiperBaseDir
$settings = Get-ReadAloudSettings -Paths $paths

function Get-ClipboardText {
    try {
        return Get-Clipboard -Raw
    } catch {
        return (Get-Clipboard) -join "`n"
    }
}

# --------------------------------------------------------------------------
# Ordenes que no necesitan texto.
# --------------------------------------------------------------------------
if ($Stop) {
    $answer = Send-ReadAloudCommand -PipeName $paths.PipeName -Command @{ cmd = 'stop' }

    if ($null -eq $answer) {
        # Sin proceso residente, queda la via dura: matar lo que este sonando.
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.Name -eq 'powershell.exe' -and
                $_.ProcessId -ne $PID -and
                $_.CommandLine -like ('*-File*' + $paths.Root + '\read_aloud*.ps1*')
            } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Get-Process -Name 'piper' -ErrorAction SilentlyContinue | Stop-Process -Force
    }

    exit 0
}

if ($Quit) {
    # Cierra el proceso residente (atajos e icono de la bandeja incluidos). Si
    # no esta abierto, no hay nada que cerrar: no se arranca para cerrarlo.
    [void](Send-ReadAloudCommand -PipeName $paths.PipeName -Command @{ cmd = 'quit' })
    exit 0
}

if ($Toggle) {
    $answer = Send-ReadAloudCommand -PipeName $paths.PipeName -Command @{ cmd = 'toggle' }
    if ($null -eq $answer) { Write-Host 'No hay ninguna lectura en curso.' -ForegroundColor Yellow }
    exit 0
}

if ($ListVoices) {
    Write-Host 'Voces Piper instaladas:' -ForegroundColor Cyan

    if (Test-Path -LiteralPath $paths.VoicesDir) {
        $models = Get-ChildItem -LiteralPath $paths.VoicesDir -Filter '*.onnx' -File -ErrorAction SilentlyContinue

        if ($models) {
            foreach ($model in $models) {
                $hasConfig = Test-Path -LiteralPath ($model.FullName + '.json')
                $mark = if ($hasConfig) { 'ok' } else { 'falta el .json' }
                Write-Host ('  {0}  [{1}]  {2:N0} MB' -f $model.BaseName, $mark, ($model.Length / 1MB))
            }
        } else {
            Write-Host '  ninguna. Ejecuta setup.ps1' -ForegroundColor Yellow
        }
    } else {
        Write-Host '  ninguna. Ejecuta setup.ps1' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host ('En uso ahora:  espanol = {0}   ingles = {1}' -f $settings.VoiceEs, $settings.VoiceEn) -ForegroundColor Gray
    Write-Host ''
    Write-Host 'Voces SAPI del sistema (respaldo):' -ForegroundColor Cyan

    try {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object Speech.Synthesis.SpeechSynthesizer
        $synth.GetInstalledVoices() |
            Where-Object { $_.Enabled } |
            ForEach-Object { Write-Host ('  {0} ({1})' -f $_.VoiceInfo.Name, $_.VoiceInfo.Culture.Name) }
        $synth.Dispose()
    } catch {
        Write-Host "  no pude listarlas: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    exit 0
}

if ($Diagnose) {
    Write-Host 'Diagnostico de Read Aloud' -ForegroundColor Cyan
    Write-Host ('  Raiz                 {0}' -f $paths.Root)

    $checks = [ordered]@{
        'piper.exe'          = $paths.PiperExe
        'espeak-ng-data'     = $paths.EspeakData
        'voz espanol'        = (Get-VoiceModelPath -Paths $paths -Settings $settings -Lang 'es').Model
        'voz ingles'         = (Get-VoiceModelPath -Paths $paths -Settings $settings -Lang 'en').Model
        'diccionario'        = $paths.TermsFile
        'ajustes'            = $paths.SettingsFile
    }

    foreach ($name in $checks.Keys) {
        $exists = Test-Path -LiteralPath $checks[$name]
        $mark = if ($exists) { 'OK   ' } else { 'FALTA' }
        $color = if ($exists) { 'Green' } else { 'Red' }
        Write-Host ('  {0} {1,-20} {2}' -f $mark, $name, $checks[$name]) -ForegroundColor $color
    }

    $running = Test-DaemonRunning -PipeName $paths.PipeName
    $mark = if ($running) { 'OK    activo' } else { 'AVISO no esta corriendo' }
    $color = if ($running) { 'Green' } else { 'Yellow' }
    Write-Host ('  {0}  proceso residente' -f $mark) -ForegroundColor $color

    $terms = Import-SpeechTerms -Path $paths.TermsFile
    Write-Host ('  OK    diccionario con {0} terminos' -f $terms.Count) -ForegroundColor Green

    if (Test-Path -LiteralPath $paths.TmpDir) {
        $tmpFiles = @(Get-ChildItem -LiteralPath $paths.TmpDir -Filter '*.wav' -File -ErrorAction SilentlyContinue)
        $tmpSize = ($tmpFiles | Measure-Object -Property Length -Sum).Sum / 1MB
        Write-Host ('        temporales: {0} archivos, {1:N0} MB' -f $tmpFiles.Count, $tmpSize) -ForegroundColor Gray
    }

    exit 0
}

# --------------------------------------------------------------------------
# Texto a leer.
# --------------------------------------------------------------------------
$text = $InputText
if ([string]::IsNullOrWhiteSpace($text)) {
    $text = Get-ClipboardText
}

if ([string]::IsNullOrWhiteSpace($text)) {
    Write-Host 'No hay texto en el portapapeles.' -ForegroundColor Red
    exit 1
}

if ($ShowPlan) {
    # Sirve para entender por que una frase se leyo en un idioma y no en otro.
    # La consola de Windows no muestra acentos con su pagina de codigos
    # heredada, y aqui se imprimen pronunciaciones acentuadas.
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }

    Set-SpeechTerms (Import-AllSpeechTerms -BasePath $paths.TermsFile -UserPath $paths.UserTermsFile)

    $plan = Build-SpeechPlan -Text $text -Requested $Language -MlMode $MlMode `
        -MinChunkChars $settings.MinChunkChars `
        -FirstChunkChars $settings.FirstChunkChars -MaxChunkChars $settings.MaxChunkChars `
        -Fallback $settings.FallbackLanguage

    $profile = Get-LanguageProfile -Text $text

    Write-Host ('Idioma del texto: {0}' -f $plan.DocumentLang) -ForegroundColor Cyan
    Write-Host ('Puntajes: es={0:N3}  en={1:N3}  palabras={2}' -f $profile.EsScore, $profile.EnScore, $profile.Tokens) -ForegroundColor Gray
    Write-Host ''

    $index = 0
    foreach ($chunk in $plan.Chunks) {
        $color = if ($chunk.Lang -eq 'en') { 'Yellow' } else { 'Green' }
        Write-Host ('[{0,2}] {1}  ' -f $index, $chunk.Lang.ToUpperInvariant()) -ForegroundColor $color -NoNewline
        Write-Host $chunk.Text

        if ($chunk.PauseAfter -gt 0) {
            Write-Host ('      pausa de {0:N2} s' -f $chunk.PauseAfter) -ForegroundColor DarkGray
        }

        $index++
    }

    exit 0
}

# --------------------------------------------------------------------------
# Lectura sin proceso residente. Es el camino de respaldo: mas lento al
# arrancar, pero no depende de nada mas.
# --------------------------------------------------------------------------
function Invoke-DirectRead {
    param([string]$Text)

    Set-SpeechTerms (Import-AllSpeechTerms -BasePath $paths.TermsFile -UserPath $paths.UserTermsFile)

    $plan = Build-SpeechPlan -Text $Text -Requested $Language -MlMode $MlMode `
        -MinChunkChars $settings.MinChunkChars `
        -FirstChunkChars $settings.FirstChunkChars -MaxChunkChars $settings.MaxChunkChars `
        -Fallback $settings.FallbackLanguage

    $voice = Get-VoiceModelPath -Paths $paths -Settings $settings -Lang $plan.DocumentLang

    if (-not ((Test-PiperInstalled -Paths $paths) -and $voice.Ready)) {
        Write-Host 'Piper no esta disponible; uso la voz SAPI de Windows.' -ForegroundColor Yellow
        Invoke-SapiRead -Text $Text -Lang $plan.DocumentLang
        return
    }

    if (-not (Test-Path -LiteralPath $paths.TmpDir)) {
        New-Item -ItemType Directory -Path $paths.TmpDir -Force | Out-Null
    }

    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $wavFiles = New-Object System.Collections.Generic.List[string]

    try {
        foreach ($lang in @('es', 'en')) {
            $langChunks = @($plan.Chunks | Where-Object { $_.Lang -eq $lang })
            if ($langChunks.Count -eq 0) { continue }

            $langVoice = Get-VoiceModelPath -Paths $paths -Settings $settings -Lang $lang
            if (-not $langVoice.Ready) { $langVoice = $voice }

            $piperArgs = @(
                '--model', ('"' + $langVoice.Model + '"')
                '--espeak_data', ('"' + $paths.EspeakData + '"')
                '--sentence_silence', ([double]$settings.SentenceSilence).ToString($invariant)
                '--length_scale', ([double]$settings.LengthScale).ToString($invariant)
                '--noise_scale', ([double]$settings.NoiseScale).ToString($invariant)
                '--noise_w', ([double]$settings.NoiseW).ToString($invariant)
                '--json-input'
                '--quiet'
            ) -join ' '

            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $paths.PiperExe
            $psi.Arguments = $piperArgs
            $psi.WorkingDirectory = $paths.PiperDir
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)

            $process = [Diagnostics.Process]::Start($psi)
            $writer = New-Object IO.StreamWriter($process.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
            $writer.AutoFlush = $true

            $planIndex = 0
            foreach ($chunk in $plan.Chunks) {
                if ($chunk.Lang -ne $lang) { $planIndex++; continue }

                $wav = Join-Path $paths.TmpDir ('direct_{0:d4}.wav' -f $planIndex)
                $writer.WriteLine((@{ text = $chunk.Text; output_file = $wav } | ConvertTo-Json -Compress))
                [void]$process.StandardOutput.ReadLine()
                $wavFiles.Add($wav)
                $planIndex++
            }

            $writer.Close()
            $process.WaitForExit(5000)
            if (-not $process.HasExited) { $process.Kill() }
        }

        foreach ($wav in ($wavFiles | Sort-Object)) {
            if (-not (Test-Path -LiteralPath $wav)) { continue }

            $sound = New-Object Media.SoundPlayer $wav
            $sound.Load()
            $sound.PlaySync()
            $sound.Dispose()
        }
    } finally {
        foreach ($wav in $wavFiles) {
            Remove-Item -LiteralPath $wav -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-SapiRead {
    param(
        [string]$Text,
        [string]$Lang
    )

    Add-Type -AssemblyName System.Speech
    $synth = New-Object Speech.Synthesis.SpeechSynthesizer

    try {
        $preferred = @('es-MX', 'es-ES', 'es-US')
        if ($Lang -eq 'en') { $preferred = @('en-US', 'en-GB') }

        $voices = $synth.GetInstalledVoices() | Where-Object { $_.Enabled }
        $chosen = $null

        foreach ($culture in $preferred) {
            $chosen = $voices | Where-Object { $_.VoiceInfo.Culture.Name -eq $culture } | Select-Object -First 1
            if ($chosen) { break }
        }

        if (-not $chosen) { $chosen = $voices | Select-Object -First 1 }
        if (-not $chosen) { throw 'No hay ninguna voz SAPI instalada.' }

        $synth.SelectVoice($chosen.VoiceInfo.Name)
        $synth.Rate = 2
        $synth.Volume = 100

        Write-Host ('Motor: SAPI | Voz: {0}' -f $chosen.VoiceInfo.Name) -ForegroundColor Green
        $synth.Speak($Text)
    } finally {
        $synth.Dispose()
    }
}

if ($Direct) {
    if (-not $NoPreview) {
        Write-Host 'Leyendo sin proceso residente...' -ForegroundColor Cyan
    }
    Invoke-DirectRead -Text $text
    exit 0
}

# --------------------------------------------------------------------------
# Camino normal: hablar con el proceso residente.
# --------------------------------------------------------------------------
$command = @{ cmd = 'speak'; text = $text; lang = $Language }
$answer = Send-ReadAloudCommand -PipeName $paths.PipeName -Command $command

if ($null -eq $answer) {
    if (-not $NoPreview) {
        Write-Host 'Arrancando el proceso residente (solo esta vez)...' -ForegroundColor Yellow
    }

    if (Start-ReadAloudDaemon -Paths $paths) {
        $answer = Send-ReadAloudCommand -PipeName $paths.PipeName -Command $command -TimeoutMs 2000
    }
}

if ($null -eq $answer) {
    Write-Host 'No pude usar el proceso residente; leo directamente.' -ForegroundColor Yellow
    Invoke-DirectRead -Text $text
    exit 0
}

if (-not $NoPreview) {
    $preview = $text
    if ($preview.Length -gt 400) { $preview = $preview.Substring(0, 400) + '...' }
    Write-Host 'Leyendo en voz alta.' -ForegroundColor Green
    Write-Host $preview -ForegroundColor Gray
}
