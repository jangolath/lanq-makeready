<#
.SYNOPSIS
  lanq-ready: READ-ONLY check of whether this PC can be a LanQueue worker.
.DESCRIPTION
  Changes nothing, installs nothing, makes no network calls, needs no admin rights.
  Every fix is printed as advice for you to run yourself (or not).
  Exit code: 0 = worker-ready, 1 = not ready, 2 = bad arguments.
.PARAMETER Json
  Also write a JSON report (schema lanq-ready/v1) to this path.
.PARAMETER Redact
  Replace hostname, user name and user-profile paths with <redacted>.
.PARAMETER Hours
  "HH:mm-HH:mm" window used for the suggested allowed_hours (start must differ from end).
.PARAMETER Quiet
  Print only the verdict lines.
#>
[CmdletBinding()]
param([string]$Json, [switch]$Redact, [string]$Hours, [switch]$Quiet)

$ToolVersion = '0.1.0'

#region ADVICE
# The ONE table of advice text. Nothing here is ever executed by this script.
$Advice = @{
  'ssh.install'  = 'Install OpenSSH Server yourself (elevated PowerShell): Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0   then: Start-Service sshd ; Set-Service -Name sshd -StartupType Automatic'
  'ssh.start'    = 'OpenSSH Server is installed but not running. In an elevated PowerShell: Start-Service sshd ; Set-Service -Name sshd -StartupType Automatic'
  'ssh.auto'     = 'sshd will not come back after a reboot. In an elevated PowerShell: Set-Service -Name sshd -StartupType Automatic'
  'ssh.fw'       = 'The firewall rule OpenSSH-Server-In-TCP is disabled. In an elevated PowerShell: Enable-NetFirewallRule -Name OpenSSH-Server-In-TCP'
  'ssh.nokeys'   = 'Put the orchestrator public key in the build user authorized_keys (for an Administrators member: C:\ProgramData\ssh\administrators_authorized_keys). A dedicated non-admin build user is simpler and safer.'
  'ssh.aclkeys'  = 'administrators_authorized_keys must be writable only by Administrators and SYSTEM, or sshd ignores it: icacls.exe C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "*S-1-5-32-544:F" /grant "SYSTEM:F"'
  'ssh.admin'    = 'This user is an administrator. A dedicated non-admin build user is simpler and safer for a worker.'
  'git.install'  = 'git is only needed for transfer: git. Without it use transfer: archive, or install Git for Windows yourself.'
  'git.longpaths'= 'Optional: git config --system core.longpaths true (elevated), and keep work_root short, for example C:/lq.'
  'tar.missing'  = 'transfer: archive needs the Windows built-in bsdtar (Windows 10 1803+ / Server 2019+) or GNU tar / bsdtar on Linux. busybox tar is refused by LanQueue.'
  'longpaths.on' = 'Optional: enable long paths (Settings registry LongPathsEnabled=1, reboot) and keep work_root short, for example C:/lq.'
  'win10.eol'    = 'Windows 10 is past end of support (2025-10-14; consumer ESU runs to 2027-10-12) and consumer 22H2 is not on the .NET 10 supported list. It usually runs; consider Windows 11 or Linux.'
  'os.old'       = 'This Windows version is too old for .NET 10 and Docker. Use a newer Windows or Linux.'
  'arch32'       = '32-bit systems cannot run the .NET 10 SDK or Docker. Install a 64-bit OS (the CPU may support it).'
  'ram.low'      = 'Less than 4 GB RAM: builds will swap and be slow. Fewer jobs (max_jobs: 1) and a lighter toolchain help; below 2 GB .NET SDK builds are unreliable.'
  'disk.hdd'     = 'A spinning disk makes builds slow. An SSD (even a small cheap one) is the single best upgrade for an old PC.'
  'disk.low'     = 'Free disk space is low. Each job needs room for a worktree plus build output; keep at least 20 GB free, below 10 GB the worker is refused.'
  'dotnet.os'    = 'This OS is not on the .NET 10 supported list. It may still run; Windows 11, Windows Server, or a listed Linux distribution is the safe choice.'
  'dotnet.glibc' = 'glibc 2.27 or newer is required (musl 1.2.3 on Alpine). Use a newer distribution release.'
  'dotnet.mac'   = '.NET 10 supports macOS 15 and newer. Note LanQueue workers are windows|linux only.'
  'docker.virt'  = 'Hardware virtualization is off. Turn on Intel VT-x / AMD-V (SVM) in the BIOS/UEFI setup yourself.'
  'docker.ram'   = 'Docker Desktop wants 8 GB RAM. With less, use Linux with Docker Engine, or Docker Engine inside WSL 2 with a memory cap in .wslconfig (memory=2GB). Below 4 GB, containers are not recommended.'
  'docker.wsl'   = 'WSL 2 was not found. Docker Desktop (WSL 2 backend) needs it; see learn.microsoft.com/windows/wsl/install.'
  'docker.build' = 'Docker Desktop needs Windows 10 22H2 (build 19045) or Windows 11 23H2+. Update Windows or use Linux.'
  'docker.daemon'= 'The Docker client is installed but the engine is not answering. Start Docker Desktop (or the docker service) yourself.'
  'power.sleep'  = 'The PC will sleep or hibernate mid-job. Review it yourself in Power Options, or in an elevated prompt: powercfg /change standby-timeout-ac 0 and powercfg /change hibernate-timeout-ac 0'
  'reboot.pending'= 'A restart is pending; the PC may reboot during a job. Restart it at a time you choose.'
  'updates.hours'= 'Windows Update may restart the PC inside your job window. Widen Active hours (Settings > Windows Update > Advanced options) to cover it.'
  'startup.many' = 'Many startup items slow boot and use RAM. Review them yourself in Task Manager > Startup apps. This tool never disables anything.'
  'temp.big'     = 'Large temp/cache folders. Disk Cleanup or Storage Sense can reclaim space; review before deleting. This tool never deletes anything.'
  'defender.rtp' = 'Real-time scanning slows builds. Options: a Dev Drive (Windows 11, performance mode) or a scoped exclusion for ONLY the work folder. Both lower protection a little; your decision.'
  'drivers.bad'  = 'Devices report driver problems. Check Windows Update > Optional updates, or the PC maker site. Never use a generic driver updater on a headless worker.'
}
#endregion ADVICE

