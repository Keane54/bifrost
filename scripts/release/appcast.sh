#!/bin/sh
# Prints appcast.xml for a release: the Sparkle feed of the native app.
#
# Usage: scripts/release/appcast.sh <version> <zip address> <length> <signature> <notes file>
#            [<date>]
#
# The app reads the feed at SUFeedURL (releases/latest/download/appcast.xml). So the feed of each
# release has one item: that release. The item has:
# - sparkle:version and sparkle:shortVersionString: the version. Sparkle compares
#   sparkle:version with CFBundleVersion of the running app, which is the version too
#   (build-app.sh).
# - sparkle:minimumSystemVersion: 26.0. Sparkle compares it with the macOS version.
# - the release notes of semantic-release as Markdown in the description, so the update window of
#   Sparkle shows what changed. The notes are in a CDATA section. Each "]]>" of the notes is
#   split over two CDATA sections, so the notes cannot end the section.
# - the enclosure: the address and the length of the update ZIP, and its EdDSA signature
#   (sparkle-sign.sh).
# The date is in the RFC 822 form. It is the time now when the argument is not there.
#
# Exit 0: the script prints the feed. Exit 1: the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"

if [ $# -ne 5 ] && [ $# -ne 6 ]; then
    fail "usage: scripts/release/appcast.sh <version> <zip address> <length> <signature>" \
        "<notes file> [<date>]"
fi
version=$1
url=$2
length=$3
signature=$4
notes=$5
date=${6:-$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')}

is_version "$version" || fail "\"$version\" is not a version of the form 1.2.3."
printf '%s\n' "$url" | grep -E -q -x 'https://[A-Za-z0-9._/-]+\.zip' ||
    fail "The ZIP address must be an https address of a .zip file with no special characters."
printf '%s\n' "$length" | grep -E -q -x '[1-9][0-9]*' || fail "The length must be a number."
printf '%s\n' "$signature" | grep -E -q -x '[A-Za-z0-9+/]{86}==' ||
    fail "The signature must be the base64 text of a 64-byte EdDSA signature."
[ -f "$notes" ] || fail "There is no notes file at $notes."
rfc822='[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} \+0000'
printf '%s\n' "$date" | grep -E -q -x "$rfc822" ||
    fail "The date must have the RFC 822 form, for example \"Wed, 18 Nov 2026 12:00:00 +0000\"."

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Bifrost</title>
    <item>
      <title>Bifrost $version</title>
      <pubDate>$date</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
XML
printf '%s' '      <description sparkle:format="markdown"><![CDATA['
sed 's/]]>/]]]]><![CDATA[>/g' "$notes" || fail "Cannot read $notes."
cat <<XML
]]></description>
      <enclosure
        url="$url"
        length="$length"
        type="application/octet-stream"
        sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
XML
