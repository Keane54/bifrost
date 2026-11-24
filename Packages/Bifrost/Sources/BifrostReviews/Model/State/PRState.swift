// The Reviews state of one PR, with the field names of the Electron file (docs/behaviour/
// reviews.md, "The state"). The pause end and the hidden mark of a PR are in the maps pauses and
// hidden of ReviewsState, as in the file.
import BifrostFoundation
import BifrostSessions
import Foundation

// A PR session: the Claude Code session of a round.
package struct SessionRef: Sendable, Equatable, StoredValue {
    package var sessionID: SessionID
    package var name: String
    package var shortID: ShortID?
    // The profile of the start flags of the session (PRSessionArgs.profile). A session of an
    // older file has none. File: profile.
    package var profile: String?
    // The rounds that the session ran. File: rounds, missing = 0.
    package var rounds: Int

    package init(
        sessionID: SessionID, name: String, shortID: ShortID? = nil, profile: String? = nil,
        rounds: Int = 0
    ) {
        self.sessionID = sessionID
        self.name = name
        self.shortID = shortID
        self.profile = profile
        self.rounds = rounds
    }

    package init?(stored value: JSONValue, dropped: inout DroppedFields) {
        guard let object = StoredObject(value, place: "prs.session"),
            let sessionID = object["sessionId"]?.string.flatMap({ SessionID($0) }),
            let name = object["name"]?.string
        else { return nil }
        let rounds = object.read("rounds", &dropped) { value in
            value.wholeNumber.flatMap { $0 >= 0 ? $0 : nil }
        }
        self.init(
            sessionID: sessionID, name: name,
            shortID: object.read("shortId", &dropped) { $0.string.flatMap { ShortID($0) } },
            profile: object.read("profile", &dropped, \.string), rounds: rounds ?? 0)
    }

    package var stored: JSONValue {
        var fields: [String: JSONValue] = [
            "sessionId": .string(sessionID.text), "name": .string(name),
        ]
        if let shortID { fields["shortId"] = .string(shortID.text) }
        if let profile { fields["profile"] = .string(profile) }
        if rounds > 0 { fields["rounds"] = .int(rounds) }
        return .object(fields)
    }
}

// The step of a round: it gets ready, its session runs, or Bifrost posts its result.
package enum RoundPhase: String, Sendable, Equatable {
    case preparing, running, posting
}

// The round of a PR that runs now.
package struct ActiveRound: Sendable, Equatable, StoredValue {
    package var phase: RoundPhase
    package var startedAt: Date
    // The time of the queue entry that started the round. File: at.
    package var at: Date
    package var headSHA: CommitID?
    // The base commit of the diff of the round, so a restart can make the diff again.
    package var baseSHA: CommitID?
    package var shortID: ShortID?
    package var sessionID: SessionID?
    package var stoppedByUser: Bool
    // A round with no kind in the file is a review round.
    package var kind: PRSessionKind
    // Request rounds: each item of the round with the newest GitHub time of its comments when
    // the round read them.
    package var items: [NodeID: Date]
    // Request rounds: the fix commit of the round.
    package var fixSHA: CommitID?
    // Review rounds: the token that the result of the session must give back. The Electron app
    // kept no token.
    package var token: String?
    // Conflict rounds: the commit with the conflict markers that the worktree of the round starts
    // from (the merge start in the clone of Bifrost). File: startSha.
    package var startSHA: CommitID?

    package init(
        phase: RoundPhase, startedAt: Date, at: Date, headSHA: CommitID? = nil,
        baseSHA: CommitID? = nil, shortID: ShortID? = nil, sessionID: SessionID? = nil,
        stoppedByUser: Bool = false, kind: PRSessionKind, items: [NodeID: Date] = [:],
        fixSHA: CommitID? = nil, token: String? = nil, startSHA: CommitID? = nil
    ) {
        self.phase = phase
        self.startedAt = startedAt
        self.at = at
        self.headSHA = headSHA
        self.baseSHA = baseSHA
        self.shortID = shortID
        self.sessionID = sessionID
        self.stoppedByUser = stoppedByUser
        self.kind = kind
        self.items = items
        self.fixSHA = fixSHA
        self.token = token
        self.startSHA = startSHA
    }

    // An unknown kind gives no round, so one job never acts on a round of another job.
    package init?(stored value: JSONValue, dropped: inout DroppedFields) {
        guard let object = StoredObject(value, place: "prs.round"),
            let phase = object["phase"]?.string.flatMap(RoundPhase.init(rawValue:)),
            let startedAt = object["startedAt"]?.time, let at = object["at"]?.time
        else { return nil }
        var kind = PRSessionKind.review
        if let value = object["kind"] {
            guard let known = value.string.flatMap(PRSessionKind.init(rawValue:)) else {
                return nil
            }
            kind = known
        }
        self.init(
            phase: phase, startedAt: startedAt, at: at,
            headSHA: object.read("headSha", &dropped, \.commitID),
            baseSHA: object.read("baseSha", &dropped, \.commitID),
            shortID: object.read("shortId", &dropped) { $0.string.flatMap { ShortID($0) } },
            sessionID: object.read("sessionId", &dropped) { $0.string.flatMap { SessionID($0) } },
            stoppedByUser: object.flag("stoppedByUser", &dropped), kind: kind,
            items: object.map("items", &dropped, key: NodeID.init, \.time),
            fixSHA: object.read("fixSha", &dropped, \.commitID),
            token: object.read("token", &dropped, \.string),
            startSHA: object.read("startSha", &dropped, \.commitID))
    }

    package var stored: JSONValue {
        var fields: [String: JSONValue] = [
            "phase": .string(phase.rawValue), "startedAt": .time(startedAt), "at": .time(at),
            "headSha": .text(headSHA?.hex), "shortId": .text(shortID?.text),
            "sessionId": .text(sessionID?.text), "stoppedByUser": .bool(stoppedByUser),
            "kind": .string(kind.rawValue),
        ]
        if let baseSHA { fields["baseSha"] = .string(baseSHA.hex) }
        if !items.isEmpty { fields["items"] = .times(items) }
        if let fixSHA { fields["fixSha"] = .string(fixSHA.hex) }
        if let token { fields["token"] = .string(token) }
        if let startSHA { fields["startSha"] = .string(startSHA.hex) }
        return .object(fields)
    }
}

