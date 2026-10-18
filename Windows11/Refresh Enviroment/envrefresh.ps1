<#
.SYNOPSIS
    Reload environment variables from Windows settings into the current shell.
    Run "envrefresh -h" for the full help screen.
#>
# ----------------------------------------------------------------------------
#  envrefresh.ps1
#
#  Reloads environment variables from the registry into the CURRENT session.
#    PowerShell : run directly ("envrefresh") -> applies to $env: in-process.
#                 A script runs in a child scope but the same process, and
#                 $env: is process-wide, so the changes stick.
#    cmd        : run via envrefresh.bat -> this script is called with
#                 -EmitCmd <file>, writes SET lines to that file, and the .bat
#                 CALLs it inside the user's cmd process.
#
#  Never changes directory and never clears history or scrollback, because
#  no new shell is started.
#
#  Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts
#  as ANSI.
# ----------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

# ============================================================================
#  Arguments
# ============================================================================
$Prune   = $false
$Quiet   = $false
$Clean   = $false
$Help    = $false
$EmitCmd = $null

for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    switch -Regex ($a) {
        '^(-|--|/)(prune|p)$'   { $Prune = $true; break }
        '^(-|--|/)(quiet|q)$'   { $Quiet = $true; break }
        '^(-|--|/)(clean|c)$'   { $Clean = $true; break }
        '^(-|--|/)(help|h|\?)$' { $Help  = $true; break }
        '^-EmitCmd$'            { $i++; $EmitCmd = [string]$args[$i]; break }
        default {
            Write-Host "envrefresh: unknown option '$a'  (try: envrefresh -h)" -ForegroundColor Red
            exit 2
        }
    }
}
$IsCmd = -not [string]::IsNullOrEmpty($EmitCmd)

# ============================================================================
#  Help (house style: coloured sections, EXAMPLES at the bottom)
# ============================================================================
function Write-Opt([string]$flag, [string]$text) {
    Write-Host ('   {0,-16}' -f $flag) -ForegroundColor Green -NoNewline
    Write-Host $text -ForegroundColor Gray
}
function Write-Ex([string]$cmd, [string]$text) {
    Write-Host ('   {0,-22}' -f $cmd) -ForegroundColor White -NoNewline
    Write-Host $text -ForegroundColor DarkGray
}

function Show-Help {
    Write-Host ''
    Write-Host ' envrefresh' -ForegroundColor Cyan -NoNewline
    Write-Host '  -  reload environment variables into the current shell' -ForegroundColor White
    Write-Host ''
    Write-Host ' USAGE' -ForegroundColor Yellow
    Write-Host '   envrefresh [options]' -ForegroundColor White
    Write-Host ''
    Write-Host ' DESCRIPTION' -ForegroundColor Yellow
    Write-Host '   Re-reads the Machine, User and Volatile environment from the registry'      -ForegroundColor Gray
    Write-Host '   and applies it to the shell you typed it in (cmd or PowerShell).'           -ForegroundColor Gray
    Write-Host '   The current directory, command history and scrollback are untouched.'       -ForegroundColor Gray
    Write-Host ''
    Write-Host '   PATH is rebuilt as Machine;User (like a fresh window), minus duplicates.'   -ForegroundColor Gray
    Write-Host '   Entries in PATH and PATHEXT that only this window added (venv, vcvars,'     -ForegroundColor Gray
    Write-Host '   pwsh adding .CPL...) are kept in place: ones that were in front stay in'    -ForegroundColor Gray
    Write-Host '   front, the rest go to the end. Empty registry values are skipped.'          -ForegroundColor Gray
    Write-Host ''
    Write-Host ' OPTIONS' -ForegroundColor Yellow
    Write-Opt '-prune, -p' 'Also remove variables that no longer exist in Windows settings.'
    Write-Opt ''           'System variables (USERNAME, APPDATA, ComSpec...) are protected.'
    Write-Opt ''           'Note: this also removes variables you SET by hand in this window.'
    Write-Opt '-clean, -c' 'Rebuild PATH and PATHEXT purely from Windows settings, dropping entries'
    Write-Opt ''           'this window added itself.'
    Write-Opt '-quiet, -q' 'No output (errors are still shown).'
    Write-Opt '-help, -h'  'Show this help.'
    Write-Host ''
    Write-Host ' OUTPUT' -ForegroundColor Yellow
    Write-Host '   + added    ~ changed    - removed     (PATH-style lists diff per entry)'    -ForegroundColor Gray
    Write-Host ''
    Write-Host ' EXAMPLES' -ForegroundColor Yellow
    Write-Ex 'envrefresh'           'pick up new/changed variables after an install'
    Write-Ex 'envrefresh -prune'    'also drop variables an uninstaller removed'
    Write-Ex 'envrefresh -clean'    'reset PATH and PATHEXT to exactly what Windows has'
    Write-Ex 'envrefresh -p -c -q'  'full reset, silently'
    Write-Host ''
}

