// The row menu of the Reviews panel (docs/behaviour/reviews.md, "The panel") on the Bifrost menu:
// only the items that apply to the row, in the order of the menu of the Electron app. Only
// Approve writes to GitHub, and only with the click of the user (a UserClick that the menu makes
// at the choice): Review starts a round, which leaves only a pending review; Comment, Request
// changes and See Claude's review open the Review panel, whose buttons make their own clicks; and
// Handle now, Handle Copilot comments and Try again on a PR of the user start a request round,
// whose result Bifrost checks before it posts.
//
// The menu shows the row of now and follows it, as the row menu of a session does
// (FollowingMenu): each change of the rows gives it the items of the row of now, and it closes
// when the row leaves its tab. A choice acts on the row of now (ReviewsPanelModel.choose).
import AppKit
import BifrostReviews

// An item of the row menu, or a button of the row. The raw value is the ID of its menu row.
package enum ReviewsMenuItem: String, Sendable, CaseIterable {
    case openOnGitHub = "open-on-github"
    case openSession = "open-session"
    case approve
    // Open the Review panel for Claude's Comment or Request changes draft.
    case comment
    case requestChanges = "request-changes"
    // Open the Review panel on Claude's note and findings of an approval. It is not a button.
    case seeReview = "see-review"
    case review
    case tryAgain = "try-again"
    case remove
    case cancelReview = "cancel-review"
    case stopSession = "stop-session"
    case pause
    case endPause = "end-pause"
    case answerClaude = "answer-claude"
    case handleNow = "handle-now"
    case handleCopilot = "handle-copilot"
    case resolveNow = "resolve-now"
    case cancel
    case dropUpdates = "drop-updates"
    case discardChanges = "discard-changes"

    package var label: String {
        switch self {
        case .openOnGitHub: "Open on GitHub"
        case .openSession: "Open session"
        case .approve: "Approve"
        case .comment: "Comment"
        case .requestChanges: "Request changes"
        case .seeReview: "See Claude's review"
        case .review: "Review"
        case .tryAgain: "Try again"
        case .remove: "Remove"
        case .cancelReview: "Cancel review"
        case .stopSession: "Stop session"
        case .pause: "Pause"
        case .endPause: "End pause now"
        case .answerClaude: "Answer Claude"
        case .handleNow: "Handle now"
        case .handleCopilot: "Handle Copilot comments"
        case .resolveNow: "Resolve now"
        case .cancel: "Cancel"
        case .dropUpdates: "Don't send the rest"
        case .discardChanges: "Discard these changes"
        }
    }
}

