"""Fail when Swift code uses a forbidden construct.

Usage: python3 -I scripts/check_forbidden.py <root>...

The home-lookup rule applies only to the files below a root whose last component is Packages.
Each service in the package gets the home folder from the launch code. The test folders (a folder
whose name ends in Tests) get only that rule and the ui-import rule. The other rules apply to the
code that is not a test.

The layer rules apply to the module folders of a package below a root whose last component is
Packages: <package>/Sources/<module>/<layer>/ and the test folders
<package>/Tests/<module>Tests/<layer>/. The layer-folder rule refuses a Swift file of a module that
is in no layer folder (Model, Services or UI), except in the test support module. The ui-import rule
applies to the layers Model and Services, also in a test folder: only the layer UI can use a UI
framework. The model-io rule applies to the layer Model of the sources: a model has no I/O. The
private-api rule applies to each file that is not a test, except the one file of the private blur
(PRIVATE_API_FILE below a root whose last component is Packages). The shared-state rule applies to
each file that is not a test, except the start files of the app module (SHARED_STATE_FILES below a
root whose last component is Packages). The test-temp-folder rule applies to the test folders of a
package: a test makes its temp folders only through TemporaryFolder of the test support module,
which stops the test outside the test sandbox. The pty-spawn rule applies to each file that is
not a test. It has two forms, and each form has one file that can use it (PTY_SPAWN_FORMS below a
root whose last component is Packages): a call of spawn(program:) in the PTY manager, and an init
of PTYProcess in the file of the system spawner. The test support module can use both forms
(PTY_SPAWN_FOLDER). The rule finds a call that spans lines. The keychain rule applies to each
file, also a test, except the files of KEYCHAIN_FILES below a root whose last component is
Packages (none now).

The rules of Reviews keep each GitHub write and each git command in closed types. Three rules
read the text of the string literals (not the code and not the comments) of the sources of
Packages/Bifrost, the test support module included, with whole-word or whole-literal matches:
github-write (a GraphQL mutation, or the word "mutation", outside GitHubWrite.swift and
GitHubQuery.swift), github-never (a mutation that merges, dismisses, unresolves, closes or edits,
in each file) and git-push (in the Reviews module and the Reviews panels: the literal "push"
outside GitCommand.swift, and a literal that starts with --force, --mirror or alias., or that is
send-pack or http-push, in each file). Two rules read the code: user-click (a UserClick made
outside the Reviews panels, in each file that is not a test) and reviews-process (a Command made
in the Reviews module outside GHRunner.swift and RepoGit.swift). The trust-run rule reads the code
too: a call of TrustRuns.check( outside the Reviews module, in each file that is not a test, so
only Reviews (and the tests) can start claude in a review clone.
"""

import os
import re
import sys

RULES = [
    ("unchecked-sendable", re.compile(r"@unchecked\s+Sendable")),
    ("nonisolated-unsafe", re.compile(r"\bnonisolated\s*\(\s*unsafe\s*\)")),
    # An isolation that the compiler does not check. The code reaches an actor with await, or the
    # main run loop with a main-actor method. A test can still use it.
    ("assume-isolated", re.compile(r"\bassumeIsolated\b")),
    ("try-bang", re.compile(r"\btry\s*!")),
    # A postfix "!" after an identifier, ")", "]", ">" or "}". Not "!=". Not "try!".
    ("force-unwrap", re.compile(r"(?<!\btry)(?<=[A-Za-z0-9_)\]>}])!(?!=)")),
    (
        "js-mechanics",
        re.compile(r"\b(Promise|EventLoop|microtask|setTimeout|setInterval)\b|\benum\s+JS\b"),
    ),
    # The UTF-16 index helpers. A Swift string uses Characters, not UTF-16 offsets.
    ("utf16-index", re.compile(r"\butf16Offset\b|\butf16\.index\b|\bUTF16View\.Index\b")),
]

# Only for the files below a root whose last component is Packages.
PACKAGE_RULES = [
    ("home-lookup", re.compile(r"\b(homeDirectoryForCurrentUser|NSHomeDirectory)\b")),
]

