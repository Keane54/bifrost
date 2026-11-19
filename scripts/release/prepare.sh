#!/bin/sh
# Signs the unsigned Release app of the build job and makes the files of a release in dist/
# (docs/release.md).
#
# Usage: scripts/release/prepare.sh <unsigned app> <version> <notes file>
#
# The sign job of the Release workflow runs this script, in each mode. The build job built the app
# with build-app.sh and gave it to the sign job as an artifact, with the version and the release
# notes. This script builds nothing, and it runs no code of the app or of a Swift package. It
# needs the signing keychain and the secrets, so only the sign job runs it.
# The app must be a folder with the name Bifrost.app, because the ZIP and the DMG keep the name.
# The notes file holds the release notes as Markdown. It must not be in dist/.
#
# The environment gives:
# - SIGNING_IDENTITY, SIGNING_KEYCHAIN and TEAM_ID: the keychain step and signing-identity.sh.
# - APPLE_API_KEY, APPLE_API_KEY_ID and APPLE_API_ISSUER: the notary key (notarise.sh).
# - SPARKLE_PRIVATE_KEY: the private key of the Sparkle key pair (sparkle-sign.sh).
# - SPARKLE_BIN: the folder of the Sparkle tools (sparkle-tools.sh). The script needs it, so it
#   never uses the tools in .build/spm, which a build can change.
# - BRIDGE_APP: the app of the last Electron release (electron-app.sh).
# - GITHUB_REPOSITORY: the owner and the name of the repo, for the address of the update ZIP.
#
# First the script checks the arguments, the version of the app and the environment. It changes
# no file before these checks pass, so scripts/test-release.sh can test them with no secret.
# Then the steps, in this order: check the Sparkle settings of the app, sign it, notarise and
# staple it, check it, make the update ZIP, do the bridge check on the ZIP, make, sign, notarise
# and staple the DMG, write latest-mac.yml, sign the ZIP for Sparkle, and write appcast.xml.
# The files in dist/: Bifrost-arm64.dmg, Bifrost-<version>-arm64-mac.zip, latest-mac.yml,
# appcast.xml and notes.md. semantic-release checks the first four (check-dist.sh), and its github
# plugin publishes them (.releaserc.json).
#
# Exit 0: all files are in dist/. Exit 1: a step failed, and the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"
root=$(cd "$here/../.." && pwd) || exit 1

[ $# -eq 3 ] || fail "usage: scripts/release/prepare.sh <unsigned app> <version> <notes file>"
app=$1
version=$2
notes=$3
[ -d "$app/Contents" ] || fail "$app is not an app bundle."
[ "${app##*/}" = Bifrost.app ] || fail "The app must have the name Bifrost.app, not ${app##*/}."
is_version "$version" || fail "\"$version\" is not a version of the form 1.2.3."
[ -s "$notes" ] || fail "The notes file $notes is not there or is empty."
for key in CFBundleShortVersionString CFBundleVersion; do
    value=$(plutil -extract "$key" raw -o - "$app/Contents/Info.plist" 2>/dev/null) || value=""
    if [ "$value" != "$version" ]; then
        fail "$key of the app is \"$value\", not $version. The app must come from the build of" \
            "this version."
    fi
done
for name in SIGNING_IDENTITY SIGNING_KEYCHAIN TEAM_ID SPARKLE_BIN BRIDGE_APP GITHUB_REPOSITORY; do
    eval "value=\${$name-}"
    [ -n "$value" ] || fail "$name is not set."
done

dist="$root/dist"
zip_name="Bifrost-$version-arm64-mac.zip"
zip="$dist/$zip_name"
dmg="$dist/Bifrost-arm64.dmg"
rm -rf "$dist" || fail "Cannot remove $dist."
mkdir -p "$dist" || fail "Cannot make $dist."
cp "$notes" "$dist/notes.md" || fail "Cannot copy the notes file $notes."

step() {
    echo "== $1"
}

step "Check the Sparkle settings"
"$here/check-sparkle.sh" "$app" "$root/Config/Release.xcconfig" || exit 1
step "Sign the app"
"$here/sign-app.sh" "$app" "$root/App/Bifrost/Bifrost.entitlements" "$SIGNING_IDENTITY" \
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
