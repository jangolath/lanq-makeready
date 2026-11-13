# lanq-makeready — design (v0.4)

Name approved by the owner 2026-11-08 (formerly the working name lanq-ready).

## What it is

A single script (the scanner) the owner of an old PC downloads and runs **on that PC**. Read-only. It answers, in plain
language:

1. Can this machine be a LanQueue worker (git mode / archive mode)? What is missing?
2. Can it run the common toolchains: .NET 10 SDK, Docker, Node, Python, git? Supported / "not supported but may run" / will not work.
3. Will it survive an overnight job (sleep, hibernate, pending reboot, disk type/space, RAM)?
4. What is slowing it down (startup items, low disk, HDD, big temp folders, Defender scanning the work folder) — **report only**.

Then it prints a ready-to-paste `machines.yml` entry for LanQueue, and optionally writes a JSON report.

## Hard rules (safety is the product)

- **Read-only.** The scanner never installs, uninstalls, updates, changes settings, disables services, edits the registry,
  or touches drivers. Every fix is printed as advice (often an exact command the user may choose to run themselves).
  The scanner has no `--fix` flag. Fixes live in separate scripts with their own rules (see "Fix mode (0.4)").
- **No admin required.** Checks that need admin print `skipped (needs admin)`. Running elevated is allowed and just
  fills in those rows.
- **No network calls.** No telemetry, no update check, no downloads. (Exception: none.) It does not resolve or ping anything.
- **No secrets read or printed.** Does not read SSH private keys, only checks that `authorized_keys` exists and
  (Windows admin case) the ACL owner/entries. Usernames/hostnames are printed only in the local report; the JSON
  has `--redact` to drop hostname, username and paths.
- **No dependencies.** Windows: Windows PowerShell 5.1 built-ins only (no modules from the gallery, no .NET install).
  Linux/macOS: POSIX `sh` + coreutils/procfs; optional tools (`docker`, `git`, `systemctl`, `smartctl`) are probed
  with `command -v` and their absence is itself a finding.
- **Bounded.** Every external command call has a timeout (Windows: jobs with `Wait-Job -Timeout`; sh: `timeout` when
  present). Never walks the whole disk: folder sizes only for a fixed list of known temp/cache folders, with a cap.
- **Honest verdicts.** Three words with fixed meanings: `OK`, `WARN` (works, but degraded or unsupported-but-may-run),
  `FAIL` (will not work for that role). Plus `SKIP` (could not check, with reason).
- Small: at most 900 lines per script (a test enforces it).
- The only writes are files the user names: `--json PATH` and `--out FILE`; `--out` creates a NEW file only (never overwrites).

## Files

```
lanq-makeready/
  lanq-makeready.ps1          # Windows (PowerShell 5.1+, also runs on pwsh 7)
  lanq-makeready.sh           # Linux + macOS (POSIX sh)
  lanq-makeready-fix.ps1      # fix mode, Windows (0.4)
  lanq-makeready-fix.sh       # fix mode, Linux with systemd (0.4)
  schema/report.v1.json   # JSON Schema for --json output
  schema/fix-record.v1.json   # JSON Schema for the fix undo record
  tests/                  # see Testing
  docs/DESIGN.md          # this file
  docs/FIX-RECORD.md      # the undo record, explained
  README.md               # how to download, verify (SHA256 + gh attestation verify), run; never irm|iex
  LICENSE                 # MIT (same as LanQueue)
```

## CLI

```
lanq-makeready.ps1 [-Json <path>] [-Redact] [-Hours "00:00-07:00"] [-Quiet]
lanq-makeready.sh  [--json <path>] [--redact] [--hours 00:00-07:00] [--quiet]
```
- `--hours` only feeds the suggested `allowed_hours` in the machines.yml snippet (validated HH:MM-HH:MM).
- Exit code: 0 = worker-ready (at least one transfer mode OK), 1 = not ready (lists blockers), 2 = bad arguments.

