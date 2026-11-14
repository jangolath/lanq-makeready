#!/bin/sh
# lanq-makeready-fix: applies a short list of reversible fixes for what lanq-makeready reports, one at a time, each only
# after you confirm it at this machine. Linux with systemd only; on macOS it says so and changes nothing.
# lanq-makeready-fix-marker (identifies this file; the script refuses to run when it was not started from a file)
#
# The scanner (lanq-makeready.sh) never changes anything. This separate script changes only what you confirm:
#  - it refuses to run over SSH, from stdin (sh -s, a pipe) or without an interactive console (--dry-run and --list
#    need no console);
#  - there is no --yes: each fix is shown (check, current state, exact command, undo) and asked with "Apply? [y/N]";
#    anything but y or yes is no;
#  - it never elevates itself: without root every fix is skipped with a note;
#  - before each change it writes the undo record (schema lanq-makeready-fix/v1) to
#    /var/lib/lanq-makeready/fix-<UTC time>.json (root only, folder 0700; every fix needs root, so records are only
#    ever written there), and --undo FILE puts the changes back, newest first, again confirming each. --undo reads
#    only records in that folder; --list also lists ${XDG_STATE_HOME:-~/.local/state}/lanq-makeready/.
# Fixes (v1): ssh.start (enable and start the ssh/sshd unit), power.sleep (mask the four sleep targets).
#
# Usage: sh lanq-makeready-fix.sh [--dry-run | --undo FILE | --list]
# Exit:  0 = done or nothing to do, 1 = a change failed or did not verify, 2 = bad arguments or a rejected record,
#        3 = refused (over SSH, from stdin, no interactive console).

TOOL_VERSION=0.5.0
RECORD_SCHEMA=lanq-makeready-fix/v1
FIX_IDS="ssh.start power.sleep"
SLEEP_KEYS="sleep suspend hibernate hybrid-sleep"
FIX_SELF=$0
USAGE="usage: sh lanq-makeready-fix.sh [--dry-run | --undo FILE | --list]   (no --yes: every change is confirmed one by one)"
LOAD_ERR=""
REC_PATH=""; REC_VERSION=""; REC_HOST=""; REC_USER=""; REC_STARTED=""; REC_ITEMS=""

out() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# ---------- local only (test seams: has_console, confirm) ----------
# Tests and the disposable-machine CI driver source this file (LANQ_MAKEREADY_FIX_LIB=1 plus a function named
# __lanq_makeready_fix_test_harness) and replace has_console/confirm. That needs code already running in this shell,
# which could change the machine directly anyway, so the seam widens nothing. A direct run with
# LANQ_MAKEREADY_FIX_LIB=1 still applies every refusal and then exits 2. main checks SSH and stdin itself.

audit_session_id() { cat "/proc/$$/sessionid" 2>/dev/null; }
session_props() { # $1 logind session id -> "Remote=..." and "Service=..." lines (nothing without loginctl)
  command -v loginctl >/dev/null 2>&1 || return 0
  if command -v timeout >/dev/null 2>&1; then timeout 5 loginctl show-session "$1" -p Remote -p Service 2>/dev/null
  else loginctl show-session "$1" -p Remote -p Service 2>/dev/null; fi
}
# The login session this process belongs to survives sudo, su and tmux/screen; logind knows whether it came over SSH.
# No session id or no loginctl (containers, CI): this check says nothing and the others decide.
logind_remote() {
  _sid=$(audit_session_id)
  case "$_sid" in ''|*[!0-9]*|4294967295) return 1 ;; esac
  case "$(session_props "$_sid")" in *Remote=yes*|*Service=sshd*) return 0 ;; esac
  return 1
}
over_ssh() {
  [ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ] && return 0
  logind_remote && return 0
  # a root shell started from an SSH session may have lost the variables: look for sshd among the parent processes too
  _p=$$; _i=0
  while [ "$_i" -lt 32 ] && [ "$_p" -gt 1 ]; do
    [ -r "/proc/$_p/status" ] || break
    case "$(sed -n 's/^Name:[[:space:]]*//p' "/proc/$_p/status" 2>/dev/null)" in sshd*|dropbear*) return 0 ;; esac
    _q=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$_p/status" 2>/dev/null)
    case "$_q" in ''|*[!0-9]*) break ;; esac
    [ "$_q" = "$_p" ] && break
    _p=$_q; _i=$((_i + 1))
  done
  return 1
}
# Linux: the shell's own command line has -c or -s before the script (dash does not show c in $-).
started_with_c_or_s() {
  [ -r "/proc/$$/cmdline" ] || return 1
  cat "/proc/$$/cmdline" | tr '\000' '\n' | awk 'NR == 1 { next } $0 == "--" { exit } /^-[A-Za-z]*[cs][A-Za-z]*$/ { f = 1; exit } /^-/ { next } { exit } END { exit !f }'
}
# Started from this file: not sh -c or sh -s (a pipe), $0 is lanq-makeready-fix.sh and holds the marker line.
from_file() {
  case "$-" in *c*|*s*) return 1 ;; esac
  started_with_c_or_s && return 1
  [ "${FIX_SELF##*/}" = lanq-makeready-fix.sh ] && [ -f "$FIX_SELF" ] && grep -q 'lanq-makeready-fix-marker' "$FIX_SELF" 2>/dev/null
}
has_console() { [ -t 0 ]; }
is_root() { [ "$(id -u 2>/dev/null)" = 0 ]; }
fx_os() { uname -s 2>/dev/null; }
have_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
is_yes() { case "$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' \t\r')" in y|yes) return 0 ;; *) return 1 ;; esac; }
confirm() {
  printf '  Apply? [y/N] '
  _ans=""; read -r _ans || _ans=""
  is_yes "$_ans"
}

