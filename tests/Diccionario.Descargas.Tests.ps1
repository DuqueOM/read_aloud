#
# Diccionario.Descargas.Tests.ps1
# config\idiomas.psd1 y la instalacion del diccionario del panel (ADR 0017):
# lo que setup.ps1 baja (origen https, tamano, sha256 y destino de cada
# pieza); como se instala una pieza desde su zip (el sha256 antes de nada,
# sin index.sense, sin salirse de la carpeta y sin romper lo que habia); el
# indice inverso; lo que el lector ve instalado; y lo que hacen setup.ps1 y
# el asistente de Inno Setup. Los zip de prueba se arman en TestDrive.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Core.ps1')
    . (Join-Path $PSScriptRoot '..\lib\ReadAloud.Dictionary.ps1')
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    $script:utf8 = New-Object Text.UTF8Encoding($false)
    $script:catalogo = Read-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\config\idiomas.psd1')
    $script:piezas = @(Get-DictionaryPieces -Catalog $script:catalogo)

    function New-TestZip {
        # Un zip con estas entradas: ruta dentro del zip -> texto. Una ruta
        # que termina en / es una carpeta.
        param([string]$Path, [hashtable]$Entries)
        $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($k in @($Entries.Keys | Sort-Object)) {
                $e = $zip.CreateEntry($k)
                if ($k.EndsWith('/')) { continue }
                $w = New-Object IO.StreamWriter($e.Open(), $script:utf8)
                try { $w.Write([string]$Entries[$k]) } finally { $w.Dispose() }
            }
        } finally {
            $zip.Dispose()
        }
    }

    function New-TestPiece {
        # Una pieza como las del catalogo, con el sha256 del zip.
        param(
            [string]$Zip,
            [string]$Destino = 'datos',
            [string[]]$Archivos = @('a.txt'),
            [string[]]$Excluir = @(),
            [string]$Formato = 'stardict'
        )
        return @{
            Id = $Destino; Url = 'https://example.org/' + (Split-Path -Leaf $Zip); Bytes = (Get-Item -LiteralPath $Zip).Length
            Sha256 = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
            Destino = $Destino; Tipo = 'zip'; Formato = $Formato; Archivos = $Archivos; Excluir = $Excluir
        }
    }

    function New-TestStarDictZip {
        # Un zip como los de WikDict: una carpeta con stardict.ifo, .idx y
        # .dict sin comprimir. Cada traduccion es un <div> sin etiquetas.
        param([string]$Path, [string]$Folder, [object[]]$Entries)
        $dir = Join-Path (Split-Path -Parent $Path) ('_sd_' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
        $carpeta = Join-Path $dir $Folder
        New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
        $dict = New-Object IO.MemoryStream
        $idx = New-Object IO.MemoryStream
        foreach ($e in $Entries) {
            $cuerpo = $script:utf8.GetBytes($e.Html)
            $pos = [uint32]$dict.Length
            $dict.Write($cuerpo, 0, $cuerpo.Length)
            $nombre = $script:utf8.GetBytes($e.Word)
            $idx.Write($nombre, 0, $nombre.Length)
            $idx.WriteByte(0)
            foreach ($n in @($pos, [uint32]$cuerpo.Length)) {
                $b = [BitConverter]::GetBytes([uint32]$n)
                if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($b) }
                $idx.Write($b, 0, 4)
            }
        }
        [IO.File]::WriteAllBytes((Join-Path $carpeta 'stardict.dict'), $dict.ToArray())
        [IO.File]::WriteAllBytes((Join-Path $carpeta 'stardict.idx'), $idx.ToArray())
        [IO.File]::WriteAllText((Join-Path $carpeta 'stardict.ifo'), "StarDict's dict ifo file`nversion=3.0.0`nwordcount=$($Entries.Count)`nsametypesequence=h`n", $script:utf8)
        [IO.Compression.ZipFile]::CreateFromDirectory($carpeta, $Path, [IO.Compression.CompressionLevel]::Optimal, $true)
        Remove-Item -LiteralPath $dir -Recurse -Force
    }

    function New-TestDir {
        $d = Join-Path $TestDrive ('d' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }
}

