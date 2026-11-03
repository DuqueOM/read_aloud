#
# PSScriptAnalyzer para los scripts de PowerShell. Lo usan el pre-commit y la
# CI, a traves de tools\run_psscriptanalyzer.ps1, que bloquea solo las reglas
# de severidad Error: las advertencias se informan sin bloquear, para
# corregirlas de a poco.
#
@{
    Severity = @('Error', 'Warning')
}
