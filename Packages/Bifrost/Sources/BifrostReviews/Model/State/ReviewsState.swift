// The Reviews state: what Bifrost keeps in ~/.bifrost/reviews/state.json (docs/behaviour/
// reviews.md, "The state"). The file keeps the form and the field names of the Electron app, and
// every field is optional in it, so a file of each Electron release opens with no change. The
// keys of the PR maps are PRKey values: a lookup ignores case, and a save writes PRKey.text.
import BifrostFoundation
import Foundation

package struct ReviewsState: Sendable, Equatable, StoredValue {
    // The version of the file. A file of another version gives the empty state.
    package static let version = 1
    // The caps of the lists. The queue keeps its oldest entries, because the oldest entry runs
    // first. The other lists keep their newest entries.
    package static let maxQueue = 200
    package static let maxPosted = 2_000
    package static let maxDrafts = 2_000
    package static let maxVoicePairs = 1_000
    // The reason of each request round that the take-over stopped.
    package static let takeOverReason =
        "Bifrost stopped this round before it finished. Choose Try again."

    // The time of the first turn-on.
    package var turnedOnAt: Date?
    // The items (GitHub node IDs) that were open at the first turn-on.
    package var baseline: [NodeID] = []
    // The first sight of each review request.
    package var requests: [PRKey: RequestMark] = [:]
    // The end of the pause of each paused PR.
    package var pauses: [PRKey: Date] = [:]
    // The state of each PR that Bifrost acted on.
    package var prs: [PRKey: PRState] = [:]
    // The comments that Bifrost posted, oldest first.
    package var posted: [PostedComment] = []
    // The draft review comments of the review rounds, oldest first.
    package var drafts: [DraftRecord] = []
    // The draft texts and the texts that the user sent, oldest first.
    package var voicePairs: [VoicePair] = []
    // One entry for each PR and kind, oldest first.
    package var queue: [QueueEntry] = []
    // The trust notice of each repository with a clone.
    package var repos: [RepoName: RepoMark] = [:]
    // The end of the trust set-up. nil until the set-up ran.
    package var setUpAt: Date?
    // An item from before this time is older: it waits for Handle now.
    package var fixFrom: Date?
    // true: the user turned on "Handle comments on my PRs automatically" in this app and
    // confirmed it. false: the take-over asks for that confirm. nil: nothing asked for it. Only
    // true lets an automatic request round start (allowsAutoFix).
    package var autoFixConsent: Bool?
    // true: the user turned on "Resolve merge conflicts automatically" in this app and confirmed
    // it. nil: nothing asked for it. Only true lets an automatic conflict round start
    // (allowsConflictFix). The file of the Electron app does not have this field.
    package var conflictConsent: Bool?
    // true: the user turned on "Fix failing CI automatically" in this app and confirmed it. nil:
    // nothing asked for it. Only true lets a CI round start, and only true gives the CIConsent of
    // a re-run (ciConsent(_:)). The file of the Electron app does not have this field.
    package var ciConsent: Bool?
    // The To review PRs that the user removed in Bifrost, with the time of the remove. A new
    // review request after that time shows the PR again.
    package var hidden: [PRKey: Date] = [:]
    // The top-level fields that the state does not know. A save writes them back.
    package var unknown = UnknownFields()
    // True when the read of the PR records lost a record: prs was not an object, a key was not a
    // PR, two keys named one PR, or a record was not an object. A lost record can hold the
    // conflict mark of a pair that Bifrost tried, so each PR of the next complete poll counts its
    // pair as tried (ReviewRounds.queueConflicts). The file does not keep it.
    package var marksInDoubt = false

    package init() {}

    // The names of the top-level fields of the file.
    private static let known: Set<String> = [
        "version", "turnedOnAt", "baseline", "requests", "pauses", "prs", "posted", "drafts",
        "voicePairs", "queue", "repos", "setUpAt", "fixFrom", "autoFixConsent",
        "conflictConsent", "ciConsent", "hidden",
    ]

    // A value that is not an object gives the empty state. A version other than 1 gives the
    // empty state with the unknown fields, and drops each known field of the file.
    package init(stored value: JSONValue, dropped: inout DroppedFields) {
        self.init()
        guard let object = StoredObject(value, place: "") else { return }
        unknown = UnknownFields(object.fields, known: Self.known)
        guard object["version"]?.wholeNumber == Self.version else {
            for key in object.fields.keys where Self.known.contains(key) { dropped.add(key) }
            return
        }
        turnedOnAt = object.read("turnedOnAt", &dropped, \.time)
        baseline = object.list("baseline", &dropped, \.nodeID)
        requests = object.map(
            "requests", &dropped, key: { PRKey(text: $0) }, RequestMark.init(stored:dropped:))
        pauses = object.map("pauses", &dropped, key: { PRKey(text: $0) }, \.time)
        var lost = DroppedFields()
        prs = object.map("prs", &lost, key: { PRKey(text: $0) }) { value, dropped in
            PRState(stored: value, dropped: &dropped)
        }
        for name in lost.names { dropped.add(name) }
        marksInDoubt = lost.names.contains("prs")
        posted = Self.newest(object.entries("posted", &dropped), Self.maxPosted, \.at)
        drafts = Self.newest(object.entries("drafts", &dropped), Self.maxDrafts, \.at)
        voicePairs = Self.newest(
            object.entries("voicePairs", &dropped), Self.maxVoicePairs, \.at)
        queue = Self.queue(object.entries("queue", &dropped))
        repos = object.map("repos", &dropped, key: RepoName.init, RepoMark.init(stored:dropped:))
        setUpAt = object.read("setUpAt", &dropped, \.time)
        fixFrom = object.read("fixFrom", &dropped, \.time)
        autoFixConsent = object.read("autoFixConsent", &dropped, \.flag)
        conflictConsent = object.read("conflictConsent", &dropped, \.flag)
        ciConsent = object.read("ciConsent", &dropped, \.flag)
        hidden = object.map("hidden", &dropped, key: { PRKey(text: $0) }, \.time)
    }

    package var stored: JSONValue {
        .object(
            unknown.merged(with: [
                "version": .int(Self.version),
                "turnedOnAt": .time(turnedOnAt),
                "baseline": .array(baseline.map { .string($0.text) }),
                "requests": .stored(requests),
                "pauses": .times(pauses),
                "prs": .stored(prs),
                "posted": .array(posted.map(\.stored)),
                "drafts": .array(drafts.map(\.stored)),
                "voicePairs": .array(voicePairs.map(\.stored)),
                "queue": .array(queue.map(\.stored)),
                "repos": .stored(repos),
                "setUpAt": .time(setUpAt),
                "fixFrom": .time(fixFrom),
                "autoFixConsent": autoFixConsent.map(JSONValue.bool) ?? .null,
                "conflictConsent": conflictConsent.map(JSONValue.bool) ?? .null,
                "ciConsent": ciConsent.map(JSONValue.bool) ?? .null,
                "hidden": .times(hidden),
            ]))
    }

    // True when new work on a PR of the user can start a request round by itself: the setting
    // "Handle comments on my PRs automatically" is on (autoFix), and the user confirmed it in this
    // app (autoFixConsent is true). No consent (nil) waits as a refusal (false) does.
    package func allowsAutoFix(_ autoFix: Bool) -> Bool {
        autoFix && autoFixConsent == true
    }

    // The user turned on "Handle comments on my PRs automatically" in this app and confirmed it.
    // The automatic request rounds can start, and only the work from now on is new: an item from
    // before now waits for Handle now.
    package mutating func consentToAutoFix(now: Date) {
        autoFixConsent = true
        fixFrom = now
    }

    // True when a conflict on a PR of the user can start a conflict round by itself: the setting
    // "Resolve merge conflicts automatically" is on, and the user confirmed it in this app
    // (conflictConsent is true).
    package func allowsConflictFix(_ setting: Bool) -> Bool {
        setting && conflictConsent == true
    }

    // True when a failed CI on a PR of the user can start a CI round by itself: the setting "Fix
    // failing CI automatically" is on, and the user confirmed it in this app (ciConsent is true).
    package func allowsCIFix(_ setting: Bool) -> Bool {
        setting && ciConsent == true
    }

    // The proof of the CI consent that a re-run of failed jobs needs, or nil when the setting is
    // off or the user did not confirm it in this app. Only the state can make the proof.
    package func ciConsent(_ setting: Bool) -> CIConsent? {
        allowsCIFix(setting) ? CIConsent() : nil
    }

    // The user turned on "Resolve merge conflicts automatically" in this app and confirmed it.
    // The start of new work (fixFrom) does not change: the confirm text tells the user that a PR
    // that has conflicts now is in the work too.
    package mutating func consentToConflictFix() {
        conflictConsent = true
    }

    // The user turned on "Fix failing CI automatically" in this app and confirmed it. The start of
    // new work (fixFrom) does not change: the confirm text tells the user that a PR whose CI
    // fails now is in the work too.
    package mutating func consentToCIFix() {
        ciConsent = true
    }

    // The entries in the order of their times (a stable sort), with the newest limit kept.
    private static func newest<Entry>(
        _ entries: [Entry], _ limit: Int, _ time: (Entry) -> Date
    ) -> [Entry] {
        let sorted = entries.enumerated().sorted {
            (time($0.element), $0.offset) < (time($1.element), $1.offset)
        }
        return sorted.suffix(limit).map(\.element)
    }

    // The queue in the order of its times. For one PR and kind, the oldest entry wins. The oldest
    // maxQueue entries stay.
    private static func queue(_ entries: [QueueEntry]) -> [QueueEntry] {
        var seen: Set<QueueSlot> = []
        let unique = newest(entries, entries.count, \.at).filter {
            seen.insert(QueueSlot(pr: $0.pr, kind: $0.kind)).inserted
        }
        return Array(unique.prefix(maxQueue))
    }

    // The take-over of the Electron state at the first open (docs/behaviour/reviews.md, "The
    // take-over"). No round of the Electron app writes to GitHub or pushes by itself after it:
    // - No automatic request round starts until the user turns on "Handle comments on my PRs
    //   automatically" in this app and confirms: the consent is false, and the new work starts
    //   now.
    // - Each outbox goes: the items whose writes all went are handled, and the other items are
    //   held. Each request round stops, and its items are held. A PR with an unsent write or a
    //   stopped round gets the reason, so its row offers Try again.
    // - The request entries of the queue go. Each Handle now and Handle Copilot comments click
    //   goes too, also one with no entry (the Electron app kept a click after some failures).
    // - Each answered question is held: the round of its answer was in the queue or ran.
    // - The review rounds, the review entries, the clones and the hidden rows stay as they are.
    package mutating func takeOver(now: Date) {
        autoFixConsent = false
        fixFrom = now
        queue.removeAll { $0.kind == .request }
        for key in Array(prs.keys) {
            guard var pr = prs[key] else { continue }
            var stopped = false
            var finished: Set<NodeID> = []
            if let outbox = pr.outbox {
                stopped = outbox.posts.contains { $0.state == .todo || $0.state == .sending }
                finished = pr.dropOutbox(now: now)
            }
            if let round = pr.round, round.kind == .request {
                pr.hold(round.items.keys.filter { !finished.contains($0) }.inOrder(of: round))
                pr.round = nil
                stopped = true
            }
            let held = Set(pr.held)
            pr.hold(
                pr.questions.filter { $0.value.answer != nil && !held.contains($0.key) }
                    .sorted { ($0.value.at, $0.key.text) < ($1.value.at, $1.key.text) }
                    .map(\.key))
            if stopped { pr.lastError = Self.takeOverReason }
            pr.handleOlder = false
            pr.handleCopilot = false
            prs[key] = pr
        }
    }
}

