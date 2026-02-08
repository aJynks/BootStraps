@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ---- Help switches (short-circuit) ----
if "%~1"=="" goto :HELP
if /I "%~1"=="-h" goto :HELP
if /I "%~1"=="--help" goto :HELP
if /I "%~1"=="-help" goto :HELP
if /I "%~1"=="/?" goto :HELP

rem ---- Require exactly 2 args ----
if "%~2"=="" goto :BADARGS
if not "%~3"=="" goto :BADARGS

set "NEWLINK=%~1"
set "TARGET=%~2"

set "HASERR=0"

rem ---- Check 1: new link must NOT exist ----
if exist "%NEWLINK%" (
  echo Error: newLinkDir already exists.
  set "HASERR=1"
)

rem ---- Check 2: target must exist / be accessible (UNC-safe) ----
pushd "%TARGET%" >nul 2>&1
if errorlevel 1 (
  echo Error: targetDir does not exist or is not accessible.
  set "HASERR=1"
) else (
  popd >nul 2>&1
)

rem ---- If any error, stop now (do NOT execute) ----
if "!HASERR!"=="1" exit /b 2

rem ---- Execute ----
echo * gsudo mklink /D "%NEWLINK%" "%TARGET%"
call gsudo mklink /D "%NEWLINK%" "%TARGET%"
exit /b %ERRORLEVEL%

:HELP
echo Usage:
echo   linkset "newLinkDir" "targetDir"
echo.
echo Options:
echo   -h, --help, -help, /?
exit /b 0

:BADARGS
echo Error: invalid arguments.
exit /b 1
