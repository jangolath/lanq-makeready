#!/bin/sh
# shellcheck disable=SC2034,SC2016,SC2329,SC2317,SC2030,SC2031,SC1091
# Tests for lanq-makeready-fix.sh (POSIX sh, busybox too). Usage: sh tests/fix.sh
# SAFETY: every apply/undo here runs against a fake systemctl (a shell function backed by files in a temp folder); the
# run stops before any scenario if systemctl is not that fake. Child processes are started only for refusals and
# argument errors, always with LANQ_MAKEREADY_FIX_LIB=1, which makes a direct run exit 2 right after the refusal checks.
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
fix="$root/lanq-makeready-fix.sh"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1 : expected '$3' got '$2'"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "$1" "$2"; fi; }
contains() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3" "$1" "*$2*" ;; esac; }
lacks() { case "$1" in *"$2"*) bad "$3" "$1" "no $2" ;; *) ok "$3" ;; esac; }
unset SSH_CONNECTION SSH_CLIENT SSH_TTY

LANQ_MAKEREADY_FIX_LIB=1
export LANQ_MAKEREADY_FIX_LIB
__lanq_makeready_fix_test_harness() { :; }
# shellcheck source=lanq-makeready-fix.sh
. "$fix"

echo "pure helpers"
for y in y Y yes YES ' yes '; do if is_yes "$y"; then ok "is_yes '$y'"; else bad "is_yes '$y'" no yes; fi; done
for n in '' n no ye yy 1 'yes please'; do if is_yes "$n"; then bad "is_yes '$n'" yes no; else ok "is_yes '$n' is no"; fi; done
for s in 'ssh.start|unit=ssh enabled=disabled active=inactive' 'ssh.start|unit=sshd enabled=enabled active=active' \
  'power.sleep|sleep=static suspend=masked hibernate=none hybrid-sleep=not-found'; do
  if valid_state "${s%%|*}" "${s#*|}"; then ok "state accepted: $s"; else bad "state accepted: $s" rejected accepted; fi
done
nl='
'
for s in 'ssh.start|unit=ssh enabled=disabled active=inactive;reboot' 'ssh.start|unit=evil enabled=disabled active=inactive' \
  'ssh.start|unit=ssh enabled=masked active=inactive' 'ssh.start|unit=$(id) enabled=disabled active=inactive' 'ssh.start|' \
  "ssh.start|unit=ssh enabled=disabled active=inactive${nl}unit=ssh enabled=disabled active=inactive" \
  'power.sleep|sleep=static suspend=static hibernate=static' 'power.sleep|sleep=Static suspend=static hibernate=static hybrid-sleep=static' \
  'evil.fix|value=1'; do
  if valid_state "${s%%|*}" "${s#*|}"; then bad "state rejected: $s" accepted rejected; else ok "state rejected: $s"; fi
done
eq "$(to_mask 'sleep=masked suspend=static hibernate=none hybrid-sleep=static')" "suspend.target hibernate.target hybrid-sleep.target" "to_mask: only targets not masked"
eq "$(field 'unit=sshd enabled=disabled active=inactive' unit)" sshd "field reads a value"

