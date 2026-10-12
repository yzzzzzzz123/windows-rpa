@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "%~dp0scripts\Invoke-Rpa.ps1" -Scenario DouyinComment -Publish -Continuous -MaxVideos 0 -WaitForKey
exit /b %errorlevel%
