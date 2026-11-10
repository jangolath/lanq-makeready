#!/bin/sh
# shellcheck disable=SC2034,SC2153,SC2016,SC2329,SC2116,SC2086
# POSIX test runner: sources lanq-makeready.sh as a library (LANQ_MAKEREADY_LIB=1) and feeds fixtures.
# Usage: sh tests/run.sh        (from anywhere)
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
pass=0; fail=0

LANQ_MAKEREADY_LIB=1
export LANQ_MAKEREADY_LIB
__lanq_makeready_test_harness() { :; } # the script refuses LANQ_MAKEREADY_LIB=1 unless this exists
# shellcheck disable=SC1091
. "$root/lanq-makeready.sh"

ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1 : expected '$3' got '$2'"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "$1" "$2"; fi; }
contains() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3" "$1" "*$2*" ;; esac; }

fixture_ubuntu() { # Ubuntu 24.04, 16 GB, SSD, everything good
  F_OS=Linux; F_OSNAME="Ubuntu 24.04.1 LTS"; F_OSVER=""; F_ARCH=x86_64; F_HOST=box; F_USER=builder
  F_LIBC=glibc; F_LIBCVER=2.39; F_RAMMB=16000; F_FREERAMMB=9000; F_CORES=4; F_CPU="Test CPU"; F_AVX2=yes
  F_SYSFREEGB=200; F_WORKFREEGB=200; F_DISK=SSD; F_SSHD=running; F_AUTHKEYS=yes
  F_GIT="git version 2.43.0"; F_TARKIND=gnu; F_GZIP=yes; F_DOTNET="8 10"; F_DOCKER_CLI=yes; F_DOCKER_SERVER=27.0
  F_CGROUP=v2; F_SLEEP=masked; F_SLEEP_DETAIL=""; F_REBOOT=no; F_STARTUP=5; F_TEMP="cache 100 MB"; F_TEMP_BIGMB=100; F_DOCKER_REMOTE=no
  F_T_node=v22.1.0; F_T_python=""; F_T_java=""; F_T_go=""; F_T_rustc=""
  F_OSID=ubuntu; F_OSVERID=24.04; F_NOW_YM=202611; F_SSHD_PW=no; F_SWAPMB=2048
  F_WOL_IF=enp1s0; F_WOL_MAC=10:20:30:aa:bb:cc; F_WOL_WIFI=no; F_WOL_SUP=pumbg; F_WOL_ON=g
  F_DOTNET_DIR=""; F_DOTNET_OFFPATH=no; F_DOTNET_OPEN=no; F_AUTHVIA=default
}
run() { eval_checks; eval_verdicts; eval_machine "${1:-}" 0; eval_summary; }
step_ids() { printf '%s' "$S_STEPS" | while IFS="$SEP" read -r _i _; do printf '%s ' "$_i"; done; }

echo "ubuntu 24.04 good"
fixture_ubuntu; run
eq "$V_GIT" OK "ubuntu: worker_git OK"
eq "$V_ARCHIVE" OK "ubuntu: worker_archive OK"
eq "$V_DOTNET" OK "ubuntu: dotnet10 OK"
eq "$V_DOCKER" OK "ubuntu: docker OK"
eq "$V_OVERNIGHT" OK "ubuntu: overnight OK"
eq "$M_TRANSFER" git "ubuntu: transfer git"
eq "$M_CAPS" "dotnet, node, docker, git, linux" "ubuntu: capabilities (git detected too)"

echo "glibc 2.26 -> .NET FAIL"
fixture_ubuntu; F_LIBCVER=2.26; run
eq "$V_DOTNET" FAIL "glibc 2.26: dotnet10 FAIL"
contains "$(advice dotnet.glibc)" "glibc 2.27" "glibc 2.26: advice names the minimum"
fixture_ubuntu; F_LIBCVER=2.27; run
eq "$V_DOTNET" OK "glibc 2.27 (the minimum): dotnet10 OK"

echo "Alpine busybox tar -> archive FAIL"
fixture_ubuntu; F_OSNAME="Alpine Linux v3.21"; F_LIBC=musl; F_LIBCVER=1.2.5; F_TARKIND=busybox; F_GZIP=yes; F_GIT=""; run
eq "$V_ARCHIVE" FAIL "alpine: worker_archive FAIL (busybox tar)"
eq "$V_GIT" FAIL "alpine without git: worker_git FAIL"
eq "$V_DOTNET" OK "alpine musl 1.2.5: dotnet10 OK"
eq "$(classify_tar 'tar: unrecognized option: version
BusyBox v1.37.0 (2024-10-17) multi-call binary.')" busybox "classify_tar: busybox"
eq "$(classify_tar 'tar (GNU tar) 1.35')" gnu "classify_tar: GNU"
eq "$(classify_tar 'bsdtar 3.7.2 - libarchive 3.7.2')" bsd "classify_tar: bsdtar"
fixture_ubuntu; F_LIBC=musl; F_LIBCVER=1.2.2; run
eq "$V_DOTNET" FAIL "musl 1.2.2: dotnet10 FAIL"

echo "32-bit x86 Linux -> .NET FAIL"
fixture_ubuntu; F_ARCH=i686; run
eq "$V_DOTNET" FAIL "i686: dotnet10 FAIL"
eq "$(st os.arch)" FAIL "i686: os.arch FAIL"

echo "no git, GNU tar -> archive transfer"
fixture_ubuntu; F_GIT=""; run
eq "$V_GIT" FAIL "no git: worker_git FAIL"
eq "$V_ARCHIVE" OK "no git: worker_archive OK"
eq "$M_TRANSFER" archive "no git: suggested transfer archive"
contains "$(render_snippet)" "transfer: archive" "no git: snippet says transfer: archive"

echo "other verdicts"
fixture_ubuntu; F_SSHD=notinstalled; run
eq "$V_GIT" FAIL "no sshd: worker_git FAIL"
fixture_ubuntu; F_RAMMB=3000; F_DISK=HDD; F_DOCKER_CLI=no; F_DOCKER_SERVER=""; run
eq "$(st ram)" WARN "3 GB: ram WARN"
eq "$(st disk)" WARN "HDD: disk WARN"
eq "$V_DOCKER" WARN "3 GB: docker WARN"
fixture_ubuntu; F_SYSFREEGB=5; run
eq "$(st disk)" FAIL "5 GB free: disk FAIL"
fixture_ubuntu; F_SLEEP=sleeps; F_REBOOT=yes; run
eq "$V_OVERNIGHT" WARN "may sleep + pending reboot: overnight WARN"
fixture_ubuntu; F_OS=Darwin; F_OSVER=14; run
eq "$V_DOTNET" WARN "macOS 14: dotnet10 WARN"
contains "$(render_snippet)" "windows|linux only" "macOS: snippet is a note, not an entry"
eq "$V_GIT:$V_ARCHIVE" "FAIL:FAIL" "macOS: both worker verdicts FAIL (LanQueue rejects macOS workers)"

