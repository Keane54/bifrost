#!/bin/sh
# Runs a command in the test sandbox.
#
# Usage: scripts/run-sandboxed.sh <command> [args]
#
# The script makes the concrete profile from scripts/test-sandbox.sb and writes it to a new file
# in .build/check/. Then it runs the command with "sandbox-exec -f". The command gets the path of
# that file in BIFROST_SANDBOX_PROFILE, and the pid of this script in BIFROST_SANDBOX_PID. This
# script runs outside the sandbox until the command ends, so in the sandbox a signal to that pid
# fails with EPERM. The script removes the file when the command ends.
#
# The profile refuses these operations for the command and for each process that it starts:
# - a read or a write under ~/.claude, ~/.bifrost, ~/.bifrost-native-dev,
#   ~/Library/Application Support/Bifrost and ~/Library/Application Support/Bifrost Native Dev,
#   and of the file ~/.claude.json;
# - a write under ~/Library/Logs, and a write of the folders ~/Library and
#   ~/Library/Application Support themselves (for example a rename);
# - each outbound IP connection, and a connection to a Unix socket under the folders of the
#   first item (other Unix sockets stay allowed);
# - the name lookup: the socket and the services of the resolver, and /etc/hosts;
# - the exec of the Keychain tool /usr/bin/security, so no test reads a Keychain item;
# - a signal to a process outside the sandbox. The command and each process that it starts are
#   in the sandbox, so a test can signal its own children.
# The test fixtures that start real processes or write real files stop the test when the two
# variables are not set or a signal to the pid does not fail (TestSandbox in BifrostTestSupport).
# macOS refuses the exec of a setuid program in a sandbox, for example /bin/ps. The profile runs
# no program outside the sandbox.
# The home comes from the user database, not from HOME. When HOME has another value, the profile
# also refuses the same paths under HOME.
# With BIFROST_SANDBOX_DENY=<folder> (only for the self-test), the profile also refuses each
# write under that folder, each connection to a socket in it and the exec of <folder>/true.
#
# SwiftPM runs the manifest and each build plug-in in its own sandbox-exec. macOS refuses a
# sandbox-exec in this profile ("sandbox_apply: Operation not permitted"). Thus each swift test
# in this profile needs --disable-sandbox. This profile still refuses the real shared state.
# The profile refuses the network, so resolve the packages before the tests, outside this profile
# (the step resolve of scripts/check.sh).
#
# A test removes its temporary folder with a rename to <folder>.gone-<UUID>, and removes the
# content in the background (TemporaryFolder in BifrostTestSupport). When the command ends, the
# script removes each renamed folder of this user that is left: only /tmp/bk-<8 characters>.gone-*
# and <temp folder of the user>/bifrost-test-*.gone-*, and only a folder, not a link.
#
# Exit: the exit code of the command. Exit 125: the script cannot make the profile. No script
# that the wrapper runs uses exit 125 (smoke.sh uses exit 2 for a Release app).

# -f: no file name expansion. -u: an unset variable is an error.
set -fu

nl='
'

refuse() {
    echo "run-sandboxed.sh: $1" >&2
    exit 125
}

[ "$#" -ge 1 ] || refuse "usage: scripts/run-sandboxed.sh <command> [args]"

here=$(cd "$(dirname "$0")" && pwd) || refuse "cannot find the scripts folder"
root=$(dirname "$here")
template="$here/test-sandbox.sb"
folder="$root/.build/check"
[ -f "$template" ] || refuse "no profile at $template"

# Refuses a path that cannot go into the profile: a path that is not absolute, or a path with a
# quote, a backslash or a line break. $2 is the name of the value for the message.
check_path() {
    case "$1" in
        /*) ;;
        *) refuse "$2 is not an absolute path: $1" ;;
    esac
    case "$1" in
        *'"'* | *'\'* | *"$nl"*) refuse "$2 has a quote, a backslash or a line break: $1" ;;
    esac
}

# The homes, one on each line. Each path is in the list one time.
homes=""

# Adds the home in $1 and its real path to the list of homes. $2 is the name of the value.
add_home() {
    check_path "$1" "$2"
    real=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || real=""
    for path in "$1" "$real"; do
        # Remove the slashes at the end. The home / gives no path.
        while [ "${path%/}" != "$path" ]; do
            path=${path%/}
        done
        [ -n "$path" ] || continue
        check_path "$path" "$2"
        case "$nl$homes" in
            *"$nl$path$nl"*) ;;
            *) homes="$homes$path$nl" ;;
        esac
    done
}

user=$(id -un) || refuse "cannot read the user name"
case "$user" in
    "" | *[!A-Za-z0-9._-]*) refuse "the user name has a character that the script refuses" ;;
esac
user_home=$(eval echo "~$user")
[ "$user_home" != / ] || refuse "the home of the user database is /"
add_home "$user_home" "the home of the user database"
if [ -n "${HOME:-}" ] && [ "$HOME" != / ]; then
    add_home "$HOME" HOME
fi

deny=""
if [ -n "${BIFROST_SANDBOX_DENY:-}" ]; then
    check_path "$BIFROST_SANDBOX_DENY" BIFROST_SANDBOX_DENY
    deny=$(CDPATH='' cd -- "$BIFROST_SANDBOX_DENY" 2>/dev/null && pwd -P) ||
        refuse "BIFROST_SANDBOX_DENY is not a folder: $BIFROST_SANDBOX_DENY"
    check_path "$deny" BIFROST_SANDBOX_DENY
fi

mkdir -p "$folder" || refuse "cannot make $folder"
profile=$(mktemp "$folder/test-sandbox-XXXXXX") || refuse "cannot make a file in $folder"
trap 'rm -f "$profile"' EXIT
trap 'exit 1' HUP INT TERM

# Writes the concrete profile. A comment line stays as it is. Each parameter is in a rule line
# one time at most.
write_profile() {
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "("*@HOME@*)
                printf '%s' "$homes" | while IFS= read -r home; do
                    printf '%s%s%s\n' "${line%%@HOME@*}" "$home" "${line#*@HOME@}"
                done
                ;;
            "("*@DENY@*)
                if [ -n "$deny" ]; then
                    printf '%s%s%s\n' "${line%%@DENY@*}" "$deny" "${line#*@DENY@}"
                fi
                ;;
            *) printf '%s\n' "$line" ;;
        esac
    done <"$template"
}
write_profile >"$profile" || refuse "cannot write $profile"

# Removes the renamed temporary folders of the tests that are left (see above). find does not
# follow a link, and -maxdepth 1 keeps it in the one folder.
sweep() {
    uid=$(id -u) || return 0
    find /tmp/ -maxdepth 1 -type d -user "$uid" -name 'bk-????????.gone-*' \
        -exec rm -rf {} + 2>/dev/null
    for temp in "${TMPDIR:-}" "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; do
        case "$temp" in
            /?*) ;;
            *) continue ;;
        esac
        find "${temp%/}/" -maxdepth 1 -type d -user "$uid" -name 'bifrost-test-*.gone-*' \
            -exec rm -rf {} + 2>/dev/null
    done
    return 0
}

BIFROST_SANDBOX_PROFILE=$profile
BIFROST_SANDBOX_PID=$$
export BIFROST_SANDBOX_PROFILE BIFROST_SANDBOX_PID
# Not exec: this script waits for the command, then sweeps, then the trap removes the profile.
/usr/bin/sandbox-exec -f "$profile" "$@"
status=$?
sweep
exit "$status"
