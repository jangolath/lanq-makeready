# Fix undo record (`lanq-makeready-fix/v1`)

The fix script (`lanq-makeready-fix.ps1` / `lanq-makeready-fix.sh`) writes one undo record per session that changes
something. A dry run, a list or a session where every fix is declined or skipped writes no record. The JSON Schema is
[schema/fix-record.v1.json](../schema/fix-record.v1.json). This page explains it.

The record is for the fix script's `-Undo` / `--undo` and for people to read. Do not edit it: undo rejects a record
that does not have exactly the shape below, and it acts only when the PC's state still matches what the record says.

## Where records live

| OS | Path | Permissions |
|---|---|---|
| Windows | `%ProgramData%\lanq-makeready\fix-<yyyyMMddTHHmmssZ>.json` | The folder is created by the script with its permissions in the same call: owned by Administrators, protected (nothing inherited), and only Administrators and SYSTEM have access (`O:BAD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)`). Each record file is created the same way (`O:BAD:PAI(A;;FA;;;BA)(A;;FA;;;SY)`). An existing folder is never re-permissioned, only checked: if it is not owned by Administrators or SYSTEM, protected (nothing inherited), not a link, and with only Administrators and SYSTEM in its DACL, the run stops before the first question. Records are never kept in `%LOCALAPPDATA%`. |
| Linux | `/var/lib/lanq-makeready/fix-<yyyyMMddTHHmmssZ>.json` | Created by root with umask 077: folder 700, files 600, owned by root. An existing folder that is not root's with mode 700, or is a link, stops the run before the first question. |

