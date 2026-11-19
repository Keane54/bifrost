// The Selected Item panel (docs/behaviour/actions.md, "The Selected Item panel"): the content of
// the selected row as values, the actions of the controls, and the body with its host and its
// send box. SwiftUI takes no synthetic click in a window that is never ordered front, so the tests
// read the content and call the actions of the model.
import AppKit
import BifrostChat
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostWindows

// An owned row that each panel action accepts: idle, with a short ID, a PID and a project folder.
private func row(
    state: SessionState = .idle, change: (inout SessionRow) -> Void = { _ in }
) -> SessionRow {
    var row = SessionRow.test(
        sessionId: s1, shortId: short1, name: "fix-a", pid: 10, cwd: "/Users/me/code/app",
        state: state)
    change(&row)
    return row
}

private func context(chatOpen: Bool = false, labels: LabelSet = .plain) -> ActionContext {
    ActionContext(
        chatOpen: chatOpen, folderShared: false, apps: [ProjectApp(id: .finder, label: "Finder")],
        labels: labels, running: false, slashFavourites: [], slashRecent: [])
}

private func details(
    _ row: SessionRow, chatOpen: Bool = false,
    status: StatusTexts = StatusTexts(lines: [], kind: nil)
) -> SelectedItemDetails {
    .of(row, context(chatOpen: chatOpen), status: status, appIcon: nil, rowFlash: true)
}

private func usage(_ percent: Double?) -> LiveUsage {
    LiveUsage(model: "claude-opus-4-1", contextPercent: percent, costUsd: 1.5)
}

// The panel on the harness, in a window that is never ordered front.
@MainActor
private final class PanelParts {
    let h: ActionsHarness
    let overviews: OverviewModel
    let part: SelectedItemPanels
    let window: NSWindow

