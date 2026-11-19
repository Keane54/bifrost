#!/bin/sh
# Checks the release summary and prints it for the release notes.
#
# Usage: RELEASE_SUMMARY=<text> scripts/release/summary.sh
#
# The person who starts the Release workflow types the summary (user decision, 2026-11-10). The
# check job of the workflow runs this script first. semantic-release runs it again as the
# generateNotesCmd of the exec plugin (.releaserc.json), and puts its output before the notes of
# the release-notes-generator plugin. So a release never gets an empty summary or a summary that
# is too long.
#
# The rules:
# - The summary has text after the white space at the start and at the end is removed.
# - The summary has 600 characters or less. The script counts characters, not bytes.
# - No line starts with "#", also after spaces. The release notes use "#" for their headings, and
#   the app reads the summary only up to the first heading (ReleaseNotes.swift).
#
# Exit 0: the script prints the trimmed summary and a blank line. Exit 1: the script prints the
# reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"

limit=600
summary=${RELEASE_SUMMARY-}
summary=${summary#"${summary%%[![:space:]]*}"}
summary=${summary%"${summary##*[![:space:]]}"}
[ -n "$summary" ] || fail "The release summary is empty. Type a short summary of the release."

# Each UTF-8 byte from 0x80 to 0xBF continues a character. The count without these bytes is the
# count of characters, with no dependency on the locale of the runner.
count=$(printf '%s' "$summary" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')
if [ "$count" -gt "$limit" ]; then
    fail "The release summary has $count characters. The limit is $limit." \
        "Write a shorter summary."
fi
if printf '%s\n' "$summary" | grep -q '^[[:blank:]]*#'; then
    fail 'A line of the release summary starts with "#". Remove the "#", because the release' \
        'notes use "#" for their headings.'
fi
printf '%s\n\n' "$summary"
