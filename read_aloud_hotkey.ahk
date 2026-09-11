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
;
; Se usa CreateFileW y no FileOpen: FileOpen intenta crear el archivo si no
; existe, y sobre una tuberia con nombre eso falla o se queda colgado.
; OPEN_EXISTING es la unica forma correcta de abrir una tuberia.
SendCommand(payload) {
    global pipePath

    ; Solo escritura: la tuberia del proceso residente es de una sola
    ; direccion, y pedir lectura tambien la abriria con permisos denegados.
    static GENERIC_WRITE := 0x40000000
    static OPEN_EXISTING := 3

    ; El servidor vuelve a abrir la tuberia despues de cada conexion. Un par de
    ; reintentos cubre esa rendija de milisegundos.
    loop 5 {
        handle := DllCall("CreateFileW", "Str", pipePath
            , "UInt", GENERIC_WRITE
            , "UInt", 0, "Ptr", 0, "UInt", OPEN_EXISTING, "UInt", 0, "Ptr", 0, "Ptr")

        if (handle != -1) {
            linea := payload . "`n"
            bytes := StrPut(linea, "UTF-8") - 1

            ; El nombre no puede ser "buffer": AutoHotkey no distingue
            ; mayusculas y chocaria con la clase Buffer, que es de solo lectura.
            datos := Buffer(bytes + 1)
            StrPut(linea, datos, "UTF-8")

            escritos := 0
            correcto := DllCall("WriteFile", "Ptr", handle, "Ptr", datos
                , "UInt", bytes, "UInt*", &escritos, "Ptr", 0)

            DllCall("CloseHandle", "Ptr", handle)
            return correcto && escritos = bytes
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
