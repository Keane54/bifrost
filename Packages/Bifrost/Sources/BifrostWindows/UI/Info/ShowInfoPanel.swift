// The Show Info panel (docs/behaviour/panels.md, "Show Info"): the known values of one session in
// seven sections, with the PR of its branch from gh. SwiftUI in one NSHostingView
// (ShowInfoPanels). The model gives each text, so the view only lays them out.
//
// The sizes are in layout units at the interface scale: a padding of 12, 12 between the
// sections, a title and a label of 11 in the dim text colour, a value of 12, a label column of
// 120 with 12 after it, and 2 between the rows. A panel with no row shows its text at 13. The
// error line is at the end of the content, and at the bottom of the panel when the content is
// shorter than the panel.
//
// The controls (Copy session ID, the PR and the close button of the error line) are never
// focusable: a SwiftUI control that moves with a frame never takes the focus. For the same
// reason the values cannot be selected (row P3 of docs/ports/panels/DELIBERATE-DIFFERENCES.md).
import AppKit
import BifrostFoundation
import BifrostLook
import BifrostSessions
import Observation
import SwiftUI

// The model of one Show Info panel: the row of its session from the session list, the PR line,
// the time of the panel and the error line.
//
// While the body exists, the model follows the folder and the branch of the row with
// Observations, and a new folder or branch asks the PR lookup again. The PR is nil until the
// lookup answers, so the PR line shows "Loading...". The time of the panel is the wall time when
// the body starts, then a tick each second on the injected clock gives a new time, so the
// duration moves.
@MainActor
@Observable
package final class ShowInfoPanelModel {
    // What the panel shows.
    package enum Content: Equatable {
        // The session list has not come yet.
        case waiting
        // The list has no row of the session.
        case gone
        case info([InfoSection], liveHint: Bool)

        // The text of a panel with no row, else nil.
        package var text: String? {
            switch self {
            case .waiting: ShowInfo.waiting
            case .gone: ActionReasons.gone
            case .info: nil
            }
        }
    }

    // The time between two ticks.
    nonisolated package static let tick = Duration.seconds(1)

    package let session: SessionID
    // The PR of the branch of the row, or nil while the lookup runs.
    package private(set) var pr: PRInfo?
    // The time of the panel, in milliseconds since 1970.
    package private(set) var now: Int
    // The reason of the last failure of a button of the panel, until the user closes it.
    package private(set) var error: String?

    // The values of the row that the PR depends on, and whether the lookup exists.
    private struct Source: Equatable, Sendable {
        var folder: String
        var branch: String?
        var lookup: Bool
    }

    @ObservationIgnored private let list: SessionListModel
    @ObservationIgnored private let lookup: () -> PRLookup?
    @ObservationIgnored private let actions: AppActions
    @ObservationIgnored private let look: PanelLook
    @ObservationIgnored private let wallNow: () -> Date
    @ObservationIgnored private let zone: TimeZone
    @ObservationIgnored private let timer: TimerSlot
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var asking: Task<Void, Never>?
    @ObservationIgnored private var asked: Source?

    init(
        session: SessionID, list: SessionListModel, lookup: @escaping () -> PRLookup?,
        actions: AppActions, look: PanelLook, clock: any Clock<Duration>,
        now: @escaping () -> Date, zone: TimeZone
    ) {
        self.session = session
        self.list = list
        self.lookup = lookup
        self.actions = actions
        self.look = look
        wallNow = now
        self.zone = zone
        timer = TimerSlot(clock: clock)
        self.now = now().millisecondsSince1970
    }

    isolated deinit {
        following?.cancel()
        asking?.cancel()
    }

    // The first row of the session in the session list, the one place of the rows.
    package var row: SessionRow? { list.rows.first { $0.sessionId == session.text } }

    package var content: Content {
        guard let row else { return list.loaded ? .gone : .waiting }
        return .info(
            ShowInfo.sections(row, now: now, pr: pr, zone: zone),
            liveHint: ShowInfo.showsLiveHint(row))
    }

    package var metrics: CanvasMetrics { look.metrics }

    // Copy the ID that resumes the session. A refusal shows in the error line.
    package func copySessionId() {
        do throws(ActionRefusal) {
            try actions.copySessionId(session.text)
        } catch {
            self.error = error.message
        }
    }

    // Open the PR in the browser. A failure shows in the error line.
    package func openPR() async {
        guard let lookup = lookup() else { return }
        do throws(ActionRefusal) {
            try await actions.openPR(session.text, with: lookup)
        } catch {
            self.error = error.message
        }
    }

    package func closeError() {
        error = nil
    }

    // Take the time of now and tick, and follow the row.
    func start() {
        advance()
        follow()
    }

    // The body is in no frame now: stop the tick, the follow and the lookup of the panel.
    func stop() {
        timer.stop()
        following?.cancel()
        following = nil
        asking?.cancel()
        asking = nil
    }

    private func advance() {
        now = wallNow().millisecondsSince1970
        timer.start(after: Self.tick) { [weak self] in self?.advance() }
    }

    private var source: Source? {
        guard let row else { return nil }
        return Source(folder: row.cwd, branch: row.branch, lookup: lookup() != nil)
    }

    private func follow() {
        guard following == nil else { return }
        let changes = Observations { [weak self] in self?.source }
        following = Task { [weak self] in
            for await source in changes { self?.ask(source) }
        }
    }

    // A row with a new folder or branch asks the lookup again. A row that goes away asks
    // nothing, and the PR line keeps its text until the row comes back.
    private func ask(_ source: Source?) {
        guard source != asked else { return }
        asked = source
        guard source != nil, let row, let lookup = lookup() else { return }
        asking?.cancel()
        pr = nil
        asking = Task { [weak self] in
            let value = await lookup.pr(row)
            guard !Task.isCancelled else { return }
            self?.pr = value
        }
    }
}

