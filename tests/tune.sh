#!/bin/sh
# shellcheck disable=SC2034,SC2016,SC2329,SC2317,SC1091,SC2086,SC2030,SC2031
# Tests for lanq-makeready-tune.sh (POSIX sh, busybox too). Usage: sh tests/tune.sh
# The checks read a fake root (R=...) and fake systemctl/df/du/smartctl answers; nothing here changes this machine.
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
tune="$root/lanq-makeready-tune.sh"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1 : expected '$3' got '$2'"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "$1" "$2"; fi; }
contains() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3" "$1" "*$2*" ;; esac; }
lacks() { case "$1" in *"$2"*) bad "$3" "$1" "no $2" ;; *) ok "$3" ;; esac; }

LANQ_MAKEREADY_TUNE_LIB=1
export LANQ_MAKEREADY_TUNE_LIB
__lanq_makeready_tune_test_harness() { :; }
# shellcheck source=lanq-makeready-tune.sh
. "$tune"

echo "pure helpers"
for h in 00:00-07:00 22:00-06:00 23:59-00:00; do if valid_hours "$h"; then ok "valid_hours $h"; else bad "valid_hours $h" no yes; fi; done
for h in '' 7-9 24:00-07:00 07:00-07:00 '00:00-07:00;id'; do if valid_hours "$h"; then bad "valid_hours '$h'" yes no; else ok "valid_hours rejects '$h'"; fi; done
for w in /srv/lq /home/b/lq /a_b.c-d; do if valid_work_root "$w"; then ok "work root $w"; else bad "work root $w" no yes; fi; done
for w in '' srv/lq '/srv/l q' '/srv/../etc' '/srv/$(id)' 'C:/lq' "/srv/lq
x"; do if valid_work_root "$w"; then bad "work root '$w'" yes no; else ok "work root rejected: '$w'"; fi; done
if in_hours 02:00 00:00-07:00; then ok "in_hours: 02:00 in 00:00-07:00"; else bad in_hours no yes; fi
if in_hours 07:00 00:00-07:00; then bad "in_hours end excluded" yes no; else ok "in_hours: the end is not inside"; fi
if in_hours 01:30 22:00-06:00; then ok "in_hours: wraps past midnight"; else bad "in_hours wrap" no yes; fi
if in_hours 12:00 22:00-06:00; then bad "in_hours wrap outside" yes no; else ok "in_hours: noon is outside 22:00-06:00"; fi
eq "$(gov_finding intel_pstate powersave | cut -d'|' -f1)" OK "governor: intel_pstate powersave is OK"
eq "$(gov_finding amd-pstate-epp powersave | cut -d'|' -f1)" OK "governor: amd-pstate-epp powersave is OK"
eq "$(gov_finding acpi-cpufreq powersave | cut -d'|' -f1)" WARN "governor: acpi-cpufreq powersave is WARN"
eq "$(gov_finding intel_cpufreq powersave | cut -d'|' -f1)" WARN "governor: intel_cpufreq powersave is WARN"
eq "$(gov_finding acpi-cpufreq schedutil | cut -d'|' -f1)" OK "governor: acpi-cpufreq schedutil is OK"
eq "$(gov_finding acpi-cpufreq userspace | cut -d'|' -f1)" INFO "governor: userspace is INFO"
eq "$(gov_finding cppc_cpufreq schedutil | cut -d'|' -f1)" INFO "governor: an unknown driver is INFO"
eq "$(inotify_finding 128 524288)" WARN "inotify: 128 instances WARN"
eq "$(inotify_finding 129 8192)" INFO "inotify: watches below 524288 INFO"
eq "$(inotify_finding 8192 524288)" OK "inotify: OK"
eq "$(printf '[Journal]\n#SystemMaxUse=1G\nSystemMaxUse = 2G\n' | journald_limits)" "2G -" "journald_limits: comments skipped, spaces dropped"
eq "$(printf 'SystemMaxUse=2G\nRuntimeMaxUse=100M\nSystemMaxUse=500M\n' | journald_limits)" "500M 100M" "journald_limits: the last value wins"
eq "$(printf 'APT::Periodic::Unattended-Upgrade "1";\nUnattended-Upgrade::Automatic-Reboot "true";\nUnattended-Upgrade::Automatic-Reboot-Time "02:30";\n' | apt_values)" "1 true 02:30" "apt_values"
eq "$(printf '//Unattended-Upgrade::Automatic-Reboot "true";\n' | apt_values)" "- - -" "apt_values: // comments skipped"
eq "$(printf '[commands]\napply_updates = yes\nreboot = when-needed\n' | dnf_values)" "yes when-needed" "dnf_values"
eq "$(svc_offer avahi no)" report "avahi is report only"
eq "$(svc_offer cups yes)" none "cups on a desktop: not reported"
eq "$(svc_offer cups-browsed yes)" fix "cups-browsed: always"
eq "$(svc_offer bluetooth no yes)" none "bluetooth with a Bluetooth input device: never offered"
eq "$(svc_offer bluetooth no no)" fix "bluetooth on a headless box without Bluetooth input: fixable"