echo "guard (command words; mutations only inside the FIXES region; a test-time tripwire, not a sandbox)"
# same tokenizer as tests/run.sh (statement-start words, quotes and $() handled)
scan_awk='
function scan(l,   i, c, n, out, d, sq, dq, len) {
  gsub(/\$\{[^}]*\}/, "X", l)
  out = ""; d = 0; dq[0] = 0; sq = 0; len = length(l)
  for (i = 1; i <= len; i++) {
    c = substr(l, i, 1); n = substr(l, i + 1, 1)
    if (sq) { if (c == "\047") sq = 0; continue }
    if (c == "\047" && !dq[d]) { sq = 1; continue }
    if (c == "\\") { i++; continue }
    if (c == "\"") { dq[d] = !dq[d]; continue }
    if (c == "$" && n == "(") { d++; dq[d] = 0; out = out ";"; i++; continue }
    if (dq[d]) continue
    if (c == ")" && d > 0) { d--; out = out " "; continue }
    out = out c
  }
  sub(/(^|[ \t])#.*$/, "", out)
  return out
}'
cmd_words() {
  awk "$scan_awk"'
    /^[ \t]*#/ { next }
    {
      l = scan($0)
      while (match(l, /(^[ \t]*|;;[ \t]*|[ \t]in[ \t]+)[^ \t;()]+\)/)) l = substr(l, 1, RSTART - 1) " ; " substr(l, RSTART + RLENGTH)
      n = split(l, seg, /[;|&(){}]/)
      for (i = 1; i <= n; i++) {
        t = seg[i]; sub(/^[ \t]+/, "", t)
        while (t ~ /^(if|then|elif|else|do|while|until|!)[ \t]/) sub(/^[^ \t]+[ \t]+/, "", t)
        if (t ~ /^(for|case)[ \t]/) continue
        split(t, w, /[ \t]/)
        if (w[1] != "" && w[1] !~ /^[A-Za-z_][A-Za-z0-9_]*=/ && w[1] !~ /^[$<>0-9=-]/ && w[1] !~ /^\[/ && w[1] != "X" && w[2] !~ /^[-+*\/%]$/ && w[1] !~ /[*?\]:|]/) print w[1]
      }
    }' | sort -u
}
allowed=" printf echo awk sed tr cut head wc grep cat command id uname date sort uniq read test shift exit return true false break continue umask type mkdir mktemp mv rm fi done esac then else elif do in while for if case until [ ]] "
forbidden=" sudo su doas pkexec chmod chown ln cp tee curl wget nc ssh scp dd eval bash sh exec source apt apt-get dnf yum apk "
mutating='systemctl[^|;&]*[[:space:]](enable|disable|start|stop|restart|reload|try-restart|reload-or-restart|mask|unmask|daemon-reload|set-default|edit|kill|isolate|link|preset|preset-all|revert|reboot|poweroff|halt|suspend|hibernate|hybrid-sleep|set-property|set-environment)([[:space:]]|$)'
fix_guard() { # FILE -> one line per violation
  _g=$1
  if [ "$(grep -c '^# region FIXES$' "$_g")" != 1 ] || [ "$(grep -c '^# endregion FIXES$' "$_g")" != 1 ]; then echo "exactly one FIXES region"; return; fi
  _outside=$(awk '/^# region FIXES$/ {s=1} !s {print} /^# endregion FIXES$/ {s=0}' "$_g")
  _inside=$(awk '/^# region FIXES$/ {s=1} s {print} /^# endregion FIXES$/ {s=0}' "$_g")
  _fns=$(grep -E '^[a-z_0-9]+\(\)' "$_g" | sed 's/().*//')
  for _w in $(printf '%s\n' "$_outside" | cmd_words); do
    case "$allowed systemctl " in *" $_w "*) continue ;; esac
    case " $(echo $_fns) " in *" $_w "*) continue ;; esac
    echo "unknown command word: $_w"
  done
  for _w in $(printf '%s\n' "$_outside$nl$_inside" | cmd_words); do case "$forbidden" in *" $_w "*) echo "forbidden command word: $_w" ;; esac; done
  for _w in $(printf '%s\n' "$_inside" | cmd_words); do
    case "$_w" in systemctl|echo|printf|return|field|to_mask|fix_command|fix_change|esac|fi|done|then|else|elif) ;; *) echo "command word in FIXES other than systemctl and helpers: $_w" ;; esac
  done
  printf '%s\n' "$_outside" | grep -vE '^[[:space:]]*#' | grep -nE "$mutating" | sed 's/^/mutating systemctl outside FIXES: /'
  printf '%s\n' "$_outside" | grep -vE '^[[:space:]]*#' | grep -nE 'systemctl' | grep -vE 'systemctl is-(enabled|active) "\$1"|command -v systemctl' | sed 's/^/systemctl other than is-enabled or is-active outside FIXES: /'
  # (sudo is caught as a command word; messages may tell the owner to run the script with sudo themselves)
  printf '%s\n' "$_outside$nl$_inside" | grep -nE 'sed[[:space:]]+(-[A-Za-z]*i|--in-place)|find[[:space:]]|system[[:space:]]*\(|getline|sh -c|bash -c|`' | sed 's/^/raw: /'
  printf '%s\n' "$_outside$nl$_inside" | grep -nE '(^|[^A-Za-z_])eval([^A-Za-z_]|$)' | sed 's/^/eval: /'
  # file changes: only the record's temp file, renamed over the record
  printf '%s\n' "$_outside$nl$_inside" | grep -nE '(^|[^A-Za-z_])(rm|mv|mkdir|mktemp)[[:space:]]' | grep -vxE '[0-9]+:  (mkdir -p -- "\$_d" 2>/dev/null \|\| \{ err "lanq-makeready-fix: cannot create \$_d"; return 1; \}|_t=\$\(mktemp "\$_d/\.fix\.XXXXXX" 2>/dev/null\) \|\| \{ err "lanq-makeready-fix: cannot write in \$_d"; return 1; \}|if render_record > "\$_t" && mv -f -- "\$_t" "\$REC_PATH"; then return 0; fi|rm -f -- "\$_t")' | sed 's/^/file change other than the record: /'
  printf '%s\n' "$_outside$nl$_inside" | awk "$scan_awk"'
    /^[ \t]*#/ { next }
    { raw = $0
      gsub(/2>\/dev\/null|>\/dev\/null|<\/dev\/null|2>&1|>&2|> "\$_t"|< "\$_f"/, "", raw)
      if (scan(raw) ~ /[<>]/) print "redirection: " $0 }'
}
eq "$(fix_guard "$fix")" "" "fix script passes its guard"
mut_dir=${TMPDIR:-/tmp}/lanq-fixmut.$$
mkdir -p "$mut_dir"
mutant() { # name, line inserted before the FIXES region (or appended with $3 = end)
  if [ "${3:-}" = end ]; then cp "$fix" "$mut_dir/m.sh"; printf '%s\n' "$2" >> "$mut_dir/m.sh"
  else awk -v ins="$2" '/^# region FIXES$/ { print ins } { print }' "$fix" > "$mut_dir/m.sh"; fi
  if [ -n "$(fix_guard "$mut_dir/m.sh")" ]; then ok "GuardRejectsMutationOutsideFixTable: $1"; else bad "GuardRejectsMutationOutsideFixTable: $1" "not flagged" flagged; fi
}
mutant "systemctl mask outside" 'bad1() { systemctl mask sleep.target; }'
mutant "systemctl unmask outside" 'bad2() { systemctl unmask sleep.target; }'
mutant "systemctl enable --now outside" 'bad3() { systemctl enable --now ssh.service; }'
mutant "systemctl stop outside" 'bad4() { systemctl stop ssh.service; }'
mutant "systemctl via a variable" 'bad5() { _x=stop; systemctl "$_x" ssh.service; }'
mutant "systemctl --user mask" 'bad6() { systemctl --user mask foo; }'
mutant "systemctl after main" 'systemctl disable ssh.service' end
mutant "sudo" 'bad7() { sudo true; }'
mutant "eval" 'bad8() { eval "$1"; }'
mutant "sh -c" "bad9() { sh -c 'id'; }"
mutant "backtick" 'bad10() { x=`id`; }'
mutant "rm of something else" 'bad11() { rm -f -- "$REC_PATH"; }'
mutant "mv of something else" 'bad12() { mv /etc/a /etc/b; }'
mutant "redirect to a file" 'bad13() { echo x > /etc/x; }'
mutant "unknown command" 'bad14() { chattr +i /etc/x; }'
mutant "ln" 'bad15() { ln -s /dev/null /etc/systemd/system/x.target; }'
awk '/^# region FIXES$/ { print; print "fix_x() { reboot; }"; next } { print }' "$fix" > "$mut_dir/m.sh"
if [ -n "$(fix_guard "$mut_dir/m.sh")" ]; then ok "guard: a non-systemctl command inside FIXES is flagged"; else bad "guard inside FIXES" "not flagged" flagged; fi
awk '/^# endregion FIXES$/ { print "# endregion FIXES" } { print }' "$fix" > "$mut_dir/m.sh"
if [ -n "$(fix_guard "$mut_dir/m.sh")" ]; then ok "guard: a second region end is refused"; else bad "guard second region" "not flagged" flagged; fi
rm -rf "$mut_dir"
eq "$(grep -cE -- '^[[:space:]]*(--yes|-y|--force|-f)[|)]' "$fix")" 0 "NoYesFlag: no --yes, -y or --force in the code"
if LC_ALL=C grep -q '[^ -~]' "$fix"; then bad "fix script is plain ASCII" non-ascii ascii; else ok "fix script is plain ASCII (no control bytes)"; fi

