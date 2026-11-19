#!/bin/sh
# Smoke test of a development build of the app.
#
# Usage: scripts/smoke.sh <path to .app>
#
# The script starts the app in a temp home, with the fake claude of scripts/fake-claude and the fake
# gh of scripts/fake-gh first on the PATH and a clean env: only BIFROST_TEST_HOME, HOME, PATH, USER,
# LANG and TMPDIR, as in the smoke test of the Electron app, and BIFROST_TEST_HEADLESS=1 (no window
# and no Dock icon). HOME is the temp home, so a program that the app runs never reads the real
# ~/.claude. The fake claude exits 1 with another HOME. Before the start, the script puts the
# fixture folder of the Electron app (scripts/smoke-fixtures/electron-support) in the temp home,
# read only. The app must:
# - make its data folders and import the fixture stores one time: the marker import.json is in
#   the support folder, the state of the test port shows the import report, and the Electron
#   folder keeps its names, modes, modification times and bytes;
# - show the three sessions of the fake claude in the imported Overview, in reverse name order
#   with the imported local name on the fixture row, and in name order after a sort by name
#   through the test port; a sort of overview:2, which is not open, gives an error;
# - open the chat of the fixture session through the debug test port: the fake attach starts,
#   the typed text and Shift+Enter (ESC CR) reach it, and the state of the port shows the chat
#   as attached;
# - dictate with the fake speech engine: a hold of Space of 800 ms types the text of the fake
#   helper into the session, the microphone of the fake engine opens one time and closes, and a
#   tap of 50 ms adds one space;
# - list a new session in registry.json;
# - own Live details and the skills through the test port, with no plugin of the fake claude at
#   the start, so the start rule does not listen: Install of Live details runs the plugin
#   commands (claude-calls.log), copies the four mod files of the bundle with their bytes to
#   <temp home>/.bifrost/mod, listens on the shared socket of the temp home,
#   <temp home>/.bifrost/live.sock, and answers a Live details line; the line gives one entry in
#   the Event log;
# - show the watched fixture row in the Watchlist (the fixture registry watches it);
# - show the PR of fake-pr.json in Show Info of the fixture row: the fixture folder has a HEAD
#   file, and the fake gh runs in that folder;
# - with Live details on: a forged session.end line for a new background entry with no pid and
#   no status, as Claude Code gives in the 2.5 s after a start, parks its row, and Resume refuses
#   it; Turn off runs a plugin command and removes the socket; Install of the skills runs the
#   plugin commands and copies the skills folder of the bundle with its bytes to
#   <temp home>/.bifrost/skills;
# - change the settings through the test port: a patch of interfaceScale saves 120 in
#   settings.json, a key patch of close-panel:mod changes the key of Close Panel in the menu that
#   the app installed, and a key patch with a conflict is refused, with no change of the file;
# - run Reviews against the fake gh and a local bare repository of the test home, with the
#   automatic rounds off: Watch GitHub on through the test port shows the My PRs row, a review
#   request that comes after the first turn-on flashes, Pause stops the flash, and Review runs a
#   round in a bifrost-test- session of the fake claude. Its result gives one pending review with
#   no event in gh-writes.jsonl, no other write, and a Draft ready row;
# - run the session actions through the test port and the action runner, with the fake claude
#   commands: a send of hello types into the fake attach of the fixture session, Rename with a
#   name sets the local name in registry.json, New session in a session folder of the test home
#   runs "claude --bg" and gives a new row with its chat, Stop of the fixture session runs
#   "claude stop 5a0e0001", and Delete with the confirmation runs "claude rm 5a0e0001", the row
#   goes and its chat closes. Each action ends with no error line;
# - open the Release notes dialog through the test port: it lists the releases of
#   github-releases.json of the temp home (the page of each release is below the Releases page of
#   the Info.plist), newest first, with no request to GitHub;
# - run the Daily update through the test port with one work area, a board source and no merged
#   PRs (so no gh runs): the probe of the fake claude prints fake-mcp-init.json and the run prints
#   fake-daily-result.json, Refresh fills the tab of the area, and Mark as sent clears its marker;
# - give a level of the Performance monitor in the state of the test port: the monitor of a test
#   home has no network reader and no GitHub points, so it makes no request;
# - quit through the test port, keep the chat panel of the new session (and not the chat of the
#   deleted session) and the imported Overview with the new sort in ui-state.json, and keep a
#   window-state.json.
# The app never runs the real claude, never attaches to a real session, and it never uses the
# real home for its data. The real ~/.claude and ~/.bifrost stay as they were: the test sandbox
# (scripts/run-sandboxed.sh) refuses each read and write there. A test home uses the fake speech
# engine, so the app never opens the microphone, never plays audio and never downloads a speech
# model.
#
# Exit 0: all checks passed and the app stopped. The script prints PASS.
# Exit 1: a check failed. The script prints the reason.
# Exit 2: the app is not a development build. The script does not start it.
#
# The script starts only the app that it checks. It stops only that process, by its pid.

# -f: no file name expansion. -u: an unset variable is an error.
set -fu

here=$(cd "$(dirname "$0")" && pwd) || exit 1
fake="$here/fake-claude"
fake_gh="$here/fake-gh"
# The fixture files of the Electron app. The registry gives the local name of the fixture
# session. The UI state has one layout with overview:1 and the config of that Overview: one tab
# that shows all sessions, sorted by name in reverse order.
fixtures="$here/smoke-fixtures/electron-support"
fixture_stores="registry.json ui-state.json"
# The session of the first entry of the list of the fake claude, and its local name in the
# fixture registry.
fixture_session=5a0e0001-0000-4000-8000-000000000001
local_name=smoke-imported
# The local name that Rename gives the fixture session.
new_name=smoke-renamed
# The other two sessions of the first list of the fake claude.
beta_session=5a0e0002-0000-4000-8000-000000000002
gamma_session=5a0e0003-0000-4000-8000-000000000003
# The new session that the script adds to the list of the fake claude.
new_session=5a0e0004-0000-4000-8000-000000000004
# A session that starts: a background entry with no pid and no status.
starting_session=5a0e0005-0000-4000-8000-000000000005
# The session that New session starts: the fake claude gives the first new session this ID.
started_session=5b0e0001-0000-4000-8000-000000000001
buddy=/usr/libexec/PlistBuddy
audio=com.apple.security.device.audio-input
# Xcode adds this entitlement for the debugger when it signs a build to run locally.
debugger=com.apple.security.get-task-allow
pid=""
home=""
log=""
port=""

fail() {
    echo "FAIL: $1"
    if [ -n "$log" ] && [ -s "$log" ]; then
        echo "app output:"
        cat "$log"
    fi
    exit 1
}

