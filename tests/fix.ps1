# Tests for lanq-makeready-fix.ps1 (no Pester). Works on Windows PowerShell 5.1 and pwsh 7.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\fix.ps1
# SAFETY: every apply/undo here runs against fakes (state, cmdlets, Invoke-Native); the names the fixes touch are pointed
# at things that do not exist, and the run stops before any scenario if a fake is missing. Child processes are started
# only for refusals and argument errors, always with LANQ_MAKEREADY_FIX_LIB=1, which makes a direct run exit 2 right
# after the refusal checks, so even a broken refusal never reaches the fixes.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$fixPath = Join-Path $root 'lanq-makeready-fix.ps1'
$script:pass = 0; $script:fail = 0
function Assert-Equal($Actual, $Expected, [string]$Name) {
  if ("$Actual" -ceq "$Expected") { $script:pass++; Write-Host "  ok   $Name" }
  else { $script:fail++; Write-Host "  FAIL $Name : expected '$Expected' got '$Actual'" -ForegroundColor Red }
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
  @('power.sleep', 'standby=0 hibernate=3600'), @('longpaths.on', 'value=-'), @('longpaths.on', 'value=0'), @('git.longpaths', 'value=false'), @('git.longpaths', 'value=-'),
  @('ssh.aclkeys', 'dacl=D:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;BU)(A;;FA;;;S-1-5-21-1-2-3-1001)'))
foreach ($s in $okStates) { Assert-True ($null -ne (ConvertFrom-StateText $s[0] $s[1])) "state shape accepted: $($s[0]) $($s[1])" }
$badStates = @(@('ssh.start', 'starttype=Manual status=Stopped; Stop-Computer'), @('ssh.start', 'starttype=$(x) status=Stopped'), @('ssh.auto', 'starttype=Boot status=Running'),
  @('power.sleep', 'standby=99999999999 hibernate=0'), @('power.sleep', 'standby=-1 hibernate=0'), @('longpaths.on', 'value=1;x'), @('git.longpaths', "value=true'"),
  @('git.longpaths', 'value=a b'), @('ssh.aclkeys', 'dacl=D:(XA;;FA;;;WD;(@User.x == "y"))'), @('ssh.aclkeys', "dacl=D:(A;;FA;;;BA)')"), @('evil.fix', 'value=1'), @('power.sleep', ''))
foreach ($s in $badStates) { Assert-True ($null -eq (ConvertFrom-StateText $s[0] $s[1])) "state shape rejected: $($s[0]) '$($s[1])'" }

Write-Host 'state reads on this machine (read-only: Get-Service, powercfg /q, git config --get, Get-ItemProperty, Get-Acl)'
foreach ($id in $FixIds) { $st = Get-FixState $id; Assert-True ($st -is [hashtable]) "Get-FixState $id returns a state" }