echo "checks against a fake root (one case per status)"
FAKE=${TMPDIR:-/tmp}/lanq-tune.$$
reset() { # a quiet, healthy Linux host with systemd
  rm -rf "$FAKE"; mkdir -p "$FAKE/r/proc/sys/vm" "$FAKE/r/proc/sys/fs/inotify" "$FAKE/r/proc/1" "$FAKE/r/run/systemd/system" "$FAKE/r/etc" "$FAKE/u"
  R=$FAKE/r; ITEMS=""; CONTAINER=false; HOURS=""; WORK_ROOT=""; REDACT=0; QUIET=0; T_END=$(( $(now_s) + 90 )); ROOTUSER=1
  echo 60 > "$R/proc/sys/vm/swappiness"; echo 8192 > "$R/proc/sys/fs/inotify/max_user_instances"; echo 524288 > "$R/proc/sys/fs/inotify/max_user_watches"
  printf 'MemTotal:       16303000 kB\n' > "$R/proc/meminfo"; printf '0::/init.scope\n' > "$R/proc/1/cgroup"; printf '/dev/sda1 / ext4 rw 0 0\n' > "$R/proc/mounts"
  echo 'PRETTY_NAME="Testix 1"' > "$R/etc/os-release"
}
cpu() { # driver governor [count]
  for _c in 0 1; do mkdir -p "$R/sys/devices/system/cpu/cpu$_c/cpufreq"; echo "$1" > "$R/sys/devices/system/cpu/cpu$_c/cpufreq/scaling_driver"; echo "$2" > "$R/sys/devices/system/cpu/cpu$_c/cpufreq/scaling_governor"; done
}
unit() { echo "$2" > "$FAKE/u/$1.en"; echo "$3" > "$FAKE/u/$1.act"; } # unit NAME enabled active
unit_en() { cat "$FAKE/u/$1.en" 2>/dev/null || echo none; }
unit_act() { cat "$FAKE/u/$1.act" 2>/dev/null || echo inactive; }
have() { case "$1" in systemctl) return 0 ;; smartctl) [ -e "$FAKE/smartctl" ] ;; loginctl) [ -e "$FAKE/sessions" ] ;; systemd-detect-virt) [ -e "$FAKE/sdv" ] ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
is_root() { [ "$ROOTUSER" = 1 ]; }
dir_kb() { _p=${1#"$R"}; _p=$(printf '%s' "$_p" | tr '/' '_'); cat "$FAKE/kb$_p" 2>/dev/null || { [ -d "$1" ] && echo 4 || echo 0; }; }
kb() { _p=$(printf '%s' "$1" | tr '/' '_'); mkdir -p "$R$1"; echo "$2" > "$FAKE/kb$_p"; } # kb /var/log/journal 2000000
df_used() { case "$1" in /) cat "$FAKE/df.root" 2>/dev/null || echo "40 /" ;; *) cat "$FAKE/df.work" 2>/dev/null || echo "40 /" ;; esac; }
run_t() { # the fakes behind run_t: smartctl, loginctl, systemd-detect-virt
  shift
  case "$1" in
    smartctl) _d=${5##*/}; cat "$FAKE/smart.$_d" 2>/dev/null ;;
    loginctl) if [ "$2" = list-sessions ]; then cat "$FAKE/sessions"; else cat "$FAKE/type.$3" 2>/dev/null; fi ;;
    systemd-detect-virt) [ -e "$FAKE/virt" ] ;;
    *) "$@" ;;
  esac
}
disk() { mkdir -p "$R/sys/block/$1/queue"; echo "$2" > "$R/sys/block/$1/queue/rotational"; echo "$3" > "$R/sys/block/$1/queue/discard_max_bytes"; }
st() { item_field "$1" 3; }
det() { item_field "$1" 4; }
fid() { item_field "$1" 7; }
run1() { ITEMS=""; "$@"; }

