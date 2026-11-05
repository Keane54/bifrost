// Text of the two POSIX sh scripts that Bifrost installs for Claude Code.
// Claude Code runs the hook at each hook event and the wrapper at each statusline refresh.
// Each process start can cost 20 to 40 ms on a loaded Mac. So the scripts start few programs.
// The scripts do their work only while the file "active" exists. Bifrost makes it at start.

export const HOOK_SCRIPT = `#!/bin/sh
# Bifrost hook. Save the hook event of Claude Code as one file.
# If Bifrost does not run, the script stops before it reads stdin.
# The script copies stdin to the event file with one cat.
# So the cost does not grow with the size of the input.
# Bifrost does not use a file that is not valid JSON and is younger than 5 seconds.
# So the script writes the final name and does not use a temporary file.
# The script starts mkdir only when the events directory is missing.
# The files get mode 0600, because they hold tool input and output.
# The script prints nothing and always exits 0.
exec >/dev/null 2>&1
umask 077
base="\${BIFROST_HOME:-$HOME/.bifrost}"
[ -e "$base/active" ] || exit 0
dir="$base/events"
[ -d "$dir" ] || mkdir -p "$dir"
cat >"$dir/$PPID-$$.json"
exit 0
`

export const UUID_PATTERN =
  '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

// One hex digit as a sh case pattern.
// The pattern has no range, because the locale can change the characters in a range.
const HEX = '[0123456789abcdefABCDEF]'

// A sh case pattern for exactly 8-4-4-4-12 hex digits.
const UUID_CASE = [8, 4, 4, 4, 12].map(n => HEX.repeat(n)).join('-')

/**
 * Build the statusline wrapper. While Bifrost runs, the wrapper saves the status JSON of a session.
 * Then it runs the original statusline command with the same input.
 * For a quiet session, it does not run the original command.
 * With no original command, the wrapper prints nothing.
 */
export function statuslineScript(originalCommand: string | null): string {
  const quoted = originalCommand === null ? null : `'${originalCommand.replaceAll("'", "'\\''")}'`
  const notRunning =
    quoted === null
      ? '[ -e "$base/active" ] || exit 0'
      : `if [ ! -e "$base/active" ]; then\n  /bin/sh -c ${quoted}\n  exit 0\nfi`
  const run = quoted === null ? '' : `printf '%s' "$input" | /bin/sh -c ${quoted}\n`
  return `#!/bin/sh
# Bifrost statusline wrapper. Save the status JSON of the session.
# Then run the original statusline command with the same input.
# Claude Code runs this script for each session again and again, for example each second.
# So the script starts few programs: cat one time and mv one time.
# It starts mkdir only for a new session.
# If Bifrost does not run, the script only runs the original command.
# Bifrost makes the file "quiet" for each owned session.
# For a quiet session, the script does not run the original command.
# The files get mode 0600. The script always exits 0.
exec 2>/dev/null
umask 077
base="\${BIFROST_HOME:-$HOME/.bifrost}"
# If fd 0 is closed, open /dev/null as stdin. Without it, bash 3.2 gives cat a pipe that never ends.
true 3<&0 || exec </dev/null
${notRunning}
# Read stdin one time. The x keeps the newlines at the end of the input.
input=$(cat; printf x)
input=\${input%x}
# Find the value of the first "session_id" key. Accept only a UUID.
id=
case $input in
*'"session_id"'*)
  rest=\${input#*'"session_id"'}
  rest=\${rest#"\${rest%%[![:space:]]*}"}
  case $rest in
  :*)
    rest=\${rest#:}
    rest=\${rest#"\${rest%%[![:space:]]*}"}
    case $rest in
    \\"${UUID_CASE}\\"*)
      id=\${rest#\\"}
      id=\${id%%\\"*}
      ;;
    esac
    ;;
  esac
  ;;
esac
if [ -n "$id" ]; then
  sdir="$base/sessions/$id"
  [ -d "$sdir" ] || mkdir -p "$sdir"
  if printf '%s' "$input" >"$sdir/.status.$$" && mv "$sdir/.status.$$" "$sdir/status.json"; then
    :
  elif [ -e "$sdir/.status.$$" ]; then
    rm -f "$sdir/.status.$$"
  fi
  [ -e "$sdir/quiet" ] && exit 0
fi
${run}exit 0
`
}
