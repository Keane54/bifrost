import AppKit
import BifrostDailyUpdate
import BifrostFoundation
import BifrostLayout
import BifrostSessions
import BifrostTestSupport
import Foundation
import Observation
import Testing

@testable import BifrostWindows

// The Daily update panel (docs/behaviour/daily-update.md, "The panel") over a real service with a
// state file in a temporary folder. The settings have no ticket source and no merged PRs, so a
// run fails at once with nothing to read: no claude and no gh runs. The confirm dialog, the
// browser and the clipboard are fakes.

private func london() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .gmt
    return calendar
}

// A moment of November 2026 in London. The 18th is a Wednesday, the 21st a Saturday.
private func november(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
    london().date(
        from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))
        ?? .distantPast
}

private func milliseconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }

// The state file with views of the areas. sent: the areas that are sent at 07:45 today.
private func stateFile(
    _ views: [String: String], sent: [String] = [], lastRun: String? = nil,
    unplaced: String = "[]", day: Int = 18
) -> String {
    let areas = views.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ",")
    let at = milliseconds(november(day, 7, 45))
    let marks = sent.map { "\"\($0)\": \(at)" }.joined(separator: ",")
    return """
        {"version":1,"marks":{"date":"2026-11-\(day)","skipped":false,"sent":{\(marks)},\
        "firstShown":false,"secondShown":false},"lastSent":{},"prevSent":{},\
        "areas":{\(areas)},"unplaced":\(unplaced)\(lastRun.map { ",\"lastRun\":\($0)" } ?? "")}
        """
}

private func view(_ draft: String, edited: Bool = false, items: String = "[]") -> String {
    let text = String(decoding: (try? JSONEncoder().encode(draft)) ?? Data(), as: UTF8.self)
    return #"{"draft":\#(text),"edited":\#(edited),"items":\#(items),"moved":true}"#
}

private let alpha = WorkArea(id: "a1", name: "Alpha", channel: "#team")
private let beta = WorkArea(id: "a2", name: "Beta")

// The settings of a test. The service reads them from its init on.
@MainActor
private final class Config {
    var value: DailySettings

    init(_ value: DailySettings) { self.value = value }
}

// The service of a panel model, as a test sets it.
@MainActor
@Observable
private final class ServiceHolder {
    var service: DailyUpdateService?
}

// The changes that an editor gave.
@MainActor
private final class Edits {
    var texts: [String] = []
}

// Why there is no service, as a test sets it.
@MainActor
private final class Reason {
    var text: String?
}

// The service and the panel model of a test.
@MainActor
private final class PanelHome {
    let folder: TemporaryFolder
    let store: DailyStateStore
    let service: DailyUpdateService
    let model: DailyUpdatePanelModel
    let clock = ManualClock()
    // gh of the merged PRs. It runs nothing.
    let gh = FakeRunner(ExecResult(.exited(1)))
    let opener = FakeOpener()
    let clipboard = FakeClipboard()
    let config: Config
    var asked: [ConfirmText] = []
    var answer = false
    var settingsOpened = 0

    init(
        at time: Date, areas: [WorkArea], state: String? = nil, mergedPrs: Bool = false
    ) async throws {
        folder = try TemporaryFolder()
        let layout = DailyLayout(folder: folder.url.appending(path: "daily-update"))
        if let state {
            try FileManager.default.createDirectory(
                at: layout.folder, withIntermediateDirectories: true)
            try Data(state.utf8).write(to: layout.stateFile)
        }
        store = try await DailyStateStore.open(layout: layout, log: Recorder<StoreEvent>())
        var settings = DailySettings.defaults
        settings.areas = areas
        settings.mergedPrs = mergedPrs
        let config = Config(settings)
        self.config = config
        let calendar = london()
        let runner = DailyRunner(
            claude: FakeRunner(ExecResult(.exited(1))).claude(),
            gh: GHCommand(path: "gh", environment: [:], folder: layout.runsFolder, runner: gh),
            layout: layout, skills: folder.url, report: { _ in }, clock: clock,
            calendar: calendar)
        weak var home: PanelHome?
        let service = DailyUpdateService(
            store: store, runner: runner, settings: { config.value },
            notifier: FakeNotifier(), bounceDock: {}, openPanel: { _ in }, clock: clock,
            now: { time }, calendar: { calendar })
        self.service = service
        model = DailyUpdatePanelModel(
            service: { service }, unavailable: { nil },
            links: DailyPanelLinks(
                confirm: { text in
                    home?.asked.append(text)
                    return home?.answer ?? false
                },
                openSettings: { home?.settingsOpened += 1 }, opener: opener,
                clipboard: clipboard),
            clock: clock, now: { time }, zone: calendar.timeZone)
        home = self
    }