echo "child processes: argument errors and real refusals (LANQ_MAKEREADY_FIX_LIB=1 safety net)"
child() { LANQ_MAKEREADY_FIX_LIB=1 sh "$fix" "$@" </dev/null 2>&1; }
for a in --yes -y --force -f --assume-yes; do
  o=$(child "$a"); rc=$?
  if [ "$rc" = 2 ]; then ok "NoYesFlag: $a -> exit 2"; else bad "NoYesFlag: $a" "$rc" 2; fi
  contains "$o" "unknown argument" "NoYesFlag: $a -> unknown argument"
done
o=$(child --dry-run --list); eq "$?" 2 "two modes at once: exit 2"
o=$(child --help); rc=$?; eq "$rc" 0 "--help: exit 0"; contains "$o" "no --yes" "--help says there is no --yes"
o=$(SSH_CONNECTION="10.20.30.5 50000 10.20.30.6 22" LANQ_MAKEREADY_FIX_LIB=1 sh "$fix" --dry-run </dev/null 2>&1); rc=$?
eq "$rc" 3 "RefusesOverSsh (real process, SSH_CONNECTION, dry run): exit 3"; contains "$o" "over SSH" "RefusesOverSsh: says why"
o=$(SSH_TTY=/dev/pts/3 LANQ_MAKEREADY_FIX_LIB=1 sh "$fix" --list </dev/null 2>&1); eq "$?" 3 "RefusesOverSsh (real process, SSH_TTY, --list): exit 3"
o=$(LANQ_MAKEREADY_FIX_LIB=1 sh -s -- --dry-run < "$fix" 2>&1); rc=$?
eq "$rc" 3 "RefusesFromStdin (real process, sh -s < file): exit 3"; contains "$o" "from stdin" "RefusesFromStdin: says why"
o=$(cat "$fix" | LANQ_MAKEREADY_FIX_LIB=1 sh 2>&1); eq "$?" 3 "RefusesFromStdin (real process, piped into sh): exit 3"
o=$(child); rc=$?
eq "$rc" 3 "RefusesWithoutConsole (real process, stdin not a terminal, apply): exit 3"; contains "$o" "no interactive console" "RefusesWithoutConsole: says why"
o=$(child --undo /nonexistent.json); eq "$?" 3 "RefusesWithoutConsole (real process, --undo): exit 3"
o=$(child --list); rc=$?
eq "$rc" 2 "a direct run with LANQ_MAKEREADY_FIX_LIB=1 passes the refusals, then exits 2"; contains "$o" "only for the test runner" "lib mode message"
if [ "$(uname -s)" = Darwin ]; then
  o=$(unset LANQ_MAKEREADY_FIX_LIB; sh "$fix" --dry-run </dev/null 2>&1); rc=$?
  eq "$rc" 0 "macOS: exit 0"; contains "$o" "no fixes for macOS" "macOS: says there are no fixes"
