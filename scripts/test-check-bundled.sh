#!/bin/sh
# Self-test of the check of the bundled files (scripts/check-bundled.sh).
#
# Usage: scripts/test-check-bundled.sh <app>
#
# The app is the built Debug app. The real repo and the app must pass. Each other case copies
# the bundled folders of the app (Contents/Resources/live-mod and bifrost-skills) to a temp app,
# or the two folders of the repo to a temp repo, makes one change, and expects exit 1 with the
# line of that fault. The script changes no file of the repo or of the app.
set -u

if [ "$#" -ne 1 ]; then
    echo "usage: scripts/test-check-bundled.sh <app>" >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd) || exit 1
root=$(dirname "$here")
app=$1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: $1"
    exit 1
}

# Runs the check. Sets out and code.
check() {
    out=$("$here/check-bundled.sh" "$@" 2>&1)
    code=$?
}

# Makes a new temp app with a copy of the bundled folders of the app. Sets copy.
new_app() {
    copy="$tmp/Copy.app"
    rm -rf "$copy"
    mkdir -p "$copy/Contents/Resources" || fail "mkdir failed"
    cp -R "$app/Contents/Resources/live-mod" "$app/Contents/Resources/bifrost-skills" \
        "$copy/Contents/Resources/" || fail "the app has no bundled folders: $app"
}

# Makes a new temp repo with a copy of the two folders of the repo. Sets repo.
new_repo() {
    repo="$tmp/repo"
    rm -rf "$repo"
    mkdir -p "$repo/App/Bifrost/Resources" || fail "mkdir failed"
    cp -R "$root/App/Bifrost/Resources/live-mod" "$root/App/Bifrost/Resources/bifrost-skills" \
        "$repo/App/Bifrost/Resources/" || fail "cp failed"
}

# Changes the first byte of a file to another byte.
change_byte() {
    if [ "$(head -c 1 "$1")" = "#" ]; then new="%"; else new="#"; fi
    printf '%s' "$new" | dd of="$1" bs=1 count=1 conv=notrunc 2>/dev/null || fail "dd failed"
}

# The check must fail with a line of the fault. The first argument names the case, the second
# is the line, the others are the arguments of the check.
expect_fault() {
    name=$1
    line=$2
    shift 2
    check "$@"
    [ "$code" -eq 1 ] || fail "$name: expected exit 1, got $code: $out"
    printf '%s\n' "$out" | grep -q -x -F "$line" || fail "$name: no line '$line': $out"
}

# The real repo and the built app pass.
check "$app"
[ "$code" -eq 0 ] || fail "the real copies: expected exit 0, got $code: $out"
[ "$out" = "bundled files ok" ] || fail "the real copies: unexpected output: $out"

# A copy of the app passes too.
new_app
check "$copy" "$root"
[ "$code" -eq 0 ] || fail "a copy of the app: expected exit 0, got $code: $out"

# One changed byte in a mod file and in a skills file.
new_app
change_byte "$copy/Contents/Resources/live-mod/hooks/register.ts"
expect_fault "a changed mod file" "the app has other bytes for the mod file hooks/register.ts" \
    "$copy" "$root"
new_app
change_byte "$copy/Contents/Resources/bifrost-skills/skills/bifrost-grill/SKILL.md"
expect_fault "a changed skills file" \
    "the app has other bytes for the skills file skills/bifrost-grill/SKILL.md" "$copy" "$root"

# A missing mod file, a missing file of a dot folder, and a missing skills file.
new_app
rm "$copy/Contents/Resources/live-mod/hooks/hooks.json"
expect_fault "a missing mod file" "the app has no mod file hooks/hooks.json" "$copy" "$root"
new_app
rm "$copy/Contents/Resources/bifrost-skills/.claude-plugin/plugin.json"
expect_fault "a missing file of a dot folder" \
    "the app has no skills file .claude-plugin/plugin.json" "$copy" "$root"
new_app
rm "$copy/Contents/Resources/bifrost-skills/skills/bifrost-humanise/rules.md"
expect_fault "a missing skills file" "the app has no skills file skills/bifrost-humanise/rules.md" \
    "$copy" "$root"

# A missing skills folder of the app.
new_app
rm -rf "$copy/Contents/Resources/bifrost-skills"
expect_fault "no skills folder in the app" "the app has no skills folder" "$copy" "$root"

# An extra file in the skills folder of the app.
new_app
printf 'x\n' >"$copy/Contents/Resources/bifrost-skills/skills/extra.md"
expect_fault "an extra skills file" "the app has an extra skills file skills/extra.md" \
    "$copy" "$root"

# A link in place of a file is not a file, also with the same bytes.
new_app
file="$copy/Contents/Resources/bifrost-skills/skills/bifrost-review/reference.md"
mv "$file" "$tmp/reference.md"
ln -s "$tmp/reference.md" "$file"
expect_fault "a link to a skills file" \
    "the app has no skills file skills/bifrost-review/reference.md" "$copy" "$root"
new_app
file="$copy/Contents/Resources/live-mod/hooks/register.ts"
mv "$file" "$tmp/register.ts"
ln -s "$tmp/register.ts" "$file"
expect_fault "a link to a mod file" "the app has no mod file hooks/register.ts" "$copy" "$root"

# An extra link in the skills folder of the app, which find -type f does not list, and a link in
# the repo copy.
new_app
ln -s "$tmp" "$copy/Contents/Resources/bifrost-skills/skills/extra-link"
expect_fault "an extra link in the app" \
    "the skills folder of the app has a link skills/extra-link" "$copy" "$root"
new_app
new_repo
ln -s "$tmp" "$repo/App/Bifrost/Resources/live-mod/hooks/extra-link"
expect_fault "a link in the repo copy" "the mod folder of the repo has a link hooks/extra-link" \
    "$copy" "$repo"

# The repo copy lacks a mod file, and the skills folder of the repo has no files.
new_app
new_repo
rm "$repo/App/Bifrost/Resources/live-mod/.claude-plugin/marketplace.json"
expect_fault "a missing mod file in the repo" \
    "the repo copy has no mod file .claude-plugin/marketplace.json" "$copy" "$repo"
new_repo
rm -rf "$repo/App/Bifrost/Resources/bifrost-skills"
mkdir "$repo/App/Bifrost/Resources/bifrost-skills"
expect_fault "an empty skills folder in the repo" "the skills folder of the repo has no files" \
    "$copy" "$repo"
new_repo
rm -rf "$repo/App/Bifrost/Resources/bifrost-skills"
expect_fault "no skills folder in the repo" "the repo has no skills folder" "$copy" "$repo"

# A bad argument.
check
[ "$code" -eq 2 ] || fail "no argument: expected exit 2, got $code: $out"
check "$tmp/none.app"
[ "$code" -eq 2 ] || fail "no app: expected exit 2, got $code: $out"

echo PASS
