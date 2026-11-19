import Darwin
import Foundation
import Testing

@testable import BifrostSessions

// The edge cases of the small rules of the registry. Each case is a short input with its result.
// The cases come from the real edge cases of the rules: hidden characters, the length limit,
// the forms of an ID, the shape of a worktree path, the forms of a HEAD file and of a model ID.

// MARK: - Local names

enum AliasResult: Equatable, CustomStringConvertible {
    case name(String)
    case refused(AliasRefusal)

    var description: String {
        switch self {
        case .name(let text): "name \(text.debugDescription)"
        case .refused(let reason): "refused \(reason)"
        }
    }
}

private func aliasResult(_ text: String) -> AliasResult {
    do throws(AliasRefusal) {
        return .name(try cleanAlias(text))
    } catch {
        return .refused(error)
    }
}

@Suite("the local name of a session")
struct LocalNameEdgeTests {
    @Test(
        "a name is trimmed and kept",
        arguments: [
            ("Work", "Work"),
            (" Work ", "Work"),
            ("\t Work \n", "Work"),
            ("a b", "a b"),
            ("é", "é"),
            ("😀", "😀"),
            // White space goes at the edges and stays inside. TextRuleTests checks each white
            // space Character at the edges.
            ("a\u{A0}b", "a\u{A0}b"),
            // An empty name is valid: it means no local name.
            ("", ""),
            ("   ", ""),
            ("\u{3000}\u{A0}", ""),
        ])
    func kept(text: String, expected: String) {
        #expect(aliasResult(text) == .name(expected))
    }

    @Test(
        "a control or hidden character inside a name refuses the name",
        arguments: [
            "a\u{0}b", "a\u{1B}b", "a\tb", "a\nb", "a\rb", "a\u{1F}b",
            "a\u{7F}b", "a\u{80}b", "a\u{9F}b", "\u{1B}" + String(repeating: "x", count: 70),
            // Zero-width characters: U+200B to U+200F.
            "a\u{200B}b", "a\u{200C}b", "a\u{200D}b", "a\u{200E}b", "a\u{200F}b",
            // The bidi controls: U+202A to U+202E and U+2066 to U+2069.
            "a\u{202A}b", "a\u{202B}b", "a\u{202C}b", "a\u{202D}b", "a\u{202E}b",
            "a\u{2066}b", "a\u{2067}b", "a\u{2068}b", "a\u{2069}b",
            // The Arabic letter mark, a bidi control.
            "a\u{061C}b",
            "a\u{FEFF}b",
        ])
    func hidden(text: String) {
        #expect(aliasResult(text) == .refused(.control))
    }

    // U+200B and U+FEFF are not white space for the trim. A trim that removes them would accept
    // the name (a bug of the port that the first checks missed).
    @Test(
        arguments: [
            "\u{200B}Work", "Work\u{200B}", "\u{200B}", "\u{FEFF}Work", "\u{202E}Work",
            "Work\u{2066}",
        ])
    func hiddenAtTheEdge(text: String) {
        #expect(aliasResult(text) == .refused(.control))
    }

    // The limit of 64 Characters counts after the trim. TextRuleTests checks the limit with
    // emoji and combined letters.
    @Test func theLimitCountsAfterTheTrim() {
        let x64 = String(repeating: "x", count: 64)
        #expect(aliasResult(" \(x64) ") == .name(x64))
        #expect(aliasResult(x64 + "x") == .refused(.tooLong))
    }

    @Test
    func hiddenBeforeLength() {
        #expect(aliasResult(String(repeating: "x", count: 70) + "\u{200B}x") == .refused(.control))
    }
}


// MARK: - Worktrees

private func root(_ worktree: String, _ repo: String) -> WorktreeRoot {
    WorktreeRoot(worktree: worktree, repo: repo)
}

