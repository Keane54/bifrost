// The trust panel (docs/behaviour/reviews.md, "Clones and trust"; PanelID.trust): a Bifrost panel
// with a chat terminal (TrustTerminal) that runs claude in the clone of one repository, so the
// real trust prompt of Claude Code shows to the user, who answers it. Bifrost never types into
// the terminal and never writes ~/.claude.json.
//
// - The Trust button of the Reviews panel opens the panel for its repository. A new repository
//   closes the terminal of the old one first.
// - The terminal reads the trust when its output settles, when its claude ends and at each change
//   of ~/.claude.json. A trusted clone closes the terminal and the panel, ends its claude and
//   tells Reviews, which starts the work that waited.
// - A claude that ends before the trust leaves its last screen and offers Try again.
// - A close of the panel closes the terminal: its claude gets SIGHUP. Then the trust is read one
//   last time, so a trust that the user gave just before the close starts the waiting work. With
//   no trust that the read sees, the trust step still ended: Reviews gives the repository one
//   start, which claude judges (a trust that the read cannot see, for example).
// - A stop of Reviews (Watch GitHub off) closes the terminal and the panel.
import AppKit
import BifrostChat
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostReviews
import BifrostSessions
import Observation
import SwiftUI

@MainActor
@Observable
package final class TrustPanels: PanelBodiesPart {
    nonisolated package static let introText =
        "Claude Code asks if you trust this folder. Accept it below. Bifrost then closes this "
        + "window and starts any review that's waiting."
    nonisolated package static let pickText =
        "Pick a repository with the Trust button in the Reviews panel."
    nonisolated package static let endedText = "Claude Code closed before the folder was trusted."
    nonisolated package static let tryAgainText = "Try again"

    nonisolated package static func openFailedText(_ repo: RepoName) -> String {
        "Bifrost couldn't open Claude Code in its copy of \(repo)."
    }

    // The repository of the panel, or nil before the first Trust click and after the end.
    package private(set) var repo: RepoName?
    // The terminal of the repository while it shows.
    package private(set) var terminal: TrustTerminal?
    // Why the terminal did not open, or nil.
    package private(set) var problem: String?

    @ObservationIgnored package let links: ReviewsPanelLinks
    @ObservationIgnored private let look: PanelLook
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var host: TrustBody?
    // The open of the terminal. A test waits for it.
    @ObservationIgnored package private(set) var opening: Task<Void, Never>?
    // The last trust read of a panel close. A test waits for it.
    @ObservationIgnored package private(set) var lastRead: Task<Void, Never>?
    // The header changed its height: the body lays out again.
    @ObservationIgnored fileprivate var headerChanged: @MainActor () -> Void = {}

    // clock runs the settle time of the trust read.
    package init(links: ReviewsPanelLinks, look: PanelLook, clock: any Clock<Duration>) {
        self.links = links
        self.look = look
        self.clock = clock
    }

    var metrics: CanvasMetrics { look.metrics }

    var style: PanelStyle {
        PanelStyle(metrics: look.metrics, transparency: look.panelTransparency)
    }

    // The Trust button of the repository: show the panel and open its terminal.
    package func open(_ repo: RepoName) {
        closeTerminal()
        self.repo = repo
        problem = nil
        links.openPanel(.trust)
        opening = Task { [weak self] in await self?.start(repo) }
    }

    // Try again after claude ended or the open failed.
    package func tryAgain() {
        guard let repo else { return }
        open(repo)
    }

    // Reviews stopped: the terminal closes (its claude gets SIGHUP), and the panel closes.
    package func reviewsStopped() {
        closeTerminal()
        repo = nil
        problem = nil
        if host != nil { links.closePanel(.trust) }
    }

    // MARK: - PanelBodiesPart

    package func body(for panel: PanelID) -> NSView? {
        guard panel == .trust else { return nil }
        if let host { return host }
        let host = TrustBody(header: NSHostingView(rootView: TrustHeader(panels: self)))
        host.show(terminal?.view)
        headerChanged = { [weak host] in host?.needsLayout = true }
        self.host = host
        return host
    }

    // The panel closed: its terminal closes, and claude gets SIGHUP. Then the trust of its
    // repository is read one last time.
    package func releaseBody(for panel: PanelID) {
        guard panel == .trust else { return }
        let closed = repo
        closeTerminal()
        repo = nil
        problem = nil
        host = nil
        guard let closed else { return }
        let links = links
        lastRead = Task {
            if await links.isTrusted(closed) {
                links.trusted(closed)
            } else {
                links.trustStepEnded(closed)
            }
        }
    }

    // MARK: - The terminal

    private func start(_ repo: RepoName) async {
        let run = await links.openTrustRun(repo)
        guard self.repo == repo, !Task.isCancelled else {
            run?.close()
            return
        }
        guard let run else {
            problem = Self.openFailedText(repo)
            return
        }
        let links = links
        let terminal = TrustTerminal(
            run: run, check: { await links.isTrusted(repo) }, triggers: links.trustChanges(),
            onTrusted: { [weak self] in self?.finished(repo) }, font: links.terminalFont(),
            clock: clock)
        self.terminal = terminal
        host?.show(terminal.view)
    }

    // The trust step of the repository ended: Reviews starts the work that waited, and the
    // panel closes.
    private func finished(_ repo: RepoName) {
        terminal = nil
        self.repo = nil
        host?.show(nil)
        links.trusted(repo)
        links.closePanel(.trust)
    }

    private func closeTerminal() {
        opening?.cancel()
        opening = nil
        terminal?.close()
        terminal = nil
        host?.show(nil)
    }
}

// The body of the trust panel: the header line on top, and the terminal under it.
final class TrustBody: NSView {
    private let header: NSView
    private var terminalView: NSView?

    init(header: NSView) {
        self.header = header
        super.init(frame: .zero)
        addSubview(header)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // Show the terminal view, or none. A new terminal takes the keyboard focus.
    func show(_ view: NSView?) {
        guard view !== terminalView else { return }
        terminalView?.removeFromSuperview()
        terminalView = view
        if let view {
            addSubview(view)
            window?.makeFirstResponder(view)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = header.fittingSize.height
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        terminalView?.frame = CGRect(
            x: 8, y: height, width: max(bounds.width - 16, 0),
            height: max(bounds.height - height - 8, 0))
    }
}

// The line over the terminal: what to do, why the terminal is not there, or Try again.
private struct TrustHeader: View {
    let panels: TrustPanels

    var body: some View {
        let style = panels.style
        let metrics = panels.metrics
        VStack(alignment: .leading, spacing: metrics.points(4)) {
            Text(text)
                .foregroundStyle(ThemeTokens.textDim.color)
                .fixedSize(horizontal: false, vertical: true)
            if offersTryAgain {
                Button(TrustPanels.tryAgainText) { panels.tryAgain() }
                    .buttonStyle(RowButtonStyle(tone: .plain, style: style))
                    .focusable(false)
            }
        }
        .font(style.font(11))
        .padding(.horizontal, metrics.points(12))
        .padding(.vertical, metrics.points(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
            panels.headerChanged()
        }
    }

    private var text: String {
        if let problem = panels.problem { return problem }
        if panels.repo == nil { return TrustPanels.pickText }
        if panels.terminal?.state == .ended { return TrustPanels.endedText }
        return TrustPanels.introText
    }

    private var offersTryAgain: Bool {
        panels.problem != nil || panels.terminal?.state == .ended
    }
}
