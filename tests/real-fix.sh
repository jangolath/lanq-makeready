#!/bin/sh
# CI ONLY: real apply and undo of lanq-makeready-fix.sh on a disposable GitHub Ubuntu runner (systemd, run as root with
# sudo -E). This CHANGES the machine (ssh unit, sleep targets) and then puts it back. It refuses to run unless
# GITHUB_ACTIONS=true and LANQ_REAL_FIX_OK=disposable-runner. Never run it on a machine you care about.
# The only test seam used is console simulation: has_console returns true and the answers (y) come from stdin.
# shellcheck disable=SC1091,SC2329
if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${LANQ_REAL_FIX_OK:-}" != disposable-runner ]; then
  echo "real-fix.sh: refusing: this changes the machine; it runs only in CI on a disposable runner." >&2; exit 2
fi
if [ "$(id -u)" != 0 ]; then echo "real-fix.sh: run it as root (sudo -E)" >&2; exit 2; fi
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
LANQ_MAKEREADY_FIX_LIB=1
export LANQ_MAKEREADY_FIX_LIB
__lanq_makeready_fix_test_harness() { :; }
. "$root/lanq-makeready-fix.sh"
FIX_SELF=$root/lanq-makeready-fix.sh
has_console() { return 0; }
fail=0
check() { if [ "$1" = 0 ]; then echo "  ok   $2"; else fail=$((fail + 1)); echo "  FAIL $2"; fi; }
snap() { echo "$(state_of ssh.start) / $(state_of power.sleep)"; }
raw() { for u in ssh.service ssh.socket sleep.target suspend.target hibernate.target hybrid-sleep.target; do echo "  $u: $(systemctl is-enabled "$u" 2>/dev/null) $(systemctl is-active "$u" 2>/dev/null)"; done; }

before=$(snap); echo "before: $before"; raw
for id in $FIX_IDS; do s=$(state_of "$id"); needed "$id" "$s"; check $? "setup made $id necessary"; done
printf 'y\ny\n' | main; check $? "apply: exit 0"
echo "after apply: $(snap)"; raw
for id in $FIX_IDS; do done_ok "$id" "$(state_of "$id")"; check $? "applied for real: $id"; done
[ "$(systemctl is-active ssh.service)" = active ]; check $? "ssh.service really active"
[ "$(systemctl is-enabled suspend.target)" = masked ]; check $? "suspend.target really masked"
rec=$(ls -t /var/lib/lanq-makeready/fix-*.json | head -n 1)
echo "record: $rec ($(stat -c '%a %U' "$rec"))"; cat "$rec"
[ "$(stat -c '%a' "$rec")" = 600 ] && [ "$(stat -c '%a' /var/lib/lanq-makeready)" = 700 ]; check $? "record 600 in a 700 folder"
if command -v python3 >/dev/null 2>&1; then python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$rec"; check $? "record is valid JSON"; fi
printf 'y\ny\n' | main --undo "$rec"; check $? "undo: exit 0"
after=$(snap); echo "after undo: $after"; raw
[ "$after" = "$before" ]; check $? "undo restored: $before"
[ "$(grep -c '"status": "undone"' "$rec")" = 2 ]; check $? "record: both items undone"
[ "$fail" = 0 ]