Describe 'config\idiomas.psd1' {
    It 'tiene los origenes, los idiomas en y es, y los pares en-es y es-en' {
        $script:catalogo.Keys | Should -Contain 'Origenes'
        $script:catalogo.Idiomas.Keys | Should -Contain 'en'
        $script:catalogo.Idiomas.Keys | Should -Contain 'es'
        $script:catalogo.Pares.Keys | Should -Contain 'en-es'
        $script:catalogo.Pares.Keys | Should -Contain 'es-en'
    }

    It 'trae las tres piezas: WordNet para en y WikDict para cada par' {
        @($script:piezas | ForEach-Object { $_.Id }) | Should -Be @('oewn2025', 'wikdict-en-es', 'wikdict-es-en')
        @($script:piezas | Where-Object { $_.Rol -eq 'Definiciones' } | ForEach-Object { $_.Lang }) | Should -Be @('en')
        @($script:piezas | Where-Object { $_.Rol -eq 'Bilingue' } | ForEach-Object { $_.Pair }) | Should -Be @('en-es', 'es-en')
    }

    It 'cada pieza tiene un origen https, su tamano, un sha256 y es un zip' {
        foreach ($p in $script:piezas) {
            $p.Url | Should -Match '^https://[^{}]+\.zip$' -Because $p.Id
            [long]$p.Bytes | Should -BeGreaterThan 0 -Because $p.Id
            $p.Sha256 | Should -Match '^[0-9a-f]{64}$' -Because $p.Id
            $p.Tipo | Should -Be 'zip' -Because $p.Id
        }
    }

    It 'las definiciones son WNDB y los bilingues StarDict, lo que la biblioteca sabe abrir' {
        foreach ($p in $script:piezas) {
            if ($p.Rol -eq 'Definiciones') { $p.Formato | Should -Be 'wndb' -Because $p.Id } else { $p.Formato | Should -Be 'stardict' -Because $p.Id }
        }
    }

    It 'cada pieza va a una carpeta de nombre simple, dentro de la del diccionario' {
        foreach ($p in $script:piezas) {
            $p.Destino | Should -Match '^[A-Za-z0-9][A-Za-z0-9._-]*$' -Because $p.Id
            $p.Destino | Should -Not -Be 'inverso' -Because 'esa carpeta es la del indice inverso'
        }
    }

    It 'los identificadores y los destinos no se repiten' {
        @($script:piezas | ForEach-Object { $_.Id } | Select-Object -Unique).Count | Should -Be $script:piezas.Count
        @($script:piezas | ForEach-Object { $_.Destino } | Select-Object -Unique).Count | Should -Be $script:piezas.Count
    }

    It 'cada pieza dice que archivos trae, su licencia, su atribucion y su fuente' {
        foreach ($p in $script:piezas) {
            @($p.Archivos).Count | Should -BeGreaterThan 0 -Because $p.Id
            $p.Licencia | Should -Match '^CC BY' -Because $p.Id
            $p.Atribucion | Should -Not -BeNullOrEmpty -Because $p.Id
            $p.Fuente | Should -Match '^https://' -Because $p.Id
        }
    }

    It 'baja unos 14 MB, como dice el ADR' {
        $total = [long]0; foreach ($p in $script:piezas) { $total += [long]$p.Bytes }
        [Math]::Round($total / 1e6, 1) | Should -Be 14.3
    }

    It 'WordNet viene de en-word.net y sin index.sense' {
        $wn = @($script:piezas | Where-Object { $_.Id -eq 'oewn2025' })[0]
        $wn.Url | Should -Be 'https://en-word.net/downloads/english-wordnet-2025.zip'
        @($wn.Excluir) | Should -Contain 'index.sense'
        foreach ($pos in 'noun', 'verb', 'adj', 'adv') {
            @($wn.Archivos) | Should -Contain "index.$pos"
            @($wn.Archivos) | Should -Contain "data.$pos"
            @($wn.Archivos) | Should -Contain "$pos.exc"
        }
    }

    It 'WikDict viene de la copia fija del release, que se cambia en un solo lugar' {
        $base = $script:catalogo.Origenes.DatosDiccionario
        $base | Should -Match '^https://github\.com/DuqueOM/read_aloud/releases/download/datos-diccionario-\d{4}-\d{2}$'
        foreach ($par in 'en-es', 'es-en') {
            $script:catalogo.Pares[$par].Bilingue.Url | Should -Be ('{DatosDiccionario}/wikdict-' + $par + '.zip')
            @($script:piezas | Where-Object { $_.Pair -eq $par })[0].Url | Should -Be ($base + '/wikdict-' + $par + '.zip')
            @($script:catalogo.Pares[$par].Bilingue.Archivos) | Should -Be @('stardict.ifo', 'stardict.idx', 'stardict.dict')
        }
    }

    It 'el sha256 de <Id> es el del archivo bajado el 28 nov' -ForEach @(
        @{ Id = 'oewn2025'; Bytes = 9616299; Sha = '38b16326159f51853626b7d24a44c453fa88ab33f06fce5ec8fc5996d1c2be93' }
        @{ Id = 'wikdict-en-es'; Bytes = 3673548; Sha = 'd9ca6c453f286d7458a93465bb5caff5e515610647437467934c308dcc92b083' }
        @{ Id = 'wikdict-es-en'; Bytes = 987049; Sha = '883a8cd25c9ba918dc390abdcd676f8b8885f2f0ac685e4a2a0c5bd12fb4d9ea' }
    ) {
        $p = @($script:piezas | Where-Object { $_.Id -eq $Id })[0]
        $p.Sha256 | Should -Be $Sha
        [long]$p.Bytes | Should -Be $Bytes
    }

    It 'es-en se completa con el indice inverso de en-es, que es un StarDict' {
        $i = @(Get-DictionaryReverseIndexes -Catalog $script:catalogo -DictionaryDir 'C:\x\diccionario')
        $i.Count | Should -Be 1
        $i[0].Pair | Should -Be 'es-en'
        $i[0].From | Should -Be 'en-es'
        $i[0].Path | Should -Be 'C:\x\diccionario\inverso\es-en.tsv'
        @($script:piezas | Where-Object { $_.Pair -eq 'en-es' })[0].Formato | Should -Be 'stardict'
    }
}

