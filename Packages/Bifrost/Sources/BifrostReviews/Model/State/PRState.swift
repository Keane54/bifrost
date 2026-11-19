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

    package init(sessionID: SessionID, name: String, shortID: ShortID? = nil) {
        self.sessionID = sessionID
        self.name = name
        self.shortID = shortID
    }

    package init?(stored value: JSONValue, dropped: inout DroppedFields) {
        guard let object = StoredObject(value, place: "prs.session"),
            let sessionID = object["sessionId"]?.string.flatMap({ SessionID($0) }),
            let name = object["name"]?.string
        else { return nil }
        self.init(
            sessionID: sessionID, name: name,
            shortID: object.read("shortId", &dropped) { $0.string.flatMap { ShortID($0) } })
    }

    package var stored: JSONValue {
        var fields: [String: JSONValue] = [
            "sessionId": .string(sessionID.text), "name": .string(name),
        ]
        if let shortID { fields["shortId"] = .string(shortID.text) }
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

    package init(
        phase: RoundPhase, startedAt: Date, at: Date, headSHA: CommitID? = nil,
        baseSHA: CommitID? = nil, shortID: ShortID? = nil, sessionID: SessionID? = nil,
        stoppedByUser: Bool = false, kind: PRSessionKind, items: [NodeID: Date] = [:],
        fixSHA: CommitID? = nil, token: String? = nil
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
    }

    // An unknown kind gives no round, so one job never acts on a round of the other job.
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
            token: object.read("token", &dropped, \.string))
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

    package init() {}

    // A value that is not an object gives the empty state, as the Electron app does.
    package init(stored value: JSONValue, dropped: inout DroppedFields) {
        self.init()
        guard let object = StoredObject(value, place: "prs") else {
            dropped.add("prs")
            return
        }
        handled = object.map("handled", &dropped, key: NodeID.init, Handled.init(stored:dropped:))
        firstCopilotReview = object.read("firstCopilotReview", &dropped, \.nodeID)
        lastReviewedCommit = object.read("lastReviewedCommit", &dropped, \.commitID)
        requestSession = object.read("request", &dropped, SessionRef.init(stored:dropped:))
        reviewSession = object.read("review", &dropped, SessionRef.init(stored:dropped:))
        handleOlder = object.flag("handleOlder", &dropped)
        handleCopilot = object.flag("handleCopilot", &dropped)
        askedReviewers = object.map(
            "rerequested", &dropped, key: { $0.isEmpty ? nil : $0 }, \.commitID)
        lastError = object.read("lastError", &dropped, \.string)
        round = object.read("round", &dropped, ActiveRound.init(stored:dropped:))
        recommendation = object.read(
            "recommendation", &dropped, RecommendationMark.init(stored:dropped:))
        actedAt = object.read("actedAt", &dropped, \.time)
        outbox = object.read("outbox", &dropped, Outbox.init(stored:dropped:))
        questions = object.map(
            "questions", &dropped, key: NodeID.init, Question.init(stored:dropped:))
        held = Self.newest(unique(object.list("held", &dropped, \.nodeID)))
        checkedAt = object.read("checkedAt", &dropped, \.time)
    }

    package var stored: JSONValue {
        [
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

// The items in their order, each one time at its first place.
private func unique(_ items: [NodeID]) -> [NodeID] {
    var seen: Set<NodeID> = []
    return items.filter { seen.insert($0).inserted }
}