# ---------- pure helpers (no I/O): used by tests with fixtures ----------

function New-Check {
  param([string]$Id, [string]$Title, [string]$Status, [string]$Detail, [string]$AdviceKey = '', [bool]$Admin = $false)
  $adv = ''
  if ($AdviceKey -and $Advice.ContainsKey($AdviceKey)) { $adv = $Advice[$AdviceKey] }
  [pscustomobject]@{ id = $Id; title = $Title; status = $Status; detail = $Detail; advice = $adv; needsAdmin = $Admin }
}

function Test-Hours([string]$H) {
  if ($H -notmatch '^([01]\d|2[0-3]):([0-5]\d)-([01]\d|2[0-3]):([0-5]\d)$') { return $false }
  $parts = $H.Split('-')
  return ($parts[0] -ne $parts[1])
}

function Test-HourInWindow([int]$Hour, [int]$StartH, [int]$EndH) {
  if ($StartH -le $EndH) { return ($Hour -ge $StartH -and $Hour -lt $EndH) }
  return ($Hour -ge $StartH -or $Hour -lt $EndH)
}

# True when some hour of the job window is NOT covered by Windows Update active hours.
function Test-UpdateOverlap([string]$H, [int]$ActStart, [int]$ActEnd) {
  $w = $H.Split('-'); $ws = [int]$w[0].Substring(0, 2); $we = [int]$w[1].Substring(0, 2)
  if ($w[1].Substring(3, 2) -ne '00') { $we = ($we + 1) % 24 }
  for ($hr = 0; $hr -lt 24; $hr++) {
    if ((Test-HourInWindow $hr $ws $we) -and -not (Test-HourInWindow $hr $ActStart $ActEnd)) { return $true }
  }
  return $false
}

