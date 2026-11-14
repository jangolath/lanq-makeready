# POOL-SAFE: the Defender ladder checks for a real pool PC (build-02), run by the owner at the PC in an elevated
# PowerShell. Matrix ids E1-E8 (and G1 with -DevDrive). Usage (docs/TUNE.md, "Before a release: build-02"):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\pool-defender.ps1 -BuildUser <the build account>
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\pool-defender.ps1 -BuildUser <account> -DevDrive
# Unlike tests/real-defender.ps1 (CI only) it creates no users, removes no existing exclusion, never touches real-time
# protection or any other Defender setting, and changes nothing without the fix script's own prompts: it runs the
# real fix script (you type the path to confirm, as always), checks the result, undoes it (you confirm), and prints a
# PASS/FAIL summary. Without -DevDrive the PC is left as it was (lanq-work stays: the fix never deletes it).
# It also prints the answers to two open questions: the exact form Defender stores C:\lanq-work\ in, and whether
# fsutil devdrv query shows WdFilter attached right after Format-Volume -DevDrive.
param([Parameter(Mandatory = $true)][string]$BuildUser, [switch]$DevDrive)
$root = Split-Path -Parent $PSScriptRoot
$fixPath = Join-Path $root 'lanq-makeready-fix.ps1'
$env:LANQ_MAKEREADY_FIX_LIB = '1'
. $fixPath
Remove-Item Env:\LANQ_MAKEREADY_FIX_LIB
$script:Results = New-Object System.Collections.ArrayList
function Check([bool]$Cond, [string]$Name) { [void]$script:Results.Add(@{ Ok = $Cond; Name = $Name }); if ($Cond) { Write-Host "  PASS $Name" -ForegroundColor Green } else { Write-Host "  FAIL $Name" -ForegroundColor Red } }
function Out-Fix { return ($FixOut -join "`n") }
function Show-Summary {
  $f = @($script:Results | Where-Object { -not $_.Ok })
  Write-Host ''; Write-Host ("pool-defender: {0} PASS, {1} FAIL" -f (@($script:Results).Count - $f.Count), $f.Count) -ForegroundColor $(if ($f.Count) { 'Red' } else { 'Green' })
  foreach ($x in $f) { Write-Host "  FAIL $($x.Name)" -ForegroundColor Red }
  if ($f.Count) { exit 1 } else { exit 0 }
}

if ($env:GITHUB_ACTIONS -eq 'true') { [Console]::Error.WriteLine('pool-defender.ps1: this is for a pool PC; CI runs tests/real-defender.ps1.'); exit 2 }
if (-not (Test-FixElevated)) { [Console]::Error.WriteLine('pool-defender.ps1: run it in an elevated PowerShell at the PC.'); exit 2 }
$why = Get-FixRefusal 'apply' $true
if ($why) { [Console]::Error.WriteLine("pool-defender.ps1: $why"); exit 3 }
$L = Get-SystemDriveLetter; $entry = Get-LanqWorkEntry $L; $work = Get-LanqWorkPath $L
$st = Get-MpComputerStatus
Write-Host "PowerShell $($PSVersionTable.PSVersion); Defender AMRunningMode=$($st.AMRunningMode) RealTimeProtectionEnabled=$($st.RealTimeProtectionEnabled) AMProductVersion=$($st.AMProductVersion)"
Write-Host 'This runs the real fix (you type the path), checks it, and undoes it (you answer y). Nothing else is changed.'

