import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostTestSupport
import Foundation
import Observation
import Testing

@testable import BifrostLook
@testable import BifrostSessions

// The Event log panel (docs/behaviour/panels.md, The Event log panel): the rows, the Session
// filter, the empty texts, the tooltip of a notice, and at most one update of the table each
// 250 ms. The log runs on a manual clock.

// The state of Live details for a test.
@MainActor
@Observable
private final class TestLive {
    var on = false
}

// The Event log body in a window that is never ordered front, with the rows of the test in the
// session list. The Interface scale is 100, so one layout unit is one point.
@MainActor
private final class ShownEventLog {
    let clock = ManualClock()
    let model: EventLogModel
    let source = FakeRowSource()
    let sessions: SessionListModel
    let live = TestLive()
    let panels: EventLogPanels
    let body: EventLogPanel
    let window: NSWindow

    init(rows: [SessionRow] = [], max: Int = EventLog.max) async {
        UITestApp.prepare()
        model = EventLogModel(
            clock: clock, now: { Date(timeIntervalSince1970: 1_800_000_000) }, max: max)
        sessions = SessionListModel.reading(source)
        source.apply(rows: rows, error: nil)
        let live = live
        panels = EventLogPanels(
            model: model, sessions: sessions, liveOn: { live.on },
            metrics: { CanvasMetrics(interfaceScale: 100) })
        guard let body = panels.body(for: .eventLog) as? EventLogPanel else {
            preconditionFailure("The Event log part gives no Event log body.")
        }
        self.body = body
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        window.contentView = content
        body.frame = content.bounds
        body.autoresizingMask = [.width, .height]
        content.addSubview(body)
        await settle()
    }

    isolated deinit {
        model.stop()
    }

    var rows: EventLogRowsView { body.rows }
    var table: EventLogTable { body.rows.table }
    var reloads: Int { body.rows.reloads }

    // Wait until the body shows the values of now.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil(sourceLocation: sourceLocation) { [self] in
            var known: [String: String] = [:]
            let names = LogView.names(sessions.rows, known: &known)
            return body.state
                == EventLogState(
                    entries: model.entries, names: names, liveOn: live.on,
                    metrics: CanvasMetrics(interfaceScale: 100))
        }
        body.layoutSubtreeIfNeeded()
    }

    // Move the clock by one gap of the batcher, so the entries that wait go to the panel.
    func flush() async {
        await clock.waitForSleepers(1)
        clock.advance(by: EventBatcher.gap)
        await waitUntil { [self] in model.entries == logEntries }
        await settle()
    }

    // The entries of the log now, also the ones that wait for the batcher. The model shows
    // them after the next gap.
    var logEntries: [LogEntry] = []

    func append(_ events: [HookEvent], expected: [LogEntry]) {
        model.append(events)
        logEntries = expected
    }

    // The cell of a row of the table, laid out.
    func cell(_ row: Int) -> EventLogCell? {
        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? EventLogCell
        cell?.layoutSubtreeIfNeeded()
        return cell
    }

    // The titles of the Session filter.
    var menuTitles: [String] { body.sessionMenu.itemTitles }
}

private func event(_ at: Int, _ session: String, _ name: HookEventName = .stop) -> HookEvent {
    HookEvent(name, session, at: at)
}