// The proof that the user turned on "Fix failing CI automatically" in this app and confirmed it,
// while the setting is on. Only ReviewsState.ciConsent(_:) makes it, so a write that needs it (a
// re-run of failed jobs) cannot start without the consent.
package struct CIConsent: Sendable, Equatable {
    fileprivate init() {}
}

// The pair that the queue holds one time.
private struct QueueSlot: Hashable {
    let pr: PRKey
    let kind: PRSessionKind
}

extension Sequence<NodeID> {
    // The items of a round in the order of their times, then of their IDs.
    fileprivate func inOrder(of round: ActiveRound) -> [NodeID] {
        sorted {
            let left = round.items[$0] ?? .distantPast
            let right = round.items[$1] ?? .distantPast
            return left == right ? $0.text < $1.text : left < right
        }
    }
}

extension StoredObject {
    // The entries of a list of a stored type. A bad entry goes and drops the field.
    fileprivate func entries<Entry: StoredValue>(
        _ key: String, _ dropped: inout DroppedFields
    ) -> [Entry] {
        var inner = DroppedFields()
        let entries = list(key, &dropped) { Entry(stored: $0, dropped: &inner) }
        for name in inner.names { dropped.add(name) }
        return entries
    }
}

// The version of a state file, against the version that this app writes.
package enum StateVersion: Sendable, Equatable {
    // The version of this app, or no file.
    case current
    // A number above the version of this app: the file of a newer app.
    case later
    // No version, a value that is not a number, or a number below the version of this app.
    case unknown

    init(_ fields: [String: JSONValue]) {
        let current = Double(ReviewsState.version)
        switch fields["version"]?.finiteNumber {
        case current?: self = .current
        case let number? where number > current: self = .later
        default: self = .unknown
        }
    }
}

// What the decode of state.json gives: the state, the names of the fields that it dropped and the
// version of the file. A value with no JSON form, and a root that is not an object, make the file
// a file that does not parse, so the store keeps a copy of it before its first save and logs
// where the copy is (FileSaver). So the store never writes over such a file in silence.
package struct StoredReviewsState: Sendable, Decodable {
    package let state: ReviewsState
    // The dropped names, in sorted order.
    package let dropped: [String]
    // The store never writes over a file of another version.
    package let version: StateVersion

    // The value of a missing file: the empty state.
    package init() {
        state = ReviewsState()
        dropped = []
        version = .current
    }

    package init(from decoder: any Decoder) throws {
        let value: JSONValue
        do {
            value = try JSONValue(from: decoder)
        } catch {
            throw NoJSONForm()
        }
        guard case .object = value else { throw NoJSONForm() }
        var names = DroppedFields()
        state = ReviewsState(stored: value, dropped: &names)
        dropped = names.sorted
        version = StateVersion(value.object ?? [:])
    }
}
