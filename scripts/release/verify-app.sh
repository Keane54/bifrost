#!/bin/sh
# Checks the signed and notarised Release app before the release publishes it.
#
# Usage: scripts/release/verify-app.sh <app> <team ID> <version>
#
# The checks: the signature of the app and of all nested code is valid; the app and each part of
# Sparkle have the Developer ID signature of the team and the hardened runtime; the app has only
# the audio-input entitlement (no debugger entitlement); the Info.plist has the version, the
# minimum macOS version 26.0 and the microphone usage text; the notarisation ticket is stapled;
# and Gatekeeper accepts the app as notarised. When Gatekeeper is off on the Mac, spctl accepts
# each app, so the script skips that check. The stapled ticket then covers the notarisation.
# Each check prints PASS or FAIL. All commands only read the app.
#
# Exit 0: all checks passed. Exit 1: one or more checks failed.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"

[ $# -eq 3 ] || fail "usage: scripts/release/verify-app.sh <app> <team ID> <version>"
app=$1
team=$2
version=$3
[ -d "$app/Contents" ] || fail "$app is not an app bundle."
printf '%s\n' "$team" | grep -E -q -x '[A-Z0-9]{10}' ||
    fail "The team ID must be 10 upper-case letters and digits."
plist="$app/Contents/Info.plist"
audio=com.apple.security.device.audio-input
failed=0

# Records the result of one check. The arguments: the name of the check, the text to show for a
# failure, and the command of the check.
check() {
    name=$1
    text=$2
    shift 2
    if "$@"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        printf '%s\n' "$text"
        failed=$((failed + 1))
    fi
}

# Returns 0 when the signature of $1 is the Developer ID of the team, with the hardened runtime.
team_signed() {
    details=$(codesign --display --verbose=4 "$1" 2>&1) || return 1
    printf '%s\n' "$details" | grep -q -x "TeamIdentifier=$team" || return 1
    printf '%s\n' "$details" | grep -q '^Authority=Developer ID Application: ' || return 1
    printf '%s\n' "$details" | grep -E -q '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime'
}

value() {
    plutil -extract "$1" raw -o - "$plist" 2>/dev/null || true
}

text=$(codesign --verify --deep --strict --verbose=2 "$app" 2>&1)
code=$?
check "the signature of the app and of its nested code is valid" "$text" test "$code" -eq 0

sparkle="$app/Contents/Frameworks/Sparkle.framework"
current="$sparkle/Versions/B"
for item in "$app" "$sparkle" "$current/Autoupdate" "$current/Updater.app" \
    "$current"/XPCServices/*.xpc; do
    [ -e "$item" ] || continue
    check "${item#"$app"} has the Developer ID of the team and the hardened runtime" \
        "$(codesign --display --verbose=4 "$item" 2>&1)" team_signed "$item"
done

entitlements=$(codesign --display --entitlements - --xml "$app" 2>/dev/null)
keys=$(printf '%s\n' "$entitlements" | grep -o '<key>[^<]*</key>' |
    sed -e 's/<key>//' -e 's/<\/key>//')
check "the app has only the audio-input entitlement" "$entitlements" test "$keys" = "$audio"

short=$(value CFBundleShortVersionString)
build=$(value CFBundleVersion)
check "CFBundleShortVersionString is $version" "It is \"$short\"." test "$short" = "$version"
check "CFBundleVersion is $version" "It is \"$build\"." test "$build" = "$version"
minimum=$(value LSMinimumSystemVersion)
check "the minimum macOS version is 26.0" "It is \"$minimum\"." test "$minimum" = 26.0
usage=$(value NSMicrophoneUsageDescription)
check "the app has the microphone usage text" "The text is empty." test -n "$usage"

text=$(xcrun stapler validate "$app" 2>&1)
code=$?
check "the notarisation ticket is stapled" "$text" test "$code" -eq 0

text=$(spctl --assess --type execute --verbose=4 "$app" 2>&1)
code=$?
case $text in
    *"override=security disabled"*)
        echo "SKIP: Gatekeeper is off on this Mac, so spctl cannot check the app."
        ;;
    *"Notarized Developer ID"*)
        check "Gatekeeper accepts the app as notarised" "$text" test "$code" -eq 0
        ;;
    *) check "Gatekeeper accepts the app as notarised" "$text" false ;;
esac

[ "$failed" -eq 0 ] || fail "$failed check(s) of the app failed. The release stops."
echo "All checks of the app passed."
