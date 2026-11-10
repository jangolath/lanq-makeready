# Self-contained test runner (no Pester). Works on Windows PowerShell 5.1 and pwsh 7.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1 [-SkipSmoke]
param([switch]$SkipSmoke)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function Assert-Equal($Actual, $Expected, [string]$Name) {
  if ("$Actual" -ceq "$Expected") { $script:pass++; Write-Host "  ok   $Name" }
  else { $script:fail++; Write-Host "  FAIL $Name : expected '$Expected' got '$Actual'" -ForegroundColor Red }
}
function Assert-True($Cond, [string]$Name) { Assert-Equal ([bool]$Cond) 'True' $Name }

$env:LANQ_MAKEREADY_LIB = '1'
. (Join-Path $root 'lanq-makeready.ps1')
Remove-Item Env:\LANQ_MAKEREADY_LIB

function New-Facts([hashtable]$Over = @{}) {
  $f = @{ Hostname = 'box'; User = 'builder'; Profile = 'C:\Users\builder'; Caption = 'Windows 11 Pro'; Build = 26100; IsServer = $false
    EditionId = 'Professional'; Is64 = $true; IsArm = $false; Arch = 'x64'; CpuName = 'Test CPU'; Cores = 2; Logical = 4; Avx2 = 'True'
    RamGB = 16; FreeRamGB = 8; SysFreeGB = 200; WorkFreeGB = 200; DiskMedia = 'SSD'; WorkDrive = 'C:'
    SshdInstalled = $true; SshdRunning = $true; SshdStartType = 'Automatic'; SshFwRule = 'enabled'; SshFwPort = $null; IsAdminUser = $false; AuthKeysNonEmpty = $true
    GitVer = 'git version 2.45.0'; GitLongPaths = $true; TarBsd = $true; LongPaths = $true; DotnetSdks = @(10)
    DockerCli = $true; DockerServerOk = $true; DockerServer = '27.0'; WslOk = $true; Tools = @{ node = 'v22.1.0' }
    StandbyAcSec = 0; HibernateAcSec = 0; RebootPending = $false; StartupCount = 5; StartupNames = @()
    WolProbe = $true; WolWifi = $false; WolNic = 'Ethernet'; WolMac = '10:20:30:aa:bb:cc'; WolMagic = 'Enabled'; WolArmed = $true; FastStartup = $false; SwapMB = 4096
    TempSizes = @(); DefenderRtp = $false; DevDrive = $true; ProblemDevices = @(); Hours = $null }
  foreach ($k in $Over.Keys) { $f[$k] = $Over[$k] }
  return $f
}
function Run($F) { $c = Get-Checks $F; $v = Get-Verdicts $c $F; return @{ C = $c; V = $v; M = (Get-Machine $F $v $F.Hours $false); S = (Get-Summary $c $v $F) } }
function New-RedFacts($H, $U) {
  New-Facts @{ Hostname = $H; User = $U; Profile = "C:\Users\$U"; Caption = "Windows $H ($U)"; CpuName = "cpu of $H"; GitVer = "git version 2.45 C:\Users\$U\git"
    DefaultShell = "C:\Users\$U\sh.exe"; StartupNames = @("$H-agent", 'OneDrive'); ProblemDevices = @("dev $U"); Tools = @{ node = "v22 $U" } }
}
function Get-JsonFor($F, $Redact) {
  if ($Redact) { $F = Protect-Facts $F }
  $c = Get-Checks $F; $v = Get-Verdicts $c $F; $m = Get-Machine $F $v $null ([bool]$Redact)
  ConvertTo-AsciiJson (New-Report $F $c $v $m '0.1.0')
}
function StepIds($R) { (@($R.S.nextSteps) | ForEach-Object { $_.id }) -join ' ' }
function St($R, [string]$Id) { ($R.C | Where-Object { $_.id -eq $Id }).status }
function Ck($R, [string]$Id) { $R.C | Where-Object { $_.id -eq $Id } }

Write-Host 'verdicts: Windows 11, 16 GB, SSD, all good'
$r = Run (New-Facts)
foreach ($k in 'worker_git', 'worker_archive', 'dotnet10', 'docker', 'overnight') { Assert-Equal $r.V[$k] 'OK' "good: $k" }
Assert-Equal $r.M.max_jobs 3 'good: 16 GB, 4 threads -> max_jobs 3 (16 GB tier)'
Assert-Equal (Run (New-Facts @{ Logical = 16 })).M.max_jobs 4 'good: 16 threads + 16 GB -> max_jobs 4 (16 GB tier)'

Write-Host 'verdicts: consumer Windows 10 22H2, 4 GB, HDD, no sshd'
$r = Run (New-Facts @{ Caption = 'Windows 10 Home'; Build = 19045; EditionId = 'Core'; RamGB = 3; DiskMedia = 'HDD'; SshdInstalled = $false; SshdRunning = $null
  DockerCli = $false; DockerServerOk = $false; VirtFirmware = $true; WslOk = $false; AuthKeysNonEmpty = $false })
Assert-Equal $r.V.worker_git 'FAIL' 'win10: worker_git FAIL (no sshd)'
Assert-Equal $r.V.worker_archive 'FAIL' 'win10: worker_archive FAIL (no sshd)'
Assert-Equal (St $r 'ssh.server') 'FAIL' 'win10: ssh.server FAIL'
Assert-Equal (St $r 'os.version') 'WARN' 'win10: os.version WARN (EOL)'
Assert-Equal $r.V.dotnet10 'WARN' 'win10: .NET 10 WARN (not on supported list)'
Assert-Equal (St $r 'disk') 'WARN' 'win10: HDD -> disk WARN'
Assert-Equal (St $r 'ram') 'WARN' 'win10: 3 GB -> ram WARN'
Assert-Equal $r.V.docker 'WARN' 'win10: docker WARN (under 4 GB)'
Assert-True ((Ck $r 'ssh.server').advice -match 'Add-WindowsCapability') 'win10: ssh advice is the printed install command'

Write-Host 'verdicts: 32-bit Windows'
$r = Run (New-Facts @{ Is64 = $false; Arch = 'x86'; Build = 19045; DockerCli = $false; DockerServerOk = $false; DotnetSdks = @() })
Assert-Equal (St $r 'os.arch') 'WARN' '32-bit Windows: os.arch WARN'
Assert-Equal $r.V.dotnet10 'WARN' '32-bit Windows: .NET 10 WARN (x86 is on the published list)'
Assert-True ((Ck $r 'os.arch').advice -match 'supports 32-bit') '32-bit Windows: advice does not claim .NET 10 cannot run'
Assert-Equal $r.V.docker 'FAIL' '32-bit: docker FAIL'

Write-Host 'verdicts: no git but bsdtar -> archive transfer'
$r = Run (New-Facts @{ GitVer = $null })
Assert-Equal $r.V.worker_git 'FAIL' 'no git: worker_git FAIL'
Assert-Equal $r.V.worker_archive 'OK' 'no git: worker_archive OK'
Assert-Equal $r.M.transfer 'archive' 'no git: suggested transfer archive'
Assert-True ((Format-Snippet $r.M $r.V (New-Facts @{ GitVer = $null })) -contains '    transfer: archive') 'no git: snippet says transfer: archive'
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

Write-Host 'verdict line and next steps'
$r = Run (New-Facts)
Assert-Equal $r.S.text 'READY' 'all good: READY'
Assert-Equal @($r.S.nextSteps).Count 0 'all good: no next steps'
$r = Run (New-Facts @{ RebootPending = $true; LongPaths = $false })
Assert-Equal $r.S.text 'READY WITH WARNINGS (2)' 'two warnings: READY WITH WARNINGS (2)'
$r = Run (New-Facts @{ SshdInstalled = $false; SshdRunning = $null; RebootPending = $true })
Assert-Equal $r.S.text 'NOT READY (1 blocker)' 'no sshd: NOT READY (1 blocker)'
Assert-Equal (StepIds $r) 'ssh.server reboot.pending' 'blocker first, then warnings'
$fs = (Format-Steps $r.S) -join "`n"
Assert-True ($fs -match ' 1\. \[MUST FIX\] OpenSSH Server: not installed') 'step 1 is MUST FIX'
Assert-True ($fs -match 'do \(needs admin: elevated PowerShell\): Install OpenSSH Server yourself') 'step names the command and that it needs admin'
Assert-True ($fs -match ' 2\. \[should fix\] Pending reboot' -and $fs -match 'do \(no admin needed\)') 'warning step: should fix, no admin'
Assert-Equal (Run (New-Facts @{ SshdInstalled = $false; SshdRunning = $null; SysFreeGB = 5 })).S.text 'NOT READY (2 blockers)' 'two FAILs: 2 blockers'
$r = Run (New-Facts @{ GitVer = $null; TarBsd = $false })
Assert-Equal $r.S.text 'NOT READY (2 blockers)' 'no git and no tar: both are blockers'
$r = Run (New-Facts @{ GitVer = $null; SshdInstalled = $false; SshdRunning = $null })
Assert-Equal (StepIds $r) 'ssh.server git' 'no sshd, no git but tar ok: git stays a warning'
Assert-Equal $r.S.blockers 1 'no sshd, no git but tar ok: 1 blocker'
Assert-Equal (Run (New-Facts @{ Is64 = $false; Arch = 'x86'; DockerCli = $false; DockerServerOk = $false })).S.verdict 'READY_WITH_WARNINGS' 'a Docker FAIL does not block the worker'
$j = ConvertTo-AsciiJson (New-Report (New-Facts) $r.C $r.V $r.M '0.2.0' $r.S) | ConvertFrom-Json
Assert-Equal $j.summary.verdict 'NOT_READY' 'JSON summary.verdict'
Assert-Equal $j.summary.nextSteps[0].id 'ssh.server' 'JSON first next step'
Assert-True ($j.summary.nextSteps[0].blocker -is [bool] -and $j.summary.nextSteps[0].adminToFix -eq $true) 'JSON step: blocker and adminToFix are booleans'

