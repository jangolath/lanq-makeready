# Tests for lanq-makeready-tune.ps1 (no Pester). Works on Windows PowerShell 5.1 and pwsh 7.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\tune.ps1 [-SkipSmoke]
# The checks are pure functions of a facts table, tested with fixtures; the smoke test runs the real (read-only) scan once.
param([switch]$SkipSmoke)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$tunePath = Join-Path $root 'lanq-makeready-tune.ps1'
$script:pass = 0; $script:fail = 0
function Assert-Equal($Actual, $Expected, [string]$Name) {
  if ("$Actual" -ceq "$Expected") { $script:pass++; Write-Host "  ok   $Name" }
  else { $script:fail++; Write-Host "  FAIL $Name : expected '$Expected' got '$Actual'" -ForegroundColor Red }
}
function Assert-True($Cond, [string]$Name) { Assert-Equal ([bool]$Cond) 'True' $Name }

$env:LANQ_MAKEREADY_TUNE_LIB = '1'
. $tunePath
Remove-Item Env:\LANQ_MAKEREADY_TUNE_LIB

# Every check OK (bios.power is always an INFO reminder).
function New-TFacts([hashtable]$Over = @{}) {
  $f = @{ Hostname = 'box'; User = 'builder'; Profile = 'C:\Users\builder'; Arch = 'x64'; Elevated = $true; Container = $false; WorkRoot = 'C:/lq'; Hours = '22:00-07:00'; Now = [datetime]'2026-11-14'
    Budget = @{}; Seconds = 3; CpuMax = 100; CpuMin = 5; UsbSuspend = 0; Nics = @(@{ Name = 'Ethernet NIC'; Up = $true; Usb = $false }); Startup = @()
    Services = @(@{ Name = 'SysMain'; Display = 'SysMain'; Start = 'Disabled'; Status = 'Stopped' }, @{ Name = 'WSearch'; Display = 'Windows Search'; Start = 'Automatic'; Status = 'Running' })
    Tasks = @(); DefragOn = $true; Disks = @(@{ Id = '0'; Media = 'SSD'; Bus = 'NVMe'; Health = 'Healthy'; Wear = 3; ReadErr = 0 }); Parts = @('C=0')
    Volumes = @(@{ Letter = 'C:'; SizeGB = 100; FreeGB = 50 }); TrimOff = $false; SearchOn = $true; IndexRules = @(@{ Url = 'file:///C:\Users\*'; Include = $true }, @{ Url = 'file:///C:\Users\*\.nuget\*'; Include = $false })
    NugetDir = 'C:\Users\builder\.nuget\packages'; DoPolicy = $null; DoSetting = 0; Edition = 'Professional'; WuNoReboot = 1; RdpOn = $false
    DotnetEnv = @{ DOTNET_CLI_TELEMETRY_OPTOUT = '1'; DOTNET_NOLOGO = '1'; DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false' }; WslInstalled = $false; WslReclaim = $false
    Defender = @{ Mode = 'Normal'; Rtp = $true; Day = 8; Time = 120; Quick = 0; Idle = $true; Scanned = [ordered]@{ work_root = $true; 'NuGet packages' = $true; temp = $true } }
    AvOther = @(); Pagefile = @{ Auto = $true; Files = @(@{ Name = 'C:\pagefile.sys'; Max = 0 }); RamMB = 16384 }; RamMB = 16384; Drivers = @(@{ Name = 'NIC'; Date = [datetime]'2024-01-01' })
    NugetV3 = @{ MB = 10; Capped = $false }; SoftDist = @{ MB = 10; Capped = $false }; AutoLogon = '0'; AutoLogonPlain = $false; OneDrive = @('C:\Users\builder\OneDrive'); MaintOff = $false; MaintMin = 600 }
  foreach ($k in $Over.Keys) { $f[$k] = $Over[$k] }
  return $f
}
function Get-It($F, [string]$Id) { return @(Get-TuneItems $F | Where-Object { $_.id -eq $Id })[0] }
function Test-Case([string]$Id, [hashtable]$Over, [string]$Status, [string]$Name, [string]$FixId = '-', [string]$DetailRe = '') {
  $i = Get-It (New-TFacts $Over) $Id
  Assert-Equal $i.status $Status "$Id ${Status}: $Name"
  if ($FixId -ne '-') { Assert-Equal "$($i.fixId)" $FixId "$Id ${Status}: fix id '$FixId' ($Name)" }
  if ($DetailRe) { Assert-True ($i.detail -match $DetailRe) "$Id ${Status}: detail says $DetailRe" }
}

Write-Host 'all fine'
$all = @(Get-TuneItems (New-TFacts))
Assert-Equal (@($all | Where-Object { $_.status -ne 'OK' } | ForEach-Object { "$($_.id)=$($_.status)" }) -join ',') 'defender.paths=INFO,bios.power=INFO' 'baseline: everything OK except the Defender build-folder scan and the BIOS reminder'
$ids = @($all | ForEach-Object { $_.id })
Assert-Equal $ids.Count 24 '24 checks'
Assert-Equal (@($ids | Sort-Object -Unique).Count) 24 'every check id once'
Assert-True (@($ids | Where-Object { $_ -notmatch '^[a-z0-9]{1,16}(\.[a-z0-9]{1,16}){0,2}$' }).Count -eq 0) 'every id has the schema shape'

Write-Host 'one case per status per check'
$usbNic = @(@{ Name = 'USB NIC'; Up = $true; Usb = $true })
Test-Case 'power.plan' @{} 'OK' 'max 100, min 5'
Test-Case 'power.plan' @{ CpuMax = 90 } 'WARN' 'max below 100' 'power.cpu' '90%'
Test-Case 'power.plan' @{ CpuMin = 100 } 'INFO' 'min 100' 'power.cpu'
Test-Case 'power.plan' @{ CpuMax = $null } 'SKIP' 'unreadable' '' 'could not read'
Test-Case 'power.plan' @{ CpuMax = $null; Budget = @{ powercfg = $true } } 'SKIP' 'over its budget' '' 'time budget'
Test-Case 'power.usbsuspend' @{ UsbSuspend = 1; Nics = $usbNic } 'WARN' 'on with a USB NIC' 'power.usbsuspend'
Test-Case 'power.usbsuspend' @{ UsbSuspend = 1 } 'OK' 'on, no USB NIC'
Test-Case 'power.usbsuspend' @{ Nics = $null } 'SKIP' 'adapters unreadable'
Test-Case 'startup.vendor' @{ Startup = @(@{ Name = 'SupportAssistTray'; Exe = 'tray.exe'; Enabled = $true }) } 'INFO' 'a maker tool at logon' 'startup.vendor' 'SupportAssistTray'
Test-Case 'startup.vendor' @{ Startup = @(@{ Name = 'Tray'; Exe = 'ArmouryCrate.exe'; Enabled = $true }) } 'INFO' 'matched by its program'
Test-Case 'startup.vendor' @{ Startup = @(@{ Name = 'SupportAssistTray'; Exe = 'tray.exe'; Enabled = $false }) } 'OK' 'already disabled in Task Manager'
Test-Case 'startup.vendor' @{ Startup = @(@{ Name = 'OneDrive'; Exe = 'OneDrive.exe'; Enabled = $true }) } 'OK' 'not on the curated list'
Test-Case 'startup.vendor' @{ Startup = $null } 'SKIP' 'unreadable'
$svc = { param($n, $s) @(@{ Name = $n; Display = $n; Start = $s; Status = 'Running' }, @{ Name = 'SysMain'; Display = 'SysMain'; Start = 'Disabled'; Status = 'Stopped' }) }
Test-Case 'vendor.services' @{ Services = (& $svc 'DellUpdate' 'Automatic') } 'INFO' 'a maker updater service' 'vendor.services' 'DellUpdate'
Test-Case 'vendor.services' @{ Services = (& $svc 'DellUpdate' 'Disabled') } 'OK' 'already disabled'
Test-Case 'vendor.services' @{ Services = (& $svc 'wuauserv' 'Manual') } 'OK' 'a Windows service is never listed'
Test-Case 'vendor.services' @{ Services = $null } 'SKIP' 'unreadable'
Test-Case 'vendor.tasks' @{ Tasks = @(@{ Path = '\Lenovo\'; Name = 'Lenovo Vantage Update'; State = 'Ready' }) } 'INFO' 'a maker task' 'vendor.tasks'
Test-Case 'vendor.tasks' @{ Tasks = @(@{ Path = '\Microsoft\Windows\X\'; Name = 'SupportAssistAgent'; State = 'Ready' }) } 'OK' 'tasks under \Microsoft\ are never listed'
Test-Case 'vendor.tasks' @{ Tasks = 'denied' } 'SKIP' 'access denied' '' 'access denied'
Test-Case 'vendor.tasks' @{ Tasks = $null; Budget = @{ tasks = $true } } 'SKIP' 'time budget' '' 'time budget'
$smOn = @(@{ Name = 'SysMain'; Display = 'SysMain'; Start = 'Automatic'; Status = 'Running' })
Test-Case 'sysmain' @{ Services = $smOn } 'INFO' 'on, every disk an SSD' 'sysmain'
Test-Case 'sysmain' @{ Services = $smOn; Disks = @(@{ Id = '0'; Media = 'Unspecified'; Bus = 'SATA'; Health = 'Healthy' }) } 'OK' 'Unspecified counts as unknown, never SSD'
Test-Case 'sysmain' @{ Services = $smOn; Disks = @(@{ Id = '0'; Media = 'SSD'; Bus = 'NVMe'; Health = 'Healthy' }, @{ Id = '1'; Media = 'HDD'; Bus = 'SATA'; Health = 'Healthy' }) } 'OK' 'a spinning disk'
Test-Case 'sysmain' @{ Disks = $null } 'SKIP' 'disks unreadable'
Test-Case 'search.index' @{ IndexRules = @(@{ Url = 'file:///C:\Users\*'; Include = $true }) } 'INFO' 'the NuGet packages are indexed' '' 'NuGet packages'
Test-Case 'search.index' @{ WorkRoot = 'C:/lq'; IndexRules = @(@{ Url = 'file:///C:\*'; Include = $true }) } 'INFO' 'work_root indexed' '' 'work_root'
Test-Case 'search.index' @{ SearchOn = $false } 'OK' 'indexer off'
Test-Case 'search.index' @{ SearchOn = $null } 'SKIP' 'unreadable'
Test-Case 'do.mode' @{ DoSetting = 3 } 'INFO' 'internet peers' 'do.mode'
Test-Case 'do.mode' @{ DoSetting = $null } 'INFO' 'Pro default (LAN peers)' 'do.mode' 'edition default'
Test-Case 'do.mode' @{ DoPolicy = 2 } 'INFO' 'set by a policy: no fix offered' ''
Test-Case 'do.mode' @{ DoPolicy = 0; DoSetting = 3 } 'OK' 'the policy wins'
Test-Case 'do.mode' @{ DoSetting = $null; Edition = $null } 'SKIP' 'unreadable'
Test-Case 'wu.reboot' @{ WuNoReboot = $null } 'INFO' 'policy not set (report only)' ''
Test-Case 'visual.fx' @{ RdpOn = $true } 'INFO' 'RDP on (report only)' ''
Test-Case 'dotnet.env' @{ DotnetEnv = @{ DOTNET_NOLOGO = '1' } } 'INFO' 'two missing' 'dotnet.env' 'DOTNET_CLI_TELEMETRY_OPTOUT, DOTNET_GENERATE_ASPNET_CERTIFICATE'
Test-Case 'dotnet.env' @{ DotnetEnv = $null } 'SKIP' 'unreadable'
Test-Case 'wsl.reclaim' @{ WslInstalled = $true } 'INFO' 'no autoMemoryReclaim (report only)' ''
Test-Case 'wsl.reclaim' @{ WslInstalled = $true; WslReclaim = $true } 'OK' 'set'
Test-Case 'defender.paths' @{} 'INFO' 'work_root and NuGet scanned' 'defender.exclude' 'work_root scanned, NuGet packages scanned, temp scanned'
Test-Case 'defender.paths' @{ Defender = @{ Mode = 'Normal'; Rtp = $true; Scanned = [ordered]@{ work_root = $false; 'NuGet packages' = $false; temp = $true } } } 'OK' 'build folders excluded, temp scanned (temp is never offered)'
Test-Case 'defender.paths' @{ Defender = @{ Mode = 'Normal'; Rtp = $true; Scanned = $null } } 'SKIP' 'not elevated' '' 'needs admin'
Test-Case 'defender.paths' @{ Defender = @{ Mode = 'Passive Mode'; Rtp = $true } } 'SKIP' 'AMRunningMode not Normal' '' 'Passive Mode'
Test-Case 'defender.paths' @{ Defender = @{ Mode = 'Normal'; Rtp = $false } } 'OK' 'real-time protection off'
Test-Case 'defender.paths' @{ Defender = $null } 'SKIP' 'unreadable'
$dfOn = @{ Mode = 'Normal'; Rtp = $true; Day = 0; Time = 120; Quick = 0; Idle = $false; Scanned = $null }
Test-Case 'defender.schedule' @{ Defender = $dfOn } 'INFO' 'scan at 02:00 inside 22:00-07:00' 'defender.scantime' '02:00'
Test-Case 'defender.schedule' @{ Defender = @{ Mode = 'Normal'; Rtp = $true; Day = 0; Time = 720; Quick = 180 } } 'INFO' 'quick scan inside' 'defender.scantime' 'quick scan at 03:00'
Test-Case 'defender.schedule' @{ Defender = @{ Mode = 'Normal'; Rtp = $true; Day = 0; Time = 720; Quick = 0 } } 'OK' 'outside the window'
Test-Case 'defender.schedule' @{ Defender = $dfOn; Hours = $null } 'SKIP' 'no -Hours' '' 'no -Hours'
Test-Case 'defender.schedule' @{ Defender = @{ Mode = 'SxS Passive Mode'; Day = 0; Time = 120 } } 'SKIP' 'not the active antivirus'
Test-Case 'av.other' @{ AvOther = @('Another AV') } 'INFO' 'another antivirus (report only)' '' 'Another AV'
Test-Case 'av.other' @{ AvOther = $null } 'SKIP' 'Security Center unreadable'
Test-Case 'av.other' @{ AvOther = $null; Defender = @{ Mode = 'Passive Mode'; Rtp = $false } } 'INFO' 'Defender passive (AMRunningMode), Security Center unreadable' '' 'Passive Mode'
Test-Case 'av.other' @{ AvOther = @('Another AV'); Defender = @{ Mode = 'Passive Mode'; Rtp = $false } } 'INFO' 'another antivirus, with the Defender mode' '' 'Another AV \(Defender AMRunningMode: Passive Mode\)'
$hddPf = @{ Disks = @(@{ Id = '0'; Media = 'SSD'; Bus = 'NVMe'; Health = 'Healthy' }, @{ Id = '1'; Media = 'HDD'; Bus = 'SATA'; Health = 'Healthy' }); Parts = @('C=0', 'D=1'); Pagefile = @{ Auto = $false; Files = @(@{ Name = 'D:\pagefile.sys'; Max = 0 }) } }
Test-Case 'pagefile' $hddPf 'INFO' 'on the HDD while an SSD exists' '' 'spinning disk'
Test-Case 'pagefile' @{ Pagefile = @{ Auto = $false; Files = @(@{ Name = 'C:\pagefile.sys'; Max = 2048 }) } } 'INFO' 'fixed size below RAM' '' 'below the RAM'
Test-Case 'pagefile' @{ Pagefile = $null } 'SKIP' 'unreadable'
Test-Case 'disk.health' @{ Disks = @(@{ Id = '0'; Media = 'SSD'; Bus = 'NVMe'; Health = 'Warning' }) } 'WARN' 'unhealthy' '' 'Warning'
Test-Case 'disk.health' @{ Disks = @(@{ Id = '0'; Media = 'SSD'; Bus = 'NVMe'; Health = 'Healthy'; Wear = 95 }) } 'WARN' 'worn out' '' 'wear 95'
Test-Case 'disk.health' @{ Disks = @(@{ Id = '0'; Media = 'HDD'; Bus = 'SATA'; Health = 'Healthy'; ReadErr = 4 }) } 'WARN' 'read errors' '' 'uncorrected'
Test-Case 'disk.health' @{ TrimOff = $true } 'INFO' 'TRIM off with an SSD'
Test-Case 'disk.health' @{ Elevated = $false } 'OK' 'not elevated: health only' '' 'need admin'
Test-Case 'disk.health' @{ Disks = $null } 'SKIP' 'unreadable'
Test-Case 'disk.full' @{ Volumes = @(@{ Letter = 'C:'; SizeGB = 100; FreeGB = 5 }) } 'WARN' '95% full' '' 'C: 95% used'
Test-Case 'disk.full' @{ Volumes = $null } 'SKIP' 'unreadable'
Test-Case 'drivers.age' @{ Drivers = @(@{ Name = 'Old NIC'; Date = [datetime]'2012-03-04' }) } 'INFO' 'older than 7 years (report only)' '' 'Old NIC \(2012-03-04\)'
Test-Case 'drivers.age' @{ Drivers = @(@{ Name = 'Odd'; Date = $null }) } 'OK' 'no date: not counted'
Test-Case 'drivers.age' @{ Drivers = $null; Budget = @{ drivers = $true } } 'SKIP' 'over its 15 s budget' '' 'time budget'
Test-Case 'cache.sizes' @{ NugetV3 = @{ MB = 3072; Capped = $true } } 'INFO' 'big NuGet HTTP cache (report only)' '' 'at least 3 GB'
Test-Case 'cache.sizes' @{ SoftDist = @{ MB = 4096; Capped = $false } } 'INFO' 'big Windows Update downloads'
Test-Case 'cache.sizes' @{ NugetV3 = $null; SoftDist = $null } 'OK' 'not found'
Test-Case 'autologon.plain' @{ AutoLogon = '1'; AutoLogonPlain = $true } 'WARN' 'plain-text password value' '' 'not read'
Test-Case 'autologon.plain' @{ AutoLogon = '1' } 'OK' 'autologon without a plain-text value'
Test-Case 'autologon.plain' @{ AutoLogon = $null } 'SKIP' 'unreadable'
Test-Case 'onedrive.workroot' @{ WorkRoot = 'C:/Users/builder/OneDrive/lq' } 'WARN' 'inside OneDrive'
Test-Case 'onedrive.workroot' @{ WorkRoot = 'D:/OneDrive - Org/lq'; OneDrive = @() } 'WARN' 'a OneDrive-named folder'
Test-Case 'onedrive.workroot' @{ WorkRoot = $null } 'SKIP' 'no -WorkRoot'
Test-Case 'bios.power' @{} 'INFO' 'always a reminder' ''
Test-Case 'maint.schedule' @{ MaintMin = 120 } 'INFO' 'maintenance at 02:00 inside the window (report only)' '' 'defrag'
Test-Case 'maint.schedule' @{ MaintMin = 120; MaintOff = $true } 'OK' 'maintenance off'
Test-Case 'maint.schedule' @{ Hours = $null } 'SKIP' 'no -Hours'
$ci = @(Get-TuneItems (New-TFacts @{ Container = $true; CpuMax = 50 }))
Assert-True (@($ci | Where-Object { $HostIds -contains $_.id -and ($_.status -ne 'SKIP' -or $_.detail -notmatch 'container' -or $_.fixId) }).Count -eq 0 -and (@($ci | Where-Object { $_.id -eq 'dotnet.env' })[0].status -eq 'OK')) 'inside a container: host checks SKIP, no fix ids; dotnet.env still checked'

Write-Host 'statuses, fix ids, security flags'
$big = @{ CpuMax = 90; UsbSuspend = 1; Nics = $usbNic; Startup = @(@{ Name = 'SupportAssistTray'; Exe = 'x.exe'; Enabled = $true }); Services = $smOn + @(@{ Name = 'DellUpdate'; Display = 'Dell Update'; Start = 'Automatic'; Status = 'Running' })
  Tasks = @(@{ Path = '\Lenovo\'; Name = 'Lenovo Vantage Update'; State = 'Ready' }); DoSetting = 3; DotnetEnv = @{}; Defender = $dfOn; AutoLogon = '1'; AutoLogonPlain = $true }
$bi = @(Get-TuneItems (New-TFacts $big))
Assert-Equal (@($bi | Where-Object { $_.fixId } | ForEach-Object { $_.fixId }) -join ',') 'power.cpu,power.usbsuspend,startup.vendor,vendor.services,vendor.tasks,sysmain,do.mode,dotnet.env,defender.scantime' 'fix ids: the tune fixes (defender.exclude is SKIP here: not elevated reading)'
Assert-True (@($bi | Where-Object { $_.fixId -and @('INFO', 'WARN') -notcontains $_.status }).Count -eq 0) 'a fix id only on INFO or WARN'
Assert-True (@($bi | Where-Object { @('OK', 'SKIP') -contains $_.status -and $_.advice }).Count -eq 0) 'no advice on OK or SKIP'
Assert-True (@($bi | Where-Object { @('OK', 'INFO', 'WARN', 'SKIP') -notcontains $_.status }).Count -eq 0) 'never FAIL'
Assert-Equal (@($bi | Where-Object { $_.security } | ForEach-Object { $_.id }) -join ',') 'defender.paths,av.other,autologon.plain' 'security items'
$fixIds = @('power.cpu', 'power.usbsuspend', 'startup.vendor', 'vendor.services', 'vendor.tasks', 'sysmain', 'do.mode', 'dotnet.env', 'defender.scantime', 'defender.exclude')
$fixText = [System.IO.File]::ReadAllText((Join-Path $root 'lanq-makeready-fix.ps1'))
Assert-True ($fixText -match [regex]::Escape("`$TuneFixIds = @('$($fixIds -join "', '")')")) 'every fix id the tune scan names is a fix in lanq-makeready-fix.ps1'
$src = [System.IO.File]::ReadAllText($tunePath)
$named = @([regex]::Matches($src, "\`$true '([a-z.]+)'") | ForEach-Object { $_.Groups[1].Value }) + @([regex]::Matches($src, "'(defender\.exclude|startup\.vendor)' \`$true") | ForEach-Object { $_.Groups[1].Value })
Assert-True (@($named | Where-Object { $fixIds -notcontains $_ }).Count -eq 0) 'the script names no fix id the fix script lacks'

Write-Host 'helpers'
Assert-True ((Test-InWindow 120 '22:00-07:00') -and -not (Test-InWindow 420 '22:00-07:00') -and (Test-InWindow 1320 '22:00-07:00') -and (Test-InWindow 60 '00:00-07:00') -and -not (Test-InWindow 1439 '00:00-07:00')) 'Test-InWindow: wraps midnight, end exclusive'
Assert-True ((Test-Hours '22:00-07:00') -and -not (Test-Hours '07:00-07:00') -and -not (Test-Hours '24:00-01:00') -and -not (Test-Hours '7-9')) 'Test-Hours'
Assert-True ((Test-WorkRoot 'C:/lq') -and (Test-WorkRoot 'D:/build/lq-1') -and -not (Test-WorkRoot 'C:\lq') -and -not (Test-WorkRoot 'C:/a b') -and -not (Test-WorkRoot 'C:/x/../y') -and -not (Test-WorkRoot '/srv/lq')) 'Test-WorkRoot: LanQueue''s Windows work_root rule'
Assert-Equal (Get-PowercfgAc "  Current AC Power Setting Index: 0x00000064") 100 'powercfg: AC percent'
Assert-Equal (Get-PowercfgAc "x`r`n Aktueller Wechselstromeinstellungsindex: 0x0000005a`r`n Aktueller Gleichstromeinstellungsindex: 0x00000032`r`n") 90 'powercfg: localized output'
Assert-True ((Test-Indexed 'C:\Users\b\.nuget\packages' @(@{ Url = 'file:///C:\Users\*'; Include = $true })) -and -not (Test-Indexed 'C:\Users\b\.nuget\packages' @(@{ Url = 'file:///C:\Users\*'; Include = $true }, @{ Url = 'file:///C:\Users\*\.nuget\*'; Include = $false }))) 'Test-Indexed: the longest rule wins'
Assert-True ((Test-Vendor 'SupportAssistAgent') -and -not (Test-Vendor 'wuauserv')) 'Test-Vendor'
$sw = [Diagnostics.Stopwatch]::StartNew(); $OverBudget.Clear()
Assert-True ($null -eq (Invoke-Probe 'slow' 1 { param($x) Start-Sleep -Seconds 20; 1 }) -and $OverBudget['slow'] -and $sw.Elapsed.TotalSeconds -lt 8) 'a probe over its budget returns nothing and is marked "time budget"'
Assert-Equal (@(Invoke-Probe 'quick' 10 { param($x) 41 + $x } 1)[0]) 42 'a probe within its budget returns its result'
$saved = $TotalSec; $TotalSec = 0
Assert-True ($null -eq (Invoke-Probe 'late' 10 { param($x) 1 }) -and $OverBudget['late'] -and $null -eq (Invoke-Exe 'cmd.exe' '/c echo x')) 'past the 90 s deadline nothing more is started'
$TotalSec = $saved; $script:Hung = $false

Write-Host 'redaction and JSON'
function Get-Keys($Obj, $Prefix = '') { foreach ($p in $Obj.PSObject.Properties) { "$Prefix$($p.Name)"; if ($p.Value -is [pscustomobject]) { Get-Keys $p.Value "$Prefix$($p.Name)." } } }
$rf = New-TFacts @{ Hostname = 'wrk7pc'; User = "o'brien"; Profile = "C:\Users\o'brien"; NugetDir = "C:\Users\o'brien\.nuget\packages"; WorkRoot = 'C:/lq'; OneDrive = @("C:\Users\o'brien\OneDrive")
  IndexRules = @(@{ Url = 'file:///C:\Users\*'; Include = $true }); Drivers = @(@{ Name = 'wrk7pc NIC'; Date = [datetime]'2010-01-01' }) }
$plain = ConvertTo-AsciiJson (New-TuneReport $rf (Get-TuneItems $rf) $false)
$red = ConvertTo-AsciiJson (New-TuneReport $rf (Get-TuneItems $rf) $true)
function Test-Leak($Text, $Token) { $Text -match ('(?<![A-Za-z0-9_])' + [regex]::Escape($Token) + '(?![A-Za-z0-9_])') }
Assert-True ((Test-Leak $plain 'wrk7pc') -and (Test-Leak $plain 'o\u0027brien')) 'without -Redact the host and user are in the report'
Assert-True (-not (Test-Leak $red 'wrk7pc') -and -not (Test-Leak $red 'o\u0027brien') -and -not (Test-Leak $red "o'brien")) 'with -Redact no host name, user name or profile folder at a token boundary'
$jr = $red | ConvertFrom-Json; $jp = $plain | ConvertFrom-Json
Assert-True ($jr.host.hostname -eq '<redacted>' -and $jr.host.user -eq '<redacted>') 'redacted host fields'
Assert-Equal ((Get-Keys $jr | Sort-Object) -join ',') ((Get-Keys $jp | Sort-Object) -join ',') 'redaction keeps the JSON keys'
$na = ConvertTo-AsciiJson (New-TuneReport (New-TFacts @{ AvOther = @("Caf$([char]0xE9) AV") }) (Get-TuneItems (New-TFacts @{ AvOther = @("Caf$([char]0xE9) AV") })) $false)
Assert-True ($na -match '\\u00e9' -and $na -notmatch '[^\x00-\x7F]') 'JSON is pure ASCII'

Write-Host 'schema (schema/tune.v1.json)'
$schema = [System.IO.File]::ReadAllText((Join-Path $root 'schema/tune.v1.json')) | ConvertFrom-Json
function Test-Obj($Obj, $Sch, [string]$Where) {
  $bad = @(); $names = @($Obj.PSObject.Properties | ForEach-Object { $_.Name })
  foreach ($r in @($Sch.required)) { if ($names -notcontains $r) { $bad += "$Where.$r missing" } }
  $allowed = @($Sch.properties.PSObject.Properties | ForEach-Object { $_.Name })
  foreach ($n in $names) { if ($allowed -notcontains $n) { $bad += "$Where.$n not in the schema" } }
  return $bad
}
function Test-TuneJson([string]$Text) {
  $j = $Text | ConvertFrom-Json; $bad = @()
  $bad += Test-Obj $j $schema 'report'
  foreach ($k in 'tool', 'host', 'context', 'summary') { $bad += Test-Obj $j.$k $schema.properties.$k $k }
  if ($j.schema -cne $schema.properties.schema.const) { $bad += 'schema id' }
  if ($j.tool.name -cne 'lanq-makeready-tune' -or $j.tool.version -cnotmatch $schema.properties.tool.properties.version.pattern) { $bad += 'tool' }
  if ("$($j.generatedAt)" -cnotmatch $schema.properties.generatedAt.pattern -and $j.generatedAt -isnot [datetime]) { $bad += 'generatedAt' }
  if ($j.host.os -isnot [string] -or $j.host.os.Length -gt $schema.properties.host.properties.os.maxLength) { $bad += 'host.os' }
  if ($j.context.container -isnot [bool] -or $j.context.elevated -isnot [bool]) { $bad += 'context booleans' }
  $is = $schema.'$defs'.item; $n = @{ OK = 0; INFO = 0; WARN = 0; SKIP = 0 }
  if (@($j.items).Count -gt $schema.properties.items.maxItems) { $bad += 'too many items' }
  foreach ($i in @($j.items)) {
    $bad += Test-Obj $i $is "item $($i.id)"
    if ($i.id -cnotmatch $is.properties.id.pattern) { $bad += "id $($i.id)" }
    if (@($is.properties.status.enum) -notcontains $i.status) { $bad += "status $($i.status)" } else { $n[$i.status]++ }
    if ($null -ne $i.fixId -and $i.fixId -cnotmatch $is.properties.fixId.pattern) { $bad += "fixId $($i.fixId)" }
    if ($null -ne $i.fixId -and @('INFO', 'WARN') -notcontains $i.status) { $bad += "fixId on $($i.status)" }
    if ($i.needsAdmin -isnot [bool] -or $i.security -isnot [bool]) { $bad += "booleans of $($i.id)" }
    foreach ($f in 'title', 'detail', 'advice') { if ($i.$f -isnot [string] -or $i.$f.Length -gt $is.properties.$f.maxLength) { $bad += "$f of $($i.id)" } }
  }
  if ($j.summary.ok -ne $n.OK -or $j.summary.info -ne $n.INFO -or $j.summary.warn -ne $n.WARN -or $j.summary.skip -ne $n.SKIP) { $bad += 'summary counts' }
  return $bad
}
Assert-Equal ((Test-TuneJson $plain) -join '; ') '' 'a fixture report matches the schema'
Assert-Equal ((Test-TuneJson (ConvertTo-AsciiJson (New-TuneReport (New-TFacts $big) (Get-TuneItems (New-TFacts $big)) $true))) -join '; ') '' 'a report with every fix id matches the schema'
Assert-True (@(Test-TuneJson ($plain -replace '"status":\s+"INFO"', '"status": "FAIL"')).Count -gt 0) 'schema check sanity: a FAIL status is caught'

Write-Host 'read-only guard (AST allow-list)'
$text = [System.IO.File]::ReadAllText($tunePath)
Assert-True ($text -notmatch '[^\x00-\x7F]') 'tune script is pure ASCII'
Assert-True (@(Get-Content -LiteralPath $tunePath).Count -le 800) 'tune script is at most 800 lines (short enough to read before running it)'
$perr = $null; $ast = [System.Management.Automation.Language.Parser]::ParseFile($tunePath, [ref]$null, [ref]$perr)
Assert-Equal @($perr).Count 0 'tune script parses'
function Get-TuneGuardViolations($Ast) {
  $bad = @()
  $funcNames = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
  $fnOf = { param($Node) $p = $Node.Parent; while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }; $p = $p.Parent }; return '' }
  $ok = @('ConvertTo-Json', 'ForEach-Object', 'Get-ChildItem', 'Get-CimInstance', 'Get-Content', 'Get-Item', 'Get-Location', 'Get-MpComputerStatus', 'Get-MpPreference', 'Get-NetAdapter', 'Get-Partition',
    'Get-PhysicalDisk', 'Get-ScheduledTask', 'Get-Service', 'Get-StorageReliabilityCounter', 'Join-Path', 'New-Object', 'Sort-Object', 'Test-Path', 'Where-Object', 'Write-Host')
  foreach ($c in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $n = $c.GetCommandName(); $fn = & $fnOf $c
    if (-not $n) { if (-not (($c.Extent.Text -match '^& \$(add|why)\b' -and $fn -eq 'Get-TuneItems') -or ($c.Extent.Text -match '^& \$min\b'))) { $bad += "dynamic command: $($c.Extent.Text)" }; continue }
    if ($ok -notcontains $n -and $funcNames -notcontains $n) { $bad += "command $n" }
    if ($n -eq 'Write-Host' -and $fn -ne 'Write-Out') { $bad += 'Write-Host outside Write-Out' }
    if ($n -eq 'New-Object' -and @('System.Diagnostics.ProcessStartInfo', 'System.Collections.Generic.Stack[string]', 'System.IO.FileInfo', 'System.IO.DirectoryInfo', 'System.Collections.ArrayList', 'System.Text.UTF8Encoding', 'Security.Principal.WindowsPrincipal') -notcontains $c.CommandElements[1].Extent.Text.Trim("'`"")) { $bad += "New-Object $($c.CommandElements[1].Extent.Text)" }
    if ($n -eq 'Invoke-Exe' -and $fn -ne 'Invoke-Exe') {
      $arg = $c.CommandElements[2].Extent.Text
      if ($c.CommandElements[1].Extent.Text -notmatch '^(\$pc|\(Join-Path \(\[Environment\]::GetFolderPath\(''System''\)\) ''fsutil\.exe''\))$' -or ($arg -notmatch "^'/q SCHEME_CURRENT [A-Za-z0-9_ -]+'$" -and $arg -ne "'behavior query DisableDeleteNotify'")) { $bad += "Invoke-Exe other than powercfg /q or fsutil behavior query: $($c.Extent.Text)" }
    }
    if ($n -eq 'ForEach-Object' -and -not ($c.CommandElements.Count -gt 1 -and $c.CommandElements[1] -is [System.Management.Automation.Language.ScriptBlockExpressionAst])) { $bad += "ForEach-Object without a script block" }
  }
  $okMembers = @('Add', 'AddArgument', 'AddScript', 'AddYears', 'BeginInvoke', 'BeginStop', 'Close', 'Contains', 'Create', 'Dispose', 'EndInvoke', 'EnumerateDirectories', 'EnumerateFiles', 'Escape', 'Exit',
    'ExpandEnvironmentVariables', 'Floor', 'Flush', 'GetCurrent', 'GetDrives', 'GetFolderPath', 'GetValue', 'GetValueNames', 'IsInRole', 'IsPathRooted', 'Kill', 'Matches', 'Min', 'Pop', 'Push', 'ReadToEndAsync',
    'Replace', 'Round', 'Split', 'Start', 'StartNew', 'StartsWith', 'Substring', 'ToInt64', 'ToLowerInvariant', 'ToString', 'ToUpper', 'Trim', 'TrimEnd', 'TryParseExact', 'Wait', 'WaitForExit', 'WaitOne',
    'Write', 'WriteAllText', 'WriteLine', 'Clear')
  $onlyIn = @{ Start = @('Invoke-Exe'); Kill = @('Invoke-Exe'); Create = @('Invoke-Probe'); AddScript = @('Invoke-Probe'); WriteAllText = @(''); Exit = @('') }
  foreach ($m in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
    $mn = $m.Member.Extent.Text; $fn = & $fnOf $m
    if ($okMembers -notcontains $mn) { $bad += "member call $($m.Extent.Text)" }
    if ($onlyIn.ContainsKey($mn) -and $onlyIn[$mn] -notcontains $fn) { $bad += "$mn in '$fn'" }
    if ($mn -eq 'Write' -and $m.Expression.Extent.Text -ne '[Console]::Out') { $bad += "Write on $($m.Expression.Extent.Text)" }
    if ($mn -eq 'Replace' -and $m.Expression.Extent.Text -match 'IO\.File') { $bad += 'File.Replace' }
    if ($mn -eq 'Create' -and $m.Expression.Extent.Text -ne '[System.Management.Automation.PowerShell]') { $bad += "Create on $($m.Expression.Extent.Text)" }
    if ($mn -eq 'GetValue' -and $m.Arguments.Count -gt 0 -and $m.Arguments[0].Extent.Text -match 'DefaultPassword') { $bad += 'GetValue(DefaultPassword)' }
  }
  foreach ($m in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Static }, $true)) { if ($m.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) { $bad += "static member through a variable: $($m.Extent.Text)" } }
  if (@($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.RedirectionAst] }, $true)).Count -gt 0) { $bad += 'redirection' }
  if (@($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.IsDriveQualified -and $n.VariablePath.DriveName -ne 'env' }, $true)).Count -gt 0) { $bad += 'drive-qualified variable' }
  $okRoots = @('$F', '$psi', '$h', '$s', '$i', '$ctx', '$OverBudget', '$F.DotnetEnv', '$h.Scanned', '$paths', '$media')
  foreach ($a in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $l = $a.Left; while ($l -is [System.Management.Automation.Language.ConvertExpressionAst] -or $l -is [System.Management.Automation.Language.AttributedExpressionAst]) { $l = $l.Child }
    if ($l -is [System.Management.Automation.Language.VariableExpressionAst]) { if ($l.VariablePath.IsDriveQualified) { $bad += "env or drive assignment $($l.Extent.Text)" }; continue }
    $r = $l; while ($r -is [System.Management.Automation.Language.MemberExpressionAst] -or $r -is [System.Management.Automation.Language.IndexExpressionAst]) { if ($r -is [System.Management.Automation.Language.MemberExpressionAst]) { $r = $r.Expression } else { $r = $r.Target } }
    if ($okRoots -notcontains $r.Extent.Text) { $bad += "assignment to $($l.Extent.Text)" }
  }
  # autologon: no Get-ItemProperty anywhere (so never on Winlogon); DefaultPassword appears once, as the right side of -contains
  foreach ($c in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) { if ("$($c.GetCommandName())" -match '^Get-ItemProperty') { $bad += "Get-ItemProperty: $($c.Extent.Text)" } }
  $dp = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -ceq 'DefaultPassword' }, $true))
  if ($dp.Count -ne 1 -or $dp[0].Parent -isnot [System.Management.Automation.Language.BinaryExpressionAst] -or "$($dp[0].Parent.Operator)" -ne 'Icontains') { $bad += 'DefaultPassword used other than in "-contains ''DefaultPassword''"' }
  return $bad
}
Assert-Equal ((Get-TuneGuardViolations $ast) -join '; ') '' 'tune script: every command, member call and assignment is on the read-only allow-list'
$cim = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-CimInstance' }, $true))
Assert-True ($cim.Count -ge 3 -and @($cim | Where-Object { $_.Extent.Text -notmatch '-ErrorAction Stop' }).Count -eq 0) 'every Get-CimInstance has -ErrorAction Stop'
Assert-Equal ([regex]::Matches($text, 'WriteAllText')).Count 1 'WriteAllText only for the -Json report'
$mutants = [ordered]@{
  'Get-ItemProperty on Winlogon'      = "function Bad-A { Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' }"
  'Get-ItemPropertyValue'             = "function Bad-B { Get-ItemPropertyValue -Path 'HKLM:\x' -Name y }"
  'GetValue of DefaultPassword'       = "function Bad-C { `$k.GetValue('DefaultPassword') }"
  'DefaultPassword elsewhere'         = "function Bad-D { `$n = 'DefaultPassword' }"
  'Set-ItemProperty'                  = "function Bad-E { Set-ItemProperty -Path HKLM:\x -Name y -Value 1 }"
  'Set-MpPreference'                  = "function Bad-F { Set-MpPreference -DisableRealtimeMonitoring `$true }"
  'Disable-ScheduledTask'             = "function Bad-G { Disable-ScheduledTask -TaskName x }"
  'Stop-Service'                      = "function Bad-H { Stop-Service -Name SysMain }"
  'powercfg /setacvalueindex'         = "function Bad-I { Invoke-Exe `$pc '/setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100' }"
  'fsutil behavior set'               = "function Bad-J { Invoke-Exe (Join-Path ([Environment]::GetFolderPath('System')) 'fsutil.exe') 'behavior set DisableDeleteNotify 0' }"
  'another exe through Invoke-Exe'    = "function Bad-K { Invoke-Exe 'C:\x\sc.exe' '/q SCHEME_CURRENT x' }"
  'an exe by name'                    = "function Bad-L { sc.exe config x start= disabled }"
  'Invoke-Expression'                 = "function Bad-M { Invoke-Expression 'x' }"
  'WriteAllText elsewhere'            = "function Bad-N { [System.IO.File]::WriteAllText('C:\x', 'y') }"
  'env assignment'                    = "function Bad-O { `$env:PATH = 'x' }"
  'SetEnvironmentVariable'            = "function Bad-P { [Environment]::SetEnvironmentVariable('X', '1', 'Machine') }"
  'redirection'                       = "function Bad-Q { 'x' > C:\x.txt }"
  'Add-MpPreference'                  = "function Bad-R { Add-MpPreference -ExclusionPath C:\ }"
  'Remove-Item'                       = "function Bad-S { Remove-Item C:\x -Recurse }"
}
$mdir = Join-Path ([IO.Path]::GetTempPath()) ('lanq-tunemut-' + [Guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $mdir); $mp = Join-Path $mdir 'm.ps1'
foreach ($k in $mutants.Keys) {
  [System.IO.File]::WriteAllText($mp, $text.Replace('# ---------- main ----------', $mutants[$k] + "`n# ---------- main ----------"))
  Assert-True (@(Get-TuneGuardViolations ([System.Management.Automation.Language.Parser]::ParseFile($mp, [ref]$null, [ref]$null))).Count -gt 0) "guard rejects: $k"
}
Remove-Item -LiteralPath $mdir -Recurse -Force

Write-Host 'curated vendor list (the same in the tune and fix scripts)'
function Get-ListValues([string]$Path, [string]$Var) {
  $a = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
  $as = @($a.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $Var }, $true))
  if ($as.Count -ne 1) { return $null }
  return @($as[0].Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
}
$lt = Get-ListValues $tunePath '$VendorPatterns'; $lf = Get-ListValues (Join-Path $root 'lanq-makeready-fix.ps1') '$VendorPatterns'
Assert-True ($lt.Count -gt 10 -and ($lt -join "`n") -ceq ($lf -join "`n")) 'the vendor lists are identical'
Assert-True (@($lt | Where-Object { $_ -match '\.\*|\.\+|^\.|^\*' -or $_ -notmatch '[A-Za-z]{4}' }).Count -eq 0) 'no bare wildcards: every pattern has a literal name'