echo "verdict line and next steps"
fixture_ubuntu; run
eq "$S_TEXT" READY "all good: READY"
eq "$S_STEPS" "" "all good: no next steps"
fixture_ubuntu; F_REBOOT=yes; F_SSHD_PW=yes; run
eq "$S_TEXT" "READY WITH WARNINGS (2)" "two warnings: READY WITH WARNINGS (2)"
eq "$S_VERDICT" READY_WITH_WARNINGS "verdict code READY_WITH_WARNINGS"
fixture_ubuntu; F_SSHD=notinstalled; F_REBOOT=yes; run
eq "$S_TEXT" "NOT READY (1 blocker)" "no sshd: NOT READY (1 blocker)"
eq "$(step_ids)" "ssh.server reboot.pending " "blocker is step 1, warnings after"
contains "$(render_steps)" " 1. [MUST FIX] SSH server: no sshd found" "step 1 is marked MUST FIX"
contains "$(render_steps)" "do (needs root): Install and start an SSH server" "step names the command and that it needs root"
contains "$(render_steps)" " 2. [should fix] Pending reboot" "warning step is should fix"
fixture_ubuntu; F_SSHD=notinstalled; F_SYSFREEGB=5; run
eq "$S_TEXT" "NOT READY (2 blockers)" "two FAILs: NOT READY (2 blockers)"
fixture_ubuntu; F_GIT=""; F_TARKIND=none; run
eq "$S_TEXT" "NOT READY (2 blockers)" "no git and no tar: both become blockers"
eq "$(step_ids)" "git tar " "no transfer mode: git and tar steps"
fixture_ubuntu; F_GIT=""; F_SSHD=notinstalled; run
eq "$(step_ids)" "ssh.server git " "no sshd, no git but tar ok: git stays a warning after the blocker"
eq "$S_BLOCKERS" 1 "no sshd, no git but tar ok: 1 blocker"
fixture_ubuntu; F_ARCH=i686; F_DOCKER_CLI=no; F_DOCKER_SERVER=""; run
eq "$S_VERDICT" READY_WITH_WARNINGS "a .NET/Docker FAIL does not block the worker: READY WITH WARNINGS"
fixture_ubuntu; F_SSHD=notinstalled; run
out=$(render_human)
eq "$(printf '%s\n' "$out" | sed -n 2p)" "VERDICT: NOT READY (1 blocker)" "verdict is the second line"
eq "$(printf '%s\n' "$out" | tail -n 1)" "VERDICT: NOT READY (1 blocker)" "verdict is the last line"
js=$(render_json 0)
contains "$js" '"summary": {"verdict": "NOT_READY", "text": "NOT READY (1 blocker)", "blockers": 1, "warnings": 0' "JSON summary"
contains "$js" '"step": 1, "id": "ssh.server", "title": "SSH server", "status": "FAIL", "blocker": true' "JSON next step"
contains "$js" '"adminToFix": true' "JSON step says it needs admin"
eq "$(advice_admin ssh.nokeys)" false "ssh.nokeys needs no root"

echo "Linux: distro end of life"
eq "$(distro_eol ubuntu 20.04)" 202505 "Ubuntu 20.04 LTS: supported through 2025-05"
eq "$(distro_eol ubuntu 24.04)" 202905 "Ubuntu 24.04 LTS: 2029-05"
eq "$(distro_eol ubuntu 25.10)" 202607 "Ubuntu 25.10 interim: 9 months"
eq "$(distro_eol debian 11)" 202608 "Debian 11: LTS to 2026-08"
eq "$(distro_eol debian 12)" 202806 "Debian 12: LTS to 2028-06"
eq "$(distro_eol alpine 3.19.1)" 202510 "Alpine 3.19: EOL 2025-11-01, last month 2025-10"
eq "$(distro_eol alpine 3.20.3)" 202603 "Alpine 3.20: EOL 2026-04-01, last month 2026-03"
eq "$(distro_eol alpine 3.21.2)" 202610 "Alpine 3.21: EOL 2026-11-01, last month 2026-10"
eq "$(distro_eol alpine 3.22.0)" 202704 "Alpine 3.22: EOL 2027-05-01, last month 2027-04"
eq "$(distro_eol alpine 3.23.0)" 202710 "Alpine 3.23: EOL 2027-11-01, last month 2027-10"
eq "$(distro_eol alpine 3.16.0)" old "Alpine 3.16: older than the table"
eq "$(distro_eol fedora 41)" 202512 "Fedora 41: 2025-12-15"
eq "$(distro_eol ubuntu 16.04)" 202104 "Ubuntu 16.04: 2021-04"
eq "$(distro_eol ubuntu 14.04)" old "Ubuntu 14.04: older than the table"
eq "$(distro_eol debian 9)" old "Debian 9: older than the table"
fixture_ubuntu; F_OSID=alpine; F_OSVERID=3.21.2; F_NOW_YM=202611; run
eq "$(st os.version)" WARN "Alpine 3.21 on 2026-11-09 is end of life"
fixture_ubuntu; F_OSID=alpine; F_OSVERID=3.21.2; F_NOW_YM=202610; run
eq "$(st os.version)" OK "Alpine 3.21 in 2026-10 is still supported"
fixture_ubuntu; F_OSID=debian; F_OSVERID=8; run
contains "$(printf '%s' "$CHECKS" | grep '^os.version')" "end of life (older than this table)" "catch-all bucket: no invented date"
eq "$(distro_eol arch "")" "" "unknown distro: no date"
fixture_ubuntu; F_OSVERID=20.04; F_OSNAME="Ubuntu 20.04.6 LTS"; run
eq "$(st os.version)" WARN "Ubuntu 20.04 in 2026-11: os.version WARN"
contains "$(printf '%s' "$CHECKS" | grep '^os.version')" "standard security support ended after 2025-05" "EOL detail has the last month"
contains "$(printf '%s' "$CHECKS" | grep '^os.version')" "Ubuntu Pro/ESM may still cover it" "EOL advice is honest about ESM"
contains "$(printf '%s' "$CHECKS" | grep '^os.version')" "do-release-upgrade" "EOL advice has the command"
fixture_ubuntu; F_OSID=debian; F_OSVERID=11; run
eq "$(st os.version)" WARN "Debian 11 in 2026-11: WARN"
fixture_ubuntu; F_OSID=debian; F_OSVERID=12; run
eq "$(st os.version)" OK "Debian 12: OK"

echo "Linux: sshd PasswordAuthentication"
eq "$(printf '# x\nPasswordAuthentication no\nPasswordAuthentication yes\n' | sshd_pw_auth)" no "first value wins"
eq "$(printf '#PasswordAuthentication no\nUsePAM yes\n' | sshd_pw_auth)" unset "commented out: unset (default yes)"
eq "$(printf 'Match User x\nPasswordAuthentication no\n' | sshd_pw_auth)" unset "Match blocks are not applied globally"
eq "$(printf '  passwordauthentication=YES\n' | sshd_pw_auth)" yes "case and = form"
# sshd_pw_auth must read to the end: if it exits early, a writer that ignores SIGPIPE (as on CI runners) gets EPIPE on
# every remaining line and dash prints "printf: I/O error" for each. 20000 lines exceed any pipe buffer.
_pw=$( (trap '' PIPE; { printf 'PasswordAuthentication no\n'; i=0; while [ "$i" -lt 20000 ]; do printf '%s\n' "# filler $i"; i=$((i + 1)); done; } | sshd_pw_auth) 2>"${TMPDIR:-/tmp}/lanq-pw.$$")
eq "$_pw" no "a long config after the first value still gives the first value"
eq "$(wc -l < "${TMPDIR:-/tmp}/lanq-pw.$$" | tr -d ' ')" 0 "reads the whole config, so a writer ignoring SIGPIPE prints no I/O errors"
rm -f "${TMPDIR:-/tmp}/lanq-pw.$$"; unset _pw
cfg=${TMPDIR:-/tmp}/lanq-sshd.$$; mkdir -p "$cfg/d"
printf 'Include %s/d/*.conf\nPasswordAuthentication yes\n' "$cfg" > "$cfg/main"; printf 'PasswordAuthentication no\n' > "$cfg/d/10-keys.conf"
eq "$(sshd_conf_lines "$cfg/main" 0 | sshd_pw_auth)" no "Include drop-in read first, first value wins"
rm -rf "$cfg"
fixture_ubuntu; F_SSHD_PW="unset"; run
eq "$(st ssh.password)" WARN "password auth by default: WARN (security note)"
contains "$(printf '%s' "$CHECKS" | grep '^ssh.password')" "PasswordAuthentication no" "advice says how"
eq "$V_GIT" OK "password note does not change the worker verdict"
fixture_ubuntu; F_SSHD_PW=unknown; run
eq "$(st ssh.password)" SKIP "unreadable config: SKIP"

