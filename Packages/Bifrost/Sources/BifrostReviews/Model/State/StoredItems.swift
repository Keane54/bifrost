// The stored items of state.json, with the field names of the Electron file (docs/behaviour/
// reviews.md, "The state"). These are the only forms of these items: the work rules and the
// outbox rules of the request rounds work on them.
import BifrostFoundation
import Foundation

// The kind of a PR session and of its round: a review of the PR of another person, or a request
// round that handles the comments on a PR of the user.
package enum PRSessionKind: String, Sendable, Equatable, CaseIterable {
    case review, request
}

// An item that Bifrost handled: when, and the newest GitHub time of its comments then. A newer
// trusted comment makes the item work again. A handled item of the first release can have no
// reply time.
package struct Handled: Sendable, Equatable, StoredValue {
    package var at: Date
    package var lastReplyAt: Date?

    package init(at: Date, lastReplyAt: Date?) {
        self.at = at
        self.lastReplyAt = lastReplyAt
    }

    package init?(stored value: JSONValue, dropped: inout DroppedFields) {
        guard let object = StoredObject(value, place: "prs.handled"),
            let at = object["at"]?.time
        else { return nil }
        self.at = at
        lastReplyAt = object.read("lastReplyAt", &dropped, \.time)
    }

    package var stored: JSONValue {
        ["at": .time(at), "lastReplyAt": .time(lastReplyAt)]
    }
}

// A question of Claude about one item, for the Answer panel. The key of the item in the map is
// its item ID.
package struct Question: Sendable, Equatable, StoredValue {
    // The kind of the item of the quote.
    package enum Kind: String, Sendable, Equatable {
        case thread, comment
    }

    // The limits in UTF-16 code units, as the Electron app counts them.
    package static let maxText = 500
    package static let maxPlace = 300
    package static let maxAnswer = 2_000
    package static let maxQuote = 600
    package static let maxAuthor = 60
    package static let maxURL = 500

    // The question. File: question.
    package var text: String
    // The place of the item: the file and the line, or the author of the comment. File: where.
    package var place: String
    // The quote of the comment of the reviewer: its author, its text and its link. A bad part
    // goes, and the question stays.
    package var author: String?
    package var body: String?
    package var url: URL?
    package var kind: Kind?
    package var at: Date
    // The answer of the user. nil until the user answers.
    package var answer: String?
    // The newest GitHub time of the comments of the item when the round read them.
    package var seenUntil: Date

    package init(
        text: String, place: String, author: String? = nil, body: String? = nil, url: URL? = nil,
        kind: Kind? = nil, at: Date, answer: String? = nil, seenUntil: Date
    ) {
        self.text = text
        self.place = place
        self.author = author
        self.body = body
        self.url = url
        self.kind = kind
        self.at = at
        self.answer = answer
        self.seenUntil = seenUntil
    }

    // A text over its limit, or an answer of the wrong form, refuses the question.
    package init?(stored value: JSONValue, dropped: inout DroppedFields) {
        guard let object = StoredObject(value, place: "prs.questions"),
            let text = object["question"]?.string, text.utf16.count <= Self.maxText,
            let place = object["where"]?.string, place.utf16.count <= Self.maxPlace,
            let at = object["at"]?.time, let seenUntil = object["seenUntil"]?.time
        else { return nil }
        let answer = object["answer"]
        if let answer, answer.string.map({ $0.utf16.count <= Self.maxAnswer }) != true {
            return nil
        }
        self.init(
            text: text, place: place, at: at, answer: answer?.string, seenUntil: seenUntil)
        author = object.read("author", &dropped) { $0.string.flatMap(Self.limited(Self.maxAuthor)) }
        body = object.read("body", &dropped) { $0.string.flatMap(Self.limited(Self.maxQuote)) }
        url = object.read("url", &dropped) { $0.string.flatMap(Self.commentURL) }
        kind = object.read("kind", &dropped) { $0.string.flatMap(Kind.init(rawValue:)) }
    }

    package var stored: JSONValue {
        var fields: [String: JSONValue] = [
            "question": .string(text), "where": .string(place), "at": .time(at),
            "answer": .text(answer), "seenUntil": .time(seenUntil),
        ]
        if let author { fields["author"] = .string(author) }
        if let body { fields["body"] = .string(body) }
        if let url { fields["url"] = .string(url.absoluteString) }
        if let kind { fields["kind"] = .string(kind.rawValue) }
        return .object(fields)
    }

    private static func limited(_ limit: Int) -> (String) -> String? {
        { $0.utf16.count <= limit ? $0 : nil }
    }

    // A link to a comment on github.com: https, the host github.com, no user, password or port,
    // and no space or control character, at most maxURL long.
    static func commentURL(_ text: String) -> URL? {
        guard (1...maxURL).contains(text.utf16.count),
            !text.unicodeScalars.contains(where: {
                $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F
            }),
            let url = URL(string: text), url.scheme == "https",
            url.host(percentEncoded: false)?.lowercased() == "github.com",
            url.user(percentEncoded: false) == nil, url.password(percentEncoded: false) == nil,
            url.port == nil
        else { return nil }
        return url
    }
}

