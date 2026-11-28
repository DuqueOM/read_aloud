#
# ReadAloud.Translators.ps1
# Los procesos de la traduccion rapida (ADR 0016): translateLocally en modo
# -p (Bergamot) y llama-server (los modelos de lenguaje), y la foto del
# equipo que necesita Select-TranslationCombo. Lo usa el hilo de traduccion
# del proceso residente; la logica que decide va en ReadAloud.Translate.ps1.
#
# Necesita lib\ReadAloud.Translate.ps1 cargado antes.
#
# Solo clases de .NET, sin cmdlets de modulos como los de CIM: el hilo corre
# en Windows PowerShell 5.1, y la carga automatica de modulos falla si el
# proceso hereda la ruta de modulos de otra version de PowerShell.
#
# Solo ASCII: el archivo se carga tambien desde Windows PowerShell 5.1.

# --------------------------------------------------------------------------
# Foto del equipo.
# --------------------------------------------------------------------------

function Get-RamAvailableMiB {
    # La RAM disponible, la misma cifra que el contador \Memory\Available
    # MBytes (GlobalMemoryStatusEx). 0 si no se puede leer.
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        return [double]((New-Object Microsoft.VisualBasic.Devices.ComputerInfo).AvailablePhysicalMemory / 1MB)
    } catch {
        return 0.0
    }
}

function Get-PhysicalCoreCount {
    # Los nucleos fisicos de todos los procesadores. Si WMI no responde, la
    # mitad de los procesadores logicos.
    try {
        Add-Type -AssemblyName System.Management -ErrorAction Stop
        $buscador = New-Object Management.ManagementObjectSearcher('SELECT NumberOfCores FROM Win32_Processor')
        $n = 0
        foreach ($p in $buscador.Get()) { $n += [int]$p['NumberOfCores'] }
        $buscador.Dispose()
        if ($n -gt 0) { return $n }
    } catch { }
    return [int][Math]::Max(1, [Math]::Floor([Environment]::ProcessorCount / 2))
}

function Get-NvidiaMemory {
    # La memoria de la tarjeta NVIDIA segun nvidia-smi (FreeMiB, UsedMiB,
    # TotalMiB). Sin nvidia-smi, FreeMiB es -1.
    param([string]$Smi)

    if (-not $Smi) { return @{ FreeMiB = -1.0; UsedMiB = 0.0; TotalMiB = 0.0 } }
    try {
        $lineas = @(& $Smi '--query-gpu=memory.free,memory.used,memory.total' '--format=csv,noheader,nounits' 2>$null)
        return ConvertFrom-NvidiaSmiMemory -Lines $lineas
    } catch {
        return @{ FreeMiB = -1.0; UsedMiB = 0.0; TotalMiB = 0.0 }
    }
}

function Get-TranslateDeviceSnapshot {
    # Lo que Select-TranslationCombo necesita saber del equipo en este
    # momento, y la memoria usada de la tarjeta (para ceder la tarjeta).
    param(
        [string]$Smi,
        [string]$BusyFile,
        [int]$PhysicalCores
    )

    $gpu = Get-NvidiaMemory -Smi $Smi
    return @{
        RamAvailableMiB = Get-RamAvailableMiB
        GpuFreeMiB      = [double]$gpu.FreeMiB
        GpuUsedMiB      = [double]$gpu.UsedMiB
        GpuBusy         = (Test-GpuBusyFile -BusyFile $BusyFile)
        PhysicalCores   = $PhysicalCores
    }
}

# --------------------------------------------------------------------------
# Bergamot con translateLocally -p: mensajes JSON con su largo delante.
# --------------------------------------------------------------------------

function Read-ExactBytes {
    # Lee Count bytes del flujo o lanza un error si se cierra o si pasa
    # TimeoutMs: un traductor colgado no debe dejar el hilo esperando siempre.
    param(
        [IO.Stream]$Stream,
        [int]$Count,
        [int]$TimeoutMs = 30000
    )

    $buf = New-Object byte[] $Count
    $leidos = 0
    $limite = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($leidos -lt $Count) {
        $resta = [int][Math]::Max(1, ($limite - [DateTime]::UtcNow).TotalMilliseconds)
        $tarea = $Stream.ReadAsync($buf, $leidos, $Count - $leidos)
        if (-not $tarea.Wait($resta)) { throw "El traductor no respondio en $TimeoutMs ms." }
        if ($tarea.Result -le 0) { throw 'El traductor cerro su salida.' }
        $leidos += $tarea.Result
    }
    return ,$buf
}

