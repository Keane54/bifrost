#!/bin/sh
# Self-test of the forbidden-construct check.
# Each bad fixture must fail with its rule. The good fixture must pass.
# The script copies each bad fixture to a file with a neutral name, so that only its text counts.
# The fixtures in bad-names and good-names test the rule for file names. Only their names count.
# The home-lookup rule applies only below a root whose last component is Packages, and it is the
# only rule for the test folders there, with the ui-import rule. Thus the script tests that
# fixture in a folder named Packages, in a test folder below it, and in a folder with another
# name.
# The layer rules apply to the module folders of a package: <package>/Sources/<module>/<layer>/
# and <package>/Tests/<module>Tests/<layer>/. The ui-import rule applies to the layers Model and
# Services, also in a test folder. The model-io rule applies to the layer Model of the sources.
# The layer-folder rule refuses a Swift file of a module in no layer folder.
# The private-api rule applies to each file except Packages/Bifrost/Sources/BifrostLook/UI/
# PrivateBackdrop.swift. The shared-state rule applies to each file that is not a test, except the
# start files of Packages/Bifrost/Sources/BifrostApp/Services. The test-temp-folder rule applies
# only to the test folders of a package: the test support module and the sources can use the temp
# folder. The pty-spawn rule applies to each file that is not a test. A call of spawn(program:) is
# allowed only in Packages/Bifrost/Sources/BifrostSessions/Services/PTYManager.swift, an init of
# PTYProcess only in PTYProcess.swift of the same folder, and both in the test support module.
# The keychain rule applies to each file, also a test folder of a package. The rules of Reviews
# apply to the sources of Packages/Bifrost: github-write, github-never and git-push read the text
# of the string literals, each with its own folders and files, and user-click and reviews-process
# read the code, as trust-run does (a check of a trust run outside the Reviews module and the
# tests). The script tests these fixtures at the paths of these rules.
set -u
here=$(cd "$(dirname "$0")" && pwd)
fix="$here/forbidden-fixtures"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: $1"
    exit 1
}

# Runs the check on one folder. Sets out and code.
check() {
    out=$(python3 -I "$here/check_forbidden.py" "$1" 2>&1)
    code=$?
}

