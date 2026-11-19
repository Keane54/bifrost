#!/bin/sh
# Prints latest-mac.yml for the update ZIP of a release: the bridge feed of the Electron app.
#
# Usage: scripts/release/latest-mac.sh <version> <zip> [<release date>]
#
# The Electron app (electron-updater 6.8.11 with the github provider) reads latest-mac.yml of the
# latest release. It takes the .zip entry of "files", downloads that file from the same release,
# checks its size and its SHA-512 (base64), and gives it to Squirrel.Mac. The file has the form
# that electron-builder writes. "path" and "sha512" at the top repeat the ZIP for old updaters.
# The release date is ISO 8601 in UTC. It is the time now when the argument is not there.
#
# minimumSystemVersion: electron-updater compares it with os.release(), the Darwin version, not
# with the macOS version. macOS 26.0 is Darwin 25.0.0, so the value is 25.0.0. A Mac with an older
# macOS does not take the update (user decision, 2026-11-15). The compare uses semver: "26.0" is
# not a semver version, so electron-updater would skip the check, and "26.0.0" would also block
# macOS 26.
#
# Exit 0: the script prints the file. Exit 1: the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"

if [ $# -ne 2 ] && [ $# -ne 3 ]; then
    fail "usage: scripts/release/latest-mac.sh <version> <zip> [<release date>]"
fi
version=$1
zip=$2
date=${3:-$(date -u +%Y-%m-%dT%H:%M:%S.000Z)}
is_version "$version" || fail "\"$version\" is not a version of the form 1.2.3."
[ -f "$zip" ] || fail "There is no ZIP at $zip."
name=${zip##*/}
printf '%s\n' "$name" | grep -E -q -x '[A-Za-z0-9._-]+\.zip' ||
    fail "The name of the ZIP must have only letters, digits, \".\", \"_\" and \"-\": $name."
printf '%s\n' "$date" | grep -E -q -x '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z' ||
    fail "The release date must be ISO 8601 in UTC, for example 2026-11-18T12:00:00.000Z."

sha512=$(openssl dgst -sha512 -binary "$zip" | openssl base64 -A) ||
    fail "openssl cannot read $zip."
size=$(wc -c <"$zip" | tr -d ' ')

cat <<YAML
version: $version
files:
  - url: $name
    sha512: $sha512
    size: $size
path: $name
sha512: $sha512
releaseDate: '$date'
minimumSystemVersion: 25.0.0
YAML
