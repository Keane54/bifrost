#!/bin/sh
# Finds the signing identity in the keychain of the Release workflow.
#
# Usage: security find-identity -v -p codesigning <keychain> | scripts/release/signing-identity.sh
#
# The script reads the output of "security find-identity" on stdin. It must find exactly one
# "Developer ID Application: <name> (<team ID>)" identity. It ignores the other identities. It
# prints two lines for the file in GITHUB_ENV:
#   SIGNING_IDENTITY=<the SHA-1 hash of the certificate>
#   TEAM_ID=<the team ID>
# Both values are public, because each released app shows them in its code signature. So the repo
# and the secrets hold no signing name (user decision, 2026-11-13). The hash names the
# certificate with no doubt, also when another certificate has the same name.
#
# Exit 0: the script prints the two lines. Exit 1: the script prints the reason.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$here/lib.sh"

# A line of the output: the number, the 40 hex characters of the hash, and the quoted name.
sp='[[:space:]]'
hash_pattern='[0-9A-Fa-f]\{40\}'
name_pattern='"Developer ID Application: \(.*\)"'
line="s/^$sp*[0-9][0-9]*)$sp$sp*\($hash_pattern\)$sp$sp*$name_pattern$sp*\$/\1 \2/p"
found=$(sed -n "$line" | sort -u)
count=$(printf '%s' "$found" | grep -c '^')
if [ "$count" -eq 0 ]; then
    fail "No Developer ID Application identity is in the keychain. Check that the CSC_LINK" \
        "secret holds a Developer ID Application certificate with its private key" \
        "(docs/release.md)."
fi
if [ "$count" -gt 1 ]; then
    fail "The keychain holds $count Developer ID Application identities. The CSC_LINK" \
        "secret must hold exactly one."
fi
hash=${found%% *}
name=${found#* }
team=$(printf '%s\n' "$name" | sed -n 's/^.* (\([A-Z0-9]\{10\}\))$/\1/p')
if [ -z "$team" ]; then
    fail "The name of the Developer ID Application identity must end with the team ID in" \
        "brackets. The team ID is 10 upper-case letters and digits."
fi
echo "The signing identity is Developer ID Application: $name" >&2
printf 'SIGNING_IDENTITY=%s\nTEAM_ID=%s\n' "$hash" "$team"