# Only for the test folders below a root whose last component is Packages. A test makes a temp
# folder only with TemporaryFolder of BifrostTestSupport. That type checks the test sandbox first,
# so a plain swift test cannot write a real folder before the guard stops it.
TEST_TEMP_RULES = [
    ("test-temp-folder", re.compile(r"\b(?:temporaryDirectory|NSTemporaryDirectory|mkdtemp)\b")),
]

# Only for the layers Model and Services of a module, also in a test folder. An import of a UI
# framework, also with an attribute (@preconcurrency) or with a kind (import struct X.Y).
UI_IMPORT_RULES = [
    (
        "ui-import",
        re.compile(
            r"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
            r"(?:AppKit|Cocoa|SwiftUI|SwiftTerm|Metal|MetalKit|QuartzCore)\b"
        ),
    ),
]
UI_IMPORT_LAYERS = ("Model", "Services")

# Only for the layer Model of the sources of a module. A model has pure types and rules: no I/O.
# The rule finds an import of a module of the system for I/O, a type of the system for files,
# processes, the network, the settings of the user or the bundle, and the read or the write of a
# file through a Foundation type. It cannot find all I/O, for example a call of a C function.
MODEL_RULES = [
    (
        "model-io",
        re.compile(
            r"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
            r"(?:Darwin|Glibc|Dispatch|Network|AVFoundation|Speech|OSLog|os)\b"
            r"|\b(?:FileManager|FileHandle|FileDescriptor|ProcessInfo|Process|URLSession"
            r"|NSWorkspace|UserDefaults|DispatchQueue|Bundle)\b"
            r"|\b(?:Data|String|NSData|NSString)\s*\(\s*contentsOf|\bcontentsOfFile\s*:"
            r"|\bwrite\s*\(\s*to(?:File)?\s*:"
        ),
    ),
]
MODEL_LAYER = "Model"

# The layer folders of a module. Each Swift file of a module is in one of them (the rule
# layer-folder). The test support module has no layers.
LAYERS = ("Model", "Services", "UI")
TEST_SUPPORT = "BifrostTestSupport"

# The look up of a class, a selector or a symbol by name, and a call of a selector. These are
# the usual ways to use private API. Only the one file of the private blur can use them. A plain
# call such as perform(effect) is not a selector call.
# Limits of the rule: it cannot find a private key of key-value coding (for example
# setValue(_:forKey:) with the name of a private property), and a method of the code named
# perform that is called through a value (self.perform(effect)) gives a false finding.
PRIVATE_API_RULES = [
    (
        "private-api",
        re.compile(
            r"\b(?:NSClassFromString|NSSelectorFromString|objc_getClass|objc_lookUpClass"
            r"|objc_getRequiredClass|dlsym)\b|\.perform\s*\("
            r"|\bperform\s*\(\s*(?:#selector|Selector\s*\()"
        ),
    ),
]
PRIVATE_API_FILE = os.path.join("Bifrost", "Sources", "BifrostLook", "UI", "PrivateBackdrop.swift")

# A use of the init of the shared paths of a home: a call (SharedClaudeState(...) or
# SharedClaudeState.init(...)), a reference to the init (SharedClaudeState.init), or an init
# through the type of a declaration (x: SharedClaudeState = .init(...)). Only the start code of
# the app module makes them, from the resolved home (StartPlan.sharedHome). Each other file gets
# them from AppServices.sharedState, so a test home never gives a real shared path.
# Limit of the rule: it cannot find an init through the type of an argument (f(.init(home:))).
SHARED_STATE_RULES = [
    (
        "shared-state",
        re.compile(r"\bSharedClaudeState\s*(?:\(|\.\s*init\b|\??\s*=\s*\.\s*init\b)"),
    ),
]
# The start files of the app module.
SHARED_STATE_FILES = tuple(
    os.path.join("Bifrost", "Sources", "BifrostApp", "Services", name)
    for name in ("AppServices.swift", "StartPlan.swift", "SystemPathCheck.swift")
)

