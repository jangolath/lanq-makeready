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
  - before each change it writes the undo record %ProgramData%\lanq-makeready\fix-<UTC time>.json (schema
    lanq-makeready-fix/v1) in a folder only Administrators and SYSTEM may change, and -Undo <file> puts the changes
    back, newest first, again confirming each.
  Fixes (v1): ssh.start, ssh.auto, power.sleep, longpaths.on, git.longpaths, ssh.aclkeys.
  Exit code: 0 = done or nothing to do, 1 = a change failed or did not verify, 2 = bad arguments or a rejected record,
  3 = refused (over SSH, from stdin, no interactive console).
.PARAMETER WhatIf
  Dry run: show every applicable fix and its undo; change nothing.
.PARAMETER List
  List the undo records in %ProgramData%\lanq-makeready (needs an elevated PowerShell to read them).
.NOTES
  -Undo <record file>: undo the changes in that record, newest first, confirming each.
#>
# lanq-makeready-fix-marker (identifies this file; the script refuses to run when it was not started from a file)
[CmdletBinding(PositionalBinding = $false)]
param([switch]$WhatIf, [switch]$List, [switch]$Help, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra)

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
# Every function this file defines; an alias with one of these names (or of a command a fix runs) would run instead.
$FixFunctionNames = @('Write-FixLine', 'Write-FixErr', 'Get-FixSessionId', 'Get-FixProcessTable', 'Get-AncestorNames', 'Test-FixOverSsh', 'Test-FixFromFile',
  'Test-FixConsole', 'Read-FixAnswer', 'Test-Yes', 'Confirm-Fix', 'Test-FixElevated', 'Get-FixCommandShadow', 'Get-FixRefusal', 'Invoke-Native', 'Get-PowercfgAcSeconds',
  'Find-Git', 'Get-PathGit', 'Test-OnlyAdminsSystem', 'ConvertFrom-Sddl', 'Test-SafeRestoreDacl', 'Get-DaclCore', 'Get-RestoreDacl', 'Format-Dacl', 'Test-TrustedSddl',
  'Get-AuthKeySummary', 'Get-FixState', 'ConvertFrom-StateText', 'Get-StateText', 'Test-SameState', 'Get-FixNote', 'Test-FixNeeded', 'Test-FixDone', 'Get-ExpectedAfter',
  'Get-StateSummary', 'Get-FixCommand', 'Assert-Native', 'Invoke-FixChange', 'Get-FixRecordDir', 'Get-UtcStamp', 'Get-SafeWord', 'Get-AccountName', 'Test-SafeUndoDacl', 'Get-ExplicitOthers', 'New-FixSecuredDir', 'New-FixSecuredFile',
  'Get-FixRecordDirProblem', 'Get-PathSddl',
  'Test-FixRecordDirTrusted', 'Initialize-FixRecordDir', 'Test-FixRecordTrusted', 'New-FixRecord', 'ConvertTo-JsonText', 'ConvertTo-FixJson', 'Save-FixRecord',
  'Test-Props', 'Test-Str', 'ConvertTo-TimeText', 'New-RecordError', 'Read-FixRecord', 'Show-Fix', 'Invoke-FixApply', 'Invoke-FixUndo', 'Show-FixRecords', 'Invoke-FixMain',
  'Get-UndoArg')
# Every cmdlet this file runs. A function or alias with one of these names would run instead of the cmdlet, so the
# script refuses to start when any of them does not resolve to the cmdlet itself (Get-FixCommandShadow).
$FixCmdletNames = @('Get-Service', 'Set-Service', 'Start-Service', 'Stop-Service', 'Get-Item', 'Set-ItemProperty', 'Remove-ItemProperty', 'Get-Acl', 'Set-Acl',
  'Get-Content', 'Get-ChildItem', 'Test-Path', 'Join-Path', 'Split-Path', 'Get-Command', 'Get-CimInstance', 'Select-Object', 'Where-Object', 'ForEach-Object', 'Sort-Object',
  'ConvertFrom-Json', 'Write-Host', 'New-Object', 'Get-Location', 'Get-Alias')
$FixWalkCache = $null   # the parent-process walk is done once per process
# The things the fixes touch. Fixed names, never taken from a record file.
$SshdName = 'sshd'
$FsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
$SysDir = [Environment]::GetFolderPath('System')
$PowercfgExe = Join-Path $SysDir 'powercfg.exe'
$IcaclsExe = Join-Path $SysDir 'icacls.exe'
$KeysFile = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ssh\administrators_authorized_keys'
$BaSid = 'S-1-5-32-544'; $SySid = 'S-1-5-18'; $TiSid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
# The record folder and files: owned by Administrators, only Administrators and SYSTEM may use them, nothing inherited.
$RecordDirSddl = 'O:BAD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)'
$RecordFileSddl = 'O:BAD:PAI(A;;FA;;;BA)(A;;FA;;;SY)'
# The DACL icacls leaves on the keys file (used to predict a pending record's after state).
$TightDacl = 'D:PAI(A;;FA;;;BA)(A;;FA;;;SY)'
$FixOut = New-Object System.Collections.ArrayList

# ---------- output ----------

function Write-FixLine([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) {
  [void]$FixOut.Add($Text)
  if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline } else { Write-Host $Text -ForegroundColor $Color }
}
function Write-FixErr([string]$Text) { [void]$FixOut.Add($Text); [Console]::Error.WriteLine($Text) }

# ---------- local only (test seams: Test-FixConsole and Read-FixAnswer) ----------
# Tests and the disposable-machine CI driver dot-source this file (LANQ_MAKEREADY_FIX_LIB=1) and replace
# Test-FixConsole/Read-FixAnswer with fakes (the fake-state tests replace more: state, runner, record store). That needs
# code already running in this PowerShell, which could change the PC directly anyway, so the seam widens nothing. A
# direct run with LANQ_MAKEREADY_FIX_LIB=1 still applies every refusal and then exits 2. Over SSH and from stdin are
# checked in Invoke-FixMain too.

function Get-FixSessionId { try { return [System.Diagnostics.Process]::GetCurrentProcess().SessionId } catch { return -1 } }

# Every process (id, parent, name, start time), read in a separate runspace with a deadline; $null on timeout or error.
function Get-FixProcessTable([int]$Sec = 15) {
  $ps = $null
  try {
    $ps = [System.Management.Automation.PowerShell]::Create()
    [void]$ps.AddScript('Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Id = [int]$_.ProcessId; Parent = [int]$_.ParentProcessId; Name = "$($_.Name)"; Created = $_.CreationDate } }')
    $h = $ps.BeginInvoke()
    if (-not $h.AsyncWaitHandle.WaitOne($Sec * 1000)) { [void]$ps.BeginStop($null, $null); return $null }
    $r = @($ps.EndInvoke($h))
    if ($ps.HadErrors -or $r.Count -eq 0) { return $null }
    return $r
  } catch { return $null } finally { if ($ps) { try { $ps.Dispose() } catch { } } }
}

