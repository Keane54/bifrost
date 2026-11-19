import BifrostFoundation
import BifrostLive
import BifrostTestSupport
import Darwin
import Foundation
import Testing

// The sync of the mod folder and of the skills folder, the list of their files and their
// removal (docs/behaviour/skills.md, The folder sync). Each test works in a TemporaryFolder: the
// source folder of the app is <folder>/source, and the copy is in <folder>/home.

// A call of the swap steps.
private enum SwapCall: Sendable, Equatable {
    case exchange(from: String, to: String)
    case rename(from: String, to: String)
    case remove(String)
}

// The system swap steps. With a swapError, each swap throws that error number. The renames whose
// numbers (from 1) are in failing throw "fail <n>", and a removal of a path that removalFails
// names throws "cleanup failed". Each call goes to calls.
private func steps(
    swapError: Int32? = nil, failing: Set<Int> = [],
    removalFails: @escaping @Sendable (String) -> Bool = { _ in false },
    calls: Recorder<SwapCall> = Recorder()
) -> SwapSteps {
    SwapSteps(
        exchange: { from, to throws(FileError) in
            calls.record(.exchange(from: from, to: to))
            if let swapError { throw .system(.rename(to: to), path: from, code: swapError) }
            try SwapSteps.system.exchange(from, to)
        },
        rename: { from, to throws(FileError) in
            calls.record(.rename(from: from, to: to))
            let number = calls.values.filter { if case .rename = $0 { true } else { false } }.count
            if failing.contains(number) { throw .other("fail \(number)") }
            try SwapSteps.system.rename(from, to)
        },
        remove: { path throws(FileError) in
            calls.record(.remove(path))
            if removalFails(path) { throw .other("cleanup failed") }
            try SwapSteps.system.remove(path)
        })
}

// Write a file below a folder, with each missing folder.
private func put(_ base: URL, _ relative: String, _ text: String) throws {
    let file = base.appending(path: relative)
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
}

private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

// The permission bits of the item at the URL, with no link followed.
private func mode(_ url: URL) -> mode_t {
    var info = stat()
    guard lstat(path(url), &info) == 0 else { return 0 }
    return info.st_mode & 0o777
}