Describe 'Resolve-DictionaryUrl y Get-DictionaryPieces' {
    It 'cambia el origen entre llaves por su direccion' {
        Resolve-DictionaryUrl -Url '{Datos}/a.zip' -Origins @{ Datos = 'https://example.org/r/' } | Should -Be 'https://example.org/r/a.zip'
    }

    It 'deja igual una Url sin llaves' {
        Resolve-DictionaryUrl -Url 'https://example.org/a.zip' -Origins @{} | Should -Be 'https://example.org/a.zip'
    }

    It 'un origen que no esta en Origenes es un error' {
        { Resolve-DictionaryUrl -Url '{Otro}/a.zip' -Origins @{ Datos = 'https://example.org' } } | Should -Throw '*Otro*'
    }

    It 'devuelve copias: el catalogo sigue con las llaves' {
        [void](Get-DictionaryPieces -Catalog $script:catalogo)
        $script:catalogo.Pares['en-es'].Bilingue.Url | Should -BeLike '{DatosDiccionario}*'
        $script:catalogo.Pares['en-es'].Bilingue.ContainsKey('Rol') | Should -BeFalse
    }

    It 'un idioma sin definiciones o un par sin bilingue no da piezas' {
        $cat = @{ Origenes = @{}; Idiomas = @{ es = @{} }; Pares = @{ 'es-en' = @{ Inverso = 'en-es' } } }
        @(Get-DictionaryPieces -Catalog $cat).Count | Should -Be 0
    }
}

