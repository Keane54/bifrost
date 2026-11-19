#!/bin/sh
# Self-test of debug_only_names.py, the list of the Debug-only types for the symbol check of the
# Release app (scripts/check.sh).
# The script makes Swift files in a temporary folder. A file that #if DEBUG wraps gives its
# top-level types that are not private or fileprivate, also an indirect enum, and also when a
# comment follows the #if DEBUG. A nested type, a type of a file that #if DEBUG does not wrap to
# its end, a file with no #if DEBUG and a test folder give no name. A root with no Debug-only type
# gives exit 1, and a missing root gives exit 2.
# The floor (--require): each required name in the list gives exit 0. A required name that left
# the list (its file lost the #if DEBUG, or its #endif moved up) gives exit 1. A bad argument
# list gives exit 2.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: $1"
    exit 1
}

# Runs the script with the arguments. Sets out and code.
names() {
    out=$(python3 -I "$here/debug_only_names.py" "$@" 2>&1)
    code=$?
}

mkdir -p "$tmp/root/Sources/Kit" "$tmp/root/Tests/KitTests"
cat >"$tmp/root/Sources/Kit/Wrapped.swift" <<'SWIFT'
// A file that only a Debug build has.

/* A block comment
   before the code. */
#if DEBUG
import Foundation

public struct Alpha {
    struct Nested {}
}
private enum Hidden {}
fileprivate struct AlsoHidden {}
package final class Bravo {}
@MainActor
public final class Charlie {}
nonisolated public enum Delta: String { case one }
protocol Echo {}
#if os(macOS)
actor Foxtrot {}
#endif
extension Alpha {}
#endif
// The end of the file.
SWIFT
cat >"$tmp/root/Sources/Kit/Commented.swift" <<'SWIFT'
#if DEBUG // Only a Debug build has this file.
indirect enum Kilo {
    case leaf
    case node(Kilo)
}
public indirect enum Lima { case end }
#endif // DEBUG
SWIFT
cat >"$tmp/root/Sources/Kit/Partial.swift" <<'SWIFT'
#if DEBUG
struct Golf {}
#endif
struct Hotel {}
SWIFT
cat >"$tmp/root/Sources/Kit/Plain.swift" <<'SWIFT'
struct India {}
SWIFT
cat >"$tmp/root/Tests/KitTests/Wrapped.swift" <<'SWIFT'
#if DEBUG
struct Juliett {}
#endif
SWIFT

names "$tmp/root"
[ "$code" -eq 0 ] || fail "a root with Debug-only types: expected exit 0, got $code: $out"
want='Alpha
Bravo
Charlie
Delta
Echo
Foxtrot
Kilo
Lima'
[ "$out" = "$want" ] || fail "the names: expected $(echo $want), got $(echo $out)"

names --require Alpha,Kilo "$tmp/root"
[ "$code" -eq 0 ] || fail "each required name in the list: expected exit 0, got $code: $out"
[ "$out" = "$want" ] || fail "the names with a floor: expected $(echo $want), got $(echo $out)"

# The file of Kilo and Lima loses its #if DEBUG. Then its #endif moves up.
mkdir -p "$tmp/floor/Sources/Kit"
cp "$tmp/root/Sources/Kit/Wrapped.swift" "$tmp/floor/Sources/Kit/"
cat >"$tmp/floor/Sources/Kit/Commented.swift" <<'SWIFT'
indirect enum Kilo { case leaf }
SWIFT
names --require Alpha,Kilo "$tmp/floor"
[ "$code" -eq 1 ] || fail "a file with no #if DEBUG: expected exit 1, got $code: $out"
echo "$out" | grep -q "Kilo" || fail "a file with no #if DEBUG: no line names Kilo: $out"
cat >"$tmp/floor/Sources/Kit/Commented.swift" <<'SWIFT'
#if DEBUG
public struct Mike {}
#endif
indirect enum Kilo { case leaf }
SWIFT
names --require Alpha,Kilo "$tmp/floor"
[ "$code" -eq 1 ] || fail "an #endif that moved up: expected exit 1, got $code: $out"
echo "$out" | grep -q "Kilo" || fail "an #endif that moved up: no line names Kilo: $out"

for args in "--require" "--require Alpha" "--other $tmp/root"; do
    # shellcheck disable=SC2086
    names $args
    [ "$code" -eq 2 ] || fail "the arguments $args: expected exit 2, got $code: $out"
done

mkdir -p "$tmp/none/Sources/Kit"
for name in Partial Plain; do
    cp "$tmp/root/Sources/Kit/$name.swift" "$tmp/none/Sources/Kit/"
done
names "$tmp/none"
[ "$code" -eq 1 ] || fail "a root with no Debug-only type: expected exit 1, got $code: $out"

names "$tmp/nonexistent"
[ "$code" -eq 2 ] || fail "missing root: expected exit 2, got $code"

echo PASS