private func isLink(_ url: URL) -> Bool {
    var info = stat()
    return lstat(path(url), &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
}

private func link(_ url: URL, to target: URL) throws {
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
}

// The mod files of a source, each with the text "content of <file>".
private func fillMod(_ source: URL) throws {
    for file in FolderSync.modFiles { try put(source, file, "content of \(file)") }
}

// The mod files sorted as listFiles sorts them.
private let sortedModFiles = [
    ".claude-plugin/marketplace.json", ".claude-plugin/plugin.json", "hooks/hooks.json",
    "hooks/register.ts",
]

// A SKILL.md with a name, a description and the group flag.
private func skill(_ name: String, _ flag: String) -> String {
    "---\nname: \(name)\ndescription: About \(name).\ndisable-model-invocation: \(flag)\n---\n"
        + "\nBody\n"
}

// The skills source of the tests: a manifest, two skills and one more file of a skill.
private func fillSkills(_ source: URL) throws {
    try put(source, ".claude-plugin/plugin.json", #"{"name":"bifrost"}"#)
    try put(source, "skills/bifrost-b/SKILL.md", skill("bifrost-b", "true"))
    try put(source, "skills/bifrost-a/SKILL.md", skill("bifrost-a", "false"))
    try put(source, "skills/bifrost-a/rules.md", "rules")
}

private let skillsFiles = [
    ".claude-plugin/plugin.json", "skills/bifrost-a/SKILL.md", "skills/bifrost-a/rules.md",
    "skills/bifrost-b/SKILL.md",
]

@Suite("Folder sync", .timeLimit(.minutes(1)))
struct FolderSyncTests {
    // MARK: - The mod folder

    @Test func syncModCopiesOnlyTheFourModFiles() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        try fillMod(source)
        try put(source, "tests/register.test.ts", "x")
        try put(source, ".claude-plugin/types/x.d.ts", "x")
        try put(source, "tsconfig.json", "{}")
        try await FolderSync.syncMod(source: source, dest: dest)
        #expect(try await FolderSync.listFiles(dest) == sortedModFiles)
        for subfolder in ["", ".claude-plugin", "hooks"] {
            #expect(mode(dest.appending(path: subfolder)) == 0o700, "\(subfolder)")
        }
        for file in FolderSync.modFiles {
            #expect(mode(dest.appending(path: file)) == 0o600, "\(file)")
        }
        #expect(
            try text(dest.appending(path: "hooks/register.ts")) == "content of hooks/register.ts")
    }

    @Test func modCurrentIsTrueAfterASyncAndFalseAfterAChangeOfOneFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        try fillMod(source)
        #expect(await FolderSync.modCurrent(source: source, dest: dest) == false)
        try await FolderSync.syncMod(source: source, dest: dest)
        #expect(await FolderSync.modCurrent(source: source, dest: dest))
        try put(dest, "hooks/hooks.json", "changed")
        #expect(await FolderSync.modCurrent(source: source, dest: dest) == false)
    }

    @Test func syncModReplacesAnOldFolderAndLeavesNoTemporaryFolder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        try fillMod(source)
        try put(dest, "old.txt", "old")
        try await FolderSync.syncMod(source: source, dest: dest)
        #expect(try names(dest) == [".claude-plugin", "hooks"])
        #expect(try names(dest.deletingLastPathComponent()) == ["mod"])
    }

    @Test func aFolderURLForDestGivesASiblingTemporaryFolder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod", directoryHint: .isDirectory)
        try fillMod(source)
        try put(dest, "old.txt", "old")
        try await FolderSync.syncMod(source: source, dest: dest)
        #expect(try await FolderSync.listFiles(dest) == sortedModFiles)
        #expect(try names(folder.url.appending(path: "home")) == ["mod"])
    }

    @Test func syncModChangesNothingWhenASourceFileIsMissing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        try fillMod(source)
        try FileManager.default.removeItem(at: source.appending(path: "hooks/register.ts"))
        try put(dest, "old.txt", "old")
        let error = await #expect(throws: SyncFailure.self) {
            try await FolderSync.syncMod(source: source, dest: dest)
        }
        #expect(error?.message.contains("hooks/register.ts") == true)
        #expect(try names(dest) == ["old.txt"])
        #expect(try names(dest.deletingLastPathComponent()) == ["mod"])
    }

    @Test func aTemporaryFolderThatCannotBeMadeKeepsDest() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let parent = folder.url.appending(path: "home")
        let dest = parent.appending(path: "mod")
        try fillMod(source)
        try put(dest, "old.txt", "old")
        chmod(path(parent), 0o500)
        defer { chmod(path(parent), 0o700) }
        await #expect(throws: SyncFailure.self) {
            try await FolderSync.syncMod(source: source, dest: dest)
        }
        chmod(path(parent), 0o700)
        #expect(try names(parent) == ["mod"])
        #expect(try names(dest) == ["old.txt"])
    }

    // MARK: - The swap

    @Test func aSyncSwapsAnExistingFolderInOneStep() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        try fillMod(source)
        try put(dest, "old.txt", "old")
        let calls = Recorder<SwapCall>()
        try await FolderSync.syncMod(source: source, dest: dest, steps: steps(calls: calls))
        #expect(await FolderSync.modCurrent(source: source, dest: dest))
        #expect(try names(dest.deletingLastPathComponent()) == ["mod"])
        // The swap gives the old folder the temporary name, and the removal takes it away.
        let destPath = path(dest)
        guard case .exchange(let temporary, destPath)? = calls.values.first else {
            Issue.record("unexpected calls: \(calls.values)")
            return
        }
        #expect(temporary.hasPrefix("\(destPath).") && temporary.hasSuffix(".tmp"))
        #expect(calls.values == [.exchange(from: temporary, to: destPath), .remove(temporary)])
    }

    @Test func aFileSystemThatCannotSwapGetsTwoRenames() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        try fillMod(source)
        try put(dest, "old.txt", "old")
        let calls = Recorder<SwapCall>()
        try await FolderSync.syncMod(
            source: source, dest: dest, steps: steps(swapError: ENOTSUP, calls: calls))
        #expect(await FolderSync.modCurrent(source: source, dest: dest))
        #expect(try names(dest.deletingLastPathComponent()) == ["mod"])
        let destPath = path(dest)
        guard case .exchange(let temporary, destPath)? = calls.values.first,
            case .rename(destPath, let old)? = calls.values.dropFirst().first
        else {
            Issue.record("unexpected calls: \(calls.values)")
            return
        }
        #expect(old.hasPrefix("\(destPath).") && old.hasSuffix(".old"))
        let rest = Array(calls.values.dropFirst(2))
        #expect(rest == [.rename(from: temporary, to: destPath), .remove(old)])
    }

    @Test func aFirstInstallRenamesTheNewFolderIntoPlace() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/.bifrost/mod")
        try fillMod(source)
        let calls = Recorder<SwapCall>()
        try await FolderSync.syncMod(source: source, dest: dest, steps: steps(calls: calls))
        #expect(await FolderSync.modCurrent(source: source, dest: dest))
        // The missing parents get mode 0700.
        #expect(mode(folder.url.appending(path: "home")) == 0o700)
        #expect(mode(folder.url.appending(path: "home/.bifrost")) == 0o700)
        let destPath = path(dest)
        guard case .exchange(let temporary, destPath)? = calls.values.first,
            case .rename(destPath, let old)? = calls.values.dropFirst().first
        else {
            Issue.record("unexpected calls: \(calls.values)")
            return
        }
        #expect(Array(calls.values.dropFirst(2)) == [.rename(from: temporary, to: destPath)])
        #expect(old.hasSuffix(".old"))
    }

    @Test func anExistingParentKeepsItsMode() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let parent = folder.url.appending(path: "home")
        try fillMod(source)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        chmod(path(parent), 0o750)
        try await FolderSync.syncMod(source: source, dest: parent.appending(path: "mod"))
        #expect(mode(parent) == 0o750)
    }

    @Test func aFailedSwapRemovesTheTemporaryFolderAndKeepsDest() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        try fillMod(source)
        try put(dest, "old.txt", "old")
        let error = await #expect(throws: SyncFailure.self) {
            try await FolderSync.syncMod(source: source, dest: dest, steps: steps(swapError: EIO))
        }
        #expect(error?.message.hasPrefix("Cannot rename ") == true)
        #expect(try names(dest) == ["old.txt"])
        #expect(try names(dest.deletingLastPathComponent()) == ["mod"])
    }

    @Test func aFailedRemovalOfTheOldFolderIsNotAnErrorAndDestIsCurrent() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        try fillMod(source)
        for swapError in [nil, ENOTSUP] {
            try put(dest, "hooks/hooks.json", "changed")
            try await FolderSync.syncMod(
                source: source, dest: dest,
                steps: steps(swapError: swapError, removalFails: { _ in true }))
            #expect(await FolderSync.modCurrent(source: source, dest: dest))
        }
    }

    @Test func aFailedLastRenamePutsTheOldFolderBack() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        try fillMod(source)
        try put(dest, "old.txt", "old")
        let calls = Recorder<SwapCall>()
        let error = await #expect(throws: SyncFailure.self) {
            try await FolderSync.syncMod(
                source: source, dest: dest,
                steps: steps(swapError: ENOTSUP, failing: [2], calls: calls))
        }
        #expect(error?.message == "fail 2")
        #expect(try names(dest) == ["old.txt"])
        #expect(try names(dest.deletingLastPathComponent()) == ["mod"])
        // The swap is not possible, the old folder goes aside, the rename of the new folder
        // fails, the old folder goes back, and the temporary folder goes.
        let destPath = path(dest)
        guard case .exchange(let temporary, destPath)? = calls.values.first,
            case .rename(destPath, let old)? = calls.values.dropFirst().first
        else {
            Issue.record("unexpected calls: \(calls.values)")
            return
        }
        #expect(old.hasPrefix("\(destPath).") && old.hasSuffix(".old"))
        #expect(temporary.hasPrefix("\(destPath).") && temporary.hasSuffix(".tmp"))
        let rest = Array(calls.values.dropFirst(2))
        #expect(
            rest == [
                .rename(from: temporary, to: destPath), .rename(from: old, to: destPath),
                .remove(temporary),
            ])
    }

    @Test func aFailedRestoreNamesTheOldFolderAndKeepsTheFirstError() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        try fillMod(source)
        try put(dest, "old.txt", "old")
        let error = await #expect(throws: SyncFailure.self) {
            try await FolderSync.syncMod(
                source: source, dest: dest,
                steps: steps(swapError: ENOTSUP, failing: [2, 3], removalFails: { _ in true }))
        }
        let message = error?.message ?? ""
        #expect(message.hasPrefix("fail 2 The old folder is at \(path(dest))."))
        #expect(message.contains(".old. Move it back to \(path(dest))."))
        #expect(!message.contains("cleanup failed"))
    }

    @Test func removeRemovesTheFolderAndAcceptsAMissingFolder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        try fillMod(source)
        try await FolderSync.syncMod(source: source, dest: dest)
        try await FolderSync.remove(dest)
        #expect(try names(dest.deletingLastPathComponent()) == [])
        try await FolderSync.remove(dest)
    }

    // MARK: - Links

    @Test func modCurrentIsFalseWhenAFileOfTheCopyIsALink() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        try fillMod(source)
        try await FolderSync.syncMod(source: source, dest: dest)
        let file = dest.appending(path: "hooks/hooks.json")
        try FileManager.default.removeItem(at: file)
        try link(file, to: source.appending(path: "hooks/hooks.json"))
        #expect(await FolderSync.modCurrent(source: source, dest: dest) == false)
        try await FolderSync.syncMod(source: source, dest: dest)
        #expect(!isLink(file))
        #expect(await FolderSync.modCurrent(source: source, dest: dest))
    }

    @Test func aLinkInTheCopyIsNotFollowed() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        let outside = folder.url.appending(path: "outside")
        try fillMod(source)
        try fillMod(outside)
        for file in FolderSync.modFiles where file.hasPrefix(".claude-plugin/") {
            try put(dest, file, "content of \(file)")
        }
        try link(dest.appending(path: "hooks"), to: outside.appending(path: "hooks"))
        #expect(await FolderSync.modCurrent(source: source, dest: dest) == false)
        try await FolderSync.syncMod(source: source, dest: dest)
        #expect(!isLink(dest.appending(path: "hooks")))
        #expect(try names(outside.appending(path: "hooks")) == ["hooks.json", "register.ts"])
    }

    @Test func aCopyThatIsALinkIsReplacedAndItsTargetStays() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        let outside = folder.url.appending(path: "outside")
        try fillMod(source)
        try fillMod(outside)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try link(dest, to: outside)
        #expect(await FolderSync.modCurrent(source: source, dest: dest) == false)
        try await FolderSync.syncMod(source: source, dest: dest)
        #expect(!isLink(dest))
        #expect(await FolderSync.modCurrent(source: source, dest: dest))
        #expect(try await FolderSync.listFiles(outside) == sortedModFiles)
    }

    @Test func removeDeletesALinkAndNeverItsTarget() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dest = folder.url.appending(path: "home/mod")
        let outside = folder.url.appending(path: "outside")
        try put(outside, "keep/keep.txt", "keep")
        try put(dest, "a.txt", "a")
        try link(dest.appending(path: "folder"), to: outside.appending(path: "keep"))
        try link(dest.appending(path: "file"), to: outside.appending(path: "keep/keep.txt"))
        try await FolderSync.remove(dest)
        #expect(try names(dest.deletingLastPathComponent()) == [])
        #expect(try text(outside.appending(path: "keep/keep.txt")) == "keep")
        try link(dest, to: outside.appending(path: "keep"))
        try await FolderSync.remove(dest)
        #expect(try names(dest.deletingLastPathComponent()) == [])
        #expect(try text(outside.appending(path: "keep/keep.txt")) == "keep")
    }

    @Test func modCurrentIsFalseWhenTheCopyHasAnExtraLinkOrFIFO() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/mod")
        let outside = folder.url.appending(path: "outside")
        try fillMod(source)
        try put(outside, "x/keep.txt", "keep")
        try await FolderSync.syncMod(source: source, dest: dest)
        try link(dest.appending(path: "hooks/extra"), to: outside.appending(path: "x"))
        #expect(await FolderSync.modCurrent(source: source, dest: dest) == false)
        try await FolderSync.syncMod(source: source, dest: dest)
        #expect(await FolderSync.modCurrent(source: source, dest: dest))
        #expect(try names(dest.appending(path: "hooks")) == ["hooks.json", "register.ts"])
        #expect(try text(outside.appending(path: "x/keep.txt")) == "keep")
        #expect(mkfifo(path(dest.appending(path: "fifo")), 0o600) == 0)
        #expect(await FolderSync.modCurrent(source: source, dest: dest) == false)
        try await FolderSync.syncMod(source: source, dest: dest)
        #expect(try names(dest) == [".claude-plugin", "hooks"])
    }

    @Test func removeOfAFolderURLThatIsALinkRemovesOnlyTheLink() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let outside = folder.url.appending(path: "outside")
        try put(outside, "keep.txt", "keep")
        let dest = folder.url.appending(path: "home/mod", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder.url.appending(path: "home"), withIntermediateDirectories: true)
        try link(folder.url.appending(path: "home/mod"), to: outside)
        try await FolderSync.remove(dest)
        #expect(try names(folder.url.appending(path: "home")) == [])
        #expect(try names(outside) == ["keep.txt"])
    }

    @Test func eachModFileIsARegularFileOfTheRepo() throws {
        let mod = try Repo.root().appending(path: "App/Bifrost/Resources/live-mod")
        for file in FolderSync.modFiles {
            var info = stat()
            #expect(lstat(path(mod.appending(path: file)), &info) == 0, "\(file)")
            #expect(info.st_mode & S_IFMT == S_IFREG, "\(file)")
        }
    }

    // MARK: - The file list

    @Test func listFilesGivesTheRegularFilesRelativeAndSortedWithTheDotFolder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        try fillSkills(source)
        #expect(try await FolderSync.listFiles(source) == skillsFiles)
    }

    @Test func listFilesGivesAnEmptyListForAMissingFolder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        #expect(try await FolderSync.listFiles(folder.url.appending(path: "none")) == [])
    }

    @Test func listFilesLeavesOutALinkAndDoesNotGoIntoIt() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let outside = folder.url.appending(path: "outside")
        try fillSkills(source)
        try put(outside, "x/SKILL.md", "outside")
        try link(source.appending(path: "skills/link"), to: outside.appending(path: "x"))
        try link(
            source.appending(path: "skills/bifrost-a/l.md"),
            to: source.appending(path: "skills/bifrost-a/rules.md"))
        #expect(try await FolderSync.listFiles(source) == skillsFiles)
    }

    @Test func listFilesOfALinkedPathThrows() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        try fillSkills(source)
        let linked = folder.url.appending(path: "linked")
        try link(linked, to: source)
        await #expect(throws: SyncFailure.self) { try await FolderSync.listFiles(linked) }
    }

    // MARK: - The skills folder

    @Test func skillsCurrentIsFalseWhenTheCopyIsMissing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        try fillSkills(source)
        let dest = folder.url.appending(path: "home/skills")
        #expect(await FolderSync.skillsCurrent(source: source, dest: dest) == false)
    }

    @Test func skillsCurrentIsTrueAfterASyncAndFalseAfterAChange() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/skills")
        try fillSkills(source)
        try await FolderSync.syncSkills(source: source, dest: dest)
        #expect(await FolderSync.skillsCurrent(source: source, dest: dest))
        try put(dest, "extra.txt", "x")
        #expect(await FolderSync.skillsCurrent(source: source, dest: dest) == false)
        try FileManager.default.removeItem(at: dest.appending(path: "extra.txt"))
        #expect(await FolderSync.skillsCurrent(source: source, dest: dest))
        try put(dest, "skills/bifrost-a/rules.md", "rulez")
        #expect(await FolderSync.skillsCurrent(source: source, dest: dest) == false)
    }

    @Test func skillsCurrentIsFalseWhenTheSourceHasNoFiles() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let none = folder.url.appending(path: "none")
        try FileManager.default.createDirectory(at: none, withIntermediateDirectories: true)
        #expect(await FolderSync.skillsCurrent(source: none, dest: none) == false)
        #expect(
            await FolderSync.skillsCurrent(
                source: folder.url.appending(path: "a"), dest: folder.url.appending(path: "b"))
                == false)
    }

    @Test func skillsCurrentIsFalseWhenTheCopyHasAnExtraLink() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/skills")
        let outside = folder.url.appending(path: "outside")
        try fillSkills(source)
        try put(outside, "x/SKILL.md", "outside")
        try await FolderSync.syncSkills(source: source, dest: dest)
        try link(dest.appending(path: "skills/x"), to: outside.appending(path: "x"))
        #expect(await FolderSync.skillsCurrent(source: source, dest: dest) == false)
        try await FolderSync.syncSkills(source: source, dest: dest)
        #expect(await FolderSync.skillsCurrent(source: source, dest: dest))
        #expect(try names(dest.appending(path: "skills")) == ["bifrost-a", "bifrost-b"])
        #expect(try text(outside.appending(path: "x/SKILL.md")) == "outside")
    }

    @Test func aSkillsCopyThatIsALinkIsReplacedAndItsTargetStays() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/skills")
        let outside = folder.url.appending(path: "outside")
        try fillSkills(source)
        try fillSkills(outside)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try link(dest, to: outside)
        #expect(await FolderSync.skillsCurrent(source: source, dest: dest) == false)
        try await FolderSync.syncSkills(source: source, dest: dest)
        #expect(!isLink(dest))
        #expect(await FolderSync.skillsCurrent(source: source, dest: dest))
        #expect(try await FolderSync.listFiles(outside) == skillsFiles)
    }

    @Test func aLinkedSubFolderOfTheSkillsCopyIsReplacedAndItsTargetStays() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/skills")
        let outside = folder.url.appending(path: "outside")
        try fillSkills(source)
        try fillSkills(outside)
        try await FolderSync.syncSkills(source: source, dest: dest)
        let sub = dest.appending(path: "skills/bifrost-a")
        try FileManager.default.removeItem(at: sub)
        try link(sub, to: outside.appending(path: "skills/bifrost-a"))
        #expect(await FolderSync.skillsCurrent(source: source, dest: dest) == false)
        try await FolderSync.syncSkills(source: source, dest: dest)
        #expect(!isLink(sub))
        #expect(await FolderSync.skillsCurrent(source: source, dest: dest))
        #expect(try await FolderSync.listFiles(outside) == skillsFiles)
    }

    @Test func syncSkillsCopiesAllFilesAndLeavesNoTemporaryFolder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/skills")
        try fillSkills(source)
        try await FolderSync.syncSkills(source: source, dest: dest)
        #expect(try await FolderSync.listFiles(dest) == skillsFiles)
        #expect(try text(dest.appending(path: "skills/bifrost-a/rules.md")) == "rules")
        #expect(try names(dest.deletingLastPathComponent()) == ["skills"])
        #expect(mode(dest.appending(path: "skills/bifrost-a")) == 0o700)
        #expect(mode(dest.appending(path: "skills/bifrost-a/rules.md")) == 0o600)
    }

    @Test func syncSkillsSwapsTheWholeFolderSoAnExtraFileGoes() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/skills")
        try fillSkills(source)
        try put(dest, "extra.txt", "x")
        try put(dest, "skills/own/SKILL.md", "mine")
        try await FolderSync.syncSkills(source: source, dest: dest)
        #expect(try await FolderSync.listFiles(dest) == skillsFiles)
    }

    @Test func aFailedRenameKeepsTheOldSkillsFolder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        let dest = folder.url.appending(path: "home/skills")
        try fillSkills(source)
        try put(dest, "old.txt", "old")
        let error = await #expect(throws: SyncFailure.self) {
            try await FolderSync.syncSkills(
                source: source, dest: dest, steps: steps(swapError: ENOTSUP, failing: [2]))
        }
        #expect(error?.message == "fail 2")
        #expect(try names(dest) == ["old.txt"])
        #expect(try names(dest.deletingLastPathComponent()) == ["skills"])
    }

    @Test func aSourceWithNoFilesThrowsAndChangesNothing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dest = folder.url.appending(path: "home/skills")
        try put(dest, "old.txt", "old")
        let error = await #expect(throws: SyncFailure.self) {
            try await FolderSync.syncSkills(source: folder.url.appending(path: "none"), dest: dest)
        }
        #expect(error?.message == "The skills folder in the app has no files.")
        #expect(try names(dest) == ["old.txt"])
    }
}
