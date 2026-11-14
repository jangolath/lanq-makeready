# Security policy

## Reporting a vulnerability

Please report privately using GitHub's "Report a vulnerability" (private security advisory) on this repository.
Do not open a public issue for security problems. Expect an acknowledgement within a few days; this is a
volunteer-maintained project.

## What these tools promise

`lanq-makeready` is meant to be run on someone else's PC (often a family member's), so its promises are strict. There
are two kinds of script, and each promise below names the script it covers.

### The scanner: `lanq-makeready.ps1` / `lanq-makeready.sh`

- **Read-only.** The scanner never installs, uninstalls, updates, changes settings, edits the registry, starts or stops
  services, or touches drivers. Every fix is printed as advice for a person to run, or not. It has no fix switch and
  never runs the fix script.
- **Writes only what you name.** The JSON report (`-Json`/`--json PATH`) and the human report (`-Out`/`--out FILE`).
  `-Out` only creates a new file and refuses an existing one, so it cannot overwrite anything (on Linux/macOS it
  writes a temp file in the same folder, links it into place with `ln`, and removes the temp file).
- **No network.** No telemetry, no update check, no downloads. Version probes run from a neutral folder with
  toolchain auto-download switched off (`GOTOOLCHAIN=local`, `RUSTUP_AUTO_INSTALL=0`).
- **No secrets.** It never reads private keys or `~/.docker/config.json`. `-Redact` / `--redact` removes host
  name, user name, profile paths and the network adapter's MAC address before the report is built.
- **No admin needed.** Checks that need admin are reported as `SKIP`.
- **Bounded.** Every tool probe and every ACL read (`getfacl`, `ls`) has a time limit. Quick local reads of one file or
  folder (`find -maxdepth 0`, `readlink`, `id`, `uname`, `sed` on a config file) do not. No whole-disk walks.
- **Suggests only safe toolchain folders.** `path_prepend` is suggested only for a .NET folder other local users
  cannot write: the owner and DACL on Windows; on Linux the owner, the mode bits and (0.4.1+) the POSIX ACL read with
  `getfacl` (access and default entries), or, without it, the `ls` ACL marker (`+`; on busybox, any group write).
  Anything the check cannot read counts as open, with one limit: on busybox without getfacl, an ACL with only
  `default:` entries is not seen (install the `acl` package). Only folders and `dotnet` itself are checked, not the files in them.
  NFSv4 ACLs and SELinux are not read; on macOS no entry is suggested.

### The tune scan: `lanq-makeready-tune.ps1` / `lanq-makeready-tune.sh` (0.5.0+)

The same promises as the scanner: read-only, no network, no admin needed, writes only the `-Json` file you name,
`-Redact` on values, a time limit on every probe (and 90 seconds for the whole run). It never affects readiness and
always exits 0 (2 for bad arguments). Two reads deserve a word:

- **Defender exclusions** (elevated runs only) are compared with work_root, the NuGet packages, lanq-work and temp
  inside the probe; only "scanned" or "excluded" per folder, and whether the lanq-work entry is there as the fix wrote
  it, come out. The list is never printed or put in the JSON. Entries with a variable are never expanded in the
  scanning account's context (0.6.0; Defender expands them as SYSTEM).
- **lanq-work drift** (0.6.0, elevated runs only): when the lanq-work exclusion exists, it reads the fix records
  (only trusted ones, as the fix script does), the folder's owner, permissions and file id, the volume, and the
  permissions of at most 2000 entries in its top two levels (5 s). It prints only what drifted.
- **Autologon**: the script tests only whether a `DefaultPassword` value exists under Winlogon (`GetValueNames()`).
  It never reads that value, and a test bans `Get-ItemProperty` from the script.

Its findings (`detail`, `advice`) are text for a person. Tools that read the JSON must not act on them.

### The fix script: `lanq-makeready-fix.ps1` / `lanq-makeready-fix.sh` (0.4.0+)

The fix script changes the PC, but only what its owner confirms there, one item at a time.

- **Local only.** It refuses to run over SSH, from stdin or a string (`sh -s`, `sh -c`, a pipe,
  `[scriptblock]::Create`, `iex`), or without an interactive console (exit 3). LanQueue does not embed or run it.
  The SSH check is a tripwire against accidental or naive remote use (see the residual risks below).
- **Runs what it means.** On Windows it refuses to start (exit 3) when a function or alias would run instead of one of
  its own functions or of a cmdlet it uses (for example one defined by a profile); start PowerShell with `-NoProfile`.
  The sh script removes all aliases before it starts.
- **Confirm each.** There is no `--yes`, `-Yes` or `-Force`. Each fix shows the check, the current state, the exact
  command and its undo, and asks `Apply? [y/N]`. The default is no.
