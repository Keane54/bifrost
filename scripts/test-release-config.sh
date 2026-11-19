#!/bin/sh
# Self-test of the semantic-release config (.releaserc.json, docs/release.md).
#
# Usage: scripts/test-release-config.sh
#
# The test needs the release tooling: run "pnpm install --frozen-lockfile" first. Each case makes
# a temp git repo with a bare remote on the disk, and runs semantic-release in it with a copy of
# the real config. The copy has no github plugin, because that plugin needs a token and the
# network. The temp repo has the real summary.sh, save-notes.sh, check-dist.sh and lib.sh, and
# stand-in release files in dist/. So the cases test the real release rules, the real notes steps
# and the real prepareCmd of the exec plugin, and nothing builds or signs an app.
# The cases: the cutover commit ("feat!:" with a BREAKING CHANGE footer) after v0.9.0 gives 1.0.0;
# after that, fix gives a patch, feat a minor, a breaking change a major, and chore a patch; a
# commit of another type gives no release; an empty summary stops the release; a dry run saves
# the full notes (the summary, then the notes of the commits) to .release-notes.md; a full run
# with the files of the version in dist/ pushes the tag; and a full run with the files of another
# version stops before the tag.
# semantic-release runs with a clean environment, so the CI variables of GitHub Actions and the
# git settings of the user do not change the result.
#
# Exit 0: all cases passed, and the script prints PASS. Exit 1: the script prints the failed case.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
root=$(dirname "$here")
semantic="$root/node_modules/.bin/semantic-release"
[ -x "$semantic" ] || {
    echo "FAIL: no semantic-release in node_modules. Run \"pnpm install --frozen-lockfile\"."
    exit 1
}
mkdir -p "$root/.build" || exit 1
tmp=$(mktemp -d "$root/.build/release-config-test.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" || exit 1

fail() {
    echo "FAIL: $1"
    exit 1
}

# The github plugin of the config must publish the four files that prepare.sh makes.
python3 -I - "$root/.releaserc.json" <<'EOF' || fail "the assets of the github plugin"
import json, sys
config = json.load(open(sys.argv[1]))
name = "@semantic-release/github"
github = [p for p in config["plugins"] if isinstance(p, list) and p[0] == name]
assert len(github) == 1, "one github plugin"
paths = [asset["path"] for asset in github[0][1]["assets"]]
expected = ["dist/Bifrost-arm64.dmg", "dist/Bifrost-*-arm64-mac.zip", "dist/latest-mac.yml",
            "dist/appcast.xml"]
assert paths == expected, paths
EOF

# Runs git in the temp repo with no settings of the user.
g() {
    HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1 git -C "$repo" "$@"
}

# Makes a new temp repo with one commit and the tag v0.9.0 (the last Electron release) on its
# remote.
new_repo() {
    repo="$tmp/repo"
    remote="$tmp/remote.git"
    rm -rf "$repo" "$remote"
    HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1 git init -q --bare -b main "$remote" ||
        fail "git init of the remote failed"
    HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1 git init -q -b main "$repo" || fail "git init failed"
    g config user.name "Release Test"
    g config user.email release-test@example.invalid
    g remote add origin "$remote"
    mkdir -p "$repo/scripts/release" || fail "cannot make the scripts folder"
    for script in summary.sh save-notes.sh check-dist.sh lib.sh; do
        cp "$here/release/$script" "$repo/scripts/release/" || fail "cannot copy $script"
    done
    python3 -I - "$root/.releaserc.json" "file://$remote" >"$repo/.releaserc.json" <<'EOF' ||
import json, sys
config = json.load(open(sys.argv[1]))
config["repositoryUrl"] = sys.argv[2]
config["plugins"] = [p for p in config["plugins"]
                     if (p[0] if isinstance(p, list) else p) != "@semantic-release/github"]
json.dump(config, sys.stdout, indent=2)
EOF
        fail "cannot write the config"
    ln -s "$root/node_modules" "$repo/node_modules" || fail "cannot link node_modules"
    printf 'node_modules\n.release-version\n.release-notes.md\ndist/\n' >"$repo/.gitignore"
    g add -A
    g commit -q -m "chore: the Electron app" || fail "the first commit failed"
    g tag v0.9.0
    g push -q origin main --tags || fail "the first push failed"
}

# Makes an empty commit with the message $1 and pushes it.
commit() {
    g commit -q --allow-empty -m "$1" || fail "the commit \"$1\" failed"
    g push -q origin main || fail "the push of \"$1\" failed"
}

# Runs semantic-release in the temp repo. Sets out and code. The other arguments go to
# semantic-release.
release() {
    rm -f "$repo/.release-version" "$repo/.release-notes.md"
    out=$(cd "$repo" && env -i PATH="$PATH" HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1 \
        RELEASE_SUMMARY="${summary-A summary.}" "$semantic" --no-ci "$@" 2>&1)
    code=$?
}

# A dry run must give the version $2. The first argument names the case. An empty version means
# no release.
expect_version() {
    release --dry-run
    [ "$code" -eq 0 ] || fail "$1: semantic-release failed with $code: $out"
    found=$(cat "$repo/.release-version" 2>/dev/null)
    [ "$found" = "$2" ] || fail "$1: expected version \"$2\", got \"$found\": $out"
}

# Writes stand-in release files of the version $1 to dist/ of the temp repo. They have the names
# and the lines that check-dist.sh reads, as prepare.sh writes them.
fake_dist() {
    dist="$repo/dist"
    zip_name="Bifrost-$1-arm64-mac.zip"
    rm -rf "$dist"
    mkdir -p "$dist" || fail "cannot make $dist"
    printf 'dmg\n' >"$dist/Bifrost-arm64.dmg"
    printf 'zip\n' >"$dist/$zip_name"
    printf 'version: %s\nfiles:\n  - url: %s\npath: %s\n' "$1" "$zip_name" "$zip_name" \
        >"$dist/latest-mac.yml"
    printf '<sparkle:version>%s</sparkle:version>\nurl="%s"\n' "$1" \
        "https://github.com/example/bifrost/releases/download/v$1/$zip_name" >"$dist/appcast.xml"
}

# Tags the commit at the top with v$1, as a release does.
tag() {
    g tag "v$1"
    g push -q origin "v$1" || fail "the push of the tag v$1 failed"
}

new_repo
commit "feat!: replace the Electron app with the native app

BREAKING CHANGE: Bifrost is a native macOS app now."
expect_version "the cutover commit" 1.0.0
tag 1.0.0
commit "fix(updates): keep the last check"
expect_version "fix after 1.0.0" 1.0.1
commit "feat(chat): add a thing"
expect_version "feat and fix" 1.1.0
commit "refactor(sessions)!: change the store"
expect_version "a breaking change with !" 2.0.0

new_repo
commit "feat: a thing

BREAKING CHANGE: only the footer says it."
expect_version "a breaking change in the footer only" 1.0.0

new_repo
commit "chore: tidy the scripts"
expect_version "chore" 0.9.1
commit "feat(updates): a feature"
expect_version "chore and feat" 0.10.0

new_repo
commit "wip: not a release type"
expect_version "a type with no release" ""
commit "Merge branch 'main' into work"
expect_version "a merge message" ""

new_repo
commit "fix: a fix"
summary=' '
release --dry-run
[ "$code" -ne 0 ] || fail "an empty summary: semantic-release did not stop: $out"
printf '%s\n' "$out" | grep -q -F "The release summary is empty" ||
    fail "an empty summary: no reason in the output: $out"
unset summary

# The notes in .release-notes.md must start with the summary and hold the notes of the commits
# once. The first argument names the case.
expect_notes() {
    notes="$repo/.release-notes.md"
    [ -f "$notes" ] || fail "$1: no .release-notes.md: $out"
    [ "$(sed -n 1,2p "$notes")" = "$summary" ] ||
        fail "$1: the notes start with: $(sed -n 1,3p "$notes")"
    for text in '## [1.0.0]' '### ⚠ BREAKING CHANGES' '### Features' '### Bug Fixes' \
        '* **updates:** a fix with "quotes", $(no command) and a `tick`'; do
        grep -q -F -- "$text" "$notes" || fail "$1: no \"$text\" in the notes: $(cat "$notes")"
    done
    for text in 'The native app is here.' '## [1.0.0]'; do
        count=$(grep -c -F -- "$text" "$notes")
        [ "$count" -eq 1 ] || fail "$1: \"$text\" is $count times in the notes: $(cat "$notes")"
    done
}

# Returns 0 when the remote has the tag $1.
has_tag() {
    HOME="$tmp/home" git -C "$remote" rev-parse -q --verify "refs/tags/$1" >/dev/null
}

new_repo
commit "feat!: replace the Electron app with the native app

BREAKING CHANGE: Bifrost is a native macOS app now."
commit "fix(updates): a fix with \"quotes\", \$(no command) and a \`tick\`"
summary='The native app is here.
It keeps your data.'

# The dry run of the check job saves the full notes and makes no tag.
expect_version "the notes of a dry run" 1.0.0
expect_notes "the notes of a dry run"
! has_tag v1.0.0 || fail "the notes of a dry run: the dry run made the tag v1.0.0"

# The files in dist/ have another version, for example after a new commit: the prepareCmd stops
# the release before the tag.
fake_dist 0.9.1
release
[ "$code" -ne 0 ] || fail "files of another version: semantic-release did not stop: $out"
printf '%s\n' "$out" | grep -q -F "exactly one update ZIP, Bifrost-1.0.0-arm64-mac.zip" ||
    fail "files of another version: no reason in the output: $out"
! has_tag v1.0.0 || fail "files of another version: the run made the tag v1.0.0"

# A full run with the files of the version: the prepareCmd passes, and the tag goes to the remote.
fake_dist 1.0.0
release
[ "$code" -eq 0 ] || fail "a full run: semantic-release failed with $code: $out"
expect_notes "a full run"
has_tag v1.0.0 || fail "a full run: no tag v1.0.0 on the remote"

echo PASS
