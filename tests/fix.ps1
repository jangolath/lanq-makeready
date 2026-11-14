# Tests for lanq-makeready-fix.ps1 (no Pester). Works on Windows PowerShell 5.1 and pwsh 7.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\fix.ps1
# SAFETY: every apply/undo here runs against fakes (state, cmdlets, Invoke-Native, the record store); the names the
# fixes touch are pointed at things that do not exist, and the run stops before any scenario if a fake is missing.
# Child processes are started only for refusals and argument errors, always with LANQ_MAKEREADY_FIX_LIB=1, which makes
# a direct run exit 2 right after the refusal checks, so even a broken refusal never reaches the fixes.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$fixPath = Join-Path $root 'lanq-makeready-fix.ps1'
$script:pass = 0; $script:fail = 0
function Assert-Equal($Actual, $Expected, [string]$Name) {
  if ("$Actual" -ceq "$Expected") { $script:pass++; Write-Host "  ok   $Name" }
  else {
    $script:fail++; Write-Host "  FAIL $Name : expected '$Expected' got '$Actual'" -ForegroundColor Red
    if ($script:LastChild) { Write-Host "       child exit $($script:LastChild.Code); stdout: $($script:LastChild.Out.Trim()); stderr: $($script:LastChild.Err.Trim())" }
  }
}
function Assert-True($Cond, [string]$Name) { Assert-Equal ([bool]$Cond) 'True' $Name }

foreach ($v in 'SSH_CONNECTION', 'SSH_CLIENT', 'SSH_TTY') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
$env:LANQ_MAKEREADY_FIX_LIB = '1'
. $fixPath
Remove-Item Env:\LANQ_MAKEREADY_FIX_LIB
$RealFixState = ${function:Get-FixState}   # the tune tests run the real state readers over faked low-level reads

Write-Host 'pure helpers'
foreach ($y in 'y', 'Y', 'yes', ' YES ', 'Yes') { Assert-True (Test-Yes $y) "Test-Yes '$y' is yes" }
foreach ($n in '', 'n', 'no', 'ye', 'yy', '1', 'yes please', $null) { Assert-True (-not (Test-Yes $n)) "Test-Yes '$n' is no" }
Assert-Equal (Get-PowercfgAcSeconds "  Current AC Power Setting Index: 0x00000708") 1800 'powercfg: AC 30 min = 1800'
Assert-Equal (Get-PowercfgAcSeconds "x`r`n Aktueller Wechselstromeinstellungsindex: 0x00000258`r`n Aktueller Gleichstromeinstellungsindex: 0x00000000`r`n") 600 'powercfg: localized output'
Assert-True ($null -eq (Get-PowercfgAcSeconds 'garbage')) 'powercfg: unparseable -> null'
Assert-Equal (ConvertTo-TimeText ([datetime]::SpecifyKind([datetime]'2026-11-13 10:00:05', 'Utc'))) '2026-11-13T10:00:05Z' 'PowerShell 7 reads record times as [datetime]: turned back into the written text'
Assert-Equal (ConvertTo-TimeText '2026-11-13T10:00:05Z') '2026-11-13T10:00:05Z' 'a time string stays as it is'
Assert-True (Test-OnlyAdminsSystem 'D:PAI(A;;FA;;;BA)(A;;FA;;;SY)') 'DACL with BA and SY only: ok'
Assert-True (-not (Test-OnlyAdminsSystem 'D:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;BU)')) 'DACL with Users: not ok'
$okStates = @(@('ssh.start', 'starttype=Manual status=Stopped'), @('ssh.auto', 'starttype=Disabled status=Running'), @('power.sleep', 'scheme=381b4222-f694-41f0-9685-ff5bb260df2e standby=1800 hibernate=-'),
  @('power.sleep', 'scheme=381b4222-f694-41f0-9685-ff5bb260df2e standby=0 hibernate=3600'), @('longpaths.on', 'value=- type=none'), @('longpaths.on', 'value=0 type=dword'), @('git.longpaths', 'value=false'), @('git.longpaths', 'value=-'),
  @('ssh.aclkeys', 'dacl=D:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;BU)(A;;FA;;;S-1-5-21-1-2-3-1001)'))
foreach ($s in $okStates) { Assert-True ($null -ne (ConvertFrom-StateText $s[0] $s[1])) "state shape accepted: $($s[0]) $($s[1])" }
$badStates = @(@('ssh.start', 'starttype=Manual status=Stopped; Stop-Computer'), @('ssh.start', 'starttype=$(x) status=Stopped'), @('ssh.auto', 'starttype=Boot status=Running'),
  @('power.sleep', 'scheme=381b4222-f694-41f0-9685-ff5bb260df2e standby=99999999999 hibernate=0'), @('power.sleep', 'scheme=381b4222-f694-41f0-9685-ff5bb260df2e standby=-1 hibernate=0'), @('power.sleep', 'standby=1800 hibernate=0'),
  @('power.sleep', 'scheme=381B4222-F694-41F0-9685-FF5BB260DF2E standby=1800 hibernate=0'), @('power.sleep', 'scheme=x standby=1800 hibernate=0'), @('longpaths.on', 'value=1;x type=dword'), @('longpaths.on', 'value=0'),
  @('longpaths.on', 'value=1 type=string'), @('longpaths.on', 'value=- type=dword'), @('git.longpaths', "value=true'"),
  @('git.longpaths', 'value=a b'), @('ssh.aclkeys', 'dacl=D:(XA;;FA;;;WD;(@User.x == "y"))'), @('ssh.aclkeys', "dacl=D:(A;;FA;;;BA)')"), @('evil.fix', 'value=1'), @('power.sleep', ''))
foreach ($s in $badStates) { Assert-True ($null -eq (ConvertFrom-StateText $s[0] $s[1])) "state shape rejected: $($s[0]) '$($s[1])'" }

Write-Host 'M1(b) a saved keys-file DACL is put back only when it is safe'
Assert-Equal (Test-SafeRestoreDacl 'D:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;BU)') '' 'the usual inherited DACL is safe to restore'
Assert-Equal (Test-SafeRestoreDacl 'D:P(A;;GA;;;BA)(A;;FA;;;SY)') '' 'generic-all counts as full control'
foreach ($d in @(@('D:(A;;FA;;;WD)', 'would not both keep full control'), @('D:', 'empty DACL'), @('D:NO_ACCESS_CONTROL', 'NULL DACL'), @('D:P(D;;FA;;;BA)(A;;FA;;;BA)(A;;FA;;;SY)', 'deny entry'),
    @('D:P(D;;FA;;;WD)(A;;FA;;;BA)(A;;FA;;;SY)', 'deny entry'), @('D:P(A;;FA;;;BA)(A;;FR;;;SY)', 'would not both keep full control'), @('D:P(A;;FA;;;SY)', 'would not both keep full control'))) {
  Assert-True ((Test-SafeRestoreDacl $d[0]) -match $d[1]) "unsafe to restore: $($d[0]) ($($d[1]))"
}
Assert-Equal (Get-DaclCore 'D:AI(A;;FA;;;S-1-5-21-1-2-3-1001)(A;ID;FA;;;SY)(A;ID;FA;;;BA)') (Get-DaclCore 'D:AI(A;;FA;;;S-1-5-21-1-2-3-1001)(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;BU)') 'M1(d) inherited entries do not count when comparing'
Assert-True ((Get-DaclCore 'D:PAI(A;;FA;;;BA)') -cne (Get-DaclCore 'D:AI(A;;FA;;;BA)')) 'M1(d) the protection flag counts'
Assert-Equal (Get-RestoreDacl 'D:AI(A;;FA;;;S-1-5-21-1-2-3-1001)(A;ID;FA;;;SY)') 'D:AI(A;;FA;;;S-1-5-21-1-2-3-1001)' 'M1(d) restore = flags + explicit entries'
Assert-True ((Test-SafeUndoDacl 'D:PAI(A;;FA;;;BU)(A;ID;FA;;;BA)(A;ID;FA;;;SY)') -match 'what undo writes') 'R2: a protected DACL whose explicit entries lack Administrators/SYSTEM: what undo writes is checked, refused'
Assert-Equal (Test-SafeUndoDacl 'D:AI(A;;FA;;;BU)(A;ID;FA;;;BA)(A;ID;FA;;;SY)') '' 'R2: unprotected: the folder hands Administrators and SYSTEM back, accepted'
Assert-True (Test-SameState 'ssh.aclkeys' 'dacl=D:PAI(A;;FA;;;BA)(A;;FA;;;SY)' 'dacl=D:PAI(A;;FA;;;SY)(A;;FA;;;BA)') 'R9: the same entries in another order are the same state'
Assert-Equal ((Get-ExplicitOthers 'D:AI(A;;FA;;;S-1-5-21-1-2-3-1001)(A;;FA;;;BA)(A;ID;FA;;;BU)') -join ',') 'S-1-5-21-1-2-3-1001' 'R9: explicit entries for others than Administrators and SYSTEM'
Assert-Equal (Get-AccountName 'S-1-5-32-545') 'BUILTIN\Users' 'account names: translated'
Assert-Equal (Get-AccountName 'S-1-5-21-1-2-3-1001') 'S-1-5-21-1-2-3-1001' 'account names: the SID when unknown'
$fd = (Format-Dacl 'D:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;BU)(A;;FA;;;S-1-5-21-1-2-3-1001)') -join "`n"
Assert-True ($fd -match 'allow NT AUTHORITY\\SYSTEM : FullControl \(inherited\)' -and $fd -match 'BUILTIN\\Users : ReadAndExecute' -and $fd -match 'S-1-5-21-1-2-3-1001 : FullControl') 'M1(c) DACL in words: names, rights, SID when unknown'
Assert-True ((Format-Dacl 'D:P(D;;FA;;;WD)(A;;FA;;;BA)') -join ' ' -match 'DENY') 'M1(c) deny entries are shown as DENY'

Write-Host 'M1(a) trusted record folder and files'
Assert-Equal (Test-TrustedSddl $RecordDirSddl) '' 'the folder this script makes is trusted'
Assert-Equal (Test-TrustedSddl $RecordFileSddl) '' 'the record files this script makes are trusted'
Assert-Equal (Test-TrustedSddl 'O:SYG:SYD:AI(A;ID;FA;;;BA)(A;ID;FA;;;SY)(A;ID;0x1200a9;;;BU)') '' 'others may read: still trusted'
foreach ($d in @(@('O:S-1-5-21-1-2-3-1001G:SYD:PAI(A;;FA;;;BA)', 'owned by S-1-5-21-1-2-3-1001'), @('O:BAG:SYD:AI(A;ID;FA;;;BA)(A;OICIIO;0x100116;;;BU)', 'BUILTIN\Users may change it'),
    @('O:BAG:SYD:PAI(A;;FA;;;BA)(A;;FA;;;S-1-5-21-1-2-3-1001)', 'may change it'), @('O:BAG:SYD:NO_ACCESS_CONTROL', 'no DACL'), @('O:BAG:SYD:PAI(A;;0x40000;;;AU)', 'may change it'))) {
  Assert-True ((Test-TrustedSddl $d[0]) -match [regex]::Escape($d[1])) "not trusted: $($d[0])"
}
Assert-True ($RecordDirSddl -cmatch '^O:BA' -and $RecordDirSddl -cmatch 'D:PAI') 'the record folder is owned by Administrators and protected (no inheritance)'

