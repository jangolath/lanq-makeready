# Fix undo record (`lanq-makeready-fix/v1`)

The fix script (`lanq-makeready-fix.ps1` / `lanq-makeready-fix.sh`) writes one undo record per session that changes
something. A dry run, a list or a session where every fix is declined or skipped writes no record. The JSON Schema is
[schema/fix-record.v1.json](../schema/fix-record.v1.json). This page explains it.

The record is for the fix script's `-Undo` / `--undo` and for people to read. Do not edit it: undo rejects a record
that does not have exactly the shape below, and it acts only when the PC's state still matches what the record says.

## Where records live

| OS | Path | Permissions |
|---|---|---|
| Windows | `%ProgramData%\lanq-makeready\fix-<yyyyMMddTHHmmssZ>.json` | The folder is created by the script, owned by Administrators, protected (nothing inherited), and only Administrators and SYSTEM have access (`O:BAG:SYD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)`). Each record gets the same owner and DACL. Records are never kept in `%LOCALAPPDATA%`. |
| Linux | `/var/lib/lanq-makeready/fix-<yyyyMMddTHHmmssZ>.json` | Created by root with umask 077: folder 700, files 600, owned by root. |

The time in the name is UTC. When a name is taken, `-2`, `-3`, ... is added. On Linux the script would use
`${XDG_STATE_HOME:-~/.local/state}/lanq-makeready/` for a non-root user, but a non-root user can make no change, so
records are written only as root. `--list` shows both folders.

A record is saved by writing a temp file in the same folder and moving it over the record, so a crash leaves the old
or the new version whole, never half a file. On Windows a leftover `fix-....json.tmp` stops the script until you remove it.

## Who may undo it

- Windows: undo needs an elevated PowerShell. The record file and its folder must be owned by Administrators or
  SYSTEM, and nobody else may have a right that changes them (write, append, delete, change permissions or owner).
  Neither may be a link.
- Linux: undo needs root. The record file and its folder must not be symlinks, must be owned by uid 0, and must not be
  writable by group or others.

Otherwise the record is rejected with exit 2 and nothing is changed.

## Fields

```text
{
  "schema":  "lanq-makeready-fix/v1",
  "tool":    {"name": "lanq-makeready-fix", "version": "N.N.N"},
  "os":      "windows" | "linux",
  "host":    host name (letters, digits, . _ -; other characters become _; at most 64),
  "user":    user name (same rules; on Linux this is root, since fixes run under sudo),
  "started": UTC time the record was created, yyyy-MM-ddTHH:mm:ssZ,
  "items":   [ item, ... ]   (at most 64)
}
```

Each item:

| Field | Meaning |
|---|---|
| `seq` | 1 to 999, unique: the order the changes were made. Undo goes from the highest down. |
| `id` | the fix id. Windows: `ssh.start`, `ssh.auto`, `power.sleep`, `longpaths.on`, `git.longpaths`, `ssh.aclkeys`. Linux: `ssh.start`, `power.sleep`. |
| `status` | `pending`, `applied`, `failed`, `undone` or `skipped` (below). |
| `time` | UTC time of the last status change. |
| `before` | the state before the change, in the fixed shape for the id (below). Undo puts this back. |
| `command` | the exact command(s) that were run, joined by ` ; `, for people to read. It is never executed. |
| `after` | the state found after the change, same shape as `before`, or `unknown` when it could not be read. While `pending` it holds the state the change is expected to leave. Undo acts only when the current state equals it. |

There are no other fields, and no field may be missing. The file is plain ASCII (other characters are written as `?`).
Windows accepts up to 256 KB, Linux up to 64 KB.

## Statuses

```text
pending --(change made and verified)--> applied --(undo verified)--> undone
   |    --(change or check failed)----> failed  --(undo verified)--> undone
   |
   +----(undo finds the before state: the change was never made)--> skipped
   +----(undo finds the expected after state: crash after the change)--> undone
```

- **pending**: written just before the change. If the script, the PC or the power stops before the next save, this
  is what remains, and undo can still handle it.
- **applied**: the change was made and the check after it passed.
- **failed**: the change returned an error or the check after it did not pass. `after` holds what was found, so undo
  can put back whatever did change.
- **undone**: undo put the `before` state back and checked it.
- **skipped**: a `pending` item whose change was never made (undo found the `before` state). Undo prints "never applied".

Undo considers `pending`, `applied` and `failed` items. When the current state is neither `before` (for a pending item)
nor `after`, it prints "changed since; left alone" and leaves the item and its status unchanged. An item you decline
also keeps its status.

## State shapes

Each `before` and `after` must match the shape for its OS and fix id exactly. Anything else makes the whole record
invalid.

