@echo off
setlocal

if not exist "_audio" mkdir "_audio"

for %%F in (*.mp4) do (
    echo Extracting audio from "%%F" ...
    ffmpeg -y -i "%%F" -map 0:a:0 -c copy "_audio\%%~nF_audio.mka"
)

echo Done.
pause
