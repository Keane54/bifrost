import BifrostChat
import BifrostSessions
import CoreGraphics
import Testing

// The size rule of a chat window (docs/behaviour/chat.md, "The size"). A decision with no bump
// has bump nil.

private let A = TerminalSize(cols: 100, rows: 30)
private let B = TerminalSize(cols: 80, rows: 24)
private let C = TerminalSize(cols: 90, rows: 20)

private func input(
    focused: Bool = false, focusGained: Bool = false, fit: TerminalSize? = A,
    session: TerminalSize? = nil, term: TerminalSize = B, lastSent: TerminalSize? = nil,
    lastSentAt: Int? = nil, now: Int = 10_000
) -> SizeInput {
    SizeInput(
        focused: focused, focusGained: focusGained, fit: fit, session: session, term: term,
        lastSent: lastSent, lastSentAt: lastSentAt.map(at), now: at(now))
}

private func decision(term: TerminalSize, send: TerminalSize?, bump: TerminalSize? = nil)
    -> SizeDecision
{
    SizeDecision(term: term, send: send, bump: bump)
}

private func px(h: Double, w: Double) -> CGSize { CGSize(width: w, height: h) }

// An instant at a time in milliseconds after a fixed start.
private let origin = ContinuousClock.now
private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
    origin.advanced(by: .milliseconds(milliseconds))
}

@Suite("deciding the size")
struct DecideSizeTests {
    @Test("an unfocused window sends no resize")
    func anUnfocusedWindow() {
        let cases = [
            input(), input(session: C), input(focusGained: true), input(fit: C, lastSent: A),
        ]
        for item in cases { #expect(SizeRule.decide(item).send == nil) }
    }

    @Test
    func theFitOnAFocusGain() {
        let d = SizeRule.decide(input(focused: true, focusGained: true, lastSent: B))
        #expect(d == decision(term: A, send: A))
    }

    @Test
    func theSessionHasTheFit() {
        let gain = { (lastSent: TerminalSize?, term: TerminalSize) in
            input(focused: true, focusGained: true, session: A, term: term, lastSent: lastSent)
        }
        #expect(SizeRule.decide(gain(A, A)) == decision(term: A, send: nil))
        #expect(SizeRule.decide(gain(B, B)) == decision(term: A, send: nil))
        #expect(SizeRule.decide(gain(nil, B)) == decision(term: A, send: nil))
    }

    @Test("gaining focus sends the fit once when session and PTY sizes differ")
    func otherSizes() {
        let gain = { (lastSent: TerminalSize?) in
            input(focused: true, focusGained: true, session: C, lastSent: lastSent)
        }
        #expect(SizeRule.decide(gain(B)) == decision(term: A, send: A))
        #expect(SizeRule.decide(gain(nil)) == decision(term: A, send: A))
    }

    @Test("gaining focus sends a bump first when only the session size differs")
    func aBumpFirst() {
        let d = SizeRule.decide(input(focused: true, focusGained: true, session: B, lastSent: A))
        #expect(d == decision(term: A, send: A, bump: TerminalSize(cols: 100, rows: 29)))
    }

    @Test("gaining focus without a session size sends the fit once")
    func noSessionSize() {
        let gain = { (lastSent: TerminalSize?, term: TerminalSize) in
            input(focused: true, focusGained: true, session: nil, term: term, lastSent: lastSent)
        }
        #expect(SizeRule.decide(gain(A, A)) == decision(term: A, send: A))
        #expect(SizeRule.decide(gain(B, B)) == decision(term: A, send: A))
        #expect(SizeRule.decide(gain(nil, B)) == decision(term: A, send: A))
    }

    @Test
    func anOldReadOnAFocusGain() {
        let gain = { (now: Int) in
            input(
                focused: true, focusGained: true, session: C, lastSent: A, lastSentAt: 9_600,
                now: now)
        }
        #expect(SizeRule.decide(gain(10_000)) == decision(term: A, send: A))
        #expect(
            SizeRule.decide(gain(10_101))
                == decision(term: A, send: A, bump: TerminalSize(cols: 100, rows: 29)))
    }

    @Test
    func noBumpWithoutAFocusGain() {
        #expect(SizeRule.decide(input(focused: true, lastSent: B)).bump == nil)
    }

    @Test("the bump differs from the fit and is at least 1 x 1")
    func theBump() {
        #expect(SizeRule.bump(TerminalSize(cols: 80, rows: 24)) == TerminalSize(cols: 80, rows: 23))
        #expect(SizeRule.bump(TerminalSize(cols: 80, rows: 1)) == TerminalSize(cols: 79, rows: 1))
        #expect(SizeRule.bump(TerminalSize(cols: 1, rows: 1)) == TerminalSize(cols: 2, rows: 1))
    }