Write-Host 'Windows 10 specifics'
$r = Run (New-Facts @{ Caption = 'Windows 10 Pro'; Build = 19045 })
Assert-True ((Ck $r 'os.version').detail -match 'past end of support \(2025-10-14\)') 'Win10 22H2: end-of-support note'
Assert-True ((Ck $r 'os.version').advice -match '22H2 \(build 19045\) is the last version' -and (Ck $r 'os.version').advice -match 'ESU') 'Win10 advice: 22H2 last, ESU'
Assert-True ((Ck $r 'os.version').advice -match 'Settings > Windows Update > Enroll now') 'Win10 advice: how to enroll in ESU'
Assert-True ((Ck (Run (New-Facts @{ Caption = 'Windows 10 Pro'; Build = 19044 })) 'os.version').detail -match 'not on 22H2') 'Win10 21H2: says not on 22H2'
Assert-Equal (St (Run (New-Facts @{ SshdStartType = 'Manual' })) 'ssh.server') 'WARN' 'sshd Manual start: WARN'
$r = Run (New-Facts @{ SshdRunning = $null })
Assert-True ((St $r 'ssh.server') -eq 'SKIP' -and (Ck $r 'ssh.server').detail -match 'cannot read the service status' -and $r.V.worker_git -eq 'OK') 'sshd status unreadable (not over ssh): SKIP, not FAIL; the worker verdict is unchanged'
Assert-Equal (St (Run (New-Facts @{ SshdRunning = $false })) 'ssh.server') 'FAIL' 'sshd readable and stopped: still FAIL'
Assert-Equal (St (Run (New-Facts @{ SshFwRule = 'enabled' })) 'ssh.firewall') 'OK' 'firewall: named rule enabled -> OK'
$r = Run (New-Facts @{ SshFwRule = 'disabled' })
Assert-True ((St $r 'ssh.firewall') -eq 'WARN' -and -not (Ck $r 'ssh.firewall').needsAdmin) 'firewall: named rule disabled -> WARN from Get-NetFirewallRule alone (no admin needed)'
Assert-Equal $r.V.worker_git 'WARN' 'firewall: disabled rule -> worker verdict WARN'
Assert-Equal (St (Run (New-Facts @{ SshFwRule = 'missing'; SshFwPort = $true })) 'ssh.firewall') 'OK' 'firewall: rule missing, another rule allows 22 -> OK'
Assert-Equal (St (Run (New-Facts @{ SshFwRule = 'missing'; SshFwPort = $false })) 'ssh.firewall') 'WARN' 'firewall: rule missing, nothing allows 22 -> WARN'
$r = Run (New-Facts @{ SshFwRule = 'missing'; SshFwPort = 'denied' })
Assert-True ((St $r 'ssh.firewall') -eq 'SKIP' -and (Ck $r 'ssh.firewall').needsAdmin) 'firewall: rule missing, port scan denied -> SKIP needs admin'
Assert-Equal (St (Run (New-Facts @{ SshFwRule = $null })) 'ssh.firewall') 'SKIP' 'firewall: rules unreadable -> SKIP'
Assert-Equal (St (Run (New-Facts @{ SshdStartType = 'Manual'; SshFwRule = 'disabled' })) 'ssh.firewall') 'WARN' 'manual start AND firewall both reported'
$fa = $Advice['ssh.fw']
Assert-True ($fa -match 'Get-NetConnectionProfile' -and $fa -match 'Set-NetConnectionProfile' -and $fa -match '-NetworkCategory Private' -and $fa -match 'Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -Profile Private -RemoteAddress LocalSubnet') 'ssh.fw hint: Private network, LocalSubnet, like the LanQueue quickstart'
Assert-Equal (St (Run (New-Facts @{ DefaultShell = $null })) 'ssh.shell') 'OK' 'default shell unset (cmd.exe): OK'
Assert-Equal (St (Run (New-Facts @{ DefaultShell = 'C:\Windows\System32\WindowsPowerShell1.0\powershell.exe' })) 'ssh.shell') 'OK' 'powershell.exe default shell: OK'
Assert-Equal (St (Run (New-Facts @{ DefaultShell = 'C:\Program Files\PowerShell\pwsh.exe' })) 'ssh.shell') 'OK' 'pwsh.exe default shell: OK'
$r = Run (New-Facts @{ DefaultShell = 'C:\Program Files\Gitinash.exe' })
Assert-Equal (St $r 'ssh.shell') 'WARN' 'bash.exe default shell: WARN'
Assert-True ((Ck $r 'ssh.shell').advice -match [regex]::Escape('Remove-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell')) 'shell advice: exact command'

Write-Host 'Wake-on-LAN (Windows)'
$na = @('Wi-Fi|Intel(R) Wi-Fi 6 AX201|10-20-30-00-00-01|Native 802.11|Up', 'vEthernet|Hyper-V Virtual Ethernet Adapter|10-20-30-00-00-02|802.3|Up',
  'Ethernet 2|Realtek USB GbE|10-20-30-00-00-03|802.3|Disconnected', 'Ethernet|Intel(R) Ethernet I219-V|10-20-30-AA-BB-CC|802.3|Up')
$sel = Select-WiredNic $na
Assert-Equal $sel.Nic.Name 'Ethernet' 'wired NIC: physical 802.3, Up first, virtual skipped'
Assert-Equal $sel.Nic.Mac '10:20:30:aa:bb:cc' 'MAC normalised to aa:bb:.. lower case'
Assert-True ($sel.Wifi) 'Wi-Fi seen'
Assert-True ($null -eq (Select-WiredNic @('Wi-Fi|Intel Wireless|10-20-30-00-00-01|Native 802.11|Up')).Nic) 'Wi-Fi only: no wired NIC'
Assert-True (Test-WakeArmed "HID Keyboard Device`r`nIntel(R) Ethernet I219-V`r`n" 'Intel(R) Ethernet I219-V') 'wake_armed lists the adapter'
Assert-True (-not (Test-WakeArmed "NONE`r`n" 'Intel(R) Ethernet I219-V')) 'wake_armed NONE: not armed'
$r = Run (New-Facts)
Assert-Equal (St $r 'wol') 'OK' 'magic packet on, armed, Fast Startup off: OK'
$sn = (Format-Snippet $r.M $r.V (New-Facts)) -join "`n"
Assert-True ($sn -match "(?m)^    wake:" -and $sn -match 'mac: "10:20:30:aa:bb:cc"') 'snippet: active wake block with the MAC'
$r = Run (New-Facts @{ FastStartup = $true })
Assert-Equal (St $r 'wol') 'WARN' 'Fast Startup on: WARN'
Assert-True ((Ck $r 'wol').advice -match 'untick "Turn on fast startup"') 'Fast Startup advice: GUI path'
$sn = (Format-Snippet $r.M $r.V (New-Facts @{ FastStartup = $true })) -join "`n"
Assert-True ($sn -match '(?m)^    # wake:' -and $sn -notmatch '(?m)^    wake:') 'snippet: wake commented out when not ready'
$r = Run (New-Facts @{ WolMagic = 'Disabled' })
Assert-True ((St $r 'wol') -eq 'WARN' -and (Ck $r 'wol').advice -match 'Wake on Magic Packet" to Enabled' -and (Ck $r 'wol').adminToFix) 'magic packet off: WARN, Device Manager path, needs admin'
Assert-Equal (St (Run (New-Facts @{ WolArmed = $false })) 'wol') 'WARN' 'not allowed to wake the PC: WARN'
$r = Run (New-Facts @{ WolMagic = $null })
Assert-True ((St $r 'wol') -eq 'SKIP' -and (Ck $r 'wol').needsAdmin -and (Ck $r 'wol').detail -match '10:20:30:aa:bb:cc') 'unreadable without admin: SKIP, MAC still shown'
$r = Run (New-Facts @{ WolMac = $null; WolNic = $null; WolWifi = $true })
Assert-True ((St $r 'wol') -eq 'WARN' -and (Ck $r 'wol').detail -match 'Wi-Fi only') 'Wi-Fi only: WARN'
Assert-True (Test-FastStartup 1 1 $null) 'Fast Startup: HiberbootEnabled=1, HibernateEnabled=1 -> on'
Assert-True (-not (Test-FastStartup 1 0 $null)) 'Fast Startup: HibernateEnabled=0 -> not effective'
Assert-True (-not (Test-FastStartup 1 0 1)) 'Fast Startup: HibernateEnabled=0 overrides HibernateEnabledDefault=1'
Assert-True (Test-FastStartup 1 $null 1) 'Fast Startup: HibernateEnabled missing, HibernateEnabledDefault=1 -> on'
Assert-True (-not (Test-FastStartup 1 $null 0)) 'Fast Startup: HibernateEnabled missing, HibernateEnabledDefault=0 -> off'
Assert-True (Test-FastStartup 1 $null $null) 'Fast Startup: both hibernation values missing -> treated as on'
Assert-True (-not (Test-FastStartup 0 $null $null)) 'Fast Startup: HiberbootEnabled=0 -> off'
Assert-True (-not (Test-FastStartup $null 1 1)) 'Fast Startup: HiberbootEnabled missing -> off'
$ps1txt = Get-Content -LiteralPath (Join-Path $root 'lanq-makeready.ps1') -Raw
Assert-True ($ps1txt -match [regex]::Escape("'HKLM:\SYSTEM\CurrentControlSet\Control\Power'") -and $ps1txt -match 'HibernateEnabledDefault') 'Fast Startup: HibernateEnabled and HibernateEnabledDefault are read from Control\Power'
$fr = Protect-Facts (New-Facts); $rr = Run $fr
$sn = (Format-Snippet $rr.M $rr.V $fr) -join "`n"
Assert-True ($sn -match '(?m)^    #   mac: "<mac>"' -and $sn -notmatch '(?m)^    wake:' -and $sn -match 'placeholder') 'redacted snippet: <mac> commented out, said to be a placeholder'
$p = Protect-Facts (New-Facts)
Assert-Equal $p.WolMac '<mac>' 'redaction hides the MAC'

