// The records of the automatic work on a PR of the user (docs/behaviour/reviews.md, "The state"):
// the attempt of the conflict round on one pair of a head and a base, and the budget, the key of
// the handled failure and the question of the CI rounds. The file of the Electron app does not
// have these records. A save writes a field only when it has a value. A record that Bifrost can't
// read in full reads in the direction that starts no more automatic work on the PR. The user can
// still start a round with a click.
import BifrostFoundation
import Foundation

// The end of the conflict attempt on one pair of a head and a base.
package enum ConflictOutcome: Sendable, Equatable {
    // The attempt runs, or a restart goes on with it.
    case working
    // Bifrost pushed this merge commit.
    case pushed(CommitID)
    // The attempt failed, with the text that the row shows (ConflictFailure.message).
    case failed(String)
}

// The conflict attempt of a PR. Bifrost tries one time for each pair of a head commit and a base
// commit. File: conflict, with head, base, at, outcome (working, pushed or failed), merge (only
// when pushed) and reason (only when failed).
package struct ConflictMark: StoredValue, Sendable, Equatable {
    package var head: CommitID
    package var base: CommitID
    package var at: Date
    package var outcome: ConflictOutcome

    package init(head: CommitID, base: CommitID, at: Date, outcome: ConflictOutcome) {
        self.head = head
        self.base = base
        self.at = at
        self.outcome = outcome
    }

    // A mark keeps the pair that it tried, so no automatic round tries that pair again. A bad
    // time reads as the distant past. An unknown outcome, a pushed outcome with no merge commit
    // and a failed outcome with no reason read as a failure with no reason, and the row then
    // shows the tip of Resolve now. Only a mark with no head or no base goes.
    package init?(stored value: JSONValue, dropped: inout DroppedFields) {
        guard let object = StoredObject(value, place: "prs.conflict"),
            let head = object["head"]?.commitID, let base = object["base"]?.commitID
        else { return nil }
        let at = object["at"]?.time
        if at == nil { dropped.add(object.name("at")) }
        let outcome: ConflictOutcome? =
            switch object["outcome"]?.string {
            case "working"?: .working
            case "pushed"?: object["merge"]?.commitID.map { .pushed($0) }
            case "failed"?: object["reason"]?.string.map { .failed($0) }
            default: nil
            }
        if outcome == nil { dropped.add(object.name("outcome")) }
        self.init(
            head: head, base: base, at: at ?? .distantPast, outcome: outcome ?? .failed(""))
    }

    package var stored: JSONValue {
        var fields: [String: JSONValue] = [
            "head": .string(head.hex), "base": .string(base.hex), "at": .time(at),
        ]
        switch outcome {
        case .working:
            fields["outcome"] = "working"
        case .pushed(let merge):
            fields["outcome"] = "pushed"
            fields["merge"] = .string(merge.hex)
        case .failed(let reason):
            fields["outcome"] = "failed"
            fields["reason"] = .string(reason)
        }
        return .object(fields)
    }

    // True when the mark is for the head and the base of the PR in the poll.
    package func matches(_ pr: PullRequest) -> Bool {
        head.hex == pr.headSHA && base.hex == pr.baseSHA
    }
}

// The question of the CI rounds for the Answer panel: the text, the head commit and the names of
// the failed jobs that it is about. Claude asks it, or Bifrost asks it when the limits are
// reached or a CI round fails. File: question of the CI mark, with text, head, jobs, at, byClaude
// (only when true) and answer (only when the user answered).
package struct CIQuestion: StoredValue, Sendable, Equatable {
    // The most names of failed jobs that a question keeps. The first stay.
    package static let maxJobs = 5

    // At most Question.maxText UTF-16 units: a longer text is cut, so the file reads back.
    package var text: String {
        didSet { text = text.cut(utf16: Question.maxText) }
    }
    package var head: CommitID
    package var jobs: [String] {
        didSet { if jobs.count > Self.maxJobs { jobs = Array(jobs.prefix(Self.maxJobs)) } }
    }
    package var at: Date
    // True when Claude asked the question, false when Bifrost asked it.
    package var byClaude: Bool
    // The answer of the user, at most Question.maxAnswer UTF-16 units (a longer answer is cut).
    // nil until the user answers.
    package var answer: String? {
        didSet { answer = answer?.cut(utf16: Question.maxAnswer) }
    }

    package init(
        text: String, head: CommitID, jobs: [String], at: Date, byClaude: Bool,
        answer: String? = nil
    ) {
        self.text = text.cut(utf16: Question.maxText)
        self.head = head
        self.jobs = Array(jobs.prefix(Self.maxJobs))
        self.at = at
        self.byClaude = byClaude
        self.answer = answer?.cut(utf16: Question.maxAnswer)
    }

    // A text over its limit, or an answer of the wrong form, refuses the question, as for the
    // questions on comments. A name that is not a text goes.
    package init?(stored value: JSONValue, dropped: inout DroppedFields) {
        guard let object = StoredObject(value, place: "prs.ci.question"),
            let text = object["text"]?.string, text.utf16.count <= Question.maxText,
            let head = object["head"]?.commitID, let at = object["at"]?.time
        else { return nil }
        let answer = object["answer"]
        if let answer, answer.string.map({ $0.utf16.count <= Question.maxAnswer }) != true {
            return nil
        }
        self.init(
            text: text, head: head, jobs: object.list("jobs", &dropped, \.string), at: at,
            byClaude: object.flag("byClaude", &dropped), answer: answer?.string)
    }

    package var stored: JSONValue {
        var fields: [String: JSONValue] = [
            "text": .string(text), "head": .string(head.hex), "at": .time(at),
        ]
        if !jobs.isEmpty { fields["jobs"] = .array(jobs.map(JSONValue.string)) }
        if byClaude { fields["byClaude"] = true }
        if let answer { fields["answer"] = .string(answer) }
        return .object(fields)
    }
}

