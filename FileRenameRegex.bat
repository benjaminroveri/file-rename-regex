@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0FileRenameRegex.ps1" %*
exit /b %ERRORLEVEL%