Write-Host 'guard (AST allow-list; mutations only inside #region FIXES)'
function Get-FixGuardViolations([string]$Path) {
  $bad = New-Object System.Collections.ArrayList
  $tokens = $null; $perr = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$perr)
  if (@($perr).Count -gt 0) { return @("parse errors") }
  $text = [System.IO.File]::ReadAllText($Path)
  $r0 = [regex]::Matches($text, '(?m)^#region FIXES\r?$'); $r1 = [regex]::Matches($text, '(?m)^#endregion FIXES\r?$')
  if ($r0.Count -ne 1 -or $r1.Count -ne 1) { return @("exactly one #region FIXES ... #endregion FIXES") }
  $s0 = $r0[0].Index; $s1 = $r1[0].Index
  $funcNames = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
  $fnOf = { param($Node) $p = $Node.Parent; while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }; $p = $p.Parent }; return '' }
  $read = @('Get-Service', 'Get-CimInstance', 'Get-Command', 'Get-ItemProperty', 'Get-Item', 'Get-Acl', 'Get-ChildItem', 'Test-Path', 'Join-Path', 'Split-Path', 'Select-Object',
    'Where-Object', 'ForEach-Object', 'Sort-Object', 'ConvertFrom-Json', 'Write-Host', 'New-Object', 'Get-Location')
  $mut = @('Set-Service', 'Start-Service', 'Stop-Service', 'Set-ItemProperty', 'Remove-ItemProperty', 'Set-Acl')
  $okNative = @("`$PowercfgExe|@('/q', 'SCHEME_CURRENT', 'SUB_SLEEP', 'STANDBYIDLE')", "`$PowercfgExe|@('/q', 'SCHEME_CURRENT', 'SUB_SLEEP', 'HIBERNATEIDLE')",
    "`$git|@('config', '--system', '--get', 'core.longpaths')", "`$git|@('config', '--get', 'core.longpaths')")
  $okTypes = @('System.Diagnostics.ProcessStartInfo', 'Security.Principal.WindowsPrincipal', 'System.Text.UTF8Encoding', 'System.Collections.ArrayList', 'System.IO.FileInfo')
  foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $n = $c.GetCommandName(); $in = ($c.Extent.StartOffset -gt $s0 -and $c.Extent.EndOffset -lt $s1); $fn = & $fnOf $c
    if (-not $n) { [void]$bad.Add("dynamic command: $($c.Extent.Text)"); continue }
    if ($mut -contains $n) { if (-not $in) { [void]$bad.Add("mutating command $n outside the FIXES region") }; continue }
    if ($read -notcontains $n -and $funcNames -notcontains $n) { [void]$bad.Add("command $n is not on the allow-list") }
    if ($n -eq 'Invoke-Native' -and -not $in -and $fn -ne 'Invoke-Native') {
      $k = $c.CommandElements[1].Extent.Text + '|' + $(if ($c.CommandElements.Count -gt 2) { $c.CommandElements[2].Extent.Text } else { '' })
      if ($okNative -notcontains $k) { [void]$bad.Add("Invoke-Native outside FIXES with other than a read: $k") }
    }
    if ($n -eq 'Invoke-FixChange' -and @('Invoke-FixApply', 'Invoke-FixUndo') -notcontains $fn) { [void]$bad.Add("Invoke-FixChange called from '$fn'") }
    if ($n -eq 'New-Object' -and $okTypes -notcontains $c.CommandElements[1].Extent.Text.Trim("'`"")) { [void]$bad.Add("New-Object $($c.CommandElements[1].Extent.Text)") }
  }
  $okMembers = @('Add', 'RemoveAt', 'Close', 'ReadToEndAsync', 'WaitForExit', 'Wait', 'Kill', 'Start', 'Trim', 'Split', 'Replace', 'ToString', 'GetSecurityDescriptorSddlForm',
    'SetSecurityDescriptorSddlForm', 'IsInRole', 'GetCurrent', 'GetFolderPath', 'Matches', 'ToInt64', 'Exists', 'ReadAllText', 'WriteAllText', 'Move', 'CreateDirectory', 'WriteLine',
    'ReadLine', 'IsPathRooted', 'ContainsKey', 'Round', 'ToUniversalTime')
  $onlyIn = @{ 'WriteAllText' = 'Save-FixRecord'; 'Move' = 'Save-FixRecord'; 'CreateDirectory' = 'Save-FixRecord'; 'Start' = 'Invoke-Native'; 'Kill' = 'Invoke-Native' }
  foreach ($m in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
    $mn = $m.Member.Extent.Text; $fn = & $fnOf $m; $in = ($m.Extent.StartOffset -gt $s0 -and $m.Extent.EndOffset -lt $s1); $ex = $m.Expression.Extent.Text
    if ($okMembers -notcontains $mn) { [void]$bad.Add("member call $ex.$mn"); continue }
    if ($onlyIn.ContainsKey($mn) -and $fn -ne $onlyIn[$mn]) { [void]$bad.Add("$mn outside $($onlyIn[$mn])") }
    if ($mn -eq 'Replace' -and $ex -match 'IO\.File' -and $fn -ne 'Save-FixRecord') { [void]$bad.Add('File.Replace outside Save-FixRecord') }
    if ($mn -eq 'SetSecurityDescriptorSddlForm' -and -not $in) { [void]$bad.Add('SetSecurityDescriptorSddlForm outside the FIXES region') }
  }
  foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    if ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $a.Left.VariablePath.IsDriveQualified) { [void]$bad.Add("drive or env assignment $($a.Left.Extent.Text)") }
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
$mutants = [ordered]@{
  'Set-Service outside FIXES'              = 'function Bad-One { Set-Service -Name sshd -StartupType Automatic }'
  'Stop-Service outside FIXES'             = 'function Bad-Two { Stop-Service -Name sshd }'
  'Set-ItemProperty outside FIXES'         = 'function Bad-Three { Set-ItemProperty -Path $FsKey -Name LongPathsEnabled -Value 1 }'
  'Remove-ItemProperty outside FIXES'      = 'function Bad-Four { Remove-ItemProperty -Path $FsKey -Name LongPathsEnabled }'
  'Set-Acl outside FIXES'                  = 'function Bad-Five { Set-Acl -LiteralPath $KeysFile -AclObject $a }'
  'powercfg /change outside FIXES'         = "function Bad-Six { Invoke-Native `$PowercfgExe @('/change', 'standby-timeout-ac', '0') }"
  'git config --system write outside'      = "function Bad-Seven { Invoke-Native `$git @('config', '--system', 'core.longpaths', 'true') }"
  'icacls outside FIXES'                   = "function Bad-Eight { Invoke-Native `$IcaclsExe @(`$KeysFile, '/grant', 'Everyone:F') }"
  'an exe by name'                         = 'function Bad-Nine { icacls.exe C:\x /grant Everyone:F }'
  'Invoke-Expression'                      = "function Bad-Ten { Invoke-Expression 'Stop-Computer' }"
  'dynamic call'                           = 'function Bad-Eleven { & $x }'
  'scriptblock Create'                     = "function Bad-Twelve { [scriptblock]::Create('x') }"
  'WriteAllText outside Save-FixRecord'    = "function Bad-Thirteen { [System.IO.File]::WriteAllText('C:\x', 'y') }"
  'env assignment'                         = "function Bad-Fourteen { `$env:PATH = 'x' }"
  'SDDL set outside FIXES'                 = "function Bad-Fifteen { `$a.SetSecurityDescriptorSddlForm('D:(A;;FA;;;WD)', 'Access') }"
  'Invoke-FixChange from elsewhere'        = "function Bad-Sixteen { Invoke-FixChange 'power.sleep' 'apply' `$s `$s }"
  'redirection to a file'                  = "function Bad-Seventeen { 'x' > C:\x.txt }"
}
foreach ($k in $mutants.Keys) {
  $mt = $fixText.Replace("#region FIXES`n", $mutants[$k] + "`n#region FIXES`n")
  $mp = Join-Path $mdir 'm.ps1'; [System.IO.File]::WriteAllText($mp, $mt)
  Assert-True (@(Get-FixGuardViolations $mp).Count -gt 0) "GuardRejectsMutationOutsideFixTable: $k"
}
$mt = $fixText + "`nSet-Service -Name sshd -StartupType Automatic`n"; [System.IO.File]::WriteAllText($mp, $mt)
Assert-True (@(Get-FixGuardViolations $mp).Count -gt 0) 'GuardRejectsMutationOutsideFixTable: Set-Service after main'
$mt = $fixText.Replace("#endregion FIXES`n", "#endregion FIXES`n#endregion FIXES`n"); [System.IO.File]::WriteAllText($mp, $mt)
Assert-True (@(Get-FixGuardViolations $mp).Count -gt 0) 'guard: a second region end is refused'
$mt = $fixText.Replace("function Assert-Native", "function Bad-Ok { Stop-Service -Name sshd }`nfunction Assert-Native"); [System.IO.File]::WriteAllText($mp, $mt)
Assert-Equal (@(Get-FixGuardViolations $mp) -join '; ') '' 'guard sanity: the same mutation inside FIXES is allowed'
Remove-Item -LiteralPath $mdir -Recurse -Force

