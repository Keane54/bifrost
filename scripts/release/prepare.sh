#!/bin/sh
# Makes the files of a release in dist/ (docs/release.md).
#
# Usage: scripts/release/prepare.sh <version> <release notes as base64>
#
# semantic-release runs this script as the prepareCmd of the exec plugin (.releaserc.json), with
# the next version and its release notes. The dry run of the Release workflow runs it directly,
# with the release summary as the notes. Only the Release workflow runs it: it builds the Release
# app, and it needs the signing keychain and the secrets.
# The notes come as base64 text, so the shell of the exec plugin gets only the characters A-Z,
# a-z, 0-9, "+", "/" and "=", and never runs a part of the notes.
#
# The environment gives:
# - SIGNING_IDENTITY, SIGNING_KEYCHAIN and TEAM_ID: the keychain step and signing-identity.sh.
# - APPLE_API_KEY, APPLE_API_KEY_ID and APPLE_API_ISSUER: the notary key (notarise.sh).
# - SPARKLE_PRIVATE_KEY: the private key of the Sparkle key pair (sparkle-sign.sh).
# - BRIDGE_APP: the app of the last Electron release (electron-app.sh).
# - GITHUB_REPOSITORY: the owner and the name of the repo, for the address of the update ZIP.
#
# The steps, in this order: build the app, check its Sparkle settings, sign it, notarise and
# staple it, check it, make the update ZIP, do the bridge check on the ZIP, make, sign, notarise
# and staple the DMG, write latest-mac.yml, sign the ZIP for Sparkle, and write appcast.xml.
# The files in dist/: Bifrost-arm64.dmg, Bifrost-<version>-arm64-mac.zip, latest-mac.yml,
# appcast.xml and notes.md. The github plugin publishes the first four (.releaserc.json).
#
# Exit 0: all files are in dist/. Exit 1: a step failed, and the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"
root=$(cd "$here/../.." && pwd) || exit 1
cd "$root" || exit 1

[ $# -eq 2 ] || fail "usage: scripts/release/prepare.sh <version> <release notes as base64>"
version=$1
is_version "$version" || fail "\"$version\" is not a version of the form 1.2.3."
for name in SIGNING_IDENTITY SIGNING_KEYCHAIN TEAM_ID BRIDGE_APP GITHUB_REPOSITORY; do
    eval "value=\${$name-}"
    [ -n "$value" ] || fail "$name is not set."
done

app=.build/xcode/Build/Products/Release/Bifrost.app
dist=dist
zip_name="Bifrost-$version-arm64-mac.zip"
zip="$dist/$zip_name"
dmg="$dist/Bifrost-arm64.dmg"
rm -rf "$dist" || fail "Cannot remove $dist."
mkdir -p "$dist" || fail "Cannot make $dist."
printf '%s' "$2" | openssl base64 -d -A >"$dist/notes.md" || fail "The notes are not base64."
[ -s "$dist/notes.md" ] || fail "The release notes are empty."

step() {
    echo "== $1"
}

step "Build the Release app $version"
"$here/build-app.sh" "$version" || exit 1
step "Check the Sparkle settings"
"$here/check-sparkle.sh" "$app" Config/Release.xcconfig || exit 1
step "Sign the app"
"$here/sign-app.sh" "$app" App/Bifrost/Bifrost.entitlements "$SIGNING_IDENTITY" \
    "$SIGNING_KEYCHAIN" || exit 1
step "Notarise the app"
"$here/notarise.sh" "$app" || exit 1
step "Check the app"
"$here/verify-app.sh" "$app" "$TEAM_ID" "$version" || exit 1
step "Make the update ZIP"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip" || fail "ditto cannot make $zip."
step "Bridge check: the Electron app must accept the update"
"$here/bridge-check.sh" "$BRIDGE_APP" "$zip" || exit 1
step "Make the DMG"
"$here/make-dmg.sh" "$app" "$dmg" "$SIGNING_IDENTITY" "$SIGNING_KEYCHAIN" || exit 1
step "Notarise the DMG"
"$here/notarise.sh" "$dmg" || exit 1
step "Write latest-mac.yml"
"$here/latest-mac.sh" "$version" "$zip" >"$dist/latest-mac.yml" || exit 1
step "Sign the update ZIP for Sparkle"
signature=$("$here/sparkle-sign.sh" "$zip" "$app") || exit 1
step "Write appcast.xml"
length=$(wc -c <"$zip" | tr -d ' ')
address="https://github.com/$GITHUB_REPOSITORY/releases/download/v$version/$zip_name"
"$here/appcast.sh" "$version" "$address" "$length" "$signature" "$dist/notes.md" \
    >"$dist/appcast.xml" || exit 1
echo "The files of version $version are in $dist."
