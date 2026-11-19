#!/bin/sh
# The check of the whole repo. CI runs it on each push, and you run it before each commit.
#
# Usage: scripts/check.sh [--clean] [--keep-going]
#
# The script runs each step in order. It prints "ok <step>" or "FAIL <step>" for each step.
# The steps tests and smoke-debug run in the test sandbox (scripts/run-sandboxed.sh).
# The sandbox refuses the real shared state and the network.
# The full output of each step goes to .build/check/<step>.log.
# The script stops at the first failed step and exits 1.
# With --keep-going, it runs each step and reports each failure in one run, as CI does. A step
# that needs the output of an earlier step that failed prints "skip <step> (needs <steps>)". At
# the end the script lists the failed and the skipped steps and exits 1.
# After all steps pass, it prints "all checks passed" and exits 0.
# With --clean, the script removes the .build folder when the run ends.
#
# The script never starts the Release build. It only builds that app.
# After the build, it removes that app from the LaunchServices database.

set -u

clean=no
keep_going=no
for arg in "$@"; do
    case "$arg" in
        --clean) clean=yes ;;
        --keep-going) keep_going=yes ;;
        *)
            echo "usage: scripts/check.sh [--clean] [--keep-going]"
            exit 1
            ;;
    esac
done

# Go to the root of the repo, from any current folder.
script_dir=$(cd "$(dirname "$0")" && pwd) || exit 1
root=$(dirname "$script_dir")
# Stop before the steps and before "rm -rf" when the parent folder is not the repo.
if [ ! -f "$root/Bifrost.xcodeproj/project.pbxproj" ]; then
    echo "error: $root is not the repo: it has no Bifrost.xcodeproj/project.pbxproj" >&2
    exit 1
fi
cd "$root" || exit 1

logs=".build/check"
products=".build/xcode/Build/Products"
mkdir -p "$logs" || exit 1

finish() {
    if [ "$clean" = yes ]; then
        rm -rf "$root/.build"
    fi
}
trap finish EXIT
trap 'exit 1' HUP INT TERM

# The names of the failed and the skipped steps of a run with --keep-going.
failed=""

# Runs one step. The first argument is the step name. A step that needs the output of earlier
# steps names them after --after, in one argument with commas. The other arguments are the
# command. A step whose needed step failed or was skipped does not run.
run_step() {
    name=$1
    shift
    if [ "${1:-}" = --after ]; then
        missing=""
        for need in $(printf '%s' "$2" | tr ',' ' '); do
            case " $failed " in
                *" $need "*) missing="$missing${missing:+, }$need" ;;
            esac
        done
        shift 2
        if [ -n "$missing" ]; then
            echo "skip $name (needs $missing)"
            failed="$failed $name"
            return
        fi
    fi
    if "$@" >"$logs/$name.log" 2>&1; then
        echo "ok $name"
    else
        echo "FAIL $name (log: $logs/$name.log)"
        if [ "$keep_going" = no ]; then
            exit 1
        fi
        failed="$failed $name"
    fi
}

xcode_build() {
    xcodebuild -project Bifrost.xcodeproj -scheme Bifrost -configuration "$1" \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
        -clonedSourcePackagesDirPath .build/spm build
}

# The Release app has the bundle ID of the Electron app. After the build, the LaunchServices
# database has the Release app. Then macOS can open the Release app in place of the Electron app.
ls_frameworks=/System/Library/Frameworks/CoreServices.framework/Frameworks
lsregister=$ls_frameworks/LaunchServices.framework/Support/lsregister

# The names of the code that only a Debug build has (#if DEBUG). scripts/debug_only_names.py
# gives the types of each file that #if DEBUG wraps: the debug test port, the US key map that
# the test port types with, the fake speech engine, and the debug bench with its plan and its
# frame counter. So a new type of such a file is in the check at once. This list adds the
# Debug-only members of other files: the key focus of a test home and of the tests, the parts of
# the shell that only the test port reads or calls, the form of the Service status panel that its
# tests read, and the local remotes of the review clones of a test home (RepoGit). Each name must
# match only symbols of the Debug-only code. One name on each line.
debug_only_members='actAsKeyForTestHome
actsAsKey
overviewsState
importState
sortOverview
OverviewSortRefusal
settingsState
changeSettings
liveDetailsState
skillsPluginState
runPluginAction
sessionsState
resumeSession
backgroundPhase
eventsState
usageState
watchlistState
showInfoState
reviewsState
releaseNotesState
dailyUpdateState
performanceState
testPortState
testPortOp
shownForm
runDailyTest
runReviewsTest
actionsState
runTestAction
sendTestText
localRemotesForTestHome
localRemotesConfig'

