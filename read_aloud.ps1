# READ ALOUD - Lee texto del portapapeles en voz alta.
# Windows 10 / PowerShell.
#
# Motor principal:
#   Piper: TTS neural local/offline. Requiere la carpeta read_aloud_piper junto a este script.
#
# Motor de respaldo:
#   Sapi: System.Speech clasico de Windows.
#
# Uso rapido:
#   Copia texto y ejecuta este script.
#
# Opciones utiles:
#   .\read_aloud.ps1 -Engine Piper
#   .\read_aloud.ps1 -Engine Sapi
#   .\read_aloud.ps1 -Language Spanish
#   .\read_aloud.ps1 -Language English
#   .\read_aloud.ps1 -MlMode MachineLearning
#   .\read_aloud.ps1 -MlMode Letters
#   .\read_aloud.ps1 -InputText "Texto de prueba"
#   .\read_aloud.ps1 -ListVoices
#
# Streaming Piper (fluidez en textos largos):
#   El texto se divide en fragmentos por oraciones y se reproducen en cadena,
#   generando el siguiente mientras suena el actual (anticipacion de 1).
#   .\read_aloud.ps1 -PiperFirstChunkChars 70   (primer fragmento mas corto = inicio mas rapido)
#   .\read_aloud.ps1 -PiperChunkTargetChars 200 (tamano de los fragmentos siguientes)

param(
    [ValidateSet("Auto", "Piper", "Sapi")]
    [string]$Engine = "Auto",

    # Solo aplica a SAPI. Piper usa PiperLengthScale.
    [ValidateRange(-10, 10)]
    [int]$Rate = 2,

    [ValidateRange(0, 100)]
    [int]$Volume = 100,

    [ValidateSet("Auto", "Spanish", "English")]
    [string]$Language = "Auto",

    [ValidateSet("MachineLearning", "Letters", "Keep")]
    [string]$MlMode = "MachineLearning",

    # Solo aplica a SAPI.
    [string]$VoiceName = "",

    # Si se indica, lee este texto en vez del portapapeles.
    [string]$InputText = "",

    # Piper: mayor valor = lectura mas lenta. 1.00 es la velocidad base del modelo.
    [ValidateRange(0.50, 2.00)]
    [double]$PiperLengthScale = 1.06,

    # Piper: silencio en segundos despues de cada frase.
    [ValidateRange(0.00, 2.00)]
    [double]$PiperSentenceSilence = 0.36,

    [ValidateRange(0.00, 2.00)]
    [double]$PiperNoiseScale = 0.667,

    [ValidateRange(0.00, 2.00)]
    [double]$PiperNoiseW = 0.8,

    # Piper streaming: tamano objetivo (en caracteres) de cada fragmento de audio.
    # Fragmentos mas grandes = menos reinicios de Piper; mas pequenos = inicio mas rapido.
    [ValidateRange(40, 4000)]
    [int]$PiperChunkTargetChars = 200,

    # Piper streaming: tamano del primer fragmento. Pequeno = el audio arranca antes.
    [ValidateRange(20, 4000)]
    [int]$PiperFirstChunkChars = 70,

    # Si lo dejas vacio, busca Desktop\read_aloud_piper junto al script.
    [string]$PiperBaseDir = "",

    [switch]$ListVoices,

    [switch]$NoPreview,

    [switch]$KeepWav
)

$ErrorActionPreference = "Stop"

function Get-ScriptDirectory {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }

    if ($MyInvocation.MyCommand.Path) {
        return Split-Path -Parent $MyInvocation.MyCommand.Path
    }

    return [Environment]::GetFolderPath("Desktop")
}

function Get-ClipboardText {
    try {
        return Get-Clipboard -Raw
    } catch {
        return Get-Clipboard
    }
}

