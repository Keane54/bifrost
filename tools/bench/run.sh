#!/bin/sh
# One run of the debug bench of the native app (phase 3b, Task 4).
#
# Usage: tools/bench/run.sh [options] <plan> <chats> <out>
#   <plan>   gate (92 s) or short (30 s): the timeline of BenchPlan.swift.
#   <chats>  the number of chats, 1 to 8.
#   <out>    the results file: one JSON line (a BenchSample) for each phase.
# The options give the variant of the run (the runs of Task 5):
#   --no-blur          no blur behind the frames.
#   --no-background    the background stays still.
#   --no-list          no frame of the session list under the chats.
#   --minimised N      N chats go to the side bar (0 to chats - 1).
#   --streaming N      only N chats stream (0 to chats). The other chats stay quiet.
#   --metal N          only N chats draw with Metal (0 to chats). The others use Core Graphics.
#   --scrollback N     the scrollback lines of each chat (0 to 10,000).
#   --normal-screen    the stream stays on the normal screen and fills the scrollback.
#   --idle-wait S      the most seconds to wait until no build and no test runs (default 600).
#   --optimised        build the Debug app with the optimisation of a release (-O, whole module)
#                      in .build/xcode-opt. The app keeps the Debug bundle ID, the test port and
#                      the bench. The shipped app is optimised, so the gates use this build.
#   --trace            record the drag and the resize with Instruments (the template "Animation
#                      Hitches", 25 s), export the tables and delete the trace at once (Task 5).
#
# The script:
# 1. Builds the Debug app with the paths of scripts/check.sh (with --optimised, in its own
#    folder). It never builds or starts the Release app.
# 2. Waits until no build, no test and no other bench runs, and checks that the screen is not
#    locked (pre-flight ruling 10). It removes an old <out>, so a failed run leaves no numbers.
# 3. Starts the app with a short temp test home, the fake claude of scripts/fake-claude first on
#    the PATH and a clean env, on the main display: not headless, with no activation. HOME is
#    the test home. The fake lists 8 sessions and streams in each chat (fake-attach-stream).
#    caffeinate keeps the display awake while the app runs.
# 4. Checks that the window is on the main display (the state of the test port), then sends the
#    bench request and reads the state each second until the run ends. The app puts the window
#    above the windows of the other apps, checks that no window covers all of it, and checks the
#    display period in a warm-up of 2 s. A locked screen or a build or a test during the run
#    stops the run with no result. From the stream phase to the end of the resize phase, the
#    script sends no state request and checks only each 4 s, so it takes no frame from them.
# 5. Copies the results to <out>, quits the app through the test port, stops it by its pid if it
#    still runs, removes the test home and prints the summary (summary.py).
#
# With --trace (pre-flight rulings 3, 11 and 12): the run needs 20 GB free in /tmp, and no other
# trace may run. Before the drag phase, xctrace records the app for 25 s into
# /tmp/bk-trace-<pid of the run>.trace. A watchdog waits for xctrace for the time limit and 60 s.
# With no trace file at that time, it stops xctrace by its pid and logs "Instruments needs
# Developer Tools access": the run keeps the frame counter result. With the trace file, xctrace
# processes the recording and gets up to 300 s more. While xctrace runs, less than 6 GB free in
# /tmp stops it: 25 s of the template write a raw kernel trace of about 15 GB into the temp
# folder of the user. A trace gives the export of its tables in <out without .jsonl>.trace-
# export/. Then the script deletes the trace, the raw kernel trace and the temp store of xctrace
# at once, also after a stop, a failure or a signal. hitches.py then writes <out without
# .jsonl>.hitches.json, and the summary uses it. The script never runs DevToolsSecurity or sudo
# and never changes the authorization database.
#
# Exit 0: the results are in <out>. The summary shows the gates.
# Exit 1: the harness failed: the build, the app, the test port or the run.
# Exit 3: no result: the screen is locked, the window does not show on the main display, the
#         display is not at 120 Hz, or a build, a test or another bench ran. The step goes to
#         the morning list.
#
# The script starts only the app, caffeinate, xctrace (with --trace) and the programs of its
# checks. It stops only the app, caffeinate and xctrace, by their pids, and only while ps still
# gives the name of that program for the pid. It never uses the real home, the real claude or a
# real session.

