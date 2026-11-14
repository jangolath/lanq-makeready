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
eq "$(to_mask 'sleep=masked-runtime suspend=static hibernate=masked hybrid-sleep=static')" "suspend.target hybrid-sleep.target" "C13: a target masked only until reboot (masked-runtime) is left alone"
for l in '-rw------- 1 0 0 10 Nov 13 10:00 f' 'drwx------ 2 0 0 4096 Nov 13 10:00 d' 'drwxr-xr-x 2 0 0 4096 Nov 13 10:00 d' '-rw-r--r--+ 1 0 0 1 Nov 13 10:00 f'; do
  if perm_ok "$l"; then ok "L6 perm_ok: $l"; else bad "L6 perm_ok: $l" refused ok; fi
done
for l in '-rw-rw---- 1 0 0 1 Nov 13 10:00 f' '-rw----rw- 1 0 0 1 Nov 13 10:00 f' '-rw------- 1 1000 0 1 Nov 13 10:00 f' 'drwxrwxrwt 2 0 0 1 Nov 13 10:00 d' ''; do
  if perm_ok "$l"; then bad "L6 perm_ok refuses: $l" ok refused; else ok "L6 perm_ok refuses: '$l'"; fi
done
if [ "$(uname -s)" = Linux ] && [ -f /etc/hostname ] && [ "$(ls -ldn /etc | awk '{ print $3 }')" = 0 ]; then
  if record_trusted /etc/hostname; then ok "L6 record_trusted: a root-owned file in a root-owned folder"; else bad "L6 record_trusted /etc/hostname" refused ok; fi
fi
tdir=${TMPDIR:-/tmp}/lanq-fixtrust.$$; mkdir -p "$tdir"; : > "$tdir/r.json"
if [ "$(id -u)" != 0 ]; then if record_trusted "$tdir/r.json"; then bad "L6 record_trusted: a file owned by this user" ok refused; else ok "L6 record_trusted: a file not owned by root is refused"; fi; fi
cp "$fix" "$tdir/other-name.sh"
if (FIX_SELF=$tdir/other-name.sh; from_file); then bad "L3 from_file: a renamed copy" ok refused; else ok "L3 from_file: a file not named lanq-makeready-fix.sh is refused"; fi
if (FIX_SELF=$fix; from_file); then ok "L3 from_file: the script itself"; else bad "L3 from_file: the script itself" refused ok; fi
rm -rf "$tdir"
if (audit_session_id() { echo 7; }; session_props() { printf 'Remote=yes\nService=gdm-password\n'; }; logind_remote); then ok "M2 logind: Remote=yes is remote"; else bad "M2 logind Remote=yes" local remote; fi
if (audit_session_id() { echo 7; }; session_props() { printf 'Remote=no\nService=sshd\n'; }; logind_remote); then ok "M2 logind: Service=sshd is remote"; else bad "M2 logind Service=sshd" local remote; fi
if (audit_session_id() { echo 7; }; session_props() { printf 'Remote=no\nService=gdm-password\n'; }; logind_remote); then bad "M2 logind local" remote local; else ok "M2 logind: a local session is local"; fi
if (audit_session_id() { echo 4294967295; }; session_props() { printf 'Remote=yes\n'; }; logind_remote); then bad "M2 no session" remote nothing; else ok "M2 logind: no login session (containers, CI): says nothing"; fi
if (audit_session_id() { echo 7; }; session_props() { :; }; logind_remote); then bad "M2 no loginctl" remote nothing; else ok "M2 logind: no loginctl: says nothing"; fi
if (unset SSH_CONNECTION SSH_CLIENT SSH_TTY; audit_session_id() { echo 7; }; session_props() { printf 'Remote=yes\n'; }; over_ssh); then ok "M2 over_ssh: sudo dropped SSH_*, logind still says remote"; else bad "M2 over_ssh via logind" local remote; fi
for fn in logind_values classify_sleep logind_auto_suspend; do
  a=$(awk -v f="$fn() {" 'index($0, f) == 1 { p = 1 } p { print } p && /^}/ { exit }' "$root/lanq-makeready.sh")
  b=$(awk -v f="$fn() {" 'index($0, f) == 1 { p = 1 } p { print } p && /^}/ { exit }' "$fix")
  if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "C1: $fn is the scanner's, unchanged"; else bad "C1: $fn copy" differs same; fi
done

