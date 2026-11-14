<#
.SYNOPSIS
  lanq-makeready-fix: applies a short list of reversible fixes for what lanq-makeready (and, with -Tune, the tune scan
  lanq-makeready-tune.ps1) reports, one at a time, each only after you confirm it at this PC.
.DESCRIPTION
  The scanners (lanq-makeready.ps1, lanq-makeready-tune.ps1) never change anything. This separate script changes only
  what you confirm:
  - it refuses to run over SSH, from stdin or a string ([scriptblock]::Create, iex), or without an interactive console
    (-WhatIf and -List need no console);
  - there is no -Yes or -Force: each fix is shown (check, current state, exact command, undo) and asked with
    "Apply? [y/N]"; anything but y or yes is no;
  - it never elevates itself: without an elevated prompt every fix is skipped with a note;
  - before each change it writes the undo record %ProgramData%\lanq-makeready\fix-<UTC time>.json (schema
    lanq-makeready-fix/v1) in a folder only Administrators and SYSTEM may change, and -Undo <file> puts the changes
    back, newest first, again confirming each.
  Fixes (v1): ssh.start, ssh.auto, power.sleep, longpaths.on, git.longpaths, ssh.aclkeys.
  Tune fixes (-Tune): power.cpu, power.usbsuspend, startup.vendor, vendor.services, vendor.tasks, sysmain, do.mode,
  dotnet.env, defender.scantime (needs -Hours). Defender exclusions (-Tune -DefenderExclusions): defender.exclude for
  work_root (-WorkRoot) and the NuGet packages folder only.
  Exit code: 0 = done or nothing to do, 1 = a change failed or did not verify, 2 = bad arguments or a rejected record,
  3 = refused (over SSH, from stdin, no interactive console).
.PARAMETER WhatIf
  Dry run: show every applicable fix and its undo; change nothing.
.PARAMETER List
  List the undo records in %ProgramData%\lanq-makeready (needs an elevated PowerShell to read them).
.PARAMETER Tune
  Offer the tune fixes instead of the readiness fixes. -Hours HH:mm-HH:mm gives the job window (defender.scantime).
.PARAMETER DefenderExclusions
  With -Tune: offer only Defender exclusions for work_root (-WorkRoot C:/lq) and the NuGet packages folder.
.NOTES
  -Undo <record file>: undo the changes in that record, newest first, confirming each.
#>
# lanq-makeready-fix-marker (identifies this file; the script refuses to run when it was not started from a file)
[CmdletBinding(PositionalBinding = $false)]
param([switch]$WhatIf, [switch]$List, [switch]$Help, [switch]$Tune, [switch]$DefenderExclusions, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra)

$FixInvocation = $MyInvocation
$ToolVersion = '0.5.0'
$RecordSchema = 'lanq-makeready-fix/v1'
$BaseFixIds = @('ssh.start', 'ssh.auto', 'power.sleep', 'longpaths.on', 'git.longpaths', 'ssh.aclkeys')
$TuneFixIds = @('power.cpu', 'power.usbsuspend', 'startup.vendor', 'vendor.services', 'vendor.tasks', 'sysmain', 'do.mode', 'dotnet.env', 'defender.scantime', 'defender.exclude')
$FixIds = $BaseFixIds + $TuneFixIds   # every id a record may hold (an older script rejects a record with a newer id)
# check id in the scanner's report, and what is wrong
$FixInfo = @{
  'ssh.start'     = @('ssh.server', 'OpenSSH Server is installed but not running')
  'ssh.auto'      = @('ssh.server', 'sshd does not start by itself after a reboot')
  'power.sleep'   = @('power.sleep', 'the PC sleeps or hibernates on AC power')
  'longpaths.on'  = @('longpaths', 'Windows long paths are off')
  'git.longpaths' = @('git', 'git core.longpaths is not on')
  'ssh.aclkeys'   = @('ssh.keys', 'administrators_authorized_keys may be changed by others than Administrators and SYSTEM, so sshd ignores it')
  'power.cpu'         = @('power.plan', 'the processor is held below 100%, or never clocks down, on AC')
  'power.usbsuspend'  = @('power.usbsuspend', 'USB selective suspend may suspend the USB network adapter')
  'startup.vendor'    = @('startup.vendor', 'a PC-maker updater or assistant starts at logon')
  'vendor.services'   = @('vendor.services', 'a PC-maker updater, assistant or telemetry service is enabled')
  'vendor.tasks'      = @('vendor.tasks', 'a PC-maker updater or assistant task is enabled')
  'sysmain'           = @('sysmain', 'SysMain runs while every disk is an SSD')
  'do.mode'           = @('do.mode', 'Delivery Optimization shares update files with other PCs')
  'dotnet.env'        = @('dotnet.env', '.NET telemetry, first-run banner and dev-certificate variables are not set for the machine')
  'defender.scantime' = @('defender.schedule', 'the Defender scheduled scan falls inside the job window')
  'defender.exclude'  = @('defender.paths', 'Defender real-time scanning covers a build folder')
}
# Curated OEM updater / assistant / telemetry names (services, scheduled tasks, Run entries). Generic across makers,
# changed only by reviewed pull requests. The same list is in lanq-makeready-tune.ps1 (a test keeps them identical).
# Every entry is a case-insensitive regex with a literal name in it: no bare wildcards.
$VendorPatterns = @(
  '^Dell ?SupportAssist', '^SupportAssist', '^Dell ?(Update|Command ?Update|Digital ?Delivery|Data ?Vault|TechHub|Optimizer|Core ?Services)', '^DDV(DataCollector|RulesProcessor|CollectorSvcApi)$',
  '^HP ?(Support ?Assistant|Support ?Solutions|Analytics|App ?Helper|Diagnostics|Insights|Touchpoint|System ?Info|Network ?Cap|Comm ?Recovery|JumpStart)', '^HP(AppHelperCap|DiagsCap|NetworkCap|SysInfoCap)$', '^HpTouchpointAnalyticsService$',
  '^Lenovo ?(Vantage|Service ?Bridge|Smart ?Standby|Utility|Welcome|System ?Update)', '^ImControllerService$', '^LITSSVC$',
  '^ASUS ?(Optimization|Software ?Manager|System ?Analysis|System ?Diagnosis|Link|Update|App ?Service)', '^ArmouryCrate', '^AsusUpdateCheck$',
  '^Acer ?(Quick ?Access|Care ?Center|Jumpstart|Collection|Product ?Registration)', '^MSI ?(Center|Dragon ?Center)', '^Samsung ?(Update|Settings)',
  '^Intel\(R\) ?(Driver ?(&|and) ?Support|Computing ?Improvement)', '^DSA(Update)?Service$', '^NvTelemetryContainer$', '^NVIDIA ?(GeForce ?Experience|Telemetry)'
)
# APPEND-ONLY: undo accepts a name that matches $VendorPatterns or one of these. A pattern removed from the list above
# moves here (never deleted), so records written by an older version can still be undone.
$VendorRetiredPatterns = @()
# Every function this file defines; an alias with one of these names (or of a command a fix runs) would run instead.
$FixFunctionNames = @('Write-FixLine', 'Write-FixErr', 'Get-FixSessionId', 'Get-FixProcessTable', 'Get-AncestorNames', 'Test-FixOverSsh', 'Test-FixFromFile',
  'Test-FixConsole', 'Read-FixAnswer', 'Test-Yes', 'Confirm-Fix', 'Test-FixElevated', 'Get-FixCommandShadow', 'Get-FixRefusal', 'Invoke-Native', 'Get-PowercfgAcSeconds',
  'Find-Git', 'Get-PathGit', 'Test-OnlyAdminsSystem', 'ConvertFrom-Sddl', 'Test-SafeRestoreDacl', 'Get-DaclCore', 'Get-RestoreDacl', 'Format-Dacl', 'Test-TrustedSddl',
  'Get-AuthKeySummary', 'Get-FixState', 'ConvertFrom-StateText', 'Get-StateText', 'Test-SameState', 'Get-FixNote', 'Test-FixNeeded', 'Test-FixDone', 'Get-ExpectedAfter',
  'Get-StateSummary', 'Get-FixCommand', 'Assert-Native', 'Invoke-FixChange', 'Get-FixRecordDir', 'Get-UtcStamp', 'Get-SafeWord', 'Get-AccountName', 'Test-SafeUndoDacl', 'Get-ExplicitOthers', 'New-FixSecuredDir', 'New-FixSecuredFile',
  'Get-FixRecordDirProblem', 'Get-PathSddl',
  'Test-FixRecordDirTrusted', 'Initialize-FixRecordDir', 'Test-FixRecordTrusted', 'New-FixRecord', 'ConvertTo-JsonText', 'ConvertTo-FixJson', 'Save-FixRecord',
  'Test-Props', 'Test-Str', 'ConvertTo-TimeText', 'New-RecordError', 'Read-FixRecord', 'Show-Fix', 'Invoke-FixApply', 'Invoke-FixUndo', 'Show-FixRecords', 'Invoke-FixMain',
  'Get-UndoArg', 'Test-Vendor', 'Test-VendorUndo', 'Test-InWindow', 'Get-HoursMin', 'Format-Min', 'Get-RegVal', 'Get-RegNames', 'Test-RegKey', 'Get-UserSid', 'Get-ActiveScheme',
  'Get-PowerAc', 'Test-UsbNic', 'Test-FixAllSsd', 'Get-SvcState', 'Get-TaskState', 'Get-StartupState', 'Get-DefenderInfo', 'ConvertTo-Minutes', 'Get-ExcludeState',
  'Get-DotnetState', 'Get-DoState', 'Get-FixTargets', 'Get-StateTarget', 'Get-UndoRefusal', 'Get-TargetLabel', 'Get-ScanTarget', 'Get-SvcNorm', 'Get-FixApplyNote', 'Get-TuneArgError', 'Get-NugetDir', 'Get-ConsoleUserSid', 'Get-ProtectedDirs', 'Get-BuildDirProblem')
