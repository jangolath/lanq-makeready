# Self-contained test runner (no Pester). Works on Windows PowerShell 5.1 and pwsh 7.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1 [-SkipSmoke]
param([switch]$SkipSmoke)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function Assert-Equal($Actual, $Expected, [string]$Name) {
  if ("$Actual" -ceq "$Expected") { $script:pass++; Write-Host "  ok   $Name" }
  else { $script:fail++; Write-Host "  FAIL $Name : expected '$Expected' got '$Actual'" -ForegroundColor Red }
}
function Assert-True($Cond, [string]$Name) { Assert-Equal ([bool]$Cond) 'True' $Name }

$env:LANQ_READY_LIB = '1'
. (Join-Path $root 'lanq-ready.ps1')
Remove-Item Env:\LANQ_READY_LIB

function New-Facts([hashtable]$Over = @{}) {
  $f = @{ Hostname = 'box'; User = 'builder'; Profile = 'C:\Users\builder'; Caption = 'Windows 11 Pro'; Build = 26100; IsServer = $false
    EditionId = 'Professional'; Is64 = $true; IsArm = $false; Arch = 'x64'; CpuName = 'Test CPU'; Cores = 2; Logical = 4; Avx2 = 'True'
    RamGB = 16; FreeRamGB = 8; SysFreeGB = 200; WorkFreeGB = 200; DiskMedia = 'SSD'; WorkDrive = 'C:'
    SshdInstalled = $true; SshdRunning = $true; SshdStartType = 'Automatic'; SshFirewall = $true; IsAdminUser = $false; AuthKeysNonEmpty = $true
    GitVer = 'git version 2.45.0'; GitLongPaths = $true; TarBsd = $true; LongPaths = $true; DotnetSdks = @(10)
    DockerCli = $true; DockerServerOk = $true; DockerServer = '27.0'; WslOk = $true; Tools = @{ node = 'v22.1.0' }
    StandbyAcSec = 0; HibernateAcSec = 0; RebootPending = $false; WolAdapters = 0; StartupCount = 5; StartupNames = @()
    TempSizes = @(); DefenderRtp = $false; DevDrive = $true; ProblemDevices = @(); Hours = $null }
  foreach ($k in $Over.Keys) { $f[$k] = $Over[$k] }
  return $f
}
function Run($F) { $c = Get-Checks $F; return @{ C = $c; V = (Get-Verdicts $c $F); M = (Get-Machine $F $null $F.Hours $false) } }
function St($R, [string]$Id) { ($R.C | Where-Object { $_.id -eq $Id }).status }
function Ck($R, [string]$Id) { $R.C | Where-Object { $_.id -eq $Id } }

Write-Host 'verdicts: Windows 11, 16 GB, SSD, all good'
$r = Run (New-Facts)
foreach ($k in 'worker_git', 'worker_archive', 'dotnet10', 'docker', 'overnight') { Assert-Equal $r.V[$k] 'OK' "good: $k" }
Assert-Equal $r.M.max_jobs 1 'good: 4 threads -> max_jobs 1'
Assert-Equal (Run (New-Facts @{ Logical = 16 })).M.max_jobs 2 'good: 16 threads + 16 GB -> max_jobs 2'

Write-Host 'verdicts: consumer Windows 10 22H2, 4 GB, HDD, no sshd'
$r = Run (New-Facts @{ Caption = 'Windows 10 Home'; Build = 19045; EditionId = 'Core'; RamGB = 3.8; DiskMedia = 'HDD'; SshdInstalled = $false; SshdRunning = $null
  DockerCli = $false; DockerServerOk = $false; VirtFirmware = $true; WslOk = $false; AuthKeysNonEmpty = $false })
Assert-Equal $r.V.worker_git 'FAIL' 'win10: worker_git FAIL (no sshd)'
Assert-Equal $r.V.worker_archive 'FAIL' 'win10: worker_archive FAIL (no sshd)'
Assert-Equal (St $r 'ssh.server') 'FAIL' 'win10: ssh.server FAIL'
Assert-Equal (St $r 'os.version') 'WARN' 'win10: os.version WARN (EOL)'
Assert-Equal $r.V.dotnet10 'WARN' 'win10: .NET 10 WARN (not on supported list)'
Assert-Equal (St $r 'disk') 'WARN' 'win10: HDD -> disk WARN'
Assert-Equal (St $r 'ram') 'WARN' 'win10: 3.8 GB -> ram WARN'
Assert-Equal $r.V.docker 'WARN' 'win10: docker WARN (under 4 GB)'
Assert-True ((Ck $r 'ssh.server').advice -match 'Add-WindowsCapability') 'win10: ssh advice is the printed install command'