@Suite("worktree paths")
struct WorktreePathEdgeTests {
    @Test(
        "a folder in the worktrees folder gives the root, also from a subfolder",
        arguments: [
            ("/r/.claude/worktrees/w1", root("/r/.claude/worktrees/w1", "/r")),
            ("/r/.claude/worktrees/w1/", root("/r/.claude/worktrees/w1", "/r")),
            ("/r/.claude/worktrees/w1/src", root("/r/.claude/worktrees/w1", "/r")),
            ("/r/.claude/worktrees/w1/src/a b", root("/r/.claude/worktrees/w1", "/r")),
            ("/a b/.claude/worktrees/n/src", root("/a b/.claude/worktrees/n", "/a b")),
            ("/é/x/.claude/worktrees/n", root("/é/x/.claude/worktrees/n", "/é/x")),
            ("/.claude/.claude/worktrees/n", root("/.claude/.claude/worktrees/n", "/.claude")),
            // The first mark gives the repo, so a worktree name can be "worktrees".
            ("//r/.claude/worktrees/worktrees", root("//r/.claude/worktrees/worktrees", "//r")),
            (
                "/r/worktrees/.claude/worktrees/n",
                root("/r/worktrees/.claude/worktrees/n", "/r/worktrees")
            ),
            ("/r//x/.claude/worktrees/n", root("/r//x/.claude/worktrees/n", "/r//x")),
        ])
    func found(cwd: String, expected: WorktreeRoot) {
        #expect(WorktreeRoot(cwd: cwd) == expected)
    }

    @Test(
        "a path that is not in a worktree gives nothing",
        arguments: [
            "", "/", "/r", "/r/w1", "/r/src", "/.claude/worktrees/n", "/.claude/worktrees/n/",
            // No name after the mark.
            "/r/.claude/worktrees", "/r/.claude/worktrees/", "/w1//.claude/worktrees/",
            // A relative path.
            "r/.claude/worktrees/n", ".claude/worktrees/n", "worktrees", "a b",
            // A "." or ".." segment, also when the rest is a worktree.
            "/r/../.claude/worktrees/n", "/é/../.claude/worktrees/n/src",
            "/r/./.claude/worktrees/n", "/r/.claude/worktrees/n/..", "/r/.claude/worktrees/..",
            "/../r/../w2", "/.",
        ])
    func notFound(cwd: String) {
        #expect(WorktreeRoot(cwd: cwd) == nil)
    }

    @Test func theRepoPathRemovesTheTrailingSlashesAndTheWorktreeTail() {
        #expect(repoPath("/a/b///") == "/a/b")
        #expect(repoPath("/a/.claude/worktrees/x/") == "/a")
        #expect(repoPath("/a/.claude/worktrees/x/.claude/worktrees/y") == "/a")
        // A worktree path needs a worktree name.
        #expect(repoPath("/a/.claude/worktrees/") == "/a/.claude/worktrees")
        #expect(repoPath("/a/.claude/worktree/x") == "/a/.claude/worktree/x")
        // A line break in the part after the worktree name keeps the whole path, and a line
        // break in the worktree name does not.
        #expect(repoPath("/a/.claude/worktrees/x/b\nc") == "/a/.claude/worktrees/x/b\nc")
        #expect(repoPath("/a/.claude/worktrees/x\ny") == "/a")
        #expect(repoPath("/") == "")
    }

    @Test(arguments: [
            // (cwd, stored worktree, result)
            ("/r/.claude/worktrees/w1/src", nil, "/r/.claude/worktrees/w1"),
            ("/r/.claude/worktrees/w1", "/r/.claude/worktrees/w2", "/r/.claude/worktrees/w1"),
            ("/p", "/r/.claude/worktrees/w2", "/r/.claude/worktrees/w2"),
            ("", "/r/.claude/worktrees/w2/src", "/r/.claude/worktrees/w2"),
            ("/p", nil, nil),
            ("/p", "", nil),
            ("/p", "/r", nil),
            ("/p", "/r/.claude/worktrees/", nil),
            ("/p", "r/.claude/worktrees/w2", nil),
            ("/p", "/r/../.claude/worktrees/w2", nil),
        ] as [(String, String?, String?)])
    func ofARow(cwd: String, stored: String?, expected: String?) {
        #expect(WorktreeRoot(cwd: cwd, stored: stored)?.worktree == expected)
    }
}

// MARK: - Paths

@Suite("paths")
struct PathEdgeTests {
    private let base = "/tmp/work"

    @Test(
        "a path resolves to an absolute normal form",
        arguments: [
            ("/a/b", "/a/b"), ("/a//b", "/a/b"), ("/a/./b", "/a/b"), ("/a/b/..", "/a"),
            ("/a/b/../../..", "/"), ("/a/b/", "/a/b"), ("/", "/"), ("a", "/tmp/work/a"),
            ("a/../b", "/tmp/work/b"), ("..", "/tmp"), (".", "/tmp/work"), ("", "/tmp/work"),
            ("/a b/é", "/a b/é"),
        ])
    func resolve(path: String, expected: String) {
        #expect(resolvePath(path, from: base) == expected)
    }