# A spawn of a PTY child, also when the call spans lines. Only the PTY manager spawns, and it
# opens only a CheckedAttach (AttachRules.check), so no other code can start "claude attach"
# around the check. The rule has two forms, each with the one file of the package that can use
# it:
# - A call of spawn(program:...) of a PTYSpawner: with a receiver (spawner.spawn), or bare in a
#   type that conforms to PTYSpawner. Only the PTY manager calls it. A declaration
#   (func spawn(program:)) and an enum case (.spawn(size)) are no call.
# - An init of PTYProcess (PTYProcess(...) or PTYProcess.init), the PTY child of the system. Only
#   the system spawner (SystemPTYSpawner, in PTYProcess.swift) makes one.
# The fakes of the test support module can use both forms.
# Limit of the rule: it cannot find a call through a function value (let f = spawner.spawn).
PTY_SPAWN = "pty-spawn"
PTY_SPAWN_FORMS = [
    (
        re.compile(r"(?P<declaration>\bfunc\s+)?\bspawn\s*\(\s*program\s*:"),
        os.path.join("Bifrost", "Sources", "BifrostSessions", "Services", "PTYManager.swift"),
    ),
    (
        re.compile(r"\bPTYProcess\s*(?:\(|\.\s*init\b)"),
        os.path.join("Bifrost", "Sources", "BifrostSessions", "Services", "PTYProcess.swift"),
    ),
]
PTY_SPAWN_FOLDER = os.path.join("Bifrost", "Sources", TEST_SUPPORT)

# An import of the Security framework (also with an attribute or a kind) and a call of its
# Keychain API. The app reads the access token of the Claude Code login only with the Keychain
# tool /usr/bin/security (AccessToken), which the test sandbox refuses. A read through the
# framework would pass the sandbox, so no file uses it. A file that must use it goes in
# KEYCHAIN_FILES after a review.
KEYCHAIN_RULES = [
    (
        "keychain",
        re.compile(
            r"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?Security\b"
            r"|\bSec(?:Item|Keychain)\w*"
        ),
    ),
]
KEYCHAIN_FILES = ()

# The GitHub and git rules of Reviews. The words of GitHub and git live in string literals, so
# three rules read the text of each string literal (string_literals), not the code and not the
# comments. They apply only to the sources of the package (below a root whose last component is
# Packages); the test folders are out of scope.
REVIEWS_SOURCES = os.path.join("Bifrost", "Sources") + os.sep
REVIEWS_MODULE = os.path.join("Bifrost", "Sources", "BifrostReviews") + os.sep
REVIEWS_UI = os.path.join("Bifrost", "Sources", "BifrostWindows", "UI", "Reviews") + os.sep

# github-write: the GraphQL mutations that Bifrost can send, and the word "mutation", as whole
# words. Only the file of the closed set of writes and the file of the reads (its check of the
# word "mutation") can hold them.
GITHUB_MUTATIONS = (
    "addPullRequestReviewThread", "updatePullRequestReview", "addPullRequestReviewThreadReply",
    "resolveReviewThread", "addComment", "requestReviews", "createCommitOnBranch",
    "addPullRequestReview", "submitPullRequestReview", "updatePullRequestReviewComment",
    "deletePullRequestReviewComment", "deletePullRequestReview",
)
GITHUB_WRITE = re.compile(r"\b(?:mutation|" + "|".join(GITHUB_MUTATIONS) + r")\b")
# github-write also refuses a flag of a write through gh api, as a whole literal, in the Reviews
# module and the Reviews panels outside the two files: a method (-X, --method), a field (-f, -F,
# --field, --raw-field) or a body (--input). Each of them makes gh send a write.
GITHUB_WRITE_FLAGS = ("-X", "-f", "-F", "--field", "--raw-field", "--input", "--method")
GITHUB_WRITE_FLAG_STARTS = ("-X", "--field=", "--raw-field=", "--input=", "--method=")
# A short field flag with its value in the same literal: -f<name>=<value>, -f=<name>=<value> or the
# same with -F. The form needs an "=", so a git flag such as -ffdx (git clean) is no match.
GITHUB_WRITE_SHORT_FIELD = re.compile(r"-[fF][^\s]*=")
GITHUB_WRITE_FILES = tuple(
    os.path.join("Bifrost", "Sources", "BifrostReviews", "Model", "GitHub", name)
    for name in ("GitHubWrite.swift", "GitHubQuery.swift")
)

