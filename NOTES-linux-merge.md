# Linux builder: merge notes for makeready 0.5.0 "tune & clean"

These are notes for the merge into the shared files that the Windows builder owns. Delete this file after the merge.

## Files on this branch

| File | Change |
|---|---|
| `lanq-makeready-tune.sh` | NEW. A read-only tune scan in POSIX sh, 462 lines (the test cap is 800). |
| `lanq-makeready-fix.sh` | `--tune` gate added, with 4 fix ids and the undo for each. |
| `tests/tune.sh` | NEW. 182 checks. |
| `tests/fix.sh` | Tune-fix tests added (495 checks in all) and the guard extended. |
| `tests/real-fix.sh` | New `--tune` mode, for disposable CI runners only. |

The version is unchanged at `TOOL_VERSION=0.4.1`. **Bump `lanq-makeready-tune.sh` together with the scanner and the fix
script.** `tests/tune.sh` checks that the tune script's version equals the scanner's.

## ci.yml

```yaml
  posix:
    steps:
      - name: shellcheck
        if: runner.os == 'Linux'
        run: shellcheck --severity=warning lanq-makeready.sh lanq-makeready-fix.sh lanq-makeready-tune.sh tests/run.sh tests/fix.sh tests/real-fix.sh tests/tune.sh
      # ... existing steps ...
      - name: Tune-scan tests (fake root)
        run: sh tests/tune.sh
  alpine:
    steps:
      # ... existing steps ...
      - name: Tune-scan tests (busybox sh)
        run: sh tests/tune.sh
  real-fix-linux:
    steps:
      # ... the two existing steps unchanged, then:
      - name: "Tune: make the tune fixes necessary (this runner is thrown away)"
        run: |
          sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q cups cups-browsed
          sudo systemctl enable --now cups.service cups.socket cups.path cups-browsed.service
          sudo rm -f /etc/sysctl.d/99-zz-lanq-makeready.conf
          sudo sysctl -w fs.inotify.max_user_instances=128
          req=sysctl.tune,services.unused:cups-browsed,services.unused:cups
          # fstrim.timer only where the runner's disk reports TRIM (Azure disks vary); the driver checks the rest
          sudo systemctl disable --now fstrim.timer || true
          for q in /sys/block/*/queue/rotational; do n=${q%/queue/rotational}
            case "$n" in */loop*|*/ram*|*/zram*|*/dm-*|*/sr*|*/nbd*|*/md*|*/fd*) continue ;; esac
            [ "$(cat "$q")" = 0 ] && [ "$(cat "$n/queue/discard_max_bytes")" != 0 ] && { req="$req,fstrim.timer"; break; }
          done
          echo "LANQ_REAL_FIX_REQUIRE=$req" >> "$GITHUB_ENV"
      - name: "Tune: real apply + undo (systemd, root)"
        run: sudo env GITHUB_ACTIONS="$GITHUB_ACTIONS" RUNNER_ENVIRONMENT="$RUNNER_ENVIRONMENT" LANQ_REAL_FIX_OK="$LANQ_REAL_FIX_OK" LANQ_REAL_FIX_REQUIRE="$LANQ_REAL_FIX_REQUIRE" sh tests/real-fix.sh --tune
```

The fstrim loop uses the same disk filter as `trim_disks`. If the leg is flaky on fstrim, drop it from `req`; the
fake tests still cover it.

Not tested locally. The rule forbids running real-fix outside a disposable runner. The first CI run is the test.

## release.yml

- **Tests step:** `sh tests/run.sh && sh tests/fix.sh && sh tests/tune.sh`
- **cp:** add `lanq-makeready-tune.sh` (plus the Windows `lanq-makeready-tune.ps1`) and `schema/tune.v1.json`.
- **sha256sum and the `attest-build-provenance` `subject-path`:** add `lanq-makeready-tune.sh` and `tune.v1.json` (as
  `dist/` paths).

## schema/tune.v1.json: what the sh script emits