Write-Host 'low RAM, page file, disk'
$r = Run (New-Facts @{ RamGB = 4; SwapMB = 0 })
Assert-True ((St $r 'swap') -eq 'WARN' -and (Ck $r 'swap').advice -match 'SystemPropertiesAdvanced') '4 GB, no page file: WARN with the GUI path'
Assert-Equal (St (Run (New-Facts @{ SwapMB = 0 })) 'swap') 'OK' '16 GB without page file: OK'
Assert-Equal (St (Run (New-Facts @{ SwapMB = $null })) 'swap') 'SKIP' 'page file unreadable: SKIP'
$f3 = New-Facts @{ RamGB = 3; Logical = 4 }; $r = Run $f3
$sn = (Format-Snippet $r.M $r.V $f3) -join "`n"
Assert-True ($sn -match 'max_jobs: 1 ' -and $sn -match 'min_free_mem_gb: 1.5' -and $sn -match '# Low-RAM PC: keep max_jobs: 1' -and $sn -match '#   NODE_OPTIONS') '3 GB: max_jobs 1, hold 1.5, note, env caps'
Assert-True ((Ck $r 'ram').advice -match 'min_free_mem_gb') 'ram advice names the hold setting'
Assert-True ($sn -match 'add -m:1 to dotnet build' -and (Get-Content -LiteralPath (Join-Path $root 'lanq-makeready.ps1') -Raw) -notmatch 'MSBUILDNODECOUNT') '3 GB: -m:1 comment; MSBUILDNODECOUNT never suggested'
$acl = @($Advice.Values | Where-Object { $_ -match 'icacls' })
Assert-True ($acl.Count -ge 1 -and @($acl | Where-Object { $_ -match '/grant "[^*]' }).Count -eq 0 -and $acl[0] -match '\*S-1-5-18:F') 'every icacls hint grants by SID (Administrators and SYSTEM)'
Assert-True ($Advice['ssh.nokeys'] -match 'Add-LocalGroupMember -SID S-1-5-32-545' -and $Advice['ssh.nokeys'] -match 'log on once') 'build-user hint: Users by SID, log on once before .ssh'
$r = Run (New-Facts @{ SysFreeGB = 15; WorkFreeGB = 15 })
Assert-True ((Ck $r 'disk').detail -match '15 GB free' -and (Ck $r 'disk').detail -match 'recommended: at least 20 GB free') 'low disk: free space and recommended minimum'

Write-Host 'pool sizing tiers (the thresholds LanQueue 0.5.1+ lanq health uses)'
Assert-Equal (Get-SuggestedJobs 24 8) 6 '24-31 GB counts as the top band'
foreach ($t in @(@(4, 4, 1), @(8, 8, 2), @(8, 1, 1), @(16, 4, 3), @(16, 8, 4), @(16, 2, 2), @(32, 12, 6), @(64, 32, 8), @(32, 4, 4))) {
  Assert-Equal (Get-SuggestedJobs $t[0] $t[1]) $t[2] "$($t[0]) GB, $($t[1]) CPUs: max_jobs $($t[2])"
}
Assert-Equal (Get-SuggestedMinMem 4) 1.5 'under 6 GB: min_free_mem_gb 1.5'
Assert-Equal (Get-SuggestedMinMem 16) 2 '6 GB+: min_free_mem_gb 2'
Assert-Equal (Get-SuitedTier 4 4) 'light' '4 GB: light'
Assert-Equal (Get-SuitedTier 8 8) 'medium' '8 GB: medium'
Assert-Equal (Get-SuitedTier 16 2) 'medium' '16 GB, 2 CPUs: medium'
Assert-Equal (Get-SuitedTier 16 4) 'heavy' '16 GB, 4 CPUs: heavy'
Assert-Equal (Get-SuitedText 'light' $false) 'light: lint and unit-test shards' 'light text'
Assert-Equal (Get-SuitedText 'medium' $false) 'medium: test shards and builds' 'medium text'
Assert-Equal (Get-SuitedText 'heavy' $true) 'heavy: full suites and large builds + container builds' 'heavy + docker text'
$f = New-Facts @{ Logical = 8 }; $r = Run $f
$j = ConvertTo-AsciiJson (New-Report $f $r.C $r.V $r.M '0.2.0' $r.S) | ConvertFrom-Json
Assert-Equal $j.suitedFor.tier 'heavy' 'JSON suitedFor.tier'
Assert-Equal $j.suitedFor.containers $true 'JSON suitedFor.containers'
Assert-Equal $j.suggestedMachine.min_free_mem_gb 2 'JSON min_free_mem_gb'
Assert-Equal $j.suggestedMachine.wake.mac '10:20:30:aa:bb:cc' 'JSON wake.mac when ready'
Assert-True ($r.M.capabilities -contains 'git') 'git is a detected capability'

Write-Host 'snippet keys are valid LanQueue 0.5 keys'
$f = New-Facts; $r = Run $f
$keys = @((Format-Snippet $r.M $r.V $f) | ForEach-Object { if ($_ -match '^[\s-]*([a-z_]+):') { $Matches[1] } } | Sort-Object -Unique) -join ' '
Assert-Equal $keys 'capabilities mac machines max_jobs min_free_mem_gb name os ssh transfer wake work_root' 'only known keys (uncommented)'
Assert-True (((Format-Snippet $r.M $r.V $f) -join "`n") -match '# allowed_hours: "22:00-07:00"') 'allowed_hours is a commented placeholder without -Hours'

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
$m = Get-Machine (New-Facts @{ Hours = '22:00-07:00' }) $null '22:00-07:00' $true
Assert-Equal $m.name 'old-pc' 'redacted snippet name'
$sn = (Format-Snippet $m (Run (New-Facts)).V (New-Facts)) -join "`n"
Assert-True ($sn -match 'allowed_hours: "22:00-07:00"') 'snippet: allowed_hours quoted HH:mm-HH:mm'
Assert-True ($sn -match 'os: windows' -and $sn -notmatch 'builder') 'snippet: os windows, no user name when redacted'

function Hide-Leak($Text, $Token) { $Text -match ('(?<![A-Za-z0-9_])' + [regex]::Escape($Token) + '(?![A-Za-z0-9_])') }

