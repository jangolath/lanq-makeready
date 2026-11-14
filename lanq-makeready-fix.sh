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
# Tune fixes (--tune, for what lanq-makeready-tune.sh reports): sysctl.tune (raise the inotify limits:
# /etc/sysctl.d/99-zz-lanq-makeready.conf plus sysctl -w), journald.cap (a journald size cap drop-in; the trimmed logs
# cannot be restored), services.unused (systemctl disable --now cups, cups-browsed, bluetooth, ModemManager; never
# masks), fstrim.timer (enable the weekly TRIM timer). --undo puts any of them back.
#
# Usage: sh lanq-makeready-fix.sh [--tune] [--dry-run] | --undo FILE | --list
# Exit:  0 = done or nothing to do, 1 = a change failed or did not verify, 2 = bad arguments or a rejected record,
#        3 = refused (over SSH, from stdin, no interactive console; --tune inside a container).

TOOL_VERSION=0.5.0
RECORD_SCHEMA=lanq-makeready-fix/v1
FIX_IDS="ssh.start power.sleep"
# --tune: one key per prompt (services.unused:<service>); the record holds the id before the colon
TUNE_KEYS="sysctl.tune journald.cap services.unused:cups-browsed services.unused:cups services.unused:bluetooth services.unused:modemmanager fstrim.timer"
# APPEND-ONLY: every service name a record may ever hold. Undo accepts a name only when it is in this list, has the
# name shape and its units match the fixed table in svc_units; never remove a name (old records must stay undoable).
SVC_KNOWN="cups cups-browsed bluetooth modemmanager"
INOTIFY_INSTANCES=1024
INOTIFY_WATCHES=524288
SYSCTL_MARK="# lanq-makeready-fix sysctl.tune: remove it with lanq-makeready-fix.sh --undo"
JOURNALD_MARK="# lanq-makeready-fix journald.cap: remove it with lanq-makeready-fix.sh --undo"
R=""   # root prefix for /proc, /sys and /etc paths; tests point it at a fake root (never taken from the environment)
KEYS=$FIX_IDS
SLEEP_KEYS="sleep suspend hibernate hybrid-sleep"
FIX_SELF=$0
USAGE="usage: sh lanq-makeready-fix.sh [--tune] [--dry-run] | --undo FILE | --list   (no --yes: every change is confirmed one by one)"
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
  case "$2" in *[!a-z0-9=\ .:-]*|'') return 1 ;; esac
  case "$1" in
    ssh.start) printf '%s\n' "$2" | grep -qxE 'unit=(ssh|sshd) enabled=(enabled|disabled) active=(active|inactive)' ;;
    power.sleep) printf '%s\n' "$2" | grep -qxE 'sleep=[a-z-]{1,20} suspend=[a-z-]{1,20} hibernate=[a-z-]{1,20} hybrid-sleep=[a-z-]{1,20}' ;;
    sysctl.tune) printf '%s\n' "$2" | grep -qxE 'file=(absent|lanq) instances=[0-9]{1,10} watches=[0-9]{1,10}' ;;
    journald.cap) printf '%s\n' "$2" | grep -qxE 'file=(absent|lanq) dir=(absent|present) sys=(own|none) run=(own|none)' ;;
    services.unused) printf '%s\n' "$2" | grep -qxE 'svc=[a-z][a-z0-9-]{0,31}( (service|socket|path)=(enabled|disabled|none):(active|inactive)){1,3}' || return 1
      _sv=$(field "$2" svc); svc_known "$_sv" || return 1
      [ "$(printf '%s\n' "$2" | tr ' ' '\n' | sed -n '2,$s/=.*//p' | tr '\n' ' ')" = "$(for _u in $(svc_units "$_sv"); do printf '%s ' "${_u##*.}"; done)" ] ;;
    fstrim.timer) printf '%s\n' "$2" | grep -qxE 'enabled=(enabled|disabled) active=(active|inactive)' ;;
    *) return 1 ;;
  esac
}
state_of() { # $1 key (an id, or services.unused:<service>) -> state text, empty when it cannot be recorded
  case "$1" in
    ssh.start) _u=$(ssh_unit) || return 0; _t="unit=$_u enabled=$(unit_enabled "$_u.service") active=$(unit_active "$_u.service")" ;;
    power.sleep) _t="sleep=$(unit_enabled sleep.target) suspend=$(unit_enabled suspend.target) hibernate=$(unit_enabled hibernate.target) hybrid-sleep=$(unit_enabled hybrid-sleep.target)" ;;
    sysctl.tune) _t="file=$(dropin_state "$(sysctl_dropin)" "$SYSCTL_MARK") instances=$(proc_num fs/inotify/max_user_instances) watches=$(proc_num fs/inotify/max_user_watches)" ;;
    journald.cap) _t="file=$(dropin_state "$(journald_dropin)" "$JOURNALD_MARK") dir=$(if [ -d "$(journald_dir)" ]; then echo present; else echo absent; fi) $(journald_own)" ;;
    services.unused:*) _t=$(svc_state "${1#*:}") ;;
    fstrim.timer) _t="enabled=$(unit_enabled fstrim.timer) active=$(unit_active fstrim.timer)" ;;
    *) return 0 ;;
  esac
  if valid_state "${1%%:*}" "$_t"; then printf '%s' "$_t"; fi
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

