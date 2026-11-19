#!/bin/sh
# Self-test of the release scripts in scripts/release (docs/release.md) that need no secret.
#
# Usage: scripts/test-release.sh
#
# The cases: summary.sh (with sh and with dash), signing-identity.sh with fixture outputs of
# "security find-identity", latest-mac.sh with a fixture ZIP, appcast.sh with fixture notes,
# check-dist.sh with fixture release files, check-sparkle.sh with fixture apps and with the real
# Release settings, sparkle-sign.sh with a new test key, sparkle-tools.sh with fixture pins (only
# the checks before the resolve), bridge-check.sh with ad hoc apps, sign-app.sh with an ad hoc
# signature and a copy of Sparkle.framework, and the checks of prepare.sh before it signs.
# The script never builds or starts the Release app, never reads the Keychain and uses no network.
# sparkle-sign.sh and sign-app.sh need the Sparkle tools and the Sparkle framework in .build/spm.
# A resolve of the Swift packages of the project puts them there (check.sh runs this test after
# its Debug build). The temp files go to a folder in .build, and the script removes the folder at
# the end.
#
# Exit 0: all cases passed, and the script prints PASS. Exit 1: the script prints the failed case.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
root=$(dirname "$here")
release="$here/release"
fix="$here/release-fixtures/Fixtures"
artifacts="$root/.build/spm/artifacts/sparkle/Sparkle"
sparkle_bin="$artifacts/bin"
sparkle_framework="$artifacts/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$root/.build" || exit 1
tmp=$(mktemp -d "$root/.build/release-test.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
# The scripts make their temp folders in TMPDIR (lib.sh). In GitHub Actions, an error of a script
# is an annotation of the run. The cases expect errors, so the script turns the annotations off.
TMPDIR=$tmp
export TMPDIR
unset GITHUB_ACTIONS RUNNER_TEMP SPARKLE_PRIVATE_KEY SPARKLE_BIN SIGNING_IDENTITY SIGNING_KEYCHAIN \
    TEAM_ID BRIDGE_APP

fail() {
    echo "FAIL: $1"
    exit 1
}

# Runs a command. Sets out (stdout and stderr together) and code.
run() {
    out=$("$@" 2>&1)
    code=$?
}

# The command must exit 0. Arguments: the case, then the command.
expect_ok() {
    name=$1
    shift
    run "$@"
    [ "$code" -eq 0 ] || fail "$name: expected exit 0, got $code: $out"
}

# The command must exit 1 with a text in its output. Arguments: the case, the text, the command.
expect_error() {
    name=$1
    text=$2
    shift 2
    run "$@"
    [ "$code" -eq 1 ] || fail "$name: expected exit 1, got $code: $out"
    printf '%s\n' "$out" | grep -q -F -- "$text" || fail "$name: no \"$text\" in: $out"
}

# The file $2 must have the same bytes as the file $3. The first argument names the case.
expect_same() {
    cmp -s "$2" "$3" || fail "$1: $2 differs from $3: $(diff "$3" "$2" | sed -n '1,20p')"
}

# Writes the Info.plist of a test app. Arguments: the app, then pairs of a key and a text value.
info_plist() {
    plist_app=$1
    shift
    mkdir -p "$plist_app/Contents/MacOS" || fail "cannot make $plist_app"
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"' \
            '	"http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0">' '<dict>'
        while [ $# -ge 2 ]; do
            printf '\t<key>%s</key>\n\t<string>%s</string>\n' "$1" "$2"
            shift 2
        done
        printf '%s\n' '</dict>' '</plist>'
    } >"$plist_app/Contents/Info.plist" || fail "cannot write the Info.plist of $plist_app"
}

# --- summary.sh ---------------------------------------------------------------------------------

shells='sh'
command -v dash >/dev/null 2>&1 && shells="sh dash"
python3 -I -c 'print("é" * 600, end="")' >"$tmp/600.txt" || fail "python3 cannot write a text"
python3 -I -c 'print("é" * 601, end="")' >"$tmp/601.txt" || fail "python3 cannot write a text"
for shell in $shells; do
    summary() {
        RELEASE_SUMMARY=$1 "$shell" "$release/summary.sh"
    }
    RELEASE_SUMMARY='
  Bifrost is native now.
  It keeps your data.	 ' "$shell" "$release/summary.sh" >"$tmp/summary.out" ||
        fail "summary ($shell): a good summary failed"
    printf 'Bifrost is native now.\n  It keeps your data.\n\n' >"$tmp/summary.expected"
    expect_same "summary ($shell): the trimmed text and a blank line" "$tmp/summary.out" \
        "$tmp/summary.expected"
    expect_ok "summary ($shell): a \"#\" inside a line" summary 'Fixes #12 and the rest.'
    expect_ok "summary ($shell): 600 characters of two bytes" summary "$(cat "$tmp/600.txt")"
    expect_error "summary ($shell): 601 characters" "has 601 characters" summary \
        "$(cat "$tmp/601.txt")"
    expect_error "summary ($shell): empty" "is empty" summary ''
    expect_error "summary ($shell): only white space" "is empty" summary "$(printf ' \t\n ')"
    expect_error "summary ($shell): a heading" 'starts with "#"' summary "$(printf 'One.\n  # Two')"
done
GITHUB_ACTIONS=true RELEASE_SUMMARY='' "$release/summary.sh" 2>"$tmp/annotation.txt"
grep -q '^::error::The release summary is empty' "$tmp/annotation.txt" ||
    fail "summary: no error annotation in GitHub Actions: $(cat "$tmp/annotation.txt")"

# --- signing-identity.sh ------------------------------------------------------------------------

identity() {
    "$release/signing-identity.sh" <"$1"
}
"$release/signing-identity.sh" <"$fix/identities-one.txt" >"$tmp/identity.out" 2>/dev/null ||
    fail "signing identity: one Developer ID identity failed"
printf 'SIGNING_IDENTITY=ABCDEF0123456789ABCDEF0123456789ABCDEF01\nTEAM_ID=ABCDE12345\n' \
    >"$tmp/identity.expected"
expect_same "signing identity: the hash and the team" "$tmp/identity.out" "$tmp/identity.expected"
expect_error "signing identity: none" "No Developer ID Application identity" identity \
    "$fix/identities-none.txt"
expect_error "signing identity: no input" "No Developer ID Application identity" identity \
    /dev/null
expect_error "signing identity: two" "holds 2 Developer ID" identity "$fix/identities-two.txt"
expect_error "signing identity: no team" "must end with the team ID" identity \
    "$fix/identities-no-team.txt"

# --- latest-mac.sh ------------------------------------------------------------------------------

zip="$fix/Bifrost-1.2.3-arm64-mac.zip"
"$release/latest-mac.sh" 1.2.3 "$zip" 2026-11-18T12:00:00.000Z >"$tmp/latest-mac.yml" ||
    fail "latest-mac: the fixture failed"
expect_same "latest-mac: the fixture" "$tmp/latest-mac.yml" "$fix/latest-mac.yml"
# The SHA-512 and the size of another implementation (Python) must be in the file.
python3 -I - "$zip" "$tmp/latest-mac.yml" <<'EOF' || fail "latest-mac: the hash or the size"
import base64, hashlib, sys
data = open(sys.argv[1], "rb").read()
lines = open(sys.argv[2]).read().split("\n")
sha = base64.b64encode(hashlib.sha512(data).digest()).decode()
assert lines.count(f"    sha512: {sha}") == 1, "files: sha512"
assert lines.count(f"sha512: {sha}") == 1, "top: sha512"
assert lines.count(f"    size: {len(data)}") == 1, "size"
assert "minimumSystemVersion: 25.0.0" in lines, "minimumSystemVersion"
EOF
expect_ok "latest-mac: the date of now" "$release/latest-mac.sh" 1.2.3 "$zip"
printf '%s\n' "$out" | grep -E -q -x "releaseDate: '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\.000Z'" ||
    fail "latest-mac: the date of now: $out"
expect_error "latest-mac: a bad version" "is not a version" "$release/latest-mac.sh" 1.2 "$zip"
expect_error "latest-mac: no ZIP" "There is no ZIP" "$release/latest-mac.sh" 1.2.3 "$tmp/no.zip"
cp "$zip" "$tmp/my update.zip" || fail "cannot copy the ZIP"
expect_error "latest-mac: a space in the name" "The name of the ZIP" "$release/latest-mac.sh" \
    1.2.3 "$tmp/my update.zip"

# --- appcast.sh ---------------------------------------------------------------------------------

address=https://github.com/example/bifrost/releases/download/v1.2.3/Bifrost-1.2.3-arm64-mac.zip
signature=$(python3 -I -c 'print("A" * 86 + "==")')
date='Wed, 18 Nov 2026 12:00:00 +0000'
appcast() {
    "$release/appcast.sh" "$@"
}
appcast 1.2.3 "$address" 1517 "$signature" "$fix/notes.md" "$date" >"$tmp/appcast.xml" ||
    fail "appcast: the fixture failed"
expect_same "appcast: the fixture" "$tmp/appcast.xml" "$fix/appcast.xml"
xmllint --noout "$tmp/appcast.xml" || fail "appcast: the XML is not well formed"
python3 -I - "$tmp/appcast.xml" "$fix/notes.md" "$address" "$signature" <<'EOF' ||
import sys
import xml.etree.ElementTree as ET
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
item = ET.parse(sys.argv[1]).find("./channel/item")
notes = open(sys.argv[2]).read()
assert item.find("description").text == notes, "the description is not the notes"
assert item.find("description").get(sparkle + "format") == "markdown", "format"
assert item.find(sparkle + "version").text == "1.2.3", "sparkle:version"
assert item.find(sparkle + "shortVersionString").text == "1.2.3", "shortVersionString"
assert item.find(sparkle + "minimumSystemVersion").text == "26.0", "minimumSystemVersion"
enclosure = item.find("enclosure")
assert enclosure.get("url") == sys.argv[3], "url"
assert enclosure.get("length") == "1517", "length"
assert enclosure.get(sparkle + "edSignature") == sys.argv[4], "edSignature"
EOF
    fail "appcast: a value of the item"
expect_ok "appcast: the date of now" appcast 1.2.3 "$address" 1517 "$signature" "$fix/notes.md"
expect_error "appcast: http" "https address" appcast 1.2.3 "http://example.com/a.zip" 1517 \
    "$signature" "$fix/notes.md"
expect_error "appcast: a quote in the address" "https address" appcast 1.2.3 \
    'https://example.com/a".zip' 1517 "$signature" "$fix/notes.md"
expect_error "appcast: a bad length" "length must be" appcast 1.2.3 "$address" 0x10 \
    "$signature" "$fix/notes.md"
expect_error "appcast: a short signature" "64-byte" appcast 1.2.3 "$address" 1517 "AAAA" \
    "$fix/notes.md"
expect_error "appcast: no notes" "no notes file" appcast 1.2.3 "$address" 1517 "$signature" \
    "$tmp/none.md"
expect_error "appcast: a bad date" "RFC 822" appcast 1.2.3 "$address" 1517 "$signature" \
    "$fix/notes.md" 2026-11-18

# --- check-dist.sh ------------------------------------------------------------------------------

# Makes the release files of version 1.2.3 in the folder $1, from the fixtures.
make_dist() {
    rm -rf "$1"
    mkdir -p "$1" || fail "cannot make $1"
    printf 'dmg\n' >"$1/Bifrost-arm64.dmg"
    cp "$zip" "$fix/latest-mac.yml" "$fix/appcast.xml" "$1/" || fail "cannot copy the fixtures"
}
dist="$tmp/dist"
check_dist() {
    "$release/check-dist.sh" "$1" "$dist"
}
make_dist "$dist"
expect_ok "dist: the files of 1.2.3" check_dist 1.2.3
expect_error "dist: another version" "exactly one update ZIP, Bifrost-1.2.4-arm64-mac.zip" \
    check_dist 1.2.4
expect_error "dist: a bad version" "is not a version" check_dist 1.2
expect_error "dist: no folder" "There is no folder" "$release/check-dist.sh" 1.2.3 "$tmp/none"
cp "$zip" "$dist/Bifrost-1.2.2-arm64-mac.zip" || fail "cannot copy the ZIP"
expect_error "dist: two ZIPs" "exactly one update ZIP" check_dist 1.2.3
make_dist "$dist"
rm "$dist/Bifrost-arm64.dmg"
expect_error "dist: no DMG" "no Bifrost-arm64.dmg" check_dist 1.2.3
make_dist "$dist"
sed 's/^version: 1.2.3$/version: 1.2.4/' "$fix/latest-mac.yml" >"$dist/latest-mac.yml"
expect_error "dist: latest-mac.yml of another version" 'no line "version: 1.2.3"' check_dist 1.2.3
make_dist "$dist"
sed 's|/v1.2.3/|/v1.2.4/|' "$fix/appcast.xml" >"$dist/appcast.xml"
expect_error "dist: appcast.xml of another tag" "appcast.xml has no" check_dist 1.2.3
make_dist "$dist"
sed 's|<sparkle:version>1.2.3<|<sparkle:version>1.2.4<|' "$fix/appcast.xml" >"$dist/appcast.xml"
expect_error "dist: appcast.xml of another version" "<sparkle:version>1.2.3" check_dist 1.2.3

# --- check-sparkle.sh ---------------------------------------------------------------------------

feed=https://github.com/example/bifrost/releases/latest/download/appcast.xml
# A key with "//" in it, as base64 text of 32 bytes.
key='ab//cdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNO='
other_key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
sparkle_check() {
    printf '// A test file.\nSPARKLE_PUBLIC_KEY = %s\n' "$1" >"$tmp/Release.xcconfig"
    info_plist "$tmp/Key.app" SUFeedURL "$2" SUPublicEDKey "$3"
    "$release/check-sparkle.sh" "$tmp/Key.app" "$tmp/Release.xcconfig"
}
expect_ok "sparkle: a key" sparkle_check "$other_key" "$feed" "$other_key"
written_key='ab/$()/cdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNO='
expect_ok "sparkle: a key with /\$()/" sparkle_check "$written_key" "$feed" "$key"
expect_error "sparkle: a key cut at //" "start of a comment" sparkle_check "$key" "$feed" ab
expect_error "sparkle: an empty key" "is empty" sparkle_check "" "$feed" ""
expect_error "sparkle: another key" "start of a comment" sparkle_check "$other_key" "$feed" "$key"
expect_error "sparkle: a short key" "not the base64 text" sparkle_check AAAA= "$feed" AAAA=
expect_error "sparkle: an http feed" "SUFeedURL" sparkle_check "$other_key" \
    http://example.com/releases/latest/download/appcast.xml "$other_key"
expect_error "sparkle: another feed file" "SUFeedURL" sparkle_check "$other_key" \
    https://example.com/releases/latest/download/feed.xml "$other_key"
expect_error "sparkle: no Info.plist" "no Info.plist" "$release/check-sparkle.sh" \
    "$tmp/None.app" "$tmp/Release.xcconfig"

# The real Release settings: the resolved values of Config/Release.xcconfig. Xcode puts these
# values into the Info.plist of the Release app. The command only reads the build settings. It
# builds nothing.
settings=$(cd "$root" && xcodebuild -project Bifrost.xcodeproj -target Bifrost \
    -configuration Release -showBuildSettings 2>/dev/null) || fail "sparkle: no build settings"
real_feed=$(printf '%s\n' "$settings" | sed -n 's/^ *SPARKLE_FEED_URL = //p')
real_key=$(printf '%s\n' "$settings" | sed -n 's/^ *SPARKLE_PUBLIC_KEY = //p')
info_plist "$tmp/Real.app" SUFeedURL "$real_feed" SUPublicEDKey "$real_key"
expect_ok "sparkle: the real Release settings" "$release/check-sparkle.sh" "$tmp/Real.app" \
    "$root/Config/Release.xcconfig"

# --- sparkle-sign.sh and verify-ed-signature.swift ----------------------------------------------

[ -x "$sparkle_bin/sign_update" ] ||
    fail "no Sparkle tools in $sparkle_bin. Resolve the Swift packages of the project first."
public_key() {
    xcrun swift "$here/release-fixtures/ed25519-public-key.swift" "$1"
}
seed=$(openssl rand -base64 32) || fail "openssl cannot make a test key"
other_seed=$(openssl rand -base64 32) || fail "openssl cannot make a test key"
public=$(public_key "$seed") || fail "sparkle sign: no public key of the test key"
other_public=$(public_key "$other_seed") || fail "sparkle sign: no public key of the test key"
info_plist "$tmp/Signed.app" SUPublicEDKey "$public"
info_plist "$tmp/Other.app" SUPublicEDKey "$other_public"
info_plist "$tmp/NoKey.app" CFBundleName NoKey
sparkle_sign() {
    SPARKLE_PRIVATE_KEY=$1 "$release/sparkle-sign.sh" "$2" "$3"
}
signed=$(sparkle_sign "$seed" "$zip" "$tmp/Signed.app" 2>"$tmp/sign.err") ||
    fail "sparkle sign: the test key failed: $(cat "$tmp/sign.err")"
printf '%s\n' "$signed" | grep -E -q -x '[A-Za-z0-9+/]{86}==' ||
    fail "sparkle sign: the output is not one signature: $signed"
expect_ok "sparkle sign: the signature with the public key" xcrun swift \
    "$release/verify-ed-signature.swift" "$public" "$signed" "$zip"
expect_error "sparkle sign: another file" "does not match" xcrun swift \
    "$release/verify-ed-signature.swift" "$public" "$signed" "$fix/notes.md"
expect_error "sparkle sign: another key pair" "does not match SUPublicEDKey" sparkle_sign "$seed" \
    "$zip" "$tmp/Other.app"
expect_error "sparkle sign: no private key" "SPARKLE_PRIVATE_KEY is empty" sparkle_sign "" "$zip" \
    "$tmp/Signed.app"
expect_error "sparkle sign: no public key" "has no SUPublicEDKey" sparkle_sign "$seed" "$zip" \
    "$tmp/NoKey.app"

# --- sparkle-tools.sh ---------------------------------------------------------------------------

# Only the checks of the pins: each case fails before the resolve, so no case uses the network.
# Writes a Package.resolved file with one pin. Arguments: the file, the identity, the address,
# the version and the revision.
pin_file() {
    printf '{"pins":[{"identity":"%s","kind":"remoteSourceControl","location":"%s",%s}],%s}\n' \
        "$2" "$3" "\"state\":{\"revision\":\"$5\",\"version\":\"$4\"}" '"version":3' >"$1" ||
        fail "cannot write $1"
}
tools() {
    "$release/sparkle-tools.sh" "$tmp/tools" "$1"
}
sparkle_url=https://github.com/sparkle-project/Sparkle
revision=ab7d71291238df6e0492143b120c9b696a35f603
pin_file "$tmp/other.resolved" swiftterm https://github.com/migueldeicaza/SwiftTerm 1.99.3 \
    "$revision"
expect_error "sparkle tools: no pin of Sparkle" "has no pin of Sparkle" tools "$tmp/other.resolved"
expect_error "sparkle tools: no file" "There is no Package.resolved" tools "$tmp/none.resolved"
printf '{"version":3}\n' >"$tmp/empty.resolved"
expect_error "sparkle tools: no pins" "has no list of pins" tools "$tmp/empty.resolved"
# The JSON text \" is a quote in the address.
pin_file "$tmp/quote.resolved" sparkle 'https://github.com/a/b\", exact: \"1.0.0\")' 2.10.1 \
    "$revision"
expect_error "sparkle tools: a quote in the address" "not a GitHub address" tools \
    "$tmp/quote.resolved"
pin_file "$tmp/branch.resolved" sparkle "$sparkle_url" "" "$revision"
expect_error "sparkle tools: no version" "no version of the form" tools "$tmp/branch.resolved"
pin_file "$tmp/short.resolved" sparkle "$sparkle_url" 2.10.1 abc
expect_error "sparkle tools: a short revision" "no revision of 40 hex" tools "$tmp/short.resolved"
[ ! -e "$tmp/tools" ] || fail "sparkle tools: a failed check made $tmp/tools"

# --- bridge-check.sh ----------------------------------------------------------------------------

printf 'int main(void) { return 0; }\n' >"$tmp/tiny.c"
cc -o "$tmp/tiny" "$tmp/tiny.c" || fail "cc cannot build the test program"
# Makes an unsigned test app. Arguments: the app and its bundle ID.
make_app() {
    info_plist "$1" CFBundleIdentifier "$2" CFBundleExecutable Tiny CFBundlePackageType APPL
    cp "$tmp/tiny" "$1/Contents/MacOS/Tiny" || fail "cannot copy the test program"
}
# Makes an update ZIP with the app $1 in it, as prepare.sh does. The second argument is the ZIP.
make_zip() {
    ditto -c -k --sequesterRsrc --keepParent "$1" "$2" || fail "ditto cannot make $2"
}
adhoc() {
    codesign --force --sign - "$@" >/dev/null 2>&1 || fail "codesign cannot sign the test app"
}
bridge=com.example.bridge
mkdir -p "$tmp/old" "$tmp/good" "$tmp/other-id" "$tmp/other-bundle" "$tmp/unsigned" \
    "$tmp/broken" || fail "cannot make the folders of the test apps"
# The old app has a designated requirement on its identifier only, as a stand-in for the
# requirement of a Developer ID app.
make_app "$tmp/old/Bifrost.app" "$bridge"
adhoc --requirements="=designated => identifier \"$bridge\"" "$tmp/old/Bifrost.app"
# This old app has the implicit requirement of an ad hoc signature: its cdhash. One more file
# makes its cdhash different from the cdhash of the good app.
make_app "$tmp/cdhash/Bifrost.app" "$bridge"
mkdir -p "$tmp/cdhash/Bifrost.app/Contents/Resources" || fail "cannot make a Resources folder"
printf 'old\n' >"$tmp/cdhash/Bifrost.app/Contents/Resources/old.txt"
adhoc "$tmp/cdhash/Bifrost.app"
make_app "$tmp/good/Bifrost.app" "$bridge"
adhoc "$tmp/good/Bifrost.app"
make_app "$tmp/other-id/Bifrost.app" "$bridge"
adhoc --identifier com.example.other "$tmp/other-id/Bifrost.app"
make_app "$tmp/other-bundle/Bifrost.app" com.example.other
adhoc "$tmp/other-bundle/Bifrost.app"
make_app "$tmp/unsigned/Bifrost.app" "$bridge"
codesign --remove-signature "$tmp/unsigned/Bifrost.app/Contents/MacOS/Tiny" ||
    fail "codesign cannot remove the signature of the linker"
make_app "$tmp/broken/Bifrost.app" "$bridge"
adhoc "$tmp/broken/Bifrost.app"
printf 'changed\n' >>"$tmp/broken/Bifrost.app/Contents/Info.plist"
for name in good other-id other-bundle unsigned broken; do
    make_zip "$tmp/$name/Bifrost.app" "$tmp/$name.zip"
done
bridge_check() {
    "$release/bridge-check.sh" "$1" "$2"
}
expect_ok "bridge: the same identifier" bridge_check "$tmp/old/Bifrost.app" "$tmp/good.zip"
printf '%s\n' "$out" | grep -q -F "identifier \"$bridge\"" ||
    fail "bridge: no requirement in the output: $out"
expect_error "bridge: another identifier" "does not meet" bridge_check "$tmp/old/Bifrost.app" \
    "$tmp/other-id.zip"
expect_error "bridge: another bundle ID" "no app with the bundle ID" bridge_check \
    "$tmp/old/Bifrost.app" "$tmp/other-bundle.zip"
expect_error "bridge: an unsigned app" "does not meet" bridge_check "$tmp/old/Bifrost.app" \
    "$tmp/unsigned.zip"
expect_error "bridge: a changed app" "does not meet" bridge_check "$tmp/old/Bifrost.app" \
    "$tmp/broken.zip"
# The requirement of the old app is implicit here, so codesign shows it with "# " before it.
expect_error "bridge: an old app with a cdhash requirement" "does not meet" bridge_check \
    "$tmp/cdhash/Bifrost.app" "$tmp/good.zip"
printf '%s\n' "$out" | grep -q -F 'requirement of the old app: cdhash H"' ||
    fail "bridge: the implicit requirement: $out"
expect_error "bridge: an unsigned old app" "old app is not valid" bridge_check \
    "$tmp/unsigned/Bifrost.app" "$tmp/good.zip"
expect_error "bridge: no ZIP" "There is no ZIP" bridge_check "$tmp/old/Bifrost.app" \
    "$tmp/none.zip"

# --- sign-app.sh --------------------------------------------------------------------------------

[ -d "$sparkle_framework" ] ||
    fail "no Sparkle framework at $sparkle_framework. Resolve the Swift packages first."
entitlements="$root/App/Bifrost/Bifrost.entitlements"
# Makes an unsigned app with Sparkle.framework and a second program in Contents/MacOS.
make_sparkle_app() {
    make_app "$1" "$bridge"
    mkdir -p "$1/Contents/Frameworks" || fail "cannot make the Frameworks folder"
    ditto "$sparkle_framework" "$1/Contents/Frameworks/Sparkle.framework" ||
        fail "ditto cannot copy Sparkle.framework"
    cp "$tmp/tiny" "$1/Contents/MacOS/helper" || fail "cannot copy the test program"
}
app="$tmp/sign/Bifrost.app"
make_sparkle_app "$app"
current="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
downloader_before=$(codesign --display --entitlements - --xml \
    "$current/XPCServices/Downloader.xpc" 2>/dev/null)
[ -n "$downloader_before" ] || fail "sign: Downloader.xpc of Sparkle has no entitlements"
expect_ok "sign: an ad hoc signature" "$release/sign-app.sh" "$app" "$entitlements" -
codesign --verify --deep --strict "$app" 2>/dev/null || fail "sign: the signature is not valid"
for item in "$app" "$app/Contents/MacOS/helper" "$app/Contents/Frameworks/Sparkle.framework" \
    "$current/Autoupdate" "$current/Updater.app" "$current/XPCServices/Downloader.xpc" \
    "$current/XPCServices/Installer.xpc"; do
    codesign --display --verbose=4 "$item" 2>&1 |
        grep -E -q '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' ||
        fail "sign: no hardened runtime on ${item#"$tmp/"}"
done
downloader_after=$(codesign --display --entitlements - --xml \
    "$current/XPCServices/Downloader.xpc" 2>/dev/null)
[ "$downloader_after" = "$downloader_before" ] ||
    fail "sign: Downloader.xpc lost its entitlements: $downloader_after"
keys=$(codesign --display --entitlements - --xml "$app" 2>/dev/null |
    grep -o '<key>[^<]*</key>')
[ "$keys" = '<key>com.apple.security.device.audio-input</key>' ] ||
    fail "sign: the entitlements of the app: $keys"

make_sparkle_app "$tmp/unknown/Bifrost.app"
printf 'text\n' >"$tmp/unknown/Bifrost.app/Contents/Frameworks/notes.txt"
expect_error "sign: an unknown item in Frameworks" "unknown item: notes.txt" \
    "$release/sign-app.sh" "$tmp/unknown/Bifrost.app" "$entitlements" -
make_app "$tmp/nosparkle/Bifrost.app" "$bridge"
expect_error "sign: no Sparkle" "no Sparkle framework" "$release/sign-app.sh" \
    "$tmp/nosparkle/Bifrost.app" "$entitlements" -

# --- prepare.sh ---------------------------------------------------------------------------------

# Only the checks before the first change: each case fails before prepare.sh removes dist/, signs
# or sends a file. The environment has no secret.
prep="$tmp/prep/Bifrost.app"
info_plist "$prep" CFBundleShortVersionString 1.2.3 CFBundleVersion 1.2.3
info_plist "$tmp/prep-name/Other.app" CFBundleShortVersionString 1.2.3 CFBundleVersion 1.2.3
info_plist "$tmp/prep-build/Bifrost.app" CFBundleShortVersionString 1.2.3 CFBundleVersion 1.2.2
: >"$tmp/empty-notes.md"
prepare() {
    "$release/prepare.sh" "$@"
}
expect_error "prepare: two arguments" "usage" prepare "$prep" 1.2.3
expect_error "prepare: no app" "is not an app bundle" prepare "$tmp/none/Bifrost.app" 1.2.3 \
    "$fix/notes.md"
expect_error "prepare: another name" "must have the name Bifrost.app" prepare \
    "$tmp/prep-name/Other.app" 1.2.3 "$fix/notes.md"
expect_error "prepare: a bad version" "is not a version" prepare "$prep" 1.2 "$fix/notes.md"
expect_error "prepare: no notes" "is not there or is empty" prepare "$prep" 1.2.3 "$tmp/none.md"
expect_error "prepare: empty notes" "is not there or is empty" prepare "$prep" 1.2.3 \
    "$tmp/empty-notes.md"
expect_error "prepare: the app of another version" \
    'CFBundleShortVersionString of the app is "1.2.3", not 1.2.4' prepare "$prep" 1.2.4 \
    "$fix/notes.md"
expect_error "prepare: another build number" 'CFBundleVersion of the app is "1.2.2"' prepare \
    "$tmp/prep-build/Bifrost.app" 1.2.3 "$fix/notes.md"
expect_error "prepare: no signing identity" "SIGNING_IDENTITY is not set" prepare "$prep" 1.2.3 \
    "$fix/notes.md"
expect_error "prepare: no Sparkle tools" "SPARKLE_BIN is not set" env SIGNING_IDENTITY=- \
    SIGNING_KEYCHAIN="$tmp/none.keychain-db" TEAM_ID=ABCDE12345 "$release/prepare.sh" "$prep" \
    1.2.3 "$fix/notes.md"

echo PASS
