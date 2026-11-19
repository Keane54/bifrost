import BifrostFoundation
import BifrostSessions
import Foundation
import Synchronization
import Testing

extension StoreSaver {
    // A saver with no file: each save does nothing.
    package static var noFile: StoreSaver { StoreSaver(nil) }
}

// An in-memory file system. The paths of files map to text. Each parent of a known path is a
// folder. A link maps a path to its target: each call follows the links of a path, as the real
// file system does. A path that is neither a file nor a folder gives an error.
package final class MemoryFileSystem: BranchFileSystem {
    private struct State {
        var files: [String: String]
        var folders: [String]
        var mtimes: [String: Int]
        var links: [String: String]
        var reads: [String] = []
    }

    private let state: Mutex<State>

    package init(
        files: [String: String], folders: [String], mtimes: [String: Int] = [:],
        links: [String: String] = [:]
    ) {
        state = Mutex(State(files: files, folders: folders, mtimes: mtimes, links: links))
    }

    package var reads: [String] { state.withLock { $0.reads } }

    package func set(_ path: String, text: String, mtime: Int) {
        state.withLock {
            $0.files[path] = text
            $0.mtimes[path] = mtime
        }
    }

    // Add 1 to each stored time.
    package func bump() {
        state.withLock { s in s.mtimes = s.mtimes.mapValues { $0 + 1 } }
    }

    package func readFile(_ path: String) async throws -> String {
        try state.withLock { s in
            let path = Self.resolve(path, s.links)
            s.reads.append(path)
            guard let text = s.files[path] else { throw CocoaError(.fileNoSuchFile) }
            return text
        }
    }

    package func info(_ path: String) async throws -> BranchFileInfo {
        try state.withLock { s in
            let path = Self.resolve(path, s.links)
            guard let kind = Self.kind(of: path, s) else { throw CocoaError(.fileNoSuchFile) }
            let ms = s.mtimes[path] ?? 1
            return BranchFileInfo(
                modified: Date(timeIntervalSince1970: Double(ms) / 1000), isFile: !kind,
                isDirectory: kind)
        }
    }

    package func realPath(_ path: String) async -> String? {
        state.withLock { s in
            let path = Self.resolve(path, s.links)
            return Self.kind(of: path, s) == nil ? nil : path
        }
    }

    // True for a folder, false for a file, nil for a path that does not exist.
    private static func kind(of path: String, _ s: State) -> Bool? {
        if s.files[path] != nil { return false }
        let known = Array(s.files.keys) + s.folders  // order: only a search
        return s.folders.contains(path) || known.contains { $0.hasPrefix("\(path)/") } ? true : nil
    }

    // The path with each link at its start replaced by the target of the link.
    private static func resolve(_ path: String, _ links: [String: String]) -> String {
        var path = path
        for _ in 0..<8 {
            guard
                let (link, target) = links.first(where: {  // order: one link at a time
                    path == $0.key || path.hasPrefix("\($0.key)/")
                })
            else { return path }
            path = target + path.dropFirst(link.count)
        }
        return path
    }
}

// A command runner that records each command and gives one result, or the result of a function.
// It runs no program. After hold(), each run waits until release() or a cancel of its task, as a
// command that does not end. A cancel gives the result of a cancel, as the real runner does.
package final class FakeRunner: CommandRunner {
    package struct Call: Equatable {
        package var file: String
        package var args: [String]
        package var timeout: Duration

        package init(file: String, args: [String], timeout: Duration) {
            self.file = file
            self.args = args
            self.timeout = timeout
        }
    }

    // The path of the claude of claude(environment:). No file is at this path.
    package static let claudePath = "/nonexistent-bifrost-test/bin/claude"

    private struct Holding {
        var on = false
        var waiters: [AsyncStream<Void>.Continuation] = []
    }

    private let respond: @Sendable (Command) -> ExecResult
    private let recorded = Mutex<[Command]>([])
    private let holding = Mutex(Holding())
    // The signal of the first run that waits after hold().
    package let held = TestSignal()

    package init(_ result: ExecResult) {
        respond = { _ in result }
    }

    package init(_ respond: @escaping @Sendable (Command) -> ExecResult) {
        self.respond = respond
    }

    // A claude runner on this fake, with the base env.
    package func claude(environment: [String: String] = [:]) -> ClaudeRunner {
        ClaudeRunner(path: Self.claudePath, baseEnvironment: environment, runner: self)
    }

    // Each command in the order of the runs.
    package var commands: [Command] { recorded.withLock { $0 } }

    // The file, the arguments and the timeout of each command.
    package var calls: [Call] {
        commands.map { Call(file: $0.executable, args: $0.arguments, timeout: $0.timeout) }
    }

    // Each later run waits until release() or a cancel of its task.
    package func hold() {
        holding.withLock { $0.on = true }
    }

    // Each run that waits gives its result now. The later runs do not wait.
    package func release() {
        let waiters = holding.withLock { h in
            h.on = false
            defer { h.waiters.removeAll() }
            return h.waiters
        }
        for waiter in waiters {
            waiter.yield()
            waiter.finish()
        }
    }

    package func run(_ command: Command) async -> ExecResult {
        recorded.withLock { $0.append(command) }
        let (stream, wake) = AsyncStream<Void>.makeStream()
        let waits = holding.withLock { h in
            if h.on { h.waiters.append(wake) }
            return h.on
        }
        if waits {
            held.send()
            // The wait has a limit on the real clock, so a defect stops the test with a message.
            let limit = Task {
                try? await Task.sleep(for: .seconds(60))
                wake.finish()
            }
            var iterator = stream.makeAsyncIterator()
            let released = await iterator.next() != nil
            limit.cancel()
            guard released else {
                if !Task.isCancelled { Issue.record("A held run got no release in 60 s.") }
                return ExecResult(.cancelled)
            }
        }
        return respond(command)
    }
}
