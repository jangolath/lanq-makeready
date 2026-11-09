# Security policy

## Reporting a vulnerability

Please report privately using GitHub's "Report a vulnerability" (private security advisory) on this repository.
Do not open a public issue for security problems. Expect an acknowledgement within a few days; this is a
volunteer-maintained project.

## What this tool promises

`lanq-makeready` is meant to be run on someone else's PC (often a family member's), so its promises are strict:

- **Read-only.** It never installs, uninstalls, updates, changes settings, edits the registry, starts or stops
  services, or touches drivers. Every fix is printed as advice for a person to run, or not.
- **Writes only what you name.** The JSON report (`-Json`/`--json PATH`) and the human report (`-Out`/`--out FILE`).
  `-Out` only creates a new file and refuses an existing one, so it cannot overwrite anything.
- **No network.** No telemetry, no update check, no downloads. Version probes run from a neutral folder with
  toolchain auto-download switched off (`GOTOOLCHAIN=local`, `RUSTUP_AUTO_INSTALL=0`).
- **No secrets.** It never reads private keys or `~/.docker/config.json`. `-Redact` / `--redact` removes host
  name, user name, profile paths and the network adapter's MAC address before the report is built.
- **No admin needed.** Checks that need admin are reported as `SKIP`.
- **Bounded.** Every external command has a time limit; no whole-disk walks.

The test suites include a read-only guard. It is a **test-time tripwire** against accidental mutating code, not a
sandbox: the guarantee rests on review of every change. A change that breaks any promise above is a security bug.

Supported version: the latest release. Verify downloads with `SHA256SUMS` and `gh attestation verify` (see README).
