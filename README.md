<p align="center"><img src="assets/makeready-banner.png" alt="MakeReady - old PC, ready by morning" width="100%"></p>

# lanq-makeready

A small, **read-only** readiness check for a PC you want to use as a worker for
[LanQueue](https://github.com/jangolath/lanqueue) (it sends build/test jobs to spare LAN PCs over SSH).
Run it on the old PC. It tells you, in plain words:

1. Can this machine be a LanQueue worker (`transfer: git` and/or `transfer: archive`)? What is missing?
2. Can it run .NET 10, Docker, Node, Python, Java, Go, Rust? (`OK`, `WARN` = works but unsupported or degraded, `FAIL` = will not work)
3. Will it survive an overnight job (sleep, hibernate, pending reboot, Windows Update restarts, disk type and space, RAM)?
4. What is slowing it down (startup items, big caches, HDD, Defender scanning, driver problems)? Report only.

Then it prints a ready-to-paste `machines.yml` entry and can write a JSON report.

Status: v0.1 prototype. Files: `lanq-makeready.ps1` (Windows PowerShell 5.1 and PowerShell 7), `lanq-makeready.sh`
(POSIX `sh`, Linux and macOS), `schema/report.v1.json`, `tests/`.

## The read-only promise

- It never installs, updates, removes or configures anything. No registry writes, no service changes, no
  driver actions, no firewall changes, no file deletion. Every fix is **printed as advice** for you to run
  yourself, all advice text lives in one table at the top of each script, and a test (`tests/`) fails if any
  mutating command appears outside that table.
- The only file it ever writes is the JSON report, and only when you pass `-Json` / `--json` with a path.
- No admin/root needed. Checks that need it print `SKIP` with the reason. Running elevated just fills those rows in.
- **No network calls at all**: no telemetry, no update check, no downloads, no DNS lookups, no pings.
- It does not read SSH private keys. It only checks that `authorized_keys` exists and is non-empty (and, for a
  Windows administrator, the permissions on `administrators_authorized_keys`). Defender exclusions are not read.
- Every external command it runs has a timeout. It never walks a whole disk: folder sizes are measured for a
  short fixed list of cache folders, each capped at a few seconds.
- `-Redact` / `--redact` replaces hostname, user name and user-profile paths with `<redacted>` in both the
  screen output and the JSON, so the output is safe to paste into an issue.

## Download and verify

Do not pipe a download into a shell. Download, read, verify, then run.

1. Download `lanq-makeready.ps1` (Windows) or `lanq-makeready.sh` (Linux/macOS) and `SHA256SUMS` from the release page.
2. Verify the hash.

   Windows (PowerShell):
   ```powershell
   (Get-FileHash .\lanq-makeready.ps1 -Algorithm SHA256).Hash.ToLower()
   # compare with the line for lanq-makeready.ps1 in SHA256SUMS
   ```
   Linux / macOS:
   ```sh
   sha256sum -c SHA256SUMS --ignore-missing      # macOS: shasum -a 256 -c SHA256SUMS
   ```
3. Optional but better, since a checksum from the same page only catches corruption: verify the GitHub
   build attestation (needs the [GitHub CLI](https://cli.github.com/)):
   ```sh
   gh attestation verify lanq-makeready.ps1 -R jangolath/lanq-makeready
   ```
4. Open the script in a text editor and read it. It is about 600 lines and has no dependencies.

**Never** run it as `irm <url> | iex` (or `curl <url> | sh`). That runs unreviewed code with your rights and
skips every check above.

## Run it

Windows (no admin needed). Files from the internet carry a "mark of the web", so unblock the file once, and
use a per-process execution-policy bypass (nothing is changed permanently):

```powershell
Unblock-File .\lanq-makeready.ps1
powershell -ExecutionPolicy Bypass -File .\lanq-makeready.ps1
powershell -ExecutionPolicy Bypass -File .\lanq-makeready.ps1 -Hours "00:00-07:00" -Redact -Json .\report.json
```

Linux / macOS:

```sh
sh ./lanq-makeready.sh
sh ./lanq-makeready.sh --hours 00:00-07:00 --redact --json ./report.json
```

Running it over SSH (what a future `lanq makeready` will do): the script is piped in, only JSON comes back on stdout,
the human report is suppressed, and the exit code is `0`/`1` as usual. Nothing is copied to the worker.

```sh
# Windows worker (default shell may be cmd.exe, so start powershell explicitly)
ssh user@worker "powershell -NoProfile -NonInteractive -Command \"& ([scriptblock]::Create([Console]::In.ReadToEnd())) -Json - -Redact\"" < lanq-makeready.ps1
# Linux worker
ssh user@worker "sh -s -- --json - --redact" < lanq-makeready.sh
```

`-Json -` only works in the stdin form above; with `powershell -File` use a file path. Windows PowerShell flags are
`-Json/-Redact/-Hours/-Quiet`; unknown arguments exit 2 with a usage line.

| Option (ps1 / sh) | Meaning |
|---|---|
| `-Json PATH` / `--json PATH` | also write a JSON report ([schema](schema/report.v1.json)); `-` writes only the JSON to stdout |
| `-Redact` / `--redact` | hide hostname, user and profile paths |
| `-Hours HH:mm-HH:mm` / `--hours` | only feeds `allowed_hours` in the snippet (start must differ from end) |
| `-Quiet` / `--quiet` | verdict lines only |

Exit code: `0` = at least one transfer mode is ready, `1` = not ready (blockers are listed), `2` = bad arguments.
A full run takes under a minute on a slow PC (the longest steps are the hardware queries and the capped
cache-folder sizes).

## Example (Windows 11 desktop, `-Redact`, shortened)

A machine with no SSH server yet, so it correctly says "not ready". Advice lines are cut for width.

```text
lanq-makeready 0.1.0 (read-only: nothing is installed, changed or sent anywhere)

[OK  ] OS: Windows 11 Pro build 26200, Professional
[OK  ] Memory: 32.4 GB installed, 10.5 GB free
[OK  ] Disk: system drive 524 GB free, work drive C: 524 GB free, work drive type: SSD
[FAIL] OpenSSH Server: not installed
       advice: Install OpenSSH Server yourself (elevated PowerShell): Add-WindowsCapability -Online ...
[WARN] SSH keys: user is an administrator; administrators_authorized_keys not found
[WARN] git: git version 2.48.1.windows.1, core.longpaths not enabled
[OK  ] tar: built-in bsdtar found
[OK  ] .NET 10 SDK: supported OS (Windows 11 24H2 or newer) (SDK majors found: 5, 9, 10)
[OK  ] Docker: engine answering (server 29.9.2)
[OK  ] Sleep/hibernate (AC): never sleeps or hibernates on AC
[WARN] Pending reboot: a restart is pending
[WARN] Update restarts vs job window: job window 00:00-07:00 is outside Windows Update active hours 08:00-02:00

Verdicts
  worker_git      FAIL
  worker_archive  FAIL
  dotnet10        OK
  docker          OK
  overnight       WARN

# Paste into machines.yml (confirm the placeholders):
# NOT READY yet: fix the FAIL items above first, then re-run.
machines:
  - name: "old-pc"
    os: windows
    ssh: "<user>@<hostname>.lan"   # placeholder: confirm user and host name
    work_root: "C:/lq"   # short path
    capabilities: [dotnet, node, java, docker, windows]
    max_jobs: 2
    transfer: git
    allowed_hours: "00:00-07:00"   # evaluated in the ORCHESTRATOR's local time

Blockers:
  - OpenSSH Server: not installed
```

## How the output maps to `machines.yml`

The snippet follows LanQueue's registry schema (`machines.example.yml`, [docs/WORKERS.md](https://github.com/jangolath/lanqueue/blob/main/docs/WORKERS.md)):

| Field | Where it comes from |
|---|---|
| `name` | lower-cased hostname (`old-pc` with redaction) |
| `os` | `windows` or `linux`. LanQueue workers are only these two, so on macOS the script prints a note instead of an entry |
| `ssh` | `user@host.lan` **placeholder**: you confirm the real user and host name |
| `work_root` | a short absolute path with forward slashes: `C:/lq` (or the fixed drive with the most free space) / `/srv/lq` |
| `capabilities` | only tools that were **detected and working** (`dotnet` only when an SDK of major 8 or newer is installed; `node`, `python`, `java`, `go`, `rust`, `docker`) plus `windows` / `linux` |
| `max_jobs` | `1`; `2` only with 8 or more logical cores and 16 GB RAM |
| `transfer` | `git` when git is present; `archive` when git is missing but a usable tar is (Windows bsdtar, GNU tar or bsdtar plus gzip; busybox tar is refused, as LanQueue does) |
| `allowed_hours` | only when you pass `-Hours`; `"HH:mm-HH:mm"`, evaluated in the orchestrator's local time |

Verdicts: `worker_git` / `worker_archive` say whether each transfer mode can work today (SSH server, disk,
OS, plus git or tar). `dotnet10`, `docker` and `overnight` are separate. `SKIP` means "could not check" or
"optional tool not present"; the reason is in the detail.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1      # fixtures + read-only guard + real smoke run
```
```sh
sh tests/run.sh                                                          # same for the sh script
docker run --rm -v "$PWD:/w:ro" ubuntu:24.04 sh /w/tests/run.sh         # also try alpine:3.21 (busybox)
```

The verdict logic is in pure functions fed by a facts object (variables in `sh`), so the tests use fixtures such
as "Windows 10 22H2, 4 GB, HDD, no sshd" or "glibc 2.26" without needing that machine.

## Safety details

- Probes (`git --version`, `node --version`, ...) run with a closed stdin, from a neutral directory (`%SystemRoot%` or `/`),
  with `GOTOOLCHAIN=local`, `RUSTUP_AUTO_INSTALL=0` and prompts off, so a version probe cannot download a toolchain.
  On macOS `git`, `python3` and `java` are only probed when the real tool exists (the stubs open an installer dialog).
- `wsl.exe` is never run unless WSL is installed. A remote Docker endpoint (`DOCKER_HOST`, or a non-local context) is never probed.
- Redaction replaces values before anything is printed or serialized, so a user or host named `false` or `linux` cannot damage the JSON.
- On timeout the whole probe process tree is stopped (Windows uses `taskkill /T` on our own child only).
- The guard tests parse the PowerShell with its AST and allow only a fixed list of read-only commands and (receiver, method) pairs,
  and check the sh script word by word against a command allow-list. **These guards are a test-time tripwire against accidental
  mutating code, not a sandbox.** The read-only guarantee rests on reading the scripts (they are short on purpose) and on code review.
- `~/.docker/config.json` (which can hold registry credentials) is never read; the Docker context comes from `DOCKER_CONTEXT` or `docker context show`.

## Known limits (v0.1)

- AVX2 is only reported on PowerShell 7 (Windows PowerShell 5.1 would need a compiled helper, which writes temp files).
- SSD/HDD detection inside VMs and containers is a heuristic and can be wrong.
- Defender exclusions and Windows Update contents are deliberately not read.
- There is no `--fix`; that may come later, per item and with confirmation.

MIT licensed.
