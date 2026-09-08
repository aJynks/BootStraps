@echo off
setlocal EnableExtensions

if "%~1"=="" goto usage

set "INPUT=%~1"
set "OUTPUT="
set "FRAMES="

shift

:parse
if "%~1"=="" goto parsed

if /I "%~1"=="-o" (
    if "%~2"=="" (
        echo ERROR: -o requires an output filename.
        exit /b 1
    )
    set "OUTPUT=%~2"
    shift
    shift
    goto parse
)

if /I "%~1"=="-frame" (
    if "%~2"=="" (
        echo ERROR: -frame requires a frame count.
        exit /b 1
    )
    set "FRAMES=%~2"
    shift
    shift
    goto parse
)

echo ERROR: Unknown option: %~1
exit /b 1


:parsed

if not exist "%INPUT%" (
    echo ERROR: Input file not found: "%INPUT%"
    exit /b 1
)

if not defined FRAMES (
    echo ERROR: You must specify -frame.
    exit /b 1
)

if not defined OUTPUT (
    for %%F in ("%INPUT%") do set "OUTPUT=%%~dpF_%%~nF.mp4"
)

echo Input : "%INPUT%"
echo Output: "%OUTPUT%"
echo Frames: %FRAMES%
echo.

ffmpeg -hide_banner -i "%INPUT%" ^
    -map 0 ^
    -c copy ^
    -frames:v %FRAMES% ^
    -shortest ^
    "%OUTPUT%"

exit /b %ERRORLEVEL%


:usage
echo Usage:
echo   trimmp4 input.mp4 -frame FRAMECOUNT
echo   trimmp4 input.mp4 -o output.mp4 -frame FRAMECOUNT
echo.
echo Example:
echo   trimmp4 file.mp4 -o newname.mp4 -frame 40859
exit /b 1