# Changelog

## 0.2.0 (unreleased)

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
- "Suited for" hint (light / medium / heavy, "+ container builds" when Docker answers), same thresholds as `lanq health`.
- Windows: Windows 10 end-of-support note (22H2 is the last version; works while updates/ESU apply); new `ssh.firewall`
  (an enabled inbound rule for TCP 22, not only the named rule) and `ssh.shell` (OpenSSH default shell must be cmd.exe or
  PowerShell) checks, both part of the worker verdicts; page file size.
- Linux: distribution end-of-life WARN from `/etc/os-release` and a small embedded table; `ssh.password` security note for
  `PasswordAuthentication yes` (or unset, which defaults to yes), from `sshd -T` as root or `sshd_config` plus `Include`
  files; unmasked systemd sleep targets now WARN with the `systemctl mask` command; swap size.
- Low disk says the free space and the recommended minimum.
- Fix hints: the `administrators_authorized_keys` icacls hint grants Administrators and SYSTEM by SID (`*S-1-5-32-544`,
  `*S-1-5-18`), so it works on non-English Windows; the build-user hint says to add a new local user to Users by SID
  (`Add-LocalGroupMember -SID S-1-5-32-545`) and log on once before creating its `.ssh` folder; low-RAM boxes get a
  `-m:1` comment for `dotnet build`/`dotnet test` instead of an MSBuild env var.
- `-Out FILE` / `--out FILE` also saves the human report. It only creates a NEW file (CreateNew / `set -C`); an existing
  file is never overwritten (exit 2).
- JSON report (schema `lanq-makeready/v1`, backward compatible: only optional fields added): `summary`, `suitedFor`,
  `suggestedMachine.min_free_mem_gb`, `suggestedMachine.wake`. New check ids: `ssh.firewall`, `ssh.shell` (Windows),
  `ssh.password` (Linux), `swap`.
- Guards: the ps1 AST allow-list adds `Get-NetAdapter`, `Get-NetFirewallPortFilter`, the `powercfg /devicequery wake_armed`
  probe and the `-Out` write (`File.Open` with CreateNew, only in `Save-OutFile`); the sh allow-list adds `set` (for
  noclobber) and the `> "$OUT_PATH"` redirection, and now flags `ethtool -s`, `nmcli` and `swapon`. Script size limit 900 lines.

## 0.1.0 (unreleased)

- First release: read-only worker-readiness scan for Windows (PowerShell 5.1+), Linux and macOS (POSIX sh),
  human report + JSON (`schema/report.v1.json`, stdout mode for piping over SSH), suggested LanQueue `machines.yml` entry.
