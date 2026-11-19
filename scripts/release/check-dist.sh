#!/bin/sh
# Checks that dist/ holds the files of a release of one version, before semantic-release publishes
# them (docs/release.md).
#
# Usage: scripts/release/check-dist.sh <version> [<folder>]
#
# semantic-release runs this script in the publish job of the Release workflow, as the prepareCmd
# of the exec plugin (.releaserc.json), with the version of the tag that it is about to make. The
# sign job made the files before, with prepare.sh, for the version that the dry run of the check
# job found. So when semantic-release finds another version now, the release stops before the
# tag. The folder is dist/ of the repo when the argument is not there.
# The checks: the DMG Bifrost-arm64.dmg is there; the only update ZIP is
# Bifrost-<version>-arm64-mac.zip; latest-mac.yml has the version and names that ZIP; appcast.xml
# has the version and the address of that ZIP in the release of the tag v<version>.
# The script is POSIX sh, and it needs no macOS tool.
#
# Exit 0: the files are correct. Exit 1: the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"
root=$(cd "$here/../.." && pwd) || exit 1

if [ $# -ne 1 ] && [ $# -ne 2 ]; then
    fail "usage: scripts/release/check-dist.sh <version> [<folder>]"
fi
version=$1
dist=${2:-$root/dist}
is_version "$version" || fail "\"$version\" is not a version of the form 1.2.3."
[ -d "$dist" ] || fail "There is no folder $dist. The sign job makes the files (prepare.sh)."

zip_name="Bifrost-$version-arm64-mac.zip"
[ -s "$dist/Bifrost-arm64.dmg" ] || fail "$dist has no Bifrost-arm64.dmg."
set -- "$dist"/Bifrost-*-arm64-mac.zip
if [ $# -ne 1 ] || [ ! -s "$dist/$zip_name" ]; then
    fail "$dist must have exactly one update ZIP, $zip_name. It has: $(cd "$dist" && echo *.zip)."
fi

# Returns 0 when the file $1 has a line that is exactly $2.
has_line() {
    grep -F -x -q -- "$2" "$1"
}
latest="$dist/latest-mac.yml"
[ -f "$latest" ] || fail "$dist has no latest-mac.yml."
for line in "version: $version" "  - url: $zip_name" "path: $zip_name"; do
    has_line "$latest" "$line" || fail "latest-mac.yml has no line \"$line\"."
done

appcast="$dist/appcast.xml"
[ -f "$appcast" ] || fail "$dist has no appcast.xml."
for text in "<sparkle:version>$version</sparkle:version>" \
    "/releases/download/v$version/$zip_name\""; do
    grep -F -q -- "$text" "$appcast" || fail "appcast.xml has no \"$text\"."
done
echo "The files in $dist are the files of version $version."