# ---------- tune fixes: fixed names and reads ----------
# The tune scan's logic (lanq-makeready-tune.sh: is_num, inotify_finding, journald_limits, journal_finding, svc_offer,
# trim_disks), copied unchanged so that a tune fix is offered only for what the tune scan reports; tests/fix.sh checks
# that the copies match.
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
inotify_finding() { # $1 max_user_instances, $2 max_user_watches -> OK | WARN | INFO
  if [ "$1" -le 128 ]; then echo WARN; elif [ "$2" -lt 524288 ]; then echo INFO; else echo OK; fi
}
journald_limits() { # journald.conf text (main file, then drop-ins) on stdin -> "SystemMaxUse RuntimeMaxUse", "-" when unset; the last value wins
  awk '/^[ \t]*[#;]/ { next } { gsub(/[ \t]/, "") } /^SystemMaxUse=/ { s = substr($0, 14) } /^RuntimeMaxUse=/ { r = substr($0, 15) } END { print (s == "" ? "-" : s) " " (r == "" ? "-" : r) }'
}
journal_finding() { # $1 persistent KB, $2 volatile (/run, RAM) KB, $3 SystemMaxUse, $4 RuntimeMaxUse -> INFO when worth a cap, else OK
  if [ "$3" = - ] && [ "$1" -ge 1048576 ]; then echo INFO; return 0; fi
  if [ "$4" = - ] && [ "$2" -ge 262144 ]; then echo INFO; return 0; fi
  echo OK
}
svc_offer() { # $1 service key, $2 desktop running (yes|no), $3 Bluetooth input device (yes|no) -> fix | report | none
  case "$1" in
    cups-browsed) echo fix ;;
    bluetooth) if [ "$2" = yes ] || [ "$3" = yes ]; then echo none; else echo fix; fi ;;
    cups|modemmanager) if [ "$2" = yes ]; then echo none; else echo fix; fi ;;
    avahi) if [ "$2" = yes ]; then echo none; else echo report; fi ;;
    *) echo none ;;
  esac
}
trim_disks() { # non-rotational disks that accept discard (TRIM)
  for _q in "$R"/sys/block/*/queue/rotational; do
    [ -r "$_q" ] || continue
    _n=${_q%/queue/rotational}; _n=${_n##*/}
    case "$_n" in loop*|ram*|zram*|dm-*|sr*|nbd*|md*|fd*) continue ;; esac
    [ "$(head -n 1 "$_q")" = 0 ] || continue
    _dm=$(head -n 1 "${_q%/rotational}/discard_max_bytes" 2>/dev/null)
    is_num "$_dm" && [ "$_dm" -gt 0 ] && printf '%s ' "$_n"
  done
}
# end of the copied tune functions