Describe 'Install-DictionaryPiece' {
    It 'instala la carpeta del zip con el nombre de Destino, sin lo excluido y con su marca' {
        $d = New-TestDir
        $zip = Join-Path $d 'wn.zip'
        New-TestZip -Path $zip -Entries @{ 'oewn/' = ''; 'oewn/a.txt' = 'uno'; 'oewn/b.txt' = 'dos'; 'oewn/index.sense' = 'grande' }
        $p = New-TestPiece -Zip $zip -Destino 'wordnet' -Archivos @('a.txt', 'b.txt') -Excluir @('index.sense')
        $dic = Join-Path $d 'diccionario'

        Install-DictionaryPiece -ZipPath $zip -Piece $p -DictionaryDir $dic

        Get-Content -LiteralPath (Join-Path $dic 'wordnet\a.txt') -Raw | Should -Be 'uno'
        Test-Path -LiteralPath (Join-Path $dic 'wordnet\index.sense') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dic 'oewn') | Should -BeFalse
        $marca = Read-DictionaryMarker -Path (Join-Path $dic 'wordnet\pieza.txt')
        $marca.Sha256 | Should -Be $p.Sha256
        $marca.Id | Should -Be 'wordnet'
        $marca.Url | Should -Be $p.Url
        @(Get-ChildItem -LiteralPath $dic -Force | ForEach-Object { $_.Name }) | Should -Be @('wordnet')
    }

    It 'un zip con los archivos sueltos tambien sirve' {
        $d = New-TestDir
        $zip = Join-Path $d 'suelto.zip'
        New-TestZip -Path $zip -Entries @{ 'a.txt' = 'uno'; 'c.txt' = 'tres' }
        $p = New-TestPiece -Zip $zip -Destino 'suelto'
        Install-DictionaryPiece -ZipPath $zip -Piece $p -DictionaryDir (Join-Path $d 'dic')
        Test-Path -LiteralPath (Join-Path $d 'dic\suelto\c.txt') | Should -BeTrue
        Test-DictionaryPiece -Piece $p -DictionaryDir (Join-Path $d 'dic') | Should -BeTrue
    }

    It 'Test-DictionaryPiece: esta si la marca dice el mismo sha256 y estan todos los archivos' {
        $d = New-TestDir
        $zip = Join-Path $d 'p.zip'
        New-TestZip -Path $zip -Entries @{ 'p/a.txt' = 'uno'; 'p/b.txt' = 'dos' }
        $p = New-TestPiece -Zip $zip -Destino 'p' -Archivos @('a.txt', 'b.txt')
        $dic = Join-Path $d 'dic'

        Test-DictionaryPiece -Piece $p -DictionaryDir $dic | Should -BeFalse
        Install-DictionaryPiece -ZipPath $zip -Piece $p -DictionaryDir $dic
        Test-DictionaryPiece -Piece $p -DictionaryDir $dic | Should -BeTrue

        # Mayusculas en el catalogo: es el mismo sha256.
        $mayus = $p.Clone(); $mayus.Sha256 = $p.Sha256.ToUpperInvariant()
        Test-DictionaryPiece -Piece $mayus -DictionaryDir $dic | Should -BeTrue

        # El catalogo paso a otra version: hay que reemplazarla.
        $otra = $p.Clone(); $otra.Sha256 = 'f' * 64
        Test-DictionaryPiece -Piece $otra -DictionaryDir $dic | Should -BeFalse

        Remove-Item -LiteralPath (Join-Path $dic 'p\b.txt')
        Test-DictionaryPiece -Piece $p -DictionaryDir $dic | Should -BeFalse
    }

    It 'un zip con otro sha256 no se instala, y lo que habia queda igual' {
        $d = New-TestDir
        $bueno = Join-Path $d 'bueno.zip'
        New-TestZip -Path $bueno -Entries @{ 'p/a.txt' = 'version 1' }
        $p = New-TestPiece -Zip $bueno -Destino 'p'
        $dic = Join-Path $d 'dic'
        Install-DictionaryPiece -ZipPath $bueno -Piece $p -DictionaryDir $dic

        $malo = Join-Path $d 'malo.zip'
        New-TestZip -Path $malo -Entries @{ 'p/a.txt' = 'version 2' }
        { Install-DictionaryPiece -ZipPath $malo -Piece $p -DictionaryDir $dic } | Should -Throw '*no es el archivo esperado*'

        Get-Content -LiteralPath (Join-Path $dic 'p\a.txt') -Raw | Should -Be 'version 1'
        Test-DictionaryPiece -Piece $p -DictionaryDir $dic | Should -BeTrue
        @(Get-ChildItem -LiteralPath $dic -Force | ForEach-Object { $_.Name }) | Should -Be @('p')
    }

    It 'un zip al que le falta un archivo no se instala, y lo que habia queda igual' {
        $d = New-TestDir
        $v1 = Join-Path $d 'v1.zip'
        New-TestZip -Path $v1 -Entries @{ 'p/a.txt' = 'version 1'; 'p/b.txt' = 'b' }
        $p1 = New-TestPiece -Zip $v1 -Destino 'p' -Archivos @('a.txt', 'b.txt')
        $dic = Join-Path $d 'dic'
        Install-DictionaryPiece -ZipPath $v1 -Piece $p1 -DictionaryDir $dic

        $v2 = Join-Path $d 'v2.zip'
        New-TestZip -Path $v2 -Entries @{ 'p/a.txt' = 'version 2' }
        $p2 = New-TestPiece -Zip $v2 -Destino 'p' -Archivos @('a.txt', 'b.txt')
        { Install-DictionaryPiece -ZipPath $v2 -Piece $p2 -DictionaryDir $dic } | Should -Throw '*no trae b.txt*'

        Get-Content -LiteralPath (Join-Path $dic 'p\a.txt') -Raw | Should -Be 'version 1'
        Test-DictionaryPiece -Piece $p1 -DictionaryDir $dic | Should -BeTrue
        @(Get-ChildItem -LiteralPath $dic -Force | ForEach-Object { $_.Name }) | Should -Be @('p')
    }

    It 'una entrada que sale de la carpeta no se extrae' {
        $d = New-TestDir
        $zip = Join-Path $d 'fuera.zip'
        New-TestZip -Path $zip -Entries @{ 'p/a.txt' = 'uno'; '../../fuera.txt' = 'no' }
        $p = New-TestPiece -Zip $zip -Destino 'p'
        $dic = Join-Path $d 'dic'
        { Install-DictionaryPiece -ZipPath $zip -Piece $p -DictionaryDir $dic } | Should -Throw '*sale de la carpeta*'
        Test-Path -LiteralPath (Join-Path $d 'fuera.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dic 'p') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $dic -Force).Count | Should -Be 0
    }

    It 'reinstalar reemplaza la carpeta entera y no deja copias' {
        $d = New-TestDir
        $v1 = Join-Path $d 'v1.zip'
        New-TestZip -Path $v1 -Entries @{ 'p/a.txt' = 'version 1'; 'p/viejo.txt' = 'solo en la 1' }
        $dic = Join-Path $d 'dic'
        Install-DictionaryPiece -ZipPath $v1 -Piece (New-TestPiece -Zip $v1 -Destino 'p') -DictionaryDir $dic

        $v2 = Join-Path $d 'v2.zip'
        New-TestZip -Path $v2 -Entries @{ 'p/a.txt' = 'version 2' }
        $p2 = New-TestPiece -Zip $v2 -Destino 'p'
        Install-DictionaryPiece -ZipPath $v2 -Piece $p2 -DictionaryDir $dic

        Get-Content -LiteralPath (Join-Path $dic 'p\a.txt') -Raw | Should -Be 'version 2'
        Test-Path -LiteralPath (Join-Path $dic 'p\viejo.txt') | Should -BeFalse
        Test-DictionaryPiece -Piece $p2 -DictionaryDir $dic | Should -BeTrue
        @(Get-ChildItem -LiteralPath $dic -Force | ForEach-Object { $_.Name }) | Should -Be @('p')
    }

    It 'no acepta un Destino con ruta' {
        $d = New-TestDir
        $zip = Join-Path $d 'p.zip'
        New-TestZip -Path $zip -Entries @{ 'p/a.txt' = 'uno' }
        foreach ($destino in @('..\fuera', 'C:\fuera', 'a\b', '')) {
            $p = New-TestPiece -Zip $zip -Destino 'p'
            $p.Destino = $destino
            { Install-DictionaryPiece -ZipPath $zip -Piece $p -DictionaryDir (Join-Path $d 'dic') } | Should -Throw '*Destino no valido*' -Because $destino
        }
    }
}