echo "Linux: sleep targets"
fixture_ubuntu; F_SLEEP=unmasked; F_SLEEP_DETAIL="logind idle and lid"; run
eq "$(st power.sleep)" OK "sleep targets not masked, no auto-suspend configured: OK with a note"
contains "$(printf '%s' "$CHECKS" | grep '^power.sleep')" "no automatic suspend was found (checked: logind idle and lid)" "OK row says what was checked"
if printf '%s' "$CHECKS" | grep '^power.sleep' | grep -q GNOME; then bad "OK row claims GNOME" yes no; else ok "OK row does not claim GNOME was checked when it was not"; fi
eq "$(classify_sleep "" "" yes no)" "desktop|" "display manager active, no session bus (SSH): desktop"
eq "$(classify_sleep "" "" no no)" "unmasked|logind idle and lid" "no desktop: unmasked, logind only"
eq "$(classify_sleep "" "'nothing'" yes yes)" "unmasked|logind idle and lid, this user's GNOME setting" "session bus, GNOME never suspends: unmasked, GNOME checked"
eq "$(classify_sleep "" "'suspend'" yes yes)" "sleeps|GNOME idle action 'suspend' on AC (this user)" "session bus, GNOME suspends: sleeps"
eq "$(classify_sleep "logind IdleAction=suspend" "" yes no)" "sleeps|logind IdleAction=suspend" "logind finding wins"
fixture_ubuntu; F_SLEEP=desktop; F_SLEEP_DETAIL=""; run
eq "$(st power.sleep)" WARN "desktop over SSH: WARN"
contains "$(printf '%s' "$CHECKS" | grep '^power.sleep')" "GNOME and GDM suspend on AC after about 15-20 minutes by default" "desktop WARN explains the default"
contains "$(printf '%s' "$CHECKS" | grep '^power.sleep')" "sleep-inactive-ac-type 'nothing'" "desktop advice prints the gsettings command"
contains "$(printf '%s' "$CHECKS" | grep '^power.sleep')" "systemctl mask sleep.target" "desktop advice prints the mask command"
fixture_ubuntu; F_SLEEP=sleeps; F_SLEEP_DETAIL="logind IdleAction=suspend"; run
eq "$(st power.sleep)" WARN "auto-suspend configured: WARN"
contains "$(printf '%s' "$CHECKS" | grep '^power.sleep')" "sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target" "mask command printed"
eq "$(printf '[Login]\n#IdleAction=ignore\nIdleAction=suspend\n' | logind_values)" "suspend - -" "logind: IdleAction read, comments skipped"
eq "$(printf '[Login]\nIdleAction=suspend\n[Login]\nIdleAction=ignore\nHandleLidSwitch=lock\n' | logind_values)" "ignore lock -" "logind: later drop-in wins"
eq "$(printf 'HandleLidSwitchExternalPower = ignore\n' | logind_values)" "- - ignore" "logind: external-power lid action"
eq "$(logind_auto_suspend suspend - - no)" "logind IdleAction=suspend" "idle suspend detected"
eq "$(logind_auto_suspend ignore - - no)" "" "desktop, idle ignore: no auto-suspend"
eq "$(logind_auto_suspend - - - yes)" "laptop lid: HandleLidSwitch default (suspend)" "laptop with default lid action: suspends"
eq "$(logind_auto_suspend - ignore - yes)" "" "laptop, lid ignored: no auto-suspend"
eq "$(logind_auto_suspend - suspend ignore yes)" "" "laptop on AC, external-power lid ignored: no auto-suspend"
eq "$(logind_auto_suspend - - - no)" "" "desktop without lid: lid setting irrelevant"

echo "Linux: Wake-on-LAN"
nics='lo 772 no no unknown 00:00:00:00:00:00
docker0 1 no no down 10:20:30:00:00:01
wlp2s0 1 yes yes up 10:20:30:00:00:02
enp1s0 1 yes no up 10:20:30:00:00:03
enp3s0 1 yes no down 10:20:30:00:00:04'
eq "$(printf '%s\n' "$nics" | pick_wired)" "enp1s0 10:20:30:00:00:03" "pick_wired: physical, wired, up first"
eq "$(printf 'wlp2s0 1 yes yes up 10:20:30:00:00:02\n' | pick_wired)" "" "pick_wired: Wi-Fi only -> none"
fixture_ubuntu; run
eq "$(st wol)" OK "Wake-on: g -> OK"
contains "$(render_snippet)" '      mac: "10:20:30:aa:bb:cc"' "snippet: wake mac when ready"
contains "$(render_json 0)" '"wake": {"mac": "10:20:30:aa:bb:cc"}' "JSON: wake mac when ready"
fixture_ubuntu; F_WOL_ON=d; run
eq "$(st wol)" WARN "Wake-on: d -> WARN"
contains "$(printf '%s' "$CHECKS" | grep '^wol')" "sudo ethtool -s enp1s0 wol g" "advice names the interface"
contains "$(render_snippet)" '    # wake:' "snippet: wake commented out when not ready"
if render_snippet | grep -q '^    wake:'; then bad "wake active when not ready" yes no; else ok "snippet: no active wake: when not ready"; fi
fixture_ubuntu; F_WOL_ON=d; F_WOL_SUP=d; run
contains "$(printf '%s' "$CHECKS" | grep '^wol')" "does not support" "no g in Supports: not supported"
fixture_ubuntu; F_WOL_ON=""; F_WOL_SUP=""; run
eq "$(st wol)" SKIP "unreadable without root: SKIP"
contains "$(printf '%s' "$CHECKS" | grep '^wol')" "as root: ethtool enp1s0 | grep Wake-on" "says how to check"
fixture_ubuntu; F_WOL_IF=""; F_WOL_MAC=""; F_WOL_WIFI=yes; run
eq "$(st wol)" WARN "Wi-Fi only: WARN"
contains "$(render_snippet)" "# wake: not suggested" "snippet: no wake block without a wired NIC"
red=$( fixture_ubuntu; redact_facts; run; render_snippet; render_json 1 )
if printf '%s' "$red" | grep -q '10:20:30:aa:bb:cc'; then bad "MAC redacted" leaked hidden; else ok "redaction hides the MAC"; fi
contains "$red" '    #   mac: "<mac>"' "redacted snippet: <mac> placeholder is commented out"
contains "$red" "placeholder" "redacted snippet says the MAC is a placeholder"
if printf '%s\n' "$red" | grep -q '^    wake:'; then bad "redacted wake active" yes no; else ok "redacted snippet: no active wake: with a placeholder MAC"; fi

echo "low RAM and swap"
fixture_ubuntu; F_RAMMB=4096; F_SWAPMB=0; run
eq "$(st swap)" WARN "4 GB, no swap: WARN"
contains "$(printf '%s' "$CHECKS" | grep '^swap')" "mkswap" "swap advice has the commands"
fixture_ubuntu; F_SWAPMB=0; run
eq "$(st swap)" OK "16 GB without swap: OK"
fixture_ubuntu; F_RAMMB=3072; F_CORES=4; run
contains "$(render_snippet)" "max_jobs: 1" "3 GB: max_jobs 1"
contains "$(render_snippet)" "min_free_mem_gb: 1.5" "3 GB: min_free_mem_gb 1.5"
contains "$(render_snippet)" "# Low-RAM PC: keep max_jobs: 1" "3 GB: low-RAM note"
contains "$(render_snippet)" '#   NODE_OPTIONS: "--max-old-space-size=1024"' "3 GB: env caps offered (commented)"
contains "$(render_snippet)" "add -m:1 to dotnet build" "3 GB: suggests -m:1, not an env var"
if grep -q MSBUILDNODECOUNT "$root/lanq-makeready.sh"; then bad "no MSBUILDNODECOUNT" found absent; else ok "MSBUILDNODECOUNT is never suggested"; fi
contains "$(printf '%s' "$CHECKS" | grep '^ram')" "min_free_mem_gb" "ram advice names the hold setting"
fixture_ubuntu; F_SYSFREEGB=15; run
contains "$(printf '%s' "$CHECKS" | grep '^disk')" "15 GB free" "low disk: says the free space"
contains "$(printf '%s' "$CHECKS" | grep '^disk')" "recommended: at least 20 GB free" "low disk: says the recommended minimum"

