@echo off
setlocal ENABLEDELAYEDEXPANSION

if "%~1"=="help" goto help
if "%~1"=="update" (
    yt-dlp.exe -U
    endlocal
    exit /b %ERRORLEVEL%
)
if "%~1"=="" goto usage

set "URL=%*"
echo Downloading audio...
yt-dlp.exe ^
  -f "bestaudio[ext=m4a]" ^
  -o "%%(title)s.%%(ext)s" ^
  "%URL%"

endlocal
exit /b 0

:help
echo.
echo Usage: %~n0 ^<YouTube URL^> or %~n0 ^<help^|update^>
echo.
echo Downloads best m4a audio to current directory using yt-dlp config.
echo.
echo Examples:
echo - %~n0 https://youtube.com/watch?v=abc123
echo - %~n0 update
echo - %~n0 help
echo.
echo Requires yt-dlp.exe on PATH.
echo.
endlocal
exit /b 0

:usage
echo Usage: %~n0 ^<YouTube URL^>
endlocal
exit /b 1
