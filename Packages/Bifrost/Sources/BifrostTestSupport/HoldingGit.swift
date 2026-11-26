import Foundation

// A git program for the tests of the clones of Reviews: a shell script that holds each clone. A
// clone adds its pid and its real folder to the log, then sleeps until SIGKILL ends it: it
// ignores SIGTERM, and the sleep keeps the pid and the ignored signal of the script. So only the
// SIGKILL at the end of the grace of a stop ends it. Each other command runs the real git
// (testGit). The script and its log are in the temporary folder of the test, so a test can
// check that a stop ended the git that it started.
package struct HoldingGit: Sendable {
    // One clone that runs or ran: its pid and its real folder.
    package struct Clone: Sendable, Equatable {
        package var pid: pid_t
        package var folder: String
    }

    // The path of the script.
    package let path: String
    // The path of the log.
    package let log: String

    package init(in folder: TemporaryFolder) throws {
        path = folder.appending("holding-git")
        log = folder.appending("holding-git.log")
        let script = """
            #!/bin/sh
            for arg in "$@"; do
                if [ "$arg" = clone ]; then
                    printf '%s %s\\n' "$$" "$(pwd -P)" >>'\(log)'
                    trap '' TERM
                    exec /bin/sleep 600
                fi
            done
            exec '\(testGit)' "$@"

            """
        try script.write(toFile: path, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    // The clones that started, in order.
    package var clones: [Clone] {
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = pid_t(parts[0]) else { return nil }
            return Clone(pid: pid, folder: String(parts[1]))
        }
    }
}
