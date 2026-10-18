@echo off
setlocal enabledelayedexpansion

:: Set the root directory to where the script is run
set "root=%cd%"
set "outdir=%root%\_converted"

if not exist "%outdir%" mkdir "%outdir%"

echo Root: "%root%"
echo Output: "%outdir%"
echo.

:: Find and convert all WAV files recursively (flatten output)
for /r "%root%" %%F in (*.wav) do (
    set "infile=%%F"
    set "outfile=%outdir%\%%~nF.flac"

    echo Converting "%%F" ...
    ffmpeg -i "%%F" -map_metadata 0 -c:a flac -compression_level 8 "!outfile!"
)

echo.
echo Done! All WAV files have been converted to FLAC in "%outdir%".
pause