# -f: no file name expansion. -u: an unset variable is an error.
set -fu

here=$(cd "$(dirname "$0")" && pwd) || exit 1
root=$(cd "$here/../.." && pwd) || exit 1
fake="$root/scripts/fake-claude"
derived="$root/.build/xcode"
lock=/tmp/bk-bench.lock
# The pids of the fake sessions. No process may have them (the smoke test has the same rule).
first_pid=99981
pid=""
caffeinate_pid=""
home=""
log=""
port=""
owns_lock=no
trace=no
trace_pid=""
# The pid of the xctrace of this run, also after it ended: its temp store has the pid in its name.
trace_xpid=""
trace_file=/tmp/bk-trace-$$.trace
trace_marker=""
# The time limit of the trace, and the watchdog: the time limit and 60 s (pre-flight ruling 3).
# When the trace file is there at that time, xctrace processes the recording (more than 60 s for
# 25 s of the template), so it gets up to 300 s more.
trace_limit=25
trace_watchdog=$((trace_limit + 60))
trace_processing=300
# The free space that a trace needs in /tmp, in GB (pre-flight ruling 12), and the least free
# space while it records: 25 s of the template write a raw kernel trace of about 15 GB.
trace_space=20
trace_floor=6

usage() {
    echo "usage: tools/bench/run.sh [--no-blur] [--no-background] [--no-list] [--minimised N]"
    echo "         [--streaming N] [--metal N] [--scrollback N] [--normal-screen]"
    echo "         [--idle-wait S] [--optimised] [--trace] <gate|short> <chats 1 to 8> <out>"
    exit 1
}

fail() {
    echo "FAIL: $1"
    if [ -n "$log" ] && [ -s "$log" ]; then
        echo "app output:"
        tail -n 40 "$log"
    fi
    exit 1
}

no_result() {
    echo "NO RESULT: $1"
    echo "The step goes to the morning list."
    exit 3
}

# Returns 0 while the started app runs. A zombie process counts as stopped.
is_running() {
    [ -n "$pid" ] || return 1
    state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$state" in
        "" | Z*) return 1 ;;
    esac
    return 0
}

# Returns 0 when the pid is still the program of the name (the last part of its path), so a
# kill never goes to another process that got the pid. Arguments: the pid and the name.
is_program() {
    [ -n "$1" ] || return 1
    command_name=$(ps -o comm= -p "$1" 2>/dev/null)
    case "$command_name" in
        "$2" | */"$2") return 0 ;;
    esac
    return 1
}

# Sends TERM to the started app and waits up to 5 s for the exit, then sends KILL. Each kill
# goes only to the pid of the app while that pid is still the app.
stop_app() {
    [ -n "$pid" ] || return 0
    if is_running && is_program "$pid" "Bifrost Dev"; then
        kill -TERM "$pid" 2>/dev/null
        i=0
        while is_running && [ "$i" -lt 50 ]; do
            sleep 0.1
            i=$((i + 1))
        done
        is_running && is_program "$pid" "Bifrost Dev" && kill -KILL "$pid" 2>/dev/null
    fi
    wait "$pid" 2>/dev/null
    pid=""
}

# Sends TERM to xctrace and waits up to 10 s for the exit, then sends KILL. Each kill goes only
# to the pid of xctrace while that pid is still xctrace.
stop_trace() {
    [ -n "$trace_pid" ] || return 0
    if is_program "$trace_pid" xctrace; then
        kill -TERM "$trace_pid" 2>/dev/null
        i=0
        while is_program "$trace_pid" xctrace && [ "$i" -lt 100 ]; do
            sleep 0.1
            i=$((i + 1))
        done
        is_program "$trace_pid" xctrace && kill -KILL "$trace_pid" 2>/dev/null
    fi
    wait "$trace_pid" 2>/dev/null
    trace_pid=""
}

