#!/bin/sh
# shellcheck disable=SC2034,SC2153
# POSIX test runner: sources lanq-makeready.sh as a library (LANQ_MAKEREADY_LIB=1) and feeds fixtures.
# Usage: sh tests/run.sh        (from anywhere)
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
pass=0; fail=0

LANQ_MAKEREADY_LIB=1
export LANQ_MAKEREADY_LIB
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
  F_CGROUP=v2; F_SLEEP=masked; F_SLEEP_DETAIL=""; F_REBOOT=no; F_STARTUP=5; F_TEMP="cache 100 MB"; F_TEMP_BIGMB=100
  F_T_node=v22.1.0; F_T_python=""; F_T_java=""; F_T_go=""; F_T_rustc=""
}
run() { eval_checks; eval_verdicts; eval_machine "${1:-}" 0; }

echo "ubuntu 24.04 good"
fixture_ubuntu; run
eq "$V_GIT" OK "ubuntu: worker_git OK"
eq "$V_ARCHIVE" OK "ubuntu: worker_archive OK"
eq "$V_DOTNET" OK "ubuntu: dotnet10 OK"
eq "$V_DOCKER" OK "ubuntu: docker OK"
eq "$V_OVERNIGHT" OK "ubuntu: overnight OK"
eq "$M_TRANSFER" git "ubuntu: transfer git"
eq "$M_CAPS" "dotnet, node, docker, linux" "ubuntu: capabilities"

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

echo "read-only guard"
begin=$(grep -c '^# BEGIN ADVICE$' "$root/lanq-makeready.sh"); eq "$begin" 1 "one advice-table start marker"
code=$(awk '/^# BEGIN ADVICE$/ {skip=1} !skip {print} /^# END ADVICE$/ {skip=0}' "$root/lanq-makeready.sh")
hits=$(printf '%s\n' "$code" | grep -nE 'Set-ItemProperty|New-Item|Remove-Item|Set-Service|Start-Service|Stop-Service|reg add|powercfg [/-]change|pnputil [/-]add|Add-WindowsCapability|(^|[^A-Za-z-])rm[[:space:]]|[[:space:]]sudo([[:space:]]|$)|systemctl[[:space:]]+(enable|disable|start|stop)|(^|[^A-Za-z-])apt(-get)?([^A-Za-z]|$)|(^|[^A-Za-z])(dnf|yum)([^A-Za-z]|$)|Invoke-WebRequest|Invoke-RestMethod|(^|[^A-Za-z])(curl|wget)([^A-Za-z]|$)|Start-BitsTransfer|New-NetFirewallRule' || true)
eq "$hits" "" "no mutating or network command outside the advice table"
lines=$(wc -l < "$root/lanq-makeready.sh" | tr -d ' ')
if [ "$lines" -le 700 ]; then ok "script is $lines lines (max 700)"; else bad "line count" "$lines" "<=700"; fi

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

echo
echo "sh tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