# Seconds from `powercfg /q` text (AC value); $null when not found. 0 means "never".
function Get-PowercfgAcSeconds([string]$Text) {
  if ($Text -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') { return [Convert]::ToInt64($Matches[1], 16) }
  return $null
}

function Get-Worst($Statuses) {
  $rank = @{ SKIP = 0; OK = 1; WARN = 2; FAIL = 3 }; $w = 'SKIP'
  foreach ($s in $Statuses) { if ($s -and $rank.ContainsKey($s) -and $rank[$s] -gt $rank[$w]) { $w = $s } }
  return $w
}

function Get-DockerCheck($F) {
  $t = 'Docker'
  if ($F.DockerServerOk) { return New-Check 'docker' $t 'OK' "engine answering (server $($F.DockerServer))" }
  if ($F.DockerCli) { return New-Check 'docker' $t 'WARN' 'client installed but engine not reachable' 'docker.daemon' }
  if (-not $F.Is64) { return New-Check 'docker' $t 'FAIL' '32-bit Windows cannot run Docker' 'arch32' }
  if ($F.Build -lt 19045) { return New-Check 'docker' $t 'FAIL' "Windows build $($F.Build) is older than 19045 (22H2)" 'docker.build' }
  $virt = ($F.HypervisorPresent -eq $true) -or ($F.VirtFirmware -eq $true)
  $note = ''
  if ($F.HypervisorPresent -eq $true) { $note = ' (a hypervisor is already running, so virtualization is enabled)' }
  if (-not $virt -and $F.VirtFirmware -eq $false) { return New-Check 'docker' $t 'FAIL' 'hardware virtualization is disabled in firmware' 'docker.virt' }
  if ($F.RamGB -lt 4) { return New-Check 'docker' $t 'WARN' "only $($F.RamGB) GB RAM: containers not recommended" 'docker.ram' }
  if ($F.RamGB -lt 8) { return New-Check 'docker' $t 'WARN' "Docker Desktop wants 8 GB RAM, this PC has $($F.RamGB) GB" 'docker.ram' }
  if ($F.WslOk -eq $false) { return New-Check 'docker' $t 'WARN' 'not installed, and WSL 2 was not found' 'docker.wsl' }
  return New-Check 'docker' $t 'OK' "not installed; prerequisites look fine$note"
}

function Get-DotnetCheck($F) {
  $t = '.NET 10 SDK'
  $have = 'no SDK found'
  if ($F.DotnetSdks -and @($F.DotnetSdks).Count -gt 0) { $have = 'SDK majors found: ' + (@($F.DotnetSdks) -join ', ') }
  if (-not $F.Is64 -and -not $F.IsArm) { return New-Check 'dotnet' $t 'FAIL' "32-bit Windows cannot run the .NET 10 SDK ($have)" 'arch32' }
  if ($F.RamGB -lt 2) { return New-Check 'dotnet' $t 'FAIL' "under 2 GB RAM ($have)" 'ram.low' }
  if ($F.IsServer) {
    if ($F.Build -lt 9200) { return New-Check 'dotnet' $t 'FAIL' "$($F.Caption) is not supported ($have)" 'os.old' }
  } elseif ($F.Build -ge 22000) {
  } elseif ($F.Build -ge 10240) {
    $listed = @(14393, 17763, 19044) -contains [int]$F.Build
    if (-not ($listed -and $F.EditionId -match 'Enterprise|IoT|Education')) {
      return New-Check 'dotnet' $t 'WARN' "not on the .NET 10 supported list, usually runs ($have)" 'dotnet.os'
    }
  } else { return New-Check 'dotnet' $t 'FAIL' "Windows build $($F.Build) is too old ($have)" 'os.old' }
  if ($F.RamGB -lt 4) { return New-Check 'dotnet' $t 'WARN' "supported OS but low RAM ($have)" 'ram.low' }
  return New-Check 'dotnet' $t 'OK' "supported OS ($have)"
}

function Get-Checks($F) {
  $c = New-Object System.Collections.ArrayList
  # --- platform
  $d = "$($F.Caption) build $($F.Build)"
  if ($F.EditionId) { $d += ", $($F.EditionId)" }
  if ($F.IsServer -and $F.Build -lt 9200) { [void]$c.Add((New-Check 'os.version' 'OS' 'FAIL' $d 'os.old')) }
  elseif (-not $F.IsServer -and $F.Build -ge 10240 -and $F.Build -lt 22000) { [void]$c.Add((New-Check 'os.version' 'OS' 'WARN' $d 'win10.eol')) }
  elseif (-not $F.IsServer -and $F.Build -lt 10240) { [void]$c.Add((New-Check 'os.version' 'OS' 'FAIL' $d 'os.old')) }
  else { [void]$c.Add((New-Check 'os.version' 'OS' 'OK' $d)) }
  if ($F.Is64 -or $F.IsArm) { [void]$c.Add((New-Check 'os.arch' 'Architecture' 'OK' "$($F.Arch)")) }
  else { [void]$c.Add((New-Check 'os.arch' 'Architecture' 'FAIL' "32-bit ($($F.Arch))" 'arch32')) }
  [void]$c.Add((New-Check 'cpu' 'CPU' 'OK' "$($F.CpuName), $($F.Cores) cores / $($F.Logical) threads, AVX2: $($F.Avx2) (informational)"))
  $rs = 'OK'; $ra = ''
  if ($F.RamGB -lt 2) { $rs = 'FAIL'; $ra = 'ram.low' } elseif ($F.RamGB -lt 4) { $rs = 'WARN'; $ra = 'ram.low' }
  [void]$c.Add((New-Check 'ram' 'Memory' $rs "$($F.RamGB) GB total, $($F.FreeRamGB) GB free" $ra))
  $ds = 'OK'; $da = ''; $dd = "system drive $($F.SysFreeGB) GB free, work drive $($F.WorkFreeGB) GB free, disk type: $($F.DiskMedia)"
  $minFree = [math]::Min([double]$F.SysFreeGB, [double]$F.WorkFreeGB)
  if ($minFree -lt 10) { $ds = 'FAIL'; $da = 'disk.low' }
  elseif ($F.DiskMedia -eq 'HDD') { $ds = 'WARN'; $da = 'disk.hdd' }
  elseif ($minFree -lt 20) { $ds = 'WARN'; $da = 'disk.low' }
  [void]$c.Add((New-Check 'disk' 'Disk' $ds $dd $da))
  # --- ssh worker
  $shell = 'cmd.exe (LanQueue invokes powershell explicitly)'
  if ($F.DefaultShell) { $shell = "$($F.DefaultShell)" }
  if (-not $F.SshdInstalled) { [void]$c.Add((New-Check 'ssh.server' 'OpenSSH Server' 'FAIL' 'not installed' 'ssh.install')) }
  elseif (-not $F.SshdRunning) { [void]$c.Add((New-Check 'ssh.server' 'OpenSSH Server' 'FAIL' 'installed but not running' 'ssh.start')) }
  elseif ($F.SshdStartType -and $F.SshdStartType -ne 'Automatic') { [void]$c.Add((New-Check 'ssh.server' 'OpenSSH Server' 'WARN' "running, start type $($F.SshdStartType); default shell: $shell" 'ssh.auto')) }
  elseif ($F.SshFirewall -eq $false) { [void]$c.Add((New-Check 'ssh.server' 'OpenSSH Server' 'WARN' 'running; firewall rule OpenSSH-Server-In-TCP is disabled' 'ssh.fw')) }
  else { [void]$c.Add((New-Check 'ssh.server' 'OpenSSH Server' 'OK' "running, automatic start; default shell: $shell")) }
  if ($F.IsAdminUser) {
    if (-not $F.AdminKeysExists) { [void]$c.Add((New-Check 'ssh.keys' 'SSH keys' 'WARN' 'user is an administrator; administrators_authorized_keys not found' 'ssh.nokeys')) }
    elseif ($F.AdminKeysAclOk -eq $false) { [void]$c.Add((New-Check 'ssh.keys' 'SSH keys' 'WARN' 'administrators_authorized_keys has too-open permissions' 'ssh.aclkeys')) }
    else { [void]$c.Add((New-Check 'ssh.keys' 'SSH keys' 'OK' 'administrators_authorized_keys present (this user is an administrator)' 'ssh.admin')) }
  } elseif ($F.AuthKeysNonEmpty) { [void]$c.Add((New-Check 'ssh.keys' 'SSH keys' 'OK' 'authorized_keys present and non-empty')) }
  else { [void]$c.Add((New-Check 'ssh.keys' 'SSH keys' 'WARN' 'no authorized_keys for this user (fine if another user is the build user)' 'ssh.nokeys')) }
  if ($F.GitVer) {
    if ($F.GitLongPaths) { [void]$c.Add((New-Check 'git' 'git' 'OK' "$($F.GitVer), core.longpaths on")) }
    else { [void]$c.Add((New-Check 'git' 'git' 'WARN' "$($F.GitVer), core.longpaths not enabled" 'git.longpaths')) }
  } else { [void]$c.Add((New-Check 'git' 'git' 'WARN' 'not found (needed for transfer: git only)' 'git.install')) }
  if ($F.TarBsd) { [void]$c.Add((New-Check 'tar' 'tar' 'OK' 'built-in bsdtar found')) }
  else { [void]$c.Add((New-Check 'tar' 'tar' 'WARN' 'bsdtar not found (needed for transfer: archive only)' 'tar.missing')) }
  if ($F.LongPaths) { [void]$c.Add((New-Check 'longpaths' 'Long paths' 'OK' 'LongPathsEnabled = 1')) }
  else { [void]$c.Add((New-Check 'longpaths' 'Long paths' 'WARN' 'LongPathsEnabled is off' 'longpaths.on')) }
  # --- toolchains
  [void]$c.Add((Get-DotnetCheck $F))
  [void]$c.Add((Get-DockerCheck $F))
  foreach ($k in @('node', 'python', 'java', 'go', 'rustc')) {
    $v = $null; if ($F.Tools) { $v = $F.Tools[$k] }
    if ($v) { [void]$c.Add((New-Check $k $k 'OK' "$v")) } else { [void]$c.Add((New-Check $k $k 'SKIP' 'not installed (optional, only if your jobs use it)')) }
  }
  # --- overnight
  if ($null -eq $F.StandbyAcSec -or $null -eq $F.HibernateAcSec) { [void]$c.Add((New-Check 'power.sleep' 'Sleep/hibernate (AC)' 'SKIP' 'could not read powercfg')) }
  elseif ($F.StandbyAcSec -gt 0 -or $F.HibernateAcSec -gt 0) {
    [void]$c.Add((New-Check 'power.sleep' 'Sleep/hibernate (AC)' 'WARN' "sleeps after $([math]::Round($F.StandbyAcSec / 60)) min, hibernates after $([math]::Round($F.HibernateAcSec / 60)) min (0 = never)" 'power.sleep'))
  } else { [void]$c.Add((New-Check 'power.sleep' 'Sleep/hibernate (AC)' 'OK' 'never sleeps or hibernates on AC')) }
  if ($F.RebootPending) { [void]$c.Add((New-Check 'reboot.pending' 'Pending reboot' 'WARN' 'a restart is pending' 'reboot.pending')) }
  else { [void]$c.Add((New-Check 'reboot.pending' 'Pending reboot' 'OK' 'none')) }
  if (-not $F.Hours) { [void]$c.Add((New-Check 'updates.activehours' 'Update restarts vs job window' 'SKIP' 'pass -Hours to compare')) }
  elseif ($null -eq $F.ActiveStart) { [void]$c.Add((New-Check 'updates.activehours' 'Update restarts vs job window' 'SKIP' 'active hours not set in registry')) }
  elseif (Test-UpdateOverlap $F.Hours ([int]$F.ActiveStart) ([int]$F.ActiveEnd)) {
    [void]$c.Add((New-Check 'updates.activehours' 'Update restarts vs job window' 'WARN' "job window $($F.Hours) is outside Windows Update active hours $('{0:00}' -f [int]$F.ActiveStart):00-$('{0:00}' -f [int]$F.ActiveEnd):00" 'updates.hours'))
  } else { [void]$c.Add((New-Check 'updates.activehours' 'Update restarts vs job window' 'OK' 'job window is inside active hours')) }
  if ($null -eq $F.WolAdapters) { [void]$c.Add((New-Check 'wol' 'Wake-on-LAN' 'SKIP' 'needs admin to read' '' $true)) }
  else { [void]$c.Add((New-Check 'wol' 'Wake-on-LAN' 'OK' "$($F.WolAdapters) adapter(s) with magic-packet wake (informational)")) }
  # --- slowdowns (report only)
  if ($null -eq $F.StartupCount) { [void]$c.Add((New-Check 'startup' 'Startup items' 'SKIP' 'could not read')) }
  elseif ($F.StartupCount -gt 20) { [void]$c.Add((New-Check 'startup' 'Startup items' 'WARN' "$($F.StartupCount) items, e.g. $(@($F.StartupNames) -join ', ')" 'startup.many')) }
  else { [void]$c.Add((New-Check 'startup' 'Startup items' 'OK' "$($F.StartupCount) items")) }
  $big = @(); $sum = @()
  foreach ($t in @($F.TempSizes)) { if ($t) { $mark = ''; if ($t.Capped) { $mark = '>=' }; $sum += "$($t.Name) $mark$($t.MB) MB"; if ($t.MB -ge 5120) { $big += $t.Name } } }
  if ($sum.Count -eq 0) { [void]$c.Add((New-Check 'temp' 'Temp/cache folders' 'SKIP' 'none readable')) }
  elseif ($big.Count -gt 0) { [void]$c.Add((New-Check 'temp' 'Temp/cache folders' 'WARN' ($sum -join '; ') 'temp.big')) }
  else { [void]$c.Add((New-Check 'temp' 'Temp/cache folders' 'OK' ($sum -join '; '))) }
  if ($null -eq $F.DefenderRtp) { [void]$c.Add((New-Check 'defender' 'Defender real-time scan' 'SKIP' 'could not read')) }
  elseif ($F.DefenderRtp) { [void]$c.Add((New-Check 'defender' 'Defender real-time scan' 'OK' "on; Dev Drive available: $($F.DevDrive). Exclusions are not read." 'defender.rtp')) }
  else { [void]$c.Add((New-Check 'defender' 'Defender real-time scan' 'OK' 'off or managed by another product')) }
  if ($null -eq $F.ProblemDevices) { [void]$c.Add((New-Check 'drivers' 'Device drivers' 'SKIP' 'could not read')) }
  elseif (@($F.ProblemDevices).Count -gt 0) { [void]$c.Add((New-Check 'drivers' 'Device drivers' 'WARN' "$(@($F.ProblemDevices).Count) device(s) with problems: $(@($F.ProblemDevices | Select-Object -First 5) -join ', ')" 'drivers.bad')) }
  else { [void]$c.Add((New-Check 'drivers' 'Device drivers' 'OK' 'no devices report problems')) }
  return , $c.ToArray()
}

function Get-Verdicts($Checks, $F) {
  $s = @{}; foreach ($k in $Checks) { $s[$k.id] = $k.status }
  # 32-bit alone does not stop an SSH + git worker, so os.arch is not part of the worker verdicts
  $w = Get-Worst @($s['ssh.server'], $s['ssh.keys'], $s['disk'], $s['os.version'])
  $git = 'FAIL'; if ($F.GitVer) { $git = 'OK' }
  $tar = 'FAIL'; if ($F.TarBsd) { $tar = 'OK' }
  [ordered]@{
    worker_git     = Get-Worst @($w, $git)
    worker_archive = Get-Worst @($w, $tar)
    dotnet10       = $s['dotnet']
    docker         = $s['docker']
    overnight      = Get-Worst @($s['power.sleep'], $s['reboot.pending'], $s['updates.activehours'])
  }
}

function Get-Machine($F, $V, [string]$H, [bool]$Redact) {
  $name = 'old-pc'
  if (-not $Redact -and $F.Hostname) { $n = ($F.Hostname.ToLowerInvariant() -replace '[^a-z0-9-]', '-'); if ($n) { $name = $n } }
  $caps = @()
  if ($F.DotnetSdks -and @($F.DotnetSdks).Count -gt 0) { $caps += 'dotnet' }
  if ($F.Tools) { foreach ($p in @(@('node', 'node'), @('python', 'python'), @('java', 'java'), @('go', 'go'), @('rustc', 'rust'))) { if ($F.Tools[$p[0]]) { $caps += $p[1] } } }
  if ($F.DockerServerOk) { $caps += 'docker' }
  $caps += 'windows'
  $jobs = 1; if ($F.Logical -ge 8 -and $F.RamGB -ge 16) { $jobs = 2 }
  $tr = 'none'
  if ($F.GitVer) { $tr = 'git' } elseif ($F.TarBsd) { $tr = 'archive' }
  $root = 'C:/lq'
  if ($F.WorkDrive) { $root = "$($F.WorkDrive)/lq" }
  $ssh = 'user@' + $name + '.lan'
  if ($Redact) { $ssh = '<user>@<hostname>.lan' } elseif ($F.User) { $ssh = "$($F.User)@$name.lan" }
  $m = [ordered]@{ name = $name; os = 'windows'; ssh = $ssh; work_root = $root; capabilities = $caps; max_jobs = $jobs; transfer = $tr }
  if ($H) { $m['allowed_hours'] = $H }
  return $m
}

function Format-Snippet($M, $V) {
  $o = @()
  $ready = ($V.worker_git -ne 'FAIL') -or ($V.worker_archive -ne 'FAIL')
  if (-not $ready) { $o += '# NOT READY yet: fix the FAIL items above first, then re-run.' }
  $o += 'machines:'
  $o += "  - name: $($M.name)"
  $o += "    os: $($M.os)"
  $o += "    ssh: $($M.ssh)   # placeholder: confirm user and host name"
  $o += "    work_root: $($M.work_root)   # short path"
  $o += "    capabilities: [$(@($M.capabilities) -join ', ')]"
  $o += "    max_jobs: $($M.max_jobs)"
  if ($M.transfer -eq 'none') { $o += '    # transfer: needs git (transfer: git) or built-in tar (transfer: archive); neither found' }
  else { $o += "    transfer: $($M.transfer)" }
  if ($M.Contains('allowed_hours')) { $o += "    allowed_hours: `"$($M.allowed_hours)`"   # evaluated in the ORCHESTRATOR's local time" }
  return $o
}

function Protect-Text([string]$T, $F) {
  foreach ($v in @($F.Profile, $F.User, $F.Hostname)) {
    if ($v -and $v.Length -ge 2) { $T = [regex]::Replace($T, '(?<![A-Za-z0-9])' + [regex]::Escape($v) + '(?![A-Za-z0-9])', '<redacted>', 'IgnoreCase') }
  }
  return $T
}

# ---------- probes (read-only) ----------

function Invoke-Bounded {
  param([string]$Exe, [string]$ArgText = '', [int]$Sec = 8, [switch]$Utf16)
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe; $psi.Arguments = $ArgText; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    if ($Utf16) { $psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode }
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($Sec * 1000)) { try { $p.Kill() } catch { }; return @{ Ok = $false; TimedOut = $true; Code = -1; Out = '' } }
    [void]$o.Wait(2000); [void]$e.Wait(2000)
    return @{ Ok = ($p.ExitCode -eq 0); TimedOut = $false; Code = $p.ExitCode; Out = ($o.Result + "`n" + $e.Result) }
  } catch { return $null }
}

function Find-Exe([string]$Name) {
  $g = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($g -and $g.Source -notmatch '\\WindowsApps\\') { return $g.Source }
  return $null
}

function Get-FirstLine([string]$T) {
  foreach ($l in ($T -split "`r?`n")) { if ($l.Trim()) { return $l.Trim() } }
  return ''
}

function Get-DirSizeMB([string]$Path, [int]$Sec = 5) {
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
  $sw = [System.Diagnostics.Stopwatch]::StartNew(); $total = [long]0; $capped = $false
  $stack = New-Object 'System.Collections.Generic.Stack[string]'; $stack.Push($Path)
  while ($stack.Count -gt 0 -and -not $capped) {
    if ($sw.Elapsed.TotalSeconds -gt $Sec) { $capped = $true; break }
    $d = $stack.Pop()
    try {
      foreach ($f in [System.IO.Directory]::EnumerateFiles($d)) {
        if ($sw.Elapsed.TotalSeconds -gt $Sec) { $capped = $true; break }
        try { $total += (New-Object System.IO.FileInfo $f).Length } catch { }
      }
      foreach ($s in [System.IO.Directory]::EnumerateDirectories($d)) {
        if ($sw.Elapsed.TotalSeconds -gt $Sec) { $capped = $true; break }
        $a = (New-Object System.IO.DirectoryInfo $s).Attributes
        if (-not ($a -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($s) }
      }
    } catch { }
  }
  return @{ MB = [int][math]::Round($total / 1MB); Capped = $capped }
}

function Get-Facts([string]$H) {
  $F = @{ Hours = $H; Hostname = $env:COMPUTERNAME; User = $env:USERNAME; Profile = $env:USERPROFILE }
  try { $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15
    $F.Caption = ($os.Caption -replace '^Microsoft\s+', ''); $F.Build = [int]$os.BuildNumber; $F.IsServer = ($os.ProductType -ne 1)
    $F.RamGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1); $F.FreeRamGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
  } catch { $F.Caption = 'Windows (unreadable)'; $F.Build = 0; $F.RamGB = 0; $F.FreeRamGB = 0; $F.IsServer = $false }
  try { $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop; $F.EditionId = $cv.EditionID } catch { $F.EditionId = '' }
  $F.Is64 = [Environment]::Is64BitOperatingSystem
  $F.IsArm = ("$env:PROCESSOR_ARCHITECTURE $env:PROCESSOR_ARCHITEW6432" -match 'ARM64')
  if ($F.IsArm) { $F.Arch = 'arm64' } elseif ($F.Is64) { $F.Arch = 'x64' } else { $F.Arch = 'x86' }
  try { $cpu = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 15)
    $F.CpuName = ($cpu[0].Name -replace '\s+', ' ').Trim(); $F.Cores = ($cpu | Measure-Object NumberOfCores -Sum).Sum; $F.Logical = ($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum
    $F.VirtFirmware = $cpu[0].VirtualizationFirmwareEnabled
  } catch { $F.CpuName = 'unknown'; $F.Cores = 0; $F.Logical = 0 }
  try { $F.Avx2 = [string][System.Runtime.Intrinsics.X86.Avx2]::IsSupported } catch { $F.Avx2 = 'not queried on Windows PowerShell 5.1' }
  try { $F.HypervisorPresent = [bool](Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15).HypervisorPresent } catch { }
  # disks
  $sysLetter = ($env:SystemDrive).TrimEnd(':'); $best = $null
  try {
    $fixed = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -OperationTimeoutSec 15)
    foreach ($d in $fixed) { if ($d.DeviceID -eq $env:SystemDrive) { $F.SysFreeGB = [math]::Round($d.FreeSpace / 1GB, 1) }
      if ($d.FreeSpace -ge 10GB -and (-not $best -or $d.FreeSpace -gt ($best.FreeSpace * 2))) { $best = $d } }
    if (-not $best) { $best = $fixed | Where-Object { $_.DeviceID -eq $env:SystemDrive } | Select-Object -First 1 }
    if ($best) { $F.WorkDrive = $best.DeviceID; $F.WorkFreeGB = [math]::Round($best.FreeSpace / 1GB, 1); }
  } catch { }
  if ($null -eq $F.SysFreeGB) { $F.SysFreeGB = 0 }; if ($null -eq $F.WorkFreeGB) { $F.WorkFreeGB = $F.SysFreeGB }
  $F.DiskMedia = 'Unknown'
  try { $pt = Get-Partition -DriveLetter $sysLetter -ErrorAction Stop; $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq "$($pt.DiskNumber)" } | Select-Object -First 1
    if ($pd -and "$($pd.MediaType)" -match 'SSD|HDD') { $F.DiskMedia = "$($pd.MediaType)" } } catch { }
  # ssh
  $svc = Get-Service sshd -ErrorAction SilentlyContinue
  $F.SshdInstalled = [bool]($svc -or (Test-Path "$env:WINDIR\System32\OpenSSH\sshd.exe"))
  if ($svc) { $F.SshdRunning = ($svc.Status -eq 'Running'); $F.SshdStartType = "$($svc.StartType)" }
  try { $r = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction Stop; $F.SshFirewall = ("$($r.Enabled)" -eq 'True') } catch { $F.SshFirewall = $null }
  try { $F.DefaultShell = (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction Stop).DefaultShell } catch { }
  try { $F.IsAdminUser = [bool]([Security.Principal.WindowsIdentity]::GetCurrent().Groups | Where-Object { $_.Value -eq 'S-1-5-32-544' }) } catch { $F.IsAdminUser = $false }
  $ak = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
  $F.AuthKeysNonEmpty = [bool]((Test-Path -LiteralPath $ak) -and ((Get-Item -LiteralPath $ak).Length -gt 0))
  $adm = "$env:ProgramData\ssh\administrators_authorized_keys"
  $F.AdminKeysExists = (Test-Path -LiteralPath $adm)
  if ($F.AdminKeysExists) { try { $ok = $true
      foreach ($ace in (Get-Acl -LiteralPath $adm).Access) { $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if (@('S-1-5-32-544', 'S-1-5-18') -notcontains $sid) { $ok = $false } }
      $F.AdminKeysAclOk = $ok } catch { $F.AdminKeysAclOk = $null } }
  # git, tar, long paths
  $git = Find-Exe 'git'
  if ($git) { $r = Invoke-Bounded $git '--version' 8; if ($r -and $r.Ok) { $F.GitVer = Get-FirstLine $r.Out }
    $r = Invoke-Bounded $git 'config --get core.longpaths' 8; $F.GitLongPaths = [bool]($r -and $r.Out -match '^\s*true') }
  $tar = "$env:SystemRoot\System32\tar.exe"
  if (Test-Path -LiteralPath $tar) { $r = Invoke-Bounded $tar '--version' 8; $F.TarBsd = [bool]($r -and $r.Out -match 'bsdtar') } else { $F.TarBsd = $false }
  try { $F.LongPaths = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction Stop).LongPathsEnabled -eq 1) } catch { $F.LongPaths = $false }
  # dotnet SDK folders (no process is started)
  $roots = @("$env:ProgramFiles\dotnet", "${env:ProgramFiles(x86)}\dotnet", $env:DOTNET_ROOT, "$env:USERPROFILE\.dotnet")
  $majors = @()
  foreach ($rt in $roots) { if ($rt -and (Test-Path -LiteralPath "$rt\sdk")) { foreach ($dir in (Get-ChildItem -LiteralPath "$rt\sdk" -Directory -ErrorAction SilentlyContinue)) { if ($dir.Name -match '^(\d+)\.') { $majors += [int]$Matches[1] } } } }
  $F.DotnetSdks = @($majors | Sort-Object -Unique)
  # docker, wsl
  $dk = Find-Exe 'docker'; $F.DockerCli = [bool]$dk; $F.DockerServerOk = $false
  if ($dk) { $r = Invoke-Bounded $dk "version --format {{.Server.Version}}" 10; if ($r -and $r.Ok -and (Get-FirstLine $r.Out)) { $F.DockerServerOk = $true; $F.DockerServer = Get-FirstLine $r.Out } }
  $wsl = "$env:SystemRoot\System32\wsl.exe"
  if (Test-Path -LiteralPath $wsl) { $r = Invoke-Bounded $wsl '--status' 8 -Utf16; $F.WslOk = [bool]($r -and $r.Ok) } else { $F.WslOk = $false }
  # other tools
  $F.Tools = @{}
  foreach ($t in @(@('node', '--version'), @('python', '--version'), @('java', '-version'), @('go', 'version'), @('rustc', '--version'))) {
    $e = Find-Exe $t[0]; if ($e) { $r = Invoke-Bounded $e $t[1] 8; if ($r -and $r.Ok) { $F.Tools[$t[0]] = Get-FirstLine $r.Out } } }
  # power
  $pc = Find-Exe 'powercfg'
  if ($pc) { $r = Invoke-Bounded $pc '/q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE' 8; if ($r) { $F.StandbyAcSec = Get-PowercfgAcSeconds $r.Out }
    $r = Invoke-Bounded $pc '/q SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE' 8; if ($r) { $F.HibernateAcSec = Get-PowercfgAcSeconds $r.Out } }
  $F.RebootPending = [bool]((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations))
  try { $ah = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction Stop
    if ($null -ne $ah.ActiveHoursStart) { $F.ActiveStart = [int]$ah.ActiveHoursStart; $F.ActiveEnd = [int]$ah.ActiveHoursEnd } } catch { }
  try { $F.WolAdapters = @(Get-NetAdapterPowerManagement -ErrorAction Stop | Where-Object { "$($_.WakeOnMagicPacket)" -eq 'Enabled' }).Count } catch { $F.WolAdapters = $null }
  # slowdowns
  try { $su = @(Get-CimInstance Win32_StartupCommand -OperationTimeoutSec 15); $F.StartupCount = $su.Count; $F.StartupNames = @($su | Select-Object -First 5 | ForEach-Object { $_.Name }) } catch { }
  $F.TempSizes = @()
  foreach ($p in @(@('user temp', $env:TEMP), @('Windows temp', "$env:WINDIR\Temp"), @('NuGet packages', "$env:USERPROFILE\.nuget\packages"), @('npm cache', "$env:LOCALAPPDATA\npm-cache"))) {
    $z = Get-DirSizeMB $p[1] 3; if ($z) { $F.TempSizes += @{ Name = $p[0]; MB = $z.MB; Capped = $z.Capped } } }
  try { $F.DefenderRtp = [bool](Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled } catch { $F.DefenderRtp = $null }
  $F.DevDrive = ($F.Build -ge 22631)
  try { $F.ProblemDevices = @(Get-CimInstance Win32_PnPEntity -OperationTimeoutSec 20 | Where-Object { $_.ConfigManagerErrorCode -ne 0 } | ForEach-Object { $_.Name }) } catch { $F.ProblemDevices = $null }
  return $F
}

