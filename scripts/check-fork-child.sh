#!/bin/sh
# Checks the compiled code that runs in the copy of a fork (forkAndExec of PTYProcess). After a
# fork, the copy has only one thread, and a lock that another thread held stays locked. So the
# copy must not call the Swift runtime, the Objective-C runtime or other Swift code. A Swift
# release or a free in the copy can wait for ever on such a lock.
#
# Usage: scripts/check-fork-child.sh <symbol pattern> <object file>...
#
# The symbol pattern is an extended regular expression for the symbol names of nm. Each object
# file must have at least one symbol that matches. For each such symbol, the script prints the
# functions that it calls (the branch relocations of objdump). The script exits 1 when:
# - an object file is missing, or it has no symbol that matches;
# - a symbol calls a function with "swift" in its name, a function that starts with "_objc_",
#   or a Swift function (a name that starts with "_$s" or "_$S");
# - a symbol has an indirect branch (blr or br), because the script cannot read its target.
# The script only reads the object files. It runs only nm and objdump. It changes no file.

set -u
set -f

if [ $# -lt 2 ]; then
    echo "usage: scripts/check-fork-child.sh <symbol pattern> <object file>..." >&2
    exit 2
fi
pattern=$1
shift

status=0
for object in "$@"; do
    if [ ! -f "$object" ]; then
        echo "FAIL $object: the file does not exist"
        status=1
        continue
    fi
    symbols=$(nm -j "$object" | grep -E -- "$pattern")
    if [ -z "$symbols" ]; then
        echo "FAIL $object: no symbol matches $pattern"
        status=1
        continue
    fi
    # A Swift symbol name has no space, so each word is one symbol.
    for symbol in $symbols; do
        echo "$object"
        echo "  $symbol"
        listing=$(xcrun objdump --disassemble-symbols="$symbol" --reloc "$object")
        if ! printf '%s\n' "$listing" | grep -qE '^[[:space:]]+[0-9a-f]+:[[:space:]]'; then
            echo "  FAIL: objdump gave no instructions"
            status=1
            continue
        fi
        calls=$(printf '%s\n' "$listing" | awk '/ARM64_RELOC_BRANCH26/ { print $NF }')
        echo "  calls: $(printf '%s' "$calls" | tr '\n' ' ')"
        bad=$(printf '%s\n' "$calls" | grep -E 'swift|^_objc_|^_\$[sS]')
        if [ -n "$bad" ]; then
            echo "  FAIL: calls of the runtime or of Swift code:"
            printf '%s\n' "$bad"
            status=1
        fi
        # An instruction line: the address, the encoding, then blr or br (also blraa and the
        # other forms) with a register.
        branch='(blr|br)[a-z]*[[:space:]]+x'
        indirect=$(printf '%s\n' "$listing" |
            grep -E "^[[:space:]]+[0-9a-f]+:[[:space:]]+[0-9a-f]+[[:space:]]+$branch")
        if [ -n "$indirect" ]; then
            echo "  FAIL: an indirect branch:"
            printf '%s\n' "$indirect"
            status=1
        fi
    done
done
exit $status