fi

echo "fakes (nothing below touches this machine)"
FAKE=${TMPDIR:-/tmp}/lanq-fixfake.$$
RECDIR=$FAKE/rec
FIX_SELF=$fix
fx_os() { echo "${FAKE_OS:-Linux}"; }
have_systemd() { return 0; }
is_root() { [ "$FAKE_ROOT" = 1 ]; }
has_console() { [ "$FAKE_CONSOLE" = 1 ]; }
rec_dir() { echo "$RECDIR"; }
latest_record() { for _r in "$RECDIR"/fix-*.json; do [ -e "$_r" ] && _last=$_r; done; [ -n "${_last:-}" ] && echo "$_last"; _last=""; }
systemctl() {
  case "$1" in
    is-enabled) echo "$2" >> "$FAKE/reads"; cat "$FAKE/u.$2.en" 2>/dev/null || return 1; [ "$(cat "$FAKE/u.$2.en")" != disabled ] ;;
    is-active) _fv=$(cat "$FAKE/u.$2.act" 2>/dev/null || echo inactive); echo "$_fv"; [ "$_fv" = active ] ;;
    *)
      echo "systemctl $*" >> "$FAKE/calls"
      _lr=$(latest_record); { if [ -n "$_lr" ]; then cat "$_lr"; fi; echo "----"; } >> "$FAKE/snaps"
      [ -f "$FAKE/failnext" ] && { rm -f "$FAKE/failnext"; return 1; }
      case "$1" in
        enable) shift; [ "$1" = --now ] && { shift; echo active > "$FAKE/u.$1.act"; }; echo enabled > "$FAKE/u.$1.en" ;;
        disable) echo disabled > "$FAKE/u.$2.en" ;;
        stop) echo inactive > "$FAKE/u.$2.act" ;;
        start) echo active > "$FAKE/u.$2.act" ;;
        mask) shift; for _fx in "$@"; do echo masked > "$FAKE/u.$_fx.en"; done ;;
        unmask) shift; for _fx in "$@"; do echo static > "$FAKE/u.$_fx.en"; done ;;
      esac ;;
  esac
}
if [ "$(type systemctl 2>/dev/null | head -n 1 | grep -c function)" = 1 ]; then ok "systemctl is the fake"; else echo "ABORT: systemctl is not faked"; exit 1; fi
reset_fake() { # everything fine: ssh enabled and active, sleep targets masked
  rm -rf "$FAKE"; mkdir -p "$FAKE"; : > "$FAKE/calls"; : > "$FAKE/snaps"; : > "$FAKE/reads"
  echo enabled > "$FAKE/u.ssh.service.en"; echo active > "$FAKE/u.ssh.service.act"; echo inactive > "$FAKE/u.ssh.socket.act"
  for t in sleep suspend hibernate hybrid-sleep; do echo masked > "$FAKE/u.$t.target.en"; done
  FAKE_ROOT=1; FAKE_CONSOLE=1; FAKE_OS=Linux; ON_ANSWER=""
}
setu() { echo "$2" > "$FAKE/u.$1"; } # setu ssh.service.en disabled
states() { echo "$(state_of ssh.start) / $(state_of power.sleep)"; }
calls() { awk '{ printf "%s%s", (NR > 1 ? "|" : ""), $0 }' "$FAKE/calls"; }
runfix() { # answers (printf %b), args...
  _feed=$1; shift; : > "$FAKE/calls"; : > "$FAKE/snaps"; : > "$FAKE/reads"
  printf '%b' "$_feed" | main "$@" > "$FAKE/out" 2>&1
  RC=$?; OUT=$(cat "$FAKE/out")
}

