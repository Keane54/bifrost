// Text of the two POSIX sh scripts that Bifrost installs for Claude Code.
// Claude Code runs them many times each second. They must stay fast.

export const HOOK_SCRIPT = `#!/bin/sh
# Bifrost hook. Save the hook event of Claude Code as one file.
# Claude Code runs this hook after every tool call.
# Each process start can cost 20 to 40 ms on a loaded Mac.
# So the script uses shell builtins and starts at most one other program (mv).
# It starts mkdir only when the events directory is missing.
# The script prints nothing and always exits 0.
exec >/dev/null 2>&1
dir="\${BIFROST_HOME:-$HOME/.bifrost}/events"
tmp="$dir/.tmp.$$"
[ -d "$dir" ] || mkdir -p "$dir"
if {
  while IFS= read -r line; do printf '%s\\n' "$line"; done
  [ -z "$line" ] || printf '%s' "$line"
} >"$tmp"; then
  mv "$tmp" "$dir/$PPID-$$.json" || rm -f "$tmp"
else
  rm -f "$tmp"
fi
exit 0
`

export const UUID_PATTERN =
  '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

/**
 * Build the statusline wrapper. The wrapper saves the status JSON of a session.
 * Then it runs the original statusline command with the same input.
 * With no original command, the wrapper prints nothing.
 */
export function statuslineScript(originalCommand: string | null): string {
  const run =
    originalCommand === null ? ':' : `sh -c '${originalCommand.replaceAll("'", "'\\''")}' <"$tmp"`
  return `#!/bin/sh
# Bifrost statusline wrapper. Save the status JSON of the session.
# Then run the original statusline command with the same input.
# The script always exits 0.
base="\${BIFROST_HOME:-$HOME/.bifrost}"
tmp=$(mktemp "\${TMPDIR:-/tmp}/bifrost-status.XXXXXX") || exit 0
trap 'rm -f "$tmp"' EXIT
trap 'exit 0' HUP INT TERM
cat >"$tmp"
id=$(tr -d '\\n\\r' <"$tmp" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
if printf '%s\\n' "$id" | grep -Eq '${UUID_PATTERN}'; then
  sdir="$base/sessions/$id"
  if mkdir -p "$sdir" 2>/dev/null && cp "$tmp" "$sdir/.status.$$" 2>/dev/null; then
    mv "$sdir/.status.$$" "$sdir/status.json" 2>/dev/null || rm -f "$sdir/.status.$$"
  fi
fi
${run}
exit 0
`
}