Describe 'El indice inverso' {
    BeforeAll {
        $script:dirInv = New-TestDir
        $zip = Join-Path $script:dirInv 'wikdict-en-es.zip'
        New-TestStarDictZip -Path $zip -Folder 'wikdict-en-es' -Entries @(
            @{ Word = 'bank'; Html = '<div><ol><li>sloping land<div>orilla</div><div>ribera</div></li><li>institution<div>banco</div></li></ol></div>' }
            @{ Word = 'shore'; Html = '<div><ol><li>land along the water<div>orilla</div><div>costa</div></li></ol></div>' }
        )
        $script:enEs = New-TestPiece -Zip $zip -Destino 'wikdict-en-es' -Archivos @('stardict.ifo', 'stardict.idx', 'stardict.dict')
        $script:dicInv = Join-Path $script:dirInv 'diccionario'
        Install-DictionaryPiece -ZipPath $zip -Piece $script:enEs -DictionaryDir $script:dicInv
        $script:indice = @{ Pair = 'es-en'; From = 'en-es'; Path = (Join-Path $script:dicInv 'inverso\es-en.tsv') }
    }

    It 'se arma con el diccionario instalado de en-es y se busca' {
        Test-DictionaryReverseIndex -Index $script:indice -Source $script:enEs | Should -BeFalse
        $claves = Install-DictionaryReverseIndex -Index $script:indice -Source $script:enEs -DictionaryDir $script:dicInv
        $claves | Should -Be 4
        @(Find-ReverseTranslations -Path $script:indice.Path -Word 'orilla') | Should -Be @('bank', 'shore')
        @(Find-ReverseTranslations -Path $script:indice.Path -Word 'banco') | Should -Be @('bank')
        Test-Path -LiteralPath ($script:indice.Path + '.part') | Should -BeFalse
        Test-DictionaryReverseIndex -Index $script:indice -Source $script:enEs | Should -BeTrue
    }

    It 'su marca dice de que diccionario salio, su sha256 y la version del formato' {
        $marca = Read-DictionaryMarker -Path (Join-Path $script:dicInv 'inverso\es-en.txt')
        $marca.Desde | Should -Be 'en-es'
        $marca.Sha256 | Should -Be $script:enEs.Sha256
        $marca.Version | Should -Be '1'
        $marca.Claves | Should -Be '4'
    }

    It 'hay que rearmarlo si cambia el diccionario de origen o el formato del indice' {
        $otro = $script:enEs.Clone(); $otro.Sha256 = '0' * 64
        Test-DictionaryReverseIndex -Index $script:indice -Source $otro | Should -BeFalse

        $marca = Join-Path $script:dicInv 'inverso\es-en.txt'
        $texto = [IO.File]::ReadAllText($marca)
        try {
            [IO.File]::WriteAllText($marca, ($texto -replace 'Version=\d+', 'Version=0'))
            Test-DictionaryReverseIndex -Index $script:indice -Source $script:enEs | Should -BeFalse
        } finally {
            [IO.File]::WriteAllText($marca, $texto)
        }
    }

    It 'solo se arma con un StarDict' {
        $wn = $script:enEs.Clone(); $wn.Formato = 'wndb'
        { Install-DictionaryReverseIndex -Index $script:indice -Source $wn -DictionaryDir $script:dicInv } | Should -Throw '*StarDict*'
    }
}

