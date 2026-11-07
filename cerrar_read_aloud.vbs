' Cierra Read Aloud del todo: el proceso residente, los atajos y el icono de la
' bandeja. Es lo que abre el acceso directo "Cerrar Read Aloud".
Set fso = CreateObject("Scripting.FileSystemObject")
carpeta = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & carpeta & "\read_aloud.ps1"" -Quit", 0, True
