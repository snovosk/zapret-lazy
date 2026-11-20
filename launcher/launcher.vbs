' launcher.vbs — zero-visibility bootstrapper for zapret-autopilot.
' Usage: wscript.exe launcher.vbs [engine|tray]   (default: engine)
'   engine -> powershell -File <project>\src\Autopilot.ps1
'   tray   -> powershell -File <project>\tray\TrayApp.ps1
' Script directory is resolved at runtime; no absolute paths are hardcoded.
' The mode argument is untrusted input: only "engine" and "tray" are accepted
' and anything else falls back to the engine — the argument is never copied
' into the command line beyond the whitelist decision. Target scripts are
' normalized to absolute paths via FileSystemObject.GetAbsolutePathName.

Option Explicit

Dim fso, shell, scriptDir, mode, targetScript, targetPath, cmdLine

Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

mode = "engine"
If WScript.Arguments.Count > 0 Then
    mode = LCase(Trim(WScript.Arguments(0)))
End If

Select Case mode
    Case "engine"
        targetScript = "src\Autopilot.ps1"
    Case "tray"
        targetScript = "tray\TrayApp.ps1"
    Case Else
        ' Unrecognized modes fall back to the engine.
        targetScript = "src\Autopilot.ps1"
End Select

targetPath = fso.GetAbsolutePathName(fso.BuildPath(scriptDir, targetScript))

cmdLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass " & _
          "-WindowStyle Hidden -File """ & targetPath & """"

Set shell = CreateObject("WScript.Shell")
' 0 = hidden window, False = do not wait for the process to finish.
shell.Run cmdLine, 0, False

Set shell = Nothing
Set fso = Nothing
