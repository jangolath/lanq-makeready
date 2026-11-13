<#
.SYNOPSIS
  lanq-makeready-fix: applies a short list of reversible fixes for what lanq-makeready reports, one at a time, each only
  after you confirm it at this PC.
.DESCRIPTION
  The scanner (lanq-makeready.ps1) never changes anything. This separate script changes only what you confirm:
  - it refuses to run over SSH, from stdin or a string ([scriptblock]::Create, iex), or without an interactive console
    (-WhatIf and -List need no console);
  - there is no -Yes or -Force: each fix is shown (check, current state, exact command, undo) and asked with
    "Apply? [y/N]"; anything but y or yes is no;
  - it never elevates itself: without an elevated prompt every fix is skipped with a note;
  - before each change it writes the undo record %LOCALAPPDATA%\lanq-makeready\fix-<UTC time>.json (schema
    lanq-makeready-fix/v1), and -Undo <file> puts the changes back, newest first, again confirming each.
  Fixes (v1): ssh.start, ssh.auto, power.sleep, longpaths.on, git.longpaths, ssh.aclkeys.
  Exit code: 0 = done or nothing to do, 1 = a change failed or did not verify, 2 = bad arguments or a rejected record,
  3 = refused (over SSH, from stdin, no interactive console).
.PARAMETER WhatIf
  Dry run: show every applicable fix and its undo; change nothing.
.PARAMETER Undo
  Undo the changes in this record file, newest first, confirming each.
.PARAMETER List
  List the undo records in %LOCALAPPDATA%\lanq-makeready.
#>
# lanq-makeready-fix-marker (identifies this file; the script refuses to run when it was not started from a file)
[CmdletBinding(PositionalBinding = $false)]
param([switch]$WhatIf, [string]$Undo, [switch]$List, [switch]$Help, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra)

$FixInvocation = $MyInvocation
$ToolVersion = '0.4.0'
$RecordSchema = 'lanq-makeready-fix/v1'
$FixIds = @('ssh.start', 'ssh.auto', 'power.sleep', 'longpaths.on', 'git.longpaths', 'ssh.aclkeys')
# check id in the scanner's report, and what is wrong
$FixInfo = @{
  'ssh.start'     = @('ssh.server', 'OpenSSH Server is installed but not running')
  'ssh.auto'      = @('ssh.server', 'sshd does not start by itself after a reboot')
  'power.sleep'   = @('power.sleep', 'the PC sleeps or hibernates on AC power')
  'longpaths.on'  = @('longpaths', 'Windows long paths are off')
  'git.longpaths' = @('git', 'git core.longpaths is not on')
  'ssh.aclkeys'   = @('ssh.keys', 'administrators_authorized_keys may be changed by others than Administrators and SYSTEM, so sshd ignores it')
}
# The things the fixes touch. Fixed names, never taken from a record file.
$SshdName = 'sshd'
$FsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
$SysDir = [Environment]::GetFolderPath('System')
$PowercfgExe = Join-Path $SysDir 'powercfg.exe'
$IcaclsExe = Join-Path $SysDir 'icacls.exe'
$KeysFile = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ssh\administrators_authorized_keys'
$FixOut = New-Object System.Collections.ArrayList

# ---------- output ----------

function Write-FixLine([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) {
  [void]$FixOut.Add($Text)
  if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline } else { Write-Host $Text -ForegroundColor $Color }
}
function Write-FixErr([string]$Text) { [void]$FixOut.Add($Text); [Console]::Error.WriteLine($Text) }

# ---------- local only (test seams: Test-FixConsole and Read-FixAnswer) ----------
# Tests and the disposable-machine CI driver dot-source this file (LANQ_MAKEREADY_FIX_LIB=1) and replace
# Test-FixConsole/Read-FixAnswer with fakes. That needs code already running in this PowerShell, which could change the PC
# directly anyway, so the seam widens nothing. A direct run with LANQ_MAKEREADY_FIX_LIB=1 still applies every refusal
# and then exits 2. Over SSH and from stdin are checked in Invoke-FixMain too, so a driver cannot skip them.

function Test-FixOverSsh {
  if ($env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:SSH_TTY) { return $true }
  try {   # an elevated or runas child may lose the variables: look for sshd among the parent processes
    $p = $PID
    for ($i = 0; $i -lt 32 -and $p -gt 0; $i++) {
      $pr = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$p" -ErrorAction Stop)
      if ($pr.Count -eq 0) { break }
      if ("$($pr[0].Name)" -match '^sshd') { return $true }
      $q = [int]$pr[0].ParentProcessId; if ($q -eq $p) { break }; $p = $q
    }
  } catch { }
  return $false
}

function Test-FixFromFile($Inv) {
  try { return [bool]($Inv.MyCommand.CommandType -eq 'ExternalScript' -and $Inv.MyCommand.Path -and ("$($Inv.MyCommand.ScriptContents)" -match 'lanq-makeready-fix-marker')) }
  catch { return $false }
}

function Test-FixConsole {
  try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) } catch { return $false }
}

function Read-FixAnswer { return [Console]::ReadLine() }