package struct ShowInfoPanel: View {
    package let model: ShowInfoPanelModel

    package init(model: ShowInfoPanelModel) {
        self.model = model
    }

    package var body: some View {
        let metrics = model.metrics
        let content = model.content
        VStack(alignment: .leading, spacing: 0) {
            if case .info(let sections, let hint) = content {
                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: metrics.points(12)) {
                                ForEach(sections, id: \.title) { section in
                                    InfoSectionView(
                                        section: section, model: model, metrics: metrics)
                                }
                                if hint {
                                    Text(ShowInfo.liveHint)
                                        .font(Self.font(11, metrics))
                                        .foregroundStyle(ThemeTokens.textDim.color)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(metrics.points(12))
                            Spacer(minLength: 0)
                            if let error = model.error {
                                ErrorLineView(text: error, metrics: metrics) {
                                    model.closeError()
                                }
                            }
                        }
                        .frame(
                            maxWidth: .infinity, minHeight: viewport.size.height,
                            alignment: .topLeading)
                    }
                }
            } else {
                Text(content.text ?? "")
                    .font(Self.font(13, metrics))
                    .foregroundStyle(ThemeTokens.textDim.color)
                    .padding(metrics.points(12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .font(Self.font(12, metrics))
        .foregroundStyle(ThemeTokens.text.color)
        .focusable(false)
        .focusEffectDisabled()
    }

    // The font of the UI at a size in layout units.
    static func font(_ size: Double, _ metrics: CanvasMetrics) -> Font {
        Font(Fonts.ui(metrics.points(size), weight: .regular) as CTFont)
    }
}

// One section: the title, then a grid of the labels and the values, each label at the top of its
// value. A mono value (an ID or a path) uses the system monospaced font, SF Mono, and each other
// text uses the UI font.
private struct InfoSectionView: View {
    let section: InfoSection
    let model: ShowInfoPanelModel
    let metrics: CanvasMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(4)) {
            Text(section.title)
                .font(ShowInfoPanel.font(11, metrics))
                .foregroundStyle(ThemeTokens.textDim.color)
                .accessibilityAddTraits(.isHeader)
            Grid(
                alignment: .topLeading, horizontalSpacing: metrics.points(12),
                verticalSpacing: metrics.points(2)
            ) {
                ForEach(section.items, id: \.label) { item in
                    GridRow(alignment: .top) {
                        Text(item.label)
                            .font(ShowInfoPanel.font(11, metrics))
                            .foregroundStyle(ThemeTokens.textDim.color)
                            .frame(width: metrics.points(120), alignment: .leading)
                        InfoValueView(item: item, model: model, metrics: metrics)
                    }
                }
            }
        }
    }
}

// A value with its control: a PR is a link that opens it in the browser, and the session ID has
// the Copy session ID button after it.
private struct InfoValueView: View {
    let item: InfoItem
    let model: ShowInfoPanelModel
    let metrics: CanvasMetrics

    var body: some View {
        switch item.control {
        case .prLink:
            PRLinkView(text: item.value) { Task { await model.openPR() } }
        case .copySessionId:
            HStack(alignment: .center, spacing: metrics.points(4)) {
                valueText
                SmallIconButton(
                    icon: .copy, iconSize: 13, label: "Copy session ID", metrics: metrics
                ) { model.copySessionId() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .none:
            valueText.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var valueText: some View {
        Text(item.value)
            .font(item.mono ? Self.mono(metrics) : ShowInfoPanel.font(12, metrics))
            .fixedSize(horizontal: false, vertical: true)
    }

    // The system monospaced font, SF Mono, at 12 layout units.
    static func mono(_ metrics: CanvasMetrics) -> Font {
        Font(NSFont.monospacedSystemFont(ofSize: metrics.points(12), weight: .regular) as CTFont)
    }
}

// The PR: the strong text colour, underlined, at 80 % opacity under the pointer. The opacity
// changes in 0.15 s on the ease curve (0.4, 0, 0.2, 1).
private struct PRLinkView: View {
    let text: String
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            Text(text)
                .underline()
                .foregroundStyle(ThemeTokens.textStrong.color)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovered ? 0.8 : 1)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15), value: hovered)
        .onHover { hovered = $0 }
        .pointerStyle(.link)
        .focusable(false)
    }
}

// A button of 16 units with an icon in the dim text colour, the hover colour and the text colour
// under the pointer, and the cyan tint during a press. Its Bifrost tooltip is its label.
private struct SmallIconButton: View {
    let icon: IconName
    let iconSize: Double
    let label: String
    let metrics: CanvasMetrics
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ButtonIcon(icon: icon, size: metrics.points(iconSize))
                .frame(width: metrics.points(16), height: metrics.points(16))
                .foregroundStyle(hovered ? ThemeTokens.text.color : ThemeTokens.textDim.color)
                .background(hovered ? ThemeTokens.hover.color : .clear)
        }
        .buttonStyle(PressTintStyle())
        .focusable(false)
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
        .background(TipAnchor(text: label, side: .top))
    }
}