if ($Help) { Show-Help; exit 0 }

# ============================================================================
#  Helpers
# ============================================================================
function Read-RegEnv([Microsoft.Win32.RegistryKey]$root, [string]$sub) {
    $out = [ordered]@{}
    $key = $null
    try { $key = $root.OpenSubKey($sub) } catch { $key = $null }
    if ($null -eq $key) { return $out }
    try {
        foreach ($n in $key.GetValueNames()) {
            if ([string]::IsNullOrEmpty($n)) { continue }
            $kind = $key.GetValueKind($n)
            if ($kind -ne [Microsoft.Win32.RegistryValueKind]::String -and
                $kind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString) { continue }
            $v = $key.GetValue($n, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $out[$n] = [pscustomobject]@{
                Value  = [string]$v
                Expand = ($kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString)
            }
        }
    } finally { $key.Close() }
    return $out
}

function Expand-Env([string]$s, [hashtable]$ctx) {
    if ([string]::IsNullOrEmpty($s)) { return $s }
    $eval = {
        param($m)
        $n = $m.Groups[1].Value
        if ($ctx.ContainsKey($n)) { $ctx[$n] } else { $m.Value }
    }.GetNewClosure()
    return [regex]::Replace($s, '%([^%;]+)%', [System.Text.RegularExpressions.MatchEvaluator]$eval)
}

function Get-EntryValue($entry, [hashtable]$ctx) {
    if ($entry.Expand) { return (Expand-Env $entry.Value $ctx) }
    return $entry.Value
}

function Split-List([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return @() }
    return @($s -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Get-NormPath([string]$p) {
    return $p.Trim().Trim('"').TrimEnd('\').ToLowerInvariant()
}

function Get-Dedup([object[]]$list) {
    $seen = @{}
    $out  = New-Object System.Collections.Generic.List[string]
    foreach ($p in $list) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        $n = Get-NormPath $p
        if (-not $seen.ContainsKey($n)) { $seen[$n] = 1; $out.Add($p) }
    }
    return ,$out.ToArray()
}

# Keep entries that only this window has (venv, vcvars, pwsh's .CPL...) in
# their relative position: ones in front of the first registry entry stay in
# front, the rest go to the end.
function Merge-SessionEntries([object[]]$regEntries, [string]$curValue) {
    $known = @{}
    foreach ($p in $regEntries) { $known[(Get-NormPath $p)] = 1 }
    $front = @(); $back = @(); $seenKnown = $false
    foreach ($p in (Split-List $curValue)) {
        if ($known.ContainsKey((Get-NormPath $p))) { $seenKnown = $true; continue }
        if ($seenKnown) { $back += $p } else { $front += $p }
    }
    return ,(Get-Dedup ($front + $regEntries + $back))
}

# Variables whose session-only entries are kept unless -clean is given
$SessionKeepVars = @('Path', 'PATHEXT')

# ============================================================================
#  Protected names (never removed by -prune, never touched by the generic pass)
# ============================================================================
$ProtectedNames = @{}
@(
    'ALLUSERSPROFILE','APPDATA','CommonProgramFiles','CommonProgramFiles(x86)',
    'CommonProgramFiles(Arm)','CommonProgramW6432','COMPUTERNAME','ComSpec',
    'DriverData','HOMEDRIVE','HOMEPATH','HOMESHARE','LOCALAPPDATA','LOGONSERVER',
    'NUMBER_OF_PROCESSORS','OS','PROCESSOR_ARCHITECTURE','PROCESSOR_ARCHITEW6432',
    'PROCESSOR_IDENTIFIER','PROCESSOR_LEVEL','PROCESSOR_REVISION','ProgramData',
    'ProgramFiles','ProgramFiles(x86)','ProgramFiles(Arm)','ProgramW6432','PROMPT',
    'PSModulePath','PSExecutionPolicyPreference','PUBLIC','SESSIONNAME',
    'SystemDrive','SystemRoot','USERDOMAIN','USERDOMAIN_ROAMINGPROFILE',
    'USERNAME','USERPROFILE','windir','Path','PATHEXT','TEMP','TMP',
    'CLIENTNAME','ZES_ENABLE_SYSMAN'
) | ForEach-Object { $ProtectedNames[$_] = 1 }

# Variables injected by terminals, editors, launchers or by this tool itself
$ProtectedPrefixes = @('=', '__ER_', 'WT_', 'VSCODE_', 'TERM', 'ConEmu', 'EFC_',
                       'FPS_BROWSER_', 'POWERSHELL_', 'PSReadLine')

function Test-Protected([string]$name) {
    if ($ProtectedNames.ContainsKey($name)) { return $true }
    foreach ($p in $ProtectedPrefixes) {
        if ($name.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Names handled specially, outside the generic set/expand pass
$MergeVars   = @('Path', 'LibPath', 'Os2LibPath')     # Windows concatenates Machine;User
$SpecialVars = @{ 'PSModulePath' = 1 }                 # PowerShell composes this itself
foreach ($m in $MergeVars) { $SpecialVars[$m] = 1 }

# Display-only: values diffed per ';' entry in the summary
$ListVars = @{ 'Path' = 1; 'PSModulePath' = 1; 'PATHEXT' = 1; 'LibPath' = 1; 'Os2LibPath' = 1 }

# ============================================================================
#  Main
# ============================================================================
try {
    # ---- current process environment (case-insensitive) ---------------------
    $cur = @{}
    foreach ($e in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
        $cur[[string]$e.Key] = [string]$e.Value
    }

    # ---- registry layers, in Windows' own order -----------------------------
    $HKLM = [Microsoft.Win32.Registry]::LocalMachine
    $HKCU = [Microsoft.Win32.Registry]::CurrentUser
    $sid  = [System.Diagnostics.Process]::GetCurrentProcess().SessionId

    $machine  = Read-RegEnv $HKLM 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $user     = Read-RegEnv $HKCU 'Environment'
    $volatile = Read-RegEnv $HKCU 'Volatile Environment'
    $volSess  = Read-RegEnv $HKCU ('Volatile Environment\' + $sid)
    $layers   = @($machine, $user, $volatile, $volSess)

    # ---- expansion context starts as the current environment ---------------
    $ctx = @{}
    foreach ($k in $cur.Keys) { $ctx[$k] = $cur[$k] }

    $final      = [ordered]@{}
    $finalNames = @{}

    # Empty values are skipped, as Windows does when it builds a new window's
    # environment (e.g. the empty CLIENTNAME in Volatile Environment).

    # pass 1: plain REG_SZ values (later layers override earlier ones)
    foreach ($L in $layers) {
        foreach ($n in $L.Keys) {
            if ($SpecialVars.ContainsKey($n)) { continue }
            $entry = $L[$n]
            if (-not $entry.Expand) {
                if ([string]::IsNullOrEmpty($entry.Value)) { continue }
                $ctx[$n] = $entry.Value
                $final[$n] = $entry.Value
                $finalNames[$n] = 1
            }
        }
    }
    # pass 2: REG_EXPAND_SZ values, expanded against what is built so far
    foreach ($L in $layers) {
        foreach ($n in $L.Keys) {
            if ($SpecialVars.ContainsKey($n)) { continue }
            $entry = $L[$n]
            if ($entry.Expand) {
                $v = Expand-Env $entry.Value $ctx
                if ([string]::IsNullOrEmpty($v)) { continue }
                $ctx[$n] = $v
                $final[$n] = $v
                $finalNames[$n] = 1
            }
        }
    }

    # ---- merged vars (Path, LibPath, Os2LibPath) ----------------------------
    foreach ($mv in $MergeVars) {
        $parts = @()
        foreach ($L in $layers) {
            if ($L.Contains($mv)) {
                $v = Get-EntryValue $L[$mv] $ctx
                if (-not [string]::IsNullOrEmpty($v)) { $parts += $v }
            }
        }
        if ($parts.Count -eq 0) { continue }

        $final[$mv] = ((Get-Dedup (Split-List ($parts -join ';'))) -join ';')
        $finalNames[$mv] = 1
    }

    # ---- keep session-only entries (Path, PATHEXT) --------------------------
    if (-not $Clean) {
        foreach ($kv in $SessionKeepVars) {
            if (-not $finalNames.ContainsKey($kv)) { continue }
            $merged = Merge-SessionEntries (Split-List $final[$kv]) $cur[$kv]
            $final[$kv] = ($merged -join ';')
        }
    }

    # ---- PSModulePath (PowerShell only, additive) ---------------------------
    # PowerShell builds this at startup from several sources; overwriting it
    # breaks module autoloading, so only append registry entries it lacks.
    # Skipped for cmd: the generator's own value is altered by PowerShell's
    # startup and does not reflect the cmd window.
    if (-not $IsCmd) {
        $psmReg = @()
        foreach ($L in @($machine, $user)) {
            if ($L.Contains('PSModulePath')) { $psmReg += Split-List (Get-EntryValue $L['PSModulePath'] $ctx) }
        }
        $curPsm = $cur['PSModulePath']
        $have = @{}
        foreach ($p in (Split-List $curPsm)) { $have[(Get-NormPath $p)] = 1 }
        $add = @()
        foreach ($p in (Get-Dedup $psmReg)) {
            if (-not $have.ContainsKey((Get-NormPath $p))) { $add += $p }
        }
        if ($add.Count -gt 0) {
            $base = if ([string]::IsNullOrEmpty($curPsm)) { '' } else { $curPsm.TrimEnd(';') + ';' }
            $final['PSModulePath'] = $base + ($add -join ';')
            $finalNames['PSModulePath'] = 1
        }
    }

    # ---- diff ---------------------------------------------------------------
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($n in $final.Keys) {
        if ($n.StartsWith('__ER_') -or $n -eq 'PSExecutionPolicyPreference') { continue }
        $new = [string]$final[$n]
        if (-not $cur.ContainsKey($n)) {
            $changes.Add([pscustomobject]@{ Kind = '+'; Name = $n; Old = $null; New = $new })
        } elseif ($cur[$n] -cne $new) {
            $changes.Add([pscustomobject]@{ Kind = '~'; Name = $n; Old = $cur[$n]; New = $new })
        }
    }
    if ($Prune) {
        foreach ($n in ($cur.Keys | Sort-Object)) {
            if ($finalNames.ContainsKey($n)) { continue }
            if (Test-Protected $n) { continue }
            $changes.Add([pscustomobject]@{ Kind = '-'; Name = $n; Old = $cur[$n]; New = $null })
        }
    }

    # ---- apply --------------------------------------------------------------
    if ($IsCmd) {
        # Called (not run) by envrefresh.bat inside the user's cmd process.
        # In a CALLed batch file %% becomes %. Inside set "..." the characters
        # & | < > ^ are literal. (If the window has delayed expansion enabled
        # via cmd /v:on, a "!" in a value can still be mangled; this is rare.)
        $sb = New-Object System.Text.StringBuilder
        foreach ($c in $changes) {
            if ($c.Kind -eq '-') {
                [void]$sb.AppendLine('set "' + $c.Name + '="')
            } else {
                [void]$sb.AppendLine('set "' + $c.Name + '=' + $c.New.Replace('%', '%%') + '"')
            }
        }
        $enc = $null
        try {
            $cp = [Console]::OutputEncoding.CodePage
            if ($cp -eq 65001) { $enc = New-Object System.Text.UTF8Encoding($false) }
            else               { $enc = [System.Text.Encoding]::GetEncoding($cp) }
        } catch { $enc = [System.Text.Encoding]::Default }
        [System.IO.File]::WriteAllText($EmitCmd, $sb.ToString(), $enc)
    } else {
        foreach ($c in $changes) {
            if ($c.Kind -eq '-') { [Environment]::SetEnvironmentVariable($c.Name, $null, 'Process') }
            else                 { [Environment]::SetEnvironmentVariable($c.Name, $c.New,  'Process') }
        }
    }

    # ---- summary ------------------------------------------------------------
    if (-not $Quiet) {
        $shell = if ($IsCmd) { 'cmd' } else { 'PowerShell' }
        if ($changes.Count -eq 0) {
            Write-Host 'envrefresh: ' -ForegroundColor Cyan -NoNewline
            Write-Host "environment already up to date ($shell)" -ForegroundColor Gray
        } else {
            $word = if ($changes.Count -eq 1) { 'change' } else { 'changes' }
            Write-Host 'envrefresh: ' -ForegroundColor Cyan -NoNewline
            Write-Host "$($changes.Count) $word applied ($shell)" -ForegroundColor White
            foreach ($c in $changes) {
                switch ($c.Kind) {
                    '+' {
                        Write-Host '  + ' -ForegroundColor Green -NoNewline
                        Write-Host $c.Name -ForegroundColor White -NoNewline
                        Write-Host (' = ' + $c.New) -ForegroundColor Gray
                    }
                    '-' {
                        Write-Host '  - ' -ForegroundColor Red -NoNewline
                        Write-Host $c.Name -ForegroundColor White -NoNewline
                        Write-Host '  (removed)' -ForegroundColor DarkGray
                    }
                    '~' {
                        Write-Host '  ~ ' -ForegroundColor Yellow -NoNewline
                        Write-Host $c.Name -ForegroundColor White
                        if ($ListVars.ContainsKey($c.Name)) {
                            $oldL = Split-List $c.Old; $newL = Split-List $c.New
                            $oldN = @{}; foreach ($p in $oldL) { $oldN[(Get-NormPath $p)] = 1 }
                            $newN = @{}; foreach ($p in $newL) { $newN[(Get-NormPath $p)] = 1 }
                            $any = $false
                            foreach ($p in $newL) {
                                if (-not $oldN.ContainsKey((Get-NormPath $p))) {
                                    Write-Host ('      + ' + $p) -ForegroundColor Green; $any = $true
                                }
                            }
                            foreach ($p in $oldL) {
                                if (-not $newN.ContainsKey((Get-NormPath $p))) {
                                    Write-Host ('      - ' + $p) -ForegroundColor Red; $any = $true
                                }
                            }
                            # Explain what else happened besides +/- entries
                            $oldUnique = Get-Dedup $oldL
                            $dupes = $oldL.Count - $oldUnique.Count
                            if ($dupes -gt 0) {
                                $w = if ($dupes -eq 1) { 'entry' } else { 'entries' }
                                Write-Host "      ($dupes duplicate $w removed)" -ForegroundColor DarkGray
                                $any = $true
                            }
                            $oldSeq = ($oldUnique | ForEach-Object { Get-NormPath $_ }) -join ';'
                            $newSeq = ($newL      | ForEach-Object { Get-NormPath $_ }) -join ';'
                            if ($oldSeq -ne $newSeq -and $oldUnique.Count -eq $newL.Count -and
                                -not ($newL | Where-Object { -not $oldN.ContainsKey((Get-NormPath $_)) })) {
                                Write-Host '      (order changed)' -ForegroundColor DarkGray
                                $any = $true
                            }
                            if (-not $any) { Write-Host '      (formatting only: case, quotes, spaces or trailing \)' -ForegroundColor DarkGray }
                        } else {
                            Write-Host ('      old: ' + $c.Old) -ForegroundColor DarkGray
                            Write-Host ('      new: ' + $c.New) -ForegroundColor Gray
                        }
                    }
                }
            }
        }
    }
    exit 0
}
catch {
    Write-Host ('envrefresh: failed - ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'envrefresh: nothing was changed.' -ForegroundColor Red
    if ($IsCmd -and (Test-Path -LiteralPath $EmitCmd)) { Remove-Item -LiteralPath $EmitCmd -Force -ErrorAction SilentlyContinue }
    exit 1
}
