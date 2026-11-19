#!/bin/sh
# Saves the release notes of semantic-release to .release-notes.md in the repo (docs/release.md).
#
# Usage: scripts/release/save-notes.sh <release notes as base64>
#
# semantic-release runs this script as the generateNotesCmd of the second exec plugin
# (.releaserc.json). That plugin comes after the release-notes-generator plugin, so it gets the
# full notes: the summary and the notes of the commits. The script prints nothing, so it adds no
# text to the notes. A dry run also makes the notes, so the check job of the Release workflow gets
# the notes with no release. The build job then puts the notes into its artifact for the sign job.
# The notes come as base64 text, so the shell of the exec plugin gets only the characters A-Z,
# a-z, 0-9, "+", "/" and "=", and never runs a part of the notes.
# The script is POSIX sh, and it runs on the Linux runner of the check job.
#
# Exit 0: the notes are in .release-notes.md. Exit 1: the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"
root=$(cd "$here/../.." && pwd) || exit 1

[ $# -eq 1 ] || fail "usage: scripts/release/save-notes.sh <release notes as base64>"
notes="$root/.release-notes.md"
printf '%s' "$1" | openssl base64 -d -A >"$notes" || fail "The notes are not base64."
[ -s "$notes" ] || fail "The release notes are empty."