```text
{
  "schema": "lanq-makeready-tune/v1",
  "tool": {"name": "lanq-makeready-tune", "version": "N.N.N"},
  "generatedAt": "yyyy-MM-ddTHH:mm:ssZ",
  "host": {"hostname": "...", "user": "...", "os": "...", "arch": "..."},
  "context": {"container": bool, "elevated": bool, "workRoot": "/srv/lq"},
  "items": [{"id", "title", "status", "detail", "advice", "needsAdmin", "fixId", "security"}],
  "summary": {"warn": n, "info": n}
}
```

- **Fields:**
  - `workRoot` is left out when `--work-root` was not given.
  - `needsAdmin` means what it means in the scanner: this row needs root to read it (it reports SKIP without root).
  - `fixId` is `null`, or one of `sysctl.tune`, `journald.cap`, `services.unused`, `fstrim.timer`.
- **Under `--redact`:**
  - `host.hostname` and `host.user` are LEFT OUT (the keys are absent), not replaced with `"<redacted>"`.
  - `os`, `detail`, `advice` and `workRoot` have the host name, user name and home folder replaced with `<redacted>`.
  - Check that this matches the ps1. If the schema makes `hostname` and `user` required, tell me and I will switch to
    `"<redacted>"` like the scanner.
- **Statuses:** `OK`, `INFO`, `WARN`, `SKIP`.
- **Linux item ids, in output order:** `cpu.governor`, `sysctl.swappiness`, `sysctl.inotify`, `journald.size`,
  `services.unused`, `unattended.reboot`, `pkgcache`, `fstrim`, `smart`, `thermal.throttle`, `disk.full`.
  - The same 11 always appear.
  - On macOS, `items` is `[]`.
- **Plain ASCII only:** `json_esc` turns other bytes into `?`.
- **Arguments:** `--json PATH|-`, `--redact`, `--hours HH:MM-HH:MM`, `--work-root /abs/path` and `--quiet`.
  - There is no `--out`. That is a deviation from the scanner, to keep the writes to the one file the user names.
  - `--work-root` follows lanq's Linux `work_root` rule (`^/[A-Za-z0-9_./-]*$`, no `..`, at most 255 characters).
- **Exit codes:** always 0, and 2 for bad arguments.

## schema/fix-record.v1.json

- **`items[].id` enum:** add `"sysctl.tune", "journald.cap", "services.unused", "fstrim.timer"`, plus whatever ids
  Windows adds.
- **`stateShapes`:** add these Linux entries.

```json
"linux:sysctl.tune": { "type": "string", "pattern": "^file=(absent|lanq) instances=[0-9]{1,10} watches=[0-9]{1,10}$", "description": "fs.inotify.max_user_instances / max_user_watches and whether /etc/sysctl.d/99-zz-lanq-makeready.conf is absent or this script's (first line is its marker). Undo removes the file and sysctl -w puts back only the limits the fix raised." },
"linux:journald.cap": { "type": "string", "pattern": "^file=(absent|lanq)$", "description": "/etc/systemd/journald.conf.d/99-zz-lanq-makeready.conf (SystemMaxUse=1G, RuntimeMaxUse=256M). Undo removes it and restarts journald; journal files deleted by the cap cannot be restored." },
"linux:services.unused": { "type": "string", "pattern": "^svc=[a-z][a-z0-9-]{0,31}( (service|socket|path)=(enabled|disabled|none):(active|inactive)){1,3}$", "description": "One item per service: svc is a name from the script's APPEND-ONLY list (cups, cups-browsed, bluetooth, modemmanager), and the unit words must match the script's fixed unit table for it (cups: service socket path; the others: service). none = no such unit. Undo re-enables the units that were enabled and starts the ones that were active. Never masks." },
"linux:fstrim.timer": { "type": "string", "pattern": "^enabled=(enabled|disabled) active=(active|inactive)$", "description": "systemctl is-enabled / is-active of fstrim.timer." }
```

- **`command`:** the sh script now accepts up to 510 characters (it was 255), from `[A-Za-z0-9 ._/;=:-]`. The schema's
  1024 is still the outer limit.
- **`before` and `after`:** the sh charset now includes `:`.
- **Older fix scripts:** 0.4.x scripts reject a record that holds a new id ("unexpected shape", exit 2). That matches
  the plan.

