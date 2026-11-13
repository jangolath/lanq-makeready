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
- **Bounded.** Every external command has a time limit; no whole-disk walks.

### The fix script: `lanq-makeready-fix.ps1` / `lanq-makeready-fix.sh` (0.4.0+)

The fix script changes the PC, but only what its owner confirms there, one item at a time.

- **Local only.** It refuses to run over SSH, from stdin or a string (`sh -s`, `sh -c`, a pipe,
  `[scriptblock]::Create`, `iex`), or without an interactive console (exit 3). LanQueue does not embed or run it.
- **Confirm each.** There is no `--yes`, `-Yes` or `-Force`. Each fix shows the check, the current state, the exact
  command and its undo, and asks `Apply? [y/N]`. The default is no.
- **Short, fixed list.** Windows: start sshd, start it automatically, no sleep or hibernate on AC, long paths, git
  `core.longpaths`, the `administrators_authorized_keys` permissions. Linux: start sshd, mask the sleep targets.
  Nothing is installed, deleted, upgraded or downloaded, and there are no network calls.
- **Never elevates itself.** Without admin or root, every fix is skipped with a note.
- **Undo record.** Each change is recorded as `pending` before it is made and updated after it, so a crash leaves a
  usable record. `-Undo` / `--undo` puts the changes back, newest first, confirming each. It touches an item only
  when its current state is still the one the fix left ("changed since; left alone" otherwise).
- **Records in admin-only or root-owned places.** Windows: `%ProgramData%\lanq-makeready`, owned by Administrators,
  not inherited, only Administrators and SYSTEM. If the folder exists and is not like that, nothing is written. Linux:
  `/var/lib/lanq-makeready`, folder 700 and files 600, owned by root.
- **Tamper handling.** Undo rejects (exit 2, nothing changed) a record whose file or folder someone other than
  Administrators/SYSTEM (Windows) or root (Linux) could have written, or a link. It also rejects a record with any
  field outside its fixed shape. Undo never runs text from the record. It builds each command from the fix id and the
  parsed before state; service, registry key, file and unit names are fixed in the script. Undo of `ssh.aclkeys` puts
  back only a DACL that keeps full control for Administrators and SYSTEM and has no deny entry.

Residual risks, stated plainly:

- **Undo of `ssh.aclkeys` re-opens what was open.** It gives the keys file back the permissions it had. Accounts that
  could change it before can change it again, and sshd ignores the file again. The prompt shows those permissions
  before you confirm.
- **The checks are not a sandbox.** The refusals (SSH, stdin, console, aliases) and the record checks stop mistakes
  and remote use. They do not protect against code that already runs as admin or root on the PC: such code can change
  the PC, or a record, directly.
- **SSH detection is best effort.** It uses the SSH variables, the parent processes, and on Linux logind's session.
  A session that hides all three is not recognized; the console check and the per-fix prompt still apply.
- **Inherited permissions.** Undo of `ssh.aclkeys` restores the file's own entries. Inherited entries come from the
  parent folder as it is at undo time.

## Guards and review

Both test suites include a guard: the scanner's allows no mutating command outside its advice table, and the fix
script's allows changes only inside its `FIXES` block. A guard is a **test-time tripwire** against accidental mutating
code, not a sandbox: the guarantee rests on review of every change. A change that breaks any promise above is a
security bug.

Supported version: the latest release. Verify downloads, including the fix scripts, with `SHA256SUMS` and
`gh attestation verify` (see README).
