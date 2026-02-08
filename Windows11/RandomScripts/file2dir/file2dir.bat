@echo off
setlocal enabledelayedexpansion

rem ======================================
rem Make a subdirectory for each file and move the file inside
rem Skips itself (.bat file)
rem ======================================

for %%F in (*) do (
    rem Skip directories
    if not "%%~aF"=="d" (
        rem Skip the batch file itself
        if /I not "%%~xF"==".bat" (
            set "name=%%~nF"
            rem Create folder if it doesn’t exist
            if not exist "!name!" (
                mkdir "!name!"
            )
            rem Move the file
            move "%%F" "!name!\"
        )
    )
)

echo Done.
pause