echo "pool sizing tiers (the thresholds LanQueue 0.5.1+ lanq health uses)"
eq "$(suggest_jobs 24 8)" 6 "24-31 GB counts as the top band"
eq "$(suggest_jobs 4 4)" 1 "4 GB: max_jobs 1"
eq "$(suggest_jobs 8 8)" 2 "8 GB: max_jobs 2"
eq "$(suggest_jobs 8 1)" 1 "8 GB, 1 CPU: capped by cores"
eq "$(suggest_jobs 16 4)" 3 "16 GB, 4 CPUs: 3"
eq "$(suggest_jobs 16 8)" 4 "16 GB, 8 CPUs: 4"
eq "$(suggest_jobs 16 2)" 2 "16 GB, 2 CPUs: capped by cores"
eq "$(suggest_jobs 32 12)" 6 "32 GB, 12 CPUs: 6"
eq "$(suggest_jobs 64 32)" 8 "64 GB, 32 CPUs: 8"
eq "$(suggest_jobs 32 4)" 4 "32 GB, 4 CPUs: capped by cores"
eq "$(suggest_minmem 4)" 1.5 "under 6 GB: min_free_mem_gb 1.5"
eq "$(suggest_minmem 16)" 2 "6 GB+: min_free_mem_gb 2"
eq "$(suited_tier 4 4)" light "4 GB: light"
eq "$(suited_tier 8 8)" medium "8 GB: medium"
eq "$(suited_tier 16 2)" medium "16 GB but 2 CPUs: medium"
eq "$(suited_tier 16 4)" heavy "16 GB + 4 CPUs: heavy"
eq "$(suited_text light no)" "light: lint and unit-test shards" "light text"
eq "$(suited_text medium no)" "medium: test shards and builds" "medium text"
eq "$(suited_text heavy yes)" "heavy: full suites and large builds + container builds" "heavy + docker text"
fixture_ubuntu; F_RAMMB=16384; F_CORES=8; run
contains "$(render_human)" "Suited for: heavy: full suites and large builds + container builds" "human report: suited-for line"
contains "$(render_json 0)" '"suitedFor": {"tier": "heavy", "containers": true' "JSON: suitedFor"
contains "$(render_snippet)" "max_jobs: 4" "snippet: 16 GB / 8 CPUs -> max_jobs 4"
contains "$(render_json 0)" '"min_free_mem_gb": 2' "JSON: min_free_mem_gb"

echo "snippet keys are valid LanQueue 0.5 keys"
fixture_ubuntu; run
keys=$(render_snippet | sed -n 's/^[ -]*\([a-z_]*\):.*/\1/p' | sort -u | tr '\n' ' ')
eq "$keys" "capabilities mac machines max_jobs min_free_mem_gb name os ssh transfer wake work_root " "only known keys (uncommented)"
contains "$(render_snippet)" '# allowed_hours: "22:00-07:00"' "allowed_hours is a commented placeholder without --hours"

echo "helpers"
fixture_ubuntu; run "00:00-07:00"
contains "$(render_snippet)" 'allowed_hours: "00:00-07:00"' "snippet: allowed_hours quoted"
if valid_hours 00:00-07:00; then ok "hours: valid"; else bad "hours: valid" no yes; fi
if valid_hours 22:00-07:00; then ok "hours: wraps midnight"; else bad "hours: wrap" no yes; fi
if valid_hours 07:00-07:00; then bad "hours: equal rejected" accepted rejected; else ok "hours: equal start/end rejected"; fi
if valid_hours 7-8; then bad "hours: bad format rejected" accepted rejected; else ok "hours: bad format rejected"; fi
if valid_hours 24:00-07:00; then bad "hours: 24:00 rejected" accepted rejected; else ok "hours: 24:00 rejected"; fi
eq "$(LANQ_MAKEREADY_LIB=0 sh "$root/lanq-makeready.sh" --hours 07:00-07:00 >/dev/null 2>&1; echo $?)" 2 "equal --hours: exit code 2"
eq "$(LANQ_MAKEREADY_LIB=0 sh "$root/lanq-makeready.sh" --bogus >/dev/null 2>&1; echo $?)" 2 "unknown flag: exit code 2"
eq "$(ver_num 2.35-0ubuntu3)" 2035000 "ver_num strips suffix"

leaks() { printf '%s\n' "$1" | grep -Eq "(^|[^A-Za-z0-9_])$2([^A-Za-z0-9_]|\$)"; }

echo "review fixes: ram, ssh socket, docker remote, dotnet rule, names, redaction, json_esc"
eq "$(ram_installed_mb 3900)" 4096 "4 GB machine (MemTotal 3900 MB) counts as 4 GB installed"
eq "$(ram_installed_mb 2900)" 3072 "2.8 GiB MemTotal is a 3 GiB machine, still below 4 GB"
eq "$(ram_installed_mb 16179)" 16384 "15.8 GiB MemTotal rounds up to 16 GiB"
eq "$(ram_installed_mb 7900)" 8192 "7.7 GiB MemTotal rounds up to 8 GiB"
fixture_ubuntu; F_SSHD=socket; run
eq "$(st ssh.server)" OK "socket-activated sshd: OK"
contains "$(printf '%s' "$CHECKS" | grep '^ssh.server')" "socket-activated" "socket-activated detail"
fixture_ubuntu; F_DOCKER_SERVER=""; F_DOCKER_REMOTE=yes; run
eq "$V_DOCKER" SKIP "remote docker endpoint: SKIP"
if docker_remote "tcp://10.0.0.5:2375" ""; then ok "docker_remote: tcp:// is remote"; else bad "docker_remote tcp" no yes; fi
if docker_remote "ssh://build@host" ""; then ok "docker_remote: ssh:// is remote"; else bad "docker_remote ssh" no yes; fi
if docker_remote "" "staging"; then ok "docker_remote: custom context is remote"; else bad "docker_remote ctx" no yes; fi
if docker_remote "unix:///var/run/docker.sock" "desktop-linux"; then bad "docker_remote local" yes no; else ok "docker_remote: unix socket + desktop-linux is local"; fi
if sdk_ge8 "6 7"; then bad "sdk_ge8 old" yes no; else ok "dotnet capability needs SDK >= 8: 6,7 -> no"; fi
if sdk_ge8 "6 10"; then ok "dotnet capability: 6,10 -> yes"; else bad "sdk_ge8 10" no yes; fi
fixture_ubuntu; F_DOTNET="6"; run
eq "$M_CAPS" "node, docker, git, linux" "SDK 6 only: no dotnet capability"

echo ".NET SDK outside PATH"
fixture_ubuntu; run
if render_snippet | grep -q 'path_prepend\|DOTNET_ROOT'; then bad "SDK on PATH: no path_prepend" present absent; else ok "SDK on PATH: no path_prepend or DOTNET_ROOT"; fi
fixture_ubuntu; F_DOTNET_DIR=/opt/build/dotnet; F_DOTNET_OFFPATH=yes; F_DOTNET="6 10"; run
eq "$V_DOTNET" WARN "SDK off PATH: dotnet10 WARN"
contains "$CHECKS" "the newest is in /opt/build/dotnet, not the dotnet on PATH" "SDK off PATH: detail names the folder"
contains "$(advice dotnet.path)" "path_prepend" "SDK off PATH: advice names path_prepend"
eq "$(advice_admin dotnet.path)" false "SDK off PATH: no root needed"
eq "$V_GIT" OK "SDK off PATH: worker verdict unchanged"
contains "$(render_snippet)" '    path_prepend: ["/opt/build/dotnet"]' "SDK off PATH: snippet path_prepend"
contains "$(render_snippet)" '    env:
      DOTNET_ROOT: "/opt/build/dotnet"' "SDK off PATH: snippet env DOTNET_ROOT"