Write-Host 'M-B (round 4): the folder above the record folder and the drive root are checked too (every elevated fix)'
$PdDefault = 'O:SYG:SYD:PAI(A;OICIIO;GA;;;CO)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)(A;CI;0x116;;;BU)'   # the Windows default C:\ProgramData
$RootDef = 'O:S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464G:S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464D:(A;;LC;;;AU)(A;OICIIO;SDGXGWGR;;;AU)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'
Assert-Equal (Get-ParentRisk $PdDefault).Why '' 'M-B: the default C:\ProgramData passes (Users may add files and folders; CREATOR OWNER is inherit-only)'
foreach ($c in @(@('O:SYG:SYD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)', 'S-1-1-0', 'Everyone full control (this dev PC)'), @('O:SYG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x10000;;;AU)', 'S-1-5-11', 'DELETE for Authenticated Users'),
    @('O:SYG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;CI;0x40;;;BU)', 'S-1-5-32-545', 'DELETE_CHILD for Users'), @('O:SYG:SYD:PAI(A;OICI;FA;;;SY)(A;CI;WD;;;BU)', 'S-1-5-32-545', 'WRITE_DAC for Users'))) {
  $pr = Get-ParentRisk $c[0]; Assert-True ($pr.Why -match 'may delete or rename' -and $pr.Sid -eq $c[1]) "M-B: refused: $($c[2]) (names $($c[1]))"
}
Assert-True ((Get-ParentRisk 'O:S-1-5-21-1-2-3-1001G:SYD:PAI(A;OICI;FA;;;BA)').Why -match 'owned by') 'M-B: a C:\ProgramData owned by a user is refused'
Assert-True ((Get-ParentRisk '').Why -ne '' -and (Get-ParentRisk 'O:SYG:SYD:PAI(A;OICI;FA;;;BA)(XA;;0x1;;;WD;(@User.x == "y"))').Why -ne '') 'M-B: unreadable or conditional: refused'
$realPathSddl = ${function:Get-PathSddl}; $realRecDir = ${function:Get-FixRecordDir}
$script:Psd = @{}
function Get-PathSddl([string]$Path) { $v = $script:Psd[$Path.TrimEnd('\')]; if ($null -eq $v) { return '' }; return $v }
$rdT = 'C:\ProgramData\lanq-makeready'
$script:Psd = @{ 'C:\ProgramData\lanq-makeready' = $RecordDirSddl; 'C:\ProgramData' = $PdDefault; 'C:' = $RootDef }
Assert-Equal (Test-FixRecordDirTrusted $rdT) '' 'M-B: the record folder under the default C:\ProgramData on the default C:\ is trusted'
$script:Psd['C:\ProgramData'] = 'O:SYG:SYD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
$w = Test-FixRecordDirTrusted $rdT
Assert-True ($w -match 'C:\\ProgramData' -and $w -match 'rename or replace' -and $w -match 'Everyone' -and $w -match [regex]::Escape('icacls "C:\ProgramData" /remove:g *S-1-1-0')) 'M-B: C:\ProgramData with Everyone full control: refused, says what is wrong and how to restore the default (text only)'
$script:Psd['C:\ProgramData'] = ''
Assert-True ((Test-FixRecordDirTrusted $rdT) -match 'link or its permissions cannot be read') 'M-B: C:\ProgramData a link (or unreadable): refused'
$script:Psd['C:\ProgramData'] = $PdDefault; $script:Psd['C:'] = 'O:SYG:SYD:PAI(A;OICI;FA;;;BA)(A;;0x40;;;AU)'
Assert-True ((Test-FixRecordDirTrusted $rdT) -match 'drive root') 'M-B: a drive root others may rename in: refused'
$script:Psd['C:'] = $RootDef; $script:Psd['C:\ProgramData'] = 'O:SYG:SYD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
function Get-FixRecordDir { return 'C:\ProgramData\lanq-test-none-0f3c' }
Assert-True ((Get-FixRecordDirProblem) -match 'rename or replace') 'M-B: the record folder does not exist yet: the folder above it is checked before it is made'
$script:Psd['C:\ProgramData'] = $PdDefault
Assert-Equal (Get-FixRecordDirProblem) '' 'M-B: missing record folder under a default C:\ProgramData: fine (it is made later)'
Set-Item -Path Function:\Get-PathSddl -Value $realPathSddl; Set-Item -Path Function:\Get-FixRecordDir -Value $realRecDir

Write-Host 'L5 key lines are shown before asking'
$ks = Get-AuthKeySummary @('# comment', '', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample build@build-01', 'command="x" ssh-rsa AAAAB3NzaC1yc2E= old-key', 'garbage')
Assert-Equal @($ks).Count 3 'three non-comment lines'
Assert-True ($ks[0] -match '^ssh-ed25519 SHA256:[A-Za-z0-9+/]{43} build@build-01$') 'type, SHA256 fingerprint and comment'
Assert-True ($ks[1] -match 'with options' -and $ks[2] -match 'cannot read') 'options and unreadable lines are flagged'
$ks = Get-AuthKeySummary @('command="echo ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample planted" ssh-rsa AAAAB3NzaC1yc2E= real-key', 'from="10.20.30.0/24",command="a \"b c\"" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample k2')
Assert-True ($ks[0] -match '^ssh-rsa SHA256:\S+ real-key \(with options\)$') 'R3: a key type inside a quoted option value is not taken for the key'
Assert-True ($ks[1] -match '^ssh-ed25519 SHA256:\S+ k2 \(with options\)$') 'R3: escaped quotes inside an option value'

Write-Host 'M2 over-SSH detection (Windows): parent walk with a deadline, PID reuse, session 0'
$t0 = [datetime]'2026-11-13 08:00:00'
$procs = @([pscustomobject]@{ Id = 100; Parent = 50; Name = 'powershell.exe'; Created = $t0.AddMinutes(5) }, [pscustomobject]@{ Id = 50; Parent = 40; Name = 'cmd.exe'; Created = $t0.AddMinutes(4) },
  [pscustomobject]@{ Id = 40; Parent = 4; Name = 'sshd-session.exe'; Created = $t0.AddMinutes(3) })
Assert-Equal ((Get-AncestorNames $procs 100) -join ',') 'cmd.exe,sshd-session.exe' 'ancestors, nearest first'
$reused = @($procs[0], [pscustomobject]@{ Id = 50; Parent = 40; Name = 'sshd.exe'; Created = $t0.AddMinutes(9) })
Assert-Equal ((Get-AncestorNames $reused 100) -join ',') '' 'C11: a "parent" that started after its child is a reused PID: not counted'
function Get-FixProcessTable { return $script:FakeProcs }
function Get-FixSessionId { return $script:FakeSession }
$script:FakeProcs = @($procs | ForEach-Object { if ($_.Id -eq 100) { [pscustomobject]@{ Id = $PID; Parent = 50; Name = 'powershell.exe'; Created = $_.Created } } else { $_ } })
$script:FakeSession = 2
$FixWalkCache = $null; Assert-True (Test-FixOverSsh) 'sshd among the parents: over SSH'
$script:FakeProcs = @([pscustomobject]@{ Id = $PID; Parent = 50; Name = 'powershell.exe'; Created = $t0 }, [pscustomobject]@{ Id = 50; Parent = 4; Name = 'explorer.exe'; Created = $t0.AddMinutes(-1) })
$FixWalkCache = $null; Assert-True (-not (Test-FixOverSsh)) 'a desktop session: not over SSH'
$script:FakeProcs = $null; $script:FakeSession = 0
$FixWalkCache = $null; Assert-True (Test-FixOverSsh) 'process list unreadable (CIM failed or timed out) in session 0: refused, not passed'
$script:FakeSession = 1
$FixWalkCache = $null; Assert-True (-not (Test-FixOverSsh)) 'process list unreadable in a desktop session: not counted as SSH'
$script:FakeSession = 0
Assert-True (-not (Test-FixConsole)) 'session 0 is never an interactive console'
$FixWalkCache = $null; $script:FakeProcs = $null; $script:FakeSession = 0; [void](Test-FixOverSsh); $script:FakeSession = 1
Assert-True (Test-FixOverSsh) 'R9: the parent walk runs once per process (a cached answer is reused)'
$env:LANQ_MAKEREADY_FIX_LIB = '1'; . $fixPath; Remove-Item Env:\LANQ_MAKEREADY_FIX_LIB   # the real Get-FixProcessTable and Get-FixSessionId again
$sw = [Diagnostics.Stopwatch]::StartNew(); $pt = Get-FixProcessTable 15
Assert-True (@($pt).Count -gt 0 -and $sw.Elapsed.TotalSeconds -lt 20) 'the real process table is read within its deadline'

Write-Host 'C9 -Undo argument'
Assert-Equal (Get-UndoArg @('-Undo', 'C:\r.json')).Path 'C:\r.json' '-Undo <file>'
Assert-True ((Get-UndoArg @('-Undo')).Error -match 'needs a record file') '-Undo alone: usage error'
Assert-True ((Get-UndoArg @('-undo', '-List')).Error -match 'needs a record file') '-Undo followed by a flag: usage error'
Assert-True ((Get-UndoArg @('-Undo', 'a', '-Undo', 'b')).Error -match 'twice') '-Undo twice: usage error'
Assert-Equal ((Get-UndoArg @('-Yes')).Rest -join ',') '-Yes' 'other arguments stay unknown'
Assert-True (@((Get-UndoArg $null).Rest).Count -eq 0 -and @((Get-UndoArg @('')).Rest).Count -eq 0 -and -not (Get-UndoArg @($null)).Error) 'no remaining arguments (PowerShell 7 may pass one empty element): nothing unknown'

Write-Host 'state reads on this machine (read-only: Get-Service, powercfg /q, git config --get/--list, registry, Get-Acl)'
foreach ($id in $FixIds) { $st = Get-FixState $id; Assert-True ($st -is [hashtable]) "Get-FixState $id returns a state" }
$gs = Get-FixState 'git.longpaths'
if ($gs.Git) { Assert-True ($gs.Trusted -eq ($gs.Git -match '\\Program Files')) "L2 git found at $($gs.Git) (trusted only under Program Files or Windows)" }
$ast0 = [System.Management.Automation.Language.Parser]::ParseFile($fixPath, [ref]$null, [ref]$null)
$defined = @($ast0.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name } | Sort-Object)
Assert-Equal ($defined -join ',') (@($FixFunctionNames | Sort-Object) -join ',') 'the alias-shadow check knows every function of the script'

Write-Host 'guard (AST allow-list; mutations only inside the FIXES functions)'
function Get-FixGuardViolations([string]$Path) {
  $SA = 'System.Management.Automation.Language'
  $bad = New-Object System.Collections.ArrayList
  $tokens = $null; $perr = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$perr)
  if (@($perr).Count -gt 0) { return @("parse errors") }
  $text = [System.IO.File]::ReadAllText($Path)
  $r0 = [regex]::Matches($text, '(?m)^#region FIXES\r?$'); $r1 = [regex]::Matches($text, '(?m)^#endregion FIXES\r?$')
  if ($r0.Count -ne 1 -or $r1.Count -ne 1) { return @("exactly one #region FIXES ... #endregion FIXES") }
  $s0 = $r0[0].Index; $s1 = $r1[0].Index
  $inR = { param($N) $N.Extent.StartOffset -gt $s0 -and $N.Extent.EndOffset -lt $s1 }
  $fdefs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
  $funcNames = @($fdefs | ForEach-Object { $_.Name })
  $regionFns = @($fdefs | Where-Object { & $inR $_ } | ForEach-Object { $_.Name })
  if (($regionFns -join ',') -ne 'Get-FixCommand,Assert-Native,Invoke-FixChange') { [void]$bad.Add("functions in FIXES must be exactly Get-FixCommand, Assert-Native, Invoke-FixChange (found: $($regionFns -join ', '))") }
  $fnOf = { param($Node) $p = $Node.Parent; while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }; $p = $p.Parent }; return '' }
  $read = @('Get-Service', 'Get-CimInstance', 'Get-Command', 'Get-Item', 'Get-Acl', 'Get-ChildItem', 'Get-Content', 'Get-Alias', 'Test-Path', 'Join-Path', 'Split-Path',
    'Get-NetAdapter', 'Get-PhysicalDisk', 'Get-ScheduledTask', 'Get-MpComputerStatus', 'Get-MpPreference', 'Get-MpThreatDetection', 'Get-Volume', 'Get-Partition', 'Get-Disk', 'Get-DiskImage',
    'Get-CimAssociatedInstance', 'Select-Object', 'Where-Object', 'ForEach-Object', 'Sort-Object', 'ConvertFrom-Json', 'Write-Host', 'New-Object', 'Get-Location',
    'Microsoft.PowerShell.Utility\Get-Alias', 'Microsoft.PowerShell.Core\Get-Command')
  $mut = @('Set-Service', 'Start-Service', 'Stop-Service', 'Set-ItemProperty', 'Remove-ItemProperty', 'Set-Acl', 'New-Item', 'Disable-ScheduledTask', 'Enable-ScheduledTask',
    'Set-MpPreference', 'Add-MpPreference', 'Remove-MpPreference', 'Initialize-Disk', 'New-Partition', 'Format-Volume')
  $callers = @{ 'Invoke-FixChange' = @('Invoke-FixApply', 'Invoke-FixUndo'); 'Assert-Native' = @('Invoke-FixChange'); 'New-FixSecuredDir' = @('Initialize-FixRecordDir', 'Invoke-FixChange'); 'New-FixSecuredFile' = @('Save-FixRecord')
    'Get-EicarBytes' = @('Invoke-FixChange') }
  $okNative = @("`$PowercfgExe|@('/q', 'SCHEME_CURRENT', 'SUB_SLEEP', 'STANDBYIDLE')", "`$PowercfgExe|@('/q', 'SCHEME_CURRENT', 'SUB_SLEEP', 'HIBERNATEIDLE')",
    "`$PowercfgExe|@('/getactivescheme')", "`$git|@('config', '--system', '--show-origin', '--get', 'core.longpaths')", "`$git|@('config', '--system', '--show-origin', '--list')", "`$git|@('config', '--get', 'core.longpaths')",
    "`$PowercfgExe|@('/q', 'SCHEME_CURRENT', `$Sub, `$Setting)", "`$FsutilExe|@('devdrv', 'query', `"`$L``:`")", "`$FsutilExe|@('file', 'queryCaseSensitiveInfo', (Get-DriveRoot `$L))",
    "`$FsutilExe|@('file', 'queryfileid', `$Path)")
  $okTypes = @('System.Diagnostics.ProcessStartInfo', 'Security.Principal.WindowsPrincipal', 'System.Text.UTF8Encoding', 'System.Collections.ArrayList', 'System.IO.FileInfo',
    'System.Security.AccessControl.RawSecurityDescriptor', 'System.Security.AccessControl.DirectorySecurity', 'System.Security.AccessControl.FileSecurity', 'System.IO.DirectoryInfo',
    'System.IO.FileStream', 'System.Security.Principal.NTAccount')
  foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $n = $c.GetCommandName(); $in = & $inR $c; $fn = & $fnOf $c
    if (-not $n) { [void]$bad.Add("dynamic command: $($c.Extent.Text)"); continue }
    if ($mut -contains $n) {
      if (-not ($in -and $fn -eq 'Invoke-FixChange')) { [void]$bad.Add("mutating command $n outside Invoke-FixChange ('$fn')") }
      continue
    }
    if ($read -notcontains $n -and $funcNames -notcontains $n) { [void]$bad.Add("command $n is not on the allow-list") }
    if ($callers.ContainsKey($n) -and $callers[$n] -notcontains $fn) { [void]$bad.Add("$n called from '$fn'") }
    if ($n -eq 'Invoke-Native' -and $fn -ne 'Invoke-Native') {
      $exe = $c.CommandElements[1].Extent.Text
      if ($in) { if ($fn -ne 'Invoke-FixChange' -or @('$PowercfgExe', '$IcaclsExe', '$Cur.Git', '$ScExe', '$DiskpartExe') -notcontains $exe) { [void]$bad.Add("Invoke-Native in FIXES with $exe") } }
      else {
        $k = $exe + '|' + $(if ($c.CommandElements.Count -gt 2) { $c.CommandElements[2].Extent.Text } else { '' })
        if ($okNative -notcontains $k) { [void]$bad.Add("Invoke-Native outside FIXES with other than a read: $k") }
      }
    }
    if ($n -eq 'ForEach-Object' -and -not ($c.CommandElements.Count -gt 1 -and $c.CommandElements[1] -is [System.Management.Automation.Language.ScriptBlockExpressionAst])) { [void]$bad.Add("ForEach-Object without a script block: $($c.Extent.Text)") }
    if ($n -eq 'New-Object' -and $okTypes -notcontains $c.CommandElements[1].Extent.Text.Trim("'`"")) { [void]$bad.Add("New-Object $($c.CommandElements[1].Extent.Text)") }
    # A1/A2: the one exclusion this script adds is the fixed <drive>:\lanq-work\ string, never a path from anywhere else
    if ($n -eq 'Add-MpPreference' -and $c.Extent.Text -cne 'Add-MpPreference -ExclusionPath $entry -ErrorAction Stop') { [void]$bad.Add("Add-MpPreference other than with `$entry: $($c.Extent.Text)") }
  }
  foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$entry' }, $true)) {
    if ($a.Right.Extent.Text -cne 'Get-LanqWorkEntry $B.Drive') { [void]$bad.Add("`$entry is set from other than Get-LanqWorkEntry `$B.Drive: $($a.Extent.Text)") }
  }
  $okMembers = @('Add', 'RemoveAt', 'Remove', 'Close', 'ReadToEndAsync', 'WaitForExit', 'Wait', 'Kill', 'Start', 'Trim', 'TrimEnd', 'Split', 'Replace', 'StartsWith', 'Substring',
    'ToString', 'GetSecurityDescriptorSddlForm', 'SetSecurityDescriptorSddlForm', 'GetOwner', 'Translate', 'IsInRole', 'GetCurrent', 'GetCurrentProcess', 'GetFolderPath', 'Matches',
    'ToInt64', 'Exists', 'ReadAllText', 'WriteAllText', 'Move', 'CreateDirectory', 'WriteLine', 'ReadLine', 'IsPathRooted', 'ContainsKey', 'Round', 'ToUniversalTime',
    'GetValueNames', 'GetValueKind', 'GetValue', 'Create', 'AddScript', 'BeginInvoke', 'WaitOne', 'BeginStop', 'EndInvoke', 'Dispose', 'ComputeHash', 'ToBase64String', 'FromBase64String',
    'GetFullPath', 'ToLowerInvariant', 'GetBytes', 'Write', 'Min', 'Floor', 'ToByte', 'WriteAllBytes', 'Delete', 'GetFileSystemEntries', 'Sleep', 'NewGuid', 'ToUpperInvariant', 'AddSeconds', 'IndexOf', 'StartNew', 'GetAccessControl', 'SetAccessControl')
  # 0.6.0: the EICAR test file is written, and the self-test folders deleted, only in Invoke-FixChange; lanq-work and the
  # self-test folders are created (with their permissions, in one call) only there too.
  $onlyIn = @{ 'WriteAllText' = @('Save-FixRecord'); 'Move' = @('Save-FixRecord', 'Invoke-FixChange'); 'CreateDirectory' = @('New-FixSecuredDir'); 'Start' = @('Invoke-Native'); 'Kill' = @('Invoke-Native')
    'Remove' = @('Invoke-Native'); 'SetSecurityDescriptorSddlForm' = @('Invoke-FixChange', 'New-FixSecuredDir', 'New-FixSecuredFile'); 'AddScript' = @('Get-FixProcessTable'); 'BeginStop' = @('Get-FixProcessTable')
    'Write' = @('New-FixSecuredFile', 'Invoke-Native'); 'WriteAllBytes' = @('Invoke-FixChange'); 'Delete' = @('Invoke-FixChange'); 'SetAccessControl' = @('Invoke-FixChange'); 'Sleep' = @('Wait-MpDetection') }
  foreach ($m in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
    $mn = $m.Member.Extent.Text; $fn = & $fnOf $m; $ex = $m.Expression.Extent.Text
    if ($okMembers -notcontains $mn) { [void]$bad.Add("member call $ex.$mn"); continue }
    if ($onlyIn.ContainsKey($mn) -and $onlyIn[$mn] -notcontains $fn) { [void]$bad.Add("$mn outside $($onlyIn[$mn] -join '/') ('$fn')") }
    if ($mn -eq 'Replace' -and $ex -match 'IO\.File' -and $fn -ne 'Save-FixRecord') { [void]$bad.Add('File.Replace outside Save-FixRecord') }
    # HIGH-2: in Invoke-FixChange a folder is moved only from the staging folder into place, and the test file is written
    # and folders deleted only through the variables the checked code sets ($f/$h after Test-SelfTestDir, $q)
    if ($fn -eq 'Invoke-FixChange' -and $mn -eq 'Move' -and ($ex -ne '[System.IO.Directory]' -or ($m.Arguments | ForEach-Object { $_.Extent.Text }) -join ',' -ne '$stage,$dst')) { [void]$bad.Add("Move other than Directory.Move(`$stage, `$dst): $($m.Extent.Text)") }
    if ($mn -eq 'WriteAllBytes' -and @('$f', '$h') -notcontains $m.Arguments[0].Extent.Text) { [void]$bad.Add("WriteAllBytes to other than `$f or `$h: $($m.Extent.Text)") }
    if ($mn -eq 'Delete' -and ($ex -ne '[System.IO.Directory]' -or $m.Arguments[0].Extent.Text -ne '$q')) { [void]$bad.Add("Delete other than Directory.Delete(`$q): $($m.Extent.Text)") }
    if ($mn -eq 'Create' -and -not (($ex -eq '[System.Management.Automation.PowerShell]' -and $fn -eq 'Get-FixProcessTable') -or ($ex -eq '[System.Security.Cryptography.SHA256]' -and @('Get-AuthKeySummary', 'Get-SdHash') -contains $fn) -or
        ($ex -eq '[System.IO.FileSystemAclExtensions]' -and @('New-FixSecuredDir', 'New-FixSecuredFile') -contains $fn))) { [void]$bad.Add("Create on $ex in '$fn'") }
    if ($mn -eq 'SetSecurityDescriptorSddlForm' -and $fn -ne 'Invoke-FixChange' -and @('$RecordDirSddl', '$RecordFileSddl') -notcontains $m.Arguments[0].Extent.Text -and -not ($fn -eq 'New-FixSecuredDir' -and $m.Arguments[0].Extent.Text -eq '$Sddl')) { [void]$bad.Add("SetSecurityDescriptorSddlForm with $($m.Arguments[0].Extent.Text) in '$fn'") }
    if ($mn -eq 'AddScript') {
      $arg = $m.Arguments[0]
      if ($arg -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { [void]$bad.Add('AddScript with other than a constant') }
      else {
        $sub = [System.Management.Automation.Language.Parser]::ParseInput($arg.Value, [ref]$null, [ref]$null)
        $sc = @($sub.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { "$($_.GetCommandName())" } | Where-Object { @('Get-CimInstance', 'ForEach-Object') -notcontains $_ })
        if ($sc.Count -gt 0) { [void]$bad.Add("AddScript runs $($sc -join ', ')") }
      }
    }
  }
  foreach ($m in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Static }, $true)) {
    if ($m.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) { [void]$bad.Add("static member through a variable: $($m.Extent.Text)") }
  }
  # member and index assignments only on local hashtables (and the ProcessStartInfo Invoke-Native fills); those
  # variables are never filled from a command or a .NET call (so $it can never be a FileInfo)
  $okRoots = @('$psi', '$s', '$item', '$it', '$seen', '$byId')
  $cmdNames = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
  foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
    if (@('$s', '$item', '$it', '$seen', '$byId') -contains $a.Left.Extent.Text) {
      $rc = @($a.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Where-Object { $funcNames -notcontains $_.GetCommandName() })
      $rm = @($a.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
      if ($rc.Count -gt 0 -or $rm.Count -gt 0) { [void]$bad.Add("$($a.Left.Extent.Text) is filled from a command or .NET call: $($a.Extent.Text)") }
    }
  }
  foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
    if (@('$s', '$item', '$it', '$seen', '$byId') -contains $f.Variable.Extent.Text -and @($f.Condition.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Where-Object { $funcNames -notcontains $_.GetCommandName() -and @('Where-Object', 'Sort-Object', 'ForEach-Object') -notcontains $_.GetCommandName() }).Count -gt 0) {
      [void]$bad.Add("foreach $($f.Variable.Extent.Text) over a command")
    }
  }
  foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $l = $a.Left
    while ($l -is [System.Management.Automation.Language.ConvertExpressionAst] -or $l -is [System.Management.Automation.Language.AttributedExpressionAst]) { $l = $l.Child }
    if ($l -is [System.Management.Automation.Language.VariableExpressionAst]) { if ($l.VariablePath.IsDriveQualified) { [void]$bad.Add("drive or env assignment $($l.Extent.Text)") }; continue }
    $r = $l
    while ($r -is [System.Management.Automation.Language.MemberExpressionAst] -or $r -is [System.Management.Automation.Language.IndexExpressionAst]) {
      if ($r -is [System.Management.Automation.Language.MemberExpressionAst]) { $r = $r.Expression } else { $r = $r.Target }
    }
    if ($r -isnot [System.Management.Automation.Language.VariableExpressionAst] -or $okRoots -notcontains $r.Extent.Text) { [void]$bad.Add("assignment to $($l.Extent.Text)") }
  }
  $dv = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.IsDriveQualified -and $n.VariablePath.DriveName -ne 'env' }, $true))
  if ($dv.Count -gt 0) { [void]$bad.Add('drive-qualified variable') }
  if (@($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.RedirectionAst] }, $true)).Count -gt 0) { [void]$bad.Add('redirection') }
  return $bad.ToArray()
}
$v = Get-FixGuardViolations $fixPath
Assert-Equal (@($v) -join '; ') '' 'fix script passes its guard'
$fixText = [System.IO.File]::ReadAllText($fixPath)
Assert-True ($fixText -notmatch '[^\x00-\x7F]') 'fix script is pure ASCII'
$mdir = Join-Path ([IO.Path]::GetTempPath()) ('lanq-fixmut-' + [Guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $mdir)
$mp = Join-Path $mdir 'm.ps1'
function Test-Mutant([string]$Name, [string]$Text) { [System.IO.File]::WriteAllText($mp, $Text); Assert-True (@(Get-FixGuardViolations $mp).Count -gt 0) "GuardRejectsMutationOutsideFixTable: $Name" }
$mutants = [ordered]@{
  'Set-Service outside FIXES'                = 'function Bad-One { Set-Service -Name sshd -StartupType Automatic }'
  'Stop-Service outside FIXES'               = 'function Bad-Two { Stop-Service -Name sshd }'
  'Set-ItemProperty outside FIXES'           = 'function Bad-Three { Set-ItemProperty -Path $FsKey -Name LongPathsEnabled -Value 1 }'
  'Remove-ItemProperty outside FIXES'        = 'function Bad-Four { Remove-ItemProperty -Path $FsKey -Name LongPathsEnabled }'
  'Set-Acl outside FIXES'                    = 'function Bad-Five { Set-Acl -LiteralPath $KeysFile -AclObject $a }'
  'powercfg /change outside FIXES'           = "function Bad-Six { Invoke-Native `$PowercfgExe @('/change', 'standby-timeout-ac', '0') }"
  'git config --system write outside'        = "function Bad-Seven { Invoke-Native `$git @('config', '--system', 'core.longpaths', 'true') }"
  'icacls outside FIXES'                     = "function Bad-Eight { Invoke-Native `$IcaclsExe @(`$KeysFile, '/grant', 'Everyone:F') }"
  'an exe by name'                           = 'function Bad-Nine { icacls.exe C:\x /grant Everyone:F }'
  'Invoke-Expression'                        = "function Bad-Ten { Invoke-Expression 'Stop-Computer' }"
  'dynamic call'                             = 'function Bad-Eleven { & $x }'
  'scriptblock Create'                       = "function Bad-Twelve { [scriptblock]::Create('x') }"
  'WriteAllText outside Save-FixRecord'      = "function Bad-Thirteen { [System.IO.File]::WriteAllText('C:\x', 'y') }"
  'env assignment'                           = "function Bad-Fourteen { `$env:PATH = 'x' }"
  'SDDL set outside FIXES'                   = "function Bad-Fifteen { `$a.SetSecurityDescriptorSddlForm('D:(A;;FA;;;WD)', 'Access') }"
  'Invoke-FixChange from elsewhere'          = "function Bad-Sixteen { Invoke-FixChange 'power.sleep' 'apply' `$s `$s }"
  'redirection to a file'                    = "function Bad-Seventeen { 'x' > C:\x.txt }"
  'L4: Assert-Native from elsewhere'         = "function Bad-Eighteen { Assert-Native `$r }"
  'L4: ForEach-Object with a member name'    = "function Bad-Nineteen { Get-ChildItem C:\x | ForEach-Object Delete }"
  'L4: % alias with a member name'           = "function Bad-Twenty { Get-ChildItem C:\x | % Delete }"
  'L4: ForEach-Object -MemberName'           = "function Bad-TwentyOne { Get-ChildItem C:\x | ForEach-Object -MemberName Delete }"
  'L4: assignment to a member'               = "function Bad-TwentyTwo { (Get-Item C:\x).IsReadOnly = `$true }"
  'L4: assignment to another object'         = "function Bad-TwentyThree { `$acl.Owner = 'x' }"
  'L4: static call through a variable'       = "function Bad-TwentyFour { `$f = [System.IO.File]; `$f::Delete('C:\x') }"
  'L4: static property through a variable'   = "function Bad-TwentyFive { `$f = [Environment]; `$f::CurrentDirectory }"
  'R1: a record file with another SDDL'      = "function New-FixSecuredFile { `$fsec.SetSecurityDescriptorSddlForm('O:BAD:(A;;FA;;;WD)') }"
  'R1: Set-Acl on the record folder'         = "function Initialize-FixRecordDir { Set-Acl -LiteralPath `$dir -AclObject `$a }"
  'R1: New-FixSecuredDir from elsewhere'     = "function Bad-TwentySeven { New-FixSecuredDir 'C:\x' }"
  'R8: a FileInfo in a hashtable variable'   = "function Bad-TwentyEight { `$it = Get-Item C:\x; `$it.IsReadOnly = `$true }"
  'R8: foreach over files into it'           = "function Bad-TwentyNine { foreach (`$it in Get-ChildItem C:\x) { `$it.IsReadOnly = `$true } }"
  'R8: a .NET object in a hashtable variable' = "function Bad-Thirty { `$s = [System.IO.FileInfo]::new('C:\x'); `$s.IsReadOnly = `$true }"
  'L4: AddScript with other commands'        = "function Get-FixProcessTable { `$ps.AddScript('Stop-Computer') }"
  'L4: AddScript with a variable'            = "function Get-FixProcessTable { `$ps.AddScript(`$x) }"
  'L4: Create on another type'               = "function Get-FixProcessTable { [System.Diagnostics.Process]::Create() }"
  'tune: Add-MpPreference outside FIXES'     = "function Bad-T1 { Add-MpPreference -ExclusionPath C:\ }"
  'tune: Set-MpPreference outside FIXES'     = "function Bad-T2 { Set-MpPreference -DisableRealtimeMonitoring `$true }"
  'tune: Disable-ScheduledTask outside'      = "function Bad-T3 { Disable-ScheduledTask -TaskPath '\x\' -TaskName y }"
  'tune: New-Item outside FIXES'             = "function Bad-T4 { New-Item -Path HKLM:\SOFTWARE\x -Force }"
  'tune: sc.exe outside FIXES'               = "function Bad-T5 { Invoke-Native `$ScExe @('config', 'WinDefend', 'start=', 'disabled') }"
  'tune: Remove-MpPreference outside FIXES'  = "function Bad-T6 { Remove-MpPreference -ExclusionPath C:\x }"
  'tune: Add-Type is banned'                = "function Bad-T8 { Add-Type -TypeDefinition 'public class X {}' }"
  'tune: SetEnvironmentVariable'             = "function Bad-T7 { [Environment]::SetEnvironmentVariable('PATH', 'x', 'Machine') }"
  'G2: EICAR written outside FIXES'          = "function Bad-D1 { [System.IO.File]::WriteAllBytes('C:\x\e.com', [byte[]](1, 2)) }"
  'G2: Get-EicarBytes outside FIXES'         = "function Bad-D2 { `$b = Get-EicarBytes }"
  'G2: a folder deleted outside FIXES'       = "function Bad-D3 { [System.IO.Directory]::Delete('C:\lanq-work', `$true) }"
  'G2: CreateDirectory elsewhere'            = "function Bad-D4 { [System.IO.Directory]::CreateDirectory('C:\lanq-work') }"
  'G2: Format-Volume outside FIXES'          = "function Bad-D5 { Format-Volume -DriveLetter D -DevDrive }"
  'G2: New-Partition outside FIXES'          = "function Bad-D6 { New-Partition -DiskNumber 1 -UseMaximumSize }"
  'G2: Initialize-Disk outside FIXES'        = "function Bad-D7 { Initialize-Disk -Number 1 }"
  'G2: diskpart outside FIXES'               = "function Bad-D8 { Invoke-Native `$DiskpartExe @() 60 'clean' }"
  'G2: fsutil devdrv trust outside FIXES'    = "function Bad-D9 { Invoke-Native `$FsutilExe @('devdrv', 'trust', 'C:') }"
  'G2: FileSystemAclExtensions elsewhere'    = "function Bad-D10 { [System.IO.FileSystemAclExtensions]::Create(`$d, `$ds) }"
  'G2: Sleep outside Wait-MpDetection'       = "function Bad-D11 { [System.Threading.Thread]::Sleep(1000) }"
}
$mutantsIn = [ordered]@{
  'G2: Delete of another path in FIXES'      = @('[System.IO.Directory]::Delete($q, $true)', "[System.IO.Directory]::Delete('C:\Windows', `$true)")
  'G2: a file deleted in FIXES'              = @('[System.IO.Directory]::Delete($q, $true)', '[System.IO.File]::Delete($q)')
  'G2: WriteAllBytes to another path'        = @('[System.IO.File]::WriteAllBytes($f, $bytes)', "[System.IO.File]::WriteAllBytes('C:\Windows\x.dll', `$bytes)")
  'G2: a folder moved from elsewhere'        = @('[System.IO.Directory]::Move($stage, $dst)', "[System.IO.Directory]::Move('C:\x', `$dst)")
  'G2: CreateDirectory in FIXES'             = @('[System.IO.Directory]::Move($stage, $dst)', '[void][System.IO.Directory]::CreateDirectory($dst)')
}
foreach ($k in $mutantsIn.Keys) {
  Assert-True ($fixText.Contains($mutantsIn[$k][0])) "mutant anchor present: $k"
  Test-Mutant $k ($fixText.Replace($mutantsIn[$k][0], $mutantsIn[$k][1]))
}
foreach ($k in $mutants.Keys) { Test-Mutant $k ($fixText.Replace("#region FIXES`n", $mutants[$k] + "`n#region FIXES`n")) }
Test-Mutant 'Set-Service after main' ($fixText + "`nSet-Service -Name sshd -StartupType Automatic`n")
Test-Mutant 'second region end' ($fixText.Replace("#endregion FIXES`n", "#endregion FIXES`n#endregion FIXES`n"))
Test-Mutant 'L4: a new function in FIXES, called from outside' ($fixText.Replace("function Assert-Native", "function Do-Thing { Stop-Service -Name sshd }`nfunction Assert-Native") + "`nDo-Thing`n")
Test-Mutant 'L4: Invoke-Native in FIXES with another exe' ($fixText.Replace("'ssh.aclkeys|apply' { Assert-Native (Invoke-Native `$IcaclsExe", "'ssh.aclkeys|apply' { Assert-Native (Invoke-Native `$OtherExe"))
Test-Mutant 'L4: a mutation in Get-FixCommand (inside the region, outside Invoke-FixChange)' ($fixText.Replace("  `$cmd = @(); `$git = ", "  Stop-Service -Name sshd; `$cmd = @(); `$git = "))
$mt = $fixText.Replace("    'ssh.auto|undo' { Set-Service", "    'ssh.auto|undo' { Stop-Service -Name `$SshdName -ErrorAction Stop; Set-Service")
[System.IO.File]::WriteAllText($mp, $mt)
Assert-Equal (@(Get-FixGuardViolations $mp) -join '; ') '' 'guard sanity: another mutation inside Invoke-FixChange is allowed'
$used = @($fast0 = [System.Management.Automation.Language.Parser]::ParseFile($fixPath, [ref]$null, [ref]$null); $fast0.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } |
  Where-Object { $_ -and $FixFunctionNames -notcontains $_ -and $_ -notmatch '\\' } | Sort-Object -Unique)
Assert-Equal (@($used | Where-Object { $FixCmdletNames -notcontains $_ -and -not $FixModuleCmds.ContainsKey($_) }) -join ',') '' 'R4: every cmdlet (and module command) the script runs is in the shadow check'
Remove-Item -LiteralPath $mdir -Recurse -Force

