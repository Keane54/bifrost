import BifrostFoundation
import Darwin
import Foundation
import System

// MARK: - The file system

// The facts of a file that the branch reader needs. A link gives the facts of its target.
package struct BranchFileInfo: Sendable, Equatable {
    package var modified: Date
    package var isFile: Bool
    package var isDirectory: Bool

    package init(modified: Date, isFile: Bool, isDirectory: Bool) {
        self.modified = modified
        self.isFile = isFile
        self.isDirectory = isDirectory
    }
}

// The file system calls of the branch reader. Each call follows the links of the path. A test
// gives a fake.
package protocol BranchFileSystem: Sendable {
    func readFile(_ path: String) async throws -> String
    func info(_ path: String) async throws -> BranchFileInfo
    // The real path of an existing path, with no links, or nil when the path does not exist.
    func realPath(_ path: String) async -> String?
}

// The real file system. The calls run off the actor of the caller.
package struct LocalBranchFileSystem: BranchFileSystem {
    package init() {}

    @concurrent package func readFile(_ path: String) async throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    // stat follows a link at the end of the path, so a .git link to a folder is a folder, and a
    // HEAD link gives the time of its target.
    @concurrent package func info(_ path: String) async throws -> BranchFileInfo {
        var facts = stat()
        guard stat(path, &facts) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let time = facts.st_mtimespec
        let type = facts.st_mode & S_IFMT
        return BranchFileInfo(
            modified: Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9),
            isFile: type == S_IFREG, isDirectory: type == S_IFDIR)
    }

    @concurrent package func realPath(_ path: String) async -> String? {
        RealPath.of(path)
    }
}

// MARK: - The branch reader

struct NoGitdir: Error {}

// Reads the branch of a folder from its HEAD file with no process. It reads a HEAD file again
// only when its modification time changes. When it cannot decide, it asks git, with the env of
// the claude runs (the login env), so git is the git of the login PATH.
//
// A folder in one of skipRoots (SkipRoots) gives nil with no file read and no git command. The
// check also compares the real paths through the file system. A relative folder has no branch.
package actor BranchReader {
    private struct Cached {
        var head: String
        var modified: Date
        var branch: String
    }

    private let runner: any CommandRunner
    private let fileSystem: any BranchFileSystem
    private let skipRoots: SkipRoots
    private let environment: [String: String]?
    // One entry for each folder of a row, so the cache needs no size limit.
    private var cache: [String: Cached] = [:]

    // environment is the env of git. nil gives git the env of the app (a test).
    package init(
        runner: any CommandRunner, fileSystem: any BranchFileSystem = LocalBranchFileSystem(),
        skipRoots: [String] = [], environment: [String: String]? = nil
    ) {
        self.runner = runner
        self.fileSystem = fileSystem
        self.skipRoots = SkipRoots(skipRoots)
        self.environment = environment
    }

    package func read(_ cwd: String) async -> String? {
        guard cwd.hasPrefix("/"), await !inSkipRoot(cwd) else {
            cache[cwd] = nil
            return nil
        }
        // A folder that is gone has no branch. Do not use a parent repo.
        guard let folder = try? await fileSystem.info(cwd), folder.isDirectory else {
            cache[cwd] = nil
            return nil
        }
        do {
            guard let head = try await findHead(cwd) else { return nil }
            // A .git file outside the reviews folder can point into it. Read no HEAD file there.
            if await inSkipRoot(FilePath(head).removingLastComponent().string) {
                cache[cwd] = nil
                return nil
            }
            let modified = try await fileSystem.info(head).modified
            if let hit = cache[cwd], hit.head == head, hit.modified == modified {
                return hit.branch
            }
            if let branch = branchOfHead(try await fileSystem.readFile(head)) {
                cache[cwd] = Cached(head: head, modified: modified, branch: branch)
                return branch
            }
        } catch {
            // A file error uses git.
        }
        cache[cwd] = nil
        return await branchFromGit(cwd)
    }

    // The branch name that git gives, or nil when git fails.
    private func branchFromGit(_ cwd: String) async -> String? {
        let result = await runner.run(
            Command(
                "git", ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"], environment: environment,
                timeout: .seconds(2)))
        return result.succeeded ? result.stdout.trimmed() : nil
    }

    // True when the absolute path is a root of skipRoots or a folder below one, by the paths as
    // they are or by their real paths.
    private func inSkipRoot(_ path: String) async -> Bool {
        await skipRoots.contains(path) { await fileSystem.realPath($0) }
    }

    // Find the HEAD file of a folder: go up from the folder to the root. A ".git" folder holds
    // HEAD. A ".git" file holds "gitdir: <path>" (a linked worktree); a relative path starts at
    // the folder. nil when no ".git" exists. Throw when a ".git" file has no gitdir.
    private func findHead(_ cwd: String) async throws -> String? {
        var dir = FilePath(resolvePath(cwd, from: "/"))
        while true {
            let dotGit = dir.appending(".git")
            let info = try? await fileSystem.info(dotGit.string)
            if info?.isDirectory == true { return dotGit.appending("HEAD").string }
            if info?.isFile == true {
                guard let gitdir = gitdirOf(try await fileSystem.readFile(dotGit.string)) else {
                    throw NoGitdir()
                }
                return FilePath(resolvePath(gitdir, from: dir.string)).appending("HEAD").string
            }
            let parent = dir.removingLastComponent()
            if parent == dir { return nil }
            dir = parent
        }
    }
}