contains "$(render_json 0)" '"path_prepend": ["/opt/build/dotnet"], "env": {"DOTNET_ROOT": "/opt/build/dotnet"}}' "SDK off PATH: JSON suggestedMachine"
fixture_ubuntu; F_DOTNET_DIR=/opt/build/dotnet; F_DOTNET_OFFPATH=yes; F_RAMMB=3000; run
eq "$(render_snippet | grep -c 'env:')" 1 "low RAM and SDK off PATH: one env: key"
contains "$(render_snippet)" '#   DOTNET_GCHeapHardLimitPercent' "low RAM and SDK off PATH: caps stay as comments"
red=$( fixture_ubuntu; F_DOTNET_DIR=/home/builder/.dotnet; F_DOTNET_OFFPATH=yes; R_HOME=/home/builder; HOME=/home/builder; redact_facts; run; render_json 1 )
contains "$red" '"path_prepend": ["<redacted>/.dotnet"], "env": {"DOTNET_ROOT": "<redacted>/.dotnet"}' "redacted JSON: the SDK folder hides the home folder"
case "$red" in *builder*) bad "redacted JSON: no user name" leaked hidden ;; *) ok "redacted JSON: no user name" ;; esac
echo "sdk_root: real folders"
sd=${TMPDIR:-/tmp}/lanq-sdk.$$
mkdir -p "$sd/a/sdk/9.0.100" "$sd/b/sdk/10.0.102" "$sd/b/sdk/10.0.99" "$sd/c/sdk/11.0.100" "$sd/d/sdk/08.0.1" "$sd/e/sdk/10.0.200-rc.1"
for x in a b c d e; do printf '#!/bin/sh\n' > "$sd/$x/dotnet"; chmod +x "$sd/$x/dotnet"; done
for v in a/sdk/9.0.100 b/sdk/10.0.102 b/sdk/10.0.99 d/sdk/08.0.1 e/sdk/10.0.200-rc.1; do : > "$sd/$v/dotnet.dll"; done
F_DOTNET=""; F_DOTNET_DIR=""; _seen=" "; _bk=0; _end=$(( $(date +%s) + 5 ))
for x in a b c d b/ ""; do sdk_root "${x:+$sd/$x}"; done
eq "$F_DOTNET" "9 10" "sdk_root: majors from SDK folders with dotnet.dll (11 has none, 08 is refused)"
eq "${F_DOTNET_DIR##*/}" b "sdk_root: the newest SDK's folder wins"
sdk_root "$sd/e"
eq "${F_DOTNET_DIR##*/}" b "sdk_root: a preview (10.0.200-rc.1) never counts as the newest"
F_DOTNET=""; F_DOTNET_DIR=""; _seen=" "; _bk=0; _end=$(( $(date +%s) + 5 ))
mkdir -p "$sd/b2/sdk/10.0.102"; printf '#!/bin/sh\n' > "$sd/b2/dotnet"; chmod +x "$sd/b2/dotnet"; : > "$sd/b2/sdk/10.0.102/dotnet.dll"
sdk_root "$sd/b2"; sdk_root "$sd/b"
eq "${F_DOTNET_DIR##*/}" b2 "sdk_root: a tie keeps the earlier folder (the dotnet on PATH is searched first)"
mkdir -p "$sd/q\"x/sdk/12.0.100" "$sd/n
l/sdk/12.0.100" "$sd/z/sdk/11.0.100"
for x in "q\"x" "n
l" z; do printf '#!/bin/sh\n' > "$sd/$x/dotnet"; chmod +x "$sd/$x/dotnet"; done
: > "$sd/q\"x/sdk/12.0.100/dotnet.dll"; : > "$sd/n
l/sdk/12.0.100/dotnet.dll"; mkdir -p "$sd/z/sdk/11.0.100"; : > "$sd/z/sdk/11.0.100/dotnet.dll"
F_DOTNET=""; F_DOTNET_DIR=""; _seen=" "; _bk=0; _end=$(( $(date +%s) + 5 ))
sdk_root "$sd/q\"x"; sdk_root "$sd/n
l"; sdk_root "$sd/z"
eq "${F_DOTNET_DIR##*/}" z "sdk_root: folders with a quote or a newline are skipped, and do not stop the search"
echo "safe_dir: real permissions"
mkdir -p "$sd/s"; printf '#!/bin/sh\n' > "$sd/s/dotnet"; chmod 755 "$sd/s" "$sd/s/dotnet"
if safe_dir "$sd/s"; then ok "safe_dir: a folder of this user, not writable by others"; else bad "safe_dir own" unsafe safe; fi
chmod 777 "$sd/s"
if safe_dir "$sd/s"; then bad "safe_dir world-writable folder" safe unsafe; else ok "safe_dir: a world-writable folder is not safe"; fi
chmod 755 "$sd/s"; chmod 777 "$sd/s/dotnet"
if safe_dir "$sd/s"; then bad "safe_dir world-writable dotnet" safe unsafe; else ok "safe_dir: a world-writable dotnet is not safe"; fi
if safe_dir "$sd/missing"; then bad "safe_dir missing" safe unsafe; else ok "safe_dir: a missing folder is not safe"; fi
chmod 777 "$sd/s/dotnet"; chmod 755 "$sd/s/dotnet"; mkdir -p "$sd/s/host/fxr/10.0.2" "$sd/s/sdk/10.0.102"; chmod 755 "$sd/s/host" "$sd/s/host/fxr" "$sd/s/host/fxr/10.0.2" "$sd/s/sdk/10.0.102"
if safe_dir "$sd/s" 10.0.102; then ok "safe_dir: host, host/fxr and the SDK folder of this user"; else bad "safe_dir tree" unsafe safe; fi
chmod 777 "$sd/s/host/fxr/10.0.2"
if safe_dir "$sd/s" 10.0.102; then bad "safe_dir open fxr" safe unsafe; else ok "safe_dir: a world-writable host/fxr version folder is not safe"; fi
chmod 755 "$sd/s/host/fxr/10.0.2"; chmod 777 "$sd/s/sdk/10.0.102"
if safe_dir "$sd/s" 10.0.102; then bad "safe_dir open sdk" safe unsafe; else ok "safe_dir: a world-writable SDK folder is not safe"; fi
chmod 755 "$sd/s/sdk/10.0.102"; mkdir -p "$sd/s/shared/Microsoft.AspNetCore.App/10.0.2" "$sd/s/packs"; chmod 777 "$sd/s/shared/Microsoft.AspNetCore.App/10.0.2"
if safe_dir "$sd/s" 10.0.102; then bad "safe_dir open shared" safe unsafe; else ok "safe_dir: a world-writable shared framework version folder is not safe"; fi
chmod 755 "$sd/s/shared/Microsoft.AspNetCore.App/10.0.2"; chmod 777 "$sd/s/packs"
if safe_dir "$sd/s" 10.0.102; then bad "safe_dir open packs" safe unsafe; else ok "safe_dir: world-writable packs is not safe"; fi
chmod 755 "$sd/s/packs"; mkdir -p "$sd/open/inner"; chmod 777 "$sd/open"; cp -R "$sd/s" "$sd/open/inner/d" 2>/dev/null || :
chmod -R go-w "$sd/open/inner"
if safe_dir "$sd/open/inner/d" 10.0.102; then bad "safe_dir open parent" safe unsafe; else ok "safe_dir: a parent folder others may write (not sticky) is not safe"; fi
chmod 1777 "$sd/open"
if safe_dir "$sd/open/inner/d" 10.0.102; then ok "safe_dir: a sticky world-writable parent (like /tmp) is fine"; else bad "safe_dir sticky parent" unsafe safe; fi
if [ "$(id -u)" = 0 ]; then
  chown 65534 "$sd/s/host"
  if safe_dir "$sd/s" 10.0.102; then bad "safe_dir foreign owner" safe unsafe; else ok "safe_dir: a folder owned by another user is not safe"; fi
  chown 0 "$sd/s/host"
  chgrp 65534 "$sd/s"; chmod 775 "$sd/s"
  if safe_dir "$sd/s" 10.0.102; then bad "safe_dir group-writable" safe unsafe; else ok "safe_dir: writable by another group is not safe"; fi
fi
F_DOTNET_DIR=""; _bk=0; _end=$(( $(date +%s) - 1 )); _seen=" "; sdk_root "$sd/b"
eq "$F_DOTNET_DIR" "" "sdk_root: nothing is read after the 5 s deadline"
rm -rf "$sd"

_end=$(( $(date +%s) + 5 )); _seen=" "; F_DOTNET_DIR=""; mkdir -p rel/sdk/10.0.1 && printf '#!/bin/sh\n' > rel/dotnet && chmod +x rel/dotnet && : > rel/sdk/10.0.1/dotnet.dll
sdk_root rel; sdk_root ./rel
eq "$F_DOTNET_DIR" "" "sdk_root: a relative folder is never searched"
rm -rf rel
if safe_dir rel 10.0.1; then bad "safe_dir relative" safe unsafe; else ok "safe_dir: a relative folder is not safe (and returns at once)"; fi

echo "AuthorizedKeysFile from sshd_config"
cfgB='AuthorizedKeysFile .ssh/authorized_keys
Match User build*,!buildx
	AuthorizedKeysFile /etc/ssh/keys/%u # the build users