function Remove-Diacritics {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object Text.StringBuilder

    foreach ($ch in $normalized.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($ch)
        }
    }

    return $builder.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function Detect-Language {
    param([string]$Text)

    $spanishStops = @(
        "que","de","la","el","en","y","a","los","se","del","las","un","por","con","no","una","su","para",
        "es","al","lo","como","mas","pero","sus","le","ya","o","este","si","esta","son","tambien","cuando",
        "muy","todo","esto","porque","hay","ser","fue","han","sin","sobre","quien","donde","desde","hasta"
    )

    $englishStops = @(
        "the","be","to","of","and","a","in","that","have","i","it","for","not","on","with","he","as","you",
        "do","at","this","but","his","by","from","they","we","say","her","she","or","an","will","my","one",
        "all","would","there","their","is","are","what","which","when","can","if","about","more","use","how"
    )

    $tokens = ($Text -split "[^\p{L}\p{N}]+") |
        Where-Object { $_ -ne "" } |
        ForEach-Object { (Remove-Diacritics $_).ToLowerInvariant() }

    $spanishCount = 0
    $englishCount = 0

    foreach ($t in $tokens) {
        if ($spanishStops -contains $t) { $spanishCount++ }
        if ($englishStops -contains $t) { $englishCount++ }
    }

    # Senales extra: caracteres propios del espanol sin escribirlos literal en el archivo.
    $spanishSignalChars = @(
        [char]0x00E1, [char]0x00E9, [char]0x00ED, [char]0x00F3, [char]0x00FA,
        [char]0x00C1, [char]0x00C9, [char]0x00CD, [char]0x00D3, [char]0x00DA,
        [char]0x00F1, [char]0x00D1, [char]0x00BF, [char]0x00A1
    )

    foreach ($signal in $spanishSignalChars) {
        if ($Text.IndexOf($signal) -ge 0) {
            $spanishCount += 2
            break
        }
    }

    $lang = "unknown"
    if ($tokens.Count -ge 3) {
        if ($spanishCount -gt ($englishCount + 1)) {
            $lang = "es"
        } elseif ($englishCount -gt ($spanishCount + 1)) {
            $lang = "en"
        }
    }

    return @{
        Lang = $lang
        SpanishCount = $spanishCount
        EnglishCount = $englishCount
        TokenCount = $tokens.Count
    }
}

function Resolve-RequestedLanguage {
    param(
        [string]$RequestedLanguage,
        [hashtable]$Detected
    )

    if ($RequestedLanguage -eq "Spanish") { return "es" }
    if ($RequestedLanguage -eq "English") { return "en" }
    if ($Detected.Lang -eq "es" -or $Detected.Lang -eq "en") { return $Detected.Lang }

    # Para textos cortos o ambiguos, el uso principal de este script suele ser espanol.
    return "es"
}

