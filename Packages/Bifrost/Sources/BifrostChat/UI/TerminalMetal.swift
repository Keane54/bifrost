// The Metal renderer of the terminal view of a chat window. SwiftTerm starts Metal only in a
// window. A hidden terminal (a minimised frame, a back tab) stops its renderer: the PTY and the
// terminal model stay. When the window closes, the renderer and the drivers of the view go for
// good (updateUiClosed of SwiftTerm). When Metal does not start, Core Graphics stays.
//
// A renderer that is busy with committed GPU work refuses a release. The release then tries
// again, at most 40 times, 50 ms apart on the clock of the chats. The task of the next try keeps
// the view until the release is done, the terminal shows again or the tries end.
import AppKit
import SwiftTerm

@MainActor
final class TerminalMetal {
    static let retryGap = Duration.milliseconds(50)
    static let maxTries = 40

    private let view: ChatTerminalView
    private let renderer: TerminalRenderer
    private let clock: any Clock<Duration>
    // The terminal shows, so it draws with Metal when it can.
    private var visible = false
    private var closed = false
    // True after Metal failed to start.
    private var failed = false
    // The next try of a release.
    private var retry: Task<Void, Never>?

    init(view: ChatTerminalView, renderer: TerminalRenderer, clock: any Clock<Duration>) {
        self.view = view
        self.renderer = renderer
        self.clock = clock
    }

    // The terminal shows or hides. Call this after the view went into its host, and before it
    // leaves the host.
    func setVisible(_ visible: Bool) {
        guard !closed else { return }
        self.visible = visible
        if visible {
            retry?.cancel()
            start()
        } else {
            tryUntilDone { $0.releaseHidden() }
        }
    }

    // The view went into a window or left it.
    func windowChanged() {
        guard !closed, visible else { return }
        start()
    }

    // The window closed. Release the renderer and the drivers of the view for good.
    func close() {
        guard !closed else { return }
        closed = true
        tryUntilDone { $0.view.updateUiClosed() }
    }

    private func start() {
        guard renderer == .metal, !failed, view.window != nil, !view.isUsingMetalRenderer
        else { return }
        do {
            try view.setUseMetal(true)
            // The new Metal view moved the scroller of SwiftTerm.
            view.placeSlider()
        } catch {
            failed = true
        }
    }

    // One try of the release of a hidden terminal. True when the release is done, or when the
    // terminal needs it no more.
    private func releaseHidden() -> Bool {
        guard !closed, !visible, view.isUsingMetalRenderer else { return true }
        do {
            try view.setUseMetal(false)
            return true
        } catch {
            return false
        }
    }

    // Make a try now. Until a try is done, make it again, retryGap apart, at most maxTries times
    // in all. A new call stops the tries of the last call.
    private func tryUntilDone(
        tries: Int = maxTries, _ attempt: @escaping @MainActor (TerminalMetal) -> Bool
    ) {
        retry?.cancel()
        retry = nil
        guard !attempt(self), tries > 1 else { return }
        let clock = clock
        retry = Task {
            do {
                try await clock.sleep(for: Self.retryGap)
            } catch {
                return
            }
            tryUntilDone(tries: tries - 1, attempt)
        }
    }
}
