// The Daily update panel (docs/behaviour/daily-update.md, "The panel"): what the view shows and
// does (DailyUpdatePanelModel), and the part that makes the body (DailyUpdatePanels).
//
// The panel reads the snapshot of the service (DailyUpdateService.snapshot) through Observation,
// so each change of the drafts, the marks or the run shows at once. The service can come after
// the panel (the store opens and claude is found at the start), and there is none while another
// copy of Bifrost holds the Daily update or the app found no claude: the panel then says why.
//
// Bifrost posts nothing: Send stays off with its tip until the Slack app. The links of the items
// open in the browser only for an https address.
import AppKit
import BifrostDailyUpdate
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostSessions
import Foundation
import Observation
import SwiftUI

// What the panel needs from the window and the services. The default asks nothing, opens nothing
// and writes no clipboard, so a test that gives no link changes nothing outside the panel.
@MainActor
package struct DailyPanelLinks {
    // Ask the user to confirm, with the confirm dialog of the window. False: cancelled, or
    // another dialog shows.
    package var confirm: @MainActor (ConfirmText) async -> Bool
    // Open Settings > Daily update.
    package var openSettings: @MainActor () -> Void
    package var opener: (any AppOpener)?
    package var clipboard: (any Clipboard)?
    // The Interface scale and the Panel transparency.
    package var look: PanelLook

    package init(
        confirm: @escaping @MainActor (ConfirmText) async -> Bool = { _ in false },
        openSettings: @escaping @MainActor () -> Void = {}, opener: (any AppOpener)? = nil,
        clipboard: (any Clipboard)? = nil, look: PanelLook = PanelLook()
    ) {
        self.confirm = confirm
        self.openSettings = openSettings
        self.opener = opener
        self.clipboard = clipboard
        self.look = look
    }
}