## Checks (id → role(s))

Each check yields `{ id, title, status, detail, advice, needsAdmin }`.

Platform
- `os.version` — OS name/version/build/edition; Win10: past EOL 2025-10-14, consumer ESU to 2027-10-12 → WARN.
- `os.arch` — x64/arm64 OK; 32-bit x86 Linux → FAIL for .NET; 32-bit Windows → FAIL for .NET 10 SDK + Docker.
- `cpu` — model, cores, logical; AVX2/SSE4.2 informational only (note .NET 11 raises x64 floor to x86-64-v2).
- `ram` — total/free GB. < 4 GB WARN (builds will swap), < 2 GB FAIL for .NET SDK builds.
- `disk` — free GB on system drive (and on the suggested work folder drive); SSD vs HDD (Windows `Get-PhysicalDisk`
  MediaType when available, Linux `/sys/block/*/queue/rotational`). HDD → WARN (slow builds). < 10 GB free → FAIL.

LanQueue worker
- `ssh.server` — Windows: OpenSSH Server capability installed (needs admin to query capability → fall back to
  `Get-Service sshd`), service running, startup type Automatic, firewall rule `OpenSSH-Server-In-TCP` enabled (if
  queryable), default shell (registry `HKLM:\SOFTWARE\OpenSSH DefaultShell`; absent = cmd.exe, which LanQueue handles
  by invoking powershell explicitly — report as info). Linux: sshd running (`systemctl is-active ssh|sshd` or `pgrep sshd`).
  macOS: Remote Login (`systemsetup -getremotelogin` needs admin → SKIP otherwise; fall back to `launchctl list | grep ssh`).
- `ssh.keys` — current user's `~/.ssh/authorized_keys` exists and non-empty; on Windows if the user is in
  Administrators (check by SID S-1-5-32-544, never by localized name), check `C:\ProgramData\ssh\administrators_authorized_keys`
  exists and advise a dedicated non-admin build user instead.
