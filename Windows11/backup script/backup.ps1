$conf = ".backuppath.conf"
$local = (Get-Location).Path
$dry = $false
$forceScan = $false

if ($args -contains "--dry") {
    $dry = $true
}

function HelpShort {
@"
Commands

backup -path "PATH" [--excludeDir "dir1" "dir2" ...] [--excludeFile "*.log" "file.txt" ...] [-scanLinks]
backup -pathlinks "PATH" [--excludeDir ...] [--excludeFile ...]

backup -push | -store
backup -pull | -fetch

backup --scanLinks
backup --compare

Every command accepts one or two leading dashes
(--push and -push are the same).

backup --dry

backup -h | --help
backup -hv | --helpv
"@
}

function HelpVerbose {
@"
Backup tool using robocopy.

CONFIG
------
.backuppath.conf contains the server directory path, optional
exclude lists for directories and files, and the symbolic links
recorded by --scanLinks.

COMMANDS
--------

-path "PATH" [--excludeDir "dir1" "dir2" ...] [--excludeFile "*.log" ...] [-scanLinks]
    Save the server path to config.
    Optionally list directory names and/or file names to exclude.
    Overwrites the entire config each time.
    Quote any name containing spaces.

    Excluded directories are matched by name at any depth.
    Excluded files are matched by name or wildcard (* ?) at any
    depth. No paths - if the same name exists in many directories,
    it is excluded in all of them.

    Names do not need to exist yet; nothing is validated.

    Add -scanLinks to scan for symbolic links straight after the
    config is written.

    Examples:
        backup -path "D:\Backup"
        backup -path "D:\Backup" --excludeDir node_modules .git
        backup -path "D:\Backup" --excludeDir "my folder" --excludeFile *.log thumbs.db
        backup -path "D:\Backup" --excludeDir node_modules -scanLinks

-pathlinks "PATH" [--excludeDir ...] [--excludeFile ...]
    Same as -path with -scanLinks always applied.

-push / -store
    Mirror local directory -> server directory.
    Excluded directories and files are never copied.

-pull / -fetch
    Mirror server directory -> local directory.
    Excluded directories and files are never copied, and local
    copies of excluded content are never deleted.

--scanLinks
    Scan the local directory for directory symbolic links
    (created with mklink /D) and record their full paths under
    "--== System Link Directories ==--".

    Replaces the whole section each time, so links that no longer
    exist are dropped.

    Needs a config that already has a path. Use -path -scanLinks
    or -pathlinks to do both at once.

--compare
    Run robocopy as a dry run and show its full output, then print
    a formatted report underneath. Nothing is ever modified.

    Excluded content is ignored by the comparison.

    The report lists each differing file with a status tag:
        [SERVER ONLY]   exists on server, not local
        [LOCAL  ONLY]   exists locally, not on server
        [SERVER NEWER]  server copy has a more recent timestamp
        [LOCAL  NEWER]  local copy has a more recent timestamp
        [DIFFERENT]     size or attributes differ, timestamps equal

    A count summary follows, then a single verdict line saying
    whether anything differs and which side is newer:

        IN SYNC - no differences found
        DIFFERENCES FOUND - local is newer
        DIFFERENCES FOUND - server is newer
        DIFFERENCES FOUND - both sides have changes

    Robocopy's own totals are used as a cross-check. If robocopy
    reports differences but none could be parsed out of its
    output, the report says so rather than claiming "in sync".

--dry
    Simulate changes without modifying files.

SYMBOLIC LINKS
--------------

Recorded links are excluded exactly like any other excluded
directory. Robocopy never looks inside them on either side, so
they are never copied to the server and never deleted locally.

Without this, -pull would find no matching directory on the
server and purge the link - following it and deleting the real
contents it points at. Robocopy's /XJ flag does not prevent
this; it only excludes links on the source side.

The list is only refreshed by --scanLinks, and -path clears it
along with the rest of the config. After adding or removing a
link, or after running -path, run --scanLinks again.

SAFETY
------

The script refuses to run if:

- source equals target
- source or target is drive root
- config file is missing
"@
}