    @Test(
        "a path is inside a root when it is below the root and not the root itself",
        arguments: [
            ("/a", "/a/b", true), ("/a", "/a/b/c", true), ("/a/", "/a/b", true),
            ("/a", "/a", false), ("/a", "/a/", false), ("/a", "/a/b/..", false),
            ("/a", "/ab", false), ("/a/b", "/a", false), ("/a", "/b", false),
            ("/a", "/a/../b", false), ("/a", "/a/b/../c", true), ("/", "/a", true),
            ("a", "a/b", true), ("a", "/tmp/work/a/b", true), ("/a", "a", false),
            ("/tmp/work", "x", true),
        ])
    func inside(root: String, path: String, expected: Bool) {
        #expect(isInside(root: root, path: path, base: base) == expected)
    }
}

// MARK: - Polls

@Suite("the poll interval")
struct PollIntervalEdgeTests {
    @Test(
        "a visible window keeps the interval",
        arguments: [0, 1000, 2000, 14_999, 15_000, 15_001, 30_000])
    func visible(ms: Int) {
        #expect(RegistryTiming.pollInterval(.milliseconds(ms), visible: true) == .milliseconds(ms))
    }

    @Test(
        "a window that is not visible waits at least 15 s",
        arguments: [
            (0, 15_000), (1000, 15_000), (2000, 15_000), (14_999, 15_000), (15_000, 15_000),
            (15_001, 15_001), (30_000, 30_000),
        ])
    func hidden(ms: Int, expected: Int) {
        #expect(
            RegistryTiming.pollInterval(.milliseconds(ms), visible: false)
                == .milliseconds(expected))
    }
}

// MARK: - Model names

@Suite("the display name of a model")
struct ModelNameEdgeTests {
    @Test(
        "a model ID of a known family shows as a name",
        arguments: [
            ("claude-opus-5-5", "Opus 5.5"), ("claude-opus-4-7", "Opus 4.7"),
            ("claude-sonnet-4", "Sonnet 4"), ("claude-haiku-5", "Haiku 5"),
            ("claude-fable-5-1", "Fable 5.1"), ("claude-opus-10", "Opus 10"),
            ("claude-opus-4-12", "Opus 4.12"),
            ("claude-opus-4-7[1m]", "Opus 4.7 (1M context)"),
            ("claude-sonnet-4[1m]", "Sonnet 4 (1M context)"),
            // A date of 8 digits at the end goes.
            ("claude-haiku-4-5-20251001", "Haiku 4.5"),
            ("claude-opus-4-20250514", "Opus 4"),
            ("claude-opus-4-20250514[1m]", "Opus 4 (1M context)"),
            ("claude-opus-4-1-20250514[1m]", "Opus 4.1 (1M context)"),
        ])
    func known(id: String, expected: String) {
        #expect(modelName(id) == expected)
    }

    @Test(
        "an ID of another form stays as it is",
        arguments: [
            "", "gpt", "claude-gpt-4", "claude-opus", "claude-opus-", "claude-opus5",
            "Claude-opus-5-5", "claude-Opus-5-5", "x-claude-opus-5-5", "claude-opus-5-5 ",
            "claude-opus-5-5\n", "claude-opus-5-5\r",
            // A minor version has 1 or 2 digits, a date has 8.
            "claude-opus-5-123", "claude-opus-5-2025051", "claude-opus-5-202505141",
            "claude-opus-5-5-2025051", "claude-opus-5a", "claude-opus-5-5a",
            // The bracket is [1m] in lower case only.
            "claude-opus-5-5[1M]", "claude-opus-5-5[2m]", "claude-opus-5-5[1m] ",
            "claude-opus-5-5[1m]x",
            // The digits are ASCII digits only.
            "claude-opus-\u{663}", "claude-opus-4-\u{663}", "claude-opus-\u{663}-1",
            "claude-opus_5-1", "claude-opus--5",
        ])
    func other(id: String) {
        #expect(modelName(id) == id)
    }
}

// MARK: - HEAD files and .git files

@Suite("a HEAD file")
struct HeadFileEdgeTests {
    private static let hash40 = String(repeating: "c", count: 40)
    private static let hash64 = String(repeating: "d", count: 64)

    @Test(
        "a branch ref gives its name",
        arguments: [
            ("ref: refs/heads/main\n", "main"), ("ref: refs/heads/main", "main"),
            (" ref: refs/heads/main \n", "main"), ("\nref: refs/heads/main\n", "main"),
            ("ref: refs/heads/main\r\n", "main"), ("ref: refs/heads/feat/a\n", "feat/a"),
            ("ref: refs/heads/v1", "v1"),
            // The trim is for the whole text. A space after the prefix is part of the name.
            ("ref: refs/heads/ spaced \n", " spaced"),
        ])
    func branch(text: String, expected: String) {
        #expect(branchOfHead(text) == expected)
    }