function Read-BergamotMessage {
    # Una respuesta de translateLocally -p: 4 bytes de largo (little-endian)
    # y el JSON en UTF-8.
    param(
        [IO.Stream]$Stream,
        [int]$TimeoutMs = 30000
    )

    $cabeza = Read-ExactBytes -Stream $Stream -Count 4 -TimeoutMs $TimeoutMs
    if (-not [BitConverter]::IsLittleEndian) { [Array]::Reverse($cabeza) }
    $largo = [BitConverter]::ToUInt32($cabeza, 0)
    if ($largo -eq 0 -or $largo -gt 67108864) { throw "Respuesta de translateLocally con un largo raro: $largo bytes." }
    $cuerpo = Read-ExactBytes -Stream $Stream -Count ([int]$largo) -TimeoutMs $TimeoutMs
    return ((New-Object Text.UTF8Encoding($false)).GetString($cuerpo) | ConvertFrom-Json)
}

function Set-BergamotThreads {
    # translateLocally lee sus hilos al arrancar de su clave en HKCU
    # (Software\translateLocally\translateLocally, valor cpu_cores). Sin el
    # valor usa todos los del procesador y frena la voz propia un 55 %. Solo
    # se escribe si cambia. Devuelve $true si quedo como se pidio.
    param(
        [int]$Threads,
        [string]$SubKey = 'Software\translateLocally\translateLocally'
    )

    $clave = $null
    try {
        $clave = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKey)
        $actual = $clave.GetValue('cpu_cores', $null)
        if ($null -eq $actual -or [int]$actual -ne $Threads -or $clave.GetValueKind('cpu_cores') -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
            $clave.SetValue('cpu_cores', [int]$Threads, [Microsoft.Win32.RegistryValueKind]::DWord)
        }
        return $true
    } catch {
        return $false
    } finally {
        if ($clave) { $clave.Dispose() }
    }
}

function Disable-StdinPreamble {
    # Windows PowerShell 5.1 abre la entrada de un proceso con la codificacion
    # de la consola y, con la consola en UTF-8 (65001), escribe primero la
    # marca BOM (EF BB BF). translateLocally la leeria como parte del largo
    # del primer mensaje y se cerraria. Se cambia por UTF-8 sin marca: la
    # pagina de codigos es la misma. PowerShell 7 ya la quita sola.
    try {
        $actual = [Console]::InputEncoding
        if ($actual.CodePage -eq 65001 -and $actual.GetPreamble().Length -gt 0) {
            [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
        }
    } catch { }
}

function Start-BergamotProcess {
    # Abre translateLocally -p con 4 hilos (o los que se pidan). El modelo de
    # cada direccion se carga con su primera traduccion (0.3 s).
    param(
        [string]$Exe,
        [int]$Threads
    )

    [void](Set-BergamotThreads -Threads $Threads)
    Disable-StdinPreamble

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = '-p'
    $psi.WorkingDirectory = (Split-Path -Parent $Exe)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    # Su salida de error no se redirige: si nadie la leyera, terminaria por
    # bloquearlo.
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $true

    $p = [Diagnostics.Process]::Start($psi)
    return @{
        Process = $p
        In      = $p.StandardInput.BaseStream
        Out     = $p.StandardOutput.BaseStream
        NextId  = 1
        Threads = $Threads
    }
}

function Invoke-BergamotTranslate {
    # Traduce un texto y devuelve la traduccion. Las respuestas de avance
    # (update) y las de otras ordenes se saltan.
    param(
        [hashtable]$Client,
        [string]$Text,
        [string]$Source,
        [string]$Target,
        [int]$TimeoutMs = 30000
    )

    $id = [int]$Client.NextId
    $Client.NextId = $id + 1
    $mensaje = ConvertTo-BergamotMessage -Id $id -Command 'Translate' -Data (Get-BergamotTranslateData -Text $Text -Source $Source -Target $Target)
    $Client.In.Write($mensaje, 0, $mensaje.Length)
    $Client.In.Flush()

    while ($true) {
        $r = Read-BergamotMessage -Stream $Client.Out -TimeoutMs $TimeoutMs
        if ($r.update -eq $true) { continue }
        if ([int]$r.id -ne $id) { continue }
        if ($r.success -ne $true) { throw ('Bergamot no pudo traducir: {0}' -f $r.error) }
        return [string]$r.data.target.text
    }
}

function Stop-TranslatorProcess {
    # Cierra un traductor: primero su entrada (translateLocally termina
    # solo), y si sigue vivo, a la fuerza.
    param(
        [Diagnostics.Process]$Process,
        $Stdin = $null,
        [int]$WaitMs = 3000
    )

    if ($null -eq $Process) { return }
    if ($null -ne $Stdin) { try { $Stdin.Close() } catch { } }
    try {
        if (-not $Process.HasExited -and -not $Process.WaitForExit($WaitMs)) { $Process.Kill() }
        [void]$Process.WaitForExit(5000)
    } catch { }
    try { $Process.Dispose() } catch { }
}

# --------------------------------------------------------------------------
# llama-server.
# --------------------------------------------------------------------------

function Get-FreeTcpPort {
    # Un puerto libre en 127.0.0.1, para no chocar con otro programa.
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start()
    try { return [int]$l.LocalEndpoint.Port } finally { $l.Stop() }
}

function Get-VulkanNvidiaDevice {
    # El dispositivo Vulkan de la NVIDIA ("Vulkan0"), segun
    # llama-server --list-devices. '' si no hay o si no responde.
    param([string]$Server, [int]$TimeoutMs = 20000)

    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $Server
        $psi.Arguments = '--list-devices'
        $psi.WorkingDirectory = (Split-Path -Parent $Server)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi)
        # Las dos salidas a la vez, para que ninguna se llene y lo bloquee.
        $salida = $p.StandardOutput.ReadToEndAsync()
        $errores = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch { }; return '' }
        [void]$salida.Wait(2000)
        [void]$errores.Wait(2000)
        $texto = ([string]$salida.Result) + "`n" + ([string]$errores.Result)
        $p.Dispose()
        return ConvertFrom-VulkanDeviceList -Lines ($texto -split "`r?`n")
    } catch {
        return ''
    }
}