if (-not $DevDrive) {
  $ex0 = @(Get-MpExclusions)
  Check (@($ex0) -notcontains $entry) "before: $entry is not excluded yet (undo any earlier one first)"
  # E1: our own positive control, in an admin-only folder of the record area (removed afterwards)
  $t0 = [DateTime]::Now.AddSeconds(-5); $tag = [Guid]::NewGuid().ToString('N')
  $pc = Join-Path (Get-FixRecordDir) "pool-pc-$tag"; New-FixSecuredDir $pc $AdminOnlySddl; $pf = Join-Path $pc "eicar-$tag.com"
  $hit = $false; try { [System.IO.File]::WriteAllBytes($pf, (Get-EicarBytes)) } catch { $hit = (Test-VirusError $_.Exception) }
  if (-not $hit) { $hit = Wait-MpDetection $pf $t0 30 }
  try { [System.IO.Directory]::Delete($pc, $true) } catch { }
  Check $hit 'E1: Defender catches the EICAR test file (positive control)'
  if (-not $hit) { Write-Host 'Defender does not scan here, so E2-E8 cannot be checked.'; Show-Summary }

  # the real apply: its own self-test is E2-E8 (inside lanq-work stays; every sibling form and a stream are caught)
  $FixOut.Clear(); $rc = Invoke-FixMain -Mode apply -FromFile $true -Set defender -BuildUser $BuildUser
  Check ($rc -eq 0) "apply: exit 0 (got $rc); its self-test covers E2-E8"
  $stored = @(Get-MpExclusions | Where-Object { "$_".TrimEnd('\', '.', ' ') -ieq $entry.TrimEnd('\') })
  Write-Host "OPEN QUESTION 1, the stored form: $(@($stored | ForEach-Object { "'$_'" }) -join ', ') (the fix adds '$entry')"
  Check ($stored.Count -eq 1 -and $stored[0] -ceq $entry) "Defender stores exactly '$entry'"
  if ($rc -eq 0) {
    # E2-E8 once more from here, with fresh names (the apply already cleaned its own)
    $tag = [Guid]::NewGuid().ToString('N'); $t0 = [DateTime]::Now.AddSeconds(-5)
    $in = Join-Path (Get-FixRecordDir) "pool-in-$tag"; New-FixSecuredDir $in $AdminOnlySddl; $dst = Join-Path $work "pool-in-$tag"
    [System.IO.Directory]::Move($in, $dst); $f = Join-Path $dst "eicar-$tag.com"
    $ok = $true; try { [System.IO.File]::WriteAllBytes($f, (Get-EicarBytes)) } catch { $ok = $false }
    Check ($ok -and -not (Wait-MpDetection $f $t0 15)) 'E2: the test file inside lanq-work stays 15 s'
    try { [System.IO.Directory]::Delete($dst, $true) } catch { }
    $i = 3
    foreach ($t in (Get-SiblingTests (Get-DriveRoot $L) $tag)) {
      $d = '\\?\' + $t.Dir
      if ([System.IO.Directory]::Exists($d)) { Check $false "E$i`: '$($t.Dir)' exists already (look at it)"; $i++; continue }
      $sg = Join-Path (Get-FixRecordDir) "pool-sib-$tag-$i"; New-FixSecuredDir $sg $AdminOnlySddl; [System.IO.Directory]::Move($sg, $d)
      $f = "$d\$($t.File)"; if ($t.Ads) { [System.IO.File]::WriteAllBytes("$d\$($t.Host)", [byte[]](120)) }
      $hit = $false; try { [System.IO.File]::WriteAllBytes($f, (Get-EicarBytes)) } catch { $hit = (Test-VirusError $_.Exception) }
      if (-not $hit) { $hit = Wait-MpDetection $f $t0 30 -HistoryOnly }
      Check $hit "E$($i): the test file in '$($t.Dir)' ($($t.File)) is caught (threat history)"
      try { [System.IO.Directory]::Delete($d, $true) } catch { }
      $i++
    }
    # undo (you answer y): the exclusion goes, the folder stays
    $rec = @(Get-ChildItem -LiteralPath (Get-FixRecordDir) -Filter 'fix-*.json' | Sort-Object -Property LastWriteTimeUtc)[-1].FullName
    $FixOut.Clear(); $rc = Invoke-FixMain -Mode undo -UndoPath $rec -FromFile $true
    Check ($rc -eq 0 -and @(Get-MpExclusions) -notcontains $entry) 'undo: the exclusion is removed'
    Check ([System.IO.Directory]::Exists($work)) 'undo: lanq-work is kept'
  }
  Show-Summary
}

# -DevDrive: the first run makes the Dev Drive (you type the VHDX path); after a restart, the second run checks G1.
$vh = Get-DevVhdFacts
if (-not $vh.Exists) {
  $FixOut.Clear(); $rc = Invoke-FixMain -Mode apply -FromFile $true -Set devdrive -BuildUser $BuildUser
  $vh = Get-DevVhdFacts
  Check ($rc -eq 0 -and $vh.Attached -and $vh.Letter) "devdrive.create: exit 0 (got $rc), attached as $($vh.Letter):"
  if ($vh.Letter) {
    $q = Invoke-Native $FsutilExe @('devdrv', 'query', "$($vh.Letter):")
    Write-Host "OPEN QUESTION 2, fsutil devdrv query $($vh.Letter): right after the format:"; Write-Host $q.Out
    Check ((Get-DevDrvInfo $q.Out).Filter) 'fsutil devdrv query shows WdFilter attached right after the format'
  }
  Write-Host 'G1: restart the PC now, then run this script again with -DevDrive (do not attach the VHDX by hand first).'
} else {
  Check $vh.Attached "G1: after the restart the Dev Drive VHDX is attached again by itself (attached: $($vh.Attached))"
  if ($vh.Letter) {
    Check ([System.IO.Directory]::Exists((Get-LanqWorkPath $vh.Letter))) "G1: $($vh.Letter):\lanq-work is there"
    $q = Invoke-Native $FsutilExe @('devdrv', 'query', "$($vh.Letter):"); Write-Host $q.Out
    $i = Get-DevDrvInfo $q.Out
    Check ($i.State -eq 'trusted' -and $i.Av -eq 'ok' -and $i.Filter) 'G1: still a trusted Dev Drive with antivirus allowed and WdFilter attached'
  } else { Write-Host "Not attached: attach it with Mount-DiskImage -ImagePath '$DevVhdFile' (and tell the maintainer: a startup task is then needed)." }
}
Show-Summary