function Normalize-ForSpeech {
    param(
        [string]$Text,
        [string]$Lang,
        [string]$MlMode
    )

    $t = $Text

    $t = $t -replace ([string][char]0x201C), '"'
    $t = $t -replace ([string][char]0x201D), '"'
    $t = $t -replace ([string][char]0x2018), "'"
    $t = $t -replace ([string][char]0x2019), "'"
    $t = $t -replace ([string][char]0x2013), " - "
    $t = $t -replace ([string][char]0x2014), " - "
    $t = $t -replace ([string][char]0x2026), "..."

    if ($MlMode -eq "MachineLearning") {
        $t = [regex]::Replace($t, "(?<![\p{L}\p{N}])ml(?![\p{L}\p{N}])", "machine learning", "IgnoreCase")
    } elseif ($MlMode -eq "Letters") {
        $replacement = if ($Lang -eq "es") { "eme ele" } else { "M L" }
        $t = [regex]::Replace($t, "(?<![\p{L}\p{N}])ml(?![\p{L}\p{N}])", $replacement, "IgnoreCase")
    }

    if ($Lang -eq "es") {
        $replacements = @{
            "\bIA\b" = "inteligencia artificial"
            "\bAI\b" = "inteligencia artificial"
            "\bAPI\b" = "a pe i"
            "\bURL\b" = "u erre ele"
            "\bHTTP\b" = "hache te te pe"
            "\bHTTPS\b" = "hache te te pe ese"
            "\bJSON\b" = "yeison"
            "\bSQL\b" = "ese cu ele"
            "\bCSV\b" = "ce ese uve"
            "\bGPU\b" = "ge pe u"
            "\bCPU\b" = "ce pe u"
            "\bLLM\b" = "ele ele eme"
            "\bTTS\b" = "te te ese"
            "\bUI\b" = "u i"
            "\bUX\b" = "u equis"
            "\bCLI\b" = "ce ele i"
            "\bPowerShell\b" = "Power Shell"
        }
    } else {
        $replacements = @{
            "\bAPI\b" = "A P I"
            "\bURL\b" = "U R L"
            "\bSQL\b" = "S Q L"
            "\bCSV\b" = "C S V"
            "\bGPU\b" = "G P U"
            "\bCPU\b" = "C P U"
            "\bLLM\b" = "L L M"
            "\bTTS\b" = "T T S"
            "\bUI\b" = "U I"
            "\bUX\b" = "U X"
            "\bCLI\b" = "C L I"
            "\bPowerShell\b" = "Power Shell"
        }
    }

    foreach ($pattern in $replacements.Keys) {
        $t = [regex]::Replace($t, $pattern, $replacements[$pattern], "IgnoreCase")
    }

    $t = $t -replace "=>", " produce "
    $t = $t -replace "->", " hacia "

    return $t
}

function Prepare-PiperText {
    param([string]$Text)

    $t = $Text -replace "`r`n", "`n"
    $t = $t -replace "`r", "`n"
    $t = $t -replace "[`t ]+", " "

    $lines = $t -split "`n", -1
    $out = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed -eq "") {
            $out.Add("")
            continue
        }

        $trimmed = $trimmed -replace "^\s*[-*]\s+", ""

        # Las listas y encabezados cortos sin puntuacion suenan mejor con cierre.
        if (($trimmed.Length -lt 140) -and ($trimmed -notmatch "[\.\!\?\:\;]$")) {
            $trimmed = "$trimmed."
        }

        $out.Add($trimmed)
    }

    return ($out -join [Environment]::NewLine)
}

function Get-PiperPaths {
    param([string]$BaseDir)

    if ([string]::IsNullOrWhiteSpace($BaseDir)) {
        $BaseDir = Join-Path (Get-ScriptDirectory) "read_aloud_piper"
    }

    $piperDir = Join-Path $BaseDir "bin\piper"

    return @{
        BaseDir = $BaseDir
        PiperExe = Join-Path $piperDir "piper.exe"
        EspeakData = Join-Path $piperDir "espeak-ng-data"
        SpanishModel = Join-Path $BaseDir "voices\es_MX-claude-high.onnx"
        SpanishFallbackModel = Join-Path $BaseDir "voices\es_MX-ald-medium.onnx"
        EnglishModel = Join-Path $BaseDir "voices\en_US-lessac-medium.onnx"
    }
}

function Get-PiperModel {
    param(
        [hashtable]$PiperPaths,
        [string]$Lang
    )

    if ($Lang -eq "en") {
        return $PiperPaths.EnglishModel
    }

    if ((Test-Path -LiteralPath $PiperPaths.SpanishModel) -and (Test-Path -LiteralPath "$($PiperPaths.SpanishModel).json")) {
        return $PiperPaths.SpanishModel
    }

    if ((Test-Path -LiteralPath $PiperPaths.SpanishFallbackModel) -and (Test-Path -LiteralPath "$($PiperPaths.SpanishFallbackModel).json")) {
        return $PiperPaths.SpanishFallbackModel
    }

    return $PiperPaths.SpanishModel
}

