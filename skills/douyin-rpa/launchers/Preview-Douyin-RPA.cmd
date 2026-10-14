@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "%~dp0..\scripts\Invoke-DouyinRpa.ps1" -MaxVideos 1 -WaitForKey
exit /b %errorlevel%
