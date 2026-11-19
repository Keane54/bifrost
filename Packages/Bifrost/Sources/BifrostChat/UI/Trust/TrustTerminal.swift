// The trust terminal (docs/behaviour/reviews.md, "Clones and trust"): a terminal over a PTYRun,
// claude with no arguments in a review clone, so the real workspace trust prompt of Claude Code
// shows to the user, who answers it. The terminal knows no type of Reviews: the owner gives the
// trust read (check), the change events of ~/.claude.json (triggers) and the end (onTrusted).
//
// - Bifrost never types into the terminal. Only the keys, a paste and the replies of the terminal
//   view go to claude, and only while it runs.
// - The check follows the real state, never a timer: it runs when the output has settled (500 ms
//   after the last output, on the clock), when claude ends, and at each change event of the
//   file. A check that sees the trust ends the terminal: its claude gets SIGHUP, and the owner
//   gets onTrusted once.
// - The view has the look of a chat terminal. It is a chat key target, so the Bifrost keys of a
//   chat apply and a plain key goes to claude.
import AppKit
import BifrostFoundation
import BifrostKeyboard
import BifrostLook
import BifrostSessions
import Observation
import SwiftTerm

@MainActor
@Observable
package final class TrustTerminal {
    // The quiet time after the last output before a check.
    nonisolated package static let settle = Duration.milliseconds(500)

    package enum State: Sendable, Equatable {
        // claude runs.
        case running
        // claude ended before the clone was trusted. The terminal keeps its last screen.
        case ended
        // A check saw the trust, and the terminal closed.
        case trusted
        // The owner closed the terminal.
        case closed
    }

    package private(set) var state = State.running

    @ObservationIgnored package let view: TrustTerminalView
    @ObservationIgnored private let run: PTYRun
    @ObservationIgnored private let check: @MainActor () async -> Bool
    @ObservationIgnored private let onTrusted: @MainActor () -> Void
    @ObservationIgnored private let settled: Debouncer
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var following: Task<Void, Never>?

    // check reads the trust of the clone. triggers are the change events of ~/.claude.json.
    // onTrusted runs once, after the terminal closed.
    package init(
        run: PTYRun, check: @escaping @MainActor () async -> Bool, triggers: AsyncStream<Void>,
        onTrusted: @escaping @MainActor () -> Void,
        font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.run = run
        self.check = check
        self.onTrusted = onTrusted
        settled = Debouncer(clock: clock)
        view = TrustTerminalView(font: font)
        view.terminal = self
        reading = Task { [weak self] in
            for await chunk in run.output { self?.received(chunk) }
            let code = await run.exit
            self?.ended(code)
        }
        following = Task { [weak self] in
            for await _ in triggers {
                guard let self else { return }
                await checkTrust()
            }
        }
    }

    isolated deinit {
        reading?.cancel()
        following?.cancel()
    }

    // The owner closed the terminal (the panel closed). claude gets SIGHUP.
    package func close() {
        guard state == .running || state == .ended else { return }
        state = .closed
        stop()
    }

    // MARK: - The view

    // The keys, a paste and the replies of the terminal view, while claude runs.
    func userInput(_ bytes: [UInt8]) {
        guard state == .running else { return }
        _ = run.write(bytes)
    }

    // The view has a new grid: claude gets the size.
    func gridChanged(cols: Int, rows: Int) {
        guard state == .running else { return }
        let size = TerminalSize(cols: cols, rows: rows)
        if size.isValid { run.resize(size) }
    }

    // MARK: - The run

    private func received(_ chunk: [UInt8]) {
        guard state == .running else { return }
        view.feed(byteArray: chunk[...])
        settled.schedule(after: Self.settle) { [weak self] in await self?.checkTrust() }
    }

    // claude ended: the screen stays, and the trust is read once more. A close came first when
    // the code is nil.
    private func ended(_ code: Int32?) {
        guard state == .running else { return }
        state = .ended
        settled.cancel()
        Task { [weak self] in await self?.checkTrust() }
    }

    // Read the trust. A trust ends the terminal and tells the owner, once.
    private func checkTrust() async {
        guard state == .running || state == .ended else { return }
        guard await check(), state == .running || state == .ended else { return }
        state = .trusted
        stop()
        onTrusted()
    }

    private func stop() {
        settled.cancel()
        following?.cancel()
        following = nil
        run.close()
    }
}

// The terminal view of the trust terminal, in the look of a chat terminal. It is a chat key
// target with a session ID that no session has, so the window gives it the keys of a chat.
package final class TrustTerminalView: TerminalView, TerminalViewDelegate, ChatKeyTarget {
    weak var terminal: TrustTerminal?

    init(font: NSFont) {
        super.init(frame: .zero, font: font, options: ChatTerminalView.options)
        terminalDelegate = self
        nativeBackgroundColor = ThemeTokens.terminalBackground.nsColor
        nativeForegroundColor = ThemeTokens.text.nsColor
        optionAsMetaKey = false
        optionAsMetaKeyForFunctionalKeys = true
        allowMouseReporting = true
        bellStyle = .none
        // A Cmd key never goes to claude before the key filter of the window.
        shouldSendCommandKeyToTerminal = { _ in false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - ChatKeyTarget

    package var sessionId: String { "trust" }

    package var isComposing: Bool { hasMarkedText() }

    // A Cmd key with one printable character goes nowhere, as in a chat. Each other key goes to
    // the terminal.
    package func chatKey(_ event: KeyEvent, dictationKey: KeyCode?) -> Bool {
        ChatTerminal.isCommandText(event)
    }

    package func chatFocus(_ focused: Bool, dictationKey: KeyCode?) {}

    // MARK: - TerminalViewDelegate

    package func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        terminal?.gridChanged(cols: newCols, rows: newRows)
    }

    package func setTerminalTitle(source: TerminalView, title: String) {}

    package func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    package func send(source: TerminalView, data: ArraySlice<UInt8>) {
        terminal?.userInput(Array(data))
    }

    package func scrolled(source: TerminalView, position: Double) {}

    package func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // The trust prompt has no link that Bifrost opens.
    package func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {}

    package func bell(source: TerminalView) {}

    package func clipboardCopy(source: TerminalView, content: Data) {}

    package func clipboardRead(source: TerminalView) -> Data? { nil }
}