| OS : id | Shape | Notes |
|---|---|---|
| windows : `ssh.start`, `ssh.auto` | `starttype=(Automatic\|Manual\|Disabled) status=(Running\|Stopped)` | the sshd service |
| windows : `power.sleep` | `standby=<seconds> hibernate=(<seconds>\|-)` | AC timeouts of the active power plan from `powercfg /q`; `-` = hibernate timeout unreadable (then it is not changed). 0 = never. |
| windows : `longpaths.on` | `value=<n> type=dword` or `value=- type=none` | `LongPathsEnabled` under `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`; `none` = absent. A value of another type is never offered. |
| windows : `git.longpaths` | `value=(<word>\|-)` | `git config --system core.longpaths`, 1-16 letters or digits; `-` = unset |
| windows : `ssh.aclkeys` | `dacl=D:<flags>(<ace>)...` | the DACL of `%ProgramData%\ssh\administrators_authorized_keys` in SDDL: allow (`A`) and deny (`D`) entries only, at most 64. On undo a `before` DACL is also rejected unless it has entries, no deny entry, and full control for both Administrators and SYSTEM. |
| linux : `ssh.start` | `unit=(ssh\|sshd) enabled=(enabled\|disabled) active=(active\|inactive)` | `systemctl is-enabled` / `is-active` of the unit (`failed` counts as inactive) |
| linux : `power.sleep` | `sleep=<v> suspend=<v> hibernate=<v> hybrid-sleep=<v>` | `systemctl is-enabled` of the four targets, for example `static`, `masked`, `masked-runtime`, `none` (not found) |

How the states are compared:

- For `ssh.aclkeys`, two DACLs count as the same state when the protection flag and the explicit (not inherited)
  entries are the same. Undo puts back exactly those. Inherited entries come back from the parent folder as it is when
  you undo; Windows re-creates them and does not take them from the record.
- Everything else is compared as exact text.

## How undo uses a record

1. Check the record's file and folder permissions (see "Who may undo it").
2. Parse and check every field and every state against the shapes above. One bad field rejects the whole record.
3. For each `pending`, `applied` or `failed` item, newest `seq` first: read the current state, compare, show, ask
   `Apply? [y/N]`, read the state again, make the change, check that the state is now `before`, and save the record
   with the item marked `undone`.

The undo command comes from a fixed table in the script, keyed by the fix id, with the values taken from the
parsed `before` state (a start type, a number of seconds, a registry value, a git value, a list of fixed target
names, a checked DACL). The service, registry key, file and unit names are fixed in the script and are never read from
the record. The `command` field is never run. The `host` and `user` fields are for people only.

## Example (Windows)

```json
{
  "schema": "lanq-makeready-fix/v1",
  "tool": {"name": "lanq-makeready-fix", "version": "0.4.0"},
  "os": "windows",
  "host": "BUILD-01",
  "user": "builder",
  "started": "2026-11-13T21:04:10Z",
  "items": [
    {"seq": 1, "id": "power.sleep", "status": "applied", "time": "2026-11-13T21:04:31Z", "before": "standby=1800 hibernate=10800", "command": "powercfg /change standby-timeout-ac 0 ; powercfg /change hibernate-timeout-ac 0", "after": "standby=0 hibernate=0"},
    {"seq": 2, "id": "longpaths.on", "status": "applied", "time": "2026-11-13T21:04:40Z", "before": "value=0 type=dword", "command": "Set-ItemProperty -Path HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem -Name LongPathsEnabled -Value 1 -Type DWord", "after": "value=1 type=dword"},
    {"seq": 3, "id": "git.longpaths", "status": "pending", "time": "2026-11-13T21:04:52Z", "before": "value=-", "command": "\"C:\\Program Files\\Git\\cmd\\git.exe\" config --system core.longpaths true", "after": "value=true"}
  ]
}
```

Item 3 is still `pending`: the session stopped after the record was written. Undo looks at git first: if
`core.longpaths` is still unset it marks the item `skipped` ("never applied"); if it is `true` it offers to unset it.

## Example (Linux)

```json
{
  "schema": "lanq-makeready-fix/v1",
  "tool": {"name": "lanq-makeready-fix", "version": "0.4.0"},
  "os": "linux",
  "host": "build-01",
  "user": "root",
  "started": "2026-11-13T21:10:02Z",
  "items": [
    {"seq": 1, "id": "ssh.start", "status": "applied", "time": "2026-11-13T21:10:09Z", "before": "unit=ssh enabled=disabled active=inactive", "command": "systemctl enable --now ssh.service", "after": "unit=ssh enabled=enabled active=active"},
    {"seq": 2, "id": "power.sleep", "status": "undone", "time": "2026-11-13T21:30:44Z", "before": "sleep=static suspend=static hibernate=static hybrid-sleep=static", "command": "systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target", "after": "sleep=masked suspend=masked hibernate=masked hybrid-sleep=masked"}
  ]
}
```

The scripts write exactly this layout: one item per line, in this field order. The sh script reads records line by line
and accepts only this layout, so a record reformatted by an editor or a JSON tool is rejected on Linux.
