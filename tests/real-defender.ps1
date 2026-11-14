# CI ONLY: real defender.exclude apply, non-admin probes, drift and undo on a disposable GitHub-hosted Windows runner
# ("Pass 4 (defender)"). It CHANGES the machine: it creates two local users, C:\lanq-work, a Defender exclusion, EICAR
# test files, and removes the runner's own C:\ and D:\ exclusions. The gate below (GITHUB_ACTIONS,
# RUNNER_ENVIRONMENT=github-hosted, LANQ_REAL_FIX_OK) only guards against running it by accident; it is not a security
# boundary. Never run it on a PC you care about. Matrix ids (docs/TUNE.md): A10, B8, C2, C3 and G3 for real here, and
# E1-E8 best effort: the runner image turns real-time protection off and excludes C:\ and D:\. The script tries to
# undo that and runs its own positive control; when Defender still does not scan, it prints a ::notice::, simulates
# only the scan results (everything else stays real) and says so. E1-E8 and G1 must then be run on build-02.
# Add-Type (LogonUser) is used here, in test code only; the product scripts never use it.
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:LANQ_REAL_FIX_OK -ne 'disposable-runner') {
  [Console]::Error.WriteLine('real-defender.ps1: refusing: this changes the machine; it runs only in CI on a disposable GitHub-hosted runner.'); exit 2
}
$root = Split-Path -Parent $PSScriptRoot
$env:LANQ_MAKEREADY_FIX_LIB = '1'
. (Join-Path $root 'lanq-makeready-fix.ps1')
Remove-Item Env:\LANQ_MAKEREADY_FIX_LIB
$script:Answers = New-Object System.Collections.Queue
function Test-FixConsole { return $true }
function Read-FixAnswer { $a = $null; if ($script:Answers.Count) { $a = $script:Answers.Dequeue() }; Write-Host "$a"; return $a }
$fail = 0
function Check([bool]$Cond, [string]$Name) { if ($Cond) { Write-Host "  ok   $Name" } else { $script:fail++; Write-Host "  FAIL $Name" -ForegroundColor Red } }
function Out-Fix { return ($FixOut -join "`n") }

Write-Host "PowerShell $($PSVersionTable.PSVersion), elevated: $(Test-FixElevated)"
try { $st0 = Get-MpComputerStatus -ErrorAction Stop } catch { Write-Host "::notice::Defender is not available on this runner ($($_.Exception.Message)): Pass 4 skipped; run tests/real-defender.ps1 steps on build-02."; exit 0 }
Write-Host "Defender: AMRunningMode=$($st0.AMRunningMode) RealTimeProtectionEnabled=$($st0.RealTimeProtectionEnabled) IsTamperProtected=$($st0.IsTamperProtected)"
$L = Get-SystemDriveLetter; $work = Get-LanqWorkPath $L; $entry = Get-LanqWorkEntry $L
Check (-not (Test-Path -LiteralPath $work)) "$work does not exist yet (a fresh run)"

