#!/bin/sh
# Signs the update ZIP for Sparkle and prints the EdDSA signature.
#
# Usage: SPARKLE_PRIVATE_KEY=<key> scripts/release/sparkle-sign.sh <zip> <app>
#
# SPARKLE_PRIVATE_KEY holds the private key that "generate_keys -x" exported (docs/release.md).
# sign_update reads the key on stdin, so the key is never an argument and never a file. With a key
# from stdin, sign_update does not read the Keychain.
# Then the script checks the signature with the public key in the Info.plist of the app
# (SUPublicEDKey, verify-ed-signature.swift). So a release never publishes an update that the
# installed apps refuse, for example after a change of the key pair with no change of the public
# key in Config/Release.xcconfig.
# SPARKLE_BIN can give the folder of the Sparkle tools. The sign job of the Release workflow
# gets the tools with sparkle-tools.sh and sets it. The default is the folder that an xcodebuild
# resolve with -clonedSourcePackagesDirPath .build/spm makes (scripts/test-release.sh).
#
# Exit 0: the script prints the signature. Exit 1: the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"
root=$(cd "$here/../.." && pwd) || exit 1

[ $# -eq 2 ] || fail "usage: SPARKLE_PRIVATE_KEY=<key> scripts/release/sparkle-sign.sh <zip> <app>"
zip=$1
app=$2
bin=${SPARKLE_BIN:-$root/.build/spm/artifacts/sparkle/Sparkle/bin}
[ -f "$zip" ] || fail "There is no ZIP at $zip."
[ -x "$bin/sign_update" ] ||
    fail "There is no sign_update in $bin. Resolve the Swift packages of the project first."
if [ -z "${SPARKLE_PRIVATE_KEY-}" ]; then
    fail "SPARKLE_PRIVATE_KEY is empty. Set the secret SPARKLE_PRIVATE_KEY (docs/release.md)."
fi
public_key=$(plutil -extract SUPublicEDKey raw -o - "$app/Contents/Info.plist" 2>/dev/null) ||
    public_key=""
[ -n "$public_key" ] || fail "The Info.plist of $app has no SUPublicEDKey."

signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$bin/sign_update" --ed-key-file - -p "$zip") ||
    fail "sign_update cannot sign $zip."
xcrun swift "$here/verify-ed-signature.swift" "$public_key" "$signature" "$zip" >&2 ||
    fail "The signature does not match SUPublicEDKey of $app. Check that SPARKLE_PRIVATE_KEY" \
        "and SPARKLE_PUBLIC_KEY in Config/Release.xcconfig are the two keys of one key pair."
printf '%s\n' "$signature"