refusal() { # $1 = mode; prints the reason and returns 0 when the script must not run
  if over_ssh; then echo "refused: this session runs over SSH (SSH_CONNECTION, SSH_CLIENT or SSH_TTY is set, logind says the login session is remote, or sshd started it). Fix mode is for the owner at the machine itself. Nothing was changed."; return 0; fi
  if ! from_file; then echo "refused: the script came from stdin or a string (sh -s, sh -c, a pipe), or the file is not named lanq-makeready-fix.sh. Save it as lanq-makeready-fix.sh, read it, and run that file at the machine. Nothing was changed."; return 0; fi
  case "$1" in
    apply|undo) if ! has_console; then echo "refused: no interactive console (stdin is not a terminal). Every change needs your answer at the keyboard; --dry-run and --list work without one. Nothing was changed."; return 0; fi ;;
  esac
  return 1
}

# ---------- state (reads only) ----------

unit_enabled() { _v=$(systemctl is-enabled "$1" 2>/dev/null | head -n 1); [ -n "$_v" ] || _v=none; printf '%s' "$_v"; }
unit_active() {
  case "$(systemctl is-active "$1" 2>/dev/null | head -n 1)" in active) echo active ;; inactive|failed) echo inactive ;; *) echo other ;; esac
}
ssh_unit() { for _u in ssh sshd; do case "$(unit_enabled "$_u.service")" in enabled|disabled) echo "$_u"; return 0 ;; esac; done; return 1; }

# A state text has a fixed shape per fix id; anything else is refused (and never offered or undone).
valid_state() { # $1 id, $2 text
  case "$2" in *[!a-z0-9=\ .-]*|'') return 1 ;; esac
  case "$1" in
    ssh.start) printf '%s\n' "$2" | grep -qxE 'unit=(ssh|sshd) enabled=(enabled|disabled) active=(active|inactive)' ;;
    power.sleep) printf '%s\n' "$2" | grep -qxE 'sleep=[a-z-]{1,20} suspend=[a-z-]{1,20} hibernate=[a-z-]{1,20} hybrid-sleep=[a-z-]{1,20}' ;;
    *) return 1 ;;
  esac
}
state_of() { # $1 id -> state text, empty when it cannot be recorded
  case "$1" in
    ssh.start) _u=$(ssh_unit) || return 0; _t="unit=$_u enabled=$(unit_enabled "$_u.service") active=$(unit_active "$_u.service")" ;;
    power.sleep) _t="sleep=$(unit_enabled sleep.target) suspend=$(unit_enabled suspend.target) hibernate=$(unit_enabled hibernate.target) hybrid-sleep=$(unit_enabled hybrid-sleep.target)" ;;
    *) return 0 ;;
  esac
  if valid_state "$1" "$_t"; then printf '%s' "$_t"; fi
}
field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
# $1 power.sleep state -> the targets this fix would mask. A target masked only until the next boot (masked-runtime)
# is left alone: masking it as well would make undo unable to put back exactly what was there.
to_mask() {
  _m=""; for _k in $SLEEP_KEYS; do case "$(field "$1" "$_k")" in masked|masked-runtime) ;; *) _m="$_m $_k.target" ;; esac; done
  printf '%s' "${_m# }"
}

# The scanner's sleep logic (lanq-makeready.sh: logind_values, logind_auto_suspend, classify_sleep), copied unchanged
# so that power.sleep is offered only when the scanner would WARN; tests/fix.sh checks that the copies match.
logind_values() { # logind.conf text (main file, then drop-ins) on stdin -> "IdleAction HandleLidSwitch HandleLidSwitchExternalPower", "-" when unset; the last value wins
  awk '/^[ \t]*[#;]/ { next } { gsub(/[ \t]/, "") } /^IdleAction=/ { i = substr($0, 12) } /^HandleLidSwitch=/ { l = substr($0, 17) } /^HandleLidSwitchExternalPower=/ { e = substr($0, 30) } END { print (i == "" ? "-" : i) " " (l == "" ? "-" : l) " " (e == "" ? "-" : e) }'
}