# Deletes the trace and the temp data of the xctrace of this run: the raw kernel trace
# (instruments*.ktrace in the temp folder of the user, made after the start of the trace) and
# the temp store of xctrace (xrtmp__<pid>.* in the cache folder of the user). A stopped xctrace
# leaves them (about 15 GB for 25 s).
remove_trace_data() {
    rm -rf "$trace_file"
    [ -n "$trace_marker" ] && [ -f "$trace_marker" ] || return 0
    temp_dir=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)
    if [ -n "$temp_dir" ] && [ -d "$temp_dir" ]; then
        find "$temp_dir" -maxdepth 1 -type f -name 'instruments*.ktrace' -newer "$trace_marker" \
            -exec rm -f {} + 2>/dev/null
    fi
    cache_dir=$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null)
    store="$cache_dir/com.apple.dt.InstrumentsCLI/path_manager"
    if [ -n "$trace_xpid" ] && [ -n "$cache_dir" ] && [ -d "$store" ]; then
        find "$store" -maxdepth 1 -name "xrtmp__$trace_xpid.*" -exec rm -rf {} + 2>/dev/null
    fi
}

# The free space in /tmp in GB.
free_gb() {
    free_kb=$(df -k /tmp | awk 'NR == 2 { print $4 }')
    case "$free_kb" in
        "" | *[!0-9]*) echo 0 ;;
        *) echo $((free_kb / 1048576)) ;;
    esac
}

cleanup() {
    stop_trace
    remove_trace_data
    stop_app
    if [ -n "$caffeinate_pid" ]; then
        is_program "$caffeinate_pid" caffeinate && kill -TERM "$caffeinate_pid" 2>/dev/null
        wait "$caffeinate_pid" 2>/dev/null
    fi
    [ -n "$home" ] && rm -rf "$home"
    if [ "$owns_lock" = yes ] && [ "$(readlink "$lock" 2>/dev/null)" = "$$" ]; then
        rm -f "$lock"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# A whole number in a range. Arguments: the value, the lowest value and the highest value.
in_range() {
    case "$1" in
        "" | *[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

variant=""
normal_screen=no
idle_wait=600
optimised=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-blur) variant="$variant,\"blur\":false" ;;
        --no-background) variant="$variant,\"background\":false" ;;
        --no-list) variant="$variant,\"list\":false" ;;
        --minimised | --streaming | --metal | --scrollback)
            if [ "$#" -lt 2 ] || ! in_range "$2" 0 10000; then usage; fi
            variant="$variant,\"${1#--}\":$2"
            shift
            ;;
        --normal-screen) normal_screen=yes ;;
        --optimised) optimised=yes ;;
        --trace) trace=yes ;;
        --idle-wait)
            if [ "$#" -lt 2 ] || ! in_range "$2" 0 86400; then usage; fi
            idle_wait=$2
            shift
            ;;
        --*) usage ;;
        *) break ;;
    esac
    shift
done
[ "$#" -eq 3 ] || usage
plan=$1
chats=$2
out=$3
# The seconds of the plan, and of its stream, drag and resize phases (BenchPlan.swift).
case "$plan" in
    gate)
        plan_seconds=92
        measured_seconds=32
        stream_seconds=12
        ;;
    short)
        plan_seconds=30
        measured_seconds=10
        stream_seconds=3
        ;;
    *) usage ;;
esac
in_range "$chats" 1 8 || usage

