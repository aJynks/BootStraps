@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0mp4cut_script.ps1" %*
exit /b %ERRORLEVEL%