reset; run1 check_governor; eq "$(st cpu.governor)" SKIP "cpu.governor SKIP: no cpufreq (VM)"
reset; cpu intel_pstate powersave; run1 check_governor; eq "$(st cpu.governor)" OK "cpu.governor OK: intel_pstate powersave"
reset; cpu acpi-cpufreq powersave; run1 check_governor; eq "$(st cpu.governor)" WARN "cpu.governor WARN: acpi-cpufreq powersave"; contains "$(item_field cpu.governor 5)" "schedutil" "cpu.governor WARN: advice"
eq "$(fid cpu.governor)" "" "cpu.governor: report only (no fix id)"
reset; cpu mystery-freq ondemand; run1 check_governor; eq "$(st cpu.governor)" INFO "cpu.governor INFO: unknown driver"
reset; run1 check_swappiness; eq "$(st sysctl.swappiness)" OK "swappiness OK: 60"
reset; echo 100 > "$R/proc/sys/vm/swappiness"; printf 'MemTotal: 4000000 kB\n' > "$R/proc/meminfo"; run1 check_swappiness; eq "$(st sysctl.swappiness)" INFO "swappiness INFO: 100 with 4 GB"; eq "$(fid sysctl.swappiness)" "" "swappiness: report only"
reset; echo 100 > "$R/proc/sys/vm/swappiness"; run1 check_swappiness; eq "$(st sysctl.swappiness)" OK "swappiness OK: 100 with 16 GB"
reset; rm "$R/proc/sys/vm/swappiness"; run1 check_swappiness; eq "$(st sysctl.swappiness)" SKIP "swappiness SKIP: not readable"
reset; run1 check_inotify; eq "$(st sysctl.inotify)" OK "inotify OK"
reset; echo 128 > "$R/proc/sys/fs/inotify/max_user_instances"; run1 check_inotify; eq "$(st sysctl.inotify)" WARN "inotify WARN: 128 instances"; eq "$(fid sysctl.inotify)" sysctl.tune "inotify: fix id sysctl.tune"
reset; echo 8192 > "$R/proc/sys/fs/inotify/max_user_watches"; run1 check_inotify; eq "$(st sysctl.inotify)" INFO "inotify INFO: watches 8192"
reset; rm "$R/proc/sys/fs/inotify/max_user_watches"; run1 check_inotify; eq "$(st sysctl.inotify)" SKIP "inotify SKIP: not readable"
reset; run1 check_journald; eq "$(st journald.size)" SKIP "journald SKIP: no journal"
reset; kb /var/log/journal 300000; run1 check_journald; eq "$(st journald.size)" OK "journald OK: 300 MB"
reset; kb /var/log/journal 2000000; run1 check_journald; eq "$(st journald.size)" INFO "journald INFO: 2 GB persistent, no cap"; eq "$(fid journald.size)" journald.cap "journald: fix id journald.cap"
contains "$(det journald.size)" "default: 10% of the filesystem, at most 4 GB" "journald: the detail names the default cap"
reset; kb /run/log/journal 300000; run1 check_journald; eq "$(st journald.size)" INFO "journald INFO: a volatile journal in /run (RAM)"
reset; kb /var/log/journal 2000000; printf '[Journal]\nSystemMaxUse=3G\n' > "$R/etc/systemd.conf.tmp"; mkdir -p "$R/etc/systemd"; mv "$R/etc/systemd.conf.tmp" "$R/etc/systemd/journald.conf"; run1 check_journald
eq "$(st journald.size)" OK "journald OK: a cap set by hand"
if [ "$(id -u)" != 0 ]; then reset; kb /var/log/journal 10; mkdir -p "$R/var/log/journal/abc"; chmod 000 "$R/var/log/journal/abc"; run1 check_journald; eq "$(st journald.size)" SKIP "journald SKIP: not readable (needs admin)"; eq "$(item_field journald.size 6)" true "journald: needsAdmin"; chmod 700 "$R/var/log/journal/abc"; fi
reset; run1 check_services; eq "$(st services.unused)" OK "services OK: none"
reset; unit cups.service enabled active; echo 7 > "$FAKE/sessions"; echo Type=wayland > "$FAKE/type.7"; run1 check_services; eq "$(st services.unused)" OK "M2: a wayland session (no display manager) is a desktop: cups not reported"
reset; unit cups.service enabled active; echo 7 > "$FAKE/sessions"; echo Type=tty > "$FAKE/type.7"; run1 check_services; eq "$(st services.unused)" INFO "M2: a tty session is not a desktop"
reset; unit bluetooth.service enabled active; mkdir -p "$R/sys/bus/hid/devices/0005:046D:B342.0001"; run1 check_services; eq "$(st services.unused)" OK "M2: a Bluetooth input device: bluetooth not reported"; contains "$(det services.unused)" "Bluetooth input device is connected" "M2: says why"
reset; unit bluetooth.service enabled active; unit cups.service enabled active; mkdir -p "$R/sys/bus/hid/devices/0005:046D:B342.0001"; run1 check_services; eq "$(fid services.unused)" services.unused "M2: cups still fixable"; lacks "$(det services.unused)" "bluetooth.service" "M2: bluetooth left out of the list"
reset; unit cups.service enabled active; unit cups.socket enabled active; unit cups-browsed.service enabled active; n=0; due() { n=$((n + 1)); [ "$n" -le 3 ]; }; run1 check_services; unset -f due
eq "$(st services.unused)" SKIP "L4: the deadline is checked per unit in services"
due() { [ $(( $(now_s) + ${1:-1} )) -le "$T_END" ]; }
reset; unit cups-browsed.service enabled active; run1 check_services; eq "$(st services.unused)" WARN "services WARN: cups-browsed"; eq "$(item_field services.unused 8)" true "services: cups-browsed is a security item"; eq "$(fid services.unused)" services.unused "services: fix id"
reset; unit cups.service enabled active; unit cups.socket enabled active; run1 check_services; eq "$(st services.unused)" INFO "services INFO: cups"; contains "$(det services.unused)" "cups.socket enabled/active" "services: units listed"
reset; unit avahi-daemon.service enabled active; run1 check_services; eq "$(st services.unused)" INFO "services INFO: avahi"; eq "$(fid services.unused)" "" "services: avahi alone is report only (no fix id)"; contains "$(item_field services.unused 5)" "host.local" "services: avahi advice explains"
reset; unit display-manager.service enabled active; unit cups.service enabled active; unit bluetooth.service enabled active; run1 check_services; eq "$(st services.unused)" OK "services OK: a desktop keeps cups and bluetooth"
reset; rm -rf "$R/run/systemd"; run1 check_services; eq "$(st services.unused)" SKIP "services SKIP: no systemd"
reset; run1 check_unattended; eq "$(st unattended.reboot)" OK "unattended OK: nothing set up"
apt_on() { mkdir -p "$R/usr/bin" "$R/etc/apt/apt.conf.d"; : > "$R/usr/bin/unattended-upgrade"; chmod 755 "$R/usr/bin/unattended-upgrade"; printf 'APT::Periodic::Unattended-Upgrade "1";\nUnattended-Upgrade::Automatic-Reboot "true";\n%s\n' "$1" > "$R/etc/apt/apt.conf.d/50x"; }
reset; apt_on 'Unattended-Upgrade::Automatic-Reboot-Time "02:00";'; HOURS=00:00-07:00; run1 check_unattended; eq "$(st unattended.reboot)" WARN "unattended WARN: 02:00 inside 00:00-07:00"; eq "$(fid unattended.reboot)" "" "unattended: report only"
reset; apt_on 'Unattended-Upgrade::Automatic-Reboot-Time "22:00";'; HOURS=00:00-07:00; run1 check_unattended; eq "$(st unattended.reboot)" OK "unattended OK: 22:00 outside the hours"
reset; apt_on ''; run1 check_unattended; eq "$(st unattended.reboot)" INFO "unattended INFO: no --hours"; contains "$(det unattended.reboot)" "06:00" "unattended: 'now' means after the 06:00 run"
reset; mkdir -p "$R/etc/dnf"; printf '[commands]\napply_updates = yes\nreboot = when-needed\n' > "$R/etc/dnf/automatic.conf"; unit dnf-automatic.timer enabled active; HOURS=05:00-08:00; run1 check_unattended
eq "$(st unattended.reboot)" WARN "unattended WARN: dnf-automatic reboots inside the hours"
n=0; due() { n=$((n + 1)); [ "$n" -le 2 ]; }; run1 check_unattended; eq "$(st unattended.reboot)" SKIP "L4: the deadline is checked per call in unattended"
due() { [ $(( $(now_s) + ${1:-1} )) -le "$T_END" ]; }
reset; run1 check_pkgcache; eq "$(st pkgcache)" OK "pkgcache OK: none"
reset; kb /var/cache/apt/archives 10; kb /var/cache/dnf 10; n=0; due() { n=$((n + 1)); [ "$n" -le 1 ]; }; run1 check_pkgcache
eq "$(st pkgcache)" SKIP "L4: the deadline is checked per folder in pkgcache"
due() { [ $(( $(now_s) + ${1:-1} )) -le "$T_END" ]; }
reset; kb /var/cache/apt/archives 3000000; run1 check_pkgcache; eq "$(st pkgcache)" INFO "pkgcache INFO: 3 GB"; contains "$(item_field pkgcache 5)" "apt clean" "pkgcache: advice"; eq "$(fid pkgcache)" "" "pkgcache: report only"
reset; run1 check_fstrim; eq "$(st fstrim)" OK "fstrim OK: no SSD"
reset; disk sda 0 2147450880; unit fstrim.timer disabled inactive; run1 check_fstrim; eq "$(st fstrim)" INFO "fstrim INFO: timer disabled"; eq "$(fid fstrim)" fstrim.timer "fstrim: fix id"
reset; disk sda 0 2147450880; unit fstrim.timer enabled active; run1 check_fstrim; eq "$(st fstrim)" OK "fstrim OK: timer enabled"
reset; disk sda 0 2147450880; printf '/dev/sda1 / ext4 rw,discard 0 0\n' > "$R/proc/mounts"; run1 check_fstrim; eq "$(st fstrim)" OK "fstrim OK: / mounted with discard"
reset; disk sda 0 2147450880; run1 check_fstrim; eq "$(st fstrim)" INFO "fstrim INFO: no timer unit"; eq "$(fid fstrim)" "" "fstrim: no unit, no fix id"
reset; disk sda 1 0; disk loop0 0 4096; run1 check_fstrim; eq "$(st fstrim)" OK "fstrim OK: HDD and loop devices ignored"
reset; disk sda 0 4096; rm -rf "$R/run/systemd"; run1 check_fstrim; eq "$(st fstrim)" SKIP "fstrim SKIP: no systemd"
reset; run1 check_smart; eq "$(st smart)" SKIP "smart SKIP: no smartctl"
reset; : > "$FAKE/smartctl"; ROOTUSER=0; run1 check_smart; eq "$(st smart)" SKIP "smart SKIP: not root"; eq "$(item_field smart 6)" true "smart: needsAdmin"
reset; : > "$FAKE/smartctl"; disk sda 0 0; disk nvme0n1 0 0; echo 'SMART overall-health self-assessment test result: PASSED' > "$FAKE/smart.sda"; echo 'SMART overall-health self-assessment test result: FAILED!' > "$FAKE/smart.nvme0n1"
run1 check_smart; eq "$(st smart)" WARN "smart WARN: a failing disk"; contains "$(det smart)" "FAILING: nvme0n1" "smart: names the disk"
reset; : > "$FAKE/smartctl"; disk sda 0 0; echo 'SMART Health Status: OK' > "$FAKE/smart.sda"; run1 check_smart; eq "$(st smart)" OK "smart OK"
reset; run1 check_thermal; eq "$(st thermal.throttle)" SKIP "thermal SKIP: no counters"
thr() { mkdir -p "$R/sys/devices/system/cpu/cpu0/thermal_throttle"; echo "$1" > "$R/sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count"; echo "$2" > "$R/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count"; }
reset; thr 0 0; run1 check_thermal; eq "$(st thermal.throttle)" OK "thermal OK"
reset; thr 12 3; run1 check_thermal; eq "$(st thermal.throttle)" INFO "thermal INFO: throttled"
reset; run1 check_disk; eq "$(st disk.full)" OK "disk OK"
reset; echo "95 /" > "$FAKE/df.root"; run1 check_disk; eq "$(st disk.full)" WARN "disk WARN: 95% used"
reset; mkdir -p "$FAKE/srv"; WORK_ROOT=$FAKE/srv/lq; echo "93 /srv" > "$FAKE/df.work"; run1 check_disk; eq "$(st disk.full)" WARN "disk WARN: the work root's filesystem"; contains "$(det disk.full)" "/srv 93%" "disk: names it"
reset; : > "$FAKE/df.root"; run1 check_disk; eq "$(st disk.full)" SKIP "disk SKIP: df gave nothing"

