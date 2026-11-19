#!/bin/sh
# Builds the Release app of a release.
#
# Usage: scripts/release/build-app.sh <version>
#
# Only the Release workflow runs this script (prepare.sh). Do not run it on a Mac: the app has
# the bundle ID of the Electron app (docs/release.md).
#
# The version is the version of semantic-release. The build sets it as MARKETING_VERSION and as
# CURRENT_PROJECT_VERSION, so the app has it as CFBundleShortVersionString and as CFBundleVersion.
# Sparkle compares CFBundleVersion, and its standard comparator orders dotted versions. So each
# release has a higher build number, and no second number is necessary.
#
# The build adds the condition BIFROST_CUTOVER on the command line only, so the released app may
# start (StartGuard). No build configuration sets the condition. Thus a Release build of the
# build configuration alone still refuses to start, and the cutover-condition rule of
# scripts/check_rules.py stays valid. A setting on the command line applies to each target. The
# package targets get the condition too, but only the app target reads it.
#
# The app goes to .build/xcode/Build/Products/Release/Bifrost.app, as in scripts/check.sh.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"
root=$(cd "$here/../.." && pwd) || exit 1
cd "$root" || exit 1

[ $# -eq 1 ] || fail "usage: scripts/release/build-app.sh <version>"
version=$1
is_version "$version" || fail "\"$version\" is not a version of the form 1.2.3."

conditions='SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BIFROST_CUTOVER'

# The last value is the value of the app target. A line above it repeats the setting of the
# command line, with "$(inherited)" not resolved.
resolved=$(xcodebuild -project Bifrost.xcodeproj -target Bifrost -configuration Release \
    -showBuildSettings "$conditions" 2>/dev/null |
    sed -n 's/^ *SWIFT_ACTIVE_COMPILATION_CONDITIONS = //p' | tail -n 1)
case " $resolved " in
    *" BIFROST_CUTOVER "*) echo "The app target gets the conditions: $resolved" ;;
    *) fail "The app target does not get BIFROST_CUTOVER (it gets \"$resolved\")." ;;
esac

xcodebuild -project Bifrost.xcodeproj -scheme Bifrost -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
    -clonedSourcePackagesDirPath .build/spm \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$version" "$conditions" \
    build || fail "The Release build failed."

app=.build/xcode/Build/Products/Release/Bifrost.app
plist="$app/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
    value=$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null) || value=""
    [ "$value" = "$version" ] || fail "$key of the app is \"$value\", not $version."
done
echo "Built $app with version $version."
