# POOL-SAFE: the Defender ladder checks for a real pool PC (build-02), run by the owner at the PC in an elevated
# PowerShell, from a copy of the release candidate in a folder only Administrators may change (it refuses otherwise).
# Matrix ids E1-E8, L2 (and G1 with -DevDrive). Usage (docs/TUNE.md, "Before a release: build-02"):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\pool-defender.ps1 -BuildUser <the build account>
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\pool-defender.ps1 -BuildUser <account> -DevDrive
# Unlike tests/real-defender.ps1 (CI only) it creates no users, removes no existing exclusion, never touches real-time
# protection or any other Defender setting, and changes nothing without the fix script's own prompts: it runs the
# real fix script (you type the path to confirm, as always), checks the result, undoes exactly the record that run
# wrote (you confirm), and prints a PASS/FAIL summary. Its own test folders are made admin-only in the record folder
# and moved into place, checked before every write and delete, and removed in a finally block; if it is interrupted
# after the apply, it says which record to undo. Without -DevDrive the PC is left as it was, except that lanq-work and
# its .lanq-pin stay (the fix never deletes them). It also prints the answers to two open questions: the exact form
# Defender stores C:\lanq-work\ in, and whether fsutil devdrv query shows WdFilter attached right after the format.
param([Parameter(Mandatory = $true)][string]$BuildUser, [switch]$DevDrive)
$root = Split-Path -Parent $PSScriptRoot
$fixPath = Join-Path $root 'lanq-makeready-fix.ps1'
$env:LANQ_MAKEREADY_FIX_LIB = '1'
. $fixPath
Remove-Item Env:\LANQ_MAKEREADY_FIX_LIB
$script:Results = New-Object System.Collections.ArrayList
function Check([bool]$Cond, [string]$Name) { [void]$script:Results.Add(@{ Ok = $Cond; Name = $Name }); if ($Cond) { Write-Host "  PASS $Name" -ForegroundColor Green } else { Write-Host "  FAIL $Name" -ForegroundColor Red } }
function Show-Summary {
  $f = @($script:Results | Where-Object { -not $_.Ok })
  Write-Host ''; Write-Host ("pool-defender: {0} PASS, {1} FAIL" -f (@($script:Results).Count - $f.Count), $f.Count) -ForegroundColor $(if ($f.Count) { 'Red' } else { 'Green' })
  foreach ($x in $f) { Write-Host "  FAIL $($x.Name)" -ForegroundColor Red }
  if ($f.Count) { exit 1 } else { exit 0 }
}
function Stop-Pool([string]$Why) { Check $false $Why; Show-Summary }
function Get-RecordNames { return @(Get-ChildItem -LiteralPath (Get-FixRecordDir) -Filter 'fix-*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
# A folder of ours (made admin-only in the record folder) moved to $Dst; $null when the move fails (the name exists).
function New-PoolDir([string]$Dst, [string]$Tag, [int]$N) {
  $stage = '\\?\' + (Join-Path (Get-FixRecordDir) "pool-$Tag-$N"); New-FixSecuredDir $stage $AdminOnlySddl
  try { [System.IO.Directory]::Move($stage, $Dst) } catch { try { [System.IO.Directory]::Delete($stage) } catch { }; return $null }
  [void]$script:Made.Add($Dst); return $Dst
}

# ---------- refusals: CI, not elevated, over SSH or from stdin, a checkout others could change ----------
if ($env:GITHUB_ACTIONS -eq 'true') { [Console]::Error.WriteLine('pool-defender.ps1: this is for a pool PC; CI runs tests/real-defender.ps1.'); exit 2 }
if (-not (Test-FixElevated)) { [Console]::Error.WriteLine('pool-defender.ps1: run it in an elevated PowerShell at the PC.'); exit 2 }
$why = Get-FixRefusal 'apply' $true
if ($why) { [Console]::Error.WriteLine("pool-defender.ps1: $why"); exit 3 }
foreach ($x in @($root, $PSScriptRoot, $fixPath, $PSCommandPath)) {   # L-6: an elevated run must not load code others may change
  $w = Test-TrustedSddl (Get-PathSddl $x)
  if ($w) { [Console]::Error.WriteLine("pool-defender.ps1: $x is not safe to run elevated ($w). Copy the release candidate to a folder only Administrators may change (for example under C:\ProgramData) and run it from there."); exit 2 }
}
$why = Get-FixRecordDirProblem
if ($why) { [Console]::Error.WriteLine("pool-defender.ps1: $why"); exit 2 }
$L = Get-SystemDriveLetter; $entry = Get-LanqWorkEntry $L; $work = Get-LanqWorkPath $L
$st = Get-MpComputerStatus
Write-Host "PowerShell $($PSVersionTable.PSVersion); Defender AMRunningMode=$($st.AMRunningMode) RealTimeProtectionEnabled=$($st.RealTimeProtectionEnabled) AMProductVersion=$($st.AMProductVersion)"
Write-Host 'This runs the real fix (you type the path), checks it, and undoes it (you answer y). Nothing else is changed.'
$script:Made = New-Object System.Collections.ArrayList

if (-not $DevDrive) {
  $ex0 = $null; try { $ex0 = @(Get-MpExclusions) } catch { Stop-Pool "the exclusions cannot be read ($($_.Exception.Message))" }
  if (@($ex0) -contains $entry) { Stop-Pool "before: $entry is already excluded; undo that first (lanq-makeready-fix.ps1 -Undo <its record>)" }
  Check $true "before: $entry is not excluded yet"
  if (-not [System.IO.Directory]::Exists((Get-FixRecordDir))) { [void](Initialize-FixRecordDir) }
  if ("$(Get-FixRecordDir)".Substring(0, 1).ToUpperInvariant() -cne $L) { Stop-Pool "the record folder is not on $L`: (the test folders could not be moved into place)" }
  $before = @(Get-RecordNames); $rec = ''; $tag = [Guid]::NewGuid().ToString('N'); $n = 0
  try {
    # E1: our own positive control, in an admin-only folder of the record area
    $pc = '\\?\' + (Join-Path (Get-FixRecordDir) "pool-pc-$tag"); New-FixSecuredDir $pc $AdminOnlySddl; [void]$script:Made.Add($pc); $pf = "$pc\eicar-$tag.com"
    $t0 = [DateTime]::Now.AddSeconds(-5); $hit = $false
    if (-not (Test-SelfTestDir $pc)) { Stop-Pool "$pc is not the folder this script made" }
    try { [System.IO.File]::WriteAllBytes($pf, (Get-EicarBytes)) } catch { $hit = (Test-VirusError $_.Exception) }
    if (-not $hit) { $hit = Wait-MpDetection $pf $t0 30 }
    Check $hit 'E1: Defender catches the EICAR test file (positive control)'
    if (-not $hit) { Stop-Pool 'Defender does not scan here, so E2-E8 cannot be checked' }

    # M-A: the real apply (its own self-test is E2-E8); PASS means exactly one new record with defender.exclude applied
    $FixOut.Clear(); [void](Invoke-FixMain -Mode apply -FromFile $true -Set defender -BuildUser $BuildUser)
    $newRecs = @(Get-RecordNames | Where-Object { $before -notcontains $_ })
    if ($newRecs.Count -eq 1) { $rp = Join-Path (Get-FixRecordDir) $newRecs[0]; $rr = Read-FixRecord $rp; if (-not $rr.Error -and @($rr.Rec.Items | Where-Object { $_.id -eq 'defender.exclude' }).Count -ge 1) { $rec = $rp } }
    $applied = ($rec -and @((Read-FixRecord $rec).Rec.Items | Where-Object { $_.id -eq 'defender.exclude' -and $_.status -eq 'applied' }).Count -eq 1)
    Check $applied "apply: exactly one new record, and it says defender.exclude applied ($($newRecs.Count) new record(s)); its self-test covers E2-E8"
    $stored = @(Get-MpExclusions | Where-Object { "$_".TrimEnd('\', '.', ' ') -ieq $entry.TrimEnd('\') })
    Write-Host "OPEN QUESTION 1, the stored form: $(@($stored | ForEach-Object { "'$_'" }) -join ', ') (the fix adds '$entry')"
    if ($applied) {
      Check ($stored.Count -eq 1 -and $stored[0] -ceq $entry) "Defender stores exactly '$entry'"
      $fid = (Get-WorkDirFacts $work).FileId
      Check (Test-WorkDirSame $work $fid) 'H-A: lanq-work is a plain folder with its admin-only .lanq-pin'
      # E2: inside lanq-work the test file stays 15 s (the folder is re-checked before the move, the write and the delete)
      $n++; $t0 = [DateTime]::Now.AddSeconds(-5); $dst = $null
      if (Test-WorkDirSame $work $fid) { $dst = New-PoolDir "\\?\$work\pool-in-$tag" $tag $n }
      if (-not $dst -or -not (Test-SelfTestDir $dst) -or -not (Test-WorkDirSame $work $fid)) { Check $false 'E2: the test folder inside lanq-work could not be put in place' }
      else {
        $f = "$dst\eicar-$tag.com"; $ok = $true; try { [System.IO.File]::WriteAllBytes($f, (Get-EicarBytes)) } catch { $ok = $false }
        Check ($ok -and -not (Wait-MpDetection $f $t0 15)) 'E2: the test file inside lanq-work stays 15 s'
      }
      # E3-E8: every sibling form is caught (this run's tagged name in the threat history)
      $i = 3
      foreach ($t in (Get-SiblingTests (Get-DriveRoot $L) $tag)) {
        $n++; $d = New-PoolDir ('\\?\' + $t.Dir) $tag $n
        if (-not $d -or -not (Test-SelfTestDir $d)) { Check $false "E$i`: '$($t.Dir)' could not be put in place (it exists already: look at it)"; $i++; continue }
        if ($t.Ads) { $h = "$d\$($t.Host)"; [System.IO.File]::WriteAllBytes($h, [byte[]](120)) }
        $f = "$d\$($t.File)"; $t0 = [DateTime]::Now.AddSeconds(-5); $hit = $false
        try { [System.IO.File]::WriteAllBytes($f, (Get-EicarBytes)) } catch { $hit = (Test-VirusError $_.Exception) }
        if (-not $hit) { $hit = Wait-MpDetection $f $t0 30 -HistoryOnly }
        Check $hit "E$($i): the test file in '$($t.Dir)' ($($t.File)) is caught (threat history)"
        $i++
      }
      # L2: a file written through a junction in lanq-work to a folder outside it is scanned (the target counts)
      $n++; $tgt = New-PoolDir ('\\?\' + "$L`:\lanq-pool-tgt-$tag") $tag $n
      $jn = "$work\pool-jn-$tag"
      if ($tgt -and (Test-WorkDirSame $work $fid)) {
        $mk = Invoke-Native (Join-Path $SysDir 'cmd.exe') @('/d', '/c', 'mklink', '/J', $jn, "$L`:\lanq-pool-tgt-$tag")
        if ($mk.Code -eq 0) {
          $f = "$jn\eicar-$tag-jn.com"; $t0 = [DateTime]::Now.AddSeconds(-5); $hit = $false
          try { [System.IO.File]::WriteAllBytes($f, (Get-EicarBytes)) } catch { $hit = (Test-VirusError $_.Exception) }
          if (-not $hit) { $hit = Wait-MpDetection "$L`:\lanq-pool-tgt-$tag\eicar-$tag-jn.com" $t0 30 }
          Check $hit 'L2: a test file written through a junction in lanq-work to a folder outside it is caught'
          [System.IO.Directory]::Delete($jn)   # the link only, never its target
        } else { Check $false "L2: the junction could not be made ($($mk.Out))" }
      } else { Check $false 'L2: the target folder could not be put in place' }
    }
  } finally {
    for ($j = $script:Made.Count - 1; $j -ge 0; $j--) {
      $q = "$($script:Made[$j])"
      if ($q -like "*\lanq-work\*" -and -not (Test-WorkDirSame $work (Get-WorkDirFacts $work).FileId)) { Write-Host "  left alone: $q (lanq-work changed)" -ForegroundColor Yellow; continue }
      if ([System.IO.Directory]::Exists($q)) { if (Test-SelfTestDir $q) { try { [System.IO.Directory]::Delete($q, $true) } catch { } } else { Write-Host "  left alone: $q is not a folder this script made" -ForegroundColor Yellow } }
    }
    if ($rec -and @(Get-MpExclusions) -contains $entry -and -not $script:UndoDone) { Write-Host "INTERRUPTED or not undone: the exclusion is still there. Undo it: lanq-makeready-fix.ps1 -Undo `"$rec`"" -ForegroundColor Yellow }
  }
  # undo exactly the record this run's apply wrote (you answer y): the exclusion goes, the folder stays
  if ($rec) {
    $FixOut.Clear(); $rc = Invoke-FixMain -Mode undo -UndoPath $rec -FromFile $true; $script:UndoDone = $true
    Check ($rc -eq 0 -and @(Get-MpExclusions) -notcontains $entry) "undo of $rec`: the exclusion is removed"
    Check ([System.IO.Directory]::Exists($work) -and [System.IO.Directory]::Exists((Join-Path $work $PinName))) 'undo: lanq-work and its .lanq-pin are kept'
  }
  Show-Summary
}

# -DevDrive: the first run makes the Dev Drive (you type the VHDX path); after a restart, the second run checks G1.
$vh = Get-DevVhdFacts
if (-not $vh.Exists) {
  $before = @(Get-RecordNames)
  $FixOut.Clear(); [void](Invoke-FixMain -Mode apply -FromFile $true -Set devdrive -BuildUser $BuildUser)
  $newRecs = @(Get-RecordNames | Where-Object { $before -notcontains $_ }); $vh = Get-DevVhdFacts
  $applied = ($newRecs.Count -eq 1 -and @((Read-FixRecord (Join-Path (Get-FixRecordDir) $newRecs[0])).Rec.Items | Where-Object { $_.id -eq 'devdrive.create' -and $_.status -eq 'applied' }).Count -eq 1)
  Check ($applied -and $vh.Attached -and $vh.Letter) "devdrive.create: one new record, applied; attached as $($vh.Letter):"
  if ($vh.Letter) {
    $q = Invoke-Native $FsutilExe @('devdrv', 'query', "$($vh.Letter):")
    Write-Host "OPEN QUESTION 2, fsutil devdrv query $($vh.Letter): right after the format:"; Write-Host $q.Out
    Check ((Get-DevDrvInfo $q.Out).Filter) 'fsutil devdrv query shows WdFilter attached right after the format'
  }
  Write-Host 'G1: restart the PC now, then run this script again with -DevDrive (do not attach the VHDX by hand first).'
} else {
  Check $vh.Attached "G1: after the restart the Dev Drive VHDX is attached again by itself (attached: $($vh.Attached))"
  if ($vh.Letter) {
    $p = Get-LanqWorkPath $vh.Letter
    Check ([System.IO.Directory]::Exists($p) -and (Test-SelfTestDir (Join-Path $p $PinName))) "G1: $p and its .lanq-pin are there"
    $q = Invoke-Native $FsutilExe @('devdrv', 'query', "$($vh.Letter):"); Write-Host $q.Out
    $i = Get-DevDrvInfo $q.Out
    Check ($i.State -eq 'trusted' -and $i.Av -eq 'ok' -and $i.Filter) 'G1: still a trusted Dev Drive with antivirus allowed and WdFilter attached'
  } else { Write-Host "Not attached: attach it with Mount-DiskImage -ImagePath '$DevVhdFile' (and tell the maintainer: a startup task is then needed)." }
}
Show-Summary