The time in the name is UTC. When a name is taken, `-2`, `-3`, ... is added. Every fix needs root, so on Linux
records are written only to `/var/lib/lanq-makeready/`. `--list` also lists `${XDG_STATE_HOME:-~/.local/state}/lanq-makeready/`
and marks any record there (or any record that is not root's alone) as not trusted.

A record is saved by writing a temp file in the same folder and moving it over the record, so a crash leaves the old
or the new version whole, never half a file. On Windows a leftover `fix-....json.tmp` stops the script until you remove it.

## Who may undo it

- Undo reads only `fix-<time>.json` files directly in the record folder above (on Linux the path is resolved, links
  followed, and its folder must be `/var/lib/lanq-makeready`). A record copied anywhere else is rejected.
- Windows: undo needs an elevated PowerShell (without it: a note and exit 1). The record file and its folder must be
  owned by Administrators or SYSTEM, and nobody else may have a right that changes them (write, append, delete, change
  permissions or owner). Neither may be a link.
- Linux: undo needs root (without it: a note and exit 1). The record file and its folder must not be symlinks, must
  be owned by uid 0, and must not be writable by group or others.

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
| `id` | the fix id. Windows: `ssh.start`, `ssh.auto`, `power.sleep`, `longpaths.on`, `git.longpaths`, `ssh.aclkeys`, and the tune fixes (0.5, `-Tune`) `power.cpu`, `power.usbsuspend`, `startup.vendor`, `vendor.services`, `vendor.tasks`, `sysmain`, `do.mode`, `dotnet.env`, `defender.scantime`, `defender.exclude`. Linux: `ssh.start`, `power.sleep`, and with `--tune` also `sysctl.tune`, `journald.cap`, `services.unused` and `fstrim.timer`. Ids are additive: a script that does not know an id rejects the whole record ("unknown fix id", exit 2), so a 0.4 script refuses a 0.5 record with a tune id. |
| `status` | `pending`, `applied`, `failed`, `undone` or `skipped` (below). |
| `time` | UTC time of the last status change. |
| `before` | the state before the change, in the fixed shape for the id (below). Undo puts this back. |
| `command` | the exact command(s) that were run, joined by ` ; `, for people to read. It is never executed. |
| `after` | the state found after the change, same shape as `before`, or `unknown` when it could not be read. While `pending` it holds the state the change is expected to leave. Undo acts only when the current state equals it. |

There are no other fields, and no field may be missing. The file is plain ASCII (other characters are written as `?`).
Windows accepts up to 256 KB, Linux up to 64 KB. On Linux `command` may be up to 510 characters.

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
| windows : `power.sleep` | `scheme=<guid> standby=<seconds> hibernate=(<seconds>\|-)` | the active power plan (`powercfg /getactivescheme`, lower case) and its AC timeouts from `powercfg /q`; `-` = hibernate timeout unreadable (then it is not changed). 0 = never. Because the plan is part of the state, undo acts only while the same plan is active; after a plan switch it says "changed since; left alone". |
| windows : `longpaths.on` | `value=<n> type=dword` or `value=- type=none` | `LongPathsEnabled` under `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`; `none` = absent. A value of another type is never offered. |
| windows : `git.longpaths` | `value=(<word>\|-)` | `git config --system core.longpaths`, 1-16 letters or digits; `-` = unset |
| windows : `ssh.aclkeys` | `dacl=D:<flags>(<ace>)...` | the DACL of `%ProgramData%\ssh\administrators_authorized_keys` in SDDL: allow (`A`) and deny (`D`) entries only, at most 64. On undo a `before` DACL is also rejected unless it has entries, no deny entry, and full control for both Administrators and SYSTEM; when it is protected, the same is required of its explicit entries alone, since that is what undo writes. After the undo the file's DACL is read again, and the undo fails loudly if Administrators or SYSTEM lost full control. |
| windows : `power.cpu` | `scheme=<guid> max=<0-100> min=<0-100>` | the active plan and its AC processor maximum and minimum state (`powercfg /q SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX/MIN`). Undo acts only while the same plan is active. |
| windows : `power.usbsuspend` | `scheme=<guid> usbsuspend=(0\|1)` | the active plan and its AC USB selective suspend setting |
| windows : `startup.vendor` | `hive=(HKCU\|HKLM) key=(Run\|Run32) sid=<S-1-5-...> flag=(-\|<24 hex>) name=<name>` | the entry's StartupApproved value (12 bytes; `-` = no value, which means enabled). `Run32` is the WOW6432Node Run key and exists only for HKLM. `sid` is the account that ran the fix: undo of an HKCU entry is refused under another account ("left alone"). It is compared on its own, not as part of the state. The name is 1-96 of letters, digits, space and `. _ ( ) & + { } -`, and must still match the curated list (or its append-only retired list), checked by name or, for a Run entry, by the program it runs. |
| windows : `vendor.services`, `sysmain` | `start=[0-4] delayed=(0\|1) name=<service>` | the service's `Start` and `DelayedAutostart` registry values; `delayed` counts only when `start=2`. Undo runs `sc.exe config <service> start= boot\|system\|auto\|demand\|disabled` (`delayed-auto` for start=2 delayed=1). The name is 1-64 of letters, digits and `_ . -`; for `sysmain` it is `SysMain`; a vendor service name (or its display name) must still match the curated list. |
| windows : `vendor.tasks` | `enabled=(0\|1) path=\<folder>\...\ name=<name>` | a scheduled task; a path under `\Microsoft\` is rejected. Undo runs `Enable-ScheduledTask`; the name must still match the curated list. |
| windows : `do.mode` | `value=<n> type=dword` or `value=- type=none` | the `DODownloadMode` policy under `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization`. The fix starts only from `none`, and undo removes the value (the key stays). |
| windows : `dotnet.env` | `telemetry=(-\|<v>) nologo=(-\|<v>) aspnetcert=(-\|<v>)` | the machine environment values of `DOTNET_CLI_TELEMETRY_OPTOUT`, `DOTNET_NOLOGO`, `DOTNET_GENERATE_ASPNET_CERTIFICATE` (1-8 letters or digits; `-` = not set). Undo removes only the ones that were `-`. |
| windows : `defender.scantime` | `day=[0-8] time=<0-1439> quick=<0-1439>` | Defender `ScanScheduleDay` and the scan and daily quick scan times in minutes after midnight (quick 0 = none). Undo sets both times back. |
| windows : `defender.exclude` | `excluded=(0\|1) path=<drive path>` | whether exactly this folder is in Defender's exclusion list. The path is a drive path of letters, digits, space and `_ . ( ) -`, never `..` and never a drive root. The fix starts only from `excluded=0` (folders already covered are not offered); undo runs `Remove-MpPreference -ExclusionPath` for that folder only. |
| linux : `ssh.start` | `unit=(ssh\|sshd) enabled=(enabled\|disabled) active=(active\|inactive)` | `systemctl is-enabled` / `is-active` of the unit (`failed` counts as inactive) |
| linux : `power.sleep` | `sleep=<v> suspend=<v> hibernate=<v> hybrid-sleep=<v>` | `systemctl is-enabled` of the four targets, for example `static`, `masked`, `masked-runtime`, `none` (not found) |
| linux : `sysctl.tune` | `file=(absent\|lanq) instances=<n> watches=<n>` | The two `fs.inotify` limits, and `/etc/sysctl.d/99-zz-lanq-makeready.conf` (`lanq` = a regular file, not a link, whose first line is this script's marker). It is offered only when the file is absent. Apply writes the file, holding only the limits below 1024 / 524288 (it never lowers one), then runs `sysctl -w` for them. Undo removes the file and runs `sysctl -w` with the old values of the raised limits. |
| linux : `journald.cap` | `file=(absent\|lanq)` | `/etc/systemd/journald.conf.d/99-zz-lanq-makeready.conf`, holding `SystemMaxUse=1G` and `RuntimeMaxUse=256M`, then `systemctl restart systemd-journald.service`. Undo removes the file and restarts journald. **The journal files deleted by the cap cannot be restored**, and the prompt says so. An empty `journald.conf.d` folder created by the fix stays. |
| linux : `services.unused` | `svc=<name> <type>=<enabled>:<active> ...` | One item per service. The name must be in the script's append-only list, and the unit words must match its fixed unit table (`cups`: `service socket path`; `cups-browsed`, `bluetooth`, `modemmanager`: `service`). Values are `enabled\|disabled\|none` and `active\|inactive`. Apply runs `systemctl disable --now` on the units that are enabled or active, and never masks. Undo runs `systemctl enable` on the units that were enabled, then `systemctl start` on the ones that were active. The unit names come from the script's table, never from the record. |
| linux : `fstrim.timer` | `enabled=(enabled\|disabled) active=(active\|inactive)` | `fstrim.timer`. Apply runs `enable --now`. Undo runs `disable` and/or `stop`, as for `ssh.start`. |

How the states are compared:

- For `ssh.aclkeys`, two DACLs count as the same state when the protection flag and the set of explicit (not
  inherited) entries are the same, in any order. Undo puts back exactly those. Inherited entries come back from the parent folder as it is when
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
the record. The tune fixes are the exception that is needed: a vendor service, task or Run entry name, and an excluded
folder, come from the record, so they must have the exact shape above, and the names must match the curated list
(current or retired) before anything is done. On Linux, undo reads the `services.unused` service name from `before` and accepts it only if it is on the script's append-only list (names are never removed, so old records stay undoable) and has the shape `[a-z][a-z0-9-]{0,31}`; it runs only the units of that name from the script's fixed table. The `command` field is never run. The `host` and `user` fields are for people only.

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
    {"seq": 1, "id": "power.sleep", "status": "applied", "time": "2026-11-13T21:04:31Z", "before": "scheme=381b4222-f694-41f0-9685-ff5bb260df2e standby=1800 hibernate=10800", "command": "powercfg /change standby-timeout-ac 0 ; powercfg /change hibernate-timeout-ac 0", "after": "scheme=381b4222-f694-41f0-9685-ff5bb260df2e standby=0 hibernate=0"},
    {"seq": 2, "id": "longpaths.on", "status": "applied", "time": "2026-11-13T21:04:40Z", "before": "value=0 type=dword", "command": "Set-ItemProperty -Path HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem -Name LongPathsEnabled -Value 1 -Type DWord", "after": "value=1 type=dword"},
    {"seq": 3, "id": "git.longpaths", "status": "pending", "time": "2026-11-13T21:04:52Z", "before": "value=-", "command": "\"C:\\Program Files\\Git\\cmd\\git.exe\" config --system core.longpaths true", "after": "value=true"}
  ]
}
```

Item 3 is still `pending`: the session stopped after the record was written. Undo looks at git first: if
`core.longpaths` is still unset it marks the item `skipped` ("never applied"); if it is `true` it offers to unset it.

## Example (Windows, `-Tune`)

```json
{
  "schema": "lanq-makeready-fix/v1",
  "tool": {"name": "lanq-makeready-fix", "version": "0.5.0"},
  "os": "windows",
  "host": "BUILD-01",
  "user": "builder",
  "started": "2026-11-14T21:04:10Z",
  "items": [
    {"seq": 1, "id": "power.cpu", "status": "applied", "time": "2026-11-14T21:04:20Z", "before": "scheme=381b4222-f694-41f0-9685-ff5bb260df2e max=90 min=5", "command": "powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 ; powercfg /setactive SCHEME_CURRENT", "after": "scheme=381b4222-f694-41f0-9685-ff5bb260df2e max=100 min=5"},
    {"seq": 2, "id": "vendor.services", "status": "applied", "time": "2026-11-14T21:04:31Z", "before": "start=2 delayed=1 name=ExampleUpdateService", "command": "sc.exe config ExampleUpdateService start= disabled", "after": "start=4 delayed=1 name=ExampleUpdateService"},
    {"seq": 3, "id": "startup.vendor", "status": "applied", "time": "2026-11-14T21:04:40Z", "before": "hive=HKCU key=Run sid=S-1-5-21-1-2-3-1001 flag=- name=ExampleTray", "command": "Set-ItemProperty -LiteralPath 'HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run' -Name 'ExampleTray' -Type Binary -Value 3,0,0,0,0,0,0,0,0,0,0,0", "after": "hive=HKCU key=Run sid=S-1-5-21-1-2-3-1001 flag=030000000000000000000000 name=ExampleTray"}
  ]
}
```

(The service and entry names here are placeholders; a real record holds names from the curated list.) Undo of item 3
removes the StartupApproved value again (`flag=-` means there was none) and is refused under another account.

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
