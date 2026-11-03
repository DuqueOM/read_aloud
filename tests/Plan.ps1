#
# Plan.ps1
# Ayudantes de las pruebas: el plan de lectura como texto, para guardarlo como
# referencia y compararlo linea por linea.

function Format-SpeechPlan {
    # Una cabecera con el idioma del texto y, por fragmento, su idioma, bloque,
    # tipo y pausa, el texto que dice la voz y el que se muestra. Los numeros
    # van con punto decimal sin importar la configuracion regional del equipo.
    param([hashtable]$Plan)

    $inv = [Globalization.CultureInfo]::InvariantCulture
    $lineas = New-Object System.Collections.Generic.List[string]
    [void]$lineas.Add("idioma del texto: $($Plan.DocumentLang)")

    $i = 0
    foreach ($c in $Plan.Chunks) {
        [void]$lineas.Add([string]::Format($inv, '[{0}] {1}, bloque {2} ({3}), pausa {4:0.00} s', $i, $c.Lang, $c.Block, $c.Kind, $c.PauseAfter))
        [void]$lineas.Add("    voz:     $($c.Text)")
        [void]$lineas.Add("    muestra: $($c.Display)")
        $i++
    }

    return ($lineas -join "`n") + "`n"
}

function Get-PlanCases {
    # Los textos de fixtures\textos con su plan esperado en fixtures\planes.
    $raiz = Join-Path $PSScriptRoot 'fixtures'
    foreach ($texto in (Get-ChildItem -LiteralPath (Join-Path $raiz 'textos') -Filter '*.txt' | Sort-Object Name)) {
        @{
            Nombre = $texto.BaseName
            Texto  = $texto.FullName
            Plan   = Join-Path (Join-Path $raiz 'planes') $texto.Name
        }
    }
}

function Get-TestPlan {
    # El plan de un texto de referencia, con el diccionario del repositorio y
    # los valores por defecto de los ajustes que lo afectan.
    param([string]$Path)

    $texto = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return (Format-SpeechPlan -Plan (Build-SpeechPlan -Text $texto -MinChunkChars 25 -Fallback 'es'))
}
