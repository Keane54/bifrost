// The git of a conflict round (docs/behaviour/reviews.md, "Merging the base branch"), with the real
// git on a local source that plays GitHub. The branch feat is the head branch of PR 7, and main is
// its base branch. Both change line 11 of src/a.swift after the first commit, so the merge of main
// into feat has a conflict there. Each test removes its repositories when it ends.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostReviews

// The 20 lines of src/a.swift, with the changed lines by number.
private func lines(_ changed: [Int: String] = [:]) -> String {
    (1...20).map { changed[$0] ?? "let line\($0) = \($0)" }.joined(separator: "\n") + "\n"
}

// The resolved src/a.swift.
private let resolved = lines([11: "let line11 = \"both\""])

// A config file that has a line of 7 "=" before its value lines.
private func table(_ value: String) -> String { "[a]\n=======\n\(value)\ny = 2\n" }

// The source and the clone of a conflict round: feat and main each have one new commit with the
// files (a text writes a file, and nil deletes it), and the clone has both. before: a step before
// each run of Bifrost's git (PushTestRepo).
private struct ConflictRepo {
    let f: PushTestRepo
    let head: CommitID
    let base: CommitID

    static func make(
        files: [String: String] = [:], feat: [String: String?], main: [String: String?],
        before: @escaping @Sendable ([String]) async -> Void = { _ in }
    ) async throws -> ConflictRepo {
        let f = try await PushTestRepo.make(
            files: files.merging(["src/a.swift": lines()]) { $1 }, before: before)
        do {
            try await f.commit(on: "feat", feat)
            try await f.commit(on: "main", main)
            let head = try await f.fetch("feat", to: "refs/bifrost/pr/7")
            let base = try await f.fetch("main", to: "refs/bifrost/base/7")
            return ConflictRepo(f: f, head: head, base: base)
        } catch {
            f.remove()
            throw error
        }
    }

    // The usual conflict on line 11, and a new file of main that merges cleanly.
    static func lineEleven(before: @escaping @Sendable ([String]) async -> Void = { _ in })
        async throws -> ConflictRepo
    {
        try await make(
            feat: ["src/a.swift": lines([11: "let line11 = \"feat\""])],
            main: ["src/a.swift": lines([11: "let line11 = \"main\""]), "docs/b.md": "# Base\n"],
            before: before)
    }

    func remove() { f.remove() }

    func start() async throws(ConflictFailure) -> MergeStart {
        try await ConflictMerge.start(pr: f.pr, head: head, base: base, git: f.git)
    }

    func reset(to commit: CommitID) async throws {
        let reset = await f.git.run(.resetHard(commit), in: .worktree(f.pr))
        try #require(reset.succeeded, "reset: \(reset.stderr)")
    }

    func checkWorktree(_ start: MergeStart) async throws(ConflictFailure) {
        try await ConflictMerge.checkWorktree(pr: f.pr, start: start, git: f.git)
    }

    // The start, and the worktree at the merge with the markers after its check, as a conflict
    // round leaves it for Claude.
    func startInWorktree() async throws -> MergeStart {
        let start = try await start()
        try await reset(to: start.auto)
        try await checkWorktree(start)
        return start
    }

    // The commit, by default on the head and the base of the start.
    func commit(_ start: MergeStart, head: CommitID? = nil, base: CommitID? = nil) async throws
        -> CommitID
    {
        let message = ConflictMerge.message(base: "main", into: try #require(BranchName("feat")))
        return try await ConflictMerge.commit(
            pr: f.pr, start: start, head: head ?? self.head, base: base ?? self.base,
            message: message, git: f.git)
    }

    func write(_ path: String, _ text: String) throws {
        try f.repo.write(path, text, in: f.repo.worktree)
    }

    // The raw form of a commit, and the text of a file of it, with plain git in the clone. The
    // text has no white space at its ends.
    func object(_ commit: CommitID) async throws -> CommitObject {
        try #require(
            CommitObject(try await f.output(["cat-file", "commit", commit.hex], in: f.repo.clone)))
    }

    func file(_ path: String, of commit: CommitID) async throws -> String {
        try await f.output(["cat-file", "-p", "\(commit.hex):\(path)"], in: f.repo.clone)
    }
}

// True for a failure of git (the text is only for the Event log).
private func isGit(_ failure: ConflictFailure?) -> Bool {
    if case .git? = failure { true } else { false }
}

