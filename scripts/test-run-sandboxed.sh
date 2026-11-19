#!/bin/sh
# Self-test of the test sandbox: scripts/run-sandboxed.sh and the profile scripts/test-sandbox.sb.
#
# Rule: the self-test never writes in the real home. A temp folder is the denied folder
# (BIFROST_SANDBOX_DENY). For the real paths, the script reads the concrete profile of a run,
# and it runs a stat of each real path in the profile that exists. A temp home with each
# protected path proves the refusal on every machine, also on a new CI runner where the real
# paths do not exist. A stat reads no content and writes nothing. No case sends data out of the
# Mac: the IP connection goes to the loopback address, and the name lookup is for localhost.
#
# Each case prints "ok <case>" or "FAIL <case>: <reason>".
# Exit 0: all cases pass, and the script prints PASS. Exit 1: a case failed.

# -f: no file name expansion. -u: an unset variable is an error.
set -fu

here=$(cd "$(dirname "$0")" && pwd) || exit 1
run="$here/run-sandboxed.sh"
# A short path in /tmp, so the path of a Unix socket stays below the limit of 104 bytes.
tmp=$(mktemp -d /tmp/bifrost-sandbox-test-XXXXXX) || exit 1
# The kernel compares real paths, so the cases use the real path of the temp folder.
tmp=$(cd "$tmp" && pwd -P) || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

failed=0
case=""
case_ok=yes

# Starts the case in $1.
start() {
    case=$1
    case_ok=yes
}

# Records a failure of the current case. $1 is the reason.
fail() {
    echo "FAIL $case: $1"
    case_ok=no
    failed=1
}

# Prints "ok" for the current case when no check of it failed. $1 is an optional note.
finish() {
    if [ "$case_ok" = yes ]; then
        echo "ok $case${1:+ ($1)}"
    fi
}

# The home of the user database. The profile must refuse the real paths under this home.
user=$(id -un) || exit 1
case "$user" in
    "" | *[!A-Za-z0-9._-]*)
        echo "FAIL: the user name has a character that the script does not accept"
        exit 1
        ;;
esac
real_home=$(eval echo "~$user")

# Prints the rule lines that the profile must have for the home in $1.
home_rules() {
    cat <<RULES
(deny file-read* file-write* (subpath "$1/.claude"))
(deny file-read* file-write* (literal "$1/.claude.json"))
(deny file-read* file-write* (subpath "$1/.bifrost"))
(deny file-read* file-write* (subpath "$1/.bifrost-native-dev"))
(deny file-read* file-write* (subpath "$1/Library/Application Support/Bifrost"))
(deny file-read* file-write* (subpath "$1/Library/Application Support/Bifrost Native Dev"))
(deny file-write* (subpath "$1/Library/Logs"))
(deny file-write* (literal "$1/Library"))
(deny file-write* (literal "$1/Library/Application Support"))
(deny network-outbound (subpath "$1/.claude"))
(deny network-outbound (subpath "$1/.bifrost"))
(deny network-outbound (subpath "$1/.bifrost-native-dev"))
(deny network-outbound (subpath "$1/Library/Application Support/Bifrost"))
(deny network-outbound (subpath "$1/Library/Application Support/Bifrost Native Dev"))
RULES
}

# Prints the rule lines that the profile must have one time, for all homes.
global_rules() {
    cat <<'RULES'
(deny network-outbound (remote ip))
(deny network-outbound (literal "/private/var/run/mDNSResponder"))
(deny mach-lookup (global-name "com.apple.dnssd.service"))
(deny mach-lookup (global-name "com.apple.mDNSResponder"))
(deny file-read* (literal "/private/etc/hosts"))
(deny process-exec (literal "/usr/bin/security"))
(deny signal)
(allow signal (target same-sandbox))
RULES
}

# Prints the rule lines that the profile must have for the denied folder in $1 (only for the
# self-test).
deny_rules() {
    cat <<RULES
(deny file-write* (subpath "$1"))
(deny network-outbound (subpath "$1"))
(deny process-exec (literal "$1/true"))
RULES
}

# Prints the exact rule lines of a profile, sorted. $1 is the denied folder, or an empty value.
# The other arguments are the homes, each one time.
expected_rules() {
    deny_folder=$1
    shift
    {
        echo '(version 1)'
        echo '(allow default)'
        for home in "$@"; do
            home_rules "$home"
        done
        global_rules
        if [ -n "$deny_folder" ]; then
            deny_rules "$deny_folder"
        fi
    } | LC_ALL=C sort
}