    init(active: [AgentEntry] = [Entry.running(s1), Entry.running(s2)]) async throws {
        h = try await ActionsHarness(active: active)
        overviews = OverviewModel(
            store: h.store, sessions: h.list, selection: h.selection, layout: h.layout,
            clock: h.clock, now: { Date(timeIntervalSince1970: 0) })
        part = SelectedItemPanels(runner: h.runner, overviews: overviews, look: h.look)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    var model: SelectedItemModel { part.model }

    // The body in the window, after its layout.
    func panel(height: CGFloat = 300) throws -> SelectedItemPanel {
        let body = try #require(part.body(for: .selectedItem) as? SelectedItemPanel)
        if window.contentView !== body {
            window.contentView = body
            body.frame = NSRect(x: 0, y: 0, width: 360, height: height)
        }
        body.layoutSubtreeIfNeeded()
        return body
    }

    func details() throws -> SelectedItemDetails {
        guard case .details(let details) = model.content else {
            Issue.record("No row shows.")
            throw HarnessError.noDialog
        }
        return details
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    // A click on Add to watchlist of the row, with a button in the window and the menu as the
    // Bifrost menu of the Overviews.
    func pressWatchAdd(on menu: BifrostMenu, sessionId: String = s1) throws {
        overviews.menu = menu
        let content = try #require(window.contentView)
        let button = NSView(frame: NSRect(x: 20, y: 200, width: 24, height: 24))
        content.addSubview(button)
        h.selection.selectedId = sessionId
        let item = try #require(try details().buttons.first { $0.action == .watchAdd })
        model.press(item, sessionId: sessionId, anchor: button)
    }
}

@Suite("the Selected Item panel", .serialized, .testTimeLimit, .tags(.window))
@MainActor
struct SelectedItemTests {
    // The name line: the row icon, the name, the state label in its tone. A row with no priority
    // shows no priority (no "-").
    @Test func aRowWithNoPriorityShowsNoPriority() {
        let plain = details(row())
        #expect(plain.priority == nil)
        #expect(plain.name == "fix-a")
        #expect(plain.state == "Idle")
        #expect(plain.stateColour == ThemeTokens.textDim)
        #expect(plain.icon == SessionIconLook(row: row(), appIcon: nil, rowFlash: true))
        let p3 = details(row { $0.priority = .p3 })
        #expect(p3.priority == PriorityMark(text: "3", colour: ThemeTokens.priority(3)))
        let working = details(row(state: .working))
        #expect(working.state == "Working")
        #expect(working.stateColour == ThemeTokens.textStrong)
    }

    // The bar of the Model row has the three band fills of the shown percent, and the strong text
    // colour with no band. With no percent, the bar is empty and the text is "-".
    @Test func theContextBarHasTheThreeBandFills() {
        #expect(SelectedItemDetails.bandColour(.low) == ThemeTokens.ctxLow)
        #expect(SelectedItemDetails.bandColour(.mid) == ThemeTokens.ctxMid)
        #expect(SelectedItemDetails.bandColour(.high) == ThemeTokens.ctxHigh)
        #expect(SelectedItemDetails.bandColour(nil) == ThemeTokens.textStrong)
        let low = details(row { $0.usage = usage(12) }).context
        #expect(low == ContextBar(fill: 12, colour: ThemeTokens.ctxLow, text: "12% context"))
        // 39.6 shows 40 %, so the bar has the mid band.
        let mid = details(row { $0.usage = usage(39.6) }).context
        #expect(mid == ContextBar(fill: 39.6, colour: ThemeTokens.ctxMid, text: "40% context"))
        let high = details(row { $0.usage = usage(120) }).context
        #expect(high == ContextBar(fill: 100, colour: ThemeTokens.ctxHigh, text: "120% context"))
        let none = details(row { $0.usage = usage(nil) }).context
        #expect(none == ContextBar(fill: 0, colour: ThemeTokens.textStrong, text: "-"))
    }

    // The facts are Project, Branch, Model and Cost, with "-" for no value. The panel shows no
    // preview of the last reply.
    @Test func noPreviewOfTheLastReply() {
        let shown = details(
            row {
                $0.lastMessage = "the last reply of Claude"
                $0.branch = "fix/a"
                $0.usage = usage(50)
            })
        #expect(
            shown.facts == [
                FactRow(label: "Project", value: "code/app", tip: "/Users/me/code/app"),
                FactRow(label: "Branch", value: "fix/a"),
                FactRow(label: "Model", value: "Opus 4.1", tip: "Opus 4.1"),
                FactRow(label: "Cost", value: "≈$1.50"),
            ])
        #expect(!String(describing: shown).contains("the last reply"))
        let empty = details(row { $0.cwd = "" })
        #expect(empty.facts.map(\.value) == ["-", "-", "-", "-"])
        #expect(empty.facts[0].tip == nil)
    }

    @Test func theNameTooltipIsTheAliasTip() {
        let renamed = row {
            $0.name = "my name"
            $0.claudeName = "claude-name"
        }
        #expect(details(renamed).nameTip == aliasTip(renamed))
        #expect(details(row()).nameTip == aliasTip(row()))
    }

    @Test func compactHasTheShrinkIcon() throws {
        #expect(ActionButtonItem.icon(.compact) == .shrink)
        let compact = try #require(details(row()).buttons.first { $0.action == .compact })
        #expect(compact.icon == .shrink)
        #expect(compact.tip == "Compact")
        #expect(compact.enabled)
    }

    // A button for each action of selectedItemActions(chatOpen:), then the watch button. Each
    // action has its own icon, and the space labels give the labels and the tooltips.
    @Test func eachSelectedItemActionHasAButton() throws {
        let closed = details(row())
        #expect(
            closed.buttons.map(\.action)
                == ActionModel.selectedItemActions(chatOpen: false) + [.watchAdd])
        let open = details(row(), chatOpen: true)
        #expect(
            open.buttons.map(\.action)
                == ActionModel.selectedItemActions(chatOpen: true) + [.watchAdd])
        #expect(!open.buttons.contains { $0.action == .open })
        let watched = details(row { $0.watch = RowWatch(colour: .red, order: 1) })
        #expect(watched.buttons.last?.action == .watchRemove)
        let icons = (ActionModel.selectedItemActions + [.watchAdd, .watchRemove]).map {
            ActionButtonItem.icon($0)
        }
        #expect(!icons.contains(nil))
        #expect(Set(icons).count == icons.count)
        // An action that is off keeps its button, with the reason in the tooltip.
        let noId = details(row { $0.shortId = nil })
        let stop = try #require(noId.buttons.first { $0.action == .stop })
        #expect(!stop.enabled)
        #expect(stop.tip == "Stop session\nWaiting for the session ID.")
        // VoiceOver reads the reason of a button that is off as its hint.
        #expect(stop.hint == "Waiting for the session ID.")
        #expect(closed.buttons.first { $0.action == .open }?.hint == nil)
        #expect(stop.label == "Stop session...")
        let space = ActionButtonItem.of(.open, row(), context(labels: .space))
        #expect(space?.label == "Warp to")
    }

    // Hand over shows the warning colour from 80 % context, after a round to a whole percent.
    @Test func handOverWarnsWhenTheContextIsNearlyFull() throws {
        let warn = try #require(
            details(row { $0.usage = usage(79.5) }).buttons.first { $0.action == .handOver })
        #expect(warn.warn)
        let calm = try #require(
            details(row { $0.usage = usage(79.4) }).buttons.first { $0.action == .handOver })
        #expect(!calm.warn)
        #expect(!(details(row()).buttons.contains { $0.action != .handOver && $0.warn }))
    }

    // The status icon shows only when a text exists: the error icon for an error or a failed
    // send, else the info icon. Its tooltip has all texts.
    @Test func theStatusIconShowsOnlyWithAText() {
        #expect(details(row()).status == nil)
        let info = details(
            row(), status: .of(error: nil, notice: "Done.", sendLine: nil, sendFailed: false))
        #expect(info.status == StatusMark(kind: .info, text: "Done."))
        #expect(info.status?.icon == .info)
        #expect(info.status?.colour == ThemeTokens.textDim)
        let error = details(
            row(), status: .of(error: "Bad.", notice: "Done.", sendLine: nil, sendFailed: false))
        #expect(error.status == StatusMark(kind: .error, text: "Bad.\nDone."))
        #expect(error.status?.icon == .circleAlert)
        #expect(error.status?.colour == ThemeTokens.textStrong)
    }

    // With a selected row, the notice and the error show in the status icon, not as lines. With
    // no selected row, they show as the lines at the bottom.
    @Test func theSelectedRowShowsNoNoticeOrErrorLine() async throws {
        let p = try await PanelParts()
        defer { p.close() }
        p.h.runner.notify("Done.")
        #expect(p.model.content == .none(notice: "Done.", error: nil))
        p.h.selection.selectedId = s1
        let shown = try p.details()
        #expect(shown.sessionId == s1)
        #expect(shown.status == StatusMark(kind: .info, text: "Done."))
        // A selected ID that is not in the rows is no selection.
        p.h.selection.selectedId = "9d9d9d9d-0000-4000-8000-000000000009"
        #expect(p.model.content == .none(notice: "Done.", error: nil))
    }

    // A click on the error icon closes the error of the actions and the failed send.
    @Test func theErrorIconClosesTheErrors() async throws {
        let p = try await PanelParts()
        defer { p.close() }
        p.h.selection.selectedId = s1
        // The open of Open project fails.
        p.h.values.apps = [InstalledApp(app: ProjectApp(id: .zed, label: "Zed"), path: "/Z.app")]
        p.h.opener.failure = .unknownApp
        p.h.runner.run(.openProject, s1, arg: .app(.zed))
        await p.h.settle()
        p.model.sendBox.setDraft(s1, "/a\nb")
        await p.model.sendBox.submit(s1)
        let failed = try p.details()
        let texts = "\(ActionRefusal.unknownApp.message)\nA slash command has one line."
        #expect(failed.status == StatusMark(kind: .error, text: texts))
        p.model.closeErrors()
        #expect(p.h.runner.error == nil)
        #expect(try p.details().status == StatusMark(kind: .info, text: SendBoxModel.slashHint))
    }

    // A button runs its action on the row of now.
    @Test func aButtonRunsItsAction() async throws {
        let p = try await PanelParts()
        defer { p.close() }
        p.h.selection.selectedId = s1
        let open = try #require(try p.details().buttons.first { $0.action == .open })
        p.model.press(open, sessionId: s1, anchor: nil)
        #expect(p.h.chatOpen(s1))
        #expect(try !p.details().buttons.contains { $0.action == .open })
    }

    // The colour menu of Add to watchlist has the colours of the row menu, and a choice adds the
    // row to the watchlist with the colour.
    @Test func addToWatchlistOpensTheColoursOfTheRowMenu() async throws {
        let p = try await PanelParts()
        defer { p.close() }
        let driver = MenuDriver()
        defer { driver.menu.close() }
        let menu = try #require(p.model.watchMenu(s1))
        let labels = menu.rows.compactMap { $0.spec?.label }
        #expect(
            labels == [
                "Dark red", "Red", "Amber", "Yellow", "Green", "Light blue", "Dark blue", "White",
            ])
        try p.pressWatchAdd(on: driver.menu)
        #expect(try driver.root.list.state.rows == menu.rows)
        let red = try #require(menu.rows.firstIndex { $0.spec?.label == "Red" })
        try driver.click(driver.row(red))
        await p.h.settle()
        #expect(!driver.menu.isOpen)
        #expect(p.h.row(s1)?.watch?.colour == .red)
        // A watched row has no colour menu.
        #expect(p.model.watchMenu(s1) == nil)
    }

    // The colour menu has the watch of the row of the row menu: it closes when its row leaves the
    // list, and when Add to watchlist turns off for the row.
    @Test func theColourMenuClosesWhenItsRowGoesOrIsWatched() async throws {
        let p = try await PanelParts()
        defer { p.close() }
        let driver = MenuDriver()
        defer { driver.menu.close() }
        try p.pressWatchAdd(on: driver.menu)
        #expect(driver.menu.isOpen)
        await p.h.deps.show([Entry.running(s2)]) { rows in !rows.contains { $0.sessionId == s1 } }
        await waitUntil { !driver.menu.isOpen }
        #expect(!driver.menu.isOpen)
        // A row that gets a watch colour while its menu shows has no Add to watchlist.
        try p.pressWatchAdd(on: driver.menu, sessionId: s2)
        #expect(driver.menu.isOpen)
        p.h.runner.run(.watchAdd, s2)
        await p.h.settle()
        await waitUntil { !driver.menu.isOpen }
        #expect(!driver.menu.isOpen)
    }

    // The host and each SwiftUI view in it refuse the first responder, so no button is in the Tab
    // loop of the window (the section "The UI" of the architecture design). Only the AppKit send
    // box takes the focus.
    @Test func theButtonsAreNotFocusable() async throws {
        let p = try await PanelParts()
        defer { p.close() }
        p.h.selection.selectedId = s1
        p.h.runner.notify("Done.")
        let panel = try p.panel()
        await waitUntil {
            panel.layoutSubtreeIfNeeded()
            return panel.sendBox.window != nil
        }
        let host = panel.host
        #expect(!host.acceptsFirstResponder)
        #expect(!host.canBecomeKeyView)
        _ = p.window.makeFirstResponder(host)
        #expect(p.window.firstResponder !== host)
        var views: [NSView] = [host]
        var all: [NSView] = []
        while let view = views.popLast() {
            guard view !== panel.sendBox else { continue }
            all.append(view)
            views += view.subviews
        }
        #expect(all.count > 1)
        #expect(all.allSatisfy { !$0.acceptsFirstResponder && !$0.canBecomeKeyView })
        #expect(panel.sendBox.isDescendant(of: host))
    }

    // The send box shows under the facts, inside the padding of 12 at each side, and goes with
    // no selected row.
    @Test func theSendBoxShowsOnlyForASelectedRow() async throws {
        let p = try await PanelParts()
        defer { p.close() }
        let panel = try p.panel()
        #expect(panel.sendBox.window == nil)
        p.h.selection.selectedId = s1
        let place = { panel.sendBox.convert(panel.sendBox.bounds, to: panel) }
        await waitUntil {
            panel.layoutSubtreeIfNeeded()
            return panel.sendBox.window != nil && Int(place().width.rounded()) == 336
        }
        let frame = place()
        #expect(frame.minY > 60)
        #expect(frame.height.rounded() == SendBoxView.height(metrics: p.h.look.metrics))
        #expect(Int(frame.minX.rounded()) == 12)
        p.h.selection.selectedId = nil
        await waitUntil {
            panel.layoutSubtreeIfNeeded()
            return panel.sendBox.window == nil
        }
    }

    // In a low frame the content scrolls, and a focus of the send box scrolls it into view. In
    // a high frame the send box shows with no scroll.
    @Test func aLowFrameScrollsToTheSendBox() async throws {
        let p = try await PanelParts()
        defer { p.close() }
        let panel = try p.panel(height: 150)
        p.h.selection.selectedId = s1
        await waitUntil {
            panel.layoutSubtreeIfNeeded()
            return panel.sendBox.window != nil
        }
        let box = panel.sendBox
        // The place of the box in the panel: the panel shows the part inside its bounds.
        let shows = { panel.bounds.contains(box.convert(box.bounds, to: panel)) }
        #expect(!shows())
        p.h.runner.run(.runSlash, s1)
        #expect(box.hasFocus)
        await waitUntil {
            panel.layoutSubtreeIfNeeded()
            return shows()
        }
        // A high frame shows all of the box.
        _ = p.window.makeFirstResponder(nil)
        panel.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        await waitUntil {
            panel.layoutSubtreeIfNeeded()
            return shows()
        }
    }

    // Run slash command with no selected row selects the row and focuses its send box at once,
    // although the view showed no send box before.
    @Test func runSlashWithNoSelectionFocusesTheSendBox() async throws {
        let p = try await PanelParts()
        defer { p.close() }
        let panel = try p.panel()
        #expect(panel.sendBox.window == nil)
        p.h.runner.run(.runSlash, s1)
        #expect(panel.sendBox.window != nil)
        #expect(panel.sendBox.hasFocus)
        #expect(panel.sendBox.field.string == "/")
    }

    // The drafts live in the part: a new body after a release shows the draft of the old one.
    @Test func aDraftStaysAfterTheBodyIsReleased() async throws {
        let p = try await PanelParts()
        defer { p.close() }
        p.h.selection.selectedId = s1
        let first = try p.panel()
        await waitUntil { first.sendBox.sessionId == s1 }
        first.sendBox.field.insertText("kept", replacementRange: NSRange(location: 0, length: 0))
        #expect(p.model.sendBox.draft(s1) == "kept")
        p.window.contentView = nil
        p.part.releaseBody(for: .selectedItem)
        let second = try p.panel()
        #expect(second !== first)
        await waitUntil { second.sendBox.sessionId == s1 }
        #expect(second.sendBox.field.string == "kept")
    }

    // The part makes the body of the one panel selected-item, and the same body until the
    // release.
    @Test func thePartMakesTheBodyOfTheSelectedItem() async throws {
        let p = try await PanelParts()
        defer { p.close() }
        let body = try #require(p.part.body(for: .selectedItem))
        #expect(p.part.body(for: .selectedItem) === body)
        #expect(p.part.body(for: .overview(1)) == nil)
        p.part.releaseBody(for: .selectedItem)
        #expect(p.part.body(for: .selectedItem) !== body)
    }

    // With the chats, the runner gives the steps of the loader to them.
    @Test func theRunnerGivesTheLoaderStepsToTheChats() async throws {
        let chats = ChatTerminals(
            ptys: nil, sizes: SessionSizeReader(inspector: FakeProcessInspector()), rows: { [] },
            clock: ManualClock(), links: LinkOpener(apps: NoDefaultApps()) { _ in },
            pasteboard: .withUniqueName(), renderer: .metal)
        let h = try await ActionsHarness(chats: chats)
        h.runner.loader(s1, .start)
        #expect(chats.showsLoader(s1))
        h.runner.loader(s1, .stop)
        #expect(!chats.showsLoader(s1))
        h.runner.loader(s1, .start)
        // No chat window: a finish ends the loader.
        h.runner.loader(s1, .finish)
        #expect(!chats.showsLoader(s1))
    }
}