echo "apply and undo each fix (exact mutating commands; record written before the change; undo restores)"
case_fix() { # name, setup, expected apply calls, expected undo calls
  reset_fake; eval "$2"
  start=$(states)
  runfix 'y\n'
  eq "$RC" 0 "$1 apply: exit 0"
  eq "$(calls)" "$3" "$1 apply: exact commands"
  contains "$(cat "$FAKE/snaps")" '"status": "pending"' "RecordWrittenBeforeChange: $1"
  rec=$(latest_record)
  contains "$(cat "$rec")" '"status": "applied"' "$1 record: applied"
  contains "$OUT" "applied and verified" "$1 apply: verified"
  runfix 'y\n' --undo "$rec"
  eq "$RC" 0 "$1 undo: exit 0"
  eq "$(calls)" "$4" "UndoRestoresEachFix: $1 exact undo commands"
  eq "$(states)" "$start" "UndoRestoresEachFix: $1 state back to the start"
  contains "$(cat "$rec")" '"status": "undone"' "$1 record: undone"
  runfix 'y\n' --undo "$rec"
  if [ "$RC" = 0 ] && [ -z "$(calls)" ]; then ok "$1 second undo: nothing to do"; else bad "$1 second undo" "$RC $(calls)" "0, no calls"; fi
}
case_fix "ssh.start (disabled, inactive)" 'setu ssh.service.en disabled; setu ssh.service.act inactive' \
  "systemctl enable --now ssh.service" "systemctl disable ssh.service|systemctl stop ssh.service"
case_fix "ssh.start (enabled, failed)" 'setu ssh.service.act failed' "systemctl enable --now ssh.service" "systemctl stop ssh.service"
case_fix "ssh.start (sshd unit)" 'rm -f "$FAKE/u.ssh.service.en"; setu sshd.service.en disabled; setu sshd.service.act inactive' \
  "systemctl enable --now sshd.service" "systemctl disable sshd.service|systemctl stop sshd.service"
case_fix "power.sleep (none masked)" 'for t in sleep suspend hibernate hybrid-sleep; do setu $t.target.en static; done' \
  "systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target" "systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target"
case_fix "power.sleep (sleep already masked)" 'for t in suspend hibernate hybrid-sleep; do setu $t.target.en static; done' \
  "systemctl mask suspend.target hibernate.target hybrid-sleep.target" "systemctl unmask suspend.target hibernate.target hybrid-sleep.target"
rec=$(latest_record)
eq "$(sed -n 2p "$rec")" '  "schema": "lanq-makeready-fix/v1",' "record layout: schema line"
contains "$(sed -n 9p "$rec")" '    {"seq": 1, "id": "power.sleep", "status": "undone"' "record layout: one item per line"
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['schema']=='lanq-makeready-fix/v1'" "$rec" 2>/dev/null; then ok "record is valid JSON"; else bad "record JSON" invalid valid; fi
fi

