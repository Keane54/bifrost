#!/bin/sh
# Self-test of the rules check (scripts/check_rules.py).
#
# Each case makes a new temp git repo with its own Config/Base.xcconfig. That file sets the
# release bundle ID to com.example.app. The case then writes the fixtures to the temp repo and
# runs the check there. Each bad fixture must fail with its rule. The good fixture must pass.
#
# The fixtures are below scripts/rules-fixtures/Fixtures. The rules check skips the long lines of
# a file below a folder named Fixtures. Thus the bad long-line fixture does not fail the rules
# step of this repo. In the temp repo, the script copies each fixture to a path outside a
# Fixtures folder, so the rule applies there.
set -u
here=$(cd "$(dirname "$0")" && pwd)
fix="$here/rules-fixtures/Fixtures"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: $1"
    exit 1
}

# Makes a new empty git repo at $repo with the xcconfig fixture. Nothing is committed.
new_repo() {
    repo="$tmp/repo"
    rm -rf "$repo"
    mkdir -p "$repo/Config"
    git -c init.defaultBranch=main init -q "$repo" || fail "git init failed"
    cp "$fix/Base.xcconfig" "$repo/Config/Base.xcconfig"
}

# Copies a fixture to a path in the temp repo. Makes the folders of the path.
put() {
    mkdir -p "$(dirname "$repo/$2")"
    cp "$fix/$1" "$repo/$2"
}

# Runs the check on the temp repo. Sets out and code.
check() {
    out=$(python3 -I "$here/check_rules.py" "${1:-$repo}" 2>&1)
    code=$?
}

# The check must pass. The first argument names the case.
expect_pass() {
    check
    [ "$code" -eq 0 ] || fail "$1: expected exit 0, got $code: $out"
}

# The check must fail with a line for the rule at the file and line.
# Arguments: the case, the path in the repo, the line number, the rule.
expect_finding() {
    check
    [ "$code" -eq 1 ] || fail "$1: expected exit 1, got $code: $out"
    printf '%s\n' "$out" | grep -q -F "$2:$3: $4: " || fail "$1: no line for $2:$3 $4: $out"
}

# A repo with only the xcconfig passes. The xcconfig can hold the release bundle ID.
new_repo
expect_pass "only the xcconfig"

# The bad fixture of each rule, once untracked and once tracked.
new_repo
put bad/long-line.txt notes.txt
expect_finding "long-line, untracked" notes.txt 2 long-line
git -C "$repo" add notes.txt
expect_finding "long-line, tracked" notes.txt 2 long-line

new_repo
put bad/release-id.txt src/notes.txt
expect_finding "release-id, untracked" src/notes.txt 2 release-id
git -C "$repo" add src/notes.txt
expect_finding "release-id, tracked" src/notes.txt 2 release-id

# The release-id rule also applies to the files that the long-line rule skips.
new_repo
put bad/release-id.txt docs/archive/phase-records/notes.md
expect_finding "release-id in the phase records" docs/archive/phase-records/notes.md 2 release-id
new_repo
put bad/release-id.txt Tests/Fixtures/notes.json
expect_finding "release-id in Fixtures" Tests/Fixtures/notes.json 2 release-id

# The cutover condition in a build configuration or in the project file. The same text in a
# Swift file, in another folder or in a doc is allowed.
new_repo
put bad/cutover.xcconfig Config/Release.xcconfig
expect_finding "cutover in an xcconfig" Config/Release.xcconfig 2 cutover-condition
new_repo
put bad/cutover.xcconfig App.xcodeproj/project.pbxproj
git -C "$repo" add App.xcodeproj
expect_finding "cutover in the project file" App.xcodeproj/project.pbxproj 2 cutover-condition
new_repo
put bad/cutover.xcconfig App/Start.swift
put bad/cutover.xcconfig Config/Old/Release.xcconfig
put bad/cutover.xcconfig docs/cutover.md
expect_pass "cutover outside the build configurations"

# The good fixture: a Markdown table row, a Markdown link definition, a pbxproj line and a line
# of exactly 100 characters, some of them with two bytes in UTF-8.
new_repo
put good/table.md docs/table.md
put good/project.pbxproj App.xcodeproj/project.pbxproj
put good/edge.txt docs/edge.txt
git -C "$repo" add docs
expect_pass "good"

# Only a Markdown file has table rows. The same line in another file is a long line.
new_repo
put good/table.md docs/table.txt
expect_finding "table row in a text file" docs/table.txt 5 long-line