// The state of one write of an outbox.
package enum PostState: String, Sendable, Equatable {
    // Planned, and not started.
    case todo
    // Started. GitHub can have made it, so a resume checks GitHub before it sends it again.
    case sending
    case done
    // Not sent, and never to be sent.
    case dropped
}

// One GitHub write of an outbox, or the commit before the push.
package enum PlannedWrite: Sendable, Equatable {
    // The fix commit: the paths, the message and, after the commit, its ID.
    case commit(paths: [String], message: String, commit: CommitID?)
    // The push of the fix. signed: the fix goes to GitHub through createSignedCommit, and commit
    // is then the commit that GitHub made. The outbox keeps the choice, so a resume uses it and
    // not the setting of now.
    case push(commit: CommitID?, signed: Bool)
    // A reply to a thread. A nil text is the "Fixed by" text. by is the commit that the text
    // names, and comment is the ID of the reply after GitHub made it.
    case reply(item: NodeID, text: String?, by: CommitID?, comment: NodeID?)
    case resolve(item: NodeID)
    // The answer to a top-level comment, with the quote of the request.
    case comment(item: NodeID, quote: String, text: String?, by: CommitID?, comment: NodeID?)
    // The new review requests. nil logins: the send finds the reviewers.
    case rerequest(logins: [String]?)

    // The kind of a write in the file. The raw values are the names of the cases. The writes that
    // are not about one item have the name of their kind as their ID (OutboxRules).
    package enum Kind: String, Sendable {
        case commit, push, reply, resolve, comment, rerequest
    }
}

// One write of an outbox and its state. The ID is unique in its outbox.
package struct OutboxPost: Sendable, Equatable {
    package var id: String
    package var state: PostState
    package var write: PlannedWrite

    package init(id: String, state: PostState, write: PlannedWrite) {
        self.id = id
        self.state = state
        self.write = write
    }

    // The item of a reply, a resolve or a comment.
    package var item: NodeID? {
        switch write {
        case .reply(let item, _, _, _), .resolve(let item), .comment(let item, _, _, _, _): item
        case .commit, .push, .rerequest: nil
        }
    }

    // nil when a field has the wrong form, also an optional field.
    package init?(stored value: JSONValue) {
        guard let fields = value.object, let id = fields["id"]?.string, !id.isEmpty,
            let state = fields["state"]?.string.flatMap(PostState.init(rawValue:)),
            let kind = fields["kind"]?.string.flatMap(PlannedWrite.Kind.init(rawValue:)),
            let commit = optional(fields["sha"], \.commitID),
            let by = optional(fields["by"], \.commitID),
            let comment = optional(fields["commentId"], \.nodeID),
            let logins = optional(fields["logins"], names),
            let signed = optional(fields["signed"], \.flag)
        else { return nil }
        let item = fields["itemId"]?.nodeID
        // A text is null (the "Fixed by" text) or a string. A missing text is not a text.
        let text: String?? =
            switch fields["text"] {
            case .null?: .some(nil)
            case .string(let text)?: .some(text)
            default: nil
            }
        switch kind {
        case .commit:
            guard let paths = fields["paths"].flatMap(names),
                let message = fields["message"]?.string
            else { return nil }
            write = .commit(paths: paths, message: message, commit: commit)
        case .push:
            write = .push(commit: commit, signed: signed == true)
        case .reply:
            guard let item, let text else { return nil }
            write = .reply(item: item, text: text, by: by, comment: comment)
        case .resolve:
            guard let item else { return nil }
            write = .resolve(item: item)
        case .comment:
            guard let item, let text, let quote = fields["quote"]?.string else { return nil }
            write = .comment(item: item, quote: quote, text: text, by: by, comment: comment)
        case .rerequest:
            write = .rerequest(logins: logins)
        }
        self.id = id
        self.state = state
    }

    package var stored: JSONValue {
        var fields: [String: JSONValue] = ["id": .string(id), "state": .string(state.rawValue)]
        func add(_ key: String, _ value: (some CustomStringConvertible)?) {
            if let value { fields[key] = .string(value.description) }
        }
        let kind: PlannedWrite.Kind
        switch write {
        case .commit(let paths, let message, let commit):
            kind = .commit
            fields["paths"] = .array(paths.map(JSONValue.string))
            fields["message"] = .string(message)
            add("sha", commit)
        case .push(let commit, let signed):
            kind = .push
            add("sha", commit)
            if signed { fields["signed"] = true }
        case .reply(let item, let text, let by, let comment):
            kind = .reply
            fields["itemId"] = .string(item.text)
            fields["text"] = .text(text)
            add("by", by)
            add("commentId", comment)
        case .resolve(let item):
            kind = .resolve
            fields["itemId"] = .string(item.text)
        case .comment(let item, let quote, let text, let by, let comment):
            kind = .comment
            fields["itemId"] = .string(item.text)
            fields["quote"] = .string(quote)
            fields["text"] = .text(text)
            add("by", by)
            add("commentId", comment)
        case .rerequest(let logins):
            kind = .rerequest
            if let logins { fields["logins"] = .array(logins.map(JSONValue.string)) }
        }
        fields["kind"] = .string(kind.rawValue)
        return .object(fields)
    }
}