Match all
AuthorizedKeysFile .ssh/keys_all
Match Group wheel
AuthorizedKeysFile /etc/ssh/wheel_keys'
eq "$(printf '%s\n' "$cfgB" | keys_files builder /home/builder "builder users" | tr '\n' '|')" "match|/etc/ssh/keys/builder|" "Match User block: its file, %u expanded"
eq "$(printf '%s\n' "$cfgB" | keys_files buildx /home/buildx "buildx" | tr '\n' '|')" "match|/home/buildx/.ssh/keys_all|" "a negated user skips that block; Match all applies; relative = home"
eq "$(printf 'AuthorizedKeysFile .ssh/authorized_keys\nMatch Group wheel\n  AuthorizedKeysFile /etc/ssh/wheel_keys\n' | keys_files ann /home/ann "ann wheel" | tr '\n' '|')" "match|/etc/ssh/wheel_keys|" "Match Group: a group the user is in"
eq "$(printf 'AuthorizedKeysFile .ssh/authorized_keys\nMatch Group wheel\n  AuthorizedKeysFile /etc/ssh/wheel_keys\n' | keys_files bob /home/bob "bob" | tr '\n' '|')" "global|/home/bob/.ssh/authorized_keys|" "Match Group: not in it, the global file"
eq "$(printf 'Match Address 10.0.0.0/8\n  AuthorizedKeysFile /etc/x\nMatch all\n  AuthorizedKeysFile "%%h/k1" none %%%%h\n' | keys_files bob /home/bob "" | tr '\n' '|')" "match|/home/bob/k1|/home/bob/%h|" "a criterion that cannot be judged is skipped; quotes, none and %% handled"
eq "$(printf '' | keys_files bob /home/bob "" | tr '\n' '|')" "default|/home/bob/.ssh/authorized_keys|/home/bob/.ssh/authorized_keys2|" "no config: the sshd default files"
eq "$(printf 'AuthorizedKeysFile=/etc/ssh/k/%%u\n' | keys_files bob /home/bob "" | tr '\n' '|')" "global|/etc/ssh/k/bob|" "Key=value form"
eq "$(printf 'MATCH ALL\n  AuthorizedKeysFile /k\n' | keys_files bob /home/bob "" | tr '\n' '|')" "match|/k|" "Match keywords are case-insensitive"
eq "$(printf 'Match Group build*\n  AuthorizedKeysFile /k\n' | keys_files bob /home/bob "bob builders" | tr '\n' '|')" "match|/k|" "Match Group takes glob patterns"
eq "$(printf "Match all\n  AuthorizedKeysFile /k/%%U\n" | keys_files bob /home/bob "" | tr '\n' '|')" "match|/k/$(id -u)|" "%U is the numeric uid"
eq "$(printf '%s\n' "${SEP}include-start" 'Match User nobody' "${SEP}include-end" 'AuthorizedKeysFile /global' | keys_files bob /home/bob "" | tr '\n' '|')" "global|/global|" "a Match block in an included file ends with that file"
fixture_ubuntu; F_AUTHVIA=match; run
contains "$CHECKS" "the file a Match block in sshd_config names" "keys found through a Match block: OK says so"
fixture_ubuntu; F_AUTHKEYS=no; F_AUTHVIA=unreadable; run
contains "$CHECKS" "sshd_config is not readable, so keys may be set up elsewhere" "sshd_config unreadable: WARN says keys may be elsewhere"
fixture_ubuntu; F_DOTNET_DIR=/opt/build/dotnet; F_DOTNET_OFFPATH=yes; F_DOTNET_OPEN=yes; run
eq "$V_DOTNET" WARN "SDK in a folder others can write: WARN"
contains "$CHECKS" "other local users can write there, so it is not suggested" "SDK in a folder others can write: the check says why"
contains "$(render_snippet)" "# path_prepend: not suggested: other local users can write to /opt/build/dotnet" "SDK in a folder others can write: a comment, no path_prepend"
if render_snippet | grep -q '^    path_prepend:\|^      DOTNET_ROOT'; then bad "open folder: path_prepend" present absent; else ok "SDK in a folder others can write: no path_prepend or DOTNET_ROOT"; fi
case "$(render_json 0)" in *'"path_prepend": ['*) bad "open folder: JSON path_prepend" present absent ;; *) ok "SDK in a folder others can write: no path_prepend in JSON" ;; esac
eq "$(safe_name 'My_PC.Local')" "my-pc-local" "safe_name: lowercase, [a-z0-9-]"
eq "$(safe_name '--x--')" "x" "safe_name: no leading/trailing hyphen"
eq "$(safe_name '___')" "old-pc" "safe_name: fallback"
if valid_ssh_user "build.user-1"; then ok "ssh user: normal name accepted"; else bad "ssh user ok" no yes; fi
if valid_ssh_user "John Smith"; then bad "ssh user space" accepted rejected; else ok "ssh user: space rejected"; fi
if valid_ssh_user "o'brien"; then bad "ssh user quote" accepted rejected; else ok "ssh user: quote rejected"; fi
fixture_ubuntu; F_USER="John Smith"; F_HOST="My_PC"; run
contains "$(render_snippet)" 'ssh: "<user>@my-pc.lan"' "bad ssh user: <user> placeholder, YAML-quoted"
contains "$(render_snippet)" 'name: "my-pc"' "name is sanitised and YAML-quoted"
if (DBUS_SESSION_BUS_ADDRESS="" ; have_session_bus); then bad "no session bus" yes no; else ok "no session bus: have_session_bus false"; fi
if (DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1/bus"; have_session_bus); then ok "session bus set: have_session_bus true"; else bad "bus" no yes; fi

esc=$(json_esc "$(printf 'a\rb\033[31mc\377\376d"e\\f\tg')")
eq "$esc" 'a?b?[31mc??d\"e\\f?g' "json_esc: CR, ESC, invalid UTF-8 and tab become '?', quote and backslash escaped"

# Redaction works on values: names that equal JSON keys/values or contain a quote must not break the report.
red=$(
  HOME="/home/o'brien"
  fixture_ubuntu; F_HOST=worker; F_USER="o'brien"; F_OSNAME="Ubuntu on worker (o'brien)"; F_CPU="cpu of worker"; F_TEMP="cache /home/o'brien/.cache 5 MB"; F_TEMP_BIGMB=5
  redact_facts; eval_checks; eval_verdicts; eval_machine 00:00-07:00 1
  render_human; render_json 1
)
if leaks "$red" "worker" || leaks "$red" "o'brien"; then bad "redaction leak" "found host/user" "none"; else ok "redaction: host, user and home path do not appear"; fi
contains "$red" '"hostname": "<redacted>"' "redaction: JSON host field"
contains "$red" "Ubuntu on <redacted> (<redacted>)" "redaction: replaced inside free text"
red2=$(
  HOME="/home/false"
  fixture_ubuntu; F_HOST=linux; F_USER=false; F_OSNAME="Ubuntu linux false"; F_GIT="git version 2.43 linux"
  redact_facts; eval_checks; eval_verdicts; eval_machine "" 1
  render_json 1
)
contains "$red2" '"needsAdmin": false' "name 'false': boolean values are untouched"
contains "$red2" '"os": "linux"' "name 'linux': enum values are untouched"
contains "$red2" '"os": "Ubuntu <redacted> <redacted>"' "names equal to words are redacted in free text only"
if printf '%s' "$red2" | grep -Eq '"<redacted>" *:'; then bad "keys corrupted" "key replaced" "keys intact"; else ok "redaction never rewrites JSON keys"; fi
eq "$(printf '%s' "$red2" | grep -c '"status": "')" "$(printf '%s' "$red2" | grep -o '"status": "\(OK\|WARN\|FAIL\|SKIP\)"' | wc -l | tr -d ' ')" "all status values still valid"

echo "arguments and stdin mode"
eq "$(LANQ_MAKEREADY_LIB=1 sh "$root/lanq-makeready.sh" >/dev/null 2>&1; echo $?)" 2 "LANQ_MAKEREADY_LIB=1 on a direct run: exit 2"
eq "$(LANQ_MAKEREADY_LIB=1 sh -s < "$root/lanq-makeready.sh" >/dev/null 2>&1; echo $?)" 2 "LANQ_MAKEREADY_LIB=1 under 'sh -s' (\$0 is sh): exit 2, not a silent 0"
eq "$(grep -c 'config.json' "$root/lanq-makeready.sh")" 0 "docker config.json (may hold credentials) is never read"

echo "bounded runner without timeout(1) (every Mac)"
have() { case "$1" in timeout|gtimeout) return 1 ;; esac; command -v "$1" >/dev/null 2>&1; }
t0=$(date +%s); out=$(run_t 2 sleep 8); t1=$(date +%s) # inside $( ) an orphaned tool would keep the pipe open for the full 8 s
eq "$([ $((t1 - t0)) -lt 4 ] && echo fast)" fast "fallback: run_t 2 sleep 8 returns in under 4 s (took $((t1 - t0)) s)"
eq "$(run_t 5 echo hi)" hi "fallback: normal command output is returned"
unset -f have
have() { command -v "$1" >/dev/null 2>&1; }

echo "read-only guard (command allow-list; a test-time tripwire, not a sandbox)"
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
# statement-start words of the code on stdin
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
        if (w[1] != "" && w[1] !~ /^[A-Za-z_][A-Za-z0-9_]*=/ && w[1] !~ /^[$<>0-9=-]/ && w[1] !~ /^\[/ && w[1] != "X" && w[2] !~ /^[-+*\/%]$/ && w[1] !~ /[*?\]:|]/) print w[1]
      }
    }' | sort -u
}
allowed=" printf echo awk sed tr cut head wc grep find cat command readlink uname hostname id df getconf ldd sw_vers sysctl vm_stat pmset launchctl pgrep systemctl gsettings xcode-select docker git tar gzip du date sleep kill wait timeout gtimeout sh exec cd exit return export eval read test /usr/libexec/java_home type shift sort true false break continue fi done esac then else elif do in while for if case until [ ]] "
forbidden=" sudo chmod chown apk apt apt-get dnf yum rm mv cp ln mkdir touch tee curl wget nc ssh scp mount dd su install useradd passwd iex bash "
# guard_check FILE: prints one line per violation (nothing when clean)
guard_check() {
  _f=$1
  _code=$(awk '/^# BEGIN ADVICE$/ {skip=1} !skip {print} /^# END ADVICE$/ {skip=0}' "$_f")
  _code=$(printf '%s\n' "$_code" | grep -vxF -e '  _otmp=$(mktemp "$_odir/.lanq-makeready.XXXXXX" 2>/dev/null) || return 1' -e '  ln -- "$_otmp" "$OUT_PATH" 2>/dev/null; _ok=$?' -e '  rm -f -- "$_otmp"' -e "  trap 'rm -f -- \"\$_otmp\"' EXIT" -e "  trap 'rm -f -- \"\$_otmp\"; exit 130' INT TERM" -e '  trap - EXIT INT TERM')
  _fns=$(grep -E '^[a-z_0-9]+\(\)' "$_f" | sed 's/().*//')
  for _w in $(printf '%s\n' "$_code" | cmd_words); do
    case "$allowed" in *" $_w "*) continue ;; esac
    case " $(echo $_fns) " in *" $_w "*) continue ;; esac
    echo "unknown command word: $_w"
  done
  for _w in $(printf '%s\n' "$_code" | cmd_words); do case "$forbidden" in *" $_w "*) echo "forbidden command word: $_w" ;; esac; done
  # sh -c bodies are code too
  printf '%s\n' "$_code" | grep -o "sh -c '[^']*'" | sed -e "s/^sh -c '//" -e "s/'\$//" | cmd_words | while read -r _w; do
    case "$allowed cd exit export exec " in *" $_w "*) ;; *) echo "unknown command word in sh -c body: $_w" ;; esac
  done
  printf '%s\n' "$_code" | grep -nE 'sh -c "|bash -c' | sed 's/^/double-quoted or bash -c body: /'
  # raw text (quotes included)
  printf '%s\n' "$_code" | grep -nE '(^|[^A-Za-z_])sudo([^A-Za-z_]|$)|sed[[:space:]]+(-[A-Za-z]*i|--in-place)|find[[:space:]].*-(delete|exec|execdir|ok)|system[[:space:]]*\(|getline|rm[[:space:]]+-[A-Za-z]|chmod[[:space:]]|chown[[:space:]]|mkfs|dd[[:space:]]+if=' | sed 's/^/raw: /'
  printf '%s\n' "$_code" | grep -nE 'awk' | grep -E '(print|printf)[^;}]*[^-=<]>[^=]|print[^;}]*\|[[:space:]]*"' | sed 's/^/awk write or pipe: /'
  printf '%s\n' "$_code" | grep -n '`' | sed 's/^/backtick: /'
  printf '%s\n' "$_code" | grep -nE 'eval ' | grep -E '\$\(|`' | sed 's/^/eval with substitution: /'
  printf '%s\n' "$_code" | grep -nE 'systemctl[^|;&]*[[:space:]](enable|disable|start|stop|mask|unmask|restart|reload|daemon-reload|set-default|edit)([[:space:]]|$)|gsettings[[:space:]]+set|pmset[[:space:]]+-a|launchctl[[:space:]]+(load|unload|bootstrap|bootout|kickstart|enable|disable)|docker[[:space:]]+(run|pull|build|rm|rmi|exec|start|stop|system|volume|network|login|push|cp|commit)|git[[:space:]]+(clone|fetch|pull|push|checkout|add|commit)|ethtool[^|;&]*[[:space:]]-[sKAGLEfW]([[:space:]]|$)|[[:space:]]wol[[:space:]]+[pumbgsd]+|nmcli|swapon|Out-File|Set-Content|Start-Process|cmd /c' | sed 's/^/mutating subcommand: /'
  printf '%s\n' "$_code" | grep -E 'git[[:space:]]+config' | grep -vE 'git[[:space:]]+config[[:space:]]+--get[[:space:]]' | sed 's/^/git config other than --get: /'
  printf '%s\n' "$_code" | awk "$scan_awk"'
    /^[ \t]*#/ { next }
    { raw = $0
      gsub(/2>\/dev\/null|>\/dev\/null|2>&1|>&2|>&1|> "\$JSON_PATH"|>"\$JSON_PATH"|> "\$out"|> "\$OUT_PATH"|> "\$_otmp"/, "", raw)
      if (scan(raw) ~ />/) print "redirection: " $0 }'
  printf '%s\n' "$_code" | grep -E 'eval ' | grep -vE 'F_T_|_v=' | sed 's/^/eval of something else: /'
}
begin=$(grep -c '^# BEGIN ADVICE$' "$root/lanq-makeready.sh"); eq "$begin" 1 "one advice-table start marker"
eq "$(guard_check "$root/lanq-makeready.sh")" "" "script passes the guard (command words, raw text, redirections, eval, sh -c bodies)"
# negative tests: each injected line must be caught
mut_dir=${TMPDIR:-/tmp}/lanq-mut.$$
mkdir -p "$mut_dir"
mutant() { # name, line
  cp "$root/lanq-makeready.sh" "$mut_dir/m.sh"; printf '%s\n' "$2" >> "$mut_dir/m.sh"
  if [ -n "$(guard_check "$mut_dir/m.sh")" ]; then ok "guard catches: $1"; else bad "guard catches: $1" "not flagged" "flagged"; fi
}
mutant "sed -i" "sed -i s/a/b/ /etc/hosts"
mutant "find -delete" "find / -name x -delete"
mutant "find -exec" "find . -exec touch {} +"
mutant "awk system()" "awk 'BEGIN { system(\"id\") }'"
mutant "awk getline pipe" "awk 'BEGIN { \"id\" | getline y }'"
mutant "awk print >" "awk 'BEGIN { print 1 > \"/tmp/x\" }'"
mutant "sh -c body" "sh -c 'rm -rf /tmp/x'"
mutant "sh -c double-quoted" "sh -c \"id\""
mutant "backtick" 'x=`id`'
mutant "eval with \$(" 'eval "y=$(id)"'
mutant "systemctl restart" "systemctl restart ssh"
mutant "systemctl --user mask" "systemctl --user mask foo"
mutant "git config write" "git config user.name x"
mutant "redirect to a file" "echo hi > /tmp/f"
mutant "sudo in text" "echo 'sudo ls'"
mutant "rm -rf" "rm -rf /tmp/x"
mutant "unknown command" "nmap localhost"
mutant "ethtool -s (changes the NIC)" 'run_t 5 "$_et" -s eth0 wol g'
mutant "ethtool -K" 'run_t 5 ethtool -K eth0 tso off'
mutant "redirect to another variable" 'printf x > "$JSON_PATH.bak"'
mutant "rm of something else" 'rm -f -- "$JSON_PATH"'
mutant "ln of something else" 'ln -- /etc/passwd "$OUT_PATH"'
mutant "set -C used to write elsewhere" '( set -C; echo x > /tmp/x )'
rm -rf "$mut_dir"
eq "$(printf '%s\n' "x=1" | cmd_words)" "" "tokenizer ignores assignments"
eq "$(grep -c '^  ln -- "$_otmp" "$OUT_PATH"' "$root/lanq-makeready.sh"):$(grep -c 'rm -f -- "$_otmp"' "$root/lanq-makeready.sh"):$(grep -c 'mktemp' "$root/lanq-makeready.sh")" "1:3:1" "the only ln, rm and mktemp are the --out temp-file lines (rm: the cleanup and its two traps)"
eq "$(grep -cE '(^|[^A-Za-z_])rm[[:space:]]' "$root/lanq-makeready.sh" | tr -d ' ')" "$(grep -c 'rm -f -- "$_otmp"' "$root/lanq-makeready.sh")" "every rm in the script removes only the --out temp file"
eq "$([ -e "$root/SHA256SUMS" ] && echo committed || echo none)" none "SHA256SUMS is produced by the release workflow, never committed (a stale copy would mislead)"
eq "$(grep -cE -- '-(fprint|fprintf|fprint0|fls|delete|exec|execdir|ok|okdir)([[:space:]]|$)' "$root/lanq-makeready.sh" | tr -d ' ')" 0 "no find action that writes, deletes or runs anything (-fprint, -fls, -delete, -exec, -ok)"
lines=$(wc -l < "$root/lanq-makeready.sh" | tr -d ' ')
if [ "$lines" -le 980 ]; then ok "script is $lines lines (max 980)"; else bad "line count" "$lines" "<=980"; fi