Write-Host 'NoYesFlag'
$tokens = $null; $perr = $null
$fast = [System.Management.Automation.Language.Parser]::ParseFile($fixPath, [ref]$tokens, [ref]$perr)
$pn = @($fast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-Equal ($pn -join ',') 'WhatIf,List,Help,Tune,Extra' 'parameters: WhatIf, List, Help, Tune (and -Undo/-Hours from the rest); no Yes, Force, Confirm or DefenderExclusions'
Assert-True ($fast.ParamBlock.Attributes.Extent.Text -notmatch 'SupportsShouldProcess') 'no SupportsShouldProcess (so no -Confirm:$false)'

# ---------- child processes: argument errors and real refusals (LANQ_MAKEREADY_FIX_LIB=1 safety net) ----------
$psExe = (Get-Process -Id $PID).Path
function Start-Child([string]$ArgText, [string]$StdinText = $null, [hashtable]$EnvVars = @{}) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe; $psi.Arguments = $ArgText; $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
  $psi.EnvironmentVariables['LANQ_MAKEREADY_FIX_LIB'] = '1'
  foreach ($k in $EnvVars.Keys) { $psi.EnvironmentVariables[$k] = $EnvVars[$k] }
  $p = [System.Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
  if ($StdinText) { $p.StandardInput.Write($StdinText) }
  $p.StandardInput.Close()
  [void]$p.WaitForExit(120000)
  $script:LastChild = @{ Code = $p.ExitCode; Out = "$($o.Result)"; Err = "$($e.Result)" }
  return $script:LastChild
}
$fileArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$fixPath`""
foreach ($a in '-Yes', '-Force', '--yes', '-y', '-AssumeYes') {
  $r = Start-Child "$fileArgs $a"
  Assert-True ($r.Code -eq 2 -and $r.Err -match 'unknown argument' -and $r.Err -match 'no -Yes or -Force') "NoYesFlag: $a -> exit 2, unknown argument"
}
$r = Start-Child "$fileArgs -Undo"; Assert-True ($r.Code -eq 2 -and $r.Err -match '-Undo needs a record file' -and $r.Err -match 'usage:') 'C9: -Undo without a file: exit 2 with the usage'
$r = Start-Child "$fileArgs -Undo a.json -Undo b.json"; Assert-True ($r.Code -eq 2 -and $r.Err -match 'twice') 'C9: -Undo twice: exit 2'
$r = Start-Child "$fileArgs -WhatIf -List"; Assert-True ($r.Code -eq 2 -and $r.Err -match 'only one of') 'two modes at once: exit 2'
$r = Start-Child "$fileArgs -WhatIf -Undo a.json"; Assert-True ($r.Code -eq 2 -and $r.Err -match 'only one of') '-WhatIf with -Undo: exit 2'
$r = Start-Child "$fileArgs -Help"; Assert-True ($r.Code -eq 0 -and $r.Out -match 'usage:') '-Help: usage, exit 0'
$r = Start-Child "$fileArgs -Tune -DefenderExclusions -WhatIf"; Assert-True ($r.Code -eq 2 -and $r.Err -match '-DefenderExclusions needs -BuildUser') 'B6: -DefenderExclusions without -BuildUser: exit 2'
$r = Start-Child "$fileArgs -DefenderExclusions -BuildUser builder -WhatIf"; Assert-True ($r.Code -eq 2 -and $r.Err -match 'go with -Tune') '-DefenderExclusions without -Tune: exit 2'
$r = Start-Child "$fileArgs -Tune -DefenderExclusions -CreateDevDrive -BuildUser builder -WhatIf"; Assert-True ($r.Code -eq 2 -and $r.Err -match 'only one of -DefenderExclusions and -CreateDevDrive') 'both Defender switches at once: exit 2'
$r = Start-Child "$fileArgs -Tune -DefenderExclusions -BuildUser builder -ExclusionPath C:\ -WhatIf"; Assert-True ($r.Code -eq 2 -and $r.Err -match 'unknown argument') 'A1: no path can be given (-ExclusionPath is an unknown argument): exit 2'
$r = Start-Child "$fileArgs -Tune -DefenderExclusions -BuildUser builder C:\Windows -WhatIf"; Assert-True ($r.Code -eq 2 -and $r.Err -match 'unknown argument') 'A1/A2: a bare path is an unknown argument: exit 2'
$r = Start-Child "$fileArgs -Tune -CreateDevDrive -BuildUser builder -SizeGB 10 -WhatIf"; Assert-True ($r.Code -eq 2 -and $r.Err -match '-SizeGB must be') 'D2: -SizeGB below 50: exit 2'
$r = Start-Child "$fileArgs -Tune -DefenderExclusions -BuildUser builder"; Assert-True ($r.Code -eq 3 -and $r.Err -match 'no interactive console') 'RefusesWithoutConsole (real process, -Tune -DefenderExclusions): exit 3'
$r = Start-Child "$fileArgs -Tune -CreateDevDrive -BuildUser builder -WhatIf" $null @{ SSH_CONNECTION = '10.20.30.5 50000 10.20.30.6 22' }
Assert-True ($r.Code -eq 3 -and $r.Err -match 'over SSH') 'RefusesOverSsh (real process, -Tune -CreateDevDrive -WhatIf): exit 3'
$r = Start-Child "$fileArgs -Tune -WorkRoot C:/lq -WhatIf"; Assert-True ($r.Code -eq 2 -and $r.Err -match 'unknown argument') '-WorkRoot is gone from the fix script: exit 2'
$r = Start-Child "$fileArgs -Hours 22:00-07:00 -WhatIf"; Assert-True ($r.Code -eq 2 -and $r.Err -match 'goes with -Tune') '-Hours without -Tune: exit 2'
$r = Start-Child "$fileArgs -Tune -Hours 25:00-07:00 -WhatIf"; Assert-True ($r.Code -eq 2 -and $r.Err -match '-Hours must') 'tune: a bad -Hours: exit 2'
$r = Start-Child "$fileArgs -Tune -WhatIf" $null @{ SSH_CONNECTION = '10.20.30.5 50000 10.20.30.6 22' }
Assert-True ($r.Code -eq 3 -and $r.Err -match 'over SSH') 'tune: RefusesOverSsh (real process, -Tune -WhatIf): exit 3'
$r = Start-Child "$fileArgs -Tune"; Assert-True ($r.Code -eq 3 -and $r.Err -match 'no interactive console') 'tune: RefusesWithoutConsole (real process, -Tune): exit 3'
$r = Start-Child "$fileArgs -WhatIf" $null @{ SSH_CONNECTION = '10.20.30.5 50000 10.20.30.6 22' }
Assert-True ($r.Code -eq 3 -and $r.Err -match 'over SSH') 'RefusesOverSsh (real process, SSH_CONNECTION, dry run): exit 3'
$r = Start-Child "$fileArgs -List" $null @{ SSH_TTY = '/dev/pts/1' }
Assert-True ($r.Code -eq 3 -and $r.Err -match 'over SSH') 'RefusesOverSsh (real process, SSH_TTY, -List): exit 3'
$r = Start-Child '-NoProfile -NonInteractive -Command "& ([scriptblock]::Create([Console]::In.ReadToEnd())) -WhatIf"' $fixText
Assert-True ($r.Code -eq 3 -and $r.Err -match 'from stdin') 'RefusesFromStdin (real process, [scriptblock]::Create): exit 3'
$r = Start-Child '-NoProfile -NonInteractive -Command "[Console]::In.ReadToEnd() | Invoke-Expression"' $fixText
Assert-True ($r.Code -eq 3 -and $r.Err -match 'from stdin') 'RefusesFromStdin (real process, piped to Invoke-Expression): exit 3'
$r = Start-Child $fileArgs
Assert-True ($r.Code -eq 3 -and $r.Err -match 'no interactive console') 'RefusesWithoutConsole (real process, stdin redirected, apply): exit 3'
$r = Start-Child "$fileArgs -Undo C:\none.json"
Assert-True ($r.Code -eq 3 -and $r.Err -match 'no interactive console') 'RefusesWithoutConsole (real process, -Undo): exit 3'
$r = Start-Child "-NoProfile -ExecutionPolicy Bypass -Command `"Set-Alias Get-FixState Get-Date; & '$fixPath' -WhatIf; exit `$LASTEXITCODE`""
Assert-True ($r.Code -eq 3 -and $r.Err -match 'alias would run instead' -and $r.Err -match 'Get-FixState') 'INFO: an alias shadowing a function of the script: refused'
$r = Start-Child "-NoProfile -ExecutionPolicy Bypass -Command `"function Set-Service { 'fake' }; & '$fixPath' -WhatIf; exit `$LASTEXITCODE`""
Assert-True ($r.Code -eq 3 -and $r.Err -match 'function or alias would run instead' -and $r.Err -match 'Set-Service') 'R4: a function over a cmdlet the fixes use: refused'
$r = Start-Child "-NoProfile -ExecutionPolicy Bypass -Command `"Set-Alias Get-Acl Get-Date; & '$fixPath' -WhatIf; exit `$LASTEXITCODE`""
Assert-True ($r.Code -eq 3 -and $r.Err -match 'Get-Acl') 'R4: an alias over a cmdlet: refused'
$r = Start-Child "$fileArgs -List"
Assert-True ($r.Code -eq 2 -and $r.Err -match 'LANQ_MAKEREADY_FIX_LIB=1 is only for tests') 'a direct run with LANQ_MAKEREADY_FIX_LIB=1 passes the refusals, then exits 2'

$script:LastChild = $null
# ---------- fakes ----------
Write-Host 'fakes (nothing below touches this PC)'
$SshdName = 'lanq-test-no-such-service'
$FsKey = 'HKCU:\Software\lanq-makeready-fix-test-none\FileSystem'
$PowercfgExe = 'C:\lanq-test-none\powercfg.exe'
$IcaclsExe = 'C:\lanq-test-none\icacls.exe'
$KeysFile = 'C:\lanq-test-none\administrators_authorized_keys'
$RecDir = Join-Path ([IO.Path]::GetTempPath()) ('lanq-fixrec-' + [Guid]::NewGuid().ToString('N'))
$Inherited = '(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;BU)'   # what the fake parent folder hands down
$OpenDacl = "D:AI$Inherited"
$OwnDacl = "D:AI(A;;FA;;;S-1-5-21-1-2-3-1001)$Inherited"
$BaOwnDacl = "D:AI(A;;FA;;;BA)$Inherited"
$TightDacl = 'D:PAI(A;;FA;;;BA)(A;;FA;;;SY)'
$KeyLine = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample build@build-01'
$Calls = New-Object System.Collections.ArrayList
$Snaps = New-Object System.Collections.ArrayList
$Reads = New-Object System.Collections.ArrayList
function Reset-Fake {
  $script:F = @{ SvcInstalled = $true; Status = 'Running'; StartType = 'Automatic'; Scheme = '381b4222-f694-41f0-9685-ff5bb260df2e'; Standby = 0; Hibernate = 0; LongPaths = 1; LpKind = $null; LpRaw = $null
    GitSystem = 'true'; GitGlobal = $null; GitTrusted = $true; PathGit = 'C:\fake\git.exe'
    Dacl = $TightDacl; Owner = $BaSid }
  $script:Elev = $true; $script:Console = $true; $script:Answers = New-Object System.Collections.Queue; $script:OnAnswer = $null; $script:Asked = 0; $script:Trust = ''; $script:DirWhy = ''
  $Calls.Clear(); $Snaps.Clear(); $Reads.Clear()
  if (Test-Path -LiteralPath $RecDir) { Remove-Item -LiteralPath $RecDir -Recurse -Force }
}
function Get-FixRecordDir { return $RecDir }
# the record store: the folder is created plain (no admin-owned ACL here), trust is what the test says
function Initialize-FixRecordDir { if ($script:DirWhy) { return $script:DirWhy }; if (-not (Test-Path -LiteralPath $RecDir)) { [void](New-Item -ItemType Directory -Path $RecDir) }; return '' }
function Get-FixRecordDirProblem { return $script:DirWhy }
function New-FixSecuredDir([string]$Dir, [string]$Sddl) {
  [void][System.IO.Directory]::CreateDirectory($Dir)
  if ($script:SquatWork -and $Dir -match 'stage-[0-9a-f]{32}-w$') { [void][System.IO.Directory]::CreateDirectory((Join-Path (Get-DriveRoot 'C') 'lanq-work')) }   # someone makes C:\lanq-work first (H-A)
}
function New-FixSecuredFile([string]$Path, [byte[]]$Bytes) { $st = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew); try { $st.Write($Bytes, 0, $Bytes.Length) } finally { $st.Dispose() } }
function Test-FixRecordTrusted([string]$Path) { return $script:Trust }
function Get-LatestRecord { $f = @(Get-ChildItem -LiteralPath $RecDir -Filter 'fix-*.json' -ErrorAction SilentlyContinue | Sort-Object -Property Name); if ($f.Count) { return $f[-1].FullName }; return $null }
function Note-Call([string]$C) { [void]$Calls.Add($C); $p = Get-LatestRecord; if ($p) { [void]$Snaps.Add([System.IO.File]::ReadAllText($p)) } else { [void]$Snaps.Add('') } }
function Test-FixElevated { return $script:Elev }
function Test-FixConsole { return $script:Console }
function Read-FixAnswer { $script:Asked++; if ($script:OnAnswer) { & $script:OnAnswer; $script:OnAnswer = $null }; if ($script:Answers.Count) { return $script:Answers.Dequeue() }; return $null }
function Write-FixLine([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) { [void]$FixOut.Add($Text) }
function Write-FixErr([string]$Text) { [void]$FixOut.Add($Text) }
function Get-FixState([string]$Id) {
  [void]$Reads.Add($Id); $f = $script:F
  switch ($Id) {
    { @('ssh.start', 'ssh.auto') -contains $_ } { if (-not $f.SvcInstalled) { return @{ Installed = $false } }; return @{ Installed = $true; Status = $f.Status; StartType = $f.StartType } }
    'power.sleep' { return @{ Scheme = $f.Scheme; Standby = $f.Standby; Hibernate = $f.Hibernate } }
    'longpaths.on' { $k = $f.LpKind; if (-not $k) { if ($null -eq $f.LongPaths) { $k = 'none' } else { $k = 'DWord' } }; $v = $f.LongPaths; if ($k -ne 'DWord') { $v = $null }; return @{ Value = $v; Kind = $k; Raw = $f.LpRaw } }
    'git.longpaths' { $e = $f.GitSystem; if ($f.GitGlobal) { $e = $f.GitGlobal }; return @{ Git = 'C:\fake\git.exe'; Trusted = $f.GitTrusted; System = $f.GitSystem; Effective = $e; SystemFile = 'C:/fake/etc/gitconfig'; PathGit = $f.PathGit } }
    'ssh.aclkeys' { if (-not $f.Dacl) { return @{ Exists = $false } }; return @{ Exists = $true; Reparse = $false; Dacl = $f.Dacl; Ok = (Test-OnlyAdminsSystem $f.Dacl); Owner = $f.Owner; Keys = (Get-AuthKeySummary @($KeyLine)) } }
  }
}
function Set-Service { param($Name, $StartupType, $ErrorAction) Note-Call "Set-Service $Name $StartupType"; $script:F.StartType = "$StartupType" }
function Start-Service { param($Name, $ErrorAction) Note-Call "Start-Service $Name"; $script:F.Status = 'Running' }
function Stop-Service { param($Name, $ErrorAction) Note-Call "Stop-Service $Name"; $script:F.Status = 'Stopped' }
function Set-ItemProperty { param($Path, $Name, $Value, $Type, $ErrorAction) Note-Call "Set-ItemProperty $Path $Name $Value $Type"; $script:F.LongPaths = [long]$Value }
function Remove-ItemProperty { param($Path, $Name, $ErrorAction) Note-Call "Remove-ItemProperty $Path $Name"; $script:F.LongPaths = $null }
function Get-Acl { param($LiteralPath, $ErrorAction) $a = New-Object System.Security.AccessControl.FileSecurity; $a.SetSecurityDescriptorSddlForm($script:F.Dacl, [System.Security.AccessControl.AccessControlSections]::Access); return $a }
function Set-Acl {
  param($LiteralPath, $AclObject, $ErrorAction)
  $d = $AclObject.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
  Note-Call "Set-Acl $LiteralPath $d"
  if ($d -cnotmatch '^D:P') { $d = $d + $Inherited }   # like Windows: an unprotected DACL gets the parent's entries again
  $script:F.Dacl = $d
}
function Invoke-Native([string]$Exe, [string[]]$ArgList, [int]$Sec = 60) {
  $leaf = Split-Path -Leaf $Exe; $a = @($ArgList)
  Note-Call "$leaf $($a -join ' ')"
  if ($leaf -eq 'powercfg.exe') {
    if ($a[0] -eq '/change' -and $a[1] -eq 'standby-timeout-ac') { $script:F.Standby = [long]$a[2] * 60 }
    elseif ($a[0] -eq '/change' -and $a[1] -eq 'hibernate-timeout-ac') { $script:F.Hibernate = [long]$a[2] * 60 }
    elseif ($a[0] -eq '/setacvalueindex' -and $a[3] -eq 'STANDBYIDLE') { $script:F.Standby = [long]$a[4] }
    elseif ($a[0] -eq '/setacvalueindex' -and $a[3] -eq 'HIBERNATEIDLE') { $script:F.Hibernate = [long]$a[4] }
  } elseif ($leaf -eq 'git.exe') {
    if ($a[2] -eq '--unset') { $script:F.GitSystem = $null } else { $script:F.GitSystem = $a[3] }
  } elseif ($leaf -eq 'icacls.exe') { $script:F.Dacl = $TightDacl }
  return @{ Code = 0; Out = '' }
}
$unsafe = @(foreach ($n in 'Set-Service', 'Start-Service', 'Stop-Service', 'Set-ItemProperty', 'Remove-ItemProperty', 'Set-Acl', 'Get-Acl', 'Invoke-Native', 'Get-FixState', 'Get-FixRecordDir',
    'Test-FixElevated', 'Initialize-FixRecordDir', 'Get-FixRecordDirProblem', 'New-FixSecuredDir', 'New-FixSecuredFile', 'Test-FixRecordTrusted') {
    if (@(Get-Command $n)[0].CommandType -ne 'Function') { $n } })
if ($unsafe.Count -gt 0) { Write-Host "ABORT: not faked: $($unsafe -join ', ')" -ForegroundColor Red; exit 1 }
Assert-True $true 'every command that could change the PC is a fake'
$FixCmdletNames = @()   # the fakes above are functions over cmdlet names on purpose; the shadow check is tested in a child process

function Invoke-Fake([string]$Mode = 'apply', [string]$UndoPath = '', [object[]]$Ans = @()) {
  $FixOut.Clear(); $Calls.Clear(); $Snaps.Clear(); $Reads.Clear()
  foreach ($x in $Ans) { $script:Answers.Enqueue($x) }
  $rc = Invoke-FixMain -Mode $Mode -UndoPath $UndoPath -FromFile $true
  return , $rc
}
function OutText { return ($FixOut -join "`n") }
function Get-AllStates { return (@($FixIds | ForEach-Object { "$_=" + (Get-StateText $_ (Get-FixState $_)) }) -join ' | ') }
function Read-Rec([string]$P) { return ([System.IO.File]::ReadAllText($P) | ConvertFrom-Json) }

# id, fake changes, expected apply calls, expected undo calls
$cases = @(
  @('ssh.start', @{ Status = 'Stopped'; StartType = 'Manual' }, "Set-Service $SshdName Automatic|Start-Service $SshdName", "Set-Service $SshdName Manual|Stop-Service $SshdName"),
  @('ssh.start', @{ Status = 'Stopped'; StartType = 'Disabled' }, "Set-Service $SshdName Automatic|Start-Service $SshdName", "Set-Service $SshdName Disabled|Stop-Service $SshdName"),
  @('ssh.auto', @{ Status = 'Running'; StartType = 'Manual' }, "Set-Service $SshdName Automatic", "Set-Service $SshdName Manual"),
  @('power.sleep', @{ Standby = 1800; Hibernate = 3600 }, 'powercfg.exe /change standby-timeout-ac 0|powercfg.exe /change hibernate-timeout-ac 0',
    'powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 1800|powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 3600|powercfg.exe /setactive SCHEME_CURRENT'),
  @('power.sleep', @{ Standby = 600; Hibernate = $null }, 'powercfg.exe /change standby-timeout-ac 0', 'powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 600|powercfg.exe /setactive SCHEME_CURRENT'),
  @('power.sleep', @{ Standby = 0; Hibernate = 7200 }, 'powercfg.exe /change hibernate-timeout-ac 0',
    'powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0|powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 7200|powercfg.exe /setactive SCHEME_CURRENT'),
  @('longpaths.on', @{ LongPaths = $null }, "Set-ItemProperty $FsKey LongPathsEnabled 1 DWord", "Remove-ItemProperty $FsKey LongPathsEnabled"),
  @('longpaths.on', @{ LongPaths = 0 }, "Set-ItemProperty $FsKey LongPathsEnabled 1 DWord", "Set-ItemProperty $FsKey LongPathsEnabled 0 DWord"),
  @('git.longpaths', @{ GitSystem = $null }, 'git.exe config --system core.longpaths true', 'git.exe config --system --unset core.longpaths'),
  @('git.longpaths', @{ GitSystem = 'false' }, 'git.exe config --system core.longpaths true', 'git.exe config --system core.longpaths false'),
  @('ssh.aclkeys', @{ Dacl = $OpenDacl }, "icacls.exe $KeysFile /inheritance:r /grant *S-1-5-32-544:F /grant *S-1-5-18:F", "Set-Acl $KeysFile D:AI"),
  @('ssh.aclkeys', @{ Dacl = $BaOwnDacl }, "icacls.exe $KeysFile /inheritance:r /grant *S-1-5-32-544:F /grant *S-1-5-18:F", "Set-Acl $KeysFile D:AI(A;;FA;;;BA)")
)
Write-Host 'apply and undo each fix (exact mutating commands; record written before the change; undo restores)'
foreach ($c in $cases) {
  $id = $c[0]; $tag = "$id ($(($c[1].Keys | ForEach-Object { "$_=$($c[1][$_])" }) -join ' '))"
  Reset-Fake; foreach ($k in $c[1].Keys) { $F[$k] = $c[1][$k] }
  $start = Get-AllStates
  $rc = Invoke-Fake 'apply' '' @('y')
  Assert-Equal $rc 0 "$tag apply: exit 0"
  Assert-Equal ($Calls -join '|') $c[2] "$tag apply: exact commands"
  Assert-True ($Snaps.Count -gt 0 -and $Snaps[0] -match ('"id": "' + [regex]::Escape($id) + '", "status": "pending"')) "RecordWrittenBeforeChange: $tag"
  Assert-True ($Snaps[0] -notmatch '"after": "unknown"') "C5: the pending item already holds the expected after state: $tag"
  $rp = Get-LatestRecord; $j = Read-Rec $rp
  Assert-True ($j.schema -eq 'lanq-makeready-fix/v1' -and @($j.items).Count -eq 1 -and $j.items[0].status -eq 'applied' -and $j.items[0].after -ne 'unknown') "$tag record: one item, applied, after state"
  Assert-True ($j.items[0].command -eq ((Get-FixCommand $id 'apply' (ConvertFrom-StateText $id $j.items[0].before) (Get-FixState $id)) -join ' ; ')) "$tag record: the command shown is the command recorded"
  Assert-True ((OutText) -match 'applied and verified') "$tag apply: verified"
  $rc = Invoke-Fake 'undo' $rp @('y')
  Assert-Equal $rc 0 "$tag undo: exit 0"
  Assert-Equal ($Calls -join '|') $c[3] "UndoRestoresEachFix: $tag exact undo commands"
  Assert-Equal (Get-AllStates) $start "UndoRestoresEachFix: $tag state back to the start"
  Assert-Equal (Read-Rec $rp).items[0].status 'undone' "$tag record: undone"
  $rc = Invoke-Fake 'undo' $rp @('y')
  Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'Nothing to undo') "$tag second undo: nothing to do"
}
Reset-Fake; $F.Dacl = $OpenDacl; $rc = Invoke-Fake 'apply' '' @('y')
Assert-True ($Snaps[0] -match [regex]::Escape('"after": "dacl=D:PAI(A;;FA;;;BA)(A;;FA;;;SY)"')) 'C5: a pending ssh.aclkeys item predicts the DACL icacls leaves'
Assert-True ((OutText) -match 'keys: +1 line\(s\)' -and (OutText) -match 'ssh-ed25519 SHA256:' -and (OutText) -match 'Review them') 'L5: the key lines are shown (type, fingerprint, comment) with a review note'
$rc = Invoke-Fake 'undo' (Get-LatestRecord) @('n')
Assert-True ((OutText) -match 'BUILTIN\\Users : ReadAndExecute' -and (OutText) -match 'administrator key logins stop working') 'M1(c): the undo prompt shows the DACL in words and what undo does'

Write-Host 'only conditions the scanner reports are offered (with a note when it cannot be fixed here)'
Reset-Fake; $rc = Invoke-Fake 'apply' '' @('y', 'y', 'y', 'y', 'y', 'y')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and (OutText) -match 'Nothing to fix') 'all good: nothing offered, nothing asked'
Reset-Fake; $F.SvcInstalled = $false; $F.Dacl = $null; $F.Status = 'Stopped'; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -notmatch '(?m)^ssh\.') 'no sshd, no keys file: no ssh fixes'
Reset-Fake; $F.GitGlobal = 'false'; $F.GitSystem = 'true'; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -match 'git\.longpaths .*not offered: .*global git config' -and (OutText) -notmatch '(?m)^git\.longpaths  \(check git\): git') 'C2: system already true, global overrides: a note, not a fix (no endless re-offer)'
Reset-Fake; $F.GitGlobal = 'false'; $F.GitSystem = $null; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -match 'not offered: .*global git config') 'C2: system unset, global false: the system change would not help: a note'
Assert-True (-not (Test-FixDone 'git.longpaths' @{ System = 'true'; Effective = 'false' })) 'C2: done means the effective value is true too'
Reset-Fake; $F.GitSystem = $null; $F.GitTrusted = $false; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -match 'not offered: git here is C:\\fake\\git.exe, outside Program Files') 'L2: a git outside Program Files is not used'
Reset-Fake; $F.LongPaths = $null; $F.LpKind = 'String'; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -match 'not offered: LongPathsEnabled is of type String') 'C12: a registry value of another type: a note, not a fix'
Reset-Fake; $F.Dacl = $OpenDacl; $F.Owner = 'S-1-5-21-1-2-3-1001'; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -match 'not offered: not fixable here: .*owned by S-1-5-21-1-2-3-1001.*/setowner') 'INFO: keys file owned by a user: not offered, says why'
Reset-Fake; $F.Dacl = 'D:NO_ACCESS_CONTROL'; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -match 'not fixable here: .*no DACL at all') 'INFO: NULL DACL: reported as not fixable here, not silently OK'
Reset-Fake; $F.Dacl = 'D:P(D;;FA;;;WD)(A;;FA;;;BA)(A;;FA;;;SY)(A;;FR;;;BU)'; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -match 'not fixable here: -Undo could not safely put the current permissions back') 'M1(b): a DACL undo could not restore safely is not changed at all'
Reset-Fake; $F.Dacl = $OwnDacl; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -match 'not offered: .*own entries for S-1-5-21-1-2-3-1001, which icacls /grant leaves in place' -and (OutText) -match 'remove:g \*S-1-5-21-1-2-3-1001') 'R9: explicit entries for others: not offered, with the command to remove them'
Reset-Fake; $F.LongPaths = $null; $F.LpKind = 'String'; $F.LpRaw = '1'; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -notmatch 'LongPathsEnabled' -and (OutText) -notmatch '(?m)^longpaths\.on') 'R7(d): a REG_SZ "1" is on for the scanner too: nothing offered, nothing said'
Reset-Fake; $F.GitSystem = $null; $F.PathGit = 'C:\Users\u\scoop\shims\git.exe'; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -match 'the scanner checks the git first on PATH \(C:\\Users\\u\\scoop\\shims\\git.exe\)') 'R7(c): the scanner''s git and the fixed git differ: a note says so'
Reset-Fake; $F.Standby = 1800; $F.Scheme = $null; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -match 'not offered: the active power scheme could not be read') 'D4: no power scheme, no fix (undo is tied to it)'
Reset-Fake; $F.Status = 'StartPending'; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -match 'StartPending \(changing state\)') 'C13: a service changing state: says so'

Write-Host 'DefaultIsNo'
foreach ($ans in @('', 'n', 'N', 'no', 'x', 'yes please', $null)) {
  Reset-Fake; $F.Standby = 1800
  $rc = Invoke-Fake 'apply' '' @(, $ans)
  Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $null -eq (Get-LatestRecord) -and (OutText) -match 'Apply\? \[y/N\]' -and (OutText) -match 'not applied') "DefaultIsNo: answer '$ans' -> nothing changed, no record"
}