    func finish() async {
        service.stop()
        await service.savesEnded()
        await store.close()
        folder.remove()
    }
}

@MainActor
private func withHome(
    at time: Date = november(18, 8, 0), areas: [WorkArea] = [alpha, beta], state: String? = nil,
    mergedPrs: Bool = false, _ body: (PanelHome) async throws -> Void
) async throws {
    let home = try await PanelHome(at: time, areas: areas, state: state, mergedPrs: mergedPrs)
    do {
        try await body(home)
    } catch {
        await home.finish()
        throw error
    }
    await home.finish()
}

@MainActor
@Suite("the Daily update panel", .timeLimit(.minutes(1)))
struct DailyUpdatePanelTests {
    @Test func oneTabPerAreaThatIsOn() async throws {
        let off = WorkArea(id: "a3", on: false, name: "Gamma")
        try await withHome(areas: [alpha, off, beta]) { home in
            #expect(home.model.shown == .tabs)
            #expect(home.model.snapshot?.tabs.map(\.id) == ["a1", "a2"])
            #expect(home.model.snapshot?.tabs.map(\.name) == ["Alpha", "Beta"])
            // The first tab that is not sent shows first.
            #expect(home.model.shownTab?.id == "a1")
        }
    }

    @Test func anUnsentTabHasAMarker() async throws {
        let state = stateFile(["a1": view("One"), "a2": view("Two")], sent: ["a2"])
        try await withHome(state: state) { home in
            let tabs = try #require(home.model.snapshot?.tabs)
            #expect(tabs.map { home.model.marker($0) } == [true, false])
            #expect(home.model.shownTab?.id == "a1")
            home.model.markSent("a1")
            let after = try #require(home.model.snapshot?.tabs)
            #expect(after.map { home.model.marker($0) } == [false, false])
            #expect(home.model.sentText(after[0]) == "Sent at 08:00")
            // The tab stays after its mark.
            #expect(home.model.shownTab?.id == "a1")
        }
        // A day that is not due has no marker.
        try await withHome(at: november(21, 8, 0)) { home in
            let tabs = try #require(home.model.snapshot?.tabs)
            #expect(tabs.allSatisfy { !home.model.marker($0) })
            #expect(home.model.dueText == nil)
            #expect(home.model.skipAction == nil)
        }
    }

    @Test func redoAsksFirstForAChangedDraft() async throws {
        let state = stateFile(["a1": view("Mine", edited: true), "a2": view("Two")])
        try await withHome(state: state) { home in
            home.service.start()
            await home.model.redo("a1")
            #expect(home.asked == [DailyUpdatePanelModel.redoText])
            #expect(home.service.manual == nil)
            #expect(home.model.snapshot?.tabs.first?.draft == "Mine")
            // A draft that the user did not change runs with no question.
            await home.model.redo("a2")
            #expect(home.asked.count == 1)
            let run = try #require(home.service.manual)
            await run.value
            #expect(home.model.snapshot?.failure?.text == FailureCode.nothingToRead.text())
            // A yes runs the Redo.
            home.answer = true
            await home.model.redo("a1")
            #expect(home.asked.count == 2)
            #expect(home.service.manual != nil)
            await home.service.manual?.value
        }
    }

    @Test func copyGivesStandardMarkdown() async throws {
        let state = stateFile(["a1": view("**Daily update**\n** Done **")])
        try await withHome(state: state) { home in
            home.model.copy("a1")
            // A bold part with white space at its edge is standard Markdown again.
            #expect(home.clipboard.texts == ["**Daily update**\n **Done** "])
            #expect(home.model.copied == "a1")
            await home.clock.waitForSleepers(1)
            home.clock.advance(by: DailyUpdatePanelModel.copiedTime)
            await home.model.copiedTask?.value
            #expect(home.model.copied == nil)
            // A tab with no draft copies nothing.
            home.model.copy("a2")
            #expect(home.clipboard.texts.count == 1)
        }
    }