function Test-PiperReady {
    param(
        [hashtable]$PiperPaths,
        [string]$Lang
    )

    $model = Get-PiperModel -PiperPaths $PiperPaths -Lang $Lang
    $config = "$model.json"

    return (
        (Test-Path -LiteralPath $PiperPaths.PiperExe) -and
        (Test-Path -LiteralPath $PiperPaths.EspeakData) -and
        (Test-Path -LiteralPath $model) -and
        (Test-Path -LiteralPath $config)
    )
}

function To-InvariantString {
    param([double]$Value)
    return $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Quote-NativeArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Split-IntoSpeechChunks {
    param(
        [string]$Text,
        [int]$TargetChars = 200,
        [int]$FirstChunkChars = 70
    )

    # Divide por fin de oracion (.!?:;) o saltos de linea, conservando el texto.
    $pieces = [regex]::Split($Text, "(?<=[\.\!\?\:;])\s+|\r?\n+")

    $chunks = New-Object System.Collections.Generic.List[string]
    $current = ""

    foreach ($piece in $pieces) {
        $p = $piece.Trim()
        if ($p -eq "") { continue }

        if ($current -eq "") {
            $current = $p
        } else {
            $current = "$current $p"
        }

        # El primer fragmento es mas corto para que el audio arranque antes.
        $limit = if ($chunks.Count -eq 0) { $FirstChunkChars } else { $TargetChars }

        if ($current.Length -ge $limit) {
            $chunks.Add($current)
            $current = ""
        }
    }

    if ($current.Trim() -ne "") {
        $chunks.Add($current)
    }

    if ($chunks.Count -eq 0) {
        $chunks.Add($Text)
    }

    # Coma para evitar que PowerShell desenrolle la lista (clave si solo hay 1 fragmento).
    return ,$chunks
}

function Start-PiperSynthesis {
    param(
        [string]$ChunkText,
        [string]$Model,
        [hashtable]$PiperPaths,
        [string]$WavPath
    )

    $piperArgs = @(
        "--model", $Model,
        "--output_file", $WavPath,
        "--sentence_silence", (To-InvariantString $PiperSentenceSilence),
        "--length_scale", (To-InvariantString $PiperLengthScale),
        "--noise_scale", (To-InvariantString $PiperNoiseScale),
        "--noise_w", (To-InvariantString $PiperNoiseW),
        "--espeak_data", $PiperPaths.EspeakData,
        "--quiet"
    )

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $PiperPaths.PiperExe
    $psi.Arguments = (($piperArgs | ForEach-Object { Quote-NativeArgument $_ }) -join " ")
    $psi.WorkingDirectory = Split-Path -Parent $PiperPaths.PiperExe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()
    $process.StandardInput.WriteLine($ChunkText)
    $process.StandardInput.Close()

    # No leemos stdout/stderr aqui: con --quiet Piper casi no escribe, asi el
    # proceso sigue generando en segundo plano mientras suena el fragmento previo.
    return @{ Process = $process; Wav = $WavPath }
}

function Complete-PiperSynthesis {
    param([hashtable]$Job)

    $process = $Job.Process
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        throw "Piper termino con codigo $($process.ExitCode). $stdout $stderr"
    }

    if (-not (Test-Path -LiteralPath $Job.Wav)) {
        throw "Piper no genero el archivo WAV esperado."
    }
}

