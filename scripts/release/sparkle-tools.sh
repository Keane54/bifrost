#!/bin/sh
# Gets the Sparkle tools (sign_update) for the sign job of the Release workflow, and prints the
# folder of the tools (docs/release.md).
#
# Usage: scripts/release/sparkle-tools.sh <folder> [<Package.resolved>]
#
# The sign job holds the signing secrets, so it builds nothing and runs no package plug-in. It
# also restores no cache, because a job that runs the code of the packages can change a cache, and
# sign_update reads the Sparkle private key. So the tools must come from Sparkle itself.
# The script reads the pin of Sparkle in the Package.resolved file of the Xcode project. The
# second argument gives another file, for scripts/test-release.sh. The script writes a new package
# in <folder> whose only dependency is Sparkle at the exact pinned version, and resolves it with
# "swift package resolve". So SwiftPM gets no other package of the project, also not SwiftTerm.
# The resolve gets the source and the binary artifact of Sparkle, and it checks the checksum of the
# artifact against the manifest of Sparkle. A resolve builds nothing and runs no plug-in: SwiftPM
# runs a build plug-in only in a build, and a command plug-in only for "swift package <command>".
# The package of Sparkle also has no plug-in, only one binary target. Then the script checks that
# the resolve got the pinned revision, so a tag that moved stops the release.
#
# Exit 0: the script prints the folder of the tools. Exit 1: the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"
root=$(cd "$here/../.." && pwd) || exit 1

if [ $# -ne 1 ] && [ $# -ne 2 ]; then
    fail "usage: scripts/release/sparkle-tools.sh <folder> [<Package.resolved>]"
fi
folder=$1
project_pins=$root/Bifrost.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
resolved=${2:-$project_pins}

# Prints the value at a key path of the JSON file $2, or nothing.
value() {
    plutil -extract "$1" raw -o - "$2" 2>/dev/null
}

# Finds the pin of Sparkle in the Package.resolved file $1. Sets location, version and revision.
read_pin() {
    [ -f "$1" ] || fail "There is no Package.resolved file at $1."
    count=$(value pins "$1") || count=""
    printf '%s\n' "$count" | grep -E -q -x '[0-9]+' || fail "$1 has no list of pins."
    index=0
    while [ "$index" -lt "$count" ]; do
        if [ "$(value "pins.$index.identity" "$1")" = sparkle ]; then
            location=$(value "pins.$index.location" "$1") || location=""
            version=$(value "pins.$index.state.version" "$1") || version=""
            revision=$(value "pins.$index.state.revision" "$1") || revision=""
            return 0
        fi
        index=$((index + 1))
    done
    fail "$1 has no pin of Sparkle."
}

read_pin "$resolved"
pinned_revision=$revision
# The values go into a Swift file, so each value must have the expected form.
printf '%s\n' "$location" | grep -E -q -x 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' ||
    fail "The address of Sparkle in $resolved is not a GitHub address: \"$location\"."
is_version "$version" || fail "The pin of Sparkle in $resolved has no version of the form 1.2.3."
printf '%s\n' "$pinned_revision" | grep -E -q -x '[0-9a-f]{40}' ||
    fail "The pin of Sparkle in $resolved has no revision of 40 hex characters."

package="$folder/package"
scratch="$folder/scratch"
mkdir -p "$package" || fail "Cannot make $package."
cat >"$package/Package.swift" <<SWIFT || fail "Cannot write $package/Package.swift."
// swift-tools-version: 5.9
// Only the Sparkle tools of the sign job (scripts/release/sparkle-tools.sh). No target uses the
// dependency, so nothing builds.
import PackageDescription

let package = Package(
    name: "SparkleTools",
    dependencies: [.package(url: "$location", exact: "$version")],
    targets: []
)
SWIFT
swift package resolve --package-path "$package" --scratch-path "$scratch" >&2 ||
    fail "swift package resolve cannot get Sparkle $version."

read_pin "$package/Package.resolved"
if [ "$revision" != "$pinned_revision" ]; then
    fail "SwiftPM resolved Sparkle $version at $revision, but $resolved pins" \
        "$pinned_revision."
fi
bin="$scratch/artifacts/sparkle/Sparkle/bin"
[ -x "$bin/sign_update" ] || fail "The Sparkle artifact has no sign_update at $bin."
echo "The tools of Sparkle $version (revision $revision) are in $bin." >&2
printf '%s\n' "$bin"
