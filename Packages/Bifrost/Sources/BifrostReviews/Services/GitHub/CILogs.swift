// The read of the logs of the failed Actions jobs of a CI round (task C1 of the CI watcher). A
// round gives Claude the logs, and Claude decides Fix, Retry or Needs you. Bifrost reads at most
// maxJobs logs, one after the other, and cleans each with CILog.
import Foundation

// The log of one failed job, or the reason that Bifrost has no log. text is nil exactly when
// missing is not nil.
package struct JobLog: Sendable, Equatable {
    package var check: HeadCheck
    package var text: String?
    package var cut: Bool
    package var missing: String?

    init(check: HeadCheck, text: String?, cut: Bool, missing: String?) {
        self.check = check
        self.text = text
        self.cut = cut
        self.missing = missing
    }
}

package enum CILogs {
    // The most logs that one round reads.
    package static let maxJobs = 5

    // One JobLog for each Actions job, in job ID order, each job one time. A job after the first
    // maxJobs gets "not read" and no read. A cancel stops the reads before the next one, and the
    // result then holds only the jobs that were read.
    @MainActor package static func read(
        _ jobs: [HeadCheck], repo: RepoName, client: GitHubClient
    ) async -> [JobLog] {
        var seen: Set<JobID> = []
        let actions = jobs.filter { check in
            guard let job = check.job else { return false }
            return seen.insert(job).inserted
        }.sorted { ($0.job?.value ?? 0) < ($1.job?.value ?? 0) }
        var result: [JobLog] = []
        for (position, check) in actions.enumerated() {
            guard let job = check.job else { continue }
            if Task.isCancelled { break }
            if position >= maxJobs {
                result.append(JobLog(check: check, text: nil, cut: false, missing: "not read"))
                continue
            }
            do {
                let cleaned = await clean(try await client.fetch(.jobLog(repo, job)))
                result.append(
                    JobLog(check: check, text: cleaned.text, cut: cleaned.cut, missing: nil))
            } catch {
                result.append(
                    JobLog(check: check, text: nil, cut: false, missing: reason(error)))
            }
        }
        return result
    }

    // A large log takes seconds to clean, so the clean runs off the main actor.
    @concurrent private static func clean(_ data: Data) async -> (text: String, cut: Bool) {
        CILog.text(data)
    }

    private static func reason(_ error: GitHubError) -> String {
        switch error {
        case .badAnswer: "too large"
        case .refused: "gone"
        default: "unreadable"
        }
    }
}