echo "guard (command words; mutations only inside the FIXES region; a test-time tripwire, not a sandbox)"
# the tokenizer of tests/run.sh, stricter: a quoted string leaves a placeholder (Q or S), so a statement that starts
# with one ("$cmd" args) shows up as an unknown command word, and so do words starting with $ ($cmd args)
scan_awk='
function scan(l,   i, c, n, out, d, sq, dq, len) {
  gsub(/\$\{[^}]*\}/, "X", l)
  out = ""; d = 0; dq[0] = 0; sq = 0; len = length(l)
  for (i = 1; i <= len; i++) {
    c = substr(l, i, 1); n = substr(l, i + 1, 1)
    if (sq) { if (c == "\047") sq = 0; continue }
    if (c == "\047" && !dq[d]) { sq = 1; if (d == 0) out = out "S"; continue }
    if (c == "\\") { i++; continue }
    if (c == "\"") { if (!dq[d] && d == 0) out = out "Q"; dq[d] = !dq[d]; continue }
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
        if (w[1] != "" && w[1] !~ /^[A-Za-z_][A-Za-z0-9_]*=/ && w[1] !~ /^[<>0-9=-]/ && w[1] !~ /^\[/ && w[1] != "X" && w[2] !~ /^[-+*\/%]$/ && w[1] !~ /[*?\]:|]/) print w[1]
      }
    }' | sort -u
}
allowed=" printf echo awk sed tr cut head wc grep cat command id uname date sort uniq read test shift exit return true false break continue umask unalias type set ls cd pwd loginctl timeout gsettings du systemd-detect-virt mkdir mktemp mv rm fi done esac then else elif do in while for if case until [ ]] "
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
    case "$_w" in systemctl|sysctl|echo|printf|return|field|to_mask|svc_pick|sysctl_args|sysctl_text|sysctl_dropin|journald_text|journald_dropin|journald_dir|journald_keys|put_file|mkdir|mktemp|mv|rm|rmdir|ls|fix_command|fix_change|'esac'|'fi'|'done'|'then'|'else'|'elif') ;; *) echo "command word in FIXES other than systemctl, sysctl, the file writer and helpers: $_w" ;; esac
  done
  printf '%s\n' "$_outside" | grep -vE '^[[:space:]]*#' | grep -nE "$mutating" | sed 's/^/mutating systemctl outside FIXES: /'
  printf '%s\n' "$_outside" | grep -vE '^[[:space:]]*#' | grep -nE '(^|[^A-Za-z_])sysctl[[:space:]]+-' | sed 's/^/sysctl outside FIXES: /'
  # per command, not per line: each command naming systemctl, loginctl, gsettings or timeout must be one of these reads
  printf '%s\n' "$_outside" | grep -vE '^[[:space:]]*#' | awk '{ sub(/[ \t]#.*$/, ""); n = split($0, a, /;|&&|[|][|]|[|]/); for (i = 1; i <= n; i++) if (a[i] ~ /systemctl|loginctl|gsettings|timeout/) print a[i] }' |
    grep -vE '^[^"]*("[$][(])?(systemctl is-(enabled|active) "[$]1" 2>/dev/null|command -v (systemctl|loginctl|timeout|gsettings) >/dev/null 2>&1|timeout 10 du -sk -- "[$]1" 2>/dev/null |timeout 5 loginctl show-session "[$]1" -p Remote -p Service 2>/dev/null|loginctl show-session "[$]1" -p Remote -p Service 2>/dev/null|(timeout 5 )?loginctl list-sessions --no-legend 2>/dev/null |(timeout 5 )?loginctl show-session "[$]1" -p Type 2>/dev/null|systemd-detect-virt -c -q 2>/dev/null|_gt=[$][(]gsettings get org[.]gnome[.]settings-daemon[.]plugins[.]power sleep-inactive-ac-type 2>/dev/null)' |
    sed 's/^/a command outside FIXES that is not an allowed read: /'
  # awk programs never write or pipe; sed scripts never write (w) or run (e) anything
  printf '%s\n' "$_outside$nl$_inside" | grep -vE '^[[:space:]]*#' | grep 'awk' | awk -F"'" '{ for (i = 2; i <= NF; i += 2) { p = $i; gsub(/"[^"]*"/, "", p); if (length($i) > 1 && p ~ /[>|]|system|getline/) { print "awk program writes, pipes or runs: " $0; next } } }'
  printf '%s\n' "$_outside$nl$_inside" | grep -vE '^[[:space:]]*#' | grep -E "sed[^|;]*(/[gpIiM0-9]*[we]([[:space:]};']|\$)|[;{][[:space:]]*[we][[:space:]]|'[0-9\$,]*[we][[:space:]])" | sed 's/^/sed write or execute: /'
  # (sudo is caught as a command word; messages may tell the owner to run the script with sudo themselves)
  # (sh and bash are forbidden command words, so sh -c is caught there; message text may name it)
  printf '%s\n' "$_outside$nl$_inside" | grep -vE '^[[:space:]]*#' | grep -nE 'sed[[:space:]]+(-[A-Za-z]*i|--in-place)|find[[:space:]]|system[[:space:]]*\(|getline|`' | sed 's/^/raw: /'
  printf '%s\n' "$_outside$nl$_inside" | grep -nE '(^|[^A-Za-z_])eval([^A-Za-z_]|$)' | sed 's/^/eval: /'
  # file changes: only the record's temp file, renamed over the record, and inside FIXES the drop-in writer (put_file)
  # and the removal of the two fixed drop-ins; the fix_command lines only print "rm FILE"
  printf '%s\n' "$_outside" | grep -vE '^[[:space:]]*#' | grep -E '(^|[^A-Za-z_])(rm|mv|mkdir|mktemp)[[:space:]]' | grep -vxF \
    -e '  mkdir -p -- "$_d" 2>/dev/null || { err "lanq-makeready-fix: cannot create $_d"; return 1; }' \
    -e '  _t=$(mktemp "$_d/.fix.XXXXXX" 2>/dev/null) || { err "lanq-makeready-fix: cannot write in $_d"; return 1; }' \
    -e '  if render_record > "$_t" && mv -f -- "$_t" "$REC_PATH"; then return 0; fi' \
    -e '  rm -f -- "$_t"' | sed 's/^/file change other than the record: /'
  printf '%s\n' "$_inside" | grep -vE '^[[:space:]]*#' | grep -E '(^|[^A-Za-z_])(rm|rmdir|mv|mkdir|mktemp)[[:space:]]' | grep -vxF \
    -e '    "sysctl.tune|undo") echo "rm $(sysctl_dropin)"; echo "sysctl -w $(sysctl_args "$3" undo)" ;;' \
    -e '      [ "$(field "$3" dir)" = absent ] && echo "mkdir -m 755 $(journald_dir)"' \
    -e '      echo "rm $(journald_dropin)"' \
    -e '      [ "$(field "$3" dir)" = absent ] && echo "rmdir $(journald_dir) when empty"' \
    -e '      if [ "$(field "$3" dir)" = absent ] && [ -z "$(ls -A -- "$(journald_dir)" 2>/dev/null)" ]; then rmdir -- "$(journald_dir)" || return 1; fi' \
    -e '  [ -d "$_pd" ] || mkdir -m 755 -- "$_pd" || return 1' \
    -e '  _pt=$(mktemp "$_pd/.lanq-makeready.XXXXXX") || return 1' \
    -e '  if printf '"'"'%s\n'"'"' "$2" > "$_pt" && mv -f -- "$_pt" "$1"; then return 0; fi' \
    -e '  rm -f -- "$_pt"' \
    -e '      rm -f -- "$(sysctl_dropin)" || _undo_rc=1' \
    -e '      rm -f -- "$(journald_dropin)" || return 1' | sed 's/^/file change in FIXES other than the drop-ins: /'
  # put_file writes only the two fixed drop-ins
  printf '%s\n' "$_inside" | grep -o 'put_file [^&;]*' | grep -vxF -e 'put_file "$(sysctl_dropin)" "$(sysctl_text "$3")" ' -e 'put_file "$(journald_dropin)" "$(journald_text "$3")" ' -e 'put_file() { ' | sed 's/^/put_file of another file: /'
  printf '%s\n' "$_outside$nl$_inside" | awk "$scan_awk"'
    /^[ \t]*#/ { next }
    { raw = $0
      gsub(/2>\/dev\/null|>\/dev\/null|<\/dev\/null|2>&1|>&2|> "\$_t"|> "\$_pt"|< "\$_f"/, "", raw)
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
mutant "L4: awk program writes a file" "bad16() { awk 'BEGIN { print 1 > \"/tmp/x\" }'; }"
mutant "L4: awk program pipes to a command" "bad17() { awk 'BEGIN { print \"id\" | \"sh\" }'; }"
mutant "L4: awk system()" "bad17b() { awk 'BEGIN { system(\"id\") }'; }"
mutant "L4: sed w (write a file)" "bad18() { sed 's/a/b/w /etc/x' /etc/y; }"
mutant "L4: sed e (run a command)" "bad19() { sed -n '1e id' /etc/y; }"
mutant "L4: a command word from a variable" 'bad20() { $1 arg; }'
mutant "L4: a command word from a quoted variable" 'bad21() { "$1" arg; }'
mutant "L4: systemctl allow-rule per command, not per line" 'bad22() { systemctl is-enabled "$1" 2>/dev/null; systemctl show x; }'
mutant "L4: loginctl other than show-session" 'bad23() { loginctl terminate-session 1; }'
mutant "L4: gsettings set" 'bad24() { gsettings set org.x y z; }'
mutant "L4: timeout running something else" 'bad25() { timeout 5 reboot; }'
mutant "tune: sysctl -w outside FIXES" 'bad26() { sysctl -w vm.swappiness=1; }'
mutant "tune: put_file outside FIXES" 'bad27() { _pt=$(mktemp "$_pd/.x.XXXXXX"); }'
mutant "tune: rm of a drop-in outside FIXES" 'bad28() { rm -f -- "$(sysctl_dropin)"; }'
mutant "tune: redirect into a drop-in" 'bad29() { echo x > "$(sysctl_dropin)"; }'
awk '/^# endregion FIXES$/ { print "bad_in() { put_file /etc/passwd x; }" } { print }' "$fix" > "$mut_dir/m.sh"
if [ -n "$(fix_guard "$mut_dir/m.sh")" ]; then ok "guard: put_file of another file inside FIXES is flagged"; else bad "guard put_file other" "not flagged" flagged; fi
awk '/^# endregion FIXES$/ { print "bad_in2() { rm -f -- /etc/shadow; }" } { print }' "$fix" > "$mut_dir/m.sh"
if [ -n "$(fix_guard "$mut_dir/m.sh")" ]; then ok "guard: rm of another file inside FIXES is flagged"; else bad "guard rm other" "not flagged" flagged; fi
awk '/^# endregion FIXES$/ { print "bad_in3() { rmdir -- /etc/systemd; }" } { print }' "$fix" > "$mut_dir/m.sh"
if [ -n "$(fix_guard "$mut_dir/m.sh")" ]; then ok "guard: rmdir of another folder inside FIXES is flagged"; else bad "guard rmdir other" "not flagged" flagged; fi
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
o=$(LANQ_MAKEREADY_FIX_LIB=1 sh -c "$(cat "$fix")" "$fix" --dry-run </dev/null 2>&1); eq "$?" 3 "L3: RefusesFromStdin (real process, sh -c with \$0 set to the real path): exit 3"
rdir=${TMPDIR:-/tmp}/lanq-fixren.$$; mkdir -p "$rdir"; cp "$fix" "$rdir/fix-copy.sh"
o=$(LANQ_MAKEREADY_FIX_LIB=1 sh "$rdir/fix-copy.sh" --dry-run </dev/null 2>&1); eq "$?" 3 "L3: a renamed copy is refused (real process): exit 3"; rm -rf "$rdir"
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
user_rec_dir() { echo "$RECDIR"; }
root_rec_dir() { echo "$RECDIR"; }
record_trusted() { [ -z "${FAKE_UNTRUSTED:-}" ]; }
record_dir_problem() { if [ -n "${FAKE_DIRBAD:-}" ]; then echo "the record folder $RECDIR is not root's alone (test). Nothing was changed."; fi; return 0; }
sleep_risk() { echo "${FAKE_RISK:-sleeps}"; }
audit_session_id() { :; }
latest_record() { for _r in "$RECDIR"/fix-*.json; do [ -e "$_r" ] && _last=$_r; done; [ -n "${_last:-}" ] && echo "$_last"; _last=""; }
fake_systemctl() {
  case "$1" in
    is-enabled) echo "$2" >> "$FAKE/reads"; cat "$FAKE/u.$2.en" 2>/dev/null || return 1; [ "$(cat "$FAKE/u.$2.en")" != disabled ] ;;
    is-active) _fv=$(cat "$FAKE/u.$2.act" 2>/dev/null || echo inactive); echo "$_fv"; [ "$_fv" = active ] ;;
    *)
      echo "systemctl $*" >> "$FAKE/calls"
      _lr=$(latest_record); { if [ -n "$_lr" ]; then cat "$_lr"; fi; echo "----"; } >> "$FAKE/snaps"
      [ -f "$FAKE/failnext" ] && { rm -f "$FAKE/failnext"; return 1; }
      _fv=$1; shift; _fn=0; [ "${1:-}" = --now ] && { _fn=1; shift; }
      for _fx in "$@"; do
        case "$_fv" in
          enable) echo enabled > "$FAKE/u.$_fx.en"; if [ "$_fn" = 1 ]; then echo active > "$FAKE/u.$_fx.act"; fi ;;
          disable) echo disabled > "$FAKE/u.$_fx.en"; if [ "$_fn" = 1 ]; then echo inactive > "$FAKE/u.$_fx.act"; fi ;;
          stop) echo inactive > "$FAKE/u.$_fx.act" ;;
          start|restart) echo active > "$FAKE/u.$_fx.act" ;;
          mask) echo masked > "$FAKE/u.$_fx.en" ;;
          unmask) echo static > "$FAKE/u.$_fx.en" ;;
        esac
      done ;;
  esac
}
sysctl() { # the fake: -w KEY=VALUE writes the fake root's /proc/sys file
  echo "sysctl $*" >> "$FAKE/calls"
  _lr=$(latest_record); { if [ -n "$_lr" ]; then cat "$_lr"; fi; echo "----"; } >> "$FAKE/snaps"
  [ "$1" = -w ] || return 1; shift
  for _kv in "$@"; do printf '%s\n' "${_kv#*=}" > "$R/proc/sys/$(printf '%s' "${_kv%%=*}" | tr . /)"; done
}
lc_sessions() { cat "$FAKE/sessions" 2>/dev/null; }   # fake logind: one session id per line
lc_type() { cat "$FAKE/type.$1" 2>/dev/null; }
virt_container() { [ -e "$FAKE/virt" ]; }            # fake systemd-detect-virt -c
dir_kb() { case "$1" in */var/log/journal) cat "$FAKE/jkb" 2>/dev/null || echo 0 ;; */run/log/journal) cat "$FAKE/rkb" 2>/dev/null || echo 0 ;; *) echo 0 ;; esac; }
systemctl() { fake_systemctl "$@"; }
if [ "$(type systemctl 2>/dev/null | head -n 1 | grep -c function)" = 1 ]; then ok "systemctl is the fake"; else echo "ABORT: systemctl is not faked"; exit 1; fi
if [ "$(type sysctl 2>/dev/null | head -n 1 | grep -c function)" = 1 ]; then ok "sysctl is the fake"; else echo "ABORT: sysctl is not faked"; exit 1; fi
reset_fake() { # everything fine: ssh enabled and active, sleep targets masked
  rm -rf "$FAKE"; mkdir -p "$FAKE"; : > "$FAKE/calls"; : > "$FAKE/snaps"; : > "$FAKE/reads"
  echo enabled > "$FAKE/u.ssh.service.en"; echo active > "$FAKE/u.ssh.service.act"; echo inactive > "$FAKE/u.ssh.socket.act"
  for t in sleep suspend hibernate hybrid-sleep; do echo masked > "$FAKE/u.$t.target.en"; done
  FAKE_ROOT=1; FAKE_CONSOLE=1; FAKE_OS=Linux; ON_ANSWER=""; FAKE_RISK=sleeps; FAKE_UNTRUSTED=""; FAKE_DIRBAD=""
  R=$FAKE/root   # tune reads: a fake root where every tune check is fine (no unit files: no services)
  mkdir -p "$R/proc/sys/fs/inotify" "$R/etc/systemd" "$R/proc"; echo 8192 > "$R/proc/sys/fs/inotify/max_user_instances"; echo 524288 > "$R/proc/sys/fs/inotify/max_user_watches"
  printf '/dev/sda1 / ext4 rw,relatime 0 0\n' > "$R/proc/mounts"
}
setu() { echo "$2" > "$FAKE/u.$1"; } # setu ssh.service.en disabled
unmask_all() { for _t in sleep suspend hibernate hybrid-sleep; do setu $_t.target.en static; done; }
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
case_fix "power.sleep (hibernate already masked)" 'for t in sleep suspend hybrid-sleep; do setu $t.target.en static; done' \
  "systemctl mask sleep.target suspend.target hybrid-sleep.target" "systemctl unmask sleep.target suspend.target hybrid-sleep.target"