@Suite("the git of a conflict round", .serialized, .timeLimit(.minutes(3)), .tags(.realProcess))
struct ConflictMergeTests {
    // The merge of main into feat has a conflict on line 11. The auto commit holds the whole
    // merge, with the markers in src/a.swift and the new file of main, and its parents are the
    // head and the base.
    @Test func startGivesTheAutoMergeWithMarkersAndTheConflictedPaths() async throws {
        let r = try await ConflictRepo.lineEleven()
        defer { r.remove() }
        let start = try await r.start()
        #expect(start.conflicted == ["src/a.swift"])
        let object = try await r.object(start.auto)
        #expect(object.parents == [r.head, r.base] && !object.signed)
        #expect(object.message == ConflictMerge.autoMessage)
        let text = try await r.file("src/a.swift", of: start.auto)
        #expect(ConflictMarkers.found(in: Data(text.utf8)))
        #expect(text.contains("let line11 = \"feat\"") && text.contains("let line11 = \"main\""))
        #expect(try await r.file("docs/b.md", of: start.auto) == "# Base")
    }

    // feat and main change different lines: git merges them with no conflict, so nothing starts
    // and Bifrost makes no commit.
    @Test func aCleanMergeStartsNothing() async throws {
        let r = try await ConflictRepo.make(
            feat: ["src/a.swift": lines([2: "let two = 2"])],
            main: ["src/a.swift": lines([18: "let eighteen = 18"]), "docs/b.md": "# Base\n"])
        defer { r.remove() }
        await #expect(throws: ConflictFailure.noConflict) { _ = try await r.start() }
        #expect(!r.f.runner.all.contains { $0.contains("commit-tree") })
    }

    // Each branch merged the other one and kept its own side of c.txt, so the two branches have
    // two merge bases. A merge with one of them is clean. git merge and GitHub merge the two bases
    // first, and then c.txt has a conflict. The round finds the same conflict.
    @Test func aCrissCrossHistoryMergesLikeGit() async throws {
        let f = try await PushTestRepo.make(files: ["c.txt": "root\n"])
        defer { f.remove() }
        let feat = try await f.commit(on: "feat", ["c.txt": "feat\n"])
        let main = try await f.commit(on: "main", ["c.txt": "main\n"])
        let source = f.repo.source
        for (branch, ours, theirs) in [("feat", feat, main), ("main", main, feat)] {
            let tree = try await f.output(["rev-parse", "\(ours.hex)^{tree}"], in: source)
            let made = try await f.output(
                ["commit-tree", tree, "-p", ours.hex, "-p", theirs.hex, "-m", "merge"], in: source)
            try await f.output(["update-ref", "refs/heads/\(branch)", made], in: source)
        }
        let head = try await f.fetch("feat", to: "refs/bifrost/pr/7")
        let base = try await f.fetch("main", to: "refs/bifrost/base/7")
        let clone = f.repo.clone
        let bases = try await f.output(["merge-base", "--all", head.hex, base.hex], in: clone)
        #expect(Set(bases.split(separator: "\n")) == [Substring(feat.hex), Substring(main.hex)])
        let one = try await f.output(["merge-base", head.hex, base.hex], in: clone)
        try await f.output(
            PushTestRepo.localRemote + [
                "merge-tree", "--write-tree", "--merge-base=\(one)", head.hex, base.hex,
            ], in: clone)
        let start = try await ConflictMerge.start(pr: f.pr, head: head, base: base, git: f.git)
        #expect(start.conflicted == ["c.txt"])
    }