@MainActor
@Suite("event log panel")
struct EventLogPanelTests {
    @Test func theEmptyTextsOfTheEventLog() async {
        #expect(EventLogPanel.empty == "No events yet.")
        #expect(
            EventLogPanel.liveHint
                == "Events come from Live details. Turn it on in Settings to see them here.")
        let shown = await ShownEventLog()
        #expect(!shown.body.emptyText.isHidden)
        #expect(shown.body.emptyText.stringValue == EventLogPanel.empty)
        #expect(!shown.body.hintText.isHidden)
        #expect(shown.body.hintText.stringValue == EventLogPanel.liveHint)
        #expect(shown.rows.isHidden)
        #expect(shown.body.countLabel.stringValue == "0 events")
        // With Live details on, only the first text shows.
        shown.live.on = true
        await shown.settle()
        #expect(!shown.body.emptyText.isHidden)
        #expect(shown.body.hintText.isHidden)
        // An entry hides both texts, also with Live details off.
        shown.live.on = false
        shown.model.line("Hello.")
        await shown.settle()
        #expect(shown.body.emptyText.isHidden)
        #expect(shown.body.hintText.isHidden)
        #expect(!shown.rows.isHidden)
        #expect(shown.body.countLabel.stringValue == "1 event")
    }

    @Test func aBurstOf20000EventsGivesAtMostOneTableUpdateEach250ms() async {
        let shown = await ShownEventLog(rows: [SessionRow.test(sessionId: "s1", name: "alpha")])
        let start = shown.reloads
        for i in 1...20_000 { shown.model.append([event(i, "s1")]) }
        await shown.settle()
        // The first event goes at once. The others wait for the end of the gap.
        #expect(shown.reloads == start + 1)
        #expect(shown.table.numberOfRows == 1)
        await shown.clock.waitForSleepers(1)
        shown.clock.advance(by: .milliseconds(249))
        // The timer of the gap still sleeps, so no batch can come.
        #expect(shown.clock.sleeperCount == 1)
        #expect(shown.reloads == start + 1)
        shown.clock.advance(by: .milliseconds(1))
        await waitUntil { shown.table.numberOfRows == 5000 }
        await shown.settle()
        #expect(shown.reloads == start + 2)
        // The newest first.
        #expect(shown.rows.entry(atRow: 0)?.seq == 20_000)
        #expect(shown.rows.entry(atRow: 4999)?.seq == 15_001)
        #expect(shown.body.countLabel.stringValue == "5000 events")
        // Five more bursts, one in each gap: one update for each gap.
        for round in 1...5 {
            for i in 1...1000 { shown.model.append([event(i, "s1")]) }
            await shown.clock.waitForSleepers(1)
            shown.clock.advance(by: EventBatcher.gap)
            let last = 20_000 + round * 1000
            await waitUntil { shown.rows.entry(atRow: 0)?.seq == last }
            await shown.settle()
            #expect(shown.reloads == start + 2 + round)
        }
    }

    // A row changes at each event of its session. A change that keeps the names of the rows
    // gives the table no work.
    @Test func aChangeOfARowThatKeepsItsNameDoesNotReloadTheTable() async {
        let row = SessionRow.test(sessionId: "s1", name: "alpha")
        let shown = await ShownEventLog(rows: [row])
        shown.model.append([event(1, "s1")])
        await shown.settle()
        let reloads = shown.reloads
        for i in 0..<50 {
            var changed = row
            changed.state = i.isMultiple(of: 2) ? .working : .idle
            changed.lastActivity = i
            shown.source.apply(rows: [changed], error: nil)
        }
        await shown.settle()
        #expect(shown.reloads == reloads)
        // A new name changes the label of the session.
        var renamed = row
        renamed.name = "beta"
        shown.source.apply(rows: [renamed], error: nil)
        await shown.settle()
        #expect(shown.reloads == reloads + 1)
        #expect(shown.cell(0)?.session.stringValue == "beta")
    }

    @Test func theSessionFilterShowsOneSession() async {
        let rows = [
            SessionRow.test(sessionId: "aaaaaaaa-1111", name: "zeta"),
            SessionRow.test(sessionId: "bbbbbbbb-2222", name: "alpha"),
        ]
        let shown = await ShownEventLog(rows: rows)
        shown.model.append([
            event(1, "aaaaaaaa-1111", .userPromptSubmit), event(2, "bbbbbbbb-2222"),
            event(3, "gone1234-5678"), event(4, "aaaaaaaa-1111"),
        ])
        await shown.settle()
        #expect(shown.menuTitles == ["All sessions", "alpha", "gone1234", "zeta"])
        #expect(shown.body.sessionMenu.indexOfSelectedItem == 0)
        #expect(shown.table.numberOfRows == 4)
        #expect(shown.body.countLabel.stringValue == "4 events")
        // A choice in the menu shows only the entries of that session.
        shown.body.sessionMenu.selectItem(at: 3)
        shown.body.sessionMenu.sendAction(shown.body.sessionMenu.action, to: shown.body)
        #expect(shown.body.session == "aaaaaaaa-1111")
        #expect(shown.table.numberOfRows == 2)
        #expect(shown.rows.entry(atRow: 0)?.seq == 4)
        #expect(shown.rows.entry(atRow: 1)?.seq == 1)
        #expect(shown.body.countLabel.stringValue == "2 events")
        #expect(shown.body.sessionMenu.selectedItem?.title == "zeta")
        #expect(shown.body.sessionMenu.selectedItem?.state == .on)
        shown.body.sessionMenu.selectItem(at: 0)
        shown.body.sessionMenu.sendAction(shown.body.sessionMenu.action, to: shown.body)
        #expect(shown.body.session == nil)
        #expect(shown.table.numberOfRows == 4)
    }

    // Two sessions with the same name are two choices.
    @Test func twoSessionsWithOneNameAreTwoChoices() async {
        let rows = [
            SessionRow.test(sessionId: "s1", name: "same"),
            SessionRow.test(sessionId: "s2", name: "same"),
        ]
        let shown = await ShownEventLog(rows: rows)
        shown.model.append([event(1, "s1"), event(2, "s2")])
        await shown.settle()
        #expect(shown.menuTitles == ["All sessions", "same", "same"])
        shown.body.sessionMenu.selectItem(at: 2)
        shown.body.sessionMenu.sendAction(shown.body.sessionMenu.action, to: shown.body)
        #expect(shown.body.session == "s2")
        #expect(shown.rows.entry(atRow: 0)?.sessionId == "s2")
    }

    // The menu keeps the filter, so it always shows what the table shows.
    @Test func theFilterStaysInTheMenuAfterItsLastEntryLeavesTheLog() async {
        let rows = [SessionRow.test(sessionId: "s1", name: "alpha")]
        let shown = await ShownEventLog(rows: rows, max: 3)
        shown.model.append([event(1, "s1"), event(2, "s2")])
        await shown.settle()
        shown.body.choose(session: "s1")
        shown.append(
            [event(3, "s2"), event(4, "s2"), event(5, "s2")],
            expected: (3...5).map { LogEntry(seq: $0, at: $0, sessionId: "s2", name: .stop) })
        await shown.flush()
        #expect(shown.menuTitles == ["All sessions", "s2", "alpha"])
        #expect(shown.body.sessionMenu.selectedItem?.title == "alpha")
        #expect(shown.table.numberOfRows == 0)
        #expect(!shown.body.emptyText.isHidden)
    }

    // A new session can change the place of each item. The open menu keeps its list, and the
    // choice maps by the session ID of its item. AppKit asks for the items before the next open,
    // and that open gets the list of now.
    @Test func theSessionMenuHoldsItsListWhileItIsOpen() async throws {
        let rows = [
            SessionRow.test(sessionId: "s1", name: "beta"),
            SessionRow.test(sessionId: "s2", name: "alpha"),
        ]
        let shown = await ShownEventLog(rows: rows)
        shown.model.append([event(1, "s1")])
        await shown.settle()
        #expect(shown.menuTitles == ["All sessions", "beta"])
        let menu = try #require(shown.body.sessionMenu.menu)
        shown.body.menuWillOpen(menu)
        shown.append(
            [event(2, "s2")],
            expected: [
                LogEntry(seq: 1, at: 1, sessionId: "s1", name: .stop),
                LogEntry(seq: 2, at: 2, sessionId: "s2", name: .stop),
            ])
        await shown.flush()
        #expect(shown.table.numberOfRows == 2)
        #expect(shown.menuTitles == ["All sessions", "beta"])
        // The choice of beta in the open menu, at its old place.
        shown.body.sessionMenu.selectItem(at: 1)
        shown.body.sessionMenu.sendAction(shown.body.sessionMenu.action, to: shown.body)
        #expect(shown.body.session == "s1")
        #expect(shown.menuTitles == ["All sessions", "beta"])
        shown.body.menuDidClose(menu)
        #expect(shown.menuTitles == ["All sessions", "beta"])
        shown.body.menuNeedsUpdate(menu)
        #expect(shown.menuTitles == ["All sessions", "alpha", "beta"])
        #expect(shown.body.sessionMenu.menu === menu)
        #expect(shown.body.sessionMenu.selectedItem?.title == "beta")
        #expect(shown.body.sessionMenu.selectedItem?.representedObject as? String == "s1")
        #expect(shown.body.sessionMenu.itemArray.first?.representedObject == nil)
        #expect(shown.table.numberOfRows == 1)
    }

    @Test func aNoticeRowHasTheWholeTextAsItsTooltip() async throws {
        let shown = await ShownEventLog(rows: [SessionRow.test(sessionId: "s1", name: "alpha")])
        shown.model.append([HookEvent(.postToolUse, "s1", at: 1000, toolName: "Bash")])
        shown.model.notice(EventLog.notificationRefused)
        shown.logEntries = [
            LogEntry(seq: 1, at: 1000, sessionId: "s1", name: .postToolUse, tool: "Bash"),
            LogEntry(seq: 2, at: 1_800_000_000_000, notice: EventLog.notificationRefused),
        ]
        await shown.flush()
        let notice = try #require(shown.cell(0))
        let event = try #require(shown.cell(1))
        #expect(notice.text.stringValue == EventLog.notificationRefused)
        #expect(notice.session.isHidden)
        #expect(TooltipController.shared.text(of: notice.text) == EventLog.notificationRefused)
        #expect(notice.text.textColor == ThemeTokens.textStrong.nsColor)
        // The text of a notice starts where the session of an event starts.
        #expect(notice.text.frame.minX == event.session.frame.minX)
        #expect(event.time.stringValue == TimeText.clockMs(1000))
        #expect(event.session.stringValue == "alpha")
        #expect(!event.session.isHidden)
        #expect(event.text.stringValue == "PostToolUse (Bash)")
        #expect(event.text.textColor == ThemeTokens.text.nsColor)
        #expect(TooltipController.shared.text(of: event.text) == nil)
        // A reused cell drops the tooltip of its notice.
        notice.show(
            EventLogCellContent(shown.model.entries[0], names: ["s1": "alpha"]),
            metrics: CanvasMetrics(interfaceScale: 100))
        #expect(TooltipController.shared.text(of: notice.text) == nil)
    }

    @Test func theRowsHaveTheHeightOf18AndTheTableTakesNoKey() async {
        let shown = await ShownEventLog()
        #expect(shown.table.rowHeight == 18)
        #expect(!shown.table.acceptsFirstResponder)
        // The window takes the focus in place of the table.
        shown.window.makeFirstResponder(shown.table)
        #expect(shown.window.firstResponder !== shown.table)
    }
}
