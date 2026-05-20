param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsList
)

$BackupSuffix = "requirements-backup.txt"
$OutdatedSuffix = "outdated-before-upgrade.txt"

function Show-Help {
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  updatepy -u"
    Write-Host "  updatepy --update"
    Write-Host "  updatepy -d <dir> -u"
    Write-Host ""
    Write-Host "  updatepy -r [date]"
    Write-Host "  updatepy --restore [date]"
    Write-Host ""
    Write-Host "  updatepy -list [date]"
    Write-Host "  updatepy --list [date]"
    Write-Host ""
    Write-Host "  updatepy -rp <package> [date]"
    Write-Host "  updatepy --restorepackage <package> [date]"
    Write-Host ""
    Write-Host "  updatepy -h"
    Write-Host "  updatepy --help"
    Write-Host "  updatepy -help"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  updatepy -u"
    Write-Host "  updatepy -d C:\Temp\PyBackup -u"
    Write-Host "  updatepy -r"
    Write-Host "  updatepy -r 29-04-2026"
    Write-Host "  updatepy -list"
    Write-Host "  updatepy -rp numpy"
    Write-Host "  updatepy -rp numpy 29-04-2026"
    Write-Host ""
    Write-Host "Notes:"
    Write-Host "  No arguments prints this help."
    Write-Host "  Backup format: DD-MM-YYYY---requirements-backup.txt"
    Write-Host "  Restore skips pip."
    Write-Host ""
}

function Fail($Message) {
    Write-Host "Error: $Message" -ForegroundColor Red
    exit 1
}

function Get-DatePrefix {
    return Get-Date -Format "dd-MM-yyyy"
}

function Get-BackupFileByDate($Directory, $DateText) {
    $file = Join-Path $Directory "$DateText---$BackupSuffix"
    if (-not (Test-Path $file)) {
        Fail "Backup file not found: $file"
    }
    return $file
}

function Get-LatestBackupFile($Directory) {
    $files = Get-ChildItem -Path $Directory -Filter "*---$BackupSuffix" -File |
        Sort-Object LastWriteTime -Descending

    if (-not $files -or $files.Count -eq 0) {
        Fail "No backup files found in: $Directory"
    }

    return $files[0].FullName
}

function Get-BackupFile($Directory, $DateText) {
    if ($DateText) {
        return Get-BackupFileByDate $Directory $DateText
    }

    return Get-LatestBackupFile $Directory
}

function Run-Pip($PipArgs) {
    & py -m pip @PipArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "pip command failed: py -m pip $($PipArgs -join ' ')"
    }
}

function Do-Update($Directory) {
    if (-not (Test-Path $Directory)) {
        New-Item -ItemType Directory -Path $Directory | Out-Null
    }

    $datePrefix = Get-DatePrefix
    $backupFile = Join-Path $Directory "$datePrefix---$BackupSuffix"
    $outdatedFile = Join-Path $Directory "$datePrefix---$OutdatedSuffix"

    Write-Host "Saving backup:"
    Write-Host "  $backupFile"
    & py -m pip freeze | Out-File -Encoding UTF8 $backupFile

    Write-Host "Saving outdated report:"
    Write-Host "  $outdatedFile"
    & py -m pip list --outdated | Out-File -Encoding UTF8 $outdatedFile

    Write-Host ""
    Write-Host "Clearing pip cache..."
    & py -m pip cache purge

    if ($LASTEXITCODE -ne 0) {
        Fail "Could not clear pip cache."
    }

    Write-Host ""
    Write-Host "Upgrading pip..."
    Run-Pip @("install", "--upgrade", "pip")

    Write-Host ""
    Write-Host "Finding outdated packages..."
    $outdatedJson = & py -m pip list --outdated --format=json

    if ($LASTEXITCODE -ne 0) {
        Fail "Could not get outdated package list."
    }

    $outdated = $outdatedJson | ConvertFrom-Json

    if (-not $outdated -or $outdated.Count -eq 0) {
        Write-Host "No outdated packages found."
        return
    }

    foreach ($item in $outdated) {
        $pkg = $item.name

        if ($pkg -ieq "pip") {
            continue
        }

        Write-Host ""
        Write-Host "Upgrading $pkg..."
        Run-Pip @("install", "--upgrade", $pkg)
    }

    Write-Host ""
    Write-Host "Done."
}

