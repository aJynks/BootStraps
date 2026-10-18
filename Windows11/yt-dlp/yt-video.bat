@echo off
setlocal
REM yt-video.bat - single YouTube video downloader
REM Backend: yt-downloader_script.py (must sit next to this .bat)

where python >nul 2>&1
if errorlevel 1 (
    echo Error: python not found on PATH.
    echo Install: winget install Python.Python.3.12
    endlocal & exit /b 9009
)

python "%~dp0yt-downloader_script.py" video %*
endlocal & exit /b %ERRORLEVEL%
