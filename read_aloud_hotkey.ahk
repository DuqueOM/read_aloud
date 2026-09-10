#Requires AutoHotkey v2.0
#SingleInstance Force

; Atajos de teclado de Read Aloud.
;
;   Ctrl+Shift+V        Lee en voz alta lo que este seleccionado
;   Ctrl+Shift+Q        Detiene la lectura
;   Ctrl+Shift+Espacio  Pausa o continua
;   Ctrl+Shift+,        Retrocede 10 segundos
;   Ctrl+Shift+.        Avanza 10 segundos
;
; El atajo habla directamente con el proceso residente por una tuberia con
; nombre. No arranca PowerShell, y por eso la respuesta es inmediata. Solo si
; el proceso no esta escuchando se recurre a PowerShell, que lo levanta.
;
; Las rutas se calculan desde la carpeta de este archivo, asi que el repositorio
; funciona igual en cualquier equipo sin editar nada.

scriptPath := A_ScriptDir . "\read_aloud.ps1"
daemonPath := A_ScriptDir . "\read_aloud_daemon.ps1"
pipePath   := "\\.\pipe\read_aloud_pipe"

; Deja el proceso residente listo al cargar los atajos, para que la primera
; lectura del dia tampoco tenga que esperar.
StartDaemon()

^+v:: ReadSelection()
^+q:: SendCommand('{"cmd":"stop"}')
^+Space:: SendCommand('{"cmd":"toggle"}')
^+,:: SendCommand('{"cmd":"back"}')
^+.:: SendCommand('{"cmd":"forward"}')

ReadSelection() {
    saved := ClipboardAll()
    A_Clipboard := ""
    Send("^c")

    if !ClipWait(0.6) {
        A_Clipboard := saved
        return
    }

    text := A_Clipboard
    A_Clipboard := saved

    if (Trim(text) = "")
        return

    payload := '{"cmd":"speak","lang":"Auto","text":"' . JsonEscape(text) . '"}'

    if !SendCommand(payload)
        RunFallback(text)
}

; Manda una linea JSON al proceso residente. Devuelve true si la recibio.
SendCommand(payload) {
    global pipePath

    ; El servidor atiende una conexion a la vez y vuelve a abrir la tuberia
    ; enseguida. Un par de reintentos cubre esa rendija de milisegundos.
    loop 5 {
        try {
            pipe := FileOpen(pipePath, "rw", "UTF-8-RAW")

            if IsObject(pipe) {
                pipe.Write(payload . "`n")
                pipe.Close()
                return true
            }
        }

        Sleep(25)
    }

    return false
}

; Camino de respaldo: PowerShell lee el portapapeles y levanta el residente.
RunFallback(text) {
    global scriptPath

    previous := ClipboardAll()
    A_Clipboard := text

    Run('powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'
        . scriptPath . '" -NoPreview', , "Hide")

    ; Se le da un momento para leer el portapapeles antes de devolverlo.
    SetTimer(() => RestoreClipboard(previous), -1500)
}

RestoreClipboard(previous) {
    A_Clipboard := previous
}

StartDaemon() {
    global daemonPath

    if SendCommand('{"cmd":"ping"}')
        return

    Run('powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'
        . daemonPath . '"', , "Hide")
}

; JSON admite muy pocos caracteres crudos. Se escapan los obligatorios y se
; descartan los de control que el portapapeles a veces arrastra.
JsonEscape(text) {
    text := StrReplace(text, "\", "\\")
    text := StrReplace(text, '"', '\"')
    text := StrReplace(text, "`r", "\r")
    text := StrReplace(text, "`n", "\n")
    text := StrReplace(text, "`t", "\t")
    text := RegExReplace(text, "[\x00-\x08\x0B\x0C\x0E-\x1F]", "")
    return text
}
