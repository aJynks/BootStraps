$conf = ".backuppath.conf"
$local = (Get-Location).Path
$dry = $false

if ($args -contains "--dry") {
    $dry = $true
}

function HelpShort {
@"
Commands

backup -path "PATH"

backup -push | -store
backup -pull | -fetch
backup -verify

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
.backuppath.conf contains the server directory path.

COMMANDS
--------

-path "PATH"
    Save the server path to config.

-push / -store
    Mirror local directory -> server directory.

-pull / -fetch
    Mirror server directory -> local directory.

-verify
    Compare directories without modifying anything.

--dry
    Simulate changes without modifying files.

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

    return $clean
}

function SaveServerPath($p) {
    $clean = NormalizePath $p

    if ([string]::IsNullOrWhiteSpace($clean)) {
        Write-Host "ERROR: Missing path"
        exit 1
    }

    Set-Content -Path $conf -Value $clean -NoNewline
    Write-Host "Saved server path to .backuppath.conf"
}

function GetServerPath {
    if (!(Test-Path $conf)) {
        Write-Host "ERROR: .backuppath.conf not found"
        Write-Host "Run: backup -path `"server/path`""
        exit 1
    }

    $path = Get-Content -Path $conf -Raw
    $path = NormalizePath $path

    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Host "ERROR: .backuppath.conf is empty"
        exit 1
    }

    return $path
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

function RunRobocopy($src, $dst, $verifyOnly) {
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

    if ($verifyOnly -or $dry) {
        $rcArgs += "/L"
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

    "-path" {
        if ($args.Count -lt 2) {
            Write-Host "ERROR: Missing path"
            exit 1
        }

        SaveServerPath $args[1]
        exit
    }

    "-push"   { $mode = "push" }
    "-store"  { $mode = "push" }

    "-pull"   { $mode = "pull" }
    "-fetch"  { $mode = "pull" }

    "-verify" { $mode = "verify" }

    default {
        HelpShort
        exit
    }
}

$server = GetServerPath

if ($mode -eq "push") {
    SafetyCheck $local $server $true

    Write-Host ""
    Write-Host "LOCAL  -> SERVER"
    Write-Host "$local -> $server"
    Write-Host ""

    RunRobocopy $local $server $false
}

if ($mode -eq "pull") {
    SafetyCheck $server $local $false

    Write-Host ""
    Write-Host "SERVER -> LOCAL"
    Write-Host "$server -> $local"
    Write-Host ""

    RunRobocopy $server $local $false
}

if ($mode -eq "verify") {
    SafetyCheck $local $server $false

    Write-Host ""
    Write-Host "VERIFYING"
    Write-Host ""

    RunRobocopy $local $server $true
}