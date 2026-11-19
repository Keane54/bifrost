// The Show Info panel (docs/behaviour/panels.md, "Show Info"): the sections of the row, the PR
// line from the PR lookup, the texts with no row, the live hint, Copy session ID, the click on
// the PR, the error line and the time. The tests give a fake gh runner, a fake opener and a fake
// clipboard, so no test runs gh, opens a browser or writes the real clipboard.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostTestSupport
import Foundation
import Observation
import SwiftUI
import Testing

@testable import BifrostWindows

private let rowId = "0f8fad5b-d9cb-469f-a165-70867728950e"
private let conversationId = "1db82d17-d5fd-4e53-a042-7dd67ea654d8"
private let okJSON =
    #"{"number":12,"title":"Fix","url":"https://github.com/o/r/pull/12","state":"OPEN"}"#
private let panelID = PanelID.showInfo("0f8fad5b-d9cb-469f-a165-70867728950e")

private func row(branch: String? = "fix-a", live: Bool = true) -> SessionRow {
    var row = SessionRow.test(sessionId: rowId, name: "fix-a", kind: .external, cwd: "/p")
    row.branch = branch
    row.live = live
    if live { row.usage = LiveUsage(model: "claude-opus-5-5") }
    return row
}

// The wall time of the panel, which a test moves.
@MainActor
private final class WallClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private struct Parts {
    let source = FakeRowSource()
    let runner: FakeRunner
    let opener = FakeOpener()
    let clipboard = FakeClipboard()
    let clock = ManualClock()
    let wall = WallClock()
    let panels: ShowInfoPanels

    init(_ results: @escaping @Sendable (Command) -> ExecResult = { _ in
        ExecResult(.exited(0), stdout: okJSON)
    }) {
        UITestApp.prepare()
        let runner = FakeRunner(results)
        self.runner = runner
        let lookup = PRLookup(
            runner: runner, environment: [:], skipRoots: [], clock: ManualClock(),
            fileKind: { _ in .dir })
        let list = SessionListModel.reading(source)
        let actions = AppActions(
            rows: { list.rows }, apps: { [] }, opener: opener, clipboard: clipboard)
        let wall = wall
        panels = ShowInfoPanels(
            list: list, lookup: { lookup }, actions: actions, look: PanelLook(), clock: clock,
            now: { wall.date }, zone: .gmt)
    }

    // The model of the body of the panel.
    func model(_ panel: PanelID = panelID) throws -> ShowInfoPanelModel {
        let host = try #require(panels.body(for: panel) as? ShowInfoHost)
        return host.rootView.model
    }
}

@MainActor
private func sections(_ model: ShowInfoPanelModel) -> [InfoSection] {
    if case .info(let sections, _) = model.content { return sections }
    return []
}

@MainActor
private func prLine(_ model: ShowInfoPanelModel) -> String? {
    sections(model).first { $0.title == "Git" }?.items.first { $0.label == "PR" }?.value
}

