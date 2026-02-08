param(
    [switch]$Help
)

if ($Help) {
    Write-Host ""
    Write-Host "mp4Extract - MP4 Audio Extractor"
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  mp4Extract"
    Write-Host "  mp4Extract help"
    Write-Host ""
    Write-Host "Description:"
    Write-Host "  Scans the current folder for .mp4 files and"
    Write-Host "  extracts their AAC audio streams into .m4a files"
    Write-Host "  without re-encoding."
    Write-Host ""
    Write-Host "Features:"
    Write-Host "  - Preserves original audio quality"
    Write-Host "  - Adds bitrate to filename"
    Write-Host "  - Skips existing output files"
    Write-Host "  - Shows progress"
    Write-Host ""
    Write-Host "Requirements:"
    Write-Host "  - ffmpeg"
    Write-Host "  - ffprobe"
    Write-Host ""
    exit
}