    // A file that one side deleted and the other changed, a binary file that both changed, or a
    // text file over 1 MiB, can't go to Claude, so the row needs you. A deleted file that already
    // had a line of 7 "=" has no "<" line, so it is no text conflict either.
    @Test func aDeleteOrBinaryConflictNeedsYou() async throws {
        let big = (1...40_000).map { "let line\($0) = \($0) // some text" }
        func changed(_ text: String) -> String {
            var copy = big
            copy[10] = text
            return copy.joined(separator: "\n") + "\n"
        }
        let (one, feat, main) = (changed(big[10]), changed("let feat = 1"), changed("let main = 1"))
        #expect(one.utf8.count > CommitFileRule.maxFileBytes)
        let cases: [@Sendable () async throws -> ConflictRepo] = [
            {
                try await ConflictRepo.make(
                    feat: ["src/a.swift": nil],
                    main: ["src/a.swift": lines([11: "let line11 = 0"])])
            },
            {
                try await ConflictRepo.make(
                    files: ["img.bin": "one\u{0}one\n"], feat: ["img.bin": "feat\u{0}feat\n"],
                    main: ["img.bin": "main\u{0}main\n"])
            },
            {
                try await ConflictRepo.make(
                    files: ["big.swift": one], feat: ["big.swift": feat], main: ["big.swift": main])
            },
            {
                try await ConflictRepo.make(
                    files: ["data/table.cfg": table("x = 1")], feat: ["data/table.cfg": nil],
                    main: ["data/table.cfg": table("x = 2")])
            },
        ]
        for make in cases {
            let r = try await make()
            defer { r.remove() }
            await #expect(throws: ConflictFailure.notText) { _ = try await r.start() }
        }
    }

    // A conflict in a workflow file: Bifrost never commits that file, so the row needs you.
    @Test func aConflictInAWorkflowFileNeedsYou() async throws {
        let path = ".github/workflows/ci.yml"
        let r = try await ConflictRepo.make(
            files: [path: "on: push\n"], feat: [path: "on: pull_request\n"],
            main: [path: "on: workflow_dispatch\n"])
        defer { r.remove() }
        await #expect(throws: ConflictFailure.forbidden(.workflow)) { _ = try await r.start() }
    }

    // 50 conflicted files go to Claude, and 51 need you.
    @Test func moreThan50ConflictedFilesNeedYou() async throws {
        func repo(_ count: Int) async throws -> ConflictRepo {
            let paths = (1...count).map { "src/f\($0).txt" }
            func each(_ text: String) -> [String: String?] {
                Dictionary(uniqueKeysWithValues: paths.map { ($0, text as String?) })
            }
            return try await ConflictRepo.make(
                files: Dictionary(uniqueKeysWithValues: paths.map { ($0, "one\n") }),
                feat: each("feat\n"), main: each("main\n"))
        }
        do {
            let many = try await repo(ConflictMerge.maxFiles + 1)
            defer { many.remove() }
            await #expect(throws: ConflictFailure.tooMany) { _ = try await many.start() }
        }
        let most = try await repo(ConflictMerge.maxFiles)
        defer { most.remove() }
        #expect(try await most.start().conflicted.count == ConflictMerge.maxFiles)
    }

