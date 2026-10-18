@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM yt-video-tolerant.bat - wrapper for yt-dlp
REM Accepts either:
REM   yt-video URL
REM   yt-video URL --extra <yt-dlp args...>
REM Also tolerates extra args without --extra (treats them as yt-dlp args), to avoid false errors.

if "%~1"=="" goto :usage
if /I "%~1"=="help" goto :usage

set "URL=%~1"
shift

set "PASS_ARGS="

REM Preferred form: --extra <args...>
if /I "%~1"=="--extra" (
    shift
    set "PASS_ARGS=%*"
) else (
    REM Tolerate any remaining args as yt-dlp args (some shells/wrappers accidentally append things)
    set "PASS_ARGS=%*"
)

REM Run yt-dlp (quote URL; leave PASS_ARGS unquoted so yt-dlp sees normal tokens)
yt-dlp "%URL%" %PASS_ARGS%

endlocal
exit /b %ERRORLEVEL%

:usage
echo Usage:
echo   yt-video URL
echo   yt-video URL --extra ^<yt-dlp args...^>
endlocal
exit /b 1
