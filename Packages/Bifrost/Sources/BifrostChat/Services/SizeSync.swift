import BifrostFoundation
import BifrostSessions
import CoreGraphics

// The size of one chat window (docs/behaviour/chat.md, "The size"): the size of its terminal, the
// sends to its PTY, the zoom and the keyboard focus after a focus gain. The rules are in SizeRule.
// SizeSync keeps the facts of one window and gives effects. The chat terminal (ChatTerminal) runs
// them in order, at once. Each input gives the time now, an instant of a monotonic clock, and tells
// if the window has an attach: before the attach, the open sends the size. SizeSender sends a size
// to the PTY, after the quiet time of the last change.

package enum SizeEffect: Sendable, Equatable {
    // Give the terminal view this size.
    case resizeTerminal(TerminalSize)
    // Send a size to the PTY with a SizeSender (queue). A bump goes first. It gives the SIGWINCH
    // that the same size does not give.
    case send(TerminalSize, bump: TerminalSize?)
    // Zoom the terminal (1: no zoom). blocksPointer: a clear cover over the terminal takes the
    // pointer, because a zoomed terminal gives wrong mouse cells. The first click on such a
    // window only focuses it (D8).
    case scale(Double, blocksPointer: Bool)
    // Give the keyboard focus to the terminal after the pointer down of the frame ends, unless
    // a menu or a dialog has the keyboard focus.
    case focusTerminal
}

package struct SizeSync: Sendable {
    private var effects: [SizeEffect] = []
    private var view = ChatView.hidden
    // The panel that shows the terminal, the size that fits it, and the size of the grid of the
    // terminal on the screen. nil: not known.
    private var panel: CGSize?
    private var fit: TerminalSize?
    private var screen: CGSize?
    private var session: TerminalSize?
    // The size that the terminal view has. nil until the first size decision, so the first
    // decision always gives the view its size.
    private var term: TerminalSize?
    private var lastSent: TerminalSize?
    private var lastSentAt: ContinuousClock.Instant?
    // True from a focus gain until a size decision with a known fit.
    private var focusGained = false
    // True from a focus gain until the window asks for the keyboard focus.
    private var wantFocus = false
    // True after the one read of the session size before the first open.
    private var sessionReadDone = false
    // The zoom that the terminal shows now.
    private var shownScale = 1.0
    private var shownBlocker = false

    package init() {}

    // MARK: The inputs

    // The view of the window, and true when the window became focused (ChatViews.gainedFocus).
    package mutating func setView(
        _ view: ChatView, focusGained: Bool, attached: Bool, now: ContinuousClock.Instant
    ) {
        guard view != self.view || focusGained else { return }
        self.view = view
        if focusGained {
            self.focusGained = true
            wantFocus = true
        }
        if !view.focused {
            self.focusGained = false
            wantFocus = false
        }
        update(attached: attached, now: now)
        takeFocus()
    }

    // The panel that shows the terminal, or nil when no panel shows it. fit: the size that fits
    // the panel with the cells of the font. screen: the size of the grid of the terminal on the
    // screen, for the zoom. Call this again when one of them changes, also after a
    // resizeTerminal effect and after a change of the font.
    package mutating func setPanel(
        _ panel: CGSize?, fit: TerminalSize?, screen: CGSize?, attached: Bool,
        now: ContinuousClock.Instant
    ) {
        self.panel = panel
        self.fit = Self.valid(fit)
        self.screen = screen
        update(attached: attached, now: now)
        takeFocus()
    }

    // The size of the session (SessionSizeWatcher), or nil when it is not known.
    package mutating func setSessionSize(
        _ size: TerminalSize?, attached: Bool, now: ContinuousClock.Instant
    ) {
        session = Self.valid(size)
        update(attached: attached, now: now)
    }

    // The result of the one read of the session size before the first open. A failed read gives
    // nil. A session size that came during the read is newer.
    package mutating func sessionRead(_ size: TerminalSize?) {
        sessionReadDone = true
        if session == nil { session = Self.valid(size) }
    }

    // The effects since the last call, in order.
    package mutating func takeEffects() -> [SizeEffect] {
        defer { effects = [] }
        return effects
    }

    // MARK: The open

    // A visible window waits for the size of its panel, so its attach gets the right size.
    package var waitsForPanel: Bool { view.visible && panel == nil }

    // A window that is not focused opens with the session size, so it reads the size one time
    // first.
    package var needsSessionSize: Bool { !view.focused && session == nil && !sessionReadDone }

    // The size of a new attach.
    package var openSize: TerminalSize {
        SizeRule.openSize(focused: view.focused, fit: currentFit, session: session)
    }

    // The size of the terminal now. A reattach opens at it.
    package var terminal: TerminalSize { term ?? SizeRule.defaultTerm }

    // An open sets the size of the terminal and of the session. The attach sends the fit of a
    // focused window, so the focus gain needs no other send.
    package mutating func open(at size: TerminalSize, now: ContinuousClock.Instant) {
        if currentFit != nil { focusGained = false }
        resizeLocal(size)
        lastSent = size
        lastSentAt = now
    }

    // The attach opened. The panel can change during the open.
    package mutating func attached(now: ContinuousClock.Instant) {
        update(attached: true, now: now)
    }

    // The PTY got a size at this time. A different session size soon after it is an old read.
    package mutating func sent(now: ContinuousClock.Instant) {
        lastSentAt = now
    }

    // MARK: The rules

    // The size that fits the panel, or nil when no panel shows the terminal.
    private var currentFit: TerminalSize? {
        view.visible && panel != nil ? fit : nil
    }

    // Apply the size rule after a change of the view, the panel or the session size.
    private mutating func update(attached: Bool, now: ContinuousClock.Instant) {
        let fit = currentFit
        let decision = SizeRule.decide(
            SizeInput(
                focused: view.focused, focusGained: focusGained, fit: fit, session: session,
                term: terminal, lastSent: lastSent, lastSentAt: lastSentAt, now: now))
        // Only a known fit can go to the session. So a focus gain waits for a fit.
        if fit != nil { focusGained = false }
        resizeLocal(decision.term)
        // Before the attach, the open sends the size.
        if let send = decision.send, attached {
            lastSent = send
            lastSentAt = now
            effects.append(.send(send, bump: decision.bump))
        }
        applyScale()
    }

    private mutating func resizeLocal(_ size: TerminalSize) {
        guard size != term else { return }
        term = size
        effects.append(.resizeTerminal(size))
    }

    // Zoom the terminal to fit its panel. The zoom is never above 1 (D8).
    private mutating func applyScale() {
        let scale = screen.map { SizeRule.fitScale(screen: $0, panel: panel) } ?? 1
        let blocker = !view.focused && scale < 1
        guard scale != shownScale || blocker != shownBlocker else { return }
        shownScale = scale
        shownBlocker = blocker
        effects.append(.scale(scale, blocksPointer: blocker))
    }

    // Ask for the keyboard focus after a focus gain, when the window has its panel.
    private mutating func takeFocus() {
        guard wantFocus, view.focused, panel != nil else { return }
        wantFocus = false
        effects.append(.focusTerminal)
    }

    // A size that a PTY accepts (TerminalSize.isValid), or nil.
    private static func valid(_ size: TerminalSize?) -> TerminalSize? {
        guard let size, size.isValid else { return nil }
        return size
    }
}

