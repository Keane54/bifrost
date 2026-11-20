// The checks of the head commit of a PR, and the fresh read of the head of a PR
// (docs/behaviour/reviews.md, "The GitHub data"). The poll and HeadQueries read the same check
// fields. The conflict and CI rounds act on these values, so a value that Bifrost can't read never
// makes the checks look done: a check with no readable progress counts as running, and a node that
// Bifrost can't read makes the list cut.
import Foundation

// Where a check comes from. Only a job of GitHub Actions has logs that Bifrost can read and jobs
// that it can re-run.
package enum CheckSource: Sendable, Equatable {
    // A check run of the app github-actions, with its job ID and the ID of its workflow run.
    case actions(job: JobID, run: RunID)
    // A check run of another app, by the slug of the app. A check run of github-actions with no
    // job ID or no run ID is here too. The slug is empty when GitHub gave none.
    case app(String)
    // A commit status of a CI service.
    case status
}

package enum CheckOutcome: Sendable, Equatable {
    // Not done yet, or Bifrost can't read its progress.
    case running
    // SUCCESS, NEUTRAL or SKIPPED.
    case passed
    // The conclusion of a check run (FAILURE, TIMED_OUT, CANCELLED, STARTUP_FAILURE or
    // ACTION_REQUIRED) or the state of a status (FAILURE or ERROR), as GitHub gave it.
    case failed(String)
    // Done with another result, for example STALE or a value that Bifrost does not know.
    case other
}

package struct HeadCheck: Sendable, Equatable {
    // The name of the check run, or the context of the status.
    package var name: String
    package var outcome: CheckOutcome
    package var source: CheckSource
    // The page of the check on GitHub or on the CI service. Only an http or https address.
    package var url: URL?

    package init(name: String, outcome: CheckOutcome, source: CheckSource, url: URL? = nil) {
        self.name = name
        self.outcome = outcome
        self.source = source
        self.url = url
    }

    // The job ID of a job of GitHub Actions, or nil.
    package var job: JobID? {
        if case .actions(let job, _) = source { return job }
        return nil
    }

    package var isFailed: Bool {
        if case .failed = outcome { return true }
        return false
    }
}

// The checks of the head commit as one read gives them.
package struct HeadChecks: Sendable, Equatable {
    // The conclusions of a job of GitHub Actions that a CI round can act on.
    package static let jobFailures: Set<String> = ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE"]

    package var checks: [HeadCheck]
    // True when GitHub has more checks than the read takes, or when Bifrost can't read a check or
    // the list of checks.
    package var cut: Bool
    // True when the checks are of the head commit of the PR.
    package var onHead: Bool

    package init(checks: [HeadCheck] = [], cut: Bool = false, onHead: Bool = false) {
        self.checks = checks
        self.cut = cut
        self.onHead = onHead
    }

    // True when each check of the head is done and the read has all of them.
    package var settled: Bool {
        onHead && !cut && !checks.contains { $0.outcome == .running }
    }

    // The jobs of GitHub Actions that failed in a way that a CI round can act on, in the order of
    // their job IDs, each job one time.
    package var failedJobs: [HeadCheck] {
        var seen: Set<JobID> = []
        return checks.compactMap { check -> (job: JobID, check: HeadCheck)? in
            guard let job = check.job, case .failed(let conclusion) = check.outcome,
                Self.jobFailures.contains(conclusion)
            else { return nil }
            return (job, check)
        }
        .sorted { $0.job < $1.job }
        .filter { seen.insert($0.job).inserted }
        .map(\.check)
    }

    // The job IDs of failedJobs: the key of one failure of the head.
    package var jobKey: [JobID] { failedJobs.compactMap(\.job) }

    // The failed checks that are not jobs of GitHub Actions: Bifrost shows only their state.
    package var others: [HeadCheck] {
        checks.filter { $0.isFailed && $0.job == nil }
    }
}

