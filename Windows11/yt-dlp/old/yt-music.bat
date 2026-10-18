@echo off
setlocal EnableDelayedExpansion

REM ============================================================
REM yt-music.bat (combined)
REM ============================================================
REM Commands (arg1):
REM   help    -> show BAT help (no yt-dlp call)
REM   update  -> yt-dlp.exe -U
REM   --help  -> yt-dlp.exe --help
REM
REM Download usage:
REM   yt-music <URL>
REM   yt-music <URL> -scale
REM   yt-music <URL> --extra <yt-dlp args...>
REM   yt-music <URL> -scale --extra <yt-dlp args...>
REM
REM Behavior:
REM   - Detect playlist URLs (contains "list=") and ask confirmation
REM   - Detect channel URLs (/@handle, /channel/, /c/, /user/) and proceed
REM   - Default uses crop config; -scale switches to scale config
REM   - If --extra is present after URL (and optional -scale), all following args
REM     are appended to the yt-dlp command line
REM ============================================================

REM ----- 1) Hard commands: do one thing and exit -----
if /I "%~1"=="help"  goto :bat_help
if /I "%~1"=="update" goto :do_update
if /I "%~1"=="--help" goto :do_ytdlp_help

REM ----- URL required -----
if "%~1"=="" goto :usage
set "URL=%~1"
set "SCRIPT_DIR=%~dp0"

REM ----- Config selection -----
set "CONF=%SCRIPT_DIR%yt-dlp-crop.conf"

REM Parse optional flags after URL
set "EXTRA_ARGS="
set "REST1=%~2"
set "REST2=%~3"

REM Optional -scale (must be immediately after URL)
if /I "%~2"=="-scale" (
    set "CONF=%SCRIPT_DIR%yt-dlp-scale.conf"
    shift
)

REM Optional --extra (must be next, if present)
if /I "%~2"=="--extra" (
    shift
    :gather_extra
    if "%~2"=="" goto :after_parse
    set "EXTRA_ARGS=!EXTRA_ARGS! %~2"
    shift
    goto :gather_extra
)

:after_parse

REM Reject anything else after URL (and optional -scale) unless it came after --extra
if not "%~2"=="" (
    echo Error: Unexpected argument "%~2"
    echo Only "-scale" and/or "--extra <args...>" are allowed after the URL.
    echo.
    goto :usage
)

REM ----- Detect playlist vs channel vs single -----
set "IS_PLAYLIST=0"
set "IS_CHANNEL=0"

echo %URL% | findstr /I "list=" >nul && set "IS_PLAYLIST=1"

REM Simple channel URL heuristics
echo %URL% | findstr /I "/channel/" >nul && set "IS_CHANNEL=1"
echo %URL% | findstr /I "/user/"    >nul && set "IS_CHANNEL=1"
echo %URL% | findstr /I "/c/"       >nul && set "IS_CHANNEL=1"
echo %URL% | findstr /I "youtube.com/@" >nul && set "IS_CHANNEL=1"

if "%IS_PLAYLIST%"=="1" (
    echo Detected playlist URL.
    set /p CONFIRM="Download entire playlist? (y/n): "
    if /I not "!CONFIRM!"=="y" (
        echo Aborted.
        endlocal
        exit /b 1
    )
) else if "%IS_CHANNEL%"=="1" (
    echo Detected channel URL.
) else (
    echo Detected single video URL (or non-playlist URL).
)

REM ----- Run yt-dlp -----
echo Using config: "%CONF%"

yt-dlp.exe ^
  --config-location "%CONF%" ^
  --download-archive "_downloaded.log" ^
  -o "%%(title)s.%%(ext)s" ^
  %EXTRA_ARGS% ^
  "%URL%"

set "RC=%ERRORLEVEL%"
endlocal
exit /b %RC%

REM ============================
REM Command cases
REM ============================
:bat_help
echo.
echo yt-music.bat - YouTube Music Audio Downloader
echo.
echo Commands:
echo   yt-music help
echo       Show this help.
echo   yt-music update
echo       Update yt-dlp (yt-dlp.exe -U).
echo   yt-music --help
echo       Show yt-dlp help (yt-dlp.exe --help).
echo.
echo Download:
echo   yt-music ^<URL^>
echo       Download from a single video / playlist / channel URL.
echo       If playlist (URL contains "list="), asks confirmation first.
echo.
echo Optional flags:
echo   -scale
echo       Use the scale config (yt-dlp-scale.conf) instead of crop config.
echo.
echo   --extra ^<yt-dlp args...^>
echo       Pass through any additional yt-dlp arguments AFTER --extra.
echo       Example:
echo         yt-music ^<URL^> -scale --extra --no-playlist
echo.
echo Output:
echo   - Saves to current folder with: %%(title)s.%%(ext)s
echo   - Uses download archive: _downloaded.log
echo.
echo Config files:
echo   - Must exist next to this .bat:
echo       yt-dlp-crop.conf
echo       yt-dlp-scale.conf
echo.
echo Requirements:
echo   - yt-dlp.exe on PATH
echo.
endlocal
exit /b 0

:do_update
yt-dlp.exe -U
set "RC=%ERRORLEVEL%"
endlocal
exit /b %RC%

:do_ytdlp_help
yt-dlp.exe --help
set "RC=%ERRORLEVEL%"
endlocal
exit /b %RC%

:usage
echo Usage:
echo   yt-music help ^| update ^| --help
echo   yt-music ^<URL^> [-scale] [--extra ^<yt-dlp args...^>]
endlocal
exit /b 2
