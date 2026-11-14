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
  dotnet.env, defender.scantime (needs -Hours).
  The Defender ladder (0.6.0, docs/TUNE.md), each alone and each with -BuildUser <the dedicated local build account>:
  -Tune -CreateDevDrive [-SizeGB 100] makes a VHDX-backed Dev Drive with <letter>:\lanq-work (no exclusion needed);
  -Tune -DefenderExclusions makes %SystemDrive%\lanq-work itself (owner Administrators, fixed permissions) and adds the
  one exclusion <drive>:\lanq-work\ after a self-test with the EICAR test file. No path can be given. You type the
  path (or the VHDX file) to confirm; undo removes the exclusion and never deletes the folder or the Dev Drive.
  Exit code: 0 = done or nothing to do, 1 = a change failed or did not verify, 2 = bad arguments or a rejected record,
  3 = refused (over SSH, from stdin, no interactive console).
.PARAMETER WhatIf
  Dry run: show every applicable fix and its undo; change nothing.
.PARAMETER List
  List the undo records in %ProgramData%\lanq-makeready (needs an elevated PowerShell to read them).
.PARAMETER Tune
  Offer the tune fixes instead of the readiness fixes. -Hours HH:mm-HH:mm gives the job window (defender.scantime).
.NOTES
  -Undo <record file>: undo the changes in that record, newest first, confirming each.
  -DefenderExclusions / -CreateDevDrive -BuildUser <account> [-SizeGB <GB>]: the Defender ladder (with -Tune).
#>
# lanq-makeready-fix-marker (identifies this file; the script refuses to run when it was not started from a file)
[CmdletBinding(PositionalBinding = $false)]
param([switch]$WhatIf, [switch]$List, [switch]$Help, [switch]$Tune, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra)

$FixInvocation = $MyInvocation
$ToolVersion = '0.6.0'
$RecordSchema = 'lanq-makeready-fix/v1'
$BaseFixIds = @('ssh.start', 'ssh.auto', 'power.sleep', 'longpaths.on', 'git.longpaths', 'ssh.aclkeys')
$TuneFixIds = @('power.cpu', 'power.usbsuspend', 'startup.vendor', 'vendor.services', 'vendor.tasks', 'sysmain', 'do.mode', 'dotnet.env', 'defender.scantime')
$DefenderFixIds = @('defender.exclude', 'devdrive.create')
$FixIds = $BaseFixIds + $TuneFixIds + $DefenderFixIds   # every id a record may hold (an older script rejects a record with a newer id)
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
  'defender.exclude'  = @('defender.paths', 'Defender scans every build file as it is written; lanq-work is not excluded')
  'devdrive.create'   = @('devdrive', 'there is no Dev Drive for the build folders')
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
  'Get-PowerAc', 'Test-UsbNic', 'Test-FixAllSsd', 'Get-SvcState', 'Get-TaskState', 'Get-StartupState', 'Get-DefenderInfo', 'ConvertTo-Minutes',
  'Get-DotnetState', 'Get-DoState', 'Get-FixTargets', 'Get-StateTarget', 'Get-UndoRefusal', 'Get-TargetLabel', 'Get-ScanTarget', 'Get-SvcNorm', 'Get-FixApplyNote', 'Get-TuneArgError', 'Get-CleanName',
  'Get-SystemDriveLetter', 'Get-DriveRoot', 'Get-LanqWorkPath', 'Get-LanqWorkEntry', 'Get-WorkDirSddl', 'Get-SdCanon', 'Get-SdHash', 'Test-WorkDirSd', 'Test-RootSddl', 'Get-BuildUser',
  'Get-BuildUserProblem', 'Get-ExclusionStatus', 'Get-DevDrvInfo', 'Test-DevDriveBuild', 'Get-DefenderFacts', 'Get-VolumeFacts', 'Get-WorkDirFacts', 'Get-DevVhdFacts', 'Get-WorkDirRecords',
  'Get-WorkDirState', 'Get-WorkDirProblem', 'Get-EicarBytes', 'Test-VirusError', 'Wait-MpDetection', 'Get-MpExclusions', 'Get-SiblingTests', 'Confirm-FixFor')
# Every cmdlet this file runs. A function or alias with one of these names would run instead of the cmdlet, so the
# script refuses to start when any of them does not resolve to the cmdlet itself (Get-FixCommandShadow).
$FixCmdletNames = @('Get-Service', 'Set-Service', 'Start-Service', 'Stop-Service', 'Get-Item', 'Set-ItemProperty', 'Remove-ItemProperty', 'Get-Acl', 'Set-Acl',
  'Get-Content', 'Get-ChildItem', 'Test-Path', 'Join-Path', 'Split-Path', 'Get-Command', 'Get-CimInstance', 'Select-Object', 'Where-Object', 'ForEach-Object', 'Sort-Object',
  'ConvertFrom-Json', 'Write-Host', 'New-Object', 'Get-Location', 'Get-Alias', 'New-Item', 'Get-CimAssociatedInstance')
# Commands from Windows modules (CDXML functions, not cmdlets) the tune fixes run, and the module each must come from:
# a function or alias of the same name from anywhere else would run instead, so the script refuses then too.
$FixModuleCmds = @{ 'Get-NetAdapter' = @('NetAdapter'); 'Get-PhysicalDisk' = @('Storage'); 'Get-ScheduledTask' = @('ScheduledTasks'); 'Disable-ScheduledTask' = @('ScheduledTasks')
  'Enable-ScheduledTask' = @('ScheduledTasks'); 'Get-MpComputerStatus' = @('ConfigDefender', 'Defender'); 'Get-MpPreference' = @('ConfigDefender', 'Defender')
  'Set-MpPreference' = @('ConfigDefender', 'Defender'); 'Add-MpPreference' = @('ConfigDefender', 'Defender'); 'Remove-MpPreference' = @('ConfigDefender', 'Defender')
  'Get-MpThreatDetection' = @('ConfigDefender', 'Defender'); 'Get-Volume' = @('Storage'); 'Get-Partition' = @('Storage'); 'Get-Disk' = @('Storage'); 'Get-DiskImage' = @('Storage')
  'Initialize-Disk' = @('Storage'); 'New-Partition' = @('Storage'); 'Format-Volume' = @('Storage') }
$FixSet = 'base'      # base (readiness fixes), tune, defender (-DefenderExclusions) or devdrive (-CreateDevDrive)
$FixHours = ''        # -Hours HH:mm-HH:mm (tune: defender.scantime)
$FixBuildUser = ''    # -BuildUser (defender, devdrive); $FixUser is what Get-BuildUser read for it
$FixSizeGB = 100      # -SizeGB (devdrive)
$FixUser = $null
$FixMade = ''         # "<path>|<file id>" of the lanq-work this run created (it has no record yet)
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
# The Defender ladder (0.6.0). Fixed names, never taken from the user or a record file.
$WorkDirName = 'lanq-work'
# <drive>:\lanq-work, owner Administrators, nothing inherited. The build user ({0}) may list, add files and folders and
# traverse on the folder itself (no delete, rename, permissions, owner, attributes or delete-child) and gets Modify
# without permissions or owner on what is created inside; OWNER RIGHTS is limited the same way, so the build user
# cannot let anyone else in by changing the permissions of its own files (review H3).
$WorkDirSddl = 'O:BAG:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200af;;;{0})(A;OICIIO;0x1301bf;;;{0})(A;OICIIO;0x1301bf;;;OW)'
$AdminOnlySddl = $RecordDirSddl   # the self-test folders and the Dev Drive's VHDX folder: Administrators and SYSTEM only
# On a drive root, rights that let someone rename, replace or re-permission what is in it: DELETE_CHILD, WRITE_DAC,
# WRITE_OWNER, GENERIC_ALL, GENERIC_WRITE.
$RootRiskMask = 0x40 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
$EicarCode = 'Am8Vewp/GhsKAW4GCgACb25yCgRzbRkZc20nfh8TGRsIdwkOGxQeGwgedxsUDhMMEwgPCXcOHwkOdxwTFh97fhJxEnA='   # the EICAR test file, XOR 0x5A, base64
$DiskpartExe = Join-Path $SysDir 'diskpart.exe'
$FsutilExe = Join-Path $SysDir 'fsutil.exe'
$DevVhdDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'lanq-makeready\devdrive'
$DevVhdFile = Join-Path $DevVhdDir 'lanq-devdrive.vhdx'

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

