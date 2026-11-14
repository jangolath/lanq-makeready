# lanq-makeready — design (v0.5)

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
  The tune scan (0.5) is a second read-only script with the same rules (see "Tune scan and tune fixes (0.5)").
- **No admin required.** Checks that need admin print `skipped (needs admin)`. Running elevated is allowed and just
  fills in those rows.
- **No network calls.** No telemetry, no update check, no downloads. (Exception: none.) It does not resolve or ping anything.
- **No secrets read or printed.** Does not read SSH private keys, only checks that `authorized_keys` exists and
  (Windows admin case) the ACL owner/entries. Usernames/hostnames are printed only in the local report; the JSON
  has `--redact` to drop hostname, username and paths.
- **No dependencies.** Windows: Windows PowerShell 5.1 built-ins only (no modules from the gallery, no .NET install).
  Linux/macOS: POSIX `sh` + coreutils/procfs; optional tools (`docker`, `git`, `systemctl`, `smartctl`) are probed
  with `command -v` and their absence is itself a finding.
- **Bounded.** Every probe of a tool, and every ACL read (`getfacl`, `ls`), has a timeout (Windows: jobs with
  `Wait-Job -Timeout`; sh: `run_t`, with `timeout` when present). Quick local reads of one path (`find -maxdepth 0`,
  `readlink`, `id`, `uname`) are not wrapped. Never walks the whole disk: folder sizes only for a fixed list of known temp/cache folders, with a cap.
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
  lanq-makeready-tune.ps1     # tune scan, Windows (0.5), read-only
  lanq-makeready-tune.sh      # tune scan, Linux (0.5), read-only
  schema/report.v1.json   # JSON Schema for --json output
  schema/tune.v1.json     # JSON Schema for the tune scan's --json output
  schema/fix-record.v1.json   # JSON Schema for the fix undo record
  tests/                  # see Testing
  docs/DESIGN.md          # this file
  docs/FIX-RECORD.md      # the undo record, explained
  docs/TUNE.md            # the tune checks, the tune fixes and the tune JSON
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
  Only when that folder is safe: other local users must not be able to plant code the job's dotnet runs. Windows reads
  the owner and DACL. Linux (`safe_dir`): the folder, `dotnet`, `sdk` and the newest SDK folder, `host`, `host/fxr`
  and its version folders, `shared` and its framework and version folders, `packs` and `sdk-manifests` (each
  resolved) are owned by root or this user and writable by nobody else, and every parent folder (as given and as
  resolved) is owned by root or this user and not writable by others unless sticky. "Writable" is judged by `find
  -perm` and, from 0.4.1, by `acl_ok`, which reads the globals `_u` (`id -u`) and `_pg` (`id -g` when the primary
  group's name is the user's name, else 0) that `safe_dir` sets:
  - `getfacl -cpn` (under `run_t 5`) output is split on `:` after `#effective:` is cut off. A `user:ID` or `group:ID`
    entry (3 fields) is open when its effective rights (under the mask) contain `w`; a `default:user:ID` or
    `default:group:ID` entry (4 fields) is open when its raw rights contain `w`, since new folders (the next SDK, a new
    shared framework) inherit it. Trusted ids: 0, `_u`, `_pg`.
  - The owner entries (`user::`, `group::`), `other::` and `mask::` are left to the mode bits (with an ACL the group
    bits are the mask), and so are their `default:` forms.
  - getfacl failing or timing out, and output with no `user::` line (empty or unrecognised), count as open.
  - Without getfacl, `ls -ld` (under `run_t 5`) failing, a line too short to have the marker column, or the marker `+`
    count as open. busybox `ls` (its `--help` says BusyBox) shows no marker, so there group write (`?????w`) counts as
    open even for root's or the private group: with an ACL that is the mask.
  - On Darwin `acl_ok` is skipped (macOS ACLs are not read, and a Mac gets no entry). Not read: NFSv4 ACLs, SELinux.
  - Limit (since 0.3.0): only folders and `dotnet` itself are checked. Files inside them (`libhostfxr.so`, the SDK's
    `.dll` files) are not, so a file another user may write in an otherwise safe folder is not seen.
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
  (exit 3). On Linux, `--tune` also refuses inside a container (Docker, Podman, LXC, systemd-nspawn; exit 3). There is no `--yes`. Each fix is shown as check, current state, exact command and undo, then
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
record folder; both are created with their owner and DACL in the same call, and nothing outside the region sets an ACL.

The guards are tests, like the scanner's:

