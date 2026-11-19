import BifrostFoundation
import BifrostSessions
import Foundation

// Reads the merged PRs of the user (MergedPRs) through gh.
package struct MergedPRsReader: Sendable {
    package let gh: GHCommand

    package init(gh: GHCommand) {
        self.gh = gh
    }

    // The PRs that merged at the time or later.
    @concurrent package func read(since: Date) async -> Result<[MergedPR], MergedPRsError> {
        let result = await gh.run(MergedPRs.args(since: since))
        switch result.end {
        case .exited(0): return MergedPRs.parse(result.stdout)
        case .notStarted: return .failure(.notStarted)
        case .timedOut: return .failure(.timedOut)
        default:
            // The line goes to the Event log, so a hidden character (a bidi control) cannot change
            // how the rest of the line reads.
            let line = result.stderr.split(whereSeparator: \.isNewline).first.map {
                String(withoutHiddenCharacters(String($0)).trimmed().prefix(MergedPRs.maxReason))
            }
            return .failure(.failed(line.flatMap { $0.isEmpty ? nil : $0 }))
        }
    }
}