# Names of the parent processes of $StartPid, nearest first. A "parent" that started after its child is a reused PID:
# the walk stops there.
function Get-AncestorNames($Procs, [int]$StartPid) {
  $byId = @{}; foreach ($p in @($Procs)) { $byId[[int]$p.Id] = $p }
  $names = @(); $cur = $byId[$StartPid]
  for ($i = 0; $i -lt 32 -and $cur; $i++) {
    $par = $byId[[int]$cur.Parent]
    if (-not $par -or $par.Id -eq $cur.Id) { break }
    if ($par.Created -and $cur.Created -and $par.Created -gt $cur.Created) { break }
    $names += "$($par.Name)"; $cur = $par
  }
  return , $names
}

function Test-FixOverSsh {
  if ($env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:SSH_TTY) { return $true }
  # an elevated or runas child may lose the variables: look for sshd among the parent processes (once per process)
  if ($null -eq $script:FixWalkCache) {
    $t = Get-FixProcessTable
    if ($null -eq $t) { $script:FixWalkCache = ((Get-FixSessionId) -eq 0) }   # cannot tell: session 0 (services, OpenSSH) is refused
    else { $script:FixWalkCache = (@(Get-AncestorNames $t $PID | Where-Object { $_ -match '^sshd' }).Count -gt 0) }
  }
  return [bool]$script:FixWalkCache
}

function Test-FixFromFile($Inv) {
  try { return [bool]($Inv.MyCommand.CommandType -eq 'ExternalScript' -and $Inv.MyCommand.Path -and ("$($Inv.MyCommand.ScriptContents)" -match 'lanq-makeready-fix-marker')) }
  catch { return $false }
}

# An interactive console: a desktop session (never session 0, where services and OpenSSH sessions run) and stdin
# not redirected.
function Test-FixConsole {
  try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and (Get-FixSessionId) -gt 0) } catch { return $false }
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

# Names that would not run what this script means: an alias over one of its functions, or a function or alias over a
# cmdlet it uses (a profile, a module or an earlier command in this session could have defined one).
function Get-FixCommandShadow {
  $bad = @()
  foreach ($n in $FixFunctionNames) { if (@(Microsoft.PowerShell.Utility\Get-Alias -Name $n -ErrorAction SilentlyContinue).Count -gt 0) { $bad += $n } }
  foreach ($n in $FixCmdletNames) {
    $c = @(Microsoft.PowerShell.Core\Get-Command -Name $n -ErrorAction SilentlyContinue)
    if ($c.Count -eq 0 -or "$($c[0].CommandType)" -ne 'Cmdlet') { $bad += $n }
  }
  return $bad
}

# '' when the script may run in this mode, else the reason it refuses.
function Get-FixRefusal([string]$Mode, [bool]$FromFile) {
  if (Test-FixOverSsh) { return 'refused: this session runs over SSH (SSH_CONNECTION, SSH_CLIENT or SSH_TTY is set, sshd started it, or the parent processes cannot be read in session 0). Fix mode is for the owner at the PC itself. Nothing was changed.' }
  if (-not $FromFile) { return 'refused: the script came from stdin or a string ([scriptblock]::Create, iex). Save it as a file, read it, and run that file at the PC. Nothing was changed.' }
  $sh = @(Get-FixCommandShadow)
  if ($sh.Count -gt 0) { return "refused: a function or alias would run instead of a command this script uses: $($sh -join ', '). Start PowerShell with -NoProfile. Nothing was changed." }
  if (@('apply', 'undo') -contains $Mode -and -not (Test-FixConsole)) { return 'refused: no interactive console (stdin is redirected, the session is not interactive, or it is session 0 where services and OpenSSH sessions run). Every change needs your answer at the keyboard; -WhatIf and -List work without one. Nothing was changed.' }
  return ''
}

# ---------- state (reads only) ----------