- **ps1: an AST allow-list.** The mutating cmdlets (`Set-Service`, `Start-Service`, `Stop-Service`, `Set-ItemProperty`,
  `Remove-ItemProperty`, `Set-Acl`) may appear only inside `Invoke-FixChange`. The record folder and files are created
  by `New-FixSecuredDir` / `New-FixSecuredFile`, which may only use the two fixed record SDDLs and are called only by
  the record store. `Invoke-Native` (the only process launcher) may run outside the region only with six fixed read
  argument lists (`powercfg /q`, `powercfg /getactivescheme`, `git config --get`/`--list`).
  Inside the region it may run only `powercfg`, `icacls` or the trusted git. The region holds exactly three functions,
  and only apply and undo may call `Invoke-FixChange`. The guard also rejects:
  - dynamic commands, `Invoke-Expression` and redirections;
  - `$env:` or drive assignments, and static calls through a variable;
  - `ForEach-Object` with a member name;
  - member or index assignments except on local hashtables (and the `ProcessStartInfo` of `Invoke-Native`); those
    variables may never be filled from a cmdlet or a .NET call, so a `FileInfo` can never be changed through them;
  - member calls outside a fixed list (file writes are allowed only in the record store).

  A test also checks that every cmdlet the script runs is in `$FixCmdletNames`, the list the start-up shadow check uses.
- **sh: a command-word guard.** Every command word must be on an allow-list. `sudo`, `su`, `chmod`, `chown`, `ln`, `cp`,
  `tee`, `curl`, `eval`, `sh`, `exec` and the like are forbidden. A mutating `systemctl` verb (`enable`, `stop`, `mask`,
  ...) may appear only inside the region.
- Injected-mutation tests (`GuardRejectsMutationOutsideFixTable`) add forbidden code to a copy of the script and check
  that the guard catches it.

As for the scanner, the guards are a test-time tripwire against accidental mutating code, not a sandbox. The scripts
are kept short enough to read.

### Each fix

1. Read the state. When the scanner would report it but this script cannot fix it safely (for example git outside
   Program Files, a `LongPathsEnabled` that is not a DWORD and not 1, a keys file that is a link or has its own entries
   for other accounts, a masked or static ssh unit), skip the fix with a note. Where the scanner's view and the fix's
   can differ, the prompt says so: the scanner checks the git first on PATH while the fix uses Program Files git, and
   on Linux a root shell cannot read a desktop user's GNOME power setting.
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

- **Windows:** `%ProgramData%\lanq-makeready`. The script creates it with its security descriptor in the same call
  (`Directory.CreateDirectory(path, security)` on PowerShell 5.1, `FileSystemAclExtensions.Create` on PowerShell 7):
  owned by Administrators, protected, only Administrators and SYSTEM (`O:BAD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)`).
  An existing folder is never re-permissioned. It is checked before the first question: it must be owned by Administrators or SYSTEM, protected (nothing inherited), not a link, and with only Administrators and SYSTEM in its DACL.
  Otherwise the run stops; the message says what is wrong (naming the owner when that is the problem) and how to move
  the folder away. Records are not kept in `%LOCALAPPDATA%`, because any non-elevated process of the same
  user can write there, and undo runs as admin. A record is written to a new `<record>.tmp` created with its owner and
  DACL (`CreateNew`, so an existing name is refused), then moved over the record.
- **Linux:** `/var/lib/lanq-makeready` as root (umask 077: 700/600). An existing folder that is not root's with mode
  700, or is a link, stops the run before the first question.
- **Only records in place.** Undo reads only `fix-<time>.json` files directly in the record folder (on Linux the path
  is resolved with `cd -P`), owned by Administrators/SYSTEM or root, not links, and not writable by anyone else.
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
Administrators and SYSTEM. When the saved DACL is protected, what undo writes is just its explicit entries, so those
must pass on their own. After the undo the file's DACL is read again; if Administrators or SYSTEM lost full control the
undo fails loudly and prints the `icacls` command that gives it back. So undo can never quietly lock out the
administrators or leave a NULL or empty DACL. The same rule decides whether the fix is offered at all: if the current
DACL would not pass, the fix is not offered.

`icacls /grant` leaves explicit entries for other accounts in place, so the fix could not make such a file
Administrators-and-SYSTEM-only. When the file has them, the fix is not offered; the note names the accounts and the
`icacls /remove:g` commands to run after checking them.

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
- **Shadowing.** ps1 refuses when an alias shadows one of its functions, or when one of the cmdlets it uses does not
  resolve to that cmdlet (a function or alias of the same name); it asks with module-qualified `Get-Command` and
  `Get-Alias`. sh runs `unalias -a`. The parent-process walk runs once per process.

These checks stop mistakes and casual or naive remote use. They are not a boundary against a determined admin or root
(for example `systemd-run --pty`, `machinectl shell`, or attaching locally to a tmux started over SSH), nor against code
that already runs as admin or root on the PC.

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