Write-Host 'review fixes: admin SID, RAM, .NET/Docker version lists, work drive, names'
Assert-True (Test-AdminSid @('S-1-5-32-545') @('S-1-5-32-544')) 'non-elevated admin: deny-only S-1-5-32-544 counts'
Assert-True (Test-AdminSid @('S-1-5-32-544') @()) 'elevated admin: group S-1-5-32-544 counts'
Assert-True (-not (Test-AdminSid @('S-1-5-32-545') @('S-1-5-32-546'))) 'standard user is not an admin'
Assert-Equal (St (Run (New-Facts @{ RamGB = 4 })) 'ram') 'OK' 'installed 4 GB is not flagged low (usable RAM is not what we compare)'
Assert-Equal (Run (New-Facts @{ DockerCli = $false; DockerServerOk = $false; RamGB = 8; HypervisorPresent = $true })).V.docker 'OK' 'installed 8 GB: Docker Desktop RAM check passes'
$mk = { param($b, $ed, $srv = $false) Run (New-Facts @{ Build = $b; EditionId = $ed; IsServer = $srv; Caption = 'Windows' }) }
Assert-Equal (& $mk 26100 'Professional').V.dotnet10 'OK' '.NET: Windows 11 24H2 OK'
Assert-Equal (& $mk 26200 'Core').V.dotnet10 'OK' '.NET: Windows 11 25H2 OK'
Assert-Equal (& $mk 22631 'Professional').V.dotnet10 'WARN' '.NET: Windows 11 23H2 Pro is not on the published list'
Assert-Equal (& $mk 22631 'Enterprise').V.dotnet10 'OK' '.NET: Windows 11 23H2 Enterprise is listed'
Assert-Equal (& $mk 22621 'Enterprise').V.dotnet10 'WARN' '.NET: Windows 11 22H2 is not listed'
Assert-Equal (& $mk 22000 'Professional').V.dotnet10 'WARN' '.NET: Windows 11 21H2 is not listed'
Assert-Equal (& $mk 19044 'Enterprise').V.dotnet10 'OK' '.NET: Windows 10 21H2 Enterprise is listed'
Assert-Equal (& $mk 19044 'Education').V.dotnet10 'WARN' '.NET: Education is not treated as LTSC/Enterprise'
Assert-Equal (& $mk 19045 'Enterprise').V.dotnet10 'WARN' '.NET: Windows 10 22H2 is not listed even for Enterprise'
Assert-Equal (& $mk 9600 'ServerStandard' $true).V.dotnet10 'WARN' '.NET: Server 2012 R2 only with ESU -> WARN'
Assert-Equal (& $mk 17763 'ServerStandard' $true).V.dotnet10 'OK' '.NET: Server 2019 OK'
$nd = @{ DockerCli = $false; DockerServerOk = $false; HypervisorPresent = $true }
Assert-Equal (Run (New-Facts ($nd + @{ Build = 22621 }))).V.docker 'WARN' 'Docker Desktop: Windows 11 22H2 is below the 23H2 floor -> WARN (usually runs)'
Assert-True ((Ck (Run (New-Facts ($nd + @{ Build = 22621 }))) 'docker').detail -match 'usually runs') 'Docker Desktop: old-Windows-11 detail says it usually runs'
Assert-Equal (Run (New-Facts ($nd + @{ Build = 19044 }))).V.docker 'WARN' 'Docker Desktop: Windows 10 below 22H2 -> WARN, same handling'
Assert-Equal (Run (New-Facts ($nd + @{ Build = 19041 }))).V.docker 'WARN' 'Docker Desktop: Windows 10 2004 (19041) has WSL 2 -> WARN'
Assert-Equal (Run (New-Facts ($nd + @{ Build = 19040 }))).V.docker 'FAIL' 'Docker Desktop: Windows 10 before 2004 has no WSL 2 -> FAIL'
Assert-Equal (Run (New-Facts ($nd + @{ Build = 9600 }))).V.docker 'FAIL' 'Docker Desktop: Windows 8.1 -> FAIL'
Assert-Equal (Run (New-Facts ($nd + @{ Build = 7601 }))).V.docker 'FAIL' 'Docker Desktop: Windows 7 -> FAIL'
Assert-Equal (Run (New-Facts ($nd + @{ Build = 26100; WslOk = $null }))).V.docker 'SKIP' 'Docker prerequisites: WSL state undeterminable -> SKIP, not WARN'
Assert-Equal (Run (New-Facts ($nd + @{ Build = 22631 }))).V.docker 'OK' 'Docker Desktop: Windows 11 23H2 meets the floor'
Assert-Equal (Run (New-Facts ($nd + @{ IsServer = $true; Build = 20348 }))).V.docker 'WARN' 'Docker Desktop: not available on Windows Server -> WARN'
Assert-Equal (Run (New-Facts @{ DockerCli = $true; DockerServerOk = $false; DockerRemote = $true })).V.docker 'SKIP' 'remote docker endpoint: SKIP'
Assert-True (Test-DockerRemote 'tcp://10.0.0.5:2375' '') 'docker: tcp:// host is remote'
Assert-True (Test-DockerRemote 'ssh://u@h' '') 'docker: ssh:// host is remote'
Assert-True (Test-DockerRemote '' 'staging') 'docker: custom context is remote'
Assert-True (-not (Test-DockerRemote 'npipe:////./pipe/docker_engine' 'desktop-linux')) 'docker: Docker Desktop pipe/context is local'
Assert-True (-not (Test-DockerRemote '' '')) 'docker: no host, no context is local'
Assert-True (Test-Sdk8 @(6, 10)) 'dotnet capability: SDK 10 present'
Assert-True (-not (Test-Sdk8 @(5, 6, 7))) 'dotnet capability: SDKs below 8 only -> no capability'
Assert-True (-not ((Run (New-Facts @{ DotnetSdks = @(6) })).M.capabilities -contains 'dotnet')) 'machine: SDK 6 only -> no dotnet capability'

Write-Host '.NET SDK outside PATH'
$r = Run (New-Facts)
Assert-True ((St $r 'dotnet') -eq 'OK' -and -not $r.M.Contains('path_prepend') -and -not $r.M.Contains('env')) 'SDK on PATH: OK, no path_prepend or env'
$fo = New-Facts @{ DotnetSdks = @(6, 10); DotnetDir = 'D:/build/dotnet'; DotnetOffPath = $true }; $r = Run $fo
Assert-True ((St $r 'dotnet') -eq 'WARN' -and (Ck $r 'dotnet').advice -match 'path_prepend' -and (Ck $r 'dotnet').detail -match 'newest is in D:/build/dotnet, not the dotnet on PATH') 'SDK off PATH: WARN naming the folder, advice names path_prepend'
Assert-True (-not (Ck $r 'dotnet').adminToFix -and $r.V.worker_git -eq 'OK') 'SDK off PATH: no admin needed, the worker verdict is unchanged'
Assert-True (@($r.M.path_prepend)[0] -eq 'D:/build/dotnet' -and $r.M.env.DOTNET_ROOT -eq 'D:/build/dotnet' -and $r.M.capabilities -contains 'dotnet') 'SDK off PATH: machine gets path_prepend, DOTNET_ROOT and the dotnet capability'
$sn = (Format-Snippet $r.M $r.V $fo) -join "`n"
Assert-True ($sn -match '(?m)^    path_prepend: \["D:/build/dotnet"\]' -and $sn -match '(?m)^    env:\n      DOTNET_ROOT: "D:/build/dotnet"$') 'SDK off PATH: snippet has path_prepend and env DOTNET_ROOT'
$fo3 = New-Facts @{ RamGB = 3; DotnetDir = 'D:/build/dotnet'; DotnetOffPath = $true }; $r3 = Run $fo3; $sn = (Format-Snippet $r3.M $r3.V $fo3) -join "`n"
Assert-True (([regex]::Matches($sn, '(?m)^\s*#?\s*env:')).Count -eq 1 -and $sn -match 'DOTNET_GCHeapHardLimitPercent') 'low RAM and SDK off PATH: one env: key, the caps stay as comments under it'
Assert-Equal ((Run (New-Facts @{ RamGB = 3; DotnetDir = 'D:/build/dotnet'; DotnetOffPath = $true })).C | Where-Object { $_.id -eq 'dotnet' }).advice $Advice['ram.low'] 'low RAM outranks the PATH hint on the dotnet check'
$j = Get-JsonFor (New-Facts @{ DotnetDir = 'C:/Users/o''brien/.dotnet'; DotnetOffPath = $true; User = "o'brien"; Profile = "C:\Users\o'brien" }) $true | ConvertFrom-Json
Assert-True ($j.suggestedMachine.path_prepend[0] -eq '<redacted>/.dotnet' -and $j.suggestedMachine.env.DOTNET_ROOT -eq '<redacted>/.dotnet') 'redacted JSON: the SDK folder hides the user name'
$j = Get-JsonFor $fo $false | ConvertFrom-Json
Assert-True ($j.suggestedMachine.path_prepend[0] -eq 'D:/build/dotnet' -and $j.suggestedMachine.env.DOTNET_ROOT -eq 'D:/build/dotnet') 'JSON: suggestedMachine carries path_prepend and env'
$raw = Get-JsonFor (New-Facts @{ DotnetDir = 'C:/Users/jsmith.CONTOSO/.dotnet'; DotnetOffPath = $true; User = 'jsmith'; Profile = 'C:\Users\jsmith.CONTOSO' }) $true
Assert-True (($raw | ConvertFrom-Json).suggestedMachine.path_prepend[0] -eq '<redacted>/.dotnet' -and $raw -notmatch 'CONTOSO' -and $raw -notmatch 'jsmith') 'redacted JSON: a profile folder not named after the user is hidden whole'
$fp = New-Facts @{ DotnetSdks = @(10); DotnetDir = 'C:/tools/dotnet'; DotnetOffPath = $true; DotnetOpen = $true }; $r = Run $fp
Assert-True ((St $r 'dotnet') -eq 'WARN' -and (Ck $r 'dotnet').detail -match 'other local users can write there, so it is not suggested') 'SDK in a folder others can write: WARN says why'
Assert-True (-not $r.M.Contains('path_prepend') -and -not $r.M.Contains('env')) 'SDK in a folder others can write: no path_prepend or env suggested'
Assert-True (((Format-Snippet $r.M $r.V $fp) -join "`n") -match '# path_prepend: not suggested: other local users can write to C:/tools/dotnet') 'SDK in a folder others can write: the snippet says so in a comment'