Describe 'Get-InstalledDictionary' {
    BeforeAll {
        $script:dirIn = New-TestDir
        $zipBil = Join-Path $script:dirIn 'en-es.zip'
        New-TestStarDictZip -Path $zipBil -Folder 'wikdict-en-es' -Entries @(@{ Word = 'bank'; Html = '<div><ol><li>land<div>orilla</div></li></ol></div>' })
        $zipWn = Join-Path $script:dirIn 'wn.zip'
        New-TestZip -Path $zipWn -Entries @{ 'oewn/index.noun' = 'x' }
        $script:catIn = @{
            Origenes = @{}
            Idiomas  = @{ en = @{ Definiciones = (New-TestPiece -Zip $zipWn -Destino 'oewn' -Archivos @('index.noun') -Formato 'wndb') }; es = @{} }
            Pares    = @{
                'en-es' = @{ Bilingue = (New-TestPiece -Zip $zipBil -Destino 'wikdict-en-es' -Archivos @('stardict.ifo', 'stardict.idx', 'stardict.dict')) }
                'es-en' = @{ Inverso = 'en-es' }
            }
        }
        $script:zipBil = $zipBil
        $script:zipWn = $zipWn
        $script:dicIn = Join-Path $script:dirIn 'diccionario'
    }

    It 'sin nada instalado, todo vacio' {
        $r = Get-InstalledDictionary -Catalog $script:catIn -DictionaryDir $script:dicIn
        $r.Definitions.Count | Should -Be 0
        $r.Bilingual.Count | Should -Be 0
        $r.Reverse.Count | Should -Be 0
    }

    It 'cuenta solo lo instalado, con su carpeta y su formato, y el indice si esta al dia' {
        Install-DictionaryPiece -ZipPath $script:zipBil -Piece $script:catIn.Pares['en-es'].Bilingue -DictionaryDir $script:dicIn
        $r = Get-InstalledDictionary -Catalog $script:catIn -DictionaryDir $script:dicIn
        $r.Definitions.Count | Should -Be 0
        $r.Bilingual['en-es'].Dir | Should -Be (Join-Path $script:dicIn 'wikdict-en-es')
        $r.Bilingual['en-es'].Format | Should -Be 'stardict'
        $r.Reverse.Count | Should -Be 0

        $indice = @(Get-DictionaryReverseIndexes -Catalog $script:catIn -DictionaryDir $script:dicIn)[0]
        [void](Install-DictionaryReverseIndex -Index $indice -Source $script:catIn.Pares['en-es'].Bilingue -DictionaryDir $script:dicIn)
        Install-DictionaryPiece -ZipPath $script:zipWn -Piece $script:catIn.Idiomas.en.Definiciones -DictionaryDir $script:dicIn
        $r = Get-InstalledDictionary -Catalog $script:catIn -DictionaryDir $script:dicIn
        $r.Definitions.en.Dir | Should -Be (Join-Path $script:dicIn 'oewn')
        $r.Definitions.en.Format | Should -Be 'wndb'
        $r.Reverse['es-en'] | Should -Be (Join-Path $script:dicIn 'inverso\es-en.tsv')
    }

    It 'lo instalado se abre con la biblioteca y da la traduccion' {
        $r = Get-InstalledDictionary -Catalog $script:catIn -DictionaryDir $script:dicIn
        $sd = Open-StarDict -Dir $r.Bilingual['en-es'].Dir
        $sd.Words | Should -Be 1
        @(Find-ReverseTranslations -Path $r.Reverse['es-en'] -Word 'orilla') | Should -Be @('bank')
    }

    It 'una pieza de otra version no cuenta, ni su indice inverso' {
        $cat = @{ Origenes = @{}; Idiomas = @{}; Pares = @{ 'en-es' = @{ Bilingue = $script:catIn.Pares['en-es'].Bilingue.Clone() }; 'es-en' = @{ Inverso = 'en-es' } } }
        $cat.Pares['en-es'].Bilingue.Sha256 = 'a' * 64
        $r = Get-InstalledDictionary -Catalog $cat -DictionaryDir $script:dicIn
        $r.Bilingual.Count | Should -Be 0
        $r.Reverse.Count | Should -Be 0
    }
}