for file in "$fix"/bad/*.swift; do
    name=$(basename "$file" .swift)
    case "$name" in
        home-lookup | ui-import* | model-io* | test-temp-folder) continue ;;
        github-* | git-push* | user-click* | reviews-process | trust-run) continue ;;
        private-api*) rule=private-api ;;
        shared-state*) rule=shared-state ;;
        pty-spawn*) rule=pty-spawn ;;
        keychain*) rule=keychain ;;
        force-cast | iuo | interpolation | force-unwrap-*) rule=force-unwrap ;;
        js-enum | js-type-*) rule=js-mechanics ;;
        *) rule=$name ;;
    esac
    rm -rf "$tmp/case"
    mkdir "$tmp/case"
    cp "$file" "$tmp/case/fixture.swift"
    check "$tmp/case"
    [ "$code" -eq 1 ] || fail "$name: expected exit 1, got $code"
    echo "$out" | grep -q ": $rule: " || fail "$name: no line for rule $rule"
done

for file in "$fix"/bad-names/*.swift; do
    name=$(basename "$file")
    rm -rf "$tmp/case"
    mkdir "$tmp/case"
    cp "$file" "$tmp/case/"
    check "$tmp/case"
    [ "$code" -eq 1 ] || fail "file name $name: expected exit 1, got $code"
    echo "$out" | grep -q ": js-file-name: " || fail "file name $name: no line for js-file-name"
done
check "$fix/good-names"
[ "$code" -eq 0 ] || fail "good-names: expected exit 0, got $code: $out"

mkdir -p "$tmp/Packages/Kit/Tests/KitTests/Model" "$tmp/Other" \
    "$tmp/Tested/Kit/Tests/KitTests/Model"
cp "$fix/bad/home-lookup.swift" "$tmp/Packages/"
cp "$fix/bad/home-lookup.swift" "$tmp/Other/"
check "$tmp/Packages"
[ "$code" -eq 1 ] || fail "home-lookup in Packages: expected exit 1, got $code"
echo "$out" | grep -q ": home-lookup: " || fail "home-lookup in Packages: no line for the rule"
check "$tmp/Other"
[ "$code" -eq 0 ] || fail "home-lookup in Other: expected exit 0, got $code: $out"

# A test folder in Packages: the home-lookup rule applies, and no other rule applies.
rm "$tmp/Packages/home-lookup.swift"
cp "$fix/bad/home-lookup.swift" "$tmp/Packages/Kit/Tests/KitTests/Model/"
check "$tmp/Packages"
[ "$code" -eq 1 ] || fail "home-lookup in a Packages test folder: expected exit 1, got $code"
echo "$out" | grep -q ": home-lookup: " || fail "home-lookup in a Packages test folder: no line"
rm "$tmp/Packages/Kit/Tests/KitTests/Model/home-lookup.swift"
cp "$fix/bad/try-bang.swift" "$tmp/Packages/Kit/Tests/KitTests/Model/"
check "$tmp/Packages"
[ "$code" -eq 0 ] || fail "try-bang in a Packages test folder: expected exit 0, got $code: $out"
# A test can use assumeIsolated.
cp "$fix/bad/assume-isolated.swift" "$tmp/Packages/Kit/Tests/KitTests/Model/"
check "$tmp/Packages"
[ "$code" -eq 0 ] || fail "assume-isolated in a test folder: expected exit 0, got $code: $out"
# A test folder below a root with another name gets no rule.
cp "$fix/bad/home-lookup.swift" "$tmp/Tested/Kit/Tests/KitTests/Model/"
check "$tmp/Tested"
[ "$code" -eq 0 ] || fail "home-lookup in another test folder: expected exit 0, got $code: $out"

# Each ui-import fixture fails in the layers Model and Services, in a source folder and in a test
# folder. It passes in the layer UI, in a file of a package that is not in a layer, and below a
# root with another name.
pkg="$tmp/ui/Packages/Bifrost"
for file in "$fix"/bad/ui-import*.swift; do
    name=$(basename "$file" .swift)
    for folder in Sources/BifrostSample/Model Sources/BifrostSample/Services \
        Tests/BifrostSampleTests/Model Tests/BifrostSampleTests/Services; do
        rm -rf "$tmp/ui"
        mkdir -p "$pkg/$folder"
        cp "$file" "$pkg/$folder/fixture.swift"
        check "$tmp/ui/Packages"
        [ "$code" -eq 1 ] || fail "$name in $folder: expected exit 1, got $code"
        echo "$out" | grep -q ": ui-import: " || fail "$name in $folder: no line"
    done
    rm -rf "$tmp/ui"
    mkdir -p "$pkg/Sources/BifrostSample/UI" "$pkg/Tests/BifrostSampleTests/UI" \
        "$pkg/Sources/BifrostTestSupport" "$tmp/ui/App"
    for folder in Sources/BifrostSample/UI Tests/BifrostSampleTests/UI \
        Sources/BifrostTestSupport; do
        cp "$file" "$pkg/$folder/fixture.swift"
    done
    cp "$file" "$tmp/ui/App/fixture.swift"
    check "$tmp/ui/Packages"
    [ "$code" -eq 0 ] || fail "$name in the layer UI: expected exit 0, got $code: $out"
    check "$tmp/ui/App"
    [ "$code" -eq 0 ] || fail "$name in App: expected exit 0, got $code: $out"
done

# Each model-io fixture fails in the layer Model of the sources. It passes in the layers Services
# and UI, in the layer Model of a test folder, and below a root with another name.
pkg="$tmp/io/Packages/Bifrost"
for file in "$fix"/bad/model-io*.swift; do
    name=$(basename "$file" .swift)
    rm -rf "$tmp/io"
    mkdir -p "$pkg/Sources/BifrostSample/Model"
    cp "$file" "$pkg/Sources/BifrostSample/Model/fixture.swift"
    check "$tmp/io/Packages"
    [ "$code" -eq 1 ] || fail "$name in the layer Model: expected exit 1, got $code"
    echo "$out" | grep -q ": model-io: " || fail "$name in the layer Model: no line"
    rm -rf "$tmp/io"
    for folder in Sources/BifrostSample/Services Sources/BifrostSample/UI \
        Tests/BifrostSampleTests/Model; do
        mkdir -p "$pkg/$folder"
        cp "$file" "$pkg/$folder/fixture.swift"
    done
    mkdir -p "$tmp/io/App"
    cp "$file" "$tmp/io/App/fixture.swift"
    check "$tmp/io/Packages"
    [ "$code" -eq 0 ] || fail "$name outside the layer Model: expected exit 0, got $code: $out"
    check "$tmp/io/App"
    [ "$code" -eq 0 ] || fail "$name in App: expected exit 0, got $code: $out"
done
# The good fixture passes in the layer Model: a read of bytes from an array is not I/O.
rm -rf "$tmp/io"
mkdir -p "$pkg/Sources/BifrostSample/Model"
cp "$fix/good/allowed.swift" "$pkg/Sources/BifrostSample/Model/allowed.swift"
check "$tmp/io/Packages"
[ "$code" -eq 0 ] || fail "good in the layer Model: expected exit 0, got $code: $out"

# Each Swift file of a module is in a layer folder (Model, Services or UI), also in a subfolder
# of a layer. The test support module has no layers. A file directly below the module folder, or
# in a folder with another name (for example a misspelt layer), fails.
pkg="$tmp/layer/Packages/Bifrost"
for folder in Sources/BifrostSample Sources/BifrostSample/Modle Sources/BifrostSample/Support \
    Tests/BifrostSampleTests Tests/BifrostSampleTests/Helpers; do
    rm -rf "$tmp/layer"
    mkdir -p "$pkg/$folder"
    cp "$fix/layer/Loose.swift" "$pkg/$folder/"
    check "$tmp/layer/Packages"
    [ "$code" -eq 1 ] || fail "a file in $folder: expected exit 1, got $code"
    echo "$out" | grep -q "/$folder/Loose.swift: layer-folder: " ||
        fail "a file in $folder: no line"
done
rm -rf "$tmp/layer"
for folder in Sources/BifrostSample/Model Sources/BifrostSample/Services/Sub \
    Sources/BifrostSample/UI Sources/BifrostTestSupport Tests/BifrostSampleTests/UI/Support; do
    mkdir -p "$pkg/$folder"
    cp "$fix/layer/Loose.swift" "$pkg/$folder/"
done
check "$tmp/layer/Packages"
[ "$code" -eq 0 ] || fail "files in the layer folders: expected exit 0, got $code: $out"
# A root with another name has no modules.
mkdir -p "$tmp/layer/Other/Bifrost/Sources/BifrostSample"
cp "$fix/layer/Loose.swift" "$tmp/layer/Other/Bifrost/Sources/BifrostSample/"
check "$tmp/layer/Other"
[ "$code" -eq 0 ] || fail "a file below a root with another name: expected exit 0: $out"

# The private API is allowed only in the one file of the blur.
look="$tmp/private/Packages/Bifrost/Sources/BifrostLook/UI"
other="$tmp/private/Packages/Other/Sources/BifrostLook/UI"
mkdir -p "$look" "$other"
cat "$fix"/bad/private-api*.swift >"$look/PrivateBackdrop.swift"
check "$tmp/private/Packages"
[ "$code" -eq 0 ] || fail "private-api in PrivateBackdrop.swift: expected exit 0, got $code: $out"
mv "$look/PrivateBackdrop.swift" "$look/FrameBlur.swift"
check "$tmp/private/Packages"
[ "$code" -eq 1 ] || fail "private-api in FrameBlur.swift: expected exit 1, got $code"
echo "$out" | grep -q ": private-api: " || fail "private-api in FrameBlur.swift: no line"
mv "$look/FrameBlur.swift" "$other/PrivateBackdrop.swift"
check "$tmp/private/Packages"
[ "$code" -eq 1 ] || fail "private-api in another package: expected exit 1, got $code"
echo "$out" | grep -q ": private-api: " || fail "private-api in another package: no line"

# Only the start files of the app module make the shared paths of a home. A test folder can make
# them. BifrostTestSupport is not a test folder, so it cannot. Another file of the same folder
# (also the file of the type, which is in BifrostFoundation now), the same file name in another
# module or package, and a file of the app cannot either.
shared="$tmp/shared/Packages"
start="$shared/Bifrost/Sources/BifrostApp/Services"
mkdir -p "$start" "$shared/Bifrost/Tests/BifrostAppTests/Services" "$tmp/shared/App"
for name in AppServices StartPlan SystemPathCheck; do
    cat "$fix"/bad/shared-state*.swift >"$start/$name.swift"
done
cat "$fix"/bad/shared-state*.swift >"$shared/Bifrost/Tests/BifrostAppTests/Services/T.swift"
check "$shared"
[ "$code" -eq 0 ] || fail "shared-state in a start file or a test: expected exit 0: $out"
for file in Bifrost/Sources/BifrostApp/Services/TestPortServer.swift \
    Bifrost/Sources/BifrostApp/Services/SharedClaudeState.swift \
    Bifrost/Sources/BifrostFoundation/Model/SharedClaudeState.swift \
    Bifrost/Sources/BifrostTestSupport/Fixture.swift \
    Bifrost/Sources/BifrostSessions/Services/StartPlan.swift \
    Other/Sources/BifrostApp/Services/StartPlan.swift; do
    mkdir -p "$shared/$(dirname "$file")"
    cp "$fix/bad/shared-state.swift" "$shared/$file"
    check "$shared"
    [ "$code" -eq 1 ] || fail "shared-state in $file: expected exit 1, got $code"
    echo "$out" | grep -q "/$file:.*: shared-state: " || fail "shared-state in $file: no line"
    rm "$shared/$file"
done
cp "$fix/bad/shared-state.swift" "$tmp/shared/App/Fixture.swift"
check "$tmp/shared/App"
[ "$code" -eq 1 ] || fail "shared-state in App: expected exit 1, got $code"
echo "$out" | grep -q ": shared-state: " || fail "shared-state in App: no line"

# A test of a package makes its temp folders only through the test support module. Each line of
# the fixture fails in a test folder. The fixture passes in the test support module, in the
# sources, and in a test folder below a root with another name.
temp="$tmp/temp/Packages/Bifrost"
mkdir -p "$temp/Tests/BifrostSampleTests/Services" "$temp/Sources/BifrostTestSupport" \
    "$temp/Sources/BifrostSample/Services" "$tmp/temp/Other/Kit/Tests/KitTests/Services"
cp "$fix/bad/test-temp-folder.swift" "$temp/Tests/BifrostSampleTests/Services/fixture.swift"
check "$tmp/temp/Packages"
[ "$code" -eq 1 ] || fail "test-temp-folder in a test folder: expected exit 1, got $code"
[ "$(echo "$out" | grep -c ": test-temp-folder: ")" -eq 3 ] ||
    fail "test-temp-folder in a test folder: not one line for each use: $out"
rm "$temp/Tests/BifrostSampleTests/Services/fixture.swift"
cp "$fix/bad/test-temp-folder.swift" "$temp/Sources/BifrostTestSupport/fixture.swift"
cp "$fix/bad/test-temp-folder.swift" "$temp/Sources/BifrostSample/Services/fixture.swift"
cp "$fix/bad/test-temp-folder.swift" "$tmp/temp/Other/Kit/Tests/KitTests/Services/fixture.swift"
check "$tmp/temp/Packages"
[ "$code" -eq 0 ] || fail "test-temp-folder outside a test folder: expected exit 0: $out"
check "$tmp/temp/Other"
[ "$code" -eq 0 ] || fail "test-temp-folder below a root with another name: expected exit 0: $out"

# Only the PTY manager calls spawn(program:), and only the system spawner (PTYProcess.swift)
# makes a PTYProcess. The test support module and a test folder can do both. Another file of the
# same module (also the file of the other form), another module, the same file name in another
# package, and a file of the app cannot. Each use in a fixture gives one line, also a use over
# two lines.
spawn="$tmp/spawn/Packages"
sessions=Bifrost/Sources/BifrostSessions/Services
for form in pty-spawn:PTYManager:PTYProcess pty-spawn-process:PTYProcess:PTYManager; do
    fixture=${form%%:*}
    owner=${form#*:}
    other=${owner#*:}
    owner=${owner%%:*}
    rm -rf "$tmp/spawn"
    mkdir -p "$spawn/$sessions" "$spawn/Bifrost/Sources/BifrostTestSupport/Sub" \
        "$spawn/Bifrost/Tests/BifrostSessionsTests/Services" "$tmp/spawn/App"
    for file in "$sessions/$owner.swift" Bifrost/Sources/BifrostTestSupport/Sub/Fake.swift \
        Bifrost/Tests/BifrostSessionsTests/Services/T.swift; do
        cp "$fix/bad/$fixture.swift" "$spawn/$file"
    done
    check "$spawn"
    [ "$code" -eq 0 ] || fail "$fixture in an allowed file: expected exit 0, got $code: $out"
    for file in "$sessions/$other.swift" Bifrost/Sources/BifrostChat/UI/ChatTerminal.swift \
        "Other/Sources/BifrostSessions/Services/$owner.swift"; do
        mkdir -p "$spawn/$(dirname "$file")"
        cp "$fix/bad/$fixture.swift" "$spawn/$file"
        check "$spawn"
        [ "$code" -eq 1 ] || fail "$fixture in $file: expected exit 1, got $code"
        [ "$(echo "$out" | grep -c "/$file:.*: pty-spawn: ")" -eq 3 ] ||
            fail "$fixture in $file: not one line for each use: $out"
        rm "$spawn/$file"
    done
    cp "$fix/bad/$fixture.swift" "$tmp/spawn/App/Fixture.swift"
    check "$tmp/spawn/App"
    [ "$code" -eq 1 ] || fail "$fixture in App: expected exit 1, got $code"
    echo "$out" | grep -q "Fixture.swift:5: pty-spawn: " ||
        fail "$fixture in App: no line for the use over two lines"
done

# The keychain rule applies also in a test folder of a package, in the test support module and in
# App.
keychain="$tmp/keychain/Packages/Bifrost"
for file in "$fix"/bad/keychain*.swift; do
    name=$(basename "$file" .swift)
    for folder in Tests/BifrostSampleTests/Services Sources/BifrostTestSupport; do
        rm -rf "$tmp/keychain"
        mkdir -p "$keychain/$folder"
        cp "$file" "$keychain/$folder/fixture.swift"
        check "$tmp/keychain/Packages"
        [ "$code" -eq 1 ] || fail "$name in $folder: expected exit 1, got $code"
        echo "$out" | grep -q ": keychain: " || fail "$name in $folder: no line"
    done
    rm -rf "$tmp/keychain"
    mkdir -p "$tmp/keychain/App"
    cp "$file" "$tmp/keychain/App/fixture.swift"
    check "$tmp/keychain/App"
    [ "$code" -eq 1 ] || fail "$name in App: expected exit 1, got $code"
done

# The rules of Reviews. Each call puts one fixture at one path below a folder named Packages (or
# in a folder App, for a path that starts with App/) and checks that folder.
# expect_lines <fixture> <path> <rule> <count>: exit 1 and <count> lines of the rule for the path.
# expect_pass <fixture> <path>: exit 0.
place() {
    rm -rf "$tmp/reviews"
    case "$2" in
        App/*) place_root="$tmp/reviews/App" place_file="$tmp/reviews/$2" ;;
        *) place_root="$tmp/reviews/Packages" place_file="$tmp/reviews/Packages/$2" ;;
    esac
    mkdir -p "$(dirname "$place_file")"
    cp "$fix/$1" "$place_file"
    check "$place_root"
}
expect_lines() {
    place "$1" "$2"
    [ "$code" -eq 1 ] || fail "$1 at $2: expected exit 1, got $code: $out"
    [ "$(echo "$out" | grep -c "/$2:[0-9]*: $3: ")" -eq "$4" ] ||
        fail "$1 at $2: not $4 lines for rule $3: $out"
}
expect_pass() {
    place "$1" "$2"
    [ "$code" -eq 0 ] || fail "$1 at $2: expected exit 0, got $code: $out"
}
src=Bifrost/Sources
reviews=$src/BifrostReviews
panels=$src/BifrostWindows/UI/Reviews
tests=Bifrost/Tests/BifrostReviewsTests/Model/GitHub/T.swift

# github-write: a mutation or the word "mutation" in a string, outside the two files of the
# writes and the reads. The test support module counts too.
for file in $reviews/Services/GitHub/GitHubClient.swift $src/BifrostTestSupport/FakeGitHub.swift \
    $src/BifrostSessions/Services/Info/Lookup.swift $panels/ReviewPanel.swift; do
    expect_lines bad/github-write.swift "$file" github-write 4
done
for file in $reviews/Model/GitHub/GitHubWrite.swift $reviews/Model/GitHub/GitHubQuery.swift \
    "$tests" App/Bifrost/Fixture.swift; do
    expect_pass bad/github-write.swift "$file"
done
expect_pass good/reviews-query.swift $reviews/Model/GitHub/GitHubQuery.swift
expect_lines good/reviews-query.swift $reviews/Services/GitHub/GitHubClient.swift github-write 1

# github-never: no file of the sources, also not the files of the writes and the test support.
for file in $reviews/Model/GitHub/GitHubWrite.swift $reviews/Model/GitHub/GitHubQuery.swift \
    $src/BifrostTestSupport/FakeGitHub.swift $src/BifrostSessions/Services/Info/Lookup.swift; do
    expect_lines bad/github-never.swift "$file" github-never 4
done
expect_pass bad/github-never.swift "$tests"
expect_pass bad/github-never.swift App/Bifrost/Fixture.swift

# git-push: the literal "push" only in GitCommand.swift, and the other literals nowhere in the
# Reviews module and the Reviews panels. Other folders are out of scope.
for file in $reviews/Services/Git/Pusher.swift $panels/ReviewPanel.swift; do
    expect_lines bad/git-push.swift "$file" git-push 2
    expect_lines bad/git-push-anywhere.swift "$file" git-push 5
done
expect_pass bad/git-push.swift $reviews/Model/Git/GitCommand.swift
expect_lines bad/git-push-anywhere.swift $reviews/Model/Git/GitCommand.swift git-push 5
for file in $src/BifrostSessions/Services/Push.swift $src/BifrostWindows/UI/Other/Push.swift \
    "$tests"; do
    expect_pass bad/git-push.swift "$file"
    expect_pass bad/git-push-anywhere.swift "$file"
done

# user-click: only the Reviews panels and the tests make a click. The test support module and the
# app cannot.
for file in $reviews/Services/Approver.swift $src/BifrostTestSupport/FakeGitHub.swift \
    $src/BifrostWindows/UI/Other/Panel.swift App/Bifrost/Fixture.swift; do
    expect_lines bad/user-click.swift "$file" user-click 4
done
expect_pass bad/user-click.swift $panels/ReviewPanel.swift
expect_pass bad/user-click.swift "$tests"

# reviews-process: in the Reviews module, only the two runners make a Command.
for file in $reviews/Services/Approver.swift $reviews/Services/GitHub/GHRunnerTwo.swift \
    $reviews/Model/Git/GitCommand.swift; do
    expect_lines bad/reviews-process.swift "$file" reviews-process 3
done
for file in $reviews/Services/GitHub/GHRunner.swift $reviews/Services/Git/RepoGit.swift \
    $src/BifrostSessions/Services/Info/Lookup.swift "$tests"; do
    expect_pass bad/reviews-process.swift "$file"
done

# trust-run: only the Reviews module and the tests check a trust run. The Sessions module (the
# file of the check), the Reviews panels, the test support module and the app cannot. The good
# fixture (a comment, the declaration, a text and other checks) passes everywhere.
for file in $src/BifrostSessions/Services/TrustRuns.swift $panels/TrustPanels.swift \
    $src/BifrostTestSupport/FakeTrust.swift App/Bifrost/Fixture.swift; do
    expect_lines bad/trust-run.swift "$file" trust-run 3
    expect_pass good/trust-run.swift "$file"
done
for file in $reviews/Services/RepoSetup.swift "$tests" \
    Bifrost/Tests/BifrostChatTests/UI/Trust/T.swift; do
    expect_pass bad/trust-run.swift "$file"
done

# The string rules read the text that a literal makes: an escape \u{...} gives its character, and
# a backslash at the end of a line of a multi-line string joins the next line.
expect_lines bad/github-write-escape.swift $reviews/Services/GitHub/GitHubClient.swift \
    github-write 2
expect_lines bad/github-never-escape.swift $src/BifrostSessions/Services/Info/Lookup.swift \
    github-never 1
expect_lines bad/git-push-escape.swift $reviews/Services/Git/Pusher.swift git-push 2

# user-click over lines: a return, an array, UserClick.self.init and a parameter with another
# label (the label click is the one the rule reads at each call).
expect_lines bad/user-click-forms.swift $reviews/Services/Approver.swift user-click 5
expect_lines bad/user-click-forms.swift App/Bifrost/Fixture.swift user-click 5
expect_pass bad/user-click-forms.swift $panels/ReviewPanel.swift
expect_pass bad/user-click-forms.swift "$tests"

# github-write: a flag of a write through gh api, in the Reviews module and the panels, outside
# the files of the writes and the reads.
for file in $reviews/Services/GitHub/GitHubClient.swift $panels/ReviewPanel.swift; do
    expect_lines bad/github-write-rest.swift "$file" github-write 6
done
for file in $reviews/Model/GitHub/GitHubWrite.swift $reviews/Model/GitHub/GitHubQuery.swift \
    $src/BifrostSessions/Services/Info/Lookup.swift "$tests"; do
    expect_pass bad/github-write-rest.swift "$file"
done

# Code, comments and friendly texts never match: a test name with createRef, alias.isEmpty as
# code, a text with the word "push" (also with an escape or over two lines), GitCommand( as code,
# a parameter with the label click, and a text with -X in it.
for file in $reviews/Services/Git/Pusher.swift $panels/ReviewPanel.swift \
    $reviews/Model/Git/GitCommand.swift; do
    expect_pass good/reviews-code.swift "$file"
done

check "$fix/good"
[ "$code" -eq 0 ] || fail "good: expected exit 0, got $code: $out"

check "$tmp/nonexistent"
[ "$code" -eq 2 ] || fail "missing root: expected exit 2, got $code"

echo PASS
