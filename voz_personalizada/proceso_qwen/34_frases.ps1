# Arma los fragmentos de cada frase de la votacion igual que Read Aloud:
# separa las oraciones, normaliza el texto para la voz (unidades, terminos en
# ingles) y decide el idioma de cada fragmento. Lo llama 34_votacion.py.
#
#   powershell -NoProfile -File scripts\34_frases.ps1 <lector> <crudas.json> <frases.json>

param(
    [string]$Lector,
    [string]$Entrada,
    [string]$Salida
)

$ErrorActionPreference = 'Stop'
. (Join-Path $Lector 'lib\ReadAloud.Core.ps1')
. (Join-Path $Lector 'lib\ReadAloud.Text.ps1')

$paths = Get-ReadAloudPaths
$settings = Get-ReadAloudSettings -Paths $paths
Set-SpeechTerms (Import-SpeechTerms -Path $paths.TermsFile)

$frases = Get-Content -LiteralPath $Entrada -Raw -Encoding UTF8 | ConvertFrom-Json
$resultado = foreach ($f in $frases) {
    $plan = Build-SpeechPlan -Text $f.texto -Requested 'Auto' -MinChunkChars $settings.MinChunkChars `
        -Fallback $settings.FallbackLanguage -Pauses (Get-DefaultPauses)
    [pscustomobject]@{
        clave      = $f.clave
        texto      = $f.texto
        grupo      = $f.grupo
        fragmentos = @(foreach ($c in $plan.Chunks) { [pscustomobject]@{ texto = $c.Text; idioma = $c.Lang } })
    }
}
$json = ConvertTo-Json -InputObject @($resultado) -Depth 5
[IO.File]::WriteAllText($Salida, $json, (New-Object Text.UTF8Encoding($false)))