Write-Host 'Test-Sddl (who may change what a job runs)'
$me = 'S-1-5-21-1-2-3-1001'; $ti = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
Assert-True (Test-Sddl "O:${ti}G:${ti}D:PAI(A;OICIIO;GA;;;CO)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)(A;OICI;0x1200a9;;;AC)" 0 $me) 'Program Files layout (TrustedInstaller owner, Users read/execute): safe'
Assert-True (Test-Sddl "O:${me}G:${me}D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;$me)" 0 $me) 'a folder only this account, SYSTEM and Administrators may write: safe'
Assert-True (-not (Test-Sddl "O:${me}G:${me}" 0 $me)) 'no DACL part at all: not safe'
Assert-True (-not (Test-Sddl "O:${me}G:${me}D:NO_ACCESS_CONTROL" 0 $me)) 'NULL DACL: not safe'
Assert-True (-not (Test-Sddl "O:BAG:BAD:(A;;FA;;;BA)(A;;LCDT;;;AU)" 0 $me)) 'Authenticated Users may add subfolders and delete children (LC DT): not safe'
Assert-True (-not (Test-Sddl "O:BAG:BAD:(A;OICI;FA;;;BA)(A;OICI;FA;;;S-1-5-32-555)" 0 $me)) 'Remote Desktop Users full control (any group not trusted): not safe'
Assert-True (-not (Test-Sddl "O:BAG:BAD:(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;S-1-5-21-9-9-9-1002)" 0 $me)) 'another local user may modify: not safe'
Assert-True (-not (Test-Sddl "O:BAG:BAD:(A;OICIIO;GW;;;AU)" 0 $me)) 'an inherit-only write entry on the folder itself counts (its new children would get it)'
Assert-True (-not (Test-Sddl "O:BUG:BUD:(A;;FA;;;BA)" 0 $me)) 'owned by Users: not safe (the owner may rewrite the ACL)'
Assert-True (-not (Test-Sddl "O:BAG:BAD:(A;;FA;;;BA)(XA;;FA;;;WD;(x))" 0 $me)) 'a conditional (callback) Allow entry for Everyone: not safe'
Assert-True (Test-Sddl "O:BAG:BAD:(A;;FA;;;BA)(D;;FA;;;WD)" 0 $me) 'a Deny entry never makes a folder unsafe'
Assert-True (Test-Sddl "O:SYG:SYD:(A;;0x1301bf;;;AU)(A;OICIIO;SDGXGWGR;;;AU)(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;BU)" 2 $me) 'a drive root where Authenticated Users may create folders: a safe parent'
Assert-True (-not (Test-Sddl "O:BAG:BAD:(A;;FA;;;BA)(A;;0x1301ff;;;AU)" 1 $me)) 'a parent where Authenticated Users may delete children (0x40): not safe'
Assert-True (-not (Test-Sddl "O:BAG:BAD:(A;;FA;;;BA)(A;;SDRCWDWO;;;AU)" 1 $me)) 'a parent others may delete, re-permission or take: not safe'
Assert-True (Test-Sddl "O:BAG:BAD:(A;;FA;;;BA)(A;OICIIO;FA;;;AU)" 1 $me) 'on a parent, an entry that only passes down is judged on the children'
$adm = 'S-1-5-21-1-2-3-1002'
Assert-True (Test-Sddl "O:${me}G:${me}D:AI(A;OICIID;FA;;;BA)(A;OICIID;FA;;;SY)(A;OICIID;FA;;;$me)(A;OICIID;FA;;;$adm)" 0 @($me, $adm)) 'a member of the local Administrators group may write: safe'
Assert-True (-not (Test-Sddl "O:${me}G:${me}D:AI(A;OICIID;FA;;;BA)(A;OICIID;FA;;;$adm)" 0 @($me))) 'the same account when it is not an administrator: not safe'
Assert-True (-not (Test-Sddl "O:BAG:BAD:(A;;FA;;;BA)(A;;KA;;;BU)" 1 $me)) 'a parent where Users have KA (delete, re-permission, take): not safe'
Assert-True (Test-Sddl "O:BAG:BAD:(A;;FA;;;BA)(A;;LO;;;BU)" 0 $me) 'read attributes (LO) only: safe'
Assert-True (-not (Test-Sddl ('O:BAG:BAD:(A;;FA;;;BA)(XA;;FR;;;WD;(@User.x == "S:"))(A;;FA;;;BU)') 0 $me)) 'an S: inside a condition does not hide the entries after it'
Assert-True (-not (Test-Sddl "O:BAG:BAD:(A;;FA;;;BA)(A;;0xZZ;;;BU)" 0 $me)) 'unparsable rights: not safe'

Write-Host 'Test-SafeFolder (real ACLs)'
$sf = Join-Path ([System.IO.Path]::GetTempPath()) "lanq-safe-$PID"; [void](New-Item -ItemType Directory -Path $sf -Force); Set-Content -LiteralPath "$sf\dotnet.exe" -Value 'x'
& icacls.exe $sf /grant '*S-1-5-11:(OI)(CI)(M)' | Out-Null
Assert-True (-not (Test-SafeFolder $sf)) 'Authenticated Users with Modify: not safe'
Assert-True (-not (Test-SafeFolder "$sf\missing")) 'a folder that cannot be read: not safe'
Remove-Item -LiteralPath $sf -Recurse -Force
$pf = "$env:ProgramFiles\dotnet"
if (Test-Path -LiteralPath "$pf\dotnet.exe") {
  $lo = Join-Path $env:LOCALAPPDATA "lanq-open-$PID"
  foreach ($d in 'sdk\10.0.102', 'shared\Microsoft.AspNetCore.App\10.0.2', 'packs', 'sdk-manifests') { [void](New-Item -ItemType Directory -Force -Path (Join-Path $lo $d)) }
  Set-Content -LiteralPath "$lo\dotnet.exe" -Value 'x'
  & icacls.exe "$lo\shared\Microsoft.AspNetCore.App\10.0.2" /grant '*S-1-5-11:(OI)(CI)(M)' | Out-Null
  Assert-True (-not (Test-SafeFolder $lo '10.0.102')) 'a shared framework version folder others may modify: not safe'
  & icacls.exe "$lo\shared\Microsoft.AspNetCore.App\10.0.2" /remove:g '*S-1-5-11' | Out-Null; & icacls.exe "$lo\packs" /grant '*S-1-5-11:(OI)(CI)(M)' | Out-Null
  Assert-True (-not (Test-SafeFolder $lo '10.0.102')) 'packs others may modify: not safe'
  # a junction to a scratch folder (never to a real install): the link alone is removed with rmdir, never Remove-Item (which would
  # ask, or with -Recurse empty the target)
  $lk = Join-Path $env:LOCALAPPDATA "lanq-junction-$PID"
  [void](New-Item -ItemType Junction -Path $lk -Target $lo)
  Assert-True (-not (Test-SafeFolder $lk '10.0.102')) 'a junction is refused (its target''s parents are never judged)'
  & cmd.exe /c rmdir "$lk"
  Remove-Item -LiteralPath $lo -Recurse -Force
}
$pf = "$env:ProgramFiles\dotnet"
if (Test-Path -LiteralPath "$pf\dotnet.exe") { Assert-True (Test-SafeFolder $pf) 'Program Files\dotnet (installer default): safe' }

