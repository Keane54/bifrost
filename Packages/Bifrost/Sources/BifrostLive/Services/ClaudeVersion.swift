import BifrostFoundation
import BifrostSessions
import Foundation

// The result of the version check of Claude Code.
package struct ClaudeVersionCheck: Sendable, Equatable {
    // Bifrost needs this version of Claude Code or a later version. Settings > General and
    // Settings > Live details show a notice for an older version.
    package static let appMinimum: ClaudeCodeVersion = "2.1.281"
    // Live details needs this version of Claude Code or a later version.
    package static let liveMinimum: ClaudeCodeVersion = "2.1.290"

    // The version that claude gave, or nil when the run failed or its output has no version.
    package var version: ClaudeCodeVersion?
    // True when the version is the minimum or a later version.
    package var ok: Bool
    package var minimum: ClaudeCodeVersion

    package init(version: ClaudeCodeVersion?, ok: Bool, minimum: ClaudeCodeVersion) {
        self.version = version
        self.ok = ok
        self.minimum = minimum
    }
}

// The version check of Claude Code: it runs claude --version and compares the version with the
// minimum of the feature.
package enum ClaudeVersion {
    static let timeout = Duration.seconds(5)

    // Run claude --version, with a time limit of 5 s. A run that does not end with code 0 gives
    // no version, and no version is never ok.
    @concurrent package static func check(
        _ claude: ClaudeRunner, minimum: ClaudeCodeVersion
    ) async -> ClaudeVersionCheck {
        let result = await claude.run(["--version"], timeout: timeout)
        let version = result.succeeded ? ClaudeCodeVersion(firstIn: result.stdout) : nil
        return ClaudeVersionCheck(
            version: version, ok: version.map { $0 >= minimum } ?? false, minimum: minimum)
    }
}
