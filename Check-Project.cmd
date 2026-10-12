@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "%~dp0tests\Verify-Project.ps1"
set "CHECK_RESULT=%errorlevel%"
pause
exit /b %CHECK_RESULT%
