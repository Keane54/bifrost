import BifrostFoundation
import Foundation
import Synchronization

// The runner of git of the round tests that writes a file at the first status command after arm:
// the reset of the worktree (a review round) and the count of the changes (a request round) run
// one, so the file changes after the end of the turn.
final class RewritingRunner: CommandRunner {
    private let real = ProcessRunner()
    private let rewrite = Mutex<(file: String, text: String)?>(nil)

    func arm(file: String, text: String) {
        rewrite.withLock { $0 = (file, text) }
    }

    func run(_ command: Command) async -> ExecResult {
        if command.arguments.contains("status"), let job = rewrite.withLock({ $0.take() }) {
            try? job.text.write(toFile: job.file, atomically: false, encoding: .utf8)
        }
        return await real.run(command)
    }
}