[ -f "$root/Bifrost.xcodeproj/project.pbxproj" ] || fail "$root is not the repo"
[ -x "$fake/claude" ] || fail "no fake claude at $fake/claude"
mkdir -p "$root/.build/bench" || fail "cannot make $root/.build/bench"
out_dir=$(dirname "$out")
mkdir -p "$out_dir" || fail "cannot make $out_dir"
[ -d "$out" ] && fail "$out is a folder"

# One bench at a time (pre-flight ruling 10). The lock is a symbolic link whose target is the
# pid of the run, so ln makes the lock and its pid in one step. A lock whose pid is gone is from
# a run that stopped with no cleanup. A lock with no pid counts as held.
take_lock() {
    [ -e "$lock" ] || [ -L "$lock" ] && return 1
    ln -s -h "$$" "$lock" 2>/dev/null
}
if ! take_lock; then
    holder=$(readlink "$lock" 2>/dev/null)
    case "$holder" in
        "" | *[!0-9]*) no_result "$lock holds no pid of a run: remove it when no bench runs" ;;
    esac
    ps -p "$holder" >/dev/null 2>&1 && no_result "another bench run (pid $holder) holds $lock"
    rm -f "$lock"
    take_lock || no_result "another bench run holds $lock"
fi
owns_lock=yes
# A failed run must leave no older numbers in the results file.
rm -f "$out" || fail "cannot remove the old results file $out"
base=${out%.jsonl}
export_dir="$base.trace-export"
hitches_file="$base.hitches.json"
rm -rf "$export_dir" "$hitches_file" || fail "cannot remove the old trace results of $out"
if [ "$trace" = yes ]; then
    free=$(free_gb)
    [ "$free" -ge "$trace_space" ] ||
        no_result "--trace needs $trace_space GB free in /tmp, and $free GB is free"
    # The path of xctrace itself, so its pid is the pid of xctrace (not of xcrun).
    xctrace=$(xcrun -f xctrace 2>/dev/null) || fail "no xctrace (Xcode)"
    [ -x "$xctrace" ] || fail "no xctrace at $xctrace"
fi

# 1. The Debug app, with the paths of scripts/check.sh. The optimised build has its own folder,
# so the build of check.sh does not change.
build_log="$root/.build/bench/build.log"
set --
if [ "$optimised" = yes ]; then
    derived="$root/.build/xcode-opt"
    # The plain Debug app has no hardened runtime (its code is in the debug dylib). Without
    # this, the optimised app refuses the ad hoc signature of the Sparkle framework.
    set -- SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule \
        ENABLE_HARDENED_RUNTIME=NO
fi
app="$derived/Build/Products/Debug/Bifrost Dev.app"
echo "building the Debug app (optimised: $optimised, log: $build_log)"
(
    cd "$root" &&
        xcodebuild -project Bifrost.xcodeproj -scheme Bifrost -configuration Debug \
            -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
            -clonedSourcePackagesDirPath .build/spm "$@" build
) >"$build_log" 2>&1 || fail "the Debug build failed (log: $build_log)"
binary="$app/Contents/MacOS/Bifrost Dev"
[ -x "$binary" ] || fail "no executable at $binary"

# 2. The checks before the run.
# The names of the build and test programs that run now (a bench needs an idle Mac).
busy() {
    for name in xcodebuild swift-build swift-test swift-frontend swiftc xctest \
        swiftpm-testing-helper clang ld; do
        pgrep -x "$name" >/dev/null 2>&1 && printf '%s ' "$name"
    done
    # Another trace. The xctrace of this run (or a child of it) does not count.
    for other in $(pgrep -x xctrace 2>/dev/null); do
        [ "$other" = "$trace_pid" ] && continue
        [ -n "$trace_pid" ] && [ "$(ps -o ppid= -p "$other" 2>/dev/null | tr -d ' ')" = \
            "$trace_pid" ] && continue
        printf '%s ' xctrace
        break
    done
    pgrep -f 'stryker|vitest' >/dev/null 2>&1 && printf '%s ' stryker
}