Write-Host 'verdicts: 32-bit Windows'
$r = Run (New-Facts @{ Is64 = $false; Arch = 'x86'; Build = 19045; DockerCli = $false; DockerServerOk = $false; DotnetSdks = @() })
Assert-Equal (St $r 'os.arch') 'FAIL' '32-bit: os.arch FAIL'
Assert-Equal $r.V.dotnet10 'FAIL' '32-bit: .NET 10 FAIL'
Assert-Equal $r.V.docker 'FAIL' '32-bit: docker FAIL'

Write-Host 'verdicts: no git but bsdtar -> archive transfer'
$r = Run (New-Facts @{ GitVer = $null })
Assert-Equal $r.V.worker_git 'FAIL' 'no git: worker_git FAIL'
Assert-Equal $r.V.worker_archive 'OK' 'no git: worker_archive OK'
Assert-Equal $r.M.transfer 'archive' 'no git: suggested transfer archive'
Assert-True ((Format-Snippet $r.M $r.V) -contains '    transfer: archive') 'no git: snippet says transfer: archive'
Assert-Equal (Run (New-Facts @{ GitVer = $null; TarBsd = $false })).V.worker_archive 'FAIL' 'no git, no tar: archive FAIL'

Write-Host 'verdicts: Docker with HypervisorPresent true, firmware flag false'
$dk = @{ DockerCli = $false; DockerServerOk = $false; Build = 22631 }
$r = Run (New-Facts ($dk + @{ HypervisorPresent = $true; VirtFirmware = $false }))
Assert-Equal $r.V.docker 'OK' 'hypervisor present: treated as virtualization enabled'
Assert-True ((Ck $r 'docker').detail -match 'hypervisor') 'hypervisor present: detail explains why'
$r = Run (New-Facts ($dk + @{ HypervisorPresent = $false; VirtFirmware = $false }))
Assert-Equal $r.V.docker 'FAIL' 'no hypervisor and firmware flag false: FAIL'
Assert-True ((Ck $r 'docker').advice -match 'BIOS') 'virtualization advice mentions BIOS'

Write-Host 'verdicts: RAM under 8 GB -> Docker Desktop WARN with advice'
$r = Run (New-Facts ($dk + @{ HypervisorPresent = $true; RamGB = 6 }))
Assert-Equal $r.V.docker 'WARN' '6 GB: docker WARN'
Assert-True ((Ck $r 'docker').advice -match 'Docker Engine inside WSL') '6 GB: advice names Engine in WSL'
Assert-Equal (St (Run (New-Facts @{ RamGB = 1.5 })) 'ram') 'FAIL' 'under 2 GB: ram FAIL'

Write-Host 'helpers: hours, powercfg, active hours, redaction, snippet'
Assert-True (Test-Hours '00:00-07:00') 'hours: valid'
Assert-True (Test-Hours '22:00-07:00') 'hours: wraps midnight'
Assert-True (-not (Test-Hours '07:00-07:00')) 'hours: equal start/end rejected'
Assert-True (-not (Test-Hours '7-8')) 'hours: bad format rejected'
Assert-True (-not (Test-Hours '24:00-07:00')) 'hours: 24:00 rejected'
Assert-Equal (Get-PowercfgAcSeconds "  Current AC Power Setting Index: 0x00000000`n  Current DC Power Setting Index: 0x00000258") 0 'powercfg: AC never = 0'
Assert-Equal (Get-PowercfgAcSeconds "  Current AC Power Setting Index: 0x00000708") 1800 'powercfg: AC 30 min = 1800'
Assert-True ($null -eq (Get-PowercfgAcSeconds 'garbage')) 'powercfg: unparseable -> null'
Assert-True (Test-UpdateOverlap '00:00-07:00' 8 17) 'active hours: night window outside 08-17 -> overlap'
Assert-True (-not (Test-UpdateOverlap '09:00-12:00' 8 17)) 'active hours: day window inside -> no overlap'
$r = Run (New-Facts @{ Hours = '00:00-07:00'; StandbyAcSec = 1800 })
Assert-Equal $r.V.overnight 'WARN' 'sleep after 30 min -> overnight WARN'
Assert-True ((Ck $r 'power.sleep').advice -match 'powercfg /change standby-timeout-ac 0') 'sleep advice is the exact powercfg command'
Assert-Equal (Protect-Text 'every box and C:\Users\builder\x' @{ Profile = 'C:\Users\builder'; User = 'builder'; Hostname = 'ver' }) 'every box and <redacted>\x' 'redaction: whole tokens only'
$m = Get-Machine (New-Facts @{ Hours = '22:00-07:00' }) $null '22:00-07:00' $true
Assert-Equal $m.name 'old-pc' 'redacted snippet name'
$sn = (Format-Snippet $m (Run (New-Facts)).V) -join "`n"
Assert-True ($sn -match 'allowed_hours: "22:00-07:00"') 'snippet: allowed_hours quoted HH:mm-HH:mm'
Assert-True ($sn -match 'os: windows' -and $sn -notmatch 'builder') 'snippet: os windows, no user name when redacted'