# The floor of the Debug-only types: the main type of each Debug-only file. debug_only_names.py
# fails when one of these names is not in its list. So a change that removes the #if DEBUG of
# such a file, or that moves its #endif up, does not remove the names of the file from the check
# with no error. Add the main type of each new Debug-only file here. ProcessMetrics is the main
# type of Metrics.swift.
debug_type_floor=BenchPlan,BenchRunner,FakeSpeechEngine,ProcessMetrics,SettingsPatch,\
TestActionDriver,TestPortHandler,TestPortMessage,TestPortServer,USKeyboard

# Prints the symbols of each Mach-O file in the executable folder and the frameworks of an app.
# The script only reads the files. It never starts the app.
app_symbols() {
    find "$1/Contents/MacOS" "$1/Contents/Frameworks" -type f 2>/dev/null | while read -r file; do
        if file -b "$file" | grep -q 'Mach-O'; then
            nm "$file" 2>/dev/null
        fi
    done
}

# The names of code that each build has: the app delegate of the app target and the services of
# the app module. One name on each line.
always_names='AppDelegate
AppServices'

# Returns 0 when the symbols in $1 have each name of the list in $2. Else prints the first missing
# name and returns 1. grep -c reads all its input (grep -q can stop early, and then printf writes
# to a closed pipe).
has_each_name() {
    for symbol in $2; do
        if ! printf '%s\n' "$1" | grep -c -F "$symbol" >/dev/null; then
            echo "$symbol"
            return 1
        fi
    done
}

# The Release app must not have the Debug-only code. Two controls make sure that the search can
# read the symbols: the Release app must have the names of each build, and the Debug app must
# have each Debug-only name. So a missing, moved or stripped binary does not pass.
check_release_symbols() {
    release_app=$1
    debug_app="$root/$products/Debug/Bifrost Dev.app"
    if ! debug_types=$(python3 -I scripts/debug_only_names.py --require "$debug_type_floor" \
        Packages/Bifrost/Sources App); then
        echo "debug_only_names.py: no complete list of the Debug-only types"
        return 1
    fi
    debug_only_names="$debug_types
$debug_only_members"
    release_symbols=$(app_symbols "$release_app")
    if ! missing=$(has_each_name "$release_symbols" "$always_names"); then
        echo "nm: the control failed: the Release app has no symbol with $missing"
        return 1
    fi
    found=$(printf '%s\n' "$release_symbols" | grep -F -c "$debug_only_names")
    if [ "$found" -ne 0 ]; then
        echo "nm: the Release app has $found symbols of the Debug-only code:"
        printf '%s\n' "$release_symbols" | grep -F "$debug_only_names" | sed -n '1,20p'
        return 1
    fi
    if ! missing=$(has_each_name "$(app_symbols "$debug_app")" "$debug_only_names"); then
        echo "nm: the control failed: the Debug app has no symbol with $missing"
        return 1
    fi
    echo "nm: the Release app has no symbol of the Debug-only code"
}

# Builds the Release app, then removes it from the LaunchServices database. Then it reads the
# symbols of the Release app (it never starts the app).
# The result is the result of the build and of the symbol check. A failure of lsregister does
# not change it. The step log records the result of lsregister.
build_release() {
    xcode_build Release
    build_status=$?
    release_app="$root/$products/Release/Bifrost.app"
    if [ -d "$release_app" ]; then
        "$lsregister" -u "$release_app"
        ls_status=$?
        if [ "$ls_status" -eq 0 ]; then
            echo "lsregister: removed $release_app from the LaunchServices database"
        else
            echo "lsregister: FAILED with exit $ls_status to remove $release_app"
        fi
    fi
    [ "$build_status" -eq 0 ] || return "$build_status"
    check_release_symbols "$release_app"
}