    @Test(
        "a full hash gives HEAD",
        arguments: [
            hash40, hash40 + "\n", " " + hash40, hash40.uppercased() + "\r\n", hash64,
            hash64 + "\n",
            hash64.uppercased(),
        ])
    func detached(text: String) {
        #expect(branchOfHead(text) == "HEAD")
    }

    @Test(
        "other text gives nothing and git decides",
        arguments: [
            "", " ", "\n", "  \n", "junk", "ref: refs/remotes/origin/x", "ref: refs/remotes/y\n",
            "ref: refs/heads/", "ref: refs/heads/\n", "ref: refs/heads/a\nb",
            "ref: refs/heads/x\u{2028}y",
            "ref:refs/heads/main", "refs/heads/main",
            // A hash that is too short, too long or not hex.
            String(repeating: "c", count: 39), String(repeating: "c", count: 41),
            String(repeating: "c", count: 63), String(repeating: "c", count: 65),
            String(repeating: "g", count: 40),
        ])
    func other(text: String) {
        #expect(branchOfHead(text) == nil)
    }
}

@Suite("a .git file")
struct GitdirFileEdgeTests {
    @Test(
        "the path is the rest of the first gitdir line, trimmed",
        arguments: [
            ("gitdir: /abs/x\n", "/abs/x"), ("gitdir: /abs/x", "/abs/x"),
            ("gitdir:/abs/x", "/abs/x"), ("gitdir:\t/abs/x\t\n", "/abs/x"),
            ("gitdir:   ../r/.git/worktrees/w\r\n", "../r/.git/worktrees/w"),
            ("gitdir: /abs/x\ngitdir: /other\n", "/abs/x"),
            ("junk\ngitdir: /abs/x\n", "/abs/x"),
            ("gitdir: /a b/c  \n", "/a b/c"),
            // Each newline character ends a line: CR, NEL, U+2028 and U+2029.
            ("junk\rgitdir: /abs/x", "/abs/x"),
            ("gitdir: /abs/x\u{2028}gitdir: /o", "/abs/x"),
            ("gitdir: /abs/x\u{2029}gitdir: /o", "/abs/x"),
            ("gitdir: /abs/x\u{85}gitdir: /o", "/abs/x"),
            ("junk\u{2028}gitdir: /abs/x\u{85}", "/abs/x"),
        ])
    func path(text: String, expected: String) {
        #expect(gitdirOf(text) == expected)
    }

    @Test(
        "a file with no path on its gitdir line gives nothing and git decides",
        arguments: [
            "", "\n", "junk", "x gitdir: /no", " gitdir: /no", "GITDIR: /no", "gitdir", "gitdir:",
            "gitdir:\n", "gitdir:   \n", "gitdir: \t \r\n", "gitdir:\n/next", "gitdir:\r\n/next",
            "gitdir: \n gitdir: /later",
            "gitdir:\r/next", "gitdir:\u{2028}/next", "gitdir:\u{2029}/next", "gitdir:\u{85}/next",
        ])
    func none(text: String) {
        #expect(gitdirOf(text) == nil)
    }
}

// MARK: - The terminal app

@Suite("the terminal app of a process")
struct TerminalAppEdgeTests {
    private static let warp = TerminalApp(name: "Warp", bundle: "/Applications/Warp.app")
    private static let table: ProcessTable = [
        2: ProcessEntry(ppid: 1, comm: "/Applications/Warp.app/Contents/MacOS/stable"),
        3: ProcessEntry(ppid: 2, comm: "-zsh"),
        4: ProcessEntry(ppid: 3, comm: "claude"),
        5: ProcessEntry(ppid: 9, comm: "claude"),
        6: ProcessEntry(ppid: 6, comm: "claude"),
        7: ProcessEntry(ppid: 8, comm: "a"),
        8: ProcessEntry(ppid: 7, comm: "b"),
        10: ProcessEntry(ppid: 1, comm: "a.app"),
        11: ProcessEntry(ppid: 1, comm: ".app/"),
        12: ProcessEntry(ppid: 1, comm: "/A/x.app/"),
        13: ProcessEntry(ppid: 1, comm: "/B.app/C.app/D"),
        14: ProcessEntry(ppid: 0, comm: "/Applications/Warp.app/x"),
        15: ProcessEntry(ppid: 14, comm: "claude"),
        16: ProcessEntry(ppid: -1, comm: "claude"),
    ]