# Returns 0 while the started app runs. The app is a child of this shell, and the shell reaps
# an ended child at once, so the check fails after the exit. Signal 0 sends no signal. The
# script runs no ps: ps is a setuid program, and the test sandbox refuses it.
is_running() {
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

# Sends TERM to the started app and waits up to 5 s for the exit.
# If the app still runs, sends KILL and returns 1.
stop_app() {
    [ -n "$pid" ] || return 0
    result=0
    if is_running; then
        kill -TERM "$pid" 2>/dev/null
        i=0
        while is_running && [ "$i" -lt 50 ]; do
            sleep 0.1
            i=$((i + 1))
        done
        if is_running; then
            kill -KILL "$pid" 2>/dev/null
            result=1
        fi
    fi
    wait "$pid" 2>/dev/null
    pid=""
    return "$result"
}

# Removes the temp home. The fixture Electron folder in it is read only, so each item of the home
# gets the write permission of the owner first.
remove_home() {
    if [ -n "$home" ]; then
        chmod -R u+w "$home" 2>/dev/null
        rm -rf "$home"
    fi
    home=""
}

cleanup() {
    stop_app
    remove_home
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ "$#" -eq 1 ] || fail "usage: smoke.sh <path to .app>"
app=$1
plist="$app/Contents/Info.plist"
[ -f "$plist" ] || fail "no Info.plist at $plist"

bundle_id=$("$buddy" -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null) ||
    fail "no CFBundleIdentifier in $plist"
case "$bundle_id" in
    *.native-dev) ;;
    *)
        echo "refused: not a development build"
        exit 2
        ;;
esac

executable=$("$buddy" -c "Print :CFBundleExecutable" "$plist" 2>/dev/null) ||
    fail "no CFBundleExecutable in $plist"
binary="$app/Contents/MacOS/$executable"
[ -f "$binary" ] && [ -x "$binary" ] || fail "no executable at $binary"

out=$(codesign --verify --strict "$app" 2>&1) || fail "the signature is not valid: $out"

# The app must have the audio input entitlement. Only the debugger entitlement can be there too.
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null) ||
    fail "cannot read the entitlements"
keys=$(printf '%s\n' "$entitlements" | grep -o '<key>[^<]*</key>' |
    sed -e 's/<key>//' -e 's/<\/key>//')
has_audio=no
for key in $keys; do
    case "$key" in
        "$audio") has_audio=yes ;;
        "$debugger") ;;
        *) fail "unexpected entitlement: $key" ;;
    esac
done
[ "$has_audio" = yes ] || fail "missing entitlement: $audio"

# The app must hold the Sparkle framework. The app loads it when the script starts the app below.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
[ -d "$sparkle" ] || fail "no Sparkle framework at $sparkle"

# A development build must have no update feed. Then it cannot update to the release app.
if "$buddy" -c "Print :SUFeedURL" "$plist" >/dev/null 2>&1; then
    fail "the Info.plist has an SUFeedURL"
fi

[ -x "$fake/claude" ] || fail "no fake claude at $fake/claude"
[ -x "$fake_gh/gh" ] || fail "no fake gh at $fake_gh/gh"

# A short path, so the socket path in the home stays below the limit of 103 bytes.
home=$(mktemp -d /tmp/bk-XXXXXXXX) || fail "cannot make a temp home"
# The folders of the sessions are in the temp home, so two runs at the same time share no
# folder. The attach starts in the folder of its session, and it cannot start in a folder that
# does not exist.
sessions="$home/sessions"
for name in alpha beta gamma delta epsilon; do
    mkdir -p "$sessions/$name" || fail "cannot make $sessions/$name"
done
# The folder of the fixture session is on a branch, so Show Info looks up its PR. The branch
# reader reads the HEAD file and runs no git. The fake gh prints fake-pr.json.
mkdir -p "$sessions/alpha/.git" || fail "cannot make $sessions/alpha/.git"
printf 'ref: refs/heads/smoke-pr\n' >"$sessions/alpha/.git/HEAD" ||
    fail "cannot write the HEAD file"
cat >"$home/fake-pr.json" <<'EOF' || fail "cannot write fake-pr.json"
{"number":42,"title":"Smoke PR","url":"https://example.invalid/pr/42","state":"OPEN"}
EOF
# The list of the fake claude for "agents --json" and "agents --json --all": an idle background
# session, a busy interactive session and a second idle background session. With the local name
# of the first session, neither name order is the order of the list. The app has not started,
# so no run reads the file yet.
cat >"$home/fake-agents.json" <<EOF || fail "cannot write fake-agents.json"
[
  {
    "cwd": "$sessions/alpha",
    "id": "5a0e0001",
    "kind": "background",
    "name": "smoke-alpha",
    "pid": 99991,
    "sessionId": "$fixture_session",
    "startedAt": 1793900000000,
    "status": "idle"
  },
  {
    "cwd": "$sessions/beta",
    "id": "5a0e0002",
    "kind": "interactive",
    "name": "smoke-beta",
    "pid": 99992,
    "sessionId": "$beta_session",
    "startedAt": 1793900001000,
    "status": "busy"
  },
  {
    "cwd": "$sessions/gamma",
    "id": "5a0e0003",
    "kind": "background",
    "name": "smoke-gamma",
    "pid": 99993,
    "sessionId": "$gamma_session",
    "startedAt": 1793900002000,
    "status": "idle"
  }
]
EOF
support="$home/Library/Application Support/Bifrost Native Dev"
dot="$home/.bifrost-native-dev"
registry="$support/registry.json"
socket="$home/.bifrost/live.sock"
port="$dot/test.sock"
log="$home/app.log"
ui_state="$support/ui-state.json"
window_state="$support/window-state.json"
chat="chat:$fixture_session"
short_id=5a0e0001
input="$home/attach-input-$short_id.log"
electron="$home/Library/Application Support/Bifrost"

# The support folder of the Electron app in the temp home: the fixture stores, read only (the
# folder at mode 0500 and its files at 0400). The import must only read it.
mkdir -p "$electron" || fail "cannot make $electron"
for name in $fixture_stores; do
    cp "$fixtures/$name" "$electron/$name" || fail "cannot copy the fixture $name"
    chmod 0400 "$electron/$name" || fail "cannot set the mode of the fixture $name"
done
chmod 0500 "$electron" || fail "cannot set the mode of $electron"

# Prints the mode, size, modification time and path of the Electron folder and of each item in
# it, then the SHA-256 hash of each file, each list in sort order.
electron_items() {
    find "$electron" -exec stat -f '%Lp %z %m %N' {} + | sort &&
        find "$electron" -type f -exec shasum -a 256 {} + | sort
}
electron_before=$(electron_items) || fail "cannot read the Electron folder"