# True when the screen is locked: the console session has CGSSessionScreenIsLocked.
screen_locked() {
    ioreg -n Root -d1 -a 2>/dev/null | grep -A1 -F CGSSessionScreenIsLocked |
        grep -q -F '<true/>'
}

waited=0
running=$(busy)
while [ -n "$running" ]; do
    [ "$waited" -lt "$idle_wait" ] || no_result "a build or a test runs: $running"
    [ "$waited" -eq 0 ] && echo "waiting until no build and no test runs: $running"
    sleep 5
    waited=$((waited + 5))
    running=$(busy)
done
screen_locked && no_result "the screen is locked"

n=0
while [ "$n" -lt 8 ]; do
    session_pid=$((first_pid + n))
    if ps -p "$session_pid" >/dev/null 2>&1; then
        fail "a process with the fake session pid $session_pid runs"
    fi
    n=$((n + 1))
done

# 3. The test home: a short path, so the socket paths stay below the limit of 103 bytes.
home=$(mktemp -d /tmp/bk-XXXXXXXX) || fail "cannot make a temp home"
support="$home/Library/Application Support/Bifrost Native Dev"
registry="$support/registry.json"
port="$home/.bifrost-native-dev/test.sock"
log="$home/app.log"
results="$home/bench/run.jsonl"

# 8 background sessions in folders of the test home. The chats use the first sessions.
{
    echo "["
    n=1
    while [ "$n" -le 8 ]; do
        mkdir -p "$home/sessions/$n" || fail "cannot make a session folder"
        [ "$n" -gt 1 ] && echo ","
        printf '  {"cwd": "%s", "id": "be0c000%s", "kind": "background",' "$home/sessions/$n" "$n"
        printf ' "name": "bench-%s", "pid": %s,' "$n" "$((first_pid + n - 1))"
        printf ' "sessionId": "be0c000%s-0000-4000-8000-00000000000%s",' "$n" "$n"
        printf ' "startedAt": 179390000%s000, "status": "idle"}\n' "$n"
        n=$((n + 1))
    done
    echo "]"
} >"$home/fake-agents.json" || fail "cannot write fake-agents.json"
if [ "$normal_screen" = yes ]; then
    : >"$home/fake-attach-stream-normal"
else
    : >"$home/fake-attach-stream"
fi

# The env of the app has only these variables, as in scripts/smoke.sh. The PATH has only the
# fake claude and the system folders. No BIFROST_TEST_HEADLESS: the window shows.
set -- "BIFROST_TEST_HOME=$home" "HOME=$home" "PATH=$fake:/usr/bin:/bin"
for key in USER LANG TMPDIR; do
    eval "isset=\${$key+x}"
    if [ -n "$isset" ]; then
        eval "value=\$$key"
        set -- "$@" "$key=$value"
    fi
done
env -i "$@" "$binary" >"$log" 2>&1 &
pid=$!
caffeinate -dimsu -w "$pid" &
caffeinate_pid=$!
echo "started the app (pid $pid) with the test home $home"

# Sends one line to the test port and prints the answer line.
request() {
    printf '%s\n' "$1" | nc -U -w 10 "$port" 2>/dev/null
}

# Waits until a command succeeds. Arguments: the limit in seconds, the text of the failure and
# the command.
wait_until() {
    limit=$1
    what=$2
    shift 2
    i=0
    while ! "$@"; do
        is_running || fail "the app stopped before $what"
        [ "$i" -lt "$((limit * 10))" ] || return 1
        sleep 0.1
        i=$((i + 1))
    done
}

listed() { grep -q -F be0c0008 "$registry" 2>/dev/null; }
# The window is on the main display and on the active space. The bench then puts it above the
# windows of the other apps and checks that no window covers all of it.
on_main_display() {
    request '{"op":"state"}' | grep -q -F '"main":true,"space":true,'
}

wait_until 30 "the test port" test -S "$port" || fail "no test port at $port in 30 s"
wait_until 30 "the session list" listed || fail "registry.json did not list 8 sessions in 30 s"
wait_until 15 "the window" on_main_display ||
    no_result "the window does not show on the main display and the active space"

