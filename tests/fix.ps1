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
$okStates = @(@('ssh.start', 'starttype=Manual status=Stopped'), @('ssh.auto', 'starttype=Disabled status=Running'), @('power.sleep', 'standby=1800 hibernate=-'),
  @('power.sleep', 'standby=0 hibernate=3600'), @('longpaths.on', 'value=- type=none'), @('longpaths.on', 'value=0 type=dword'), @('git.longpaths', 'value=false'), @('git.longpaths', 'value=-'),
  @('ssh.aclkeys', 'dacl=D:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;BU)(A;;FA;;;S-1-5-21-1-2-3-1001)'))
foreach ($s in $okStates) { Assert-True ($null -ne (ConvertFrom-StateText $s[0] $s[1])) "state shape accepted: $($s[0]) $($s[1])" }
$badStates = @(@('ssh.start', 'starttype=Manual status=Stopped; Stop-Computer'), @('ssh.start', 'starttype=$(x) status=Stopped'), @('ssh.auto', 'starttype=Boot status=Running'),
  @('power.sleep', 'standby=99999999999 hibernate=0'), @('power.sleep', 'standby=-1 hibernate=0'), @('longpaths.on', 'value=1;x type=dword'), @('longpaths.on', 'value=0'),
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
$fd = (Format-Dacl 'D:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;BU)(A;;FA;;;S-1-5-21-1-2-3-1001)') -join "`n"
Assert-True ($fd -match 'allow NT AUTHORITY\\SYSTEM : FullControl \(inherited\)' -and $fd -match 'BUILTIN\\Users : ReadAndExecute' -and $fd -match 'S-1-5-21-1-2-3-1001 : FullControl') 'M1(c) DACL in words: names, rights, SID when unknown'
Assert-True ((Format-Dacl 'D:P(D;;FA;;;WD)(A;;FA;;;BA)') -join ' ' -match 'DENY') 'M1(c) deny entries are shown as DENY'

Write-Host 'M1(a) trusted record folder and files'
Assert-Equal (Test-TrustedSddl $RecordDirSddl) '' 'the folder this script makes is trusted'
Assert-Equal (Test-TrustedSddl $RecordFileSddl) '' 'the record files this script makes are trusted'
Assert-Equal (Test-TrustedSddl 'O:SYG:SYD:AI(A;ID;FA;;;BA)(A;ID;FA;;;SY)(A;ID;0x1200a9;;;BU)') '' 'others may read: still trusted'
foreach ($d in @(@('O:S-1-5-21-1-2-3-1001G:SYD:PAI(A;;FA;;;BA)', 'owned by S-1-5-21-1-2-3-1001'), @('O:BAG:SYD:AI(A;ID;FA;;;BA)(A;OICIIO;0x100116;;;BU)', 'S-1-5-32-545 may change it'),
    @('O:BAG:SYD:PAI(A;;FA;;;BA)(A;;FA;;;S-1-5-21-1-2-3-1001)', 'may change it'), @('O:BAG:SYD:NO_ACCESS_CONTROL', 'no DACL'), @('O:BAG:SYD:PAI(A;;0x40000;;;AU)', 'may change it'))) {
  Assert-True ((Test-TrustedSddl $d[0]) -match [regex]::Escape($d[1])) "not trusted: $($d[0])"
}
Assert-True ($RecordDirSddl -cmatch '^O:BA' -and $RecordDirSddl -cmatch 'D:PAI') 'the record folder is owned by Administrators and protected (no inheritance)'

Write-Host 'L5 key lines are shown before asking'
$ks = Get-AuthKeySummary @('# comment', '', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample build@build-01', 'command="x" ssh-rsa AAAAB3NzaC1yc2E= old-key', 'garbage')
Assert-Equal @($ks).Count 3 'three non-comment lines'
Assert-True ($ks[0] -match '^ssh-ed25519 SHA256:[A-Za-z0-9+/]{43} build@build-01$') 'type, SHA256 fingerprint and comment'
Assert-True ($ks[1] -match 'with options' -and $ks[2] -match 'cannot read') 'options and unreadable lines are flagged'

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
Assert-True (Test-FixOverSsh) 'sshd among the parents: over SSH'
$script:FakeProcs = @([pscustomobject]@{ Id = $PID; Parent = 50; Name = 'powershell.exe'; Created = $t0 }, [pscustomobject]@{ Id = 50; Parent = 4; Name = 'explorer.exe'; Created = $t0.AddMinutes(-1) })
Assert-True (-not (Test-FixOverSsh)) 'a desktop session: not over SSH'
$script:FakeProcs = $null; $script:FakeSession = 0
Assert-True (Test-FixOverSsh) 'process list unreadable (CIM failed or timed out) in session 0: refused, not passed'
$script:FakeSession = 1
Assert-True (-not (Test-FixOverSsh)) 'process list unreadable in a desktop session: not counted as SSH'
$script:FakeSession = 0
Assert-True (-not (Test-FixConsole)) 'session 0 is never an interactive console'
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
    'Select-Object', 'Where-Object', 'ForEach-Object', 'Sort-Object', 'ConvertFrom-Json', 'Write-Host', 'New-Object', 'Get-Location')
  $mut = @('Set-Service', 'Start-Service', 'Stop-Service', 'Set-ItemProperty', 'Remove-ItemProperty', 'Set-Acl')
  $callers = @{ 'Invoke-FixChange' = @('Invoke-FixApply', 'Invoke-FixUndo'); 'Assert-Native' = @('Invoke-FixChange'); 'Set-FixRecordAcl' = @('Initialize-FixRecordDir', 'Save-FixRecord') }
  $okNative = @("`$PowercfgExe|@('/q', 'SCHEME_CURRENT', 'SUB_SLEEP', 'STANDBYIDLE')", "`$PowercfgExe|@('/q', 'SCHEME_CURRENT', 'SUB_SLEEP', 'HIBERNATEIDLE')",
    "`$git|@('config', '--system', '--show-origin', '--get', 'core.longpaths')", "`$git|@('config', '--system', '--show-origin', '--list')", "`$git|@('config', '--get', 'core.longpaths')")
  $okTypes = @('System.Diagnostics.ProcessStartInfo', 'Security.Principal.WindowsPrincipal', 'System.Text.UTF8Encoding', 'System.Collections.ArrayList', 'System.IO.FileInfo',
    'System.Security.AccessControl.RawSecurityDescriptor')
  foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $n = $c.GetCommandName(); $in = & $inR $c; $fn = & $fnOf $c
    if (-not $n) { [void]$bad.Add("dynamic command: $($c.Extent.Text)"); continue }
    if ($mut -contains $n) {
      if (-not (($in -and $fn -eq 'Invoke-FixChange') -or ($n -eq 'Set-Acl' -and $fn -eq 'Set-FixRecordAcl'))) { [void]$bad.Add("mutating command $n outside Invoke-FixChange ('$fn')") }
      continue
    }
    if ($read -notcontains $n -and $funcNames -notcontains $n) { [void]$bad.Add("command $n is not on the allow-list") }
    if ($callers.ContainsKey($n) -and $callers[$n] -notcontains $fn) { [void]$bad.Add("$n called from '$fn'") }
    if ($n -eq 'Set-FixRecordAcl' -and @('$RecordDirSddl', '$RecordFileSddl') -notcontains $c.CommandElements[2].Extent.Text) { [void]$bad.Add("Set-FixRecordAcl with $($c.CommandElements[2].Extent.Text)") }
    if ($n -eq 'Invoke-Native' -and $fn -ne 'Invoke-Native') {
      $exe = $c.CommandElements[1].Extent.Text
      if ($in) { if ($fn -ne 'Invoke-FixChange' -or @('$PowercfgExe', '$IcaclsExe', '$Cur.Git') -notcontains $exe) { [void]$bad.Add("Invoke-Native in FIXES with $exe") } }
      else {
        $k = $exe + '|' + $(if ($c.CommandElements.Count -gt 2) { $c.CommandElements[2].Extent.Text } else { '' })
        if ($okNative -notcontains $k) { [void]$bad.Add("Invoke-Native outside FIXES with other than a read: $k") }
      }
    }
    if ($n -eq 'ForEach-Object' -and -not ($c.CommandElements.Count -gt 1 -and $c.CommandElements[1] -is [System.Management.Automation.Language.ScriptBlockExpressionAst])) { [void]$bad.Add("ForEach-Object without a script block: $($c.Extent.Text)") }
    if ($n -eq 'New-Object' -and $okTypes -notcontains $c.CommandElements[1].Extent.Text.Trim("'`"")) { [void]$bad.Add("New-Object $($c.CommandElements[1].Extent.Text)") }
  }
  $okMembers = @('Add', 'RemoveAt', 'Remove', 'Close', 'ReadToEndAsync', 'WaitForExit', 'Wait', 'Kill', 'Start', 'Trim', 'TrimEnd', 'Split', 'Replace', 'StartsWith', 'Substring',
    'ToString', 'GetSecurityDescriptorSddlForm', 'SetSecurityDescriptorSddlForm', 'GetOwner', 'Translate', 'IsInRole', 'GetCurrent', 'GetCurrentProcess', 'GetFolderPath', 'Matches',
    'ToInt64', 'Exists', 'ReadAllText', 'WriteAllText', 'Move', 'CreateDirectory', 'WriteLine', 'ReadLine', 'IsPathRooted', 'ContainsKey', 'Round', 'ToUniversalTime',
    'GetValueNames', 'GetValueKind', 'GetValue', 'Create', 'AddScript', 'BeginInvoke', 'WaitOne', 'BeginStop', 'EndInvoke', 'Dispose', 'ComputeHash', 'ToBase64String', 'FromBase64String')
  $onlyIn = @{ 'WriteAllText' = @('Save-FixRecord'); 'Move' = @('Save-FixRecord'); 'CreateDirectory' = @('Initialize-FixRecordDir'); 'Start' = @('Invoke-Native'); 'Kill' = @('Invoke-Native')
    'Remove' = @('Invoke-Native'); 'SetSecurityDescriptorSddlForm' = @('Invoke-FixChange', 'Set-FixRecordAcl'); 'AddScript' = @('Get-FixProcessTable'); 'BeginStop' = @('Get-FixProcessTable') }
  foreach ($m in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
    $mn = $m.Member.Extent.Text; $fn = & $fnOf $m; $ex = $m.Expression.Extent.Text
    if ($okMembers -notcontains $mn) { [void]$bad.Add("member call $ex.$mn"); continue }
    if ($onlyIn.ContainsKey($mn) -and $onlyIn[$mn] -notcontains $fn) { [void]$bad.Add("$mn outside $($onlyIn[$mn] -join '/') ('$fn')") }
    if ($mn -eq 'Replace' -and $ex -match 'IO\.File' -and $fn -ne 'Save-FixRecord') { [void]$bad.Add('File.Replace outside Save-FixRecord') }
    if ($mn -eq 'Create' -and -not (($ex -eq '[System.Management.Automation.PowerShell]' -and $fn -eq 'Get-FixProcessTable') -or ($ex -eq '[System.Security.Cryptography.SHA256]' -and $fn -eq 'Get-AuthKeySummary'))) { [void]$bad.Add("Create on $ex in '$fn'") }
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
  $okRoots = @('$psi', '$s', '$item', '$it', '$seen', '$byId', '$h')
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
  'L4: Set-FixRecordAcl with another SDDL'   = "function Save-FixRecord { Set-FixRecordAcl 'C:\x' 'O:BAD:(A;;FA;;;WD)' }"
  'L4: Set-FixRecordAcl from elsewhere'      = "function Bad-TwentySix { Set-FixRecordAcl 'C:\x' `$RecordDirSddl }"
  'L4: AddScript with other commands'        = "function Get-FixProcessTable { `$ps.AddScript('Stop-Computer') }"
  'L4: AddScript with a variable'            = "function Get-FixProcessTable { `$ps.AddScript(`$x) }"
  'L4: Create on another type'               = "function Get-FixProcessTable { [System.Diagnostics.Process]::Create() }"
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
Remove-Item -LiteralPath $mdir -Recurse -Force

Write-Host 'NoYesFlag'
$tokens = $null; $perr = $null
$fast = [System.Management.Automation.Language.Parser]::ParseFile($fixPath, [ref]$tokens, [ref]$perr)
$pn = @($fast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-Equal ($pn -join ',') 'WhatIf,List,Help,Extra' 'parameters: WhatIf, List, Help (and -Undo <file> from the rest); no Yes, Force or Confirm'
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
Assert-True ($r.Code -eq 3 -and $r.Err -match 'an alias would run instead' -and $r.Err -match 'Get-FixState') 'INFO: an alias shadowing a function of the script: refused'
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
$TightDacl = 'D:PAI(A;;FA;;;BA)(A;;FA;;;SY)'
$KeyLine = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample build@build-01'
$Calls = New-Object System.Collections.ArrayList
$Snaps = New-Object System.Collections.ArrayList
$Reads = New-Object System.Collections.ArrayList
function Reset-Fake {
  $script:F = @{ SvcInstalled = $true; Status = 'Running'; StartType = 'Automatic'; Standby = 0; Hibernate = 0; LongPaths = 1; LpKind = $null; GitSystem = 'true'; GitGlobal = $null; GitTrusted = $true
    Dacl = $TightDacl; Owner = $BaSid }
  $script:Elev = $true; $script:Console = $true; $script:Answers = New-Object System.Collections.Queue; $script:OnAnswer = $null; $script:Asked = 0; $script:Trust = ''; $script:DirWhy = ''
  $Calls.Clear(); $Snaps.Clear(); $Reads.Clear()
  if (Test-Path -LiteralPath $RecDir) { Remove-Item -LiteralPath $RecDir -Recurse -Force }
}
function Get-FixRecordDir { return $RecDir }
# the record store: the folder is created plain (no admin-owned ACL here), trust is what the test says
function Initialize-FixRecordDir { if ($script:DirWhy) { return $script:DirWhy }; if (-not (Test-Path -LiteralPath $RecDir)) { [void](New-Item -ItemType Directory -Path $RecDir) }; return '' }
function Set-FixRecordAcl([string]$Path, [string]$Sddl) { }
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
    'power.sleep' { return @{ Standby = $f.Standby; Hibernate = $f.Hibernate } }
    'longpaths.on' { $k = $f.LpKind; if (-not $k) { if ($null -eq $f.LongPaths) { $k = 'none' } else { $k = 'DWord' } }; return @{ Value = $f.LongPaths; Kind = $k } }
    'git.longpaths' { $e = $f.GitSystem; if ($f.GitGlobal) { $e = $f.GitGlobal }; return @{ Git = 'C:\fake\git.exe'; Trusted = $f.GitTrusted; System = $f.GitSystem; Effective = $e; SystemFile = 'C:/fake/etc/gitconfig' } }
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
    'Test-FixElevated', 'Initialize-FixRecordDir', 'Set-FixRecordAcl', 'Test-FixRecordTrusted') {
    if (@(Get-Command $n)[0].CommandType -ne 'Function') { $n } })
if ($unsafe.Count -gt 0) { Write-Host "ABORT: not faked: $($unsafe -join ', ')" -ForegroundColor Red; exit 1 }
Assert-True $true 'every command that could change the PC is a fake'

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
  @('ssh.aclkeys', @{ Dacl = $OwnDacl }, "icacls.exe $KeysFile /inheritance:r /grant *S-1-5-32-544:F /grant *S-1-5-18:F", "Set-Acl $KeysFile D:AI(A;;FA;;;S-1-5-21-1-2-3-1001)")
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
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $Reads.Count -eq 0 -and $script:Asked -eq 0 -and (OutText) -match 'needs an elevated PowerShell') 'C7: undo when not elevated: says so before reading any state'

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
Reset-Fake; $F.LongPaths = 0; $script:DirWhy = 'the record folder X is not safe (it is owned by S-1-5-21-1)'
$rc = Invoke-Fake 'apply' '' @('y')
Assert-True ($rc -eq 1 -and $Calls.Count -eq 0 -and (OutText) -match 'not safe' -and (OutText) -match 'nothing changed') 'M1(a): an unsafe record folder: nothing is changed'
Reset-Fake
$rec0 = New-FixRecord; [void](New-Item -ItemType Directory -Path $RecDir); [System.IO.File]::WriteAllText($rec0.Path + '.tmp', 'planted'); $FixOut.Clear()
Assert-True (-not (Save-FixRecord $rec0) -and (OutText) -match 'exists \(left by a crash, or planted\)' -and -not (Test-Path -LiteralPath $rec0.Path)) 'L1: an existing temp file is refused, never written through'

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
$rc = Invoke-Fake 'undo' (Join-Path $RecDir 'missing.json') @('y')
Assert-True ($rc -eq 2 -and (OutText) -match 'no such file') 'undo of a missing file: exit 2'
Remove-Item -LiteralPath $RecDir -Recurse -Force -ErrorAction SilentlyContinue

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
foreach ($f in 'lanq-makeready.ps1', 'lanq-makeready.sh', 'lanq-makeready-fix.ps1', 'lanq-makeready-fix.sh', 'tests/run.ps1', 'tests/run.sh', 'tests/fix.ps1', 'tests/fix.sh') {
  $b = [System.IO.File]::ReadAllBytes((Join-Path $root $f))
  Assert-Equal @($b | Where-Object { ($_ -lt 32 -and $_ -ne 9 -and $_ -ne 10 -and $_ -ne 13) -or $_ -eq 127 }).Count 0 "$f has no control bytes (BEL, backspace, ...)"
}
$sch = [System.IO.File]::ReadAllText((Join-Path $root 'schema/fix-record.v1.json')) | ConvertFrom-Json
Assert-Equal $sch.properties.schema.const 'lanq-makeready-fix/v1' 'schema/fix-record.v1.json parses, schema id'
Assert-Equal ((@($sch.'$defs'.item.properties.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object) -join ',') 'after,before,command,id,seq,status,time' 'schema item fields = record item fields'
Assert-True (@($FixIds | Where-Object { @($sch.'$defs'.item.properties.id.enum) -notcontains $_ }).Count -eq 0) 'schema lists every Windows fix id'
Assert-True ('value=0 type=dword' -cmatch $sch.'$defs'.stateShapes.properties.'windows:longpaths.on'.pattern -and 'value=- type=none' -cmatch $sch.'$defs'.stateShapes.properties.'windows:longpaths.on'.pattern) 'schema: the longpaths shape includes the value type'

Write-Host ("`nfix PowerShell tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