case_fix "power.sleep (hibernate masked until reboot)" 'for t in sleep suspend hybrid-sleep; do setu $t.target.en static; done; setu hibernate.target.en masked-runtime' \
  "systemctl mask sleep.target suspend.target hybrid-sleep.target" "systemctl unmask sleep.target suspend.target hybrid-sleep.target"
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
reset_fake; setu ssh.service.act activating; runfix '' --dry-run
contains "$OUT" "ssh.service is changing state" "C13: a unit that is activating: says so"
for m in sleep suspend; do
  reset_fake; unmask_all; setu $m.target.en masked; runfix '' --dry-run
  lacks "$OUT" "power.sleep  (" "C1: $m.target masked (the scanner says OK): power.sleep not offered"
done
reset_fake; unmask_all; FAKE_RISK=unmasked; runfix '' --dry-run
lacks "$OUT" "power.sleep  (" "C1: nothing found that would suspend (the scanner says OK): not offered"
reset_fake; unmask_all; FAKE_RISK=desktop; runfix '' --dry-run
contains "$OUT" "power.sleep  (" "C1: a desktop whose power settings cannot be read (the scanner WARNs): offered"

echo "DefaultIsNo"
for a in '\n' 'n\n' 'N\n' 'no\n' 'x\n' 'yes please\n' ''; do
  reset_fake; unmask_all
  runfix "$a"
  if [ "$RC" = 0 ] && [ -z "$(calls)" ] && [ -z "$(latest_record)" ]; then ok "DefaultIsNo: answer '$a' -> nothing changed, no record"; else bad "DefaultIsNo '$a'" "$RC $(calls)" "0, none"; fi
  contains "$OUT" "Apply? [y/N]" "DefaultIsNo: '$a' was asked"
