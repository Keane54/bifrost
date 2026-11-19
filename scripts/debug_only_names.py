"""Print the names of the types that only a Debug build has.

Usage: python3 -I scripts/debug_only_names.py [--require <name>,...] <root>...

A Swift file is Debug-only when "#if DEBUG" is its first line of code and the "#endif" of that
block is its last line of code. A line of code is a line that is not empty and is not only a
comment. A comment after a directive (#if DEBUG // text) is not a part of the directive. The
script prints the name of each top-level type of a Debug-only file: a struct, a class, an enum
(also an indirect enum), an actor or a protocol at the start of a line. It does not print a
private or a fileprivate type, because a short private name (for example Field) can be a part of
the symbols of other code. It prints one name on each line, sorted, with no name two times. It
skips the .build folders and the test folders (a folder whose name ends in Tests).

scripts/check.sh gives these names to the symbol check of the Release app. So each new type of a
Debug-only file is in the check, with no list to keep by hand.

A change can remove the names of a file from the list with no error: for example a removed
"#if DEBUG", or an "#endif" that moved up. Then the symbol check has less control and still
passes. So check.sh gives a fixed floor of names with --require: the script fails when one of
these names is not in its list.

Exit: 0 when the script found at least one name and each required name. 1 when it found no name
(then the check would pass with no control), or when a required name is missing. 2 for a missing
root or a bad argument.
"""

import os
import re
import sys

TYPE = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*"
    r"((?:(?:nonisolated|public|package|internal|private|fileprivate|final|open|indirect)\s+)*)"
    r"(?:struct|class|enum|actor|protocol)\s+(\w+)"
)
HIDDEN = {"private", "fileprivate"}


def code_lines(text):
    """Return the lines of code of a file: no empty line and no line that is only a comment."""
    lines = []
    in_block = False
    for raw in text.splitlines():
        line = raw.strip()
        if in_block:
            if "*/" in line:
                in_block = False
            continue
        if not line or line.startswith("//"):
            continue
        if line.startswith("/*"):
            in_block = "*/" not in line
            continue
        lines.append(raw)
    return lines


def directive(raw):
    """Return a line of code with no comment at its end and with single spaces, when it is a
    directive (#if, #endif). Return each other line with no change. Only a directive loses its
    comment, because a "//" in a string of code is not a comment."""
    line = raw.strip()
    if not line.startswith("#"):
        return line
    line = re.sub(r"/\*.*?\*/", " ", line)
    line = line.split("//", 1)[0]
    return " ".join(line.split())


def is_debug_only(lines):
    """True when "#if DEBUG" opens the file and its "#endif" is the last line of code."""
    if len(lines) < 2 or directive(lines[0]) != "#if DEBUG":
        return False
    depth = 0
    for index, raw in enumerate(lines):
        line = directive(raw)
        if line.startswith("#if"):
            depth += 1
        elif line.startswith("#endif"):
            depth -= 1
            if depth == 0:
                return index == len(lines) - 1
    return False


def type_names(lines):
    """Yield the name of each top-level type that is not private or fileprivate."""
    for raw in lines:
        match = TYPE.match(raw)
        if match and not HIDDEN & set(match.group(1).split()):
            yield match.group(2)


def swift_files(root):
    for folder, names, files in os.walk(root):
        names[:] = sorted(d for d in names if d != ".build" and not d.endswith("Tests"))
        for name in sorted(files):
            if name.endswith(".swift"):
                yield os.path.join(folder, name)


def main(roots, required=()):
    for root in roots:
        if not os.path.isdir(root):
            print(f"error: not a folder: {root}", file=sys.stderr)
            return 2
    names = set()
    for root in roots:
        for path in swift_files(root):
            with open(path, encoding="utf-8") as handle:
                lines = code_lines(handle.read())
            if is_debug_only(lines):
                names.update(type_names(lines))
    if not names:
        print("error: no type in a Debug-only file", file=sys.stderr)
        return 1
    missing = sorted(set(required) - names)
    if missing:
        print(
            f"error: no Debug-only type {', '.join(missing)}: check the #if DEBUG and the #endif"
            " of its file",
            file=sys.stderr,
        )
        return 1
    print("\n".join(sorted(names)))
    return 0


def parse(args):
    """Return (roots, required names), or None for a bad argument list."""
    required = []
    if args[:1] == ["--require"]:
        if len(args) < 2:
            return None
        required = [name for name in args[1].split(",") if name]
        args = args[2:]
    if not args or any(arg.startswith("-") for arg in args):
        return None
    return args, required


if __name__ == "__main__":
    parsed = parse(sys.argv[1:])
    if parsed is None:
        print("usage: debug_only_names.py [--require <name>,...] <root>...", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(*parsed))
