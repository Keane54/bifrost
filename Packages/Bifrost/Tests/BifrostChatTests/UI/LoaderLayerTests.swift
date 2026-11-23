// The Take control loader of a chat window (docs/behaviour/chat.md, "The Take control loader"): the
// look of the layer, and its life on the chat terminals. The chats run on the fake PTY with a
// manual clock: no child process starts, and the test gives the output of each attach. The window
// is never ordered front.
import AppKit
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostTestSupport
import QuartzCore
import Testing

@testable import BifrostChat

private let id = "5a0e0001-0000-4000-8000-000000000001"

@Suite("the Take control loader layer", .serialized, .testTimeLimit, .tags(.window))
@MainActor
struct LoaderLayerTests {
    // The values of the look: the colours of the base gradient of the window background and no
    // colour of its own, the bottom two fifths, a fade from transparent that stays faint in its
    // upper half, a soft opacity and a slow shift.
    @Test func theLookHasTheValuesOfTheLoader() {
        let look = LoaderLook.standard
        #expect(look.colours == Motion.baseColours)
        #expect(look.angle == 100)
        #expect(look.widthFactor == 2)
        #expect(look.heightPart == 0.4)
        #expect(look.fade.first == LoaderLook.FadeStep(0, 0))
        #expect(look.fade.last == LoaderLook.FadeStep(1, 1))
        #expect(look.fade.count >= 5)
        #expect(look.fade.filter { $0.at <= 0.5 }.allSatisfy { $0.alpha <= 0.25 })
        #expect(look.fade.map(\.at) == look.fade.map(\.at).sorted())
        #expect(look.fade.map(\.alpha) == look.fade.map(\.alpha).sorted())
        #expect(look.opacity == 0.25)
        #expect(look.shiftTime == .seconds(12))
        #expect(look.textTop == 0.4)
        #expect(look.textSize == 13)
        #expect(look.textInset == 16)
    }