# Every cmdlet this file runs. A function or alias with one of these names would run instead of the cmdlet, so the
# script refuses to start when any of them does not resolve to the cmdlet itself (Get-FixCommandShadow).
$FixCmdletNames = @('Get-Service', 'Set-Service', 'Start-Service', 'Stop-Service', 'Get-Item', 'Set-ItemProperty', 'Remove-ItemProperty', 'Get-Acl', 'Set-Acl',
  'Get-Content', 'Get-ChildItem', 'Test-Path', 'Join-Path', 'Split-Path', 'Get-Command', 'Get-CimInstance', 'Select-Object', 'Where-Object', 'ForEach-Object', 'Sort-Object',
  'ConvertFrom-Json', 'Write-Host', 'New-Object', 'Get-Location', 'Get-Alias', 'New-Item')
# Commands from Windows modules (CDXML functions, not cmdlets) the tune fixes run, and the module each must come from:
# a function or alias of the same name from anywhere else would run instead, so the script refuses then too.
$FixModuleCmds = @{ 'Get-NetAdapter' = @('NetAdapter'); 'Get-PhysicalDisk' = @('Storage'); 'Get-ScheduledTask' = @('ScheduledTasks'); 'Disable-ScheduledTask' = @('ScheduledTasks')
  'Enable-ScheduledTask' = @('ScheduledTasks'); 'Get-MpComputerStatus' = @('ConfigDefender', 'Defender'); 'Get-MpPreference' = @('ConfigDefender', 'Defender')
  'Set-MpPreference' = @('ConfigDefender', 'Defender'); 'Add-MpPreference' = @('ConfigDefender', 'Defender'); 'Remove-MpPreference' = @('ConfigDefender', 'Defender') }