// The writes of one request round, in their order, with the state of each. The outbox stays in
// the file until each write is done or dropped, so a restart goes on with the rest. An outbox is
// whole or nothing: one bad part drops it, so no part of a damaged list of writes is ever sent.
package struct Outbox: Sendable, Equatable, StoredValue {
    package var headSHA: CommitID
    package var mergeBase: CommitID
    package var startedAt: Date
    // Each item of the round, with the newest GitHub time of its comments when the round read
    // them.
    package var seen: [NodeID: Date]
    package var posts: [OutboxPost]

    package init(
        headSHA: CommitID, mergeBase: CommitID, startedAt: Date, seen: [NodeID: Date],
        posts: [OutboxPost]
    ) {
        self.headSHA = headSHA
        self.mergeBase = mergeBase
        self.startedAt = startedAt
        self.seen = seen
        self.posts = posts
    }

    package init?(stored value: JSONValue, dropped _: inout DroppedFields) {
        guard let fields = value.object, let headSHA = fields["headSha"]?.commitID,
            let mergeBase = fields["mergeBase"]?.commitID,
            let startedAt = fields["startedAt"]?.time,
            let seenFields = fields["seen"]?.object, let items = fields["posts"]?.array
        else { return nil }
        var seen: [NodeID: Date] = [:]
        for (text, value) in seenFields {
            guard let id = NodeID(text), let time = value.time else { return nil }
            seen[id] = time
        }
        var posts: [OutboxPost] = []
        for item in items {
            guard let post = OutboxPost(stored: item), !posts.contains(where: { $0.id == post.id })
            else { return nil }
            posts.append(post)
        }
        self.init(
            headSHA: headSHA, mergeBase: mergeBase, startedAt: startedAt, seen: seen, posts: posts)
    }

    package var stored: JSONValue {
        [
            "headSha": .string(headSHA.hex), "mergeBase": .string(mergeBase.hex),
            "startedAt": .time(startedAt), "seen": .times(seen),
            "posts": .array(posts.map(\.stored)),
        ]
    }
}

// An entry of the queue: a PR, the kind of its job and the time of the entry.
package struct QueueEntry: Sendable, Equatable, StoredValue {
    package var pr: PRKey
    package var kind: PRSessionKind
    package var at: Date

    package init(pr: PRKey, kind: PRSessionKind, at: Date) {
        self.pr = pr
        self.kind = kind
        self.at = at
    }

    package init?(stored value: JSONValue, dropped _: inout DroppedFields) {
        guard let fields = value.object, let pr = fields["key"]?.prKey,
            let kind = fields["kind"]?.string.flatMap(PRSessionKind.init(rawValue:)),
            let at = fields["at"]?.time
        else { return nil }
        self.init(pr: pr, kind: kind, at: at)
    }

    package var stored: JSONValue {
        ["key": .string(pr.text), "kind": .string(kind.rawValue), "at": .time(at)]
    }
}

// A comment that Bifrost posted, with its ID and its text.
package struct PostedComment: Sendable, Equatable, StoredValue {
    package var id: NodeID
    package var pr: PRKey
    package var body: String
    package var at: Date

    package init(id: NodeID, pr: PRKey, body: String, at: Date) {
        self.id = id
        self.pr = pr
        self.body = body
        self.at = at
    }

    package init?(stored value: JSONValue, dropped _: inout DroppedFields) {
        guard let fields = value.object, let id = fields["id"]?.nodeID,
            let pr = fields["prKey"]?.prKey, let body = fields["body"]?.string,
            let at = fields["at"]?.time
        else { return nil }
        self.init(id: id, pr: pr, body: body, at: at)
    }

    package var stored: JSONValue {
        ["id": .string(id.text), "prKey": .string(pr.text), "body": .string(body), "at": .time(at)]
    }
}

