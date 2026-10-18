$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture

function Fail([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Usage {
    function Help-Head([string]$t)  { Write-Host $t -ForegroundColor Yellow }
    function Help-Line([string]$k, [string]$d) {
        Write-Host ('  ' + $k.PadRight(22)) -ForegroundColor Cyan -NoNewline
        Write-Host $d
    }
    function Help-Desc([string]$t) { Write-Host (' ' * 24 + $t) }

    Write-Host ''
    Write-Host 'mp4cut' -ForegroundColor Green -NoNewline
    Write-Host ' - cut a section out of an OBS mp4 by frame number'
    Write-Host ''
    Help-Head 'USAGE'
    Write-Host '  mp4cut ' -NoNewline
    Write-Host 'input.mp4 START_FRAME END_FRAME ' -ForegroundColor Cyan -NoNewline
    Write-Host '[options]' -ForegroundColor DarkGray
    Write-Host ''
    Help-Head 'ARGUMENTS'
    Help-Line 'input.mp4'   'Recording to cut.'
    Help-Line 'START_FRAME' 'First frame to keep (zero-based).'
    Help-Line 'END_FRAME'   'Last frame to keep (inclusive). Must be inside the file.'
    Write-Host ''
    Help-Head 'OPTIONS'
    Help-Line '-o, --output NAME' 'Output file. Default: <input>_cut.mp4 next to the input.'
    Help-Desc '".mp4" is added if NAME has no extension.'
    Help-Line '--force'           'Exact START_FRAME. Re-encodes video only if START_FRAME'
    Help-Desc 'is not a keyframe (source codec, source bitrate).'
    Help-Line '-h, --help'        'Show this help.'
    Write-Host ''
    Help-Head 'MODES'
    Write-Host '  default  ' -ForegroundColor Cyan -NoNewline
    Write-Host 'Stream copy, no re-encoding. Start snaps to the nearest keyframe;'
    Help-Desc 'the end may run a frame or two long so the copied end is not broken.'
    Write-Host '  --force  ' -ForegroundColor Cyan -NoNewline
    Write-Host 'Exact START_FRAME and END_FRAME.'
    Write-Host ''
    Help-Head 'NOTES'
    Write-Host '  Keeps the video and audio track 1 only; other audio tracks are dropped.'
    Write-Host '  Frame numbers match PotPlayer''s Elapsed Frames counter.'
    Write-Host ''
    Help-Head 'EXAMPLES'
    Write-Host '  mp4cut rec.mp4 2396 131327' -ForegroundColor White
    Write-Host '  mp4cut rec.mp4 2396 131327 -o clip.mp4 --force' -ForegroundColor White
    Write-Host ''
}

function ParseD($s) {
    if ($null -eq $s) { return $null }
    $v = 0.0
    if ([double]::TryParse([string]$s, [Globalization.NumberStyles]::Float, $Inv, [ref]$v)) { return $v }
    return $null
}

function Parse-Rate([string]$Rate) {
    if (-not $Rate) { return $null }
    if ($Rate -match '^([0-9.]+)\/([0-9.]+)$') {
        $n = ParseD $Matches[1]
        $d = ParseD $Matches[2]
        if ($n -and $d) { return $n / $d }
        return $null
    }
    return ParseD $Rate
}

function Fmt([double]$Value) {
    return $Value.ToString('0.###############', $Inv)
}

# Frame <-> time helpers. Times are absolute stream timestamps (as ffprobe reports them).
function FrameTime([long]$n) { return $vStart + ($n / $fps) }
function ToFrame([double]$t) { return [long][math]::Floor((($t - $vStart) * $fps) + 0.5) }
# ffmpeg's input -ss is relative to the file's start time.
function SeekArg([double]$abs) { return Fmt ([math]::Max(0.0, $abs - $fStart)) }

function Get-Probe([string]$File) {
    Write-Host 'Reading media info...'
    $json = & ffprobe -v error -show_entries "stream=index,codec_type,codec_name,pix_fmt,avg_frame_rate,r_frame_rate,bit_rate,start_time,duration,nb_frames,color_range,color_space,color_transfer,color_primaries:format=start_time,duration,bit_rate" -of json -- "$File"
    if ($LASTEXITCODE -ne 0 -or -not $json) { Fail 'ffprobe could not read the file.' }
    try { return ((@($json) -join "`n") | ConvertFrom-Json) }
    catch { Fail 'Could not parse ffprobe output.' }
}

# Video packets in decode order between two absolute times. Reads packet headers only
# (no decoding), and only this window, so it is quick regardless of file size.
function Get-Packets([string]$File, [double]$From, [double]$To) {
    $iv = '{0}%{1}' -f (Fmt ([math]::Max(0.0, $From))), (Fmt $To)
    $lines = & ffprobe -v error -select_streams v:0 -read_intervals $iv -show_entries packet=pts_time,flags -of csv=p=0 -- "$File"
    if ($LASTEXITCODE -ne 0) { Fail 'ffprobe failed while scanning for keyframes.' }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($ln in @($lines)) {
        $p = ([string]$ln).Split(',')
        if ($p.Count -lt 2) { continue }
        $pts = ParseD $p[0]
        if ($null -eq $pts) { continue }
        $list.Add([pscustomobject]@{ Pts = $pts; Frame = (ToFrame $pts); Key = ($p[1] -like '*K*') })
    }
    return ,$list
}

# Nearest keyframe to START_FRAME (ties go to the earlier one), never past END_FRAME.
# Starts with a small window and widens only if nothing usable is found.
function Find-StartKeyframe([string]$File, [long]$InFrame, [long]$OutFrame) {
    $t = FrameTime $InFrame
    $best = $null
    foreach ($w in 10, 30, 120, 600) {
        $pk = Get-Packets $File ($t - $w) ($t + $w)
        $best = $null
        $bestDist = [long]::MaxValue
        foreach ($q in $pk) {
            if (-not $q.Key -or $q.Frame -lt 0 -or $q.Frame -gt $OutFrame) { continue }
            $d = [math]::Abs($q.Frame - $InFrame)
            if ($d -lt $bestDist -or ($d -eq $bestDist -and $q.Frame -lt $best.Frame)) {
                $best = $q
                $bestDist = $d
            }
        }
        # Only trust the pick if nothing outside the window could be closer.
        if ($best -and ($bestDist / $fps) -le $w) { return $best }
    }
    return $best
}

# For stream copy: the smallest end frame >= END_FRAME where the decode-order packets
# form a complete run of frames. With B-frames, stopping exactly on END_FRAME can drop
# or swap the last frame or two, so the end is extended just enough to avoid that.
function Find-CopyEnd([string]$File, [long]$OutFrame, [long]$LastFrame) {
    if ($OutFrame -ge $LastFrame) { return $LastFrame }
    $t = FrameTime $OutFrame
    $pk = Get-Packets $File ($t - 1.0) ($t + 1.0)
    $n = $pk.Count
    $need = -1
    for ($i = 0; $i -lt $n; $i++) { if ($pk[$i].Frame -le $OutFrame) { $need = $i } }
    if ($need -lt 0) { return $OutFrame }

    $sufMin = New-Object 'long[]' ($n + 1)
    $sufMin[$n] = [long]::MaxValue
    for ($i = $n - 1; $i -ge 0; $i--) { $sufMin[$i] = [math]::Min([long]$sufMin[$i + 1], [long]$pk[$i].Frame) }

    $maxF = [long]::MinValue
    for ($i = 0; $i -lt $n; $i++) {
        if ($pk[$i].Frame -gt $maxF) { $maxF = [long]$pk[$i].Frame }
        if ($i -ge $need -and $sufMin[$i + 1] -gt $maxF) {
            return [math]::Min([math]::Max([long]$maxF, [long]$OutFrame), [long]$LastFrame)
        }
    }
    return $OutFrame
}

function Get-EncoderArgs($v, [double]$Bitrate) {
    $encList = (& ffmpeg -hide_banner -encoders) -join "`n"
    $a = @()

    switch ([string]$v.codec_name) {
        'h264' { $name = 'libx264';   $a += @('-c:v','libx264','-preset','slow') }
        'hevc' { $name = 'libx265';   $a += @('-c:v','libx265','-preset','slow','-tag:v','hvc1') }
        'av1'  { $name = 'libsvtav1'; $a += @('-c:v','libsvtav1','-preset','5') }
        default {
            Write-Host "Source codec '$($v.codec_name)' has no configured matching encoder; using H.264." -ForegroundColor Yellow
            $name = 'libx264'
            $a += @('-c:v','libx264','-preset','slow')
        }
    }
    if ($encList -notmatch ('\s' + [regex]::Escape($name) + '\s')) {
        Fail "This ffmpeg build has no '$name' encoder, which --force needs for $($v.codec_name) video."
    }

    if ($Bitrate -gt 0) {
        # Match the source's average bitrate so size and quality stay close to the original.
        $b = [long][math]::Round($Bitrate)
        $a += @('-b:v', "$b")
        if ($name -ne 'libsvtav1') {
            $a += @('-maxrate', "$([long]($b * 1.5))", '-bufsize', "$([long]($b * 2))")
        }
        Write-Host ("Bitrate   : {0:N0} kb/s (matched to source)" -f ($b / 1000))
    }
    else {
        Write-Host 'Source bitrate unknown; falling back to quality-based encoding.' -ForegroundColor Yellow
        switch ($name) {
            'libx264'   { $a += @('-crf','18') }
            'libx265'   { $a += @('-crf','20') }
            'libsvtav1' { $a += @('-crf','24') }
        }
    }

    $pf = [string]$v.pix_fmt
    if ($name -eq 'libsvtav1' -and $pf -and $pf -ne 'yuv420p' -and $pf -ne 'yuv420p10le') {
        $pf = if ($pf -match '10') { 'yuv420p10le' } else { 'yuv420p' }
    }
    if ($pf) { $a += @('-pix_fmt', $pf) }
    if ($v.color_range -and $v.color_range -ne 'unknown') { $a += @('-color_range',[string]$v.color_range) }
    if ($v.color_space -and $v.color_space -ne 'unknown') { $a += @('-colorspace',[string]$v.color_space) }
    if ($v.color_transfer -and $v.color_transfer -ne 'unknown') { $a += @('-color_trc',[string]$v.color_transfer) }
    if ($v.color_primaries -and $v.color_primaries -ne 'unknown') { $a += @('-color_primaries',[string]$v.color_primaries) }

    return $a
}

# Parse GNU-style options.
$pos = New-Object System.Collections.Generic.List[string]
$outName = $null
$force = $false
for ($i = 0; $i -lt $args.Count; $i++) {
    $x = [string]$args[$i]
    switch ($x) {
        '-o' {
            if ($i + 1 -ge $args.Count) { Fail '-o requires a filename.' }
            $i++; $outName = [string]$args[$i]
        }
        '--output' {
            if ($i + 1 -ge $args.Count) { Fail '--output requires a filename.' }
            $i++; $outName = [string]$args[$i]
        }
        '--force' { $force = $true }
        '-h' { Usage; exit 0 }
        '--help' { Usage; exit 0 }
        default {
            if ($x.StartsWith('-')) { Fail "Unknown option: $x" }
            $pos.Add($x)
        }
    }
}

if ($args.Count -eq 0) { Usage; exit 0 }

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Fail 'ffmpeg was not found in PATH.' }
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { Fail 'ffprobe was not found in PATH.' }

if ($pos.Count -gt 3) { Usage; Fail 'Too many arguments.' }

$inputFile = if ($pos.Count -ge 1) { $pos[0] } else { (Read-Host 'MP4 file').Trim().Trim('"') }
$startText = if ($pos.Count -ge 2) { $pos[1] } else { (Read-Host 'Start frame').Trim() }
$endText   = if ($pos.Count -ge 3) { $pos[2] } else { (Read-Host 'End frame').Trim() }

if (-not $inputFile -or -not (Test-Path -LiteralPath $inputFile -PathType Leaf)) { Fail "Input file not found: $inputFile" }

[long]$startFrame = 0
[long]$endFrame = 0
if (-not [long]::TryParse($startText, [ref]$startFrame)) { Fail "Invalid start frame: $startText" }
if (-not [long]::TryParse($endText, [ref]$endFrame)) { Fail "Invalid end frame: $endText" }
if ($startFrame -lt 0) { Fail 'Start frame must be 0 or greater.' }
if ($endFrame -lt $startFrame) { Fail 'End frame must be >= start frame.' }

$inputFull = (Resolve-Path -LiteralPath $inputFile).Path
$dir = Split-Path -Parent $inputFull
$base = [IO.Path]::GetFileNameWithoutExtension($inputFull)

if ($outName) {
    if ([IO.Path]::GetExtension($outName) -eq '') { $outName += '.mp4' }
    $outputFile = if ([IO.Path]::IsPathRooted($outName)) { $outName } else { Join-Path $dir $outName }
} else {
    $outputFile = Join-Path $dir ($base + '_cut.mp4')
}
$outputFile = [IO.Path]::GetFullPath($outputFile)
if ($outputFile -eq $inputFull) { Fail 'Output cannot overwrite input.' }

$probe = Get-Probe $inputFull
$v = @($probe.streams | Where-Object { $_.codec_type -eq 'video' }) | Select-Object -First 1
if (-not $v) { Fail 'No video stream found.' }
$audios = @($probe.streams | Where-Object { $_.codec_type -eq 'audio' })

$fps = Parse-Rate ([string]$v.avg_frame_rate)
if (-not $fps -or $fps -le 0) { $fps = Parse-Rate ([string]$v.r_frame_rate) }
if (-not $fps -or $fps -le 0) { Fail 'Could not determine video frame rate.' }

$vStart = ParseD $v.start_time;            if ($null -eq $vStart) { $vStart = 0.0 }
$fStart = ParseD $probe.format.start_time; if ($null -eq $fStart) { $fStart = 0.0 }
$eps = 0.01 / $fps   # nudge used so timestamp rounding never lands on the wrong frame

# Total frame count, for range-checking the frame numbers.
$nb = ParseD $v.nb_frames
$sd = ParseD $v.duration
$fd = ParseD $probe.format.duration
if ($nb -and $nb -gt 0) { [long]$totalFrames = $nb }
elseif ($sd -and $sd -gt 0) { [long]$totalFrames = [math]::Floor($sd * $fps + 0.5) }
elseif ($fd -and $fd -gt 0) { [long]$totalFrames = [math]::Floor(($fd - ($vStart - $fStart)) * $fps + 0.5) }
else { Fail 'Could not determine the number of frames in the video.' }
[long]$lastFrame = $totalFrames - 1

if ($startFrame -gt $lastFrame) { Fail "Start frame $startFrame is past the end of the file (last frame is $lastFrame)." }
if ($endFrame -gt $lastFrame) { Fail "End frame $endFrame is past the end of the file (last frame is $lastFrame)." }

Write-Host ("FPS       : {0:N3}" -f $fps)
Write-Host "Frames    : 0-$lastFrame in file"
Write-Host "Requested : frames $startFrame-$endFrame"
Write-Host "Output    : $outputFile"
Write-Host 'Finding keyframe...'

$kf = Find-StartKeyframe $inputFull $startFrame $endFrame
if (-not $kf) { Fail 'Could not find a usable keyframe near the start frame.' }
[long]$K = $kf.Frame
$startIsKey = ($K -eq $startFrame)

if (-not $force -or $startIsKey) {
    # ---------- Stream copy ----------
    [long]$endUsed = Find-CopyEnd $inputFull $endFrame $lastFrame
    [long]$count = $endUsed - $K + 1

    if ($force) { Write-Host 'Mode      : --force, but the start frame is a keyframe, so stream copy is exact' }
    else        { Write-Host 'Mode      : stream copy (no re-encoding)' }

    if ($startIsKey) {
        Write-Host "Start     : frame $K (exact, it is a keyframe)"
    } else {
        $diff = $K - $startFrame
        $dir2 = if ($diff -lt 0) { 'earlier' } else { 'later' }
        Write-Host ("Start     : frame $K, nearest keyframe, {0} frame(s) {1}" -f [math]::Abs($diff), $dir2) -ForegroundColor Yellow
    }
    if ($endUsed -ne $endFrame) {
        Write-Host ("End       : frame $endUsed, {0} extra frame(s) so the copied end stays intact" -f ($endUsed - $endFrame)) -ForegroundColor Yellow
    } else {
        Write-Host "End       : frame $endUsed"
    }
    Write-Host "Actual    : frames $K-$endUsed ($count frames)"
    Write-Host 'Cutting...'

    # Seek a hair past the keyframe: ffmpeg's copy-seek lands on the keyframe at or before
    # that point, so this always gets exactly the chosen keyframe. -frames:v sets the video
    # length; -t trims audio track 1 to match.
    $ff = @(
        '-hide_banner','-y','-stats','-stats_period','0.5',
        '-ss',(SeekArg ($kf.Pts + $eps)),
        '-i',$inputFull,
        '-map','0:v:0','-map','0:a:0?',
        '-frames:v',"$count",
        '-t',(Fmt ($count / $fps)),
        '-c','copy',
        '-map_metadata','0','-map_chapters','0',
        '-avoid_negative_ts','make_zero',
        '-movflags','+faststart',
        $outputFile
    )
    & ffmpeg @ff
    if ($LASTEXITCODE -ne 0) { Fail 'ffmpeg failed.' }
}
else {
    # ---------- Exact re-encode (--force) ----------
    [long]$count = $endFrame - $startFrame + 1
    Write-Host 'Mode      : --force, exact frames (start is not a keyframe, re-encoding video)'
    Write-Host "Actual    : frames $startFrame-$endFrame ($count frames)"
    Write-Host 'Audio     : track 1, stream copied'

    $vbr = ParseD $v.bit_rate
    if (-not $vbr -or $vbr -le 0) {
        $fbr = ParseD $probe.format.bit_rate
        if ($fbr -and $fbr -gt 0) {
            $abr = 0.0
            foreach ($au in $audios) { $x = ParseD $au.bit_rate; if ($x) { $abr += $x } }
            $vbr = $fbr - $abr
        }
    }
    if (-not $vbr) { $vbr = 0.0 }

    $enc = Get-EncoderArgs $v $vbr
    Write-Host 'Cutting...'

    # Input seek to just before the start frame: ffmpeg jumps to the prior keyframe, decodes
    # and discards up to the start frame, then emits exactly COUNT frames. Only the section
    # is encoded. -t trims audio track 1 to the same length.
    $ff = @(
        '-hide_banner','-y','-stats','-stats_period','0.5',
        '-ss',(SeekArg ((FrameTime $startFrame) - $eps)),
        '-i',$inputFull,
        '-map','0:v:0','-map','0:a:0?',
        '-frames:v',"$count",
        '-t',(Fmt ($count / $fps))
    ) + $enc + @(
        '-c:a','copy',
        '-map_metadata','0','-map_chapters','0',
        '-movflags','+faststart',
        $outputFile
    )
    & ffmpeg @ff
    if ($LASTEXITCODE -ne 0) { Fail 'ffmpeg failed in --force mode.' }
}

if (-not (Test-Path -LiteralPath $outputFile)) { Fail 'Output file was not created.' }
$size = (Get-Item -LiteralPath $outputFile).Length
Write-Host ("Done      : {0:N2} MB" -f ($size / 1MB)) -ForegroundColor Green
exit 0