# Prints the rule lines of the profile text in $1, sorted: each line that is not empty and is not
# a comment. A rule on more than one line, or with a comment after it, gives a line that the
# compare does not expect.
rule_lines() {
    printf '%s\n' "$1" | grep -v -e '^[[:space:]]*;' -e '^[[:space:]]*$' | LC_ALL=C sort
}

# Prints the homes of a run with HOME set to $1: the home of the user database, HOME, and the
# real path of each, each path one time. The wrapper makes the same list.
homes_of_run() {
    for path in "$real_home" "$(cd "$real_home" && pwd -P)" "$1" "$(cd "$1" && pwd -P)"; do
        echo "$path"
    done | awk '!seen[$0]++'
}

# Returns 0 when the text in $1 has each line of the text in $2 as a full line. Else prints the
# first missing line and returns 1.
has_lines() {
    while IFS= read -r wanted; do
        if ! printf '%s\n' "$1" | grep -q -x -F -- "$wanted"; then
            echo "$wanted"
            return 1
        fi
    done <<LINES
$2
LINES
    return 0
}

start theProfileRefusesAWriteToEachDeniedFolder
denied="$tmp/denied"
mkdir -p "$denied/sub" || exit 1
for target in "$denied/file" "$denied/sub/file"; do
    out=$(BIFROST_SANDBOX_DENY="$denied" "$run" /usr/bin/touch "$target" 2>&1)
    code=$?
    if [ "$code" -eq 0 ]; then
        fail "the touch of $target passed"
    elif ! printf '%s\n' "$out" | grep -q "Operation not permitted"; then
        fail "the touch of $target gave exit $code with no refusal: $out"
    elif [ -e "$target" ]; then
        fail "the touch failed, but $target exists"
    fi
done
finish

start theProfileRefusesTheExecOfAProgramInADeniedFolder
# The exec rule of the denied folder is a literal path, as the rule of the Keychain tool is, so
# this case proves that form with a copy of true. The self-test never runs the Keychain tool: the
# exact compare of the rule lines checks its rule. A copy of true elsewhere still runs.
exec_denied="$tmp/exec-denied"
exec_free="$tmp/exec-free"
mkdir -p "$exec_denied" "$exec_free" || exit 1
cp /usr/bin/true "$exec_denied/true" && cp /usr/bin/true "$exec_free/true" || exit 1
out=$(BIFROST_SANDBOX_DENY="$exec_denied" "$run" "$exec_denied/true" 2>&1)
code=$?
if [ "$code" -eq 0 ]; then
    fail "the exec of $exec_denied/true passed"
elif ! printf '%s\n' "$out" | grep -q "Operation not permitted"; then
    fail "the exec of $exec_denied/true gave exit $code with no refusal: $out"
fi
out=$(BIFROST_SANDBOX_DENY="$exec_denied" "$run" "$exec_free/true" 2>&1) ||
    fail "the exec of $exec_free/true failed: $out"
finish

start aWriteElsewhereWorks
target="$tmp/elsewhere/file"
mkdir -p "$tmp/elsewhere" || exit 1
out=$(BIFROST_SANDBOX_DENY="$denied" "$run" /usr/bin/touch "$target" 2>&1)
code=$?
if [ "$code" -ne 0 ]; then
    fail "the touch of $target gave exit $code: $out"
elif [ ! -f "$target" ]; then
    fail "the touch passed, but $target does not exist"
fi
finish