@MainActor
@Observable
package final class DailyUpdatePanelModel {
    // What the panel shows.
    package enum Shown: Equatable {
        // The service starts: an empty panel.
        case starting
        // No service: why.
        case unavailable(String)
        // No area is on: a short text and the button to Settings > Daily update.
        case noArea
        case tabs
    }

    // The button of the status line that acts on the day.
    package enum SkipAction: Equatable {
        case skip, undo
    }

    // The buttons of a tab: true when a button is on.
    package struct TabButtons: Equatable {
        package var redo: Bool
        package var copy: Bool
        package var copyLabel: String
        // "Sent at 09:31" with Undo, or nil for Mark as sent.
        package var sent: String?
        package var markSent: Bool
        package var send: Bool
        package var sendLabel: String
        package var sendTip: String
    }

    // The time that Copy shows "Copied".
    nonisolated package static let copiedTime = Duration.seconds(2)

    // MARK: The texts

    package static let setUpText = "Set up your work areas to get a daily update."
    package static let openSettingsButton = "Open settings"
    package static let nothingMoved = "Nothing moved since your last update."
    package static let noDraft = "This work area doesn't have a draft yet."
    package static let newDraft = "There's a new draft."
    package static let sendTip = "Sending comes with the Slack app. For now, copy the draft."
    package static let redoText = ConfirmText(
        title: "Replace your changes with a new draft?",
        body: "Redo draft writes a new draft for this work area, and your changes go.",
        confirm: "Replace")

    // The tab that the user chose last, or nil.
    package private(set) var chosen: String?
    // True while the items that fit no area show.
    package private(set) var showsUnplaced = false
    // The area whose Copy shows "Copied", or nil.
    package private(set) var copied: String?
    // Why the last open of a link failed, or nil.
    package private(set) var error: String?

    @ObservationIgnored private let service: @MainActor () -> DailyUpdateService?
    @ObservationIgnored private let unavailable: @MainActor () -> String?
    @ObservationIgnored package let links: DailyPanelLinks
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored package let zone: TimeZone
    @ObservationIgnored private let copiedTimer: TimerSlot

    // service gives the service of now, or nil. unavailable gives why there is none, or nil
    // while it starts. Both read observed values.
    package init(
        service: @escaping @MainActor () -> DailyUpdateService?,
        unavailable: @escaping @MainActor () -> String?, links: DailyPanelLinks,
        clock: any Clock<Duration>, now: @escaping () -> Date, zone: TimeZone
    ) {
        self.service = service
        self.unavailable = unavailable
        self.links = links
        self.now = now
        self.zone = zone
        copiedTimer = TimerSlot(clock: clock)
    }

    #if DEBUG
    // The task of the timer of "Copied", or nil. A test waits for it.
    package var copiedTask: Task<Void, Never>? { copiedTimer.task }
    #endif

    // MARK: - What the panel shows

    package var snapshot: DailySnapshot? { service()?.snapshot }

    // True while the service of the Daily update is there.
    package var hasService: Bool { service() != nil }

    package var shown: Shown {
        if let snapshot { return snapshot.tabs.isEmpty ? .noArea : .tabs }
        if let text = unavailable() { return .unavailable(text) }
        return .starting
    }

    package var style: PanelStyle {
        PanelStyle(
            metrics: links.look.metrics, transparency: links.look.panelTransparency)
    }

    // The tab to show: the chosen tab of an area that is on, else the first tab that is not
    // sent, else the first tab.
    package var shownTab: DailySnapshot.Tab? {
        guard let tabs = snapshot?.tabs else { return nil }
        if let chosen, let tab = tabs.first(where: { $0.id == chosen }) { return tab }
        return tabs.first { $0.sentAt == nil } ?? tabs.first
    }

    package func marker(_ tab: DailySnapshot.Tab) -> Bool {
        snapshot?.showsMarker(tab) ?? false
    }

    // The status line: the state of the day in words.
    package var statusText: String {
        Self.text(of: snapshot?.status ?? DailySnapshot.idle.status)
    }

    package static func text(of status: DailyStatus) -> String {
        switch status {
        case .writing: "Bifrost is writing your drafts."
        case .noArea: "Turn on an area in Settings > Daily update."
        case .skipped: "You skipped today."
        case .allSent: "All your updates are sent for today."
        case .ready: "Your drafts are ready."
        case .failed: "Bifrost couldn't write your drafts."
        case .noDrafts: "No drafts yet."
        }
    }

    // "Due 10:00" on a due day, else nil.
    package var dueText: String? {
        guard let snapshot, snapshot.due else { return nil }
        return "Due \(snapshot.deadline.text)"
    }

    // The time of the last good run: the clock for a run of today, else the day, the date and
    // the clock. nil while a run goes, or before the first good run.
    package var refreshText: String? {
        guard let snapshot, !snapshot.isRunning, let at = snapshot.lastRefresh else { return nil }
        return "Refreshed \(when(at))"
    }

    // Refresh is off while a run goes.
    package var canRefresh: Bool { snapshot.map { !$0.isRunning } ?? false }

    // The buttons of the tab. Redo is off while a run goes, and Copy with no draft. Mark as sent
    // stays on, also after a failed run, so the user can post a draft of their own. Send stays
    // off until the Slack app: Bifrost posts nothing.
    package func buttons(_ tab: DailySnapshot.Tab) -> TabButtons {
        TabButtons(
            redo: canRefresh, copy: tab.hasDraft, copyLabel: copied == tab.id ? "Copied" : "Copy",
            sent: sentText(tab), markSent: snapshot != nil, send: false,
            sendLabel: Self.sendLabel(tab), sendTip: Self.sendTip)
    }

    // Skip today on a due day, and Undo after a skip.
    package var skipAction: SkipAction? {
        guard let snapshot, snapshot.due else { return nil }
        return snapshot.skipped ? .undo : .skip
    }

    // The button that shows the items that fit no area, or nil when each item fits an area.
    package var unplacedText: String? {
        let count = snapshot?.unplaced.count ?? 0
        if count == 0 { return nil }
        return count == 1 ? "1 ticket fits no area" : "\(count) tickets fit no area"
    }

    package func movedHeader(_ tab: DailySnapshot.Tab) -> String {
        let text = "Moved since your last update"
        guard let since = tab.since else { return text }
        return "\(text) (\(when(since)))"
    }

    // The change of state of an item, or nil.
    package static func change(of item: DailyItem) -> String? {
        if let from = item.from, let to = item.to { return "\(from) → \(to)" }
        return item.to ?? item.from
    }

    // "Sent at 09:31", or nil for a tab that is not sent.
    package func sentText(_ tab: DailySnapshot.Tab) -> String? {
        tab.sentAt.map { "Sent at \(TimeText.clock($0.millisecondsSince1970, zone: zone))" }
    }

    package static func sendLabel(_ tab: DailySnapshot.Tab) -> String {
        let channel = tab.channel.trimmed()
        return channel.isEmpty ? "Send" : "Send to \(channel)"
    }

    // True when the item has an https link that the panel opens.
    package static func link(of item: DailyItem) -> URL? {
        guard let text = item.url, text.lowercased().hasPrefix("https://"),
            let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil
        else { return nil }
        return url
    }

    // True when the editor shows the draft again: the draft is not the Markdown of the text of
    // the editor (Redo, Use new draft, a new run), or the font changed. A change of the user gives
    // the same Markdown back, so the editor keeps its text and its caret.
    package static func showsDraftAgain(
        _ draft: String, editorText: String, fontChanged: Bool
    ) -> Bool {
        fontChanged || editorText != draft
    }

    private func when(_ date: Date) -> String {
        TimeText.when(date.millisecondsSince1970, now: now().millisecondsSince1970, zone: zone)
    }

    // MARK: - The actions

    // The panel shows and the service is there: the service runs the drafts when its rule
    // allows (DailyUpdateService.panelOpened).
    package func panelOpened() { service()?.panelOpened() }

    // A click on a reminder asks for the area, or nil for the first tab that is not sent.
    package func show(area: String?) { chosen = area }

    package func choose(_ tab: String) { chosen = tab }

    package func refresh() { service()?.refresh() }

    package func skipToday() { service()?.skipToday() }

    package func undoSkip() { service()?.undoSkip() }

    package func toggleUnplaced() { showsUnplaced.toggle() }

    package func openSettings() { links.openSettings() }

    package func closeError() { error = nil }

    // Open the link of the item in the browser. Only an https link opens. The task ends after
    // the open.
    @discardableResult
    package func open(_ item: DailyItem) -> Task<Void, Never>? {
        guard let url = Self.link(of: item), let opener = links.opener else { return nil }
        error = nil
        return Task {
            do throws(ActionRefusal) {
                try await opener.openInBrowser(url)
            } catch {
                self.error = error.message
            }
        }
    }

    // Redo the draft of the area. A changed draft asks first, because the new draft replaces it.
    package func redo(_ area: String) async {
        guard let tab = snapshot?.tabs.first(where: { $0.id == area }) else { return }
        if tab.edited, !(await links.confirm(Self.redoText)) { return }
        service()?.redo(area)
    }

    // Copy the draft as standard Markdown. The button shows "Copied" for a short time.
    package func copy(_ area: String) {
        guard let service = service(), let clipboard = links.clipboard,
            snapshot?.tabs.first(where: { $0.id == area })?.hasDraft == true
        else { return }
        clipboard.write(service.copyText(area))
        copied = area
        copiedTimer.start(after: Self.copiedTime) { [weak self] in self?.copied = nil }
    }

    // The tab stays the shown tab after the mark, also when it was not chosen.
    package func markSent(_ area: String) {
        chosen = area
        service()?.markSent(area)
    }

    package func undoSent(_ area: String) { service()?.undoSent(area) }

    package func edit(_ area: String, _ text: String) { service()?.edit(area, text) }

    package func usePending(_ area: String) { service()?.usePending(area) }

    package func keepMine(_ area: String) { service()?.keepMine(area) }

    // The panel left the last frame.
    package func panelClosed() {
        copiedTimer.stop()
        copied = nil
        error = nil
        showsUnplaced = false
    }
}

// The body of the Daily update panel: one host while the panel is in a frame. The open of the
// panel follows the service: a panel of the restored layout gets its body before the service
// starts, so the open run comes when the service is there, once for each open of the panel.
@MainActor
package final class DailyUpdatePanels: PanelBodiesPart {
    package let model: DailyUpdatePanelModel
    private var host: PassiveHostingView<DailyUpdatePanel>?
    // The wait for the service of this open of the panel, until it comes or the body goes.
    private(set) var opening: Task<Void, Never>?

    package init(model: DailyUpdatePanelModel) {
        self.model = model
    }

    isolated deinit {
        opening?.cancel()
    }

    package func body(for panel: PanelID) -> NSView? {
        guard panel == .dailyUpdate else { return nil }
        if let host { return host }
        let host = PassiveHostingView(rootView: DailyUpdatePanel(model: model))
        host.sizingOptions = []
        self.host = host
        let model = model
        let services = Observations { model.hasService }
        opening = Task {
            for await present in services where present {
                model.panelOpened()
                return
            }
        }
        return host
    }

    package func releaseBody(for panel: PanelID) {
        guard panel == .dailyUpdate, host != nil else { return }
        host = nil
        opening?.cancel()
        opening = nil
        model.panelClosed()
    }
}
