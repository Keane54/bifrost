#!/bin/sh
# Makes the DMG of a release: a disk image with the app and a link to /Applications.
#
# Usage: scripts/release/make-dmg.sh <app> <dmg> [<identity> <keychain>]
#
# The workflow names the DMG Bifrost-arm64.dmg, with no version, so the link
# https://github.com/Keane54/bifrost/releases/latest/download/Bifrost-arm64.dmg (README, Install)
# always gets the DMG of the latest release. The format is UDBZ (bzip2), as in the Electron
# release. With an identity and a keychain, the script signs the DMG, so that the notary service
# can notarise it (notarise.sh).
#
# Exit 0: the DMG is there. Exit 1: the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"

if [ $# -ne 2 ] && [ $# -ne 4 ]; then
    fail "usage: scripts/release/make-dmg.sh <app> <dmg> [<identity> <keychain>]"
fi
app=$1
dmg=$2
[ -d "$app/Contents" ] || fail "$app is not an app bundle."

stage=$(temp_folder) || fail "Cannot make a temp folder."
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/${app##*/}" || fail "ditto cannot copy $app."
ln -s /Applications "$stage/Applications" || fail "Cannot make the link to /Applications."

# hdiutil on a GitHub runner sometimes fails with "Resource busy". A second try then works.
tries=1
until hdiutil create -volname Bifrost -srcfolder "$stage" -fs HFS+ -format UDBZ -ov "$dmg"; do
    [ "$tries" -lt 3 ] || fail "hdiutil cannot make $dmg."
    tries=$((tries + 1))
    echo "hdiutil failed. Try $tries of 3 starts in 10 seconds."
    sleep 10
done

if [ $# -eq 4 ]; then
    codesign --force --sign "$3" --keychain "$4" --timestamp "$dmg" ||
        fail "codesign cannot sign $dmg."
    codesign --verify --strict --verbose=2 "$dmg" || fail "The signature of $dmg is not valid."
fi
echo "Made $dmg."