## Tune scan and tune fixes (0.5)

### Why a separate script

- The tune results must never change readiness. In the scanner they would flow into `checks[]`, the verdicts, the
  next steps and LanQueue's view of the report. A separate script and schema (`lanq-makeready-tune/v1`) keep them out.
- The scanner's own budget: it is close to its line cap, and its parameter list and read-only guard are pinned by
  tests. The new probes (scheduled tasks, Defender preferences, storage, network adapters) would widen its allow-list.
- LanQueue runs each remote scan with a time limit; the tune scan has its own 90-second deadline, so a second run fits.

### Shape

- Same structure as the scanner: probes fill a facts table, pure functions turn facts into items, and the output is
  text or JSON. Tests feed fixtures to the pure functions (`tests/tune.ps1`).
- Statuses OK, INFO, WARN, SKIP only. Exit code 0 always (2 for bad arguments). `fixId` only on INFO and WARN.
- Time: a stopwatch for the whole run (90 s) and a budget per probe. Slow probes run in a separate runspace with
  `WaitOne(budget)`; on timeout the runspace is stopped, the probe's checks say `SKIP` "time budget", and the process
  exits with `[Environment]::Exit` so a hung pipeline cannot hold it. Executables (`powercfg /q`, `fsutil behavior
  query`) run with closed stdin and a deadline. Driver dates come from `Get-NetAdapter` and the Class registry, never
  `Win32_PnPSignedDriver` (30 to 90 s or more), within 15 s.
- Read-only by construction: the guard test allows a fixed list of read-only commands and member calls, bans
  `Get-ItemProperty` outright (registry values are read with `Get-Item` and the key object), allows the literal
  `DefaultPassword` only as the right side of `-contains` (its existence is tested with `GetValueNames()`, its value is
  never read), and allows `Invoke-Exe` only for `powercfg /q` and `fsutil behavior query`. Injected mutants prove the
  guard catches each banned form. Line cap 800.
- Defender exclusions are compared with work_root, the NuGet packages and temp inside the probe's runspace; only a
  scanned/excluded flag per folder comes out, so the list itself can never be printed or serialized.
- Redaction is on values (host, user, profile folder, at token boundaries) after the items are built, before output.

### Tune fixes

- In the existing fix script, behind `-Tune` (and `-Tune -DefenderExclusions` for exclusions only), with the same
  refusals, confirmation, record and undo. Fix ids are additive under `lanq-makeready-fix/v1`; a 0.4 script rejects a
  record with a tune id ("unknown fix id", exit 2).
- One fix id may touch several things (services, tasks, Run entries, folders). `Get-FixTargets` lists them,
  `Get-FixState` reads one, and the target is part of the recorded state, so undo knows what to read again. Each target
  is asked separately; a record holds at most 64 items, after which nothing more is offered in that session.
- Names in a record (service, task, Run entry) must match a fixed shape, and undo re-checks them against the curated
  list plus an append-only list of retired entries (`$VendorRetiredPatterns`), so a record can neither name an
  arbitrary service nor be orphaned by a later list change. Tasks under `\Microsoft\` are rejected by shape.
- StartupApproved: no value means enabled; `Run32` (WOW6432Node) has its own key; undo deletes a value that was absent.
  The account SID is recorded and an HKCU item is undone only by that account.
- Services: Start and DelayedAutostart come from the registry (PowerShell 5.1 cannot read Delayed Start) and are put
  back with `sc.exe config start=` (`delayed-auto` when needed). The delayed flag is compared only for automatic
  services.
- Defender: exclusions only for work_root plus the NuGet package cache, never temp or processes. Each folder passes
  `Get-BuildDirProblem` (no `.`/`..` part, canonical by `GetFullPath`, no drive root, not a Windows, program,
  shared-data or user folder or a parent of one; the tune scan uses the same function, checked equal by a test), and
  the NuGet cache is offered only when the process user SID equals the console user's (`Win32_ComputerSystem.UserName`),
  since `%USERPROFILE%` is otherwise another account's. A folder already
  covered is skipped and never recorded; nothing is offered unless AMRunningMode is Normal; undo removes exactly the
  folders the record says this script added. The scan-time fix replaces the plan's "CPU load factor" idea.
- The commands that come from Windows modules (ScheduledTasks, Defender, Storage, NetAdapter) are CDXML functions, not
  cmdlets; the shadow check requires each to come from its module, so a function or alias of the same name refuses the
  run (only in tune mode, since looking them up loads the modules).
- Real apply and undo on a disposable Windows runner cover `power.cpu`, `do.mode`, `sysmain` (the SSD test is replaced
  there, since runner disks report no media type) and `defender.scantime`. The others are covered by fake-world tests.

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
