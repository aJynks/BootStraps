# --- PowerShell MP4 Audio Extractor ---

# Get all MP4 files in the current directory
$files = Get-ChildItem -Path . -Filter *.mp4
$total = $files.Count

if ($total -eq 0) {
    Write-Host "No MP4 files found."
    exit
}

Write-Host "Found $total MP4 files."
Write-Host "Processing..."

$current = 0

foreach ($file in $files) {

    $current++

    # Get full path and filename without extension
    $inputPath = $file.FullName
    $baseName = $file.BaseName

    # Get audio bitrate using ffprobe
    $bitrate = ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of csv=p=0 "$inputPath"
    
    # Convert to kbps
    $bitrateKb = [math]::Round([int]$bitrate / 1000)

    # Set codec
    $codec = "aac"

    # Construct output filename with 'k' suffix
    $outputName = "$baseName - ($codec-$bitrateKb`k).m4a"
    $outputPath = Join-Path -Path $file.DirectoryName -ChildPath $outputName

    # Skip if output exists
    if (Test-Path $outputPath) {
        continue
    }

    # Extract audio with ffmpeg, suppress all output
    & ffmpeg -hide_banner -loglevel error -n -i "$inputPath" -vn -acodec copy "$outputPath" | Out-Null

    # --- Progress Bar ---
    $percent = [int](($current / $total) * 100)
    $filled = [int]($percent / 2)
    $bar = "#" * $filled + "." * (50 - $filled)
    Write-Host -NoNewline ("Progress: [$bar] $percent% ($current/$total)`r")
}

Write-Host "`nAll files processed."