Write-Host 'NoYesFlag'
$tokens = $null; $perr = $null
$fast = [System.Management.Automation.Language.Parser]::ParseFile($fixPath, [ref]$tokens, [ref]$perr)
$pn = @($fast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-Equal ($pn -join ',') 'WhatIf,Undo,List,Help,Extra' 'parameters: WhatIf, Undo, List, Help only (no Yes, Force or Confirm)'
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
  return @{ Code = $p.ExitCode; Out = "$($o.Result)"; Err = "$($e.Result)" }
}
$fileArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$fixPath`""
foreach ($a in '-Yes', '-Force', '--yes', '-y', '-AssumeYes') {
  $r = Start-Child "$fileArgs $a"
  Assert-True ($r.Code -eq 2 -and $r.Err -match 'unknown argument' -and $r.Err -match 'no -Yes or -Force') "NoYesFlag: $a -> exit 2, unknown argument"
}
$r = Start-Child "$fileArgs -WhatIf -List"; Assert-True ($r.Code -eq 2 -and $r.Err -match 'only one of') 'two modes at once: exit 2'
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
$r = Start-Child "$fileArgs -List"
Assert-True ($r.Code -eq 2 -and $r.Err -match 'LANQ_MAKEREADY_FIX_LIB=1 is only for tests') 'a direct run with LANQ_MAKEREADY_FIX_LIB=1 passes the refusals, then exits 2'

# ---------- fakes ----------
Write-Host 'fakes (nothing below touches this PC)'
$SshdName = 'lanq-test-no-such-service'
$FsKey = 'HKCU:\Software\lanq-makeready-fix-test-none\FileSystem'
$PowercfgExe = 'C:\lanq-test-none\powercfg.exe'
$IcaclsExe = 'C:\lanq-test-none\icacls.exe'
$KeysFile = 'C:\lanq-test-none\administrators_authorized_keys'
$RecDir = Join-Path ([IO.Path]::GetTempPath()) ('lanq-fixrec-' + [Guid]::NewGuid().ToString('N'))
$OpenDacl = 'D:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;BU)'
$TightDacl = 'D:PAI(A;;FA;;;BA)(A;;FA;;;SY)'
$Calls = New-Object System.Collections.ArrayList
$Snaps = New-Object System.Collections.ArrayList
$Reads = New-Object System.Collections.ArrayList
function Reset-Fake {
  $script:F = @{ SvcInstalled = $true; Status = 'Running'; StartType = 'Automatic'; Standby = 0; Hibernate = 0; LongPaths = 1; GitSystem = 'true'; GitGlobal = $null; Dacl = $TightDacl }
  $script:Elev = $true; $script:Console = $true; $script:Answers = New-Object System.Collections.Queue; $script:OnAnswer = $null; $script:Asked = 0
  $Calls.Clear(); $Snaps.Clear(); $Reads.Clear()
  if (Test-Path -LiteralPath $RecDir) { Remove-Item -LiteralPath $RecDir -Recurse -Force }
}
function Get-FixRecordDir { return $RecDir }
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
    'longpaths.on' { return @{ Value = $f.LongPaths } }
    'git.longpaths' { $e = $f.GitSystem; if ($f.GitGlobal) { $e = $f.GitGlobal }; return @{ Git = 'C:\fake\git.exe'; System = $f.GitSystem; Effective = $e } }
    'ssh.aclkeys' { if (-not $f.Dacl) { return @{ Exists = $false } }; return @{ Exists = $true; Reparse = $false; Dacl = $f.Dacl; Ok = (Test-OnlyAdminsSystem $f.Dacl) } }
  }
}
function Set-Service { param($Name, $StartupType, $ErrorAction) Note-Call "Set-Service $Name $StartupType"; $script:F.StartType = "$StartupType" }
function Start-Service { param($Name, $ErrorAction) Note-Call "Start-Service $Name"; $script:F.Status = 'Running' }
function Stop-Service { param($Name, $ErrorAction) Note-Call "Stop-Service $Name"; $script:F.Status = 'Stopped' }
function Set-ItemProperty { param($Path, $Name, $Value, $Type, $ErrorAction) Note-Call "Set-ItemProperty $Path $Name $Value $Type"; $script:F.LongPaths = [long]$Value }
function Remove-ItemProperty { param($Path, $Name, $ErrorAction) Note-Call "Remove-ItemProperty $Path $Name"; $script:F.LongPaths = $null }
function Get-Acl { param($LiteralPath, $ErrorAction) $a = New-Object System.Security.AccessControl.FileSecurity; $a.SetSecurityDescriptorSddlForm($script:F.Dacl, [System.Security.AccessControl.AccessControlSections]::Access); return $a }
function Set-Acl { param($LiteralPath, $AclObject, $ErrorAction) Note-Call "Set-Acl $LiteralPath $($AclObject.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access))"; $script:F.Dacl = $AclObject.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access) }
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
$unsafe = @(foreach ($n in 'Set-Service', 'Start-Service', 'Stop-Service', 'Set-ItemProperty', 'Remove-ItemProperty', 'Set-Acl', 'Get-Acl', 'Invoke-Native', 'Get-FixState', 'Get-FixRecordDir', 'Test-FixElevated') {
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
  @('ssh.aclkeys', @{ Dacl = $OpenDacl }, "icacls.exe $KeysFile /inheritance:r /grant *S-1-5-32-544:F /grant *S-1-5-18:F", "Set-Acl $KeysFile $OpenDacl")
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
  $rp = Get-LatestRecord; $j = Read-Rec $rp
  Assert-True ($j.schema -eq 'lanq-makeready-fix/v1' -and @($j.items).Count -eq 1 -and $j.items[0].status -eq 'applied' -and $j.items[0].after -ne 'unknown') "$tag record: one item, applied, after state"
  Assert-True ($j.items[0].command -eq ((Get-FixCommand $id 'apply' (ConvertFrom-StateText $id $j.items[0].before)) -join ' ; ')) "$tag record: the command shown is the command recorded"
  Assert-True ((OutText) -match 'applied and verified') "$tag apply: verified"
  $rc = Invoke-Fake 'undo' $rp @('y')
  Assert-Equal $rc 0 "$tag undo: exit 0"
  Assert-Equal ($Calls -join '|') $c[3] "UndoRestoresEachFix: $tag exact undo commands"
  Assert-Equal (Get-AllStates) $start "UndoRestoresEachFix: $tag state back to the start"
  Assert-Equal (Read-Rec $rp).items[0].status 'undone' "$tag record: undone"
  $rc = Invoke-Fake 'undo' $rp @('y')
  Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and (OutText) -match 'Nothing to undo') "$tag second undo: nothing to do"
}

Write-Host 'only conditions the scanner reports are offered'
Reset-Fake; $rc = Invoke-Fake 'apply' '' @('y', 'y', 'y', 'y', 'y', 'y')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and (OutText) -match 'Nothing to fix') 'all good: nothing offered, nothing asked'
Reset-Fake; $F.SvcInstalled = $false; $F.Dacl = $null; $F.Status = 'Stopped'; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -notmatch '(?m)^ssh\.') 'no sshd, no keys file: no ssh fixes'
Reset-Fake; $F.Status = 'Running'; $F.StartType = 'Automatic'; $F.GitGlobal = 'false'; $F.GitSystem = 'true'; $rc = Invoke-Fake 'dry'
Assert-True ((OutText) -match 'git\.longpaths') 'git: offered when the effective value is not true'

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
$script:Elev = $false; $F.Standby = 0
$rc = Invoke-Fake 'undo' $rp @('y')
Assert-True ($Calls.Count -eq 0 -and $script:Asked -eq 3 -and (OutText) -match 'needs an elevated') 'undo when not elevated: skipped, not asked'

Write-Host 'a failed change is recorded'
Reset-Fake; $F.LongPaths = 0
function Set-ItemProperty { param($Path, $Name, $Value, $Type, $ErrorAction) Note-Call 'Set-ItemProperty failing'; throw 'access denied' }
$rc = Invoke-Fake 'apply' '' @('y')
Assert-True ($rc -eq 1 -and (OutText) -match 'FAILED: access denied' -and (Read-Rec (Get-LatestRecord)).items[0].status -eq 'failed') 'failed change: exit 1, item failed'
function Set-ItemProperty { param($Path, $Name, $Value, $Type, $ErrorAction) Note-Call "Set-ItemProperty $Path $Name $Value $Type"; $script:F.LongPaths = [long]$Value }

Write-Host 'WhatIfChangesNothing'
Reset-Fake; $F.Status = 'Stopped'; $F.StartType = 'Manual'; $F.Standby = 1800; $F.LongPaths = $null; $F.GitSystem = $null; $F.Dacl = $OpenDacl; $script:Console = $false
$before = Get-AllStates
$rc = Invoke-Fake 'dry' '' @('y', 'y', 'y', 'y', 'y')
Assert-True ($rc -eq 0 -and $Calls.Count -eq 0 -and $script:Asked -eq 0 -and $null -eq (Get-LatestRecord) -and (Get-AllStates) -eq $before) 'WhatIfChangesNothing: no command, no question, no record (and no console needed)'
foreach ($id in 'ssh.start', 'power.sleep', 'longpaths.on', 'git.longpaths', 'ssh.aclkeys') { Assert-True ((OutText) -match "(?m)^$([regex]::Escape($id)) ") "WhatIf shows $id" }
Assert-True ([regex]::Matches((OutText), '(?m)^  undo: ').Count -ge 5 -and (OutText) -match 'dry run: not applied') 'WhatIf shows each undo'

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
Reset-Fake; $script:Console = $false; $rc = Invoke-Fake 'list'
Assert-True ($rc -eq 0 -and (OutText) -match 'No undo records') '-List needs no console'

Write-Host 'TamperedRecordRejected'
Reset-Fake; $F.Standby = 1800; $F.LongPaths = 0
$rc = Invoke-Fake 'apply' '' @('y', 'y'); $rp = Get-LatestRecord; $good = [System.IO.File]::ReadAllText($rp)
Assert-True ($good -match '"items": \[\n    \{"seq": 1, "id": "power.sleep", "status": "applied"') 'record layout: one item per line'
$tampers = [ordered]@{
  'schema id'               = { param($t) $t.Replace('lanq-makeready-fix/v1', 'lanq-makeready-fix/v2') }
  'unknown fix id'          = { param($t) $t.Replace('"id": "longpaths.on"', '"id": "evil.fix"') }
  'command in before'       = { param($t) $t.Replace('"before": "value=0"', '"before": "value=0; Stop-Computer"') }
  'subexpression in before' = { param($t) $t.Replace('"before": "value=0"', '"before": "value=$(Stop-Computer)"') }
  'extra item field'        = { param($t) $t.Replace('"seq": 2,', '"seq": 2, "run": "Stop-Computer",') }
  'extra top-level field'   = { param($t) $t.Replace('"os": "windows",', '"os": "windows", "hook": "x",') }
  'unknown status'          = { param($t) $t.Replace('"status": "applied"', '"status": "done"') }
  'repeated seq'            = { param($t) $t.Replace('"seq": 2,', '"seq": 1,') }
  'seq as text'             = { param($t) $t.Replace('"seq": 2,', '"seq": "2",') }
  'linux record'            = { param($t) $t.Replace('"os": "windows"', '"os": "linux"') }
  'non-ASCII'               = { param($t) $t.Replace('"user": "', '"user": "' + [char]0xE9) }
  'escaped control char'    = { param($t) $t.Replace('"command": "', '"command": "\u001b[2J') }
  'bad after shape'         = { param($t) [regex]::Replace($t, '"after": "value=1"', '"after": "value=1 && x"') }
  'number as state'         = { param($t) $t.Replace('"before": "value=0"', '"before": 0') }
  'not JSON'                = { param($t) $t.Substring(0, 40) }
  'too large'               = { param($t) $t + (' ' * 300000) }
}
foreach ($k in $tampers.Keys) {
  $tt = & $tampers[$k] $good
  Assert-True ($tt -cne $good) "tamper '$k' changes the text"
  [System.IO.File]::WriteAllText($rp, $tt)
  $F.Standby = 0; $F.LongPaths = 1
  $rc = Invoke-Fake 'undo' $rp @('y', 'y')
  Assert-True ($rc -eq 2 -and $Calls.Count -eq 0 -and (OutText) -match 'record rejected' -and [System.IO.File]::ReadAllText($rp) -ceq $tt) "TamperedRecordRejected: $k -> exit 2, nothing run, file untouched"
}
[System.IO.File]::WriteAllText($rp, $good)
$rc = Invoke-Fake 'list'
Assert-True ($rc -eq 0 -and (OutText) -match 'power.sleep applied, longpaths.on applied') '-List shows the records'
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

Write-Host ("`nfix PowerShell tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