Write-Host 'arguments and the real scan'
$psExe = (Get-Process -Id $PID).Path
function Start-Child([string]$ArgText) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe; $psi.Arguments = $ArgText; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
  $p = [System.Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync(); $p.StandardInput.Close()
  [void]$p.WaitForExit(180000)
  return @{ Code = $p.ExitCode; Out = "$($o.Result)"; Err = "$($e.Result)" }
}
$fa = "-NoProfile -ExecutionPolicy Bypass -File `"$tunePath`""
foreach ($a in @('-Hours 7-9', '-WorkRoot C:\a b', '-WorkRoot C:/x/../y', '-Fix', '-Yes')) { $r = Start-Child "$fa $a"; Assert-True ($r.Code -eq 2 -and $r.Err -match 'lanq-makeready-tune:') "bad argument '$a': exit 2" }
if (-not $SkipSmoke) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = Start-Child "-NoProfile -ExecutionPolicy Bypass -Command `"& '$tunePath' -Json '-' -Redact -Hours 22:00-07:00 -WorkRoot C:/lq; exit `$LASTEXITCODE`""
  Assert-True ($r.Code -eq 0) "real scan (read-only, -Json - -Redact): exit 0 (got $($r.Code); $($r.Err.Trim()))"
  Assert-True ($sw.Elapsed.TotalSeconds -lt 100) "real scan finished inside its deadline ($([int]$sw.Elapsed.TotalSeconds) s)"
  $bad = @(); try { $bad = @(Test-TuneJson $r.Out) } catch { $bad = @('not JSON') }
  Assert-Equal ($bad -join '; ') '' 'real scan output matches the schema'
  Assert-True (-not (Test-Leak $r.Out $env:USERNAME) -or $env:USERNAME.Length -lt 2) 'real scan with -Redact: the user name is not in it'
  $r = Start-Child "$fa -Hours 22:00-07:00"
  Assert-True ($r.Code -eq 0 -and $r.Out -match 'read-only' -and $r.Out -match 'Summary: \d+ OK, \d+ INFO, \d+ WARN, \d+ SKIP') 'real scan, text: exit 0, a summary line'
}

Write-Host ("`ntune PowerShell tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
