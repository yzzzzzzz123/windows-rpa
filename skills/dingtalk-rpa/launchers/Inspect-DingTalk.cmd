@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "%~dp0..\scripts\Invoke-DingTalkRpa.ps1" -Mode Inspect -WaitForKey
exit /b %errorlevel%