# Runs an exe with fixed arguments, stdin closed (or fed $StdinText, then closed: diskpart), from %SystemRoot%,
# without GIT_* variables; @{ Code; Out }. Reads here; changes only in FIXES.
function Invoke-Native([string]$Exe, [string[]]$ArgList, [int]$Sec = 60, [string]$StdinText = '') {
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $env:SystemRoot
    $psi.Arguments = (@($ArgList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    foreach ($k in @($psi.EnvironmentVariables.Keys)) { if ("$k" -like 'GIT_*') { $psi.EnvironmentVariables.Remove($k) } }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($StdinText) { $p.StandardInput.Write($StdinText) }
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
# Defender's running mode and scan schedule; $null when unreadable.
function Get-DefenderInfo {
  try { $st = Get-MpComputerStatus -ErrorAction Stop; $pr = Get-MpPreference -ErrorAction Stop } catch { return $null }
  return @{ Mode = "$($st.AMRunningMode)"; Day = [int]$pr.ScanScheduleDay
    Time = (ConvertTo-Minutes $pr.ScanScheduleTime); Quick = (ConvertTo-Minutes $pr.ScanScheduleQuickScanTime) }
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

# ---------- the Defender ladder (0.6.0): reads only ----------
# The drive Windows is on (%SystemDrive%, read from the Windows folder, never from the environment). lanq-work is always
# <that drive>:\lanq-work for the exclusion, and <Dev Drive>:\lanq-work on a Dev Drive: never a path from the user or a record.
function Get-SystemDriveLetter { return ([Environment]::GetFolderPath('Windows')).Substring(0, 1).ToUpperInvariant() }
function Get-DriveRoot([string]$L) { return "$L`:\" }
function Get-LanqWorkPath([string]$L) { return ((Get-DriveRoot $L) + $WorkDirName) }
# The one string this script ever adds as an exclusion: <drive>:\lanq-work\ (the trailing backslash keeps lanq-work-x out).
function Get-LanqWorkEntry([string]$L) { if ($L -cnotmatch '^[A-Z]$') { return '' }; return "$L`:\$WorkDirName\" }
function Get-WorkDirSddl([string]$Sid) { return ($WorkDirSddl -f $Sid) }

# A security descriptor in a canonical form (owner, protected, its entries sorted); '' when unreadable or unusual.
function Get-SdCanon([string]$Sddl) {
  $sd = ConvertFrom-Sddl $Sddl
  if (-not $Sddl -or -not $sd -or $null -eq $sd.DiscretionaryAcl) { return '' }
  $aces = @(); $odd = $false
  foreach ($a in $sd.DiscretionaryAcl) {
    if ($a -isnot [System.Security.AccessControl.CommonAce]) { $odd = $true; continue }
    $aces += ('{0}|{1}|{2}|0x{3:x8}|{4}' -f "$($a.AceQualifier)", [int]$a.IsCallback, [int]$a.AceFlags, $a.AccessMask, "$($a.SecurityIdentifier)")
  }
  if ($odd) { return '' }
  return ("owner=$($sd.Owner);protected=$([int](([int]$sd.ControlFlags -band 0x1000) -ne 0));" + (@($aces | Sort-Object) -join ';'))
}
function Get-SdHash([string]$Sddl) {
  $c = Get-SdCanon $Sddl; if (-not $c) { return '' }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return (-join @($sha.ComputeHash((New-Object System.Text.UTF8Encoding($false)).GetBytes($c)) | ForEach-Object { '{0:x2}' -f $_ })) } finally { $sha.Dispose() }
}
# True when $Sddl is exactly what this script sets on lanq-work for the build user $Sid (owner, protection, entries).
function Test-WorkDirSd([string]$Sddl, [string]$Sid) { $c = Get-SdCanon $Sddl; return ([bool]$c -and $Sid -cmatch '^S-1-5-21-' -and $c -ceq (Get-SdCanon (Get-WorkDirSddl $Sid))) }

# '' when nobody but Administrators, SYSTEM and TrustedInstaller can rename, replace or re-permission what is in a drive
# root (so lanq-work cannot be swapped under the exclusion string), else why not. Deny entries only take rights away, and
# inherit-only entries do not apply to the root itself; a conditional or object entry fails closed.
function Test-RootSddl([string]$Sddl) {
  $sd = ConvertFrom-Sddl $Sddl
  if (-not $Sddl -or -not $sd) { return 'its permissions cannot be read' }
  if (@($BaSid, $SySid, $TiSid) -notcontains "$($sd.Owner)") { return "it is owned by $(Get-AccountName "$($sd.Owner)")" }
  if ($null -eq $sd.DiscretionaryAcl) { return 'it has no DACL (everyone may change it)' }
  foreach ($a in $sd.DiscretionaryAcl) {
    if ($a -isnot [System.Security.AccessControl.CommonAce] -or $a.IsCallback) { return 'it has a conditional or object entry this script cannot judge' }
    if ("$($a.AceQualifier)" -ne 'AccessAllowed' -or ([int]$a.AceFlags -band 8) -or @($BaSid, $SySid, $TiSid) -contains "$($a.SecurityIdentifier)") { continue }
    if (($a.AccessMask -band $RootRiskMask) -ne 0) { return "$(Get-AccountName "$($a.SecurityIdentifier)") may delete or rename what is in it, or change its permissions or owner" }
  }
  return ''
}

# The -BuildUser account: its SID, whether it is a local user, enabled, an administrator.
function Get-BuildUser([string]$Name) {
  $s = @{ Given = $Name; Name = $Name; Found = $false; Sid = ''; Local = $false; Type = 0; Disabled = $false; Admin = $false }
  try { $sid = "$((New-Object System.Security.Principal.NTAccount($Name)).Translate([System.Security.Principal.SecurityIdentifier]).Value)" } catch { return $s }
  $s.Found = $true; $s.Sid = $sid
  if ($sid -cnotmatch "^$SidRe$") { return $s }
  try { $u = @(Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True AND SID='$sid'" -OperationTimeoutSec 15 -ErrorAction Stop) } catch { $u = @() }
  if ($u.Count -ne 1) { return $s }
  $s.Local = $true; $s.Type = [int]$u[0].SIDType; $s.Disabled = [bool]$u[0].Disabled; $s.Name = "$($u[0].Caption)"
  try { $s.Admin = (@(Get-CimAssociatedInstance -InputObject $u[0] -Association Win32_GroupUser -ResultClassName Win32_Group -OperationTimeoutSec 15 -ErrorAction Stop | Where-Object { "$($_.SID)" -eq $BaSid }).Count -gt 0) } catch { }
  return $s
}
# '' when the account may be the build user: a local, enabled user account (S-1-5-21-...), not a group, a built-in
# or service account, Administrator, Guest, DefaultAccount or WDAGUtilityAccount.
function Get-BuildUserProblem($U) {
  if (-not $U.Found) { return "no account named '$(Get-CleanName $U.Given)' on this PC" }
  if ("$($U.Sid)" -cnotmatch '^S-1-5-21-[0-9]{1,10}-[0-9]{1,10}-[0-9]{1,10}-[0-9]{1,10}$') { return "$($U.Sid) is not a user account SID (S-1-5-21-...): a group, a built-in or a service account cannot be the build user" }
  if (@(500, 501, 503, 504) -contains [long]("$($U.Sid)" -replace '^.*-', '')) { return 'a built-in account (Administrator, Guest, DefaultAccount, WDAGUtilityAccount) cannot be the build user' }
  if (-not $U.Local) { return 'it is not a local user account on this PC (a group, or a domain account)' }
  if ($U.Type -ne 1) { return 'it is not a user account' }
  if ($U.Disabled) { return 'the account is disabled' }
  return ''
}

# How the exclusions already on this PC relate to <drive>:\lanq-work\: Exact (that string), Variant (another form of the
# same folder), Broader (it covers lanq-work, like C:\), Unknown (a variable, wildcard or .. part that might).
# Variables are never expanded in this account's context (Defender expands them as SYSTEM): only %SystemDrive% is
# resolved, and the well-known folders that can never hold lanq-work are skipped.
function Get-ExclusionStatus($Ex, [string]$Entry) {
  $s = @{ Exact = $false; Variant = $false; Broader = $false; Unknown = $false }
  $e0 = $Entry.TrimEnd('\'); $drv = $Entry.Substring(0, 2)
  foreach ($x in @($Ex)) {
    $t = "$x".Trim(); if (-not $t) { continue }
    if ($t -eq $Entry) { $s.Exact = $true; continue }
    $t = ($t -ireplace '%SystemDrive%', $drv) -replace '^\\\\[?.]\\|^\\\?\?\\', ''
    if ($t -match '^%(SystemRoot|windir|ProgramData|ProgramFiles|ProgramFiles\(x86\)|ProgramW6432|CommonProgramFiles|CommonProgramFiles\(x86\)|ALLUSERSPROFILE|PUBLIC|USERPROFILE|LOCALAPPDATA|APPDATA|TEMP|TMP)%(\\|$)') { continue }
    if ($t -match '[%*?]' -or $t -match '(^|\\)\.\.?(\\|$)') {
      $lit = ($t -split '[%*?]|\\\.\.?(?:\\|$)', 2)[0]
      if (-not $lit -or $Entry.StartsWith($lit, [System.StringComparison]::OrdinalIgnoreCase)) { $s.Unknown = $true }
      continue
    }
    $t = $t.TrimEnd('\')
    if ($t.TrimEnd('.', ' ') -eq $e0) { $s.Variant = $true; continue }
    if ($Entry.StartsWith($t + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $s.Broader = $true }
  }
  return $s
}

# fsutil devdrv query: State no, untrusted or trusted; Av ok or disallowed; Filter = WdFilter is attached.
function Get-DevDrvInfo([string]$Text) {
  $s = @{ State = 'no'; Av = '-'; Filter = $false }
  if ($Text -notmatch '(?i)developer volume' -or $Text -match '(?i)not a (trusted )?developer volume') { return $s }
  $s.State = 'untrusted'
  if ($Text -match '(?i)\btrusted developer volume' -and $Text -notmatch '(?i)\b(not|un)trusted\b') { $s.State = 'trusted' }
  $s.Av = 'ok'
  if ($Text -match '(?i)disallow|not protected by antivirus') { $s.Av = 'disallowed' }
  $s.Filter = ($Text -match '(?i)\bWdFilter\b')
  return $s
}
# Dev Drive: Windows 11 22H2 build 22621.2338 or later.
function Test-DevDriveBuild([int]$Build, [int]$Ubr) {
  return ($Build -gt 22621 -or ($Build -eq 22621 -and $Ubr -ge 2338))
}

# Defender: running mode, real-time protection and direction, the exclusions (hidden or not), and who manages them.
function Get-DefenderFacts {
  $s = @{ Known = $false; Mode = ''; Rtp = $false; Rtsd = 0; Ex = @(); Hidden = $false; LocalMerge = $false; PolicyEx = $false; Mdm = $false; Sense = $false }
  try { $st = Get-MpComputerStatus -ErrorAction Stop; $pr = Get-MpPreference -ErrorAction Stop } catch { return $s }
  $s.Known = $true; $s.Mode = "$($st.AMRunningMode)"; $s.Rtp = [bool]$st.RealTimeProtectionEnabled; $s.Rtsd = [int]$pr.RealTimeScanDirection
  $ex = @($pr.ExclusionPath | Where-Object { $_ } | ForEach-Object { "$_" })
  if ($ex.Count -eq 1 -and $ex[0] -match '^N/A') { $s.Hidden = $true; $ex = @() }
  $s.Ex = $ex
  $pk = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
  $m = Get-RegVal $pk 'DisableLocalAdminMerge'; $s.LocalMerge = ($m.Has -and "$($m.Value)" -eq '1')
  $e = Get-RegVal "$pk\Exclusions" 'Exclusions_Paths'; $s.PolicyEx = (($e.Has -and "$($e.Value)" -eq '1') -or @(Get-RegNames "$pk\Exclusions\Paths").Count -gt 0)
  $s.Mdm = (@(Get-RegNames 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender' | Where-Object { $_ -match '^Excluded' }).Count -gt 0)
  $ob = Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' 'OnboardingState'
  $sv = @(Get-Service -Name 'Sense' -ErrorAction SilentlyContinue)
  $s.Sense = (($ob.Has -and "$($ob.Value)" -eq '1') -or ($sv.Count -gt 0 -and "$($sv[0].Status)" -eq 'Running'))
  return $s
}

# A drive: fixed or not, file system, bus, volume GUID, Dev Drive state, free space, the root's case sensitivity and SDDL.
function Get-VolumeFacts([string]$L) {
  $s = @{ Known = $false; Letter = $L; Fixed = $false; Fs = ''; Bus = ''; Guid = ''; DevDrv = 'no'; DevAv = '-'; DevFilter = $false; FreeGB = 0; CaseSens = $null; RootSddl = '' }
  try { $v = Get-Volume -DriveLetter $L -ErrorAction Stop; $p = Get-Partition -DriveLetter $L -ErrorAction Stop; $d = Get-Disk -Number $p.DiskNumber -ErrorAction Stop } catch { return $s }
  $s.Fixed = ("$($v.DriveType)" -eq 'Fixed'); $s.Fs = "$($v.FileSystemType)"; $s.Bus = "$($d.BusType)"; $s.FreeGB = [int][math]::Floor($v.SizeRemaining / 1GB)
  if ("$($v.UniqueId)" -match "\{($GuidRe)\}") { $s.Guid = '{' + $Matches[1].ToLowerInvariant() + '}' }
  $dd = Get-DevDrvInfo "$((Invoke-Native $FsutilExe @('devdrv', 'query', "$L`:")).Out)"
  $s.DevDrv = $dd.State; $s.DevAv = $dd.Av; $s.DevFilter = $dd.Filter
  $r = Invoke-Native $FsutilExe @('file', 'queryCaseSensitiveInfo', (Get-DriveRoot $L))
  if ($r.Code -eq 0) { $s.CaseSens = ("$($r.Out)" -match '(?i)\benabled\b') }
  $s.RootSddl = Get-PathSddl (Get-DriveRoot $L)
  $s.Known = [bool]$s.Guid
  return $s
}

# A lanq-work folder: there, a link (or not a folder), its SDDL, empty, its file id (fsutil file queryfileid).
function Get-WorkDirFacts([string]$Path) {
  $s = @{ Exists = $false; Reparse = $false; Sddl = ''; Empty = $false; FileId = '-' }
  try { $fi = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { return $s }
  $s.Exists = $true; $s.Reparse = ([bool]($fi.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or -not $fi.PSIsContainer)
  if ($s.Reparse) { return $s }
  try { $s.Sddl = "$((Get-Acl -LiteralPath $Path -ErrorAction Stop).Sddl)" } catch { }
  try { $s.Empty = (@([System.IO.Directory]::GetFileSystemEntries($Path)).Count -eq 0) } catch { }
  $r = Invoke-Native $FsutilExe @('file', 'queryfileid', $Path)
  if ($r.Code -eq 0 -and "$($r.Out)" -match '(0x[0-9a-fA-F]{1,32})') { $s.FileId = $Matches[1].ToLowerInvariant() }
  return $s
}

# The Dev Drive VHDX this script makes: there, attached, its drive letter.
function Get-DevVhdFacts {
  $ex = [System.IO.File]::Exists($DevVhdFile)
  $s = @{ Exists = $ex; Attached = $false; Letter = '' }
  if (-not $ex) { return $s }
  try {
    $im = Get-DiskImage -ImagePath $DevVhdFile -ErrorAction Stop
    $s.Attached = [bool]$im.Attached
    if ($s.Attached) { $s.Letter = "$(@(Get-Partition -DiskNumber $im.Number -ErrorAction Stop | Where-Object { "$($_.DriveLetter)" -cmatch '^[A-Z]$' } | ForEach-Object { "$($_.DriveLetter)" })[0])" }
  } catch { }
  return $s
}

# The lanq-work folders trusted records vouch for: the after state of each defender.exclude item that made one (drive,
# volume GUID, file id, permissions hash, build user). Only trusted, valid records in the record folder count.
function Get-WorkDirRecords {
  $out = @()
  foreach ($f in @(Get-ChildItem -LiteralPath (Get-FixRecordDir) -Filter 'fix-*.json' -File -ErrorAction SilentlyContinue)) {
    if ($f.Name -notmatch '^fix-[0-9]{8}T[0-9]{6}Z(-[0-9]{1,4})?\.json$' -or (Test-FixRecordTrusted $f.FullName)) { continue }
    $r = Read-FixRecord $f.FullName
    if ($r.Error) { continue }
    foreach ($i in @($r.Rec.Items)) {
      if ($i.id -ne 'defender.exclude' -or @('applied', 'failed', 'undone') -notcontains $i.status) { continue }
      $a = ConvertFrom-StateText $i.id $i.after
      if ($a -and $a.DirState -eq 'lanq' -and $a.FileId -ne '-' -and $a.Sd -ne '-') { $out += $a }
    }
  }
  return $out
}
# absent, lanq (made by this script: this run, or a trusted record matches its volume, file id, permissions and user)
# or other; and why it is other. There is no marker file in the folder: the record is the only proof.
function Get-WorkDirState($S) {
  $d = $S.Dir
  if (-not $d.Exists) { return @('absent', '') }
  if ($d.Reparse) { return @('other', 'it is a link or junction, or not a folder') }
  if (-not $S.User) { return @('other', 'no build user was given') }
  if (-not (Test-WorkDirSd $d.Sddl $S.User)) { return @('other', "its owner or permissions are not the ones this script sets for $($S.User)") }
  if ($script:FixMade -and $script:FixMade -ceq "$($S.Path)|$($d.FileId)") { return @('lanq', '') }
  $h = Get-SdHash $d.Sddl
  foreach ($r in @(Get-WorkDirRecords)) {
    if ($r.Drive -ceq $S.Drive -and $r.Vol -ceq $S.Vol.Guid -and $r.FileId -ceq $d.FileId -and $r.Sd -ceq $h -and $r.User -ceq $S.User) { return @('lanq', '') }
  }
  return @('other', 'no trusted fix record matches its volume, file id and permissions')
}
# '' when the folder at $Path is exactly what this script makes: there, not a link, its owner and permissions as set,
# empty when it was just made, and its file id readable (the record ties the exclusion to it).
function Get-WorkDirProblem([string]$Path, [string]$Sid, [bool]$New) {
  $d = Get-WorkDirFacts $Path
  if (-not $d.Exists) { return 'it does not exist' }
  if ($d.Reparse) { return 'it is a link or junction' }
  if (-not (Test-WorkDirSd $d.Sddl $Sid)) { return 'its owner or permissions are not the ones this script sets' }
  if ($New -and -not $d.Empty) { return 'it is not empty' }
  if ("$($d.FileId)" -cnotmatch '^0x[0-9a-f]{1,32}$') { return 'its file id cannot be read (fsutil file queryfileid)' }
  return ''
}

# The EICAR antivirus test file (harmless by design), built at run time from a transformed constant, so that this
# script never contains it (Defender would flag the script itself).
function Get-EicarBytes { return [byte[]]@([Convert]::FromBase64String($EicarCode) | ForEach-Object { $_ -bxor 0x5A }) }
# Windows refused to write a file because it holds a virus (ERROR_VIRUS_INFECTED, ERROR_VIRUS_DELETED).
function Test-VirusError($E) { $x = $E; while ($x) { if (@(-2147024671, -2147024670) -contains $x.HResult) { return $true }; $x = $x.InnerException }; return $false }
# True when Defender caught the test file at $Path within $Sec seconds: it was removed (quarantined), or the threat
# history lists it. -HistoryOnly for a stream, whose presence this cannot read reliably.
function Wait-MpDetection([string]$Path, [datetime]$Since, [int]$Sec, [switch]$HistoryOnly) {
  $p = $Path -replace '^\\\\\?\\', ''; $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    if (-not $HistoryOnly -and -not [System.IO.File]::Exists('\\?\' + $p)) { return $true }
    try { if (@(Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.InitialDetectionTime -ge $Since -and @($_.Resources | Where-Object { "$_".IndexOf($p, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0 }).Count -gt 0) { return $true } } catch { }
    if ($sw.Elapsed.TotalSeconds -ge $Sec) { return $false }
    [System.Threading.Thread]::Sleep(500)
  }
}
function Get-MpExclusions { try { return @((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ } | ForEach-Object { "$_" }) } catch { return @() } }
# The forms next to lanq-work that the self-test checks are still scanned (anyone may create them on the drive root).
function Get-SiblingTests([string]$Root, [string]$Tag) {
  return @(@{ Dir = "$Root$WorkDirName-$Tag"; File = 'eicar.com' }, @{ Dir = "$Root$WorkDirName$Tag"; File = 'eicar.com' }, @{ Dir = "$Root$WorkDirName.$Tag"; File = 'eicar.com' },
    @{ Dir = "$Root$WorkDirName."; File = 'eicar.com' }, @{ Dir = "$Root$WorkDirName "; File = 'eicar.com' }, @{ Dir = "$Root$WorkDirName-$Tag-ads"; File = 'host.txt:eicar'; Ads = $true })
}

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
  }
  return @{ List = @(''); Note = '' }
}
# The target a parsed before state belongs to (undo reads the current state of that same thing).
function Get-StateTarget([string]$Id, $B) {
  switch ($Id) {
    'startup.vendor' { return "$($B.Hive)|$($B.Key)|$($B.Name)" }
    { @('vendor.services', 'sysmain') -contains $_ } { return $B.Name }
    'vendor.tasks' { return "$($B.Path)|$($B.Name)" }
  }
  return ''
}
function Get-TargetLabel([string]$Id, $S) {
  switch ($Id) {
    'startup.vendor' { return " $($S.Hive) $($S.Key): $(Get-CleanName $S.Name)" }
    { @('vendor.services', 'sysmain') -contains $_ } { return " $($S.Name)" }
    'vendor.tasks' { return " $($S.Path)$($S.Name)" }
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
    'devdrive.create' { return "a Dev Drive is never removed by this script (the files on it would be lost). To remove it yourself: Dismount-DiskImage -ImagePath '$DevVhdFile', then delete that file" }
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
    'defender.exclude' {
      $L = Get-SystemDriveLetter; $p = Get-LanqWorkPath $L
      $s = @{ Drive = $L; Path = $p; Entry = (Get-LanqWorkEntry $L); User = "$($FixUser.Sid)"; Def = (Get-DefenderFacts); Vol = (Get-VolumeFacts $L); Dir = (Get-WorkDirFacts $p); ObCi = 1; Linked = $false; DirState = 'absent'; DirWhy = '' }
      $s.ExSt = Get-ExclusionStatus $s.Def.Ex $s.Entry; $s.Has = $s.ExSt.Exact
      $o = Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'ObCaseInsensitive'
      if ($o.Has -and $o.Kind -eq 'DWord') { $s.ObCi = [int]$o.Value } elseif ($null -eq $o.Has -or $o.Has) { $s.ObCi = -1 }
      $k = Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLinkedConnections'; $s.Linked = ($k.Has -and "$($k.Value)" -eq '1')
      $w = Get-WorkDirState $s; $s.DirState = $w[0]; $s.DirWhy = $w[1]
      return $s
    }
    'devdrive.create' {
      $L = Get-SystemDriveLetter; $vh = Get-DevVhdFacts
      $s = @{ Drive = $L; Size = $FixSizeGB; User = "$($FixUser.Sid)"; Vhd = $vh; Sys = (Get-VolumeFacts $L); Build = 0; Ubr = 0; Dev = @{ Known = $false }; Dir = @{ Exists = $false }; DirState = 'absent' }
      $bn = Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber'; $ub = Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'UBR'
      if ("$($bn.Value)" -match '^[0-9]{1,6}$') { $s.Build = [int]$bn.Value }
      if ($ub.Has -and $ub.Kind -eq 'DWord') { $s.Ubr = [int]$ub.Value }
      if ($vh.Letter) {
        $s.Dev = Get-VolumeFacts $vh.Letter; $s.Dir = Get-WorkDirFacts (Get-LanqWorkPath $vh.Letter)
        if ($s.Dir.Exists) { $s.DirState = 'other'; if (-not $s.Dir.Reparse -and (Test-WorkDirSd $s.Dir.Sddl $s.User)) { $s.DirState = 'lanq' } }
      }
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
      if ($Text -cmatch "^entry=([01]) dir=(absent|lanq|other) path=([A-Z]):\\$WorkDirName\\ user=(-|S-1-5-21(?:-[0-9]{1,10}){4}) vol=(-|\{$GuidRe\}) fileid=(-|0x[0-9a-f]{1,32}) sd=(-|[0-9a-f]{64})$") {
        $u = $Matches[4]; if ($u -eq '-') { $u = '' }
        return @{ Has = ($Matches[1] -eq '1'); DirState = $Matches[2]; Drive = $Matches[3]; User = $u; Vol = $Matches[5]; FileId = $Matches[6]; Sd = $Matches[7] }
      }
      return $null
    }
    'devdrive.create' {
      if ($Text -cmatch '^vhd=(absent|attached|detached) letter=(-|[D-Z]) size=([0-9]{2,5}) user=(-|S-1-5-21(?:-[0-9]{1,10}){4}) dir=(absent|lanq|other)$' -and [int]$Matches[3] -ge 50 -and [int]$Matches[3] -le 65536) {
        $u = $Matches[4]; if ($u -eq '-') { $u = '' }
        return @{ Vhd = $Matches[1]; Letter = $Matches[2]; Size = [int]$Matches[3]; User = $u; DirState = $Matches[5] }
      }
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
    'defender.exclude' {
      if ($S.Drive) {
        $u = '-'; if ($S.User) { $u = $S.User }; $v = '-'; if ($S.Vol.Guid) { $v = $S.Vol.Guid }; $fid = '-'; $sd = '-'
        if ($S.Dir.Exists -and -not $S.Dir.Reparse) { if ($S.Dir.FileId) { $fid = $S.Dir.FileId }; $hh = Get-SdHash $S.Dir.Sddl; if ($hh) { $sd = $hh } }
        $t = "entry=$([int][bool]$S.Has) dir=$($S.DirState) path=$($S.Drive):\$WorkDirName\ user=$u vol=$v fileid=$fid sd=$sd"
      }
    }
    'devdrive.create' {
      $vw = 'absent'; if ($S.Vhd.Exists) { $vw = 'detached'; if ($S.Vhd.Attached) { $vw = 'attached' } }
      $lt = '-'; if ("$($S.Vhd.Letter)" -cmatch '^[D-Z]$') { $lt = $S.Vhd.Letter }; $u = '-'; if ($S.User) { $u = $S.User }
      $t = "vhd=$vw letter=$lt size=$($S.Size) user=$u dir=$($S.DirState)"
    }
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
  # defender.exclude: undo only removes the exclusion string, so what counts is whether it is there (and for which drive)
  if ($Id -eq 'defender.exclude') { return (($A -creplace ' dir=.*$', '') -ceq ($B -creplace ' dir=.*$', '') -and ($A -creplace '^.* (path=\S+) .*$', '$1') -ceq ($B -creplace '^.* (path=\S+) .*$', '$1')) }
  if ($Id -eq 'devdrive.create') { return (($A -creplace ' letter=.*$', '') -ceq ($B -creplace ' letter=.*$', '')) }
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
      if ($S.RunHas -and -not $S.Flag) { return "$(Get-CleanName $S.Name): its StartupApproved value is not the usual 12-byte flag; use Task Manager > Startup apps" }
    }
    'vendor.services' { if (-not $S.Exists -and $S.Name -cnotmatch "^$SvcRe$") { return "$(Get-CleanName $S.Name): the service name has characters this script does not record; use services.msc" } }
    'vendor.tasks' {
      if ($null -eq $S.Exists) { return "$(Get-CleanName "$($S.Path)$($S.Name)") could not be read (access denied); skipped" }
      if (-not $S.Exists) { return "$(Get-CleanName "$($S.Path)$($S.Name)"): the task path or name has characters this script does not record; use taskschd.msc" }
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
    'defender.exclude' {   # any doubt: report only (not offered, exit 0)
      $d = $S.Def; $v = $S.Vol; $x = $S.ExSt; $w = "$($S.Drive):\$WorkDirName"
      if (-not $d.Known) { return 'Defender could not be read (Get-MpComputerStatus, Get-MpPreference)' }
      if ($d.Mode -ne 'Normal') { return "Defender is not the active antivirus (AMRunningMode: $($d.Mode))" }
      if (-not $d.Rtp) { return 'real-time protection is off, so an exclusion would change nothing' }
      if ($d.Rtsd -ne 0) { return "RealTimeScanDirection is $($d.Rtsd), not 0 (both directions); this script works only with the default" }
      if ($d.Hidden) { return 'the exclusions are hidden from local administrators (HideExclusionsFromLocalAdmins), so this script cannot check or read back its entry' }
      if ($d.LocalMerge) { return 'DisableLocalAdminMerge is set by a policy: Defender ignores exclusions added here; ask whoever manages it' }
      if ($d.PolicyEx) { return 'Defender exclusions are set by a group policy on this PC; add lanq-work there, not here' }
      if ($d.Mdm) { return 'Defender exclusions are managed by MDM (Intune) on this PC; add lanq-work there, not here' }
      if ($d.Sense) { return 'Microsoft Defender for Endpoint is onboarded (Sense): the self-test file would alert your security team. Report only (docs/TUNE.md)' }
      if ($x.Broader) { return "an existing exclusion already covers $w; it is reported, never recorded or undone here (remove it yourself if lanq-work should be scanned again)" }
      if ($x.Unknown) { return "an existing exclusion uses a variable or wildcard (or a .. part) that may cover $w; check it yourself: (Get-MpPreference).ExclusionPath" }
      if ($x.Variant) { return "an exclusion for $w exists that is not exactly $($S.Entry) (a changed or variant string); remove it (Remove-MpPreference -ExclusionPath <it>) and run this script again" }
      if ($S.Has -and $S.DirState -ne 'lanq') { return "the exclusion $($S.Entry) exists, but this script did not add it (no trusted fix record vouches for the folder); remove it: Remove-MpPreference -ExclusionPath '$($S.Entry)'" }
      if (-not $v.Known) { return "the drive $($S.Drive): could not be read (Get-Volume, Get-Partition, Get-Disk)" }
      if (-not $v.Fixed) { return "$($S.Drive): is not a fixed drive" }
      if (@('USB', 'File Backed Virtual', 'SD', 'MMC') -contains $v.Bus) { return "$($S.Drive): is on a $($v.Bus) disk; the exclusion is offered only on an internal disk" }
      if ($v.DevDrv -ne 'no') { return "$($S.Drive): is a Dev Drive: it needs no exclusion" }
      if ($v.Fs -ne 'NTFS') { return "$($S.Drive): is $($v.Fs), not NTFS" }
      $rw = Test-RootSddl $v.RootSddl; if ($rw) { return "the drive root $($S.Drive):\ is not safe to keep lanq-work in: $rw" }
      if ($v.CaseSens -ne $false) { return "the drive root $($S.Drive):\ is case-sensitive, or that could not be read (fsutil file queryCaseSensitiveInfo)" }
      if ($S.ObCi -ne 1) { return 'ObCaseInsensitive is not 1: Windows is case-sensitive here, so other spellings of lanq-work could slip past the exclusion' }
      if ($S.Dir.Reparse) { return "$($S.Path) is a link or junction (or not a folder); it is not touched" }
      if ($S.DirState -eq 'other') { return "$($S.Path) exists and was not made by this script ($($S.DirWhy)). Look at what is in it, then move it out of the way: takeown.exe /a /r /d y /f `"$($S.Path)`"; Rename-Item -LiteralPath '$($S.Path)' -NewName $WorkDirName.old; and run this script again" }
    }
    'devdrive.create' {
      if (-not (Test-DevDriveBuild $S.Build $S.Ubr)) { return "a Dev Drive needs Windows 11 22H2 build 22621.2338 or later (this is build $($S.Build).$($S.Ubr))" }
      if ($S.Vhd.Exists -and -not (Test-FixDone $Id $S)) { return "$DevVhdFile exists already (detached after a restart?): attach it with Mount-DiskImage -ImagePath '$DevVhdFile', or move it away to make a new one" }
      if (-not $S.Vhd.Exists -and -not $S.Sys.Known) { return "the drive $($S.Drive): could not be read (Get-Volume, Get-Partition, Get-Disk)" }
      if (-not $S.Vhd.Exists -and $S.Sys.FreeGB -lt $S.Size + 10) { return "only $($S.Sys.FreeGB) GB are free on $($S.Drive):; a $($S.Size) GB Dev Drive grows up to that size and needs 10 GB to spare: give a smaller -SizeGB" }
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
    'defender.exclude' { return (-not $S.Has -and @('absent', 'lanq') -contains $S.DirState) }
    'devdrive.create' { return (-not $S.Vhd.Exists) }
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
    'defender.exclude' { return ($S.Has -and $S.DirState -eq 'lanq') }
    'devdrive.create' { return ($S.Vhd.Attached -and $S.Vhd.Letter -and $S.Dev.DevDrv -eq 'trusted' -and $S.Dev.DevAv -eq 'ok' -and $S.DirState -eq 'lanq') }
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
    'defender.exclude' {
      $v = '-'; if ($S.Vol.Guid) { $v = $S.Vol.Guid }; $fid = '-'; if ($S.DirState -eq 'lanq' -and $S.Dir.FileId) { $fid = $S.Dir.FileId }
      return "entry=1 dir=lanq path=$($S.Drive):\$WorkDirName\ user=$($S.User) vol=$v fileid=$fid sd=$(Get-SdHash (Get-WorkDirSddl $S.User))"
    }
    'devdrive.create' { return "vhd=attached letter=- size=$($S.Size) user=$($S.User) dir=lanq" }
  }
  return 'unknown'
}

# A name from the PC (Run entry, service, task, driver, product) made safe to print: control and bidi characters
# removed (any user process can write a Run entry), at most 80 characters.
function Get-CleanName([string]$S) {
  $c = [regex]::Replace("$S", '[\p{Cc}\p{Cf}\p{Cs}\u2028\u2029]', '')
  if ($c.Length -gt 80) { $c = $c.Substring(0, 77) + '...' }
  return $c
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
    'startup.vendor' { $f = 'no flag (enabled)'; if ($S.Flag -ne '-') { $f = "flag $($S.Flag)" }; return "$($S.Hive) $($S.Key) entry '$(Get-CleanName $S.Name)' ($(Get-CleanName $S.Exe)), StartupApproved $f" }
    { @('vendor.services', 'sysmain') -contains $_ } { $d = ''; if ($S.Start -eq 2 -and $S.Delayed -eq 1) { $d = ' (delayed)' }; return "service $($S.Name) ($(Get-CleanName $S.Display)): start $($StartWord[[int]$S.Start])$d" }
    'vendor.tasks' { $e = 'disabled'; if ($S.Enabled) { $e = 'enabled' }; return "task $($S.Path)$($S.Name) is $e" }
    'do.mode' { $p = 'not set'; if ($null -ne $S.Value) { $p = "$($S.Value)" }; return "policy DODownloadMode: $p; download mode in effect: $($S.Effective) (1 = LAN peers, 2 = group, 3 = internet peers)" }
    'dotnet.env' { return (@($DotnetVars.Keys | ForEach-Object { "$($DotnetVars[$_][0])=$($S.Vals[$_])" }) -join ', ') + ' (- = not set) for the machine' }
    'defender.scantime' { return "scheduled scan day $($S.Day) (0 = every day, 8 = never) at $(Format-Min $S.Time); daily quick scan at $(Format-Min ([int]$S.Quick)) (00:00:00 = none); job window $FixHours" }
    'defender.exclude' {
      $dw = @{ absent = 'does not exist yet (it is created)'; lanq = 'exists, made by this script'; other = 'exists' }[$S.DirState]; $e = 'not excluded'; if ($S.Has) { $e = 'excluded' }
      return "$($S.Drive):\$WorkDirName $dw and is $e; drive $($S.Drive): is $($S.Vol.Fs) on a $($S.Vol.Bus) disk; Defender $($S.Def.Mode), real-time protection on"
    }
    'devdrive.create' {
      if ($S.Vhd.Exists) { return "the Dev Drive VHDX $DevVhdFile exists (attached: $($S.Vhd.Attached); drive $($S.Vhd.Letter))" }
      return "no Dev Drive VHDX yet ($DevVhdFile); $($S.Sys.FreeGB) GB free on $($S.Drive):; Windows build $($S.Build).$($S.Ubr). The new one: $($S.Size) GB, expandable, a ReFS Dev Drive"
    }
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
    'defender.exclude' { return "note: point work_root at $($S.Drive):/$WorkDirName (LanQueue machines.yml). Undo removes the exclusion and keeps the folder; this script never deletes it" }
    'devdrive.create' {
      $l = (Get-DevVhdFacts).Letter
      return "note: point work_root at $l`:/$WorkDirName (LanQueue machines.yml). A VHDX attached this way may not come back by itself after a restart: check after the next one, and attach it again with Mount-DiskImage -ImagePath '$DevVhdFile' (docs/TUNE.md)"
    }
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
    'defender.exclude|apply' {
      $w = "$($B.Drive):\$WorkDirName"
      if ($B.DirState -eq 'absent') { $cmd += "New folder $w, owner Administrators, permissions $(Get-WorkDirSddl $B.User)   (set in the same call, then read back; never re-permissioned)" }
      else { $cmd += "use $w (made by this script: a trusted record matches its volume, file id and permissions)" }
      $cmd += "self-test: the EICAR test file in an admin-only folder $($B.Drive):\lanq-selftest-<id> must be detected (otherwise nothing is added)"
      $cmd += "Add-MpPreference -ExclusionPath '$(Get-LanqWorkEntry $B.Drive)'   (read back: exactly this one new entry)"
      $cmd += "self-test: EICAR in $w\lanq-selftest-<id> must stay 15 s; in $w-<id>, $w<id>, $w.<id>, '$w.', '$w ' and a stream it must be detected (otherwise Remove-MpPreference)"
    }
    'defender.exclude|undo' { $cmd = @("Remove-MpPreference -ExclusionPath '$(Get-LanqWorkEntry $B.Drive)'   ($($B.Drive):\$WorkDirName is kept: this script never deletes it)") }
    'devdrive.create|apply' {
      $cmd = @("diskpart (fixed input): create vdisk file=`"$DevVhdFile`" maximum=$([int]$B.Size * 1024) type=expandable; attach vdisk   (its folder: owner Administrators, Administrators and SYSTEM only)",
        'Initialize-Disk -PartitionStyle GPT; New-Partition -UseMaximumSize -AssignDriveLetter; Format-Volume -DevDrive -NewFileSystemLabel lanq-dev',
        'check: fsutil devdrv query <letter>: trusted, antivirus allowed, WdFilter attached',
        "New folder <letter>:\$WorkDirName, owner Administrators, permissions $(Get-WorkDirSddl $B.User)   (no Defender exclusion: a Dev Drive needs none)")
    }
    'devdrive.create|undo' { $cmd = @("none: a Dev Drive is never removed by this script (yourself: Dismount-DiskImage -ImagePath '$DevVhdFile', then delete that file)") }
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
    'defender.exclude|apply' {
      # 1. lanq-work: created with its owner and permissions in one call (only when the state said it is absent), then
      #    read back; a folder someone else made meanwhile (or anything unexpected) stops here, before any exclusion.
      $root = Get-DriveRoot $B.Drive; $p = Get-LanqWorkPath $B.Drive; $entry = Get-LanqWorkEntry $B.Drive; $tag = [Guid]::NewGuid().ToString('N')
      if ($B.DirState -eq 'absent') { New-FixSecuredDir $p (Get-WorkDirSddl $B.User) }
      $why = Get-WorkDirProblem $p $B.User ($B.DirState -eq 'absent')
      if ($why) { throw "$p is not as this script makes it ($why); no exclusion was added" }
      if ($B.DirState -eq 'absent') { $script:FixMade = "$p|$((Get-WorkDirFacts $p).FileId)" }
      $made = New-Object System.Collections.ArrayList; $fail = ''; $new = @(); $bytes = Get-EicarBytes
      try {
        # 2. positive control: Defender must catch the test file in an admin-only folder on the same drive
        $d = $root + "lanq-selftest-$tag"; New-FixSecuredDir $d $AdminOnlySddl; [void]$made.Add($d)
        $f = "$d\eicar.com"; $t0 = [DateTime]::Now.AddSeconds(-5); $hit = $false
        try { [System.IO.File]::WriteAllBytes($f, $bytes) } catch { if (Test-VirusError $_.Exception) { $hit = $true } else { throw } }
        if (-not $hit) { $hit = Wait-MpDetection $f $t0 30 }
        if (-not $hit) { throw 'the positive control failed: Defender did not detect the EICAR test file in an admin-only folder within 30 s, so it may not scan here. No exclusion was added (report only)' }
        # 3. the one exclusion, read back: exactly one new entry, exactly this string
        $old = @(Get-MpExclusions)
        Add-MpPreference -ExclusionPath $entry -ErrorAction Stop
        $new = @(Get-MpExclusions | Where-Object { $old -notcontains $_ })
        if ($new.Count -ne 1 -or $new[0] -ne $entry) { $fail = "read back: Defender lists $($new.Count) new exclusion(s), not exactly $entry (a policy or Tamper Protection may manage exclusions)" }
        # 4. inside lanq-work the test file must stay; in every sibling form it must still be caught
        if (-not $fail) {
          $d = "$p\lanq-selftest-$tag"; New-FixSecuredDir $d $AdminOnlySddl; [void]$made.Add($d)
          $f = "$d\eicar.com"; $t0 = [DateTime]::Now.AddSeconds(-5); $hit = $true
          try { [System.IO.File]::WriteAllBytes($f, $bytes); $hit = Wait-MpDetection $f $t0 15 } catch { }
          if ($hit) { $fail = 'the EICAR test file in lanq-work was still detected (or could not be written): the exclusion did not take effect' }
        }
        if (-not $fail) {
          foreach ($t in (Get-SiblingTests $root $tag)) {
            $d = '\\?\' + $t.Dir
            if ([System.IO.Directory]::Exists($d)) { $fail = "the folder '$($t.Dir)' exists already (someone made it), so the self-test cannot show that the exclusion does not reach it; look at it"; break }
            New-FixSecuredDir $d $AdminOnlySddl; [void]$made.Add($d)
            if ($t.Ads) { [System.IO.File]::WriteAllBytes("$d\host.txt", [byte[]](120)) }
            $f = "$d\$($t.File)"; $t0 = [DateTime]::Now.AddSeconds(-5); $hit = $false
            try { [System.IO.File]::WriteAllBytes($f, $bytes) } catch { if (Test-VirusError $_.Exception) { $hit = $true } else { throw } }
            if (-not $hit) { $hit = Wait-MpDetection $f $t0 30 -HistoryOnly:([bool]$t.Ads) }
            if (-not $hit) { $fail = "the EICAR test file in '$($t.Dir)' was not detected: the exclusion reaches beyond lanq-work"; break }
          }
        }
      } finally {
        foreach ($d in @($made)) { $q = $d; if (-not $q.StartsWith('\\?\')) { $q = '\\?\' + $q }; try { [System.IO.Directory]::Delete($q, $true) } catch { } }
      }
      if ($fail) {
        foreach ($e in @(@($entry) + @($new | Where-Object { "$_".TrimEnd('\', '.', ' ') -eq $entry.TrimEnd('\') }))) { Remove-MpPreference -ExclusionPath $e -ErrorAction SilentlyContinue }
        throw "$fail; the exclusion was removed again"
      }
    }
    'defender.exclude|undo' { $entry = Get-LanqWorkEntry $B.Drive; if (@(Get-MpExclusions) -contains $entry) { Remove-MpPreference -ExclusionPath $entry -ErrorAction Stop } }
    'devdrive.create|apply' {
      if (-not [System.IO.Directory]::Exists($DevVhdDir)) { New-FixSecuredDir $DevVhdDir $AdminOnlySddl }
      Assert-Native (Invoke-Native $DiskpartExe @() 300 "create vdisk file=`"$DevVhdFile`" maximum=$([int]$B.Size * 1024) type=expandable`r`nattach vdisk`r`nexit`r`n")
      $n = [int](Get-DiskImage -ImagePath $DevVhdFile -ErrorAction Stop).Number
      Initialize-Disk -Number $n -PartitionStyle GPT -ErrorAction Stop
      $L = "$((New-Partition -DiskNumber $n -UseMaximumSize -AssignDriveLetter -ErrorAction Stop).DriveLetter)"
      if ($L -cnotmatch '^[D-Z]$') { throw 'the new partition got no drive letter' }
      [void](Format-Volume -DriveLetter $L -DevDrive -NewFileSystemLabel 'lanq-dev' -Confirm:$false -Force -ErrorAction Stop)
      $v = Get-VolumeFacts $L
      if ($v.DevDrv -ne 'trusted' -or $v.DevAv -ne 'ok' -or -not $v.DevFilter) { throw "the new volume $L`: is not a trusted Dev Drive with antivirus allowed and WdFilter attached (fsutil devdrv query $L`:: $($v.DevDrv), antivirus $($v.DevAv))" }
      $p = Get-LanqWorkPath $L; New-FixSecuredDir $p (Get-WorkDirSddl $B.User)
      $why = Get-WorkDirProblem $p $B.User $true
      if ($why) { throw "$p is not as this script makes it ($why)" }
    }
    'devdrive.create|undo' { throw 'a Dev Drive is never removed by this script' }
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
#
# The record folder, and (from Invoke-FixChange) lanq-work, the self-test folders and the VHDX folder are made this way.
function New-FixSecuredDir([string]$Dir, [string]$Sddl = $RecordDirSddl) {
  $ds = New-Object System.Security.AccessControl.DirectorySecurity
  $ds.SetSecurityDescriptorSddlForm($Sddl)
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
  if (@($DefenderFixIds) -contains $Id) {
    Write-FixLine "  build user: $(Get-CleanName $FixUser.Name) ($($FixUser.Sid)): it may add and change files in lanq-work; it can never rename, delete or re-permission the folder itself"
    if ($FixUser.Admin) { Write-FixLine "  WARNING: $(Get-CleanName $FixUser.Name) is an administrator. Use a dedicated, non-admin build account: an administrator can change anything, lanq-work included." 'Yellow' }
    Write-FixLine '  note: use a dedicated build account that runs nothing but builds: whatever it lets into lanq-work is not scanned (docs/TUNE.md, residual risks)'
    $nd = "$($S.Drive):"; if ($Id -eq 'devdrive.create') { $nd = '<letter>:' }
    Write-FixLine "  note: set NUGET_PACKAGES=$nd\$WorkDirName\.nuget\packages for the jobs only (LanQueue machines.yml env:, or that account's own environment), never for the whole machine"
  }
  if ($Id -eq 'defender.exclude') {
    Write-FixLine '  note: the self-test writes the harmless EICAR test file: Defender shows notifications and keeps threat history entries for it'
    if ($S.Linked) { Write-FixLine '  WARNING: EnableLinkedConnections is 1: drive letters a user maps are visible to elevated programs too. lanq-work is on the system drive, so it is not affected; check that the setting is intended (docs/TUNE.md)' 'Yellow' }
  }
  foreach ($c in (Get-FixCommand $Id 'apply' $S $S)) { Write-FixLine "  command: $c" 'Cyan' }
  foreach ($c in (Get-FixCommand $Id 'undo' $S $S)) { Write-FixLine "  undo:    $c" }
}

# The Defender ladder is confirmed by typing what it makes (the folder path, or the VHDX file); the others by y/N.
function Confirm-FixFor([string]$Id, $S) {
  if (@($DefenderFixIds) -notcontains $Id) { return (Confirm-Fix) }
  $want = "$($S.Drive):\$WorkDirName"; if ($Id -eq 'devdrive.create') { $want = $DevVhdFile }
  Write-FixLine "  Type $want to apply (anything else = no): " 'White' -NoNewline
  $a = Read-FixAnswer
  Write-Host ''
  return ("$a".Trim() -ne '' -and "$a".Trim().TrimEnd('\') -eq $want.TrimEnd('\'))
}

function Invoke-FixApply([bool]$Dry) {
  $elev = Test-FixElevated
  if ($Dry) { Write-FixLine "lanq-makeready-fix $ToolVersion dry run: shows each applicable fix and its undo; nothing is changed" }
  else { Write-FixLine "lanq-makeready-fix ${ToolVersion}: changes only what you confirm, one fix at a time (default no)" }
  $rec = $null; $failed = 0; $shown = 0
  $ids = $BaseFixIds
  if ($FixSet -eq 'tune') { $ids = $TuneFixIds; Write-FixLine 'Tune fixes (lanq-makeready-tune.ps1 reports these; none of them changes whether the PC is worker-ready).' }
  if ($FixSet -eq 'defender') { $ids = @('defender.exclude'); Write-FixLine "The Defender ladder (docs/TUNE.md): a Dev Drive (-CreateDevDrive) needs no exclusion and comes first. This adds the one exclusion $(Get-LanqWorkEntry (Get-SystemDriveLetter)) for a folder this script makes itself, after a self-test." }
  if ($FixSet -eq 'devdrive') { $ids = @('devdrive.create'); Write-FixLine 'The Defender ladder (docs/TUNE.md), first rung: a VHDX-backed Dev Drive with lanq-work on it. Defender scans it asynchronously (performance mode); no exclusion is added.' }
  if (@('defender', 'devdrive') -contains $FixSet) {
    $script:FixUser = Get-BuildUser $FixBuildUser
    $why = Get-BuildUserProblem $FixUser
    if ($why) { Write-FixErr "lanq-makeready-fix: -BuildUser $(Get-CleanName $FixBuildUser): $why. Nothing was changed."; return 2 }
  }
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
    if (-not (Confirm-FixFor $id $s)) { Write-FixLine '  not applied'; continue }
    $s2 = Get-FixState $id $target   # the precondition, re-read just before the change
    $n2 = Get-FixNote $id $s2; if ($n2) { Write-FixLine "  not applied: $n2" 'DarkYellow'; continue }
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

function Invoke-FixMain([string]$Mode = 'apply', [string]$UndoPath = '', [bool]$FromFile = $false, [string]$Set = 'base', [string]$Hours = '', [string]$BuildUser = '', [int]$SizeGB = 100) {
  $script:FixSet = $Set; $script:FixHours = $Hours; $script:FixBuildUser = $BuildUser; $script:FixSizeGB = $SizeGB; $script:FixUser = $null; $script:FixMade = ''
  $why = Get-FixRefusal $Mode $FromFile
  if ($why) { Write-FixErr "lanq-makeready-fix: $why"; return 3 }
  if ($Mode -eq 'list') { return (Show-FixRecords) }
  if ($Mode -eq 'undo') { return (Invoke-FixUndo $UndoPath) }
  return (Invoke-FixApply ($Mode -eq 'dry'))
}

# -Undo <file>, -Hours <window>, -BuildUser <account> and -SizeGB <GB> are read from the remaining arguments, so a
# missing value is a usage error (exit 2), not a binder error; so are the -DefenderExclusions and -CreateDevDrive
# switches. Returns @{ Path; Hours; BuildUser; SizeGB; Defender; DevDrive; Rest; Error }.
function Get-UndoArg([string[]]$Rest) {
  $out = @(); $seen = @{ undo = $null; hours = $null; builduser = $null; sizegb = $null; defender = $false; devdrive = $false }; $err = ''; $a = @($Rest | Where-Object { $null -ne $_ -and "$_" -ne '' })   # PowerShell 7 can hand over one empty element
  $what = @{ undo = 'a record file'; hours = 'a window like 22:00-07:00'; builduser = 'an account (the dedicated local account LanQueue builds as)'; sizegb = 'a size in GB' }
  for ($i = 0; $i -lt $a.Count; $i++) {
    if ($a[$i] -match '^-(?i:(undo|hours|builduser|sizegb))$') {
      $k = $Matches[1].ToLowerInvariant(); $nm = @{ undo = '-Undo'; hours = '-Hours'; builduser = '-BuildUser'; sizegb = '-SizeGB' }[$k]
      if ($null -ne $seen[$k]) { $err = "$nm given twice" }
      elseif ($i + 1 -ge $a.Count -or "$($a[$i + 1])" -eq '' -or "$($a[$i + 1])".StartsWith('-')) { $err = "$nm needs $($what[$k])" }
      else { $seen[$k] = $a[$i + 1]; $i++ }
    }
    elseif ($a[$i] -match '^-(?i:DefenderExclusions)$') { $seen.defender = $true }
    elseif ($a[$i] -match '^-(?i:CreateDevDrive)$') { $seen.devdrive = $true }
    else { $out += $a[$i] }
  }
  return @{ Path = $seen.undo; Hours = $seen.hours; BuildUser = $seen.builduser; SizeGB = $seen.sizegb; Defender = $seen.defender; DevDrive = $seen.devdrive; Rest = $out; Error = $err }
}

# '' when the tune arguments are usable, else the usage error.
function Get-TuneArgError($Ua, [bool]$TuneOn, [string]$Mode) {
  $dx = ($Ua.Defender -or $Ua.DevDrive)
  if (-not $TuneOn -and $null -ne $Ua.Hours) { return '-Hours goes with -Tune' }
  if (-not $TuneOn -and $dx) { return '-DefenderExclusions and -CreateDevDrive go with -Tune' }
  if ($TuneOn -and @('undo', 'list') -contains $Mode) { return '-Tune goes with -WhatIf or alone; -Undo and -List handle every record' }
  if ($Ua.Defender -and $Ua.DevDrive) { return 'use only one of -DefenderExclusions and -CreateDevDrive' }
  if ($dx -and $null -ne $Ua.Hours) { return '-Hours goes with the other tune fixes, not with -DefenderExclusions or -CreateDevDrive' }
  if ($dx -and $null -eq $Ua.BuildUser) { $sw = '-DefenderExclusions'; if ($Ua.DevDrive) { $sw = '-CreateDevDrive' }; return "$sw needs -BuildUser <account> (the dedicated local account LanQueue builds as)" }
  if (-not $dx -and $null -ne $Ua.BuildUser) { return '-BuildUser goes with -DefenderExclusions or -CreateDevDrive' }
  if ($null -ne $Ua.SizeGB -and -not $Ua.DevDrive) { return '-SizeGB goes with -CreateDevDrive' }
  if ($null -ne $Ua.SizeGB -and ("$($Ua.SizeGB)" -notmatch '^[0-9]{2,5}$' -or [int]$Ua.SizeGB -lt 50 -or [int]$Ua.SizeGB -gt 65536)) { return '-SizeGB must be a whole number of GB from 50 to 65536' }
  if ($null -ne $Ua.BuildUser -and "$($Ua.BuildUser)" -cnotmatch '^[A-Za-z0-9][A-Za-z0-9 ._$@\\-]{0,63}$') { return '-BuildUser must be an account name (letters, digits, space, . _ $ @ \ -)' }
  if ($null -ne $Ua.Hours -and ($Ua.Hours -notmatch '^([01]\d|2[0-3]):([0-5]\d)-([01]\d|2[0-3]):([0-5]\d)$' -or $Ua.Hours.Split('-')[0] -eq $Ua.Hours.Split('-')[1])) { return '-Hours must look like 00:00-07:00 (HH:mm-HH:mm, start different from end)' }
  return ''
}

# ---------- main ----------

if ($env:LANQ_MAKEREADY_FIX_LIB -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
$Usage = 'usage: lanq-makeready-fix.ps1 [-WhatIf | -Undo <record file> | -List] [-Tune [-Hours HH:mm-HH:mm | -CreateDevDrive -BuildUser <account> [-SizeGB 100] | -DefenderExclusions -BuildUser <account>]]   (no -Yes or -Force: every change is confirmed one by one)'
$ua = Get-UndoArg $Extra
if ($ua.Error) { [Console]::Error.WriteLine("lanq-makeready-fix: $($ua.Error)"); [Console]::Error.WriteLine($Usage); exit 2 }
if (@($ua.Rest).Count -gt 0) { [Console]::Error.WriteLine("lanq-makeready-fix: unknown argument(s): $(@($ua.Rest) -join ' ')"); [Console]::Error.WriteLine($Usage); exit 2 }
if ($Help) { Write-Host $Usage; exit 0 }
$mode = 'apply'; $n = 0
if ($WhatIf) { $mode = 'dry'; $n++ }
if ($null -ne $ua.Path) { $mode = 'undo'; $n++ }
if ($List) { $mode = 'list'; $n++ }
if ($n -gt 1) { [Console]::Error.WriteLine('lanq-makeready-fix: use only one of -WhatIf, -Undo and -List'); exit 2 }
$te = Get-TuneArgError $ua ([bool]$Tune) $mode
if ($te) { [Console]::Error.WriteLine("lanq-makeready-fix: $te"); [Console]::Error.WriteLine($Usage); exit 2 }
$set = 'base'; if ($Tune) { $set = 'tune' }; if ($ua.Defender) { $set = 'defender' } elseif ($ua.DevDrive) { $set = 'devdrive' }
$size = 100; if ($null -ne $ua.SizeGB) { $size = [int]$ua.SizeGB }
$FixSet = $set
$fromFile = Test-FixFromFile $FixInvocation
$why = Get-FixRefusal $mode $fromFile
if ($why) { [Console]::Error.WriteLine("lanq-makeready-fix: $why"); exit 3 }
if ($env:LANQ_MAKEREADY_FIX_LIB -eq '1') { [Console]::Error.WriteLine('lanq-makeready-fix: LANQ_MAKEREADY_FIX_LIB=1 is only for tests that dot-source this file; unset it.'); exit 2 }
exit (Invoke-FixMain -Mode $mode -UndoPath "$($ua.Path)" -FromFile $fromFile -Set $set -Hours "$($ua.Hours)" -BuildUser "$($ua.BuildUser)" -SizeGB $size)
