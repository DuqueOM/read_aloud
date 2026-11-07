' Arranca Read Aloud sin mostrar ninguna ventana. Es lo que abre el acceso
' directo del menu Inicio; si ya esta abierto, no hace nada.
Set fso = CreateObject("Scripting.FileSystemObject")
carpeta = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & carpeta & "\read_aloud_daemon.ps1""", 0, False