# The fake claude has no plugin state (no fake-plugins.json): Live details and the skills are not
# installed. The start rule of the app then does not listen. Each plugin command of the fake adds
# its line to claude-calls.log.
mod="$home/.bifrost/mod"
skills="$home/.bifrost/skills"
calls="$home/claude-calls.log"
resources="$app/Contents/Resources"

# The env of the app has only these variables (carried item 5). The PATH has only the fake claude
# and the system folders. Thus the app cannot find the real claude. HOME is the test home, so the
# env of each claude run has no path to the real home. The app finds the real home in the user
# database, not in HOME, so it accepts the test home.
set -- "BIFROST_TEST_HOME=$home" "HOME=$home" "PATH=$fake:$fake_gh:/usr/bin:/bin" \
    "BIFROST_TEST_HEADLESS=1"
for key in USER LANG TMPDIR; do
    eval "isset=\${$key+x}"
    if [ -n "$isset" ]; then
        eval "value=\$$key"
        set -- "$@" "$key=$value"
    fi
done
env -i "$@" "$binary" >"$log" 2>&1 &
pid=$!

i=0
while [ ! -d "$support" ] || [ ! -d "$dot" ]; do
    is_running || fail "the app stopped before it made its data folders"
    [ "$i" -lt 150 ] || fail "the app did not make its data folders in 15 s"
    sleep 0.1
    i=$((i + 1))
done

# Waits until registry.json holds a session ID. Arguments: the ID, the limit in seconds and the
# name of the session for the messages.
wait_for_session() {
    i=0
    while ! grep -q -F "$1" "$registry" 2>/dev/null; do
        is_running || fail "the app stopped before registry.json listed $3"
        [ "$i" -lt "$(($2 * 10))" ] || fail "registry.json did not list $3 in $2 s"
        sleep 0.1
        i=$((i + 1))
    done
    echo "registry.json lists $3 after $((i / 10)).$((i % 10)) s"
}

# Sends one line to the test port and prints the answer line. nc ends when the app closes the
# connection after its answer. An action answers at the end of its run, and the test port gives
# up a request after 30 s, so nc waits up to 30 s for the answer.
request() {
    printf '%s\n' "$1" | nc -U -w 30 "$port" 2>/dev/null
}

# Waits until a command succeeds. Arguments: the limit in seconds, the text of the failure, and
# the command.
wait_until() {
    limit=$1
    what=$2
    shift 2
    i=0
    while ! "$@"; do
        is_running || fail "the app stopped before $what"
        [ "$i" -lt "$((limit * 10))" ] || fail "$what did not happen in $limit s"
        sleep 0.1
        i=$((i + 1))
    done
}

# The bytes of a file as hex digits, with no space.
hex() {
    od -An -v -tx1 "$1" 2>/dev/null | tr -d ' \n'
}

attached() { grep -q -F "FAKE ATTACH $short_id" "$home/attach.log" 2>/dev/null; }
# hello, then ESC CR (Shift+Enter of a chat window).
typed() { hex "$input" | grep -q 68656c6c6f1b0d; }
# The chat of the state of the test port. The keys of the answer are in order: attached, blocked,
# ended, metal, note and session.
pattern='\{"attached":true,"blocked":false,"ended":false,"metal":(true|false),'
pattern="$pattern"'"note":(null|"[^"]*"),"session":"'"$fixture_session"'"\}'
chat_attached() { request '{"op":"state"}' | grep -q -E "$pattern"; }

# Phases 2 and 3 rule: the debug test port listens only in the test home, with mode 0600.
wait_until 15 "the test port at $port" test -S "$port"
mode=$(stat -f %Lp "$port") || fail "cannot read the mode of $port"
[ "$mode" = 600 ] || fail "the mode of $port is $mode, not 600"

# The import ran before the stores opened: the marker is in the support folder, the report in the
# state lists the two fixture stores and no earlier file, and the Electron folder did not change.
# The keys of the report are in order: at, imported, kept and skipped.
[ -f "$support/import.json" ] || fail "no import.json in $support"
state=$(request '{"op":"state"}')
case "$state" in
    *'"imported":["registry.json","ui-state.json"],"kept":[]'*) ;;
    *) fail "the state of the test port does not show the import of the fixture stores: $state" ;;
esac
[ "$(electron_items)" = "$electron_before" ] || fail "the import changed the Electron folder"
echo "the import copied the fixture stores, and the Electron folder did not change"

# The rows of the imported Overview in the state of the test port. The fixture row has the
# imported local name. The keys of an Overview are in order: desc, panel, rows, sort and tab.
row() { printf '{"id":"%s","name":"%s"}' "$1" "$2"; }
alpha_row=$(row "$fixture_session" "$local_name")
beta_row=$(row "$beta_session" smoke-beta)
gamma_row=$(row "$gamma_session" smoke-gamma)
# Arguments: desc (true or false), then the three rows in view order.
overview_shows() {
    expected="{\"desc\":$1,\"panel\":\"overview:1\",\"rows\":[$2,$3,$4],"
    expected="$expected\"sort\":\"name\",\"tab\":\"t1\"}"
    request '{"op":"state"}' | grep -q -F "$expected"
}
wait_until 15 "the three rows of the imported Overview in reverse name order" \
    overview_shows true "$alpha_row" "$gamma_row" "$beta_row"
