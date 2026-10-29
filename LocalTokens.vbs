' LocalTokens - starts the app without a console window.
' Double-click this file. To stop it, use Exit in the tray icon's menu.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & dir & "\src\LocalTokens.ps1""", 0, False