echo "containers, the time budget, macOS"
host_ids="cpu.governor sysctl.swappiness sysctl.inotify journald.size services.unused unattended.reboot fstrim smart thermal.throttle"
reset; : > "$R/.dockerenv"; cpu acpi-cpufreq powersave; echo 128 > "$R/proc/sys/fs/inotify/max_user_instances"; DEADLINE=90; gather_lin() { in_container && CONTAINER=true; ITEMS=""; check_governor; check_swappiness; check_inotify; check_journald; check_services; check_unattended; check_pkgcache; check_fstrim; check_smart; check_thermal; check_disk; }
gather_lin; for i in $host_ids; do eq "$(st "$i")" SKIP "container (/.dockerenv): $i SKIP"; done
eq "$(st pkgcache)" OK "container: pkgcache still runs"; eq "$(st disk.full)" OK "container: disk.full still runs"
contains "$(det cpu.governor)" "inside a container" "container: says why"
reset; printf '12:cpu:/docker/abc\n' > "$R/proc/1/cgroup"; if in_container; then ok "container: cgroup with docker"; else bad "cgroup docker" no yes; fi
reset; if in_container; then bad "a host is not a container" yes no; else ok "host: not a container"; fi
reset; mkdir -p "$R/run/systemd"; echo lxc > "$R/run/systemd/container"; if in_container; then ok "L3: /run/systemd/container (LXC, nspawn)"; else bad "L3 run/systemd/container" no yes; fi
reset; : > "$FAKE/sdv"; : > "$FAKE/virt"; if in_container; then ok "L3: systemd-detect-virt -c says container"; else bad "L3 detect-virt" no yes; fi
reset; : > "$FAKE/sdv"; if in_container; then bad "L3 detect-virt says none" yes no; else ok "L3: systemd-detect-virt -c says none: a host"; fi
reset; T_END=$(( $(now_s) - 1 )); gather_lin
eq "$(printf '%s' "$ITEMS" | awk -F"$SEP" '$3 != "SKIP"' | wc -l | tr -d ' ')" 0 "time budget spent: every check SKIP"
contains "$(det smart)" "time budget" "time budget: says so"
mac_uname() { if [ "$1" = -s ]; then echo Darwin; else echo arm64; fi; }
out=$( reset; uname() { mac_uname "$@"; }; sw_vers() { echo 15.1; }; main; echo "rc=$?" )
contains "$out" "no tune checks for macOS" "macOS: says so"; contains "$out" "rc=0" "macOS: exit 0"
out=$( reset; uname() { mac_uname "$@"; }; sw_vers() { echo 15.1; }; main --json - )
contains "$out" '"items": [],' "macOS: JSON with empty items"