@MainActor
@Suite("Show Info panel", .serialized, .timeLimit(.minutes(1)), .tags(.window))
struct ShowInfoPanelTests {
    @Test func thePanelShowsTheSevenSections() async throws {
        let p = Parts()
        p.source.apply(rows: [row()], error: nil)
        let model = try p.model()
        #expect(sections(model).map(\.title) == [
            "Session", "Files", "Git", "Model", "Time", "Cost and context", "Limits and version",
        ])
        #expect(prLine(model) == "Loading...")
        await waitUntil { model.pr != nil }
        #expect(prLine(model) == "#12 Fix (open)")
        #expect(p.runner.commands.map(\.directory) == ["/p"])
    }

    @Test func aRowWithNoLiveDataShowsTheHint() throws {
        let p = Parts()
        p.source.apply(rows: [row(live: false)], error: nil)
        let model = try p.model()
        guard case .info(_, let hint) = model.content else {
            Issue.record("no sections")
            return
        }
        #expect(hint)
        p.source.apply(rows: [row()], error: nil)
        guard case .info(_, let liveHint) = model.content else {
            Issue.record("no sections")
            return
        }
        #expect(!liveHint)
    }

    @Test func thePanelWaitsForTheListThenSaysWhenTheRowIsGone() throws {
        let p = Parts()
        let model = try p.model()
        #expect(model.content == .waiting)
        #expect(model.content.text == "Waiting for the session list...")
        p.source.apply(rows: [], error: nil)
        #expect(model.content == .gone)
        #expect(model.content.text == "This session isn't in the list any more.")
    }

    // A new folder or branch needs a new answer. A row that changes only its state does not:
    // its PR line never goes back to "Loading...". The follow of the panel runs on the main
    // actor, so the yields let it see the state change before the branch changes.
    @Test func aNewBranchAsksForThePRAgain() async throws {
        let p = Parts { command in
            ExecResult(
                .exited(1), stderr: command.directory == "/p" ? "no pull requests found" : "x")
        }
        p.source.apply(rows: [row()], error: nil)
        let model = try p.model()
        await waitUntil { model.pr == PRInfo.none }
        let values = Recorder<PRInfo?>(following: Observations { model.pr })
        defer { values.stop() }
        await waitUntil { values.values == [PRInfo.none] }
        var working = row()
        working.state = .working
        p.source.apply(rows: [working], error: nil)
        for _ in 0..<5 { await Task.yield() }
        #expect(model.pr == PRInfo.none)
        #expect(!values.values.contains(nil))
        #expect(p.runner.commands.count == 1)
        p.source.apply(rows: [row(branch: "fix-b")], error: nil)
        await waitUntil { p.runner.commands.count == 2 }
        await waitUntil { model.pr == PRInfo.none && values.values.last == PRInfo.none }
        // Only the new branch made the line "Loading..." again.
        #expect(values.values.filter { $0 == nil }.count <= 1)
        #expect(p.runner.commands.count == 2)
    }

    @Test func copySessionIdCopiesTheIdThatResumesTheSession() throws {
        let p = Parts()
        var external = row()
        external.currentId = conversationId
        p.source.apply(rows: [external], error: nil)
        let model = try p.model()
        model.copySessionId()
        #expect(p.clipboard.texts == [conversationId])
        #expect(model.error == nil)
    }

    // A background job whose resume ID is not known yet copies nothing. The reason stays in the
    // error line until the user closes it.
    @Test func aCopyThatFailsShowsItsReasonUntilTheClose() throws {
        let p = Parts()
        var job = row()
        job.kind = .owned
        job.currentId = conversationId
        p.source.apply(rows: [job], error: nil)
        let model = try p.model()
        model.copySessionId()
        #expect(p.clipboard.texts.isEmpty)
        #expect(model.error == ActionRefusal.noResumeId.message)
        #expect(model.error?.hasPrefix("Bifrost doesn't know which ID resumes") == true)
        model.closeError()
        #expect(model.error == nil)
    }

    @Test func aClickOnThePROpensItInTheBrowser() async throws {
        let p = Parts()
        p.source.apply(rows: [row()], error: nil)
        let model = try p.model()
        await waitUntil { model.pr != nil }
        await model.openPR()
        #expect(p.opener.calls == [.browse("https://github.com/o/r/pull/12")])
        #expect(model.error == nil)
    }

    @Test func aFailedOpenOfThePRShowsItsReason() async throws {
        let p = Parts()
        p.opener.failure = .openFailed("No browser is set.")
        p.source.apply(rows: [row()], error: nil)
        let model = try p.model()
        await model.openPR()
        #expect(model.error == "No browser is set.")
    }

    // The duration moves while the panel shows: the time of the panel moves each second.
    @Test func theTimeMovesEachSecond() async throws {
        let p = Parts()
        p.source.apply(rows: [row()], error: nil)
        let model = try p.model()
        let start = model.now
        await p.clock.waitForSleepers(1)
        p.wall.date += 61
        p.clock.advance(by: .seconds(1))
        await waitUntil { model.now == start + 61_000 }
    }

    @Test func eachPanelHasOneHostThatTakesNoFocus() throws {
        let p = Parts()
        let host = try #require(p.panels.body(for: panelID))
        #expect(p.panels.body(for: panelID) === host)
        #expect(p.panels.body(for: .settings) == nil)
        #expect(!host.acceptsFirstResponder)
        #expect(!host.canBecomeKeyView)
        let other = PanelID.showInfo("1db82d17-d5fd-4e53-a042-7dd67ea654d8")
        #expect(try p.model(other).session.text == conversationId)
        // A release ends the work of the body, and a later open makes a new body.
        p.panels.releaseBody(for: panelID)
        #expect(p.panels.body(for: panelID) !== host)
    }

    // The body in a window that is never ordered front. The Copy session ID button and the close
    // button of the error line each have their Bifrost tooltip.
    @Test func theBodyShowsTheButtonsWithTheirTooltips() async throws {
        let p = Parts()
        var job = row()
        job.kind = .owned
        p.source.apply(rows: [job], error: nil)
        let host = try #require(p.panels.body(for: panelID) as? ShowInfoHost)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(tips(in: host) == ["Copy session ID"])
        host.rootView.model.copySessionId()
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return tips(in: host) == ["Copy session ID", "Close"]
        }
    }

    @Test func aReleasedPanelStopsItsTimer() async throws {
        let p = Parts()
        p.source.apply(rows: [row()], error: nil)
        _ = try p.model()
        await p.clock.waitForSleepers(1)
        p.panels.releaseBody(for: panelID)
        await p.clock.waitUntilNoSleepers()
    }
}

// The texts of the tooltip anchors below the view, from the top to the bottom.
@MainActor
private func tips(in view: NSView) -> [String] {
    var all: [TipAnchorView] = []
    var next: [NSView] = [view]
    while let view = next.popLast() {
        if let tip = view as? TipAnchorView { all.append(tip) }
        next += view.subviews
    }
    return all.sorted {
        $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY
    }.map(\.text)
}
