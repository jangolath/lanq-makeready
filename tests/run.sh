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
  F_CGROUP=v2; F_SLEEP=masked; F_SLEEP_DETAIL=""; F_REBOOT=no; F_STARTUP=5; F_TEMP="cache 100 MB"; F_TEMP_BIGMB=100; F_DOCKER_REMOTE=no
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
eq "$V_GIT:$V_ARCHIVE" "FAIL:FAIL" "macOS: both worker verdicts FAIL (LanQueue rejects macOS workers)"

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
eq "$([ "$(ram_installed_mb 3900)" -ge 4096 ] && echo yes)" yes "4 GB machine (MemTotal 3900 MB) counts as 4 GB installed"
eq "$([ "$(ram_installed_mb 3300)" -lt 4096 ] && echo yes)" yes "3.2 GB MemTotal is still below 4 GB"
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
eq "$M_CAPS" "node, docker, linux" "SDK 6 only: no dotnet capability"
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

echo "read-only guard (command allow-list)"
begin=$(grep -c '^# BEGIN ADVICE$' "$root/lanq-makeready.sh"); eq "$begin" 1 "one advice-table start marker"
code=$(awk '/^# BEGIN ADVICE$/ {skip=1} !skip {print} /^# END ADVICE$/ {skip=0}' "$root/lanq-makeready.sh")
# scan(): drops quoted text and ${...}, keeps the inside of $(...) as code. Used for the command-word list and the redirect check.
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
words=$(printf '%s\n' "$code" | awk "$scan_awk"'
  /^[ \t]*#/ || /^EOF$/ { next }
  {
    l = scan($0)
    while (match(l, /(^[ 	]*|;;[ \t]*|[ \t]in[ \t]+)[^ \t;()]+\)/)) l = substr(l, 1, RSTART - 1) " ; " substr(l, RSTART + RLENGTH)
    n = split(l, seg, /[;|&(){}]/)
    for (i = 1; i <= n; i++) {
      t = seg[i]; sub(/^[ \t]+/, "", t)
      while (t ~ /^(if|then|elif|else|do|while|until|!)[ \t]/) sub(/^[^ \t]+[ \t]+/, "", t)
      if (t ~ /^(for|case)[ \t]/) continue
      split(t, w, /[ \t]/)
      if (w[1] != "" && w[1] !~ /^[A-Za-z_][A-Za-z0-9_]*=/ && w[1] !~ /^[$<>0-9=-]/ && w[1] !~ /^\[/ && w[1] != "X" && w[2] !~ /^[-+*\/%]$/ && w[1] !~ /[*?\]:|]/) print w[1]
    }
  }' | sort -u)
allowed=" printf echo awk sed tr cut head wc grep find cat command readlink uname hostname id df getconf ldd sw_vers sysctl vm_stat pmset launchctl pgrep systemctl gsettings xcode-select docker git tar gzip du date sleep kill wait timeout gtimeout sh exec cd exit return export eval read test /usr/libexec/java_home shift sort true false break continue fi done esac then else elif do in "
extra=""; bad_cmd=""
for w in $words; do
  case "$allowed" in *" $w "*) continue ;; esac
  if grep -Eq "^[[:space:]]*$w\(\)" "$root/lanq-makeready.sh"; then continue; fi
  extra="$extra $w"
done
eq "$extra" "" "every command word is allow-listed or a function defined in the script"
for w in $words; do
  forbidden=" sudo chmod chown apk apt apt-get dnf yum rm mv cp ln mkdir touch tee curl wget nc ssh scp mount dd su install useradd passwd iex "
  case "$forbidden" in *" $w "*) bad_cmd="$bad_cmd $w" ;; esac
done
eq "$bad_cmd" "" "no forbidden command word (rm, chmod, apk, apt, curl, ssh, ...)"
eq "$(printf '%s\n' "$code" | grep -cE '(^|[^A-Za-z_])sudo([^A-Za-z_]|$)')" 0 "sudo appears nowhere outside the advice table"
forbid=$(printf '%s\n' "$code" | grep -nE 'systemctl[[:space:]]+(mask|unmask|enable|disable|start|stop|restart|daemon-reload)|gsettings[[:space:]]+set|pmset[[:space:]]+-a|launchctl[[:space:]]+(load|unload|bootstrap|bootout|kickstart|enable|disable)|docker[[:space:]]+(run|pull|build|rm|rmi|exec|start|stop|system|volume|network|login|push)|git[[:space:]]+(config[[:space:]]+--(global|system)|clone|fetch|pull|push|checkout)|Out-File|Set-Content|Start-Process|cmd /c' || true)
eq "$forbid" "" "no mutating systemctl/gsettings/pmset/launchctl/docker/git subcommands"
redirs=$(printf '%s\n' "$code" | awk "$scan_awk"'
  /^[ \t]*#/ { next }
  { raw = $0
    gsub(/2>\/dev\/null|>\/dev\/null|2>&1|>&2|>&1|> "\$JSON_PATH"|>"\$JSON_PATH"/, "", raw)
    if (scan(raw) ~ />/) print $0 }')
eq "$redirs" "" "output redirections only go to /dev/null, stderr/stdout, or the --json file"
eq "$(printf '%s\n' "$code" | grep -E 'eval ' | grep -vcE 'F_T_|_v=')" 0 "eval is used only for the F_T_* tool variables"
lines=$(wc -l < "$root/lanq-makeready.sh" | tr -d ' ')
if [ "$lines" -le 750 ]; then ok "script is $lines lines (max 750)"; else bad "line count" "$lines" "<=750"; fi

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
