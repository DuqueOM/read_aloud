#
# Codificacion.Tests.ps1
# Windows PowerShell 5.1 lee como ANSI un .ps1 o .psd1 sin BOM. Una tilde
# escrita tal cual en uno de esos archivos llega cambiada al codigo: asi una
# regla de plural dejo de reconocer "cuantos" con tilde. Cada archivo de
# PowerShell, o tiene BOM, o es ASCII.

BeforeDiscovery {
    $raiz = Split-Path -Parent $PSScriptRoot
    $archivos = @(git -C $raiz ls-files '*.ps1' '*.psm1' '*.psd1' | ForEach-Object {
        @{ Archivo = $_; Ruta = Join-Path $raiz $_ }
    })
}

Describe 'Codificacion de <Archivo>' -ForEach $archivos {
    It 'tiene BOM o es ASCII' {
        $bytes = [IO.File]::ReadAllBytes($Ruta)
        $conBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        if (-not $conBom) {
            $linea = 1
            $fuera = foreach ($b in $bytes) {
                if ($b -eq 10) { $linea++ } elseif ($b -gt 127) { $linea; break }
            }
            $fuera | Should -BeNullOrEmpty -Because "la linea $fuera tiene un caracter que no es ASCII y el archivo no tiene BOM"
        }
    }
}
