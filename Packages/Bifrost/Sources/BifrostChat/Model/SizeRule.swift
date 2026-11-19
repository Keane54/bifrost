// The size rule of the chat windows (docs/behaviour/chat.md, "The size"). Only the focused window
// sends a resize. The other windows follow the session size or zoom. A size in points (the panel of
// a terminal, or the grid of a terminal on the screen) is a CGSize.
import BifrostSessions
import CoreGraphics

// The facts for one size decision. The times are instants of a monotonic clock.
package struct SizeInput: Sendable, Equatable {
    package var focused, focusGained: Bool
    // The size that fits the panel, and the size of the session. nil: not known.
    package var fit, session: TerminalSize?
    // The size that the terminal has now.
    package var term: TerminalSize
    package var lastSent: TerminalSize?
    package var lastSentAt: ContinuousClock.Instant?
    package var now: ContinuousClock.Instant

    package init(
        focused: Bool, focusGained: Bool, fit: TerminalSize?, session: TerminalSize?,
        term: TerminalSize, lastSent: TerminalSize?, lastSentAt: ContinuousClock.Instant?,
        now: ContinuousClock.Instant
    ) {
        self.focused = focused
        self.focusGained = focusGained
        self.fit = fit
        self.session = session
        self.term = term
        self.lastSent = lastSent
        self.lastSentAt = lastSentAt
        self.now = now
    }
}

// The result of one size decision: the size of the terminal, and the size to send, or nil.
package struct SizeDecision: Sendable, Equatable {
    package var term: TerminalSize
    package var send: TerminalSize?
    // Set only on a focus gain when the PTY has the fit already and the session has another
    // size. A resize to the same size gives no SIGWINCH. So the window sends this size first,
    // then the size of send.
    package var bump: TerminalSize?

    package init(term: TerminalSize, send: TerminalSize?, bump: TerminalSize? = nil) {
        self.term = term
        self.send = send
        self.bump = bump
    }
}

package enum SizeRule {
    // The size of a new terminal when the fit and the session size are not known.
    package static let defaultTerm = TerminalSize(cols: 120, rows: 32)
    // Each resize gives a full redraw of the session. So only the last size of a burst goes to
    // the PTY, after this quiet time.
    package static let resizeDebounce = Duration.milliseconds(150)
    // The time between the bump and the fit, so the session gets two separate SIGWINCH.
    package static let bumpGap = Duration.milliseconds(60)
    // After a send, a different session size is an old read for this time.
    package static let sessionEcho = Duration.milliseconds(500)
    // The smallest zoom of a window that is not focused.
    package static let minScale = 0.1

    package static func decide(_ input: SizeInput) -> SizeDecision {
        let recent = input.lastSentAt.map { $0.duration(to: input.now) <= sessionEcho } ?? false
        let oldRead =
            input.session != nil && recent && input.lastSent != nil
            && input.session != input.lastSent
        // An old read is not the session size. The session gets the sent size soon.
        let known = oldRead ? nil : input.session
        if input.focused, let fit = input.fit {
            if input.focusGained { return takeBack(fit, session: known, lastSent: input.lastSent) }
            if fit != input.lastSent { return SizeDecision(term: fit, send: fit) }
        }
        return SizeDecision(term: known ?? input.term, send: nil)
    }

    // A size that differs from the fit by one row. It is never smaller than 1 x 1.
    package static func bump(_ fit: TerminalSize) -> TerminalSize {
        if fit.rows > 1 { return TerminalSize(cols: fit.cols, rows: fit.rows - 1) }
        return TerminalSize(cols: fit.cols > 1 ? fit.cols - 1 : fit.cols + 1, rows: fit.rows)
    }

    // The zoom of a window that is not focused. It is always a finite number from minScale to 1.
    // A value that makes no sense gives 1. A panel of size 0 gives minScale.
    package static func fitScale(screen: CGSize, panel: CGSize?) -> Double {
        guard let panel, usable(screen.width), usable(screen.height) else { return 1 }
        guard panel.width.isFinite, panel.height.isFinite else { return 1 }
        guard panel.width >= 0, panel.height >= 0 else { return 1 }
        return max(minScale, min(1, panel.width / screen.width, panel.height / screen.height))
    }

    // The size of a new terminal. A window that is not focused takes the session size.
    package static func openSize(focused: Bool, fit: TerminalSize?, session: TerminalSize?)
        -> TerminalSize
    {
        if !focused, let session { return session }
        return fit ?? session ?? defaultTerm
    }

    // A focus gain takes the size back from another client. Each resize gives a full redraw of
    // the session. So the window sends only when the session size is not the fit, or is not
    // known.
    private static func takeBack(
        _ fit: TerminalSize, session: TerminalSize?, lastSent: TerminalSize?
    ) -> SizeDecision {
        if session == fit { return SizeDecision(term: fit, send: nil) }
        // The PTY has the fit already, so a resize to the fit gives no SIGWINCH. The bump gives
        // one.
        if session != nil && lastSent == fit {
            return SizeDecision(term: fit, send: fit, bump: bump(fit))
        }
        return SizeDecision(term: fit, send: fit)
    }

    private static func usable(_ n: CGFloat) -> Bool { n.isFinite && n > 0 }
}