# 4. The run.
request_line="{\"op\":\"bench\",\"plan\":\"$plan\",\"chats\":$chats,\"name\":\"run\"$variant}"
answer=$(request "$request_line")
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for $request_line"
echo "the bench runs: $request_line"

# The checks of the run: the app runs, the screen is not locked, and no build or test runs.
check_run() {
    is_running || fail "the app stopped during the run"
    screen_locked && no_result "the screen locked during the run"
    running=$(busy)
    [ -z "$running" ] || no_result "a build or a test ran during the run: $running"
}

# The trace: xctrace records the app for the time limit, from 4 s before the drag. It needs the
# Developer Tools access. Without the access, it waits for a password that nobody gives, so the
# watchdog stops it (pre-flight ruling 3).
trace_log="$home/xctrace.log"
trace_at=0
trace_started=0
trace_state=none
processing_told=no
start_trace() {
    echo "xctrace records the app for $trace_limit s (watchdog: $trace_watchdog s)"
    trace_marker="$home/trace-start"
    : >"$trace_marker"
    "$xctrace" record --template 'Animation Hitches' --attach "$pid" \
        --time-limit "${trace_limit}s" --output "$trace_file" --no-prompt >"$trace_log" 2>&1 &
    trace_pid=$!
    trace_xpid=$trace_pid
    trace_started=$elapsed
    trace_state=recording
}
# Stops xctrace and deletes the trace and its temp data. Sets trace_state to stopped.
end_trace() {
    echo "$1"
    stop_trace
    remove_trace_data
    trace_state=stopped
}
# Checks the trace: it ended, or the watchdog stops it, or the disk is nearly full. Sets
# trace_state to ended or stopped.
watch_trace() {
    [ "$trace_state" = recording ] || return 0
    if ! is_program "$trace_pid" xctrace; then
        wait "$trace_pid" 2>/dev/null
        trace_pid=""
        trace_state=ended
        return 0
    fi
    free=$(free_gb)
    if [ "$free" -lt "$trace_floor" ]; then
        end_trace "the trace stopped: $free GB is free in /tmp, less than $trace_floor GB"
        return 0
    fi
    waited=$((elapsed - trace_started))
    [ "$waited" -ge "$trace_watchdog" ] || return 0
    if [ ! -e "$trace_file" ]; then
        end_trace "Instruments needs Developer Tools access"
        return 0
    fi
    if [ "$processing_told" = no ]; then
        echo "xctrace processes the recording (up to $trace_processing s more)"
        processing_told=yes
    fi
    [ "$waited" -ge "$((trace_watchdog + trace_processing))" ] || return 0
    end_trace "xctrace did not end in $((trace_watchdog + trace_processing)) s: the script stops it"
}

# The state requests go to the main actor of the app, and the checks start programs. So from
# the start of the stream phase to the end of the resize phase, the script sends no state
# request and runs its checks (and the watchdog of the trace) only each 4 s.
limit=$((plan_seconds + 150))
elapsed=0
quiet_until=0
status=""
last_phase=""
while :; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$trace" = yes ] && [ "$trace_state" = none ] && [ "$trace_at" -gt 0 ] &&
        [ "$elapsed" -ge "$trace_at" ]; then
        start_trace
    fi
    if [ "$elapsed" -lt "$quiet_until" ]; then
        if [ "$(((quiet_until - elapsed) % 4))" -eq 0 ]; then
            check_run
            watch_trace
        fi
        continue
    fi
    check_run
    watch_trace
    state=$(request '{"op":"state"}')
    status=$(printf '%s' "$state" | grep -o '"status":"[a-z]*"' | sed -e 's/.*:"//' -e 's/"$//')
    phase=$(printf '%s' "$state" | grep -o '"phase":"[a-z]*"' | sed -e 's/.*:"//' -e 's/"$//')
    if [ -n "$phase" ] && [ "$phase" != "$last_phase" ]; then
        background=$(printf '%s' "$state" | grep -o '"background":"[a-z]*"' |
            sed -e 's/.*:"//' -e 's/"$//')
        echo "phase $phase (background: $background)"
        last_phase=$phase
        if [ "$phase" = stream ] && [ "$quiet_until" -eq 0 ]; then
            quiet_until=$((elapsed + measured_seconds + 1))
            echo "no state requests for $measured_seconds s (stream, drag and resize)"
            # The stream started in the last second. The trace starts 4 s before the drag.
            delay=$((stream_seconds - 4))
            [ "$delay" -ge 1 ] || delay=1
            trace_at=$((elapsed + delay))
        fi
    fi
    case "$status" in
        done | failed) break ;;
    esac
    [ "$elapsed" -lt "$limit" ] || fail "the run did not end in $limit s"