    @Test(
        "the walk gives the first app of the parent chain",
        arguments: [
            (pid_t(4), TerminalApp?.some(warp)), (3, .some(warp)), (2, .some(warp)),
            (12, .some(TerminalApp(name: "x", bundle: "/A/x.app"))),
            // The first process in an app bundle gives the app, so the outer one wins.
            (13, .some(TerminalApp(name: "B", bundle: "/B.app"))),
            (11, .some(TerminalApp(name: "", bundle: ".app"))),
            (15, .some(warp)),
        ])
    func found(pid: pid_t, expected: TerminalApp?) {
        #expect(Self.table.terminalApp(of: pid) == expected)
    }

    @Test(
        "the walk gives nothing with no app, a missing PID, PID 1 or less, or a loop",
        arguments: [
            pid_t(5),  // the parent is not in the table
            6,  // a process that is its own parent
            7,  // a loop of two processes
            10,  // ".app" with no slash after it is not a bundle
            16,  // a negative parent PID
            1, 0, -1, 99,
        ])
    func notFound(pid: pid_t) {
        #expect(Self.table.terminalApp(of: pid) == nil)
    }

    @Test("the walk stops after 64 processes")
    func steps() {
        // A chain from PID 2 to PID 200 with the app at the top. The 64th process is PID 137.
        var chain: ProcessTable = [200: ProcessEntry(ppid: 1, comm: "/Applications/Warp.app/x")]
        for pid: pid_t in 2..<200 { chain[pid] = ProcessEntry(ppid: pid + 1, comm: "sh") }
        #expect(chain.terminalApp(of: 137) == Self.warp)
        #expect(chain.terminalApp(of: 136) == nil)
    }
}

// MARK: - The wall time

@Suite("the wall time in milliseconds")
struct WallTimeEdgeTests {
    // A part of a millisecond goes, also near the next millisecond and before 1970.
    @Test(
        arguments: [(1.0, 1000), (1.0009, 1000), (1.9999, 1999), (0, 0), (-0.0005, -1)]
            as [(Double, Int)])
    func theMillisecondsRoundDown(seconds: Double, expected: Int) {
        #expect(Date(timeIntervalSince1970: seconds).millisecondsSince1970 == expected)
    }
}

// The one clean of each text from the Live details mod and from the session list.
@Suite("the clean of the texts from other programs")
struct ForeignTextCleanTests {
    @Test(
        "each unsafe character goes",
        arguments: [
            "\u{1B}[31mred", "a\u{85}b", "a\u{9F}b", "a\u{200E}b", "a\u{200F}b", "a\u{061C}b",
            "a\u{2028}b", "a\u{2029}b", "a\u{202E}b", "a\u{2066}b", "a\u{7F}b", "a\tb\nc",
            "a\u{200B}b", "a\u{2060}b", "a\u{2064}b", "a\u{FEFF}b", "a\u{AD}b", "a\u{180E}b",
            "a\u{206A}b", "a\u{206F}b", "a\u{FFF9}b", "a\u{FFFB}b", "a\u{E0001}b", "a\u{E007F}b",
            "a\u{115F}b", "a\u{1160}b", "a\u{3164}b", "a\u{FFA0}b", "a\u{034F}b", "a\u{17B4}b",
            "a\u{17B5}b", "a\u{2065}b", "a\u{1BCA0}b", "a\u{1BCA3}b", "a\u{1D173}b",
            "a\u{1D17A}b",
        ])
    func hidden(text: String) {
        let clean = cleanText(text)
        #expect(!hasUnsafeCharacter(clean))
        #expect(clean.unicodeScalars.count < text.unicodeScalars.count)
    }

    @Test func theLinesOfAnAnswerKeepTheirTabsAndLineBreaks() {
        #expect(cleanText("a\tb\nc\u{202E}d\r", lines: true) == "a\tb\ncd")
        #expect(cleanText("a\tb\nc") == "abc")
    }

    @Test func aTextWithNoHiddenCharacterStaysAsItIs() {
        // The joiners and the variation selectors stay: emoji and some scripts need them.
        let kept = [
            "", "Bash", "claude-opus-5-5", "日本語 ✓ 👩‍💻", "e\u{301}", "क्\u{200D}ष", "a\u{200C}b",
            "\u{2764}\u{FE0F}", "a\u{FE00}",
        ]
        for text in kept {
            #expect(cleanText(text) == text)
            #expect(!hasUnsafeCharacter(text))
        }
    }
}