Write-Host 'SkipsAdminItemsWhenNotElevated'
Reset-Fake; $F.Status = 'Stopped'; $F.StartType = 'Manual'; $F.Standby = 1800; $F.LongPaths = 0; $F.GitSystem = $null; $F.Dacl = $OpenDacl; $script:Elev = $false
$rc = Invoke-Fake 'apply' '' @('y', 'y', 'y', 'y', 'y', 'y')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and $null -eq (Get-LatestRecord)) 'SkipsAdminItemsWhenNotElevated: nothing asked or changed'
Assert-Equal ([regex]::Matches((OutText), 'needs an elevated PowerShell')).Count 5 'SkipsAdminItemsWhenNotElevated: a note per fix'
Assert-True ((OutText) -match 'never elevates itself') 'not elevated: says it never elevates itself'

Write-Host 'EachFixRechecksPreconditionFirst'
$fixed = @{ 'ssh.start' = { $script:F.Status = 'Running'; $script:F.StartType = 'Automatic' }; 'ssh.auto' = { $script:F.StartType = 'Automatic' }; 'power.sleep' = { $script:F.Standby = 0; $script:F.Hibernate = 0 }
  'longpaths.on' = { $script:F.LongPaths = 1 }; 'git.longpaths' = { $script:F.GitSystem = 'true' }; 'ssh.aclkeys' = { $script:F.Dacl = $TightDacl } }
foreach ($c in $cases) {
  Reset-Fake; foreach ($k in $c[1].Keys) { $F[$k] = $c[1][$k] }; $script:OnAnswer = $fixed[$c[0]]
  $rc = Invoke-Fake 'apply' '' @('y')
  Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'no longer needed') "EachFixRechecksPreconditionFirst: $($c[0]) fixed meanwhile -> nothing done"
  Assert-True (@($Reads | Where-Object { $_ -eq $c[0] }).Count -ge 2) "EachFixRechecksPreconditionFirst: $($c[0]) state read again after the answer"
}
Reset-Fake; $F.Standby = 1800; $script:OnAnswer = { $script:F.Standby = 600 }
$rc = Invoke-Fake 'apply' '' @('y')
Assert-True ($Calls.Count -eq 0 -and (OutText) -match 'changed since it was shown') 'state changed to another value after it was shown: nothing done'

Write-Host 'UndoInReverseOrder and UndoSkipsChangedSince'
Reset-Fake; $F.Standby = 1800; $F.LongPaths = 0; $F.GitSystem = $null
$start = Get-AllStates
$rc = Invoke-Fake 'apply' '' @('y', 'y', 'y'); $rp = Get-LatestRecord
Assert-Equal (@($Calls | ForEach-Object { $_.Split(' ')[0] }) -join ',') 'powercfg.exe,Set-ItemProperty,git.exe' 'applied in list order'
$rc = Invoke-Fake 'undo' $rp @('y', 'y', 'y')
Assert-Equal (@($Calls | ForEach-Object { $_.Split(' ')[0] }) -join ',') 'git.exe,Set-ItemProperty,powercfg.exe,powercfg.exe,powercfg.exe' 'UndoInReverseOrder: newest change first'
Assert-Equal (Get-AllStates) $start 'UndoInReverseOrder: everything restored'
Reset-Fake; $F.Standby = 1800; $F.LongPaths = 0
$rc = Invoke-Fake 'apply' '' @('y', 'y'); $rp = Get-LatestRecord
$F.Standby = 900
$rc = Invoke-Fake 'undo' $rp @('y', 'y')
Assert-True ((OutText) -match 'changed since; left alone' -and @($Calls | Where-Object { $_ -match 'powercfg' }).Count -eq 0) 'UndoSkipsChangedSince: power.sleep changed by hand, left alone'
Assert-True (@($Calls | Where-Object { $_ -match 'LongPathsEnabled' }).Count -eq 1 -and $F.Standby -eq 900) 'UndoSkipsChangedSince: the other fix is still undone; the hand change stays'
$j = Read-Rec $rp
Assert-Equal (@($j.items | ForEach-Object { "$($_.id):$($_.status)" }) -join ',') 'power.sleep:applied,longpaths.on:undone' 'UndoSkipsChangedSince: record keeps the skipped item as applied'
Reset-Fake; $F.Standby = 1800; $rc = Invoke-Fake 'apply' '' @('y'); $rp = Get-LatestRecord
$rc = Invoke-Fake 'undo' $rp @('n')
Assert-True ($Calls.Count -eq 0 -and (OutText) -match 'left as it is' -and (Read-Rec $rp).items[0].status -eq 'applied') 'undo: default no leaves it'
$script:OnAnswer = { $script:F.Standby = 60 }
$rc = Invoke-Fake 'undo' $rp @('y')
Assert-True ($Calls.Count -eq 0 -and (OutText) -match 'changed since; left alone') 'undo: re-checks the state after the answer'
$script:Elev = $false; $F.Standby = 0; $script:Asked = 0
$rc = Invoke-Fake 'undo' $rp @('y')
Assert-True ($rc -eq 1 -and $Calls.Count -eq 0 -and $Reads.Count -eq 0 -and $script:Asked -eq 0 -and (OutText) -match 'needs an elevated PowerShell') 'C7/D5: undo when not elevated: exit 1, says so before reading any state'
Reset-Fake; $F.Standby = 1800; $rc = Invoke-Fake 'apply' '' @('y'); $rp = Get-LatestRecord
$F.Scheme = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$rc = Invoke-Fake 'undo' $rp @('y')
Assert-True ($Calls.Count -eq 0 -and (OutText) -match 'changed since; left alone') 'D4: another power scheme is active now: changed since; left alone'

Write-Host 'C5 pending items'
Reset-Fake; $F.Standby = 1800; $rc = Invoke-Fake 'apply' '' @('y'); $rp = Get-LatestRecord
[System.IO.File]::WriteAllText($rp, ([System.IO.File]::ReadAllText($rp) -replace '"status": "applied"', '"status": "pending"'))
$F.Standby = 1800   # the crash happened before the change
$rc = Invoke-Fake 'undo' $rp @('y')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'never applied' -and (Read-Rec $rp).items[0].status -eq 'skipped') 'C5: pending and still as before: "never applied", marked skipped'
[System.IO.File]::WriteAllText($rp, ([System.IO.File]::ReadAllText($rp) -replace '"status": "skipped"', '"status": "pending"'))
$F.Standby = 0   # the crash happened after the change
$rc = Invoke-Fake 'undo' $rp @('y')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 3 -and $F.Standby -eq 1800 -and (Read-Rec $rp).items[0].status -eq 'undone') 'C5: pending and changed as predicted: undone'

Write-Host 'failed changes and failed saves'
Reset-Fake; $F.LongPaths = 0
function Set-ItemProperty { param($Path, $Name, $Value, $Type, $ErrorAction) Note-Call 'Set-ItemProperty failing'; throw 'access denied' }
$rc = Invoke-Fake 'apply' '' @('y')
Assert-True ($rc -eq 1 -and (OutText) -match 'FAILED: access denied' -and (Read-Rec (Get-LatestRecord)).items[0].status -eq 'failed') 'failed change: exit 1, item failed'
function Set-ItemProperty { param($Path, $Name, $Value, $Type, $ErrorAction) Note-Call "Set-ItemProperty $Path $Name $Value $Type"; $script:F.LongPaths = [long]$Value }
$origSave = ${function:Save-FixRecord}
function Save-FixRecord($Rec) { $script:SaveN++; if ($script:SaveN -eq 2) { return $false }; return (& $origSave $Rec) }
Reset-Fake; $F.LongPaths = 0; $script:SaveN = 0
$rc = Invoke-Fake 'apply' '' @('y')
Assert-True ($rc -eq 1 -and (OutText) -match 'still says pending') 'C6: the record cannot be updated after the change: exit 1, says so'
Set-Item -Path Function:\Save-FixRecord -Value $origSave
Reset-Fake; $F.LongPaths = 0; $script:DirWhy = 'the record folder X is not safe (it is owned by S-1-5-21-1). Nothing was changed.'
$rc = Invoke-Fake 'apply' '' @('y')
Assert-True ($rc -eq 1 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and (OutText) -match 'not safe') 'R1: an unsafe record folder stops the run before the first question'
$script:DirWhy = ''
Reset-Fake
$rec0 = New-FixRecord; [void](New-Item -ItemType Directory -Path $RecDir); [System.IO.File]::WriteAllText($rec0.Path + '.tmp', 'planted'); $FixOut.Clear()
Assert-True (-not (Save-FixRecord $rec0) -and (OutText) -match 'exists \(left by a crash, or planted\)' -and -not (Test-Path -LiteralPath $rec0.Path)) 'L1: an existing temp file is refused, never written through'

Reset-Fake; $F.Dacl = $OpenDacl; $rc = Invoke-Fake 'apply' '' @('y'); $rp = Get-LatestRecord
function Set-Acl { param($LiteralPath, $AclObject, $ErrorAction) Note-Call "Set-Acl $LiteralPath"; $script:F.Dacl = 'D:PAI(A;;FA;;;BU)' }
$rc = Invoke-Fake 'undo' $rp @('y')
Assert-True ($rc -eq 1 -and (OutText) -match 'FAILED: after the undo the keys file''s permissions are not safe' -and (OutText) -match '/grant \*S-1-5-32-544:F') 'R2: after the undo the real DACL is read again; Administrators/SYSTEM without full control fails loudly'
function Set-Acl {
  param($LiteralPath, $AclObject, $ErrorAction)
  $d = $AclObject.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
  Note-Call "Set-Acl $LiteralPath $d"
  if ($d -cnotmatch '^D:P') { $d = $d + $Inherited }
  $script:F.Dacl = $d
}

Write-Host 'WhatIfChangesNothing'
Reset-Fake; $F.Status = 'Stopped'; $F.StartType = 'Manual'; $F.Standby = 1800; $F.LongPaths = $null; $F.GitSystem = $null; $F.Dacl = $OpenDacl; $script:Console = $false
$before = Get-AllStates
$rc = Invoke-Fake 'dry' '' @('y', 'y', 'y', 'y', 'y')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and $null -eq (Get-LatestRecord) -and (Get-AllStates) -eq $before) 'WhatIfChangesNothing: no command, no question, no record (and no console needed)'
foreach ($id in 'ssh.start', 'power.sleep', 'longpaths.on', 'git.longpaths', 'ssh.aclkeys') { Assert-True ((OutText) -match "(?m)^$([regex]::Escape($id)) ") "WhatIf shows $id" }
Assert-True ([regex]::Matches((OutText), '(?m)^  undo: ').Count -ge 5 -and (OutText) -match 'dry run: not applied') 'WhatIf shows each undo'
Assert-True ((OutText) -match 'git C:\\fake\\git.exe, system config C:/fake/etc/gitconfig') 'L2: the git path and its system config file are shown'

Write-Host 'refusals (in process: the driver seam cannot skip SSH or stdin)'
foreach ($m in 'apply', 'dry', 'list', 'undo') {
  Reset-Fake; $F.Standby = 1800; $env:SSH_CLIENT = '10.20.30.5 50000 22'
  $rc = Invoke-Fake $m 'C:\none.json' @('y')
  Remove-Item Env:\SSH_CLIENT
  Assert-True ($rc -eq 3 -and $Reads.Count -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'over SSH') "RefusesOverSsh ($m): exit 3 before any read"
  Reset-Fake; $F.Standby = 1800
  $FixOut.Clear(); $rc = Invoke-FixMain -Mode $m -UndoPath 'C:\none.json' -FromFile $false
  Assert-True ($rc -eq 3 -and $Reads.Count -eq 0 -and (OutText) -match 'from stdin') "RefusesFromStdin ($m): exit 3"
}
foreach ($m in 'apply', 'undo') {
  Reset-Fake; $F.Standby = 1800; $script:Console = $false
  $rc = Invoke-Fake $m 'C:\none.json' @('y')
  Assert-True ($rc -eq 3 -and $Reads.Count -eq 0 -and (OutText) -match 'no interactive console') "RefusesWithoutConsole ($m): exit 3"
}
Set-Alias -Name Get-FixNote -Value Get-Date
Reset-Fake; $rc = Invoke-Fake 'dry'
Assert-True ($rc -eq 3 -and $Reads.Count -eq 0 -and (OutText) -match 'alias would run instead.*: Get-FixNote') 'INFO: an alias shadowing a function: refused before anything'
Remove-Item Alias:\Get-FixNote
Reset-Fake; $script:Console = $false; $rc = Invoke-Fake 'list'
Assert-True ($rc -eq 0 -and (OutText) -match 'No undo records' -and (OutText) -match 'never in %LOCALAPPDATA%') '-List needs no console; says where records live'
Reset-Fake; $script:Elev = $false; $rc = Invoke-Fake 'list'
Assert-True ($rc -eq 0 -and (OutText) -match 'Reading them needs an elevated PowerShell') '-List when not elevated: says it needs elevation'

