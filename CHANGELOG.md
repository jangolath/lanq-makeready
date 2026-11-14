# Changelog

## 0.6.0 (unreleased)

- **The Defender ladder** (Windows, `lanq-makeready-fix.ps1 -Tune`). Defender scanning of build folders now has two
  fixes, each with its own switch, each needing `-BuildUser <the dedicated local build account>`, each confirmed by
  typing the path it makes (no `-Yes`, no path argument). Details: docs/TUNE.md, "The Defender ladder".
  - **`devdrive.create`** (`-CreateDevDrive [-SizeGB 100]`, 50 to 65536): a VHDX-backed Dev Drive in
    `%ProgramData%\lanq-makeready\devdrive` (Administrators and SYSTEM only), made with diskpart (fixed input),
    `Initialize-Disk`, `New-Partition` and `Format-Volume -DevDrive`, checked with `fsutil devdrv query` (trusted,
    antivirus allowed, WdFilter attached), with `<letter>:\lanq-work` on it. No exclusion. Windows 11 build
    22621.2338 or later. Undo never removes a Dev Drive; it says how. Whether the VHDX comes back by itself after a
    restart is checked on the pool before release (no startup task yet).
  - **`defender.exclude`** (`-DefenderExclusions`): makes `%SystemDrive%\lanq-work` itself, with its owner
    (Administrators) and fixed permissions in one call (the build user may add and change files inside, never rename,
    delete or re-permission the folder; an inherited OWNER RIGHTS entry stops it from re-permissioning its own files),
    reads it back, runs a positive control with the EICAR test file, adds the one exclusion `<drive>:\lanq-work\`,
    reads it back (exactly one new entry, exactly that string), and checks that the test file stays inside lanq-work
    and is still caught in `lanq-work-x`, `lanq-workx`, `lanq-work.x`, `lanq-work.`, `lanq-work` with a trailing space
    and a stream. Any miss rolls the exclusion back (exit 1). Undo removes only the exclusion; the folder is kept.
  - **Not offered** (report only, exit 0) on any doubt: Defender not active, real-time protection off or one-way,
    exclusions hidden, managed by policy or MDM, Defender for Endpoint onboarded, an existing exclusion that covers
    lanq-work (reported, never recorded or undone) or a variant of it, a drive that is not fixed, internal and NTFS,
    a Dev Drive, a drive root others may rename in or re-permission, case sensitivity, or a lanq-work this script
    cannot vouch for. An existing lanq-work counts only when a trusted fix record matches its volume GUID, file id and
    permissions hash; there is no marker file.
  - `-BuildUser` must be a local, enabled user account (exit 2 otherwise); the prompt shows its SID and warns when it
    is an administrator. `NUGET_PACKAGES` goes per job only (machines.yml `env:`); the script never sets it.
  - The EICAR test file is built at run time from a transformed constant; no script contains it. No P/Invoke or
    Add-Type in the product scripts.
- **Fix record**: new ids `defender.exclude` and `devdrive.create` and their state shapes, additive under
  `lanq-makeready-fix/v1` (a 0.5 script rejects a record that holds them, exit 2).
- **Tune scan**: `defender.paths` gets a lanq-work row and may carry fix id `defender.exclude` (a change for lanq,
  which maps fix ids through its own table); the advice is now the ladder. New checks `defender.drift` (security,
  needs admin: the lanq-work exclusion against its record, the folder's owner, permissions, file id and volume, and a
  sample of its top two levels) and `devdrive` (fix id `devdrive.create`; WARN when antivirus is disallowed on a Dev
  Drive). Exclusion entries with a variable are no longer expanded in the scanning account's context (Defender expands
  them as SYSTEM). fsutil runs only from a fixed allow-list of reads. The scan stays under 800 lines.
- **Linux**: `lanq-makeready-fix.sh` refuses `--defender-exclusions` and `--create-dev-drive` with exit 2 (Windows
  only).
- **Tests**: the review's matrix (A1-A10, B1-B8, C1-C4, D1-D7, E1-E9, G1-G4; the list is in docs/TUNE.md) written
  first. Fakes in `tests/fix.ps1` and `tests/tune.ps1` (folders only in a temp sandbox, harmless test text, never
  the real EICAR file), the guard extended with mutants, and a new CI pass, `tests/real-defender.ps1` ("Pass 4
  (defender)"): a real apply on a disposable runner, two local non-admin users and LogonUser probes, drift and undo.
  The EICAR checks there are best effort (the runner image turns real-time protection off; the pass prints a notice
  and simulates only the scan results); E1-E8 and G1 run on a pool PC before release.
- Version 0.6.0 in the scanners, tune scripts and fix scripts. The scanners are otherwise unchanged.

## 0.5.0 (2026-11-14)

- **Tune scan**, in new, separate, read-only scripts: `lanq-makeready-tune.ps1` (Windows PowerShell 5.1 and
  PowerShell 7) and `lanq-makeready-tune.sh`. It reports what slows a worker down or keeps it busy during the job
  window. Statuses OK, INFO, WARN and SKIP (never FAIL); it never changes readiness, and the exit code is always 0
  (2 for bad arguments). Arguments like the scanner's (`-Json <path|->`, `-Redact`, `-Hours`) plus `-WorkRoot`
  (LanQueue's work_root rule). JSON schema `lanq-makeready-tune/v1` (`schema/tune.v1.json`). See docs/TUNE.md.
- Time: a 90-second deadline for the whole scan and a budget per probe; a probe over its budget reports SKIP
  "time budget". Driver dates come from `Get-NetAdapter` and the Class registry (15 s), never `Win32_PnPSignedDriver`.
- Windows checks: `power.plan`, `power.usbsuspend`, `startup.vendor`, `vendor.services`, `vendor.tasks`, `sysmain`,
  `search.index`, `do.mode`, `wu.reboot`, `visual.fx`, `dotnet.env`, `wsl.reclaim`, `defender.paths` (admin; report only; the
  exclusion list is compared inside the probe and never printed), `defender.schedule` (the scheduled scan against
  `-Hours`, in place of a CPU-load check), `av.other` (Security Center and AMRunningMode), `pagefile`, `disk.health`,
  `disk.full` (over 90%), `drivers.age`, `cache.sizes` (NuGet HTTP cache and Windows Update downloads only),
  `autologon.plain` (tests that `DefaultPassword` exists, never reads it), `onedrive.workroot`, `bios.power` (a
  reminder) and `maint.schedule` (automatic maintenance and defrag against `-Hours`).
- **Tune fixes** in `lanq-makeready-fix.ps1 -Tune`, with the same refusals, confirmation, record and undo:
  `power.cpu`, `power.usbsuspend`, `startup.vendor`, `vendor.services`, `vendor.tasks`, `sysmain`, `do.mode` (offers 0,
  HTTP only), `dotnet.env` and `defender.scantime` (needs `-Hours`). Fix ids are additive under
  `lanq-makeready-fix/v1`; a 0.4 script rejects a record that holds one (exit 2).
  - StartupApproved: no value means enabled, `Run32` handled, the account SID recorded; an HKCU entry is undone only
    by the same account.
  - Services: Start and DelayedAutostart recorded from the registry and put back with `sc.exe` (`delayed-auto`).
  - Scheduled tasks under `\Microsoft\` are never touched; access denied is skipped.
  - Undo re-checks service, task and Run entry names against the curated list plus an append-only retired list, and
    every name and path in a record has a fixed shape. A record holds at most 64 changes.
- **Defender exclusions are report-only.** Defender exclusions are not automated in 0.5.0: whether a folder can be trusted (who can write to it, where it really is, what runs from it) is hard to verify safely from a script, and a wrong exclusion silently turns off scanning. `defender.paths` says, per
  folder, whether real-time scanning covers it and gives the manual procedure (Dev Drive first; otherwise lock a
  top-level build folder down with icacls and use `Add-MpPreference`); docs/TUNE.md has the steps. The fix script
  has no exclusion fix: `-DefenderExclusions` exits 2 with a pointer to that page.
- Names read from the PC (Run entries, services, tasks, drivers) are printed without control or bidi characters and
  cut at 80 characters; detail and advice at 1024. Under `-Redact` account SIDs in task names are redacted too.
- `defender.scantime` is not offered when an hour after the window is still inside it (windows of 23 hours or more).
- Report only, never fixed: cache clean-up, the Windows Update restart policy (`wu.reboot`) and the other checks
  without a fix id.
- The PC-maker list is short, generic across makers, kept in code and identical in the tune and fix scripts (a test
  checks it); every entry has a literal name, no bare wildcards.
- Agents may run the tune scan only when the developer asks; they never run the fix script.
- Tests: `tests/tune.ps1` (one fixture per status per check, the read-only AST guard with mutants, an 800-line cap,
  redaction, a schema check, a real read-only run) on PowerShell 5.1 and 7; tune fixes against fakes in
  `tests/fix.ps1`; real apply and undo of `power.cpu`, `do.mode`, `sysmain` and `defender.scantime` on a disposable
  Windows runner. PSScriptAnalyzer 1.23.0 runs in CI, warnings only.
- The release ships, checksums and attests the tune scripts and `tune.v1.json`; its Windows tests run first.
- New `lanq-makeready-tune.sh`:
  - a read-only tuning report for Linux workers (`lanq-makeready-tune/v1` JSON with `--json`);
  - checks: CPU governor, swappiness, inotify limits, journald size (persistent and `/run`), unused services
    (cups-browsed flagged as a security item), automatic update reboots against `--hours`, package cache, SSD TRIM,
    SMART health (root), thermal throttling, and disks over 90% full;
  - `--work-root` (lanq's `work_root` rule) and `--hours`, a 90 s internal deadline, and SKIP for host checks inside a
    container;
  - on macOS it reports "no tune checks". Tuning never changes readiness or the exit code.
- `lanq-makeready-fix.sh --tune`:
  - four new reversible fixes: `sysctl.tune` (inotify limits through `/etc/sysctl.d/99-zz-lanq-makeready.conf`),
    `journald.cap` (a journald size cap; the trimmed logs cannot be restored), `services.unused` (`disable --now` of
    cups, cups-browsed, bluetooth, ModemManager; never masks, avahi stays report only), `fstrim.timer`;
  - the new fix ids are additive under `lanq-makeready-fix/v1`, and older fix scripts reject records that hold them;
  - undo checks service names against an append-only list and a name shape.
- Tests:
  - `tests/tune.sh` (fake root: one case per status per check, a read-only guard with injected mutations, a line cap
    of 800, redaction, JSON shape, the 90 s deadline, containers, macOS);
  - tune-fix tests in `tests/fix.sh` (fakes);
  - a `--tune` leg in `tests/real-fix.sh` for disposable CI runners (cups, the sysctl drop-in, fstrim.timer).
- Linux review fixes: `journald.cap` never overrides an admin's cap (it writes only the caps not already set, and
  removes a `journald.conf.d` folder it created when undone); desktop detection uses logind x11/wayland sessions;
  `bluetooth` is never offered while a Bluetooth input device is present; `--tune` refuses to apply, and `--undo` refuses tune items,
  inside a container (Docker, Podman, LXC, systemd-nspawn; exit 3), `--tune --dry-run` still works there, and WSL 2
  counts as a host; `journald.cap` undo compares only the drop-in and its folder, so a cap you add later does not block it.
- Both tune scripts write the same JSON: `host.hostname` and `host.user` are `"<redacted>"` with `-Redact`/`--redact`, `context.hours` is present when given, and `summary` has `ok`, `info`, `warn` and `skip` (`host.os` is free text: `windows`, or the Linux distribution name).
- Version 0.5.0 in the scanners, tune scripts and fix scripts. The scanners are otherwise unchanged.

## 0.4.1 (2026-11-13)

### Security

- The Linux safe-folder check (before `path_prepend` is suggested for a .NET SDK outside PATH) now also reads POSIX
  ACLs. Before, it judged the mode bits only, and with an ACL the group bits are the mask, so a folder owned by
  `root:root` with `drwxrwxr-x+` and a `user:<other>:rwx` entry passed. Now, with `getfacl` installed, a named
  `user:` or `group:` entry that can write (its effective rights, under the mask) makes the folder open unless it is
  root, you, or your own private group. A `default:user:` or `default:group:` entry that can write (raw rights) makes
  it open too, since the next SDK or shared framework folder inherits it. getfacl failing or timing out, or output
  with no `user::` line, makes it open. A sticky parent folder (like `/tmp`) is still fine.
- Without `getfacl`: the `ls` ACL marker (`+`), `ls` failing, or a line without the marker column makes the folder
  open. busybox `ls` shows no marker, so there any group write makes it open (with an ACL the group bits are the
  mask). An ACL with only `default:` entries is not seen on busybox without getfacl: install the `acl` package.
- `getfacl` and `ls` run under the scanner's time limit (`run_t`, 5 s). SECURITY.md's "Bounded" now says which quick
  local reads are not wrapped.
- On macOS the check is skipped (macOS ACLs are not read; a Mac never gets a machines.yml entry). NFSv4 ACLs and
  SELinux are not read. Only folders and `dotnet` itself are checked, not the files inside them (documented; as
  before).
- The scanner's line cap in the tests is raised from 980 to 1050 for this check.
- The scanner stays read-only: `getfacl` and `ls` are on its test-time command allow-list, and `setfacl` is not.
- The fix scripts are unchanged apart from the version.

## 0.4.0 (2026-11-13)

- **Fix mode**, in new, separate scripts: `lanq-makeready-fix.ps1` (Windows PowerShell 5.1 and PowerShell 7) and
  `lanq-makeready-fix.sh` (POSIX sh, Linux with systemd; on macOS it says there are no fixes and changes nothing).
  The scanner never changes anything; the fix script changes only what you confirm, one item at a time, at the PC.
  LanQueue does not embed or run it. See README "Fix mode".
- Fixes (v1), each offered only when the scanner would report the problem. Each one re-reads its state just before the
  change and verifies the result after it.
  - Windows: `ssh.start`, `ssh.auto`, `power.sleep` (AC timeouts of the active plan), `longpaths.on`, `git.longpaths`
    (git from Program Files only) and `ssh.aclkeys`. Before you confirm `ssh.aclkeys`, it lists every key in
    `administrators_authorized_keys`.
  - Linux: `ssh.start` (`systemctl enable --now` of the ssh or sshd unit) and `power.sleep` (`systemctl mask` of
    the sleep targets that are not masked yet).
- Refusals (exit 3, nothing changed): over SSH (the SSH variables, an `sshd` parent process, logind's remote session
  on Linux, session 0 on Windows when the parent processes cannot be read), from stdin or a string (`sh -s`, `sh -c`,
  a pipe, `[scriptblock]::Create`, `iex`), without an interactive console, and on Windows when a function or alias
  shadows a function or cmdlet the script uses. The SSH check is a tripwire against accidental or naive remote use,
  not a barrier against a determined admin. There is no `--yes`, and the script never elevates itself. Without admin or root, each fix
  is skipped with a note.
- `-WhatIf` / `--dry-run` shows every fix that applies and its undo, and changes nothing. `-List` / `--list` shows the
  undo records.
- Undo record (schema `lanq-makeready-fix/v1`, [schema/fix-record.v1.json](schema/fix-record.v1.json),
  [docs/FIX-RECORD.md](docs/FIX-RECORD.md)). Each item is written as `pending` before the change and updated to
  `applied` or `failed` after it. Records are kept in `%ProgramData%\lanq-makeready` (created with its permissions in
  one step: owned by Administrators, only Administrators and SYSTEM) or `/var/lib/lanq-makeready` (root, 700/600). An
  existing record folder that is not like that stops the run before the first question. The Windows `power.sleep`
  record keeps the active power plan, and undo acts only while that plan is still active.
- `-Undo FILE` / `--undo FILE` goes newest first and confirms each item. It acts only when the state is still what the
  fix left ("changed since; left alone" otherwise), and marks a `pending` item whose change was never made as `skipped`.
  It reads only `fix-<time>.json` records directly in the record folder, and rejects (exit 2) a record that someone
  other than an admin or root could have written, or one with any field outside its fixed shape. It never runs text
  from the record, puts back a keys-file DACL only when Administrators and SYSTEM keep full control (checked on what it
  writes), and checks the file's DACL again afterwards. `ssh.aclkeys` is not offered when the file has explicit entries
  for other accounts, which `icacls /grant` would leave.
- Exit codes: 0 done or nothing to do, 1 a change or undo failed, an unsafe record folder, or undo without admin or
  root, 2 bad arguments or a rejected record, 3 refused.
- Tests: `tests/fix.ps1` and `tests/fix.sh` run every apply and undo against fakes. A guard (AST allow-list for
  PowerShell, command words for sh) allows changes only inside one `FIXES` block, and injected mutations prove it. The
  tests also cover the refusals, a tampered record, and a check that the scanner is unchanged and still read-only.
- CI: real apply and undo on throwaway GitHub-hosted runners only: Windows (PowerShell 5.1 and 7: powercfg, long paths,
  git `--system`, the sshd service when the image has it, the keys-file ACL) and Ubuntu with systemd (ssh unit, sleep
  targets). The drivers refuse to run anywhere else. shellcheck also covers the fix scripts.
- Release: `lanq-makeready-fix.ps1`, `lanq-makeready-fix.sh` and `fix-record.v1.json` are new release assets, listed
  in `SHA256SUMS` with build attestations. Release tests also run `tests/fix.sh`.
- Scanner: reports version 0.4.0. No behaviour change; it stays read-only.
- `tests/run.ps1`: removed stray control bytes (a vertical tab, BEL and backspaces where `\v`, `\7` and `\b` were meant
  in three paths).

## 0.3.0 (2026-11-10)

- Windows: works for a build account that is denied WMI/CIM (a non-admin user on a PC tuned as a server), where
  0.2.0 showed 0 GB RAM, 0 CPUs and "Windows (unreadable)". Memory then comes from .NET's `Microsoft.VisualBasic`
  `ComputerInfo`, the Windows version and CPU name from the registry, logical CPUs from the environment and free disk
  space from `DriveInfo`. Everything stays read-only.
- Windows: every WMI/CIM query now uses `-ErrorAction Stop`. "Access denied" is a non-terminating error in PowerShell,
  so in 0.2.0 the fallbacks never ran and the errors were printed on stderr.
- Windows: OpenSSH Server no longer FAILs as "installed but not running" when the account may not read the service status
  (`OpenService` access denied for a non-admin build user). Run over ssh, it is reported running (the session came in
  through it), with the start type from the registry; run locally, the check is SKIP with that reason.
  `sshd.exe` without a registered service is still a FAIL.
- Windows: without WMI, Windows Server Core counts as a server (it was taken for a client OS).
- Windows: without WMI, Windows 11 is no longer shown as "Windows 10" (the registry `ProductName` still says Windows 10 on 11).
- Wider .NET SDK search, the same folders LanQueue 0.8 searches. Windows: `DOTNET_ROOT` (and `_X64`, `_ARM64`),
  Program Files, `%LOCALAPPDATA%\Microsoft\dotnet`, `%USERPROFILE%\.dotnet`, the `InstalledVersions` registry keys, and
  `DRIVE:\dotnet` and `DRIVE:\DIR\dotnet` on every fixed drive. Linux and macOS: `DOTNET_ROOT` (and `_X64`, `_ARM64`),
  `~/.dotnet`, `/etc/dotnet/install_location*`, `/usr/share`, `/usr/lib`, `/usr/lib64`, `/opt/dotnet`, the snap,
  `/usr/local/share/dotnet` and the Homebrew folders. An SDK counts only when its folder has `dotnet.dll` next to a
  `dotnet` executable, so a runtime-only install is not reported as an SDK. The search starts no process and stops after 5 seconds.
- New `dotnet.path` WARN: when the newest SDK is not the `dotnet` on PATH, the check names that folder and the
  `machines.yml` snippet and `--json` `suggestedMachine` add `path_prepend: [FOLDER]` and `env: DOTNET_ROOT`
  (LanQueue 0.8+ keys). The `dotnet` on PATH is searched first and wins a tie; preview SDKs never count as the newest; a
  snap install keeps its stable `/snap/dotnet-sdk/current` folder. The folder is redacted like other free text under
  `--redact` (the whole profile folder, also when it is not named after the account).
- `path_prepend` is suggested only for a folder other local users cannot plant code in. Trusted: Administrators, SYSTEM,
  TrustedInstaller (root on Linux and macOS), the members of the local Administrators group, and the account itself. On
  Windows the folder, its `dotnet.exe`, `sdk` and the newest SDK folder, `host`, `host\fxr`, `shared`,
  `shared\Microsoft.NETCore.App` and their version folders must have a trusted owner, a DACL (not NULL), and give nobody
  else more than read/execute; every parent folder must have a trusted owner and let nobody else delete or rename what is
  in it; a junction or link on the path is refused. On Linux and macOS the same items must be owned by root or the account
  and writable by nobody else (a group only when it is root's or the account's own private group), and each parent
  folder of the path as given and as resolved must not be writable by others or another group unless sticky; POSIX and
  macOS ACLs are not read. Only absolute folders are searched. Otherwise the check says so and the snippet carries a
  comment instead (on a shared PC, a world-writable folder could otherwise make jobs run a planted `dotnet`).
- SSH keys: the check reads `AuthorizedKeysFile` from `sshd_config` the way sshd does (a matching `Match all`, `User` or
  `Group` block before the global value, `%h`, `%u`, `%%` and `__PROGRAMDATA__`), so keys in a central file such as
  `C:\ProgramData\ssh\<user>_authorized_keys` no longer give a false "no authorized_keys" WARN. When `sshd_config`
  cannot be read, the WARN says keys may be set up elsewhere. Also `AuthorizedKeysFile=value`, `%U`, `Match` keywords in
  any case, `Match Group` patterns, and (Linux) a `Match` in an `Include`d file ending with that file. A key file on a
  network share is never read.

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
