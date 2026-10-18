@echo off
setlocal ENABLEDELAYEDEXPANSION

if "%~1"=="help" goto help
if "%~1"=="update" (
    yt-dlp.exe -U
    endlocal
    exit /b %ERRORLEVEL%
)
if "%~1"=="" goto usage

set "URL=%~1"
set "SCRIPT_DIR=%~dp0"

rem Default: crop config
set "CONF=%SCRIPT_DIR%yt-dlp-crop.conf"

rem Optional second arg: -scale => use scale config
if /I "%~2"=="-scale" (
    set "CONF=%SCRIPT_DIR%yt-dlp-scale.conf"
)

echo Using config: %CONF%
yt-dlp.exe ^
  --config-location "%CONF%" ^
  --download-archive "_downloaded.log" ^
  -o "%%(title)s.%%(ext)s" ^
  "%URL%"

endlocal
exit /b 0

:help
echo.
echo Usage: %~n0 ^<YouTube URL^> [-scale] or %~n0 ^<help^|update^>
echo.
echo Downloads using yt-dlp config files (crop.conf or scale.conf).
echo.
echo Examples:
echo - %~n0 https://youtube.com/watch?v=abc123          ^(uses crop.conf^)
echo - %~n0 https://youtube.com/watch?v=abc123 -scale   ^(uses scale.conf^)
echo - %~n0 update
echo - %~n0 help
echo.
echo Config files must be in same folder as this .bat file.
echo Requires yt-dlp.exe on PATH.
echo.
endlocal
exit /b 0

:usage
echo Usage: %~n0 ^<YouTube URL^> [-scale]
endlocal
exit /b 1