classify_sleep() { # $1 logind finding, $2 GNOME sleep-inactive-ac-type ("" = not read), $3 display manager active, $4 session bus (yes|no) -> "state|detail"
  if [ -n "$1" ]; then echo "sleeps|$1"; return 0; fi
  if [ "$4" = yes ] && [ -n "$2" ]; then
    case "$2" in *nothing*) echo "unmasked|logind idle and lid, this user's GNOME setting" ;; *) echo "sleeps|GNOME idle action $2 on AC (this user)" ;; esac
    return 0
  fi
  if [ "$3" = yes ]; then echo "desktop|"; return 0; fi
  echo "unmasked|logind idle and lid"
}

logind_auto_suspend() { # $1 idle $2 lid $3 lid-on-AC $4 laptop(yes|no) -> what would suspend this PC, empty = nothing found
  case "$1" in suspend|hibernate|hybrid-sleep|suspend-then-hibernate|sleep) echo "logind IdleAction=$1"; return 0 ;; esac
  [ "$4" = yes ] || return 0
  _la=$3; [ "$_la" = - ] && _la=$2
  case "$_la" in
    -) echo "laptop lid: HandleLidSwitch default (suspend)" ;;
    suspend|hibernate|hybrid-sleep|suspend-then-hibernate|sleep) echo "laptop lid: HandleLidSwitch=$_la" ;;
  esac
  return 0
}
# end of the copied scanner functions