@MainActor
package enum ReviewsMenu {
    // The items of the row, in their order: Open on GitHub for each row; Open session while the
    // PR has a session that is not parked; Approve while the row offers it and CI doesn't run;
    // Comment or Request changes while the row offers Claude's draft; See Claude's review while
    // the row shows an approval with Claude's note or findings; Review (Try again on a failed
    // row) while a round can start; Remove for a row that others approved; Cancel review for a
    // review that waits; Stop session; Pause for a new request and End pause now for a paused
    // row. A My PRs row has its own items (mineItems).
    package static func items(_ row: ReviewRow, hasSession: Bool) -> [ReviewsMenuItem] {
        guard case .toReview(let state) = row.state else {
            return mineItems(row, hasSession: hasSession)
        }
        var items: [ReviewsMenuItem] = [.openOnGitHub]
        if hasSession { items.append(.openSession) }
        if row.approve == .ready { items.append(.approve) }
        if let draft = row.draft { items.append(draftItem(draft)) }
        if row.findingsPanel { items.append(.seeReview) }
        if row.reviewable {
            if case .failed = state { items.append(.tryAgain) } else { items.append(.review) }
        }
        switch state {
        case .approvedByOthers: items.append(.remove)
        case .queued, .trustNeeded: items.append(.cancelReview)
        case .newRequest, .paused, .draftReady, .reviewed, .newCommits, .failed, .waitingForYou,
            .reviewing,
            .youApproved, .youRequestedChanges, .youCommented, .teamRequest:
            break
        }
        if hasSession { items.append(.stopSession) }
        switch state {
        case .newRequest: items.append(.pause)
        case .paused: items.append(.endPause)
        case .draftReady, .reviewed, .newCommits, .failed, .waitingForYou, .trustNeeded,
            .reviewing, .queued, .youApproved, .youRequestedChanges, .youCommented,
            .approvedByOthers, .teamRequest:
            break
        }
        return items
    }

    // The items of a My PRs row, in their order: Open on GitHub; then, unless the PR comes from a
    // fork, Open session while the PR has a session that is not parked; Answer Claude while Claude
    // has open questions; Handle now while items wait for it and Handle Copilot comments while
    // later Copilot threads wait (each while Claude waits, needs the user or failed, while the PR
    // has conflicts and while a re-run of failed jobs waits for its result), and Handle now on
    // each row whose work waits for the user, so a click clears the reason and the next round
    // checks again; Resolve now after them while the row is resolvable; Try again after a failed
    // round, and while an own request of the user that
    // needs the user waits with its writes; Don't send the rest while the writes of a stopped
    // round wait for Try again; Discard these changes on a row whose work waits for the user for
    // files that Bifrost found in its copy, with no writes that wait; Cancel while a round waits
    // in the queue; Stop session while a request, conflict or CI round runs.
    static func mineItems(_ row: ReviewRow, hasSession: Bool) -> [ReviewsMenuItem] {
        var items: [ReviewsMenuItem] = [.openOnGitHub]
        guard case .mine(_, let claude) = row.state, claude != .fork else { return items }
        if hasSession { items.append(.openSession) }
        if row.questions > 0 { items.append(.answerClaude) }
        let handles: Bool
        switch claude {
        case .waiting, .needsYou, .waitsForYou, .unpushedChanges, .unpushedComments, .unpushedCI,
            .askAgain, .error, .conflicts, .retryingCI:
            handles = true
        case .fixing, .resolvingConflicts, .fixingCI, .queued, .trustNeeded, .cloning, .fork:
            handles = false
        }
        let waitsForYou = claude.waitsForUser
        if handles && (row.waiting > 0 || waitsForYou) { items.append(.handleNow) }
        if handles && row.laterCopilot > 0 { items.append(.handleCopilot) }
        // Resolve now starts a conflict round by hand (MyPRRules.isResolvable).
        if row.resolvable { items.append(.resolveNow) }
        switch claude {
        case .error: items.append(.tryAgain)
        case .waitsForYou where row.unsentUpdates, .unpushedChanges where row.unsentUpdates,
            .unpushedComments where row.unsentUpdates, .unpushedCI where row.unsentUpdates,
            .askAgain where row.unsentUpdates:
            items.append(.tryAgain)
        default: break
        }
        if handles && row.unsentUpdates { items.append(.dropUpdates) }
        if waitsForYou && row.unsavedFiles > 0 && !row.unsentUpdates {
            items.append(.discardChanges)
        }
        switch claude {
        case .queued, .trustNeeded, .cloning: items.append(.cancel)
        case .fixing, .resolvingConflicts, .fixingCI: if hasSession { items.append(.stopSession) }
        default: break
        }
        return items
    }

    // The buttons of a To review row, in their order: Approve while the row offers it (it waits
    // while CI runs); Comment or Request changes while the row offers Claude's draft; Remove for a
    // row that others approved; Review on a request that waits for the user (Try again on a failed
    // row) while a round can start, on a New commits row, and on a Looks good row with no Approve;
    // and Pause for a new request. Each button is also an item of the menu of the row, except an
    // Approve that waits.
    package static func buttons(_ row: ReviewRow) -> [ReviewsMenuItem] {
        guard case .toReview(let state) = row.state else { return mineButtons(row) }
        var buttons: [ReviewsMenuItem] = []
        if row.approve != nil { buttons.append(.approve) }
        if let draft = row.draft { buttons.append(draftItem(draft)) }
        switch state {
        case .approvedByOthers: buttons.append(.remove)
        case .newRequest: buttons += row.reviewable ? [.review, .pause] : [.pause]
        case .waitingForYou, .teamRequest, .newCommits:
            if row.reviewable { buttons.append(.review) }
        case .reviewed: if row.reviewable && row.approve == nil { buttons.append(.review) }
        case .failed: if row.reviewable { buttons.append(.tryAgain) }
        case .draftReady, .trustNeeded, .reviewing, .queued, .paused, .youApproved,
            .youRequestedChanges, .youCommented:
            break
        }
        return buttons
    }

    // The buttons of a My PRs row: Unpushed changes has Open session (while the PR has a session)
    // and Discard changes, and Ask again has Discard edits. Each one is an item of the row menu.
    package static func mineButtons(_ row: ReviewRow) -> [ReviewsMenuItem] {
        guard case .mine(_, let claude) = row.state, row.unsavedFiles > 0, !row.unsentUpdates
        else { return [] }
        switch claude {
        case .unpushedChanges, .unpushedComments, .unpushedCI:
            return [.openSession, .discardChanges]
        case .askAgain: return [.discardChanges]
        default: return []
        }
    }

    // The label of a button of the row. On a My PRs row, the discard button has a short label of
    // its own; the menu keeps Discard these changes.
    package static func buttonLabel(_ item: ReviewsMenuItem, _ row: ReviewRow) -> String {
        guard item == .discardChanges, case .mine(_, let claude) = row.state else {
            return item.label
        }
        switch claude {
        case .unpushedChanges, .unpushedComments, .unpushedCI: return "Discard changes"
        case .askAgain: return "Discard edits"
        default: return item.label
        }
    }

    // The item that opens the Review panel for a draft of the event.
    static func draftItem(_ draft: DraftEvent) -> ReviewsMenuItem {
        switch draft {
        case .comment: .comment
        case .requestChanges: .requestChanges
        }
    }

    package static func rows(_ items: [ReviewsMenuItem]) -> [MenuRow] {
        items.map { .item(MenuItemSpec(id: $0.rawValue, label: $0.label)) }
    }

    // Show the menu of the row of the PR at the placement over the window. The menu follows the
    // row (FollowingMenu). A row that went shows no menu.
    static func show(
        _ pr: PRKey, model: ReviewsPanelModel, at placement: BifrostMenu.Placement,
        in window: NSWindow, menu: BifrostMenu
    ) {
        FollowingMenu.show(
            { [weak model] in model?.menuItems(pr) }, rows: rows, at: placement, in: window,
            menu: menu,
            onChoose: { [weak model] id, _ in
                guard let model, let item = ReviewsMenuItem(rawValue: id) else { return }
                // Approve writes to GitHub: the choice of the user is its click.
                if item == .approve {
                    model.approve(pr, click: UserClick())
                } else {
                    model.choose(item, for: pr)
                }
            })
    }
}