# Only a link definition with no space in its address is skipped. A long prose line in the same
# Markdown file is a long line.
new_repo
put good/table.md docs/links.md
not_a_link="[a link]: https://example.com/an address with spaces"
not_a_link="$not_a_link that is not a link definition at all, so it fails"
printf '%s\n' "$not_a_link" >> "$repo/docs/links.md"
expect_finding "long line that is not a link definition" docs/links.md 8 long-line

# The other files that the long-line rule skips.
new_repo
put bad/long-line.txt docs/archive/phase-records/ledger.md
put bad/long-line.txt docs/archive/gates/pilot/RESULTS.md
put bad/long-line.txt docs/explainers/page.html
put bad/long-line.txt Tests/Fixtures/cases.json
put bad/long-line.txt App.xcodeproj/xcshareddata/xcschemes/App.xcscheme
put bad/long-line.txt Config/Debug.xcconfig
put bad/long-line.txt Package.resolved
put bad/long-line.txt Packages/Kit/Package.resolved
put bad/long-line.txt pnpm-lock.yaml
put bad/long-line.txt .releaserc.json
put bad/long-line.txt package.json
put bad/long-line.txt Packages/Kit/Sources/Kit/Resources/Fonts/LICENSE
put bad/long-line.txt Packages/Kit/Sources/Kit/Resources/Icons/icon.svg
put bad/long-line.txt App/Bifrost/Resources/live-mod/.claude-plugin/plugin.json
put bad/long-line.txt App/Bifrost/Resources/bifrost-skills/skills/bifrost-x/SKILL.md
expect_pass "the skipped files"

# Another file next to the skipped release files keeps the long-line rule.
new_repo
put bad/long-line.txt releaserc.json
expect_finding "another JSON file" releaserc.json 2 long-line

# Only the package.json at the root skips the long-line rule.
new_repo
put bad/long-line.txt tools/package.json
expect_finding "a package.json in a folder" tools/package.json 2 long-line

# Only a setting line of an xcconfig file skips the long-line rule. A comment line keeps it.
new_repo
put bad/long-line.txt Config/Debug.xcconfig
printf '// %0100d\n' 0 >>"$repo/Config/Debug.xcconfig"
expect_finding "a long comment line in an xcconfig" Config/Debug.xcconfig 4 long-line

# A file named LICENSE or an SVG file outside a Resources folder, and another file in a Resources
# folder, keep the long-line rule.
new_repo
put bad/long-line.txt LICENSE
expect_finding "a LICENSE outside Resources" LICENSE 2 long-line
new_repo
put bad/long-line.txt docs/diagram.svg
expect_finding "an SVG file outside Resources" docs/diagram.svg 2 long-line
new_repo
put bad/long-line.txt Packages/Kit/Sources/Kit/Resources/Fonts/NOTICE
expect_finding "another file in Resources" Packages/Kit/Sources/Kit/Resources/Fonts/NOTICE 2 \
    long-line
new_repo
put bad/long-line.txt App/Bifrost/Resources/other/notes.md
expect_finding "another folder of the app resources" App/Bifrost/Resources/other/notes.md 2 \
    long-line

# The check does not read an ignored file, a file with a NUL byte or a file that is not UTF-8.
new_repo
printf 'ignored/\n' >"$repo/.gitignore"
put bad/long-line.txt ignored/notes.txt
put bad/release-id.txt ignored/id.txt
printf 'com.example.app\000\n' >"$repo/binary.dat"
printf 'com.example.app \377\n' >"$repo/latin.txt"
expect_pass "ignored and binary files"

# A tracked file that is deleted in the work tree is not an error.
new_repo
put bad/release-id.txt gone.txt
git -C "$repo" add gone.txt
rm "$repo/gone.txt"
expect_pass "a deleted tracked file"

# Without the release bundle ID in the xcconfig, the check cannot run.
new_repo
printf '// No ID.\n' >"$repo/Config/Base.xcconfig"
check
[ "$code" -eq 2 ] || fail "no release ID: expected exit 2, got $code: $out"
new_repo
rm "$repo/Config/Base.xcconfig"
check
[ "$code" -eq 2 ] || fail "no xcconfig: expected exit 2, got $code: $out"

# A folder that is not a git repo.
mkdir -p "$tmp/plain/Config"
cp "$fix/Base.xcconfig" "$tmp/plain/Config/Base.xcconfig"
check "$tmp/plain"
[ "$code" -eq 2 ] || fail "not a repo: expected exit 2, got $code: $out"
check "$tmp/nonexistent"
[ "$code" -eq 2 ] || fail "missing root: expected exit 2, got $code: $out"

echo PASS
