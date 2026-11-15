$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture

function Fail([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Usage {
    Write-Host ''
    Write-Host 'mkvglue' -ForegroundColor Green -NoNewline
    Write-Host ' - cut frame ranges from two MKVs and stitch them together'
    Write-Host ''
    Write-Host 'USAGE' -ForegroundColor Yellow
    Write-Host '  mkvglue ' -NoNewline
    Write-Host 'part1.mkv START1 END1 part2.mkv START2 END2 ' -ForegroundColor Cyan -NoNewline
    Write-Host '[options]' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'OPTIONS' -ForegroundColor Yellow
    Write-Host '  -o, --output NAME      Output MKV. Default: <part1>_glued.mkv'
    Write-Host '  --force                Exact frame ranges. Re-encodes the selected video ranges.'
    Write-Host '  -h, --help             Show this help.'
    Write-Host ''
    Write-Host 'MODES' -ForegroundColor Yellow
    Write-Host '  default  ' -ForegroundColor Cyan -NoNewline
    Write-Host 'No re-encoding. Each start snaps to the nearest usable keyframe;'
    Write-Host '           each end may extend by a frame or two so copied video is not broken.'
    Write-Host '  --force  ' -ForegroundColor Cyan -NoNewline
    Write-Host 'Exact requested frame ranges. Both selected video ranges are re-encoded'
    Write-Host '           to keep the joined output consistent. Audio track 1 is stream-copied.'
    Write-Host ''
    Write-Host 'NOTES' -ForegroundColor Yellow
    Write-Host '  Inputs must have compatible video/audio stream parameters for a clean join.'
    Write-Host '  Keeps video track 1 and audio track 1 only; subtitles and extra audio are dropped.'
    Write-Host '  Frame numbers are zero-based and intended to match PotPlayer''s Elapsed Frames counter.'
    Write-Host ''
    Write-Host 'EXAMPLE' -ForegroundColor Yellow
    Write-Host '  mkvglue part1.mkv 0 500 part2.mkv 500 1000' -ForegroundColor White
    Write-Host '  mkvglue part1.mkv 0 500 part2.mkv 500 1000 --force -o joined.mkv' -ForegroundColor White
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
        $n = ParseD $Matches[1]; $d = ParseD $Matches[2]
        if ($n -and $d) { return $n / $d }
        return $null
    }
    return ParseD $Rate
}

function Fmt([double]$Value) { return $Value.ToString('0.###############', $Inv) }

function Get-Probe([string]$File) {
    $json = & ffprobe -v error -show_entries "stream=index,codec_type,codec_name,pix_fmt,width,height,avg_frame_rate,r_frame_rate,bit_rate,start_time,duration,nb_frames,sample_rate,channels,channel_layout,color_range,color_space,color_transfer,color_primaries:format=start_time,duration,bit_rate" -of json -- "$File"
    if ($LASTEXITCODE -ne 0 -or -not $json) { Fail "ffprobe could not read: $File" }
    try { return ((@($json) -join "`n") | ConvertFrom-Json) }
    catch { Fail "Could not parse ffprobe output for: $File" }
}

function Get-Media([string]$File) {
    $full = (Resolve-Path -LiteralPath $File).Path
    $p = Get-Probe $full
    $v = @($p.streams | Where-Object { $_.codec_type -eq 'video' }) | Select-Object -First 1
    if (-not $v) { Fail "No video stream found in: $File" }
    $a = @($p.streams | Where-Object { $_.codec_type -eq 'audio' }) | Select-Object -First 1

    $fps = Parse-Rate ([string]$v.avg_frame_rate)
    if (-not $fps -or $fps -le 0) { $fps = Parse-Rate ([string]$v.r_frame_rate) }
    if (-not $fps -or $fps -le 0) { Fail "Could not determine frame rate for: $File" }

    $vStart = ParseD $v.start_time; if ($null -eq $vStart) { $vStart = 0.0 }
    $fStart = ParseD $p.format.start_time; if ($null -eq $fStart) { $fStart = 0.0 }
    $nb = ParseD $v.nb_frames
    $sd = ParseD $v.duration
    $fd = ParseD $p.format.duration
    if ($nb -and $nb -gt 0) { [long]$total = $nb }
    elseif ($sd -and $sd -gt 0) { [long]$total = [math]::Floor($sd * $fps + 0.5) }
    elseif ($fd -and $fd -gt 0) { [long]$total = [math]::Floor(($fd - ($vStart - $fStart)) * $fps + 0.5) }
    else { Fail "Could not determine frame count for: $File" }

    return [pscustomobject]@{
        File=$full; Probe=$p; Video=$v; Audio=$a; Fps=$fps; VStart=$vStart; FStart=$fStart;
        LastFrame=([long]$total - 1); Eps=(0.01 / $fps)
    }
}

function FrameTime($M, [long]$n) { return $M.VStart + ($n / $M.Fps) }
function ToFrame($M, [double]$t) { return [long][math]::Floor((($t - $M.VStart) * $M.Fps) + 0.5) }
function SeekArg($M, [double]$abs) { return Fmt ([math]::Max(0.0, $abs - $M.FStart)) }

function Get-Packets($M, [double]$From, [double]$To) {
    $iv = '{0}%{1}' -f (Fmt ([math]::Max(0.0, $From))), (Fmt $To)
    $lines = & ffprobe -v error -select_streams v:0 -read_intervals $iv -show_entries packet=pts_time,flags -of csv=p=0 -- "$($M.File)"
    if ($LASTEXITCODE -ne 0) { Fail "ffprobe failed while scanning keyframes in: $($M.File)" }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($ln in @($lines)) {
        $p = ([string]$ln).Split(',')
        if ($p.Count -lt 2) { continue }
        $pts = ParseD $p[0]; if ($null -eq $pts) { continue }
        $list.Add([pscustomobject]@{ Pts=$pts; Frame=(ToFrame $M $pts); Key=($p[1] -like '*K*') })
    }
    return ,$list
}

function Find-StartKeyframe($M, [long]$InFrame, [long]$OutFrame) {
    $t = FrameTime $M $InFrame
    foreach ($w in 10,30,120,600) {
        $pk = Get-Packets $M ($t - $w) ($t + $w)
        $best = $null; $bestDist = [long]::MaxValue
        foreach ($q in $pk) {
            if (-not $q.Key -or $q.Frame -lt 0 -or $q.Frame -gt $OutFrame) { continue }
            $d = [math]::Abs($q.Frame - $InFrame)
            if ($d -lt $bestDist -or ($d -eq $bestDist -and $q.Frame -lt $best.Frame)) {
                $best = $q; $bestDist = $d
            }
        }
        if ($best -and ($bestDist / $M.Fps) -le $w) { return $best }
    }
    return $null
}

function Find-CopyEnd($M, [long]$OutFrame) {
    if ($OutFrame -ge $M.LastFrame) { return $M.LastFrame }
    $t = FrameTime $M $OutFrame
    $pk = Get-Packets $M ($t - 1.0) ($t + 1.0)
    $n = $pk.Count; $need = -1
    for ($i=0; $i -lt $n; $i++) { if ($pk[$i].Frame -le $OutFrame) { $need = $i } }
    if ($need -lt 0) { return $OutFrame }
    $sufMin = New-Object 'long[]' ($n + 1); $sufMin[$n] = [long]::MaxValue
    for ($i=$n-1; $i -ge 0; $i--) { $sufMin[$i] = [math]::Min([long]$sufMin[$i+1], [long]$pk[$i].Frame) }
    $maxF = [long]::MinValue
    for ($i=0; $i -lt $n; $i++) {
        if ($pk[$i].Frame -gt $maxF) { $maxF = [long]$pk[$i].Frame }
        if ($i -ge $need -and $sufMin[$i+1] -gt $maxF) {
            return [math]::Min([math]::Max([long]$maxF,[long]$OutFrame),[long]$M.LastFrame)
        }
    }
    return $OutFrame
}

function Check-Compatible($A, $B) {
    $va=$A.Video; $vb=$B.Video
    $problems = New-Object System.Collections.Generic.List[string]
    if ($va.codec_name -ne $vb.codec_name) { $problems.Add("video codec: $($va.codec_name) vs $($vb.codec_name)") }
    if ($va.width -ne $vb.width -or $va.height -ne $vb.height) { $problems.Add("resolution: $($va.width)x$($va.height) vs $($vb.width)x$($vb.height)") }
    if ($va.pix_fmt -ne $vb.pix_fmt) { $problems.Add("pixel format: $($va.pix_fmt) vs $($vb.pix_fmt)") }
    if ([math]::Abs($A.Fps - $B.Fps) -gt 0.0001) { $problems.Add("frame rate: $($A.Fps) vs $($B.Fps)") }
    if (($null -eq $A.Audio) -ne ($null -eq $B.Audio)) { $problems.Add('one file has audio and the other does not') }
    elseif ($A.Audio -and $B.Audio) {
        if ($A.Audio.codec_name -ne $B.Audio.codec_name) { $problems.Add("audio codec: $($A.Audio.codec_name) vs $($B.Audio.codec_name)") }
        if ([string]$A.Audio.sample_rate -ne [string]$B.Audio.sample_rate) { $problems.Add("audio sample rate: $($A.Audio.sample_rate) vs $($B.Audio.sample_rate)") }
        if ([string]$A.Audio.channels -ne [string]$B.Audio.channels) { $problems.Add("audio channels: $($A.Audio.channels) vs $($B.Audio.channels)") }
    }
    if ($problems.Count -gt 0) { Fail ("Inputs are not compatible for this join:`n  " + ($problems -join "`n  ")) }
}

function Get-EncoderArgs($M) {
    $v = $M.Video
    $encList = (& ffmpeg -hide_banner -encoders) -join "`n"
    $a = @()
    switch ([string]$v.codec_name) {
        'h264' { $name='libx264'; $a += @('-c:v','libx264','-preset','slow','-crf','18') }
        'hevc' { $name='libx265'; $a += @('-c:v','libx265','-preset','slow','-crf','20') }
        'av1'  { $name='libsvtav1'; $a += @('-c:v','libsvtav1','-preset','5','-crf','24') }
        default { Fail "--force has no configured encoder for source codec '$($v.codec_name)'." }
    }
    if ($encList -notmatch ('\s' + [regex]::Escape($name) + '\s')) { Fail "This ffmpeg build has no '$name' encoder." }
    if ($v.pix_fmt) { $a += @('-pix_fmt',[string]$v.pix_fmt) }
    return $a
}

function Cut-Segment($M, [long]$Start, [long]$End, [string]$OutFile, [bool]$Force) {
    if ($Start -lt 0 -or $End -lt $Start -or $End -gt $M.LastFrame) {
        Fail "Invalid frame range $Start-$End for '$($M.File)' (valid: 0-$($M.LastFrame))."
    }
    $kf = Find-StartKeyframe $M $Start $End
    if (-not $kf) { Fail "Could not find a usable keyframe near frame $Start in '$($M.File)'." }
    [long]$K = $kf.Frame
    $startIsKey = ($K -eq $Start)

    if (-not $Force) {
        [long]$endUsed = Find-CopyEnd $M $End
        [long]$count = $endUsed - $K + 1
        Write-Host "  source    : $($M.File)"
        Write-Host "  requested : $Start-$End"
        if ($K -ne $Start) { Write-Host "  start     : $K (nearest keyframe)" -ForegroundColor Yellow }
        else { Write-Host "  start     : $K (exact keyframe)" }
        if ($endUsed -ne $End) { Write-Host "  end       : $endUsed (extended for clean stream copy)" -ForegroundColor Yellow }
        else { Write-Host "  end       : $endUsed" }
        Write-Host "  actual    : $K-$endUsed ($count frames)"
        $ff = @('-hide_banner','-y','-loglevel','error','-ss',(SeekArg $M ($kf.Pts + $M.Eps)),'-i',$M.File,
                '-map','0:v:0','-map','0:a:0?','-frames:v',"$count",'-t',(Fmt ($count / $M.Fps)),
                '-c','copy','-avoid_negative_ts','make_zero',$OutFile)
        & ffmpeg @ff
        if ($LASTEXITCODE -ne 0) { Fail "ffmpeg failed while cutting '$($M.File)'." }
    }
    else {
        [long]$count = $End - $Start + 1
        Write-Host "  source    : $($M.File)"
        Write-Host "  requested : $Start-$End"
        Write-Host "  actual    : $Start-$End ($count frames, video re-encoded)" -ForegroundColor Yellow
        $enc = Get-EncoderArgs $M
        $ff = @('-hide_banner','-y','-loglevel','error','-ss',(SeekArg $M ((FrameTime $M $Start) - $M.Eps)),'-i',$M.File,
                '-map','0:v:0','-map','0:a:0?','-frames:v',"$count",'-t',(Fmt ($count / $M.Fps))) + $enc + @(
                '-c:a','copy','-avoid_negative_ts','make_zero',$OutFile)
        & ffmpeg @ff
        if ($LASTEXITCODE -ne 0) { Fail "ffmpeg failed while exact-cutting '$($M.File)'." }
    }
}

# arguments
$pos = New-Object System.Collections.Generic.List[string]
$outName = $null; $force = $false
for ($i=0; $i -lt $args.Count; $i++) {
    $x=[string]$args[$i]
    switch ($x) {
        '-o' { if ($i+1 -ge $args.Count) { Fail '-o requires a filename.' }; $i++; $outName=[string]$args[$i] }
        '--output' { if ($i+1 -ge $args.Count) { Fail '--output requires a filename.' }; $i++; $outName=[string]$args[$i] }
        '--force' { $force=$true }
        '-h' { Usage; exit 0 }
        '--help' { Usage; exit 0 }
        default { if ($x.StartsWith('-')) { Fail "Unknown option: $x" }; $pos.Add($x) }
    }
}
if ($args.Count -eq 0) { Usage; exit 0 }
if ($pos.Count -ne 6) { Usage; Fail 'Expected 6 arguments.' }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Fail 'ffmpeg was not found in PATH.' }
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { Fail 'ffprobe was not found in PATH.' }