sleep_risk() { # what the scanner concludes when the sleep targets are not masked: sleeps | desktop | unmasked
  _lap=no; for _x in /proc/acpi/button/lid/*; do [ -e "$_x" ] && _lap=yes; done
  _lv=$(for _x in /etc/systemd/logind.conf /usr/lib/systemd/logind.conf.d/*.conf /run/systemd/logind.conf.d/*.conf /etc/systemd/logind.conf.d/*.conf; do [ -r "$_x" ] && cat "$_x"; done | logind_values)
  # shellcheck disable=SC2086
  _ld=$(logind_auto_suspend $_lv "$_lap")
  _gt=""; _bus=no; _dm=no
  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then _bus=yes; fi
  if [ -z "$_ld" ] && [ "$_bus" = yes ] && command -v gsettings >/dev/null 2>&1; then _gt=$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null); fi
  if [ -z "$_ld" ] && [ -z "$_gt" ] && [ "$(unit_active display-manager.service)" = active ]; then _dm=yes; fi
  _cs=$(classify_sleep "$_ld" "$_gt" "$_dm" "$_bus")
  echo "${_cs%%|*}"
}

needed() { # $1 id, $2 state
  case "$1" in
    ssh.start) [ "$(field "$2" active)" = inactive ] || return 1
      [ "$(unit_active "$(field "$2" unit).socket")" = active ] && return 1   # socket-activated: the scanner says OK
      return 0 ;;
    power.sleep) # like the scanner: sleep.target or suspend.target masked is OK; otherwise only when it finds a way to sleep
      [ "$(field "$2" sleep)" = masked ] && return 1
      [ "$(field "$2" suspend)" = masked ] && return 1
      [ -n "$(to_mask "$2")" ] || return 1
      case "$(sleep_risk)" in sleeps|desktop) return 0 ;; esac
      return 1 ;;
    *) return 1 ;;
  esac
}
note_of() { # $1 id -> why a fix the scanner would report is not offered (empty: nothing to say)
  case "$1" in
    ssh.start)
      if ! _u=$(ssh_unit); then
        for _u in ssh sshd; do
          case "$(unit_enabled "$_u.service")" in
            none|not-found|alias) ;;
            *) [ "$(unit_active "$_u.socket")" = active ] && return 0   # socket-activated: the scanner says OK
               [ "$(unit_active "$_u.service")" = active ] || echo "$_u.service is $(unit_enabled "$_u.service"); this script only enables a unit that is enabled or disabled, so change it yourself if you want it (unmask or enable the unit)"; return 0 ;;
          esac
        done
        return 0
      fi
      [ "$(unit_active "$_u.service")" = other ] && echo "$_u.service is changing state (activating or deactivating); run this script again in a moment" ;;
  esac
  return 0
}
done_ok() { # $1 id, $2 state after the change
  case "$1" in
    ssh.start) [ "$(field "$2" enabled)" = enabled ] && [ "$(field "$2" active)" = active ] ;;
    power.sleep) [ -z "$(to_mask "$2")" ] ;;
    *) return 1 ;;
  esac
}
expected_after() {
  case "$1" in
    ssh.start) echo "unit=$(field "$2" unit) enabled=enabled active=active" ;;
    power.sleep) echo "sleep=masked suspend=masked hibernate=masked hybrid-sleep=masked" ;;
  esac
}
check_of() { case "$1" in ssh.start) echo "ssh.server: sshd is installed but not running" ;; power.sleep) echo "power.sleep: the sleep targets are not all masked, so the machine may suspend mid-job" ;; esac; }
summary() {
  case "$1" in
    ssh.start) echo "$(field "$2" unit).service is $(field "$2" active), $(field "$2" enabled) at boot" ;;
    power.sleep) echo "$2" ;;
  esac
}

# region FIXES
# The ONE place that changes this machine, keyed by fix id. fix_command prints the exact commands shown and recorded;
# fix_change runs them. $3 is the before state (fresh, or from a validated record). Unit and target names come only
# from fixed lists (ssh|sshd, the four sleep targets); nothing in a record is ever run as code.
fix_command() { # $1 id, $2 apply|undo, $3 before
  case "$1|$2" in
    "ssh.start|apply") echo "systemctl enable --now $(field "$3" unit).service" ;;
    "ssh.start|undo")
      [ "$(field "$3" enabled)" = disabled ] && echo "systemctl disable $(field "$3" unit).service"
      [ "$(field "$3" active)" = inactive ] && echo "systemctl stop $(field "$3" unit).service" ;;
    "power.sleep|apply") echo "systemctl mask $(to_mask "$3")" ;;
    "power.sleep|undo") echo "systemctl unmask $(to_mask "$3")" ;;
  esac
  return 0
}
# shellcheck disable=SC2046 # the target list is words from a fixed list, split on purpose
fix_change() { # $1 id, $2 apply|undo, $3 before
  case "$1|$2" in
    "ssh.start|apply") systemctl enable --now "$(field "$3" unit).service" </dev/null ;;
    "ssh.start|undo")
      _undo_rc=0
      if [ "$(field "$3" enabled)" = disabled ]; then systemctl disable "$(field "$3" unit).service" </dev/null || _undo_rc=1; fi
      if [ "$(field "$3" active)" = inactive ]; then systemctl stop "$(field "$3" unit).service" </dev/null || _undo_rc=1; fi
      return "$_undo_rc" ;;
    "power.sleep|apply") systemctl mask $(to_mask "$3") </dev/null ;;
    "power.sleep|undo") systemctl unmask $(to_mask "$3") </dev/null ;;
    *) return 1 ;;
  esac
}
# endregion FIXES

# ---------- undo record (the only file this script writes) ----------

user_rec_dir() {
  _b=${XDG_STATE_HOME:-}
  case "$_b" in /*) ;; *) _b=${HOME:-/nonexistent}/.local/state ;; esac
  echo "$_b/lanq-makeready"
}
root_rec_dir() { echo /var/lib/lanq-makeready; }
rec_dir() { if is_root; then root_rec_dir; else user_rec_dir; fi; }
# An `ls -ldn` line: owned by uid 0 and not writable by group or others.
perm_ok() {
  # shellcheck disable=SC2086
  set -- $1
  [ "${3:-}" = 0 ] || return 1
  case "$1" in ?????w*|????????w*) return 1 ;; esac
  return 0
}
# An `ls -ldn` line of the record folder as this script makes it: a directory, mode 0700, owned by uid 0.
dir_perm_ok() {
  # shellcheck disable=SC2086
  set -- $1
  [ "${3:-}" = 0 ] || return 1
  case "$1" in drwx------*) return 0 ;; esac
  return 1
}
# '' when the root record folder is missing (it is created at the first change) or root's alone; checked before the
# first question, so an unsafe folder stops the run before anything is asked or changed.
record_dir_problem() {
  _rdir=$(root_rec_dir)
  { [ -e "$_rdir" ] || [ -L "$_rdir" ]; } || return 0
  if [ -L "$_rdir" ] || ! dir_perm_ok "$(ls -ldn -- "$_rdir" 2>/dev/null)"; then
    echo "the record folder $_rdir is not root's alone (a link, not owned by root, or not mode 0700). Nothing was changed. Look at what is in it, then rename it (for example to $_rdir.untrusted) or make it root's with mode 700 (chown root:root, chmod 700), and run this script again."
  fi
  return 0
}
# --undo reads only fix-<time>.json files directly in the root record folder (both paths resolved, links followed).
record_in_place() {
  case "${1##*/}" in fix-[0-9]*T[0-9]*Z.json|fix-[0-9]*T[0-9]*Z-[0-9]*.json) ;; *) return 1 ;; esac
  case "$1" in */*) _pd=${1%/*}; [ -n "$_pd" ] || _pd=/ ;; *) _pd=. ;; esac
  _pd=$(cd -P -- "$_pd" 2>/dev/null && pwd -P) || return 1
  _rd=$(cd -P -- "$(root_rec_dir)" 2>/dev/null && pwd -P) || return 1
  [ "$_pd" = "$_rd" ]
}
# As root, a record is used only if it and its folder are root's alone (not links, owned by root, no group/other write).
record_trusted() {
  _rf=$1; case "$_rf" in */*) _rd=${_rf%/*}; [ -n "$_rd" ] || _rd=/ ;; *) _rd=. ;; esac
  for _x in "$_rf" "$_rd"; do
    [ -L "$_x" ] && return 1
    perm_ok "$(ls -ldn -- "$_x" 2>/dev/null)" || return 1
  done
  return 0
}
safe_word() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64; }
item_count() { printf '%s\n' "$REC_ITEMS" | grep -c '^[0-9]'; }

new_record() {
  _d=$(rec_dir); _b=fix-$(date -u +%Y%m%dT%H%M%SZ)
  REC_PATH=$_d/$_b.json; _n=2
  while [ -e "$REC_PATH" ]; do REC_PATH=$_d/$_b-$_n.json; _n=$((_n + 1)); done
  REC_VERSION=$TOOL_VERSION; REC_HOST=$(safe_word "$(uname -n 2>/dev/null)"); REC_USER=$(safe_word "$(id -un 2>/dev/null)")
  REC_STARTED=$(now_utc); REC_ITEMS=""
}

# Fixed layout, one item per line, pure ASCII; load_record accepts exactly this layout and nothing else.
render_record() {
  printf '{\n  "schema": "%s",\n  "tool": {"name": "lanq-makeready-fix", "version": "%s"},\n  "os": "linux",\n' "$RECORD_SCHEMA" "$REC_VERSION"
  printf '  "host": "%s",\n  "user": "%s",\n  "started": "%s",\n  "items": [\n' "$REC_HOST" "$REC_USER" "$REC_STARTED"
  _n=$(item_count)
  printf '%s\n' "$REC_ITEMS" | grep '^[0-9]' | awk -F'|' -v n="$_n" '{ printf "    {\"seq\": %s, \"id\": \"%s\", \"status\": \"%s\", \"time\": \"%s\", \"before\": \"%s\", \"command\": \"%s\", \"after\": \"%s\"}%s\n", $1, $2, $3, $4, $5, $6, $7, (NR < n ? "," : "") }'
  printf '  ]\n}\n'
}

# Written to a temp file in the same folder (umask 077), then moved over the record: a crash leaves a whole record.
save_record() {
  _d=${REC_PATH%/*}
  if [ -L "$_d" ]; then err "lanq-makeready-fix: $_d is a symlink; not writing the record there"; return 1; fi
  mkdir -p -- "$_d" 2>/dev/null || { err "lanq-makeready-fix: cannot create $_d"; return 1; }
  _why=$(record_dir_problem); if [ -n "$_why" ]; then err "lanq-makeready-fix: $_why"; return 1; fi
  _t=$(mktemp "$_d/.fix.XXXXXX" 2>/dev/null) || { err "lanq-makeready-fix: cannot write in $_d"; return 1; }
  if render_record > "$_t" && mv -f -- "$_t" "$REC_PATH"; then return 0; fi
  rm -f -- "$_t"
  err "lanq-makeready-fix: could not write the record $REC_PATH"
  return 1
}

set_item() { # seq status time after
  REC_ITEMS=$(printf '%s\n' "$REC_ITEMS" | grep '^[0-9]' | awk -F'|' -v s="$1" -v st="$2" -v t="$3" -v a="$4" 'BEGIN { OFS = "|" } $1 == s { $3 = st; $4 = t; $7 = a } { print }')
}

# Reads and validates a record into REC_*; on failure LOAD_ERR says why. Every line must have its fixed shape.
load_record() {
  _f=$1; LOAD_ERR=""
  if [ ! -f "$_f" ] || [ -L "$_f" ]; then LOAD_ERR="no such file (or a symlink)"; return 1; fi
  _sz=$(wc -c < "$_f" | tr -d ' ')
  if [ "$_sz" -gt 65536 ]; then LOAD_ERR="larger than 64 KB"; return 1; fi
  if LC_ALL=C grep -q '[^ -~]' "$_f" || [ "$(tr -d '\r\t' < "$_f" | wc -c | tr -d ' ')" != "$_sz" ]; then LOAD_ERR="not plain ASCII"; return 1; fi
  _n=$(wc -l < "$_f" | tr -d ' ')
  if [ "$_n" -lt 10 ] || [ "$_n" -gt 74 ]; then LOAD_ERR="unexpected number of lines"; return 1; fi
  _T='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
  _S='[a-z0-9 .=-]{1,200}'
  _I='    \{"seq": [1-9][0-9]{0,2}, "id": "(ssh\.start|power\.sleep)", "status": "(pending|applied|failed|undone|skipped)", "time": "'$_T'", "before": "'$_S'", "command": "[A-Za-z0-9 ._/;-]{0,255}", "after": "'$_S'"\}'
  _ln=0
  while IFS= read -r _l; do
    _ln=$((_ln + 1))
    case "$_ln" in
      1) _re='\{' ;;
      2) _re='  "schema": "lanq-makeready-fix/v1",' ;;
      3) _re='  "tool": \{"name": "lanq-makeready-fix", "version": "[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}"\},' ;;
      4) _re='  "os": "linux",' ;;
      5) _re='  "host": "[A-Za-z0-9._-]{0,64}",' ;;
      6) _re='  "user": "[A-Za-z0-9._-]{0,64}",' ;;
      7) _re='  "started": "'$_T'",' ;;
      8) _re='  "items": \[' ;;
      *) if [ "$_ln" -eq "$_n" ]; then _re='\}'; elif [ "$_ln" -eq $((_n - 1)) ]; then _re='  \]'; elif [ "$_ln" -eq $((_n - 2)) ]; then _re=$_I; else _re="$_I,"; fi ;;
    esac
    if ! printf '%s\n' "$_l" | grep -qxE "$_re"; then LOAD_ERR="line $_ln has an unexpected shape"; return 1; fi
  done < "$_f"
  if [ "$_ln" -ne "$_n" ]; then LOAD_ERR="unexpected end of file"; return 1; fi
  REC_PATH=$_f
  REC_VERSION=$(sed -n '3s/.*"version": "\([0-9.]*\)".*/\1/p' "$_f")
  REC_HOST=$(sed -n '5s/^  "host": "\(.*\)",$/\1/p' "$_f")
  REC_USER=$(sed -n '6s/^  "user": "\(.*\)",$/\1/p' "$_f")
  REC_STARTED=$(sed -n '7s/^  "started": "\(.*\)",$/\1/p' "$_f")
  REC_ITEMS=$(sed -n 's/^    {"seq": \([0-9]*\), "id": "\([a-z.]*\)", "status": "\([a-z]*\)", "time": "\([^"]*\)", "before": "\([^"]*\)", "command": "\([^"]*\)", "after": "\([^"]*\)"},*$/\1|\2|\3|\4|\5|\6|\7/p' "$_f")
  if [ -n "$(printf '%s\n' "$REC_ITEMS" | grep '^[0-9]' | cut -d'|' -f1 | sort | uniq -d)" ]; then LOAD_ERR="repeated seq"; return 1; fi
  for _s in $(printf '%s\n' "$REC_ITEMS" | grep '^[0-9]' | cut -d'|' -f1); do
    _line=$(printf '%s\n' "$REC_ITEMS" | grep "^$_s|")
    _id=$(printf '%s' "$_line" | cut -d'|' -f2); _b=$(printf '%s' "$_line" | cut -d'|' -f5); _a=$(printf '%s' "$_line" | cut -d'|' -f7)
    valid_state "$_id" "$_b" || { LOAD_ERR="before state of $_id has an unexpected shape"; return 1; }
    [ "$_a" = unknown ] || valid_state "$_id" "$_a" || { LOAD_ERR="after state of $_id has an unexpected shape"; return 1; }
  done
  return 0
}