done

echo "SkipsAdminItemsWhenNotElevated"
reset_fake; setu ssh.service.act inactive; unmask_all; FAKE_ROOT=0
runfix 'y\ny\n'
if [ "$RC" = 0 ] && [ -z "$(calls)" ] && [ -z "$(latest_record)" ]; then ok "SkipsAdminItemsWhenNotElevated: nothing changed"; else bad "not root" "$(calls)" none; fi
eq "$(printf '%s\n' "$OUT" | grep -c 'needs root')" 2 "SkipsAdminItemsWhenNotElevated: a note per fix"
lacks "$OUT" "Apply?" "not root: nothing asked"
contains "$OUT" "never elevates itself" "not root: says it never elevates itself"

echo "WhatIfChangesNothing"
reset_fake; setu ssh.service.en disabled; setu ssh.service.act inactive; unmask_all; FAKE_CONSOLE=0
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
reset_fake; unmask_all; ON_ANSWER='setu sleep.target.en masked'; runfix 'y\n'
if [ -z "$(calls)" ]; then ok "EachFixRechecksPreconditionFirst: power.sleep fixed meanwhile -> nothing done"; else bad "recheck power" "$(calls)" none; fi
reset_fake; unmask_all; ON_ANSWER='setu hibernate.target.en masked'; runfix 'y\n'
if [ -z "$(calls)" ]; then ok "state changed to another value after it was shown: nothing done"; else bad "recheck changed" "$(calls)" none; fi
contains "$OUT" "changed since it was shown" "recheck changed: says so"

echo "UndoInReverseOrder and UndoSkipsChangedSince"
reset_fake; setu ssh.service.en disabled; setu ssh.service.act inactive; unmask_all
start=$(states); runfix 'y\ny\n'; rec=$(latest_record)
eq "$(calls)" "systemctl enable --now ssh.service|systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target" "applied in list order"
runfix 'y\ny\n' --undo "$rec"
eq "$(calls)" "systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target|systemctl disable ssh.service|systemctl stop ssh.service" "UndoInReverseOrder: newest change first"
eq "$(states)" "$start" "UndoInReverseOrder: everything restored"
reset_fake; setu ssh.service.en disabled; setu ssh.service.act inactive; unmask_all
runfix 'y\ny\n'; rec=$(latest_record)
unmask_all
runfix 'y\ny\n' --undo "$rec"
contains "$OUT" "changed since; left alone" "UndoSkipsChangedSince: power.sleep unmasked by hand, left alone"
eq "$(calls)" "systemctl disable ssh.service|systemctl stop ssh.service" "UndoSkipsChangedSince: the other fix is still undone"
contains "$(cat "$rec")" '"id": "power.sleep", "status": "applied"' "UndoSkipsChangedSince: record keeps the skipped item as applied"
reset_fake; unmask_all; runfix 'y\n'; rec=$(latest_record)
runfix 'n\n' --undo "$rec"
if [ -z "$(calls)" ]; then ok "undo: default no leaves it"; else bad "undo no" "$(calls)" none; fi
ON_ANSWER='setu suspend.target.en static'; runfix 'y\n' --undo "$rec"
if [ -z "$(calls)" ]; then ok "undo: re-checks the state after the answer"; else bad "undo recheck" "$(calls)" none; fi
setu suspend.target.en masked; FAKE_ROOT=0; runfix 'y\n' --undo "$rec"
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && [ ! -s "$FAKE/reads" ]; then ok "C7/D5: undo when not root: exit 1, nothing read or changed"; else bad "undo not root" "$RC $(calls)" "1, none"; fi
contains "$OUT" "--undo needs root" "C7: undo when not root: says so first"
FAKE_ROOT=1; FAKE_UNTRUSTED=1; runfix 'y\n' --undo "$rec"
if [ "$RC" = 2 ] && [ -z "$(calls)" ] && [ ! -s "$FAKE/reads" ]; then ok "L6: a record others could have written is refused as root"; else bad "L6 untrusted record" "$RC $(calls)" "2, none"; fi
contains "$OUT" "not owned by root, or writable by group or others" "L6: says why"
FAKE_UNTRUSTED=""

echo "C5 pending items"
reset_fake; unmask_all; runfix 'y\n'; rec=$(latest_record)
sed 's/"status": "applied"/"status": "pending"/' "$rec" > "$rec.x" && mv "$rec.x" "$rec"
unmask_all   # the crash happened before the change
runfix 'y\n' --undo "$rec"
if [ "$RC" = 0 ] && [ -z "$(calls)" ]; then ok "C5: pending and still as before: nothing run"; else bad "C5 never applied" "$RC $(calls)" "0, none"; fi
contains "$OUT" "never applied" "C5: says never applied"; contains "$(cat "$rec")" '"status": "skipped"' "C5: marked skipped"
sed 's/"status": "skipped"/"status": "pending"/' "$rec" > "$rec.x" && mv "$rec.x" "$rec"
for t in sleep suspend hibernate hybrid-sleep; do setu $t.target.en masked; done   # the crash happened after the change
runfix 'y\n' --undo "$rec"
eq "$(calls)" "systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target" "C5: pending and changed as predicted: undone"
contains "$(cat "$rec")" '"status": "undone"' "C5: marked undone"

echo "C8 --list shows both places"
reset_fake; unmask_all; runfix 'y\n'
user_rec_dir() { echo "$FAKE/user"; }
runfix '' --list
contains "$OUT" "No undo records in $FAKE/user" "C8: this user's folder (none there)"; contains "$OUT" "power.sleep applied" "C8: and root's folder"
mkdir -p "$FAKE/user"; chmod 000 "$FAKE/user" 2>/dev/null
if [ ! -r "$FAKE/user" ]; then runfix '' --list; contains "$OUT" "cannot be read without root" "C8: a folder it cannot read: says so"; fi
chmod 700 "$FAKE/user" 2>/dev/null
user_rec_dir() { echo "$RECDIR"; }
FAKE_UNTRUSTED=1; runfix '' --list
contains "$OUT" "not trusted (only root-owned records in $RECDIR are used" "D3: --list marks a record --undo would refuse"
FAKE_UNTRUSTED=""

echo "R6 records only from the root record folder; D1 an unsafe folder stops the run before any question"
for l in 'drwx------ 2 0 0 4096 Nov 13 10:00 d' 'drwx------+ 2 0 0 4096 Nov 13 10:00 d'; do
  if dir_perm_ok "$l"; then ok "D1 dir_perm_ok: $l"; else bad "D1 dir_perm_ok: $l" refused ok; fi
