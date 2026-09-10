#Requires AutoHotkey v2.0
#SingleInstance Force

scriptPath := "C:\ruta\a\read_aloud\read_aloud.ps1"
stopPath := "C:\ruta\a\read_aloud\stop_read_aloud.ps1"

^+v:: {
    saved := ClipboardAll()
    A_Clipboard := ""
    Send("^c")
    if !ClipWait(0.6) {
        A_Clipboard := saved
    }
    if (Trim(A_Clipboard) = "") {
        A_Clipboard := saved
        return
    }
    Run('powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' scriptPath '" -NoPreview -Engine Auto -Language Spanish', , "Hide")
}

^+q:: {
    RunWait('powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' stopPath '"', , "Hide")
}