    @Test("a focused window sends its fit when the fit changes")
    func aFitChange() {
        let d = SizeRule.decide(input(focused: true, lastSent: B))
        #expect(d == decision(term: A, send: A))
    }

    @Test("a focused window does not repeat the same fit")
    func theSameFit() {
        let d = SizeRule.decide(input(focused: true, term: A, lastSent: A))
        #expect(d.send == nil)
    }

    @Test("a size from another client sets the terminal size and sends nothing")
    func anotherClient() {
        #expect(SizeRule.decide(input(session: C)) == decision(term: C, send: nil))
        let focused = input(focused: true, session: C, term: A, lastSent: A)
        #expect(SizeRule.decide(focused) == decision(term: C, send: nil))
    }

    @Test("a different size within 500 ms of a send is an old read")
    func anOldRead() {
        let base = { (now: Int, session: TerminalSize, term: TerminalSize) in
            input(
                focused: true, session: session, term: term, lastSent: A, lastSentAt: 9_600,
                now: now)
        }
        #expect(SizeRule.decide(base(10_100, C, A)) == decision(term: A, send: nil))
        #expect(SizeRule.decide(base(10_101, C, A)) == decision(term: C, send: nil))
        // The same size as the send is not an old read.
        #expect(SizeRule.decide(base(10_000, A, B)) == decision(term: A, send: nil))
    }

    @Test
    func noSessionSizeKeepsTheSize() {
        #expect(SizeRule.decide(input(fit: nil)) == decision(term: B, send: nil))
        #expect(SizeRule.decide(input(focused: true, fit: nil)) == decision(term: B, send: nil))
    }
}

@Suite("fit scale")
struct FitScaleTests {
    // screen, panel (nil: no panel), the zoom.
    @Test(
        "the zoom is the smaller ratio of the panel to the screen, never above 1",
        arguments: [
            (px(h: 500, w: 1000), px(h: 500, w: 500), 0.5),
            (px(h: 500, w: 1000), px(h: 100, w: 1000), 0.2),
            (px(h: 300, w: 400), px(h: 600, w: 800), 1),
            (px(h: 300, w: 400), nil, 1),
            (px(h: 0, w: 400), px(h: 600, w: 800), 1),
            (px(h: 500, w: .nan), px(h: 600, w: 800), 1),
            (px(h: 500, w: .infinity), px(h: 500, w: 500), 1),
            (px(h: 500, w: -1), px(h: 500, w: 500), 1),
        ] as [(CGSize, CGSize?, Double)])
    func theZoom(screen: CGSize, panel: CGSize?, expected: Double) {
        #expect(SizeRule.fitScale(screen: screen, panel: panel) == expected)
    }

    // The zoom of a panel that makes no sense: from 0.1 to 1, and a number that is not usable
    // gives 1. A panel of size 0 gives 0.1.
    @Test(
        "the zoom is always a finite number from 0.1 to 1",
        arguments: [
            (px(h: 0, w: 0), 0.1), (px(h: 500, w: 0), 0.1), (px(h: 1, w: 1), 0.1),
            (px(h: 500, w: -5), 1), (px(h: .nan, w: 500), 1), (px(h: 500, w: .infinity), 1),
        ] as [(CGSize, Double)])
    func aFiniteNumber(panel: CGSize, expected: Double) {
        let screen = px(h: 500, w: 1000)
        #expect(SizeRule.fitScale(screen: screen, panel: panel) == expected)
    }
}

@Suite("open size")
struct OpenSizeTests {
    @Test
    func theSessionSizeOnlyWhenUnfocused() {
        #expect(SizeRule.openSize(focused: false, fit: A, session: C) == C)
        #expect(SizeRule.openSize(focused: true, fit: A, session: C) == A)
        #expect(SizeRule.openSize(focused: true, fit: nil, session: C) == C)
        #expect(SizeRule.openSize(focused: false, fit: A, session: nil) == A)
        #expect(SizeRule.openSize(focused: false, fit: nil, session: nil) == SizeRule.defaultTerm)
    }
}

// The values of the size rules in docs/behaviour/chat.md.
@Suite("size rule values")
struct SizeRuleValueTests {
    @Test func theValuesAreTheValuesOfTheBehaviourList() {
        #expect(SizeRule.defaultTerm == TerminalSize(cols: 120, rows: 32))
        #expect(SizeRule.resizeDebounce == .milliseconds(150))
        #expect(SizeRule.bumpGap == .milliseconds(60))
    }
}