done
for l in 'drwxr-xr-x 2 0 0 4096 Nov 13 10:00 d' 'drwx------ 2 1000 0 4096 Nov 13 10:00 d' '-rw------- 1 0 0 1 Nov 13 10:00 f' 'lrwxrwxrwx 1 0 0 1 Nov 13 10:00 l'; do
  if dir_perm_ok "$l"; then bad "D1 dir_perm_ok refuses: $l" ok refused; else ok "D1 dir_perm_ok refuses: $l"; fi
done
reset_fake; mkdir -p "$RECDIR" "$FAKE/other"; : > "$RECDIR/fix-20990101T000000Z.json"; : > "$FAKE/other/fix-20990101T000000Z.json"; : > "$RECDIR/notes.json"
if record_in_place "$RECDIR/fix-20990101T000000Z.json"; then ok "R6: a fix-<time>.json in the root record folder"; else bad "R6 in place" refused ok; fi
if (cd "$RECDIR" && record_in_place fix-20990101T000000Z.json); then ok "R6: the same, given as a relative path"; else bad "R6 relative" refused ok; fi
if record_in_place "$FAKE/other/fix-20990101T000000Z.json"; then bad "R6 other folder" ok refused; else ok "R6: a record in another folder is refused"; fi
if record_in_place "$RECDIR/notes.json"; then bad "R6 other name" ok refused; else ok "R6: another file name is refused"; fi
if record_in_place "$RECDIR/../rec/fix-20990101T000000Z.json"; then ok "R6: .. in the path is resolved"; else bad "R6 dotdot" refused ok; fi
runfix 'y\n' --undo "$FAKE/other/fix-20990101T000000Z.json"
if [ "$RC" = 2 ] && [ -z "$(calls)" ]; then ok "R6: --undo of a record outside the folder: exit 2"; else bad "R6 undo outside" "$RC" 2; fi
contains "$OUT" "reads only the records this script writes" "R6: says why"
reset_fake; unmask_all; FAKE_DIRBAD=1; runfix 'y\n'
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && [ -z "$(latest_record)" ]; then ok "D1: an unsafe record folder: exit 1, nothing changed"; else bad "D1 unsafe folder" "$RC $(calls)" "1, none"; fi
lacks "$OUT" "Apply?" "D1: stopped before the first question"; contains "$OUT" "not root's alone" "D1: says why"

echo "R7 notes where the scanner's view and this script's could differ"
reset_fake; unmask_all; FAKE_RISK=desktop; runfix '' --dry-run
contains "$OUT" "cannot be read from here (a root shell has no session bus)" "R7(a): a desktop whose power setting cannot be read: the prompt says so"
reset_fake; setu ssh.service.en masked; setu ssh.service.act inactive; runfix '' --dry-run
contains "$OUT" "ssh.service is masked; this script only enables a unit that is enabled or disabled" "R7(b): a masked ssh unit: a note says why it is not offered"
reset_fake; setu ssh.service.en masked; setu ssh.service.act inactive; setu ssh.socket.act active; runfix '' --dry-run
lacks "$OUT" "ssh.service is masked" "R7(b): a masked ssh.service with an active ssh.socket (the scanner says OK): no note"
reset_fake; rm -f "$FAKE/u.ssh.service.en"; setu sshd.service.en static; setu sshd.service.act inactive; runfix '' --dry-run
contains "$OUT" "sshd.service is static" "R7(b): a static sshd unit: a note"

echo "a failed change is recorded"
reset_fake; unmask_all; : > "$FAKE/failnext"; runfix 'y\n'
eq "$RC" 1 "failed change: exit 1"; contains "$(cat "$(latest_record)")" '"status": "failed"' "failed change: item failed"

echo "refusals (in process: the driver seam cannot skip SSH or stdin)"
for m in "" --dry-run --list "--undo /nonexistent.json"; do
  reset_fake; unmask_all
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
  reset_fake; unmask_all; FAKE_CONSOLE=0
  # shellcheck disable=SC2086
  runfix 'y\n' $m
  if [ "$RC" = 3 ] && [ -z "$(calls)" ] && [ ! -s "$FAKE/reads" ]; then ok "RefusesWithoutConsole (${m:-apply}): exit 3"; else bad "RefusesWithoutConsole ${m:-apply}" "$RC" 3; fi
done
reset_fake; FAKE_CONSOLE=0; runfix '' --list; eq "$RC" 0 "--list needs no console"; contains "$OUT" "No undo records" "--list: none yet"
reset_fake; FAKE_OS=Darwin; runfix '' --dry-run; eq "$RC" 0 "macOS: exit 0"; contains "$OUT" "no fixes for macOS" "macOS: no fixes"

echo "TamperedRecordRejected"
reset_fake; setu ssh.service.en disabled; setu ssh.service.act inactive; unmask_all
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


echo "tune fixes (--tune; a fake systemctl, a fake sysctl and a fake root only)"
eq "$(grep -cxF "$(grep '^is_num() ' "$fix")" "$root/lanq-makeready-tune.sh")" 1 "tune: is_num is the tune scan's, unchanged"
for fn in inotify_finding journald_limits journal_finding svc_offer trim_disks; do
  a=$(awk -v f="$fn() {" 'index($0, f) == 1 { p = 1 } p { print } p && /^}/ { exit }' "$root/lanq-makeready-tune.sh")
  b=$(awk -v f="$fn() {" 'index($0, f) == 1 { p = 1 } p { print } p && /^}/ { exit }' "$fix")
  if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "tune: $fn is the tune scan's, unchanged"; else bad "tune: $fn copy" differs same; fi
done
for s in 'sysctl.tune|file=absent instances=128 watches=8192' 'sysctl.tune|file=lanq instances=1024 watches=524288' 'journald.cap|file=absent dir=absent sys=none run=none' 'journald.cap|file=lanq dir=present sys=own run=none' \
  'services.unused|svc=cups service=enabled:active socket=enabled:active path=none:inactive' 'services.unused|svc=modemmanager service=disabled:active' \
  'services.unused|svc=cups-browsed service=enabled:inactive' 'fstrim.timer|enabled=disabled active=inactive'; do
  if valid_state "${s%%|*}" "${s#*|}"; then ok "tune state accepted: $s"; else bad "tune state accepted: $s" rejected accepted; fi
done
for s in 'sysctl.tune|file=other instances=128 watches=8192' 'sysctl.tune|file=absent instances=x watches=8192' 'sysctl.tune|file=absent instances=128' \
  'journald.cap|file=other dir=present sys=none run=none' 'journald.cap|file=absent' 'journald.cap|file=absent dir=absent sys=1G run=none' 'services.unused|svc=sshd service=enabled:active' 'services.unused|svc=cups service=enabled:active' \
  'services.unused|svc=cups-browsed service=masked:inactive' 'services.unused|svc=cups-browsed socket=enabled:active' 'services.unused|svc=Bluetooth service=enabled:active' \
  'services.unused|svc=avahi service=enabled:active' 'services.unused|svc=bluetooth service=enabled:active;reboot' 'fstrim.timer|enabled=static active=inactive'; do
  if valid_state "${s%%|*}" "${s#*|}"; then bad "tune state rejected: $s" accepted rejected; else ok "tune state rejected: $s"; fi