$FixSet = 'base'      # base (readiness fixes), tune, or defender (-Tune -DefenderExclusions)
$FixHours = ''        # -Hours HH:mm-HH:mm (tune: defender.scantime)
$FixWorkRoot = ''     # -WorkRoot C:/lq (defender.exclude)
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
# Tune: fixed names, never taken from a record file (names and paths in a record are checked against these shapes).
$ScExe = Join-Path $SysDir 'sc.exe'
$SvcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$DoKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
$DoSettingKey = 'Registry::HKEY_USERS\S-1-5-20\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings'
$EnvKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$UsbSub = '2a737441-1930-4402-8d77-b2bebba308a3'; $UsbSet = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$RunSources = @{
  'HKCU|Run'   = @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run')
  'HKLM|Run'   = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run')
  'HKLM|Run32' = @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32')
}
$DisabledFlag = '030000000000000000000000'   # StartupApproved: first byte odd = disabled (what Task Manager writes, time zeroed)
$DotnetVars = [ordered]@{ telemetry = @('DOTNET_CLI_TELEMETRY_OPTOUT', '1'); nologo = @('DOTNET_NOLOGO', '1'); aspnetcert = @('DOTNET_GENERATE_ASPNET_CERTIFICATE', 'false') }
$StartWord = @{ 0 = 'boot'; 1 = 'system'; 2 = 'auto'; 3 = 'demand'; 4 = 'disabled' }
$GuidRe = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
$NameRe = '[A-Za-z0-9._()&+{}-][A-Za-z0-9 ._()&+{}-]{0,95}'
$SvcRe = '[A-Za-z0-9_.-]{1,64}'
$TaskPathRe = '\\(?:[A-Za-z0-9 ._()&+-]{1,64}\\){0,4}'
$SidRe = 'S-1-5(?:-[0-9]{1,10}){1,14}'
$WinPathRe = '[A-Za-z]:(?:\\[A-Za-z0-9 _.()-]{1,64}){1,16}'
$DefenderScreen = @(
  '',
  'Defender exclusions: read this first.',
  '  - A Dev Drive is the better choice: on Windows 11 a Dev Drive in performance mode keeps real-time protection on and',
  '    scans asynchronously. Settings > System > Storage > Disks & volumes > Create Dev Drive; put work_root and',
  '    NUGET_PACKAGES there. Prefer it to an exclusion when you can.',
  '  - An exclusion is a trade-off: nothing in that folder is ever scanned in real time, so a malicious package or build',
  '    output there is not caught. Only folder paths are offered (never processes), only work_root plus the NuGet package',
  '    cache (never temp, never a drive or system folder; the cache only for the account at the console), and a folder already covered by an exclusion is skipped.',
  '  - Each one is recorded; -Undo removes exactly the paths this script added.')

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
  if ($FixSet -ne 'base') {   # module commands (only the tune fixes use them; looking them up loads their modules)
    foreach ($n in $FixModuleCmds.Keys) {
      $c = @(Microsoft.PowerShell.Core\Get-Command -Name $n -ErrorAction SilentlyContinue)
      if ($c.Count -gt 0 -and (@('Function', 'Cmdlet') -notcontains "$($c[0].CommandType)" -or @($FixModuleCmds[$n]) -notcontains "$($c[0].ModuleName)")) { $bad += $n }
    }
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

# ---------- tune: reads only ----------

function Test-Vendor([string]$Name) { foreach ($p in $VendorPatterns) { if ($Name -match $p) { return $true } }; return $false }
# Undo: the name still has its shape and matches the current list or an append-only retired entry.
function Test-VendorUndo([string]$Name) { foreach ($p in @($VendorPatterns) + @($VendorRetiredPatterns)) { if ($Name -match $p) { return $true } }; return $false }
function Get-HoursMin([string]$T) { $p = $T.Split(':'); return ([int]$p[0] * 60 + [int]$p[1]) }
function Test-InWindow([int]$M, [string]$H) {
  $w = $H.Split('-'); $a = Get-HoursMin $w[0]; $e = Get-HoursMin $w[1]
  if ($a -lt $e) { return ($M -ge $a -and $M -lt $e) }
  return ($M -ge $a -or $M -lt $e)
}
function Format-Min([int]$M) { return ('{0:00}:{1:00}:00' -f [math]::Floor($M / 60), ($M % 60)) }

# A registry value: @{ Has = $true; Kind; Value }, @{ Has = $false } when the key or value is absent, @{ Has = $null } when unreadable.
function Get-RegVal([string]$Path, [string]$Name) {
  if (-not (Test-RegKey $Path)) { return @{ Has = $false } }
  try {
    $k = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (@($k.GetValueNames()) -notcontains $Name) { return @{ Has = $false } }
    return @{ Has = $true; Kind = "$($k.GetValueKind($Name))"; Value = $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') }
  } catch { return @{ Has = $null } }
}
function Get-RegNames([string]$Path) { try { return @((Get-Item -LiteralPath $Path -ErrorAction Stop).GetValueNames() | Where-Object { $_ }) } catch { return @() } }
function Test-RegKey([string]$Path) { return [bool](Test-Path -LiteralPath $Path) }
function Get-UserSid { try { return "$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)" } catch { return '' } }

function Get-ActiveScheme {
  $r = Invoke-Native $PowercfgExe @('/getactivescheme')
  if ($r.Code -eq 0 -and "$($r.Out)" -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1].ToLowerInvariant() }
  return $null
}
function Get-PowerAc([string]$Sub, [string]$Setting) { $r = Invoke-Native $PowercfgExe @('/q', 'SCHEME_CURRENT', $Sub, $Setting); if ($r.Code -eq 0) { return (Get-PowercfgAcSeconds $r.Out) }; return $null }
function Test-UsbNic { try { return (@(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { "$($_.Status)" -eq 'Up' -and "$($_.PnPDeviceID)" -like 'USB\*' }).Count -gt 0) } catch { return $null } }
# Every fixed physical disk is an SSD (MediaType Unspecified counts as unknown, never as SSD); $null when unreadable.
function Test-FixAllSsd {
  try { $d = @(Get-PhysicalDisk -ErrorAction Stop | Where-Object { @('USB', 'File Backed Virtual', 'Virtual') -notcontains "$($_.BusType)" }) } catch { return $null }
  return ($d.Count -gt 0 -and @($d | Where-Object { "$($_.MediaType)" -ne 'SSD' }).Count -eq 0)
}

# A service's start type and delayed flag from the registry (PowerShell 5.1 cannot read Delayed Start).
function Get-SvcState([string]$Name) {
  if ($Name -cnotmatch "^$SvcRe$" -or -not (Test-RegKey "$SvcKey\$Name")) { return @{ Name = $Name; Exists = $false } }
  $st = Get-RegVal "$SvcKey\$Name" 'Start'; $dl = Get-RegVal "$SvcKey\$Name" 'DelayedAutostart'; $dn = "$(@(Get-Service -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1).DisplayName)"
  $start = $null; if ($st.Has -and $st.Kind -eq 'DWord' -and @(0, 1, 2, 3, 4) -contains [int]$st.Value) { $start = [int]$st.Value }
  $del = 0; if ($dl.Has -and $dl.Kind -eq 'DWord' -and [int]$dl.Value -eq 1) { $del = 1 }
  return @{ Name = $Name; Exists = ($null -ne $start); Start = $start; Delayed = $del; Display = $dn }
}
# delayed only matters for an automatic service: compared as 0 otherwise.
function Get-SvcNorm([string]$T) { if ($T -cmatch '^start=([0-4]) delayed=[01] (name=.*)$' -and $Matches[1] -ne '2') { return "start=$($Matches[1]) delayed=0 $($Matches[2])" }; return $T }

function Get-TaskState([string]$Path, [string]$Name) {
  if ($Path -cnotmatch "^$TaskPathRe$" -or $Path -like '\Microsoft\*' -or $Name -cnotmatch "^$NameRe$") { return @{ Path = $Path; Name = $Name; Exists = $false } }
  try { $t = @(Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop) } catch { return @{ Path = $Path; Name = $Name; Exists = $null } }
  if ($t.Count -ne 1) { return @{ Path = $Path; Name = $Name; Exists = $null } }
  return @{ Path = $Path; Name = $Name; Exists = $true; Enabled = ("$($t[0].State)" -ne 'Disabled') }
}

# A Run entry and its StartupApproved flag ('-' = no flag value, which means enabled).
function Get-StartupState([string]$Target) {
  $p = $Target.Split('|'); $src = $RunSources["$($p[0])|$($p[1])"]; $nm = ''; if ($p.Count -gt 2) { $nm = $p[2..($p.Count - 1)] -join '|' }
  $s = @{ Hive = $p[0]; Key = $p[1]; Name = $nm; Sid = (Get-UserSid); RunHas = $false; Exe = ''; Flag = $null; Enabled = $false }
  if (-not $src) { return $s }
  $run = Get-RegVal $src[0] $s.Name; $s.RunHas = [bool]$run.Has
  if ($run.Has) { $s.Exe = ("$($run.Value)" -replace '^\s*"?([^"]*?\.exe).*$', '$1') -replace '^.*\\', '' }
  $f = Get-RegVal $src[1] $s.Name
  if ($f.Has -eq $false) { $s.Flag = '-'; $s.Enabled = $true }
  elseif ($f.Has -and $f.Kind -eq 'Binary' -and @($f.Value).Count -eq 12) { $s.Flag = (@($f.Value | ForEach-Object { '{0:x2}' -f $_ }) -join ''); $s.Enabled = ((@($f.Value)[0] -band 1) -eq 0) }
  return $s
}

function ConvertTo-Minutes($V) { if ($V -is [TimeSpan]) { return [int]$V.TotalMinutes }; if ($V -is [DateTime]) { return [int]$V.TimeOfDay.TotalMinutes }; return $null }
# Defender's running mode, schedule and exclusion list (read here only to compare; never printed). $null when unreadable.
function Get-DefenderInfo {
  try { $st = Get-MpComputerStatus -ErrorAction Stop; $pr = Get-MpPreference -ErrorAction Stop } catch { return $null }
  $ex = @($pr.ExclusionPath | Where-Object { $_ }); $readable = -not ($ex.Count -eq 1 -and "$($ex[0])" -match '^N/A')
  if (-not $readable) { $ex = @() }
  return @{ Mode = "$($st.AMRunningMode)"; Tamper = [bool]$st.IsTamperProtected; Readable = $readable; Ex = $ex; Day = [int]$pr.ScanScheduleDay
    Time = (ConvertTo-Minutes $pr.ScanScheduleTime); Quick = (ConvertTo-Minutes $pr.ScanScheduleQuickScanTime) }
}
function Get-ExcludeState([string]$Path) {
  $d = Get-DefenderInfo
  $s = @{ Path = $Path; Known = ($null -ne $d); Mode = ''; Readable = $false; Exact = $false; Covered = $false; Tamper = $false; IsNuget = $false }
  $s.IsNuget = ($Path -ieq (Get-NugetDir) -and $Path -ine "$FixWorkRoot".Replace('/', '\'))
  if (-not $d) { return $s }
  $s.Mode = $d.Mode; $s.Readable = $d.Readable; $s.Tamper = $d.Tamper
  $t = $Path.TrimEnd('\') + '\'
  foreach ($e in $d.Ex) {
    $x = [Environment]::ExpandEnvironmentVariables("$e").TrimEnd('\')   # as Defender does (and the tune scan)
    if ($x -ieq $Path.TrimEnd('\')) { $s.Exact = $true }
    if ($t.StartsWith($x + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $s.Covered = $true }
  }
  return $s
}
function Get-NugetDir { $ng = "$env:USERPROFILE\.nuget\packages"; if ($env:NUGET_PACKAGES) { $ng = "$env:NUGET_PACKAGES" }; return $ng.Replace('/', '\').TrimEnd('\') }
# The account logged on at the console (Win32_ComputerSystem.UserName) as a SID; '' when nobody is or it cannot be read.
function Get-ConsoleUserSid {
  try {
    $n = "$((Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 15 -ErrorAction Stop).UserName)"
    if (-not $n) { return '' }
    return "$((New-Object System.Security.Principal.NTAccount($n)).Translate([System.Security.Principal.SecurityIdentifier]).Value)"
  } catch { return '' }
}
# Folders a build folder must never be, or hold: the Windows, program, shared-data and user folders.
function Get-ProtectedDirs {
  $u = [Environment]::GetFolderPath('UserProfile'); $users = "$u" -replace '\\[^\\]+$', ''
  return @($env:SystemRoot, [Environment]::GetFolderPath('Windows'), [Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'), $env:ProgramW6432,
    [Environment]::GetFolderPath('CommonApplicationData'), $env:ProgramData, $env:PUBLIC, $u, $users, $env:USERPROFILE) | Where-Object { $_ }
}
# '' when $Path may be work_root or a Defender exclusion: a folder on a drive with no '.' or '..' segment, already in
# canonical form (GetFullPath gives it back unchanged), not a drive root, and neither a protected folder nor a parent of one.
function Get-BuildDirProblem([string]$Path) {
  $p = "$Path".Replace('/', '\').TrimEnd('\')
  if ($p -notmatch '^[A-Za-z]:(\\[^\\]+)+$') { return 'it is not a folder on a drive (a whole drive is never used)' }
  foreach ($g in @($p.Split('\'))) { if ($g -eq '.' -or $g -eq '..') { return "it has a '.' or '..' part" }; if ($g -ne $g.Trim() -or $g.EndsWith('.')) { return 'a part of it starts or ends with a space or ends with a dot (Windows drops those)' } }
  $full = ''; try { $full = [System.IO.Path]::GetFullPath($p).TrimEnd('\') } catch { return 'it is not a valid path' }
  if ($full -ine $p) { return "it is not in canonical form (Windows reads it as $full)" }
  foreach ($k in (Get-ProtectedDirs)) {
    $q = "$k".Replace('/', '\').TrimEnd('\')
    if ($q -and ($q -ieq $p -or $q.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase))) { return "it is $q or a folder that holds it (Windows, program, shared-data and user folders are never used)" }
  }
  return ''
}
function Get-DotnetState {
  $s = @{ Readable = (Test-RegKey $EnvKey); Vals = [ordered]@{}; Odd = '' }
  foreach ($k in $DotnetVars.Keys) {
    $v = Get-RegVal $EnvKey $DotnetVars[$k][0]
    if ($v.Has -eq $false) { $s.Vals[$k] = '-' }
    elseif ($v.Has -and @('String', 'ExpandString') -contains $v.Kind -and "$($v.Value)" -match '^[A-Za-z0-9]{1,8}$') { $s.Vals[$k] = "$($v.Value)" }
    else { $s.Vals[$k] = $null; $s.Odd = $DotnetVars[$k][0] }
  }
  return $s
}
function Get-DoState {
  $p = Get-RegVal $DoKey 'DODownloadMode'
  $s = @{ Value = $null; Kind = 'none'; Effective = $null }
  if ($null -eq $p.Has) { $s.Kind = 'unreadable' } elseif ($p.Has) { $s.Kind = "$($p.Kind)"; if ($p.Kind -eq 'DWord') { $s.Value = ([long]$p.Value) -band 4294967295 } }
  $u = Get-RegVal $DoSettingKey 'DownloadMode'; $ed = Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'EditionID'
  if ($null -ne $s.Value) { $s.Effective = $s.Value } elseif ($u.Has -and $u.Kind -eq 'DWord') { $s.Effective = [int]$u.Value } elseif ("$($ed.Value)" -like 'Core*') { $s.Effective = 3 } else { $s.Effective = 1 }
  return $s
}
# The new scan time: an hour after the job window ends.
function Get-ScanTarget([string]$H) { return ((Get-HoursMin $H.Split('-')[1]) + 60) % 1440 }

# The things one fix id may change on this PC: @{ List = targets; Note = why none can be listed }. '' = the single
# thing a fix touches; services, tasks, Run entries and folders are listed (vendor names from the curated list only).
function Get-FixTargets([string]$Id) {
  switch ($Id) {
    'vendor.services' { return @{ List = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { (Test-Vendor $_.Name) -or (Test-Vendor $_.DisplayName) } | ForEach-Object { "$($_.Name)" }); Note = '' } }
    'sysmain' { return @{ List = @('SysMain'); Note = '' } }
    'vendor.tasks' {
      if (@(Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue).Count -eq 0) { return @{ List = @(); Note = 'the ScheduledTasks module is not available on this PC; skipped' } }
      try { $all = @(Get-ScheduledTask -ErrorAction Stop) } catch {
        if ("$($_.Exception.Message)" -match '(?i)denied|0x80070005') { return @{ List = @(); Note = 'the scheduled tasks could not be read (access denied); skipped' } }
        return @{ List = @(); Note = 'the scheduled tasks could not be read; skipped' }
      }
      return @{ List = @($all | Where-Object { "$($_.TaskPath)" -notlike '\Microsoft\*' -and ((Test-Vendor $_.TaskName) -or (Test-Vendor "$($_.TaskPath)".Trim('\'))) } | ForEach-Object { "$($_.TaskPath)|$($_.TaskName)" }); Note = '' }
    }
    'startup.vendor' {
      $l = @(); foreach ($k in @('HKCU|Run', 'HKLM|Run', 'HKLM|Run32')) { foreach ($n in (Get-RegNames $RunSources[$k][0])) { $l += "$k|$n" } }
      return @{ List = @($l | Where-Object { $st = Get-StartupState $_; (Test-Vendor $st.Name) -or (Test-Vendor $st.Exe) }); Note = '' }
    }
    'defender.exclude' {
      $l = @(); if ($FixWorkRoot) { $l += $FixWorkRoot.Replace('/', '\') }
      $l += Get-NugetDir
      return @{ List = $l; Note = '' }
    }
  }
  return @{ List = @(''); Note = '' }
}
# The target a parsed before state belongs to (undo reads the current state of that same thing).
function Get-StateTarget([string]$Id, $B) {
  switch ($Id) {
    'startup.vendor' { return "$($B.Hive)|$($B.Key)|$($B.Name)" }
    { @('vendor.services', 'sysmain') -contains $_ } { return $B.Name }
    'vendor.tasks' { return "$($B.Path)|$($B.Name)" }
    'defender.exclude' { return $B.Path }
  }
  return ''
}
function Get-TargetLabel([string]$Id, $S) {
  switch ($Id) {
    'startup.vendor' { return " $($S.Hive) $($S.Key): $($S.Name)" }
    { @('vendor.services', 'sysmain') -contains $_ } { return " $($S.Name)" }
    'vendor.tasks' { return " $($S.Path)$($S.Name)" }
    'defender.exclude' { return " $($S.Path)" }
  }
  return ''
}
# Why undo leaves an item alone although the record is valid ('' = it may go ahead).
function Get-UndoRefusal([string]$Id, $B) {
  switch ($Id) {
    'startup.vendor' {
      if ($B.Hive -eq 'HKCU' -and $B.Sid -cne (Get-UserSid)) { return "this entry belongs to the account $($B.Sid); undo it as that account (HKCU is per account)" }
      $run = Get-StartupState (Get-StateTarget $Id $B)
      if (-not ((Test-VendorUndo $B.Name) -or ($run.RunHas -and (Test-VendorUndo $run.Exe)))) { return "$($B.Name) is not a known PC-maker name (and its Run entry is gone or runs something else)" }
    }
    'vendor.services' { $sv = Get-SvcState $B.Name; if (-not ((Test-VendorUndo $B.Name) -or (Test-VendorUndo $sv.Display))) { return "$($B.Name) is not a known PC-maker service" } }
    'vendor.tasks' { if (-not ((Test-VendorUndo $B.Name) -or (Test-VendorUndo $B.Path.Trim('\')))) { return "$($B.Path)$($B.Name) is not a known PC-maker task" } }
  }
  return ''
}

# The current state of what one fix touches, as a hashtable. $Target names the service, task, Run entry or folder.
function Get-FixState([string]$Id, [string]$Target = '') {
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
    'power.cpu' { return @{ Scheme = (Get-ActiveScheme); Max = (Get-PowerAc 'SUB_PROCESSOR' 'PROCTHROTTLEMAX'); Min = (Get-PowerAc 'SUB_PROCESSOR' 'PROCTHROTTLEMIN') } }
    'power.usbsuspend' { return @{ Scheme = (Get-ActiveScheme); Usb = (Get-PowerAc $UsbSub $UsbSet); UsbNic = (Test-UsbNic) } }
    'startup.vendor' { return (Get-StartupState $Target) }
    'vendor.services' { return (Get-SvcState $Target) }
    'sysmain' { $s = Get-SvcState 'SysMain'; $s.AllSsd = Test-FixAllSsd; return $s }
    'vendor.tasks' { $p = $Target.Split('|'); return (Get-TaskState $p[0] (($p | Select-Object -Skip 1) -join '|')) }
    'do.mode' { return (Get-DoState) }
    'dotnet.env' { return (Get-DotnetState) }
    'defender.scantime' {
      $d = Get-DefenderInfo
      if (-not $d) { return @{ Known = $false } }
      return @{ Known = $true; Mode = $d.Mode; Day = $d.Day; Time = $d.Time; Quick = $d.Quick }
    }
    'defender.exclude' { return (Get-ExcludeState $Target) }
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
    'power.cpu' {
      if ($Text -cmatch "^scheme=($GuidRe) max=([0-9]{1,3}) min=([0-9]{1,3})$") { $sc = $Matches[1]; $mx = [int]$Matches[2]; $mn = [int]$Matches[3]; if ($mx -le 100 -and $mn -le 100) { return @{ Scheme = $sc; Max = $mx; Min = $mn } } }
      return $null
    }
    'power.usbsuspend' { if ($Text -cmatch "^scheme=($GuidRe) usbsuspend=([01])$") { return @{ Scheme = $Matches[1]; Usb = [int]$Matches[2]; UsbNic = $true } }; return $null }
    'startup.vendor' {
      if ($Text -cmatch "^hive=(HKCU|HKLM) key=(Run|Run32) sid=($SidRe) flag=(-|[0-9a-f]{24}) name=($NameRe)$" -and -not ($Matches[1] -eq 'HKCU' -and $Matches[2] -eq 'Run32')) {
        return @{ Hive = $Matches[1]; Key = $Matches[2]; Sid = $Matches[3]; Flag = $Matches[4]; Name = $Matches[5]; RunHas = $true; Enabled = $true }
      }
      return $null
    }
    { @('vendor.services', 'sysmain') -contains $_ } {
      if ($Text -cmatch "^start=([0-4]) delayed=([01]) name=($SvcRe)$" -and ($Id -ne 'sysmain' -or $Matches[3] -ceq 'SysMain')) { return @{ Exists = $true; Start = [int]$Matches[1]; Delayed = [int]$Matches[2]; Name = $Matches[3] } }
      return $null
    }
    'vendor.tasks' {
      if ($Text -cmatch "^enabled=([01]) path=($TaskPathRe) name=($NameRe)$" -and $Matches[2] -notlike '\Microsoft\*') { return @{ Exists = $true; Enabled = ($Matches[1] -eq '1'); Path = $Matches[2]; Name = $Matches[3] } }
      return $null
    }
    'do.mode' {
      if ($Text -cmatch '^value=([0-9]{1,10}) type=dword$') { $v = [long]$Matches[1]; if ($v -gt 4294967295) { return $null }; return @{ Value = $v; Kind = 'DWord' } }
      if ($Text -ceq 'value=- type=none') { return @{ Value = $null; Kind = 'none' } }
      return $null
    }
    'dotnet.env' {
      if ($Text -cmatch '^telemetry=(-|[A-Za-z0-9]{1,8}) nologo=(-|[A-Za-z0-9]{1,8}) aspnetcert=(-|[A-Za-z0-9]{1,8})$') { return @{ Readable = $true; Odd = ''; Vals = [ordered]@{ telemetry = $Matches[1]; nologo = $Matches[2]; aspnetcert = $Matches[3] } } }
      return $null
    }
    'defender.scantime' {
      if ($Text -cmatch '^day=([0-8]) time=([0-9]{1,4}) quick=([0-9]{1,4})$') { $dy = [int]$Matches[1]; $tm = [int]$Matches[2]; $qk = [int]$Matches[3]; if ($tm -lt 1440 -and $qk -lt 1440) { return @{ Known = $true; Mode = 'Normal'; Day = $dy; Time = $tm; Quick = $qk } } }
      return $null
    }
    'defender.exclude' {
      if ($Text -cmatch "^excluded=([01]) path=($WinPathRe)$" -and $Matches[2] -notmatch '\.\.') { return @{ Known = $true; Readable = $true; Mode = 'Normal'; Exact = ($Matches[1] -eq '1'); Path = $Matches[2] } }
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
    'power.cpu' { if ($S.Scheme -and $null -ne $S.Max -and $null -ne $S.Min) { $t = "scheme=$($S.Scheme) max=$($S.Max) min=$($S.Min)" } }
    'power.usbsuspend' { if ($S.Scheme -and @(0, 1) -contains $S.Usb) { $t = "scheme=$($S.Scheme) usbsuspend=$($S.Usb)" } }
    'startup.vendor' { if ($S.RunHas -and $S.Flag) { $t = "hive=$($S.Hive) key=$($S.Key) sid=$($S.Sid) flag=$($S.Flag) name=$($S.Name)" } }
    { @('vendor.services', 'sysmain') -contains $_ } { if ($S.Exists) { $t = "start=$($S.Start) delayed=$($S.Delayed) name=$($S.Name)" } }
    'vendor.tasks' { if ($S.Exists) { $t = "enabled=$([int][bool]$S.Enabled) path=$($S.Path) name=$($S.Name)" } }
    'do.mode' { if ($S.Kind -eq 'none') { $t = 'value=- type=none' } elseif ($S.Kind -eq 'DWord') { $t = "value=$($S.Value) type=dword" } }
    'dotnet.env' { if ($S.Readable -and -not $S.Odd) { $t = "telemetry=$($S.Vals.telemetry) nologo=$($S.Vals.nologo) aspnetcert=$($S.Vals.aspnetcert)" } }
    'defender.scantime' { if ($S.Known -and $null -ne $S.Time) { $q = 0; if ($S.Quick) { $q = $S.Quick }; $t = "day=$($S.Day) time=$($S.Time) quick=$q" } }
    'defender.exclude' { if ($S.Known -and $S.Readable) { $t = "excluded=$([int][bool]$S.Exact) path=$($S.Path)" } }
  }
  if ($null -eq $t -or $null -eq (ConvertFrom-StateText $Id $t)) { return $null }
  return $t
}

# Two state texts of one fix describe the same state. For the keys file that is the protection flag and the explicit
# entries: inherited entries are re-inherited by Windows, not restored literally. A Run entry's account (sid) is
# checked on its own before undo; a service's delayed flag only counts for an automatic service.
function Test-SameState([string]$Id, [string]$A, [string]$B) {
  if ($Id -eq 'ssh.aclkeys' -and $A.StartsWith('dacl=') -and $B.StartsWith('dacl=')) { return ((Get-DaclCore $A.Substring(5)) -ceq (Get-DaclCore $B.Substring(5))) }
  if ($Id -eq 'startup.vendor') { return (($A -creplace ' sid=\S+', '') -ceq ($B -creplace ' sid=\S+', '')) }
  if (@('vendor.services', 'sysmain') -contains $Id) { return ((Get-SvcNorm $A) -ceq (Get-SvcNorm $B)) }
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
    { @('power.cpu', 'power.usbsuspend') -contains $_ } { if (-not $S.Scheme) { return 'the active power scheme could not be read (powercfg /getactivescheme), so undo could not be tied to it' } }
    'startup.vendor' {
      if ($S.RunHas -and $S.Name -cnotmatch "^$NameRe$") { return "the entry name has characters this script does not record; use Task Manager > Startup apps" }
      if ($S.RunHas -and -not $S.Flag) { return "$($S.Name): its StartupApproved value is not the usual 12-byte flag; use Task Manager > Startup apps" }
    }
    'vendor.services' { if (-not $S.Exists -and $S.Name -cnotmatch "^$SvcRe$") { return "$($S.Name): the service name has characters this script does not record; use services.msc" } }
    'vendor.tasks' {
      if ($null -eq $S.Exists) { return "$($S.Path)$($S.Name) could not be read (access denied); skipped" }
      if (-not $S.Exists) { return "$($S.Path)$($S.Name): the task path or name has characters this script does not record; use taskschd.msc" }
    }
    'do.mode' {
      if ($S.Kind -eq 'DWord' -and $S.Value -ne 0) { return "DODownloadMode is $($S.Value) by a policy (managed by your organization or set by hand); not changed here" }
      if (@('none', 'DWord') -notcontains $S.Kind) { return "DODownloadMode is of type $($S.Kind), not DWORD; not changed here" }
    }
    'dotnet.env' { if ($S.Odd) { return "$($S.Odd) has a value this script does not record (not 1-8 letters or digits); set the variables yourself" } }
    'defender.scantime' {
      if (-not $S.Known) { return 'Defender could not be read (Get-MpPreference)' }
      if ($S.Mode -and $S.Mode -ne 'Normal') { return "Defender is not the active antivirus (AMRunningMode: $($S.Mode))" }
      if (-not $FixHours) { return 'give the job window with -Hours HH:mm-HH:mm to check the scan time against it' }
      if (Test-InWindow (Get-ScanTarget $FixHours) $FixHours) { return "the job window $FixHours leaves no hour after it outside the window; move the scan yourself" }
    }
    'defender.exclude' {
      if (-not $S.Known) { return 'Defender could not be read (Get-MpPreference)' }
      if ($S.Mode -and $S.Mode -ne 'Normal') { return "Defender is not the active antivirus (AMRunningMode: $($S.Mode)); its exclusions do not matter" }
      if (-not $S.Readable) { return 'the exclusion list can only be read elevated' }
      $why = Get-BuildDirProblem $S.Path; if ($why) { return "$($S.Path) is refused: $why" }
      if ($S.Path -cnotmatch "^$WinPathRe$") { return "$($S.Path): this script adds only plain drive paths (letters, digits, space, _ . ( ) -)" }
      if ($S.IsNuget) {
        $cu = Get-ConsoleUserSid
        if (-not $cu -or $cu -cne (Get-UserSid)) { return "the NuGet packages folder ($($S.Path)) comes from this account's profile, and this PowerShell does not run as the account logged on at the console, so it may be the wrong profile. Run the script elevated as the build user at the console, or exclude that user's NuGet folder yourself" }
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
    'power.cpu' { return ($S.Max -lt 100 -or $S.Min -ge 100) }
    'power.usbsuspend' { return ($S.Usb -eq 1 -and $S.UsbNic -eq $true) }
    'startup.vendor' { return ($S.RunHas -and $S.Enabled -and ((Test-Vendor $S.Name) -or (Test-Vendor $S.Exe))) }
    'vendor.services' { return ($S.Start -ne 4 -and ((Test-Vendor $S.Name) -or (Test-Vendor $S.Display))) }
    'sysmain' { return (@(2, 3) -contains $S.Start -and $S.AllSsd -eq $true) }
    'vendor.tasks' { return ($S.Enabled -and ((Test-Vendor $S.Name) -or (Test-Vendor $S.Path.Trim('\')))) }
    'do.mode' { return ($S.Kind -eq 'none' -and @(1, 2, 3) -contains [int]$S.Effective) }
    'dotnet.env' { return (@($S.Vals.Values | Where-Object { $_ -eq '-' }).Count -gt 0) }
    'defender.scantime' { return ($S.Day -ne 8 -and ((Test-InWindow $S.Time $FixHours) -or ($S.Quick -gt 0 -and (Test-InWindow $S.Quick $FixHours)))) }
    'defender.exclude' { return (-not $S.Covered) }
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
    'power.cpu' { return ($S.Max -eq 100 -and $S.Min -lt 100) }
    'power.usbsuspend' { return ($S.Usb -eq 0) }
    'startup.vendor' { return ($S.Flag -ceq $DisabledFlag) }
    { @('vendor.services', 'sysmain') -contains $_ } { return ($S.Start -eq 4) }
    'vendor.tasks' { return ($S.Exists -and -not $S.Enabled) }
    'do.mode' { return ($S.Kind -eq 'DWord' -and $S.Value -eq 0) }
    'dotnet.env' { return ($S.Readable -and @($S.Vals.Values | Where-Object { $_ -eq '-' -or $null -eq $_ }).Count -eq 0) }
    'defender.scantime' { return ($S.Known -and -not (Test-InWindow $S.Time $FixHours) -and -not ($S.Quick -gt 0 -and (Test-InWindow $S.Quick $FixHours))) }
    'defender.exclude' { return ($S.Exact -eq $true) }
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
    'power.cpu' { $mn = $S.Min; if ($mn -ge 100) { $mn = 5 }; return "scheme=$($S.Scheme) max=100 min=$mn" }
    'power.usbsuspend' { return "scheme=$($S.Scheme) usbsuspend=0" }
    'startup.vendor' { return "hive=$($S.Hive) key=$($S.Key) sid=$($S.Sid) flag=$DisabledFlag name=$($S.Name)" }
    { @('vendor.services', 'sysmain') -contains $_ } { return "start=4 delayed=$($S.Delayed) name=$($S.Name)" }
    'vendor.tasks' { return "enabled=0 path=$($S.Path) name=$($S.Name)" }
    'do.mode' { return 'value=0 type=dword' }
    'dotnet.env' { $t = @(foreach ($k in $DotnetVars.Keys) { $x = $S.Vals[$k]; if ($x -eq '-') { $x = $DotnetVars[$k][1] }; "$k=$x" }); return ($t -join ' ') }
    'defender.scantime' {
      $n = Get-ScanTarget $FixHours; $q = $S.Quick; if ($q -gt 0 -and (Test-InWindow $q $FixHours)) { $q = $n }
      $tm = $S.Time; if (Test-InWindow $tm $FixHours) { $tm = $n }; return "day=$($S.Day) time=$tm quick=$q"
    }
    'defender.exclude' { return "excluded=1 path=$($S.Path)" }
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
    'power.cpu' { return "power scheme $($S.Scheme): processor maximum $($S.Max)%, minimum $($S.Min)% on AC" }
    'power.usbsuspend' { $o = 'off'; if ($S.Usb -eq 1) { $o = 'on' }; return "power scheme $($S.Scheme): USB selective suspend $o on AC; a network adapter in use is on USB" }
    'startup.vendor' { $f = 'no flag (enabled)'; if ($S.Flag -ne '-') { $f = "flag $($S.Flag)" }; return "$($S.Hive) $($S.Key) entry '$($S.Name)' ($($S.Exe)), StartupApproved $f" }
    { @('vendor.services', 'sysmain') -contains $_ } { $d = ''; if ($S.Start -eq 2 -and $S.Delayed -eq 1) { $d = ' (delayed)' }; return "service $($S.Name) ($($S.Display)): start $($StartWord[[int]$S.Start])$d" }
    'vendor.tasks' { $e = 'disabled'; if ($S.Enabled) { $e = 'enabled' }; return "task $($S.Path)$($S.Name) is $e" }
    'do.mode' { $p = 'not set'; if ($null -ne $S.Value) { $p = "$($S.Value)" }; return "policy DODownloadMode: $p; download mode in effect: $($S.Effective) (1 = LAN peers, 2 = group, 3 = internet peers)" }
    'dotnet.env' { return (@($DotnetVars.Keys | ForEach-Object { "$($DotnetVars[$_][0])=$($S.Vals[$_])" }) -join ', ') + ' (- = not set) for the machine' }
    'defender.scantime' { return "scheduled scan day $($S.Day) (0 = every day, 8 = never) at $(Format-Min $S.Time); daily quick scan at $(Format-Min ([int]$S.Quick)) (00:00:00 = none); job window $FixHours" }
    'defender.exclude' { $e = 'scanned in real time'; if ($S.Exact) { $e = 'excluded' }; return "$($S.Path) is $e" }
  }
  return ''
}

# What to say after a tune change was applied and verified ('' = nothing).
function Get-FixApplyNote([string]$Id, $S) {
  switch ($Id) {
    { @('vendor.services', 'sysmain') -contains $_ } { return "note: it stops at the next restart (or now: Stop-Service -Name $($S.Name))" }
    'vendor.tasks' { return 'note: updaters often enable their tasks again when they update themselves; run the tune scan again later' }
    'do.mode' { return 'note: Settings now shows "managed by your organization" for Delivery Optimization' }
    'dotnet.env' { return 'note: new processes see it; restart sshd (Restart-Service sshd) so new SSH sessions do, and sign out and in for this desktop' }
    'defender.exclude' { if ($S.Tamper) { return 'note: Tamper Protection is on; if an organization manages Defender, its policy may remove the exclusion' } }
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
    'power.cpu|apply' {
      if ($B.Max -lt 100) { $cmd += 'powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100' }; if ($B.Min -ge 100) { $cmd += 'powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5' }
      $cmd += 'powercfg /setactive SCHEME_CURRENT'
    }
    'power.cpu|undo' { $cmd = @("powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX $($B.Max)", "powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN $($B.Min)", 'powercfg /setactive SCHEME_CURRENT') }
    'power.usbsuspend|apply' { $cmd = @("powercfg /setacvalueindex SCHEME_CURRENT $UsbSub $UsbSet 0", 'powercfg /setactive SCHEME_CURRENT') }
    'power.usbsuspend|undo' { $cmd = @("powercfg /setacvalueindex SCHEME_CURRENT $UsbSub $UsbSet $($B.Usb)", 'powercfg /setactive SCHEME_CURRENT') }
    'startup.vendor|apply' { $cmd = @("Set-ItemProperty -LiteralPath '$($RunSources["$($B.Hive)|$($B.Key)"][1])' -Name '$($B.Name)' -Type Binary -Value 3,0,0,0,0,0,0,0,0,0,0,0   (as Task Manager > Disable; the key is created first when missing)") }
    'startup.vendor|undo' {
      $k = $RunSources["$($B.Hive)|$($B.Key)"][1]
      if ($B.Flag -eq '-') { $cmd = @("Remove-ItemProperty -LiteralPath '$k' -Name '$($B.Name)'") } else { $cmd = @("Set-ItemProperty -LiteralPath '$k' -Name '$($B.Name)' -Type Binary -Value 0x$($B.Flag)") }
    }
    { @('vendor.services|apply', 'sysmain|apply') -contains $_ } { $cmd = @("sc.exe config $($B.Name) start= disabled") }
    { @('vendor.services|undo', 'sysmain|undo') -contains $_ } { $w = $StartWord[[int]$B.Start]; if ($B.Start -eq 2 -and $B.Delayed -eq 1) { $w = 'delayed-auto' }; $cmd = @("sc.exe config $($B.Name) start= $w") }
    'vendor.tasks|apply' { $cmd = @("Disable-ScheduledTask -TaskPath '$($B.Path)' -TaskName '$($B.Name)'") }
    'vendor.tasks|undo' { if ($B.Enabled) { $cmd = @("Enable-ScheduledTask -TaskPath '$($B.Path)' -TaskName '$($B.Name)'") } }
    'do.mode|apply' { $cmd = @("New-Item -Path '$DoKey' -Force   (only when the key is missing)", "Set-ItemProperty -LiteralPath '$DoKey' -Name DODownloadMode -Value 0 -Type DWord") }
    'do.mode|undo' { if ($null -eq $B.Value) { $cmd = @("Remove-ItemProperty -LiteralPath '$DoKey' -Name DODownloadMode") } else { $cmd = @("Set-ItemProperty -LiteralPath '$DoKey' -Name DODownloadMode -Value $($B.Value) -Type DWord") } }
    'dotnet.env|apply' { foreach ($k in $DotnetVars.Keys) { if ($B.Vals[$k] -eq '-') { $cmd += "Set-ItemProperty -LiteralPath '$EnvKey' -Name $($DotnetVars[$k][0]) -Value $($DotnetVars[$k][1]) -Type String" } } }
    'dotnet.env|undo' { foreach ($k in $DotnetVars.Keys) { if ($B.Vals[$k] -eq '-') { $cmd += "Remove-ItemProperty -LiteralPath '$EnvKey' -Name $($DotnetVars[$k][0])" } } }
    'defender.scantime|apply' {
      $n = Format-Min (Get-ScanTarget $FixHours); $o = ''
      if (Test-InWindow $B.Time $FixHours) { $o += " -ScanScheduleTime $n" }; if ($B.Quick -gt 0 -and (Test-InWindow $B.Quick $FixHours)) { $o += " -ScanScheduleQuickScanTime $n" }
      $cmd = @("Set-MpPreference$o")
    }
    'defender.scantime|undo' { $cmd = @("Set-MpPreference -ScanScheduleTime $(Format-Min $B.Time) -ScanScheduleQuickScanTime $(Format-Min $B.Quick)") }
    'defender.exclude|apply' { $cmd = @("Add-MpPreference -ExclusionPath '$($B.Path)'") }
    'defender.exclude|undo' { if (-not $B.Exact) { $cmd = @("Remove-MpPreference -ExclusionPath '$($B.Path)'") } }
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
    'power.cpu|apply' {
      if ($B.Max -lt 100) { Assert-Native (Invoke-Native $PowercfgExe @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMAX', '100')) }
      if ($B.Min -ge 100) { Assert-Native (Invoke-Native $PowercfgExe @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMIN', '5')) }
      Assert-Native (Invoke-Native $PowercfgExe @('/setactive', 'SCHEME_CURRENT'))
    }
    'power.cpu|undo' {
      Assert-Native (Invoke-Native $PowercfgExe @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMAX', "$([int]$B.Max)"))
      Assert-Native (Invoke-Native $PowercfgExe @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMIN', "$([int]$B.Min)"))
      Assert-Native (Invoke-Native $PowercfgExe @('/setactive', 'SCHEME_CURRENT'))
    }
    'power.usbsuspend|apply' { Assert-Native (Invoke-Native $PowercfgExe @('/setacvalueindex', 'SCHEME_CURRENT', $UsbSub, $UsbSet, '0')); Assert-Native (Invoke-Native $PowercfgExe @('/setactive', 'SCHEME_CURRENT')) }
    'power.usbsuspend|undo' { Assert-Native (Invoke-Native $PowercfgExe @('/setacvalueindex', 'SCHEME_CURRENT', $UsbSub, $UsbSet, "$([int]$B.Usb)")); Assert-Native (Invoke-Native $PowercfgExe @('/setactive', 'SCHEME_CURRENT')) }
    'startup.vendor|apply' {
      $k = $RunSources["$($B.Hive)|$($B.Key)"][1]
      if (-not (Test-RegKey $k)) { [void](New-Item -Path $k -Force -ErrorAction Stop) }
      Set-ItemProperty -LiteralPath $k -Name $B.Name -Value ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) -Type Binary -ErrorAction Stop
    }
    'startup.vendor|undo' {
      $k = $RunSources["$($B.Hive)|$($B.Key)"][1]
      if ($B.Flag -eq '-') { Remove-ItemProperty -LiteralPath $k -Name $B.Name -ErrorAction Stop }
      else { Set-ItemProperty -LiteralPath $k -Name $B.Name -Value ([byte[]]@(for ($i = 0; $i -lt 24; $i += 2) { [Convert]::ToByte($B.Flag.Substring($i, 2), 16) })) -Type Binary -ErrorAction Stop }
    }
    { @('vendor.services|apply', 'sysmain|apply') -contains $_ } { Assert-Native (Invoke-Native $ScExe @('config', $B.Name, 'start=', 'disabled')) }
    { @('vendor.services|undo', 'sysmain|undo') -contains $_ } {
      $w = $StartWord[[int]$B.Start]; if ($B.Start -eq 2 -and $B.Delayed -eq 1) { $w = 'delayed-auto' }
      Assert-Native (Invoke-Native $ScExe @('config', $B.Name, 'start=', $w))
    }
    'vendor.tasks|apply' { [void](Disable-ScheduledTask -TaskPath $B.Path -TaskName $B.Name -ErrorAction Stop) }
    'vendor.tasks|undo' { if ($B.Enabled) { [void](Enable-ScheduledTask -TaskPath $B.Path -TaskName $B.Name -ErrorAction Stop) } }
    'do.mode|apply' {
      if (-not (Test-RegKey $DoKey)) { [void](New-Item -Path $DoKey -Force -ErrorAction Stop) }
      Set-ItemProperty -LiteralPath $DoKey -Name DODownloadMode -Value 0 -Type DWord -ErrorAction Stop
    }
    'do.mode|undo' {
      if ($null -eq $B.Value) { Remove-ItemProperty -LiteralPath $DoKey -Name DODownloadMode -ErrorAction Stop }
      else { Set-ItemProperty -LiteralPath $DoKey -Name DODownloadMode -Value ([long]$B.Value) -Type DWord -ErrorAction Stop }
    }
    'dotnet.env|apply' { foreach ($k in $DotnetVars.Keys) { if ($B.Vals[$k] -eq '-') { Set-ItemProperty -LiteralPath $EnvKey -Name $DotnetVars[$k][0] -Value $DotnetVars[$k][1] -Type String -ErrorAction Stop } } }
    'dotnet.env|undo' { foreach ($k in $DotnetVars.Keys) { if ($B.Vals[$k] -eq '-') { Remove-ItemProperty -LiteralPath $EnvKey -Name $DotnetVars[$k][0] -ErrorAction Stop } } }
    'defender.scantime|apply' {
      $n = Format-Min (Get-ScanTarget $FixHours)
      if (Test-InWindow $B.Time $FixHours) { Set-MpPreference -ScanScheduleTime $n -ErrorAction Stop }
      if ($B.Quick -gt 0 -and (Test-InWindow $B.Quick $FixHours)) { Set-MpPreference -ScanScheduleQuickScanTime $n -ErrorAction Stop }
    }
    'defender.scantime|undo' { Set-MpPreference -ScanScheduleTime (Format-Min $B.Time) -ScanScheduleQuickScanTime (Format-Min $B.Quick) -ErrorAction Stop }
    'defender.exclude|apply' { Add-MpPreference -ExclusionPath $B.Path -ErrorAction Stop }
    'defender.exclude|undo' { if (-not $B.Exact) { Remove-MpPreference -ExclusionPath $B.Path -ErrorAction Stop } }
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
  Write-FixLine "$Id$(Get-TargetLabel $Id $S)  (check $($FixInfo[$Id][0])): $($FixInfo[$Id][1])" 'Yellow'
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
  $ids = $BaseFixIds
  if ($FixSet -eq 'tune') { $ids = @($TuneFixIds | Where-Object { $_ -ne 'defender.exclude' }); Write-FixLine 'Tune fixes (lanq-makeready-tune.ps1 reports these; none of them changes whether the PC is worker-ready).' }
  elseif ($FixSet -eq 'defender') { $ids = @($TuneFixIds | Where-Object { $_ -eq 'defender.exclude' }); foreach ($l in $DefenderScreen) { Write-FixLine $l 'Yellow' } }
  if ($elev -and -not $Dry) { $why = Get-FixRecordDirProblem; if ($why) { Write-FixErr "lanq-makeready-fix: $why"; return 1 } }
  foreach ($id in $ids) {
   $tg = Get-FixTargets $id
   if ($tg.Note) { Write-FixLine ''; Write-FixLine "$id  (check $($FixInfo[$id][0])): not offered: $($tg.Note)" 'DarkYellow'; continue }
   foreach ($target in @($tg.List)) {
    $s = Get-FixState $id $target
    $note = Get-FixNote $id $s
    if ($note) { Write-FixLine ''; Write-FixLine "$id  (check $($FixInfo[$id][0])): not offered: $note" 'DarkYellow'; continue }
    if (-not (Test-FixNeeded $id $s)) { continue }
    $shown++
    Show-Fix $id $s
    if (-not $elev) { Write-FixLine '  skipped: needs an elevated PowerShell (Run as administrator); this script never elevates itself' 'DarkYellow'; continue }
    if ($Dry) { Write-FixLine '  dry run: not applied'; continue }
    if ($rec -and $rec.Items.Count -ge 64) { Write-FixLine '  not offered: this session''s undo record is full (64 changes); run the script again for the rest' 'DarkYellow'; continue }
    if (-not (Confirm-Fix)) { Write-FixLine '  not applied'; continue }
    $s2 = Get-FixState $id $target   # the precondition, re-read just before the change
    if (-not (Test-FixNeeded $id $s2)) { Write-FixLine '  no longer needed (the state changed); nothing done'; continue }
    $before = Get-StateText $id $s2
    if ($before -cne (Get-StateText $id $s)) { Write-FixLine '  the state changed since it was shown; nothing done (run the script again)' 'DarkYellow'; continue }
    if (-not $rec) { $rec = New-FixRecord }
    $item = [ordered]@{ seq = ($rec.Items.Count + 1); id = $id; status = 'pending'; time = (Get-UtcStamp); before = $before; command = ((Get-FixCommand $id 'apply' $s2 $s2) -join ' ; '); after = (Get-ExpectedAfter $id $s2) }
    [void]$rec.Items.Add($item)
    if (-not (Save-FixRecord $rec)) { Write-FixErr '  nothing changed: the undo record could not be written'; $rec.Items.RemoveAt($rec.Items.Count - 1); return 1 }
    $err = ''
    try { Invoke-FixChange $id 'apply' $s2 $s2 } catch { $err = "$($_.Exception.Message)" }
    $s3 = Get-FixState $id $target
    $after = Get-StateText $id $s3; if (-not $after) { $after = 'unknown' }
    $item.after = $after; $item.time = Get-UtcStamp
    if (-not $err -and (Test-FixDone $id $s3)) { $item.status = 'applied'; Write-FixLine '  applied and verified' 'Green' }
    else { $item.status = 'failed'; $failed++; Write-FixLine "  FAILED: $err (now: $(Get-StateSummary $id $s3)); recorded, so -Undo can put back what changed" 'Red' }
    if (-not (Save-FixRecord $rec)) { $failed++; Write-FixErr "  the record could not be updated after the change; it still says pending: $($rec.Path)" }
    if ($id -eq 'longpaths.on' -and $item.status -eq 'applied') { Write-FixLine '  note: programs started from now on see it; reboot so that every program does' }
    $an = Get-FixApplyNote $id $s2; if ($an -and $item.status -eq 'applied') { Write-FixLine "  $an" }
   }
  }
  if ($shown -eq 0) { Write-FixLine "Nothing to fix here (fixes: $($ids -join ', '))." }
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
    $id = $it.id; $b = ConvertFrom-StateText $id $it.before; $tgt = Get-StateTarget $id $b
    Write-FixLine ''
    Write-FixLine "undo $id$(Get-TargetLabel $id $b)  (check $($FixInfo[$id][0])), $($it.status) at $($it.time)" 'Yellow'
    $no = Get-UndoRefusal $id $b
    if ($no) { Write-FixLine "  left alone: $no" 'DarkYellow'; continue }
    $cur = Get-FixState $id $tgt; $ct = Get-StateText $id $cur
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
    $cur2 = Get-FixState $id $tgt
    $ct2 = Get-StateText $id $cur2
    if (-not $ct2 -or -not (Test-SameState $id $ct2 $it.after)) { Write-FixLine '  changed since; left alone' 'DarkYellow'; continue }
    $err = ''
    try { Invoke-FixChange $id 'undo' $b $cur2 } catch { $err = "$($_.Exception.Message)" }
    $nowState = Get-FixState $id $tgt
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

function Invoke-FixMain([string]$Mode = 'apply', [string]$UndoPath = '', [bool]$FromFile = $false, [string]$Set = 'base', [string]$Hours = '', [string]$WorkRoot = '') {
  $script:FixSet = $Set; $script:FixHours = $Hours; $script:FixWorkRoot = $WorkRoot
  $why = Get-FixRefusal $Mode $FromFile
  if ($why) { Write-FixErr "lanq-makeready-fix: $why"; return 3 }
  if ($Mode -eq 'list') { return (Show-FixRecords) }
  if ($Mode -eq 'undo') { return (Invoke-FixUndo $UndoPath) }
  return (Invoke-FixApply ($Mode -eq 'dry'))
}

# -Undo <file>, -Hours <window> and -WorkRoot <folder> are read from the remaining arguments, so a missing value is a
# usage error (exit 2), not a binder error. Returns @{ Path; Hours; WorkRoot; Rest; Error }.
function Get-UndoArg([string[]]$Rest) {
  $out = @(); $seen = @{ undo = $null; hours = $null; workroot = $null }; $err = ''; $a = @($Rest | Where-Object { $null -ne $_ -and "$_" -ne '' })   # PowerShell 7 can hand over one empty element
  $what = @{ undo = 'a record file'; hours = 'a window like 22:00-07:00'; workroot = 'a folder like C:/lq' }
  for ($i = 0; $i -lt $a.Count; $i++) {
    if ($a[$i] -match '^-(?i:(undo|hours|workroot))$') {
      $k = $Matches[1].ToLowerInvariant(); $nm = @{ undo = '-Undo'; hours = '-Hours'; workroot = '-WorkRoot' }[$k]
      if ($null -ne $seen[$k]) { $err = "$nm given twice" }
      elseif ($i + 1 -ge $a.Count -or "$($a[$i + 1])" -eq '' -or "$($a[$i + 1])".StartsWith('-')) { $err = "$nm needs $($what[$k])" }
      else { $seen[$k] = $a[$i + 1]; $i++ }
    } else { $out += $a[$i] }
  }
  return @{ Path = $seen.undo; Hours = $seen.hours; WorkRoot = $seen.workroot; Rest = $out; Error = $err }
}

# '' when the tune arguments are usable, else the usage error. -WorkRoot follows LanQueue's work_root rule (a drive
# path with forward slashes, letters, digits, _ . / -, no '..'), and is never a whole drive.
function Get-TuneArgError($Ua, [bool]$TuneOn, [bool]$Def, [string]$Mode) {
  if (-not $TuneOn -and ($Def -or $null -ne $Ua.Hours -or $null -ne $Ua.WorkRoot)) { return '-DefenderExclusions, -Hours and -WorkRoot go with -Tune' }
  if ($TuneOn -and @('undo', 'list') -contains $Mode) { return '-Tune goes with -WhatIf or alone; -Undo and -List handle every record' }
  if ($null -ne $Ua.Hours -and ($Ua.Hours -notmatch '^([01]\d|2[0-3]):([0-5]\d)-([01]\d|2[0-3]):([0-5]\d)$' -or $Ua.Hours.Split('-')[0] -eq $Ua.Hours.Split('-')[1])) { return '-Hours must look like 00:00-07:00 (HH:mm-HH:mm, start different from end)' }
  if ($null -ne $Ua.WorkRoot -and ("$($Ua.WorkRoot)".Replace('\', '/') -cnotmatch '^[A-Za-z]:/[A-Za-z0-9_.-][A-Za-z0-9_./-]*$' -or "$($Ua.WorkRoot)" -match '\.\.')) { return '-WorkRoot must be a folder like C:/lq (letters, digits, _ . / -; no spaces, no .., not a whole drive), as in LanQueue machines.yml' }
  if ($null -ne $Ua.WorkRoot) { $why = Get-BuildDirProblem "$($Ua.WorkRoot)"; if ($why) { return "-WorkRoot $($Ua.WorkRoot) is refused: $why" } }
  return ''
}

# ---------- main ----------

if ($env:LANQ_MAKEREADY_FIX_LIB -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
$Usage = 'usage: lanq-makeready-fix.ps1 [-WhatIf | -Undo <record file> | -List] [-Tune [-Hours HH:mm-HH:mm] [-DefenderExclusions -WorkRoot C:/lq]]   (no -Yes or -Force: every change is confirmed one by one)'
$ua = Get-UndoArg $Extra
if ($ua.Error) { [Console]::Error.WriteLine("lanq-makeready-fix: $($ua.Error)"); [Console]::Error.WriteLine($Usage); exit 2 }
if (@($ua.Rest).Count -gt 0) { [Console]::Error.WriteLine("lanq-makeready-fix: unknown argument(s): $(@($ua.Rest) -join ' ')"); [Console]::Error.WriteLine($Usage); exit 2 }
if ($Help) { Write-Host $Usage; exit 0 }
$mode = 'apply'; $n = 0
if ($WhatIf) { $mode = 'dry'; $n++ }
if ($null -ne $ua.Path) { $mode = 'undo'; $n++ }
if ($List) { $mode = 'list'; $n++ }
if ($n -gt 1) { [Console]::Error.WriteLine('lanq-makeready-fix: use only one of -WhatIf, -Undo and -List'); exit 2 }
$te = Get-TuneArgError $ua ([bool]$Tune) ([bool]$DefenderExclusions) $mode
if ($te) { [Console]::Error.WriteLine("lanq-makeready-fix: $te"); [Console]::Error.WriteLine($Usage); exit 2 }
$set = 'base'; if ($Tune) { $set = 'tune'; if ($DefenderExclusions) { $set = 'defender' } }
$FixSet = $set
$wr = ''; if ($ua.WorkRoot) { $wr = "$($ua.WorkRoot)".Replace('\', '/') }
$fromFile = Test-FixFromFile $FixInvocation
$why = Get-FixRefusal $mode $fromFile
if ($why) { [Console]::Error.WriteLine("lanq-makeready-fix: $why"); exit 3 }
if ($env:LANQ_MAKEREADY_FIX_LIB -eq '1') { [Console]::Error.WriteLine('lanq-makeready-fix: LANQ_MAKEREADY_FIX_LIB=1 is only for tests that dot-source this file; unset it.'); exit 2 }
exit (Invoke-FixMain -Mode $mode -UndoPath "$($ua.Path)" -FromFile $fromFile -Set $set -Hours "$($ua.Hours)" -WorkRoot $wr)