    // A filter attribute on a conflicted file would refuse each commit, so the round stops
    // before Claude starts, with a text that does not ask for a new try.
    @Test func aFilterOnAConflictedFileStopsTheRoundBeforeClaude() async throws {
        let r = try await ConflictRepo.make(
            files: [".gitattributes": "src/a.swift filter=lfs\n"],
            feat: ["src/a.swift": lines([11: "let line11 = \"feat\""])],
            main: ["src/a.swift": lines([11: "let line11 = \"main\""])])
        defer { r.remove() }
        let start = try await r.start()
        try await r.reset(to: start.auto)
        await #expect(throws: ConflictFailure.forbidden(.filter)) {
            try await r.checkWorktree(start)
        }
    }

    // Claude resolved the conflict: the commit is a merge of the head and the base with the
    // message "Merge main into feat", with no signature. It holds the resolved file and the new
    // file of main.
    @Test func theCommitIsAnUnsignedMergeOfHeadAndBase() async throws {
        let r = try await ConflictRepo.lineEleven()
        defer { r.remove() }
        let start = try await r.startInWorktree()
        try r.write("src/a.swift", resolved)
        let made = try await r.commit(start)
        let object = try await r.object(made)
        #expect(object.parents == [r.head, r.base] && !object.signed)
        #expect(object.message == "Merge main into feat")
        let raw = try await r.f.output(["cat-file", "commit", made.hex], in: r.f.repo.clone)
        #expect(!raw.contains("gpgsig"))
        #expect(try await r.file("src/a.swift", of: made) + "\n" == resolved)
        #expect(try await r.file("docs/b.md", of: made) == "# Base")
        // The commit is on no branch: only the push puts it on GitHub.
        #expect(try await r.f.branch() == r.head)
    }

    // The user pushed to the branch after the start. The merge of the start does not hold the new
    // commit, so a commit on the new head would drop it: Bifrost refuses it, and also a commit on
    // another base.
    @Test func aCommitOnAnotherHeadIsRefused() async throws {
        let r = try await ConflictRepo.lineEleven()
        defer { r.remove() }
        let start = try await r.startInWorktree()
        try r.write("src/a.swift", resolved)
        try await r.f.commit(on: "feat", ["d.txt": "new\n"])
        let moved = try await r.f.fetch("feat", to: "refs/bifrost/pr/7")
        let onHead = await #expect(throws: ConflictFailure.self) {
            _ = try await r.commit(start, head: moved)
        }
        let onBase = await #expect(throws: ConflictFailure.self) {
            _ = try await r.commit(start, base: moved)
        }
        #expect(isGit(onHead) && isGit(onBase))
        #expect(!r.f.runner.all.contains { $0.contains("write-tree") })
    }

    // The worktree is not at the merge to resolve: the check before the session and the commit
    // both refuse it, because git status and git add would compare with another commit.
    @Test func aWorktreeThatIsNotAtTheMergeIsRefused() async throws {
        let r = try await ConflictRepo.lineEleven()
        defer { r.remove() }
        let start = try await r.start()
        let early = await #expect(throws: ConflictFailure.self) { try await r.checkWorktree(start) }
        try r.write("src/a.swift", resolved)
        let late = await #expect(throws: ConflictFailure.self) { _ = try await r.commit(start) }
        #expect(isGit(early) && isGit(late))
    }

    // A file that still holds conflict markers stops the commit, also when only one marker line
    // is left, or when both sides stay with the line between them.
    @Test func markersLeftRefuseTheCommit() async throws {
        let r = try await ConflictRepo.lineEleven()
        defer { r.remove() }
        let start = try await r.startInWorktree()
        await #expect(throws: ConflictFailure.markersLeft) { _ = try await r.commit(start) }
        let texts = [
            lines([11: "let line11 = \"both\"\n>>>>>>> \(r.base.hex)"]),
            lines([11: "let line11 = \"feat\"\n=======\nlet main11 = \"main\""]),
        ]
        for text in texts {
            try r.write("src/a.swift", text)
            await #expect(throws: ConflictFailure.markersLeft) { _ = try await r.commit(start) }
        }
        try r.write("src/a.swift", resolved)
        _ = try await r.commit(start)
    }

    // A file with no extension uses a heading with a line of 7 "=" under it. The heading stays
    // in the resolved merge, so the commit goes. A line of 7 "=" that the merge added does not.
    @Test func aHeadingUnderlineThatTheFileHadStays() async throws {
        func readme(_ line: String, _ more: String = "") -> String {
            "Title\n=======\n\n\(line)\n\(more)line b\n"
        }
        let r = try await ConflictRepo.make(
            files: ["README": readme("line a")], feat: ["README": readme("feat a")],
            main: ["README": readme("main a")])
        defer { r.remove() }
        let start = try await r.startInWorktree()
        #expect(start.conflicted == ["README"])
        try r.write("README", readme("feat a", "=======\nmain a\n"))
        await #expect(throws: ConflictFailure.markersLeft) { _ = try await r.commit(start) }
        try r.write("README", readme("both a"))
        let made = try await r.commit(start)
        #expect(try await r.file("README", of: made) + "\n" == readme("both a"))
    }

    // A file that is not a doc file already had a line of 7 "=" before the merge. The line stays
    // in the resolved merge, so the commit goes.
    @Test func aSeparatorLineThatTheFileHadBeforeStays() async throws {
        let path = "data/table.cfg"
        let r = try await ConflictRepo.make(
            files: [path: table("x = 1")], feat: [path: table("x = 2")],
            main: [path: table("x = 3")])
        defer { r.remove() }
        let start = try await r.startInWorktree()
        #expect(start.conflicted == [path])
        try r.write(path, table("x = 4"))
        let made = try await r.commit(start)
        #expect(try await r.file(path, of: made) + "\n" == table("x = 4"))
    }

    // git or the file system can't answer the check before the session (here a folder that
    // can't be read). That can work in a later try, so the text asks for one.
    @Test func aCheckOfTheWorktreeThatFailsCanBeTriedAgain() async throws {
        let r = try await ConflictRepo.lineEleven()
        defer { r.remove() }
        let start = try await r.startInWorktree()
        let folder = r.f.repo.worktree + "/src"
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: folder)
        }
        let failure = await #expect(throws: ConflictFailure.self) {
            try await r.checkWorktree(start)
        }
        #expect(isGit(failure))
        #expect(failure?.message.hasSuffix("Choose Resolve now to try again.") == true)
    }

    // A change of a file that had no conflict, or a new file, stops the commit. With only the
    // conflicted file changed, the commit goes.
    @Test func aChangeOutsideTheConflictsRefusesTheCommit() async throws {
        let r = try await ConflictRepo.lineEleven()
        defer { r.remove() }
        let start = try await r.startInWorktree()
        try r.write("src/a.swift", resolved)
        try r.write("a.txt", "changed\n")
        await #expect(throws: ConflictFailure.otherFiles) { _ = try await r.commit(start) }
        try r.write("a.txt", "one\n")
        try r.write("notes.txt", "Claude's notes\n")
        await #expect(throws: ConflictFailure.otherFiles) { _ = try await r.commit(start) }
        try FileManager.default.removeItem(atPath: r.f.repo.worktree + "/notes.txt")
        let made = try await r.commit(start)
        let changed = try await r.f.output(
            ["diff", "--name-only", start.auto.hex, made.hex], in: r.f.repo.clone)
        #expect(changed == "src/a.swift")
    }

    // The start refuses each conflict where one side deleted the file, so each conflicted file of
    // a round is in both sides. A conflicted file that the worktree deleted can only be a mistake
    // of the session: the commit refuses it, and the resolved file then goes.
    @Test func aDeletedConflictedFileRefusesTheCommit() async throws {
        let r = try await ConflictRepo.lineEleven()
        defer { r.remove() }
        let start = try await r.startInWorktree()
        try FileManager.default.removeItem(atPath: r.f.repo.worktree + "/src/a.swift")
        await #expect(throws: ConflictFailure.git("Claude deleted a conflicted file.")) {
            _ = try await r.commit(start)
        }
        try r.write("src/a.swift", resolved)
        _ = try await r.commit(start)
    }

    // MARK: - A change of the session after the checks

    // The session stays open, so it can change src/a.swift after the checks of the worktree and
    // before git add. The result is the failure of the commit, which the check of the made commit
    // must give.
    private func changeBeforeGitAdd(_ change: @escaping @Sendable (String) throws -> Void)
        async throws -> ConflictFailure?
    {
        let file = Mutex<String?>(nil)
        let r = try await ConflictRepo.lineEleven { args in
            guard args.contains("add"), args.contains("-A"),
                let path = file.withLock({ path in
                    defer { path = nil }
                    return path
                })
            else { return }
            try? change(path)
        }
        defer { r.remove() }
        let start = try await r.startInWorktree()
        try r.write("src/a.swift", resolved)
        file.withLock { $0 = r.f.repo.worktree + "/src/a.swift" }
        do {
            _ = try await r.commit(start)
            return nil
        } catch let failure as ConflictFailure {
            return failure
        }
    }

    // The file becomes a folder with a new file in it: git add takes the new file, whose path
    // passed no rule, so the changed paths of the made commit refuse it.
    @Test func aFileThatBecomesAFolderBeforeGitAddIsRefused() async throws {
        let failure = try await changeBeforeGitAdd { path in
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.createDirectory(
                atPath: path + "/.claude", withIntermediateDirectories: true)
            try "{}\n".write(
                toFile: path + "/.claude/settings.json", atomically: false, encoding: .utf8)
        }
        #expect(failure == .otherFiles)
    }

    // The file becomes a symbolic link: git records the link, so the mode of the made commit
    // refuses it.
    @Test func aFileThatBecomesALinkBeforeGitAddIsRefused() async throws {
        let failure = try await changeBeforeGitAdd { path in
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.createSymbolicLink(
                atPath: path, withDestinationPath: "../../outside.txt")
        }
        #expect(failure == .commitRefused(.link))
    }

    // The file grows over 1 MiB: the size in the made commit refuses it.
    @Test func aFileThatGrowsBeforeGitAddIsRefused() async throws {
        let failure = try await changeBeforeGitAdd { path in
            try String(repeating: "x", count: CommitFileRule.maxFileBytes + 1)
                .write(toFile: path, atomically: false, encoding: .utf8)
        }
        #expect(failure == .commitRefused(.tooLarge))
    }
}
