import Foundation

// The GitHub CLI (gh) for the Daily update, the Performance panel and Reviews. gh gets the env of
// the claude runs (the login-shell PATH, so the app finds gh as a shell does) with the two values
// that keep it from asking a question or printing an update notice, and a Bifrost folder as its
// current folder, so gh never reads a repository of the user. Bifrost reads no token: gh uses its
// own login. After a cancel, the call ends when gh ended (SIGKILL).
package struct GHCommand: Sendable {
    // The time limit of one gh call.
    package static let timeout = Duration.seconds(30)
    // The limit of stdout and of stderr of one gh call, in bytes.
    package static let outputLimit = 1_048_576

    package let path: String
    package let environment: [String: String]
    package let folder: URL
    private let runner: any CommandRunner

    package init(
        path: String, environment: [String: String], folder: URL, runner: any CommandRunner
    ) {
        self.path = path
        self.environment = environment.merging(
            ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"]
        ) { _, fixed in fixed }
        self.folder = folder
        self.runner = runner
    }

    // Run gh with the arguments. input goes to its stdin (nil: an empty, closed stdin).
    package func run(
        _ arguments: [String], input: Data? = nil, timeout: Duration = Self.timeout,
        outputLimit: Int = Self.outputLimit
    ) async -> ExecResult {
        await runner.run(
            Command(
                path, arguments, directory: folder.path(percentEncoded: false),
                environment: environment, timeout: timeout, outputLimit: outputLimit,
                input: input, waitsForEnd: true))
    }
}