# ---------- modes ----------

show_fix() { # id state
  out ""
  out "$1  (check $(check_of "$1"))"
  out "  now:     $(summary "$1" "$2")"
  if [ "$1" = power.sleep ] && [ "$(sleep_risk)" = desktop ]; then
    out "  note:    a desktop is running and its own power setting (GNOME, per user) cannot be read from here (a root shell has no session bus), so this cannot tell whether it really sleeps; masking is harmless if it does not"
  fi
  fix_command "$1" apply "$2" | while IFS= read -r _c; do out "  command: $_c"; done
  fix_command "$1" undo "$2" | while IFS= read -r _c; do out "  undo:    $_c"; done
}

do_apply() { # $1 = 1 for a dry run
  _dry=$1; _failed=0; _shown=0; REC_PATH=""
  _root=no; if is_root; then _root=yes; fi
  if [ "$_dry" = 1 ]; then out "lanq-makeready-fix $TOOL_VERSION dry run: shows each applicable fix and its undo; nothing is changed"
  else out "lanq-makeready-fix $TOOL_VERSION: changes only what you confirm, one fix at a time (default no)"; fi
  if [ "$_root" = yes ] && [ "$_dry" != 1 ]; then _why=$(record_dir_problem); if [ -n "$_why" ]; then err "lanq-makeready-fix: $_why"; return 1; fi; fi
  for _id in $FIX_IDS; do
    _note=$(note_of "$_id")
    if [ -n "$_note" ]; then out ""; out "$_id  (check $(check_of "$_id")): not offered: $_note"; continue; fi
    _s=$(state_of "$_id")
    { [ -n "$_s" ] && needed "$_id" "$_s"; } || continue
    _shown=$((_shown + 1))
    show_fix "$_id" "$_s"
    if [ "$_root" = no ]; then out "  skipped: needs root (run it yourself with sudo at this machine); this script never elevates itself"; continue; fi
    if [ "$_dry" = 1 ]; then out "  dry run: not applied"; continue; fi
    if ! confirm; then out ""; out "  not applied"; continue; fi
    out ""
    _s2=$(state_of "$_id")   # the precondition, re-read just before the change
    if [ -z "$_s2" ] || ! needed "$_id" "$_s2"; then out "  no longer needed (the state changed); nothing done"; continue; fi
    if [ "$_s2" != "$_s" ]; then out "  the state changed since it was shown; nothing done (run the script again)"; continue; fi
    [ -n "$REC_PATH" ] || new_record
    _seq=$(($(item_count) + 1))
    _cmd=$(fix_command "$_id" apply "$_s2" | awk 'NR != 1 { printf " ; " } { printf "%s", $0 }')
    REC_ITEMS=$(printf '%s\n%s|%s|pending|%s|%s|%s|%s' "$REC_ITEMS" "$_seq" "$_id" "$(now_utc)" "$_s2" "$_cmd" "$(expected_after "$_id" "$_s2")" | grep '^[0-9]')
    if ! save_record; then err "  nothing changed: the undo record could not be written"; return 1; fi
    fix_change "$_id" apply "$_s2"; _rc=$?
    _s3=$(state_of "$_id"); [ -n "$_s3" ] || _s3=unknown
    if [ "$_rc" = 0 ] && [ "$_s3" != unknown ] && done_ok "$_id" "$_s3"; then set_item "$_seq" applied "$(now_utc)" "$_s3"; out "  applied and verified"
    else set_item "$_seq" failed "$(now_utc)" "$_s3"; _failed=$((_failed + 1)); out "  FAILED (exit $_rc; now: $_s3); recorded, so --undo can put back what changed"; fi
    save_record || _failed=$((_failed + 1))
  done
  if [ "$_shown" = 0 ]; then out "Nothing to fix here (fixes: $FIX_IDS)."
  elif [ "$_root" = no ]; then out ""; out "To apply, run it yourself with sudo at this machine: sudo sh lanq-makeready-fix.sh"; fi
  if [ -n "$REC_PATH" ]; then out ""; out "Undo record: $REC_PATH"; out "To undo:     sudo sh lanq-makeready-fix.sh --undo $REC_PATH"; fi
  [ "$_failed" = 0 ] || return 1
  return 0
}

