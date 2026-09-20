@echo off
setlocal
rem ---------------------------------------------------------------------
rem  trackerextract - extract WAV samples from tracker modules
rem
rem  Locates its Python sibling via %~dp0 (the folder this .bat lives in),
rem  so the pair can sit anywhere on PATH and run from any directory or
rem  drive. Arguments pass through verbatim; the script's exit code is
rem  propagated to the caller.
rem ---------------------------------------------------------------------

set "SCRIPT=%~dp0trackerextract_script.py"

if not exist "%SCRIPT%" (
    echo [trackerextract] Cannot find trackerextract_script.py
    echo                  Expected beside this batch file:
    echo                  %~dp0
    exit /b 9009
)

rem Prefer the Python Launcher, fall back to python on PATH.
where py >nul 2>&1
if %ERRORLEVEL% equ 0 (
    py "%SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

where python >nul 2>&1
if %ERRORLEVEL% equ 0 (
    python "%SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

echo [trackerextract] Python not found on PATH.
echo                  Install Python 3.7 or newer, or add it to PATH.
exit /b 9009
