@echo off
setlocal EnableExtensions

:: -----------------------------------------
:: cc.bat - wrapper for Chocolatey commands
:: -----------------------------------------

:: Wrapper help (only for --help or /?)
if /I "%~1"=="--help" goto :wrapper_help
if /I "%~1"=="/?"     goto :wrapper_help

:: Wrapper setup
if /I "%~1"=="--setup"  goto :setup
if /I "%~1"=="--update" goto :update_all

:: Choco help passthrough (NO gsudo)
if /I "%~1"=="-h" (
  choco %*
  exit /b %errorlevel%
)
if /I "%~1"=="help" (
  choco %*
  exit /b %errorlevel%
)

:: Normal path: run choco elevated via gsudo, then refreshenv (on success)
where gsudo >nul 2>&1
if %errorlevel% neq 0 (
  echo [ERROR] gsudo not found. Run: cc --setup
  exit /b 1
)

where choco >nul 2>&1
if %errorlevel% neq 0 (
  echo [ERROR] choco not found. Run: cc --setup
  exit /b 1
)

gsudo choco %*
set "CHOCO_EXIT=%errorlevel%"

echo.

if "%CHOCO_EXIT%"=="0" (
  call refreshenv >nul 2>&1
  echo ----------------------------------
  echo -- Environment Path Refreshed --
  echo ----------------------------------
) else (
  echo ----------------------------------
  echo -- Chocolatey Command FAILED --
  echo -- Exit Code: %CHOCO_EXIT% --
  echo ----------------------------------
)

exit /b %CHOCO_EXIT%


:wrapper_help
echo cc.bat - Chocolatey wrapper
echo.
echo Usage:
echo   cc [choco-command] [args...]
echo.
echo Wrapper commands:
echo   cc --help      Show this wrapper help
echo   cc --setup     Install Chocolatey (via winget) and install gsudo
echo   cc --update    Update Chocolatey and all installed packages
echo.
echo Help passthrough (no elevation):
echo   cc -h          Calls: choco -h
echo   cc help        Calls: choco help
echo.
echo Normal behavior:
echo   Any other command runs as: gsudo choco ^<args^>
echo   If that succeeds, refreshenv runs silently and a banner is printed.
echo.
echo Examples:
echo   cc install imagemagick -y
echo   cc upgrade all -y
echo   cc --update
echo.
exit /b 0


:update_all
where gsudo >nul 2>&1
if %errorlevel% neq 0 (
  echo [ERROR] gsudo not found. Run: cc --setup
  exit /b 1
)

where choco >nul 2>&1
if %errorlevel% neq 0 (
  echo [ERROR] choco not found. Run: cc --setup
  exit /b 1
)

echo Updating Chocolatey and all installed packages...
gsudo choco upgrade chocolatey -y && choco upgrade all -y
set "CHOCO_EXIT=%errorlevel%"

echo.

if "%CHOCO_EXIT%"=="0" (
  call refreshenv >nul 2>&1
  echo ----------------------------------
  echo -- Chocolatey Fully Updated --
  echo ----------------------------------
) else (
  echo ----------------------------------
  echo -- Update FAILED --
  echo -- Exit Code: %CHOCO_EXIT% --
  echo ----------------------------------
)

exit /b %CHOCO_EXIT%


:setup
echo [SETUP] Installing Chocolatey via winget...
where winget >nul 2>&1
if %errorlevel% neq 0 (
  echo [ERROR] winget not found. Install "App Installer" from Microsoft Store.
  exit /b 1
)

winget install --id Chocolatey.Chocolatey --source winget
set "WINGET_EXIT=%errorlevel%"
if not "%WINGET_EXIT%"=="0" (
  echo [ERROR] winget failed installing Chocolatey. Exit Code: %WINGET_EXIT%
  exit /b %WINGET_EXIT%
)

call refreshenv >nul 2>&1

echo.
echo [SETUP] Installing gsudo via choco (UAC prompt expected)...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c choco install gsudo -y' -Verb RunAs -Wait"

set "GSUDO_INSTALL_EXIT=%errorlevel%"

call refreshenv >nul 2>&1

echo.
echo ----------------------------------
echo -- Environment Path Refreshed --
echo ----------------------------------

exit /b %GSUDO_INSTALL_EXIT%