// A draft review comment that a review round left, with its review, its place and its text.
// File: an entry of drafts.
package struct DraftRecord: Sendable, Equatable, StoredValue {
    package var reviewID: NodeID
    package var pr: PRKey
    package var path: String
    package var line: Int
    package var body: String
    package var at: Date

    package init(reviewID: NodeID, pr: PRKey, path: String, line: Int, body: String, at: Date) {
        self.reviewID = reviewID
        self.pr = pr
        self.path = path
        self.line = line
        self.body = body
        self.at = at
    }

    package init?(stored value: JSONValue, dropped _: inout DroppedFields) {
        guard let fields = value.object, let reviewID = fields["reviewId"]?.nodeID,
            let pr = fields["prKey"]?.prKey, let path = fields["path"]?.string,
            let line = fields["line"]?.wholeNumber, let body = fields["body"]?.string,
            let at = fields["at"]?.time
        else { return nil }
        self.init(reviewID: reviewID, pr: pr, path: path, line: line, body: body, at: at)
    }

    package var stored: JSONValue {
        [
            "reviewId": .string(reviewID.text), "prKey": .string(pr.text), "path": .string(path),
            "line": .int(line), "body": .string(body), "at": .time(at),
        ]
    }
}

// A draft text and the text that the user sent, for the voice of the replies.
package struct VoicePair: Sendable, Equatable, StoredValue {
    package var pr: PRKey
    package var draft: String
    package var final: String
    package var at: Date

    package init(pr: PRKey, draft: String, final: String, at: Date) {
        self.pr = pr
        self.draft = draft
        self.final = final
        self.at = at
    }

    package init?(stored value: JSONValue, dropped _: inout DroppedFields) {
        guard let fields = value.object, let pr = fields["prKey"]?.prKey,
            let draft = fields["draft"]?.string, let final = fields["final"]?.string,
            let at = fields["at"]?.time
        else { return nil }
        self.init(pr: pr, draft: draft, final: final, at: at)
    }

    package var stored: JSONValue {
        [
            "prKey": .string(pr.text), "draft": .string(draft), "final": .string(final),
            "at": .time(at),
        ]
    }
}

// The first sight of a review request. baseline is true for a request that was open at the
// first turn-on, which never flashes. noticeWaitsForCI is true while the notification of a new
// request waits until its CI does not fail (ReviewsState.recordNotices). File: an entry of
// requests. noticeWaitsForCI is a field of Bifrost only: the Electron app did not write it. The
// file has it only while it is true, so a mark with no wait has the form of the Electron app.
package struct RequestMark: Sendable, Equatable, StoredValue {
    package var firstSeen: Date
    package var baseline: Bool
    package var noticeWaitsForCI: Bool

    package init(firstSeen: Date, baseline: Bool, noticeWaitsForCI: Bool = false) {
        self.firstSeen = firstSeen
        self.baseline = baseline
        self.noticeWaitsForCI = noticeWaitsForCI
    }

    package init?(stored value: JSONValue, dropped: inout DroppedFields) {
        guard let object = StoredObject(value, place: "requests"),
            let firstSeen = object["firstSeen"]?.time
        else { return nil }
        self.init(
            firstSeen: firstSeen, baseline: object.flag("baseline", &dropped),
            noticeWaitsForCI: object.flag("noticeWaitsForCI", &dropped))
    }

    package var stored: JSONValue {
        var fields: [String: JSONValue] = [
            "firstSeen": .time(firstSeen), "baseline": .bool(baseline),
        ]
        if noticeWaitsForCI { fields["noticeWaitsForCI"] = true }
        return .object(fields)
    }
}

// The trust notice of one repository: when Bifrost last told the user that its clone needs
// trust. File: an entry of repos.
package struct RepoMark: Sendable, Equatable, StoredValue {
    package var trustNotifiedAt: Date?

    package init(trustNotifiedAt: Date? = nil) {
        self.trustNotifiedAt = trustNotifiedAt
    }

    package init?(stored value: JSONValue, dropped: inout DroppedFields) {
        guard let object = StoredObject(value, place: "repos") else { return nil }
        trustNotifiedAt = object.read("trustNotifiedAt", &dropped, \.time)
    }

    package var stored: JSONValue {
        ["trustNotifiedAt": .time(trustNotifiedAt)]
    }
}

// An optional field of a write: .some(nil) when it is missing or null, .some(value) when make
// accepts it, and nil when make refuses it.
private func optional<Value>(_ value: JSONValue?, _ make: (JSONValue) -> Value?) -> Value?? {
    guard let value, value != .null else { return .some(nil) }
    return make(value).map { .some($0) }
}

// A list of texts that are not empty: the paths of a commit and the logins of the reviewers.
private func names(_ value: JSONValue) -> [String]? {
    guard let items = value.array else { return nil }
    let texts = items.compactMap(\.string).filter { !$0.isEmpty }
    return texts.count == items.count ? texts : nil
}