echo "smoke: real run of the script on this machine"
out=${TMPDIR:-/tmp}/lanq-makeready-smoke.$$.json
LANQ_MAKEREADY_LIB=0 sh "$root/lanq-makeready.sh" --json "$out" --redact --hours 00:00-07:00 >"$out.txt" 2>&1
rc=$?
case "$rc" in 0|1) ok "smoke: exit code $rc in {0,1}" ;; *) bad "smoke exit code" "$rc" "0 or 1"; cat "$out.txt" ;; esac
for k in '"schema": "lanq-makeready/v1"' '"verdicts"' '"checks"' '"capabilities"' '"suggestedMachine"' '"generatedAt"' '"hostname": "<redacted>"'; do
  if grep -q "$k" "$out" 2>/dev/null; then ok "smoke: json has $k"; else bad "smoke: json has $k" missing present; fi
done
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$out" 2>/dev/null; then ok "smoke: JSON parses"; else bad "smoke: JSON parses" invalid valid; fi
elif command -v jq >/dev/null 2>&1; then
  if jq . "$out" >/dev/null 2>&1; then ok "smoke: JSON parses"; else bad "smoke: JSON parses" invalid valid; fi
fi
host=$(hostname 2>/dev/null)
if [ ${#host} -ge 2 ] && grep -q "[^A-Za-z0-9]${host}[^A-Za-z0-9]" "$out.txt" "$out" 2>/dev/null; then bad "smoke: hostname redacted" leaked hidden; else ok "smoke: hostname not in redacted output"; fi
rm -f "$out" "$out.txt"
echo "--out: saves the human report, never overwrites"
od=${TMPDIR:-/tmp}/lanq-out.$$; mkdir -p "$od"
LANQ_MAKEREADY_LIB=0 sh "$root/lanq-makeready.sh" --out "$od/r.txt" --redact >"$od/screen.txt" 2>&1; rc=$?
case "$rc" in 0|1) ok "--out: exit $rc" ;; *) bad "--out exit" "$rc" "0 or 1" ;; esac
eq "$(sed -n 2p "$od/r.txt" 2>/dev/null | cut -c1-8)" "VERDICT:" "--out: file holds the report (verdict on line 2)"
if cmp -s "$od/r.txt" "$od/screen.txt"; then ok "--out: file equals the screen report"; else
  bad "--out: file equals the screen report" differs same
  echo "    --- diff (file vs screen, screen includes stderr):"; diff "$od/r.txt" "$od/screen.txt" | head -20 | sed 's/^/    /'