$f1=$pos[0]; $f2=$pos[3]
if (-not (Test-Path -LiteralPath $f1 -PathType Leaf)) { Fail "Input file not found: $f1" }
if (-not (Test-Path -LiteralPath $f2 -PathType Leaf)) { Fail "Input file not found: $f2" }
[long]$s1=0; [long]$e1=0; [long]$s2=0; [long]$e2=0
if (-not [long]::TryParse($pos[1],[ref]$s1)) { Fail "Invalid start frame: $($pos[1])" }
if (-not [long]::TryParse($pos[2],[ref]$e1)) { Fail "Invalid end frame: $($pos[2])" }
if (-not [long]::TryParse($pos[4],[ref]$s2)) { Fail "Invalid start frame: $($pos[4])" }
if (-not [long]::TryParse($pos[5],[ref]$e2)) { Fail "Invalid end frame: $($pos[5])" }

Write-Host 'Reading media info...'
$m1=Get-Media $f1; $m2=Get-Media $f2
Check-Compatible $m1 $m2

$dir=Split-Path -Parent $m1.File
$base=[IO.Path]::GetFileNameWithoutExtension($m1.File)
if ($outName) {
    if ([IO.Path]::GetExtension($outName) -eq '') { $outName += '.mkv' }
    $output = if ([IO.Path]::IsPathRooted($outName)) { $outName } else { Join-Path $dir $outName }
} else { $output=Join-Path $dir ($base + '_glued.mkv') }
$output=[IO.Path]::GetFullPath($output)
if ($output -eq $m1.File -or $output -eq $m2.File) { Fail 'Output cannot overwrite an input.' }

