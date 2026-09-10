$ErrorActionPreference = 'SilentlyContinue'
Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -like '*read_aloud.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Get-Process piper -ErrorAction SilentlyContinue | Stop-Process -Force
