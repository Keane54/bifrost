// The row menu of the Reviews panel (docs/behaviour/reviews.md, "The panel") on the Bifrost menu:
// only the items that apply to the row, in the order of the menu of the Electron app. Only
// Approve writes to GitHub, and only with the click of the user (a UserClick that the menu makes
// at the choice): Review starts a round, which leaves only a pending review; Comment and Request
// changes open the Review panel, whose buttons make their own clicks; and Handle now, Handle
// Copilot comments and Try again on a PR of the user start a request round, whose result Bifrost
// checks before it posts.
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
    case cancel
    case dropUpdates = "drop-updates"

    package var label: String {
        switch self {
        case .openOnGitHub: "Open on GitHub"
        case .openSession: "Open session"
        case .approve: "Approve"
        case .comment: "Comment"
        case .requestChanges: "Request changes"
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
        case .cancel: "Cancel"
        case .dropUpdates: "Don't send the rest"
        }
    }
}

@MainActor
package enum ReviewsMenu {
    // The items of the row, in their order: Open on GitHub for each row; Open session while the
    // PR has a session that is not parked; Approve while the row offers it and CI doesn't run;
    // Comment or Request changes while the row offers Claude's draft; Review (Try again on a
    // failed row) while a round can start; Remove for a row that others approved; Cancel review
    // for a review that waits; Stop session; Pause for a new request and End pause now for a
    // paused row. A My PRs row has its own items (mineItems).
    package static func items(_ row: ReviewRow, hasSession: Bool) -> [ReviewsMenuItem] {
        guard case .toReview(let state) = row.state else {
            return mineItems(row, hasSession: hasSession)
        }
        var items: [ReviewsMenuItem] = [.openOnGitHub]
        if hasSession { items.append(.openSession) }
        if row.approve == .ready { items.append(.approve) }
        if let draft = row.draft { items.append(draftItem(draft)) }
        if row.reviewable {
            if case .failed = state { items.append(.tryAgain) } else { items.append(.review) }
        }
        switch state {
        case .approvedByOthers: items.append(.remove)
        case .queued, .trustNeeded: items.append(.cancelReview)
        case .newRequest, .paused, .draftReady, .reviewed, .failed, .waitingForYou, .reviewing,
            .youApproved, .teamRequest:
            break
        }
        if hasSession { items.append(.stopSession) }
        switch state {
        case .newRequest: items.append(.pause)
        case .paused: items.append(.endPause)
        case .draftReady, .reviewed, .failed, .waitingForYou, .trustNeeded, .reviewing, .queued,
            .youApproved, .approvedByOthers, .teamRequest:
            break
        }
        return items
    }

    // The items of a My PRs row, in their order: Open on GitHub; then, unless the PR comes from a
    // fork, Open session while the PR has a session that is not parked; Answer Claude while Claude
    // has open questions; Handle now while items wait for it and Handle Copilot comments while
    // later Copilot threads wait (each while Claude waits, needs the user or failed); Try again
    // after a failed round; Don't send the rest while the writes of a stopped round wait for Try
    // again; Cancel while a round waits in the queue; Stop session while a round runs.
    static func mineItems(_ row: ReviewRow, hasSession: Bool) -> [ReviewsMenuItem] {
        var items: [ReviewsMenuItem] = [.openOnGitHub]
        guard case .mine(_, let claude) = row.state, claude != .fork else { return items }
        if hasSession { items.append(.openSession) }
        if row.questions > 0 { items.append(.answerClaude) }
        let handles: Bool
        switch claude {
        case .waiting, .needsYou, .error: handles = true
        case .fixing, .queued, .trustNeeded, .cloning, .fork: handles = false
        }
        if handles && row.waiting > 0 { items.append(.handleNow) }
        if handles && row.laterCopilot > 0 { items.append(.handleCopilot) }
        if case .error = claude { items.append(.tryAgain) }
        if handles && row.unsentUpdates { items.append(.dropUpdates) }
        switch claude {
        case .queued, .trustNeeded, .cloning: items.append(.cancel)
        case .fixing where hasSession: items.append(.stopSession)
        default: break
        }
        return items
    }

    // The buttons of a To review row, in their order: Approve while the row offers it (it waits
    // while CI runs); Comment or Request changes while the row offers Claude's draft; Remove for a
    // row that others approved; Review on a request that waits for the user (Try again on a failed
    // row) while a round can start, and on a Looks good row with no Approve; and Pause for a new
    // request. Each button is also an item of the menu of the row, except an Approve that waits.
    package static func buttons(_ row: ReviewRow) -> [ReviewsMenuItem] {
        guard case .toReview(let state) = row.state else { return [] }
        var buttons: [ReviewsMenuItem] = []
        if row.approve != nil { buttons.append(.approve) }
        if let draft = row.draft { buttons.append(draftItem(draft)) }
        switch state {
        case .approvedByOthers: buttons.append(.remove)
        case .newRequest: buttons += row.reviewable ? [.review, .pause] : [.pause]
        case .waitingForYou, .teamRequest: if row.reviewable { buttons.append(.review) }
        case .reviewed: if row.reviewable && row.approve == nil { buttons.append(.review) }
        case .failed: if row.reviewable { buttons.append(.tryAgain) }
        case .draftReady, .trustNeeded, .reviewing, .queued, .paused, .youApproved: break
        }
        return buttons
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