function Start-LlamaServer {
    # Abre llama-server con los argumentos de Get-LlamaServerArgs. Su registro
    # va al archivo de --log-file; sus salidas no se redirigen, para que no se
    # llenen y lo bloqueen.
    param(
        [string]$Exe,
        [string[]]$Arguments
    )

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ConvertTo-CommandLine -Arguments $Arguments
    $psi.WorkingDirectory = (Split-Path -Parent $Exe)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($psi)
}

function New-LocalRequest {
    # Una peticion a llama-server sin proxy (buscar uno puede tardar segundos)
    # y sin la espera de "100-continue" en los POST.
    param([int]$Port, [string]$Path, [int]$TimeoutMs)

    $r = [Net.HttpWebRequest]::Create(('http://127.0.0.1:{0}{1}' -f $Port, $Path))
    $r.Proxy = $null
    $r.Timeout = $TimeoutMs
    $r.ReadWriteTimeout = $TimeoutMs
    $r.ServicePoint.Expect100Continue = $false
    return $r
}

function Test-LlamaServerHealth {
    # /health responde 200 con "ok" cuando el modelo ya cargo (503 mientras).
    param([int]$Port)

    $resp = $null
    try {
        $resp = (New-LocalRequest -Port $Port -Path '/health' -TimeoutMs 2000).GetResponse()
        $texto = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
        return ($texto -match '"status"\s*:\s*"ok"')
    } catch {
        return $false
    } finally {
        if ($resp) { try { $resp.Close() } catch { } }
    }
}

function Wait-LlamaServerReady {
    # Espera a que el modelo cargue. Devuelve los segundos que tardo, o lanza
    # un error si el proceso termina o pasa TimeoutSeconds.
    param(
        [Diagnostics.Process]$Process,
        [int]$Port,
        [double]$TimeoutSeconds = 180,
        [hashtable]$Sync = $null
    )

    $reloj = [Diagnostics.Stopwatch]::StartNew()
    while ($reloj.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($Process.HasExited) { throw ('llama-server termino al cargar el modelo (codigo {0}).' -f $Process.ExitCode) }
        if ($null -ne $Sync -and $Sync.Stopping) { throw 'El lector se esta cerrando.' }
        if (Test-LlamaServerHealth -Port $Port) { return $reloj.Elapsed.TotalSeconds }
        Start-Sleep -Milliseconds 150
    }
    throw ('llama-server no cargo el modelo en {0:N0} s.' -f $TimeoutSeconds)
}

