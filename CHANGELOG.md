# Changelog

## 0.3.0 (unreleased)

- Windows: works for a build account that is denied WMI/CIM (a non-admin user on a PC tuned as a server), where
  0.2.0 showed 0 GB RAM, 0 CPUs and "Windows (unreadable)". Memory then comes from .NET's `Microsoft.VisualBasic`
  `ComputerInfo`, the Windows version and CPU name from the registry, logical CPUs from the environment and free disk
  space from `DriveInfo`. Everything stays read-only.
- Windows: every WMI/CIM query now uses `-ErrorAction Stop`. "Access denied" is a non-terminating error in PowerShell,
  so in 0.2.0 the fallbacks never ran and the errors were printed on stderr.
- Windows: OpenSSH Server no longer FAILs as "installed but not running" when the account may not read the service status
  (`OpenService` access denied for a non-admin build user). Run over ssh, it is reported running (the session came in
  through it), with the start type from the registry; run locally, the check is SKIP with that reason.
- Windows: without WMI, Windows 11 is no longer shown as "Windows 10" (the registry `ProductName` still says Windows 10 on 11).
- Wider .NET SDK search, the same folders LanQueue 0.8 searches. Windows: `DOTNET_ROOT` (and `_X64`, `_ARM64`),
  Program Files, `%LOCALAPPDATA%\Microsoft\dotnet`, `%USERPROFILE%\.dotnet`, the `InstalledVersions` registry keys, and
  `DRIVE:\dotnet` and `DRIVE:\DIR\dotnet` on every fixed drive. Linux and macOS: `DOTNET_ROOT` (and `_X64`, `_ARM64`),
  `~/.dotnet`, `/etc/dotnet/install_location*`, `/usr/share`, `/usr/lib`, `/usr/lib64`, `/opt/dotnet`, the snap,
  `/usr/local/share/dotnet` and the Homebrew folders. An SDK counts only when its folder has `dotnet.dll` next to a
  `dotnet` executable, so a runtime-only install is not reported as an SDK. The search starts no process and stops after 5 seconds.
- New `dotnet.path` WARN: when the newest SDK is not the `dotnet` on PATH, the check names that folder and the
  `machines.yml` snippet and `--json` `suggestedMachine` add `path_prepend: [FOLDER]` and `env: DOTNET_ROOT`
  (LanQueue 0.8+ keys). The folder is redacted like other free text under `--redact`.

## 0.2.0 (2026-11-09)

- One-line verdict at the top and bottom of the report: `READY`, `READY WITH WARNINGS (n)` or `NOT READY (n blockers)`,
  then numbered next steps (WARN/FAIL only, blockers first), each with the exact command or settings path for the OS
  and whether it needs admin/root. Replaces the old "Blockers:" list and the advice lines under each check.