# The compiled code of the copy of a fork must not call the Swift or the Objective-C runtime:
# after a fork, a lock that another thread held stays locked, and the copy can wait on it for
# ever. The step reads the PTYProcess object files of the Debug and the Release build with nm and
# objdump. It changes no file.
fork_child() {
    objects=.build/xcode/Build/Intermediates.noindex/Bifrost.build
    scripts/check-fork-child.sh 'PTYProcessC11forkAndExec' \
        "$objects/Debug/BifrostSessions.build/Objects-normal/arm64/PTYProcess.o" \
        "$objects/Release/BifrostSessions.build/Objects-normal/arm64/PTYProcess.o"
}

# Expects exit 2 from smoke.sh: it must refuse the Release app and not start it.
refuse_release() {
    scripts/smoke.sh "$products/Release/Bifrost.app"
    [ "$?" -eq 2 ]
}

# Resolves the dependencies of the package, outside the test sandbox. The sandbox refuses the
# network, so the test step needs the resolved package. The step uses the scratch folder of the
# test step.
resolve_package() {
    swift package resolve --package-path Packages/Bifrost --scratch-path .build/pkg
}

# Runs the tests of all modules of the package in the test sandbox. The first swift test builds
# each module one time and runs the test targets that open no window: Foundation, Layout,
# Sessions, Live, Settings and Dictation. The second swift test uses the same build and runs the
# other test targets, which open windows. Some tests of the first group run timers on the real
# clock (the tag timing), and the window tests load the main actor, so the two groups do not run
# at the same time. Warnings are errors. The tests open no window in front and never activate
# the test process.
no_window_tests='^Bifrost(Foundation|Layout|Sessions|Live|Settings|Dictation)Tests\.'
package_tests() {
    scripts/run-sandboxed.sh swift test --package-path Packages/Bifrost \
        --scratch-path .build/pkg --disable-sandbox -Xswiftc -warnings-as-errors \
        --filter "$no_window_tests" &&
        scripts/run-sandboxed.sh swift test --package-path Packages/Bifrost \
            --scratch-path .build/pkg --disable-sandbox -Xswiftc -warnings-as-errors \
            --skip-build --skip "$no_window_tests"
}

# Builds the modules of the app in the release configuration with SwiftPM, with warnings as
# errors. Xcode builds the targets of the package with -suppress-warnings, so no Xcode build shows
# a warning of the package. This build finds a warning in the code of a Release build, for example
# a value that only a #if DEBUG branch reads. The target BifrostApp needs each module of the app.
# The test support module is not in it: it uses Debug-only code.
package_release() {
    swift build --package-path Packages/Bifrost --scratch-path .build/pkg -c release \
        --target BifrostApp -Xswiftc -warnings-as-errors
}

run_step forbidden-selftest scripts/test-check-forbidden.sh
run_step rules-selftest scripts/test-check-rules.sh
run_step debug-names-selftest scripts/test-debug-only-names.sh
run_step rules python3 -I scripts/check_rules.py .
run_step forbidden python3 -I scripts/check_forbidden.py Packages App
run_step resolve resolve_package
run_step sandbox-selftest scripts/test-run-sandboxed.sh
run_step tests --after resolve package_tests
run_step package-release --after resolve package_release
run_step build-debug xcode_build Debug
# The self-test of the release scripts. It needs the Sparkle tools that the Debug build resolves
# into .build/spm. The test of the semantic-release config needs Node, so CI runs it (ci.yml).
run_step release-selftest --after build-debug scripts/test-release.sh
run_step bundled-selftest --after build-debug \
    scripts/test-check-bundled.sh "$products/Debug/Bifrost Dev.app"
run_step bundled --after build-debug scripts/check-bundled.sh "$products/Debug/Bifrost Dev.app"
run_step build-release build_release
run_step fork-child --after build-debug,build-release fork_child
run_step smoke-debug --after build-debug \
    scripts/run-sandboxed.sh scripts/smoke.sh "$products/Debug/Bifrost Dev.app"
run_step refuse-release --after build-release refuse_release

if [ -n "$failed" ]; then
    echo "failed or skipped:$failed"
    exit 1
fi
echo "all checks passed"