# Runs an exe with fixed arguments, stdin closed, from %SystemRoot%, without GIT_* variables; @{ Code; Out }.
# Reads here; changes only in FIXES.
function Invoke-Native([string]$Exe, [string[]]$ArgList, [int]$Sec = 60) {
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $env:SystemRoot
    $psi.Arguments = (@($ArgList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    foreach ($k in @($psi.EnvironmentVariables.Keys)) { if ("$k" -like 'GIT_*') { $psi.EnvironmentVariables.Remove($k) } }
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

# git from Program Files first; a git found only on PATH elsewhere (a folder users may change) is reported, not used.
function Find-Git {
  $roots = @([Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'), $env:SystemRoot) | Where-Object { $_ }
  foreach ($r in $roots) { $c = Join-Path $r 'Git\cmd\git.exe'; if (Test-Path -LiteralPath $c -PathType Leaf) { return @{ Path = $c; Trusted = $true } } }
  $g = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $g -or $g.Source -match '\\WindowsApps\\') { return $null }
  $ok = $false; foreach ($r in $roots) { if ($g.Source.StartsWith($r.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $ok = $true } }
  return @{ Path = $g.Source; Trusted = $ok }
}
# The git the scanner checks: the first one on PATH (outside WindowsApps), as lanq-makeready.ps1 finds it.
function Get-PathGit {
  $g = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $g -or $g.Source -match '\\WindowsApps\\') { return '' }
  return "$($g.Source)"
}

function Test-OnlyAdminsSystem([string]$Dacl) {   # every ACE is for Administrators (BA) or SYSTEM (SY)
  foreach ($m in [regex]::Matches($Dacl, '\(([^)]*)\)')) {
    $sid = $m.Groups[1].Value.Split(';')[5]
    if (@('BA', 'SY', $BaSid, $SySid) -notcontains $sid) { return $false }
  }
  return $true
}

function ConvertFrom-Sddl([string]$Sddl) { try { return (New-Object System.Security.AccessControl.RawSecurityDescriptor($Sddl)) } catch { return $null } }

$FullMask = 0x1F01FF; $GenericAll = 0x10000000
# Rights that let someone change a file or folder, or the files a folder holds (data, attributes, delete, ACL, owner).
$WriteMask = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000

# '' when a saved keys-file DACL is safe to put back, else why not: it must be a real DACL with entries, no deny entries,
# and Administrators and SYSTEM keep full control.
function Test-SafeRestoreDacl([string]$Dacl) {
  $sd = ConvertFrom-Sddl $Dacl
  if (-not $sd) { return 'it cannot be parsed' }
  if ($null -eq $sd.DiscretionaryAcl) { return 'it is a NULL DACL (everyone has full access)' }
  if ($sd.DiscretionaryAcl.Count -eq 0) { return 'it is an empty DACL (nobody could open the file)' }
  $ba = $false; $sy = $false
  foreach ($a in $sd.DiscretionaryAcl) {
    if ("$($a.AceQualifier)" -ne 'AccessAllowed') { return 'it has a deny entry (it could lock out Administrators or SYSTEM)' }
    $full = (($a.AccessMask -band $FullMask) -eq $FullMask) -or (($a.AccessMask -band $GenericAll) -ne 0)
    if ($full -and "$($a.SecurityIdentifier)" -eq $BaSid) { $ba = $true }
    if ($full -and "$($a.SecurityIdentifier)" -eq $SySid) { $sy = $true }
  }
  if (-not ($ba -and $sy)) { return 'Administrators and SYSTEM would not both keep full control' }
  return ''
}

# '' when undo may write back this saved DACL. What undo writes is the protection flag plus the explicit entries
# (Get-RestoreDacl): when the DACL is protected that is the whole result and is checked on its own; when it is not, the
# folder adds its inherited entries again, which the saved DACL shows, so the saved DACL is checked as well.
function Test-SafeUndoDacl([string]$Dacl) {
  $why = Test-SafeRestoreDacl $Dacl
  if ($why) { return $why }
  if ($Dacl -cmatch '^D:[A-Z]*P') { $why = Test-SafeRestoreDacl (Get-RestoreDacl $Dacl); if ($why) { return "what undo writes (the explicit entries): $why" } }
  return ''
}

# Explicit (not inherited) entries for others than Administrators and SYSTEM: icacls /grant leaves them in place.
function Get-ExplicitOthers([string]$Dacl) {
  return @([regex]::Matches($Dacl, '\(([^)]*)\)') | Where-Object { $f = $_.Groups[1].Value.Split(';'); $f[1] -cnotmatch 'ID' -and @('BA', 'SY', $BaSid, $SySid) -notcontains $f[5] } | ForEach-Object { $_.Groups[1].Value.Split(';')[5] })
}

# An account name for a SID (SDDL alias or S-1-...), or the SID when it cannot be translated.
function Get-AccountName([string]$Sid) {
  try {
    $sd = ConvertFrom-Sddl "O:$Sid"
    $id = $sd.Owner
    try { return $id.Translate([System.Security.Principal.NTAccount]).Value } catch { return "$id" }
  } catch { return $Sid }
}

# What undo can put back of a DACL: its protection flag and its own (explicit) entries. Inherited entries come back
# from the parent folder by themselves; Windows does not take them literally.
function Get-DaclCore([string]$Dacl) {
  $flags = ''; if ($Dacl -cmatch '^D:([A-Z]*)') { $flags = $Matches[1] }
  $own = @([regex]::Matches($Dacl, '\([^)]*\)') | Where-Object { $_.Value.Split(';')[1] -cnotmatch 'ID' } | ForEach-Object { $_.Value } | Sort-Object)
  return ("protected=$($flags -cmatch 'P') " + ($own -join ''))
}
function Get-RestoreDacl([string]$Dacl) {
  $flags = ''; if ($Dacl -cmatch '^D:([A-Z]*)') { $flags = $Matches[1] }
  $own = @([regex]::Matches($Dacl, '\([^)]*\)') | Where-Object { $_.Value.Split(';')[1] -cnotmatch 'ID' } | ForEach-Object { $_.Value })
  return ('D:' + $flags + ($own -join ''))
}

# The DACL in words: one line per entry, account name (or SID) and rights.
function Format-Dacl([string]$Dacl) {
  $sd = ConvertFrom-Sddl $Dacl
  if (-not $sd -or $null -eq $sd.DiscretionaryAcl) { return @("    (cannot show $Dacl)") }
  $lines = @()
  foreach ($a in $sd.DiscretionaryAcl) {
    $sid = $a.SecurityIdentifier; $name = "$sid"
    try { $name = $sid.Translate([System.Security.Principal.NTAccount]).Value } catch { }
    $kind = 'allow'; if ("$($a.AceQualifier)" -ne 'AccessAllowed') { $kind = 'DENY' }
    $rights = "$([System.Security.AccessControl.FileSystemRights]($a.AccessMask -band 0x1FFFFF))"
    if (($a.AccessMask -band $GenericAll) -ne 0) { $rights = 'FullControl (generic)' }
    $inh = ''; if ("$($a.AceFlags)" -match 'Inherited') { $inh = ' (inherited)' }
    $lines += "    $kind $name : $rights$inh"
  }
  return $lines
}

# '' when a file or folder security descriptor is owned by Administrators or SYSTEM and nobody else may change it.
function Test-TrustedSddl([string]$Sddl) {
  $sd = ConvertFrom-Sddl $Sddl
  if (-not $sd) { return 'its permissions cannot be read' }
  if (@($BaSid, $SySid) -notcontains "$($sd.Owner)") { return "it is owned by $(Get-AccountName "$($sd.Owner)"), not Administrators or SYSTEM" }
  if ($null -eq $sd.DiscretionaryAcl) { return 'it has no DACL (everyone may change it)' }
  foreach ($a in $sd.DiscretionaryAcl) {
    if ("$($a.AceQualifier)" -eq 'AccessAllowed' -and @($BaSid, $SySid) -notcontains "$($a.SecurityIdentifier)" -and ($a.AccessMask -band $WriteMask) -ne 0) {
      return "$(Get-AccountName "$($a.SecurityIdentifier)") may change it"
    }
  }
  return ''
}

# One line per key in an authorized_keys file: type, SHA256 fingerprint (as ssh-keygen -l shows it) and comment.
function Get-AuthKeySummary([string[]]$Lines) {
  $out = @()
  foreach ($l in @($Lines)) {
    $t = "$l".Trim(); if (-not $t -or $t.StartsWith('#')) { continue }
    $opt = ''
    if ($t -notmatch '^(ssh-|ecdsa-|sk-)') {   # options first: they end at the first blank outside double quotes (as sshd reads them)
      $q = $false; $i = 0
      for (; $i -lt $t.Length; $i++) {
        $ch = $t[$i]
        if ($q -and $ch -eq '\') { $i++ } elseif ($ch -eq '"') { $q = -not $q } elseif (-not $q -and ($ch -eq ' ' -or $ch -eq "`t")) { break }
      }
      $opt = ' (with options)'; $t = $t.Substring([math]::Min($i, $t.Length)).Trim()
    }
    $w = @($t -split '\s+')
    if ($w.Count -lt 2 -or $w[0] -notmatch '^(ssh-|ecdsa-|sk-)') { $out += 'a line this script cannot read as a key (check it yourself)'; continue }
    $fp = 'fingerprint unreadable'
    try { $sha = [System.Security.Cryptography.SHA256]::Create(); $fp = 'SHA256:' + [Convert]::ToBase64String($sha.ComputeHash([Convert]::FromBase64String($w[1]))).TrimEnd('='); $sha.Dispose() } catch { }
    $c = ''; if ($w.Count -gt 2) { $c = ' ' + ($w[2..($w.Count - 1)] -join ' ') }
    $out += (("$($w[0]) $fp$c$opt") -replace '[^\x20-\x7E]', '?')
  }
  return , $out
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
      $s = @{ Scheme = $null; Standby = $null; Hibernate = $null }
      $r = Invoke-Native $PowercfgExe @('/getactivescheme'); if ($r.Code -eq 0 -and "$($r.Out)" -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $s.Scheme = $Matches[1].ToLowerInvariant() }
      $r = Invoke-Native $PowercfgExe @('/q', 'SCHEME_CURRENT', 'SUB_SLEEP', 'STANDBYIDLE'); if ($r.Code -eq 0) { $s.Standby = Get-PowercfgAcSeconds $r.Out }
      $r = Invoke-Native $PowercfgExe @('/q', 'SCHEME_CURRENT', 'SUB_SLEEP', 'HIBERNATEIDLE'); if ($r.Code -eq 0) { $s.Hibernate = Get-PowercfgAcSeconds $r.Out }
      return $s
    }
    'longpaths.on' {
      $s = @{ Value = $null; Kind = 'none'; Raw = $null }
      try {
        $k = Get-Item -LiteralPath $FsKey -ErrorAction Stop
        if (@($k.GetValueNames()) -contains 'LongPathsEnabled') {
          $s.Kind = "$($k.GetValueKind('LongPathsEnabled'))"; $s.Raw = $k.GetValue('LongPathsEnabled')
          if ($s.Kind -eq 'DWord') { $s.Value = ([long]$s.Raw) -band 4294967295 }
        }
      } catch { $s.Kind = 'unreadable' }
      return $s
    }
    'git.longpaths' {
      $g = Find-Git
      if (-not $g) { return @{ Git = $null } }
      $s = @{ Git = $g.Path; Trusted = $g.Trusted; System = $null; Effective = $null; SystemFile = ''; PathGit = (Get-PathGit) }
      if (-not $g.Trusted) { return $s }
      $git = $g.Path
      $r = Invoke-Native $git @('config', '--system', '--show-origin', '--get', 'core.longpaths')
      if ($r.Code -eq 0 -and "$($r.Out)" -match '^file:(.+?)\t(.*)$') { $s.SystemFile = $Matches[1]; $s.System = $Matches[2].Trim() }
      if (-not $s.SystemFile) { $r = Invoke-Native $git @('config', '--system', '--show-origin', '--list'); if ($r.Code -eq 0 -and "$($r.Out)" -match '^file:([^\t]+)\t') { $s.SystemFile = $Matches[1] } }
      $r = Invoke-Native $git @('config', '--get', 'core.longpaths'); if ($r.Code -eq 0) { $s.Effective = "$($r.Out)".Trim() }
      return $s
    }
    'ssh.aclkeys' {
      if (-not (Test-Path -LiteralPath $KeysFile -PathType Leaf)) { return @{ Exists = $false } }
      $s = @{ Exists = $true; Reparse = $true; Dacl = $null; Ok = $null; Owner = $null; Keys = @() }
      try {
        $fsItem = Get-Item -LiteralPath $KeysFile -Force -ErrorAction Stop
        $s.Reparse = [bool]($fsItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        $acl = Get-Acl -LiteralPath $KeysFile -ErrorAction Stop
        $s.Owner = "$($acl.GetOwner([System.Security.Principal.SecurityIdentifier]))"
        $s.Dacl = $acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
        $s.Ok = Test-OnlyAdminsSystem $s.Dacl
        $s.Keys = Get-AuthKeySummary @(Get-Content -LiteralPath $KeysFile -ErrorAction Stop)
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
      if ($Text -cmatch '^scheme=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) standby=([0-9]{1,10}) hibernate=([0-9]{1,10}|-)$') {
        $sc = $Matches[1]; $sb = [long]$Matches[2]; $hb = $null; if ($Matches[3] -ne '-') { $hb = [long]$Matches[3] }
        if ($sb -gt 4294967295 -or $hb -gt 4294967295) { return $null }
        return @{ Scheme = $sc; Standby = $sb; Hibernate = $hb }
      }
      return $null
    }
    'longpaths.on' {
      if ($Text -cmatch '^value=([0-9]{1,10}) type=dword$') { $v = [long]$Matches[1]; if ($v -gt 4294967295) { return $null }; return @{ Value = $v; Kind = 'DWord' } }
      if ($Text -ceq 'value=- type=none') { return @{ Value = $null; Kind = 'none' } }
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
    'power.sleep' { if ($null -ne $S.Standby -and $S.Scheme) { $h = '-'; if ($null -ne $S.Hibernate) { $h = "$($S.Hibernate)" }; $t = "scheme=$($S.Scheme) standby=$($S.Standby) hibernate=$h" } }
    'longpaths.on' { if ($S.Kind -eq 'none') { $t = 'value=- type=none' } elseif ($S.Kind -eq 'DWord') { $t = "value=$($S.Value) type=dword" } }
    'git.longpaths' { if ($S.Git -and $S.Trusted) { $v = '-'; if ($null -ne $S.System) { $v = "$($S.System)" }; $t = "value=$v" } }
    'ssh.aclkeys' { if ($S.Exists -and -not $S.Reparse -and $S.Dacl) { $t = "dacl=$($S.Dacl)" } }
  }
  if ($null -eq $t -or $null -eq (ConvertFrom-StateText $Id $t)) { return $null }
  return $t
}

# Two state texts of one fix describe the same state. For the keys file that is the protection flag and the explicit
# entries: inherited entries are re-inherited by Windows, not restored literally.
function Test-SameState([string]$Id, [string]$A, [string]$B) {
  if ($Id -eq 'ssh.aclkeys' -and $A.StartsWith('dacl=') -and $B.StartsWith('dacl=')) { return ((Get-DaclCore $A.Substring(5)) -ceq (Get-DaclCore $B.Substring(5))) }
  return ($A -ceq $B)
}

# Why a fix that the scanner would report is not offered here ('' when there is nothing to say).
function Get-FixNote([string]$Id, $S) {
  switch ($Id) {
    'ssh.start' { if ($S.Installed -and @('Running', 'Stopped') -notcontains $S.Status) { return "sshd is $($S.Status) (changing state); run this script again in a moment" } }
    'ssh.auto' { if ($S.Installed -and $S.Status -eq 'Running' -and @('Automatic', 'Manual', 'Disabled') -notcontains $S.StartType) { return "sshd starts $($S.StartType); this script only sets Automatic, Manual or Disabled" } }
    'longpaths.on' {   # the scanner reads the value as a number: a REG_SZ or REG_QWORD 1 counts as on there, so nothing to say
      if (@('none', 'DWord') -notcontains $S.Kind -and -not ($S.Raw -eq 1)) { return "LongPathsEnabled is of type $($S.Kind), not DWORD; fix it yourself in the registry" }
    }
    'power.sleep' { if ($null -ne $S.Standby -and -not $S.Scheme) { return 'the active power scheme could not be read (powercfg /getactivescheme), so undo could not be tied to it' } }
    'git.longpaths' {
      if ($S.Git -and -not $S.Trusted) { return "git here is $($S.Git), outside Program Files (a folder users may change); this script runs git only from Program Files, so set it yourself" }
      if ($S.Git -and "$($S.Effective)" -notmatch '^(?i)true$' -and $null -ne $S.Effective -and "$($S.Effective)" -ne "$($S.System)") {
        return "core.longpaths is $($S.Effective) in your global git config, which overrides the system config this script changes: git config --global core.longpaths true (or --unset)"
      }
    }
    'ssh.aclkeys' {
      if (-not $S.Exists) { return '' }
      if ($S.Reparse) { return "$KeysFile is a link; it is not touched" }
      if (-not $S.Dacl) { return "$KeysFile could not be read (run elevated)" }
      if ($S.Dacl -match 'NO_ACCESS_CONTROL') { return "not fixable here: $KeysFile has no DACL at all (everyone has full access); set its permissions yourself" }
      if (@($BaSid, $SySid, $TiSid) -notcontains $S.Owner) { return "not fixable here: $KeysFile is owned by $($S.Owner); sshd also requires the owner to be Administrators or SYSTEM and this fix does not change owners: icacls.exe `"$KeysFile`" /setowner *S-1-5-32-544" }
      if ($S.Ok -eq $false) {
        $why = Test-SafeUndoDacl $S.Dacl; if ($why) { return "not fixable here: -Undo could not safely put the current permissions back ($why); fix them yourself" }
        $ex = @(Get-ExplicitOthers $S.Dacl)
        if ($ex.Count -gt 0) {
          $names = @($ex | ForEach-Object { Get-AccountName $_ }) -join ', '
          $cmd = @($ex | ForEach-Object { "icacls.exe `"$KeysFile`" /remove:g *$(if ($_ -match '^S-1-') { $_ } else { "$((ConvertFrom-Sddl "O:$_").Owner)" })" }) -join ' ; '
          return "not offered: $KeysFile has its own entries for $names, which icacls /grant leaves in place, so this fix could not make it Administrators and SYSTEM only. Remove them yourself after checking ($cmd), then run this script again"
        }
      }
    }
  }
  return ''
}

function Test-FixNeeded([string]$Id, $S) {
  if (-not (Get-StateText $Id $S)) { return $false }
  if (Get-FixNote $Id $S) { return $false }
  switch ($Id) {
    'ssh.start' { return ($S.Status -eq 'Stopped') }
    'ssh.auto' { return ($S.Status -eq 'Running' -and @('Manual', 'Disabled') -contains $S.StartType) }
    'power.sleep' { return ($S.Standby -gt 0 -or ($null -ne $S.Hibernate -and $S.Hibernate -gt 0)) }
    'longpaths.on' { return ($S.Value -ne 1) }
    'git.longpaths' { return ("$($S.System)" -notmatch '^(?i)true$' -and "$($S.Effective)" -notmatch '^(?i)true$') }
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
    'git.longpaths' { return ("$($S.System)" -match '^(?i)true$' -and "$($S.Effective)" -match '^(?i)true$') }
    'ssh.aclkeys' { return ($S.Ok -eq $true) }
  }
  return $false
}

# What the state should be right after the change (recorded with the pending item, so a crash leaves it undoable).
function Get-ExpectedAfter([string]$Id, $S) {
  switch ($Id) {
    'ssh.start' { return 'starttype=Automatic status=Running' }
    'ssh.auto' { return "starttype=Automatic status=$($S.Status)" }
    'power.sleep' { $h = '-'; if ($null -ne $S.Hibernate) { $h = '0' }; return "scheme=$($S.Scheme) standby=0 hibernate=$h" }
    'longpaths.on' { return 'value=1 type=dword' }
    'git.longpaths' { return 'value=true' }
    'ssh.aclkeys' { return "dacl=$TightDacl" }
  }
  return 'unknown'
}

function Get-StateSummary([string]$Id, $S) {
  switch ($Id) {
    { @('ssh.start', 'ssh.auto') -contains $_ } { return "sshd is $($S.Status), start type $($S.StartType)" }
    'power.sleep' { $h = 'unreadable'; if ($null -ne $S.Hibernate) { $h = "$([math]::Round($S.Hibernate / 60)) min" }; return "power scheme $($S.Scheme): sleeps after $([math]::Round($S.Standby / 60)) min, hibernates after $h (0 = never)" }
    'longpaths.on' { if ($null -eq $S.Value) { return 'LongPathsEnabled is not set (off)' }; return "LongPathsEnabled = $($S.Value)" }
    'git.longpaths' {
      $v = 'not set'; if ($null -ne $S.System) { $v = $S.System }; $e = 'not set'; if ($S.Effective) { $e = $S.Effective }
      $f = $S.SystemFile; if (-not $f) { $f = 'its system config file (created on first write)' }
      return "git $($S.Git), system config $f; core.longpaths there: $v; in effect: $e"
    }
    'ssh.aclkeys' { return "$KeysFile has the DACL $($S.Dacl)" }
  }
  return ''
}

#region FIXES
# The ONE place that changes this PC, keyed by fix id. Get-FixCommand is the exact text shown for each change;
# Invoke-FixChange makes it. $B is the before state (fresh, or parsed from a validated record), $Cur the current state
# (only its git path is used). Undo commands are built from the fix id and $B only; nothing in a record is ever run.
function Get-FixCommand([string]$Id, [string]$Mode, $B, $Cur) {
  $cmd = @(); $git = "`"$($Cur.Git)`""
  switch ("$Id|$Mode") {
    'ssh.start|apply' { $cmd = @("Set-Service -Name $SshdName -StartupType Automatic", "Start-Service -Name $SshdName") }
    'ssh.start|undo' { $cmd = @("Set-Service -Name $SshdName -StartupType $($B.StartType)"); if ($B.Status -eq 'Stopped') { $cmd += "Stop-Service -Name $SshdName" } }
    'ssh.auto|apply' { $cmd = @("Set-Service -Name $SshdName -StartupType Automatic") }
    'ssh.auto|undo' { $cmd = @("Set-Service -Name $SshdName -StartupType $($B.StartType)") }
    'power.sleep|apply' { if ($B.Standby -gt 0) { $cmd += 'powercfg /change standby-timeout-ac 0' }; if ($B.Hibernate -gt 0) { $cmd += 'powercfg /change hibernate-timeout-ac 0' } }
    'power.sleep|undo' { $cmd = @("powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE $($B.Standby)"); if ($null -ne $B.Hibernate) { $cmd += "powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE $($B.Hibernate)" }; $cmd += 'powercfg /setactive SCHEME_CURRENT' }
    'longpaths.on|apply' { $cmd = @("Set-ItemProperty -Path $FsKey -Name LongPathsEnabled -Value 1 -Type DWord") }
    'longpaths.on|undo' { if ($null -eq $B.Value) { $cmd = @("Remove-ItemProperty -Path $FsKey -Name LongPathsEnabled") } else { $cmd = @("Set-ItemProperty -Path $FsKey -Name LongPathsEnabled -Value $($B.Value) -Type DWord") } }
    'git.longpaths|apply' { $cmd = @("$git config --system core.longpaths true") }
    'git.longpaths|undo' { if ($null -eq $B.System) { $cmd = @("$git config --system --unset core.longpaths") } else { $cmd = @("$git config --system core.longpaths $($B.System)") } }
    'ssh.aclkeys|apply' { $cmd = @("icacls.exe `"$KeysFile`" /inheritance:r /grant *S-1-5-32-544:F /grant *S-1-5-18:F") }
    'ssh.aclkeys|undo' { $cmd = @("`$a = Get-Acl -LiteralPath '$KeysFile'; `$a.SetSecurityDescriptorSddlForm('$(Get-RestoreDacl $B.Dacl)', 'Access'); Set-Acl -LiteralPath '$KeysFile' -AclObject `$a   (inherited entries come back from the folder)") }
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
      $a.SetSecurityDescriptorSddlForm((Get-RestoreDacl $B.Dacl), [System.Security.AccessControl.AccessControlSections]::Access)
      Set-Acl -LiteralPath $KeysFile -AclObject $a -ErrorAction Stop
    }
    default { throw "no fix $Id ($Mode)" }
  }
}
#endregion FIXES

# ---------- undo record (the only file this script writes) ----------
# %ProgramData%\lanq-makeready, created by this script owned by Administrators with only Administrators and SYSTEM
# allowed (every fix needs elevation anyway). A non-elevated process cannot plant or change a record there, and -Undo
# refuses a record (or folder) that someone else could have written. Records are never kept in %LOCALAPPDATA%.

function Get-FixRecordDir { return (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'lanq-makeready') }
function Get-UtcStamp { return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
function Get-SafeWord([string]$S) { return ($S -replace '[^A-Za-z0-9._-]', '_') }

# The folder is created with its owner and DACL in the same call (no window in which it has the parent's permissions),
# and never re-permissioned afterwards: an existing folder is only checked. .NET Framework (PowerShell 5.1) has
# Directory.CreateDirectory(path, security); .NET 5+ (PowerShell 7) has FileSystemAclExtensions.Create.
function New-FixSecuredDir([string]$Dir) {
  $ds = New-Object System.Security.AccessControl.DirectorySecurity
  $ds.SetSecurityDescriptorSddlForm($RecordDirSddl)
  if ('System.IO.FileSystemAclExtensions' -as [type]) { [void][System.IO.FileSystemAclExtensions]::Create((New-Object System.IO.DirectoryInfo($Dir)), $ds) }
  else { [void][System.IO.Directory]::CreateDirectory($Dir, $ds) }
}
# A new file (CreateNew: refused if the name exists, as a leftover or a planted link) created with its owner and DACL.
function New-FixSecuredFile([string]$Path, [byte[]]$Bytes) {
  $fsec = New-Object System.Security.AccessControl.FileSecurity
  $fsec.SetSecurityDescriptorSddlForm($RecordFileSddl)
  if ('System.IO.FileSystemAclExtensions' -as [type]) {
    $st = [System.IO.FileSystemAclExtensions]::Create((New-Object System.IO.FileInfo($Path)), [System.IO.FileMode]::CreateNew, [System.Security.AccessControl.FileSystemRights]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::None, $fsec)
  } else {
    $st = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.Security.AccessControl.FileSystemRights]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::None, $fsec)
  }
  try { $st.Write($Bytes, 0, $Bytes.Length) } finally { $st.Dispose() }
}

# Full security descriptor of a path, or '' when it is a reparse point (link, junction) or cannot be read.
function Get-PathSddl([string]$Path) {
  try {
    $fsItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($fsItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return '' }
    return "$((Get-Acl -LiteralPath $Path -ErrorAction Stop).Sddl)"
  } catch { return '' }
}

# '' when the record folder is exactly as this script makes it: not a link, owned by Administrators or SYSTEM,
# protected, and only Administrators and SYSTEM in its DACL.
function Test-FixRecordDirTrusted([string]$Dir) {
  $sd = Get-PathSddl $Dir
  if (-not $sd) { return 'it is a link or its permissions cannot be read' }
  $why = Test-TrustedSddl $sd; if ($why) { return $why }
  if ($sd -cnotmatch 'D:P') { return 'it inherits permissions from its parent' }
  if (-not (Test-OnlyAdminsSystem ($sd -replace '^.*?D:', 'D:'))) { return 'others than Administrators and SYSTEM are in its permissions' }
  return ''
}

# '' when the record folder is missing (it is created at the first change) or exactly as this script makes it; checked
# before the first question, so an unsafe folder stops the run before anything is asked or changed.
function Get-FixRecordDirProblem {
  $dir = Get-FixRecordDir
  if (-not (Test-Path -LiteralPath $dir)) { return '' }
  $why = Test-FixRecordDirTrusted $dir
  if (-not $why) { return '' }
  return ("the record folder $dir is not safe ($why). Nothing was changed. Look at what is in it, then move it out of the way: " +
    "Rename-Item -LiteralPath '$dir' -NewName lanq-makeready.untrusted   (if that is refused, take it over first: takeown.exe /a /r /d y /f `"$dir`"), and run this script again.")
}

function Initialize-FixRecordDir {
  $dir = Get-FixRecordDir
  if (-not (Test-Path -LiteralPath $dir)) {
    try { New-FixSecuredDir $dir } catch { return "could not create $dir ($($_.Exception.Message))" }
  }
  return (Get-FixRecordDirProblem)
}

# '' when a record file and its folder could only have been written by Administrators or SYSTEM.
function Test-FixRecordTrusted([string]$Path) {
  $f = Get-PathSddl $Path
  if (-not $f) { return 'the record is a link or its permissions cannot be read' }
  $why = Test-TrustedSddl $f; if ($why) { return "the record: $why" }
  $d = Get-PathSddl (Split-Path -Parent $Path)
  if (-not $d) { return 'its folder is a link or its permissions cannot be read' }
  $why = Test-TrustedSddl $d; if ($why) { return "its folder: $why" }
  return ''
}

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

# Written to a new temp file next to the record (refused if that name exists: a leftover or a planted link), created
# with the record's owner and ACL, then moved over the record, so a crash leaves the old or the new record whole.
function Save-FixRecord($Rec) {
  try {
    $why = Initialize-FixRecordDir
    if ($why) { Write-FixErr "lanq-makeready-fix: $why"; return $false }
    $tmp = $Rec.Path + '.tmp'
    if (@(Get-ChildItem -LiteralPath (Split-Path -Parent $tmp) -Force -Filter (Split-Path -Leaf $tmp) -ErrorAction SilentlyContinue).Count -gt 0) {
      Write-FixErr "lanq-makeready-fix: $tmp exists (left by a crash, or planted); look at it, remove it, and run this script again"; return $false
    }
    New-FixSecuredFile $tmp ((New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-FixJson $Rec)))
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
    if ($it.id -eq 'ssh.aclkeys') { $why = Test-SafeUndoDacl $it.before.Substring(5); if ($why) { return (New-RecordError "the saved ssh.aclkeys permissions are not safe to put back: $why") } }
    [void]$rec.Items.Add([ordered]@{ seq = [int]$it.seq; id = $it.id; status = $it.status; time = $tm; before = $it.before; command = $it.command; after = $it.after })
  }
  return @{ Rec = $rec; Error = '' }
}

# ---------- modes ----------

function Show-Fix([string]$Id, $S) {
  Write-FixLine ''
  Write-FixLine "$Id  (check $($FixInfo[$Id][0])): $($FixInfo[$Id][1])" 'Yellow'
  Write-FixLine "  now:     $(Get-StateSummary $Id $S)"
  if ($Id -eq 'ssh.aclkeys') {
    Write-FixLine "  keys:    $(@($S.Keys).Count) line(s) in the file. Review them: after this fix sshd trusts every one of them for administrator logins."
    foreach ($k in @($S.Keys)) { Write-FixLine "    - $k" }
  }
  if ($Id -eq 'git.longpaths' -and $S.PathGit -and $S.PathGit -ne $S.Git) {
    Write-FixLine "  note:    the scanner checks the git first on PATH ($($S.PathGit)); this fix sets the system config of $($S.Git). If they are different installs, the scanner may still report git."
  }
  foreach ($c in (Get-FixCommand $Id 'apply' $S $S)) { Write-FixLine "  command: $c" 'Cyan' }
  foreach ($c in (Get-FixCommand $Id 'undo' $S $S)) { Write-FixLine "  undo:    $c" }
}

function Invoke-FixApply([bool]$Dry) {
  $elev = Test-FixElevated
  if ($Dry) { Write-FixLine "lanq-makeready-fix $ToolVersion dry run: shows each applicable fix and its undo; nothing is changed" }
  else { Write-FixLine "lanq-makeready-fix ${ToolVersion}: changes only what you confirm, one fix at a time (default no)" }
  $rec = $null; $failed = 0; $shown = 0
  if ($elev -and -not $Dry) { $why = Get-FixRecordDirProblem; if ($why) { Write-FixErr "lanq-makeready-fix: $why"; return 1 } }
  foreach ($id in $FixIds) {
    $s = Get-FixState $id
    $note = Get-FixNote $id $s
    if ($note) { Write-FixLine ''; Write-FixLine "$id  (check $($FixInfo[$id][0])): not offered: $note" 'DarkYellow'; continue }
    if (-not (Test-FixNeeded $id $s)) { continue }
    $shown++
    Show-Fix $id $s
    if (-not $elev) { Write-FixLine '  skipped: needs an elevated PowerShell (Run as administrator); this script never elevates itself' 'DarkYellow'; continue }
    if ($Dry) { Write-FixLine '  dry run: not applied'; continue }
    if (-not (Confirm-Fix)) { Write-FixLine '  not applied'; continue }
    $s2 = Get-FixState $id   # the precondition, re-read just before the change
    if (-not (Test-FixNeeded $id $s2)) { Write-FixLine '  no longer needed (the state changed); nothing done'; continue }
    $before = Get-StateText $id $s2
    if ($before -cne (Get-StateText $id $s)) { Write-FixLine '  the state changed since it was shown; nothing done (run the script again)' 'DarkYellow'; continue }
    if (-not $rec) { $rec = New-FixRecord }
    $item = [ordered]@{ seq = ($rec.Items.Count + 1); id = $id; status = 'pending'; time = (Get-UtcStamp); before = $before; command = ((Get-FixCommand $id 'apply' $s2 $s2) -join ' ; '); after = (Get-ExpectedAfter $id $s2) }
    [void]$rec.Items.Add($item)
    if (-not (Save-FixRecord $rec)) { Write-FixErr '  nothing changed: the undo record could not be written'; $rec.Items.RemoveAt($rec.Items.Count - 1); return 1 }
    $err = ''
    try { Invoke-FixChange $id 'apply' $s2 $s2 } catch { $err = "$($_.Exception.Message)" }
    $s3 = Get-FixState $id
    $after = Get-StateText $id $s3; if (-not $after) { $after = 'unknown' }
    $item.after = $after; $item.time = Get-UtcStamp
    if (-not $err -and (Test-FixDone $id $s3)) { $item.status = 'applied'; Write-FixLine '  applied and verified' 'Green' }
    else { $item.status = 'failed'; $failed++; Write-FixLine "  FAILED: $err (now: $(Get-StateSummary $id $s3)); recorded, so -Undo can put back what changed" 'Red' }
    if (-not (Save-FixRecord $rec)) { $failed++; Write-FixErr "  the record could not be updated after the change; it still says pending: $($rec.Path)" }
    if ($id -eq 'longpaths.on' -and $item.status -eq 'applied') { Write-FixLine '  note: programs started from now on see it; reboot so that every program does' }
  }
  if ($shown -eq 0) { Write-FixLine "Nothing to fix here (fixes: $($FixIds -join ', '))." }
  elseif (-not $elev) { Write-FixLine ''; Write-FixLine 'To apply, open PowerShell as administrator at this PC and run this script again.' }
  if ($rec) { Write-FixLine ''; Write-FixLine "Undo record: $($rec.Path)"; Write-FixLine "To undo:     lanq-makeready-fix.ps1 -Undo `"$($rec.Path)`"" }
  if ($failed -gt 0) { return 1 }
  return 0
}

function Invoke-FixUndo([string]$Path) {
  if (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path (Get-Location).ProviderPath $Path }
  if (-not (Test-FixElevated)) {
    Write-FixLine "lanq-makeready-fix ${ToolVersion}: -Undo needs an elevated PowerShell (Run as administrator): the records and every change need it. This script never elevates itself. Nothing was changed." 'DarkYellow'
    return 1
  }
  $dir = [System.IO.Path]::GetFullPath((Get-FixRecordDir)).TrimEnd('\')
  $full = [System.IO.Path]::GetFullPath($Path)
  if ((Split-Path -Parent $full) -ne $dir -or (Split-Path -Leaf $full) -notmatch '^fix-[0-9]{8}T[0-9]{6}Z(-[0-9]{1,4})?\.json$') {
    Write-FixErr "lanq-makeready-fix: record rejected: -Undo reads only the records this script writes, fix-<time>.json in $dir. Nothing was changed."; return 2
  }
  $Path = $full
  $why = Test-FixRecordTrusted $Path
  if ($why -and [System.IO.File]::Exists($Path)) { Write-FixErr "lanq-makeready-fix: record rejected ($why; someone other than Administrators could have written it): $Path. Nothing was changed."; return 2 }
  $r = Read-FixRecord $Path
  if ($r.Error) { Write-FixErr "lanq-makeready-fix: record rejected ($($r.Error)): $Path. Nothing was changed."; return 2 }
  $rec = $r.Rec; $failed = 0
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
    if ($it.status -eq 'pending' -and $ct -and (Test-SameState $id $ct $it.before)) {
      $it.status = 'skipped'; $it.time = Get-UtcStamp
      if (Save-FixRecord $rec) { Write-FixLine '  never applied (the record was written, the change was not made); marked skipped' } else { $failed++ }
      continue
    }
    foreach ($c in (Get-FixCommand $id 'undo' $b $cur)) { Write-FixLine "  command: $c" 'Cyan' }
    if (-not $ct -or -not (Test-SameState $id $ct $it.after)) { Write-FixLine '  changed since; left alone' 'DarkYellow'; continue }
    if ($id -eq 'ssh.aclkeys') {
      Write-FixLine "  undo gives $KeysFile these permissions again:" 'Yellow'
      foreach ($l in (Format-Dacl $it.before.Substring(5))) { Write-FixLine $l 'Yellow' }
      Write-FixLine '  Every account above that may change the file could add keys again, and sshd ignores the file while others may change it: administrator key logins stop working.' 'Yellow'
    }
    if (-not (Confirm-Fix)) { Write-FixLine '  left as it is'; continue }
    $cur2 = Get-FixState $id
    $ct2 = Get-StateText $id $cur2
    if (-not $ct2 -or -not (Test-SameState $id $ct2 $it.after)) { Write-FixLine '  changed since; left alone' 'DarkYellow'; continue }
    $err = ''
    try { Invoke-FixChange $id 'undo' $b $cur2 } catch { $err = "$($_.Exception.Message)" }
    $nowState = Get-FixState $id
    $now = Get-StateText $id $nowState
    if ($id -eq 'ssh.aclkeys' -and $nowState.Dacl) {
      $lost = Test-SafeRestoreDacl $nowState.Dacl
      if ($lost) {
        $failed++
        Write-FixLine "  FAILED: after the undo the keys file's permissions are not safe ($lost). Give Administrators and SYSTEM full control again now: icacls.exe `"$KeysFile`" /grant *S-1-5-32-544:F /grant *S-1-5-18:F" 'Red'
        continue
      }
    }
    if (-not $err -and $now -and (Test-SameState $id $now $it.before)) {
      $it.status = 'undone'; $it.time = Get-UtcStamp
      if (Save-FixRecord $rec) { Write-FixLine '  undone and verified' 'Green' } else { $failed++ }
    } else { $failed++; Write-FixLine "  FAILED: $err (now: $now)" 'Red' }
  }
  if ($failed -gt 0) { return 1 }
  return 0
}

function Show-FixRecords {
  $dir = Get-FixRecordDir
  Write-FixLine "Undo records are kept in $dir (never in %LOCALAPPDATA%)."
  if (-not (Test-FixElevated)) { Write-FixLine 'Reading them needs an elevated PowerShell (only Administrators and SYSTEM may); this script never elevates itself.' 'DarkYellow'; return 0 }
  $files = @(Get-ChildItem -LiteralPath $dir -Filter 'fix-*.json' -File -ErrorAction SilentlyContinue | Sort-Object -Property CreationTimeUtc, Name)
  if ($files.Count -eq 0) { Write-FixLine "No undo records in $dir"; return 0 }
  foreach ($f in $files) {
    $why = Test-FixRecordTrusted $f.FullName
    if ($why) { Write-FixLine "$($f.FullName): not trusted ($why)" 'DarkYellow'; continue }
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

# -Undo <file> is read from the remaining arguments, so a missing file name is a usage error (exit 2), not a binder error.
# Returns @{ Path; Rest; Error }.
function Get-UndoArg([string[]]$Rest) {
  $out = @(); $path = $null; $err = ''; $a = @($Rest | Where-Object { $null -ne $_ -and "$_" -ne '' })   # PowerShell 7 can hand over one empty element
  for ($i = 0; $i -lt $a.Count; $i++) {
    if ($a[$i] -match '^-(?i:undo)$') {
      if ($null -ne $path) { $err = '-Undo given twice' }
      elseif ($i + 1 -ge $a.Count -or "$($a[$i + 1])" -eq '' -or "$($a[$i + 1])".StartsWith('-')) { $err = '-Undo needs a record file' }
      else { $path = $a[$i + 1]; $i++ }
    } else { $out += $a[$i] }
  }
  return @{ Path = $path; Rest = $out; Error = $err }
}

# ---------- main ----------

if ($env:LANQ_MAKEREADY_FIX_LIB -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
$Usage = 'usage: lanq-makeready-fix.ps1 [-WhatIf | -Undo <record file> | -List]   (no -Yes or -Force: every change is confirmed one by one)'
$ua = Get-UndoArg $Extra
if ($ua.Error) { [Console]::Error.WriteLine("lanq-makeready-fix: $($ua.Error)"); [Console]::Error.WriteLine($Usage); exit 2 }
if (@($ua.Rest).Count -gt 0) { [Console]::Error.WriteLine("lanq-makeready-fix: unknown argument(s): $(@($ua.Rest) -join ' ')"); [Console]::Error.WriteLine($Usage); exit 2 }
if ($Help) { Write-Host $Usage; exit 0 }
$mode = 'apply'; $n = 0
if ($WhatIf) { $mode = 'dry'; $n++ }
if ($null -ne $ua.Path) { $mode = 'undo'; $n++ }
if ($List) { $mode = 'list'; $n++ }
if ($n -gt 1) { [Console]::Error.WriteLine('lanq-makeready-fix: use only one of -WhatIf, -Undo and -List'); exit 2 }
$fromFile = Test-FixFromFile $FixInvocation
$why = Get-FixRefusal $mode $fromFile
if ($why) { [Console]::Error.WriteLine("lanq-makeready-fix: $why"); exit 3 }
if ($env:LANQ_MAKEREADY_FIX_LIB -eq '1') { [Console]::Error.WriteLine('lanq-makeready-fix: LANQ_MAKEREADY_FIX_LIB=1 is only for tests that dot-source this file; unset it.'); exit 2 }
exit (Invoke-FixMain -Mode $mode -UndoPath "$($ua.Path)" -FromFile $fromFile)