Write-Host 'AuthorizedKeysFile from sshd_config'
$cfgB = @('AuthorizedKeysFile .ssh/authorized_keys', 'Match User build*,!buildx', '       AuthorizedKeysFile __PROGRAMDATA__/ssh/%u_authorized_keys', 'Match all', 'AuthorizedKeysFile .ssh/keys_all', 'Match Group administrators', '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys')
$k = Get-KeyFiles $cfgB 'builder' $false 'C:\Users\builder.PC' 'C:\ProgramData'
Assert-True ($k.Via -eq 'match' -and @($k.Files) -join '|' -eq 'C:\ProgramData\ssh\builder_authorized_keys') 'Match User block: its file, %u and __PROGRAMDATA__ expanded'
$k = Get-KeyFiles $cfgB 'buildx' $false 'C:\Users\buildx' 'C:\ProgramData'
Assert-True ($k.Via -eq 'match' -and @($k.Files) -join '|' -eq 'C:\Users\buildx\.ssh\keys_all') 'a negated user skips that block; Match all applies; a relative file is under home'
$k = Get-KeyFiles $cfgB 'alice' $true 'C:\Users\alice' 'C:\ProgramData'
Assert-Equal (@($k.Files) -join '|') 'C:\Users\alice\.ssh\keys_all' 'the first matching block wins (Match all before Match Group administrators)'
$k = Get-KeyFiles @('AuthorizedKeysFile .ssh/authorized_keys', 'Match Group administrators', '  AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys') 'alice' $true 'C:\Users\alice' 'C:\ProgramData'
Assert-True ($k.Via -eq 'match' -and @($k.Files) -join '|' -eq 'C:\ProgramData\ssh\administrators_authorized_keys') 'Windows default config: an administrator gets administrators_authorized_keys'
$k = Get-KeyFiles @('AuthorizedKeysFile .ssh/authorized_keys', 'Match Group administrators', '  AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys') 'bob' $false 'C:\Users\bob' 'C:\ProgramData'
Assert-True ($k.Via -eq 'global' -and @($k.Files) -join '|' -eq 'C:\Users\bob\.ssh\authorized_keys') 'Windows default config: a standard user gets the global file'
$k = Get-KeyFiles @('Match Address 10.0.0.0/8', '  AuthorizedKeysFile /etc/x', 'Match all', '  AuthorizedKeysFile "%h/k1" none %%h') 'bob' $false 'C:\Users\bob' 'C:\ProgramData'
Assert-Equal (@($k.Files) -join '|') 'C:\Users\bob\k1|C:\Users\bob\%h' 'a criterion that cannot be judged is skipped; quotes, none and %% handled'
$k = Get-KeyFiles @('AuthorizedKeysFile=__PROGRAMDATA__/ssh/%u_keys \\fileserver\keys\%u //fileserver/k2') 'bob' $false 'C:\Users\bob' 'C:\ProgramData'
Assert-True ($k.Via -eq 'global' -and @($k.Files) -join '|' -eq 'C:\ProgramData\ssh\bob_keys') 'Key=value form read; files on a network share are never touched'
$k = Get-KeyFiles @('MATCH ALL', '  AuthorizedKeysFile x') 'bob' $false 'C:\Users\bob' 'C:\ProgramData'
Assert-Equal (@($k.Files) -join '|') 'C:\Users\bob\x' 'Match keywords are case-insensitive'
$k = Get-KeyFiles $null 'bob' $false 'C:\Users\bob' 'C:\ProgramData'
Assert-True ($k.Via -eq 'default' -and @($k.Files) -join '|' -eq 'C:\Users\bob\.ssh\authorized_keys|C:\Users\bob\.ssh\authorized_keys2') 'no config: the sshd default files'
Assert-True ((Ck (Run (New-Facts @{ AuthKeysVia = 'match' })) 'ssh.keys').detail -match 'Match block') 'keys found through a Match block: OK says so'
$r = Run (New-Facts @{ AuthKeysNonEmpty = $false; AuthKeysVia = 'unreadable' })
Assert-True ((St $r 'ssh.keys') -eq 'WARN' -and (Ck $r 'ssh.keys').detail -match 'sshd_config is not readable') 'sshd_config unreadable: WARN says keys may be elsewhere'
$wd = @(@{ Letter = 'C:'; FreeGB = 100; Media = 'SSD' }, @{ Letter = 'D:'; FreeGB = 500; Media = 'HDD' })
Assert-Equal (Select-WorkDrive $wd 'C:').Letter 'C:' 'work drive: SSD with >= 20 GB beats a bigger HDD'
Assert-Equal (Select-WorkDrive @(@{ Letter = 'C:'; FreeGB = 100; Media = 'HDD' }, @{ Letter = 'D:'; FreeGB = 500; Media = 'HDD' }) 'C:').Letter 'D:' 'work drive: most free space among HDDs'
Assert-Equal (Select-WorkDrive @(@{ Letter = 'C:'; FreeGB = 15; Media = 'SSD' }, @{ Letter = 'D:'; FreeGB = 500; Media = 'HDD' }) 'C:').Letter 'D:' 'work drive: SSD under 20 GB free is skipped'
Assert-Equal (Select-WorkDrive @(@{ Letter = 'C:'; FreeGB = 5; Media = 'SSD' }) 'C:').Letter 'C:' 'work drive: nothing roomy -> system drive'
Assert-Equal (Get-SafeName 'My_PC.Local') 'my-pc-local' 'name: lowercase [a-z0-9-]'
Assert-Equal (Get-SafeName '--x--') 'x' 'name: no leading/trailing hyphen'
Assert-Equal (Get-SafeName '___') 'old-pc' 'name: fallback old-pc'
Assert-True (Test-SshUser 'build.user-1') 'ssh user: normal accepted'
Assert-True (-not (Test-SshUser 'John Smith')) 'ssh user: space rejected'
Assert-True (-not (Test-SshUser "o'brien")) 'ssh user: quote rejected'
$mm = Get-Machine (New-Facts @{ User = 'John Smith'; Hostname = 'My_PC' }) $null $null $false
Assert-Equal $mm.ssh '<user>@my-pc.lan' 'machine: unusual user -> <user> placeholder'
$sn = (Format-Snippet $mm (Run (New-Facts)).V (New-Facts)) -join "`n"
Assert-True ($sn -match 'name: "my-pc"' -and $sn -match 'ssh: "<user>@my-pc.lan"' -and $sn -match 'work_root: "C:/lq"') 'snippet: name, ssh and work_root are YAML-quoted'
$de = "  GUID des Energieschemas: x`r`n  Mindestwert: 0x00000000`r`n  Hoechstwert: 0xffffffff`r`n  Inkrement: 0x00000001`r`n  Aktueller Wechselstromeinstellungsindex: 0x00000708`r`n  Aktueller Gleichstromeinstellungsindex: 0x00000258`r`n"
Assert-Equal (Get-PowercfgAcSeconds $de) 1800 'powercfg: localized (German) output still parses the AC value'
Assert-Equal (Get-PowercfgAcSeconds "x`r`n Aktueller Wechselstromeinstellungsindex: 0x00000000`r`n Aktueller Gleichstromeinstellungsindex: 0x00000000`r`n") 0 'powercfg: localized "never" = 0'
Assert-True ($null -eq (Get-PowercfgAcSeconds 'nothing here')) 'powercfg: no hex values -> null (SKIP)'
$r = Run (New-Facts @{ StandbyAcSec = 0; HibernateAcSec = $null })
Assert-Equal (St $r 'power.sleep') 'OK' 'sleep check does not SKIP just because hibernate is unreadable'

Write-Host 'review fixes round 2: falsy one-element results, WSL tri-state, docker context'
Assert-True ((Get-ProbeBool @($false)) -eq $false -and $null -ne (Get-ProbeBool @($false))) 'Defender off ([$false]) is $false, not unknown'
Assert-True ($null -eq (Get-ProbeBool $null)) 'timed-out probe is unknown ($null)'
Assert-True ((Get-ProbeInt @(0)) -eq 0 -and $null -ne (Get-ProbeInt @(0))) 'zero WoL adapters ([0]) is 0, not unknown'
Assert-Equal (St (Run (New-Facts @{ DefenderRtp = (Get-ProbeBool @($false)) })) 'defender') 'OK' 'Defender off shows OK, not SKIP'
Assert-Equal (Invoke-WithTimeout { param($x) $false } $null 10).Count 1 'Invoke-WithTimeout keeps a single $false result'
Assert-Equal (Get-WslInstalled $true $null) $true 'WSL: service/key present -> installed'
Assert-Equal (Get-WslInstalled $false $true) $true 'WSL: Store package present -> installed'
Assert-Equal (Get-WslInstalled $false $false) $false 'WSL: nothing found, Store query answered no -> not installed'
Assert-True ($null -eq (Get-WslInstalled $false $null)) 'WSL: Store query undeterminable -> unknown'
Assert-True ($null -eq (Get-WslState $null { throw 'must not run' })) 'WSL unknown: wsl.exe is not run, result unknown'
$ps1src = Get-Content -LiteralPath (Join-Path $root 'lanq-makeready.ps1') -Raw
Assert-True ($ps1src -notmatch 'config\.json') 'docker config.json (may hold credentials) is never read'
$env:DOCKER_CONTEXT = 'staging'; Assert-Equal (Get-DockerContext $null) 'staging' 'docker context comes from DOCKER_CONTEXT'; Remove-Item Env:\DOCKER_CONTEXT

Write-Host 'probes: closed stdin, neutral cwd, probe env, deadlines, no WSL stub'
$cmd = "$env:SystemRoot\System32\cmd.exe"
$r = Invoke-Bounded $cmd '/c cd' 5
Assert-True ((Get-FirstLine $r.Out) -eq $env:SystemRoot) 'probe runs in %SystemRoot%, not the current directory'
$r = Invoke-Bounded $cmd '/c echo %GOTOOLCHAIN%/%RUSTUP_AUTO_INSTALL%' 5
Assert-Equal (Get-FirstLine $r.Out) 'local/0' 'probe env: GOTOOLCHAIN=local, RUSTUP_AUTO_INSTALL=0'
Assert-True ((Get-ProbeEnv).GIT_TERMINAL_PROMPT -eq '0') 'probe env: git never prompts'
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Bounded "$env:SystemRoot\System32\findstr.exe" '/R "."' 20
Assert-True ($r -and -not $r.TimedOut -and $sw.Elapsed.TotalSeconds -lt 10) 'stdin is closed: a program that reads stdin ends instead of hanging'
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Bounded $cmd '/c ping -n 40 127.0.0.1 >nul' 1
Assert-True ($r.TimedOut -and $sw.Elapsed.TotalSeconds -lt 8) 'deadline: a long-running probe is stopped (with its child processes)'
$ran = $false
Assert-Equal (Get-WslState $false { $script:ran = $true; @{ Ok = $true } }) $false 'WSL not installed: reports false'
Assert-Equal $ran $false 'WSL not installed: wsl.exe is never run'
Assert-Equal (Get-WslState $true { @{ Ok = $true } }) $true 'WSL installed: status result is used'
$sw = [Diagnostics.Stopwatch]::StartNew()
Assert-True ($null -eq (Invoke-WithTimeout { param($x) Start-Sleep -Seconds 30; 1 } $null 1) -and $sw.Elapsed.TotalSeconds -lt 8) 'Invoke-WithTimeout: a hung cmdlet block returns $null at the deadline'
Assert-Equal (Invoke-WithTimeout { param($x) 41 + $x } 1 10)[0] 42 'Invoke-WithTimeout: normal result is returned'
$script:Hung = $false