echo "only conditions the scanner reports are offered"
reset_fake; runfix 'y\ny\n'
if [ "$RC" = 0 ] && [ -z "$(calls)" ]; then ok "all good: nothing changed"; else bad "all good" "$(calls)" none; fi
contains "$OUT" "Nothing to fix" "all good: says so"
reset_fake; setu ssh.service.act inactive; setu ssh.socket.act active; runfix '' --dry-run
lacks "$OUT" "ssh.start  (" "socket-activated sshd (scanner OK): ssh.start not offered"
reset_fake; rm -f "$FAKE/u.ssh.service.en"; runfix '' --dry-run
lacks "$OUT" "ssh.start  (" "no ssh unit: ssh.start not offered"

echo "DefaultIsNo"
for a in '\n' 'n\n' 'N\n' 'no\n' 'x\n' 'yes please\n' ''; do
  reset_fake; setu sleep.target.en static
  runfix "$a"
  if [ "$RC" = 0 ] && [ -z "$(calls)" ] && [ -z "$(latest_record)" ]; then ok "DefaultIsNo: answer '$a' -> nothing changed, no record"; else bad "DefaultIsNo '$a'" "$RC $(calls)" "0, none"; fi
  contains "$OUT" "Apply? [y/N]" "DefaultIsNo: '$a' was asked"
done

echo "SkipsAdminItemsWhenNotElevated"
reset_fake; setu ssh.service.act inactive; setu sleep.target.en static; FAKE_ROOT=0
runfix 'y\ny\n'
if [ "$RC" = 0 ] && [ -z "$(calls)" ] && [ -z "$(latest_record)" ]; then ok "SkipsAdminItemsWhenNotElevated: nothing changed"; else bad "not root" "$(calls)" none; fi
eq "$(printf '%s\n' "$OUT" | grep -c 'needs root')" 2 "SkipsAdminItemsWhenNotElevated: a note per fix"
lacks "$OUT" "Apply?" "not root: nothing asked"
contains "$OUT" "never elevates itself" "not root: says it never elevates itself"

echo "WhatIfChangesNothing"
reset_fake; setu ssh.service.en disabled; setu ssh.service.act inactive; setu sleep.target.en static; FAKE_CONSOLE=0
before=$(states); runfix 'y\ny\n' --dry-run
if [ "$RC" = 0 ] && [ -z "$(calls)" ] && [ -z "$(latest_record)" ] && [ "$(states)" = "$before" ]; then ok "WhatIfChangesNothing: no command, no record, no console needed"; else bad "dry run" "$RC $(calls)" "0, none"; fi
contains "$OUT" "ssh.start  (" "dry run shows ssh.start"; contains "$OUT" "power.sleep  (" "dry run shows power.sleep"
eq "$(printf '%s\n' "$OUT" | grep -c '^  undo: ')" 3 "dry run shows each undo command"
lacks "$OUT" "Apply?" "dry run asks nothing"

# from here a test confirm with a hook (the seam a driver uses), same answer rules as the script's
confirm() { if [ -n "${ON_ANSWER:-}" ]; then eval "$ON_ANSWER"; fi; printf '  Apply? [y/N] '; _ans=""; read -r _ans || _ans=""; is_yes "$_ans"; }

echo "EachFixRechecksPreconditionFirst"
reset_fake; setu ssh.service.act inactive; ON_ANSWER='setu ssh.service.act active'; runfix 'y\n'
if [ -z "$(calls)" ]; then ok "EachFixRechecksPreconditionFirst: ssh.start fixed meanwhile -> nothing done"; else bad "recheck ssh" "$(calls)" none; fi
contains "$OUT" "no longer needed" "recheck ssh: says so"
reset_fake; setu sleep.target.en static; ON_ANSWER='setu sleep.target.en masked'; runfix 'y\n'
if [ -z "$(calls)" ]; then ok "EachFixRechecksPreconditionFirst: power.sleep fixed meanwhile -> nothing done"; else bad "recheck power" "$(calls)" none; fi
reset_fake; setu sleep.target.en static; ON_ANSWER='setu suspend.target.en static'; runfix 'y\n'
if [ -z "$(calls)" ]; then ok "state changed to another value after it was shown: nothing done"; else bad "recheck changed" "$(calls)" none; fi
contains "$OUT" "changed since it was shown" "recheck changed: says so"