function Test-Yes($Answer) { return ("$Answer".Trim() -match '^(?i)(y|yes)$') }

function Confirm-Fix {
  Write-FixLine '  Apply? [y/N] ' 'White' -NoNewline
  $a = Read-FixAnswer
  Write-Host ''
  return (Test-Yes $a)
}

function Test-FixElevated {
  try { return (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
  catch { return $false }
}

# '' when the script may run in this mode, else the reason it refuses.
function Get-FixRefusal([string]$Mode, [bool]$FromFile) {
  if (Test-FixOverSsh) { return 'refused: this session runs over SSH (SSH_CONNECTION, SSH_CLIENT or SSH_TTY is set, or sshd started it). Fix mode is for the owner at the PC itself. Nothing was changed.' }
  if (-not $FromFile) { return 'refused: the script came from stdin or a string ([scriptblock]::Create, iex). Save it as a file, read it, and run that file at the PC. Nothing was changed.' }
  if (@('apply', 'undo') -contains $Mode -and -not (Test-FixConsole)) { return 'refused: no interactive console (stdin is redirected or the session is not interactive). Every change needs your answer at the keyboard; -WhatIf and -List work without one. Nothing was changed.' }
  return ''
}

# ---------- state (reads only) ----------

# Runs an exe with fixed arguments, stdin closed, from %SystemRoot%; @{ Code; Out }. Reads here; changes only in FIXES.
function Invoke-Native([string]$Exe, [string[]]$ArgList, [int]$Sec = 60) {
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $env:SystemRoot
    $psi.Arguments = (@($ArgList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($Sec * 1000)) { try { $p.Kill() } catch { }; return @{ Code = -1; Out = 'timed out' } }
    [void]$o.Wait(2000); [void]$e.Wait(2000)
    return @{ Code = $p.ExitCode; Out = ("$($o.Result)`n$($e.Result)").Trim() }
  } catch { return @{ Code = -1; Out = "$($_.Exception.Message)" } }
}

# Seconds from `powercfg /q` text (AC value); $null when not found (same parser as the scanner, localized output too).
function Get-PowercfgAcSeconds([string]$Text) {
  if ($Text -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') { return [Convert]::ToInt64($Matches[1], 16) }
  $hex = @([regex]::Matches($Text, '0x([0-9a-fA-F]{8})\s*(?:\r?\n|$)'))
  if ($hex.Count -lt 2) { return $null }
  return [Convert]::ToInt64($hex[$hex.Count - 2].Groups[1].Value, 16)
}

function Find-Git {
  $g = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($g -and $g.Source -notmatch '\\WindowsApps\\') { return $g.Source }
  return $null
}

function Test-OnlyAdminsSystem([string]$Dacl) {   # every ACE is for Administrators (BA) or SYSTEM (SY)
  foreach ($m in [regex]::Matches($Dacl, '\(([^)]*)\)')) {
    $sid = $m.Groups[1].Value.Split(';')[5]
    if (@('BA', 'SY', 'S-1-5-32-544', 'S-1-5-18') -notcontains $sid) { return $false }
  }
  return $true
}

# The current state of what one fix touches, as a hashtable.
function Get-FixState([string]$Id) {
  switch ($Id) {
    { @('ssh.start', 'ssh.auto') -contains $_ } {
      $svc = Get-Service -Name $SshdName -ErrorAction SilentlyContinue
      if (-not $svc) { return @{ Installed = $false } }
      return @{ Installed = $true; Status = "$($svc.Status)"; StartType = "$($svc.StartType)" }
    }
    'power.sleep' {
      $s = @{ Standby = $null; Hibernate = $null }
      $r = Invoke-Native $PowercfgExe @('/q', 'SCHEME_CURRENT', 'SUB_SLEEP', 'STANDBYIDLE'); if ($r.Code -eq 0) { $s.Standby = Get-PowercfgAcSeconds $r.Out }
      $r = Invoke-Native $PowercfgExe @('/q', 'SCHEME_CURRENT', 'SUB_SLEEP', 'HIBERNATEIDLE'); if ($r.Code -eq 0) { $s.Hibernate = Get-PowercfgAcSeconds $r.Out }
      return $s
    }
    'longpaths.on' {
      $v = $null
      try { $v = [long](Get-ItemProperty -Path $FsKey -Name LongPathsEnabled -ErrorAction Stop).LongPathsEnabled } catch { }
      return @{ Value = $v }
    }
    'git.longpaths' {
      $git = Find-Git
      if (-not $git) { return @{ Git = $null } }
      $s = @{ Git = $git; System = $null; Effective = $null }
      $r = Invoke-Native $git @('config', '--system', '--get', 'core.longpaths'); if ($r.Code -eq 0) { $s.System = "$($r.Out)".Trim() }
      $r = Invoke-Native $git @('config', '--get', 'core.longpaths'); if ($r.Code -eq 0) { $s.Effective = "$($r.Out)".Trim() }
      return $s
    }
    'ssh.aclkeys' {
      if (-not (Test-Path -LiteralPath $KeysFile -PathType Leaf)) { return @{ Exists = $false } }
      $s = @{ Exists = $true; Reparse = $true; Dacl = $null; Ok = $null }
      try {
        $it = Get-Item -LiteralPath $KeysFile -Force -ErrorAction Stop
        $s.Reparse = [bool]($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        $s.Dacl = (Get-Acl -LiteralPath $KeysFile -ErrorAction Stop).GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
        $s.Ok = Test-OnlyAdminsSystem $s.Dacl
      } catch { }
      return $s
    }
  }
  return @{}
}

# ---------- state text: the only form stored in a record (fixed shapes; anything else is rejected) ----------

$DaclRe = 'D:[A-Z]{0,8}(\((A|D);[A-Z]{0,16};(0x[0-9a-fA-F]{1,8}|[A-Z]{2,24});;;([A-Z]{2}|S-1(-[0-9]{1,10}){1,14})\)){0,64}'

# Parses a state text for a fix id into a hashtable; $null when it is not exactly one of the allowed shapes.
function ConvertFrom-StateText([string]$Id, [string]$Text) {
  if ($Text.Length -gt 4096) { return $null }
  switch ($Id) {
    { @('ssh.start', 'ssh.auto') -contains $_ } {
      if ($Text -cmatch '^starttype=(Automatic|Manual|Disabled) status=(Running|Stopped)$') { return @{ Installed = $true; StartType = $Matches[1]; Status = $Matches[2] } }
      return $null
    }
    'power.sleep' {
      if ($Text -cmatch '^standby=([0-9]{1,10}) hibernate=([0-9]{1,10}|-)$') {
        $sb = [long]$Matches[1]; $hb = $null; if ($Matches[2] -ne '-') { $hb = [long]$Matches[2] }
        if ($sb -gt 4294967295 -or $hb -gt 4294967295) { return $null }
        return @{ Standby = $sb; Hibernate = $hb }
      }
      return $null
    }
    'longpaths.on' {
      if ($Text -cmatch '^value=([0-9]{1,10}|-)$') { $v = $null; if ($Matches[1] -ne '-') { $v = [long]$Matches[1] }; if ($v -gt 4294967295) { return $null }; return @{ Value = $v } }
      return $null
    }
    'git.longpaths' {
      if ($Text -cmatch '^value=([A-Za-z0-9]{1,16}|-)$') { $v = $null; if ($Matches[1] -ne '-') { $v = $Matches[1] }; return @{ System = $v } }
      return $null
    }
    'ssh.aclkeys' {
      if ($Text -cmatch "^dacl=($DaclRe)$") { return @{ Exists = $true; Reparse = $false; Dacl = $Matches[1] } }
      return $null
    }
  }
  return $null
}

# The state as text, or $null when it cannot be recorded in an allowed shape (then the fix is not offered).
function Get-StateText([string]$Id, $S) {
  $t = $null
  switch ($Id) {
    { @('ssh.start', 'ssh.auto') -contains $_ } { if ($S.Installed) { $t = "starttype=$($S.StartType) status=$($S.Status)" } }
    'power.sleep' { if ($null -ne $S.Standby) { $h = '-'; if ($null -ne $S.Hibernate) { $h = "$($S.Hibernate)" }; $t = "standby=$($S.Standby) hibernate=$h" } }
    'longpaths.on' { $v = '-'; if ($null -ne $S.Value) { $v = "$($S.Value)" }; $t = "value=$v" }
    'git.longpaths' { if ($S.Git) { $v = '-'; if ($null -ne $S.System) { $v = "$($S.System)" }; $t = "value=$v" } }
    'ssh.aclkeys' { if ($S.Exists -and -not $S.Reparse -and $S.Dacl) { $t = "dacl=$($S.Dacl)" } }
  }
  if ($null -eq $t -or $null -eq (ConvertFrom-StateText $Id $t)) { return $null }
  return $t
}

function Test-FixNeeded([string]$Id, $S) {
  if (-not (Get-StateText $Id $S)) { return $false }
  switch ($Id) {
    'ssh.start' { return ($S.Status -eq 'Stopped') }
    'ssh.auto' { return ($S.Status -eq 'Running' -and @('Manual', 'Disabled') -contains $S.StartType) }
    'power.sleep' { return ($S.Standby -gt 0 -or ($null -ne $S.Hibernate -and $S.Hibernate -gt 0)) }
    'longpaths.on' { return ($S.Value -ne 1) }
    'git.longpaths' { return ("$($S.Effective)" -notmatch '^(?i)true$') }
    'ssh.aclkeys' { return ($S.Ok -eq $false) }
  }
  return $false
}

function Test-FixDone([string]$Id, $S) {
  switch ($Id) {
    'ssh.start' { return ($S.Status -eq 'Running' -and $S.StartType -eq 'Automatic') }
    'ssh.auto' { return ($S.StartType -eq 'Automatic') }
    'power.sleep' { return ($S.Standby -eq 0 -and ($null -eq $S.Hibernate -or $S.Hibernate -eq 0)) }
    'longpaths.on' { return ($S.Value -eq 1) }
    'git.longpaths' { return ("$($S.System)" -match '^(?i)true$') }
    'ssh.aclkeys' { return ($S.Ok -eq $true) }
  }
  return $false
}

# What the state should be right after the change ('unknown' when it cannot be predicted).
function Get-ExpectedAfter([string]$Id, $S) {
  switch ($Id) {
    'ssh.start' { return 'starttype=Automatic status=Running' }
    'ssh.auto' { return "starttype=Automatic status=$($S.Status)" }
    'power.sleep' { $h = '-'; if ($null -ne $S.Hibernate) { $h = '0' }; return "standby=0 hibernate=$h" }
    'longpaths.on' { return 'value=1' }
    'git.longpaths' { return 'value=true' }
  }
  return 'unknown'
}

function Get-StateSummary([string]$Id, $S) {
  switch ($Id) {
    { @('ssh.start', 'ssh.auto') -contains $_ } { return "sshd is $($S.Status), start type $($S.StartType)" }
    'power.sleep' { $h = 'unreadable'; if ($null -ne $S.Hibernate) { $h = "$([math]::Round($S.Hibernate / 60)) min" }; return "sleeps after $([math]::Round($S.Standby / 60)) min, hibernates after $h (0 = never)" }
    'longpaths.on' { if ($null -eq $S.Value) { return 'LongPathsEnabled is not set (off)' }; return "LongPathsEnabled = $($S.Value)" }
    'git.longpaths' { $v = 'not set'; if ($null -ne $S.System) { $v = $S.System }; $e = 'not set'; if ($S.Effective) { $e = $S.Effective }; return "core.longpaths in the system config: $v; in effect for you: $e" }
    'ssh.aclkeys' { return "$KeysFile has the DACL $($S.Dacl)" }
  }
  return ''
}

#region FIXES
# The ONE place that changes this PC, keyed by fix id. Get-FixCommand is the exact text shown for each change;
# Invoke-FixChange makes it. $B is the before state (fresh, or parsed from a validated record), $Cur the current state.
# Undo commands are built from the fix id and $B only; nothing in a record is ever run as code.
function Get-FixCommand([string]$Id, [string]$Mode, $B) {
  $cmd = @()
  switch ("$Id|$Mode") {
    'ssh.start|apply' { $cmd = @("Set-Service -Name $SshdName -StartupType Automatic", "Start-Service -Name $SshdName") }
    'ssh.start|undo' { $cmd = @("Set-Service -Name $SshdName -StartupType $($B.StartType)"); if ($B.Status -eq 'Stopped') { $cmd += "Stop-Service -Name $SshdName" } }
    'ssh.auto|apply' { $cmd = @("Set-Service -Name $SshdName -StartupType Automatic") }
    'ssh.auto|undo' { $cmd = @("Set-Service -Name $SshdName -StartupType $($B.StartType)") }
    'power.sleep|apply' { if ($B.Standby -gt 0) { $cmd += 'powercfg /change standby-timeout-ac 0' }; if ($B.Hibernate -gt 0) { $cmd += 'powercfg /change hibernate-timeout-ac 0' } }
    'power.sleep|undo' { $cmd = @("powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE $($B.Standby)"); if ($null -ne $B.Hibernate) { $cmd += "powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE $($B.Hibernate)" }; $cmd += 'powercfg /setactive SCHEME_CURRENT' }
    'longpaths.on|apply' { $cmd = @("Set-ItemProperty -Path $FsKey -Name LongPathsEnabled -Value 1 -Type DWord") }
    'longpaths.on|undo' { if ($null -eq $B.Value) { $cmd = @("Remove-ItemProperty -Path $FsKey -Name LongPathsEnabled") } else { $cmd = @("Set-ItemProperty -Path $FsKey -Name LongPathsEnabled -Value $($B.Value) -Type DWord") } }
    'git.longpaths|apply' { $cmd = @('git config --system core.longpaths true') }
    'git.longpaths|undo' { if ($null -eq $B.System) { $cmd = @('git config --system --unset core.longpaths') } else { $cmd = @("git config --system core.longpaths $($B.System)") } }
    'ssh.aclkeys|apply' { $cmd = @("icacls.exe `"$KeysFile`" /inheritance:r /grant *S-1-5-32-544:F /grant *S-1-5-18:F") }
    'ssh.aclkeys|undo' { $cmd = @("`$a = Get-Acl -LiteralPath '$KeysFile'; `$a.SetSecurityDescriptorSddlForm('$($B.Dacl)', 'Access'); Set-Acl -LiteralPath '$KeysFile' -AclObject `$a") }
  }
  return $cmd
}

function Assert-Native($R) { if ($R.Code -ne 0) { throw "exit code $($R.Code): $($R.Out)" } }

function Invoke-FixChange([string]$Id, [string]$Mode, $B, $Cur) {
  switch ("$Id|$Mode") {
    'ssh.start|apply' { Set-Service -Name $SshdName -StartupType Automatic -ErrorAction Stop; Start-Service -Name $SshdName -ErrorAction Stop }
    'ssh.start|undo' { Set-Service -Name $SshdName -StartupType $B.StartType -ErrorAction Stop; if ($B.Status -eq 'Stopped') { Stop-Service -Name $SshdName -ErrorAction Stop } }
    'ssh.auto|apply' { Set-Service -Name $SshdName -StartupType Automatic -ErrorAction Stop }
    'ssh.auto|undo' { Set-Service -Name $SshdName -StartupType $B.StartType -ErrorAction Stop }
    'power.sleep|apply' {
      if ($B.Standby -gt 0) { Assert-Native (Invoke-Native $PowercfgExe @('/change', 'standby-timeout-ac', '0')) }
      if ($B.Hibernate -gt 0) { Assert-Native (Invoke-Native $PowercfgExe @('/change', 'hibernate-timeout-ac', '0')) }
    }
    'power.sleep|undo' {
      Assert-Native (Invoke-Native $PowercfgExe @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'STANDBYIDLE', "$([long]$B.Standby)"))
      if ($null -ne $B.Hibernate) { Assert-Native (Invoke-Native $PowercfgExe @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'HIBERNATEIDLE', "$([long]$B.Hibernate)")) }
      Assert-Native (Invoke-Native $PowercfgExe @('/setactive', 'SCHEME_CURRENT'))
    }
    'longpaths.on|apply' { Set-ItemProperty -Path $FsKey -Name LongPathsEnabled -Value 1 -Type DWord -ErrorAction Stop }
    'longpaths.on|undo' {
      if ($null -eq $B.Value) { Remove-ItemProperty -Path $FsKey -Name LongPathsEnabled -ErrorAction Stop }
      else { Set-ItemProperty -Path $FsKey -Name LongPathsEnabled -Value ([long]$B.Value) -Type DWord -ErrorAction Stop }
    }
    'git.longpaths|apply' { Assert-Native (Invoke-Native $Cur.Git @('config', '--system', 'core.longpaths', 'true')) }
    'git.longpaths|undo' {
      if ($null -eq $B.System) { Assert-Native (Invoke-Native $Cur.Git @('config', '--system', '--unset', 'core.longpaths')) }
      else { Assert-Native (Invoke-Native $Cur.Git @('config', '--system', 'core.longpaths', "$($B.System)")) }
    }
    'ssh.aclkeys|apply' { Assert-Native (Invoke-Native $IcaclsExe @($KeysFile, '/inheritance:r', '/grant', '*S-1-5-32-544:F', '/grant', '*S-1-5-18:F')) }
    'ssh.aclkeys|undo' {
      $a = Get-Acl -LiteralPath $KeysFile -ErrorAction Stop
      $a.SetSecurityDescriptorSddlForm($B.Dacl, [System.Security.AccessControl.AccessControlSections]::Access)
      Set-Acl -LiteralPath $KeysFile -AclObject $a -ErrorAction Stop
    }
    default { throw "no fix $Id ($Mode)" }
  }
}
#endregion FIXES

# ---------- undo record (the only file this script writes) ----------

function Get-FixRecordDir { return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'lanq-makeready') }
function Get-UtcStamp { return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
function Get-SafeWord([string]$S) { return ($S -replace '[^A-Za-z0-9._-]', '_') }

function New-FixRecord {
  $dir = Get-FixRecordDir
  $base = 'fix-' + [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture)
  $path = Join-Path $dir "$base.json"; $n = 2
  while (Test-Path -LiteralPath $path) { $path = Join-Path $dir "$base-$n.json"; $n++ }
  return @{ Path = $path; Version = $ToolVersion; Host = (Get-SafeWord $env:COMPUTERNAME); User = (Get-SafeWord $env:USERNAME); Started = (Get-UtcStamp); Items = (New-Object System.Collections.ArrayList) }
}

function ConvertTo-JsonText([string]$S) { return '"' + ($S -replace '[^\x20-\x7E]', '?').Replace('\', '\\').Replace('"', '\"') + '"' }

# Fixed layout, one item per line (the sh script parses this same layout line by line).
function ConvertTo-FixJson($Rec) {
  $l = @('{', "  `"schema`": `"$RecordSchema`",", "  `"tool`": {`"name`": `"lanq-makeready-fix`", `"version`": $(ConvertTo-JsonText $Rec.Version)},", '  "os": "windows",',
    "  `"host`": $(ConvertTo-JsonText $Rec.Host),", "  `"user`": $(ConvertTo-JsonText $Rec.User),", "  `"started`": $(ConvertTo-JsonText $Rec.Started),", '  "items": [')
  $n = $Rec.Items.Count; $i = 0
  foreach ($it in $Rec.Items) {
    $i++; $sep = ','; if ($i -eq $n) { $sep = '' }
    $l += ('    {"seq": ' + [int]$it.seq + ', "id": ' + (ConvertTo-JsonText $it.id) + ', "status": ' + (ConvertTo-JsonText $it.status) + ', "time": ' + (ConvertTo-JsonText $it.time) +
      ', "before": ' + (ConvertTo-JsonText $it.before) + ', "command": ' + (ConvertTo-JsonText $it.command) + ', "after": ' + (ConvertTo-JsonText $it.after) + '}' + $sep)
  }
  $l += @('  ]', '}')
  return (($l -join "`n") + "`n")
}

# Written to a temp file next to the record, then moved over it, so a crash leaves the old or the new record whole.
function Save-FixRecord($Rec) {
  try {
    $dir = Split-Path -Parent $Rec.Path
    [void][System.IO.Directory]::CreateDirectory($dir)
    $tmp = $Rec.Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, (ConvertTo-FixJson $Rec), (New-Object System.Text.UTF8Encoding($false)))
    if ([System.IO.File]::Exists($Rec.Path)) { [System.IO.File]::Replace($tmp, $Rec.Path, [NullString]::Value) } else { [System.IO.File]::Move($tmp, $Rec.Path) }
    return $true
  } catch { Write-FixErr "lanq-makeready-fix: could not write the record $($Rec.Path): $($_.Exception.Message)"; return $false }
}

function Test-Props($Obj, [string[]]$Names) {
  if ($Obj -isnot [System.Management.Automation.PSCustomObject]) { return $false }
  return ((@($Obj.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object) -join ',') -ceq (@($Names | Sort-Object) -join ','))
}
function Test-Str($V, [string]$Re) { return ($V -is [string] -and $V -cmatch $Re) }
# PowerShell 7 ConvertFrom-Json turns ISO times into [datetime]; give them back as the UTC text they were written as.
function ConvertTo-TimeText($V) { if ($V -is [datetime]) { return $V.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }; return $V }

function New-RecordError([string]$Why) { return @{ Rec = $null; Error = $Why } }

# Reads and validates a record. @{ Rec = ...; Error = '' }. Every field must have its fixed shape; nothing is executed.
function Read-FixRecord([string]$Path) {
  try {
    if (-not [System.IO.File]::Exists($Path)) { return (New-RecordError 'no such file') }
    if ((New-Object System.IO.FileInfo($Path)).Length -gt 262144) { return (New-RecordError 'larger than 256 KB') }
    $txt = [System.IO.File]::ReadAllText($Path)
  } catch { return (New-RecordError "cannot read it: $($_.Exception.Message)") }
  if ($txt -cmatch '[^\x09\x0A\x0D\x20-\x7E]') { return (New-RecordError 'not plain ASCII') }
  try { $j = $txt | ConvertFrom-Json } catch { return (New-RecordError 'not JSON') }
  if (-not (Test-Props $j @('schema', 'tool', 'os', 'host', 'user', 'started', 'items'))) { return (New-RecordError 'unexpected or missing top-level fields') }
  if ($j.schema -cne $RecordSchema) { return (New-RecordError "schema is not $RecordSchema") }
  if (-not (Test-Props $j.tool @('name', 'version')) -or $j.tool.name -cne 'lanq-makeready-fix' -or -not (Test-Str $j.tool.version '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$')) { return (New-RecordError 'bad tool field') }
  if ($j.os -cne 'windows') { return (New-RecordError 'not a Windows record') }
  if (-not (Test-Str $j.host '^[A-Za-z0-9._-]{0,64}$') -or -not (Test-Str $j.user '^[A-Za-z0-9._-]{0,64}$')) { return (New-RecordError 'bad host or user') }
  $timeRe = '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  $started = ConvertTo-TimeText $j.started
  if (-not (Test-Str $started $timeRe)) { return (New-RecordError 'bad started time') }
  if ($j.items -isnot [System.Array] -and $null -ne $j.items) { return (New-RecordError 'items is not a list') }
  $items = @($j.items)
  if ($items.Count -gt 64) { return (New-RecordError 'too many items') }
  $rec = @{ Path = $Path; Version = $j.tool.version; Host = $j.host; User = $j.user; Started = $started; Items = (New-Object System.Collections.ArrayList) }
  $seen = @{}
  foreach ($it in $items) {
    if (-not (Test-Props $it @('seq', 'id', 'status', 'time', 'before', 'command', 'after'))) { return (New-RecordError 'an item has unexpected or missing fields') }
    if (-not ($it.seq -is [int] -or $it.seq -is [long]) -or $it.seq -lt 1 -or $it.seq -gt 999 -or $seen.ContainsKey("$($it.seq)")) { return (New-RecordError 'bad or repeated seq') }
    $seen["$($it.seq)"] = 1
    if (-not ($it.id -is [string] -and $FixIds -ccontains $it.id)) { return (New-RecordError 'unknown fix id') }
    if (-not (Test-Str $it.status '^(pending|applied|failed|undone|skipped)$')) { return (New-RecordError 'bad status') }
    $tm = ConvertTo-TimeText $it.time
    if (-not (Test-Str $tm $timeRe)) { return (New-RecordError 'bad time') }
    if (-not (Test-Str $it.command '^[\x20-\x7E]{0,1024}$')) { return (New-RecordError 'bad command text') }
    if (-not ($it.before -is [string]) -or $null -eq (ConvertFrom-StateText $it.id $it.before)) { return (New-RecordError "before state of $($it.id) has an unexpected shape") }
    if (-not ($it.after -is [string]) -or ($it.after -cne 'unknown' -and $null -eq (ConvertFrom-StateText $it.id $it.after))) { return (New-RecordError "after state of $($it.id) has an unexpected shape") }
    [void]$rec.Items.Add([ordered]@{ seq = [int]$it.seq; id = $it.id; status = $it.status; time = $tm; before = $it.before; command = $it.command; after = $it.after })
  }
  return @{ Rec = $rec; Error = '' }
}

# ---------- modes ----------

function Show-Fix([string]$Id, $S, $Elevated) {
  Write-FixLine ''
  Write-FixLine "$Id  (check $($FixInfo[$Id][0])): $($FixInfo[$Id][1])" 'Yellow'
  Write-FixLine "  now:     $(Get-StateSummary $Id $S)"
  foreach ($c in (Get-FixCommand $Id 'apply' $S)) { Write-FixLine "  command: $c" 'Cyan' }
  foreach ($c in (Get-FixCommand $Id 'undo' $S)) { Write-FixLine "  undo:    $c" }
}

function Invoke-FixApply([bool]$Dry) {
  $elev = Test-FixElevated
  if ($Dry) { Write-FixLine "lanq-makeready-fix $ToolVersion dry run: shows each applicable fix and its undo; nothing is changed" }
  else { Write-FixLine "lanq-makeready-fix ${ToolVersion}: changes only what you confirm, one fix at a time (default no)" }
  $rec = $null; $failed = 0; $shown = 0
  foreach ($id in $FixIds) {
    $s = Get-FixState $id
    if (-not (Test-FixNeeded $id $s)) { continue }
    $shown++
    Show-Fix $id $s $elev
    if (-not $elev) { Write-FixLine '  skipped: needs an elevated PowerShell (Run as administrator); this script never elevates itself' 'DarkYellow'; continue }
    if ($Dry) { Write-FixLine '  dry run: not applied'; continue }
    if (-not (Confirm-Fix)) { Write-FixLine '  not applied'; continue }
    $s2 = Get-FixState $id   # the precondition, re-read just before the change
    if (-not (Test-FixNeeded $id $s2)) { Write-FixLine '  no longer needed (the state changed); nothing done'; continue }
    $before = Get-StateText $id $s2
    if ($before -cne (Get-StateText $id $s)) { Write-FixLine '  the state changed since it was shown; nothing done (run the script again)' 'DarkYellow'; continue }
    if (-not $rec) { $rec = New-FixRecord }
    $item = [ordered]@{ seq = ($rec.Items.Count + 1); id = $id; status = 'pending'; time = (Get-UtcStamp); before = $before; command = ((Get-FixCommand $id 'apply' $s2) -join ' ; '); after = (Get-ExpectedAfter $id $s2) }
    [void]$rec.Items.Add($item)
    if (-not (Save-FixRecord $rec)) { Write-FixErr '  nothing changed: the undo record could not be written'; $rec.Items.RemoveAt($rec.Items.Count - 1); return 1 }
    $err = ''
    try { Invoke-FixChange $id 'apply' $s2 $s2 } catch { $err = "$($_.Exception.Message)" }
    $s3 = Get-FixState $id
    $after = Get-StateText $id $s3; if (-not $after) { $after = 'unknown' }
    $item.after = $after; $item.time = Get-UtcStamp
    if (-not $err -and (Test-FixDone $id $s3)) { $item.status = 'applied'; Write-FixLine '  applied and verified' 'Green' }
    else { $item.status = 'failed'; $failed++; Write-FixLine "  FAILED: $err (now: $(Get-StateSummary $id $s3)); recorded, so -Undo can put back what changed" 'Red' }
    [void](Save-FixRecord $rec)
    if ($id -eq 'longpaths.on' -and $item.status -eq 'applied') { Write-FixLine '  note: programs started from now on see it; reboot so that every program does' }
    if ($id -eq 'git.longpaths' -and "$($s3.Effective)" -notmatch '^(?i)true$') { Write-FixLine '  note: still off for you: a global or repository git config sets core.longpaths (git config --show-origin --get core.longpaths)' }
  }
  if ($shown -eq 0) { Write-FixLine "Nothing to fix here (fixes: $($FixIds -join ', '))." }
  elseif (-not $elev) { Write-FixLine ''; Write-FixLine 'To apply, open PowerShell as administrator at this PC and run this script again.' }
  if ($rec) { Write-FixLine ''; Write-FixLine "Undo record: $($rec.Path)"; Write-FixLine "To undo:     lanq-makeready-fix.ps1 -Undo `"$($rec.Path)`"" }
  if ($failed -gt 0) { return 1 }
  return 0
}

function Invoke-FixUndo([string]$Path) {
  if (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path (Get-Location).ProviderPath $Path }
  $r = Read-FixRecord $Path
  if ($r.Error) { Write-FixErr "lanq-makeready-fix: record rejected ($($r.Error)): $Path. Nothing was changed."; return 2 }
  $rec = $r.Rec; $elev = Test-FixElevated; $failed = 0
  Write-FixLine "lanq-makeready-fix $ToolVersion undo: $Path (newest change first; each needs your answer)"
  $todo = @($rec.Items | Where-Object { @('applied', 'failed', 'pending') -contains $_.status } | Sort-Object -Property { $_.seq } -Descending)
  if ($todo.Count -eq 0) { Write-FixLine 'Nothing to undo in this record.'; return 0 }
  foreach ($it in $todo) {
    $id = $it.id; $b = ConvertFrom-StateText $id $it.before
    Write-FixLine ''
    Write-FixLine "undo $id  (check $($FixInfo[$id][0])), $($it.status) at $($it.time)" 'Yellow'
    $cur = Get-FixState $id; $ct = Get-StateText $id $cur
    Write-FixLine "  before the fix: $($it.before)"
    Write-FixLine "  after the fix:  $($it.after)"
    Write-FixLine "  now:            $ct"
    foreach ($c in (Get-FixCommand $id 'undo' $b)) { Write-FixLine "  command: $c" 'Cyan' }
    if ($ct -cne $it.after) { Write-FixLine '  changed since; left alone' 'DarkYellow'; continue }
    if (-not $elev) { Write-FixLine '  skipped: needs an elevated PowerShell (Run as administrator); this script never elevates itself' 'DarkYellow'; continue }
    if (-not (Confirm-Fix)) { Write-FixLine '  left as it is'; continue }
    $cur2 = Get-FixState $id
    if ((Get-StateText $id $cur2) -cne $it.after) { Write-FixLine '  changed since; left alone' 'DarkYellow'; continue }
    $err = ''
    try { Invoke-FixChange $id 'undo' $b $cur2 } catch { $err = "$($_.Exception.Message)" }
    $now = Get-StateText $id (Get-FixState $id)
    if (-not $err -and $now -ceq $it.before) {
      $it.status = 'undone'; $it.time = Get-UtcStamp
      if (Save-FixRecord $rec) { Write-FixLine '  undone and verified' 'Green' } else { $failed++ }
    } else { $failed++; Write-FixLine "  FAILED: $err (now: $now)" 'Red' }
  }
  if ($failed -gt 0) { return 1 }
  return 0
}

function Show-FixRecords {
  $dir = Get-FixRecordDir
  $files = @(Get-ChildItem -LiteralPath $dir -Filter 'fix-*.json' -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)
  if ($files.Count -eq 0) { Write-FixLine "No undo records in $dir"; return 0 }
  foreach ($f in $files) {
    $r = Read-FixRecord $f.FullName
    if ($r.Error) { Write-FixLine "$($f.FullName): not a valid record ($($r.Error))" 'DarkYellow'; continue }
    $its = @($r.Rec.Items | ForEach-Object { "$($_.id) $($_.status)" }) -join ', '
    if (-not $its) { $its = 'no changes' }
    Write-FixLine "$($f.FullName): started $($r.Rec.Started) on $($r.Rec.Host): $its"
  }
  return 0
}

function Invoke-FixMain([string]$Mode = 'apply', [string]$UndoPath = '', [bool]$FromFile = $false) {
  $why = Get-FixRefusal $Mode $FromFile
  if ($why) { Write-FixErr "lanq-makeready-fix: $why"; return 3 }
  if ($Mode -eq 'list') { return (Show-FixRecords) }
  if ($Mode -eq 'undo') { return (Invoke-FixUndo $UndoPath) }
  return (Invoke-FixApply ($Mode -eq 'dry'))
}

# ---------- main ----------

if ($env:LANQ_MAKEREADY_FIX_LIB -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
$Usage = 'usage: lanq-makeready-fix.ps1 [-WhatIf | -Undo <record file> | -List]   (no -Yes or -Force: every change is confirmed one by one)'
if ($Extra -and @($Extra).Count -gt 0) { [Console]::Error.WriteLine("lanq-makeready-fix: unknown argument(s): $(@($Extra) -join ' ')"); [Console]::Error.WriteLine($Usage); exit 2 }
if ($Help) { Write-Host $Usage; exit 0 }
$mode = 'apply'; $n = 0
if ($WhatIf) { $mode = 'dry'; $n++ }
if ($PSBoundParameters.ContainsKey('Undo')) { $mode = 'undo'; $n++; if (-not $Undo) { [Console]::Error.WriteLine('lanq-makeready-fix: -Undo needs a record file'); exit 2 } }
if ($List) { $mode = 'list'; $n++ }
if ($n -gt 1) { [Console]::Error.WriteLine('lanq-makeready-fix: use only one of -WhatIf, -Undo and -List'); exit 2 }
$fromFile = Test-FixFromFile $FixInvocation
$why = Get-FixRefusal $mode $fromFile
if ($why) { [Console]::Error.WriteLine("lanq-makeready-fix: $why"); exit 3 }
if ($env:LANQ_MAKEREADY_FIX_LIB -eq '1') { [Console]::Error.WriteLine('lanq-makeready-fix: LANQ_MAKEREADY_FIX_LIB=1 is only for tests that dot-source this file; unset it.'); exit 2 }
exit (Invoke-FixMain -Mode $mode -UndoPath $Undo -FromFile $fromFile)