done
if [ "$status" = failed ]; then
    reason=$(printf '%s' "$state" | grep -o '"reason":"[^"]*"' | sed -e 's/^"reason":"//' \
        -e 's/"$//')
    # The app marks a failed check of the display or of the window with "check":true.
    printf '%s' "$state" | grep -q -F '"check":true' && no_result "$reason"
    fail "the run failed: $reason"
fi
[ -s "$results" ] || fail "no results file at $results"
cp "$results" "$out" || fail "cannot copy the results to $out"

# The end of the trace: xctrace ends after its time limit, or the watchdog stops it.
if [ "$trace" = yes ]; then
    [ "$trace_state" = none ] && echo "the trace did not start: the run ended first"
    while [ "$trace_state" = recording ]; do
        sleep 1
        elapsed=$((elapsed + 1))
        watch_trace
    done
fi

# 5. The quit through the test port. The cleanup stops the app if it still runs.
answer=$(request '{"op":"quit"}')
i=0
while is_running && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
done
stop_app

# The export of the trace, then its delete at once (a trace uses 5 to 8 GB). The export stays
# next to the results, so hitches.py can read it again.
if [ "$trace" = yes ] && [ "$trace_state" = ended ]; then
    if [ -d "$trace_file" ]; then
        echo "the trace has $(du -sh "$trace_file" | cut -f 1)"
        mkdir -p "$export_dir" || fail "cannot make $export_dir"
        exported=yes
        "$xctrace" export --input "$trace_file" --toc --output "$export_dir/toc.xml" \
            >>"$trace_log" 2>&1 || exported=no
        for schema in time-info hitches hitches-frame-lifetimes hitches-lifetime-interval \
            hitches-summary display-surface-swap displayed-surfaces-interval; do
            xpath="/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]"
            "$xctrace" export --input "$trace_file" --xpath "$xpath" \
                --output "$export_dir/$schema.xml" >>"$trace_log" 2>&1 || exported=no
        done
        remove_trace_data
        cp "$trace_log" "$export_dir/xctrace.log"
        [ "$exported" = yes ] || echo "xctrace export failed (log: $export_dir/xctrace.log)"
        if python3 -I "$here/hitches.py" "$export_dir" "$out" >"$hitches_file"; then
            echo "Instruments result: $hitches_file"
        else
            rm -f "$hitches_file"
            echo "hitches.py gave no result: the run keeps the frame counter result"
        fi
    else
        echo "xctrace ended with no trace: the run keeps the frame counter result"
        tail -n 5 "$trace_log"
    fi
fi
[ "$trace" = yes ] && remove_trace_data

echo "results: $out"
if [ -s "$hitches_file" ]; then
    python3 -I "$here/summary.py" --hitches "$hitches_file" "$out"
else
    if [ "$trace" = yes ]; then
        echo "no Instruments result: the drag and resize gates use the frame counter (provisional)"
    fi
    python3 -I "$here/summary.py" "$out"
fi
exit 0