function Do-List($Directory, $DateText) {
    $backupFile = Get-BackupFile $Directory $DateText

    Write-Host "Reading:"
    Write-Host "  $backupFile"
    Write-Host ""

    Get-Content $backupFile
}

function Do-Restore($Directory, $DateText) {
    $backupFile = Get-BackupFile $Directory $DateText

    Write-Host "Restoring from:"
    Write-Host "  $backupFile"
    Write-Host "Skipping pip."
    Write-Host ""

    $tempFile = Join-Path $env:TEMP "updatepy-restore-no-pip.txt"

    Get-Content $backupFile |
        Where-Object { $_ -notmatch "^(?i)pip==" } |
        Out-File -Encoding UTF8 $tempFile

    Run-Pip @("install", "-r", $tempFile)

    Remove-Item $tempFile -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "Restore complete."
}

function Do-RestorePackage($Directory, $PackageName, $DateText) {
    if (-not $PackageName) {
        Fail "Missing package name. Example: updatepy -rp numpy"
    }

    if ($PackageName -ieq "pip") {
        Fail "This script does not restore pip."
    }

    $backupFile = Get-BackupFile $Directory $DateText

    $match = Get-Content $backupFile |
        Where-Object { $_ -match "^(?i)$([regex]::Escape($PackageName))==" } |
        Select-Object -First 1

    if (-not $match) {
        Fail "Package '$PackageName' not found in backup."
    }

    Write-Host "Restoring package:"
    Write-Host "  $match"
    Write-Host ""

    Run-Pip @("install", $match)

    Write-Host ""
    Write-Host "Package restore complete."
}

if (-not $ArgsList -or $ArgsList.Count -eq 0) {
    Show-Help
    exit 0
}

$Directory = (Get-Location).Path
$CleanArgs = New-Object System.Collections.Generic.List[string]

for ($i = 0; $i -lt $ArgsList.Count; $i++) {
    $arg = $ArgsList[$i]

    if ($arg -eq "-d" -or $arg -eq "--directory") {
        if ($i + 1 -ge $ArgsList.Count) {
            Fail "Missing directory after $arg"
        }

        $Directory = $ArgsList[$i + 1]
        $i++
    }
    else {
        $CleanArgs.Add($arg)
    }
}

if ($CleanArgs.Count -eq 0) {
    Show-Help
    exit 0
}

$cmd = $CleanArgs[0]

switch ($cmd) {
    "-h" { Show-Help }
    "--help" { Show-Help }
    "-help" { Show-Help }

    "-u" {
        Do-Update $Directory
    }

    "--update" {
        Do-Update $Directory
    }

    "-r" {
        $dateText = if ($CleanArgs.Count -ge 2) { $CleanArgs[1] } else { $null }
        Do-Restore $Directory $dateText
    }

    "--restore" {
        $dateText = if ($CleanArgs.Count -ge 2) { $CleanArgs[1] } else { $null }
        Do-Restore $Directory $dateText
    }

    "-list" {
        $dateText = if ($CleanArgs.Count -ge 2) { $CleanArgs[1] } else { $null }
        Do-List $Directory $dateText
    }

    "--list" {
        $dateText = if ($CleanArgs.Count -ge 2) { $CleanArgs[1] } else { $null }
        Do-List $Directory $dateText
    }

    "-rp" {
        $packageName = if ($CleanArgs.Count -ge 2) { $CleanArgs[1] } else { $null }
        $dateText = if ($CleanArgs.Count -ge 3) { $CleanArgs[2] } else { $null }
        Do-RestorePackage $Directory $packageName $dateText
    }

    "--restorepackage" {
        $packageName = if ($CleanArgs.Count -ge 2) { $CleanArgs[1] } else { $null }
        $dateText = if ($CleanArgs.Count -ge 3) { $CleanArgs[2] } else { $null }
        Do-RestorePackage $Directory $packageName $dateText
    }

    default {
        Show-Help
        Fail "Unknown option: $cmd"
    }
}