// The recommendation of a review round.
package enum Recommendation: String, Sendable, Equatable, Codable {
    case approve, comment
    case requestChanges = "request-changes"
}

// The recommendation of the last review round, with the draft review that holds it.
package struct RecommendationMark: Sendable, Equatable, StoredValue {
    package var value: Recommendation
    package var why: String
    package var headSHA: CommitID
    // The draft review of the round. nil when the round left no draft.
    package var reviewID: NodeID?
    package var at: Date
    // True when the user deleted the draft with Approve and not with the Review panel. The row
    // then offers the Approve button. Only a mark with no draft can have a deleted draft.
    package var deleted: Bool

    package init(
        value: Recommendation, why: String, headSHA: CommitID, reviewID: NodeID?, at: Date,
        deleted: Bool = false
    ) {
        self.value = value
        self.why = why
        self.headSHA = headSHA
        self.reviewID = reviewID
        self.at = at
        self.deleted = deleted && reviewID == nil
    }

    package init?(stored value: JSONValue, dropped: inout DroppedFields) {
        guard let object = StoredObject(value, place: "prs.recommendation"),
            let mark = object["value"]?.string.flatMap(Recommendation.init(rawValue:)),
            let why = object["why"]?.string, let headSHA = object["headSha"]?.commitID,
            let at = object["at"]?.time
        else { return nil }
        self.init(
            value: mark, why: why, headSHA: headSHA,
            reviewID: object.read("reviewId", &dropped, \.nodeID), at: at,
            deleted: object.flag("deleted", &dropped))
    }

    package var stored: JSONValue {
        var fields: [String: JSONValue] = [
            "value": .string(value.rawValue), "why": .string(why), "headSha": .string(headSHA.hex),
            "reviewId": .text(reviewID?.text), "at": .time(at),
        ]
        if deleted { fields["deleted"] = true }
        return .object(fields)
    }
}