function Invoke-PiperRead {
    param(
        [string]$Text,
        [hashtable]$PiperPaths,
        [string]$Lang
    )

    $model = Get-PiperModel -PiperPaths $PiperPaths -Lang $Lang
    $tmpDir = Join-Path $PiperPaths.BaseDir "tmp"

    if (-not (Test-Path -LiteralPath $tmpDir)) {
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
    }

    $piperText = Prepare-PiperText -Text $Text
    $chunks = Split-IntoSpeechChunks -Text $piperText -TargetChars $PiperChunkTargetChars -FirstChunkChars $PiperFirstChunkChars

    Write-Host ("Fragmentos: {0} (streaming con anticipacion)" -f $chunks.Count) -ForegroundColor Gray

    $oldConsoleInput = [Console]::InputEncoding
    $oldConsoleOutput = [Console]::OutputEncoding
    $utf8NoBom = New-Object Text.UTF8Encoding($false)

    $newWavPath = {
        Join-Path $tmpDir ("read_aloud_{0}.wav" -f ([guid]::NewGuid().ToString("N")))
    }

    try {
        [Console]::InputEncoding = $utf8NoBom
        [Console]::OutputEncoding = $utf8NoBom

        $keptWavCount = 0

        # Genera y espera el primer fragmento (unica espera real, deliberadamente corta).
        $current = Start-PiperSynthesis -ChunkText $chunks[0] -Model $model -PiperPaths $PiperPaths -WavPath (& $newWavPath)
        Complete-PiperSynthesis -Job $current

        for ($i = 0; $i -lt $chunks.Count; $i++) {
            # Lanza la sintesis del siguiente fragmento ANTES de reproducir el actual,
            # para que se genere en paralelo mientras suena este.
            $next = $null
            if (($i + 1) -lt $chunks.Count) {
                $next = Start-PiperSynthesis -ChunkText $chunks[$i + 1] -Model $model -PiperPaths $PiperPaths -WavPath (& $newWavPath)
            }

            $player = New-Object Media.SoundPlayer $current.Wav
            $player.Load()
            $player.PlaySync()
            $player.Dispose()

            if ($KeepWav) {
                $keptWavCount++
            } else {
                Remove-Item -LiteralPath $current.Wav -Force -ErrorAction SilentlyContinue
            }

            if ($next) {
                Complete-PiperSynthesis -Job $next
                $current = $next
            }
        }

        if ($KeepWav) {
            Write-Host ("WAV generados: {0} en {1}" -f $keptWavCount, $tmpDir) -ForegroundColor Gray
        }
    } finally {
        [Console]::InputEncoding = $oldConsoleInput
        [Console]::OutputEncoding = $oldConsoleOutput
    }
}

function Escape-Xml {
    param([string]$Text)
    return [Security.SecurityElement]::Escape($Text)
}

function Text-ToSsmlBody {
    param([string]$Text)

    $t = $Text
    $t = $t -replace "(?<=\d)\.(?=\d)", "[[DOT]]"
    $t = $t -replace "(?i)\b(v|ver|version)\s*(\d+)\.(\d+)", '$1 $2[[DOT]]$3'

    $parts = New-Object System.Collections.Generic.List[string]
    $paragraphs = [regex]::Split($t.Trim(), "(\r?\n\s*\r?\n)")

    foreach ($p in $paragraphs) {
        if ([string]::IsNullOrWhiteSpace($p)) {
            continue
        }

        if ($p -match "^\r?\n\s*\r?\n$") {
            $parts.Add('<break time="850ms"/>')
            continue
        }

        $lines = [regex]::Split($p, "(\r?\n)")

        foreach ($line in $lines) {
            if ($line -match "^\r?\n$") {
                $parts.Add('<break time="420ms"/>')
                continue
            }

            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $escaped = Escape-Xml $line

            $escaped = $escaped -replace "\.{3,}", '...<break time="700ms"/>'
            $escaped = $escaped -replace "([.!?])(\s+|$)", '$1<break time="520ms"/>$2'
            $escaped = $escaped -replace "([;:])(\s+|$)", '$1<break time="340ms"/>$2'
            $escaped = $escaped -replace "(,)(\s+|$)", '$1<break time="180ms"/>$2'
            $escaped = $escaped -replace "\s+-\s+", '<break time="260ms"/> '
            $escaped = $escaped -replace "\[\[DOT\]\]", "."

            $parts.Add($escaped)
        }
    }

    return ($parts -join " ")
}

function Convert-ToSsml {
    param(
        [string]$Text,
        [string]$CultureName
    )

    $body = Text-ToSsmlBody -Text $Text

    return @"
<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="$CultureName">
  <prosody rate="medium" pitch="+0st">
    $body
  </prosody>
</speak>
"@
}