do_undo() { # $1 record file
  if ! is_root; then
    out "lanq-makeready-fix $TOOL_VERSION: --undo needs root (run it yourself with sudo at this machine): every change it puts back needs it. This script never elevates itself. Nothing was changed."
    return 1
  fi
  if ! record_in_place "$1"; then err "lanq-makeready-fix: record rejected: --undo reads only the records this script writes, fix-<time>.json in $(root_rec_dir). Nothing was changed."; return 2; fi
  if [ -e "$1" ] && ! record_trusted "$1"; then err "lanq-makeready-fix: record rejected (it or its folder is a link, not owned by root, or writable by group or others, so someone else could have written it): $1. Nothing was changed."; return 2; fi
  if ! load_record "$1"; then err "lanq-makeready-fix: record rejected ($LOAD_ERR): $1. Nothing was changed."; return 2; fi
  _failed=0
  out "lanq-makeready-fix $TOOL_VERSION undo: $1 (newest change first; each needs your answer)"
  _todo=$(printf '%s\n' "$REC_ITEMS" | grep -E '^[0-9]+[|][a-z.]+[|](applied|failed|pending)[|]' | cut -d'|' -f1 | sort -nr)
  if [ -z "$_todo" ]; then out "Nothing to undo in this record."; return 0; fi
  for _s in $_todo; do
    _line=$(printf '%s\n' "$REC_ITEMS" | grep "^$_s|")
    _id=$(printf '%s' "$_line" | cut -d'|' -f2); _st=$(printf '%s' "$_line" | cut -d'|' -f3); _tm=$(printf '%s' "$_line" | cut -d'|' -f4)
    _b=$(printf '%s' "$_line" | cut -d'|' -f5); _a=$(printf '%s' "$_line" | cut -d'|' -f7)
    out ""
    out "undo $_id  (check $(check_of "$_id")), $_st at $_tm"
    _cur=$(state_of "$_id")
    out "  before the fix: $_b"
    out "  after the fix:  $_a"
    out "  now:            $_cur"
    if [ "$_st" = pending ] && [ -n "$_cur" ] && [ "$_cur" = "$_b" ]; then
      set_item "$_s" skipped "$(now_utc)" "$_a"
      if save_record; then out "  never applied (the record was written, the change was not made); marked skipped"; else _failed=$((_failed + 1)); fi
      continue
    fi
    fix_command "$_id" undo "$_b" | while IFS= read -r _c; do out "  command: $_c"; done
    if [ -z "$_cur" ] || [ "$_cur" != "$_a" ]; then out "  changed since; left alone"; continue; fi
    if ! confirm; then out ""; out "  left as it is"; continue; fi
    out ""
    if [ "$(state_of "$_id")" != "$_a" ]; then out "  changed since; left alone"; continue; fi
    fix_change "$_id" undo "$_b"; _rc=$?
    _now=$(state_of "$_id")
    if [ "$_rc" = 0 ] && [ "$_now" = "$_b" ]; then
      set_item "$_s" undone "$(now_utc)" "$_a"
      if save_record; then out "  undone and verified"; else _failed=$((_failed + 1)); fi
    else _failed=$((_failed + 1)); out "  FAILED (exit $_rc; now: $_now)"; fi
  done
  [ "$_failed" = 0 ] || return 1
  return 0
}