- **Short, fixed list.** Windows: start sshd, start it automatically, no sleep or hibernate on AC, long paths, git
  `core.longpaths`, the `administrators_authorized_keys` permissions. Linux: start sshd, mask the sleep targets.
  With `-Tune` (0.5.0+): the tune fixes in [docs/TUNE.md](docs/TUNE.md). PC-maker services, tasks and Run entries are
  taken only from a short curated list in the code (never "everything unused"), tasks under `\Microsoft\` are never
  touched, and undo re-checks every name against that list. With `-Tune -CreateDevDrive` or `-Tune
  -DefenderExclusions` (0.6.0+, each needs `-BuildUser`): the Defender ladder below.
  Nothing is installed, deleted, upgraded or downloaded, and there are no network calls.
- **Never elevates itself.** Without admin or root, every fix is skipped with a note.
- **Undo record.** Each change is recorded as `pending` before it is made and updated after it, so a crash leaves a
  usable record. `-Undo` / `--undo` puts the changes back, newest first, confirming each. It touches an item only
  when its current state is still the one the fix left ("changed since; left alone" otherwise).
- **Records in admin-only or root-owned places.** Windows: `%ProgramData%\lanq-makeready`, owned by Administrators,
  not inherited, only Administrators and SYSTEM. The folder and each record file are created with these permissions
  in the same call; an existing folder is never re-permissioned, only checked. Linux: `/var/lib/lanq-makeready`,
  folder 700 and files 600, owned by root. If the folder exists and is not like that (another owner, other
  permissions, a link), the run stops before the first question and nothing is changed; the message says what is
  wrong and how to move the folder out of the way.
- **Tamper handling.** Undo reads only `fix-<time>.json` files directly in the record folder above; a record copied
  anywhere else is rejected. It also rejects (exit 2, nothing changed) a record whose file or folder someone other than
  Administrators/SYSTEM (Windows) or root (Linux) could have written, or a link, and a record with any field outside
  its fixed shape. Undo never runs text from the record. It builds each command from the fix id and the
  parsed before state; service, registry key, file and unit names are fixed in the script. Undo of `ssh.aclkeys` puts
  back only a DACL that keeps full control for Administrators and SYSTEM and has no deny entry, checks that on what it
  actually writes (the saved explicit entries, when the DACL was protected), and reads the file's DACL again afterwards:
  if Administrators or SYSTEM lost full control it fails loudly and prints the command that gives it back.

### The Defender ladder in the fix script (0.6.0+)

A Defender exclusion is a string that Defender matches at scan time, so the script excludes exactly one string it
controls, for one folder it makes itself, and proves it. Reviewers check every change against this invariant:

> Only SYSTEM, Administrators and the build user can cause any file to exist at an excluded path. The build user can
> do so only inside lanq-work, and only for code it already runs, or for a principal it deliberately lets in. No
> principal can redirect, rename or recreate any part of the excluded path.

- **No path from anyone.** The one exclusion is `<drive>:\lanq-work\`, on the drive Windows is on; the Dev Drive rung
  adds none. No argument, environment variable or record field can change it. A syntactic test of the script's
  AST allows only that string, but it is a tripwire for review, not a proof. There is no `-Path` and no configuration.
- **The script makes the folder.** `lanq-work` is created with its owner (Administrators) and its permissions in one
  call, then read back: owner, exact permissions, empty, not a link, its file id. The build user can add and change
  files inside but cannot rename, delete or re-permission the folder, and OWNER RIGHTS takes away its right to
  re-permission its own files later (not to choose the permissions of a new one: see H3 below). An existing folder is used only when a trusted fix record matches its volume GUID,
  file id and permissions hash (no marker file, which anyone could copy).
- **The drive root is checked** (nobody but Administrators, SYSTEM and TrustedInstaller may delete or rename what is
  in it, or change its permissions or owner), and so are the drive (fixed, internal, NTFS, not a Dev Drive) and case
  sensitivity. Any doubt, any policy-managed Defender, or Defender for Endpoint: not offered (report only).
- **Proven, not assumed.** Before the exclusion: a positive control (the EICAR test file in an admin-only folder
  must be caught). After it: exactly one new entry, exactly that string; the test file must stay inside lanq-work and
  must still be caught in every sibling form anyone could create (`lanq-work-x`, `lanq-workx`, `lanq-work.x`,
  `lanq-work.`, `lanq-work` with a trailing space, a stream: this run's tagged file in Defender's threat history).
  Any miss, error or interruption after the exclusion was added removes it again and reads the list back; if it is
  still there the run says FAILED with the command to run (exit 1). A failed item never counts as done.
- **Self-test folders cannot be swapped.** Each is made admin-only in the record folder and moved into place (a move
  fails when the name exists), and checked again before every write and delete; a folder that is not ours is never
  written to or deleted.
- **lanq-work is never empty** (review round 2). It is made with a permanent admin-only child `.lanq-pin` in an
  admin-only place and moved into place, so the build user can never turn it into a junction (that works only on an
  empty folder) and cannot delete the pin. The pin is checked on every read-back and reuse, and lanq-work (not a
  link, the same file id, the pin there) right before every move into it, write and delete there.
- **Undo** removes only that exclusion string. The folder, its `.lanq-pin` and a Dev Drive are never deleted.
- **No P/Invoke or Add-Type** in the product scripts (the non-admin checks are done in the CI test with LogonUser).

New places the fix script writes, all only after you type the path to confirm: `%SystemDrive%\lanq-work` and its
`.lanq-pin` (or `<Dev Drive>:\lanq-work` and its pin, staged in `<Dev Drive>:\.lanq-stage-<id>`); the Defender exclusion `<drive>:\lanq-work\`; self-test folders on the drive root
(`lanq-selftest-<id>`, `lanq-work-<id>`, `lanq-work<id>`, `lanq-work.<id>`, `lanq-work.`, `lanq-work` with a trailing space,
`lanq-work-<id>-ads`) and `lanq-work\lanq-selftest-<id>`, each created admin-only in the record folder (as
`stage-<id>-<n>`), moved into place and removed again (a sibling name that
already exists is never touched: the run stops); Defender's threat history (the EICAR detections); and for the Dev
Drive, `%ProgramData%\lanq-makeready\devdrive\lanq-devdrive.vhdx` (folder Administrators and SYSTEM only) and the new
volume.

Residual risks, stated plainly:

- **The build user's own output is not scanned.** That account already runs the build code, so the exclusion adds no
  new exposure for it. Administrators must not run files from lanq-work.
- **The build user can let others in** (accepted, review H3). OWNER RIGHTS stops it from changing permissions
  later, but it can give a new file or folder any permissions when it creates it, move in a file from elsewhere on
  the same drive that carries its own permissions, or make a hard link to a file it can write; then another account
  could change that file, unscanned. Use a **dedicated** build account that runs
  nothing else; the tune scan's `defender.drift` samples the top two levels for entries others may change. Only a
  dedicated volume (a Dev Drive, rung 1, needs no exclusion at all) closes this fully.
- **`NUGET_PACKAGES` per job only.** Setting it for the whole machine would make an administrator's `dotnet build`
  run package build files (`.props`, `.targets`, analyzers) the build account can change. The script never sets it;
  the docs say per job (machines.yml `env:`).
- **Defender's matching is checked, not known.** The sibling matrix runs at every apply, and on a pool PC before each
  release; a Defender update that changed matching would fail the next self-test, not the existing exclusion. Run the
  tune scan elevated now and then (`defender.drift`).
- **A Dev Drive VHDX** may need attaching again after a restart (see docs/TUNE.md).

- **Undo of `ssh.aclkeys` re-opens what was open.** It gives the keys file back the permissions it had. Accounts that
  could change it before can change it again, and sshd ignores the file again. The prompt shows those permissions
  before you confirm.
- **The checks are not a sandbox.** The refusals (SSH, stdin, console, aliases) and the record checks stop mistakes
  and remote use. They do not protect against code that already runs as admin or root on the PC: such code can change
  the PC, or a record, directly.
- **SSH detection is a tripwire, not a barrier.** It uses the SSH variables, the parent processes (Windows: also
  session 0), and on Linux logind's view of the login session. It stops accidental or naive remote use, such as an
  agent or a script running the fix script through `ssh`. It does not stop a determined admin or root: for example
  `systemd-run --pty`, `machinectl shell`, a scheduled task, or attaching at the console to a tmux or screen session
  can give a session that looks local. Such a person can change the PC directly anyway; the console check and the
  per-fix prompt still apply.
- **Inherited permissions.** Undo of `ssh.aclkeys` restores the file's own entries. Inherited entries come from the
  parent folder as it is at undo time.

## Guards and review

Both test suites include a guard: the scanner's allows no mutating command outside its advice table, and the fix
script's allows changes only inside its `FIXES` block. A guard is a **test-time tripwire** against accidental mutating
code, not a sandbox: the guarantee rests on review of every change. A change that breaks any promise above is a
security bug.

Supported version: the latest release. Verify downloads, including the fix scripts, with `SHA256SUMS` and
`gh attestation verify` (see README).
