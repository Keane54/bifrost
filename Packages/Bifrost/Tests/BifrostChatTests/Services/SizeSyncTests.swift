import BifrostTestSupport
import CoreGraphics
import Testing

@testable import BifrostChat
@testable import BifrostSessions

// The size of one chat window (docs/behaviour/chat.md, "The size"). The tests give the times as
// instants a number of milliseconds after a fixed start.

private let A = TerminalSize(cols: 100, rows: 30)
private let B = TerminalSize(cols: 80, rows: 24)
private let C = TerminalSize(cols: 90, rows: 20)
private let panelPixels = CGSize(width: 800, height: 600)
// A screen smaller than the panel (zoom 1), and a screen of twice the size (zoom 0.5).
private let smallScreen = CGSize(width: 400, height: 300)
private let largeScreen = CGSize(width: 1600, height: 1200)
private let focusedView = ChatView(visible: true, focused: true)
private let shownView = ChatView(visible: true, focused: false)

extension [SizeEffect] {
    fileprivate var sends: [TerminalSize] {
        compactMap { effect in
            guard case .send(let size, _) = effect else { return nil }
            return size
        }
    }

    fileprivate var terminalResizes: [TerminalSize] {
        compactMap { effect in
            guard case .resizeTerminal(let size) = effect else { return nil }
            return size
        }
    }

    fileprivate var scales: [Double] {
        compactMap { effect in
            guard case .scale(let scale, _) = effect else { return nil }
            return scale
        }
    }
}

private let origin = ContinuousClock.now
private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
    origin.advanced(by: .milliseconds(milliseconds))
}

// A window with this view, the panel, the fit and the screen, before its open.
private func shown(
    _ view: ChatView, fit: TerminalSize? = A, screen: CGSize = smallScreen, now: Int = 1000
) -> SizeSync {
    var size = SizeSync()
    size.setView(view, focusGained: view.focused, attached: false, now: at(now))
    size.setPanel(panelPixels, fit: fit, screen: screen, attached: false, now: at(now))
    return size
}

// The window opens at its open size at the time now, and the attach starts. It has no effects to
// take.
private func opened(_ size: inout SizeSync, now: Int = 1000) {
    size.open(at: size.openSize, now: at(now))
    size.attached(now: at(now))
    _ = size.takeEffects()
}

// A focused window that attached at the time 1000 with the fit A.
private func attachedFocused() -> SizeSync {
    var size = shown(focusedView)
    opened(&size)
    return size
}

// A window that is not focused and attached at the time 1000 with the session size B.
private func attachedUnfocused(screen: CGSize = smallScreen) -> SizeSync {
    var size = shown(shownView, screen: screen)
    size.sessionRead(B)
    opened(&size)
    return size
}

@Suite("chat size", .testTimeLimit)
struct SizeSyncTests {
    @Test func aVisibleWindowWaitsForItsPanel() {
        var size = SizeSync()
        size.setView(focusedView, focusGained: true, attached: false, now: at(1000))
        #expect(size.waitsForPanel)
        size.setPanel(panelPixels, fit: A, screen: smallScreen, attached: false, now: at(1000))
        #expect(!size.waitsForPanel)
        #expect(size.openSize == A)

        // A hidden window does not wait for a panel.
        var hidden = SizeSync()
        hidden.setView(.hidden, focusGained: false, attached: false, now: at(1000))
        #expect(!hidden.waitsForPanel)
    }

    @Test func aWindowThatIsNotFocusedReadsTheSessionSizeOnce() {
        var size = shown(shownView)
        #expect(size.needsSessionSize)
        size.sessionRead(C)
        #expect(!size.needsSessionSize)
        #expect(size.openSize == C)
        size.open(at: C, now: at(1200))
        #expect(size.takeEffects().terminalResizes.last == C)

        // A session size that comes during the read is newer than the read.
        var newer = shown(shownView)
        newer.setSessionSize(B, attached: false, now: at(1100))
        newer.sessionRead(C)
        #expect(newer.openSize == B)

        // A failed read gives no size, so the window opens at the fit.
        var failed = shown(shownView)
        failed.sessionRead(nil)
        #expect(failed.openSize == A)
        // The window reads the size one time only.
        #expect(!failed.needsSessionSize)

        // A focused window opens at the fit, and a known session size needs no read.
        #expect(!shown(focusedView).needsSessionSize)
        var known = shown(shownView)
        known.setSessionSize(B, attached: false, now: at(1000))
        #expect(!known.needsSessionSize)
    }

    @Test func aFocusedWindowOpensAtTheFit() {
        var size = shown(focusedView)
        let start = size.takeEffects()
        #expect(start.terminalResizes.last == A)
        #expect(start.contains(.focusTerminal))
        #expect(size.openSize == A)

        // The open sent the fit, so the focus gain sends no resize.
        size.open(at: A, now: at(1000))
        size.attached(now: at(1000))
        #expect(size.takeEffects().isEmpty)
    }

