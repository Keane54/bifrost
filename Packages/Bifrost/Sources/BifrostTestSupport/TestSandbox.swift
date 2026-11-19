import Darwin
import Foundation
import Testing

// The guard of the tests that start real processes or write real files. scripts/run-sandboxed.sh
// runs a command in the test sandbox. It gives the command the path of the concrete profile in
// BIFROST_SANDBOX_PROFILE and its own pid in BIFROST_SANDBOX_PID. The wrapper runs outside the
// sandbox. The sandbox refuses the real shared state of Claude Code and Bifrost, the network,
// and each signal to a process outside the sandbox. A plain swift test or a test run in Xcode
// has no sandbox. Then the guard records an issue and throws, so the test stops before it starts
// a process or writes a file.
//
// TemporaryFolder and StandInProcess call the guard. Thus FakeClaude, ChatFixture and the PTY
// harnesses, which make a TemporaryFolder, get it too. A test that starts a real process with no
// fixture calls it first.
package enum TestSandbox {
    package enum Refusal: Error, CustomStringConvertible {
        // The variables are not set, or the process does not run in the test sandbox.
        case notInSandbox

        package var description: String {
            "This test starts real processes or writes real files. "
                + "Run the tests with scripts/run-sandboxed.sh."
        }
    }

    // The variables that scripts/run-sandboxed.sh sets.
    package static let variable = "BIFROST_SANDBOX_PROFILE"
    package static let wrapperVariable = "BIFROST_SANDBOX_PID"

    // True when the environment is the environment of a run in the test sandbox: the profile
    // variable names a file (the wrapper removes the file only when its command ends), and a
    // signal to the wrapper process is refused. A variable can be set by hand, but outside the
    // sandbox a signal 0 to a process of the same user does not fail with EPERM.
    package static func isActive(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let path = environment[variable], !path.isEmpty,
            FileManager.default.fileExists(atPath: path),
            let text = environment[wrapperVariable], let wrapper = pid_t(text), wrapper > 1
        else { return false }
        return refusesSignals(to: wrapper)
    }

    // Records an issue and throws when the environment is not the environment of a run in the
    // test sandbox. Swift Testing gives the issue to the test that runs.
    package static func require(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(Refusal) {
        guard !isActive(environment) else { return }
        Issue.record("Run the tests with scripts/run-sandboxed.sh")
        throw .notInSandbox
    }

    // True when the process runs as this user and signal 0 to it fails with EPERM. Only the
    // signal rule of the test sandbox refuses a signal to a process of the same user.
    private static func refusesSignals(to pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
            info.pbi_uid == getuid()
        else { return false }
        return kill(pid, 0) == -1 && errno == EPERM
    }
}
