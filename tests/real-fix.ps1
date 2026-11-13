# CI ONLY: real apply and undo of lanq-makeready-fix.ps1 on a disposable GitHub Windows runner. This CHANGES the machine
# (powercfg, LongPathsEnabled, git --system, sshd, administrators_authorized_keys) and then puts it back. It refuses to
# run unless GITHUB_ACTIONS=true and LANQ_REAL_FIX_OK=disposable-runner. Never run it on a PC you care about.
# The only test seam used is console simulation: Test-FixConsole returns true and Read-FixAnswer answers y.
# LANQ_REAL_FIX_REQUIRE (comma list) names the fixes the setup step made necessary; each must be applied and undone.
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:LANQ_REAL_FIX_OK -ne 'disposable-runner') {
  [Console]::Error.WriteLine('real-fix.ps1: refusing: this changes the machine; it runs only in CI on a disposable runner.'); exit 2
}
$root = Split-Path -Parent $PSScriptRoot
$env:LANQ_MAKEREADY_FIX_LIB = '1'
. (Join-Path $root 'lanq-makeready-fix.ps1')
Remove-Item Env:\LANQ_MAKEREADY_FIX_LIB
function Test-FixConsole { return $true }
function Read-FixAnswer { Write-Host 'y'; return 'y' }
$fail = 0
function Check([bool]$Cond, [string]$Name) { if ($Cond) { Write-Host "  ok   $Name" } else { $script:fail++; Write-Host "  FAIL $Name" -ForegroundColor Red } }
function Snap { $h = [ordered]@{}; foreach ($id in $FixIds) { $h[$id] = "$(Get-StateText $id (Get-FixState $id))" }; return $h }
function Show($Title, $S) { Write-Host $Title; foreach ($k in $S.Keys) { Write-Host ("  {0,-14} {1}" -f $k, $S[$k]) } }

Write-Host "PowerShell $($PSVersionTable.PSVersion), elevated: $(Test-FixElevated)"
$before = Snap; Show 'before' $before
$need = @($FixIds | Where-Object { Test-FixNeeded $_ (Get-FixState $_) })
Write-Host "needed: $($need -join ', ')"
foreach ($r in @("$env:LANQ_REAL_FIX_REQUIRE".Split(',') | Where-Object { $_ })) { Check ($need -contains $r) "setup made $r necessary" }

$rc = Invoke-FixMain -Mode apply -FromFile $true
Check ($rc -eq 0) "apply: exit 0 (got $rc)"
$after = Snap; Show 'after apply' $after
foreach ($id in $need) { Check (Test-FixDone $id (Get-FixState $id)) "applied for real: $id" }
$rec = @(Get-ChildItem -LiteralPath (Get-FixRecordDir) -Filter 'fix-*.json' | Sort-Object -Property LastWriteTimeUtc)[-1].FullName
Write-Host "record: $rec"; Get-Content -LiteralPath $rec | ForEach-Object { Write-Host "  $_" }
$j = Get-Content -LiteralPath $rec -Raw | ConvertFrom-Json
Check (@($j.items | Where-Object { $_.status -eq 'applied' }).Count -eq $need.Count) 'record: every needed fix applied'

$rc = Invoke-FixMain -Mode undo -UndoPath $rec -FromFile $true
Check ($rc -eq 0) "undo: exit 0 (got $rc)"
$restored = Snap; Show 'after undo' $restored
foreach ($id in $FixIds) { Check ($restored[$id] -ceq $before[$id]) "undo restored $id ($($before[$id]))" }
$j = Get-Content -LiteralPath $rec -Raw | ConvertFrom-Json
Check (@($j.items | Where-Object { $_.status -ne 'undone' }).Count -eq 0) 'record: every item undone'
if ($fail -gt 0) { exit 1 } else { exit 0 }