# ---------- main ----------

if ($env:LANQ_READY_LIB -eq '1') { return }

if ($Hours -and -not (Test-Hours $Hours)) {
  Write-Host 'lanq-ready: -Hours must look like 00:00-07:00 (HH:mm-HH:mm, start different from end).'
  exit 2
}
$rank = @{ OK = 'OK  '; WARN = 'WARN'; FAIL = 'FAIL'; SKIP = 'SKIP' }
$color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; SKIP = 'DarkGray' }
$facts = Get-Facts $Hours
$checks = Get-Checks $facts
$verdicts = Get-Verdicts $checks $facts
$machine = Get-Machine $facts $verdicts $Hours ([bool]$Redact)

function Write-Out([string]$Text, [string]$Color = 'Gray') {
  if ($Redact) { $Text = Protect-Text $Text $facts }
  Write-Host $Text -ForegroundColor $Color
}

Write-Out "lanq-ready $ToolVersion (read-only: nothing is installed, changed or sent anywhere)"
if (-not $Quiet) {
  Write-Out ''
  foreach ($c in $checks) {
    Write-Out ("[{0}] {1}: {2}" -f $rank[$c.status], $c.title, $c.detail) $color[$c.status]
    if ($c.advice -and $c.status -ne 'SKIP') { Write-Out "       advice: $($c.advice)" 'DarkGray' }
    if ($c.status -eq 'SKIP' -and $c.needsAdmin) { Write-Out '       skipped (needs admin); re-run elevated to fill this in' 'DarkGray' }
  }
}
Write-Out ''
Write-Out 'Verdicts'
foreach ($k in $verdicts.Keys) { Write-Out ("  {0,-15} {1}" -f $k, $verdicts[$k]) $color[$verdicts[$k]] }
$ready = ($verdicts.worker_git -ne 'FAIL') -or ($verdicts.worker_archive -ne 'FAIL')
if (-not $Quiet) {
  Write-Out ''
  Write-Out '# Paste into machines.yml (confirm the placeholders):'
  foreach ($l in (Format-Snippet $machine $verdicts)) { Write-Out $l 'Cyan' }
}
if (-not $ready) {
  Write-Out ''
  Write-Out 'Blockers:' 'Red'
  foreach ($c in $checks) { if ($c.status -eq 'FAIL') { Write-Out "  - $($c.title): $($c.detail)" 'Red' } }
  if (-not $facts.GitVer -and -not $facts.TarBsd) { Write-Out '  - neither git nor built-in tar found: no transfer mode works' 'Red' }
}

