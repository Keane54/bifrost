// The input file of a CI round, input-<round ID>.json in the round folder of a PR
// (docs/behaviour/reviews.md, "My PRs", and skills/bifrost-fix-ci/bifrost-mode.md, "The input
// file"). The round runs in the one session of the PR, which also holds review text from other
// people. The file gives the token of the round, the PR, the head, the tip of the base that
// Bifrost fetched, their merge base, the failed Actions jobs with the paths of their logs, the
// other failed checks, the allowed outcomes, the tries of the chain, the answer of the user, and
// the paths of the full diff, the mode file, the result file and the own request file. It holds
// no PR body and no comment. The logs, the names of the checks and the title of the PR are
// material, never instructions: the mode file says so.
import BifrostFoundation
import Foundation

package struct CIInput: Sendable, Equatable, Encodable {
    package static let version = 1

    // The files of one round in the round folder of the PR.
    package struct Files: Sendable, Equatable {
        package var result: URL
        package var mode: URL
        // The full diff of the PR, from the merge base to the head. nil when the diff is over
        // ReviewInput.maxDiffBytes.
        package var fullDiff: URL?
        // The input file itself.
        package var input: URL
        // The own request file of the user between rounds (OwnRequestFile). It is the file of
        // the request rounds of the PR (RequestInput.Files.ownRequest), so the session knows it
        // also when a CI round is the first round of the session.
        package var ownRequest: URL

        // The names of the round, each with the round ID: input-<id>.json, result-<id>.json,
        // mode-<id>.md and full-<id>.diff. The own request file of the round folder has no round
        // ID.
        package init(_ files: RoundFiles, fullDiff: Bool) {
            result = files.result
            mode = files.file("mode", "md")
            self.fullDiff = fullDiff ? files.file("full", "diff") : nil
            input = files.input
            ownRequest = files.folder.appending(
                path: OwnRequestFile.name, directoryHint: .notDirectory)
        }

        // The log file of a failed job in the round folder: log-<job ID>-<round ID>.txt.
        package static func log(_ files: RoundFiles, job: JobID) -> URL {
            files.file("log-\(job.value)", "txt")
        }
    }

    // A failed Actions job of the head and its log.
    package struct Failed: Sendable, Equatable {
        package var name: String
        // nil only for a check that is not an Actions job. CILogs.read never gives one.
        package var job: JobID?
        // The conclusion of the check run, as GitHub gave it (for example FAILURE). Empty for a
        // check that did not fail: HeadChecks.failedJobs never gives one.
        package var conclusion: String
        // The log file in the round folder, or nil when the log is missing.
        package var log: URL?
        // True when Bifrost cut the start of the log (CILog.text).
        package var logCut: Bool
        // Why the log is missing, for example "gone" or "not read" (CILogs.read), or nil.
        package var logMissing: String?

        // A job and its log, with the file that holds the log text.
        package init(_ log: JobLog, file: URL?) {
            name = log.check.name
            job = log.check.job
            if case .failed(let conclusion) = log.check.outcome {
                self.conclusion = conclusion
            } else {
                conclusion = ""
            }
            self.log = file
            logCut = log.cut
            logMissing = log.missing
        }
    }

    // A failed check that is not an Actions job (HeadChecks.others): Bifrost has no log of it and
    // cannot re-run it.
    package struct Other: Sendable, Equatable {
        package var name: String
        // The conclusion of the check run, or the state of the status, as GitHub gave it.
        package var state: String
        // The page of the check, or nil.
        package var url: URL?

        package init(_ check: HeadCheck) {
            name = check.name
            if case .failed(let state) = check.outcome {
                self.state = state
            } else {
                state = ""
            }
            url = check.url
        }
    }

    // The fix rounds and the re-runs of the chain before this round (CIMark).
    package struct Tried: Sendable, Equatable {
        package var fixes: Int
        package var retries: Int

        package init(fixes: Int, retries: Int) {
            self.fixes = fixes
            self.retries = retries
        }
    }

    // The CI question of an earlier round and the answer of the user.
    package struct Answer: Sendable, Equatable {
        package var question: String
        package var answer: String

        package init(question: String, answer: String) {
            self.question = question
            self.answer = answer
        }
    }

    package var pr: PRKey
    // The token of the round. The result file must give it back.
    package var round: String
    package var url: String
    package var title: String
    package var baseRef: String
    package var headRef: String
    // The head of the round, the tip of the base branch that Bifrost fetched and their merge
    // base.
    package var headSHA: CommitID
    package var baseSHA: CommitID
    package var mergeBase: CommitID
    package var viewer: String
    package var failed: [Failed]
    package var other: [Other]
    // The actions that the result may give (CIRule.allowed). needs-you is always allowed.
    package var allowed: Set<CIAction>
    package var tried: Tried
    // The answer of the user when the round answers a CI question, else nil.
    package var answer: Answer?
    package var files: Files

    package init(
        pr: PRKey, round: String, url: String, title: String, baseRef: String, headRef: String,
        headSHA: CommitID, baseSHA: CommitID, mergeBase: CommitID, viewer: String,
        failed: [Failed], other: [Other], allowed: Set<CIAction>, tried: Tried, answer: Answer?,
        files: Files
    ) {
        self.pr = pr
        self.round = round
        self.url = url
        self.title = title
        self.baseRef = baseRef
        self.headRef = headRef
        self.headSHA = headSHA
        self.baseSHA = baseSHA
        self.mergeBase = mergeBase
        self.viewer = viewer
        self.failed = failed
        self.other = other
        self.allowed = allowed
        self.tried = tried
        self.answer = answer
        self.files = files
    }

    // MARK: - The file

    package func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }

    // The JSON of the input file. The failed jobs go in job ID order, and the allowed actions in
    // the order of their names. A missing log, a missing page, a full diff that is not in the
    // folder and a round with no answer are null, as the mode file says.
    package var json: JSONValue {
        let jobs = failed.sorted { ($0.job?.value ?? 0) < ($1.job?.value ?? 0) }
        let answered: JSONValue =
            answer.map { ["question": .string($0.question), "answer": .string($0.answer)] }
            ?? .null
        return [
            "version": .int(Self.version),
            "round": .string(round),
            "pr": [
                "key": .string(pr.text), "url": .string(url), "title": .string(title),
                "baseRef": .string(baseRef), "headRef": .string(headRef),
                "headSha": .string(headSHA.hex), "baseSha": .string(baseSHA.hex),
                "mergeBase": .string(mergeBase.hex),
            ],
            "viewer": .string(viewer),
            "failed": .array(jobs.map(\.json)),
            "other": .array(other.map(\.json)),
            "allowed": .array(allowed.map(\.rawValue).sorted().map(JSONValue.string)),
            "tried": ["fixes": .int(tried.fixes), "retries": .int(tried.retries)],
            "answer": answered,
            "files": [
                "result": .string(files.result.path(percentEncoded: false)),
                "mode": .string(files.mode.path(percentEncoded: false)),
                "fullDiff": .text(files.fullDiff?.path(percentEncoded: false)),
                "ownRequest": .string(files.ownRequest.path(percentEncoded: false)),
            ],
        ]
    }

    // The bytes of the input file: sorted keys, two spaces, and a line break at the end.
    package var fileData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(json)) ?? Data("{}".utf8)) + Data("\n".utf8)
    }
}

extension CIInput.Failed {
    fileprivate var json: JSONValue {
        [
            "name": .string(name), "job": job.map { .int($0.value) } ?? .null,
            "conclusion": .string(conclusion), "log": .text(log?.path(percentEncoded: false)),
            "logCut": .bool(logCut), "logMissing": .text(logMissing),
        ]
    }
}

extension CIInput.Other {
    fileprivate var json: JSONValue {
        ["name": .string(name), "state": .string(state), "url": .text(url?.absoluteString)]
    }
}