Write-Host 'redaction on values, JSON structure intact'
function Get-Keys($Obj, $Prefix = '') { foreach ($p in $Obj.PSObject.Properties) { "$Prefix$($p.Name)"; if ($p.Value -is [pscustomobject]) { Get-Keys $p.Value "$Prefix$($p.Name)." } } }
$base = (Get-JsonFor (New-RedFacts 'box' 'builder') $false) | ConvertFrom-Json
foreach ($pair in @(@('worker', "o'brien"), @('windows', 'OK'), @('false', 'linux'))) {
  $raw = Get-JsonFor (New-RedFacts $pair[0] $pair[1]) $true
  $j = $raw | ConvertFrom-Json
  Assert-Equal ((Get-Keys $j | Sort-Object) -join ',') ((Get-Keys $base | Sort-Object) -join ',') "redact host '$($pair[0])' user '$($pair[1])': JSON keys unchanged"
  Assert-Equal $j.host.hostname '<redacted>' "redact '$($pair[0])': host field"
  Assert-True (@($j.checks | Where-Object { @('OK', 'WARN', 'FAIL', 'SKIP') -notcontains $_.status }).Count -eq 0) "redact '$($pair[0])': every status still valid"
  Assert-True (($j.checks | Where-Object { $_.id -eq 'ssh.server' }).needsAdmin -is [bool]) "redact '$($pair[0])': booleans are still booleans"
  Assert-Equal $j.suggestedMachine.os 'windows' "redact '$($pair[0])': os value untouched"
  Assert-True ((($j.checks | Where-Object { $_.id -eq 'cpu' }).detail) -match 'cpu of <redacted>') "redact '$($pair[0])': replaced inside free text"
}
$raw = Get-JsonFor (New-RedFacts 'wrk7pc' "o'brien") $true
Assert-True (-not (Hide-Leak $raw 'wrk7pc') -and -not (Hide-Leak $raw "o'brien") -and -not (Hide-Leak $raw 'C:\\Users\\o\u0027brien')) "no host/user/profile at a token boundary in redacted JSON (apostrophe name)"
$h = (New-Facts @{ Caption = "Windows $([char]0xE9)" }); $ascii = ConvertTo-AsciiJson (New-Report $h (Get-Checks $h) @{} @{ capabilities = @() } '0.1.0')
Assert-True ($ascii -match '\\u00e9' -and -not ($ascii -match '[^\x00-\x7F]')) 'JSON is pure ASCII (non-ASCII escaped)'

Write-Host 'read-only guard (AST allow-list)'
$AstNs = 'System.Management.Automation.Language'
foreach ($f in @('lanq-makeready.ps1', 'lanq-makeready.sh')) {
  $text = Get-Content -LiteralPath (Join-Path $root $f) -Raw
  Assert-True (-not ($text -match '[^\x00-\x7F]')) "$f is pure ASCII"
  Assert-True (@(Get-Content -LiteralPath (Join-Path $root $f)).Count -le 980) "$f is at most 980 lines"
}
$psPath = Join-Path $root 'lanq-makeready.ps1'
$tokens = $null; $perr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($psPath, [ref]$tokens, [ref]$perr)
Assert-Equal @($perr).Count 0 'ps1 parses without errors'
$funcs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$funcNames = @($funcs | ForEach-Object { $_.Name })
function Get-Fn($Node) { $p = $Node.Parent; while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }; $p = $p.Parent }; return '' }
$okCmds = @('Add-Type', 'ConvertFrom-Json', 'Get-LocalGroupMember', 'ConvertTo-Json', 'ForEach-Object', 'Get-Acl', 'Get-ChildItem', 'Get-CimInstance', 'Get-Command', 'Get-Content', 'Get-Item', 'Get-ItemProperty',
  'Get-Location', 'Get-MpComputerStatus', 'Get-NetAdapter', 'Get-NetAdapterPowerManagement', 'Get-NetFirewallPortFilter', 'Get-NetFirewallRule', 'Get-Partition', 'Get-PhysicalDisk', 'Get-Service', 'Join-Path',
  'Measure-Object', 'Get-AppxPackage', 'New-Object', 'Select-Object', 'Sort-Object', 'Test-Path', 'Where-Object', 'Write-Host')
$bad = @()
foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
  $n = $c.GetCommandName(); $fn = Get-Fn $c
  if ($n) { if (($okCmds -notcontains $n) -and ($funcNames -notcontains $n)) { $bad += "command $n" } }
  elseif (-not (($c.Extent.Text -match '^& \$Run\b' -and $fn -eq 'Get-WslState') -or ($c.Extent.Text -match '^& \$fix\b' -and $fn -eq 'Protect-Facts'))) { $bad += "dynamic command: $($c.Extent.Text)" }
  if ($n -eq 'Write-Host' -and $fn -ne 'Write-Out') { $bad += 'Write-Host outside Write-Out' }
  if ($n -eq 'Add-Type' -and ($c.Extent.Text -ne 'Add-Type -AssemblyName Microsoft.VisualBasic' -or $fn -ne 'Get-Facts')) { $bad += "Add-Type other than loading Microsoft.VisualBasic in Get-Facts: $($c.Extent.Text)" }
  if ($n -eq 'New-Object') {
    $t = $c.CommandElements[1].Extent.Text.Trim("'`"")
    if (@('System.Diagnostics.ProcessStartInfo', "System.Collections.Generic.Stack[string]", 'System.IO.FileInfo', 'System.IO.DirectoryInfo', 'System.Text.UTF8Encoding', 'System.Collections.ArrayList', 'Security.Principal.WindowsPrincipal', 'Microsoft.VisualBasic.Devices.ComputerInfo') -notcontains $t -and $t -notmatch '^System\.Collections\.Generic\.Stack') { $bad += "New-Object $t" }
  }
  if ($n -eq 'Invoke-Bounded') {
    $exe = $c.CommandElements[1].Extent.Text; $arg = ''; if ($c.CommandElements.Count -gt 2) { $arg = $c.CommandElements[2].Extent.Text }
    $okExe = @('$git', '$tar', '$dk', '$DockerExe', '$wsl', '$pc', '$e', '"$env:SystemRoot\System32\taskkill.exe"', 'param')
    $okArg = @("'/devicequery wake_armed'", "'context show'", "'--version'", "'config --get core.longpaths'", '"version --format {{.Server.Version}}"', "'--status'", "'/q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE'", "'/q SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE'", '$t[1]', '"/T /F /PID $ProcId"')
    if ($fn -ne 'Invoke-Bounded' -and $fn -ne 'Stop-Tree') {
      if ($okExe -notcontains $exe) { $bad += "Invoke-Bounded exe $exe" }
      if ($okArg -notcontains $arg) { $bad += "Invoke-Bounded args $arg" }
      if ($exe -match 'taskkill' -and $fn -ne 'Stop-Tree') { $bad += 'taskkill outside Stop-Tree' }
    }
  }
}
# (expression, member) PAIRS: a call is allowed only on the exact receiver it is used on today.
$okPairs = @(
  '"$S"|ToLowerInvariant', '$ace.IdentityReference|Translate', '$Advice|ContainsKey', '$Block|ToString', '$c|Add', '$c|ToArray',
  '$d.DeviceID.Substring(0, 1)|ToUpper', '$d.DeviceID|Substring', '$e|Wait', '$h.AsyncWaitHandle|WaitOne', '$H|Split', '$l|Trim', '$M|Contains',
  '$Matches[1]|ToUpper', '$media|ContainsKey', '$n.Substring(0, 63)|Trim', '$n|Substring', '$o|Wait', '$p.StandardError|ReadToEndAsync',
  '$p.StandardInput|Close', '$p.StandardOutput|ReadToEndAsync', '$p|Kill', '$p|WaitForExit', '$ps.AddScript($Block.ToString())|AddArgument',
  '$ps|AddScript', '$ps|BeginInvoke', '$ps|BeginStop', '$ps|Dispose', '$ps|EndInvoke', '$rank|ContainsKey', '$stack|Pop', '$stack|Push',
  '$w[0]|Substring', '$w[1]|Substring', '("$S".ToLowerInvariant() -replace ''[^a-z0-9-]'', ''-'')|Trim', '($cpu[0].Name -replace ''\s+'', '' '')|Trim', '($cn -replace ''\s+'', '' '')|Trim', '[System.IO.DriveInfo]|GetDrives', '[System.GC]|GetGCMemoryInfo',
  '[Console]::Error|WriteLine', '[Console]::Out|Flush', '[Console]::Out|Write', '[Convert]|ToInt64', '[DateTime]::UtcNow|ToString', '[Environment]|Exit',
  '[math]|Min', '[math]|Round', '"$l"|Split', '$p[2].ToLowerInvariant()|Replace', '$p[2]|ToLowerInvariant', '$r|Remove', '$PSBoundParameters|ContainsKey', '$Lines|Add',
  '[System.IO.File]|Open', '(New-Object System.Text.UTF8Encoding($false))|GetBytes', '$fs|Write', '$fs|Dispose', '[regex]|Escape', '[regex]|Matches', '[regex]|Replace', '[Security.Principal.WindowsIdentity]|GetCurrent',
  '[System.Diagnostics.Process]|Start', '[System.Diagnostics.Stopwatch]|StartNew', '[System.IO.Directory]|EnumerateDirectories',
  '[System.IO.Directory]|EnumerateFiles', '[System.IO.File]|WriteAllText', '[System.IO.Path]|IsPathRooted', '[System.Management.Automation.PowerShell]|Create')
