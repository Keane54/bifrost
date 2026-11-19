// The pull request of the branch of a session, as Show Info shows it (docs/behaviour/panels.md,
// "The PR lookup"). PRLookup gets it from the GitHub CLI (gh).
import Foundation

package enum PRInfo: Sendable, Equatable {
    // The PR of the branch. The address always starts with https://.
    case pr(number: Int, title: String, url: URL, state: String)
    // The branch has no PR.
    case none
    // Bifrost could not check, for this reason.
    case unavailable(PRUnavailable)
}

// Why Bifrost could not check for a PR. text is the PR line that Show Info shows.
package enum PRUnavailable: Sendable, Equatable {
    // gh is not on the PATH, or it cannot run.
    case notInstalled
    // gh did not end within PRLookup.ghTimeout.
    case timedOut
    // gh failed with no error line, went over the output limit, or the lookup stopped.
    case failed
    // The folder of the session is not there.
    case noFolder
    // The folder is at or below a skip root, so Bifrost runs no gh in it.
    case reviewSession
    // The first line of the error of gh, with no hidden characters and at most
    // PRLookup.reasonLimit characters.
    case gh(String)

    package var text: String {
        switch self {
        case .notInstalled: "GitHub CLI (gh) isn't installed."
        case .timedOut: "GitHub CLI (gh) didn't answer within 10 seconds."
        case .failed: "GitHub CLI (gh) couldn't check for a PR."
        case .noFolder: "The session folder isn't there any more."
        case .reviewSession: "This is a review session, so Bifrost doesn't run gh in its folder."
        case .gh(let line): line
        }
    }
}