sysctl_dropin() { echo "$R/etc/sysctl.d/99-zz-lanq-makeready.conf"; }
journald_dir() { echo "$R/etc/systemd/journald.conf.d"; }
journald_dropin() { echo "$(journald_dir)/99-zz-lanq-makeready.conf"; }
journald_confs() { # journald.conf and its drop-ins in the order journald reads them; $1 = skip this script's drop-in
  for _x in "$R"/etc/systemd/journald.conf "$R"/usr/lib/systemd/journald.conf.d/*.conf "$R"/run/systemd/journald.conf.d/*.conf "$R"/etc/systemd/journald.conf.d/*.conf; do
    [ "${1:-}" = own ] && [ "$_x" = "$(journald_dropin)" ] && continue
    [ -r "$_x" ] && cat "$_x"
  done
}
journald_own() { # "sys=own|none run=own|none": the caps set by the admin (this script's drop-in left out)
  _lim=$(journald_confs own | journald_limits)
  if [ "${_lim%% *}" = - ]; then printf 'sys=none '; else printf 'sys=own '; fi
  if [ "${_lim#* }" = - ]; then printf 'run=none'; else printf 'run=own'; fi
}
svc_units() { # the FIXED unit table: service key -> its units (never read from a record)
  case "$1" in
    cups) echo "cups.service cups.socket cups.path" ;;
    cups-browsed) echo cups-browsed.service ;;
    bluetooth) echo bluetooth.service ;;
    modemmanager) echo ModemManager.service ;;
  esac
}
svc_known() { # $1 service key: the name shape and the append-only list
  printf '%s\n' "$1" | grep -qxE '[a-z][a-z0-9-]{0,31}' || return 1
  case " $SVC_KNOWN " in *" $1 "*) return 0 ;; esac
  return 1
}
svc_state() { # $1 service key -> "svc=KEY service=en:act ..." (one word per unit, named by its type; none = no such unit)
  _st="svc=$1"
  for _u in $(svc_units "$1"); do
    _e=$(unit_enabled "$_u"); [ "$_e" = not-found ] && _e=none
    _st="$_st ${_u##*.}=$_e:$(unit_active "$_u")"
  done
  printf '%s' "$_st"
}
svc_pick() { # $1 services.unused state, $2 on|enabled|active -> the matching unit names from the fixed table
  _sv=$(field "$1" svc); _o=""
  for _u in $(svc_units "$_sv"); do
    case "$2:$(field "$1" "${_u##*.}")" in on:enabled:*|on:*:active|enabled:enabled:*|active:*:active) _o="$_o${_o:+ }$_u" ;; esac
  done
  printf '%s' "$_o"
}
any_on() { printf '%s\n' "$1" | tr ' ' '\n' | grep -qE '=enabled:|:active$'; }
lc_sessions() { # logind session ids (nothing without loginctl)
  command -v loginctl >/dev/null 2>&1 || return 0
  if command -v timeout >/dev/null 2>&1; then timeout 5 loginctl list-sessions --no-legend 2>/dev/null | awk '{ print $1 }'
  else loginctl list-sessions --no-legend 2>/dev/null | awk '{ print $1 }'; fi
}
lc_type() { # $1 session id -> "Type=..."
  case "$1" in ''|*[!A-Za-z0-9]*) return 0 ;; esac
  if command -v timeout >/dev/null 2>&1; then timeout 5 loginctl show-session "$1" -p Type 2>/dev/null
  else loginctl show-session "$1" -p Type 2>/dev/null; fi
}
# A desktop in use: a display manager, or a logind session of type x11 or wayland (the tune scan's rule)
desktop() {
  if [ "$(unit_active display-manager.service)" = active ]; then echo yes; return 0; fi
  for _sid in $(lc_sessions); do case "$(lc_type "$_sid")" in Type=x11|Type=wayland) echo yes; return 0 ;; esac; done
  echo no
}
bt_input() { for _h in "$R"/sys/bus/hid/devices/0005:*; do [ -e "$_h" ] && return 0; done; return 1; } # a Bluetooth keyboard, mouse or pad
bt_flag() { if bt_input; then echo yes; else echo no; fi; }
virt_container() { # systemd-detect-virt -c, bounded; WSL counts as a host here (as in the tune scan)
  command -v systemd-detect-virt >/dev/null 2>&1 || return 1
  if command -v timeout >/dev/null 2>&1; then _v=$(timeout 5 systemd-detect-virt -c 2>/dev/null </dev/null); else _v=$(systemd-detect-virt -c 2>/dev/null </dev/null); fi
  case "$_v" in ''|none|wsl) return 1 ;; *) return 0 ;; esac
}
fx_container() { # docker, podman, LXC, systemd-nspawn (the tune scan's rule)
  [ -e "$R/.dockerenv" ] || [ -e "$R/run/.containerenv" ] || [ -s "$R/run/systemd/container" ] && return 0
  grep -qE '(docker|lxc|kubepods|containerd|libpod)' "$R/proc/1/cgroup" 2>/dev/null && return 0
  virt_container
}
dropin_state() { # $1 file, $2 its first line when this script wrote it -> absent | lanq | other
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then echo absent
  elif [ -f "$1" ] && [ ! -L "$1" ] && [ "$(head -n 1 "$1" 2>/dev/null)" = "$2" ]; then echo lanq
  else echo other; fi
}
proc_num() { _v=$(head -n 1 "$R/proc/sys/$1" 2>/dev/null); if is_num "$_v"; then echo "$_v"; else echo x; fi; }
raise_to() { if [ "$1" -lt "$2" ]; then echo "$2"; else echo "$1"; fi; }
sysctl_args() { # $1 sysctl.tune before state, $2 apply|undo -> key=value words, only for the limits below the target
  _o=""
  for _k in instances watches; do
    _b=$(field "$1" "$_k"); _t=$INOTIFY_INSTANCES; [ "$_k" = watches ] && _t=$INOTIFY_WATCHES
    [ "$_b" -lt "$_t" ] || continue
    if [ "$2" = apply ]; then _o="$_o${_o:+ }fs.inotify.max_user_$_k=$_t"; else _o="$_o${_o:+ }fs.inotify.max_user_$_k=$_b"; fi
  done
  printf '%s' "$_o"
}
sysctl_text() { # $1 before state -> the drop-in text
  echo "$SYSCTL_MARK"
  for _a in $(sysctl_args "$1" apply); do echo "${_a%%=*} = ${_a#*=}"; done
}
journald_keys() { # $1 journald.cap before state -> the caps this fix writes: only those the admin has not set
  _o=""
  [ "$(field "$1" sys)" = none ] && _o="SystemMaxUse=1G"
  [ "$(field "$1" run)" = none ] && _o="$_o${_o:+ }RuntimeMaxUse=256M"
  printf '%s' "$_o"
}
journald_text() { # $1 before state
  printf '%s\n[Journal]\n' "$JOURNALD_MARK"
  for _k in $(journald_keys "$1"); do echo "$_k"; done
}
dir_kb() { # size of a folder in KB, bounded (0 when absent or unreadable)
  [ -d "$1" ] || { echo 0; return 0; }
  if command -v timeout >/dev/null 2>&1; then _k=$(timeout 10 du -sk -- "$1" 2>/dev/null | head -n 1); else _k=$(du -sk -- "$1" 2>/dev/null | head -n 1); fi
  _k=${_k%%[!0-9]*}; if is_num "$_k"; then echo "$_k"; else echo 0; fi
}
journal_need() { # true when the tune scan reports journald.size INFO
  _lim=$(journald_confs | journald_limits)
  [ "$(journal_finding "$(dir_kb "$R/var/log/journal")" "$(dir_kb "$R/run/log/journal")" "${_lim%% *}" "${_lim#* }")" = INFO ]
}
trim_need() { # an SSD that accepts TRIM, and / not mounted with discard (the tune scan's rule)
  [ -n "$(trim_disks)" ] || return 1
  ! awk '$2 == "/" { n = split($4, o, ","); for (i = 1; i <= n; i++) if (o[i] == "discard") f = 1 } END { exit !f }' "$R/proc/mounts" 2>/dev/null
}

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
    sysctl.tune) [ "$(field "$2" file)" = absent ] && [ "$(inotify_finding "$(field "$2" instances)" "$(field "$2" watches)")" != OK ] ;;
    journald.cap) [ "$(field "$2" file)" = absent ] && [ -n "$(journald_keys "$2")" ] && journal_need ;;
    services.unused:*) [ "$(svc_offer "${1#*:}" "$(desktop)" "$(bt_flag)")" = fix ] && any_on "$2" ;;
    fstrim.timer) [ "$(field "$2" enabled)" = disabled ] && trim_need ;;
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
    sysctl.tune)
      _i=$(proc_num fs/inotify/max_user_instances); _w=$(proc_num fs/inotify/max_user_watches)
      { is_num "$_i" && is_num "$_w"; } || return 0
      [ "$(inotify_finding "$_i" "$_w")" = OK ] && return 0
      [ "$(dropin_state "$(sysctl_dropin)" "$SYSCTL_MARK")" = absent ] || echo "$(sysctl_dropin) exists already (from an earlier run or written by hand); this script writes it only when it is absent, so edit it yourself (or undo the earlier record first)" ;;
    journald.cap)
      [ "$(dropin_state "$(journald_dropin)" "$JOURNALD_MARK")" = absent ] && return 0
      journal_need && echo "$(journald_dropin) exists already (from an earlier run or written by hand); this script writes it only when it is absent" ;;
    services.unused:*)
      _sv=${1#*:}
      if [ "$_sv" = bluetooth ] && [ "$(desktop)" = no ] && bt_input && any_on "$(svc_state bluetooth)"; then echo "a Bluetooth keyboard, mouse or other input device is connected (/sys/bus/hid/devices/0005:*), so bluetooth stays on"; return 0; fi
      [ "$(svc_offer "$_sv" "$(desktop)" "$(bt_flag)")" = fix ] || return 0
      _st=$(svc_state "$_sv")
      if ! valid_state services.unused "$_st" && any_on "$_st"; then echo "a unit is in a state this script does not change ($_st); it handles only units that are enabled, disabled or missing and active or inactive, so change it yourself if you want"; fi ;;
  esac
  return 0
}
done_ok() { # $1 key, $2 state after the change
  case "$1" in
    ssh.start|fstrim.timer) [ "$(field "$2" enabled)" = enabled ] && [ "$(field "$2" active)" = active ] ;;
    power.sleep) [ -z "$(to_mask "$2")" ] ;;
    sysctl.tune) [ "$(field "$2" file)" = lanq ] && [ "$(inotify_finding "$(field "$2" instances)" "$(field "$2" watches)")" = OK ] ;;
    journald.cap) [ "$(field "$2" file)" = lanq ] ;;
    services.unused:*) ! any_on "$2" ;;
    *) return 1 ;;
  esac
}
expected_after() {
  case "$1" in
    ssh.start) echo "unit=$(field "$2" unit) enabled=enabled active=active" ;;
    power.sleep) echo "sleep=masked suspend=masked hibernate=masked hybrid-sleep=masked" ;;
    sysctl.tune) echo "file=lanq instances=$(raise_to "$(field "$2" instances)" "$INOTIFY_INSTANCES") watches=$(raise_to "$(field "$2" watches)" "$INOTIFY_WATCHES")" ;;
    journald.cap) echo "file=lanq dir=present sys=$(field "$2" sys) run=$(field "$2" run)" ;;
    services.unused:*) printf '%s\n' "$2" | awk '{ for (i = 2; i <= NF; i++) { sub(/=enabled:/, "=disabled:", $i); sub(/:active$/, ":inactive", $i) } print }' ;;
    fstrim.timer) echo "enabled=enabled active=active" ;;
  esac
}
check_of() {
  case "$1" in
    ssh.start) echo "ssh.server: sshd is installed but not running" ;;
    power.sleep) echo "power.sleep: the sleep targets are not all masked, so the machine may suspend mid-job" ;;
    sysctl.tune) echo "sysctl.inotify: the inotify limits are below the suggested $INOTIFY_INSTANCES instances and $INOTIFY_WATCHES watches" ;;
    journald.cap) echo "journald.size: the systemd journal is large and has no size cap of its own" ;;
    services.unused:*) echo "services.unused: ${1#*:} is enabled or running on a build box" ;;
    fstrim.timer) echo "fstrim: an SSD that accepts TRIM, but fstrim.timer is disabled" ;;
  esac
}
# Undo succeeded when the state is back to before. services.unused: each unit has its enabled state back, and every unit
# that was active is active again (starting cups.path or cups.socket may start cups.service too). journald.cap: the
# folder this fix created may stay when something else put files in it.
# Two states of one fix are the same. journald.cap: only file= and dir=; sys/run (caps of your own) are read again at
# undo time, and a cap you add later must not make the record impossible to undo.
same_state() { # $1 key, $2 state, $3 state
  case "$1" in
    journald.cap) [ -n "$2" ] && [ "$(field "$2" file)" = "$(field "$3" file)" ] && [ "$(field "$2" dir)" = "$(field "$3" dir)" ] ;;
    *) [ "$2" = "$3" ] ;;
  esac
}
undo_ok() { # $1 key, $2 state now, $3 before
  case "$1" in
    services.unused:*)
      [ -n "$2" ] && [ "$(field "$2" svc)" = "$(field "$3" svc)" ] || return 1
      for _u in $(svc_units "$(field "$3" svc)"); do
        _n=$(field "$2" "${_u##*.}"); _b=$(field "$3" "${_u##*.}")
        [ "${_n%%:*}" = "${_b%%:*}" ] || return 1
        [ "${_b#*:}" = inactive ] || [ "${_n#*:}" = active ] || return 1
      done ;;
    journald.cap)
      same_state journald.cap "$2" "$3" && return 0
      [ "$(field "$2" file)" = "$(field "$3" file)" ] && [ "$(field "$3" dir)" = absent ] && [ "$(field "$2" dir)" = present ] || return 1
      [ -n "$(ls -A -- "$(journald_dir)" 2>/dev/null)" ] ;;
    *) [ "$2" = "$3" ] ;;
  esac
}
summary() {
  case "$1" in
    ssh.start) echo "$(field "$2" unit).service is $(field "$2" active), $(field "$2" enabled) at boot" ;;
    sysctl.tune) echo "max_user_instances $(field "$2" instances), max_user_watches $(field "$2" watches); $(sysctl_dropin) is $(field "$2" file)" ;;
    journald.cap) echo "$(journald_dropin) is $(field "$2" file); caps of your own: SystemMaxUse $(field "$2" sys), RuntimeMaxUse $(field "$2" run)" ;;
    fstrim.timer) echo "fstrim.timer is $(field "$2" active), $(field "$2" enabled) at boot" ;;
    *) echo "$2" ;;
  esac
}

# region FIXES
# The ONE place that changes this machine, keyed by fix id. fix_command prints the exact commands shown and recorded;
# fix_change runs them. $3 is the before state (fresh, or from a validated record). Unit, target, file and sysctl names
# come only from fixed lists (ssh|sshd, the four sleep targets, svc_units, the two drop-in paths, the two inotify keys);
# a record supplies only states that passed valid_state, and nothing in a record is ever run as code.
fix_command() { # $1 key, $2 apply|undo, $3 before
  case "${1%%:*}|$2" in
    "ssh.start|apply") echo "systemctl enable --now $(field "$3" unit).service" ;;
    "ssh.start|undo")
      [ "$(field "$3" enabled)" = disabled ] && echo "systemctl disable $(field "$3" unit).service"
      [ "$(field "$3" active)" = inactive ] && echo "systemctl stop $(field "$3" unit).service" ;;
    "power.sleep|apply") echo "systemctl mask $(to_mask "$3")" ;;
    "power.sleep|undo") echo "systemctl unmask $(to_mask "$3")" ;;
    "sysctl.tune|apply") echo "write $(sysctl_dropin): $(sysctl_args "$3" apply)"; echo "sysctl -w $(sysctl_args "$3" apply)" ;;
    "sysctl.tune|undo") echo "rm $(sysctl_dropin)"; echo "sysctl -w $(sysctl_args "$3" undo)" ;;
    "journald.cap|apply")
      [ "$(field "$3" dir)" = absent ] && echo "mkdir -m 755 $(journald_dir)"
      echo "write $(journald_dropin): $(journald_keys "$3")"; echo "systemctl restart systemd-journald.service" ;;
    "journald.cap|undo")
      echo "rm $(journald_dropin)"
      [ "$(field "$3" dir)" = absent ] && echo "rmdir $(journald_dir) when empty"
      echo "systemctl restart systemd-journald.service" ;;
    "services.unused|apply") echo "systemctl disable --now $(svc_pick "$3" on)" ;;
    "services.unused|undo")
      [ -n "$(svc_pick "$3" enabled)" ] && echo "systemctl enable $(svc_pick "$3" enabled)"
      [ -n "$(svc_pick "$3" active)" ] && echo "systemctl start $(svc_pick "$3" active)" ;;
    "fstrim.timer|apply") echo "systemctl enable --now fstrim.timer" ;;
    "fstrim.timer|undo")
      [ "$(field "$3" enabled)" = disabled ] && echo "systemctl disable fstrim.timer"
      [ "$(field "$3" active)" = inactive ] && echo "systemctl stop fstrim.timer" ;;
  esac
  return 0
}
# A new file: written to a temp file in the same folder, then renamed into place (root's, mode 0600 from umask 077).
put_file() { # $1 path, $2 text
  _pd=${1%/*}
  [ -L "$_pd" ] && return 1
  [ -d "$_pd" ] || mkdir -m 755 -- "$_pd" || return 1
  _pt=$(mktemp "$_pd/.lanq-makeready.XXXXXX") || return 1
  if printf '%s\n' "$2" > "$_pt" && mv -f -- "$_pt" "$1"; then return 0; fi
  rm -f -- "$_pt"
  return 1
}
# shellcheck disable=SC2046 # the target list is words from a fixed list, split on purpose
fix_change() { # $1 key, $2 apply|undo, $3 before
  case "${1%%:*}|$2" in
    "ssh.start|apply") systemctl enable --now "$(field "$3" unit).service" </dev/null ;;
    "ssh.start|undo")
      _undo_rc=0
      if [ "$(field "$3" enabled)" = disabled ]; then systemctl disable "$(field "$3" unit).service" </dev/null || _undo_rc=1; fi
      if [ "$(field "$3" active)" = inactive ]; then systemctl stop "$(field "$3" unit).service" </dev/null || _undo_rc=1; fi
      return "$_undo_rc" ;;
    "power.sleep|apply") systemctl mask $(to_mask "$3") </dev/null ;;
    "power.sleep|undo") systemctl unmask $(to_mask "$3") </dev/null ;;
    "sysctl.tune|apply") put_file "$(sysctl_dropin)" "$(sysctl_text "$3")" && sysctl -w $(sysctl_args "$3" apply) </dev/null >/dev/null ;;
    "sysctl.tune|undo")
      _undo_rc=0
      rm -f -- "$(sysctl_dropin)" || _undo_rc=1
      sysctl -w $(sysctl_args "$3" undo) </dev/null >/dev/null || _undo_rc=1
      return "$_undo_rc" ;;
    "journald.cap|apply") put_file "$(journald_dropin)" "$(journald_text "$3")" && systemctl restart systemd-journald.service </dev/null ;;
    "journald.cap|undo")
      rm -f -- "$(journald_dropin)" || return 1
      if [ "$(field "$3" dir)" = absent ] && [ -z "$(ls -A -- "$(journald_dir)" 2>/dev/null)" ]; then rmdir -- "$(journald_dir)" || return 1; fi
      systemctl restart systemd-journald.service </dev/null ;;
    "services.unused|apply") systemctl disable --now $(svc_pick "$3" on) </dev/null ;;
    "services.unused|undo")
      _undo_rc=0
      if [ -n "$(svc_pick "$3" enabled)" ]; then systemctl enable $(svc_pick "$3" enabled) </dev/null || _undo_rc=1; fi
      if [ -n "$(svc_pick "$3" active)" ]; then systemctl start $(svc_pick "$3" active) </dev/null || _undo_rc=1; fi
      return "$_undo_rc" ;;
    "fstrim.timer|apply") systemctl enable --now fstrim.timer </dev/null ;;
    "fstrim.timer|undo")
      _undo_rc=0
      if [ "$(field "$3" enabled)" = disabled ]; then systemctl disable fstrim.timer </dev/null || _undo_rc=1; fi
      if [ "$(field "$3" active)" = inactive ]; then systemctl stop fstrim.timer </dev/null || _undo_rc=1; fi
      return "$_undo_rc" ;;
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
  _S='[a-z0-9 .=:-]{1,200}'
  _I='    \{"seq": [1-9][0-9]{0,2}, "id": "(ssh\.start|power\.sleep|sysctl\.tune|journald\.cap|services\.unused|fstrim\.timer)", "status": "(pending|applied|failed|undone|skipped)", "time": "'$_T'", "before": "'$_S'", "command": "[A-Za-z0-9 ._/;=:-]{0,255}[A-Za-z0-9 ._/;=:-]{0,255}", "after": "'$_S'"\}'
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
  case "$1" in
    sysctl.tune) out "  note:    raises the limits now and at every boot (the file is read at boot); it never lowers a value" ;;
    journald.cap) out "  WARNING: when journald restarts it deletes the oldest journal files down to the new caps ($(journald_keys "$2"); caps you set yourself are left as they are). Undo removes the caps, but the deleted logs cannot be restored." ;;
    services.unused:cups) out "  note:    cups-browsed needs cups, so it stops too while cups is stopped; printing from this machine stops" ;;
    services.unused:bluetooth) out "  note:    Bluetooth keyboards, mice and headsets stop working on this machine" ;;
    services.unused:modemmanager) out "  note:    a mobile-broadband (cellular modem) connection on this machine drops and does not come back until ModemManager runs again" ;;
  esac
  fix_command "$1" apply "$2" | while IFS= read -r _c; do out "  command: $_c"; done
  fix_command "$1" undo "$2" | while IFS= read -r _c; do out "  undo:    $_c"; done
}

do_apply() { # $1 = 1 for a dry run
  _dry=$1; _failed=0; _shown=0; REC_PATH=""
  _root=no; if is_root; then _root=yes; fi
  if [ "$_dry" = 1 ]; then out "lanq-makeready-fix $TOOL_VERSION dry run: shows each applicable fix and its undo; nothing is changed"
  else out "lanq-makeready-fix $TOOL_VERSION: changes only what you confirm, one fix at a time (default no)"; fi
  if [ "$_root" = yes ] && [ "$_dry" != 1 ]; then _why=$(record_dir_problem); if [ -n "$_why" ]; then err "lanq-makeready-fix: $_why"; return 1; fi; fi
  for _key in $KEYS; do
    _id=${_key%%:*}
    _note=$(note_of "$_key")
    if [ -n "$_note" ]; then out ""; out "$_key  (check $(check_of "$_key")): not offered: $_note"; continue; fi
    _s=$(state_of "$_key")
    { [ -n "$_s" ] && needed "$_key" "$_s"; } || continue
    _shown=$((_shown + 1))
    show_fix "$_key" "$_s"
    if [ "$_root" = no ]; then out "  skipped: needs root (run it yourself with sudo at this machine); this script never elevates itself"; continue; fi
    if [ "$_dry" = 1 ]; then out "  dry run: not applied"; continue; fi
    if ! confirm; then out ""; out "  not applied"; continue; fi
    out ""
    _s2=$(state_of "$_key")   # the precondition, re-read just before the change
    if [ -z "$_s2" ] || ! needed "$_key" "$_s2"; then out "  no longer needed (the state changed); nothing done"; continue; fi
    if [ "$_s2" != "$_s" ]; then out "  the state changed since it was shown; nothing done (run the script again)"; continue; fi
    [ -n "$REC_PATH" ] || new_record
    _seq=$(($(item_count) + 1))
    _cmd=$(fix_command "$_key" apply "$_s2" | awk 'NR != 1 { printf " ; " } { printf "%s", $0 }')
    REC_ITEMS=$(printf '%s\n%s|%s|pending|%s|%s|%s|%s' "$REC_ITEMS" "$_seq" "$_id" "$(now_utc)" "$_s2" "$_cmd" "$(expected_after "$_key" "$_s2")" | grep '^[0-9]')
    if ! save_record; then err "  nothing changed: the undo record could not be written"; return 1; fi
    fix_change "$_key" apply "$_s2"; _rc=$?
    _s3=$(state_of "$_key"); [ -n "$_s3" ] || _s3=unknown
    if [ "$_rc" = 0 ] && [ "$_s3" != unknown ] && done_ok "$_key" "$_s3"; then set_item "$_seq" applied "$(now_utc)" "$_s3"; out "  applied and verified"
    else set_item "$_seq" failed "$(now_utc)" "$_s3"; _failed=$((_failed + 1)); out "  FAILED (exit $_rc; now: $_s3); recorded, so --undo can put back what changed"; fi
    save_record || _failed=$((_failed + 1))
  done
  _t=""; [ "$KEYS" = "$TUNE_KEYS" ] && _t=" --tune"
  if [ "$_shown" = 0 ]; then out "Nothing to fix here (fixes: $KEYS)."
  elif [ "$_root" = no ]; then out ""; out "To apply, run it yourself with sudo at this machine: sudo sh lanq-makeready-fix.sh$_t"; fi
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
    _key=$_id; [ "$_id" = services.unused ] && _key="$_id:$(field "$_b" svc)"   # a known name: the state passed valid_state
    out ""
    out "undo $_key  (check $(check_of "$_key")), $_st at $_tm"
    _cur=$(state_of "$_key")
    out "  before the fix: $_b"
    out "  after the fix:  $_a"
    out "  now:            $_cur"
    if [ "$_st" = pending ] && [ -n "$_cur" ] && same_state "$_key" "$_cur" "$_b"; then
      set_item "$_s" skipped "$(now_utc)" "$_a"
      if save_record; then out "  never applied (the record was written, the change was not made); marked skipped"; else _failed=$((_failed + 1)); fi
      continue
    fi
    fix_command "$_key" undo "$_b" | while IFS= read -r _c; do out "  command: $_c"; done
    if [ -z "$_cur" ] || ! same_state "$_key" "$_cur" "$_a"; then out "  changed since; left alone"; continue; fi
    if ! confirm; then out ""; out "  left as it is"; continue; fi
    out ""
    if ! same_state "$_key" "$(state_of "$_key")" "$_a"; then out "  changed since; left alone"; continue; fi
    fix_change "$_key" undo "$_b"; _rc=$?
    _now=$(state_of "$_key")
    if [ "$_rc" = 0 ] && undo_ok "$_key" "$_now" "$_b"; then
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
  MODE=apply; UNDO_FILE=""; _modes=0; KEYS=$FIX_IDS; _tune=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --tune) KEYS=$TUNE_KEYS; _tune=1 ;;
      --dry-run) MODE=dry; _modes=$((_modes + 1)) ;;
      --undo) if [ $# -lt 2 ] || [ -z "$2" ]; then err "lanq-makeready-fix: --undo needs a record file"; return 2; fi; MODE=undo; UNDO_FILE=$2; _modes=$((_modes + 1)); shift ;;
      --list) MODE=list; _modes=$((_modes + 1)) ;;
      -h|--help) out "$USAGE"; return 0 ;;
      *) err "lanq-makeready-fix: unknown argument: $1"; err "$USAGE"; return 2 ;;
    esac
    shift
  done
  if [ "$_modes" -gt 1 ]; then err "lanq-makeready-fix: use only one of --dry-run, --undo and --list"; return 2; fi
  case "$_tune:$MODE" in 1:undo|1:list) err "lanq-makeready-fix: --tune goes with an apply run or --dry-run; --undo and --list handle every fix without it"; return 2 ;; esac
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
  if [ "$_tune" = 1 ] && [ "$MODE" != dry ] && fx_container; then err "lanq-makeready-fix: refused: this is a container (docker, podman, LXC or systemd-nspawn). The tune fixes change host settings; run them on the host. Nothing was changed."; return 3; fi
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