- `git` — present + version; Windows: `core.longpaths` true? advise.
- `tar` — Windows: `%SystemRoot%\System32\tar.exe --version` says bsdtar; Linux: GNU tar or bsdtar (busybox → FAIL for
  archive mode, matching LanQueue's own rule); gzip present.
- `longpaths` (Windows) — `LongPathsEnabled`; advise a short work root like `C:\lq`.

Toolchains (informational capabilities; feed the `capabilities:` list)
- `dotnet` — find without relying on PATH and without starting a process: list `sdk/X.Y.Z` folders (with `dotnet.dll`,
  next to a `dotnet` executable) in the folders LanQueue 0.8 searches (0.3.0+): `DOTNET_ROOT` (`_X64`, `_ARM64`), the
  default install folders, `~/.dotnet`, the `InstalledVersions` registry keys / `/etc/dotnet/install_location*`,
  `/opt/dotnet`, the snap and Homebrew folders, and on Windows `DRIVE:\dotnet` and `DRIVE:\DIR\dotnet` on every fixed
  drive (64 folders per drive, 5 s in all). Report SDK majors; when the newest SDK's folder is not the `dotnet` on PATH,
  WARN `dotnet.path` and suggest `path_prepend` + `env: DOTNET_ROOT`.
  Verdict for "can install .NET 10" from the OS table (see docs/research-summary in README): Win11 OK, Win Server
  2012+ OK, Win10 Enterprise/IoT LTSC listed builds OK, consumer Win10 → WARN "not on .NET 10's supported list; usually
  runs; consider Windows 11 or Linux". Linux: glibc ≥ 2.27 (`ldd --version` / `getconf GNU_LIBC_VERSION`) else FAIL;
  musl ≥ 1.2.3 on Alpine. macOS ≥ 15 OK, older WARN.
- `docker` — `docker version` if present (client+server reachable?). Else prerequisites: Windows — virtualization
  firmware flag (`Win32_Processor.VirtualizationFirmwareEnabled`; if `Win32_ComputerSystem.HypervisorPresent` is
  true the firmware flag reads false — treat as enabled), WSL status (`wsl.exe --status`; output is UTF-16 — decode),
  build ≥ 19045 (22H2) for Desktop, RAM ≥ 8 GB for Desktop. < 8 GB: suggest Linux + Docker Engine or Engine inside
  WSL with a memory cap; < 4 GB: containers not recommended. Linux: `/dev/kvm` irrelevant for Engine; cgroup v2 info.
- `node`, `python`, `java`, `go`, `rustc` — present + version only (no verdict beyond OK/missing-info).

Overnight survivability
- `power.sleep` — Windows: `powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE` and `HIBERNATEIDLE` AC values (no admin
  needed); non-zero → WARN with the exact `powercfg /change standby-timeout-ac 0` advice. Laptop on battery /
  lid action info. Linux: `systemctl status sleep.target` masked? / `gsettings` if present → otherwise SKIP.
  macOS: `pmset -g` sleep value.
- `reboot.pending` — Windows: registry keys `...\Component Based Servicing\RebootPending`,
  `...\WindowsUpdate\Auto Update\RebootRequired`, `PendingFileRenameOperations`. Linux: `/var/run/reboot-required`.
- `updates.activehours` — Windows: active hours registry values vs `--hours` window (Windows Update may reboot
  inside the overnight window) → WARN with advice.
- `wol` — Wake-on-LAN for LanQueue's `wake:`. Windows: wired adapter + MAC (`Get-NetAdapter -Physical`), "Wake on Magic
  Packet" (`Get-NetAdapterPowerManagement`, may need admin → SKIP), `powercfg /devicequery wake_armed`, Fast Startup
  (`HiberbootEnabled`). Linux: wired NIC from `/sys/class/net`, `ethtool <if>` "Wake-on" if readable without root.
  WARN when no wired NIC, magic packet off, not armed, or Fast Startup on. The snippet's `wake:` is active only on OK.

Slowdowns (report only, never act)
- `startup` — count + top entries from `Win32_StartupCommand` and HKCU/HKLM Run keys; Linux: enabled user services
  count. Advice: point to Task Manager › Startup / `systemctl --user disable`; never disable anything.
- `temp` — sizes of %TEMP%, `C:\Windows\Temp` (if readable), browser caches not touched/not listed (privacy),
  NuGet/npm caches (`~/.nuget/packages`, npm cache dir) with a 5-second cap per folder.
- `defender` — Windows: real-time protection on; Dev Drive available (build ≥ 22621.2338)? Exclusions are NOT read
  (hidden without admin, and privacy). Advise Dev Drive or a scoped exclusion for the work folder — as advice only.
- `drivers` — report only: count of devices with problem codes (`Win32_PnPEntity` ConfigManagerErrorCode ≠ 0) with
  names; advise Windows Update optional driver updates / vendor site. **Never updates drivers.**

## Verdict and next steps (0.2)

`NOT READY (n blockers)` when no transfer mode works (exit 1); blockers are FAIL checks among os.version, ssh.*, disk,
git, tar (git/tar also when neither transfer tool exists). Otherwise `READY WITH WARNINGS (n)` (every other WARN/FAIL) or
`READY`. Next steps list WARN/FAIL checks, blockers first, each with its advice text and an admin flag from a second
table in the ADVICE region (`$AdviceAdmin` / `advice_admin`). Sizing (`max_jobs`, `min_free_mem_gb`, suited-for tier)
uses the thresholds LanQueue 0.5.1+ `lanq health` uses: under 6 GB → 1 job / light; under 12 GB → 2 / medium; under 24 GB → 3 (4 with
8+ CPUs); else 6 (8 with 16+ CPUs; 24-31 GB is this top band); capped by logical CPUs; heavy = 16 GB+ and 4+ logical CPUs.

## Suggested machines.yml snippet

```yaml
  - name: <hostname-lowercased or "old-pc">
    os: windows|linux            # macOS: print a note that LanQueue v0.3 workers are windows|linux only
    ssh: <user>@<hostname>.lan   # placeholder; user must confirm
    work_root: C:/lq | /srv/lq   # short path; on Windows choose the SSD/most-free fixed drive
    capabilities: [dotnet, node, docker, windows]   # only what was detected AND working
    max_jobs: 1                  # from RAM and CPUs (see "Verdict and next steps")
    min_free_mem_gb: 1.5         # 1.5 under 6 GB, else 2
    transfer: git | archive      # archive when git missing but tar OK
    allowed_hours: "00:00-07:00" # when --hours given (the worker's own clock); else a commented example
    wake: {mac: ...}             # only when the wol check is OK; otherwise commented out
```

## JSON report v1

`{ schema: "lanq-makeready/v1", tool: {name, version}, generatedAt (UTC ISO8601), host: {hostname?, user?, os, arch},
   verdicts: { worker_git, worker_archive, dotnet10, docker, overnight } (OK|WARN|FAIL|SKIP),
   checks: [ {id, title, status, detail, advice, needsAdmin} ], capabilities: [..], suggestedMachine: {...} }`
With `--redact`: hostname, user and any absolute user-profile paths replaced by `<redacted>`.

## Testing

- Verdict logic lives in pure functions that take a facts object/variables, so tests feed fixtures
  (e.g. "Win10 22H2, 4 GB, HDD, no sshd") without needing that machine.
- Windows: Pester if available (Pester 3.4 ships inbox with PowerShell 5.1 — tests must work on 3.4 AND 5.x, or use a
  tiny hand-rolled assert runner to avoid version drift). Also a smoke test: run the script for real with `-Json`,
  parse it, validate required keys, assert exit code in {0,1}.
- sh: a small POSIX test runner sourcing the script with `LANQ_MAKEREADY_LIB=1` (skips main) and asserting verdict
  functions; `shellcheck` clean if available; smoke-run in an Ubuntu and an Alpine container and natively on WSL if present.
- A **read-only guard test**: grep both scripts for mutating commands (`Set-ItemProperty`, `New-Item`, `Remove-`,
  `Stop-Service`, `Set-Service`, `reg add`, `powercfg /change`, `pnputil /add`, `rm `, `sudo`, `systemctl (enable|disable|stop|start)`, `apt`, `Invoke-WebRequest`, `curl`, `wget`, ...)
  outside of advice strings — the advice strings live in a single table so the guard can exclude them.

## Fix mode (0.4)

### Shape

- **Separate scripts.** `lanq-makeready-fix.ps1` (PowerShell 5.1 and 7) and `lanq-makeready-fix.sh` (POSIX sh, Linux
  with systemd; on macOS it says "no fixes for macOS" and exits 0). A `-Fix` switch in the scanner would break the
  scanner's read-only promise and its guard, so the scanner is unchanged and still has no fix table. A test
  (`ScannerUnchangedAndStillReadOnly`) checks that the scanners do not mention the fix script, keep their parameters,
  and report the same version.
- **Released together.** Same tag, listed in `SHA256SUMS`, attested. Not embedded in LanQueue: `lanq` never copies or
  runs the fix script.
- **Local only, confirm each.** It refuses to run over SSH, from stdin or a string, or without an interactive console
  (exit 3). There is no `--yes`. Each fix is shown as check, current state, exact command and undo, then
  `Apply? [y/N]`; the default is no. It never elevates itself: without admin or root each fix is skipped with a note.
- **Short, reversible fix list (v1).** Windows: `ssh.start`, `ssh.auto`, `power.sleep`, `longpaths.on`,
  `git.longpaths`, `ssh.aclkeys`. Linux: `ssh.start`, `power.sleep`. Left out on purpose: installing OpenSSH, firewall
  rules, `ssh.password` (lockout risk), Wake-on-LAN, swap, Docker, and anything that installs, deletes, upgrades or
  touches firmware.
- **Only what the scanner reports.** A fix is offered only for a condition the scanner would WARN or FAIL. The sh
  script carries the scanner's sleep functions unchanged (`logind_values`, `logind_auto_suspend`, `classify_sleep`),
  and a test checks that the copies match.

### One FIXES region

All code that changes the PC is in one `#region FIXES` (ps1) / `# region FIXES` (sh) block, keyed by fix id and mode
(apply or undo):

- `Get-FixCommand` / `fix_command` returns the exact text shown to the user and stored in the record.
- `Invoke-FixChange` / `fix_change` makes the change.

Everything outside the region follows read-only rules. The only other writes are the undo record and, on Windows, the
ACL of the record folder and files.

The guards are tests, like the scanner's:

- **ps1: an AST allow-list.** The mutating cmdlets (`Set-Service`, `Start-Service`, `Stop-Service`, `Set-ItemProperty`,
  `Remove-ItemProperty`, `Set-Acl`) may appear only inside `Invoke-FixChange`. The one exception is `Set-Acl` in
  `Set-FixRecordAcl`, which may only use one of the two fixed record SDDLs. `Invoke-Native` (the only process launcher)
  may run outside the region only with five fixed read argument lists (`powercfg /q`, `git config --get`/`--list`).
  Inside the region it may run only `powercfg`, `icacls` or the trusted git. The region holds exactly three functions,
  and only apply and undo may call `Invoke-FixChange`. The guard also rejects:
  - dynamic commands, `Invoke-Expression` and redirections;
  - `$env:` or drive assignments, and static calls through a variable;
  - `ForEach-Object` with a member name;
  - member calls outside a fixed list (file writes are allowed only in `Save-FixRecord`).
- **sh: a command-word guard.** Every command word must be on an allow-list. `sudo`, `su`, `chmod`, `chown`, `ln`, `cp`,
  `tee`, `curl`, `eval`, `sh`, `exec` and the like are forbidden. A mutating `systemctl` verb (`enable`, `stop`, `mask`,
  ...) may appear only inside the region.
- Injected-mutation tests (`GuardRejectsMutationOutsideFixTable`) add forbidden code to a copy of the script and check
  that the guard catches it.

As for the scanner, the guards are a test-time tripwire against accidental mutating code, not a sandbox. The scripts
are kept short enough to read.

### Each fix

1. Read the state. When the scanner would report it but this script cannot fix it safely (for example git outside
   Program Files, a `LongPathsEnabled` that is not a DWORD, or a keys file that is a link), skip the fix with a note.
2. Turn the state into its fixed text shape (see `docs/FIX-RECORD.md`). If it does not fit a shape, the fix is not
   offered: a state that cannot be recorded cannot be undone.
3. Show it, ask. On yes, read the state again (the precondition). If it is no longer needed, or differs from what was
   shown, do nothing.
4. Write the record item as `pending`, with the before state and the expected after state, **before** the change.
   If the record cannot be written, stop with exit 1 and change nothing.
5. Make the change. Read the state again and verify it. Mark the item `applied` or `failed` with the after state found,
   and save the record again.

### Record lifecycle

On apply, an item goes from `pending` to `applied` or `failed`. On undo:

- `applied`, `failed` or `pending` becomes `undone` once the before state is back and verified;
- `pending` becomes `skipped` when undo finds the before state (the change was never made).

A crash between writing the record and making the change leaves `pending` with a usable expected after state. Undo
handles both cases: the change was never made, or it was made but not recorded.

Undo goes newest first and confirms each item. It acts only when the current state equals the recorded after state;
otherwise it prints "changed since; left alone". It never overwrites a change it did not make.

### Record storage and validation

- **Windows:** `%ProgramData%\lanq-makeready`. The script creates it owned by Administrators, protected, with only
  Administrators and SYSTEM (`O:BAG:SYD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)`). If the folder exists but is not like
  that (a link, another owner, inheriting, other accounts in the DACL), nothing is written. Records are not kept in
  `%LOCALAPPDATA%`, because any non-elevated process of the same user can write there, and undo runs as admin. A record
  is written to `<record>.tmp` (refused if that name exists) with the record SDDL set, then moved over the record.
- **Linux:** `/var/lib/lanq-makeready` as root (umask 077: 700/600). Undo uses a record only when it and its folder are
  owned by root, not symlinks, and not writable by group or others.
- **Validation on undo.** One bad field rejects the record (exit 2). Undo checks:
  - a size limit and plain ASCII;
  - exactly the known fields, with none extra and none missing;
  - a known schema and OS, known fix ids, a unique `seq`, the fixed status set and UTC times;
  - every before and after state in the exact shape for its id;
  - on Linux, the exact line layout the script writes;
  - for `ssh.aclkeys`, a saved DACL that is safe to put back (see below).
- **Undo never executes text from the record.** The undo command comes from the FIXES table, keyed by the fix id.
  Only values parsed from the before state go in:
  - a start type from a fixed set;
  - a number, or a DWORD;
  - a short alphanumeric git value;
  - target names from the fixed list of four;
  - a DACL that matches a strict SDDL pattern.

  Service, registry, file and unit names are constants in the script. The `command` field is for people and is never
  run. So a forged record can at most ask to restore a state of the same kind, and only an admin or root could have
  written it.

### The safe-DACL rule (`ssh.aclkeys`)

sshd on Windows ignores `administrators_authorized_keys` when anyone but Administrators and SYSTEM may change it. The
fix runs `icacls ... /inheritance:r /grant *S-1-5-32-544:F /grant *S-1-5-18:F` (SIDs, so it works on non-English
Windows). Before the prompt it lists every key in the file (type, SHA256 fingerprint, comment), because after the fix
sshd trusts each of them for administrator logins.

Undo puts back the saved DACL, but only when that DACL has entries, no deny entry, and full control for both
Administrators and SYSTEM. So undo can never lock out the administrators or leave a NULL or empty DACL. The same rule
decides whether the fix is offered at all: if the current DACL would not pass, the fix is not offered.

Undo restores the protection flag and the explicit entries. Inherited entries come back from the parent folder as it is
at that time, and states are compared on the flag and explicit entries only. The fix does not change the owner; an
owner other than Administrators, SYSTEM or TrustedInstaller gets a note instead.

### Detecting SSH and the console

- **SSH.** First `SSH_CONNECTION`, `SSH_CLIENT` or `SSH_TTY`. Since `sudo` or Run as administrator can drop those
  variables, it then walks the parent processes and refuses when one is named `sshd*` (on Linux also `dropbear*`).
  - Windows reads the process table in a separate runspace with a 15 s deadline. The walk stops at a parent that
    started after its child (a reused PID). When the table cannot be read, it refuses in session 0.
  - Linux also asks logind about the audit session (`/proc/$$/sessionid`, then
    `loginctl show-session -p Remote -p Service`). That session survives `sudo`, `su` and tmux.
- **From a file.**
  - ps1 requires an `ExternalScript` invocation whose file contains the marker line, so `[scriptblock]::Create` and
    `iex` are refused.
  - sh refuses when `$-` has `c` or `s`, or (on Linux) when the shell's own command line in `/proc` shows `-c` or `-s`.
    It also requires `$0` to be a file named `lanq-makeready-fix.sh` that contains the marker.
- **Console.**
  - ps1 needs `[Environment]::UserInteractive`, stdin not redirected, and a session id above 0.
  - sh needs stdin to be a terminal (`[ -t 0 ]`).
- **Aliases.** ps1 refuses when an alias shadows one of its functions or the cmdlets it uses; sh runs `unalias -a`.

These checks stop mistakes and casual remote use. They are not a boundary against code that already runs as admin or
root on the PC.

### Testing fix mode

- **Injected runner, every OS.** `tests/fix.ps1` and `tests/fix.sh` dot-source the script (with
  `LANQ_MAKEREADY_FIX_LIB=1`). They replace the state readers, the commands (`Invoke-Native` or `systemctl`) and the
  record store with fakes that record each call. The run stops before any scenario if a fake is missing. The named
  tests are:
  - refusals: `RefusesOverSsh`, `RefusesFromStdin`, `RefusesWithoutConsole`, `NoYesFlag`;
  - prompts and elevation: `DefaultIsNo`, `SkipsAdminItemsWhenNotElevated`, `EachFixRechecksPreconditionFirst`;
  - apply: the exact mutating commands per fix, and the record written before the change;
  - undo: each fix restored, `UndoInReverseOrder`, `UndoSkipsChangedSince`, pending items;
  - `WhatIfChangesNothing`, `TamperedRecordRejected`, `GuardRejectsMutationOutsideFixTable`,
    `ScannerUnchangedAndStillReadOnly`.
- **The test seam.** A direct run with `LANQ_MAKEREADY_FIX_LIB=1` still applies every refusal and then exits 2. On sh
  the seam also needs a function named `__lanq_makeready_fix_test_harness`, so the variable alone does nothing. Using
  the seam needs code already running in that shell, which could change the PC anyway, so it widens nothing.
- **Real apply and undo, disposable machines only.** Two CI jobs, both on GitHub-hosted runners:
  - `real-fix-windows`, on a Windows runner with PowerShell 5.1 and 7: powercfg, `LongPathsEnabled` (set to 0, and
    absent), git `--system`, sshd when the image has it, and the keys-file ACL;
  - `real-fix-linux`, on an Ubuntu runner with systemd, as root: `ssh.service` and the four sleep targets.

  The setup step makes each fix necessary. The driver applies everything, checks the record folder and file
  permissions, undoes everything, and compares before and after snapshots. The drivers (`tests/real-fix.ps1`,
  `tests/real-fix.sh`) replace only the console check and the answer. They refuse to run unless `GITHUB_ACTIONS=true`,
  `RUNNER_ENVIRONMENT=github-hosted` and `LANQ_REAL_FIX_OK=disposable-runner`; that gate guards against accidents and is
  not a security boundary. On a runner image without sshd, Windows `ssh.start` and `ssh.auto` are covered by the fake
  tests only.

## Later (not v0.1)

- `lanq inspect <machine>`: LanQueue pipes this read-only script over its existing SSH to a worker and imports the
  JSON (capabilities, transfer mode, health hints). Keeps lanq tiny: the script is data, not a dependency.
- (Done in 0.4 as separate scripts, not a scanner flag: see "Fix mode (0.4)".) Opt-in, per-item, confirm-each fixes
  for a short list of safe, reversible items.
- Signed releases (GitHub artifact attestations first; Authenticode later if worth the cost).

## Note on the guard tests

0.2 widened the allow-lists deliberately: ps1 `Get-NetAdapter`, `Get-NetFirewallPortFilter`, the `powercfg /devicequery
wake_armed` probe, and `[System.IO.File]::Open` with `CreateNew` (only inside `Save-OutFile`, for `-Out`). For sh `--out` (a temp file plus
`ln`, so there is no noclobber race on FIFOs or devices) the guard allows exactly three lines in `save_out` (`mktemp`, `ln --`, `rm -f --` on the
temp file) and the `> "$_otmp"` redirection, and a test checks those are the only `ln`, `rm` and `mktemp` in the script. The sh guard now also flags `ethtool -s/-K/...`, `nmcli` and `swapon`.

The read-only guard tests (AST allow-list for PowerShell, command-word allow-list for sh, plus injected-mutation tests) are a
test-time tripwire against accidental mutating code. They are not a sandbox and cannot prove the scripts are safe: the read-only
guarantee rests on the scripts being short enough to read and on review. Docker credentials in `~/.docker/config.json` are never read.
