#!/bin/sh
# Downloads the update ZIP of an Electron release, unpacks it, and prints the path of its app.
#
# Usage: GH_TOKEN=<token> scripts/release/electron-app.sh <tag> <folder>
#
# The bridge check (bridge-check.sh) reads the designated requirement of this app.
# GITHUB_REPOSITORY names the repo of the release. The script fails when the app is not an
# Electron app, for example when the tag names a native release.
#
# Exit 0: the script prints the path of the app. Exit 1: the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"

[ $# -eq 2 ] || fail "usage: scripts/release/electron-app.sh <tag> <folder>"
tag=$1
folder=$2
[ -n "${GITHUB_REPOSITORY-}" ] || fail "GITHUB_REPOSITORY is not set."
mkdir -p "$folder" || fail "Cannot make $folder."
gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern 'Bifrost-*-arm64-mac.zip' \
    --dir "$folder" >&2 || fail "Cannot download the update ZIP of $tag."
set -- "$folder"/Bifrost-*-arm64-mac.zip
[ $# -eq 1 ] && [ -f "$1" ] || fail "The release $tag must have exactly one update ZIP."
ditto -x -k "$1" "$folder/app" || fail "ditto cannot unpack $1."
app="$folder/app/Bifrost.app"
[ -d "$app/Contents/Frameworks/Electron Framework.framework" ] ||
    fail "The ZIP of $tag has no Electron app at Bifrost.app."
printf '%s\n' "$app"