    // The layer covers the body, the terminal and the note are transparent, and a click goes
    // through. The band fills the bottom two fifths, fades in from its top edge and shifts.
    @Test func theLoaderCoversTheChatBodyAndHidesTheTerminal() async throws {
        let chat = try ChatFixture(fakePTY: true)
        chat.chats.reduceMotion = { false }
        chat.chats.startLoader(id)
        chat.open()
        let body = try #require(chat.chats.body(for: chat.panel()) as? ChatPanelBody)
        #expect(body.showsLoader)
        #expect(body.loader.text == "Taking control of fake...")
        #expect(body.host.alphaValue == 0)
        #expect(body.note.alphaValue == 0)
        body.layoutSubtreeIfNeeded()
        let loader = body.loader
        #expect(loader.frame == body.bounds)
        #expect(loader.hitTest(NSPoint(x: 10, y: 10)) == nil)
        let rainbow = loader.rainbow
        #expect(rainbow.frame.height == (body.bounds.height * 0.4).rounded())
        #expect(rainbow.frame.maxY == loader.bounds.height)
        #expect(rainbow.alphaValue == 0.25)
        // The mask goes from the top edge (y = 1 in the unit space) to the bottom edge.
        #expect(rainbow.mask.startPoint.y == 1)
        #expect(rainbow.mask.endPoint.y == 0)
        #expect(rainbow.mask.locations?.map(\.doubleValue) == LoaderLook.standard.fade.map(\.at))
        // The gradient has the colours of the background, from the left to the right.
        let colours = Motion.baseColours.map { [$0.r, $0.g, $0.b, $0.a].map { CGFloat($0) } }
        #expect((rainbow.gradient.colors as? [CGColor])?.map { $0.components ?? [] } == colours)
        #expect(rainbow.gradient.bounds.width == rainbow.bounds.width * 2)
        #expect(rainbow.gradient.startPoint.x < rainbow.gradient.endPoint.x)
        #expect(loader.isMoving)
        let shift = try #require(
            rainbow.gradient.animation(forKey: LoaderLayer.shiftKey) as? CABasicAnimation)
        #expect(shift.duration == 12)
        #expect(shift.autoreverses)
        #expect(shift.repeatCount == .infinity)
        chat.chats.stopLoader(id)
        #expect(!body.showsLoader)
        #expect(body.loader.text == nil)
        #expect(body.host.alphaValue == 1)
        #expect(body.note.alphaValue == 1)
        #expect(!loader.isMoving)
        await chat.close()
    }

    @Test func withReducedMotionTheBandDoesNotMove() async throws {
        let chat = try ChatFixture(fakePTY: true)
        chat.chats.reduceMotion = { true }
        chat.open()
        chat.chats.startLoader(id)
        let body = try #require(chat.chats.body(for: chat.panel()) as? ChatPanelBody)
        #expect(body.showsLoader)
        #expect(!body.loader.isMoving)
        chat.chats.stopLoader(id)
        await chat.close()
    }

    // After a good Take control, the loader waits for the first output of the terminal. The
    // time limit then stops.
    @Test func aGoodTakeControlWaitsForTheFirstOutput() async throws {
        let chat = try ChatFixture(fakePTY: true)
        chat.open()
        chat.chats.startLoader(id)
        await waitUntil {
            chat.fakeChild() != nil && chat.chats.terminal(id)?.state.attached == true
        }
        chat.chats.finishLoader(id)
        #expect(chat.chats.showsLoader(id))
        #expect(chat.chats.loaderTimer(id) != nil)
        try #require(await chat.waitForAttach())
        await waitUntil { !chat.chats.showsLoader(id) }
        #expect(chat.chats.loaderTimer(id) == nil)
        let body = try #require(chat.chats.body(for: chat.panel()) as? ChatPanelBody)
        #expect(!body.showsLoader)
        #expect(body.host.alphaValue == 1)
        await chat.close()
    }

    // When the terminal shows Claude while Take control still runs, the loader stays until the
    // finish, and it has no time limit.
    @Test func theFirstOutputBeforeTheFinishEndsTheLoaderAtTheFinish() async throws {
        let chat = try ChatFixture(fakePTY: true)
        chat.open()
        chat.chats.startLoader(id)
        try #require(await chat.waitForAttach())
        let terminal = try chat.terminal()
        #expect(terminal.isShowingText)
        #expect(chat.chats.showsLoader(id))
        #expect(chat.chats.loaderTimer(id) == nil)
        // The watch of the terminal takes the step shown in a later turn. Then the finish ends
        // the loader at once.
        var shown = TakeControlLoader()
        shown.start(id)
        shown.shown(id)
        await waitUntil { chat.chats.loaders == shown }
        chat.chats.finishLoader(id)
        #expect(!chat.chats.showsLoader(id))
        await chat.close()
    }

    // While Take control runs, the chat does not attach, also when its row can attach. After the
    // finish, the chat attaches. Its first output ends the loader.
    @Test func theChatAttachesOnlyWhenTakeControlEnds() async throws {
        let chat = try ChatFixture(
            rows: { [FakeSession.row(folder: $0, kind: .external)] }, fakePTY: true)
        chat.open()
        chat.chats.startLoader(id)
        let terminal = try chat.terminal()
        chat.rows = [FakeSession.row(folder: chat.home)]
        chat.sync()
        #expect({ if case .waiting = terminal.attachState { true } else { false } }())
        #expect(terminal.state.note == nil)
        chat.chats.finishLoader(id)
        try #require(await chat.waitForAttach())
        #expect(chat.fakes.spawns.count == 1)
        await waitUntil { !chat.chats.showsLoader(id) }
        await chat.close()
    }

    // After a failed Take control, a chat that stays open also attaches when its row can attach.
    @Test func aStopEndsTheWaitOfTheAttach() async throws {
        let chat = try ChatFixture(fakePTY: true)
        chat.chats.startLoader(id)
        chat.open()
        let terminal = try chat.terminal()
        #expect({ if case .waiting = terminal.attachState { true } else { false } }())
        chat.chats.stopLoader(id)
        await waitUntil { terminal.state.attached }
        #expect(chat.fakes.spawns.count == 1)
        await chat.close()
    }

    // A chat that closes and opens again while Take control runs waits again, and the finish
    // attaches the new terminal. Take control of one session does not hold the chat of another
    // session.
    @Test func aReopenedChatWaitsForTakeControlAndAnotherChatDoesNot() async throws {
        let chat = try ChatFixture(
            rows: {
                [
                    FakeSession.row(folder: $0),
                    FakeSession.row(FakeSession.second, folder: $0),
                ]
            }, fakePTY: true)
        chat.chats.startLoader(id)
        chat.open()
        chat.model.apply(.close(chat.panel()))
        chat.open()
        let again = try chat.terminal()
        #expect({ if case .waiting = again.attachState { true } else { false } }())
        chat.open(FakeSession.second, at: LayoutRect(x: 700, y: 0, w: 400, h: 400))
        try #require(await chat.waitForAttach(FakeSession.second))
        #expect(chat.fakeChild(id) == nil)
        chat.chats.finishLoader(id)
        try #require(await chat.waitForAttach(id))
        await chat.close()
    }

    // A window that cannot attach (an external row) shows no output, so the time limit of 20 s
    // ends the loader. The window then shows its note.
    @Test func theTimeLimitEndsALoaderThatWaitsForTheFirstOutput() async throws {
        let chat = try ChatFixture(
            rows: { [FakeSession.row(folder: $0, kind: .external)] }, fakePTY: true)
        chat.open()
        chat.chats.startLoader(id)
        let body = try #require(chat.chats.body(for: chat.panel()) as? ChatPanelBody)
        let start = chat.clock.now
        chat.chats.finishLoader(id)
        #expect(chat.chats.showsLoader(id))
        await chat.clock.waitForSleepers(1)
        #expect(chat.clock.nextDeadline == start.advanced(by: .seconds(20)))
        chat.clock.advance(by: .seconds(20))
        await waitUntil { !chat.chats.showsLoader(id) }
        #expect(!body.showsLoader)
        #expect(
            body.noteText
                == "This session runs in another terminal, so Bifrost can only show its status.")
        await chat.close()
    }

    // Each path ends the loader: a finish with no chat window, and the close of a chat window
    // whose loader waits for the first output. A loader of a Take control that runs stays when
    // its window closes, and its stop ends it.
    @Test func aFinishWithNoChatOrAClosedChatEndsTheLoader() async throws {
        let chat = try ChatFixture(
            rows: { [FakeSession.row(folder: $0, kind: .external)] }, fakePTY: true)
        chat.chats.startLoader(id)
        chat.chats.finishLoader(id)
        #expect(!chat.chats.showsLoader(id))

        chat.open()
        chat.chats.startLoader(id)
        chat.chats.finishLoader(id)
        #expect(chat.chats.showsLoader(id))
        chat.model.apply(.close(chat.panel()))
        #expect(!chat.chats.showsLoader(id))
        #expect(chat.chats.loaderTimer(id) == nil)

        chat.open()
        chat.chats.startLoader(id)
        chat.model.apply(.close(chat.panel()))
        #expect(chat.chats.showsLoader(id))
        chat.chats.stopLoader(id)
        #expect(!chat.chats.showsLoader(id))
        await chat.close()
    }

    // The shift moves the anchor point of the gradient from its left edge to its middle, so the
    // band shows the first half and then the second half of the gradient, on the ease-in-out
    // curve. The line of the gradient has the angle of the look across the whole gradient.
    @Test func theShiftHasTheTimingAndTheValuesOfTheLook() throws {
        UITestApp.prepare()
        let layer = LoaderLayer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        layer.show("Taking control...", reduceMotion: false)
        layer.layoutSubtreeIfNeeded()
        let gradient = layer.rainbow.gradient
        let shift = try #require(
            gradient.animation(forKey: LoaderLayer.shiftKey) as? CABasicAnimation)
        #expect(shift.keyPath == "anchorPoint")
        #expect(shift.fromValue as? CGPoint == CGPoint(x: 0, y: 0.5))
        #expect(shift.toValue as? CGPoint == CGPoint(x: 0.5, y: 0.5))
        #expect(shift.duration == 12)
        #expect(shift.autoreverses)
        #expect(shift.repeatCount == .infinity)
        var c1: [Float] = [0, 0]
        var c2: [Float] = [0, 0]
        shift.timingFunction?.getControlPoint(at: 1, values: &c1)
        shift.timingFunction?.getControlPoint(at: 2, values: &c2)
        #expect(c1 == [0.42, 0] && c2 == [0.58, 1])
        let band = layer.rainbow.bounds
        #expect(band.height == 120)
        #expect(gradient.bounds.size == CGSize(width: 800, height: 120))
        let line = Motion.gradientLine(100, 800, 120)
        #expect(abs(gradient.startPoint.x - line.x0 / 800) < 1e-9)
        #expect(abs(gradient.startPoint.y - (1 - line.y0 / 120)) < 1e-9)
        #expect(abs(gradient.endPoint.x - line.x1 / 800) < 1e-9)
        #expect(abs(gradient.endPoint.y - (1 - line.y1 / 120)) < 1e-9)
        // 100 degrees points to the right and a little down: the end is lower in the unit space.
        #expect(gradient.endPoint.y < gradient.startPoint.y)
        layer.hide()
        #expect(!layer.isMoving)
    }

    // A long line wraps inside the insets of 16 units, from 40 % of the height.
    @Test func aLongLineWraps() {
        UITestApp.prepare()
        let layer = LoaderLayer(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        layer.show("Taking control...", reduceMotion: true)
        layer.layoutSubtreeIfNeeded()
        let one = layer.label.frame.height
        let long = TakeControlLoader.text(name: String(repeating: "long-name ", count: 8))
        layer.show(long, reduceMotion: true)
        layer.layoutSubtreeIfNeeded()
        #expect(layer.label.frame.height > one * 2)
        #expect(layer.label.frame.minX == 16)
        #expect(layer.label.frame.width == 168)
        #expect(layer.label.frame.minY == 120)
    }

    // A close of the window (detachAll) ends a loader that waits for the first output, and
    // keeps the loader of a Take control that runs. Its stop then ends it.
    @Test func detachAllEndsALoaderThatWaitsAndKeepsOneThatRuns() async throws {
        let chat = try ChatFixture(
            rows: { [FakeSession.row(folder: $0, kind: .external)] }, fakePTY: true)
        chat.open()
        chat.chats.startLoader(id)
        chat.chats.finishLoader(id)
        #expect(chat.chats.showsLoader(id))
        chat.chats.detachAll()
        #expect(!chat.chats.showsLoader(id))
        #expect(chat.chats.loaderTimer(id) == nil)
        chat.sync()
        chat.chats.startLoader(id)
        chat.chats.detachAll()
        #expect(chat.chats.showsLoader(id))
        chat.chats.stopLoader(id)
        #expect(!chat.chats.showsLoader(id))
        await chat.close()
    }

    // A second Take control after a finish runs with no time limit, and its finish starts a new
    // limit of 20 s.
    @Test func aSecondTakeControlAfterAFinish() async throws {
        let chat = try ChatFixture(
            rows: { [FakeSession.row(folder: $0, kind: .external)] }, fakePTY: true)
        chat.open()
        chat.chats.startLoader(id)
        chat.chats.finishLoader(id)
        let first = try #require(chat.chats.loaderTimer(id))
        chat.clock.advance(by: .seconds(10))
        chat.chats.startLoader(id)
        #expect(chat.chats.showsLoader(id))
        #expect(chat.chats.loaderTimer(id) == nil)
        await first.value
        #expect(chat.chats.showsLoader(id))
        let start = chat.clock.now
        chat.chats.finishLoader(id)
        await chat.clock.waitForSleepers(1)
        #expect(chat.clock.nextDeadline == start.advanced(by: .seconds(20)))
        chat.clock.advance(by: .seconds(20))
        await waitUntil { !chat.chats.showsLoader(id) }
        await chat.close()
    }

    // The end line of a window counts as the terminal showing Claude: the loader goes, so the
    // line shows why the window ended.
    @Test func anEndLineEndsTheLoader() async throws {
        let chat = try ChatFixture(fakePTY: true)
        chat.open()
        await waitUntil {
            chat.fakeChild() != nil && chat.chats.terminal(id)?.state.attached == true
        }
        let terminal = try chat.terminal()
        #expect(!terminal.isShowingText)
        chat.chats.startLoader(id)
        chat.chats.finishLoader(id)
        #expect(chat.chats.showsLoader(id))
        try #require(chat.fakeChild()).emitExit(0)
        await waitUntil { terminal.state.ended }
        await waitUntil { !chat.chats.showsLoader(id) }
        await chat.close()
    }

    // The loader is keyed by the row ID, which a /clear does not change: the row gets a new
    // current ID, and the loader stays on the chat window of the row.
    @Test func theLoaderIsKeyedByTheRowId() async throws {
        let chat = try ChatFixture(
            rows: { [FakeSession.row(folder: $0, kind: .external)] }, fakePTY: true)
        chat.open()
        chat.chats.startLoader(id)
        chat.rows[0].currentId = "6b1f0003-0000-4000-8000-000000000003"
        chat.sync()
        let body = try #require(chat.chats.body(for: chat.panel()) as? ChatPanelBody)
        #expect(chat.chats.showsLoader(id))
        #expect(body.showsLoader)
        #expect(!chat.chats.showsLoader("6b1f0003-0000-4000-8000-000000000003"))
        chat.chats.stopLoader(id)
        await chat.close()
    }
}