fi
printf 'keep me\n' > "$od/exists.txt"
eq "$(LANQ_MAKEREADY_LIB=0 sh "$root/lanq-makeready.sh" --out "$od/exists.txt" >/dev/null 2>&1; echo $?)" 2 "--out to an existing file: exit 2"
eq "$(cat "$od/exists.txt")" "keep me" "--out: existing file left untouched"
eq "$(LANQ_MAKEREADY_LIB=0 sh "$root/lanq-makeready.sh" --out >/dev/null 2>&1; echo $?)" 2 "--out without a name: exit 2"
eq "$(ls -a "$od" | wc -l | tr -d ' ')" 5 "--out: no other file written (no temp file left)"
if command -v mkfifo >/dev/null 2>&1; then
  mkfifo "$od/fifo"
  eq "$(OUT_PATH="$od/fifo"; save_out "x" >/dev/null 2>&1; echo $?)" 1 "save_out: a FIFO that appeared after the first check is refused (no blocking write)"
fi
ln -s "$od/nowhere" "$od/dangling"
eq "$(OUT_PATH="$od/dangling"; save_out "x" >/dev/null 2>&1; echo $?)" 1 "save_out: a dangling symlink is refused"
eq "$([ -e "$od/nowhere" ] && echo created || echo absent)" absent "save_out: nothing created through the symlink"
eq "$(OUT_PATH="$od/new.txt"; save_out "hello" 2>/dev/null; cat "$od/new.txt")" hello "save_out: writes a new file"
eq "$(for _t in "$od"/.lanq-makeready.*; do [ -e "$_t" ] && echo left; done)" "" "save_out: temp files removed"
eq "$(OUT_PATH="$od/t2.txt"; save_out "x" 2>/dev/null; trap)" "" "save_out: its cleanup traps are removed afterwards"
eq "$(cd "$od" && mkdir -- -d && OUT_PATH="-d/r.txt"; save_out "dash" 2>/dev/null; cat -- "$od/-d/r.txt" 2>/dev/null)" dash "save_out: a folder name starting with - is not taken as a mktemp option"
eq "$(OUT_PATH="$od/nolink.txt"; ln() { return 1; }; save_out "x" 2>/dev/null; echo $?)" 3 "save_out: ln failing on a new name returns 3 (no hard links on this filesystem)"
eq "$([ -e "$od/nolink.txt" ] && echo created || echo absent):$(for _t in "$od"/.lanq-makeready.*; do [ -e "$_t" ] && echo left; done)" "absent:" "save_out: failed ln leaves nothing behind"
contains "$(out_error 3)" "may not support hard links (e.g. FAT/exFAT USB sticks); choose another folder" "--out: hard-link failure message"
contains "$(out_error 1)" "already exists" "--out: other failures keep their message"
rm -rf "$od"

echo "smoke: stdout JSON mode (the SSH invocation)"
so=$(LANQ_MAKEREADY_LIB=0 sh -s -- --json - --redact < "$root/lanq-makeready.sh" 2>/dev/null); rc=$?
case "$rc" in 0|1) ok "sh -s -- --json - --redact < script: exit $rc" ;; *) bad "stdin mode exit" "$rc" "0 or 1" ;; esac
eq "$(printf '%s' "$so" | head -c 1)" "{" "stdin mode: output starts with {"
eq "$(printf '%s\n' "$so" | tail -n 1)" "}" "stdin mode: output ends with }"
contains "$so" '"schema": "lanq-makeready/v1"' "stdin mode: JSON report on stdout"
if printf '%s' "$so" | grep -q 'read-only: nothing is installed'; then bad "stdin mode human text" present absent; else ok "stdin mode: no human text mixed into stdout"; fi
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$so" | python3 -c "import json,sys; json.load(sys.stdin)"; then ok "stdin mode: JSON parses"; else bad "stdin mode JSON" invalid valid; fi
fi
so2=$(LANQ_MAKEREADY_LIB=0 sh "$root/lanq-makeready.sh" --json - 2>/dev/null)
eq "$(printf '%s' "$so2" | head -c 1)" "{" "--json - on a normal run: stdout is only JSON"
host=$(hostname 2>/dev/null)
if leaks "$so" "$host"; then bad "stdin mode redaction" "$host" none; else ok "stdin mode: hostname not in redacted JSON"; fi

echo
echo "sh tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