- Wake-on-LAN readiness (for LanQueue 0.5's `wake:`): Windows reads the wired adapter, its MAC, "Wake on Magic Packet",
  `powercfg /devicequery wake_armed` and Fast Startup (`HiberbootEnabled`); Linux reads the wired NIC from `/sys/class/net`
  and `ethtool`'s `Wake-on` when readable without root, otherwise prints the command to check it.
- `machines.yml` snippet: `max_jobs` and `min_free_mem_gb` sized from RAM and logical CPUs for every machine (under 6 GB 1,
  8 GB 2, 16 GB 3-4, 32 GB+ 6-8, capped by CPUs; 1.5 / 2 GB headroom), a `wake:` block (commented out unless the `wol`
  check is OK), `git` as a detected capability, a commented `allowed_hours` example, low-RAM `env:` caps for .NET and Node (commented),
  `<mac>` placeholder under redaction. `allowed_hours` comments now say the worker's own clock (LanQueue 0.4+).
- "Suited for" hint (light / medium / heavy, "+ container builds" when Docker answers), the thresholds LanQueue 0.5.1+ `lanq health` uses (24-31 GB counts as the top band; heavy counts logical CPUs).
- Windows: Windows 10 end-of-support note (22H2 is the last version; works while updates/ESU apply); new `ssh.firewall`
  (an enabled inbound rule for TCP 22, not only the named rule) and `ssh.shell` (OpenSSH default shell must be cmd.exe or
  PowerShell) checks, both part of the worker verdicts; page file size.
- Linux: distribution end-of-life WARN from `/etc/os-release` and a small embedded table; `ssh.password` security note for
  `PasswordAuthentication yes` (or unset, which defaults to yes), from `sshd -T` as root or `sshd_config` plus `Include`
  files; automatic suspend WARNs (with the `systemctl mask` command) only when detectable without root (logind
  `IdleAction`, a laptop's `HandleLidSwitch`, the user's GNOME idle action), and when a display manager is active but
  no session bus is available (over SSH) it WARNs that GNOME/GDM suspend on AC by default, with the gsettings and mask
  commands; otherwise unmasked targets are OK and the row says what was checked; swap size.
  End-of-life dates are the last month of standard support (Alpine from alpinelinux.org/releases; Fedora 41 2025-12;
  Ubuntu 16.04 2021-04); releases older than the table say so instead of a made-up date; the advice mentions Ubuntu
  Pro/ESM and Debian LTS honestly.
- Low disk says the free space and the recommended minimum.
- Fix hints: the `administrators_authorized_keys` icacls hint grants Administrators and SYSTEM by SID (`*S-1-5-32-544`,
  `*S-1-5-18`), so it works on non-English Windows; the build-user hint says to add a new local user to Users by SID
  (`Add-LocalGroupMember -SID S-1-5-32-545`) and log on once before creating its `.ssh` folder; low-RAM boxes get a
  `-m:1` comment for `dotnet build`/`dotnet test` instead of an MSBuild env var.
- `-Out FILE` / `--out FILE` also saves the human report. It only creates a NEW file (Windows CreateNew; sh: a temp file
  in the same folder linked into place with `ln`, which fails on any existing name, including a FIFO, device or link);
  an existing file is never overwritten (exit 2). A trap removes the temp file on INT/TERM/EXIT; a folder starting
  with `-` is passed as `./-...`; when `ln` fails the message says the filesystem may not support hard links (FAT/exFAT).
- Windows firewall: the named rule `OpenSSH-Server-In-TCP` decides (disabled = WARN, readable without admin); the
  port-22 scan runs only when the rule is missing, and SKIPs (needs admin) when access is denied. The hint checks for a
  Private network and limits the rule to `-Profile Private -RemoteAddress LocalSubnet`.
- Fast Startup WARNs when `HiberbootEnabled=1` and hibernation is effectively on (`HKLM\SYSTEM\CurrentControlSet\Control\Power`:
  `HibernateEnabled` if present, else `HibernateEnabledDefault`, and on when both are missing, as on many PCs). Windows 10 ESU advice: Settings > Windows Update > Enroll now.
- Under redaction the snippet's `wake:` block is commented out, since `<mac>` is a placeholder.
- `SHA256SUMS` is produced only by the release workflow; a test fails if a copy is committed.
- JSON report (schema `lanq-makeready/v1`, backward compatible: only optional fields added): `summary`, `suitedFor`,
  `suggestedMachine.min_free_mem_gb`, `suggestedMachine.wake`. New check ids: `ssh.firewall`, `ssh.shell` (Windows),
  `ssh.password` (Linux), `swap`.
- Guards: the ps1 AST allow-list adds `Get-NetAdapter`, `Get-NetFirewallPortFilter`, the `powercfg /devicequery wake_armed`
  probe and the `-Out` write (`File.Open` with CreateNew, only in `Save-OutFile`); the sh guard allows exactly
  the three `--out` temp-file lines (`mktemp`, `ln --`, `rm -f --` on the temp file) and the `> "$_otmp"` redirection,
  and now flags `ethtool -s/-K`, `wol`, `nmcli`, `swapon` and any other `ln`/`rm`. Script size limit 900 lines.

## 0.1.0 (2026-11-09)

- First release: read-only worker-readiness scan for Windows (PowerShell 5.1+), Linux and macOS (POSIX sh),
  human report + JSON (`schema/report.v1.json`, stdout mode for piping over SSH), suggested LanQueue `machines.yml` entry.