Write-Host 'read-only guard: no mutating or network commands outside the advice table'
$patterns = @('Set-ItemProperty', 'New-Item', 'Remove-Item', 'Set-Service', 'Start-Service', 'Stop-Service', '\breg(\.exe)?\s+add\b', 'powercfg\s+[/-]change',
  'pnputil\s+[/-]add', 'Add-WindowsCapability', '(?<![\w-])rm\s', '\bsudo\b', 'systemctl\s+(enable|disable|start|stop)', '\bapt(-get)?\b', '\bdnf\b', '\byum\b',
  'Invoke-WebRequest', 'Invoke-RestMethod', '\bcurl\b', '\bwget\b', 'Start-BitsTransfer', 'New-NetFirewallRule')
foreach ($f in @('lanq-ready.ps1', 'lanq-ready.sh')) {
  $text = Get-Content -LiteralPath (Join-Path $root $f) -Raw
  $isPs = $f.EndsWith('.ps1')
  $b = if ($isPs) { '#region ADVICE' } else { '# BEGIN ADVICE' }; $e = if ($isPs) { '#endregion ADVICE' } else { '# END ADVICE' }
  Assert-Equal ([regex]::Matches($text, [regex]::Escape($b)).Count) 1 "$f has exactly one advice-table start marker"
  $i = $text.IndexOf($b); $j = $text.IndexOf($e)
  Assert-True ($i -ge 0 -and $j -gt $i) "$f advice-table markers are ordered"
  $code = $text.Substring(0, $i) + $text.Substring($j + $e.Length)
  $hits = @(); foreach ($p in $patterns) { foreach ($m2 in [regex]::Matches($code, $p)) { $hits += "$p -> '$($m2.Value)'" } }
  Assert-Equal ($hits -join '; ') '' "${f}: no mutating command outside advice table"
  Assert-True (-not ($text -match '[^\x00-\x7F]')) "$f is pure ASCII"
  Assert-True (@(Get-Content -LiteralPath (Join-Path $root $f)).Count -le 700) "$f is at most 700 lines"
}
Assert-True ((Get-Content -LiteralPath (Join-Path $root 'schema/report.v1.json') -Raw | ConvertFrom-Json).title) 'schema parses as JSON'

if (-not $SkipSmoke) {
  Write-Host 'smoke: real run, non-elevated, -Json -Redact'
  $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  Assert-True (-not $isAdmin) 'smoke runs non-elevated'
  $out = Join-Path ([IO.Path]::GetTempPath()) ("lanq-ready-smoke-" + [Guid]::NewGuid().ToString('N') + '.json')
  $console = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'lanq-ready.ps1') -Json $out -Redact -Hours 00:00-07:00 | Out-String
  $code = $LASTEXITCODE
  Assert-True (@(0, 1) -contains $code) "smoke: exit code in {0,1} (got $code)"
  Assert-True (Test-Path -LiteralPath $out) 'smoke: JSON written'
  $raw = Get-Content -LiteralPath $out -Raw; $j = $raw | ConvertFrom-Json
  Assert-Equal $j.schema 'lanq-ready/v1' 'smoke: schema id'
  foreach ($k in 'tool', 'generatedAt', 'host', 'verdicts', 'checks', 'capabilities', 'suggestedMachine') { Assert-True ($null -ne $j.PSObject.Properties[$k]) "smoke: key $k" }
  foreach ($k in 'worker_git', 'worker_archive', 'dotnet10', 'docker', 'overnight') { Assert-True (@('OK', 'WARN', 'FAIL', 'SKIP') -contains $j.verdicts.$k) "smoke: verdict $k valid" }
  Assert-True (@($j.checks).Count -ge 15) 'smoke: has checks'
  Assert-Equal $j.host.hostname '<redacted>' 'smoke: hostname redacted'
  $tok = { param($v) '(?<![A-Za-z0-9])' + [regex]::Escape($v) + '(?![A-Za-z0-9])' }
  Assert-True (($raw -notmatch (& $tok $env:COMPUTERNAME)) -and ($console -notmatch (& $tok $env:COMPUTERNAME)) -and ($console -notmatch (& $tok $env:USERNAME)) -and ($raw -notmatch (& $tok $env:USERNAME))) 'smoke: no hostname/user in output'
  $r2 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'lanq-ready.ps1') -Hours 07:00-07:00 | Out-String
  Assert-Equal $LASTEXITCODE 2 'equal -Hours start/end: exit code 2'
  [IO.File]::Delete($out)
}
Write-Host ("`nPowerShell tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