list_dir() { # $1 folder: one line per record in it
  if [ ! -e "$1" ]; then out "No undo records in $1"; return 0; fi
  if [ ! -r "$1" ] || [ ! -x "$1" ]; then out "$1: cannot be read without root (run --list with sudo to see it)"; return 0; fi
  _any=0
  for _f in "$1"/fix-*.json; do
    [ -e "$_f" ] || continue
    _any=1
    if ! record_in_place "$_f" || ! record_trusted "$_f"; then out "$_f: not trusted (only root-owned records in $(root_rec_dir) are used; --undo refuses this one)"; continue; fi
    if load_record "$_f"; then
      _its=$(printf '%s\n' "$REC_ITEMS" | grep '^[0-9]' | awk -F'|' '{ printf "%s%s %s", (NR == 1 ? "" : ", "), $2, $3 }')
      out "$_f: started $REC_STARTED on $REC_HOST: ${_its:-no changes}"
    else out "$_f: not a valid record ($LOAD_ERR)"; fi
  done
  [ "$_any" = 1 ] || out "No undo records in $1"
  return 0
}
do_list() { # both places: this user's records and root's
  list_dir "$(user_rec_dir)"
  [ "$(root_rec_dir)" = "$(user_rec_dir)" ] || list_dir "$(root_rec_dir)"
  return 0
}