echo "UndoInReverseOrder and UndoSkipsChangedSince"
reset_fake; setu ssh.service.en disabled; setu ssh.service.act inactive; setu sleep.target.en static
start=$(states); runfix 'y\ny\n'; rec=$(latest_record)
eq "$(calls)" "systemctl enable --now ssh.service|systemctl mask sleep.target" "applied in list order"
runfix 'y\ny\n' --undo "$rec"
eq "$(calls)" "systemctl unmask sleep.target|systemctl disable ssh.service|systemctl stop ssh.service" "UndoInReverseOrder: newest change first"
eq "$(states)" "$start" "UndoInReverseOrder: everything restored"
reset_fake; setu ssh.service.en disabled; setu ssh.service.act inactive; setu sleep.target.en static
runfix 'y\ny\n'; rec=$(latest_record)
setu sleep.target.en static
runfix 'y\ny\n' --undo "$rec"
contains "$OUT" "changed since; left alone" "UndoSkipsChangedSince: power.sleep unmasked by hand, left alone"
eq "$(calls)" "systemctl disable ssh.service|systemctl stop ssh.service" "UndoSkipsChangedSince: the other fix is still undone"
contains "$(cat "$rec")" '"id": "power.sleep", "status": "applied"' "UndoSkipsChangedSince: record keeps the skipped item as applied"
reset_fake; setu sleep.target.en static; runfix 'y\n'; rec=$(latest_record)
runfix 'n\n' --undo "$rec"
if [ -z "$(calls)" ]; then ok "undo: default no leaves it"; else bad "undo no" "$(calls)" none; fi
ON_ANSWER='setu suspend.target.en static'; runfix 'y\n' --undo "$rec"
if [ -z "$(calls)" ]; then ok "undo: re-checks the state after the answer"; else bad "undo recheck" "$(calls)" none; fi
setu suspend.target.en masked; FAKE_ROOT=0; runfix 'y\n' --undo "$rec"
if [ -z "$(calls)" ]; then ok "undo when not root: skipped"; else bad "undo not root" "$(calls)" none; fi
contains "$OUT" "needs root" "undo when not root: says so"

echo "a failed change is recorded"
reset_fake; setu sleep.target.en static; : > "$FAKE/failnext"; runfix 'y\n'
eq "$RC" 1 "failed change: exit 1"; contains "$(cat "$(latest_record)")" '"status": "failed"' "failed change: item failed"

echo "refusals (in process: the driver seam cannot skip SSH or stdin)"
for m in "" --dry-run --list "--undo /nonexistent.json"; do
  reset_fake; setu sleep.target.en static
  # shellcheck disable=SC2086
  SSH_CLIENT="10.20.30.5 50000 22"; export SSH_CLIENT; runfix 'y\n' $m; unset SSH_CLIENT
  if [ "$RC" = 3 ] && [ -z "$(calls)" ] && [ ! -s "$FAKE/reads" ]; then ok "RefusesOverSsh (${m:-apply}): exit 3 before any read"; else bad "RefusesOverSsh ${m:-apply}" "$RC" 3; fi
  FIX_SELF=/nonexistent/sh
  # shellcheck disable=SC2086
  runfix 'y\n' $m; FIX_SELF=$fix
  if [ "$RC" = 3 ] && [ ! -s "$FAKE/reads" ]; then ok "RefusesFromStdin (${m:-apply}): exit 3"; else bad "RefusesFromStdin ${m:-apply}" "$RC" 3; fi
  contains "$OUT" "from stdin" "RefusesFromStdin (${m:-apply}): says why"
done
for m in "" "--undo /nonexistent.json"; do
  reset_fake; setu sleep.target.en static; FAKE_CONSOLE=0
  # shellcheck disable=SC2086
  runfix 'y\n' $m
  if [ "$RC" = 3 ] && [ -z "$(calls)" ] && [ ! -s "$FAKE/reads" ]; then ok "RefusesWithoutConsole (${m:-apply}): exit 3"; else bad "RefusesWithoutConsole ${m:-apply}" "$RC" 3; fi
done
reset_fake; FAKE_CONSOLE=0; runfix '' --list; eq "$RC" 0 "--list needs no console"; contains "$OUT" "No undo records" "--list: none yet"
reset_fake; FAKE_OS=Darwin; runfix '' --dry-run; eq "$RC" 0 "macOS: exit 0"; contains "$OUT" "no fixes for macOS" "macOS: no fixes"

