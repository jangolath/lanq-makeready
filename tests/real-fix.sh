#!/bin/sh
# CI ONLY: real apply and undo of lanq-makeready-fix.sh on a disposable GitHub-hosted Ubuntu runner (systemd, run as
# root). This CHANGES the machine (ssh unit, sleep targets) and then puts it back. The gate below (GITHUB_ACTIONS,
# RUNNER_ENVIRONMENT=github-hosted, LANQ_REAL_FIX_OK) only guards against running it by accident; it is not a security
# boundary. Never run it on a machine you care about.
# The only test seam used is console simulation: has_console returns true and the answers (y) come from stdin.
# shellcheck disable=SC1091,SC2329
if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ] || [ "${LANQ_REAL_FIX_OK:-}" != disposable-runner ]; then
  echo "real-fix.sh: refusing: this changes the machine; it runs only in CI on a disposable GitHub-hosted runner." >&2; exit 2
fi
if [ "$(id -u)" != 0 ]; then echo "real-fix.sh: run it as root (sudo env ...)" >&2; exit 2; fi
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
LANQ_MAKEREADY_FIX_LIB=1
export LANQ_MAKEREADY_FIX_LIB
__lanq_makeready_fix_test_harness() { :; }
# shellcheck source=lanq-makeready-fix.sh
. "$root/lanq-makeready-fix.sh"
FIX_SELF=$root/lanq-makeready-fix.sh
has_console() { return 0; }
fail=0
check() { if [ "$1" = 0 ]; then echo "  ok   $2"; else fail=$((fail + 1)); echo "  FAIL $2"; fi; }
raw() { for u in ssh.service ssh.socket sleep.target suspend.target hibernate.target hybrid-sleep.target; do printf '%s=%s/%s ' "$u" "$(systemctl is-enabled "$u" 2>/dev/null)" "$(systemctl is-active "$u" 2>/dev/null)"; done; echo; }
snap() { echo "$(state_of ssh.start) / $(state_of power.sleep) / $(raw)"; }

before=$(snap); echo "before: $before"
echo "sleep risk (the scanner's view): $(sleep_risk)"
for id in $FIX_IDS; do s=$(state_of "$id"); needed "$id" "$s"; check $? "setup made $id necessary"; done
printf 'y\ny\n' | main; check $? "apply: exit 0"
echo "after apply: $(snap)"
for id in $FIX_IDS; do done_ok "$id" "$(state_of "$id")"; check $? "applied for real: $id"; done
[ "$(systemctl is-active ssh.service)" = active ]; check $? "ssh.service really active"
[ "$(systemctl is-enabled suspend.target)" = masked ]; check $? "suspend.target really masked"
rec=$(ls -t /var/lib/lanq-makeready/fix-*.json | head -n 1)
echo "record: $rec ($(stat -c '%a %U' "$rec"))"; cat "$rec"
[ "$(stat -c '%a' "$rec")" = 600 ] && [ "$(stat -c '%a' /var/lib/lanq-makeready)" = 700 ]; check $? "record 600 in a 700 folder"
record_trusted "$rec"; check $? "L6: the record passes the root-ownership check"
if command -v python3 >/dev/null 2>&1; then python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$rec"; check $? "record is valid JSON"; fi
printf 'y\ny\n' | main --undo "$rec"; check $? "undo: exit 0"
after=$(snap); echo "after undo: $after"
[ "$after" = "$before" ]; check $? "undo restored everything, ssh.socket included: $before"
[ "$(grep -c '"status": "undone"' "$rec")" = 2 ]; check $? "record: both items undone"
[ "$fail" = 0 ]