# github-never: the GraphQL mutations that merge, dismiss, unresolve, close, reopen or edit a PR,
# a ref or the comment of another person, as whole words. No file of the sources holds them, also
# not the test support module.
GITHUB_NEVER = re.compile(
    r"\b(?:mergePullRequest|dismissPullRequestReview|enablePullRequestAutoMerge"
    r"|unresolveReviewThread|deleteIssueComment|updateIssueComment|minimizeComment"
    r"|closePullRequest|reopenPullRequest|updatePullRequest|updatePullRequestBranch"
    r"|convertPullRequestToDraft|markPullRequestReadyForReview|requestReviewsByLogin"
    r"|createRef|updateRef|deleteRef)\b"
)

# git-push: a whole string literal in the Reviews module and the Reviews panels. Only the file
# of the closed set of git commands holds the literal "push". No file holds a literal that starts
# with --force, --mirror or alias. (a git alias can run a shell), or a literal send-pack or
# http-push. A friendly text with the word "push" is a longer literal, so it never matches.
GIT_PUSH_FOLDERS = (REVIEWS_MODULE, REVIEWS_UI)
GIT_PUSH_FILE = os.path.join(
    "Bifrost", "Sources", "BifrostReviews", "Model", "Git", "GitCommand.swift"
)
GIT_PUSH_STARTS = ("--force", "--mirror", "alias.")
GIT_PUSH_NEVER = ("send-pack", "http-push")

# user-click (code): a value that says that the user clicked. Only the Reviews panels and the
# tests make one. The rule reads the code of the whole file, so a form that spans lines counts. It
# finds a call (UserClick(...), UserClick.init or UserClick.self.init), an init through the type
# of a declaration (x: UserClick = .init(), x: [UserClick] = [.init()]) or of a return
# (-> UserClick { .init() }), an init as the click argument of a write (click: .init()), and a
# parameter of the type UserClick with a label other than click, so that each call of a function
# with a click has the label that the rule reads. Limit of the rule: it cannot find an init
# through a generic type or a type alias.
USER_CLICK = re.compile(
    r"\bUserClick\s*(?:\(|\.\s*(?:self\s*\.\s*)?init\b|\??\s*=\s*\.\s*init\b)"
    r"|\[\s*UserClick\s*\]\s*\??\s*=\s*\[\s*\.\s*init\b"
    r"|->\s*UserClick\s*\??\s*\{\s*(?:return\s+)?\.\s*init\b"
    r"|\bclick\s*:\s*\.\s*init\b"
    r"|[(,]\s*(?!click\b)\w+(?:\s+\w+)?\s*:\s*(?:inout\s+)?UserClick\b"
)

# reviews-process (code): a Command of the process runner in the Reviews module. Only the gh
# runner and the git runner make one, so each run of gh or git takes one closed value
# (GitHubQuery, GitHubWrite or GitCommand). Limit of the rule: it cannot find a run through the
# short form run(_:_:timeout:) of a CommandRunner.
REVIEWS_PROCESS_RULES = [
    ("reviews-process", re.compile(r"\bCommand\s*(?:\(|\.\s*init\b|\??\s*=\s*\.\s*init\b)")),
]
REVIEWS_PROCESS_FILES = (
    os.path.join("Bifrost", "Sources", "BifrostReviews", "Services", "GitHub", "GHRunner.swift"),
    os.path.join("Bifrost", "Sources", "BifrostReviews", "Services", "Git", "RepoGit.swift"),
)

