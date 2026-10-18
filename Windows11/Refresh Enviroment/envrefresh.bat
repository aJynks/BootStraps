@echo off
rem ---------------------------------------------------------------------------
rem  envrefresh.bat  -  cmd entry point for envrefresh
rem
rem  A batch file runs INSIDE the calling cmd process, so SET commands made here
rem  change the user's live session. envrefresh.ps1 (next to this file) works
rem  out the changes and writes them as SET lines to a temp file, which is
rem  CALLed here and then deleted.
rem
rem  DO NOT add setlocal: it would throw every change away when this file ends.
rem  Directory, history and scrollback are never touched.
rem ---------------------------------------------------------------------------

if not exist "%~dp0envrefresh.ps1" (
    echo envrefresh: envrefresh.ps1 not found next to "%~f0"
    exit /b 1
)

set "__ER_TMP=%TEMP%\envrefresh_%RANDOM%%RANDOM%.cmd"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0envrefresh.ps1" -EmitCmd "%__ER_TMP%" %*

if exist "%__ER_TMP%" call "%__ER_TMP%"
if exist "%__ER_TMP%" del /q "%__ER_TMP%" >nul 2>&1
set "__ER_TMP="