function NormalizePath($p) {
    if ($null -eq $p) {
        return ""
    }

    $clean = [string]$p
    $clean = $clean.Trim()

    # Windows paths cannot legally contain double quotes.
    # Remove any that were accidentally saved.
    $clean = $clean.Replace('"', "")

    # Normalise forward slashes and strip trailing slashes
    # (c:\foo\  c:/foo/  c:/foo  all become c:\foo)
    $clean = $clean.Replace('/', '\')
    $clean = $clean.TrimEnd('\')

    return $clean
}

# --------------------------------------------------------------------
# Raw command-line tokenizer.
#
# Windows argument parsing treats \" as an escaped quote, so a path
# typed as "z:\test\" swallows everything after it into one argument
# before the script ever sees it. For the -path command we therefore
# re-tokenize the RAW process command line with simpler rules:
#   - a quote toggles grouping on/off
#   - backslash is always a literal character, never an escape
# --------------------------------------------------------------------

function GetRawArgTokens {
    $raw = [Environment]::CommandLine
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    # Everything after the script filename is our argument tail
    $scriptName = Split-Path -Leaf $PSCommandPath
    $idx = $raw.IndexOf($scriptName, [StringComparison]::OrdinalIgnoreCase)
    if ($idx -lt 0) { return $null }

    $tail = $raw.Substring($idx + $scriptName.Length)
    $tail = $tail.TrimStart('"').Trim()

    if ($tail -eq "") { return @() }

    $tokens = @()
    $cur = ""
    $inQuote = $false

    foreach ($ch in $tail.ToCharArray()) {
        if ($ch -eq '"') {
            $inQuote = -not $inQuote
        }
        elseif (($ch -eq ' ' -or $ch -eq "`t") -and -not $inQuote) {
            if ($cur -ne "") {
                $tokens += $cur
                $cur = ""
            }
        }
        else {
            $cur += $ch
        }
    }
    if ($cur -ne "") {
        $tokens += $cur
    }

    return $tokens
}

function SaveConf($serverPath, $excludeDirs, $excludeFiles, $linkDirs = @(), [bool]$quiet = $false) {
    $clean = NormalizePath $serverPath

    if ([string]::IsNullOrWhiteSpace($clean)) {
        Write-Host "ERROR: Missing path"
        exit 1
    }

    # Store excludes alphabetically regardless of input order
    if ($excludeDirs.Count -gt 0) {
        $excludeDirs = @($excludeDirs | Sort-Object)
    }
    if ($excludeFiles.Count -gt 0) {
        $excludeFiles = @($excludeFiles | Sort-Object)
    }
    if ($linkDirs.Count -gt 0) {
        $linkDirs = @($linkDirs | Sort-Object)
    }

    # Blank line before each header for readability
    $lines = @("path=$clean")

    if ($excludeDirs.Count -gt 0) {
        $lines += ""
        $lines += "--== Excluded Directories ==--"
        foreach ($e in $excludeDirs) {
            $lines += $e
        }
    }

    if ($excludeFiles.Count -gt 0) {
        $lines += ""
        $lines += "--== Excluded Files ==--"
        foreach ($e in $excludeFiles) {
            $lines += $e
        }
    }

    # Written last: full paths, kept apart from the hand-edited
    # exclude lists because only --scanLinks maintains them.
    if ($linkDirs.Count -gt 0) {
        $lines += ""
        $lines += "--== System Link Directories ==--"
        foreach ($e in $linkDirs) {
            $lines += $e
        }
    }

    Set-Content -Path $conf -Value $lines -Encoding UTF8

    if ($quiet) {
        return
    }

    Write-Host "Saved server path to .backuppath.conf"

    if ($excludeDirs.Count -gt 0) {
        Write-Host "Excluded directories:"
        foreach ($e in $excludeDirs) {
            Write-Host "  $e"
        }
    }

    if ($excludeFiles.Count -gt 0) {
        Write-Host "Excluded files:"
        foreach ($e in $excludeFiles) {
            Write-Host "  $e"
        }
    }
}

function ReadConf {
    if (!(Test-Path $conf)) {
        Write-Host "ERROR: .backuppath.conf not found"
        Write-Host "Run: backup -path `"server/path`""
        exit 1
    }

    $lines = @(Get-Content -Path $conf -Encoding UTF8)

    $serverPath = ""
    $excludeDirs = @()
    $excludeFiles = @()
    $linkDirs = @()
    $section = "none"

    foreach ($line in $lines) {
        $trimmed = ([string]$line).Trim()

        if ($trimmed -match '^path=(.*)$') {
            $serverPath = NormalizePath $matches[1]
        }
        elseif ($trimmed -match '^--==\s*(.*?)\s*==--$') {
            # Any header line switches section. Unknown headers stop
            # collection so their contents never leak into a list.
            $header = $matches[1]

            if ($header -ieq "Excluded Directories") {
                $section = "dirs"
            }
            elseif ($header -ieq "Excluded Files") {
                $section = "files"
            }
            elseif ($header -ieq "System Link Directories") {
                $section = "links"
            }
            elseif ($header -ieq "exclude") {
                # Legacy header from older confs
                $section = "dirs"
            }
            else {
                $section = "none"
            }
        }
        elseif ($trimmed -ne "") {
            if ($section -eq "dirs") {
                $excludeDirs += $trimmed
            }
            elseif ($section -eq "files") {
                $excludeFiles += $trimmed
            }
            elseif ($section -eq "links") {
                $linkDirs += NormalizePath $trimmed
            }
        }
    }

    # Legacy support: conf written as a bare path with no key
    if ([string]::IsNullOrWhiteSpace($serverPath) -and $lines.Count -gt 0) {
        $first = ([string]$lines[0]).Trim()
        if ($first -ne "" -and $first -notmatch '^--') {
            $serverPath = NormalizePath $first
        }
    }

    if ([string]::IsNullOrWhiteSpace($serverPath)) {
        Write-Host "ERROR: .backuppath.conf is empty or missing path"
        exit 1
    }

    # Keep display order alphabetical even if the conf was hand-edited
    if ($excludeDirs.Count -gt 0) {
        $excludeDirs = @($excludeDirs | Sort-Object)
    }
    if ($excludeFiles.Count -gt 0) {
        $excludeFiles = @($excludeFiles | Sort-Object)
    }
    if ($linkDirs.Count -gt 0) {
        $linkDirs = @($linkDirs | Sort-Object)
    }

    # Symlinks are ordinary /XD exclusions - merging them here means
    # push, pull and compare need no special handling at all.
    # ExcludeDirs is what robocopy gets; LinkDirs is kept separate
    # only so --scanLinks can replace it and the two can be listed
    # apart on screen.
    return @{
        Path         = $serverPath
        ExcludeDirs  = @($excludeDirs) + @($linkDirs)
        ExcludeFiles = $excludeFiles
        ConfDirs     = $excludeDirs
        LinkDirs     = $linkDirs
    }
}

function IsDriveRoot($p) {
    $p = NormalizePath $p
    return $p -match '^[A-Za-z]:\\?$'
}

function SafetyCheck($src, $dst, [bool]$createTargetIfMissing = $false) {
    $src = NormalizePath $src
    $dst = NormalizePath $dst

    if ($src -eq $dst) {
        Write-Host "ERROR: Source and destination are identical."
        exit 1
    }

    if (IsDriveRoot $src) {
        Write-Host "ERROR: Refusing to mirror drive root source."
        exit 1
    }

    if (IsDriveRoot $dst) {
        Write-Host "ERROR: Refusing to mirror drive root target."
        exit 1
    }

    if (!(Test-Path -LiteralPath $src)) {
        Write-Host "ERROR: Source does not exist."
        Write-Host $src
        exit 1
    }

    if (!(Test-Path -LiteralPath $dst)) {
        if ($createTargetIfMissing) {
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
        }
        else {
            Write-Host "ERROR: Target does not exist."
            Write-Host $dst
            exit 1
        }
    }
}

function ShowExcludes($excludeDirs, $excludeFiles, $linkDirs = @()) {
    if ($excludeDirs.Count -gt 0) {
        Write-Host "Excluding directories:"
        foreach ($e in $excludeDirs) {
            Write-Host "  $e"
        }
    }

    if ($excludeFiles.Count -gt 0) {
        Write-Host "Excluding files:"
        foreach ($e in $excludeFiles) {
            Write-Host "  $e"
        }
    }

    if ($linkDirs.Count -gt 0) {
        Write-Host "Excluding system links:"
        foreach ($e in $linkDirs) {
            Write-Host "  $e"
        }
    }
}

function ScanLocalSymlinks($root) {
    # Walks the local tree for directory symbolic links (mklink /D).
    # Only --scanLinks runs this; push and pull read the config, so a
    # large tree is never scanned during a normal backup.
    $found = @()

    $items = Get-ChildItem -LiteralPath $root -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LinkType -eq "SymbolicLink" }

    foreach ($item in $items) {
        $found += NormalizePath $item.FullName
    }

    return $found
}

function DoScanLinks($serverPath, $excludeDirs, $excludeFiles) {
    Write-Host ""
    Write-Host "SCANNING FOR SYSTEM LINKS"
    Write-Host $local
    Write-Host ""

    $found = @(ScanLocalSymlinks $local)

    # Replaces the section outright - links that are gone drop out.
    SaveConf $serverPath $excludeDirs $excludeFiles $found $true

    if ($found.Count -eq 0) {
        Write-Host "No system links found."
        Write-Host "System link section cleared in .backuppath.conf"
    }
    else {
        Write-Host "Found $($found.Count) system link(s):"
        foreach ($s in $found) {
            Write-Host "  $s"
        }
        Write-Host ""
        Write-Host "Saved to .backuppath.conf"
    }
}

function DoCompare($local, $server, $excludeDirs, $excludeFiles) {
    # Robocopy runs in list-only mode (/L), so nothing is ever modified.
    #
    # Its output is printed as it arrives and captured at the same time.
    # There is no log file and therefore no encoding to get wrong. An
    # earlier version wrote /LOG: (which robocopy emits as ANSI) and read
    # it back as Unicode; every line decoded to garbage, matched nothing,
    # and the parser reported "In sync" while real differences existed.
    #
    # Flag keywords, running local -> server:
    #   Newer      local copy is newer
    #   Older      server copy is newer
    #   *EXTRA     exists on server only
    #   New File   exists on local only
    #   Changed / size / attrib   timestamps match, content does not

    $local  = NormalizePath $local
    $server = NormalizePath $server

    Write-Host ""
    Write-Host "COMPARING LOCAL <-> SERVER   (dry run - nothing is modified)"
    Write-Host "$local"
    Write-Host "$server"

    ShowExcludes $excludeDirs $excludeFiles
    Write-Host ""

    $rcArgs = @(
        $local
        $server
        "/MIR"
        "/L"
        "/FFT"
        "/NP"
        "/FP"
        "/XJ"
        "/R:0"
        "/W:0"
    )

    if ($excludeDirs.Count -gt 0) {
        $rcArgs += "/XD"
        foreach ($e in $excludeDirs) { $rcArgs += $e }
    }
    if ($excludeFiles.Count -gt 0) {
        $rcArgs += "/XF"
        foreach ($e in $excludeFiles) { $rcArgs += $e }
    }

    # Stream to screen and collect at once, so a long scan still shows
    # progress instead of sitting silent until robocopy finishes.
    $out = New-Object System.Collections.ArrayList
    & robocopy @rcArgs | ForEach-Object {
        Write-Host $_
        [void]$out.Add([string]$_)
    }
    $rc = $LASTEXITCODE

    if ($rc -ge 8) {
        Write-Host ""
        Write-Host "ERROR: robocopy failed with exit code $rc"
        exit $rc
    }

    # ----------------------------------------------------------------
    # Parse the body for names
    # ----------------------------------------------------------------

    $serverOnly    = @()
    $localOnly     = @()
    $serverNewer   = @()
    $localNewer    = @()
    $different     = @()
    $serverOnlyDir = @()

    foreach ($line in $out) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Directory scan lines are "<spaces><count><spaces><path>" and
        # carry no keyword. *EXTRA Dir lines do carry one, so test for
        # the keyword before discarding plain scan lines.
        $head = $line.Substring(0, [Math]::Min(24, $line.Length))

        $isExtraDir = $head -match '(?i)\*EXTRA\s+Dir'

        if (-not $isExtraDir -and $line -match '^\s+\d+\s+\S') { continue }
        if ($line -notmatch '[A-Za-z]:\\') { continue }

        if ($line -match '([A-Za-z]:\\.*)$') {
            $fullPath = $matches[1].Trim()
        }
        else { continue }

        # Make relative for display
        $rel = $fullPath
        if ($rel.StartsWith($local, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($local.Length).TrimStart('\')
        }
        elseif ($rel.StartsWith($server, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($server.Length).TrimStart('\')
        }
        if ($rel -eq "" -or $rel -eq $fullPath) { continue }

        if ($isExtraDir) {
            $serverOnlyDir += $rel
            continue
        }

        # Anything else ending in a backslash is a directory header
        if ($fullPath.EndsWith('\')) { continue }

        $h = $head.ToLower()

        if     ($h -match '\*extra')      { $serverOnly  += $rel }
        elseif ($h -match 'new file')     { $localOnly   += $rel }
        elseif ($h -match '\*lonely')     { $localOnly   += $rel }
        elseif ($h -match '\bnewer\b')    { $localNewer  += $rel }
        elseif ($h -match '\bolder\b')    { $serverNewer += $rel }
        elseif ($h -match '\bchanged\b' -or
                $h -match '\bsize\b'    -or
                $h -match '\battrib\b')   { $different   += $rel }
    }

    # ----------------------------------------------------------------
    # Parse robocopy's own totals as a cross-check
    #
    # These are authoritative in a way parsed body lines are not: if
    # robocopy says files would be copied but we bucketed none, the
    # parser is broken and must say so instead of printing "in sync".
    # ----------------------------------------------------------------

    $rcFilesCopied = -1
    $rcFilesExtra  = -1
    $rcDirsExtra   = -1

    foreach ($line in $out) {
        if ($line -match '^\s*Files\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
            $rcFilesCopied = [int]$matches[2]
            $rcFilesExtra  = [int]$matches[6]
        }
        elseif ($line -match '^\s*Dirs\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
            $rcDirsExtra = [int]$matches[6]
        }
    }

    $rcSaysDiff = ($rcFilesCopied -gt 0) -or ($rcFilesExtra -gt 0) -or ($rcDirsExtra -gt 0)

    $allDiff = @($serverOnly) + @($localOnly) + @($serverNewer) +
               @($localNewer) + @($different) + @($serverOnlyDir)

    $divider = "-" * 78

    Write-Host ""
    Write-Host $divider
    Write-Host "  REPORT"
    Write-Host $divider
    Write-Host ""

    # Parser failed but robocopy disagrees - never claim "in sync" here.
    if ($allDiff.Count -eq 0 -and ($rcSaysDiff -or $rc -ne 0)) {
        Write-Host "  WARNING: robocopy reports differences but none could be read"
        Write-Host "           from its output. The report below is incomplete."
        Write-Host ""
        if ($rcFilesCopied -gt 0) { Write-Host "  Files that would be copied: $rcFilesCopied" }
        if ($rcFilesExtra  -gt 0) { Write-Host "  Extra files on server:      $rcFilesExtra" }
        if ($rcDirsExtra   -gt 0) { Write-Host "  Extra dirs on server:       $rcDirsExtra" }
        Write-Host ""
        Write-Host "  DIFFERENCES FOUND - see robocopy output above"
        Write-Host "  (robocopy exit code $rc)"
        Write-Host ""
        return
    }

    if ($allDiff.Count -eq 0) {
        Write-Host "  IN SYNC - no differences found"
        Write-Host ""
        return
    }

    # --- File list ---
    foreach ($f in ($serverOnlyDir | Sort-Object)) { Write-Host "  [SERVER DIR]    $f" }
    foreach ($f in ($serverOnly    | Sort-Object)) { Write-Host "  [SERVER ONLY]   $f" }
    foreach ($f in ($localOnly     | Sort-Object)) { Write-Host "  [LOCAL  ONLY]   $f" }
    foreach ($f in ($serverNewer   | Sort-Object)) { Write-Host "  [SERVER NEWER]  $f" }
    foreach ($f in ($localNewer    | Sort-Object)) { Write-Host "  [LOCAL  NEWER]  $f" }
    foreach ($f in ($different     | Sort-Object)) { Write-Host "  [DIFFERENT]     $f" }

    # --- Counts ---
    Write-Host ""
    Write-Host $divider

    $total = $allDiff.Count
    Write-Host "  $total item(s) differ"
    Write-Host ""

    if ($serverOnlyDir.Count -gt 0) { Write-Host ("  Server dirs:  " + $serverOnlyDir.Count) }
    if ($serverOnly.Count    -gt 0) { Write-Host ("  Server only:  " + $serverOnly.Count) }
    if ($localOnly.Count     -gt 0) { Write-Host ("  Local  only:  " + $localOnly.Count) }
    if ($serverNewer.Count   -gt 0) { Write-Host ("  Server newer: " + $serverNewer.Count) }
    if ($localNewer.Count    -gt 0) { Write-Host ("  Local  newer: " + $localNewer.Count) }
    if ($different.Count     -gt 0) { Write-Host ("  Different:    " + $different.Count) }

    # --- Verdict ---
    $localAhead  = ($localNewer.Count  + $localOnly.Count)
    $serverAhead = ($serverNewer.Count + $serverOnly.Count + $serverOnlyDir.Count)

    Write-Host ""
    Write-Host $divider

    if ($localAhead -gt 0 -and $serverAhead -gt 0) {
        Write-Host "  DIFFERENCES FOUND - both sides have changes"
        Write-Host "  Run -pull to update local, -push to update server"
    }
    elseif ($localAhead -gt 0) {
        Write-Host "  DIFFERENCES FOUND - local is newer"
        Write-Host "  Run -push to update server"
    }
    elseif ($serverAhead -gt 0) {
        Write-Host "  DIFFERENCES FOUND - server is newer"
        Write-Host "  Run -pull to update local"
    }
    else {
        Write-Host "  DIFFERENCES FOUND - timestamps match but content differs"
        Write-Host "  Check manually before pushing or pulling"
    }

    Write-Host ""
}

function RunRobocopy($src, $dst, $excludeDirs, $excludeFiles) {
    $src = NormalizePath $src
    $dst = NormalizePath $dst

    $rcArgs = @(
        $src
        $dst
        "/MIR"
        "/FFT"
        "/Z"
        "/R:2"
        "/W:2"
        "/XJ"
        "/NP"
    )

    if ($dry) {
        $rcArgs += "/L"
    }

    # /XD and /XF match names at any depth. They also suppress /MIR's
    # purge for excluded content, so excluded files and directories
    # are never copied and never deleted on either side.
    if ($excludeDirs.Count -gt 0) {
        $rcArgs += "/XD"
        foreach ($e in $excludeDirs) {
            $rcArgs += $e
        }
    }

    if ($excludeFiles.Count -gt 0) {
        $rcArgs += "/XF"
        foreach ($e in $excludeFiles) {
            $rcArgs += $e
        }
    }

    & robocopy @rcArgs
    $rc = $LASTEXITCODE

    if ($rc -ge 8) {
        Write-Host ""
        Write-Host "ERROR: robocopy failed with exit code $rc"
        exit $rc
    }

    exit 0
}

if ($args.Count -eq 0) {
    HelpShort
    exit
}

switch ($args[0]) {
    "-h"      { HelpShort; exit }
    "--help"  { HelpShort; exit }
    "help"    { HelpShort; exit }

    "-hv"     { HelpVerbose; exit }
    "--helpv" { HelpVerbose; exit }
    "helpv"   { HelpVerbose; exit }

    "-path"       { $mode = "path" }
    "--path"      { $mode = "path" }
    "-pathlinks"  { $mode = "path"; $forceScan = $true }
    "--pathlinks" { $mode = "path"; $forceScan = $true }
}

if ($mode -eq "path") {
    # Use raw command-line tokens so trailing backslashes inside
    # quotes ("z:\test\") cannot corrupt argument splitting.
    $tokens = GetRawArgTokens
    if ($null -eq $tokens -or $tokens.Count -lt 2) {
        # Fallback to PowerShell's own parsing
        $tokens = @()
        foreach ($a in $args) { $tokens += [string]$a }
    }

    if ($tokens.Count -lt 2) {
        Write-Host "ERROR: Missing path"
        exit 1
    }

    $targetPath = $tokens[1]
    $excludeDirs = @()
    $excludeFiles = @()
    $collecting = "none"
    $scanAfter = $forceScan

    for ($i = 2; $i -lt $tokens.Count; $i++) {
        $t = $tokens[$i]

        if ($t -ieq "--excludeDir" -or $t -ieq "--exclude") {
            # --exclude retained as a legacy alias
            $collecting = "dirs"
        }
        elseif ($t -ieq "--excludeFile") {
            $collecting = "files"
        }
        elseif ($t -ieq "-scanLinks" -or $t -ieq "--scanLinks") {
            # A flag, never an exclude name - otherwise it would be
            # swallowed into whichever list is currently collecting.
            $scanAfter = $true
        }
        elseif ($t -eq "--dry") {
            continue
        }
        elseif ($collecting -ne "none") {
            # "./cat" and "cat" are the same thing; strip the
            # leading ./ or .\ but never eat dot-names like .git
            $entry = $t.Trim()
            $entry = $entry -replace '^\.[\\/]', ''
            $entry = $entry.TrimEnd('\', '/')
            if ($entry -ne "") {
                if ($collecting -eq "dirs") {
                    $excludeDirs += $entry
                }
                else {
                    $excludeFiles += $entry
                }
            }
        }
    }

    # Nothing is validated: names may refer to directories or
    # files that do not exist yet, or never will.

    # Always a full rewrite - any previously recorded links are
    # dropped, then re-scanned below if asked for.
    SaveConf $targetPath $excludeDirs $excludeFiles @()

    if ($scanAfter) {
        # The conf now exists with a valid path, so the scan can
        # simply read it back and replace the link section.
        $c = ReadConf
        DoScanLinks $c.Path $c.ConfDirs $c.ExcludeFiles
    }

    exit
}

switch ($args[0]) {
    "--scanLinks" { $mode = "scanlinks" }
    "-scanLinks"  { $mode = "scanlinks" }
    "scanLinks"   { $mode = "scanlinks" }

    "--compare"   { $mode = "compare" }
    "-compare"    { $mode = "compare" }
    "compare"     { $mode = "compare" }

    "-push"   { $mode = "push" }
    "--push"  { $mode = "push" }
    "-store"  { $mode = "push" }
    "--store" { $mode = "push" }

    "-pull"   { $mode = "pull" }
    "--pull"  { $mode = "pull" }
    "-fetch"  { $mode = "pull" }
    "--fetch" { $mode = "pull" }

    default {
        HelpShort
        exit
    }
}

$confData = ReadConf
$server = $confData.Path
$excludeDirs = $confData.ExcludeDirs
$excludeFiles = $confData.ExcludeFiles

if ($mode -eq "scanlinks") {
    DoScanLinks $server $confData.ConfDirs $excludeFiles
    exit 0
}

if ($mode -eq "compare") {
    SafetyCheck $local $server $false
    DoCompare $local $server $excludeDirs $excludeFiles
    exit 0
}

if ($mode -eq "push") {
    SafetyCheck $local $server $true

    Write-Host ""
    Write-Host "LOCAL  -> SERVER"
    Write-Host "$local -> $server"

    ShowExcludes $confData.ConfDirs $excludeFiles $confData.LinkDirs

    Write-Host ""

    RunRobocopy $local $server $excludeDirs $excludeFiles
}

if ($mode -eq "pull") {
    SafetyCheck $server $local $false

    Write-Host ""
    Write-Host "SERVER -> LOCAL"
    Write-Host "$server -> $local"

    ShowExcludes $confData.ConfDirs $excludeFiles $confData.LinkDirs

    Write-Host ""

    RunRobocopy $server $local $excludeDirs $excludeFiles
}