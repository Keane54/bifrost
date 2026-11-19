#!/bin/sh
# Signs the Release app and the code in it, from the inside out, with the hardened runtime.
#
# Usage: scripts/release/sign-app.sh <app> <entitlements file> <identity> [<keychain>]
#
# The identity is the SHA-1 hash of a Developer ID Application certificate (signing-identity.sh),
# or "-" for an ad hoc signature (scripts/test-release.sh). With a Developer ID identity, each
# signature gets a secure timestamp, because the notary service needs one.
#
# The script does not use "codesign --deep". That option signs each nested item in the same way,
# but Sparkle needs its own order and options. The order follows the Sparkle 2 documentation
# (Code signing and notarization):
# 1. Each XPC service of Sparkle. Downloader.xpc keeps the entitlements that Sparkle gives it,
#    after a check (see downloader_keys).
# 2. Autoupdate, then Updater.app, then Sparkle.framework.
# 3. Each other framework and each dynamic library in Contents/Frameworks.
# 4. Each other Mach-O file in Contents/MacOS.
# 5. The app, with the entitlements file. The app gets no debugger entitlement.
# The app has no App Sandbox, so Sparkle does not use its XPC services. The script signs them
# because they are in the framework, and the notary service refuses unsigned code.
#
# Exit 0: the app and its nested code have valid signatures. Exit 1: the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"

if [ $# -ne 3 ] && [ $# -ne 4 ]; then
    fail "usage: scripts/release/sign-app.sh <app> <entitlements file> <identity> [<keychain>]"
fi
app=$1
entitlements=$2
identity=$3
keychain=${4-}
[ -d "$app/Contents" ] || fail "$app is not an app bundle."
[ -f "$entitlements" ] || fail "There is no entitlements file at $entitlements."
[ -n "$identity" ] || fail "The identity is empty."
if [ "$identity" = - ]; then
    stamp=--timestamp=none
else
    stamp=--timestamp
fi

# The entitlement keys that Sparkle gives Downloader.xpc, one on each line, sorted. The signature
# keeps the entitlements of Downloader.xpc (--preserve-metadata), and they come from the app of
# the build job. So the script first checks them. Sparkle 2.10.1 gives Downloader.xpc no
# entitlement, so the check of the keys is complete. When a new version of Sparkle gives it
# entitlements, write their keys here, and also check their values.
downloader_keys=''

# Prints the entitlement keys of the code at $1, one on each line, sorted.
entitlement_keys() {
    codesign --display --entitlements - --xml "$1" 2>/dev/null | grep -o '<key>[^<]*</key>' |
        sed -e 's/<key>//' -e 's/<\/key>//' | sort
}

# Signs one item. The first argument is the path. The other arguments are more codesign options.
sign() {
    item=$1
    shift
    echo "sign ${item#"$app/"}"
    if [ -n "$keychain" ]; then
        codesign --force --sign "$identity" --keychain "$keychain" --options runtime "$stamp" \
            "$@" "$item" || fail "codesign could not sign $item."
    else
        codesign --force --sign "$identity" --options runtime "$stamp" "$@" "$item" ||
            fail "codesign could not sign $item."
    fi
}

frameworks="$app/Contents/Frameworks"
sparkle="$frameworks/Sparkle.framework"
current="$sparkle/Versions/B"
[ -d "$sparkle" ] || fail "There is no Sparkle framework at $sparkle."
if [ ! -d "$current" ]; then
    fail "Sparkle.framework has no Versions/B. Check the order of this script against the" \
        "documentation of the new version of Sparkle."
fi
for xpc in "$current"/XPCServices/*.xpc; do
    [ -e "$xpc" ] || continue
    case ${xpc##*/} in
        Downloader.xpc)
            keys=$(entitlement_keys "$xpc")
            if [ "$keys" != "$downloader_keys" ]; then
                fail "Downloader.xpc has other entitlements than Sparkle gives it:" \
                    "$(printf '%s' "$keys" | tr '\n' ' ')(expected: ${downloader_keys:-none})."
            fi
            sign "$xpc" --preserve-metadata=entitlements
            ;;
        *) sign "$xpc" ;;
    esac
done
sign "$current/Autoupdate"
sign "$current/Updater.app"
sign "$sparkle"

for item in "$frameworks"/*; do
    [ -e "$item" ] || continue
    [ "$item" = "$sparkle" ] && continue
    case $item in
        *.framework | *.dylib) sign "$item" ;;
        *) fail "Contents/Frameworks has an unknown item: ${item##*/}. Add a rule for it." ;;
    esac
done

main=$(plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist" 2>/dev/null) ||
    fail "The Info.plist of $app has no CFBundleExecutable."
for item in "$app"/Contents/MacOS/*; do
    [ -f "$item" ] || continue
    [ "${item##*/}" = "$main" ] && continue
    if file -b "$item" | grep -q 'Mach-O'; then
        sign "$item"
    fi
done

sign "$app" --entitlements "$entitlements"
codesign --verify --deep --strict --verbose=2 "$app" || fail "The signature of $app is not valid."