done
eq "$(SVC_KNOWN="cups"; if svc_known bluetooth; then echo y; else echo n; fi)" n "svc_known: only the append-only list"
if (SVC_KNOWN="Cups cups"; svc_known Cups); then bad "svc_known name shape" accepted rejected; else ok "svc_known: the name shape is checked too"; fi
eq "$(sysctl_args 'file=absent instances=128 watches=8192' apply)" "fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=524288" "sysctl_args: raise both"
eq "$(sysctl_args 'file=absent instances=128 watches=8192' undo)" "fs.inotify.max_user_instances=128 fs.inotify.max_user_watches=8192" "sysctl_args: undo puts both back"
eq "$(sysctl_args 'file=absent instances=2048 watches=8192' apply)" "fs.inotify.max_user_watches=524288" "sysctl_args: never lowers a value"
eq "$(svc_pick 'svc=cups service=enabled:active socket=disabled:active path=none:inactive' on)" "cups.service cups.socket" "svc_pick: units to disable --now"
eq "$(svc_pick 'svc=cups service=enabled:active socket=disabled:active path=none:inactive' enabled)" "cups.service" "svc_pick: units to re-enable"
tstates() { for _k in $TUNE_KEYS; do printf '%s / ' "$(state_of "$_k")"; done; }
ssd() { mkdir -p "$R/sys/block/sda/queue"; echo 0 > "$R/sys/block/sda/queue/rotational"; echo "${1:-2147450880}" > "$R/sys/block/sda/queue/discard_max_bytes"; }
case_tune() { # name, setup, expected apply calls, expected undo calls, check after apply (eval)
  reset_fake; eval "$2"
  start=$(tstates)
  runfix 'y\n' --tune
  eq "$RC" 0 "$1 apply: exit 0"
  eq "$(calls)" "$3" "$1 apply: exact commands"
  contains "$(cat "$FAKE/snaps")" '"status": "pending"' "RecordWrittenBeforeChange: $1"
  rec=$(latest_record)
  contains "$(cat "$rec")" '"status": "applied"' "$1 record: applied"
  contains "$OUT" "applied and verified" "$1 apply: verified"
  [ -z "${5:-}" ] || eval "$5"
  runfix 'y\n' --undo "$rec"
  eq "$RC" 0 "$1 undo: exit 0"
  eq "$(calls)" "$4" "UndoRestoresEachFix: $1 exact undo commands"
  eq "$(tstates)" "$start" "UndoRestoresEachFix: $1 state back to the start"
  contains "$(cat "$rec")" '"status": "undone"' "$1 record: undone"
}
case_tune "sysctl.tune (instances 128, watches 8192)" 'echo 128 > "$R/proc/sys/fs/inotify/max_user_instances"; echo 8192 > "$R/proc/sys/fs/inotify/max_user_watches"' \
  "sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=524288" "sysctl -w fs.inotify.max_user_instances=128 fs.inotify.max_user_watches=8192" \
  'eq "$(cat "$(sysctl_dropin)")" "$SYSCTL_MARK${nl}fs.inotify.max_user_instances = 1024${nl}fs.inotify.max_user_watches = 524288" "sysctl.tune: the drop-in holds the raised limits"; contains "$(cat "$rec")" "\"before\": \"file=absent instances=128 watches=8192\"" "sysctl.tune: the record has the old values and that the file was absent"'
eq "$([ -e "$(sysctl_dropin)" ] && echo left || echo removed)" removed "sysctl.tune undo: the drop-in is removed"
case_tune "sysctl.tune (watches only)" 'echo 8192 > "$R/proc/sys/fs/inotify/max_user_watches"' \
  "sysctl -w fs.inotify.max_user_watches=524288" "sysctl -w fs.inotify.max_user_watches=8192"
case_tune "journald.cap (2 GB journal)" 'echo 2000000 > "$FAKE/jkb"' "systemctl restart systemd-journald.service" "systemctl restart systemd-journald.service" \
  'contains "$(cat "$(journald_dropin)")" "SystemMaxUse=1G" "journald.cap: the drop-in caps the journal"; contains "$OUT" "the deleted logs cannot be restored" "journald.cap: the prompt says trimmed logs cannot be restored"; eq "$(ls -ld "$(journald_dir)" | cut -c1-10)" drwxr-xr-x "L2: journald.conf.d created with mode 755"; contains "$(cat "$rec")" "\"before\": \"file=absent dir=absent sys=none run=none\"" "L2: the record says the folder was absent"'
eq "$([ -d "$(journald_dir)" ] && echo left || echo removed)" removed "L2: undo removes the empty journald.conf.d it created"
case_tune "journald.cap (volatile journal in /run)" 'echo 300000 > "$FAKE/rkb"' "systemctl restart systemd-journald.service" "systemctl restart systemd-journald.service"
case_tune "M1 journald.cap (SystemMaxUse set by hand, a big /run journal)" 'echo 300000 > "$FAKE/rkb"; mkdir -p "$(journald_dir)"; printf "[Journal]\nSystemMaxUse=3G\n" > "$(journald_dir)/10-admin.conf"' \
  "systemctl restart systemd-journald.service" "systemctl restart systemd-journald.service" \
  'eq "$(sed 1d "$(journald_dropin)")" "[Journal]${nl}RuntimeMaxUse=256M" "M1: only the unset key is written; the admin cap is kept"; contains "$OUT" "write $(journald_dropin): RuntimeMaxUse=256M" "M1: the command names only that key"; lacks "$OUT" "mkdir -m 755" "M1: the folder existed: no mkdir"'
eq "$(cat "$(journald_dir)/10-admin.conf" 2>/dev/null | sed -n 2p)" "SystemMaxUse=3G" "M1: undo leaves the admin's drop-in and folder alone"
reset_fake; echo 2000000 > "$FAKE/jkb"; echo 300000 > "$FAKE/rkb"; printf '[Journal]\nSystemMaxUse=3G\nRuntimeMaxUse=100M\n' > "$R/etc/systemd/journald.conf"; runfix '' --tune --dry-run
lacks "$OUT" "journald.cap  (" "M1: both caps set by hand: never offered"
reset_fake; echo 2000000 > "$FAKE/jkb"; runfix 'y\n' --tune; rec=$(latest_record); : > "$(journald_dir)/50-other.conf"; runfix 'y\n' --undo "$rec"
contains "$OUT" "undone and verified" "L2: a folder something else put a file in stays, and undo still verifies"
eq "$([ -e "$(journald_dir)/50-other.conf" ] && echo kept)" kept "L2: the other file is kept"

echo "M2: desktop sessions, Bluetooth input devices, ModemManager"
reset_fake; for u in cups.service bluetooth.service; do setu $u.en enabled; setu $u.act active; done; echo 3 > "$FAKE/sessions"; echo Type=wayland > "$FAKE/type.3"; runfix '' --tune --dry-run
lacks "$OUT" "services.unused:cups  (" "M2: a wayland session (no display manager): cups not offered"; lacks "$OUT" "services.unused:bluetooth  (" "M2: a wayland session: bluetooth not offered"
reset_fake; setu cups.service.en enabled; setu cups.service.act active; printf '3\n4\n' > "$FAKE/sessions"; echo Type=tty > "$FAKE/type.3"; echo Type=x11 > "$FAKE/type.4"; runfix '' --tune --dry-run
lacks "$OUT" "services.unused:cups  (" "M2: an x11 session: cups not offered"
reset_fake; setu cups.service.en enabled; setu cups.service.act active; echo 3 > "$FAKE/sessions"; echo Type=tty > "$FAKE/type.3"; runfix '' --tune --dry-run
contains "$OUT" "services.unused:cups  (" "M2: only a tty session (headless): cups offered"
reset_fake; setu bluetooth.service.en enabled; setu bluetooth.service.act active; mkdir -p "$R/sys/bus/hid/devices/0005:046D:B342.0001"; runfix '' --tune --dry-run
lacks "$OUT" "services.unused:bluetooth  (check services.unused: bluetooth is enabled or running on a build box)${nl}" "M2: a Bluetooth HID device: bluetooth not offered"
contains "$OUT" "not offered: a Bluetooth keyboard, mouse or other input device is connected" "M2: a Bluetooth HID device: a note says why"
reset_fake; setu bluetooth.service.en enabled; setu bluetooth.service.act active; mkdir -p "$R/sys/bus/hid/devices/0003:046D:C52B.0002"; runfix '' --tune --dry-run
contains "$OUT" "services.unused:bluetooth  (" "M2: only a USB HID device: bluetooth offered"
reset_fake; setu ModemManager.service.en enabled; setu ModemManager.service.act active; runfix '' --tune --dry-run
contains "$OUT" "a mobile-broadband (cellular modem) connection on this machine drops" "M2: the ModemManager prompt warns about mobile broadband"

