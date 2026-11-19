import Foundation

// A process that stands in for a session process: /bin/sleep 600 in its own process group,
// with no descriptor of the test. The row of a session gets its pid, so a test can check that a
// close signals only the attach child, never the session. A test can give the first argument
// (argv[0]), for example "claude", so the process reads as a claude process. Outside the test
// sandbox, the init records an issue and throws (TestSandbox).
@MainActor
package final class StandInProcess {
    package let pid: pid_t
    private var reaped = false

    package init(name: String = "/bin/sleep") throws {
        try TestSandbox.require()
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([name, "600"] as [String]).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        let env: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let code = posix_spawn(&pid, "/bin/sleep", &actions, &attributes, argv, env)
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EPERM) }
        self.pid = pid
    }

    // True while the process runs. A reaped pid can belong to a new process, so a reaped
    // stand-in gets no more signals.
    package var alive: Bool {
        guard !reaped else { return false }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
            reaped = true
            return false
        }
        return kill(pid, 0) == 0
    }

    package func stop() {
        guard !reaped else { return }
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        reaped = true
    }

    // A test that stops early (a failed #require) does not call stop.
    isolated deinit { stop() }
}