function Invoke-LlamaTranslate {
    # Traduce una parte con streaming. Devuelve Text, FirstTokenSeconds,
    # Seconds y los tiempos que informa el servidor (Timings).
    param(
        [int]$Port,
        [string]$Family,
        [string]$Text,
        [string]$Source,
        [string]$Target,
        [int]$TimeoutSeconds = 300
    )

    $peticion = Get-TranslationRequest -Family $Family -Text $Text -Source $Source -Target $Target
    $json = ConvertTo-Json -InputObject $peticion.Body -Compress -Depth 6
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)

    $reloj = [Diagnostics.Stopwatch]::StartNew()
    $req = New-LocalRequest -Port $Port -Path $peticion.Path -TimeoutMs ($TimeoutSeconds * 1000)
    $req.Method = 'POST'
    $req.ContentType = 'application/json; charset=utf-8'
    $req.ContentLength = $bytes.Length
    $cuerpo = $req.GetRequestStream()
    try { $cuerpo.Write($bytes, 0, $bytes.Length) } finally { $cuerpo.Close() }

    $resp = $req.GetResponse()
    $texto = New-Object Text.StringBuilder
    $primero = -1.0
    $tiempos = $null
    try {
        $lector = New-Object IO.StreamReader($resp.GetResponseStream(), (New-Object Text.UTF8Encoding($false)))
        while ($null -ne ($linea = $lector.ReadLine())) {
            if ($linea.Trim() -eq 'data: [DONE]') { break }
            $d = ConvertFrom-TranslationStreamLine -Line $linea -Family $Family
            if ($null -eq $d) { continue }
            if ($d.Text) {
                if ($primero -lt 0) { $primero = $reloj.Elapsed.TotalSeconds }
                [void]$texto.Append($d.Text)
            }
            if ($null -ne $d.Timings) { $tiempos = $d.Timings }
        }
    } finally {
        try { $resp.Close() } catch { }
    }

    return @{
        Text              = $texto.ToString()
        FirstTokenSeconds = $primero
        Seconds           = $reloj.Elapsed.TotalSeconds
        Timings           = $tiempos
    }
}

function Stop-OrphanTranslators {
    # Cierra los llama-server.exe y translateLocally.exe de esta carpeta de
    # traductores que quedaron abiertos (de un proceso residente cerrado a la
    # fuerza). Los de otras carpetas no se tocan. Devuelve "nombre pid" de
    # cada uno.
    param([string]$TranslateDir)

    if (-not $TranslateDir) { return }
    $prefijo = [IO.Path]::GetFullPath($TranslateDir).TrimEnd('\') + '\'
    foreach ($nombre in @('llama-server', 'translateLocally')) {
        foreach ($p in [Diagnostics.Process]::GetProcessesByName($nombre)) {
            try {
                $ruta = $p.MainModule.FileName
                if ($ruta -and $ruta.StartsWith($prefijo, [StringComparison]::OrdinalIgnoreCase)) {
                    $p.Kill()
                    [void]$p.WaitForExit(5000)
                    '{0} {1}' -f $nombre, $p.Id
                }
            } catch { } finally { $p.Dispose() }
        }
    }
}

function Set-GpuReserveFile {
    # Le dice a la voz propia (lib\servidor_qwen.py --reserva) cuanto ocupa en
    # la tarjeta el traductor de Read Aloud, para que no lo tome por otro
    # programa y ceda la tarjeta por error: "pid MiB". Sin Process, lo borra.
    param(
        [string]$Path,
        [Diagnostics.Process]$Process = $null,
        [double]$MiB = 0
    )

    if (-not $Path) { return }
    try {
        if ($null -eq $Process -or $MiB -le 0) {
            if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
            return
        }
        $texto = '{0} {1}' -f $Process.Id, ([Math]::Ceiling($MiB)).ToString([Globalization.CultureInfo]::InvariantCulture)
        [IO.File]::WriteAllText($Path, $texto, (New-Object Text.ASCIIEncoding))
    } catch { }
}
