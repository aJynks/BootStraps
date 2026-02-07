@echo off
setlocal EnableDelayedExpansion

if not exist "_audio" mkdir "_audio"

for %%F in (*.mp4) do (
    echo.
    echo Processing "%%F" ...

    rem --- Detect audio codec using ffprobe ---
    for /f "delims=" %%C in ('ffprobe -v error -select_streams a:0 -show_entries stream^=codec_name -of csv^=p^=0 "%%F"') do set codec=%%C

    if not defined codec (
        echo No audio stream found in "%%F"
        goto :next
    )

    rem --- Pick file extension based on codec ---
    set ext=!codec!
    if /i "!codec!"=="aac"  set ext=m4a
    if /i "!codec!"=="alac" set ext=m4a
    if /i "!codec!"=="mp3"  set ext=mp3
    if /i "!codec!"=="opus" set ext=opus
    if /i "!codec!"=="vorbis" set ext=ogg
    if /i "!codec!"=="flac" set ext=flac
    if /i "!codec!"=="ac3"  set ext=ac3
    if /i "!codec!"=="eac3" set ext=eac3
    if /i "!codec!"=="pcm_s16le" set ext=wav
    if /i "!codec!"=="pcm_s24le" set ext=wav
    if /i "!codec!"=="pcm_f32le" set ext=wav

    echo Found codec: !codec!
    echo Extracting audio as "!ext!" ...
    ffmpeg -y -i "%%F" -vn -c:a copy "_audio\%%~nF.!ext!"

    :next
    set codec=
)

echo.
echo Done.
pause