echo "a whole run against the fake root: output, JSON shape, exit code, redaction"
whole() { # args...
  reset; : > "$FAKE/smartctl"; disk sda 0 2147450880; unit fstrim.timer disabled inactive; unit cups-browsed.service enabled active
  cpu acpi-cpufreq powersave; echo 128 > "$R/proc/sys/fs/inotify/max_user_instances"; kb /var/log/journal 2000000; echo 'SMART Health Status: OK' > "$FAKE/smart.sda"
  gather() { F_OS=Linux; F_ARCH=x86_64; F_HOST=testbox7; F_USER=builder7; F_OSNAME="Testix on testbox7"; CONTAINER=false; ELEVATED=true; T_END=$(( $(now_s) + 90 ))
    check_governor; check_swappiness; check_inotify; check_journald; check_services; check_unattended; check_pkgcache; check_fstrim; check_smart; check_thermal; check_disk; }
  HOME=/home/builder7; id() { case "$1" in -un) echo builder7 ;; -u) echo 0 ;; *) command id "$@" ;; esac; }; hostname() { echo testbox7; }
  main "$@"; echo "rc=$?"
}
out=$(whole --hours 00:00-07:00); contains "$out" "rc=0" "WARN rows still exit 0 (tuning never affects readiness)"
contains "$out" "[WARN] CPU frequency governor:" "human: [WARN] lines"; contains "$out" "Possible fixes (run at the PC): sudo sh lanq-makeready-fix.sh --tune --dry-run" "human: points at the fix script"
contains "$out" "Summary: 3 WARN, 2 INFO" "human: summary"
q=$(whole --quiet); lacks "$q" "[OK  ]" "--quiet: OK rows left out"
js=$(whole --json - --work-root /srv/lq); js=${js%rc=*}
eq "$(printf '%s' "$js" | head -n 1)" "{" "json: starts with {"
for k in '"schema": "lanq-makeready-tune/v1",' '"tool": {"name": "lanq-makeready-tune", "version": "' '"generatedAt": "' '"host": {"hostname": "testbox7", "user": "builder7", "os": "Testix on testbox7", "arch": "x86_64"},' \
  '"context": {"container": false, "elevated": true, "workRoot": "/srv/lq"},' '"summary": {"ok": 5, "info": 2, "warn": 3, "skip": 1}' '"fixId": null' '"fixId": "sysctl.tune"' '"security": true'; do
  contains "$js" "$k" "json has $k"