start theExitCodeOfTheCommandPasses
out=$("$run" /bin/sh -c 'exit 3' 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "expected exit 3, got $code: $out"
finish

start theSweepRemovesOnlyTheRenamedFoldersOfTheTests
# The command makes the folders, so the names are of this run. The sweep removes a renamed
# folder of /tmp and of the temp folder of the user. A folder with another name, and a link with
# the name of a renamed folder, stay. The target of the link stays too.
mark=$(printf '%08x' "$$" | cut -c1-8)
uuid=00000000-0000-4000-8000-$(printf '%012x' "$$")
temp_dir=$(getconf DARWIN_USER_TEMP_DIR) || temp_dir=""
gone_short="/tmp/bk-$mark.gone-$uuid"
gone_long="${temp_dir%/}/bifrost-test-$uuid.gone-$uuid"
kept="/tmp/bk-$mark.kept-$uuid"
link="/tmp/bk-$mark.gone-link-$uuid"
target="$tmp/link-target"
out=$("$run" /bin/sh -c "mkdir -p '$gone_short/sub' '$gone_long' '$kept' '$target' &&
    ln -s '$target' '$link'" 2>&1)
code=$?
[ "$code" -eq 0 ] || fail "the command gave exit $code: $out"
[ ! -e "$gone_short" ] || fail "$gone_short is still there"
if [ -n "$temp_dir" ] && [ -e "$gone_long" ]; then
    fail "$gone_long is still there"
fi
[ -d "$kept" ] || fail "$kept is gone"
[ -L "$link" ] || fail "the link $link is gone"
[ -d "$target" ] || fail "the target of the link is gone"
rm -rf "$kept" "$link"
finish

start theProfileRefusesAnOutboundIPConnection
# Outside a sandbox, nothing listens on port 9, so the connect gives ECONNREFUSED.
out=$("$run" /usr/bin/python3 -I -c '
import errno, socket
s = socket.socket()
try:
    s.connect(("127.0.0.1", 9))
    print("connected")
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))
' 2>&1)
[ "$out" = EPERM ] || fail "expected EPERM, got: $out"
finish

start aUnixSocketInATempFolderWorks
out=$("$run" /usr/bin/python3 -I -c '
import socket, sys
path = sys.argv[1]
server = socket.socket(socket.AF_UNIX)
server.bind(path)
server.listen(1)
client = socket.socket(socket.AF_UNIX)
client.connect(path)
peer, _ = server.accept()
client.sendall(b"x")
print("ok" if peer.recv(1) == b"x" else "no data")
' "$tmp/s.sock" 2>&1)
[ "$out" = ok ] || fail "expected ok, got: $out"
finish

start theProfileRefusesAConnectionToASocketInADeniedFolder
# A listener outside the sandbox makes the socket in the denied folder. A file rule does not
# refuse a connection to a socket, so only the network-outbound rule of the folder refuses it.
sockets="$tmp/denied-sockets"
mkdir -p "$sockets" || exit 1
socket="$sockets/s.sock"
/usr/bin/python3 -I -c '
import socket, sys, time
server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.listen(1)
time.sleep(120)
' "$socket" >/dev/null 2>&1 &
listener=$!
# A program start can be slow on a test host, so the wait is up to 60 s.
i=0
while [ ! -S "$socket" ] && [ "$i" -lt 600 ]; do
    sleep 0.1
    i=$((i + 1))
done
if [ ! -S "$socket" ]; then
    fail "the listener made no socket in 60 s"
else
    out=$(BIFROST_SANDBOX_DENY="$sockets" "$run" /usr/bin/python3 -I -c '
import errno, socket, sys
client = socket.socket(socket.AF_UNIX)
try:
    client.connect(sys.argv[1])
    print("connected")
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))
' "$socket" 2>&1)
    [ "$out" = EPERM ] || fail "expected EPERM, got: $out"
fi
kill "$listener" 2>/dev/null
wait "$listener" 2>/dev/null
finish

start theProfileRefusesASignalToAProcessOutsideTheSandbox
# A sleep outside the sandbox stands in for a process of the user, for example a Claude session.
# Signal 0 sends no signal, but the kernel still checks the permission. The TERM case shows that
# the profile refuses a real signal too: the sleep must still run after it.
/bin/sleep 120 </dev/null >/dev/null 2>&1 &
outside=$!
out=$("$run" /usr/bin/python3 -I -c '
import errno, os, signal, sys
pid = int(sys.argv[1])
for number in (0, signal.SIGTERM):
    try:
        os.kill(pid, number)
        print("sent")
    except OSError as e:
        print(errno.errorcode.get(e.errno, e.errno))
' "$outside" 2>&1)
expected='EPERM
EPERM'
[ "$out" = "$expected" ] || fail "expected EPERM for signal 0 and for TERM, got: $out"
kill -0 "$outside" 2>/dev/null || fail "the sleep outside the sandbox stopped"
kill "$outside" 2>/dev/null
wait "$outside" 2>/dev/null
finish

start aSignalToAChildInTheSandboxWorks
# Each child of the command is in the same sandbox, so a test can still stop its own children.
# The shell gives the exit 128 + 15 for a child that TERM stopped. The shell writes its note of
# the stopped job to its stderr, so the inner shell sends its stderr to /dev/null.
out=$("$run" /bin/sh -c 'exec 2>/dev/null; /bin/sleep 120 & kill -TERM $!; wait $!; echo $?' 2>&1)
[ "$out" = 143 ] || fail "expected 143 from the child that TERM stopped, got: $out"
finish

start theCommandGetsThePidOfTheWrapperOutsideTheSandbox
# The guard of the tests (TestSandbox) expects that a signal 0 to this pid fails with EPERM. The
# pid is a process of this user that runs, so only the sandbox refuses the signal.
out=$("$run" /usr/bin/python3 -I -c '
import errno, os
pid = int(os.environ["BIFROST_SANDBOX_PID"])
try:
    os.kill(pid, 0)
    print("sent")
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))
' 2>&1)
[ "$out" = EPERM ] || fail "expected EPERM for a signal to the wrapper, got: $out"
finish

start theProfileRefusesARenameOfLibraryAndApplicationSupport
# A rename of a parent folder would move the folders of the rules out of their paths. The case
# uses another HOME in the temp folder, so a failed rule moves no real folder.
rename_home="$tmp/rename-home"
mkdir -p "$rename_home/Library/Application Support/Bifrost" || exit 1
n=0
for folder in "$rename_home/Library/Application Support" "$rename_home/Library"; do
    n=$((n + 1))
    out=$(HOME="$rename_home" "$run" /bin/mv "$folder" "$tmp/moved-$n" 2>&1)
    code=$?
    if [ "$code" -eq 0 ]; then
        fail "the rename of $folder passed"
    elif ! printf '%s\n' "$out" | grep -q "Operation not permitted"; then
        fail "the rename of $folder gave exit $code with no refusal: $out"
    elif [ ! -d "$folder" ]; then
        fail "the rename failed, but $folder does not exist"
    fi
done
# A write in the folder stays allowed.
out=$(HOME="$rename_home" "$run" /usr/bin/touch "$rename_home/Library/file" 2>&1) ||
    fail "a write in $rename_home/Library failed: $out"
finish

start aRefusalOfTheWrapperGivesExit125
# No script that the wrapper runs uses exit 125. The wrapper refuses a denied folder that does
# not exist before it starts sandbox-exec.
out=$(BIFROST_SANDBOX_DENY="$tmp/missing" "$run" /usr/bin/true 2>&1)
code=$?
[ "$code" -eq 125 ] || fail "expected exit 125, got $code: $out"
finish

start aNameLookupFails
# The lookup of localhost reads /etc/hosts, or asks the resolver through its socket or through
# the dnssd service. The profile refuses each of these, so the lookup fails. 1100 is
# BOOTSTRAP_NOT_PRIVILEGED: the profile refuses the lookup of the service.
out=$("$run" /usr/bin/python3 -I -c '
import ctypes, socket
try:
    socket.getaddrinfo("localhost", 80)
    print("resolved")
except OSError:
    print("no address")
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
port = ctypes.c_uint.in_dll(libc, "bootstrap_port")
service = ctypes.c_uint(0)
print(libc.bootstrap_look_up(port, b"com.apple.dnssd.service", ctypes.byref(service)))
' 2>&1)
expected='no address
1100'
[ "$out" = "$expected" ] || fail "expected no address and 1100, got: $out"
finish

start theProfileHasNoNoSandboxRule
# macOS refuses the exec of a setuid program in a sandbox. No test and no script needs one, so
# the profile runs no program outside the sandbox. A comment line can name the rule type.
profile=$("$run" /bin/sh -c 'cat "$BIFROST_SANDBOX_PROFILE"' 2>&1)
code=$?
if [ "$code" -ne 0 ]; then
    fail "cannot read the profile of a run: exit $code: $profile"
elif lines=$(rule_lines "$profile" | grep -F "no-sandbox"); then
    fail "the profile has a no-sandbox rule: $lines"
fi
finish

start theProfileHasExactlyTheExpectedRules
# A later allow rule has priority over a deny rule. Thus the case compares all rule lines of the
# concrete profile with the exact expected set: an extra, a changed or a missing line fails. The
# first run has the home of the user database as HOME and no denied folder. The second run has
# another HOME and a denied folder.
other="$tmp/exact-home"
denied_exact="$tmp/exact-denied"
mkdir -p "$other" "$denied_exact" || exit 1
for run_case in plain other; do
    if [ "$run_case" = plain ]; then
        home=$real_home
        deny_folder=""
    else
        home=$other
        deny_folder=$denied_exact
    fi
    profile=$(HOME="$home" BIFROST_SANDBOX_DENY="$deny_folder" "$run" /bin/sh -c \
        'cat "$BIFROST_SANDBOX_PROFILE"' 2>&1)
    code=$?
    if [ "$code" -ne 0 ]; then
        fail "$run_case: cannot read the profile of a run: exit $code: $profile"
        continue
    fi
    # The homes are one path on each line, so the expansion splits only at the line ends.
    IFS='
'
    expected_rules "$deny_folder" $(homes_of_run "$home") >"$tmp/expected-$run_case"
    unset IFS
    rule_lines "$profile" >"$tmp/profile-$run_case"
    if ! difference=$(diff "$tmp/expected-$run_case" "$tmp/profile-$run_case"); then
        fail "$run_case: the rule lines differ (< expected, > profile): $difference"
    fi
done
finish

start theProfileNamesEachRealPath
profile=$("$run" /bin/sh -c 'cat "$BIFROST_SANDBOX_PROFILE"' 2>&1)
code=$?
if [ "$code" -ne 0 ]; then
    fail "cannot read the profile of a run: exit $code: $profile"
elif ! missing=$(has_lines "$profile" "$(home_rules "$real_home")
$(global_rules)"); then
    fail "the profile has no line: $missing"
fi
finish

start anotherHomeGetsTheSameRules
other="$tmp/other-home"
mkdir -p "$other" || exit 1
profile=$(HOME="$other" "$run" /bin/sh -c 'cat "$BIFROST_SANDBOX_PROFILE"' 2>&1)
code=$?
if [ "$code" -ne 0 ]; then
    fail "cannot read the profile of a run: exit $code: $profile"
elif ! missing=$(has_lines "$profile" "$(home_rules "$real_home")
$(home_rules "$other")"); then
    fail "the profile has no line: $missing"
fi
finish

# Prints the protected paths of the home in $1, one on each line.
protected_paths() {
    printf '%s\n' "$1/.claude" "$1/.claude.json" "$1/.bifrost" "$1/.bifrost-native-dev" \
        "$1/Library/Application Support/Bifrost" \
        "$1/Library/Application Support/Bifrost Native Dev"
}

start aStatOfEachProtectedPathOfAHomeIsRefused
# macOS gives the refusal only for a path that exists: for a missing path, the lookup ends with
# "No such file or directory" first. So this case makes each protected path in a temp home and
# runs with that HOME, so the profile has the rules of that home. Each stat must give the
# refusal. A run with no profile, or a profile with a missing rule, cannot pass.
stat_home="$tmp/stat-home"
mkdir -p "$stat_home/.claude" "$stat_home/.bifrost" "$stat_home/.bifrost-native-dev" \
    "$stat_home/Library/Application Support/Bifrost" \
    "$stat_home/Library/Application Support/Bifrost Native Dev" || exit 1
: >"$stat_home/.claude.json" || exit 1
while IFS= read -r path; do
    out=$(HOME="$stat_home" "$run" /usr/bin/stat -f %N "$path" 2>&1)
    code=$?
    if [ "$code" -eq 0 ]; then
        fail "the stat of $path passed"
    elif ! printf '%s\n' "$out" | grep -q "Operation not permitted"; then
        fail "the stat of $path gave exit $code with no refusal: $out"
    fi
done <<PATHS
$(protected_paths "$stat_home")
PATHS
finish

start aStatOfEachRealPathThatExistsIsRefused
# Each real path that exists must give the refusal. A missing path holds no data, so the case
# skips it and names it. theProfileNamesEachRealPath proves that the profile has the rule of each
# real path, and aStatOfEachProtectedPathOfAHomeIsRefused proves that such a rule refuses.
refused=0
missing=""
while IFS= read -r path; do
    if [ ! -e "$path" ]; then
        missing="$missing${missing:+, }$path"
        continue
    fi
    out=$("$run" /usr/bin/stat -f %N "$path" 2>&1)
    code=$?
    if [ "$code" -eq 0 ]; then
        fail "the stat of $path passed"
    elif printf '%s\n' "$out" | grep -q "Operation not permitted"; then
        refused=$((refused + 1))
    else
        fail "the stat of $path gave exit $code with no refusal: $out"
    fi
done <<PATHS
$(protected_paths "$real_home")
PATHS
finish "$refused paths refused${missing:+; not on this machine: $missing}"

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo PASS