Describe 'setup.ps1 y el diccionario' {
    BeforeAll {
        $script:setupD = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\setup.ps1') -Raw
        $errores = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path (Join-Path $PSScriptRoot '..\setup.ps1')).Path, [ref]$null, [ref]$errores)
        $script:erroresSetupD = $errores
    }

    It 'se puede leer sin errores de sintaxis' {
        $script:erroresSetupD | Should -BeNullOrEmpty
    }

    It 'tiene -SkipDictionary y -OnlyDictionary, y lee config\idiomas.psd1 con la biblioteca del diccionario' {
        $script:setupD | Should -Match '\[switch\]\$SkipDictionary'
        $script:setupD | Should -Match '\[switch\]\$OnlyDictionary'
        $script:setupD | Should -Match "lib\\ReadAloud\.Dictionary\.ps1"
        $script:setupD | Should -Match "'idiomas\.psd1'"
    }

    It 'instala el diccionario por defecto, salvo con -SkipDictionary o -OnlyTranslation' {
        $script:setupD | Should -Match 'if \(-not \$SkipDictionary -and -not \$OnlyTranslation\) \{\s+if \(-not \(Install-Dictionary\)\)'
    }

    It 'con -OnlyDictionary no toca el motor, las voces ni la traduccion' {
        $script:setupD | Should -Match 'if \(-not \$OnlyTranslation -and -not \$OnlyDictionary\) \{\s+Write-Step .Motor Piper.'
        $script:setupD | Should -Match 'if \(-not \$SkipTranslation -and -not \$OnlyDictionary\) \{'
    }

    It 'cada pieza pasa por Install-DictionaryPiece, que comprueba el sha256 antes de extraer' {
        $f = [regex]::Match($script:setupD, '(?s)function Install-DictionaryItem \{.*?\n\}').Value
        $f | Should -Match 'Get-RemoteFile'
        $f.IndexOf('Install-DictionaryPiece -ZipPath') | Should -BeGreaterThan $f.IndexOf('Get-RemoteFile -Url')
        $lib = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\lib\ReadAloud.Dictionary.ps1') -Raw
        $g = [regex]::Match($lib, '(?s)function Install-DictionaryPiece \{.*?\n\}').Value
        $g.IndexOf('Get-FileHash') | Should -BeGreaterThan 0
        $g.IndexOf('Get-FileHash') | Should -BeLessThan $g.IndexOf('Expand-DictionaryZip')
    }

    It 'si falla el diccionario sale con 2, como la traduccion' {
        $f = [regex]::Match($script:setupD, '(?s)if \(-not \(Install-Dictionary\)\) \{.*?\n        \}').Value
        $f | Should -Match '\$exitCode = 2'
    }
}