done
bad_lines=$(printf '%s\n' "$js" | sed -n '/"items": \[/,/^  \]/p' | sed '1d;$d' | grep -vxE '    \{"id": "[a-z.]+", "title": "[^"\\]*", "status": "(OK|INFO|WARN|SKIP)", "detail": "([^"\\]|\\.)*", "advice": "([^"\\]|\\.)*", "needsAdmin": (true|false), "fixId": (null|"[a-z.]+"), "security": (true|false)\},?')
eq "$bad_lines" "" "json: every item has exactly the schema's fields in order"
eq "$(printf '%s\n' "$js" | grep -c '"id": ')" 11 "json: eleven items"
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$js" | python3 -c "import json,sys; d=json.load(sys.stdin); assert set(d)=={'schema','tool','generatedAt','host','context','items','summary'}; assert set(d['summary'])=={'ok','info','warn','skip'}; assert all(set(i)=={'id','title','status','detail','advice','needsAdmin','fixId','security'} for i in d['items'])"; then ok "json parses (python3), exact keys"; else bad "json parse" invalid valid; fi
fi
red=$(whole --json - --redact --work-root /home/builder7/lq); red=${red%rc=*}
lacks "$red" "builder7" "redact: no user name"; lacks "$red" "testbox7" "redact: no host name"
contains "$red" '"host": {"hostname": "<redacted>", "user": "<redacted>", "os": "Testix on <redacted>", "arch": "x86_64"},' "redact: hostname and user are <redacted> (as in the ps1), free text redacted"
contains "$red" '"workRoot": "<redacted>/lq"' "redact: the work root hides the home folder"
l1d=$(REDACT=1; R_USER=PC; R_HOST=x; R_HOME=/nonexistent; ITEMS=""; add_item t T INFO "detail on PC" inotify.low false "" false; item_field t 4)
l1a=$(REDACT=1; R_USER=PC; R_HOST=x; R_HOME=/nonexistent; ITEMS=""; add_item t T INFO "detail on PC" inotify.low false "" false; item_field t 5)
eq "$l1d" "detail on <redacted>" "L1: --redact rewrites the detail"
eq "$l1a" "$(tadvice inotify.low)" "L1: --redact never rewrites the fixed advice text (it says 'at the PC')"
long=$(printf '%0200d' 0)
l8=$(F_OSNAME="Os $long"; F_ARCH=x86_64; F_OS=Linux; REDACT=0; WORK_ROOT=""; HOURS=""; ITEMS=""; render_json | sed -n 's/.*"os": "\([^"]*\)".*/\1/p')
eq "${#l8}" 128 "L8: host.os is cut to 128 characters"
jf=${TMPDIR:-/tmp}/lanq-tune-out.$$.json; whole --json "$jf" >/dev/null; eq "$(head -n 1 "$jf" 2>/dev/null)" "{" "--json PATH writes the file"; rm -f "$jf"
rm -rf "$FAKE"

