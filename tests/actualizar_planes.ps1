#
# actualizar_planes.ps1
# Reescribe fixtures\planes con el plan que da hoy el codigo para cada texto
# de fixtures\textos. Se corre a proposito despues de un cambio que debe
# cambiar la lectura (una regla nueva del diccionario, por ejemplo), y antes
# del commit se revisa con git diff que solo cambio lo esperado.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\actualizar_planes.ps1

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\lib\ReadAloud.Text.ps1')
. (Join-Path $PSScriptRoot 'Plan.ps1')

Set-SpeechTerms (Import-SpeechTerms -Path (Join-Path $PSScriptRoot '..\config\terms_es.tsv'))

$sinBom = New-Object Text.UTF8Encoding($false)
foreach ($caso in (Get-PlanCases)) {
    [IO.File]::WriteAllText($caso.Plan, (Get-TestPlan -Path $caso.Texto), $sinBom)
    Write-Output "listo: $($caso.Nombre)"
}
