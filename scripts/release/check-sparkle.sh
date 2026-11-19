#!/bin/sh
# Checks the Sparkle settings of a built Release app (docs/release.md).
#
# Usage: scripts/release/check-sparkle.sh <app> <xcconfig file>
#
# The Info.plist of the app must have:
# - SUFeedURL: an https address that ends with /releases/latest/download/appcast.xml.
# - SUPublicEDKey: the full value of SPARKLE_PUBLIC_KEY in the xcconfig file. The value must be the
#   base64 text of a 32-byte EdDSA public key.
# An xcconfig file reads "//" as the start of a comment, so a key with "//" gets cut with no
# error. In the file, write each "//" of a key as "/$()/". This script removes each "$()" from
# the line of the file and compares the result with the value in the built app. So a cut key
# fails here.
# UpdatePolicy keeps the updater off when the key is empty. A release must update itself, so an
# empty key is an error here.
#
# Exit 0: the settings are correct. Exit 1: the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"

[ $# -eq 2 ] || fail "usage: scripts/release/check-sparkle.sh <app> <xcconfig file>"
app=$1
xcconfig=$2
plist="$app/Contents/Info.plist"
[ -f "$plist" ] || fail "There is no Info.plist at $plist."
[ -f "$xcconfig" ] || fail "There is no xcconfig file at $xcconfig."

value() {
    plutil -extract "$1" raw -o - "$plist" 2>/dev/null || true
}
feed=$(value SUFeedURL)
key=$(value SUPublicEDKey)
# The value of the last SPARKLE_PUBLIC_KEY line (a later line replaces an earlier one), with each
# "$()" and the white space at the end removed.
expected=$(sed -n 's/^[[:space:]]*SPARKLE_PUBLIC_KEY[[:space:]]*=[[:space:]]*//p' "$xcconfig" |
    tail -n 1 | sed -e 's/\$()//g' -e 's/[[:space:]]*$//')

case $feed in
    https://*/releases/latest/download/appcast.xml) ;;
    *)
        fail "SUFeedURL of the app is \"$feed\". It must be an https address that ends with" \
            "/releases/latest/download/appcast.xml."
        ;;
esac
if [ -z "$expected" ]; then
    fail "SPARKLE_PUBLIC_KEY in $xcconfig is empty. A release needs the public key of the" \
        "Sparkle key pair (docs/release.md)."
fi
if [ "$key" != "$expected" ]; then
    fail "SUPublicEDKey of the app is \"$key\", but SPARKLE_PUBLIC_KEY in $xcconfig is" \
        "\"$expected\". An xcconfig file reads \"//\" as the start of a comment: write each" \
        "\"//\" of the key as \"/\$()/\"."
fi
if ! printf '%s\n' "$key" | grep -E -q -x '[A-Za-z0-9+/]{43}='; then
    fail "SUPublicEDKey of the app is not the base64 text of a 32-byte EdDSA key: \"$key\"."
fi
echo "The Sparkle settings of $app are correct."