echo "the Overview shows the imported sort and the imported local name"
answer=$(request '{"op":"overview","panel":"overview:1","sort":"name"}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the sort by name"
wait_until 10 "the three rows of the Overview in name order" \
    overview_shows false "$beta_row" "$gamma_row" "$alpha_row"
echo "a sort by name gives the three rows in name order"
answer=$(request '{"op":"overview","panel":"overview:2","sort":"name"}')
[ "$answer" = '{"error":"the Overview is not open"}' ] ||
    fail "the test port gave \"$answer\" for the sort of overview:2, which is not open"

# The rows of the fixtures have the pids 99991, 99992 and 99993. A chat that is not focused reads
# the terminal size of the pid of its row (with the process APIs of macOS). The size reader must
# never read the terminal of a process that this script did not start, so the chat step needs
# these pids free. pgrep lists the pids of all processes (-a: also its own parents), and it
# sends no signal.
for fixture_pid in 99991 99992 99993; do
    if pgrep -a . | grep -q -x "$fixture_pid"; then
        fail "a process with the fixture pid $fixture_pid runs: the chat could read its terminal"
    fi
done

# The chat of the fixture session: the double-click of the Electron smoke test.
answer=$(request "{\"op\":\"open\",\"panel\":\"$chat\"}")
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the open of $chat"
wait_until 15 "FAKE ATTACH $short_id in attach.log" attached
echo "the chat of the fixture session attached"
# The fake attach makes its terminal raw and then writes its input to this file.
wait_until 10 "the input file of the fake attach" test -f "$input"
# The open of the PTY ends on the main actor after the spawn, so the fake can start before the
# chat attached. Typed keys reach the session only after the attach.
wait_until 10 "the attach of the chat in the state of the test port" chat_attached
answer=$(request '{"op":"type","text":"hello"}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the type of hello"
answer=$(request '{"op":"key","key":"shift-enter"}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for Shift+Enter"
wait_until 10 "hello and ESC CR in $input" typed
echo "the chat typed hello and Shift+Enter"
state=$(request '{"op":"state"}')
printf '%s\n' "$state" | grep -q -E "$pattern" ||
    fail "the state of the test port does not show the chat as attached: $state"
echo "the state of the test port shows the chat as attached"

# Dictation: the hold key is Space. A hold of 800 ms dictates the text of the fake speech engine
# (the text of the fake helper of the Electron smoke test) into the session. The answer of the
# hold comes after the key up.
dictated_text="Hello from the fake helper."
answer=$(request '{"op":"hold","key":"space","ms":800}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the hold of 800 ms"
dictated() { grep -q -F "$dictated_text" "$input" 2>/dev/null; }
wait_until 10 "the dictated text in $input" dictated
# The microphone of the fake engine opened one time, and it closed at the release.
microphone_closed() {
    request '{"op":"state"}' | grep -q -F '"microphone":{"closes":1,"opens":1}'
}
wait_until 10 "the close of the microphone of the fake engine" microphone_closed
echo "a hold of Space dictated the text of the fake engine"
# A tap types one space after the dictated text, and opens no dictation.
before=$(hex "$input")
answer=$(request '{"op":"hold","key":"space","ms":50}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the hold of 50 ms"
one_space() { [ "$(hex "$input")" = "${before}20" ]; }
wait_until 10 "one space after the dictated text" one_space
sleep 0.5
one_space || fail "the tap of Space typed more than one space"
microphone_closed || fail "the tap of Space opened the microphone"
echo "a tap of Space typed one space"

# A new background session with a pid. The pid is the pid of this script, so it is a process
# that runs. The app only reads the process table. The session of the fixture stays in the list,
# so its chat stays attached. The fake claude reads this file. A rename
# makes the change in one step, so the fake claude never reads a part of the file.
now=$(date +%s)
cat >"$home/fake-agents.json.tmp" <<EOF || fail "cannot write fake-agents.json"
[
  {
    "cwd": "$sessions/alpha",
    "id": "5a0e0001",
    "kind": "background",
    "name": "smoke-alpha",
    "pid": 99991,
    "sessionId": "$fixture_session",
    "startedAt": 1793900000000,
    "status": "idle"
  },
  {
    "cwd": "$sessions/delta",
    "id": "5a0e0004",
    "kind": "background",
    "name": "smoke-delta",
    "pid": $$,
    "sessionId": "$new_session",
    "startedAt": ${now}000,
    "status": "busy"
  }
]
EOF
mv "$home/fake-agents.json.tmp" "$home/fake-agents.json" || fail "cannot write fake-agents.json"

# A window that is not visible polls each 15 s, as in the Electron app. For example, the window
# is not visible when the screen is locked or when another app fills the screen. The limit is
# 15 s after that slow poll.
wait_for_session "$new_session" 30 "the new session"

# Returns 0 when claude-calls.log has the line of the plugin command $1 for the folder or the
# plugin ID $2, with the options of a write.
called() {
    grep -q -x -F "plugin $1 $2 --scope user --json" "$calls" 2>/dev/null
}

# Live details is not installed, so the start rule does not listen. The state of the test port
# shows the status that Settings has.
live_read() { request '{"op":"state"}' | grep -q -F '"live":{'; }
wait_until 15 "the first read of the Live details status" live_read
[ ! -e "$socket" ] || fail "the start rule listens with no plugin: $socket"
# The keys of the status are in order, and no value of it is an object.
state=$(request '{"op":"state"}')
printf '%s\n' "$state" | grep -q -E '"live":\{[^}]*"plugin":"not-installed"' ||
    fail "the state of the test port does not show Live details as not installed: $state"
echo "Live details is not installed, and the start rule does not listen"

# Install of Live details: the plugin commands, the four mod files of the bundle with their
# bytes, and the shared socket of the temp home with mode 0600.
answer=$(request '{"op":"live","action":"install"}')
[ "$answer" = '{"ok":true}' ] ||
    fail "the test port gave \"$answer\" for the install of Live details"
called "marketplace add" "$mod" ||
    fail "claude-calls.log has no marketplace add of $mod"
called install "bifrost-live@bifrost-local" ||
    fail "claude-calls.log has no install of Live details"
for file in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json \
    hooks/register.ts; do
    cmp -s "$resources/live-mod/$file" "$mod/$file" ||
        fail "$mod/$file does not have the bytes of the bundle"
done
[ -S "$socket" ] || fail "no socket at $socket after the install of Live details"
mode=$(stat -f %Lp "$socket") || fail "cannot read the mode of $socket"
[ "$mode" = 600 ] || fail "the mode of $socket is $mode, not 600"
echo "the install of Live details ran the plugin commands, copied the mod and listens"

# One line of the Live details mod. The server answers 204 when it takes the line. curl uses
# only the socket: the host name is a fixed text and no proxy applies.
line="{\"v\":1,\"sid\":\"$fixture_session\",\"at\":${now}000,\"seq\":1,\"kind\":\"session.start\"}"
status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    --noproxy '*' --unix-socket "$socket" -X POST -H 'Content-Type: application/json' \
    --data-binary "$line" http://bifrost/v1/event) || fail "curl failed: $status"
[ "$status" = 204 ] || fail "the Live details server gave $status, not 204"
echo "the Live details server took a line"

# The line gives one entry in the Event log: its state event. The keys are in order: count and
# last.
events_show() {
    request '{"op":"state"}' | grep -q -F '"events":{"count":1,"last":["SessionStart"]}'
}
wait_until 10 "the entry of the Live details line in the Event log" events_show
echo "the Live details line gave one entry in the Event log"

# The fixture registry watches the fixture session, so the Watchlist shows its row.
answer=$(request '{"op":"open","panel":"watchlist"}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the open of the Watchlist"
watchlist_shows() {
    request '{"op":"state"}' | grep -q -F "\"watchlist\":[$alpha_row]"
}
wait_until 10 "the watched fixture row in the Watchlist" watchlist_shows
echo "the Watchlist shows the watched fixture row"

# Show Info of the fixture row gives the PR of fake-pr.json through the fake gh, which ran in the
# folder of the session. The keys of the PR are in order: number, state, title and url.
info="show-info:$fixture_session"
answer=$(request "{\"op\":\"open\",\"panel\":\"$info\"}")
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the open of $info"
pr='{"number":42,"state":"OPEN","title":"Smoke PR","url":"https://example.invalid/pr/42"}'
info_shows() {
    request '{"op":"state"}' | grep -q -F "\"showInfo\":[{\"panel\":\"$info\",\"pr\":$pr}]"
}
wait_until 15 "the PR of fake-pr.json in Show Info" info_shows
alpha_real=$(cd "$sessions/alpha" && pwd -P) || fail "cannot read the real path of alpha"
grep -q -x -F "$alpha_real: pr view --json number,title,url,state" "$home/gh-calls.log" ||
    fail "gh-calls.log has no run of the fake gh in $alpha_real"
echo "Show Info of the fixture row shows the PR of the fake gh"

# The start window: Claude Code gives a new background entry no pid and no status for about 2.5 s
# after a start. The entry of the fake stays so, so the window lasts. A forged session.end line
# parks its row, but the active list still has the entry, so Resume refuses it and runs no claude
# command. The keys of a row of the state are in order: id, listed, pid and state.
cat >"$home/fake-agents.json.tmp" <<EOF || fail "cannot write fake-agents.json"
[
  {
    "cwd": "$sessions/alpha",
    "id": "5a0e0001",
    "kind": "background",
    "name": "smoke-alpha",
    "pid": 99991,
    "sessionId": "$fixture_session",
    "startedAt": 1793900000000,
    "status": "idle"
  },
  {
    "cwd": "$sessions/delta",
    "id": "5a0e0004",
    "kind": "background",
    "name": "smoke-delta",
    "pid": $$,
    "sessionId": "$new_session",
    "startedAt": ${now}000,
    "status": "busy"
  },
  {
    "cwd": "$sessions/epsilon",
    "id": "5a0e0005",
    "kind": "background",
    "name": "smoke-epsilon",
    "sessionId": "$starting_session",
    "startedAt": ${now}000
  }
]
EOF
mv "$home/fake-agents.json.tmp" "$home/fake-agents.json" || fail "cannot write fake-agents.json"
# Argument: the start of the state of the row, for example "parked\"}" for a parked row.
starting_row() {
    request '{"op":"state"}' |
        grep -q -F "{\"id\":\"$starting_session\",\"listed\":true,\"pid\":null,\"state\":\"$1"
}
wait_until 30 "the row of the starting session with no pid" starting_row ""
line="{\"v\":1,\"sid\":\"$starting_session\",\"at\":$(date +%s)000,\"seq\":1,"
line="$line\"kind\":\"session.end\","
line="$line\"reason\":\"other\"}"
status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    --noproxy '*' --unix-socket "$socket" -X POST -H 'Content-Type: application/json' \
    --data-binary "$line" http://bifrost/v1/event) || fail "curl failed: $status"
[ "$status" = 204 ] || fail "the Live details server gave $status, not 204, for session.end"
wait_until 10 "the park of the starting session by the line" starting_row 'parked"}'
answer=$(request "{\"op\":\"resume\",\"session\":\"$starting_session\"}")
[ "$answer" = "{\"error\":\"This session isn't parked, so there's nothing to resume.\"}" ] ||
    fail "the test port gave \"$answer\" for the resume of the starting session"
if grep -q -F -e "--resume $starting_session" "$calls" 2>/dev/null; then
    fail "the resume of the starting session ran claude"
fi
echo "a forged session.end in the start window parks the row, and Resume refuses it"

# Turn off of Live details: the plugin command, and the socket goes.
answer=$(request '{"op":"live","action":"disable"}')
[ "$answer" = '{"ok":true}' ] ||
    fail "the test port gave \"$answer\" for the turn off of Live details"
called disable "bifrost-live@bifrost-local" ||
    fail "claude-calls.log has no disable of Live details"
[ ! -e "$socket" ] || fail "the turn off of Live details did not remove $socket"
echo "the turn off of Live details ran the plugin command and removed the socket"

# Install of the skills: the plugin commands, and the skills folder of the bundle with its bytes.
answer=$(request '{"op":"skills","action":"install"}')
[ "$answer" = '{"ok":true}' ] ||
    fail "the test port gave \"$answer\" for the install of the skills"
called "marketplace add" "$skills" ||
    fail "claude-calls.log has no marketplace add of $skills"
called install "bifrost@bifrost-skills" || fail "claude-calls.log has no install of the skills"
out=$(diff -r "$resources/bifrost-skills" "$skills" 2>&1) ||
    fail "$skills does not have the files of the bundle: $out"
echo "the install of the skills ran the plugin commands and copied the skills of the bundle"

# The settings. The store opens at the start of the services, and then the state of the test port
# has the saved settings. A patch of the Interface scale saves the new value in settings.json.
settings_file="$support/settings.json"
settings_open() { request '{"op":"state"}' | grep -q -F '"settings":{'; }
wait_until 10 "the open of the settings store" settings_open
answer=$(request '{"op":"setting","patch":{"interfaceScale":120}}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the Interface scale"
scale=$(/usr/bin/plutil -extract interfaceScale raw -o - "$settings_file" 2>/dev/null) ||
    fail "settings.json has no interfaceScale"
[ "$scale" = 120 ] || fail "settings.json has the Interface scale $scale, not 120"
echo "a patch of the Interface scale saved 120 in settings.json"

# A key patch of Close Panel. The change of a menu key builds the menu again, so the item of the
# installed menu gets the new key. The state gives the key of each item by its title.
menu_key() { request '{"op":"state"}' | grep -q -F "\"Close Panel\":\"$1\""; }
wait_until 10 "the default key of Close Panel in the menu" menu_key cmd+w
answer=$(request '{"op":"setting","patch":{"keys":{"close-panel:mod":"Mod+Shift+K"}}}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the key of Close Panel"
wait_until 10 "the new key of Close Panel in the menu" menu_key shift+cmd+k
echo "a key patch of Close Panel changed its key in the menu"

# A key patch with a conflict: Cmd+L is the key of Event log. The app refuses the patch with the
# text of the key edit, and settings.json and the menu keep their keys.
saved=$(shasum -a 256 "$settings_file") || fail "cannot read settings.json"
answer=$(request '{"op":"setting","patch":{"keys":{"close-panel:mod":"Mod+L"}}}')
[ "$answer" = "{\"error\":\"Two actions can't share the same key.\"}" ] ||
    fail "the test port gave \"$answer\" for a key patch with a conflict"
[ "$(shasum -a 256 "$settings_file")" = "$saved" ] ||
    fail "a refused key patch changed settings.json"
menu_key shift+cmd+k || fail "a refused key patch changed the key of Close Panel in the menu"
echo "a key patch with a conflict was refused, and settings.json did not change"

# Reviews (docs/behaviour/reviews.md) against the fake gh and a local bare repository. In a test
# home the clones come from <test home>/git-remotes/<owner>/<repo>.git (StartPlan.reviewsRemotes),
# so no git command reaches the network. The fixture PR 7 asks the user of the poll for a review,
# and PR 8 is a PR of that user, both in smoke-owner/smoke-repo. The bare repository has the base
# branch main and the head of PR 7 at refs/pull/7/head, as on GitHub. The fake gh answers the poll,
# the read of the PR and the one write of a round from the files of the test home, and it records
# each write in gh-writes.jsonl.
reviews_fixtures="$here/smoke-fixtures/reviews"
remote="$home/git-remotes/smoke-owner/smoke-repo.git"
work="$home/reviews-work"
# The git of the set-up reads no config of the user or of the system, and has a fixed identity.
setup_git() {
    env -i PATH=/usr/bin:/bin HOME="$home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        git -c user.name=Smoke -c user.email=smoke@example.invalid -c init.defaultBranch=main \
        "$@"
}
mkdir -p "$home/git-remotes/smoke-owner" || fail "cannot make the folder of $remote"
setup_git init -q --bare "$remote" || fail "cannot make the bare repository $remote"
setup_git init -q "$work" || fail "cannot make the repository $work"
printf 'one\n' >"$work/notes.txt" || fail "cannot write notes.txt"
{ setup_git -C "$work" add notes.txt && setup_git -C "$work" commit -q -m "Add the notes" &&
    setup_git -C "$work" push -q "$remote" HEAD:refs/heads/main; } ||
    fail "cannot push the base branch"
base_sha=$(setup_git -C "$work" rev-parse HEAD) || fail "cannot read the base commit"
printf 'one\ntwo\n' >"$work/notes.txt" || fail "cannot write notes.txt"
{ setup_git -C "$work" commit -q -a -m "Add a second line" &&
    setup_git -C "$work" push -q "$remote" HEAD:refs/pull/7/head; } ||
    fail "cannot push the head of PR 7"
head_sha=$(setup_git -C "$work" rev-parse HEAD) || fail "cannot read the head commit"

# Claude Code trusts the clone: .claude.json of the test home has the trust of its real path, so
# a round needs no trust step. Bifrost only reads this file.
home_real=$(cd "$home" && pwd -P) || fail "cannot read the real path of $home"
clone="$home_real/.bifrost/reviews/repos/smoke-owner/smoke-repo"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$clone" >"$home/.claude.json" ||
    fail "cannot write .claude.json"

# Writes the fixture $2 to the file $3 of the test home, with the commits of the bare repository
# and the time $1 of the review request in place of the markers. The fake claude puts the token of
# the round in place of @ROUND@ of the result.
fill() {
    sed -e "s/@HEAD@/$head_sha/g" -e "s/@BASE@/$base_sha/g" -e "s/@REQUESTED@/$1/g" \
        "$reviews_fixtures/$2" >"$home/$3" || fail "cannot write $3"
}
poll="$home/fake-reviews-poll.json"
fill 2026-11-01T09:00:00Z context.json fake-reviews-context.json
fill 2026-11-01T09:00:00Z writes.json fake-reviews-writes.json
fill 2026-11-01T09:00:00Z result.json fake-review-result.json

pr7=smoke-owner/smoke-repo#7
pr8=smoke-owner/smoke-repo#8
# A row of the reviews state as an extended regular expression. Arguments: flash, paused, the PR,
# the state and the tab. The keys of a row are in order: flash, paused, pr, round (only while a
# round of the PR runs), state and tab.
review_row() {
    printf '\\{"flash":%s,"paused":%s,"pr":"%s","state":"%s","tab":"%s"\\}' "$@"
}
mine_row=$(review_row false false "$pr8" '[^"]*' mine)
# Returns 0 when the Reviews panel has the rows $1 (an extended regular expression), in order,
# and no problem line. The keys of the reviews state are in order: autoFixConsent, problem and
# rows.
reviews_rows() {
    rows_start='"reviews":\{"autoFixConsent":(true|false|null),"problem":null,"rows":\['
    request '{"op":"state"}' | grep -q -E "$rows_start$1\\]\\}"
}
# The reviews state, for a message.
reviews_state() { request '{"op":"state"}' | grep -o '"reviews":{[^]]*]}'; }
# Waits up to $1 s for the rows $3, with the text $2 for the message.
wait_for_rows() {
    i=0
    while ! reviews_rows "$3"; do
        is_running || fail "the app stopped before $2"
        [ "$i" -lt "$(($1 * 10))" ] || fail "$2 did not happen in $1 s: $(reviews_state)"
        sleep 0.1
        i=$((i + 1))
    done
}

# The first turn-on of Watch GitHub, with the automatic rounds off. The first poll lists only PR 8,
# so it records no review request: the first poll after the first turn-on never flashes.
fill 2026-11-01T09:00:00Z poll.json fake-reviews-poll.json
plutil -replace data.toReview.nodes -json '[]' "$poll" || fail "cannot write the first poll"
answer=$(request '{"op":"setting","patch":{"reviewsWatch":true,"reviewsAutoFix":false}}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for Watch GitHub"
wait_for_rows 30 "the My PRs row of the first poll" "$mine_row"
echo "Watch GitHub polled the fake gh and shows the My PRs row"

# Turn off and on again: the second open of the state polls at once. The request of PR 7 comes
# after the first turn-on (the wait of 1 s makes sure of it at a precision of seconds), so it is
# new and its row flashes.
answer=$(request '{"op":"setting","patch":{"reviewsWatch":false}}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the turn-off"
wait_for_rows 10 "the empty Reviews panel after the turn-off" ''
sleep 1
requested=$(date -u +%Y-%m-%dT%H:%M:%SZ) || fail "cannot read the time"
fill "$requested" poll.json fake-reviews-poll.json
answer=$(request '{"op":"setting","patch":{"reviewsWatch":true}}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the second turn-on"
wait_for_rows 30 "the flash of the new request of PR 7" \
    "$(review_row true false "$pr7" '' toReview),$mine_row"
answer=$(request '{"op":"open","panel":"reviews"}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the open of Reviews"
echo "the new request of PR 7 flashes, and the Reviews panel opens"

# Pause on the new request stops its flash. A My PRs row has no Pause, so the click is refused.
answer=$(request "{\"op\":\"reviews\",\"action\":\"pause\",\"pr\":\"$pr7\"}")
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the pause of PR 7"
wait_for_rows 10 "the pause of PR 7" \
    "$(review_row false true "$pr7" 'Paused [0-9]+m' toReview),$mine_row"
answer=$(request "{\"op\":\"reviews\",\"action\":\"pause\",\"pr\":\"$pr8\"}")
[ "$answer" = "{\"error\":\"the row of $pr8 has no pause item now\"}" ] ||
    fail "the test port gave \"$answer\" for the pause of PR 8"
echo "Pause stopped the flash of PR 7, and PR 8 has no Pause"

# Review runs a review round: the clone, the read of the PR, the input folder, the review session
# of the fake claude, the check of its result and one pending review. The write moves the next
# poll answer in place, so the poll at the end of the round shows the pending review of the user,
# and the row shows Claude's draft.
{ cp "$poll" "$home/fake-reviews-poll-next.json" &&
    plutil -replace data.toReview.nodes.0.pendingReviews.nodes -json '[{"id":"PRR_smokeDraft1"}]' \
        "$home/fake-reviews-poll-next.json"; } || fail "cannot write the poll after the write"
answer=$(request "{\"op\":\"reviews\",\"action\":\"review\",\"pr\":\"$pr7\"}")
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the review of PR 7"
wait_for_rows 120 "the draft of the review round of PR 7" \
    "$(review_row false false "$pr7" 'Draft ready' toReview),$mine_row"
review_start='^--bg --restricted --strict-mcp-config --tools Read Glob Grep Write Skill .* '
review_start="$review_start--name bifrost-test-smoke-repo-7-review "
review_start="$review_start/bifrost-review bifrost-input=.*/\\.bifrost-io/7/input\\.json$"
grep -q -E "$review_start" "$calls" ||
    fail "claude-calls.log has no start of the review session: $(cat "$calls")"
[ -f "$clone/.bifrost-io/7/result.json" ] || fail "the review session wrote no result.json"
echo "Review ran a round in the review session bifrost-test-smoke-repo-7-review"

# The round wrote one pending review with no event, so it stays pending, and nothing else.
expected='{"args":["api","--method","POST","repos/smoke-owner/smoke-repo/pulls/7/reviews",'
expected="$expected\"--input\",\"-\"],\"input\":{\"body\":\"The change reads well. One question"
expected="$expected on the empty notes file.\",\"commit_id\":\"$head_sha\"}}"
[ "$(cat "$home/gh-writes.jsonl" 2>/dev/null)" = "$expected" ] ||
    fail "gh-writes.jsonl does not hold only the pending review: $(cat "$home/gh-writes.jsonl")"
echo "gh-writes.jsonl holds one pending review with no event, and no other write"

# The automatic rounds stay off: the setting is off, and the store has no consent.
auto_fix=$(/usr/bin/plutil -extract reviewsAutoFix raw -o - "$settings_file" 2>/dev/null) ||
    fail "settings.json has no reviewsAutoFix"
[ "$auto_fix" = false ] || fail "settings.json has reviewsAutoFix $auto_fix"
request '{"op":"state"}' | grep -q -E '"reviews":\{"autoFixConsent":(false|null),' ||
    fail "the store of Reviews has the consent of the automatic rounds: $(reviews_state)"
echo "the automatic rounds of Reviews stay off"

# The session actions (docs/behaviour/actions.md) run through the action runner of the app, as
# a click on a button does, and the fake claude logs each call to claude-calls.log. The answer of
# an action comes at the end of its run. Each step ends with no dialog, no error line and no
# running action in the state of the test port (the keys of the state are in order).
calls="$home/claude-calls.log"
actions_idle() {
    request '{"op":"state"}' | grep -q -F '"dialog":false,"error":null,'
}
no_running() {
    request '{"op":"state"}' | grep -q -F '"running":[],'
}
# Arguments: the request, then the name of the step for the messages.
action() {
    answer=$(request "$1")
    [ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for $2"
    actions_idle || fail "$2 left a dialog or an error: $(request '{"op":"state"}')"
}

# A send types the text into the session with a paste, then CR (ESC [ 200 ~, the text, ESC [
# 201 ~, CR). The chat of the fixture session is open, so the text goes through its attach.
before=$(hex "$input")
action "{\"op\":\"send\",\"session\":\"$fixture_session\",\"text\":\"hello\"}" "the send of hello"
sent() { [ "$(hex "$input")" = "${before}1b5b3230307e68656c6c6f1b5b3230317e0d" ]; }
wait_until 10 "the paste of hello and CR in $input" sent
echo "a send of hello typed into the fake attach of the fixture session"

# The start of an action request on the fixture session, with no closing brace.
on_fixture="{\"op\":\"action\",\"session\":\"$fixture_session\""

# Rename with a name saves the local name in registry.json.
action "$on_fixture,\"id\":\"rename\",\"name\":\"$new_name\"}" "the rename of the fixture session"
renamed() {
    [ "$(/usr/bin/plutil -extract "aliases.$fixture_session" raw -o - "$registry" 2>/dev/null)" = \
        "$new_name" ]
}
wait_until 10 "the local name $new_name in registry.json" renamed
echo "Rename saved the local name $new_name in registry.json"

# New session in a session folder of the test home: the fake claude starts the session and lists
# it, the answer comes when the row is there, the new row is selected and its chat opens.
action "{\"op\":\"action\",\"id\":\"new-session\",\"folder\":\"$sessions/epsilon\"}" \
    "the start of a new session"
grep -q -E '^--bg .*--name epsilon-[0-9a-f]{4}$' "$calls" ||
    fail "claude-calls.log has no start of the new session: $(cat "$calls")"
state=$(request '{"op":"state"}')
case "$state" in
    *"\"id\":\"$started_session\""*) ;;
    *) fail "the Overview does not show the new session: $state" ;;
esac
case "$state" in
    *"\"selected\":\"$started_session\""*) ;;
    *) fail "the new session is not selected: $state" ;;
esac
started_chat() { request '{"op":"state"}' | grep -q -F "\"session\":\"$started_session\""; }
wait_until 10 "the chat of the new session" started_chat
echo "New session ran claude --bg and gave a new row with its chat"

# Stop of the fixture session. Stop asks first only for a session that works, so the request
# answers yes in case a line of the Live details server made the session work. Stop ends when a
# sample of the list without the session parks the row, so the Delete below runs no second stop.
action "$on_fixture,\"id\":\"stop\",\"confirm\":true}" "the stop of the fixture session"
grep -q -x "stop $short_id" "$calls" || fail "claude-calls.log has no stop $short_id"
no_running || fail "an action still runs after the stop"
echo "Stop ran claude stop $short_id"

# Delete asks first. The confirmation answers yes, then the row goes and its chat closes.
action "$on_fixture,\"id\":\"delete\",\"confirm\":true}" "the delete of the fixture session"
grep -q -x "rm $short_id" "$calls" || fail "claude-calls.log has no rm $short_id"
state=$(request '{"op":"state"}')
case "$state" in
    *"\"id\":\"$fixture_session\""* | *"\"session\":\"$fixture_session\""*)
        fail "the deleted session still has a row or a chat: $state"
        ;;
esac
no_running || fail "an action still runs after the delete"
echo "Delete ran claude rm $short_id, and the row and its chat went"

is_running || fail "the app stopped after the checks"

# The Release notes dialog reads github-releases.json of the temp home, never GitHub. The page of
# each release must be below the Releases page of the Info.plist.
releases_page=$("$buddy" -c "Print :BifrostReleasesURL" "$plist") ||
    fail "the Info.plist has no BifrostReleasesURL"
cat >"$home/github-releases.json" <<EOF || fail "cannot write github-releases.json"
[
  {"tag_name": "v9.8.0", "published_at": "2026-11-09T09:00:00Z", "draft": false,
   "prerelease": false, "body": "Older.", "html_url": "$releases_page/tag/v9.8.0"},
  {"tag_name": "v9.9.0", "published_at": "2026-11-10T09:00:00Z", "draft": false,
   "prerelease": false, "body": "Newest.\n\n### Features\n\n* **chat:** a new item",
   "html_url": "$releases_page/tag/v9.9.0"}
]
EOF
answer=$(request '{"op":"releaseNotes"}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the release notes"
notes='"releaseNotes":{"load":"loaded","title":"Release notes",'
notes="$notes"'"versions":["9.9.0","9.8.0"],"view":"all"}'
notes_shown() { request '{"op":"state"}' | grep -q -F "$notes"; }
wait_until 15 "the release notes of github-releases.json" notes_shown
echo "the Release notes dialog lists the releases of github-releases.json"

# The Daily update: one work area on each day, the board as the source with one read tool, and
# no merged PRs, so no gh runs. The probe of the run prints fake-mcp-init.json, and the run prints
# fake-daily-result.json, the JSON output of claude -p with the result between its markers.
init='{"type":"system","subtype":"init","cwd":"/nonexistent","session_id":"s",'
init="$init"'"tools":["Read","mcp__board__list_items"],'
init="$init"'"mcp_servers":[{"name":"board","status":"connected"}]}'
printf '%s\n' "$init" >"$home/fake-mcp-init.json" || fail "cannot write fake-mcp-init.json"
result='BIFROST-DAILY-RESULT-BEGIN\n{\"version\":1,\"areas\":[{\"id\":\"smoke-area\",'
result="$result"'\"moved\":true,\"items\":[],\"draft\":\"**Daily update**\\nDone.\"}],'
result="$result"'\"unplaced\":[]}\nBIFROST-DAILY-RESULT-END'
printf '{"type":"result","is_error":false,"result":"%s","permission_denials":[]}\n' "$result" \
    >"$home/fake-daily-result.json" || fail "cannot write fake-daily-result.json"
daily='{"source":{"server":"board","tools":["mcp__board__list_items"]},"you":"",'
daily="$daily"'"mergedPrs":false,"draftTime":"09:30","deadline":"10:00","days":[0,1,2,3,4,5,6],'
daily="$daily"'"model":"","format":{"template":"**Daily update**","examples":[]},'
daily="$daily"'"areas":[{"id":"smoke-area","on":true,"name":"Smoke","channel":"#smoke",'
daily="$daily"'"description":"","takesRest":true}]}'
answer=$(request "{\"op\":\"setting\",\"patch\":{\"dailyUpdate\":$daily}}")
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the Daily update settings"
# A start or a change of the settings after the draft time can run the drafts by itself. Then
# Refresh does nothing, and that run fills the tab in the same way.
answer=$(request '{"op":"daily","action":"refresh"}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the Daily update refresh"
daily_tab() {
    request '{"op":"state"}' |
        grep -q -E "\"draft\":[1-9][0-9]*,\"id\":\"smoke-area\",\"marker\":$1,\"sent\":$2"
}
wait_until 30 "the draft of the Daily update tab" daily_tab true false
echo "Refresh of the Daily update filled the tab with the draft of fake-daily-result.json"
answer=$(request '{"op":"daily","action":"mark-sent","area":"smoke-area"}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for Mark as sent"
wait_until 10 "the mark of the Daily update tab" daily_tab false true
echo "Mark as sent cleared the marker of the Daily update tab"

# The Performance monitor of the test home ticks each 15 s from the start, so by now its second
# tick gave a sample: the state leaves "checking" and gives a level and the number of reasons.
# A test home has no network reader and no GitHub points, so the monitor makes no request.
performance_level() {
    request '{"op":"state"}' |
        grep -q -E '"performance":\{"level":"(ok|warning|problem)","reasons":[0-9]+\}'
}
wait_until 30 "a level of the Performance monitor" performance_level
echo "the Performance monitor of the test home gives a level"

# The quit of the test port runs the quit of the app: the saves, the detach of each chat and the
# stop of the services (docs/behaviour/shell.md, The window and the menu). The cleanup sends
# TERM if the app still runs.
answer=$(request '{"op":"quit"}')
[ "$answer" = '{"ok":true}' ] || fail "the test port gave \"$answer\" for the quit"
i=0
while is_running && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
done
is_running && fail "the app did not quit in 10 s after the quit of the test port"
stop_app
echo "the app quit through the test port"

frames=$(/usr/bin/plutil -extract current.frames json -o - "$ui_state" 2>/dev/null) ||
    fail "ui-state.json has no current.frames"
case "$frames" in
    *"\"chat:$started_session\""*) ;;
    *) fail "current.frames of ui-state.json has no chat:$started_session: $frames" ;;
esac
case "$frames" in
    *"\"$chat\""*) fail "current.frames of ui-state.json has the deleted $chat: $frames" ;;
esac
[ -f "$window_state" ] || fail "no window-state.json at $window_state"
echo "ui-state.json keeps the chat panel of the new session, and window-state.json exists"

# The imported Overview config keeps its name, and its tab has the sort of the test port.
overview_value() {
    /usr/bin/plutil -extract "overviews.overview:1.$1" raw -o - "$ui_state" 2>/dev/null
}
saved="$(overview_value name)/$(overview_value tabs.0.sort.column)"
saved="$saved/$(overview_value tabs.0.sort.desc)"
[ "$saved" = Smoke/name/false ] ||
    fail "ui-state.json does not keep the imported Overview sorted by name: $saved"
echo "ui-state.json keeps the imported Overview with the sort by name"

[ "$(electron_items)" = "$electron_before" ] || fail "the app changed the Electron folder"
echo "the Electron folder did not change"

remove_home
echo PASS
