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

- **Defender exclusions** (elevated runs only) are compared with work_root, the NuGet packages and temp inside the
  probe; only "scanned" or "excluded" per folder comes out. The list is never printed or put in the JSON.
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
  touched, and undo re-checks every name against that list. Defender exclusions need a second switch
  (`-DefenderExclusions`), cover work_root plus the NuGet package cache only (never temp, processes, a drive root, or a Windows, program,
  shared-data or user folder or a parent of one; the NuGet cache only when the elevated account is the console user), and
  are not offered when Defender is not the active antivirus.
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

Residual risks, stated plainly:

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