    @Test func sendIsOffWithItsTip() async throws {
        try await withHome { home in
            let tabs = try #require(home.model.snapshot?.tabs)
            let buttons = tabs.map(home.model.buttons)
            #expect(buttons.map(\.sendLabel) == ["Send to #team", "Send"])
            #expect(buttons.allSatisfy { !$0.send })
            #expect(
                buttons.allSatisfy {
                    $0.sendTip == "Sending comes with the Slack app. For now, copy the draft."
                })
        }
    }

    // Redo and Refresh are off while a run goes. Copy needs a draft. Mark as sent stays on.
    @Test func theButtonsFollowTheRun() async throws {
        let state = stateFile(["a1": view("One")])
        try await withHome(state: state, mergedPrs: true) { home in
            home.service.start()
            let tabs = try #require(home.model.snapshot?.tabs)
            #expect(home.model.canRefresh)
            #expect(tabs.map { home.model.buttons($0).redo } == [true, true])
            #expect(tabs.map { home.model.buttons($0).copy } == [true, false])
            #expect(tabs.map { home.model.buttons($0).markSent } == [true, true])
            // The run waits in gh. The stop at the end of the test cancels it.
            home.gh.hold()
            home.model.refresh()
            await home.gh.held.wait(for: "the held gh of the run")
            #expect(home.model.snapshot?.isRunning == true)
            #expect(!home.model.canRefresh)
            let running = home.model.buttons(tabs[0])
            #expect(!running.redo)
            #expect(running.copy)
            #expect(running.markSent)
            #expect(!running.send)
        }
    }

    @Test func noAreaShowsTheSettingsButton() async throws {
        let off = WorkArea(id: "a3", on: false, name: "Gamma")
        try await withHome(areas: [off]) { home in
            #expect(home.model.shown == .noArea)
            home.model.openSettings()
            #expect(home.settingsOpened == 1)
        }
        // With no service, the panel says why, or shows nothing while the service starts.
        let reason = Reason()
        let model = DailyUpdatePanelModel(
            service: { nil }, unavailable: { reason.text }, links: DailyPanelLinks(),
            clock: ManualClock(), now: Date.init, zone: .gmt)
        #expect(model.shown == .starting)
        reason.text = DailyUpdateService.noClaudeText
        #expect(model.shown == .unavailable(DailyUpdateService.noClaudeText))
    }

    @Test func aFailedRunKeepsMarkAsSentOn() async throws {
        let at = milliseconds(november(18, 7, 30))
        let state = stateFile(
            ["a1": view("One")], lastRun: #"{"at":\#(at),"ok":false,"failure":"no-user"}"#)
        try await withHome(state: state) { home in
            let snapshot = try #require(home.model.snapshot)
            #expect(snapshot.failure?.text == FailureCode.noUser.text())
            #expect(home.model.statusText == "Bifrost couldn't write your drafts.")
            #expect(home.model.refreshText == nil)
            #expect(home.model.skipAction == .skip)
            // The buttons of the day stay on after the failure.
            let buttons = home.model.buttons(try #require(snapshot.tabs.first))
            #expect(buttons.markSent)
            #expect(buttons.sent == nil)
            #expect(buttons.redo)
            #expect(home.model.canRefresh)
            home.model.markSent("a1")
            #expect(home.model.snapshot?.tabs.first?.sentAt == november(18, 8, 0))
            home.model.undoSent("a1")
            home.model.skipToday()
            #expect(home.model.skipAction == .undo)
            #expect(home.model.snapshot?.tabs.allSatisfy { !home.model.marker($0) } == true)
            home.model.undoSkip()
            #expect(home.model.skipAction == .skip)
        }
    }

    @Test func onlyAnHttpsItemLinkOpens() async throws {
        let items = """
            [{"kind":"ticket","id":"T-1","title":"Safe","url":"https://board.example.com/T-1"},\
            {"kind":"ticket","id":"T-2","title":"Plain","url":"http://board.example.com/T-2"},\
            {"kind":"ticket","id":"T-3","title":"Script","url":"javascript:alert(1)"},\
            {"kind":"pr","id":"PR-4","title":"No link"}]
            """
        let state = stateFile(["a1": view("One", items: items)])
        try await withHome(state: state) { home in
            let list = try #require(home.model.snapshot?.tabs.first?.items)
            let opens = list.map { DailyUpdatePanelModel.link(of: $0) != nil }
            #expect(opens == [true, false, false, false])
            for item in list.dropFirst() { #expect(home.model.open(item) == nil) }
            await home.model.open(list[0])?.value
            #expect(home.opener.calls == [.browse("https://board.example.com/T-1")])
        }
    }

    @Test func theStatusLineTellsTheDay() async throws {
        let at = milliseconds(november(18, 7, 30))
        let unplaced = #"[{"kind":"ticket","id":"T-9","title":"Lost"}]"#
        let state = stateFile(
            ["a1": view("One")], lastRun: #"{"at":\#(at),"ok":true}"#, unplaced: unplaced)
        try await withHome(state: state) { home in
            #expect(home.model.dueText == "Due 10:00")
            #expect(home.model.refreshText == "Refreshed 07:30")
            #expect(home.model.unplacedText == "1 ticket fits no area")
            #expect(!home.model.showsUnplaced)
            home.model.toggleUnplaced()
            #expect(home.model.showsUnplaced)
            // A click on a reminder asks for a tab.
            home.model.show(area: "a2")
            #expect(home.model.shownTab?.id == "a2")
        }
    }

    // The editor shows the draft again only for a new draft or a new font, so a change of the
    // user keeps its caret.
    @Test func theEditorShowsADraftAgainOnlyWhenItChanged() {
        let draft = "**Done** today"
        let again = DailyUpdatePanelModel.showsDraftAgain
        #expect(!again(draft, draft, false))
        #expect(again("New", draft, false))
        #expect(again(draft, draft, true))
    }

    // The open run follows the service: a panel that got its body before the service started
    // runs the drafts when the service comes. A body that went before runs nothing: its wait
    // ends with the body, so the service that comes later gets no open from it.
    @Test func theOpenRunWaitsForTheService() async throws {
        UITestApp.prepare()
        try await withHome { home in
            home.service.start()
            let holder = ServiceHolder()
            let model = DailyUpdatePanelModel(
                service: { holder.service }, unavailable: { nil }, links: DailyPanelLinks(),
                clock: home.clock, now: { november(18, 8, 0) }, zone: .gmt)
            let panels = DailyUpdatePanels(model: model)
            _ = panels.body(for: .dailyUpdate)
            let gone = try #require(panels.opening)
            panels.releaseBody(for: .dailyUpdate)
            #expect(panels.opening == nil)
            holder.service = home.service
            await gone.value
            #expect(home.service.manual == nil)
            #expect(home.service.snapshot.failure == nil)
            // A new body of the panel with the service there runs the open.
            _ = panels.body(for: .dailyUpdate)
            let opening = try #require(panels.opening)
            await opening.value
            await home.service.manual?.value
            #expect(home.service.snapshot.failure?.text == FailureCode.nothingToRead.text())
        }
    }

    // The editor has its own undo. The same draft from the service keeps the text and its undo.
    // A new draft clears the undo, so Cmd+Z never acts on the text of an earlier draft.
    @Test func aNewDraftClearsTheUndoOfTheEditor() {
        UITestApp.prepare()
        let font = NSFont.systemFont(ofSize: 12)
        let bold = NSFont.boldSystemFont(ofSize: 12)
        let edits = Edits()
        let editor = DraftEditor(draft: "**Done** today", font: font, boldFont: bold) {
            edits.texts.append($0)
        }
        let coordinator = editor.makeCoordinator()
        let view = DraftEditor.makeTextView()
        view.delegate = coordinator
        DraftEditor.update(view, draft: editor.draft, font: font, boldFont: bold)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        window.contentView?.addSubview(view)
        #expect(window.makeFirstResponder(view))
        view.insertText(" now", replacementRange: view.selectedRange())
        #expect(edits.texts.last == "**Done** today now")
        #expect(view.undoManager?.canUndo == true)
        DraftEditor.update(view, draft: "**Done** today now", font: font, boldFont: bold)
        #expect(view.string == "Done today now")
        #expect(view.undoManager?.canUndo == true)
        DraftEditor.update(view, draft: "New", font: font, boldFont: bold)
        #expect(view.string == "New")
        #expect(view.undoManager?.canUndo == false)
        view.insertText("!", replacementRange: view.selectedRange())
        view.undoManager?.undo()
        #expect(view.string == "New")
    }

    // The editor shows a bold part bold with no stars, and gives Markdown back.
    @Test func theEditorShowsBoldAndGivesMarkdownBack() {
        let font = NSFont.systemFont(ofSize: 12)
        let bold = NSFont.boldSystemFont(ofSize: 12)
        let text = DraftEditor.attributed("**Done** today\nNext", font: font, boldFont: bold)
        #expect(text.string == "Done today\nNext")
        #expect(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == bold)
        #expect(text.attribute(.font, at: 5, effectiveRange: nil) as? NSFont == font)
        #expect(DraftEditor.markdown(of: text) == "**Done** today\nNext")
        // Text typed after the bold part keeps its attribute, so it is bold too.
        let typed = NSMutableAttributedString(attributedString: text)
        let attributes = typed.attributes(at: 3, effectiveRange: nil)
        typed.insert(NSAttributedString(string: " all", attributes: attributes), at: 4)
        #expect(DraftEditor.markdown(of: typed) == "**Done all** today\nNext")
    }
}
