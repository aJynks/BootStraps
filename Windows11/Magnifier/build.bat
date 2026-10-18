@echo off
setlocal
cd /d "%~dp0"

set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" (
    echo [ERROR] csc.exe not found at:
    echo         %CSC%
    echo         Enable .NET Framework 4.x in "Turn Windows features on or off".
    exit /b 1
)

"%CSC%" /nologo /target:winexe /platform:x64 /optimize+ /out:Magnifier.exe /r:System.Windows.Forms.dll /r:System.Drawing.dll Magnifier.cs
if errorlevel 1 (
    echo [ERROR] Build failed.
    exit /b 1
)

echo Built: %~dp0Magnifier.exe
endlocal