Write-Host 'TamperedRecordRejected'
Reset-Fake; $F.Standby = 1800; $F.LongPaths = 0; $F.Dacl = $OpenDacl
$rc = Invoke-Fake 'apply' '' @('y', 'y', 'y'); $rp = Get-LatestRecord; $good = [System.IO.File]::ReadAllText($rp)
Assert-True ($good -match '"items": \[\n    \{"seq": 1, "id": "power.sleep", "status": "applied"') 'record layout: one item per line'
$tampers = [ordered]@{
  'schema id'                    = { param($t) $t.Replace('lanq-makeready-fix/v1', 'lanq-makeready-fix/v2') }
  'unknown fix id'               = { param($t) $t.Replace('"id": "longpaths.on"', '"id": "evil.fix"') }
  'command in before'            = { param($t) $t.Replace('"before": "value=0 type=dword"', '"before": "value=0 type=dword; Stop-Computer"') }
  'subexpression in before'      = { param($t) $t.Replace('"before": "value=0 type=dword"', '"before": "value=$(Stop-Computer) type=dword"') }
  'extra item field'             = { param($t) $t.Replace('"seq": 2,', '"seq": 2, "run": "Stop-Computer",') }
  'extra top-level field'        = { param($t) $t.Replace('"os": "windows",', '"os": "windows", "hook": "x",') }
  'unknown status'               = { param($t) $t.Replace('"status": "applied"', '"status": "done"') }
  'repeated seq'                 = { param($t) $t.Replace('"seq": 2,', '"seq": 1,') }
  'seq as text'                  = { param($t) $t.Replace('"seq": 2,', '"seq": "2",') }
  'linux record'                 = { param($t) $t.Replace('"os": "windows"', '"os": "linux"') }
  'non-ASCII'                    = { param($t) $t.Replace('"user": "', '"user": "' + [char]0xE9) }
  'escaped control char'         = { param($t) $t.Replace('"command": "', '"command": "\u001b[2J') }
  'bad after shape'              = { param($t) [regex]::Replace($t, '"after": "value=1 type=dword"', '"after": "value=1 && x"') }
  'number as state'              = { param($t) $t.Replace('"before": "value=0 type=dword"', '"before": 0') }
  'not JSON'                     = { param($t) $t.Substring(0, 40) }
  'too large'                    = { param($t) $t + (' ' * 300000) }
  'M1(b) DACL for Everyone'      = { param($t) $t.Replace("`"before`": `"dacl=$OpenDacl`"", '"before": "dacl=D:(A;;FA;;;WD)"') }
  'M1(b) empty DACL'             = { param($t) $t.Replace("`"before`": `"dacl=$OpenDacl`"", '"before": "dacl=D:P"') }
  'M1(b) deny Administrators'    = { param($t) $t.Replace("`"before`": `"dacl=$OpenDacl`"", '"before": "dacl=D:P(D;;FA;;;BA)(A;;FA;;;BA)(A;;FA;;;SY)"') }
  'M1(b) SYSTEM loses control'   = { param($t) $t.Replace("`"before`": `"dacl=$OpenDacl`"", '"before": "dacl=D:P(A;;FA;;;BA)(A;;FR;;;SY)(A;;FA;;;BU)"') }
}
foreach ($k in $tampers.Keys) {
  $tt = & $tampers[$k] $good
  Assert-True ($tt -cne $good) "tamper '$k' changes the text"
  [System.IO.File]::WriteAllText($rp, $tt)
  $F.Standby = 0; $F.LongPaths = 1; $F.Dacl = $TightDacl
  $rc = Invoke-Fake 'undo' $rp @('y', 'y', 'y')
  Assert-True ($rc -eq 2 -and $Calls.Count -eq 0 -and (OutText) -match 'record rejected' -and [System.IO.File]::ReadAllText($rp) -ceq $tt) "TamperedRecordRejected: $k -> exit 2, nothing run, file untouched"
}
Assert-True ((OutText) -match 'not safe to put back: Administrators and SYSTEM') 'M1(b): the rejection says why'
[System.IO.File]::WriteAllText($rp, $good)
$script:Trust = 'the record: it is owned by S-1-5-21-1-2-3-1001, not Administrators or SYSTEM'
$rc = Invoke-Fake 'undo' $rp @('y', 'y', 'y')
Assert-True ($rc -eq 2 -and $Calls.Count -eq 0 -and $Reads.Count -eq 0 -and (OutText) -match 'someone other than Administrators could have written it') 'M1(a): a record others could have written is refused'
$rc = Invoke-Fake 'list'
Assert-True ((OutText) -match 'not trusted \(the record: it is owned by') 'M1(a): -List marks it untrusted'
$script:Trust = ''
$rc = Invoke-Fake 'list'
Assert-True ($rc -eq 0 -and (OutText) -match 'power.sleep applied, longpaths.on applied, ssh.aclkeys applied') '-List shows the records'
[System.IO.File]::WriteAllText((Join-Path $RecDir 'fix-20990101T000000Z.json'), '{"schema": "x"}')
$rc = Invoke-Fake 'list'
Assert-True ($rc -eq 0 -and (OutText) -match 'not a valid record') '-List marks a bad record'
$rc = Invoke-Fake 'undo' (Join-Path $RecDir 'fix-20990102T000000Z.json') @('y')
Assert-True ($rc -eq 2 -and (OutText) -match 'no such file') 'undo of a missing file: exit 2'
$rc = Invoke-Fake 'undo' (Join-Path $RecDir 'notes.json') @('y')
Assert-True ($rc -eq 2 -and (OutText) -match 'reads only the records this script writes') 'R1: a file not named fix-<time>.json is refused'
$other = Join-Path ([IO.Path]::GetTempPath()) ('lanq-other-' + [Guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $other)
Copy-Item -LiteralPath $rp -Destination (Join-Path $other (Split-Path -Leaf $rp))
$rc = Invoke-Fake 'undo' (Join-Path $other (Split-Path -Leaf $rp)) @('y', 'y', 'y')
Assert-True ($rc -eq 2 -and $Calls.Count -eq 0 -and (OutText) -match 'reads only the records this script writes') 'R1: a record outside the record folder is refused'
Remove-Item -LiteralPath $other -Recurse -Force
Remove-Item -LiteralPath $RecDir -Recurse -Force -ErrorAction SilentlyContinue

# ---------- tune fixes (-Tune): the real state readers over a fake registry, power, services,
# tasks, disks, adapters and Defender. Every command that could change the PC is a fake (checked below). ----------
Write-Host 'tune fixes (fakes only)'
Set-Item -Path Function:\Get-FixState -Value $RealFixState
$SvcKey = 'HKLM:\lanq-test\Services'; $DoKey = 'HKLM:\lanq-test\DeliveryOptimization'; $DoSettingKey = 'HKLM:\lanq-test\DoSettings'; $EnvKey = 'HKLM:\lanq-test\Environment'
$ScExe = 'C:\lanq-test-none\sc.exe'
$RunSources = @{ 'HKCU|Run' = @('HKCU:\lanq-test\Run', 'HKCU:\lanq-test\Approved\Run'); 'HKLM|Run' = @('HKLM:\lanq-test\Run', 'HKLM:\lanq-test\Approved\Run'); 'HKLM|Run32' = @('HKLM:\lanq-test\Wow\Run', 'HKLM:\lanq-test\Approved\Run32') }
$FixModuleCmds = @{}   # the fakes below are functions over module command names on purpose
$MeSid = "$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"
function Reset-Tune {
  Reset-Fake
  $script:Reg = @{}; $script:RegKeys = New-Object System.Collections.ArrayList
  $script:Pw = @{ Max = 100; Min = 5; Usb = 0 }; $script:NicUsb = $false
  $script:Svcs = New-Object System.Collections.ArrayList; $script:Tasks = New-Object System.Collections.ArrayList; $script:TaskDenied = $false
  $script:Disks = @([pscustomobject]@{ MediaType = 'SSD'; BusType = 'NVMe' })
  $script:Mp = @{ Mode = 'Normal'; Tamper = $false; Ex = New-Object System.Collections.ArrayList; Readable = $true; Day = 0; Time = [TimeSpan]'02:00:00'; Quick = [TimeSpan]::Zero; Rtp = $true; Rtsd = 0 }
  $script:FakeSid = $MeSid
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'EditionID' 'String' 'Professional'
  foreach ($k in $EnvKey, $SvcKey) { [void]$RegKeys.Add($k) }
}
function Set-Reg([string]$P, [string]$N, [string]$K, $V) { $script:Reg["$P|$N"] = @{ Kind = $K; Value = $V }; if ($RegKeys -notcontains $P) { [void]$RegKeys.Add($P) } }
function Add-Svc([string]$Name, [int]$Start, [int]$Delayed = 0, [string]$Display = '', [string]$Status = 'Stopped') { [void]$Svcs.Add([pscustomobject]@{ Name = $Name; DisplayName = $Display; Status = $Status });Set-Reg "$SvcKey\$Name" 'Start' 'DWord' $Start; Set-Reg "$SvcKey\$Name" 'DelayedAutostart' 'DWord' $Delayed }
function Get-RegVal([string]$Path, [string]$Name) { $e = $script:Reg["$Path|$Name"]; if ($e) { return @{ Has = $true; Kind = $e.Kind; Value = $e.Value } }; return @{ Has = $false } }
function Get-RegNames([string]$Path) { return @($script:Reg.Keys | Where-Object { $_.StartsWith("$Path|") } | ForEach-Object { $_.Substring($Path.Length + 1) } | Sort-Object) }
function Test-RegKey([string]$Path) { return ($RegKeys -contains $Path) }
function Get-UserSid { return $script:FakeSid }
function New-Item { param($Path, [switch]$Force, $ErrorAction, $ItemType) if ($ItemType) { return (Microsoft.PowerShell.Management\New-Item -ItemType $ItemType -Path $Path) }; Note-Call "New-Item $Path"; [void]$RegKeys.Add($Path) }
function Set-ItemProperty { param($Path, $LiteralPath, $Name, $Value, $Type, $ErrorAction) $p = "$LiteralPath$Path"; $v = $Value; if ($Type -eq 'Binary') { $v = [byte[]]$Value }; Note-Call "Set-ItemProperty $p $Name $(@($Value) -join ',') $Type"; Set-Reg $p $Name "$Type" $v }
function Remove-ItemProperty { param($Path, $LiteralPath, $Name, $ErrorAction) $p = "$LiteralPath$Path"; Note-Call "Remove-ItemProperty $p $Name"; $script:Reg.Remove("$p|$Name") }
function Invoke-Native([string]$Exe, [string[]]$ArgList, [int]$Sec = 60) {
  $leaf = Split-Path -Leaf $Exe; $a = @($ArgList); $map = @{ PROCTHROTTLEMAX = 'Max'; PROCTHROTTLEMIN = 'Min'; $UsbSet = 'Usb' }
  if ($leaf -eq 'powercfg.exe' -and $a[0] -eq '/getactivescheme') { return @{ Code = 0; Out = 'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)' } }
  if ($leaf -eq 'powercfg.exe' -and $a[0] -eq '/q') { return @{ Code = 0; Out = ('Current AC Power Setting Index: 0x{0:x8}' -f [int]$script:Pw[$map[$a[3]]]) } }
  Note-Call "$leaf $($a -join ' ')"
  if ($leaf -eq 'powercfg.exe' -and $a[0] -eq '/setacvalueindex') { $script:Pw[$map[$a[3]]] = [int]$a[4] }
  if ($leaf -eq 'sc.exe' -and $a[0] -eq 'config') {
    $st = @{ boot = 0; system = 1; auto = 2; 'delayed-auto' = 2; demand = 3; disabled = 4 }[$a[3]]; Set-Reg "$SvcKey\$($a[1])" 'Start' 'DWord' $st
    if ($a[3] -eq 'delayed-auto') { Set-Reg "$SvcKey\$($a[1])" 'DelayedAutostart' 'DWord' 1 } elseif ($a[3] -eq 'auto') { Set-Reg "$SvcKey\$($a[1])" 'DelayedAutostart' 'DWord' 0 }
  }
  return @{ Code = 0; Out = '' }
}
function Get-Service { param($Name, $ErrorAction) return @($Svcs | Where-Object { -not $Name -or $_.Name -eq $Name }) }
function Get-NetAdapter { param([switch]$Physical, $ErrorAction) $p = 'PCI\VEN_1'; if ($script:NicUsb) { $p = 'USB\VID_1' }; return @([pscustomobject]@{ Status = 'Up'; PnPDeviceID = $p }) }
function Get-PhysicalDisk { param($ErrorAction) return $script:Disks }
function Get-ScheduledTask { param($TaskPath, $TaskName, $ErrorAction) if ($script:TaskDenied) { throw 'Access is denied' }; $r = @($Tasks | Where-Object { (-not $TaskPath -or $_.TaskPath -eq $TaskPath) -and (-not $TaskName -or $_.TaskName -eq $TaskName) }); if ($TaskName -and $r.Count -eq 0) { throw 'No MSFT_ScheduledTask objects found' }; return $r }
function Disable-ScheduledTask { param($TaskPath, $TaskName, $ErrorAction) Note-Call "Disable-ScheduledTask $TaskPath$TaskName"; foreach ($t in @($Tasks | Where-Object { $_.TaskPath -eq $TaskPath -and $_.TaskName -eq $TaskName })) { $t.State = 'Disabled' } }
function Enable-ScheduledTask { param($TaskPath, $TaskName, $ErrorAction) Note-Call "Enable-ScheduledTask $TaskPath$TaskName"; foreach ($t in @($Tasks | Where-Object { $_.TaskPath -eq $TaskPath -and $_.TaskName -eq $TaskName })) { $t.State = 'Ready' } }
function Get-MpComputerStatus { param($ErrorAction) return [pscustomobject]@{ AMRunningMode = $Mp.Mode; IsTamperProtected = $Mp.Tamper; RealTimeProtectionEnabled = $Mp.Rtp } }
function Get-MpPreference { param($ErrorAction) if ($script:MpReadBroken) { throw 'the Defender service is not answering' }; $ex = @($Mp.Ex); if (-not $Mp.Readable) { $ex = @('N/A: Must be an administrator to view exclusions') }; return [pscustomobject]@{ ExclusionPath = $ex; ScanScheduleDay = $Mp.Day; ScanScheduleTime = $Mp.Time; ScanScheduleQuickScanTime = $Mp.Quick; RealTimeScanDirection = $Mp.Rtsd } }
function Set-MpPreference { param($ScanScheduleTime, $ScanScheduleQuickScanTime, $ErrorAction) Note-Call "Set-MpPreference $ScanScheduleTime $ScanScheduleQuickScanTime"; if ($ScanScheduleTime) { $Mp.Time = [TimeSpan]$ScanScheduleTime }; if ($ScanScheduleQuickScanTime) { $Mp.Quick = [TimeSpan]$ScanScheduleQuickScanTime } }
function Add-MpPreference { param($ExclusionPath, $ErrorAction) Note-Call "Add-MpPreference $ExclusionPath"; [void]$Mp.Ex.Add($ExclusionPath) }
function Remove-MpPreference { param($ExclusionPath, $ErrorAction) Note-Call "Remove-MpPreference $ExclusionPath"; if (-not $script:RemoveBroken) { $Mp.Ex.Remove($ExclusionPath) } }
$unsafe = @(foreach ($n in 'Set-ItemProperty', 'Remove-ItemProperty', 'New-Item', 'Invoke-Native', 'Get-RegVal', 'Test-RegKey', 'Disable-ScheduledTask', 'Enable-ScheduledTask', 'Set-MpPreference', 'Add-MpPreference', 'Remove-MpPreference',
    'Get-MpPreference', 'Get-ScheduledTask', 'Get-Service', 'Test-FixElevated', 'Initialize-FixRecordDir', 'New-FixSecuredFile', 'Test-FixRecordTrusted', 'Get-FixRecordDir') { if (@(Get-Command $n)[0].CommandType -ne 'Function' -or @(Get-Command $n)[0].ScriptBlock.File -eq $fixPath) { $n } })
if ($unsafe.Count -gt 0) { Write-Host "ABORT: not faked: $($unsafe -join ', ')" -ForegroundColor Red; exit 1 }
Assert-True $true 'tune: every command that could change the PC is a fake'
function Invoke-Tune([string]$Mode = 'apply', [object[]]$Ans = @(), [string]$Set = 'tune', [string]$Hours = '', [string]$WorkRoot = '', [string]$UndoPath = '') {
  $FixOut.Clear(); $Calls.Clear(); $Snaps.Clear(); $Reads.Clear(); $script:Asked = 0
  foreach ($x in $Ans) { $script:Answers.Enqueue($x) }
  $rc = Invoke-FixMain -Mode $Mode -UndoPath $UndoPath -FromFile $true -Set $Set -Hours $Hours
  $script:Answers.Clear()
  return , $rc
}
function Get-TuneWorld { return ((@($Reg.Keys | Sort-Object | ForEach-Object { "$_=$(@($Reg[$_].Value) -join ',')" }) -join ';') + "|$($Pw.Max),$($Pw.Min),$($Pw.Usb)|" + (@($Tasks | ForEach-Object { "$($_.TaskName)=$($_.State)" }) -join ',') + "|$($Mp.Time),$($Mp.Quick)|$(@($Mp.Ex) -join ',')") }

$approvedCu = 'HKCU:\lanq-test\Approved\Run'
$tcases = @(
  @('power.cpu max 90', { $Pw.Max = 90 }, 'powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100|powercfg.exe /setactive SCHEME_CURRENT',
    'powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 90|powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5|powercfg.exe /setactive SCHEME_CURRENT', ''),
  @('power.cpu min 100', { $Pw.Min = 100 }, 'powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5|powercfg.exe /setactive SCHEME_CURRENT',
    'powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100|powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100|powercfg.exe /setactive SCHEME_CURRENT', ''),
  @('power.usbsuspend on, USB NIC', { $Pw.Usb = 1; $script:NicUsb = $true }, "powercfg.exe /setacvalueindex SCHEME_CURRENT $UsbSub $UsbSet 0|powercfg.exe /setactive SCHEME_CURRENT", "powercfg.exe /setacvalueindex SCHEME_CURRENT $UsbSub $UsbSet 1|powercfg.exe /setactive SCHEME_CURRENT", ''),
  @('startup.vendor HKCU, no flag', { Set-Reg 'HKCU:\lanq-test\Run' 'SupportAssistTray' 'String' '"C:\x\tray.exe" /s' }, "New-Item $approvedCu|Set-ItemProperty $approvedCu SupportAssistTray 3,0,0,0,0,0,0,0,0,0,0,0 Binary", "Remove-ItemProperty $approvedCu SupportAssistTray", ''),
  @('startup.vendor HKLM Run32, enabled flag', { Set-Reg 'HKLM:\lanq-test\Wow\Run' 'Updater' 'String' 'C:\x\ArmouryCrate.exe'; Set-Reg 'HKLM:\lanq-test\Approved\Run32' 'Updater' 'Binary' ([byte[]](2, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8)) },
    'Set-ItemProperty HKLM:\lanq-test\Approved\Run32 Updater 3,0,0,0,0,0,0,0,0,0,0,0 Binary', 'Set-ItemProperty HKLM:\lanq-test\Approved\Run32 Updater 2,0,0,0,1,2,3,4,5,6,7,8 Binary', ''),
  @('vendor.services delayed auto', { Add-Svc 'DellUpdate' 2 1 }, 'sc.exe config DellUpdate start= disabled', 'sc.exe config DellUpdate start= delayed-auto', ''),
  @('vendor.services by display name, manual', { Add-Svc 'xsvc' 3 0 'Lenovo Vantage Service' }, 'sc.exe config xsvc start= disabled', 'sc.exe config xsvc start= demand', ''),
  @('sysmain on an SSD-only PC', { Add-Svc 'SysMain' 2 0 }, 'sc.exe config SysMain start= disabled', 'sc.exe config SysMain start= auto', ''),
  @('vendor.tasks', { [void]$Tasks.Add([pscustomobject]@{ TaskPath = '\LenovoTools\'; TaskName = 'Lenovo Vantage Update'; State = 'Ready' }) }, 'Disable-ScheduledTask \LenovoTools\Lenovo Vantage Update', 'Enable-ScheduledTask \LenovoTools\Lenovo Vantage Update', ''),
  @('do.mode (Pro default, no policy)', {}, "New-Item $DoKey|Set-ItemProperty $DoKey DODownloadMode 0 DWord", "Remove-ItemProperty $DoKey DODownloadMode", ''),
  @('dotnet.env none set', {}, "Set-ItemProperty $EnvKey DOTNET_CLI_TELEMETRY_OPTOUT 1 String|Set-ItemProperty $EnvKey DOTNET_NOLOGO 1 String|Set-ItemProperty $EnvKey DOTNET_GENERATE_ASPNET_CERTIFICATE false String",
    "Remove-ItemProperty $EnvKey DOTNET_CLI_TELEMETRY_OPTOUT|Remove-ItemProperty $EnvKey DOTNET_NOLOGO|Remove-ItemProperty $EnvKey DOTNET_GENERATE_ASPNET_CERTIFICATE", ''),
  @('defender.scantime 02:00 in 00:00-07:00', {}, 'Set-MpPreference 08:00:00 ', 'Set-MpPreference 02:00:00 00:00:00', '00:00-07:00')
)
# everything else already fine, so each case offers exactly one fix
function Set-TuneQuiet { Set-Reg $DoKey 'DODownloadMode' 'DWord' 0; foreach ($v in 'DOTNET_CLI_TELEMETRY_OPTOUT', 'DOTNET_NOLOGO') { Set-Reg $EnvKey $v 'String' '1' }; Set-Reg $EnvKey 'DOTNET_GENERATE_ASPNET_CERTIFICATE' 'String' 'false'; $Mp.Day = 8 }
foreach ($c in $tcases) {
  $tag = $c[0]; Reset-Tune; Set-TuneQuiet
  if ($tag -like 'do.mode*') { $script:Reg.Remove("$DoKey|DODownloadMode"); $RegKeys.Remove($DoKey) }
  if ($tag -like 'dotnet.env*') { foreach ($k in @($Reg.Keys | Where-Object { $_ -like "$EnvKey|*" })) { $Reg.Remove($k) } }
  if ($tag -like 'defender.scantime*') { $Mp.Day = 0 }
  & $c[1]
  $start = Get-TuneWorld
  $rc = Invoke-Tune 'apply' @('y') 'tune' $c[4]
  Assert-Equal $rc 0 "tune $tag apply: exit 0"
  Assert-Equal ($Calls -join '|') $c[2] "tune $tag apply: exact commands"
  Assert-True ($Snaps.Count -gt 0 -and $Snaps[0] -match '"status": "pending"' -and $Snaps[0] -notmatch '"after": "unknown"') "tune $tag RecordWrittenBeforeChange, with the expected after state"
  $rp = Get-LatestRecord; $j = Read-Rec $rp
  Assert-True (@($j.items).Count -eq 1 -and $j.items[0].status -eq 'applied' -and $script:Asked -eq 1) "tune $tag record: one item, applied, one question"
  Assert-Equal (Read-FixRecord $rp).Error '' "tune $tag record: valid for -Undo"
  $rc = Invoke-Tune 'undo' @('y') 'base' '' '' $rp
  Assert-Equal $rc 0 "tune $tag undo: exit 0"
  Assert-Equal ($Calls -join '|') $c[3] "tune $tag undo: exact commands"
  Assert-Equal (Get-TuneWorld) $start "tune $tag undo: back to the start"
}
Reset-Tune; Set-TuneQuiet; Add-Svc 'DellUpdate' 2 1; [void]$Tasks.Add([pscustomobject]@{ TaskPath = '\LenovoTools\'; TaskName = 'Lenovo Vantage Update'; State = 'Ready' })
$rc = Invoke-Tune 'apply' @('y', 'y'); Assert-True ((OutText) -match 'stops at the next restart' -and (OutText) -match 'enable their tasks again') 'tune: notes after a service and a task (restart; updaters re-enable tasks)'
$rp = Get-LatestRecord; Assert-True ((Get-Content -LiteralPath $rp -Raw) -match '"before": "start=2 delayed=1 name=DellUpdate"') 'vendor.services: Start and DelayedAutostart are recorded'

Write-Host 'tune: what is not offered'
Reset-Tune; Set-TuneQuiet; $rc = Invoke-Tune 'apply' @('y', 'y', 'y')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and (OutText) -match 'Nothing to fix here') 'tune: all fine: nothing offered, nothing asked'
Reset-Tune; Set-TuneQuiet; [void]$Tasks.Add([pscustomobject]@{ TaskPath = '\Microsoft\Windows\SupportAssist\'; TaskName = 'SupportAssistAgent'; State = 'Ready' }); Add-Svc 'wuauserv' 3; Add-Svc 'WSearch' 2
$rc = Invoke-Tune 'apply' @('y', 'y'); Assert-True ($Calls.Count -eq 0 -and $script:Asked -eq 0) 'tune: tasks under \Microsoft\ and Windows services are never offered'
Reset-Tune; Set-TuneQuiet; $script:TaskDenied = $true; $rc = Invoke-Tune 'dry'
Assert-True ($rc -eq 0 -and (OutText) -match 'vendor\.tasks .*not offered: the scheduled tasks could not be read \(access denied\); skipped') 'vendor.tasks: access denied: skipped with a note'
Reset-Tune; Set-TuneQuiet; Add-Svc 'SysMain' 2; $script:Disks = @([pscustomobject]@{ MediaType = 'SSD'; BusType = 'NVMe' }, [pscustomobject]@{ MediaType = 'Unspecified'; BusType = 'SATA' }); $rc = Invoke-Tune 'dry'
Assert-True ((OutText) -notmatch '(?m)^sysmain') 'sysmain: a disk of unknown type (Unspecified) is not an SSD: not offered'
Reset-Tune; Set-TuneQuiet; Set-Reg $DoKey 'DODownloadMode' 'DWord' 3; $rc = Invoke-Tune 'dry'
Assert-True ((OutText) -match 'do\.mode .*not offered: DODownloadMode is 3 by a policy') 'do.mode: a policy already set is left to whoever set it'
Reset-Tune; Set-TuneQuiet; Set-Reg $DoSettingKey 'DownloadMode' 'DWord' 0; $script:Reg.Remove("$DoKey|DODownloadMode"); $rc = Invoke-Tune 'dry'
Assert-True ((OutText) -notmatch '(?m)^do\.mode') 'do.mode: HTTP only in Settings: nothing to do'
Reset-Tune; Set-TuneQuiet; Set-Reg $EnvKey 'DOTNET_NOLOGO' 'String' 'yes please'; $rc = Invoke-Tune 'dry'
Assert-True ((OutText) -match 'dotnet\.env .*not offered: DOTNET_NOLOGO has a value this script does not record') 'dotnet.env: an unusual value is not recorded or changed'
Reset-Tune; Set-TuneQuiet; Set-Reg 'HKCU:\lanq-test\Run' 'SupportAssist Tray' 'String' 'x.exe'; Set-Reg $approvedCu 'SupportAssist Tray' 'Binary' ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)); $rc = Invoke-Tune 'dry'
Assert-True ((OutText) -notmatch '(?m)^startup\.vendor') 'startup.vendor: already disabled in Task Manager (odd first byte): not offered'
Reset-Tune; Set-TuneQuiet; Set-Reg 'HKCU:\lanq-test\Run' 'SupportAssist Tray' 'String' 'x.exe'; Set-Reg $approvedCu 'SupportAssist Tray' 'Binary' ([byte[]](2, 0)); $rc = Invoke-Tune 'dry'
Assert-True ((OutText) -match 'not offered: SupportAssist Tray: its StartupApproved value is not the usual 12-byte flag') 'startup.vendor: an unusual flag value: a note, not a fix'
Reset-Tune; Set-TuneQuiet; Set-Reg 'HKCU:\lanq-test\Run' 'OneDrive' 'String' 'C:\x\OneDrive.exe'; Set-Reg 'HKCU:\lanq-test\Run' 'MyTool' 'String' 'C:\x\tool.exe'; $rc = Invoke-Tune 'dry'
Assert-True ((OutText) -notmatch '(?m)^startup\.vendor') 'startup.vendor: only names on the curated list'
Reset-Tune; Set-TuneQuiet; $Mp.Day = 0; $rc = Invoke-Tune 'dry'
Assert-True ((OutText) -match 'defender\.scantime .*not offered: give the job window with -Hours') 'defender.scantime: needs -Hours'
Reset-Tune; Set-TuneQuiet; $Mp.Day = 0; $Mp.Mode = 'Passive Mode'; $rc = Invoke-Tune 'dry' @() 'tune' '00:00-07:00'
Assert-True ((OutText) -match 'not offered: Defender is not the active antivirus \(AMRunningMode: Passive Mode\)') 'defender.scantime: SKIP when AMRunningMode is not Normal'
Reset-Tune; Set-TuneQuiet; $Mp.Day = 0; $Mp.Time = [TimeSpan]'12:00:00'; $Mp.Quick = [TimeSpan]'03:30:00'; $rc = Invoke-Tune 'apply' @('y') 'tune' '22:00-07:00'
Assert-Equal ($Calls -join '|') 'Set-MpPreference  08:00:00' 'defender.scantime: only the quick scan inside the window is moved (an hour after the window ends)'
Reset-Tune; Set-TuneQuiet; Add-Svc 'DellUpdate' 2; $script:Elev = $false; $rc = Invoke-Tune 'apply' @('y')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and (OutText) -match 'needs an elevated PowerShell') 'tune: not elevated: shown, skipped, nothing asked'
Reset-Tune; Set-TuneQuiet; Add-Svc 'DellUpdate' 2; $Pw.Max = 50; $script:Console = $false; $before = Get-TuneWorld; $rc = Invoke-Tune 'dry' @('y', 'y')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and (Get-TuneWorld) -eq $before -and $null -eq (Get-LatestRecord) -and (OutText) -match '(?m)^vendor\.services DellUpdate' -and (OutText) -match 'undo: +sc\.exe config DellUpdate start= auto') 'tune -WhatIf: shown with the undo, nothing changed or asked'
Reset-Tune; Set-TuneQuiet; Add-Svc 'DellUpdate' 2; $rc = Invoke-Tune 'apply' @('n')
Assert-True ($Calls.Count -eq 0 -and $null -eq (Get-LatestRecord)) 'tune: DefaultIsNo'

Write-Host 'tune: record cap, SID, curated names on undo'
Reset-Tune; Set-TuneQuiet; for ($i = 1; $i -le 66; $i++) { Add-Svc ("DellUpdate$i") 3 }
$rc = Invoke-Tune 'apply' @(1..66 | ForEach-Object { 'y' })
$j = Read-Rec (Get-LatestRecord)
Assert-True (@($j.items).Count -eq 64 -and $script:Asked -eq 64 -and ([regex]::Matches((OutText), 'record is full')).Count -eq 2) 'record cap: at most 64 changes per record; the rest are not offered (run again)'
Reset-Tune; Set-TuneQuiet; Set-Reg 'HKCU:\lanq-test\Run' 'SupportAssistTray' 'String' 'x.exe'
$rc = Invoke-Tune 'apply' @('y'); $rp = Get-LatestRecord
Assert-True ((Get-Content -LiteralPath $rp -Raw) -match "sid=$MeSid") 'startup.vendor: the account SID is recorded'
$script:FakeSid = 'S-1-5-21-1-2-3-1002'; $rc = Invoke-Tune 'undo' @('y') 'base' '' '' $rp
Assert-True ($Calls.Count -eq 0 -and $script:Asked -eq 0 -and (OutText) -match "left alone: this entry belongs to the account $MeSid") 'startup.vendor: undo under another account (SID) refused for HKCU'
$script:FakeSid = $MeSid; $rc = Invoke-Tune 'undo' @('y') 'base' '' '' $rp
Assert-True ($rc -eq 0 -and $Calls.Count -eq 1 -and (Read-Rec $rp).items[0].status -eq 'undone') 'startup.vendor: undo by the same account'
Reset-Tune; Set-TuneQuiet; Add-Svc 'DellUpdate' 2; $rc = Invoke-Tune 'apply' @('y'); $rp = Get-LatestRecord
$t = (Get-Content -LiteralPath $rp -Raw).Replace('DellUpdate', 'Spooler'); [System.IO.File]::WriteAllText($rp, $t); Add-Svc 'Spooler' 4
$rc = Invoke-Tune 'undo' @('y') 'base' '' '' $rp
Assert-True ($Calls.Count -eq 0 -and (OutText) -match 'left alone: Spooler is not a known PC-maker service') 'undo: a valid-shaped name that is not on the curated list is left alone'
$VendorRetiredPatterns = @('^Spooler$'); $rc = Invoke-Tune 'undo' @('y') 'base' '' '' $rp
Assert-True (($Calls -join '|') -eq 'sc.exe config Spooler start= auto') 'undo: a name on the append-only retired list is still undone'
$VendorRetiredPatterns = @()
foreach ($bad in @(@('vendor.tasks', 'enabled=1 path=\Microsoft\Windows\ name=SupportAssist'), @('vendor.services', 'start=2 delayed=0 name=a b'), @('sysmain', 'start=2 delayed=0 name=DellUpdate'),
    @('startup.vendor', 'hive=HKCU key=Run32 sid=S-1-5-21-1 flag=- name=SupportAssist'), @('startup.vendor', 'hive=HKCU key=Run sid=S-1-5-21-1 flag=- name=x;y'),
    @('defender.scantime', 'day=0 time=1440 quick=0'), @('power.cpu', 'scheme=381b4222-f694-41f0-9685-ff5bb260df2e max=101 min=5'), @('dotnet.env', 'telemetry=$(x) nologo=- aspnetcert=-'))) {
  Assert-True ($null -eq (ConvertFrom-StateText $bad[0] $bad[1])) "tune state shape rejected: $($bad[0]) '$($bad[1])'"
}
Reset-Tune; Set-TuneQuiet; $Pw.Max = 90; $rc = Invoke-Tune 'apply' @('y'); $rp = Get-LatestRecord
[System.IO.File]::WriteAllText($rp, ([System.IO.File]::ReadAllText($rp) -replace '"id": "power.cpu"', '"id": "defender.exclude"'))
$rc = Invoke-Tune 'undo' @('y') 'base' '' '' $rp
Assert-True ($rc -eq 2 -and $Calls.Count -eq 0 -and (OutText) -match 'record rejected \(before state of defender.exclude has an unexpected shape\)') 'C1: a defender.exclude item with another fix''s state is rejected (exit 2)'
[System.IO.File]::WriteAllText($rp, ([System.IO.File]::ReadAllText($rp) -replace '"id": "defender.exclude"', '"id": "defender.everything"'))
$rc = Invoke-Tune 'undo' @('y') 'base' '' '' $rp
Assert-True ($rc -eq 2 -and $Calls.Count -eq 0 -and (OutText) -match 'record rejected \(unknown fix id\)') 'an unknown fix id is still rejected (exit 2)'
Assert-True (Test-SameState 'vendor.services' 'start=3 delayed=1 name=X' 'start=3 delayed=0 name=X') 'services: the delayed flag does not count for a manual service'
Assert-True (-not (Test-SameState 'vendor.services' 'start=2 delayed=1 name=X' 'start=2 delayed=0 name=X')) 'services: the delayed flag counts for an automatic service'

Reset-Tune; Set-TuneQuiet; $Mp.Day = 0; $rc = Invoke-Tune 'dry' @() 'tune' '00:00-23:30'
Assert-True ((OutText) -match 'defender\.scantime .*not offered: the job window 00:00-23:30 leaves no hour') 'defender.scantime: not offered when an hour after the window is still inside it'
Reset-Tune; Set-TuneQuiet; ${function:Get-ScheduledTask} = { param($TaskPath, $TaskName, $ErrorAction) throw 'The RPC server is unavailable' }; $rc = Invoke-Tune 'dry'
Assert-True ((OutText) -match 'vendor\.tasks .*not offered: the scheduled tasks could not be read; skipped' -and (OutText) -notmatch 'access denied') 'vendor.tasks: another error is not called "access denied"'
${function:Get-ScheduledTask} = { param($TaskPath, $TaskName, $ErrorAction) if ($script:TaskDenied) { throw 'Access is denied' }; $r = @($Tasks | Where-Object { (-not $TaskPath -or $_.TaskPath -eq $TaskPath) -and (-not $TaskName -or $_.TaskName -eq $TaskName) }); if ($TaskName -and $r.Count -eq 0) { throw 'No MSFT_ScheduledTask objects found' }; return $r }

$esc = [string][char]27
$ss = Get-StateSummary 'startup.vendor' @{ Hive = 'HKCU'; Key = 'Run'; Name = "SupportAssist${esc}[2J"; Exe = (('x' * 500) + "${esc}]0;t.exe"); Flag = '-' }
$sv = Get-StateSummary 'vendor.services' @{ Name = 'DellUpdate'; Display = ("Dell Update${esc}[31m" + ('y' * 900)); Start = 2; Delayed = 0 }
Assert-True ($ss -notmatch '[\x00-\x1F\x7F]' -and $sv -notmatch '[\x00-\x1F\x7F]' -and $ss.Length -lt 250 -and $sv.Length -lt 200) 'the consent prompt shows Run entry, program and service display names without control characters, capped'

# ---------- defender.exclude and devdrive.create (0.6.0). Matrix ids (docs/TUNE.md, "Test matrix"): A1-A10, B1-B7,
# C1-C4, D1-D7, E9, G2 here; B8 and E1-E8 in tests/real-defender.ps1 (CI, best effort) and on build-02; G1 on build-02.
# Fakes only: every folder these fixes create lands in a temp sandbox, the test file is harmless text (never the real
# EICAR string), and Defender, the disks, the volumes and the accounts are fakes. ----------
Write-Host 'defender.exclude and devdrive.create: pure checks'
$Bu = 'S-1-5-21-1111-2222-3333-1005'
$RealWorkDirSddl = $WorkDirSddl
$RealSelfTest = ${function:Test-SelfTestDir}
$wsd = ConvertFrom-Sddl ($RealWorkDirSddl -f $Bu)
Assert-True ($null -ne $wsd -and "$($wsd.Owner)" -eq $BaSid -and (([int]$wsd.ControlFlags -band 0x1000) -ne 0)) 'B1: lanq-work is owned by Administrators and protected (nothing inherited from the drive root)'
$wa = @($wsd.DiscretionaryAcl)
$onSelf = @($wa | Where-Object { "$($_.SecurityIdentifier)" -eq $Bu -and -not ([int]$_.AceFlags -band 8) })
Assert-True ($onSelf.Count -eq 1 -and ($onSelf[0].AccessMask -band (0x10000 -bor 0x40000 -bor 0x80000 -bor 0x40 -bor 0x100 -bor 0x10000000 -bor 0x40000000)) -eq 0 -and ($onSelf[0].AccessMask -band 0x6) -eq 0x6) 'B1: on the folder itself the build user may add files and folders, but has no DELETE, WRITE_DAC, WRITE_OWNER, DELETE_CHILD or WRITE_ATTRIBUTES'
$io = @($wa | Where-Object { [int]$_.AceFlags -band 8 })
Assert-True (@($io | Where-Object { @($Bu, 'S-1-3-4') -contains "$($_.SecurityIdentifier)" }).Count -eq 2 -and @($io | Where-Object { ($_.AccessMask -band 0xC0000) -ne 0 -or ($_.AccessMask -band 0x10000) -eq 0 }).Count -eq 0) 'B1/H3: the build user and OWNER RIGHTS get Modify without WRITE_DAC or WRITE_OWNER on what is created inside'
Assert-True (@($wa | Where-Object { @($BaSid, $SySid, $Bu, 'S-1-3-4') -notcontains "$($_.SecurityIdentifier)" }).Count -eq 0 -and @($wa | Where-Object { "$($_.AceQualifier)" -ne 'AccessAllowed' }).Count -eq 0) 'B1: Administrators, SYSTEM, the build user and OWNER RIGHTS only; no deny entries'
Assert-True (Test-WorkDirSd ($RealWorkDirSddl -f $Bu) $Bu) 'B1: the permissions this script sets match its own check'
Assert-True (Test-WorkDirSd "O:BAG:SYD:PAI(A;OICIIO;0x1301bf;;;OW)(A;OICIIO;0x1301bf;;;$Bu)(A;;0x1200af;;;$Bu)(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)" $Bu) 'C3: the same entries in another order, with another group, still match (as Windows may read them back)'
foreach ($b in @(@("O:$($Bu)G:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200af;;;$Bu)(A;OICIIO;0x1301bf;;;$Bu)(A;OICIIO;0x1301bf;;;OW)", 'owned by the build user'),
    @("O:BAG:BAD:AI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200af;;;$Bu)(A;OICIIO;0x1301bf;;;$Bu)(A;OICIIO;0x1301bf;;;OW)", 'not protected'),
    @("O:BAG:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200af;;;$Bu)(A;OICIIO;0x1301bf;;;$Bu)(A;OICIIO;0x1301bf;;;OW)(A;OICI;0x1200a9;;;WD)", 'Everyone may read'),
    @("O:BAG:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;$Bu)(A;OICIIO;0x1301bf;;;OW)", 'the build user may delete the folder'),
    @("O:BAG:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200af;;;$Bu)(A;OICIIO;0x1301bf;;;$Bu)", 'no OWNER RIGHTS entry'),
    @("O:BAG:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200af;;;S-1-5-21-1111-2222-3333-1006)(A;OICIIO;0x1301bf;;;S-1-5-21-1111-2222-3333-1006)(A;OICIIO;0x1301bf;;;OW)", 'made for another build user'),
    @('', 'unreadable'))) {
  Assert-True (-not (Test-WorkDirSd $b[0] $Bu)) "B1/C3: not the folder this script makes: $($b[1])"
}
Assert-True ((Get-SdHash ($RealWorkDirSddl -f $Bu)) -cmatch '^[0-9a-f]{64}$' -and (Get-SdHash ($RealWorkDirSddl -f $Bu)) -ceq (Get-SdHash "O:BAG:SYD:PAI(A;OICIIO;0x1301bf;;;OW)(A;OICIIO;0x1301bf;;;$Bu)(A;;0x1200af;;;$Bu)(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)")) 'C3: the permissions hash is SHA-256 of the canonical form (order and group do not count)'

$RootDefault = 'O:S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464G:S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464D:(A;;LC;;;AU)(A;OICIIO;SDGXGWGR;;;AU)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)(A;;0x1000a1;;;S-1-15-3-65536-1888954469-739942743-1668119174-2468466756-4239452838-1296943325-355587736-700089176)'
Assert-Equal (Test-RootSddl $RootDefault) '' 'B2: the default root of C: on Windows 11 passes'
Assert-Equal (Test-RootSddl 'O:SYG:SYD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;BU)(A;OICIIO;SDGXGWGR;;;AU)(A;;0x4;;;AU)') '' 'B2: an older default root passes'
Assert-Equal (Test-RootSddl 'O:SYG:SYD:PAI(A;OICI;FA;;;BA)(A;OICIIO;GA;;;CO)(D;;0x40;;;AU)(A;OICIIO;0x1301bf;;;AU)') '' 'B2: inherit-only and deny entries do not apply to the root itself'
Assert-Equal (Test-RootSddl 'O:SYG:SYD:PAI(A;OICI;FA;;;BA)(A;;0x1301bf;;;AU)') '' 'B2: Modify on the root itself (no DELETE_CHILD) cannot rename or replace what is in it'
foreach ($r in @(@('(A;;0x40;;;AU)', 'DELETE_CHILD'), @('(A;;WD;;;BU)', 'WRITE_DAC'), @('(A;;WO;;;BU)', 'WRITE_OWNER'), @('(A;;GA;;;WD)', 'GENERIC_ALL'), @('(A;;GW;;;AU)', 'GENERIC_WRITE'), @("(A;;FA;;;$Bu)", 'full control'))) {
  Assert-True ((Test-RootSddl ('O:SYG:SYD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)' + $r[0])) -match 'may delete or rename') "B3: a drive root that gives others $($r[1]) fails"
}
Assert-True ((Test-RootSddl "O:$($Bu)G:SYD:PAI(A;OICI;FA;;;BA)") -match 'owned by') 'B3: a drive root owned by a user fails'
Assert-True ((Test-RootSddl 'O:SYG:SYD:NO_ACCESS_CONTROL') -match 'no DACL') 'B3: a drive root with a NULL DACL fails'
Assert-True ((Test-RootSddl 'O:SYG:SYD:PAI(A;OICI;FA;;;BA)(XA;;0x1;;;WD;(@User.x == "y"))') -ne '') 'B3: a conditional (callback) entry on the root fails closed'
Assert-True ((Test-RootSddl '') -match 'cannot be read') 'B3: an unreadable root fails'

$okU = @{ Given = 'builder'; Name = 'PC\builder'; Found = $true; Sid = $Bu; Local = $true; Type = 1; Disabled = $false; Admin = $false }
Assert-Equal (Get-BuildUserProblem $okU) '' 'B6: a local, enabled user account is a valid build user'
foreach ($u in @(@{ Found = $false; Given = 'nobody' }, @{ Sid = 'S-1-5-32-545' }, @{ Sid = 'S-1-5-18' }, @{ Sid = 'S-1-5-21-1111-2222-3333-501' }, @{ Sid = 'S-1-5-21-1111-2222-3333-500' }, @{ Local = $false }, @{ Type = 2 }, @{ Disabled = $true })) {
  $t = $okU.Clone(); foreach ($k in $u.Keys) { $t[$k] = $u[$k] }
  Assert-True ((Get-BuildUserProblem $t) -ne '') "B6: not a valid build user: $(($u.Keys | ForEach-Object { "$_=$($u[$_])" }) -join ' ')"
}
$au = $okU.Clone(); $au.Admin = $true
Assert-Equal (Get-BuildUserProblem $au) '' 'B6: an administrator is accepted (with a warning, shown below)'

$entryC = 'C:\lanq-work\'
Assert-Equal (Get-LanqWorkEntry 'C') $entryC 'A1/A2: the exclusion is always <drive>:\lanq-work\ (with the trailing backslash)'
foreach ($x in 'CC', '1', '', 'C:\x', 'c', '%') { Assert-Equal (Get-LanqWorkEntry $x) '' "A1/A2: no entry for a drive '$x'" }
Assert-True ((Get-SystemDriveLetter) -cmatch '^[A-Z]$' -and (Get-SystemDriveLetter) -eq ([Environment]::GetFolderPath('Windows')).Substring(0, 1)) 'A1: the drive is the one Windows is on (%SystemDrive%), never given by the user'
$exCases = @(@(@('C:\'), 'Broader'), @(@('c:'), 'Broader'), @(@('C:\lanq-work\..\'), 'Unknown'), @(@('\\?\C:\'), 'Broader'), @(@('C:\lanq-work'), 'Variant'), @(@('c:\LANQ-WORK.'), 'Variant'), @(@('C:\lanq-work\\'), 'Variant'),
  @(@('c:\LANQ-WORK\'), 'Exact'), @(@('%SystemDrive%\lanq-work\'), 'Variant'), @(@('%SystemDrive%\'), 'Broader'), @(@('%BUILDROOT%\x'), 'Unknown'), @(@('C:\lanq*'), 'Unknown'), @(@('C:\l?nq-work\'), 'Unknown'))
foreach ($c in $exCases) {
  $st = Get-ExclusionStatus $c[0] $entryC
  Assert-True ($st[$c[1]] -and @('Exact', 'Variant', 'Broader', 'Unknown' | Where-Object { $st[$_] }).Count -eq 1) "A10/H4: existing exclusion '$($c[0])' is $($c[1])"
}
$st = Get-ExclusionStatus @('C:\lanq-work-old\', 'D:\', 'C:\Users\*\AppData', '%TEMP%', '%USERPROFILE%\.nuget\packages', 'C:\lanq-work\sub\', 'C:\Windows\Temp') $entryC
Assert-True (-not ($st.Exact -or $st.Variant -or $st.Broader -or $st.Unknown)) 'A10: siblings, other drives, profile and temp variables and narrower entries do not cover lanq-work'

$okStates = @(@('defender.exclude', "entry=0 dir=absent path=C:\lanq-work\ user=$Bu vol={11111111-2222-3333-4444-555555555555} fileid=- sd=-"),
  @('defender.exclude', "entry=1 dir=lanq path=D:\lanq-work\ user=$Bu vol={11111111-2222-3333-4444-555555555555} fileid=0x000000000000000000010000000ed741 sd=$('a' * 64)"),
  @('defender.exclude', 'entry=0 dir=other path=C:\lanq-work\ user=- vol=- fileid=- sd=-'),
  @('devdrive.create', "vhd=absent letter=- size=100 user=$Bu dir=absent"), @('devdrive.create', "vhd=attached letter=L size=50 user=$Bu dir=lanq"), @('devdrive.create', 'vhd=detached letter=- size=65536 user=- dir=other'))
foreach ($s in $okStates) { Assert-True ($null -ne (ConvertFrom-StateText $s[0] $s[1])) "C1: state shape accepted: $($s[0]) $($s[1])" }
$badStates = @(@('defender.exclude', "entry=1 dir=lanq path=C:\Windows\ user=$Bu vol=- fileid=- sd=-"), @('defender.exclude', "entry=1 dir=lanq path=C:\lanq-work\x\ user=$Bu vol=- fileid=- sd=-"),
  @('defender.exclude', "entry=1 dir=lanq path=C:\lanq-work user=$Bu vol=- fileid=- sd=-"), @('defender.exclude', 'entry=1 dir=lanq path=C:\lanq-work\ user=S-1-5-32-544 vol=- fileid=- sd=-'),
  @('defender.exclude', "entry=2 dir=lanq path=C:\lanq-work\ user=$Bu vol=- fileid=- sd=-"), @('defender.exclude', "entry=1 dir=evil path=C:\lanq-work\ user=$Bu vol=- fileid=- sd=-"),
  @('defender.exclude', "entry=1 dir=lanq path=%SystemDrive%\lanq-work\ user=$Bu vol=- fileid=- sd=-"), @('defender.exclude', "entry=1 dir=lanq path=C:\lanq-work\ user=$Bu vol=x fileid=- sd=-"),
  @('defender.exclude', "entry=1 dir=lanq path=C:\lanq-work\ user=$Bu vol=- fileid=- sd=zz"), @('defender.exclude', "entry=1 dir=lanq path=C:\lanq-work\ user=$Bu vol=- fileid=- sd=-; Remove-MpPreference x"),
  @('devdrive.create', "vhd=attached letter=C:\ size=100 user=$Bu dir=lanq"), @('devdrive.create', "vhd=attached letter=L size=10 user=$Bu dir=lanq"), @('devdrive.create', "vhd=attached letter=L size=99999 user=$Bu dir=lanq"),
  @('devdrive.create', "vhd=gone letter=L size=100 user=$Bu dir=lanq"))
foreach ($s in $badStates) { Assert-True ($null -eq (ConvertFrom-StateText $s[0] $s[1])) "C1: state shape rejected: $($s[0]) '$($s[1])'" }

$eb = Get-EicarBytes; $sha = [System.Security.Cryptography.SHA256]::Create()
Assert-True ($eb.Length -eq 68 -and (@($sha.ComputeHash($eb) | ForEach-Object { '{0:x2}' -f $_ }) -join '') -eq '275a021bbfb6489e54d471899f7db9d1663fc695ec2fe2a2c4538aabf651fd0f') 'M5: the test file is the standard EICAR file, built at run time (the script itself does not hold the string)'
$eb = $null; $sha.Dispose()
Assert-True ($fixText -notmatch 'EICAR-STANDARD' -and $fixText -notmatch 'X5O!P') 'M5: the fix script does not contain the EICAR string (Defender would flag the script)'
$ddTrusted = "This is a trusted developer volume.`r`nDeveloper volumes are protected by antivirus filter.`r`nFilters currently attached to this developer volume:`r`n    WdFilter, bindFlt"
$di = Get-DevDrvInfo $ddTrusted; Assert-True ($di.State -eq 'trusted' -and $di.Av -eq 'ok' -and $di.Filter) 'D5: fsutil devdrv query: a trusted Dev Drive with WdFilter attached'
$di = Get-DevDrvInfo 'This is not a developer volume.'; Assert-True ($di.State -eq 'no') 'D5: fsutil devdrv query: not a Dev Drive'
$di = Get-DevDrvInfo "This is an untrusted developer volume.`r`nDeveloper volumes are protected by antivirus filter."; Assert-True ($di.State -eq 'untrusted') 'D5: fsutil devdrv query: untrusted'
$di = Get-DevDrvInfo "This is a trusted developer volume.`r`nDeveloper volumes are not protected by antivirus filter (disallowAv)."; Assert-True ($di.State -eq 'trusted' -and $di.Av -eq 'disallowed') 'D5: fsutil devdrv query: antivirus disallowed'
Assert-True ((Test-DevDriveBuild 22621 2338) -and (Test-DevDriveBuild 22631 0) -and (Test-DevDriveBuild 26100 1) -and -not (Test-DevDriveBuild 22621 2337) -and -not (Test-DevDriveBuild 22000 2600) -and -not (Test-DevDriveBuild 19045 5000)) 'D1: Dev Drive needs build 22621.2338 or later'

Write-Host 'defender.exclude and devdrive.create: arguments'
$ga = Get-UndoArg @('-DefenderExclusions', '-BuildUser', 'builder')
Assert-True ($ga.Defender -and -not $ga.DevDrive -and $ga.BuildUser -eq 'builder' -and @($ga.Rest).Count -eq 0 -and -not $ga.Error) 'Get-UndoArg: -DefenderExclusions and -BuildUser'
$ga = Get-UndoArg @('-createdevdrive', '-buildUser', 'b', '-SizeGB', '200'); Assert-True ($ga.DevDrive -and $ga.SizeGB -eq '200') 'Get-UndoArg: -CreateDevDrive and -SizeGB (any case)'
Assert-True ((Get-UndoArg @('-BuildUser')).Error -match '-BuildUser needs') 'Get-UndoArg: -BuildUser without a value'
foreach ($e in @(@(@{ Defender = $true; BuildUser = $null }, $true, 'apply', 'needs -BuildUser'), @(@{ DevDrive = $true; BuildUser = $null }, $true, 'dry', 'needs -BuildUser'), @(@{ Defender = $true; BuildUser = 'b' }, $false, 'apply', 'go with -Tune'),
    @(@{ Defender = $true; DevDrive = $true; BuildUser = 'b' }, $true, 'apply', 'only one of'), @(@{ BuildUser = 'b' }, $true, 'apply', '-BuildUser goes with'), @(@{ SizeGB = '100'; Defender = $true; BuildUser = 'b' }, $true, 'apply', '-SizeGB goes with -CreateDevDrive'),
    @(@{ DevDrive = $true; BuildUser = 'b'; SizeGB = '49' }, $true, 'apply', '-SizeGB must be'), @(@{ DevDrive = $true; BuildUser = 'b'; SizeGB = '1e3' }, $true, 'apply', '-SizeGB must be'), @(@{ DevDrive = $true; BuildUser = 'b'; SizeGB = '70000' }, $true, 'apply', '-SizeGB must be'),
    @(@{ Defender = $true; BuildUser = "b`r`nx" }, $true, 'apply', '-BuildUser must be'), @(@{ Defender = $true; BuildUser = 'b'; Hours = '22:00-07:00' }, $true, 'apply', '-Hours goes with'))) {
  $ua0 = @{ Hours = $null; Defender = $false; DevDrive = $false; BuildUser = $null; SizeGB = $null }; foreach ($k in $e[0].Keys) { $ua0[$k] = $e[0][$k] }
  Assert-True ((Get-TuneArgError $ua0 $e[1] $e[2]) -match [regex]::Escape($e[3])) "D2/B6: arguments refused: $($e[3])"
}
Assert-Equal (Get-TuneArgError @{ Hours = $null; Defender = $false; DevDrive = $true; BuildUser = 'builder'; SizeGB = '50' } $true 'dry') '' 'D2: -CreateDevDrive -BuildUser -SizeGB 50 accepted'

Write-Host 'defender.exclude and devdrive.create: apply, refuse and undo (fakes; folders only in a temp sandbox)'
$Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('lanq-dx-' + [Guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $Sandbox)
function Get-DriveRoot([string]$L) { return ((Join-Path $Sandbox $L) + '\') }
# No owner (a test cannot make Administrators the owner) and this account may clean up; the checks read the fake facts.
$WorkDirSddl = 'D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200af;;;{0})(A;OICIIO;0x1301bf;;;{0})(A;OICIIO;0x1301bf;;;OW)(A;OICI;FA;;;' + $MeSid + ')'
$AdminOnlySddl = "D:PAI(A;OICI;FA;;;$MeSid)"
$DevVhdDir = Join-Path $Sandbox 'ProgramData\devdrive'; $DevVhdFile = Join-Path $DevVhdDir 'lanq-devdrive.vhdx'
$DiskpartExe = 'C:\lanq-test-none\diskpart.exe'; $FsutilExe = 'C:\lanq-test-none\fsutil.exe'
function Get-SystemDriveLetter { return 'C' }
function Get-EicarBytes { return [System.Text.Encoding]::ASCII.GetBytes('lanq-makeready fake test file, not a virus') }
function Get-Rel([string]$P) { return (($P -replace '^\\\\\?\\', '').Replace($Sandbox + '\', '') -replace '[0-9a-f]{32}', '<id>') }
function Wait-MpDetection([string]$Path, $Since, [int]$Sec, [switch]$HistoryOnly) {
  $rel = Get-Rel $Path; $hn = ''; if ($HistoryOnly) { $hn = ' (history)' }; Note-Call "detect $rel$hn"
  if ($script:MpReadBrokenNext) { $script:MpReadBroken = $true; $script:MpReadBrokenNext = $false }   # the service stops answering after the add (L-2)
  if ($script:ThrowAt -and $rel -like $script:ThrowAt) { throw 'interrupted (a fake failure in the middle of the matrix)' }
  if ($script:JunctionAfterPc -and $rel -like 'C\lanq-selftest-*') { $script:WdOver['C\lanq-work'] = @{ Exists = $true; Reparse = $true; Sddl = ''; Fresh = $false; Pin = $false; FileId = '-' } }   # lanq-work turned into a link mid-run
  foreach ($p in @($script:Undetected)) { if ($rel -like $p) { return $false } }
  return $true
}
# the self-test folders: owner Administrators, admin-only, no link (a test cannot set that owner, so it is faked; NotOurs = tampered)
# every folder name the fix makes; SquatInside: the build user makes lanq-work\lanq-selftest-<name> first, for every
# name it could see (HIGH-2), which now cannot help it guess the next one (L-d)
function New-TestTag {
  $g = [Guid]::NewGuid().ToString('N'); $w = Join-Path (Get-DriveRoot 'C') 'lanq-work'
  if ($script:SquatInside -and $script:TagLog.Count -and [System.IO.Directory]::Exists($w)) { [void][System.IO.Directory]::CreateDirectory("$w\lanq-selftest-$($script:TagLog[$script:TagLog.Count - 1])") }   # names it saw
  if ($script:SquatCurrent -and [System.IO.Directory]::Exists($w)) { [void][System.IO.Directory]::CreateDirectory("$w\lanq-selftest-$g") }   # if it could guess
  [void]$script:TagLog.Add($g); return $g
}
function Test-SelfTestDir([string]$Path) { $rel = Get-Rel $Path; foreach ($p in @($script:NotOurs)) { if ($rel -like $p) { return $false } }; return [System.IO.Directory]::Exists($Path) }
function Get-BuildUser([string]$Name) { $u = $script:Users[$Name]; if ($u) { return $u.Clone() }; return @{ Given = $Name; Name = $Name; Found = $false; Sid = ''; Local = $false; Type = 0; Disabled = $false; Admin = $false } }
function New-Vol([string]$L, [hashtable]$Over = @{}) {
  $v = @{ Known = $true; Letter = $L; Fixed = $true; Fs = 'NTFS'; Bus = 'NVMe'; Guid = '{11111111-2222-3333-4444-555555555555}'; DevDrv = 'no'; DevAv = '-'; DevFilter = $false; FreeGB = 300; CaseSens = $false; RootSddl = $RootDefault }
  foreach ($k in $Over.Keys) { $v[$k] = $Over[$k] }; return $v
}
function Get-VolumeFacts([string]$L) { $v = $script:Vols[$L]; if ($v) { return $v.Clone() }; return @{ Known = $false; Letter = $L } }
function Get-WorkDirFacts([string]$Path) {
  $o = $script:WdOver[(Get-Rel $Path)]; if ($o) { return $o.Clone() }
  if (-not [System.IO.Directory]::Exists($Path)) { return @{ Exists = $false; Reparse = $false; Sddl = ''; Fresh = $false; Pin = $false; FileId = '-' } }
  $sd = $WorkDirSddl -f $script:WdSid; if ($script:SddlAfterCreate) { $sd = $script:SddlAfterCreate }
  $fresh = ((@([System.IO.Directory]::GetFileSystemEntries($Path) | ForEach-Object { Split-Path -Leaf $_ }) -join ',') -ceq '.lanq-pin'); if ($script:NotEmptyAfterCreate) { $fresh = $false }
  return @{ Exists = $true; Reparse = $false; Sddl = $sd; Fresh = $fresh; Pin = (Test-SelfTestDir (Join-Path $Path '.lanq-pin')); FileId = $script:FileIds[(Get-Rel $Path)] }
}
function Get-DevVhdFacts { return $script:Vhd.Clone() }
function Get-DiskImage { param($ImagePath, $ErrorAction) Note-Call 'Get-DiskImage'; return [pscustomobject]@{ Number = 7; Attached = $true } }
function Initialize-Disk { param($Number, $PartitionStyle, $ErrorAction) Note-Call "Initialize-Disk $Number $PartitionStyle" }
function New-Partition { param($DiskNumber, [switch]$UseMaximumSize, [switch]$AssignDriveLetter, $ErrorAction) Note-Call "New-Partition $DiskNumber"; $script:Vhd.Letter = 'L'; return [pscustomobject]@{ DriveLetter = [char]'L' } }
function Format-Volume {
  param($DriveLetter, [switch]$DevDrive, $NewFileSystemLabel, $Confirm, [switch]$Force, $ErrorAction)
  Note-Call "Format-Volume $DriveLetter DevDrive=$([bool]$DevDrive) $NewFileSystemLabel"
  $script:Vols["$DriveLetter"] = New-Vol "$DriveLetter" @{ Fs = 'ReFS'; Guid = '{99999999-2222-3333-4444-555555555555}'; DevDrv = $script:FormatDev; DevAv = $script:FormatAv; DevFilter = $true }
  [void][System.IO.Directory]::CreateDirectory((Get-DriveRoot "$DriveLetter"))
  if ($script:SquatDevWork) { [void][System.IO.Directory]::CreateDirectory((Join-Path (Get-DriveRoot "$DriveLetter") 'lanq-work')) }   # someone was quicker on the new volume (L-b)
}
function Invoke-Native([string]$Exe, [string[]]$ArgList, [int]$Sec = 60, [string]$StdinText = '') {
  $leaf = Split-Path -Leaf $Exe; $a = @($ArgList)
  if ($leaf -eq 'diskpart.exe') {
    Note-Call ("diskpart.exe " + (($StdinText.Trim() -split "`r?`n") -join '|'))
    if ($StdinText -match 'create vdisk') { $script:Vhd.Exists = $true; $script:Vhd.Attached = $true }
    return @{ Code = $script:DiskpartCode; Out = '' }
  }
  Note-Call "$leaf $($a -join ' ')"
  return @{ Code = 0; Out = '' }
}
$unsafe = @(foreach ($n in 'New-FixSecuredDir', 'Test-SelfTestDir', 'New-TestTag', 'Add-MpPreference', 'Remove-MpPreference', 'Wait-MpDetection', 'Get-EicarBytes', 'Get-DriveRoot', 'Get-SystemDriveLetter', 'Invoke-Native', 'Initialize-Disk', 'New-Partition', 'Format-Volume', 'Get-DiskImage',
    'Get-BuildUser', 'Get-VolumeFacts', 'Get-WorkDirFacts', 'Get-DevVhdFacts', 'Get-MpPreference', 'Get-MpComputerStatus', 'Test-FixRecordTrusted', 'Initialize-FixRecordDir', 'New-FixSecuredFile', 'Get-FixRecordDir') {
    if (@(Get-Command $n)[0].CommandType -ne 'Function' -or @(Get-Command $n)[0].ScriptBlock.File -eq $fixPath) { $n } })
if ($unsafe.Count -gt 0 -or -not (Get-DriveRoot 'C').StartsWith([IO.Path]::GetTempPath()) -or -not $DevVhdFile.StartsWith($Sandbox) -or "$(Get-EicarBytes)" -match 'EICAR') { Write-Host "ABORT: not faked: $($unsafe -join ', ')" -ForegroundColor Red; exit 1 }
Assert-True $true 'defender: every command that could change Defender, a disk or a folder outside the sandbox is a fake'

function Reset-Dx {
  Reset-Tune; Set-TuneQuiet
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber' 'String' '26100'; Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'UBR' 'DWord' 4000
  $script:Users = @{ builder = @{ Given = 'builder'; Name = 'PC\builder'; Found = $true; Sid = $Bu; Local = $true; Type = 1; Disabled = $false; Admin = $false } }
  $script:Vols = @{ C = (New-Vol 'C') }; $script:WdOver = @{}; $script:WdSid = $Bu; $script:SddlAfterCreate = ''; $script:NotEmptyAfterCreate = $false
  $script:FileIds = @{ 'C\lanq-work' = '0x000000000000000000010000000ed741'; 'L\lanq-work' = '0x0000000000000000000a000000000005' }
  $script:Undetected = @('C\lanq-work\lanq-selftest-*'); $script:Vhd = @{ Exists = $false; Attached = $false; Letter = '' }; $script:FormatDev = 'trusted'; $script:FormatAv = 'ok'; $script:DiskpartCode = 0
  $script:FixMade = ''; $script:AddVariant = $null; $script:ThrowAt = ''; $script:SquatWork = $false; $script:SquatDevWork = $false; $script:SquatCurrent = $false; $script:TagLog = New-Object System.Collections.ArrayList; $script:JunctionAfterPc = $false; $script:MpReadBroken = $false; $script:SquatInside = $false; $script:NotOurs = @(); $script:RemoveBroken = $false
  $script:ExclusionSettleSec = 0   # one attempt for the inside test unless a test sets it
  foreach ($d in @(Get-ChildItem -LiteralPath $Sandbox -Force -ErrorAction SilentlyContinue)) { [System.IO.Directory]::Delete('\\?\' + $d.FullName, $true) }
  [void][System.IO.Directory]::CreateDirectory((Get-DriveRoot 'C'))   # the drive root always exists
}
function Invoke-Dx([string]$Mode = 'apply', [object[]]$Ans = @(), [string]$Set = 'defender', [string]$User = 'builder', [int]$Size = 100, [string]$UndoPath = '') {
  $FixOut.Clear(); $Calls.Clear(); $Snaps.Clear(); $Reads.Clear(); $script:Asked = 0
  foreach ($x in $Ans) { $script:Answers.Enqueue($x) }
  $rc = Invoke-FixMain -Mode $Mode -UndoPath $UndoPath -FromFile $true -Set $Set -BuildUser $User -SizeGB $Size
  $script:Answers.Clear()
  return , $rc
}
function Get-SandboxDirs([string]$L) { return @(Get-ChildItem -LiteralPath (Get-DriveRoot $L) -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object) }
function Add-MpPreference { param($ExclusionPath, $ErrorAction) Note-Call "Add-MpPreference $ExclusionPath"; if ($script:OnAddHook) { $script:MpReadBrokenNext = $true }; if ($null -ne $script:AddVariant) { foreach ($v in @($script:AddVariant)) { [void]$Mp.Ex.Add($v) } } else { [void]$Mp.Ex.Add($ExclusionPath) } }
$MatrixCalls = 'detect C\lanq-selftest-<id>\eicar-<id>.com|Add-MpPreference C:\lanq-work\|detect C\lanq-work\lanq-selftest-<id>\eicar-<id>-1.com|detect C\lanq-work-<id>\eicar-<id>.com (history)|detect C\lanq-work<id>\eicar-<id>.com (history)|detect C\lanq-work.<id>\eicar-<id>.com (history)|detect C\lanq-work.\eicar-<id>.com (history)|detect C\lanq-work \eicar-<id>.com (history)|detect C\lanq-work-<id>-ads\host-<id>.txt:eicar-<id> (history)'

Reset-Dx; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-Equal $rc 0 'C2: defender.exclude apply: exit 0'
Assert-Equal ($Calls -join '|') $MatrixCalls 'C2/E9: positive control first, then the exclusion, then the matrix: excluded folder and every sibling form'
Assert-True ($Snaps.Count -gt 0 -and $Snaps[0] -match '"id": "defender.exclude", "status": "pending"' -and $Snaps[0] -notmatch '"after": "unknown"') 'C2: the record is written (pending, with the expected after state) before the first change'
$rp = Get-LatestRecord; $j = Read-Rec $rp
Assert-True (@($j.items).Count -eq 1 -and $j.items[0].status -eq 'applied' -and $j.items[0].after -cmatch '^entry=1 dir=lanq path=C:\\lanq-work\\ user=S-1-5-21-1111-2222-3333-1005 vol=\{11111111-2222-3333-4444-555555555555\} fileid=0x000000000000000000010000000ed741 sd=[0-9a-f]{64}$') 'C2: record: applied, with the volume, file id and permissions hash'
Assert-Equal (Read-FixRecord $rp).Error '' 'C2: the record is valid for -Undo'
Assert-True (@($Mp.Ex) -ccontains 'C:\lanq-work\' -and @($Mp.Ex).Count -eq 1) 'C2: exactly one exclusion: C:\lanq-work\'
Assert-Equal ((Get-SandboxDirs 'C') -join ',') 'lanq-work' 'M5: every self-test folder is cleaned up; only lanq-work stays'
Assert-Equal (@(Get-ChildItem -LiteralPath (Join-Path (Get-DriveRoot 'C') 'lanq-work') -Force | ForEach-Object { $_.Name }) -join ',') '.lanq-pin' 'M5/H-A: nothing is left in lanq-work but its permanent .lanq-pin'
Assert-True ((OutText) -match 'build user: PC\\builder \(S-1-5-21-1111-2222-3333-1005\)' -and (OutText) -match 'NUGET_PACKAGES=C:\\lanq-work\\.nuget\\packages' -and (OutText) -match 'never for the whole machine' -and (OutText) -match 'EICAR' -and (OutText) -match 'dedicated') 'B6/H1/H3/M5: shows the build user and SID, NUGET_PACKAGES per job, the EICAR note and the dedicated account'
Assert-True ((OutText) -match 'Type C:\\lanq-work to apply') 'the owner types the path to confirm'
$rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and (OutText) -match 'Nothing to fix') 'C3: run again: excluded, and the folder matches the trusted record: nothing to do'
$rc = Invoke-Dx 'undo' @('y') 'base' '' 100 $rp
Assert-True ($rc -eq 0 -and ($Calls -join '|') -eq 'Remove-MpPreference C:\lanq-work\' -and @($Mp.Ex).Count -eq 0 -and (Read-Rec $rp).items[0].status -eq 'undone') 'C2: undo removes only that exclusion'
Assert-True ([System.IO.Directory]::Exists((Join-Path (Get-DriveRoot 'C') 'lanq-work')) -and (OutText) -match 'never deletes') 'C2: undo keeps the folder (never deleted)'
$rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and ($Calls -join '|') -eq $MatrixCalls -and @($Mp.Ex) -ccontains 'C:\lanq-work\') 'C3: after undo the existing folder is used again: a trusted record matches its volume, file id and permissions'
$script:FileIds['C\lanq-work'] = '0x000000000000000000010000000eeeee'; $Mp.Ex.Clear()
$rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'not offered: .*lanq-work exists and was not made by this script.*no trusted fix record matches' -and (OutText) -match 'takeown') 'C3/M1: another folder with the same name (another file id): not offered, with the takeown and rename advice'
$script:FileIds['C\lanq-work'] = '0x000000000000000000010000000ed741'; $script:Trust = 'the record: it is owned by S-1-5-21-1-2-3-1001'
$rc = Invoke-Dx 'apply' @('C:\lanq-work'); $script:Trust = ''
Assert-True ($Calls.Count -eq 0 -and (OutText) -match 'no trusted fix record') 'C3/M1: a record others could have written vouches for nothing'

Write-Host 'defender.exclude: not offered (exit 0, nothing asked or changed)'
$notOffered = [ordered]@{
  'A3: not a fixed drive'               = @({ $script:Vols.C.Fixed = $false }, 'not a fixed')
  'A3: a USB disk'                      = @({ $script:Vols.C.Bus = 'USB' }, 'USB')
  'A3/M2: a virtual disk file (VHD)'    = @({ $script:Vols.C.Bus = 'File Backed Virtual' }, 'File Backed Virtual')
  'A3: an SD card'                      = @({ $script:Vols.C.Bus = 'SD' }, 'SD')
  'A3: not NTFS'                        = @({ $script:Vols.C.Fs = 'FAT32' }, 'NTFS')
  'M2: a Dev Drive needs no exclusion'  = @({ $script:Vols.C.DevDrv = 'trusted' }, 'Dev Drive')
  'A3: volume unreadable'               = @({ $script:Vols.C = @{ Known = $false; Letter = 'C' } }, 'could not be read')
  'A4: lanq-work is a junction'         = @({ $script:WdOver['C\lanq-work'] = @{ Exists = $true; Reparse = $true; Sddl = ''; Empty = $true; FileId = '-' } }, 'link or junction')
  'A5: squatted (owned by a user)'      = @({ $script:WdOver['C\lanq-work'] = @{ Exists = $true; Reparse = $false; Sddl = "O:$($Bu)G:SYD:PAI(A;OICI;FA;;;WD)"; Empty = $true; FileId = '0x1' } }, 'was not made by this script.*takeown')
  'A6: our permissions, but no record'  = @({ $script:WdOver['C\lanq-work'] = @{ Exists = $true; Reparse = $false; Sddl = ($WorkDirSddl -f $Bu); Empty = $true; FileId = '0x2' } }, 'no trusted fix record')
  'A7: DisableLocalAdminMerge'          = @({ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableLocalAdminMerge' 'DWord' 1 }, 'DisableLocalAdminMerge')
  'A7: exclusions set by group policy'  = @({ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions\Paths' 'D:\x' 'String' '0' }, 'group policy')
  'A7: exclusions set by MDM'           = @({ Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender' 'ExcludedPaths' 'String' 'D:\x' }, 'MDM')
  'A8: Defender for Endpoint onboarded' = @({ Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' 'OnboardingState' 'DWord' 1 }, 'Defender for Endpoint')
  'A8: Sense running'                   = @({ Add-Svc 'Sense' 2 0 'Windows Defender Advanced Threat Protection Service' 'Running' }, 'Defender for Endpoint')
  'A9: passive mode'                    = @({ $Mp.Mode = 'Passive Mode' }, 'Passive Mode')
  'A9: real-time protection off'        = @({ $Mp.Rtp = $false }, 'real-time protection is off')
  'A9: scans only incoming files'       = @({ $Mp.Rtsd = 1 }, 'RealTimeScanDirection')
  'A9: exclusions hidden from admins'   = @({ $Mp.Readable = $false }, 'hidden')
  'A10: C:\ is already excluded'        = @({ [void]$Mp.Ex.Add('C:\') }, 'already covers .*never recorded or undone')
  'H4: a variant without the backslash' = @({ [void]$Mp.Ex.Add('C:\lanq-work') }, 'not exactly C:\\lanq-work\\')
  'L4: a variable we cannot resolve'    = @({ [void]$Mp.Ex.Add('%BUILDROOT%\lanq-work') }, 'variable or wildcard')
  'C3: excluded, but no record'         = @({ [void]$Mp.Ex.Add('C:\lanq-work\') }, 'this script did not add it.*Remove-MpPreference')
  'B3: a drive root others may change'  = @({ $script:Vols.C.RootSddl = 'O:SYG:SYD:PAI(A;OICI;FA;;;BA)(A;;0x40;;;AU)' }, 'drive root')
  'B5: case-sensitive drive root'       = @({ $script:Vols.C.CaseSens = $true }, 'case-sensitive')
  'B5: ObCaseInsensitive is 0'          = @({ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'ObCaseInsensitive' 'DWord' 0 }, 'ObCaseInsensitive')
}
foreach ($k in $notOffered.Keys) {
  Reset-Dx; & $notOffered[$k][0]
  $before = Get-TuneWorld
  $rc = Invoke-Dx 'apply' @('C:\lanq-work')
  Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and $null -eq (Get-LatestRecord) -and (Get-TuneWorld) -eq $before -and (OutText) -match "defender\.exclude .*not offered: .*$($notOffered[$k][1])") "$k : not offered, says why, exit 0"
}
Reset-Dx; Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLinkedConnections' 'DWord' 1; $rc = Invoke-Dx 'dry'
Assert-True ($rc -eq 0 -and (OutText) -match 'WARNING: EnableLinkedConnections') 'L5: EnableLinkedConnections=1 is a warning, not a refusal'

Write-Host 'defender.exclude: the build user, consent, dry run'
Reset-Dx; $rc = Invoke-Dx 'apply' @('C:\lanq-work') 'defender' 'nobody'
Assert-True ($rc -eq 2 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and (OutText) -match "-BuildUser nobody: no account named 'nobody'" -and (OutText) -match 'Nothing was changed') 'B6: an unknown -BuildUser: exit 2 before anything is shown or asked'
Reset-Dx; $script:Users['grp'] = @{ Given = 'grp'; Name = 'grp'; Found = $true; Sid = 'S-1-5-32-545'; Local = $false; Type = 4; Disabled = $false; Admin = $false }; $rc = Invoke-Dx 'dry' @() 'defender' 'grp'
Assert-True ($rc -eq 2 -and (OutText) -match 'not a user account SID') 'B6: a group as -BuildUser: exit 2 (also in a dry run)'
Reset-Dx; $script:Users.builder.Admin = $true; $rc = Invoke-Dx 'dry'
Assert-True ($rc -eq 0 -and (OutText) -match 'WARNING: PC\\builder is an administrator') 'B6: an administrator as build user: a warning'
foreach ($ans in @('y', 'yes', 'Y', 'C:\lanq-work-x', 'D:\lanq-work', '', $null, 'C:\lanq')) {
  Reset-Dx; $rc = Invoke-Dx 'apply' @(, $ans)
  Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $null -eq (Get-LatestRecord) -and (OutText) -match 'not applied') "DefaultIsNo: '$ans' is not the path: nothing changed"
}
Reset-Dx; $rc = Invoke-Dx 'apply' @('c:\LANQ-WORK\')
Assert-True ($rc -eq 0 -and (Read-Rec (Get-LatestRecord)).items[0].status -eq 'applied') 'the typed path ignores case and a trailing backslash'
Reset-Dx; $script:Console = $false; $before = Get-TuneWorld; $rc = Invoke-Dx 'dry' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and $null -eq (Get-LatestRecord) -and (Get-TuneWorld) -eq $before -and (Get-SandboxDirs 'C').Count -eq 0) 'WhatIfChangesNothing: no folder, no exclusion, no record, nothing asked'
Assert-True ((OutText) -match ("command: New folder C:\\lanq-work, owner Administrators, permissions " + [regex]::Escape(($WorkDirSddl -f $Bu))) -and (OutText) -match "command: Add-MpPreference -ExclusionPath 'C:\\lanq-work\\'" -and (OutText) -match "undo: +Remove-MpPreference -ExclusionPath 'C:\\lanq-work\\'") 'WhatIf shows the folder, its permissions, the exact exclusion and the undo'
Reset-Dx; $script:Elev = $false; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and (OutText) -match 'needs an elevated PowerShell') 'not elevated: shown, skipped, nothing asked'
Reset-Dx; $script:OnAnswer = { [void]$Mp.Ex.Add('C:\') }; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($Calls.Count -eq 0 -and (OutText) -match 'not applied: .*already covers') 'EachFixRechecksPreconditionFirst: a broader exclusion added meanwhile: nothing done'

Write-Host 'defender.exclude: self-test and read-back failures roll back (exit 1)'
Reset-Dx; $script:Undetected = @('C\lanq-work\lanq-selftest-*', 'C\lanq-selftest-*'); $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and ($Calls -join '|') -eq 'detect C\lanq-selftest-<id>\eicar-<id>.com' -and @($Mp.Ex).Count -eq 0 -and (OutText) -match 'positive control') 'E9/M5: Defender misses the test file (positive control): no exclusion is added, exit 1'
Assert-True ((Read-Rec (Get-LatestRecord)).items[0].status -eq 'failed' -and (Read-Rec (Get-LatestRecord)).items[0].after -match '^entry=0 dir=lanq') 'E9: recorded as failed; the folder stays (made by this script)'
Assert-Equal ((Get-SandboxDirs 'C') -join ',') 'lanq-work' 'E9: the self-test folder is cleaned up after a failure too'
foreach ($sib in @('C\lanq-work-<id>\*', 'C\lanq-work<id>\*', 'C\lanq-work.<id>\*', 'C\lanq-work.\*', 'C\lanq-work \*', 'C\lanq-work-<id>-ads\*')) {
  Reset-Dx; $script:Undetected = @('C\lanq-work\lanq-selftest-*', $sib); $rc = Invoke-Dx 'apply' @('C:\lanq-work')
  Assert-True ($rc -eq 1 -and $Calls[$Calls.Count - 1] -eq 'Remove-MpPreference C:\lanq-work\' -and @($Mp.Ex).Count -eq 0 -and (OutText) -match 'reaches beyond lanq-work' -and ((Get-SandboxDirs 'C') -join ',') -eq 'lanq-work') "E9/H4: sibling $sib is not scanned: rolled back (Remove-MpPreference), exit 1, cleaned up"
}
Reset-Dx; $script:Undetected = @(); $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and $Calls -contains 'Remove-MpPreference C:\lanq-work\' -and @($Mp.Ex).Count -eq 0 -and (OutText) -match 'did not take effect') 'E9: the test file inside lanq-work is still detected (the exclusion does not work): rolled back, exit 1'
Reset-Dx; $script:AddVariant = @(); $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and @($Mp.Ex).Count -eq 0 -and (OutText) -match 'read back') 'C4/M4: the entry is not there afterwards (managed Tamper Protection drops it): exit 1'
Reset-Dx; $script:AddVariant = @('C:\lanq-work'); $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and @($Mp.Ex).Count -eq 0 -and (OutText) -match 'read back') 'C4/H4: Defender stored another form (no trailing backslash): that new entry is removed again, exit 1'
Reset-Dx; $script:AddVariant = @('C:\lanq-work\', 'C:\other\'); $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and @($Mp.Ex) -notcontains 'C:\lanq-work\' -and (OutText) -match 'read back') 'C4: two new entries: rolled back, exit 1'
Reset-Dx; $script:SddlAfterCreate = "O:$($Bu)G:SYD:PAI(A;OICI;FA;;;WD)"; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and $Calls.Count -eq 0 -and @($Mp.Ex).Count -eq 0 -and (OutText) -match 'not as this script makes it') 'B4/M1: the folder read back after creating it is not ours (a race): no exclusion, exit 1'
Reset-Dx; $script:NotEmptyAfterCreate = $true; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and $Calls.Count -eq 0 -and (OutText) -match 'not empty') 'B7/M1: a new folder that is not empty right after creating it: no exclusion, exit 1'
Reset-Dx; [void][System.IO.Directory]::CreateDirectory('\\?\' + (Get-DriveRoot 'C') + 'lanq-work.'); $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and @($Mp.Ex).Count -eq 0 -and (OutText) -match 'could not be put in place' -and (Get-SandboxDirs 'C') -contains 'lanq-work.') 'E9/H4/MEDIUM-1: a sibling form someone made already (lanq-work.): the move fails, fail closed, it is left alone'

Write-Host 'defender.exclude: review round 1 (HIGH-1, HIGH-2, MEDIUM-1, MEDIUM-2, the CI wait, LOWs)'
Reset-Dx; $script:ThrowAt = 'C\lanq-work.<id>\*'; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and $Calls -contains 'Remove-MpPreference C:\lanq-work\' -and @($Mp.Ex).Count -eq 0 -and (OutText) -match 'interrupted' -and ((Get-SandboxDirs 'C') -join ',') -eq 'lanq-work') 'HIGH-1: an error in the middle of the matrix still rolls the exclusion back and cleans up'
Assert-True ((Read-Rec (Get-LatestRecord)).items[0].after -match '^entry=0 ') 'HIGH-1: the failed record says the exclusion is not there'
$script:ThrowAt = ''; $rc = Invoke-Dx 'apply' @('C:\lanq-work'); Assert-True ($rc -eq 0 -and ($Calls -join '|') -eq $MatrixCalls) 'HIGH-1: after a rolled-back failure the next run offers it again (the folder is reused)'
Reset-Dx; $script:RemoveBroken = $true; $script:Undetected = @(); $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and @($Mp.Ex) -contains 'C:\lanq-work\' -and (OutText) -match 'FAILED to remove the exclusion' -and (OutText) -match "Remove-MpPreference -ExclusionPath 'C:\\lanq-work\\'") 'MEDIUM-2: the rollback is read back; a remove that did not work says FAILED with the command'
Assert-True ((Read-Rec (Get-LatestRecord)).items[0].status -eq 'failed' -and (Read-Rec (Get-LatestRecord)).items[0].after -match '^entry=1 ') 'MEDIUM-2: the failed record says the exclusion is still there'
$script:RemoveBroken = $false; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'not offered: .*this script did not add it') 'HIGH-1: a failed record with the exclusion still there does not count as done: not offered, says to remove it'
Reset-Dx; $script:NotOurs = @('C\lanq-work.<id>'); $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and @($Mp.Ex).Count -eq 0 -and (OutText) -match 'is not the folder this script made' -and (OutText) -match 'left alone' -and @(Get-SandboxDirs 'C' | Where-Object { $_ -match '^lanq-work\.[0-9a-f]{32}$' }).Count -eq 1) 'HIGH-2: a self-test folder that is not ours before the write: nothing written, never deleted, rolled back'
Reset-Dx; $script:ExclusionSettleSec = 30; $script:Undetected = @('C\lanq-work\lanq-selftest-*-2.com'); $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and ($Calls -join '|') -match ([regex]::Escape('eicar-<id>-1.com|detect C\lanq-work\lanq-selftest-<id>\eicar-<id>-2.com|'))) 'CI: the exclusion takes a moment to apply: the inside test is tried again (up to 30 s) before it fails'
Reset-Dx; $RecDirSaved = $RecDir; $RecDir = 'Q:\lanq-none\rec'; $rc = Invoke-Dx 'dry'; $RecDir = $RecDirSaved
Assert-True ($rc -eq 0 -and (OutText) -match 'not offered: .*not on the drive') 'HIGH-2: %ProgramData% on another drive than lanq-work (the folders could not be moved into place): not offered'
Reset-Dx; $Mp.Rtsd = $null; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'not offered: .*RealTimeScanDirection') 'LOW: RealTimeScanDirection unreadable: not offered (fail closed)'
Assert-True ((Get-CaseSens 'Case sensitive attribute on directory C:\ is disabled.') -eq $false -and (Get-CaseSens 'Case sensitive attribute on directory C:\ is enabled.') -eq $true -and $null -eq (Get-CaseSens 'Das Attribut ist deaktiviert.') -and $null -eq (Get-CaseSens '')) 'LOW: case sensitivity: disabled, enabled, or unknown (any other language: fail closed)'
$stp = Join-Path ([IO.Path]::GetTempPath()) ('lanq-st-' + [Guid]::NewGuid().ToString('N')); [void][System.IO.Directory]::CreateDirectory($stp)
Assert-True (-not (& $RealSelfTest $stp) -and -not (& $RealSelfTest (Join-Path $stp 'none'))) 'HIGH-2: the real Test-SelfTestDir refuses a folder this account owns, and a missing one'
[System.IO.Directory]::Delete($stp, $true)

Write-Host 'defender.exclude: review round 2 (H-A .lanq-pin, L-1, L-2, L-3)'
Reset-Dx; $script:SquatWork = $true; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and $Calls.Count -eq 0 -and @($Mp.Ex).Count -eq 0 -and (OutText) -match 'could not be put in place') 'H-A: lanq-work is made with its .lanq-pin in the record folder and moved into place: a C:\lanq-work someone made first fails closed'
Reset-Dx; $script:JunctionAfterPc = $true; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and @($Mp.Ex).Count -eq 0 -and (OutText) -match 'lanq-work changed' -and @($Calls | Where-Object { $_ -like 'detect C\lanq-work\*' }).Count -eq 0) 'H-A: lanq-work became a link (or another folder) before the inside test: nothing is moved, written or deleted there, rolled back'
Reset-Dx; $rc = Invoke-Dx 'apply' @('C:\lanq-work'); $rp = Get-LatestRecord; $rc = Invoke-Dx 'undo' @('y') 'base' '' 100 $rp
Assert-True ([System.IO.Directory]::Exists((Join-Path (Get-DriveRoot 'C') 'lanq-work\.lanq-pin'))) 'H-A: undo keeps lanq-work and its .lanq-pin'
[System.IO.Directory]::Delete((Join-Path (Get-DriveRoot 'C') 'lanq-work\.lanq-pin')); $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'not offered: .*\.lanq-pin') 'H-A: a reused lanq-work without its .lanq-pin is not used (it could be emptied and made a link)'
[void][System.IO.Directory]::CreateDirectory((Join-Path (Get-DriveRoot 'C') 'lanq-work\.lanq-pin')); $script:NotOurs = @('C\lanq-work\.lanq-pin'); $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'not offered: .*\.lanq-pin') 'H-A: a .lanq-pin that is not the admin-only one this script made: not used'
$script:NotOurs = @(); $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and ($Calls -join '|') -eq $MatrixCalls) 'H-A: with its .lanq-pin back the folder is used again'
$fx3 = [System.IO.File]::ReadAllText($fixPath)
Assert-True ($fx3 -match '(?s)New-FixSecuredDir \$stage \$AdminOnlySddl; New-FixSecuredDir "\$stage\\\$PinName" \$AdminOnlySddl.{0,800}SetAccessControl') 'L-3 (round 4): lanq-work is staged admin-only, gets its pin, and only then its own permissions'
Assert-True (Test-MpResource @('file:_C:\a\eicar-1.com') 'C:\a\eicar-1.com') 'L-1: a threat-history resource that is exactly file:_<path> counts'
foreach ($r in @('file:_C:\a\eicar-1.com->x.zip', 'file:_C:\x\C:\a\eicar-1.com', 'containerfile:_C:\a\eicar-1.com', 'file:_C:\a\eicar-1.com.zip', 'C:\a\eicar-1.com')) {
  Assert-True (-not (Test-MpResource @($r) 'C:\a\eicar-1.com')) "L-1: a resource that only contains the path does not count: $r"
}
Reset-Dx; $script:MpReadBroken = $true; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and @($Calls | Where-Object { $_ -like 'Add-MpPreference*' }).Count -eq 0 -and (OutText) -match 'not offered: Defender could not be read') 'L-2: the exclusions cannot be read: not offered, nothing is added'
Reset-Dx; $script:Undetected = @(); $script:OnAddHook = $true; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and (OutText) -match 'FAILED to remove the exclusion' -and (OutText) -match 'could not be read' -and (OutText) -match "Remove-MpPreference -ExclusionPath 'C:\\lanq-work\\'") 'L-2: the read-back after the rollback fails: loud FAILED with the command, never "removed again"'
$script:OnAddHook = $false; $script:MpReadBroken = $false
Reset-Dx; $rc = Invoke-Dx 'apply' @('C:\lanq-work'); $Mp.Ex.Clear()
$script:RemoveBroken = $true; $script:Undetected = @(); $rc = Invoke-Dx 'apply' @('C:\lanq-work'); $script:RemoveBroken = $false; $script:Undetected = @('C\lanq-work\lanq-selftest-*')
$rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'not offered: .*this script did not add it') 'L-3: an older applied record does not vouch once a newer failed run left the exclusion behind (only the newest item counts)'

Write-Host 'review round 3 (L-d, L-b)'
Reset-Dx; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and @($script:TagLog | Sort-Object -Unique).Count -eq 7) 'L-d: the run tag and every self-test folder name are separate random names (a watcher cannot guess the next folder from one it sees)'
Reset-Dx; $script:SquatInside = $true; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 0 -and ($Calls -join '|') -eq $MatrixCalls) 'L-d: folders made from names the build user saw do not get in the way of the next ones'
Reset-Dx; $script:SquatDevWork = $true; $rc = Invoke-Dx 'apply' @($DevVhdFile) 'devdrive'
Assert-True ($rc -eq 1 -and (OutText) -match 'could not be put in place' -and @(Get-SandboxDirs 'L' | Where-Object { $_ -like '.lanq-stage-*' }).Count -eq 0) 'L-b: L:\lanq-work made by someone else first: the Dev Drive run fails and removes its staging holder'

Reset-Dx; $script:SquatCurrent = $true; $rc = Invoke-Dx 'apply' @('C:\lanq-work')
Assert-True ($rc -eq 1 -and @($Mp.Ex).Count -eq 0 -and (OutText) -match 'could not be put in place' -and @(Get-ChildItem -LiteralPath (Join-Path (Get-DriveRoot 'C') 'lanq-work') -Force).Count -ge 2) 'HIGH-2: a self-test folder name made first (here: guessed) makes the move fail: nothing is written into it or deleted from it, rolled back'

Write-Host 'devdrive.create'
$DevCalls = "diskpart.exe create vdisk file=`"$DevVhdFile`" maximum=102400 type=expandable|attach vdisk|exit|Get-DiskImage|Initialize-Disk 7 GPT|New-Partition 7|Format-Volume L DevDrive=True lanq-dev"
Reset-Dx; $rc = Invoke-Dx 'apply' @($DevVhdFile) 'devdrive'
Assert-Equal $rc 0 'D4: devdrive.create apply: exit 0'
Assert-Equal ($Calls -join '|') $DevCalls 'D4: diskpart (fixed input), then Initialize-Disk, New-Partition and Format-Volume -DevDrive; no exclusion, no test file'
Assert-True ([System.IO.Directory]::Exists((Join-Path (Get-DriveRoot 'L') 'lanq-work')) -and [System.IO.Directory]::Exists($DevVhdDir)) 'D4: L:\lanq-work is created on the Dev Drive; the VHDX folder in ProgramData'
$rp = Get-LatestRecord; $j = Read-Rec $rp
Assert-True ($j.items[0].id -eq 'devdrive.create' -and $j.items[0].status -eq 'applied' -and $j.items[0].after -ceq "vhd=attached letter=L size=100 user=$Bu dir=lanq" -and $Snaps[0] -match '"status": "pending"') 'D4: recorded: pending before, applied after'
Assert-True ((OutText) -match 'work_root' -and (OutText) -match 'restart') 'D4/G1: says to point work_root at it and to check it after a restart'
$rc = Invoke-Dx 'undo' @('y') 'base' '' 100 $rp
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'left alone: a Dev Drive is never removed by this script' -and (Read-Rec $rp).items[0].status -eq 'applied') 'D6: undo leaves the Dev Drive alone and says how to remove it'
$rc = Invoke-Dx 'apply' @($DevVhdFile) 'devdrive'
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'Nothing to fix') 'D4: run again: the Dev Drive is there: nothing to do'
Reset-Dx; $rc = Invoke-Dx 'apply' @($DevVhdFile) 'devdrive' 'builder' 64
Assert-True ($rc -eq 0 -and $Calls[0] -match 'maximum=65536 ') 'D2: -SizeGB 64 makes a 64 GB VHDX'
foreach ($c in @(@({ Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber' 'String' '22000' }, 'needs Windows 11 22H2', 'D1: build 22000'),
    @({ Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber' 'String' '22621'; Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'UBR' 'DWord' 2000 }, '22621.2338', 'D1: build 22621.2000'),
    @({ $script:Vhd.Exists = $true }, 'exists', 'D3: the VHDX exists (not attached)'), @({ $script:Vols.C.FreeGB = 80 }, 'only 80 GB are free', 'D3: not enough free space'),
    @({ $script:Vols.C = @{ Known = $false; Letter = 'C' } }, 'could not be read', 'D3: system drive unreadable'))) {
  Reset-Dx; & $c[0]; $rc = Invoke-Dx 'apply' @($DevVhdFile) 'devdrive'
  Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and (OutText) -match "devdrive\.create .*not offered: .*$($c[1])") "$($c[2]): not offered, exit 0"
}
Reset-Dx; Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber' 'String' '22621'; Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'UBR' 'DWord' 2338; $rc = Invoke-Dx 'dry' @() 'devdrive'
Assert-True ($rc -eq 0 -and (OutText) -match '(?m)^devdrive\.create' -and (OutText) -notmatch 'not offered') 'D1: build 22621.2338 is offered'
Reset-Dx; $script:FormatDev = 'untrusted'; $rc = Invoke-Dx 'apply' @($DevVhdFile) 'devdrive'
Assert-True ($rc -eq 1 -and (Read-Rec (Get-LatestRecord)).items[0].status -eq 'failed' -and (OutText) -match 'not a trusted Dev Drive') 'D5: the new volume is not a trusted Dev Drive: exit 1'
Reset-Dx; $script:FormatAv = 'disallowed'; $rc = Invoke-Dx 'apply' @($DevVhdFile) 'devdrive'
Assert-True ($rc -eq 1 -and -not [System.IO.Directory]::Exists((Join-Path (Get-DriveRoot 'L') 'lanq-work'))) 'D5: antivirus disallowed on the new Dev Drive: exit 1, no lanq-work'
Reset-Dx; $script:DiskpartCode = 1; $rc = Invoke-Dx 'apply' @($DevVhdFile) 'devdrive'
Assert-True ($rc -eq 1 -and $Calls.Count -eq 1) 'D4: diskpart fails: nothing more is run, exit 1'
foreach ($ans in @('y', 'C:\lanq-work', '')) { Reset-Dx; $rc = Invoke-Dx 'apply' @(, $ans) 'devdrive'; Assert-True ($Calls.Count -eq 0 -and $null -eq (Get-LatestRecord)) "D4: DefaultIsNo for the Dev Drive: '$ans'" }
Reset-Dx; $script:Console = $false; $rc = Invoke-Dx 'dry' @() 'devdrive'
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'Format-Volume' -and (OutText) -match 'never removed' -and -not (Test-Path -LiteralPath $DevVhdDir)) 'D4: WhatIf shows the steps and the undo note; creates nothing'
Reset-Dx; [System.IO.Directory]::Delete('\\?\' + $Sandbox, $true)

Write-Host 'defender: guard and record checks (G2, A2)'
$asts = [System.Management.Automation.Language.Parser]::ParseFile($fixPath, [ref]$null, [ref]$null)
$adds = @($asts.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-MpPreference' }, $true))
Assert-True ($adds.Count -eq 1 -and $adds[0].Extent.Text -match '^Add-MpPreference -ExclusionPath \$entry -ErrorAction Stop$') 'A2: one Add-MpPreference, with $entry only'
$entryAs = @($asts.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$entry' }, $true))
Assert-True ($entryAs.Count -ge 1 -and @($entryAs | Where-Object { $_.Right.Extent.Text -cne 'Get-LanqWorkEntry $B.Drive' }).Count -eq 0) 'A2: $entry is only ever Get-LanqWorkEntry of the recorded drive letter'
Assert-True (@($asts.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type' }, $true)).Count -eq 0 -and $fixText -notmatch 'DllImport') 'H2: no Add-Type and no P/Invoke in the fix script'
$sch2 = [System.IO.File]::ReadAllText((Join-Path $root 'schema/fix-record.v1.json')) | ConvertFrom-Json
Assert-True ("entry=1 dir=lanq path=C:\lanq-work\ user=$Bu vol={11111111-2222-3333-4444-555555555555} fileid=0x1 sd=$('a' * 64)" -cmatch $sch2.'$defs'.stateShapes.properties.'windows:defender.exclude'.pattern) 'schema: the defender.exclude shape'
Assert-True ("vhd=attached letter=L size=100 user=$Bu dir=lanq" -cmatch $sch2.'$defs'.stateShapes.properties.'windows:devdrive.create'.pattern) 'schema: the devdrive.create shape'
Assert-True ('entry=1 dir=lanq path=C:\Windows\ user=- vol=- fileid=- sd=-' -cnotmatch $sch2.'$defs'.stateShapes.properties.'windows:defender.exclude'.pattern) 'schema: another path is not a defender.exclude shape'

Write-Host 'tune arguments'
Assert-Equal (Get-UndoArg @('-Hours', '22:00-07:00')).Hours '22:00-07:00' 'Get-UndoArg: -Hours value'
Assert-True ((Get-UndoArg @('-Hours')).Error -match '-Hours needs') 'Get-UndoArg: -Hours without a value'
Assert-Equal ((Get-UndoArg @('-WorkRoot', 'C:/lq')).Rest -join ' ') '-WorkRoot C:/lq' 'Get-UndoArg: -WorkRoot is not an argument any more'
foreach ($e in @(@(@{ Hours = '22:00-07:00' }, $false, 'apply', 'goes with -Tune'), @(@{ Hours = $null }, $true, 'undo', '-Undo and -List'), @(@{ Hours = '7-9' }, $true, 'apply', '-Hours must'))) {
  Assert-True ((Get-TuneArgError $e[0] $e[1] $e[2]) -match [regex]::Escape($e[3])) "tune arguments refused: $($e[3])"
}
Assert-Equal (Get-TuneArgError @{ Hours = '22:00-07:00' } $true 'dry') '' 'tune arguments accepted'

Write-Host 'curated vendor list'
# Every pattern shipped in a release (0.5.0). Append the next release's patterns here; each must stay in the current
# list or move to $VendorRetiredPatterns, so records written by that release can still be undone.
$ShippedPatterns = @(
  '^Dell ?SupportAssist', '^SupportAssist', '^Dell ?(Update|Command ?Update|Digital ?Delivery|Data ?Vault|TechHub|Optimizer|Core ?Services)', '^DDV(DataCollector|RulesProcessor|CollectorSvcApi)$',
  '^HP ?(Support ?Assistant|Support ?Solutions|Analytics|App ?Helper|Diagnostics|Insights|Touchpoint|System ?Info|Network ?Cap|Comm ?Recovery|JumpStart)', '^HP(AppHelperCap|DiagsCap|NetworkCap|SysInfoCap)$', '^HpTouchpointAnalyticsService$',
  '^Lenovo ?(Vantage|Service ?Bridge|Smart ?Standby|Utility|Welcome|System ?Update)', '^ImControllerService$', '^LITSSVC$',
  '^ASUS ?(Optimization|Software ?Manager|System ?Analysis|System ?Diagnosis|Link|Update|App ?Service)', '^ArmouryCrate', '^AsusUpdateCheck$',
  '^Acer ?(Quick ?Access|Care ?Center|Jumpstart|Collection|Product ?Registration)', '^MSI ?(Center|Dragon ?Center)', '^Samsung ?(Update|Settings)',
  '^Intel\(R\) ?(Driver ?(&|and) ?Support|Computing ?Improvement)', '^DSA(Update)?Service$', '^NvTelemetryContainer$', '^NVIDIA ?(GeForce ?Experience|Telemetry)'
)
foreach ($p in $ShippedPatterns) { Assert-True (@($VendorPatterns) + @($VendorRetiredPatterns) -ccontains $p) "shipped pattern '$p' is still in the list or the retired list" }
function Get-ListValues([string]$Path, [string]$Var) {
  $a = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
  $as = @($a.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $Var }, $true))
  if ($as.Count -ne 1) { return $null }
  return @($as[0].Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
}
$lf = Get-ListValues $fixPath '$VendorPatterns'; $lt = Get-ListValues (Join-Path $root 'lanq-makeready-tune.ps1') '$VendorPatterns'
Assert-True ($lf.Count -gt 10 -and ($lf -join "`n") -ceq ($lt -join "`n")) 'the vendor list in the fix script and the tune script are identical'
Assert-Equal (@(Get-ListValues $fixPath '$VendorRetiredPatterns') -join ',') '' 'the retired list starts empty (append-only from here)'
foreach ($p in $lf) {
  $ok = $true; try { [void][regex]::new($p) } catch { $ok = $false }
  Assert-True ($ok -and $p -notmatch '\.\*|\.\+|^\.|\|\||^\||\|$' -and $p -match '[A-Za-z]{4}') "vendor pattern '$p': a valid regex with a literal name, no bare wildcard"
}
$core = @('wuauserv', 'WinDefend', 'BITS', 'sshd', 'WSearch', 'SysMain', 'Dnscache', 'EventLog', 'Schedule', 'mpssvc', 'Spooler', 'UsoSvc', 'DoSvc', 'Windows Update', 'Microsoft Defender Antivirus Service',
  'OneDrive', 'MicrosoftEdgeUpdateTaskMachineCore', 'GoogleUpdateTaskMachineCore', 'SecurityHealth', 'Docker Desktop Service', 'docker', 'ssh-agent', 'Update', 'Service', 'Updater', 'Helper', 'Intel', 'NVIDIA Display Container LS', 'HP', 'Dell', 'Lenovo')
foreach ($n in $core) { Assert-True (-not (Test-Vendor $n)) "vendor list does not match '$n'" }
foreach ($n in 'SupportAssistAgent', 'Dell SupportAssist Remediation', 'HP Support Assistant Service', 'HpTouchpointAnalyticsService', 'ImControllerService', 'Lenovo Vantage Service', 'ArmouryCrateService', 'NvTelemetryContainer', 'DSAService') {
  Assert-True (Test-Vendor $n) "vendor list matches '$n'"
}

Write-Host 'ScannerUnchangedAndStillReadOnly'
$scanPs = [System.IO.File]::ReadAllText((Join-Path $root 'lanq-makeready.ps1')); $scanSh = [System.IO.File]::ReadAllText((Join-Path $root 'lanq-makeready.sh'))
Assert-True ($scanPs -notmatch 'region FIXES' -and $scanSh -notmatch 'region FIXES' -and $scanPs -notmatch 'lanq-makeready-fix' -and $scanSh -notmatch 'lanq-makeready-fix') 'scanners have no fix table and do not call the fix script'
Assert-True ($scanPs -match "\`$ToolVersion = '$([regex]::Escape($ToolVersion))'" -and $scanSh -match "TOOL_VERSION=$([regex]::Escape($ToolVersion))") 'scanner and fix script report the same version'
$a0 = $scanPs.IndexOf('#region ADVICE'); $a1 = $scanPs.IndexOf('#endregion ADVICE'); $noAdv = $scanPs.Substring(0, $a0) + $scanPs.Substring($a1)
foreach ($pat in 'Set-ItemProperty', 'Remove-ItemProperty', 'Set-Service', 'Start-Service', 'Stop-Service', 'Set-Acl', 'icacls', '/change', '/inheritance') {
  Assert-True ($noAdv -notmatch [regex]::Escape($pat)) "scanner (outside its advice table) has no $pat"
}
Assert-True ($scanPs -match "param\(\[string\]\`$Json, \[string\]\`$Out, \[switch\]\`$Redact, \[string\]\`$Hours, \[switch\]\`$Quiet," ) 'scanner parameters unchanged (no fix switch)'

Write-Host 'files'
foreach ($f in 'lanq-makeready.ps1', 'lanq-makeready.sh', 'lanq-makeready-fix.ps1', 'lanq-makeready-fix.sh', 'tests/run.ps1', 'tests/run.sh', 'tests/fix.ps1', 'tests/fix.sh', 'lanq-makeready-tune.ps1', 'tests/tune.ps1', 'tests/real-fix.ps1', 'tests/real-defender.ps1', 'tests/pool-defender.ps1') {
  $b = [System.IO.File]::ReadAllBytes((Join-Path $root $f))
  Assert-Equal @($b | Where-Object { ($_ -lt 32 -and $_ -ne 9 -and $_ -ne 10 -and $_ -ne 13) -or $_ -eq 127 }).Count 0 "$f has no control bytes (BEL, backspace, ...)"
}
$poolAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'tests/pool-defender.ps1'), [ref]$null, [ref]$perr)
$poolCmds = @($poolAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { "$($_.GetCommandName())" })
Assert-True (@($perr).Count -eq 0 -and @($poolCmds | Where-Object { $_ -match '^(net(\.exe)?|New-LocalUser|Remove-LocalUser|Add-MpPreference|Remove-MpPreference|Set-MpPreference|Add-Type)$' }).Count -eq 0) 'MEDIUM-3: the pool harness creates no users, removes or adds no exclusion itself, changes no Defender setting, no Add-Type'
$poolText = [System.IO.File]::ReadAllText((Join-Path $root 'tests/pool-defender.ps1'))
# M-2: the trust check runs before the fix script is dot-sourced (an elevated run must not load code others may change)
$dotAt = $poolText.IndexOf('. $fixPath'); $trustAt = $poolText.IndexOf('Test-PoolTrust (')
Assert-True ($dotAt -gt 0 -and $trustAt -gt 0 -and $trustAt -lt $dotAt) 'M-2: the pool harness checks its folder, its parents and both files before it dot-sources the fix script'
# M-1/L-c: the L2 junction lives in an admin-only folder of ours (staged and moved), and is tracked for clean-up
Assert-True ($poolText -match 'New-PoolDir \(.*pool-jp-' -and $poolText -match '\$script:Links' -and $poolText -notmatch 'mklink.*\$work\\pool-jn') 'M-1/L-c: the L2 junction is made inside an admin-only folder of ours and removed even on interrupt'
Assert-True ($poolText -match '\$why = Initialize-FixRecordDir' -and $poolText -notmatch '\[void\]\(Initialize-FixRecordDir\)') 'M-A (round 4): the pool harness makes the record folder and stops when it is not trusted (never discards the result)'
Assert-True ($poolText -match '(?s)finally \{.{0,200}Get-FixRecordDirProblem') 'M-A (round 4): the clean-up re-checks the record folder before it deletes anything'
Assert-True ($poolText -match '(?s)foreach \(\$l in @\(\$script:Links\)\).{0,300}Test-SelfTestDir.{0,200}Test-WorkDirSame') 'L-1 (round 4): the link is removed only while its folder and lanq-work are still ours'
$docT = [System.IO.File]::ReadAllText((Join-Path $root 'docs/TUNE.md'))
Assert-True ($docT -match 'SHA256SUMS' -and $docT -match 'gh attestation verify') 'L-2 (round 4): the procedure says to verify the release candidate before copying it'
Assert-True ($poolText -notmatch 'Test-WorkDirSame \$work \(Get-WorkDirFacts \$work\)\.FileId') 'L-e: the pool clean-up compares lanq-work with the file id it saw at the start, not the current one'
# M-3: the documented procedure (a copy under C:\ProgramData, icacls /inheritance:r with Administrators and SYSTEM) passes
$ptAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'tests/pool-defender.ps1'), [ref]$null, [ref]$null)
$ptFn = @($ptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-PoolTrust' }, $true))
Assert-Equal $ptFn.Count 1 'M-3: Test-PoolTrust is defined in the pool harness'
if ($ptFn.Count -eq 1) {
  . ([scriptblock]::Create($ptFn[0].Extent.Text))
  $docTune = [System.IO.File]::ReadAllText((Join-Path $root 'docs/TUNE.md'))
  Assert-True ($docTune -match [regex]::Escape("icacls C:\ProgramData\lanq-rc /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F")) 'M-3: docs/TUNE.md gives the icacls step for the copy'
  $okPairs = @(
    @('O:BAG:SYD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)', $false, 'the copy after the documented icacls'),
    @('O:BAG:SYD:PAI(A;OICIID;FA;;;BA)(A;OICIID;FA;;;SY)', $false, 'its tests folder (inherited)'),
    @('O:BAG:SYD:AI(A;ID;FA;;;BA)(A;ID;FA;;;SY)', $true, 'a file in it'),
    @('O:SYG:SYD:PAI(A;OICIIO;GA;;;CO)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)(A;CI;0x116;;;BU)', $false, 'the default C:\ProgramData'),
    @($RootDefault, $false, 'the default C:\'))
  foreach ($c in $okPairs) { Assert-Equal (Test-PoolTrust $c[0] $c[1]) '' "M-3: passes: $($c[2])" }
  $badPairs = @(
    @('O:S-1-5-21-1-2-3-1001G:SYD:PAI(A;OICI;FA;;;S-1-5-21-1-2-3-1001)(A;OICI;FA;;;BA)', $false, 'a user''s own checkout (owned by the user)'),
    @('O:SYG:SYD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)', $false, 'a C:\ProgramData that gives Everyone full control'),
    @('O:BAG:SYD:PAI(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;BU)', $false, 'a folder Users may modify (rename or replace files)'),
    @('O:BAG:SYD:AI(A;ID;FA;;;BA)(A;ID;0x1301bf;;;BU)', $true, 'a file Users may change'),
    @('O:BAG:SYD:AI(A;ID;FA;;;BA)(A;ID;0x2;;;AU)', $true, 'a file others may write'),
    @('O:BAG:SYD:PAI(A;OICI;FA;;;BA)(XA;;0x1;;;WD;(@User.x == "y"))', $false, 'a conditional entry'),
    @('', $true, 'unreadable'))
  foreach ($c in $badPairs) { Assert-True ((Test-PoolTrust $c[0] $c[1]) -ne '') "M-3: refused: $($c[2])" }
  $ppFn = @($ptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-PoolPath' }, $true))
  Assert-Equal $ppFn.Count 1 'L-4 (round 4): Test-PoolPath is defined in the pool harness'
  if ($ppFn.Count -eq 1) {
    . ([scriptblock]::Create($ppFn[0].Extent.Text))
    foreach ($x in '\\server\share\lanq-rc', '\\?\UNC\server\share\x', '//server/share/x', 'Z:x') { Assert-True ((Test-PoolPath $x) -ne '') "L-4: refused: $x" }
    foreach ($x in 'C:\ProgramData\lanq-rc', 'C:\ProgramData\lanq-rc\tests\pool-defender.ps1', 'C:\') { Assert-Equal (Test-PoolPath $x) '' "L-4: a local path passes: $x" }
  }
}
Assert-True ($poolText -match 'exactly one new record' -and $poolText -match 'INTERRUPTED' -and $poolText -match 'finally' -and $poolText -match 'Test-SelfTestDir' -and $poolText -match 'Test-WorkDirSame' -and $poolText -match 'Test-PoolTrust' -and $poolText -match 'Get-FixRecordDirProblem' -and $poolText -notmatch 'Sort-Object -Property LastWriteTimeUtc') 'M-A/M-B/L-6: the pool harness undoes only the one record its own apply wrote, is interrupt-safe, re-checks every folder, refuses a checkout others may change'
Assert-True ($poolText -notmatch 'DisableRealtimeMonitoring' -and $poolText -match 'OPEN QUESTION 1' -and $poolText -match 'OPEN QUESTION 2' -and $poolText -match 'GITHUB_ACTIONS') 'MEDIUM-3: the pool harness never touches real-time protection, reports both open questions, and refuses in CI'
$sch = [System.IO.File]::ReadAllText((Join-Path $root 'schema/fix-record.v1.json')) | ConvertFrom-Json
Assert-Equal $sch.properties.schema.const 'lanq-makeready-fix/v1' 'schema/fix-record.v1.json parses, schema id'
Assert-Equal ((@($sch.'$defs'.item.properties.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object) -join ',') 'after,before,command,id,seq,status,time' 'schema item fields = record item fields'
Assert-True (@($FixIds | Where-Object { @($sch.'$defs'.item.properties.id.enum) -notcontains $_ }).Count -eq 0) 'schema lists every Windows fix id'
Assert-True ('scheme=381b4222-f694-41f0-9685-ff5bb260df2e standby=60 hibernate=-' -cmatch $sch.'$defs'.stateShapes.properties.'windows:power.sleep'.pattern) 'schema: the power.sleep shape includes the scheme'
Assert-True ('value=0 type=dword' -cmatch $sch.'$defs'.stateShapes.properties.'windows:longpaths.on'.pattern -and 'value=- type=none' -cmatch $sch.'$defs'.stateShapes.properties.'windows:longpaths.on'.pattern) 'schema: the longpaths shape includes the value type'

Write-Host ("`nfix PowerShell tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
