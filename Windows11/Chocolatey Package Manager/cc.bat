@echo off

:: Run Chocolatey elevated
gsudo choco %*

:: Always refresh environment silently
call refreshenv >nul 2>&1
