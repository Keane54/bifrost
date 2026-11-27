#!/bin/sh
# Builds the host check app and signs it from the inside out.
#
# Usage: scripts/module-host-check/build.sh [--sign-only <app>]
#            [--identity <name> [--keychain <path>]]
#
# The check app stands in for Heimdall: it carries the real module host in Contents/Helpers and the
# test module in Contents/Resources, starts the host the way Heimdall will and runs the checks of
# tools/module-host-check/probe. The script builds the host, the check app and the test module,
# puts them together in .build/module-host-check/Bifrost Module Host Check.app and signs the host
# first, then the app, both with the hardened runtime and no entitlements. It doesn't use
# codesign --deep, because the host and the app each get their own identifier.
#
# With no identity it signs ad hoc with no timestamp, which is enough to run the app on this Mac.
# With --identity (a Developer ID Application certificate, by name or SHA-1 hash) each signature
# gets a secure timestamp for the notary service, and --keychain names the keychain it's in.
#
# --sign-only signs an app that's already built, with the same two signatures and the same check,
# and builds nothing. The signing job of the host check workflow uses it, as that job holds the
# signing keys, so it never runs swift, pnpm, node or anything inside the app.
#
# The IDs come from BIFROST_RELEASE_BUNDLE_ID in Config/Base.xcconfig: the app is
# <id>.module-host-check and the host signs as <id>.module-host, so neither is the installed
# Bifrost. The test module's install needs the npm registry the first time, and only then.
#
# Exit 0: the app is built (or only signed, with --sign-only) and its signature verifies. Exit 1: a
# step failed, and the script says which. Exit 2: a bad argument.

# -f: no file name expansion. -u: an unset variable is an error.
set -fu

# --sign-only takes a path from the folder the script started in.
start=$(pwd) || exit 1
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/../release/lib.sh"
root=$(cd "$here/../.." && pwd) || exit 1
# Stop before any build or rm -rf when the parent folder isn't the repo.
if [ ! -f "$root/Bifrost.xcodeproj/project.pbxproj" ]; then
    fail "$root is not the repo: it has no Bifrost.xcodeproj/project.pbxproj"
fi
cd "$root" || exit 1

usage() {
    echo "usage: scripts/module-host-check/build.sh [--sign-only <app>]" \
        "[--identity <name> [--keychain <path>]]" >&2
    exit 2
}

identity=-
keychain=""
sign_only=""
while [ $# -gt 0 ]; do
    case $1 in
        --identity | --keychain | --sign-only)
            [ $# -ge 2 ] && [ -n "$2" ] || usage
            case $1 in
                --identity) identity=$2 ;;
                --keychain) keychain=$2 ;;
                *) sign_only=$2 ;;
            esac
            shift 2
            ;;
        *) usage ;;
    esac
done
if [ "$identity" = - ]; then
    [ -z "$keychain" ] || usage
    stamp=--timestamp=none
else
    stamp=--timestamp
fi

base_id=$(sed -n 's/^[[:space:]]*BIFROST_RELEASE_BUNDLE_ID[[:space:]]*=[[:space:]]*//p' \
    Config/Base.xcconfig | sed 's/[[:space:]]*$//')
case $base_id in
    '' | *[!A-Za-z0-9.-]*) fail "Config/Base.xcconfig has no single BIFROST_RELEASE_BUNDLE_ID." ;;
esac
app_id=$base_id.module-host-check
host_id=$base_id.module-host

out=.build/module-host-check
app="$out/Bifrost Module Host Check.app"
module=tools/module-host-check/module

# Signs one item with its identifier. The host goes first, because the app's signature seals the
# signatures of the code inside it.
sign() {
    item=$1
    echo "sign ${item#"${app%/*}/"}"
    set -- --force --sign "$identity" --options runtime "$stamp" --identifier "$2" "$item"
    if [ -n "$keychain" ]; then
        set -- --keychain "$keychain" "$@"
    fi
    codesign "$@" || fail "codesign couldn't sign $item."
}

sign_app() {
    sign "$app/Contents/Helpers/bifrost-module-host" "$host_id"
    sign "$app" "$app_id"
    codesign --verify --deep --strict --verbose=2 "$app" ||
        fail "The signature of $app isn't valid."
}

# The app comes from somewhere else, so it's only data here and nothing in it runs. codesign
# follows a symbolic link, so a link could make it change a file outside the app, and the check app
# is built with none, so any link at all stops the signing.
if [ -n "$sign_only" ]; then
    case $sign_only in
        /*) app=${sign_only%/} ;;
        *) app=$start/${sign_only%/} ;;
    esac
    [ -d "$app/Contents" ] && [ ! -L "$app" ] || fail "$app isn't an app folder."
    links=$(find "$app" -type l) || fail "find couldn't read $app."
    [ -z "$links" ] || fail "$app has symbolic links, and the check app has none:" \
        "$(printf '%s' "$links" | tr '\n' ' ')"
    [ -f "$app/Contents/Helpers/bifrost-module-host" ] || fail "$app has no host in its Helpers."
    sign_app
    echo "Signed $app."
    exit 0
fi

# The host gets the same build as the plan's own command for it, and the check app the same flags.
echo "build the host"
set -- -c release --package-path Packages/Bifrost --scratch-path .build/pkg-release
swift build "$@" --product bifrost-module-host -Xswiftc -warnings-as-errors ||
    fail "The host build failed."
host_bin=$(swift build "$@" --show-bin-path)/bifrost-module-host || fail "No host build folder."

echo "build the check app"
set -- -c release --package-path tools/module-host-check/probe \
    --scratch-path .build/pkg-module-host-check
swift build "$@" -Xswiftc -warnings-as-errors || fail "The check app build failed."
probe_bin=$(swift build "$@" --show-bin-path)/module-host-check || fail "No check app folder."

echo "build the test module"
(cd "$module" && pnpm install --frozen-lockfile && node build.ts) ||
    fail "The test module build failed."

echo "put the app together"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" || exit 1
cp "$probe_bin" "$app/Contents/MacOS/module-host-check" || fail "The check app is missing."
cp "$host_bin" "$app/Contents/Helpers/bifrost-module-host" || fail "The host is missing."
cp "$module/dist/module.js" "$app/Contents/Resources/module.js" || fail "The module is missing."
cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>module-host-check</string>
    <key>CFBundleIdentifier</key>
    <string>$app_id</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Bifrost Module Host Check</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF
plutil -lint "$app/Contents/Info.plist" >/dev/null || fail "The app's Info.plist isn't valid."

sign_app
echo "Built $app."