Describe 'El asistente de instalacion y el diccionario' {
    BeforeAll {
        $script:iss = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\instalador\read_aloud.iss'), [Text.Encoding]::UTF8)
    }

    It 'tiene la tarea del diccionario, marcada' {
        $tarea = [regex]::Match($script:iss, '(?m)^Name: "dictionary";.*$').Value
        $tarea | Should -Not -BeNullOrEmpty
        $tarea | Should -Not -Match 'unchecked'
        $tarea | Should -Match '\{cm:TaskDictionary\}'
    }

    It 'dice 14 MB y las licencias, en espanol y en ingles' {
        foreach ($idioma in 'es', 'en') {
            $texto = [regex]::Match($script:iss, "(?m)^$idioma\.TaskDictionary=.*$").Value
            $texto | Should -Match '14 MB' -Because $idioma
            $texto | Should -Match 'CC BY 4\.0' -Because $idioma
            $texto | Should -Match 'CC BY-SA 4\.0' -Because $idioma
        }
    }

    It 'sin la tarea, pasa -SkipDictionary a setup.ps1' {
        $script:iss | Should -Match "if not WizardIsTaskSelected\('dictionary'\) then Result := ' -SkipDictionary';"
        $script:iss | Should -Match 'ArgumentosTraduccion \+ ArgumentosDiccionario'
    }

    It 'al desinstalar borra read_aloud_piper\diccionario' {
        $f = [regex]::Match($script:iss, '(?s)procedure CurUninstallStepChanged.*?\nend;').Value
        $f | Should -Match "DelTree\(ExpandConstant\('\{app\}\\read_aloud_piper\\diccionario'\)"
    }
}

Describe 'Rutas, repositorio y atribucion' {
    It 'Get-ReadAloudPaths pone el diccionario en read_aloud_piper\diccionario' {
        (Get-ReadAloudPaths -PiperBaseDir 'C:\x\piper').DictionaryDir | Should -Be 'C:\x\piper\diccionario'
    }

    It 'git no versiona lo que instala setup.ps1' {
        $ignorar = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\.gitignore')
        $ignorar | Should -Contain 'read_aloud_piper/diccionario/'
    }

    It 'NOTICE da la atribucion de cada fuente' {
        $notice = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\NOTICE') -Raw
        foreach ($p in $script:piezas) {
            $notice | Should -Match ([regex]::Escape($p.Fuente)) -Because $p.Id
            $notice | Should -Match ([regex]::Escape($p.Licencia)) -Because $p.Id
        }
        $notice | Should -Match 'Open English Wordnet is derived from Princeton WordNet'
        $notice | Should -Match 'WikDict by Karl Bartel'
        $notice | Should -Match 'datos-diccionario-2026-11'
    }
}
