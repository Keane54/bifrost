#!/bin/sh
# The bridge check, step 1 (docs/release.md): checks that the Electron app accepts the update.
#
# Usage: scripts/release/bridge-check.sh <old app> <update zip>
#
# The Electron app installs an update with Squirrel.Mac. Squirrel.Mac unpacks the ZIP with ditto
# and takes the app in it that has the bundle ID of the running app. It installs that app only
# when the app meets the designated requirement of the running app, with the strict checks and
# the check of the nested code. This script does the same checks: it reads the designated
# requirement of the old app, unpacks the ZIP, finds the app with the same bundle ID, and checks
# that app against the requirement with codesign. The check needs no release.
#
# Exit 0: the new app meets the requirement. Exit 1: the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"

[ $# -eq 2 ] || fail "usage: scripts/release/bridge-check.sh <old app> <update zip>"
old=$1
zip=$2
[ -d "$old/Contents" ] || fail "$old is not an app bundle."
[ -f "$zip" ] || fail "There is no ZIP at $zip."

old_id=$(plutil -extract CFBundleIdentifier raw -o - "$old/Contents/Info.plist" 2>/dev/null) ||
    fail "The Info.plist of $old has no CFBundleIdentifier."
text=$(codesign --verify --deep --strict "$old" 2>&1) ||
    fail "The signature of the old app is not valid: $text"
# codesign shows an implicit requirement (the one that codesign makes when the signer gives none)
# with "# " before it, and an explicit requirement with no "# ".
requirement=$(codesign --display --requirements - "$old" 2>/dev/null |
    sed -n 's/^\(# \)\{0,1\}designated => //p')
[ -n "$requirement" ] || fail "codesign shows no designated requirement of $old."
echo "The designated requirement of the old app: $requirement"

work=$(temp_folder) || fail "Cannot make a temp folder."
trap 'rm -rf "$work"' EXIT
ditto -x -k "$zip" "$work" || fail "ditto cannot unpack $zip."
new=""
for candidate in "$work"/*.app; do
    [ -d "$candidate" ] || continue
    id=$(plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist" \
        2>/dev/null) || continue
    if [ "$id" = "$old_id" ]; then
        new=$candidate
        break
    fi
done
[ -n "$new" ] || fail "The ZIP has no app with the bundle ID of the old app ($old_id)."

if ! text=$(codesign --verify --deep --strict --verbose=2 --test-requirement="=$requirement" \
    "$new" 2>&1); then
    printf '%s\n' "$text" >&2
    fail "The app in the ZIP does not meet the designated requirement of the old app." \
        "Squirrel.Mac would refuse the update."
fi
printf '%s\n' "$text"
echo "PASS: the app in the ZIP meets the designated requirement of the old app."