echo "L3: --tune refuses inside a container"
for c in .dockerenv run/.containerenv; do
  reset_fake; echo 128 > "$R/proc/sys/fs/inotify/max_user_instances"; mkdir -p "$R/run"; : > "$R/$c"; runfix 'y\n' --tune
  if [ "$RC" = 3 ] && [ -z "$(calls)" ]; then ok "L3: /$c: --tune refused, exit 3"; else bad "L3 /$c" "$RC $(calls)" "3, none"; fi
done
reset_fake; echo 128 > "$R/proc/sys/fs/inotify/max_user_instances"; mkdir -p "$R/run/systemd"; echo lxc > "$R/run/systemd/container"; runfix 'y\n' --tune --dry-run
eq "$RC" 3 "L3: /run/systemd/container (LXC, nspawn): refused"; contains "$OUT" "this is a container" "L3: says why"
reset_fake; echo 128 > "$R/proc/sys/fs/inotify/max_user_instances"; : > "$FAKE/virt"; runfix 'y\n' --tune --dry-run; eq "$RC" 3 "L3: systemd-detect-virt -c: refused"
reset_fake; : > "$R/.dockerenv"; unmask_all; runfix '' --dry-run; eq "$RC" 0 "L3: without --tune a container is not refused (the v1 fixes keep their rules)"

echo "L6: cups undo tolerates a path or socket unit starting cups.service"
eq "$(if undo_ok services.unused:cups 'svc=cups service=enabled:active socket=enabled:active path=enabled:active' 'svc=cups service=enabled:inactive socket=enabled:active path=enabled:active'; then echo ok; fi)" ok "L6: an extra active unit after undo is fine"
eq "$(if undo_ok services.unused:cups 'svc=cups service=enabled:inactive socket=enabled:active path=enabled:active' 'svc=cups service=enabled:active socket=enabled:active path=enabled:active'; then echo ok; else echo no; fi)" no "L6: a unit that was active and is not: failed"
eq "$(if undo_ok services.unused:cups 'svc=cups service=disabled:active socket=enabled:active path=enabled:active' 'svc=cups service=enabled:active socket=enabled:active path=enabled:active'; then echo ok; else echo no; fi)" no "L6: an enabled state not put back: failed"
reset_fake; setu cups.path.en enabled; setu cups.path.act active; setu cups.service.en enabled; setu cups.service.act inactive; runfix 'y\n' --tune; rec=$(latest_record)
systemctl() { # the fake, plus: starting cups.path starts cups.service as well (path activation)
  case "$1" in start) case " $* " in *" cups.path "*) echo active > "$FAKE/u.cups.service.act" ;; esac ;; esac
  fake_systemctl "$@"
}
runfix 'y\n' --undo "$rec"
contains "$OUT" "undone and verified" "L6: cups.path started cups.service on undo: still undone and verified"; eq "$RC" 0 "L6: exit 0"
systemctl() { fake_systemctl "$@"; }
case_tune "services.unused (cups-browsed)" 'setu cups-browsed.service.en enabled; setu cups-browsed.service.act active' \
  "systemctl disable --now cups-browsed.service" "systemctl enable cups-browsed.service|systemctl start cups-browsed.service"
case_tune "services.unused (cups: service and socket, no path unit)" 'setu cups.service.en enabled; setu cups.service.act active; setu cups.socket.en enabled; setu cups.socket.act active' \
  "systemctl disable --now cups.service cups.socket" "systemctl enable cups.service cups.socket|systemctl start cups.service cups.socket"
case_tune "services.unused (cups disabled but running)" 'setu cups.service.en disabled; setu cups.service.act active' "systemctl disable --now cups.service" "systemctl start cups.service"
case_tune "services.unused (bluetooth)" 'setu bluetooth.service.en enabled; setu bluetooth.service.act active' \
  "systemctl disable --now bluetooth.service" "systemctl enable bluetooth.service|systemctl start bluetooth.service"
case_tune "services.unused (ModemManager)" 'setu ModemManager.service.en enabled; setu ModemManager.service.act inactive' \
  "systemctl disable --now ModemManager.service" "systemctl enable ModemManager.service"
case_tune "fstrim.timer (SSD, timer disabled)" 'ssd; setu fstrim.timer.en disabled' "systemctl enable --now fstrim.timer" "systemctl disable fstrim.timer|systemctl stop fstrim.timer"
if grep -q 'mask' "$FAKE/calls" 2>/dev/null; then bad "services.unused never masks" masked none; else ok "services.unused never masks"; fi

echo "tune fixes: all at once, in order, undone newest first"
reset_fake; echo 128 > "$R/proc/sys/fs/inotify/max_user_instances"; echo 2000000 > "$FAKE/jkb"; ssd; setu fstrim.timer.en disabled
for u in cups-browsed.service cups.service bluetooth.service ModemManager.service; do setu $u.en enabled; setu $u.act active; done
start=$(tstates); runfix 'y\ny\ny\ny\ny\ny\ny\n' --tune; rec=$(latest_record)
eq "$(calls)" "sysctl -w fs.inotify.max_user_instances=1024|systemctl restart systemd-journald.service|systemctl disable --now cups-browsed.service|systemctl disable --now cups.service|systemctl disable --now bluetooth.service|systemctl disable --now ModemManager.service|systemctl enable --now fstrim.timer" "all tune fixes, cups-browsed before cups"
eq "$(grep -c '"status": "applied"' "$rec")" 7 "seven items applied"
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert len(d['items'])==7" "$rec" 2>/dev/null; then ok "tune record is valid JSON"; else bad "tune record JSON" invalid valid; fi
fi
runfix 'y\ny\ny\ny\ny\ny\ny\n' --undo "$rec"
eq "$(calls)" "systemctl disable fstrim.timer|systemctl stop fstrim.timer|systemctl enable ModemManager.service|systemctl start ModemManager.service|systemctl enable bluetooth.service|systemctl start bluetooth.service|systemctl enable cups.service|systemctl start cups.service|systemctl enable cups-browsed.service|systemctl start cups-browsed.service|systemctl restart systemd-journald.service|sysctl -w fs.inotify.max_user_instances=128" "undo: newest first"
eq "$(tstates)" "$start" "undo: every tune fix put back"