$tempDir=Join-Path ([IO.Path]::GetTempPath()) ('mkvglue_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null
$seg1=Join-Path $tempDir 'segment1.mkv'; $seg2=Join-Path $tempDir 'segment2.mkv'; $list=Join-Path $tempDir 'concat.txt'
try {
    Write-Host ''
    Write-Host 'Segment 1' -ForegroundColor Cyan
    Cut-Segment $m1 $s1 $e1 $seg1 $force
    Write-Host ''
    Write-Host 'Segment 2' -ForegroundColor Cyan
    Cut-Segment $m2 $s2 $e2 $seg2 $force

    # ffmpeg concat-demuxer list. Paths are generated by us and contain no single quotes in normal temp paths.
    $p1=$seg1.Replace('\\','/').Replace("'","'\\''")
    $p2=$seg2.Replace('\\','/').Replace("'","'\\''")
    [IO.File]::WriteAllText($list, "file '$p1'`r`nfile '$p2'`r`n", (New-Object Text.UTF8Encoding($false)))

    Write-Host ''
    Write-Host "Joining    : $output"
    & ffmpeg -hide_banner -y -loglevel error -f concat -safe 0 -i $list -map 0:v:0 -map 0:a:0? -c copy -avoid_negative_ts make_zero $output
    if ($LASTEXITCODE -ne 0) { Fail 'ffmpeg failed while joining the two temporary segments.' }
    if (-not (Test-Path -LiteralPath $output)) { Fail 'Output file was not created.' }
    $size=(Get-Item -LiteralPath $output).Length
    Write-Host ("Done       : {0:N2} MB" -f ($size/1MB)) -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
