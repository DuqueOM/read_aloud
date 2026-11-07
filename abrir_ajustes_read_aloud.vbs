' Abre los ajustes de Read Aloud sin leer nada: arranca el programa si no esta
' abierto y le pide la ventana de ajustes. Es lo que abre el acceso directo del
' escritorio. La ventana se queda hasta que la cierras; Read Aloud sigue activo
' hasta que lo cierras con "Cerrar Read Aloud".
Set fso = CreateObject("Scripting.FileSystemObject")
carpeta = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & carpeta & "\read_aloud.ps1"" -ShowSettings", 0, False