echo "tune fixes: only what the tune scan reports"
reset_fake; runfix '' --tune --dry-run
contains "$OUT" "Nothing to fix" "all fine: nothing offered"
reset_fake; echo 128 > "$R/proc/sys/fs/inotify/max_user_instances"; setu cups.service.en enabled; runfix '' --dry-run
lacks "$OUT" "sysctl.tune" "without --tune: no tune fix is offered"; lacks "$OUT" "services.unused" "without --tune: no services fix"
reset_fake; setu display-manager.service.act active; for u in cups-browsed.service cups.service bluetooth.service ModemManager.service; do setu $u.en enabled; setu $u.act active; done; runfix '' --tune --dry-run
contains "$OUT" "services.unused:cups-browsed  (" "a desktop: cups-browsed is still offered (it listens on the network)"
lacks "$OUT" "services.unused:cups  (" "a desktop: cups is not offered"; lacks "$OUT" "services.unused:bluetooth" "a desktop: bluetooth is not offered"
reset_fake; setu avahi-daemon.service.en enabled; setu avahi-daemon.service.act active; runfix '' --tune --dry-run
lacks "$OUT" "avahi" "avahi-daemon is never offered (report only: host.local names)"
reset_fake; setu bluetooth.service.en static; setu bluetooth.service.act active; runfix '' --tune --dry-run
contains "$OUT" "services.unused:bluetooth  (check services.unused: bluetooth is enabled or running on a build box): not offered: a unit is in a state" "a static unit that runs: a note, not a fix"
reset_fake; setu bluetooth.service.en masked; runfix '' --tune --dry-run
lacks "$OUT" "services.unused:bluetooth  (" "a masked, stopped unit: nothing to say"
reset_fake; echo 128 > "$R/proc/sys/fs/inotify/max_user_instances"; mkdir -p "$R/etc/sysctl.d"; echo 'fs.inotify.max_user_instances = 256' > "$(sysctl_dropin)"; runfix '' --tune --dry-run
contains "$OUT" "exists already" "sysctl.tune: an existing drop-in is never overwritten (a note)"
reset_fake; echo 2000000 > "$FAKE/jkb"; mkdir -p "$R/etc/systemd"; printf '[Journal]\nSystemMaxUse=500M\n' > "$R/etc/systemd/journald.conf"; runfix '' --tune --dry-run
lacks "$OUT" "journald.cap  (" "journald.cap: a cap set by hand: not offered"
reset_fake; echo 500000 > "$FAKE/jkb"; runfix '' --tune --dry-run
lacks "$OUT" "journald.cap  (" "journald.cap: a journal under 1 GB: not offered"
reset_fake; ssd; setu fstrim.timer.en disabled; printf '/dev/sda1 / ext4 rw,discard 0 0\n' > "$R/proc/mounts"; runfix '' --tune --dry-run
lacks "$OUT" "fstrim.timer  (" "fstrim.timer: / mounted with discard: not offered"
reset_fake; ssd 0; setu fstrim.timer.en disabled; runfix '' --tune --dry-run
lacks "$OUT" "fstrim.timer  (" "fstrim.timer: no TRIM support: not offered"
reset_fake; mkdir -p "$R/sys/block/sdb/queue"; echo 1 > "$R/sys/block/sdb/queue/rotational"; echo 0 > "$R/sys/block/sdb/queue/discard_max_bytes"; setu fstrim.timer.en disabled; runfix '' --tune --dry-run
lacks "$OUT" "fstrim.timer  (" "fstrim.timer: an HDD only: not offered"
reset_fake; echo 2000000 > "$FAKE/jkb"; FAKE_CONSOLE=0; runfix 'y\n' --tune --dry-run
contains "$OUT" "the deleted logs cannot be restored" "journald.cap: the dry run shows the loss warning too"
eq "$(calls)" "" "tune dry run: nothing changed"
reset_fake; runfix '' --tune --undo "$RECDIR/fix-20990101T000000Z.json"; eq "$RC" 2 "--tune with --undo: exit 2"
reset_fake; runfix '' --tune --list; eq "$RC" 2 "--tune with --list: exit 2"
reset_fake; echo 128 > "$R/proc/sys/fs/inotify/max_user_instances"; FAKE_ROOT=0; runfix 'y\n' --tune
if [ -z "$(calls)" ] && [ -z "$(latest_record)" ]; then ok "tune: not root: nothing changed"; else bad "tune not root" "$(calls)" none; fi
contains "$OUT" "sudo sh lanq-makeready-fix.sh --tune" "tune: not root: says to run it with --tune and sudo"

echo "tune fixes: undo checks the state and the record"
reset_fake; echo 128 > "$R/proc/sys/fs/inotify/max_user_instances"; runfix 'y\n' --tune; rec=$(latest_record)
echo '# edited by hand' > "$(sysctl_dropin)"; runfix 'y\n' --undo "$rec"
contains "$OUT" "changed since; left alone" "sysctl.tune: a drop-in edited since: left alone"; eq "$(calls)" "" "sysctl.tune: nothing run"
reset_fake; setu cups-browsed.service.en enabled; setu cups-browsed.service.act active; runfix 'y\n' --tune; rec=$(latest_record); cp "$rec" "$FAKE/good.json"
setu cups-browsed.service.act active; runfix 'y\n' --undo "$rec"
contains "$OUT" "changed since; left alone" "services.unused: started again by hand: left alone"
cp "$FAKE/good.json" "$rec"; setu cups-browsed.service.act inactive
tamper "unknown service name" 's/svc=cups-browsed /svc=sshd /g'
tamper "service units that do not match the fixed table" 's/svc=cups-browsed service=/svc=cups-browsed socket=/g'
tamper "service name with a command" 's/svc=cups-browsed /svc=cups-browsed;reboot /'
tamper "unknown tune fix id" 's/"id": "services.unused"/"id": "services.all"/'
reset_fake; echo 2000000 > "$FAKE/jkb"; runfix 'y\n' --tune; rec=$(latest_record)
sed 's/"status": "applied"/"status": "pending"/' "$rec" > "$rec.x" && mv "$rec.x" "$rec"; rm -f "$(journald_dropin)"; rmdir "$(journald_dir)"
runfix 'y\n' --undo "$rec"
if [ -z "$(calls)" ]; then ok "journald.cap: pending and never applied: nothing run"; else bad "journald pending" "$(calls)" none; fi
contains "$(cat "$rec")" '"status": "skipped"' "journald.cap: pending, never applied: marked skipped"
rm -rf "$FAKE"

echo "ScannerUnchangedAndStillReadOnly"
scan="$root/lanq-makeready.sh"
eq "$(grep -c 'region FIXES\|lanq-makeready-fix' "$scan")" 0 "scanner has no fix table and does not call the fix script"
eq "$(grep -c "^TOOL_VERSION=$TOOL_VERSION\$" "$scan")" 1 "scanner and fix script report the same version"
eq "$(awk '/^# BEGIN ADVICE$/ {s=1} !s {print} /^# END ADVICE$/ {s=0}' "$scan" | grep -v '^[[:space:]]*#' | grep -cE "$mutating")" 0 "scanner (outside its advice table) has no mutating systemctl"
contains "$(grep -n 'usage: lanq-makeready.sh' "$scan")" "[--json PATH|-] [--out FILE] [--redact] [--hours HH:MM-HH:MM] [--quiet]" "scanner arguments unchanged (no fix flag)"
for f in lanq-makeready.sh lanq-makeready-fix.sh lanq-makeready-tune.sh tests/run.sh tests/fix.sh tests/tune.sh lanq-makeready.ps1 lanq-makeready-fix.ps1 tests/run.ps1 tests/fix.ps1 schema/fix-record.v1.json; do
  if LC_ALL=C grep -q "$(printf '[\001-\010\013\014\016-\037\177]')" "$root/$f"; then bad "$f has no control bytes" found none; else ok "$f has no control bytes"; fi
done
contains "$(cat "$root/schema/fix-record.v1.json")" '"const": "lanq-makeready-fix/v1"' "schema/fix-record.v1.json carries the schema id"

echo
echo "fix sh tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
