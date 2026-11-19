"""Fail when a text file of the repo breaks a file rule.

Usage: python3 -I scripts/check_rules.py <repo root>

The check reads the files that git lists: the tracked files and the untracked files that git
does not ignore. It reads only text files: UTF-8 with no NUL byte.

Rules:
- long-line: a line of more than 100 characters. The rule skips these files: *.pbxproj,
  *.xcscheme, Package.resolved, pnpm-lock.yaml, .releaserc.json, the files below a folder named
  Fixtures, the files named LICENSE and the SVG files below a folder named Resources (a licence
  text and an icon file of an icon set stay as written), the files below
  docs/archive/phase-records/, docs/archive/gates/ and docs/explainers/, and the bundled files of
  Claude Code below App/Bifrost/Resources/live-mod/ and App/Bifrost/Resources/bifrost-skills/. It
  also skips the table rows of a Markdown file (the lines that start with "|"), the link
  definitions of a Markdown file ("[name]: address", because an address cannot wrap) and the
  setting lines of a *.xcconfig file (a build setting cannot continue on the next line). A comment
  line of a *.xcconfig file keeps the rule.
- release-id: a line that holds the release bundle ID. The ID is the value of
  BIFROST_RELEASE_BUNDLE_ID in Config/Base.xcconfig. Only that file can hold it.
- cutover-condition: a line of Config/*.xcconfig or of a project.pbxproj file that holds
  BIFROST_CUTOVER. Only that condition lets the release build run (StartGuard), so no build
  configuration can set it before cutover.

Exit 0: no finding. Exit 1: one or more findings, one line each. Exit 2: the check cannot run.
"""

import os
import re
import subprocess
import sys

LIMIT = 100
XCCONFIG = "Config/Base.xcconfig"
RELEASE_ID = re.compile(r"^\s*BIFROST_RELEASE_BUNDLE_ID\s*=\s*(\S+)\s*$", re.MULTILINE)
# The long-line rule skips the files below these folders. The phase records and the results of
# the gates are not edited.
# An explainer page is one HTML file with inline SVG. Its lines are long by design.
# Claude Code reads the bundled files of the mod and of the skills plugin as they are. A field of
# the frontmatter of a SKILL.md and a JSON string cannot continue on the next line.
SKIPPED_FOLDERS = (
    "docs/archive/phase-records/", "docs/archive/gates/", "docs/explainers/",
    "App/Bifrost/Resources/live-mod/", "App/Bifrost/Resources/bifrost-skills/",
)
SKIPPED_SUFFIXES = (".pbxproj", ".xcscheme")
# A build setting cannot continue on the next line, so only a comment line of a build
# configuration file keeps the long-line rule.
SETTINGS_SUFFIX = ".xcconfig"
# A tool writes the two lock files. A command of the semantic-release config is one JSON string,
# and a JSON string cannot continue on the next line.
SKIPPED_NAMES = ("Package.resolved", "pnpm-lock.yaml", ".releaserc.json")
# A licence text of a resource (a font or an icon set) stays as written. So does an icon file of
# an icon set (for example a copy of a lucide icon).
LICENCE_NAME = "LICENSE"
ICON_SUFFIX = ".svg"
CUTOVER = "BIFROST_CUTOVER"


class CheckError(Exception):
    pass


def listed_files(root):
    """Return the sorted paths, relative to root, that git lists."""
    command = [
        "git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z",
    ]
    try:
        done = subprocess.run(command, capture_output=True, check=False)
    except OSError as error:
        raise CheckError(f"cannot run git: {error}") from error
    if done.returncode != 0:
        text = done.stderr.decode("utf-8", "replace").strip()
        raise CheckError(f"git ls-files failed in {root}: {text}")
    paths = [path.decode("utf-8", "surrogateescape") for path in done.stdout.split(b"\0")]
    return sorted({path for path in paths if path})


def release_id(root):
    """Return the release bundle ID from the xcconfig file."""
    path = os.path.join(root, XCCONFIG)
    try:
        with open(path, encoding="utf-8") as handle:
            match = RELEASE_ID.search(handle.read())
    except (OSError, UnicodeDecodeError) as error:
        raise CheckError(f"cannot read {XCCONFIG}: {error}") from error
    if not match:
        raise CheckError(f"no BIFROST_RELEASE_BUNDLE_ID in {XCCONFIG}")
    return match.group(1)


def read_text(path):
    """Return the text of a file, or None when it is not a text file or not a file."""
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as handle:
        data = handle.read()
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def long_lines_apply(path):
    """True when the long-line rule applies to the file at this relative path."""
    parts = path.split("/")
    if path.startswith(SKIPPED_FOLDERS) or "Fixtures" in parts[:-1]:
        return False
    if (parts[-1] == LICENCE_NAME or parts[-1].endswith(ICON_SUFFIX)) and "Resources" in parts[:-1]:
        return False
    return not (path.endswith(SKIPPED_SUFFIXES) or parts[-1] in SKIPPED_NAMES)


def is_build_configuration(path):
    """True for a file of Config/*.xcconfig and for a project.pbxproj file."""
    parts = path.split("/")
    if len(parts) == 2 and parts[0] == "Config" and parts[1].endswith(".xcconfig"):
        return True
    return parts[-1] == "project.pbxproj"


# A Markdown link definition: [name]: address, with no space in the address.
LINK_DEFINITION = re.compile(r"\[[^\]]+\]: \S+")

def check_file(path, text, identifier):
    """Yield (line number, rule, source line) for each finding in one file."""
    long_lines = long_lines_apply(path)
    markdown = path.endswith(".md")
    settings = path.endswith(SETTINGS_SUFFIX)
    release = path != XCCONFIG
    configuration = is_build_configuration(path)
    for number, line in enumerate(text.split("\n"), start=1):
        line = line.removesuffix("\r")
        table_row = markdown and line.startswith("|")
        # A Markdown link definition holds one web address, and an address cannot wrap.
        link_definition = markdown and LINK_DEFINITION.fullmatch(line) is not None
        setting = settings and not line.lstrip().startswith("//")
        if long_lines and len(line) > LIMIT and not (table_row or link_definition or setting):
            yield number, "long-line", f"{len(line)} characters"
        if release and identifier.lower() in line.lower():
            yield number, "release-id", line.strip()
        if configuration and CUTOVER in line:
            yield number, "cutover-condition", line.strip()


def main(root):
    if not os.path.isdir(root):
        print(f"error: not a folder: {root}", file=sys.stderr)
        return 2
    try:
        paths = listed_files(root)
        identifier = release_id(root)
    except CheckError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    found = 0
    for path in paths:
        text = read_text(os.path.join(root, path))
        if text is None:
            continue
        for number, rule, source in check_file(path, text, identifier):
            print(f"{path}:{number}: {rule}: {source}")
            found += 1
    if found:
        return 1
    print("no rule findings")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check_rules.py <repo root>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