    // Before the attach, the open sends the size: a new fit resizes only the terminal.
    @Test func aWindowThatIsNotAttachedSendsNoResize() {
        var size = shown(focusedView)
        _ = size.takeEffects()
        size.setPanel(panelPixels, fit: B, screen: smallScreen, attached: false, now: at(1100))
        #expect(size.takeEffects() == [.resizeTerminal(B)])
    }

    // Each change of the fit gives a send. The sender keeps only the last one (SizeSenderTests).
    @Test func eachNewFitGivesASend() {
        var size = attachedFocused()
        let last = TerminalSize(cols: 70, rows: 22)
        size.setPanel(panelPixels, fit: B, screen: smallScreen, attached: true, now: at(2000))
        size.setPanel(panelPixels, fit: C, screen: smallScreen, attached: true, now: at(2050))
        size.setPanel(panelPixels, fit: last, screen: smallScreen, attached: true, now: at(2100))
        let burst = size.takeEffects()
        #expect(burst.terminalResizes == [B, C, last])
        #expect(burst.sends == [B, C, last])
    }

    @Test func aFocusGainSendsTheBumpThenTheFit() {
        var size = attachedFocused()
        size.setView(shownView, focusGained: false, attached: true, now: at(1100))
        // Another client gives the session the size B.
        size.setSessionSize(B, attached: true, now: at(5000))
        #expect(size.takeEffects() == [.resizeTerminal(B)])

        size.setView(focusedView, focusGained: true, attached: true, now: at(5000))
        let gain = size.takeEffects()
        #expect(gain.terminalResizes == [A])
        #expect(gain.contains(.send(A, bump: SizeRule.bump(A))))

        // The time of setView counts. Within 500 ms of a send, a different session size is an
        // old read, so a focus gain at that time sends the fit with no bump.
        var soon = attachedFocused()
        soon.setView(shownView, focusGained: false, attached: true, now: at(1100))
        soon.setSessionSize(B, attached: true, now: at(1200))
        soon.setView(focusedView, focusGained: true, attached: true, now: at(1300))
        #expect(soon.takeEffects().contains(.send(A, bump: nil)))
    }

    // The sender tells the size that went to the PTY, so a session size soon after it is an old
    // read.
    @Test func aSizeThatWentToThePTYStartsTheOldReadTime() {
        var size = attachedFocused()
        size.sent(now: at(5000))
        size.setSessionSize(B, attached: true, now: at(5400))
        #expect(size.takeEffects().isEmpty)
        size.setSessionSize(B, attached: true, now: at(5600))
        #expect(size.takeEffects() == [.resizeTerminal(B)])
    }

    @Test func aWindowThatIsNotFocusedFollowsTheSessionSizeAndZooms() {
        var size = attachedUnfocused()
        size.setSessionSize(C, attached: true, now: at(2000))
        #expect(size.takeEffects() == [.resizeTerminal(C)])

        size.setPanel(panelPixels, fit: A, screen: largeScreen, attached: true, now: at(2100))
        #expect(size.takeEffects() == [.scale(0.5, blocksPointer: true)])

        // The focused window takes the keys, so the pointer blocker goes.
        size.setView(focusedView, focusGained: true, attached: true, now: at(2200))
        #expect(size.takeEffects().contains(.scale(0.5, blocksPointer: false)))
    }

    @Test func theScaleNeverGoesAbove1() {
        var size = attachedUnfocused(screen: smallScreen)
        size.setPanel(panelPixels, fit: A, screen: smallScreen, attached: true, now: at(2000))
        var effects = size.takeEffects()
        size.setPanel(panelPixels, fit: A, screen: largeScreen, attached: true, now: at(2100))
        effects += size.takeEffects()
        size.setPanel(
            CGSize(width: 4000, height: 3000), fit: A, screen: largeScreen, attached: true,
            now: at(2200))
        effects += size.takeEffects()
        #expect(effects.scales == [0.5, 1])
        #expect(effects.contains(.scale(1, blocksPointer: false)))
    }

    // The start of the open sets the send time, with the time of the open. A different session
    // size within 500 ms of the open is an old read, so the terminal keeps the size of the open.
    @Test func aSizeReadSoonAfterTheOpenIsAnOldRead() {
        var size = SizeSync()
        size.setView(focusedView, focusGained: true, attached: false, now: at(1000))
        size.setPanel(panelPixels, fit: A, screen: smallScreen, attached: false, now: at(1000))
        opened(&size, now: 5000)
        size.setSessionSize(B, attached: true, now: at(5400))
        #expect(size.takeEffects().isEmpty)
        size.setSessionSize(C, attached: true, now: at(5600))
        #expect(size.takeEffects() == [.resizeTerminal(C)])
    }