# ---------- main ----------

main() {
  unalias -a 2>/dev/null   # an alias must never stand in for a command this script runs
  MODE=apply; UNDO_FILE=""; _modes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) MODE=dry; _modes=$((_modes + 1)) ;;
      --undo) if [ $# -lt 2 ] || [ -z "$2" ]; then err "lanq-makeready-fix: --undo needs a record file"; return 2; fi; MODE=undo; UNDO_FILE=$2; _modes=$((_modes + 1)); shift ;;
      --list) MODE=list; _modes=$((_modes + 1)) ;;
      -h|--help) out "$USAGE"; return 0 ;;
      *) err "lanq-makeready-fix: unknown argument: $1"; err "$USAGE"; return 2 ;;
    esac
    shift
  done
  if [ "$_modes" -gt 1 ]; then err "lanq-makeready-fix: use only one of --dry-run, --undo and --list"; return 2; fi
  if _why=$(refusal "$MODE"); then err "lanq-makeready-fix: $_why"; return 3; fi
  if [ "${LANQ_MAKEREADY_FIX_LIB:-}" = 1 ] && ! type __lanq_makeready_fix_test_harness >/dev/null 2>&1; then
    err "lanq-makeready-fix: LANQ_MAKEREADY_FIX_LIB=1 is only for the test runner (it must source this file); unset it."; return 2
  fi
  case "$(fx_os)" in
    Linux) ;;
    Darwin) out "lanq-makeready-fix: no fixes for macOS (nothing changed)"; return 0 ;;
    *) out "lanq-makeready-fix: no fixes for $(fx_os); this script is for Linux with systemd (nothing changed)"; return 0 ;;
  esac
  umask 077
  if [ "$MODE" = list ]; then do_list; return $?; fi
  if ! have_systemd; then out "lanq-makeready-fix: systemd is not running here, so no fix applies (nothing changed)"; return 0; fi
  case "$MODE" in
    undo) do_undo "$UNDO_FILE" ;;
    dry) do_apply 1 ;;
    *) do_apply 0 ;;
  esac
}

# LANQ_MAKEREADY_FIX_LIB=1 is for tests that source this file AND define __lanq_makeready_fix_test_harness first.
# shellcheck disable=SC2317
if [ "${LANQ_MAKEREADY_FIX_LIB:-}" = 1 ] && type __lanq_makeready_fix_test_harness >/dev/null 2>&1; then return 0 2>/dev/null || exit 0; fi
main "$@"
exit $?