if ($Json) {
  try {
    $hostName = $facts.Hostname; $userName = $facts.User
    if ($Redact) { $hostName = '<redacted>'; $userName = '<redacted>' }
    $report = [ordered]@{
      schema = 'lanq-ready/v1'; tool = [ordered]@{ name = 'lanq-ready'; version = $ToolVersion }
      generatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
      host = [ordered]@{ hostname = $hostName; user = $userName; os = "$($facts.Caption) build $($facts.Build)"; arch = $facts.Arch }
      verdicts = $verdicts
      checks = @($checks | ForEach-Object { [ordered]@{ id = $_.id; title = $_.title; status = $_.status; detail = $_.detail; advice = $_.advice; needsAdmin = $_.needsAdmin } })
      capabilities = @($machine.capabilities | Where-Object { $_ -ne 'windows' })
      suggestedMachine = $machine
    }
    $text = $report | ConvertTo-Json -Depth 6
    if ($Redact) { $text = Protect-Text $text $facts }
    $full = $Json
    if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path (Get-Location).ProviderPath $Json }
    [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($false)))
    if (-not $Quiet) { Write-Out "JSON report written to the path you gave." }
  } catch { Write-Out "Could not write the JSON report: $($_.Exception.Message)" 'Yellow' }
}
if ($ready) { exit 0 } else { exit 1 }