echo "arguments and real runs (read-only)"
run_real() { LANQ_MAKEREADY_TUNE_LIB=0 sh "$tune" "$@" </dev/null >/dev/null 2>&1; echo $?; }
eq "$(run_real --hours 7-9)" 2 "bad --hours: exit 2"
eq "$(run_real --work-root srv/lq)" 2 "relative --work-root: exit 2"
eq "$(run_real --work-root /srv/../etc)" 2 "--work-root with ..: exit 2"
eq "$(run_real --bogus)" 2 "unknown argument: exit 2"
eq "$(run_real --json)" 2 "--json without a path: exit 2"
eq "$(run_real --help)" 0 "--help: exit 0"
eq "$(LANQ_MAKEREADY_TUNE_LIB=1 sh "$tune" >/dev/null 2>&1; echo $?)" 2 "LANQ_MAKEREADY_TUNE_LIB=1 on a direct run: exit 2"
t0=$(date +%s); so=$(LANQ_MAKEREADY_TUNE_LIB=0 sh -s -- --json - --redact --hours 00:00-07:00 --work-root /srv/lq < "$tune" 2>/dev/null); rc=$?; t1=$(date +%s)
eq "$rc" 0 "real run, sh -s -- --json - --redact: exit 0"
eq "$(printf '%s' "$so" | head -c 1)" "{" "real run: stdout is only JSON"
contains "$so" '"schema": "lanq-makeready-tune/v1"' "real run: schema"
eq "$([ $((t1 - t0)) -le 95 ] && echo ok)" ok "real run took $((t1 - t0)) s (deadline 90 s)"
h=$(hostname 2>/dev/null); if [ ${#h} -ge 2 ] && printf '%s' "$so" | grep -q "[^A-Za-z0-9]${h}[^A-Za-z0-9]"; then bad "real run: hostname redacted" leaked hidden; else ok "real run: hostname not in redacted JSON"; fi
if command -v python3 >/dev/null 2>&1; then if printf '%s' "$so" | python3 -c "import json,sys; json.load(sys.stdin)"; then ok "real run: JSON parses"; else bad "real run JSON" invalid valid; fi; fi
hu=$(LANQ_MAKEREADY_TUNE_LIB=0 sh "$tune" </dev/null 2>&1); rc=$?
eq "$rc" 0 "real run, human: exit 0"; contains "$hu" "read-only" "real run: says read-only"

echo "read-only guard (command allow-list; a test-time tripwire, not a sandbox)"
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
    /^[ \t]*#/ || /^EOF$/ { next }
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
allowed=" printf echo awk sed tr cut head wc grep cat command id uname hostname sw_vers df du date sleep kill wait timeout sh exec cd exit return read test type shift sort true false break continue set systemctl smartctl fi done esac then else elif do in while for if case until [ ]] "
forbidden=" sudo su doas pkexec chmod chown ln cp mv rm mkdir mktemp touch tee curl wget nc ssh scp dd eval bash source apt apt-get dnf yum apk mount sysctl install "
tune_guard() { # FILE -> one line per violation
  _code=$(awk '/^# BEGIN ADVICE$/ {skip=1} !skip {print} /^# END ADVICE$/ {skip=0}' "$1")
  _fns=$(grep -E '^[a-z_0-9]+\(\)' "$1" | sed 's/().*//')
  for _w in $(printf '%s\n' "$_code" | cmd_words); do
    case "$allowed" in *" $_w "*) continue ;; esac
    case " $(echo $_fns) " in *" $_w "*) continue ;; esac
    echo "unknown command word: $_w"
  done
  for _w in $(printf '%s\n' "$_code" | cmd_words); do case "$forbidden" in *" $_w "*) echo "forbidden command word: $_w" ;; esac; done
  # the only sh -c body is run_t's
  printf '%s\n' "$_code" | grep -o "sh -c '[^']*'" | grep -vxF "sh -c 'cd / || exit 1; exec \"\$@\"'" | sed 's/^/other sh -c body: /'
  printf '%s\n' "$_code" | grep -nE 'sh -c "|bash -c' | sed 's/^/double-quoted or bash -c body: /'
  printf '%s\n' "$_code" | grep -nE '(^|[^A-Za-z_])sudo([^A-Za-z_]|$)|sed[[:space:]]+(-[A-Za-z]*i|--in-place)|find[[:space:]]|system[[:space:]]*\(|getline|`|(^|[^A-Za-z_])eval([^A-Za-z_]|$)' | sed 's/^/raw: /'
  printf '%s\n' "$_code" | grep -vE '^[[:space:]]*#' | grep 'awk' | awk -F"'" '{ for (i = 2; i <= NF; i += 2) { p = $i; gsub(/"[^"]*"/, "", p); if (length($i) > 1 && p ~ /[>|]|system|getline/) { print "awk program writes, pipes or runs: " $0; next } } }'
  printf '%s\n' "$_code" | grep -vE '^[[:space:]]*#' | grep -E "sed[^|;]*(/[gpIiM0-9]*[we]([[:space:]};']|\$)|[;{][[:space:]]*[we][[:space:]]|'[0-9\$,]*[we][[:space:]])" | sed 's/^/sed write or execute: /'
  # systemctl: only is-enabled and is-active; smartctl: only the health check of a standby-safe read
  printf '%s\n' "$_code" | grep -vE '^[[:space:]]*#' | grep -oE 'systemctl [a-z-]+' | grep -vxE 'systemctl (is-enabled|is-active|show)' | sed 's/^/systemctl other than is-enabled, is-active or show: /'
  # every command run through run_t: one of these reads, exactly
  printf '%s\n' "$_code" | grep -vE '^[[:space:]]*#' | grep -oE 'run_t [0-9]+ [^;|&)]*' | grep -vxF \
    -e 'run_t 10 du -sk "$1" 2>/dev/null ' -e 'run_t 5 systemctl is-enabled "$1" 2>/dev/null ' -e 'run_t 5 systemctl is-active "$1" 2>/dev/null ' \
    -e 'run_t 5 systemd-detect-virt -c -q 2>/dev/null' -e 'run_t 5 loginctl list-sessions --no-legend 2>/dev/null ' \
    -e 'run_t 5 loginctl show-session "$_sid" -p Type 2>/dev/null' -e 'run_t 10 smartctl -H -n standby "/dev/$_d" 2>/dev/null' \
    -e 'run_t 5 df -Pk "$1" 2>/dev/null ' | sed 's/^/a command run through run_t that is not an allowed read: /'
  printf '%s\n' "$_code" | grep -vE '^[[:space:]]*#' | grep -oE 'smartctl -[^;|&)]*' | grep -vxE 'smartctl -H -n standby "/dev/\$_d" 2>/dev/null' | sed 's/^/smartctl other than -H -n standby: /'
  printf '%s\n' "$_code" | awk "$scan_awk"'
    /^[ \t]*#/ { next }
    { raw = $0
      gsub(/2>\/dev\/null|>\/dev\/null|<\/dev\/null|2>&1|>&2|> "\$JSON_PATH"/, "", raw)
      if (scan(raw) ~ />/) print "redirection: " $0 }'
}
eq "$(grep -c '^# BEGIN ADVICE$' "$tune"):$(grep -c '^# END ADVICE$' "$tune")" "1:1" "one advice table"
eq "$(tune_guard "$tune")" "" "tune script passes the guard"
mut_dir=${TMPDIR:-/tmp}/lanq-tunemut.$$; mkdir -p "$mut_dir"
mutant() { cp "$tune" "$mut_dir/m.sh"; printf '%s\n' "$2" >> "$mut_dir/m.sh"; if [ -n "$(tune_guard "$mut_dir/m.sh")" ]; then ok "guard catches: $1"; else bad "guard catches: $1" "not flagged" flagged; fi; }
mutant "sysctl -w" 'x() { sysctl -w fs.inotify.max_user_instances=1024; }'
mutant "systemctl disable" 'x() { systemctl disable --now cups.service; }'
mutant "systemctl via run_t" 'x() { run_t 5 systemctl stop cups.service; }'
mutant "smartctl self-test" 'x() { run_t 10 smartctl -t short /dev/sda; }'
mutant "redirect to a file" 'x() { echo 1 > /proc/sys/vm/swappiness; }'
mutant "rm" 'x() { rm -rf /var/cache/apt/archives; }'
mutant "tee" 'x() { echo 1 | tee /etc/x; }'
mutant "eval" 'x() { eval "$1"; }'
mutant "sh -c body" "x() { sh -c 'apt clean'; }"
mutant "awk system()" "x() { awk 'BEGIN { system(\"id\") }'; }"
mutant "sed -i" 'x() { sed -i s/a/b/ /etc/x; }'
mutant "unknown command" 'x() { journalctl --vacuum-size=1G; }'
mutant "backtick" 'x() { y=`id`; }'
mutant "L7: systemctl edit" 'x() { systemctl edit cups.service; }'
mutant "L7: run_t loginctl terminate" 'x() { run_t 5 loginctl terminate-session 3; }'
mutant "L7: run_t of another command" 'x() { run_t 5 journalctl --vacuum-size=1G; }'
mutant "L7: run_t du with other options" 'x() { run_t 10 du -sk --exclude=x "$1"; }'
rm -rf "$mut_dir"

echo "size, bytes, version"
lines=$(wc -l < "$tune" | tr -d ' ')
if [ "$lines" -le 800 ]; then ok "tune script is $lines lines (max 800)"; else bad "tune line count" "$lines" "<=800"; fi
if LC_ALL=C grep -q '[^ -~]' "$tune"; then bad "tune script is plain ASCII" non-ascii ascii; else ok "tune script is plain ASCII"; fi
eq "$(grep -c "^TOOL_VERSION=$(sed -n 's/^TOOL_VERSION=//p' "$root/lanq-makeready.sh")\$" "$tune")" 1 "tune script reports the scanner's version"
eq "$(grep -c 'lanq-makeready-tune' "$root/lanq-makeready.sh")" 0 "the scanner does not mention the tune script (unchanged)"

echo
echo "tune sh tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