## docs/FIX-RECORD.md

- **The `id` row of the item table:**
  - Linux: `ssh.start`, `power.sleep`, and with `--tune` also `sysctl.tune`, `journald.cap`, `services.unused` and
    `fstrim.timer`.
  - Add the Windows tune ids too.
- **The state-shapes table: add these rows.**

| OS : id | Shape | Notes |
|---|---|---|
| linux : `sysctl.tune` | `file=(absent\|lanq) instances=<n> watches=<n>` | The two `fs.inotify` limits, and `/etc/sysctl.d/99-zz-lanq-makeready.conf` (`lanq` = a regular file, not a link, whose first line is this script's marker). It is offered only when the file is absent. Apply writes the file, holding only the limits below 1024 / 524288 (it never lowers one), then runs `sysctl -w` for them. Undo removes the file and runs `sysctl -w` with the old values of the raised limits. |
| linux : `journald.cap` | `file=(absent\|lanq)` | `/etc/systemd/journald.conf.d/99-zz-lanq-makeready.conf`, holding `SystemMaxUse=1G` and `RuntimeMaxUse=256M`, then `systemctl restart systemd-journald.service`. Undo removes the file and restarts journald. **The journal files deleted by the cap cannot be restored**, and the prompt says so. An empty `journald.conf.d` folder created by the fix stays. |
| linux : `services.unused` | `svc=<name> <type>=<enabled>:<active> ...` | One item per service. The name must be in the script's append-only list, and the unit words must match its fixed unit table (`cups`: `service socket path`; `cups-browsed`, `bluetooth`, `modemmanager`: `service`). Values are `enabled\|disabled\|none` and `active\|inactive`. Apply runs `systemctl disable --now` on the units that are enabled or active, and never masks. Undo runs `systemctl enable` on the units that were enabled, then `systemctl start` on the ones that were active. The unit names come from the script's table, never from the record. |
| linux : `fstrim.timer` | `enabled=(enabled\|disabled) active=(active\|inactive)` | `fstrim.timer`. Apply runs `enable --now`. Undo runs `disable` and/or `stop`, as for `ssh.start`. |

- **Prose for "How undo uses a record":**
  - For `services.unused`, undo reads the service name from `before`.
  - It accepts the name only if the name is on the script's append-only list (names are never removed, so old records
    stay undoable) and has the name shape `[a-z][a-z0-9-]{0,31}`.
  - It runs only the units of that name from the fixed table.
- **The Linux "Fields" rule:** the record's `command` may be up to 510 characters on Linux.

## docs/TUNE.md: the "## Linux" section

