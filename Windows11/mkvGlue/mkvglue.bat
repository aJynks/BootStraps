@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0mkvglue_script.ps1" %*
exit /b %ERRORLEVEL%