// The Reviews state of one PR: its sessions, its round, its handled, held and open items and
// the writes of its last request round.
package struct PRState: Sendable, Equatable, StoredValue {
    // The most held items of one PR. The newest stay.
    package static let maxHeld = 200

    // The items that Bifrost handled, by item ID.
    package var handled: [NodeID: Handled] = [:]
    // The first Copilot review: only its threads are work.
    package var firstCopilotReview: NodeID?
    package var lastReviewedCommit: CommitID?
    // The sessions of the PR. File: request and review.
    package var requestSession: SessionRef?
    package var reviewSession: SessionRef?
    // A Handle now click that waits for its round: the items from before fixFrom are work.
    package var handleOlder = false
    // A Handle Copilot comments click that waits for its round.
    package var handleCopilot = false
    // The reviewers that Bifrost asked for a new review, by login, each with the head commit of
    // the request. File: rerequested.
    package var askedReviewers: [String: CommitID] = [:]
    // The reason of the last failed or stopped round. The row shows it with Try again.
    package var lastError: String?
    // Why the work on the PR waits for the user (docs/behaviour/reviews.md, "Your own
    // requests"): an own request that Bifrost did not commit or push, or changes in the worktree
    // that no round made. The row shows Needs you with the reason. Files: waitsForYou and
    // waitsForYouFiles.
    package var waiting: WaitsForYou?

    // The reason of waiting.
    package var waitsForYou: String? { waiting?.reason }

    // A round stopped for the work of a person. A reason that is there already (an own request
    // that did not go) says more, so it stays. The files of the round are newer, so they
    // replace the files that are there. adoptsKind: a kind of the new value replaces the kind
    // other of the old value.
    package mutating func keepWaiting(_ new: WaitsForYou, adoptsKind: Bool) {
        var kept = waiting ?? new
        if !new.files.isEmpty {
            kept.files = new.files
            kept.fileCount = new.fileCount
        }
        if adoptsKind, kept.kind == .other { kept.kind = new.kind }
        waiting = kept
    }
    package var round: ActiveRound?
    package var recommendation: RecommendationMark?
    // The time of the last Review click or of the last posts of a round.
    package var actedAt: Date?
    // The writes of the last request round that are not all sent.
    package var outbox: Outbox?
    // The open questions of Claude, by item ID.
    package var questions: [NodeID: Question] = [:]
    // The items of a failed or a stopped request round, oldest first, each one time. They wait
    // for Try again, Handle now or a newer trusted comment.
    package var held: [NodeID] = []
    // The GitHub update time of the PR at the last full read of a request round.
    package var checkedAt: Date?
    // The conflict attempt on the last pair of a head and a base. File: conflict.
    package var conflict: ConflictMark?
    // The budget, the handled failure and the question of the CI rounds. File: ci.
    package var ci: CIMark?
    // A Resolve now click that waits for its conflict round, until the round ends. File:
    // resolveNow.
    package var resolveNow = false
    // True when the read of the record of the PR in the file dropped a field, or the record was
    // not an object. The record can then lack the conflict mark of a pair that Bifrost tried, so
    // the first poll that lists the PR counts its pair as tried (ReviewRounds.queueConflicts).
    // An explicit null in conflict or ci counts as a lost mark too. The file keeps the doubt
    // (markInDoubt, only when true) until a poll settles it, so a quit does not lose it.
    package var markInDoubt = false

    package init() {}

    // A value that is not an object gives the empty state, as the Electron app does.
    package init(stored value: JSONValue, dropped: inout DroppedFields) {
        self.init()
        var lost = DroppedFields()
        var savedDoubt = false
        defer {
            for name in lost.names { dropped.add(name) }
            markInDoubt = !lost.names.isEmpty || savedDoubt
        }
        guard let object = StoredObject(value, place: "prs") else {
            lost.add("prs")
            return
        }
        handled = object.map("handled", &lost, key: NodeID.init, Handled.init(stored:dropped:))
        firstCopilotReview = object.read("firstCopilotReview", &lost, \.nodeID)
        lastReviewedCommit = object.read("lastReviewedCommit", &lost, \.commitID)
        requestSession = object.read("request", &lost, SessionRef.init(stored:dropped:))
        reviewSession = object.read("review", &lost, SessionRef.init(stored:dropped:))
        handleOlder = object.flag("handleOlder", &lost)
        handleCopilot = object.flag("handleCopilot", &lost)
        askedReviewers = object.map(
            "rerequested", &lost, key: { $0.isEmpty ? nil : $0 }, \.commitID)
        lastError = object.read("lastError", &lost, \.string)
        if let reason = object.read("waitsForYou", &lost, \.string) {
            let files = object.list("waitsForYouFiles", &lost, \.string)
            let kind = object.read("waitsForYouKind", &lost, \.string)
                .flatMap(WaitsForYou.Kind.init(rawValue:))
            let count = object.read("waitsForYouFileCount", &lost) { $0.wholeNumber }
            waiting = WaitsForYou(
                reason: reason, files: files, fileCount: count, kind: kind ?? .other)
        }
        round = object.read("round", &lost, ActiveRound.init(stored:dropped:))
        recommendation = object.read(
            "recommendation", &lost, RecommendationMark.init(stored:dropped:))
        actedAt = object.read("actedAt", &lost, \.time)
        outbox = object.read("outbox", &lost, Outbox.init(stored:dropped:))
        questions = object.map(
            "questions", &lost, key: NodeID.init, Question.init(stored:dropped:))
        held = Self.newest(unique(object.list("held", &lost, \.nodeID)))
        checkedAt = object.read("checkedAt", &lost, \.time)
        conflict = object.read("conflict", &lost, ConflictMark.init(stored:dropped:))
        ci = object.read("ci", &lost, CIMark.init(stored:dropped:))
        resolveNow = object.flag("resolveNow", &lost)
        // Bifrost never writes null here, so a null is a mark that something damaged.
        for key in ["conflict", "ci"] where object.fields[key] == .null {
            lost.add(object.name(key))
        }
        savedDoubt = object.flag("markInDoubt", &lost)
    }

    package var stored: JSONValue {
        var fields: [String: JSONValue] = [
            "handled": .stored(handled),
            "firstCopilotReview": .text(firstCopilotReview?.text),
            "lastReviewedCommit": .text(lastReviewedCommit?.hex),
            "request": requestSession?.stored ?? .null,
            "review": reviewSession?.stored ?? .null,
            "handleOlder": .bool(handleOlder),
            "handleCopilot": .bool(handleCopilot),
            "rerequested": .object(askedReviewers.mapValues { .string($0.hex) }),
            "lastError": .text(lastError),
            "round": round?.stored ?? .null,
            "recommendation": recommendation?.stored ?? .null,
            "actedAt": .time(actedAt),
            "outbox": outbox?.stored ?? .null,
            "questions": .stored(questions),
            "held": .array(held.map { .string($0.text) }),
            "checkedAt": .time(checkedAt),
        ]
        if let waiting {
            fields["waitsForYou"] = .string(waiting.reason)
            if !waiting.files.isEmpty {
                fields["waitsForYouFiles"] = .array(waiting.files.map(JSONValue.string))
                if waiting.fileCount > waiting.files.count {
                    fields["waitsForYouFileCount"] = .int(waiting.fileCount)
                }
            }
            if waiting.kind != .other { fields["waitsForYouKind"] = .string(waiting.kind.rawValue) }
        }
        if let conflict { fields["conflict"] = conflict.stored }
        if let ci { fields["ci"] = ci.stored }
        if markInDoubt { fields["markInDoubt"] = .bool(true) }
        if resolveNow { fields["resolveNow"] = true }
        return .object(fields)
    }

    // Add the items to the held items. Each item shows one time, at its newest place. The newest
    // maxHeld stay.
    package mutating func hold(_ items: some Sequence<NodeID>) {
        let added = unique(Array(items))
        let new = Set(added)
        held = Self.newest(held.filter { !new.contains($0) } + added)
    }

    // Drop the outbox: each item whose writes all went is handled, with the time that the round
    // read as its reply time, and the other items of the outbox are held. The result is the
    // items that it handled.
    @discardableResult
    package mutating func dropOutbox(now: Date) -> Set<NodeID> {
        guard let outbox else { return [] }
        var states: [NodeID: [PostState]] = [:]
        var order: [NodeID] = []
        for post in outbox.posts {
            guard let item = post.item else { continue }
            if states[item] == nil { order.append(item) }
            states[item, default: []].append(post.state)
        }
        let done = order.filter { states[$0]?.allSatisfy { $0 == .done } == true }
        for item in done {
            handled[item] = Handled(at: now, lastReplyAt: outbox.seen[item] ?? now)
        }
        let finished = Set(done)
        held.removeAll { finished.contains($0) }
        hold(order.filter { !finished.contains($0) })
        self.outbox = nil
        return finished
    }

    private static func newest(_ items: [NodeID]) -> [NodeID] {
        Array(items.suffix(maxHeld))
    }
}