```markdown
## Linux

`lanq-makeready-tune.sh` is read-only POSIX sh, like the scanner. Run it on the worker, or over SSH with
`sh -s -- --json - --redact < lanq-makeready-tune.sh`.

    sh lanq-makeready-tune.sh [--json PATH|-] [--redact] [--hours HH:MM-HH:MM] [--work-root /srv/lq] [--quiet]

It never changes anything. Tuning never affects readiness: there is no FAIL, and the exit code is always 0 (2 for bad
arguments). The whole scan has a 90 s deadline, and any probe that would start after it reports `SKIP` (time budget).
Inside a container (`/.dockerenv`, `/run/.containerenv`, or a docker/lxc/kubepods/containerd/libpod cgroup for PID 1),
the host-level checks report `SKIP`; `pkgcache` and `disk.full` still run. On macOS it prints "no tune checks for
macOS". The pending reboot is reported by the scanner (`reboot.pending`), not here.

| id | What it looks at | OK / INFO / WARN | Fix |
|---|---|---|---|
| `cpu.governor` | `scaling_driver` and `scaling_governor` | intel_pstate and amd-pstate-epp: any governor is OK (powersave is their normal dynamic mode). acpi-cpufreq and intel_cpufreq: powersave is WARN, userspace is INFO. Any other driver: INFO. No cpufreq (a VM): SKIP. | report only |
| `sysctl.swappiness` | `vm.swappiness`, RAM | INFO above 60 with less than 8 GB RAM | report only |
| `sysctl.inotify` | `fs.inotify.max_user_instances` / `max_user_watches` | WARN when instances is 128 or less; INFO when watches is below 524288 | `sysctl.tune` |
| `journald.size` | `/var/log/journal`, `/run/log/journal` (RAM), and `SystemMaxUse` / `RuntimeMaxUse` in journald.conf and its drop-ins | INFO when there is no cap of your own and the persistent journal is 1 GB or more, or the volatile one 256 MB or more (the default cap is already 10% of the filesystem, at most 4 GB). SKIP (needs admin) when the folders cannot be read. | `journald.cap` |
| `services.unused` | cups (service, socket, path), cups-browsed, avahi-daemon, bluetooth, ModemManager: enabled or active | cups-browsed is WARN and a security item (it listens on the network, CVE-2024-47176). The others are INFO. With a desktop running (display-manager), only cups-browsed is checked. avahi-daemon is report only: disabling it can make `host.local` names stop resolving. | `services.unused` (not avahi) |
| `unattended.reboot` | unattended-upgrades `Automatic-Reboot` / `-Time`; dnf-automatic `reboot =` with an enabled timer | WARN when the reboot time falls inside `--hours` ("now" counts as about 06:00, after apt-daily-upgrade); INFO without `--hours` | report only |
| `pkgcache` | apt, dnf, yum, apk, pacman and zypper caches | INFO above 2 GB; the clean commands are given as advice | report only |
| `fstrim` | non-rotational disks with `discard_max_bytes` > 0; `/` mounted with discard; `fstrim.timer` | INFO when the timer is disabled (or missing) | `fstrim.timer` |
| `smart` | `smartctl -H -n standby` per disk (at most 8; never wakes a sleeping disk); needs root and smartctl | WARN on a failing health check | report only |
| `thermal.throttle` | Intel `thermal_throttle` counters | INFO when the CPU throttled since boot (with a BIOS power and C-state reminder) | report only |
| `disk.full` | `df` of `/` and the work root's filesystem | WARN above 90% used | report only |

### Linux fixes (`sudo sh lanq-makeready-fix.sh --tune`)

`--tune` uses the same machinery as the other fixes: run at the PC (it refuses over SSH, from stdin, or without a
console), each fix confirmed with `[y/N]`, no `--yes`, root needed, an undo record written before each change, and
`--undo FILE` puts it back, newest first. `--tune` goes with an apply run or `--dry-run`; `--undo` and `--list` work
for every fix without it. A tune fix is offered only for what the tune scan reports: the fix script carries the
scan's decision functions unchanged, and a test checks that the copies match.

- `sysctl.tune` writes `/etc/sysctl.d/99-zz-lanq-makeready.conf` (only when absent) with the inotify limits that are
  below 1024 instances and 524288 watches, and applies them with `sysctl -w`. It never lowers a value. Undo removes the
  file and restores the old values.
- `journald.cap` writes `/etc/systemd/journald.conf.d/99-zz-lanq-makeready.conf` (`SystemMaxUse=1G`,
  `RuntimeMaxUse=256M`) and restarts journald. **The trimmed logs cannot be restored**; the prompt says so.
- `services.unused` runs `systemctl disable --now` on cups (service, socket and path), cups-browsed, bluetooth or
  ModemManager. Each is its own prompt, and none is offered while a desktop runs, except cups-browsed. It never masks.
  Undo re-enables and restarts exactly the units that were enabled and running.
- `fstrim.timer` runs `systemctl enable --now fstrim.timer`.

Undo takes unit, file and sysctl names only from fixed tables in the script. A service name in a record must be on
the script's append-only list and have the name shape, or the record is rejected.
```

## CHANGELOG bullets (0.5.0, Linux part)

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

## README (Linux lines, if the README lists the files and commands)

- `lanq-makeready-tune.sh` is a read-only tuning report; never a readiness verdict.
- `sudo sh lanq-makeready-fix.sh --tune --dry-run` shows the tune fixes, then run it without `--dry-run` at the PC.