// The record of the CI rounds of a PR. The budget belongs to a chain: the head that the user
// pushed, then each commit that Bifrost pushed on top of it (a CI fix or a conflict merge). A new
// push of the user starts a new chain. File: ci, with chain, fixes, retries, handledHead,
// handled, retrying, question and userHandles.
package struct CIMark: StoredValue, Sendable, Equatable {
    // The commits of the chain, oldest first. The newest CIRule.maxChain stay.
    package var chain: [CommitID] {
        didSet {
            if chain.count > CIRule.maxChain { chain = Array(chain.suffix(CIRule.maxChain)) }
        }
    }
    // The fix rounds and the re-runs of the chain.
    package var fixes: Int
    package var retries: Int
    // The head and the failed job IDs of the last failure that a CI round took. The same failure
    // never starts a second round.
    package var handledHead: CommitID?
    package var handled: [JobID]
    // The head whose failed jobs Bifrost re-ran.
    package var retrying: CommitID?
    // The question of the CI rounds for the Answer panel.
    package var question: CIQuestion?
    // The head whose CI the user fixes: no CI round starts on it.
    package var userHandles: CommitID?

    package init(
        chain: [CommitID], fixes: Int = 0, retries: Int = 0, handledHead: CommitID? = nil,
        handled: [JobID] = [], retrying: CommitID? = nil, question: CIQuestion? = nil,
        userHandles: CommitID? = nil
    ) {
        self.chain = Array(chain.suffix(CIRule.maxChain))
        self.fixes = fixes
        self.retries = retries
        self.handledHead = handledHead
        self.handled = handled
        self.retrying = retrying
        self.question = question
        self.userHandles = userHandles
    }

    // A missing count is 0. When the read loses any field (a count, a commit, a job ID, the
    // question or a part of it), or the value is not an object, both counts read as their limits,
    // so no more fix or re-run starts on the chain. A chain with a bad commit reads as no chain.
    // A good save never writes the other fields with no chain, so a mark with no chain and with
    // any other field is damaged too: it loses its chain. Thus a mark with no chain and with spent
    // counts is a damaged mark. The names of the lost fields go in the dropped names, so the open
    // of the store logs them.
    package init?(stored value: JSONValue, dropped: inout DroppedFields) {
        var lost = DroppedFields()
        defer { for name in lost.names { dropped.add(name) } }
        guard let object = StoredObject(value, place: "prs.ci") else {
            lost.add("prs.ci")
            self.init(chain: [], fixes: CIRule.maxFixes, retries: CIRule.maxRetries)
            return
        }
        func count(_ key: String) -> Int {
            object.read(key, &lost) { $0.wholeNumber.flatMap { $0 >= 0 ? $0 : nil } } ?? 0
        }
        var chain = object.list("chain", &lost, \.commitID)
        if lost.names.contains(object.name("chain")) { chain = [] }
        if chain.isEmpty, object.fields.keys.contains(where: { $0 != "chain" && object[$0] != nil })
        {
            lost.add(object.name("chain"))
        }
        let fixes = count("fixes")
        let retries = count("retries")
        let handledHead = object.read("handledHead", &lost, \.commitID)
        let handled = object.list("handled", &lost) { $0.wholeNumber.flatMap(JobID.init) }
        let retrying = object.read("retrying", &lost, \.commitID)
        let question = object.read("question", &lost, CIQuestion.init(stored:dropped:))
        let userHandles = object.read("userHandles", &lost, \.commitID)
        let spent = !lost.names.isEmpty
        self.init(
            chain: chain, fixes: spent ? max(fixes, CIRule.maxFixes) : fixes,
            retries: spent ? max(retries, CIRule.maxRetries) : retries, handledHead: handledHead,
            handled: handled, retrying: retrying, question: question, userHandles: userHandles)
    }

    package var stored: JSONValue {
        var fields: [String: JSONValue] = [:]
        if !chain.isEmpty { fields["chain"] = .array(chain.map { .string($0.hex) }) }
        if fixes > 0 { fields["fixes"] = .int(fixes) }
        if retries > 0 { fields["retries"] = .int(retries) }
        if let handledHead { fields["handledHead"] = .string(handledHead.hex) }
        if !handled.isEmpty { fields["handled"] = .array(handled.map { .int($0.value) }) }
        if let retrying { fields["retrying"] = .string(retrying.hex) }
        if let question { fields["question"] = question.stored }
        if let userHandles { fields["userHandles"] = .string(userHandles.hex) }
        return .object(fields)
    }
}