    // A reattach opens at the size that the terminal has now.
    @Test func aReattachOpensAtTheSizeOfTheTerminal() {
        var size = attachedUnfocused()
        size.setSessionSize(C, attached: true, now: at(2000))
        _ = size.takeEffects()
        #expect(size.terminal == C)
        size.open(at: size.terminal, now: at(2100))
        #expect(size.takeEffects().isEmpty)
        // The new size of the session counts after the open.
        size.setSessionSize(B, attached: true, now: at(2700))
        #expect(size.takeEffects() == [.resizeTerminal(B)])
    }

    // TerminalSize.isValid: a size of 0 or above 1000 is no size.
    @Test func aBadSizeIsNoSize() {
        let size = shown(focusedView, fit: TerminalSize(cols: 1001, rows: 30))
        #expect(size.openSize == SizeRule.defaultTerm)

        var unfocused = attachedUnfocused()
        unfocused.setSessionSize(TerminalSize(cols: 0, rows: 20), attached: true, now: at(2000))
        unfocused.setSessionSize(TerminalSize(cols: 90, rows: 1001), attached: true, now: at(2100))
        #expect(unfocused.takeEffects().terminalResizes.isEmpty)

        var read = shown(shownView)
        read.sessionRead(TerminalSize(cols: 1001, rows: 20))
        #expect(read.openSize == A)
    }
}

// The sender of the sizes to the PTY, on a manual clock: one debounce of 150 ms, the bump, 60 ms
// and the fit.
@MainActor
@Suite("size sender", .testTimeLimit)
struct SizeSenderTests {
    private let clock = ManualClock()
    private var sent = Box()

    @MainActor
    private final class Box {
        var sizes: [TerminalSize] = []
        var attached = true
    }

    private func sender() -> SizeSender {
        let box = sent
        return SizeSender(clock: clock, attached: { box.attached }, send: { box.sizes.append($0) })
    }

    @Test func aBurstSendsOnlyTheLastSizeAfterTheQuietTime() async {
        let sender = sender()
        sender.queue(B, bump: nil)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(100))
        sender.queue(C, bump: nil)
        clock.advance(by: .milliseconds(100))
        // The task woke at the old deadline and sleeps again to the new one.
        await clock.waitForSleepers(1)
        #expect(sent.sizes.isEmpty)
        clock.advance(by: .milliseconds(50))
        await waitUntil { sent.sizes == [C] }
    }

    @Test func aBumpGoesFirstThenTheFitAfterTheGap() async {
        let sender = sender()
        sender.queue(A, bump: SizeRule.bump(A))
        await clock.waitForSleepers(1)
        clock.advance(by: SizeRule.resizeDebounce)
        await waitUntil { sent.sizes == [SizeRule.bump(A)] }
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(59))
        // The gap still sleeps, so the fit did not go.
        #expect(clock.sleeperCount == 1)
        #expect(sent.sizes == [SizeRule.bump(A)])
        clock.advance(by: .milliseconds(1))
        await waitUntil { sent.sizes == [SizeRule.bump(A), A] }
    }

    // A bump that a later change of the burst carries stays: the later change gave none.
    @Test func theBumpOfAnEarlierChangeStays() async {
        let sender = sender()
        sender.queue(A, bump: SizeRule.bump(A))
        sender.queue(B, bump: nil)
        await clock.waitForSleepers(1)
        clock.advance(by: SizeRule.resizeDebounce)
        await waitUntil { sent.sizes == [SizeRule.bump(A)] }
    }

    @Test func aWindowWithNoAttachSendsNothing() async {
        let sender = sender()
        sent.attached = false
        sender.queue(A, bump: SizeRule.bump(A))
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await sender.task?.value
        #expect(sent.sizes.isEmpty)

        // The attach goes away during the gap: the fit does not go.
        sent.attached = true
        sender.queue(A, bump: SizeRule.bump(A))
        await clock.waitForSleepers(1)
        clock.advance(by: SizeRule.resizeDebounce)
        await waitUntil { sent.sizes == [SizeRule.bump(A)] }
        sent.attached = false
        await clock.waitForSleepers(1)
        clock.advance(by: SizeRule.bumpGap)
        await sender.task?.value
        #expect(sent.sizes == [SizeRule.bump(A)])
    }

    @Test func aStopSendsNothing() async {
        let sender = sender()
        sender.queue(A, bump: nil)
        await clock.waitForSleepers(1)
        let queued = sender.task
        sender.stop()
        clock.advance(by: .seconds(1))
        await queued?.value
        #expect(sent.sizes.isEmpty)

        // A stop during the gap drops the fit.
        sender.queue(A, bump: SizeRule.bump(A))
        await clock.waitForSleepers(1)
        clock.advance(by: SizeRule.resizeDebounce)
        await waitUntil { sent.sizes == [SizeRule.bump(A)] }
        await clock.waitForSleepers(1)
        let gap = sender.task
        sender.stop()
        clock.advance(by: .seconds(1))
        await gap?.value
        #expect(sent.sizes == [SizeRule.bump(A)])
    }
}
