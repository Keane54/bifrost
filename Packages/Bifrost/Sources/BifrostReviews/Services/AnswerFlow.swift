// The Answer panel of the My PRs tab (docs/behaviour/reviews.md, "The Answer panel"): the user
// answers the open questions of Claude on one PR, or says that they handle an item themselves.
// - The panel lists each open question of the PR (an unanswered Question of the state), oldest
//   first, with the place of its item and the quote of the reviewer's comment.
// - Send to Claude needs an answer or "I'll handle this one myself" for each question. It goes
//   through the request rounds (ReviewRounds.answerQuestions) in one call: the answers start one
//   request round, and a handled item becomes handled with no round. The answered items follow
//   the work rules of the rounds, so an answer never starts an automatic round by itself.
import BifrostFoundation
import Foundation
import Observation

// An open question of Claude, as the panel shows it.
package struct OpenQuestion: Sendable, Equatable, Identifiable {
    // The item of the question.
    package let id: NodeID
    package let question: Question

    // The line over the quote: "user-b on src/a.swift line 12" or "user-b on the PR", or only the
    // place when the question has no author or no kind.
    package var header: String {
        guard let author = question.author, let kind = question.kind else {
            return question.place
        }
        return kind == .comment ? "\(author) on the PR" : "\(author) on \(question.place)"
    }
}

@MainActor
@Observable
package final class AnswerFlow {
    // The most answers of one send.
    nonisolated package static let maxAnswers = 50

    package let pr: PRKey
    // The text of each answer, by item. A text is at most Question.maxAnswer characters.
    package private(set) var answers: [NodeID: String] = [:]
    // The items that the user handles themselves.
    package private(set) var handled: Set<NodeID> = []
    // True while the send runs.
    package private(set) var busy = false

    @ObservationIgnored private let store: ReviewsStore
    @ObservationIgnored private let send: @MainActor ([NodeID: QuestionAnswer]) async -> Bool

    // send gives the answers to the request rounds of the PR (ReviewRounds.answerQuestions) and
    // tells whether they took them.
    package init(
        pr: PRKey, store: ReviewsStore,
        send: @escaping @MainActor ([NodeID: QuestionAnswer]) async -> Bool
    ) {
        self.pr = pr
        self.store = store
        self.send = send
    }

    // The open questions of the PR, oldest first. Reviews that is off has none.
    package var questions: [OpenQuestion] {
        guard store.isOpen, let prState = store.state.prs[pr] else { return [] }
        return prState.questions.filter { $0.value.answer == nil }
            .sorted { ($0.value.at, $0.key.text) < ($1.value.at, $1.key.text) }
            .map { OpenQuestion(id: $0.key, question: $0.value) }
    }

    // The reason of the last failed round of the PR. The row shows Needs you while questions are
    // open, so the panel shows the reason.
    package var lastError: String? {
        store.isOpen ? store.state.prs[pr]?.lastError : nil
    }

    // True when the PR has more open questions than one send can take.
    package var tooMany: Bool { questions.count > Self.maxAnswers }

    // True when each question has an answer or is handled, and no send runs.
    package var canSubmit: Bool {
        let open = questions
        return !busy && !open.isEmpty && open.count <= Self.maxAnswers
            && open.allSatisfy { handled.contains($0.id) || !(answers[$0.id] ?? "").isBlank }
    }

    // The answer of the user to the question of the item. A longer text is cut to the limit.
    package func answer(_ item: NodeID, _ text: String) {
        answers[item] = Self.limited(text)
    }

    // "I'll handle this one myself" for the item, or off again.
    package func handleMyself(_ item: NodeID, _ on: Bool = true) {
        if on {
            handled.insert(item)
        } else {
            handled.remove(item)
        }
    }

    // Send to Claude: each answer starts one request round, and each handled item becomes
    // handled with no round. The result is false when the send didn't go: a question has no
    // answer, or the questions changed (the panel then shows them again).
    @discardableResult
    package func submit() async -> Bool {
        guard canSubmit else { return false }
        var list: [NodeID: QuestionAnswer] = [:]
        for question in questions {
            list[question.id] =
                handled.contains(question.id)
                ? .handleMyself : .text((answers[question.id] ?? "").trimmed())
        }
        busy = true
        defer { busy = false }
        return await send(list)
    }

    // The text cut to Question.maxAnswer UTF-16 code units, at a character edge.
    private static func limited(_ text: String) -> String {
        guard text.utf16.count > Question.maxAnswer else { return text }
        var cut = ""
        for character in text {
            guard cut.utf16.count + character.utf16.count <= Question.maxAnswer else { break }
            cut.append(character)
        }
        return cut
    }
}

extension String {
    // True for a text with nothing but white space.
    fileprivate var isBlank: Bool { trimmed().isEmpty }
}