$onlyIn = @{ Start = 'Invoke-Bounded'; Kill = 'Invoke-Bounded'; WaitForExit = 'Invoke-Bounded'; Create = 'Invoke-WithTimeout'; WriteAllText = ''; Exit = ''; Open = 'Save-OutFile' }
foreach ($m in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
  $mn = $m.Member.Extent.Text; $fn = Get-Fn $m
  $pair = $m.Expression.Extent.Text + '|' + $mn
  if ($okPairs -notcontains $pair) { $bad += "call $pair" }
  if ($onlyIn.ContainsKey($mn) -and $fn -ne $onlyIn[$mn]) { $bad += "member $mn in '$fn'" }
}
$SA = 'System.Management.Automation.Language'
$redirs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.RedirectionAst] }, $true))
Assert-Equal $redirs.Count 0 'ps1 has no output redirection at all (the JSON report is written with WriteAllText)'
$driveVars = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.IsDriveQualified -and $n.VariablePath.DriveName -ne 'env' }, $true))
Assert-Equal @($driveVars | ForEach-Object { $_.Extent.Text }).Count 0 'ps1 uses no drive-qualified variable other than $env: (no ${C:\file} reads or writes)'
$okTargets = @('$F', '$F.Tools', '$m', '$media', '$o', '$psi', '$psi.EnvironmentVariables', '$s', '$t2')
$badAssign = @()
foreach ($a2 in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
  $l = $a2.Left
  if ($l -is [System.Management.Automation.Language.VariableExpressionAst]) { if ($l.VariablePath.IsDriveQualified) { $badAssign += "drive/env assignment $($l.Extent.Text)" }; continue }
  $root2 = ''
  if ($l -is [System.Management.Automation.Language.MemberExpressionAst]) { $root2 = $l.Expression.Extent.Text }
  elseif ($l -is [System.Management.Automation.Language.IndexExpressionAst]) { $root2 = $l.Target.Extent.Text }
  else { $root2 = $l.Extent.Text }
  if ($okTargets -notcontains $root2) { $badAssign += "assignment target $root2" }
}
Assert-Equal ($badAssign -join '; ') '' 'ps1 assigns only to local hashtables and ProcessStartInfo ($psi), never to env:/drive/other objects'
$assign = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$Advice' }, $true))
Assert-Equal $assign.Count 1 'one advice table'
$ht = $assign[0].Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
$nonLit = @($ht.KeyValuePairs | Where-Object { -not ($_.Item2.PipelineElements[0].Expression -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Item2.PipelineElements[0].Expression.StringConstantType -eq 'SingleQuoted') })
Assert-Equal $nonLit.Count 0 'advice table: every value is a single-quoted string literal (never executed)'
Assert-Equal @($ht.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)).Count 0 'advice table: contains no commands'
Assert-Equal ($bad -join '; ') '' 'ps1: every command, member call and probe invocation is on the read-only allow-list'
$cim = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-CimInstance' }, $true))
Assert-True ($cim.Count -ge 8 -and @($cim | Where-Object { $_.Extent.Text -notmatch '-ErrorAction Stop' }).Count -eq 0) 'ps1: every Get-CimInstance has -ErrorAction Stop (access denied is non-terminating, so try/catch would not see it)'
$ps1 = Get-Content -LiteralPath $psPath -Raw
Assert-Equal ([regex]::Matches($ps1, "@\('(?:node|python|java|go|rustc)', '(?:-{1,2}version|version)'\)")).Count 5 'ps1: exactly five toolchain probes, each only --version / -version / version'
Assert-True ($ps1 -match "\[System\.IO\.File\]::WriteAllText\(\`$full" -and ([regex]::Matches($ps1, 'WriteAllText')).Count -eq 1) 'ps1: WriteAllText only for the --json report'
Assert-Equal ([regex]::Matches($ps1, '\[System\.IO\.File\]::Open\(')).Count 1 'ps1: one File.Open, for -Out'
Assert-True ($ps1 -match "\[System\.IO\.File\]::Open\(\`$Path, \[System\.IO\.FileMode\]::CreateNew, \[System\.IO\.FileAccess\]::Write\)") 'ps1: -Out opens with CreateNew (never overwrites)'
$sh = Get-Content -LiteralPath (Join-Path $root 'lanq-makeready.sh') -Raw
$adv0 = $ps1.IndexOf('#region ADVICE'); $adv1 = $ps1.IndexOf('#endregion ADVICE')
$noAdvice = $ps1.Substring(0, $adv0) + $ps1.Substring($adv1)
foreach ($pat in @('Set-ItemProperty', 'Remove-Item', 'Set-Service', 'Start-Service', 'Stop-Service', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer', 'New-NetFirewallRule', 'Invoke-Expression', 'Out-File', 'Set-Content', 'Add-Content', 'Start-Process', 'New-Item')) {
  Assert-True ($noAdvice -notmatch [regex]::Escape($pat)) "ps1 outside the advice table has no $pat"
}
Assert-True (('x Remove-Item y' -match [regex]::Escape('Remove-Item'))) 'the text scan can fail (sanity)'
Assert-True ((Get-Content -LiteralPath (Join-Path $root 'schema/report.v1.json') -Raw | ConvertFrom-Json).title) 'schema parses as JSON'

if (-not $SkipSmoke) {
  Write-Host 'arguments (fast)'
  $script = Join-Path $root 'lanq-makeready.ps1'
  foreach ($case in @(@('--bogus', 'x'), @('stray'), @('-Hours', '07:00-07:00'))) {
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $script @case 2>$null
    Assert-Equal $LASTEXITCODE 2 ("exit 2 for: " + ($case -join ' '))
  }
  $env:LANQ_MAKEREADY_LIB = '1'
  $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $script 2>$null
  $libRc = $LASTEXITCODE
  Remove-Item Env:\LANQ_MAKEREADY_LIB
  Assert-Equal $libRc 2 'LANQ_MAKEREADY_LIB=1 on a direct run: exit 2'

  Write-Host '-Out: saves the human report, never overwrites'
  $od = Join-Path ([IO.Path]::GetTempPath()) ('lanq-out-' + [Guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $od)
  $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Out (Join-Path $od 'r.txt') -Redact
  Assert-True (@(0, 1) -contains $LASTEXITCODE) "-Out: exit $LASTEXITCODE"
  $rep = @(Get-Content -LiteralPath (Join-Path $od 'r.txt'))
  Assert-True ($rep[1] -match '^VERDICT: (READY|NOT READY)' -and $rep[-1] -match '^VERDICT: ') '-Out: report with the verdict at the top and bottom'
  Assert-True (-not (Hide-Leak ($rep -join "`n") $env:COMPUTERNAME)) '-Out: redacted'
  Set-Content -LiteralPath (Join-Path $od 'x.txt') -Value 'keep me'
  $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Out (Join-Path $od 'x.txt') 2>$null
  Assert-Equal $LASTEXITCODE 2 '-Out to an existing file: exit 2'
  Assert-Equal ((Get-Content -LiteralPath (Join-Path $od 'x.txt')) -join '') 'keep me' '-Out: existing file untouched'
  Assert-Equal @(Get-ChildItem -LiteralPath $od).Count 2 '-Out: no other file written'
  Remove-Item -LiteralPath $od -Recurse -Force

  Write-Host 'smoke: real run, non-elevated, -Json <file> -Redact'
  $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) { Write-Host '  note: running elevated (CI runners are admin); admin-only rows are filled in' } else { Assert-True $true 'smoke runs non-elevated' }
  $out = Join-Path ([IO.Path]::GetTempPath()) ("lanq-makeready-smoke-" + [Guid]::NewGuid().ToString('N') + '.json')
  $console = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Json $out -Redact -Hours 00:00-07:00 | Out-String
  $code = $LASTEXITCODE
  Assert-True (@(0, 1) -contains $code) "smoke: exit code in {0,1} (got $code)"
  Assert-True (Test-Path -LiteralPath $out) 'smoke: JSON written'
  $raw = Get-Content -LiteralPath $out -Raw; $j = $raw | ConvertFrom-Json
  Assert-Equal $j.schema 'lanq-makeready/v1' 'smoke: schema id'
  foreach ($k in 'tool', 'generatedAt', 'host', 'verdicts', 'checks', 'capabilities', 'suggestedMachine') { Assert-True ($null -ne $j.PSObject.Properties[$k]) "smoke: key $k" }
  foreach ($k in 'worker_git', 'worker_archive', 'dotnet10', 'docker', 'overnight') { Assert-True (@('OK', 'WARN', 'FAIL', 'SKIP') -contains $j.verdicts.$k) "smoke: verdict $k valid" }
  Assert-True (@($j.checks).Count -ge 15) 'smoke: has checks'
  Assert-Equal $j.host.hostname '<redacted>' 'smoke: hostname redacted'
  $leak = $false
  foreach ($tok in @($env:COMPUTERNAME, $env:USERNAME, $env:USERPROFILE)) { if ((Hide-Leak $raw $tok) -or (Hide-Leak $console $tok)) { $leak = $true; Write-Host "  leaked: $tok" } }
  Assert-True (-not $leak) 'smoke: no hostname, user name or profile path in the redacted output'
  [IO.File]::Delete($out)

  Write-Host 'smoke: stdout JSON over a pipe (the invocation lanq will use over SSH)'
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = '-NoProfile -NonInteractive -Command "& ([scriptblock]::Create([Console]::In.ReadToEnd())) -Json - -Redact"'
  $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
  $p.StandardInput.Write((Get-Content -LiteralPath $script -Raw)); $p.StandardInput.Close()
  [void]$p.WaitForExit(180000)
  $txt = $so.Result
  $j2 = $txt | ConvertFrom-Json
  $expect = 1; if ($j2.verdicts.worker_git -ne 'FAIL' -or $j2.verdicts.worker_archive -ne 'FAIL') { $expect = 0 }
  Assert-Equal $p.ExitCode $expect "stdin mode: exit code equals the one implied by the verdicts ($expect)"
  Assert-Equal ($se.Result.Trim()) '' 'stdin mode: nothing on stderr'
  Assert-Equal $j2.schema 'lanq-makeready/v1' 'stdin mode: stdout is the JSON report'
  Assert-True ($txt.TrimStart().StartsWith('{') -and $txt -notmatch 'read-only: nothing is installed') 'stdin mode: nothing but JSON on stdout'
  Assert-True (-not (Hide-Leak $txt $env:COMPUTERNAME) -and -not (Hide-Leak $txt $env:USERNAME)) 'stdin mode: redacted'
}
Write-Host ("`nPowerShell tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