// Why the work on a PR waits for the user, and the files of the worktree that are not on GitHub,
// as Bifrost found them at that time: the changes that the safety net stopped a round for, or the
// change of an own request that did not go. With files, the row offers Discard these changes.
package struct WaitsForYou: Sendable, Equatable {
    // The cause decides the short text of the row. other keeps Needs you with the reason as tip.
    package enum Kind: String, Sendable {
        // The safety net stopped a conflict round for changes that are not on GitHub.
        case unpushed
        // The user asked for a change while Claude resolved conflicts.
        case askAgain
        // The safety net stopped a request round for changes that are not on GitHub.
        case unpushedRequest
        case other
    }

    // The state keeps at most this count of names. Discard these changes and the drop read the
    // worktree again for the real list.
    package static let maxNames = 5

    package var reason: String
    // The first names of the files, sorted as the caller gave them. A bigger list shortens here,
    // and fileCount holds the full count.
    package private(set) var names: [String]
    package var fileCount: Int
    package var kind: Kind

    // The files in the state: the first names (maxNames). Setting the files sets the count too.
    package var files: [String] {
        get { names }
        set {
            names = Array(newValue.prefix(Self.maxNames))
            fileCount = newValue.count
        }
    }

    package init(reason: String, files: [String] = [], fileCount: Int? = nil, kind: Kind = .other) {
        self.reason = reason
        names = Array(files.prefix(Self.maxNames))
        self.fileCount = max(fileCount ?? files.count, names.count)
        self.kind = kind
    }
}

// The items in their order, each one time at its first place.
private func unique(_ items: [NodeID]) -> [NodeID] {
    var seen: Set<NodeID> = []
    return items.filter { seen.insert($0).inserted }
}