// The fresh read of the head of a PR (HeadQueries): the values that a conflict or CI round checks
// before it acts, and before the push.
package struct HeadRead: Sendable, Equatable {
    package var state: PRLifecycle
    // The login of the author, or empty when GitHub gave none (a deleted user).
    package var author: String
    package var isFork: Bool
    package var headRef: String
    package var head: CommitID
    package var baseRef: String
    package var base: CommitID?
    package var defaultBranch: String
    // nil when GitHub gave no known merge state.
    package var mergeable: Mergeable?
    package var checks: HeadChecks

    package init(
        state: PRLifecycle = .open, author: String, isFork: Bool = false,
        headRef: String = "feature", head: CommitID, baseRef: String = "main",
        base: CommitID? = nil, defaultBranch: String = "main", mergeable: Mergeable? = nil,
        checks: HeadChecks = HeadChecks()
    ) {
        self.state = state
        self.author = author
        self.isFork = isFork
        self.headRef = headRef
        self.head = head
        self.baseRef = baseRef
        self.base = base
        self.defaultBranch = defaultBranch
        self.mergeable = mergeable
        self.checks = checks
    }
}

// The decoded answer of the fresh read, with what goes to the log.
package struct HeadAnswer: Sendable, Equatable {
    package var read: HeadRead
    // The GraphQL errors next to the data, each one time.
    package var errors: [String]
    // The fields that GitHub left out or gave in a form that Bifrost can't read.
    package var faults: [WireFault]

    // Reads the output of gh. GitHub can give data and errors together, as in a poll: the read
    // then keeps the data, so an error on one check field does not stop each round. This is safe
    // for the push target. A read needs a known state, a full head commit and the fork flag, else
    // it fails. A missing head branch gives no PushTarget, and a missing base branch or default
    // branch makes PushPlan.targetRefusal refuse the push. Thus a field that an error left out
    // never sends a push to another branch or to a fork. With no such PR, an answer with errors
    // is the refusal of GitHub, and an answer with no errors is a bad answer.
    package static func decode(_ data: Data) -> Result<HeadAnswer, GitHubError> {
        guard let wire = try? JSONDecoder().decode(HeadWire.self, from: data) else {
            return .failure(.badAnswer)
        }
        let errors = PollAnswer.messages(wire.errors ?? [])
        guard let node = wire.data?.repository?.pullRequest,
            let state = node.state.flatMap(PRLifecycle.init(rawValue:)),
            let head = node.pull.headRefOid.flatMap(CommitID.init),
            let isFork = node.pull.isCrossRepository
        else { return .failure(errors.first.map(GitHubError.refused) ?? .badAnswer) }
        var faults = WireFaults()
        let read = HeadRead(
            state: state, author: node.pull.author?.login ?? "", isFork: isFork,
            headRef: node.pull.headRefName ?? "", head: head, baseRef: node.pull.baseRefName ?? "",
            base: node.pull.baseRefOid.flatMap(CommitID.init),
            defaultBranch: node.repository?.defaultBranchRef?.name ?? "",
            mergeable: node.pull.mergeState(&faults),
            checks: node.pull.headChecks(&faults))
        if read.base == nil { faults.add(.baseRefOid) }
        if node.pull.headRefName == nil { faults.add(.headRefName) }
        if node.pull.baseRefName == nil { faults.add(.baseRefName) }
        if node.repository?.defaultBranchRef?.name == nil { faults.add(.defaultBranch) }
        return .success(HeadAnswer(read: read, errors: errors, faults: faults.sorted))
    }
}

// The JSON of the fresh read. The PR fields that the poll also reads decode as in the poll.
private struct HeadWire: Decodable {
    struct Body: Decodable {
        struct Repository: Decodable { var pullRequest: Pull? }
        var repository: Repository?

        init(from decoder: any Decoder) throws {
            repository = try decoder.container(keyedBy: AnyKey.self).lenient("repository")
        }
    }

    // The fields of the poll, and the two fields that only the fresh read has.
    struct Pull: Decodable {
        struct DefaultBranch: Decodable {
            struct Ref: Decodable { var name: String? }
            var defaultBranchRef: Ref?
        }
        var pull: PullRequestWire
        var state: String?
        var repository: DefaultBranch?

        init(from decoder: any Decoder) throws {
            pull = try PullRequestWire(from: decoder)
            let fields = try decoder.container(keyedBy: AnyKey.self)
            state = fields.lenient("state")
            repository = fields.lenient("repository")
        }
    }

    var data: Body?
    var errors: [PollWire.Failure]?
}