echo "TamperedRecordRejected"
reset_fake; setu ssh.service.en disabled; setu ssh.service.act inactive; setu sleep.target.en static
runfix 'y\ny\n'; rec=$(latest_record); cp "$rec" "$FAKE/good.json"
tamper() { # name, sed expression (or a command with $3 = cmd)
  if [ "${3:-}" = cmd ]; then eval "$2" < "$FAKE/good.json" > "$rec"; else sed "$2" "$FAKE/good.json" > "$rec"; fi
  if cmp -s "$rec" "$FAKE/good.json"; then bad "tamper '$1' changes the file" same changed; return; fi
  cp "$rec" "$FAKE/t.json"
  runfix 'y\ny\n' --undo "$rec"
  if [ "$RC" = 2 ] && [ -z "$(calls)" ] && cmp -s "$rec" "$FAKE/t.json"; then ok "TamperedRecordRejected: $1 -> exit 2, nothing run, file untouched"; else bad "TamperedRecordRejected: $1" "$RC $(calls)" "2, none"; fi
  contains "$OUT" "record rejected" "TamperedRecordRejected: $1 says why"
}
tamper "schema id" 's#lanq-makeready-fix/v1#lanq-makeready-fix/v2#'
tamper "unknown fix id" 's/"id": "power.sleep"/"id": "evil.fix"/'
tamper "command in before" 's/"before": "sleep=static/"before": "sleep=static;reboot/'
tamper "subexpression in before" 's/"before": "unit=ssh enabled=disabled/"before": "unit=$(reboot) enabled=disabled/'
tamper "unit outside the list" 's/"before": "unit=ssh /"before": "unit=getty /'
tamper "extra item field" 's/"seq": 2,/"seq": 2, "run": "reboot",/'
tamper "extra line" '/"os": "linux"/a\
  "hook": "reboot",'
tamper "unknown status" 's/"status": "applied"/"status": "done"/'
tamper "repeated seq" 's/"seq": 2,/"seq": 1,/'
tamper "seq zero" 's/"seq": 2,/"seq": 0,/'
tamper "windows record" 's/"os": "linux"/"os": "windows"/'
tamper "quote in command" 's/"command": "systemctl/"command": "\\"systemctl/'
tamper "bad after shape" 's/"after": "sleep=masked/"after": "sleep=masked;x/'
tamper "missing comma" 's/"after": "\(unit[^"]*\)"},/"after": "\1"}/'
eacute=$(printf '\303\251')
tamper "non-ASCII" "s/\"user\": \"/&$eacute/"
tamper "CR line ends" "awk '{ printf \"%s\r\n\", \$0 }'" cmd
tamper "truncated" "head -n 6" cmd
tamper "padded past the size limit" "awk '{ print } END { for (i = 0; i < 1800; i++) print \"                                        \" }'" cmd
cp "$FAKE/good.json" "$rec"
runfix '' --list; contains "$OUT" "ssh.start applied, power.sleep applied" "--list shows the records"
printf '{\n}\n' > "$RECDIR/fix-20990101T000000Z.json"; runfix '' --list; contains "$OUT" "not a valid record" "--list marks a bad record"
runfix 'y\n' --undo "$RECDIR/missing.json"; eq "$RC" 2 "undo of a missing file: exit 2"
ln -s "$rec" "$RECDIR/link.json" 2>/dev/null && [ -L "$RECDIR/link.json" ] && { runfix 'y\n' --undo "$RECDIR/link.json"; eq "$RC" 2 "undo through a symlink: exit 2"; }
rm -rf "$FAKE"

echo "ScannerUnchangedAndStillReadOnly"
scan="$root/lanq-makeready.sh"
eq "$(grep -c 'region FIXES\|lanq-makeready-fix' "$scan")" 0 "scanner has no fix table and does not call the fix script"
eq "$(grep -c "^TOOL_VERSION=$TOOL_VERSION\$" "$scan")" 1 "scanner and fix script report the same version"
eq "$(awk '/^# BEGIN ADVICE$/ {s=1} !s {print} /^# END ADVICE$/ {s=0}' "$scan" | grep -v '^[[:space:]]*#' | grep -cE "$mutating")" 0 "scanner (outside its advice table) has no mutating systemctl"
contains "$(grep -n 'usage: lanq-makeready.sh' "$scan")" "[--json PATH|-] [--out FILE] [--redact] [--hours HH:MM-HH:MM] [--quiet]" "scanner arguments unchanged (no fix flag)"
for f in lanq-makeready.sh lanq-makeready-fix.sh tests/run.sh tests/fix.sh lanq-makeready.ps1 lanq-makeready-fix.ps1 tests/run.ps1 tests/fix.ps1 schema/fix-record.v1.json; do
  if LC_ALL=C grep -q "$(printf '[\001-\010\013\014\016-\037\177]')" "$root/$f"; then bad "$f has no control bytes" found none; else ok "$f has no control bytes"; fi
done
contains "$(cat "$root/schema/fix-record.v1.json")" '"const": "lanq-makeready-fix/v1"' "schema/fix-record.v1.json carries the schema id"

echo
echo "fix sh tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
