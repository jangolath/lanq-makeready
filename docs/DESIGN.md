# lanq-makeready — design (v0.1 prototype)

Name approved by the owner 2026-11-08 (formerly the working name lanq-ready).

## What it is

A single script the owner of an old PC downloads and runs **on that PC**. Read-only. It answers, in plain language:

1. Can this machine be a LanQueue worker (git mode / archive mode)? What is missing?
2. Can it run the common toolchains: .NET 10 SDK, Docker, Node, Python, git? Supported / "not supported but may run" / will not work.
3. Will it survive an overnight job (sleep, hibernate, pending reboot, disk type/space, RAM)?
4. What is slowing it down (startup items, low disk, HDD, big temp folders, Defender scanning the work folder) — **report only**.

Then it prints a ready-to-paste `machines.yml` entry for LanQueue, and optionally writes a JSON report.

## Hard rules (safety is the product)

- **Read-only.** The script never installs, uninstalls, updates, changes settings, disables services, edits the registry,
  or touches drivers. Every fix is printed as advice (often an exact command the user may choose to run themselves).
  No `--fix` flag in v0.1.
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
- Small: target ≤ 700 lines per script.

## Files

```
lanq-makeready/
  lanq-makeready.ps1          # Windows (PowerShell 5.1+, also runs on pwsh 7)
  lanq-makeready.sh           # Linux + macOS (POSIX sh)
  schema/report.v1.json   # JSON Schema for --json output
  tests/                  # see Testing
  docs/DESIGN.md          # this file
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
- `dotnet` — find without relying on PATH: `dotnet --list-sdks` if on PATH, else `%ProgramFiles%\dotnet\dotnet.exe`,
  `/usr/share/dotnet`, `/usr/lib/dotnet`, `~/.dotnet`, `/usr/local/share/dotnet`. Report SDK majors.
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
- `wol` — informational only; Windows `Get-NetAdapterPowerManagement` (may need admin → SKIP).

Slowdowns (report only, never act)
- `startup` — count + top entries from `Win32_StartupCommand` and HKCU/HKLM Run keys; Linux: enabled user services
  count. Advice: point to Task Manager › Startup / `systemctl --user disable`; never disable anything.
- `temp` — sizes of %TEMP%, `C:\Windows\Temp` (if readable), browser caches not touched/not listed (privacy),
  NuGet/npm caches (`~/.nuget/packages`, npm cache dir) with a 5-second cap per folder.
- `defender` — Windows: real-time protection on; Dev Drive available (build ≥ 22621.2338)? Exclusions are NOT read
  (hidden without admin, and privacy). Advise Dev Drive or a scoped exclusion for the work folder — as advice only.
- `drivers` — report only: count of devices with problem codes (`Win32_PnPEntity` ConfigManagerErrorCode ≠ 0) with
  names; advise Windows Update optional driver updates / vendor site. **Never updates drivers.**

## Suggested machines.yml snippet

```yaml
  - name: <hostname-lowercased or "old-pc">
    os: windows|linux            # macOS: print a note that LanQueue v0.3 workers are windows|linux only
    ssh: <user>@<hostname>.lan   # placeholder; user must confirm
    work_root: C:/lq | /srv/lq   # short path; on Windows choose the SSD/most-free fixed drive
    capabilities: [dotnet, node, docker, windows]   # only what was detected AND working
    max_jobs: 1                  # 2 only if logical cores ≥ 8 and RAM ≥ 16 GB
    transfer: git | archive      # archive when git missing but tar OK
    allowed_hours: "00:00-07:00" # only when --hours given; note: evaluated in the ORCHESTRATOR's local time
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

## Later (not v0.1)

- `lanq inspect <machine>`: LanQueue pipes this read-only script over its existing SSH to a worker and imports the
  JSON (capabilities, transfer mode, health hints). Keeps lanq tiny: the script is data, not a dependency.
- Opt-in, per-item, confirm-each `--fix` for a short list of safe, reversible items (sleep-on-AC off, start sshd,
  enable long paths) — only after v0.1 is proven on real old machines.
- Signed releases (GitHub artifact attestations first; Authenticode later if worth the cost).