function Select-BestSapiVoice {
    param(
        [Speech.Synthesis.SpeechSynthesizer]$Synth,
        [string]$Lang,
        [string]$VoiceName
    )

    $voices = $Synth.GetInstalledVoices() | Where-Object { $_.Enabled }

    if ($VoiceName -ne "") {
        $chosen = $voices | Where-Object { $_.VoiceInfo.Name -eq $VoiceName } | Select-Object -First 1
        if ($chosen) { return $chosen }

        Write-Host "No encontre la voz exacta: $VoiceName" -ForegroundColor Yellow
    }

    if ($Lang -eq "es") {
        $preferredCultures = @("es-MX", "es-ES", "es-US", "es-*")
    } elseif ($Lang -eq "en") {
        $preferredCultures = @("en-US", "en-GB", "en-*")
    } else {
        $preferredCultures = @(
            [Globalization.CultureInfo]::InstalledUICulture.Name,
            "es-MX",
            "es-ES",
            "en-US",
            "es-*",
            "en-*"
        )
    }

    foreach ($culture in $preferredCultures) {
        $match = $voices | Where-Object {
            if ($culture.EndsWith("*")) {
                $_.VoiceInfo.Culture.Name -like $culture
            } else {
                $_.VoiceInfo.Culture.Name -eq $culture
            }
        } | Select-Object -First 1

        if ($match) { return $match }
    }

    return $voices | Select-Object -First 1
}

function Invoke-SapiRead {
    param(
        [string]$Text,
        [string]$Lang
    )

    Add-Type -AssemblyName System.Speech
    $synth = New-Object Speech.Synthesis.SpeechSynthesizer

    try {
        $selectedVoice = Select-BestSapiVoice -Synth $synth -Lang $Lang -VoiceName $VoiceName

        if (-not $selectedVoice) {
            throw "No se encontro ninguna voz SAPI instalada."
        }

        $synth.SelectVoice($selectedVoice.VoiceInfo.Name)
        $synth.Rate = $Rate
        $synth.Volume = $Volume

        $voiceCulture = $selectedVoice.VoiceInfo.Culture.Name
        $effectiveLang = if ($voiceCulture -like "es-*") { "es" } elseif ($voiceCulture -like "en-*") { "en" } else { $Lang }
        $prepared = Normalize-ForSpeech -Text $Text -Lang $effectiveLang -MlMode $MlMode
        $ssml = Convert-ToSsml -Text $prepared -CultureName $voiceCulture

        Write-Host ("Motor: SAPI | Voz: {0} ({1})" -f $selectedVoice.VoiceInfo.Name, $voiceCulture) -ForegroundColor Green

        try {
            $synth.SpeakSsml($ssml)
        } catch {
            Write-Host "SSML fallo; usando lectura SAPI simple. Detalle: $($_.Exception.Message)" -ForegroundColor Yellow
            $synth.Speak($prepared)
        }
    } finally {
        if ($synth) {
            $synth.Dispose()
        }
    }
}