# trust-run (code): the check of a trust run (claude with no arguments in a review clone, through
# PTYManager.openTrust). Only the Reviews module and the tests call it, so no other part of the
# app can start claude in a folder of its choice. The rule finds a call that spans lines. Limit of
# the rule: it cannot find a call through a function value (let f = TrustRuns.check).
TRUST_RUN = re.compile(r"\bTrustRuns\s*\.\s*check\s*\(")

TYPE_NAME = re.compile(r"\b(?:struct|class|enum|actor|protocol|typealias)\s+(\w+)")

# The words of a name: "EventLoopRunner" gives Event, Loop and Runner. "JSONValue" gives JSON
# and Value. "js-runtime" gives js and runtime.
NAME_WORD = re.compile(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|\d+")
JS_WORDS = {
    "js", "javascript", "promise", "promises", "microtask", "microtasks", "eventloop",
    "insertionorder", "ordereddict", "orderedset",
}
JS_WORD_PAIRS = {
    ("event", "loop"), ("insertion", "order"), ("ordered", "dict"), ("ordered", "dictionary"),
    ("ordered", "set"),
}


def says_javascript(name):
    """True when a type name or a file name says that it copies a JavaScript mechanism."""
    words = [word.lower() for word in NAME_WORD.findall(name)]
    if any(word in JS_WORDS for word in words):
        return True
    return any(pair in JS_WORD_PAIRS for pair in zip(words, words[1:]))


# A bare regex literal (/.../) starts only where an expression starts: after one of these
# characters, after one of these keywords, or at the start of the code of the line.
REGEX_BEFORE = set("([{,=:;!&|?+-*<>^~%")
REGEX_KEYWORDS = {
    "return", "try", "await", "case", "in", "if", "guard", "while", "throw", "else", "where",
}
LAST_WORD = re.compile(r"\b(\w+)$")

# The character of an escape in a string literal, for the text of the literal. Each other escape
# gives the character after the backslash. \u{...} gives its code point (unicode_escape).
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0"}


def unicode_escape(digits):
    """Return the character of the hex digits of a \\u{...} escape, or "" for a bad escape."""
    try:
        return chr(int(digits, 16))
    except (ValueError, OverflowError):
        return ""


def bare_regex_end(line, i, code):
    """Return the index after the bare regex literal that starts at line[i], else None.

    The "/" at i starts a bare regex literal only where an expression starts (REGEX_BEFORE and
    REGEX_KEYWORDS). As in Swift, the literal does not start or end with a space or a tab, and
    it ends on the same line. In each other case, the "/" is a division.
    """
    if i + 1 >= len(line) or line[i + 1] in " \t":
        return None
    before = "".join(code).rstrip()
    if before and before[-1] not in REGEX_BEFORE:
        word = LAST_WORD.search(before)
        if not word or word.group(1) not in REGEX_KEYWORDS:
            return None
    j = i + 1
    while j < len(line):
        if line[j] == "\\":
            j += 2
        elif line[j] == "/":
            return None if line[j - 1] in " \t" else j + 1
        else:
            j += 1
    return None


def split_line(line, state):
    """Return the code of one line: the line with no comments, no string text and no regex text.

    The code inside a string interpolation stays as code, also when it holds nested strings.
    `state` is a dict that holds the open block comment and the open strings.

    A string or a regex literal on the stack is a tuple (kind, hashes). The kinds are "s" (a
    string on one line), "m" (a multi-line string), "r" (a regex literal on one line) and "R" (a
    multi-line regex literal: #/ at the end of a line). hashes is the number of "#" of a raw
    string (#"..."#) or of an extended regex literal (#/.../#). In a raw string, only a backslash
    with the same number of "#" starts an escape or an interpolation, and only a quote with that
    number of "#" ends the string. A regex literal has no interpolation, a backslash escapes the
    next character, and only a "/" with the same number of "#" ends it. An open interpolation is
    a list with the depth of its parentheses.

    Limit: a bare regex literal (/.../) and a division look the same. The splitter reads a "/"
    as the start of a bare regex literal only where an expression starts (bare_regex_end), so it
    can read some divisions as regex text, for example a division at the start of a line.

    When `state` holds the key "texts", the splitter also collects the text of each string
    literal (string_literals): "texts" holds one open text for each tuple on the stack, and each
    string that ends goes to state["literals"] as (line number of its start, text). The code of
    an interpolation is not a part of the text, and an escape gives the character that it makes
    (\\n gives a line break, \\u{6D} gives "m"). A backslash at the end of a line of a
    multi-line string joins the next line, with no line break and with no indent of that line.
    """
    stack = state["stack"]
    texts = state.get("texts")
    code = []
    i = 0
    n = len(line)
    # The line after a joined line of a multi-line string: its indent is no part of the text.
    joined = state.pop("joined", False)
    if joined and stack and isinstance(stack[-1], tuple) and stack[-1][0] == "m":
        while i < n and line[i] in " \t":
            i += 1

    def open_text(kind):
        if texts is not None:
            texts.append((kind, [], state["line"]))

    def close_text():
        if texts is not None:
            kind, chars, start = texts.pop()
            if kind in ("s", "m"):
                state["literals"].append((start, "".join(chars)))

    def add_text(char):
        if texts is not None:
            texts[-1][1].append(char)

    while i < n:
        top = stack[-1] if stack else None
        if state["block"]:
            end = line.find("*/", i)
            if end < 0:
                break
            i = end + 2
            state["block"] = False
        elif isinstance(top, tuple) and top[0] in ("r", "R"):
            close = "/" + "#" * top[1]
            if line[i] == "\\":
                i += 2
            elif line.startswith(close, i):
                stack.pop()
                close_text()
                code.append("//")
                i += len(close)
            else:
                i += 1
        elif isinstance(top, tuple):
            kind, hashes = top
            delimiter = "#" * hashes
            close = ('"""' if kind == "m" else '"') + delimiter
            if line.startswith("\\" + delimiter + "(", i):
                stack.append([1])
                code.append("(")
                i += 2 + hashes
            elif line.startswith("\\" + delimiter, i):
                at = i + 1 + hashes
                escaped = line[at : at + 1]
                brace = line.find("}", at + 2) if line.startswith("u{", at) else -1
                if brace > 0:
                    add_text(unicode_escape(line[at + 2 : brace]))
                    i = brace + 1
                else:
                    # A backslash at the end of a line of a multi-line string joins the next
                    # line, with no line break.
                    if escaped == "" and kind == "m":
                        state["joined"] = True
                    add_text(ESCAPES.get(escaped, escaped))
                    i = at + 1
            elif line.startswith(close, i):
                stack.pop()
                close_text()
                code.append('""')
                i += len(close)
            else:
                add_text(line[i])
                i += 1
        elif line.startswith("//", i):
            break
        elif line.startswith("/*", i):
            state["block"] = True
            i += 2
        elif line[i] in "#\"":
            # A string opens with a quote, or with a run of "#" and a quote (a raw string). An
            # extended regex literal opens with a run of "#" and a "/". Another "#" is code, for
            # example #selector or #if.
            hashes = len(line[i:]) - len(line[i:].lstrip("#"))
            at = i + hashes
            if line.startswith('"""', at):
                stack.append(("m", hashes))
                open_text("m")
                i = at + 3
            elif line.startswith('"', at):
                stack.append(("s", hashes))
                open_text("s")
                i = at + 1
            elif hashes and line.startswith("/", at):
                stack.append(("R" if line[at + 1:].strip() == "" else "r", hashes))
                open_text("r")
                i = at + 1
            else:
                code.append(line[i])
                i += 1
        elif line[i] == "/" and (end := bare_regex_end(line, i, code)) is not None:
            code.append("//")
            i = end
        else:
            if top is not None:
                if line[i] == "(":
                    top[0] += 1
                elif line[i] == ")":
                    top[0] -= 1
                    if top[0] == 0:
                        stack.pop()
            code.append(line[i])
            i += 1
    # A string or a regex literal on one line cannot continue on the next line. Its text ends
    # here. A multi-line string gets the line break.
    for depth, entry in enumerate(stack):
        if isinstance(entry, tuple) and entry[0] in ("s", "r"):
            for _ in range(sum(isinstance(e, tuple) for e in stack[depth:])):
                close_text()
            del stack[depth:]
            break
    last = len(texts or []) - 1
    for index, (kind, chars, _) in enumerate(texts or []):
        if kind == "m" and not (index == last and state.get("joined")):
            chars.append("\n")
    return "".join(code)


def line_rules(code, rules, all_rules):
    """Return the rules that one line breaks, each one time, in a fixed order."""
    found = [rule for rule, pattern in rules if pattern.search(code)]
    if all_rules and any(says_javascript(name) for name in TYPE_NAME.findall(code)):
        found.append("js-mechanics")
    return list(dict.fromkeys(found))


def check_text(text, rules=RULES, all_rules=True):
    """Yield (line number, rule, source line) for each finding.

    With all_rules False, only the regular expressions of rules apply (for a test folder).
    """
    state = {"block": False, "stack": []}
    for number, raw in enumerate(text.splitlines(), start=1):
        code = split_line(raw, state)
        for rule in line_rules(code, rules, all_rules):
            yield number, rule, raw.strip()


def check_spanning(text, rule):
    """Yield (line number, rule, source line) for each match of a rule that can span lines.

    The match runs on the code of the whole file: the lines with no comments, no string text and
    no regex text (split_line), joined with line breaks. The line of a match is its first line. A
    match with the group "declaration" is a declaration, not a finding.
    """
    name, pattern = rule
    state = {"block": False, "stack": []}
    lines = text.splitlines()
    code = "\n".join(split_line(raw, state) for raw in lines)
    for match in pattern.finditer(code):
        if match.groupdict().get("declaration"):
            continue
        number = code.count("\n", 0, match.start()) + 1
        yield number, name, lines[number - 1].strip()


def string_literals(text):
    """Return (line number, text) for each string literal of a file, in their order.

    The line number is the line where the literal starts. Comments, code and regex literals give
    no text (split_line).
    """
    state = {"block": False, "stack": [], "texts": [], "literals": [], "line": 0}
    for number, raw in enumerate(text.splitlines(), start=1):
        state["line"] = number
        split_line(raw, state)
    return state["literals"]


def string_rules(relative, package):
    """Return the rules of string text of one file that is not a test: a list of (name, test)."""
    if not package or not relative.startswith(REVIEWS_SOURCES):
        return []
    rules = [("github-never", lambda text: GITHUB_NEVER.search(text) is not None)]
    if relative not in GITHUB_WRITE_FILES:
        rules.append(("github-write", lambda text: GITHUB_WRITE.search(text) is not None))
    if relative.startswith(GIT_PUSH_FOLDERS) and relative not in GITHUB_WRITE_FILES:
        rules.append(
            (
                "github-write",
                lambda text: text in GITHUB_WRITE_FLAGS
                or text.startswith(GITHUB_WRITE_FLAG_STARTS)
                or GITHUB_WRITE_SHORT_FIELD.match(text) is not None,
            )
        )
    if relative.startswith(GIT_PUSH_FOLDERS):
        rules.append(
            (
                "git-push",
                lambda text: (text == "push" and relative != GIT_PUSH_FILE)
                or text.startswith(GIT_PUSH_STARTS)
                or text in GIT_PUSH_NEVER,
            )
        )
    return rules


def check_strings(text, rules):
    """Yield (line number, rule, source line) for each string literal that breaks a rule, one time
    for each line and rule."""
    if not rules:
        return
    lines = text.splitlines()
    found = []
    for number, literal in string_literals(text):
        found += [(number, name) for name, test in rules if test(literal)]
    for number, name in dict.fromkeys(found):
        yield number, name, lines[number - 1].strip()


def spawn_allowed(relative, package, owner):
    """True when a file that is not a test can use a form of the pty-spawn rule: the one file of
    the form (owner) and the test support module of a package."""
    return package and (relative == owner or relative.startswith(PTY_SPAWN_FOLDER + os.sep))


def is_test(path):
    return any(part.endswith("Tests") for part in path.split(os.sep))


def swift_files(root):
    """Yield (path, is a test file) for each Swift file below root. No .build folder."""
    for folder, names, files in os.walk(root):
        names[:] = sorted(d for d in names if d != ".build")
        for name in sorted(files):
            path = os.path.join(folder, name)
            if name.endswith(".swift"):
                yield path, is_test(os.path.relpath(path, root))


def layer_of(relative):
    """Return (kind, layer) for a file in a module folder of a package, else (None, None).

    kind is "Sources" or "Tests". The path is <package>/<kind>/<module>/<layer>/...
    """
    parts = relative.split(os.sep)
    if len(parts) < 5 or parts[1] not in ("Sources", "Tests"):
        return None, None
    return parts[1], parts[3]


def outside_layer(relative):
    """True when a Swift file of a module folder of a package is in no layer folder.

    Each Swift file below <package>/Sources/<module>/ (except the test support module) and
    below <package>/Tests/<module>Tests/ must be in a folder Model, Services or UI. Else the
    layer rules cannot apply to it.
    """
    parts = relative.split(os.sep)
    if len(parts) < 4 or parts[1] not in ("Sources", "Tests"):
        return False
    if parts[1] == "Sources" and parts[2] == TEST_SUPPORT:
        return False
    return len(parts) < 5 or parts[3] not in LAYERS


def file_rules(relative, package, test):
    """Return the regular expression rules of one file, from its path below the root."""
    rules = [] if test else list(RULES)
    if package:
        rules += PACKAGE_RULES
        if test:
            rules += TEST_TEMP_RULES
        kind, layer = layer_of(relative)
        if layer in UI_IMPORT_LAYERS:
            rules += UI_IMPORT_RULES
        if kind == "Sources" and layer == MODEL_LAYER:
            rules += MODEL_RULES
    if not test and not (package and relative == PRIVATE_API_FILE):
        rules += PRIVATE_API_RULES
    if not test and not (package and relative in SHARED_STATE_FILES):
        rules += SHARED_STATE_RULES
    if not (package and relative in KEYCHAIN_FILES):
        rules += KEYCHAIN_RULES
    if (
        not test
        and package
        and relative.startswith(REVIEWS_MODULE)
        and relative not in REVIEWS_PROCESS_FILES
    ):
        rules += REVIEWS_PROCESS_RULES
    return rules


def main(roots):
    for root in roots:
        if not os.path.isdir(root):
            print(f"error: not a folder: {root}", file=sys.stderr)
            return 2
    found = 0
    for root in roots:
        package = os.path.basename(os.path.abspath(root)) == "Packages"
        for path, test in swift_files(root):
            if test and not package:
                continue
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            relative = os.path.relpath(path, root)
            rules = file_rules(relative, package, test)
            findings = list(check_text(text, rules, all_rules=not test))
            if not test:
                for pattern, owner in PTY_SPAWN_FORMS:
                    if not spawn_allowed(relative, package, owner):
                        findings += check_spanning(text, (PTY_SPAWN, pattern))
                findings += check_strings(text, string_rules(relative, package))
                if not (package and relative.startswith(REVIEWS_UI)):
                    findings += dict.fromkeys(check_spanning(text, ("user-click", USER_CLICK)))
                if not (package and relative.startswith(REVIEWS_MODULE)):
                    findings += check_spanning(text, ("trust-run", TRUST_RUN))
            for number, rule, source in findings:
                print(f"{path}:{number}: {rule}: {source}")
                found += 1
            if package and outside_layer(os.path.relpath(path, root)):
                print(f"{path}: layer-folder: not in a folder Model, Services or UI")
                found += 1
            name = os.path.basename(path)[: -len(".swift")]
            if not test and says_javascript(name):
                print(f"{path}: js-file-name: {name}")
                found += 1
    if found:
        return 1
    print("no forbidden constructs")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: check_forbidden.py <root>...", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
