#!/bin/sh
# Sends an app or a DMG to the Apple notary service, waits for the result, and staples the ticket.
#
# Usage: scripts/release/notarise.sh <app or dmg>
#
# The environment gives the App Store Connect key: APPLE_API_KEY (the path of the .p8 file),
# APPLE_API_KEY_ID and APPLE_API_ISSUER. The script prints no value of the key.
# The notary service reads a zip, a dmg or a pkg file. For an app, the script sends a zip of the
# app, and then staples the ticket to the app itself.
# When the service does not accept the file, the script prints the log of the service.
#
# Exit 0: the service accepted the file, and the ticket is stapled. Exit 1: the script prints the
# reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"

[ $# -eq 1 ] || fail "usage: scripts/release/notarise.sh <app or dmg>"
file=$1
[ -n "${APPLE_API_KEY-}" ] || fail "APPLE_API_KEY is not set."
[ -n "${APPLE_API_KEY_ID-}" ] || fail "APPLE_API_KEY_ID is not set."
[ -n "${APPLE_API_ISSUER-}" ] || fail "APPLE_API_ISSUER is not set."
[ -f "$APPLE_API_KEY" ] || fail "APPLE_API_KEY is not the path of a file."

work=$(temp_folder) || fail "Cannot make a temp folder."
trap 'rm -rf "$work"' EXIT
case $file in
    *.app)
        [ -d "$file" ] || fail "There is no app at $file."
        upload="$work/upload.zip"
        ditto -c -k --keepParent "$file" "$upload" || fail "ditto cannot make a zip of $file."
        ;;
    *.dmg)
        [ -f "$file" ] || fail "There is no DMG at $file."
        upload=$file
        ;;
    *) fail "notarise.sh needs an .app or a .dmg, not $file." ;;
esac

# notarytool can exit 0 for a submission that the service does not accept. So the script reads
# the status of the result.
result="$work/result.json"
xcrun notarytool submit "$upload" --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER" --wait --timeout 2h --output-format json >"$result"
submit_status=$?
status=$(plutil -extract status raw -o - "$result" 2>/dev/null) || status=""
id=$(plutil -extract id raw -o - "$result" 2>/dev/null) || id=""
echo "notarytool: submission ${id:-(none)} of ${file##*/}: ${status:-no status}" \
    "(exit $submit_status)"
if [ "$status" != Accepted ]; then
    if [ -n "$id" ]; then
        xcrun notarytool log "$id" --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" \
            --issuer "$APPLE_API_ISSUER"
    fi
    fail "The notary service did not accept ${file##*/} (status: ${status:-none})."
fi
xcrun stapler staple "$file" || fail "stapler cannot staple the ticket to $file."
xcrun stapler validate "$file" || fail "The stapled ticket of $file is not valid."