// Sends the sizes of one window to its PTY. Each resize causes a full redraw. So only the last
// size of a burst goes to the PTY, after the quiet time of SizeRule.resizeDebounce. A bump goes
// first, then the fit after SizeRule.bumpGap, so the session gets two SIGWINCH. A failed resize
// does not end the attach. The next resize can work.
@MainActor
package final class SizeSender {
    private let clock: any Clock<Duration>
    private let debounce: Debouncer
    private let attached: () -> Bool
    private let send: (TerminalSize) -> Void
    private var next: TerminalSize?
    private var bump: TerminalSize?
    // A stop makes a new epoch, so a send that waits for the gap never goes.
    private var epoch = 0

    // attached: true while the window has an attach. send: the size goes to the PTY.
    package init(
        clock: any Clock<Duration>, attached: @escaping () -> Bool,
        send: @escaping (TerminalSize) -> Void
    ) {
        self.clock = clock
        debounce = Debouncer(clock: clock)
        self.attached = attached
        self.send = send
    }

    // A size to send. A new size moves the time of the send. The last bump stays.
    package func queue(_ size: TerminalSize, bump: TerminalSize?) {
        next = size
        self.bump = bump ?? self.bump
        debounce.schedule(after: SizeRule.resizeDebounce) { [weak self] in await self?.flush() }
    }

    // The task of the next send. A test waits for its end.
    package var task: Task<Void, Never>? { debounce.task }

    // True when the time of the next send came, and the send did not run yet (Debouncer.isDue).
    package var isDue: Bool { debounce.isDue }

    // The window ended or closed: nothing goes to the PTY.
    package func stop() {
        debounce.cancel()
        next = nil
        bump = nil
        epoch += 1
    }

    private func flush() async {
        let size = next
        let first = bump
        next = nil
        bump = nil
        guard let size, attached() else { return }
        guard let first else {
            send(size)
            return
        }
        send(first)
        // The epoch is the stop of a bump gap: stop() does not cancel this sleep, but it changes
        // the epoch, so the sleep ends with no send.
        let mine = epoch
        do {
            try await clock.sleep(for: SizeRule.bumpGap)
        } catch {
            return
        }
        guard mine == epoch, attached() else { return }
        send(size)
    }
}