function Show-AvailableVoices {
    param([hashtable]$PiperPaths)

    Write-Host "Voces Piper locales:" -ForegroundColor Cyan

    if ((Test-Path -LiteralPath $PiperPaths.SpanishModel) -and (Test-Path -LiteralPath "$($PiperPaths.SpanishModel).json")) {
        Write-Host ("- Spanish / es_MX female high: {0}" -f $PiperPaths.SpanishModel)
    } else {
        Write-Host "- Spanish / es_MX female high: no instalada" -ForegroundColor Yellow
    }

    if ((Test-Path -LiteralPath $PiperPaths.SpanishFallbackModel) -and (Test-Path -LiteralPath "$($PiperPaths.SpanishFallbackModel).json")) {
        Write-Host ("- Spanish / es_MX fallback: {0}" -f $PiperPaths.SpanishFallbackModel)
    } else {
        Write-Host "- Spanish / es_MX fallback: no instalada" -ForegroundColor Yellow
    }

    if ((Test-Path -LiteralPath $PiperPaths.EnglishModel) -and (Test-Path -LiteralPath "$($PiperPaths.EnglishModel).json")) {
        Write-Host ("- English / en_US: {0}" -f $PiperPaths.EnglishModel)
    } else {
        Write-Host "- English / en_US: no instalada" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Voces SAPI instaladas:" -ForegroundColor Cyan

    try {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object Speech.Synthesis.SpeechSynthesizer
        $synth.GetInstalledVoices() |
            Where-Object { $_.Enabled } |
            ForEach-Object {
                Write-Host ("- {0} ({1})" -f $_.VoiceInfo.Name, $_.VoiceInfo.Culture.Name)
            }
        $synth.Dispose()
    } catch {
        Write-Host "No pude listar voces SAPI: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$piperPaths = Get-PiperPaths -BaseDir $PiperBaseDir

if ($ListVoices) {
    Show-AvailableVoices -PiperPaths $piperPaths
    exit 0
}

$text = if ([string]::IsNullOrWhiteSpace($InputText)) {
    Get-ClipboardText
} else {
    $InputText
}

if ([string]::IsNullOrWhiteSpace($text)) {
    Write-Host "No hay texto en el portapapeles." -ForegroundColor Red
    exit 1
}

$detected = Detect-Language -Text $text
$lang = Resolve-RequestedLanguage -RequestedLanguage $Language -Detected $detected
$preparedText = Normalize-ForSpeech -Text $text -Lang $lang -MlMode $MlMode

$engineToUse = $Engine
if ($engineToUse -eq "Auto") {
    if (Test-PiperReady -PiperPaths $piperPaths -Lang $lang) {
        $engineToUse = "Piper"
    } else {
        $engineToUse = "Sapi"
    }
}

Write-Host "Leyendo en voz alta..." -ForegroundColor Cyan
Write-Host ("Idioma: {0} | Deteccion: {1} es:{2} en:{3} tokens:{4}" -f $lang, $detected.Lang, $detected.SpanishCount, $detected.EnglishCount, $detected.TokenCount) -ForegroundColor Gray
Write-Host ("MlMode: {0}" -f $MlMode) -ForegroundColor Gray

if (-not $NoPreview) {
    Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray

    $preview = $text
    if ($preview.Length -gt 1200) {
        $preview = $preview.Substring(0, 1200) + "`n...[texto recortado en vista previa]..."
    }

    Write-Host $preview -ForegroundColor White
    Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray
}

try {
    if ($engineToUse -eq "Piper") {
        if (-not (Test-PiperReady -PiperPaths $piperPaths -Lang $lang)) {
            throw "Piper no esta listo para el idioma '$lang'. Revisa: $($piperPaths.BaseDir)"
        }

        $model = Get-PiperModel -PiperPaths $piperPaths -Lang $lang
        Write-Host ("Motor: Piper | Modelo: {0}" -f (Split-Path -Leaf $model)) -ForegroundColor Green
        Write-Host ("PiperLengthScale: {0} | SentenceSilence: {1}s" -f $PiperLengthScale, $PiperSentenceSilence) -ForegroundColor Gray
        Invoke-PiperRead -Text $preparedText -PiperPaths $piperPaths -Lang $lang
    } else {
        Invoke-SapiRead -Text $text -Lang $lang
    }

    Write-Host "Lectura completada." -ForegroundColor Green
} catch {
    if (($engineToUse -eq "Piper") -and ($Engine -eq "Auto")) {
        Write-Host "Piper fallo; intentando con SAPI. Detalle: $($_.Exception.Message)" -ForegroundColor Yellow
        Invoke-SapiRead -Text $text -Lang $lang
        Write-Host "Lectura completada con SAPI." -ForegroundColor Green
    } else {
        Write-Host "Error durante la sintesis: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
