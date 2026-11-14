# CI ONLY: real apply and undo of lanq-makeready-fix.ps1 on a disposable GitHub-hosted Windows runner. This CHANGES the
# machine (powercfg, LongPathsEnabled, git --system, sshd, administrators_authorized_keys, %ProgramData%\lanq-makeready)
# and then puts it back. The gate below (GITHUB_ACTIONS, RUNNER_ENVIRONMENT=github-hosted, LANQ_REAL_FIX_OK) only
# guards against running it by accident; it is not a security boundary. Never run it on a PC you care about.
# The only test seam used is console simulation: Test-FixConsole returns true and Read-FixAnswer answers y.
# LANQ_REAL_FIX_REQUIRE (comma list) names the fixes the setup step made necessary; each must be applied and undone.
# LANQ_REAL_FIX_SET=tune runs the safe tune fixes (power.cpu, do.mode, sysmain, defender.scantime) with
# LANQ_REAL_FIX_HOURS as -Hours; the other tune fixes are covered by the fake tests (tests/fix.ps1).
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:LANQ_REAL_FIX_OK -ne 'disposable-runner') {
  [Console]::Error.WriteLine('real-fix.ps1: refusing: this changes the machine; it runs only in CI on a disposable GitHub-hosted runner.'); exit 2
}
$root = Split-Path -Parent $PSScriptRoot
$env:LANQ_MAKEREADY_FIX_LIB = '1'
. (Join-Path $root 'lanq-makeready-fix.ps1')
Remove-Item Env:\LANQ_MAKEREADY_FIX_LIB
function Test-FixConsole { return $true }
function Read-FixAnswer { Write-Host 'y'; return 'y' }
$set = 'base'; $ids = $BaseFixIds; $hours = "$env:LANQ_REAL_FIX_HOURS"
if ($env:LANQ_REAL_FIX_SET -eq 'tune') {
  $set = 'tune'; $TuneFixIds = @('power.cpu', 'do.mode', 'sysmain', 'defender.scantime'); $ids = $TuneFixIds; $FixSet = 'tune'; $FixHours = $hours
  # sysmain is offered only when every disk is a known SSD; runner disks report Unspecified. The change itself is real.
  function Test-FixAllSsd { return $true }
}
$fail = 0
function Check([bool]$Cond, [string]$Name) { if ($Cond) { Write-Host "  ok   $Name" } else { $script:fail++; Write-Host "  FAIL $Name" -ForegroundColor Red } }
function Snap { $h = [ordered]@{}; foreach ($id in $ids) { $h[$id] = "$(Get-StateText $id (Get-FixState $id))" }; return $h }
function Show($Title, $S) { Write-Host $Title; foreach ($k in $S.Keys) { Write-Host ("  {0,-14} {1}" -f $k, $S[$k]) } }

Write-Host "PowerShell $($PSVersionTable.PSVersion), elevated: $(Test-FixElevated), session $(Get-FixSessionId)"
$before = Snap; Show 'before' $before
$need = @($ids | Where-Object { Test-FixNeeded $_ (Get-FixState $_) })
Write-Host "needed: $($need -join ', ')"
foreach ($id in $ids) { $n = Get-FixNote $id (Get-FixState $id); if ($n) { Write-Host "  note $id : $n" } }
foreach ($r in @("$env:LANQ_REAL_FIX_REQUIRE".Split(',') | Where-Object { $_ })) { Check ($need -contains $r) "setup made $r necessary" }

$dirBefore = Test-Path -LiteralPath (Get-FixRecordDir)
Write-Host "record folder exists before apply: $dirBefore; FileSystemAclExtensions available: $([bool]('System.IO.FileSystemAclExtensions' -as [type]))"
if ($env:LANQ_REAL_FIX_NEW_DIR -eq '1') { Check (-not $dirBefore) 'the record folder is absent, so this run creates it' }
$rc = Invoke-FixMain -Mode apply -FromFile $true -Set $set -Hours $hours
Check ($rc -eq 0) "apply: exit 0 (got $rc)"
$after = Snap; Show 'after apply' $after
foreach ($id in $need) { Check (Test-FixDone $id (Get-FixState $id)) "applied for real: $id" }
$dir = Get-FixRecordDir
$dsd = "$((Get-Acl -LiteralPath $dir).Sddl)"; Write-Host "record folder $dir : $dsd"
if (-not $dirBefore) { Check ($dsd -cmatch '^O:BA' -and $dsd -cmatch 'D:PA?I?\(' -and (Test-OnlyAdminsSystem ($dsd -replace '^.*?D:', 'D:'))) 'R1: the folder this run created is owned by Administrators, protected, Administrators and SYSTEM only' }
Check ((Test-FixRecordDirTrusted $dir) -eq '') 'M1(a): the record folder is owned by Administrators, protected, Administrators and SYSTEM only'
$rec = @(Get-ChildItem -LiteralPath $dir -Filter 'fix-*.json' | Sort-Object -Property LastWriteTimeUtc)[-1].FullName
Write-Host "record: $rec  $((Get-Acl -LiteralPath $rec).Sddl)"; Get-Content -LiteralPath $rec | ForEach-Object { Write-Host "  $_" }
Check ((Test-FixRecordTrusted $rec) -eq '') 'M1(a): the record itself is trusted'
$j = Get-Content -LiteralPath $rec -Raw | ConvertFrom-Json
Check (@($j.items | Where-Object { $_.status -eq 'applied' }).Count -eq $need.Count) 'record: every needed fix applied'

$rc = Invoke-FixMain -Mode undo -UndoPath $rec -FromFile $true
Check ($rc -eq 0) "undo: exit 0 (got $rc)"
$restored = Snap; Show 'after undo' $restored
foreach ($id in $ids) {
  Check ((Test-SameState $id $restored[$id] $before[$id]) -or $restored[$id] -ceq $before[$id]) "undo restored $id ($($before[$id]))"
  if ($restored[$id] -cne $before[$id]) { Write-Host "  note: $id text differs only in what Windows re-inherits: $($restored[$id])" }
}
$j = Get-Content -LiteralPath $rec -Raw | ConvertFrom-Json
Check (@($j.items | Where-Object { $_.status -ne 'undone' }).Count -eq 0) 'record: every item undone'
if ($fail -gt 0) { exit 1 } else { exit 0 }
