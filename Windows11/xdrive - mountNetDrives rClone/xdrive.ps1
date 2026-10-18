param(
    [Parameter(Position = 0)]
    [ValidateSet("mount", "unmount")]
    [string]$Action,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

# ============================================================================
# DRIVE DEFINITIONS
# ============================================================================
$Drives = [ordered]@{
    modland = 'rclone mount modland: M: --read-only --network-mode --no-console'
}

# ============================================================================
# Nothing below this line normally needs editing.
# ============================================================================
$StateDir = Join-Path $env:LOCALAPPDATA "xdrive"
$LogDir   = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "logs\rclone"
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

function Show-Usage {
    Write-Host "Usage:"
    Write-Host "  xdrive mount"
    Write-Host "  xdrive unmount"
    Write-Host "  xdrive mount modland"
    Write-Host "  xdrive unmount modland"
    Write-Host "  xdrive mount modland other1"
    Write-Host "  xdrive mount --log"
    Write-Host "  xdrive mount modland --log"
}

function Get-StateFile([string]$Name) {
    Join-Path $StateDir "$Name.pid"
}

function Get-MountSignature([string]$Name) {
    $Command = $ExecutionContext.InvokeCommand.ExpandString($Drives[$Name])
    if ($Command -match '^\s*rclone(?:\.exe)?\s+mount\s+("[^"]+"|\S+)\s+("[^"]+"|\S+)') {
        return [pscustomobject]@{
            Remote = $Matches[1].Trim('"')
            Mount  = $Matches[2].Trim('"')
        }
    }
    throw "Drive '$Name' must begin with: rclone mount <remote> <mountpoint>"
}

function Find-MountProcess([string]$Name) {
    $Sig = Get-MountSignature $Name
    $Candidate = Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match '(?i)\bmount\b' -and
            $_.CommandLine.Contains($Sig.Remote) -and
            $_.CommandLine.Contains($Sig.Mount)
        } |
        Sort-Object CreationDate -Descending |
        Select-Object -First 1

    if ($Candidate) {
        return Get-Process -Id $Candidate.ProcessId -ErrorAction SilentlyContinue
    }
    return $null
}

function Get-LiveTrackedProcess([string]$Name) {
    $StateFile = Get-StateFile $Name

    if (Test-Path $StateFile) {
        $PidText = (Get-Content $StateFile -Raw).Trim()
        if ($PidText -match '^\d+$') {
            $TrackedPid = [int]$PidText
            $Process = Get-Process -Id $TrackedPid -ErrorAction SilentlyContinue
            if ($Process) {
                $Win32 = Get-CimInstance Win32_Process -Filter "ProcessId = $TrackedPid" -ErrorAction SilentlyContinue
                $Sig = Get-MountSignature $Name
                if ($Win32 -and $Win32.Name -ieq "rclone.exe" -and $Win32.CommandLine -and
                    $Win32.CommandLine -match '(?i)\bmount\b' -and
                    $Win32.CommandLine.Contains($Sig.Remote) -and
                    $Win32.CommandLine.Contains($Sig.Mount)) {
                    return $Process
                }
            }
        }
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    }

    # Recover the real long-running rclone process if the launcher/shim PID was lost.
    $Process = Find-MountProcess $Name
    if ($Process) {
        Set-Content -Path $StateFile -Value $Process.Id -NoNewline
        return $Process
    }

    return $null
}

function Start-XDrive([string]$Name, [bool]$EnableLog) {
    if (-not $Drives.Contains($Name)) {
        Write-Error "Unknown drive '$Name'."
        return
    }

    if (Get-LiveTrackedProcess $Name) {
        Write-Host "$Name is already mounted."
        return
    }

    $Command = $ExecutionContext.InvokeCommand.ExpandString($Drives[$Name])
    if ($Command -notmatch '^\s*rclone(?:\.exe)?\s+(.+)$') {
        Write-Error "Drive '$Name' must use a command beginning with 'rclone'."
        return
    }

    $Arguments = $Matches[1]
    if ($EnableLog) {
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        $LogFile = Join-Path $LogDir "$Name.log"
        $Arguments += " --log-file `"$LogFile`""
    }

    try {
        Start-Process -FilePath "rclone.exe" -ArgumentList $Arguments -WindowStyle Hidden | Out-Null

        $Process = $null
        for ($i = 0; $i -lt 20 -and -not $Process; $i++) {
            Start-Sleep -Milliseconds 250
            $Process = Find-MountProcess $Name
        }

        if (-not $Process) {
            Write-Error "$Name failed to mount or its rclone process could not be found."
            if ($EnableLog) { Write-Host "Check log: $LogFile" }
            return
        }

        Set-Content -Path (Get-StateFile $Name) -Value $Process.Id -NoNewline
        Write-Host "$Name mounted. PID $($Process.Id)"
        if ($EnableLog) { Write-Host "Logging to: $LogFile" }
    }
    catch {
        Write-Error "Failed to mount '$Name': $($_.Exception.Message)"
    }
}

function Stop-XDrive([string]$Name) {
    if (-not $Drives.Contains($Name)) {
        Write-Error "Unknown drive '$Name'."
        return
    }

    # Only targets this configured rclone remote+mountpoint.
    # It does not touch SMB/network drives or unrelated rclone mounts.
    $Process = Get-LiveTrackedProcess $Name
    $StateFile = Get-StateFile $Name

    if (-not $Process) {
        Write-Host "$Name is not mounted."
        return
    }

    try {
        Stop-Process -Id $Process.Id -Force -ErrorAction Stop
        $Process.WaitForExit()
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        Write-Host "$Name unmounted."
    }
    catch {
        Write-Error "Failed to unmount '$Name': $($_.Exception.Message)"
    }
}

if (-not $Action) {
    Show-Usage
    exit 1
}

$EnableLog = $false
$Names = @()
foreach ($Arg in $ExtraArgs) {
    if ($Arg -eq "--log") { $EnableLog = $true }
    else { $Names += $Arg }
}

$Targets = if ($Names.Count -gt 0) { $Names } else { @($Drives.Keys) }
$HadUnknown = $false

foreach ($Name in $Targets) {
    if (-not $Drives.Contains($Name)) {
        Write-Error "Unknown drive '$Name'. Configured drives: $($Drives.Keys -join ', ')"
        $HadUnknown = $true
        continue
    }

    switch ($Action) {
        "mount"   { Start-XDrive $Name $EnableLog }
        "unmount" { Stop-XDrive $Name }
    }
}

if ($HadUnknown) { exit 1 }