# ---------- two local non-admin accounts (test code: net.exe; passwords only in this process) ----------
function New-Pw { $c = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'; $r = New-Object System.Random; return ('Lq' + (-join (1..9 | ForEach-Object { $c[$r.Next($c.Length)] })) + '#7a') }
$users = @{ lanqbuild = (New-Pw); lanqother = (New-Pw) }
foreach ($u in $users.Keys) {
  & net.exe user $u /delete 2>$null | Out-Null
  & net.exe user $u $users[$u] /add /expires:never /passwordchg:no 2>&1 | Out-Null
  Check ($LASTEXITCODE -eq 0) "created the local user $u"
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LanqCiLogon {
  [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool LogonUser(string user, string domain, string password, int logonType, int provider, out IntPtr token);
}
'@
function Get-Token([string]$User) {
  foreach ($t in 2, 3, 8) {   # interactive, network, network cleartext
    $h = [IntPtr]::Zero
    if ([LanqCiLogon]::LogonUser($User, '.', $users[$User], $t, 0, [ref]$h)) { Write-Host "  (logon type $t for $User)"; return (New-Object Microsoft.Win32.SafeHandles.SafeAccessTokenHandle($h)) }
    Write-Host "  logon type $t for $User failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
  }
  return $null
}
$tokens = @{}; foreach ($u in $users.Keys) { $tokens[$u] = Get-Token $u; Check ($null -ne $tokens[$u]) "LogonUser $u (for the non-admin probes)" }
# Runs $Do as $User; $true when it completed without an error.
function Test-As([string]$User, [scriptblock]$Do) {
  $script:ProbeErr = ''; $script:ProbeOk = $false; $script:ProbeDo = $Do
  if (-not $tokens[$User]) { $script:ProbeErr = 'no token'; return $null }
  $act = [Action]{ try { & $script:ProbeDo; $script:ProbeOk = $true } catch { $script:ProbeErr = "$($_.Exception.Message)" } }
  try { [System.Security.Principal.WindowsIdentity]::RunImpersonated($tokens[$User], $act) } catch { $script:ProbeErr = "$($_.Exception.Message)"; $script:ProbeOk = $false }
  return $script:ProbeOk
}

# ---------- A10: the runner's own C:\ exclusion is the fixture ----------
$ex0 = @((Get-MpPreference).ExclusionPath | Where-Object { $_ })
Write-Host "runner exclusions: $($ex0.Count) entries; C:\ among them: $([bool](@($ex0) -contains 'C:\'))"
if (@($ex0) -notcontains 'C:\') { Add-MpPreference -ExclusionPath 'C:\'; Write-Host '  (added C:\ as the A10 fixture)' }
# The image turns real-time protection off, which is checked first ("not offered: real-time protection is off"); to
# test A10 itself, the Defender facts say it is on for this one dry run. The exclusion list stays the real one.
$realDef0 = ${function:Get-DefenderFacts}
function Get-DefenderFacts { $d = & $realDef0; $d.Mode = 'Normal'; $d.Rtp = $true; $d.Rtsd = 0; return $d }
$FixOut.Clear(); $rc = Invoke-FixMain -Mode dry -FromFile $true -Set defender -BuildUser lanqbuild
Set-Item -Path Function:\Get-DefenderFacts -Value $realDef0
Write-Host (Out-Fix)
Check ($rc -eq 0 -and (Out-Fix) -match 'not offered: .*already covers') 'A10: with C:\ excluded, defender.exclude is not offered (reported, never recorded)'
Check (-not (Test-Path -LiteralPath $work)) 'A10: nothing was created'
foreach ($x in @((Get-MpPreference).ExclusionPath | Where-Object { $_ })) { if ((Get-ExclusionStatus @($x) $entry).Broader -or (Get-ExclusionStatus @($x) $entry).Unknown -or (Get-ExclusionStatus @($x) $entry).Variant) { Remove-MpPreference -ExclusionPath $x; Write-Host "  removed the runner exclusion $x" } }

# ---------- E: make Defender scan if it can, then a positive control of our own ----------
try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop } catch { Write-Host "  could not turn real-time protection on: $($_.Exception.Message)" }
Start-Sleep -Seconds 5
$st1 = Get-MpComputerStatus
$E = $false
if ("$($st1.AMRunningMode)" -eq 'Normal' -and $st1.RealTimeProtectionEnabled) {
  $pcDir = "$L`:\lanq-ci-pc-$([Guid]::NewGuid().ToString('N'))"; [void][System.IO.Directory]::CreateDirectory($pcDir)
  $pf = Join-Path $pcDir "eicar-$([Guid]::NewGuid().ToString('N')).com"; $t0 = [DateTime]::Now.AddSeconds(-5)
  $E = $false; try { [System.IO.File]::WriteAllBytes($pf, (Get-EicarBytes)) } catch { $E = (Test-VirusError $_.Exception); Write-Host "  write blocked: $($_.Exception.Message)" }
  if (-not $E) { $E = Wait-MpDetection $pf $t0 30 }
  try { [System.IO.Directory]::Delete($pcDir, $true) } catch { }
}
if ($E) { Write-Host 'E: Defender scans here (positive control detected): E1-E8 run for real in this pass' }
else {
  Write-Host "::notice::Defender does not scan on this runner (AMRunningMode=$($st1.AMRunningMode), real-time protection $($st1.RealTimeProtectionEnabled), or the positive control was not detected). E1-E8 are SIMULATED in this pass (the scan results only; folders, permissions, the exclusion, the record, the probes and undo are real). Run E1-E8 and G1 on build-02."
  $realDef = ${function:Get-DefenderFacts}
  function Get-DefenderFacts { $d = & $realDef; $d.Mode = 'Normal'; $d.Rtp = $true; $d.Rtsd = 0; return $d }
  function Wait-MpDetection([string]$Path, $Since, [int]$Sec, [switch]$HistoryOnly) { return ($Path -notlike "*\lanq-work\lanq-selftest-*") }
}

# ---------- C2: apply for real ----------
$script:Answers.Enqueue("$L`:\lanq-work")
$FixOut.Clear(); $rc = Invoke-FixMain -Mode apply -FromFile $true -Set defender -BuildUser lanqbuild
Write-Host (Out-Fix)
Check ($rc -eq 0) "C2: apply: exit 0 (got $rc)"
$sid = (Get-BuildUser 'lanqbuild').Sid
$sd = "$((Get-Acl -LiteralPath $work).Sddl)"; Write-Host "lanq-work: $sd"
Check (Test-WorkDirSd $sd $sid) 'B1/C2: lanq-work has exactly the owner and permissions the fix sets (read back from Windows)'
Check (@((Get-MpPreference).ExclusionPath | Where-Object { $_ -eq $entry }).Count -eq 1) "C2: the exclusion $entry is there, once"
$rec = @(Get-ChildItem -LiteralPath (Get-FixRecordDir) -Filter 'fix-*.json' | Sort-Object -Property Name)[-1].FullName
Get-Content -LiteralPath $rec | ForEach-Object { Write-Host "  $_" }
Check ((Test-FixRecordTrusted $rec) -eq '' -and (Read-FixRecord $rec).Error -eq '' -and (Get-Content -LiteralPath $rec -Raw) -match '"id": "defender.exclude", "status": "applied"') 'C2: the record is trusted, valid and says applied'

if ($E) {
  # E2-E8 again from the test, on top of the apply-time matrix
  $tag = [Guid]::NewGuid().ToString('N'); $t0 = [DateTime]::Now.AddSeconds(-5)
  $in = Join-Path $work "ci-$tag"; [void][System.IO.Directory]::CreateDirectory($in); $f = Join-Path $in "eicar-$tag.com"
  $ok2 = $true; try { [System.IO.File]::WriteAllBytes($f, (Get-EicarBytes)) } catch { $ok2 = $false }; Start-Sleep -Seconds 15
  Check ($ok2 -and [System.IO.File]::Exists($f)) 'E2: EICAR inside lanq-work survives 15 s (the exclusion works)'
  [System.IO.Directory]::Delete($in, $true)
  $i = 3
  foreach ($s in @("lanq-work-ci$tag", "lanq-workci$tag", "lanq-work.ci$tag", 'lanq-work.', 'lanq-work ')) {
    $d = '\\?\' + "$L`:\$s"; [void][System.IO.Directory]::CreateDirectory($d); $f = "$d\eicar-$tag.com"
    $hit = $false; try { [System.IO.File]::WriteAllBytes($f, (Get-EicarBytes)) } catch { $hit = (Test-VirusError $_.Exception) }
    if (-not $hit) { $hit = Wait-MpDetection $f $t0 30 -HistoryOnly }
    Check $hit "E$i`: EICAR in the sibling '$s' is detected (the exclusion does not reach it)"; $i++
    try { [System.IO.Directory]::Delete($d, $true) } catch { }
  }
  $d = "$L`:\lanq-work-ads$tag"; [void][System.IO.Directory]::CreateDirectory($d); [System.IO.File]::WriteAllText("$d\host-$tag.txt", 'x')
  $hit = $false; try { [System.IO.File]::WriteAllBytes('\\?\' + "$d\host-$tag.txt:eicar-$tag", (Get-EicarBytes)) } catch { $hit = (Test-VirusError $_.Exception) }
  if (-not $hit) { $hit = Wait-MpDetection "$d\host-$tag.txt:eicar-$tag" $t0 30 -HistoryOnly }
  Check $hit 'E8: EICAR in a stream of a sibling file is detected'
  try { [System.IO.Directory]::Delete($d, $true) } catch { }
}

# ---------- B8: what the build user and another user can do (LogonUser + RunImpersonated) ----------
$moved = "$L`:\lanq-work-moved"
Check (Test-As 'lanqbuild' { [System.IO.File]::WriteAllText("$work\b.txt", 'build output') }) "B8: the build user creates a file in lanq-work ($ProbeErr)"
Check (Test-As 'lanqbuild' { [void][System.IO.Directory]::CreateDirectory("$work\sub") }) "B8: the build user creates a folder in lanq-work ($ProbeErr)"
Check (-not (Test-As 'lanqbuild' { [System.IO.Directory]::Move($work, $moved) })) "B8: the build user cannot rename lanq-work ($ProbeErr)"
Check (-not (Test-As 'lanqbuild' { $a = Get-Acl -LiteralPath $work; $a.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('Everyone', 'FullControl', 'Allow'))); Set-Acl -LiteralPath $work -AclObject $a -ErrorAction Stop })) "B8: the build user cannot change lanq-work's permissions ($ProbeErr)"
Check (-not (Test-As 'lanqbuild' { [System.IO.File]::SetAttributes($work, [System.IO.FileAttributes]::Hidden) })) "B8/M3: the build user cannot change lanq-work's attributes ($ProbeErr)"
Check (-not (Test-As 'lanqbuild' { $a = Get-Acl -LiteralPath "$work\b.txt"; $a.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('Everyone', 'FullControl', 'Allow'))); Set-Acl -LiteralPath "$work\b.txt" -AclObject $a -ErrorAction Stop })) "B8/H3: the build user cannot let others into its own file (OWNER RIGHTS) ($ProbeErr)"
[void](Test-As 'lanqbuild' { [System.IO.Directory]::Delete($work, $true) })
Check ([System.IO.Directory]::Exists($work) -and -not [System.IO.Directory]::Exists($moved)) "B8: the build user cannot delete lanq-work itself ($ProbeErr)"
Check (-not (Test-As 'lanqother' { [System.IO.File]::WriteAllText("$work\o.txt", 'x') })) "B8: another user cannot create a file in lanq-work ($ProbeErr)"
Check (-not (Test-As 'lanqother' { [System.IO.Directory]::Move($work, $moved) })) "B8: another user cannot rename lanq-work ($ProbeErr)"
Check (-not (Test-As 'lanqother' { [void][System.IO.Directory]::CreateDirectory("$work\sub2") })) "B8: another user cannot create a folder in lanq-work ($ProbeErr)"

# ---------- G3: the tune scan's drift check, run elevated ----------
$psExe = (Get-Process -Id $PID).Path
function Get-Drift {
  $o = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'lanq-makeready-tune.ps1') -Json - 2>$null
  try { return @(("$($o -join "`n")" | ConvertFrom-Json).items | Where-Object { $_.id -eq 'defender.drift' })[0] } catch { return $null }
}
$dr = Get-Drift; Write-Host "defender.drift: $($dr.status): $($dr.detail)"
Check ($dr.status -eq 'OK') 'G3: defender.drift is OK right after the fix'
[void][System.IO.Directory]::CreateDirectory("$work\sub\deep")
$a = Get-Acl -LiteralPath "$work\sub"; $a.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('Everyone', 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))); Set-Acl -LiteralPath "$work\sub" -AclObject $a
$dr = Get-Drift; Write-Host "defender.drift: $($dr.status): $($dr.detail)"
Check ($dr.status -eq 'WARN' -and $dr.security -and $dr.detail -match 'sampled entries') 'G3/H3: an admin let Everyone into a subfolder: defender.drift WARN (security)'
$a = Get-Acl -LiteralPath "$work\sub"; [void]$a.RemoveAccessRuleAll((New-Object System.Security.AccessControl.FileSystemAccessRule('Everyone', 'Modify', 'Allow'))); Set-Acl -LiteralPath "$work\sub" -AclObject $a

# ---------- C2/C3: undo, then apply again on the same folder ----------
$script:Answers.Enqueue('y')
$FixOut.Clear(); $rc = Invoke-FixMain -Mode undo -UndoPath $rec -FromFile $true
Write-Host (Out-Fix)
Check ($rc -eq 0 -and @((Get-MpPreference).ExclusionPath | Where-Object { $_ -eq $entry }).Count -eq 0) 'C2: undo removed the exclusion'
Check ([System.IO.Directory]::Exists($work)) 'C2: undo kept lanq-work'
$script:Answers.Enqueue("$L`:\lanq-work")
$FixOut.Clear(); $rc = Invoke-FixMain -Mode apply -FromFile $true -Set defender -BuildUser lanqbuild
Write-Host (Out-Fix)
Check ($rc -eq 0 -and @((Get-MpPreference).ExclusionPath | Where-Object { $_ -eq $entry }).Count -eq 1) 'C3: apply again uses the existing folder (a trusted record matches it)'
$rec2 = @(Get-ChildItem -LiteralPath (Get-FixRecordDir) -Filter 'fix-*.json' | Sort-Object -Property Name)[-1].FullName
$script:Answers.Enqueue('y')
$FixOut.Clear(); $rc = Invoke-FixMain -Mode undo -UndoPath $rec2 -FromFile $true
Check ($rc -eq 0 -and @((Get-MpPreference).ExclusionPath | Where-Object { $_ -eq $entry }).Count -eq 0) 'C2: the second undo removed it again'

foreach ($u in $users.Keys) { if ($tokens[$u]) { $tokens[$u].Dispose() }; & net.exe user $u /delete 2>$null | Out-Null }
if ($fail -gt 0) { exit 1 } else { exit 0 }
