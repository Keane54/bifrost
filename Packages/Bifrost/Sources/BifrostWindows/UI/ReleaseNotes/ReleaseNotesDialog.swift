// The release notes dialog (docs/behaviour/updates.md, "Release notes"). It opens by itself after
// an update as "What's new", with the releases since the last seen version, and Settings >
// Updates opens it as "Release notes", with the last 10 releases. The source reads GitHub only
// when the dialog opens. Each text shows as plain text with only bold and code. Esc, the Close
// button and a click on the backdrop close it. The page of a release opens in the default
// browser, and only the page of a release of the answer or the Releases page can open.
import AppKit
import BifrostLook
import Observation
import SwiftUI

// What the dialog shows: the releases since the last seen version, or all releases.
package enum ReleaseNotesView: Sendable, Equatable {
    case whatsNew(WhatsNewRange)
    case all
}

@MainActor
@Observable
package final class ReleaseNotesDialogModel {
    package enum Load: Equatable {
        case loading
        case failed
        case loaded([Release])
    }

    package let view: ReleaseNotesView
    package private(set) var load = Load.loading
    // The load that runs. A test waits for it.
    @ObservationIgnored package private(set) var loading: Task<Void, Never>?
    // The dialog host sets this when it shows the dialog. The close of the dialog calls it.
    @ObservationIgnored package var onClose: @MainActor (ReleaseNotesDialogModel) -> Void = { _ in }
    @ObservationIgnored private let source: ReleaseNotesSource
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void

    package init(
        view: ReleaseNotesView, source: ReleaseNotesSource,
        openURL: @escaping @MainActor (URL) -> Void
    ) {
        self.view = view
        self.source = source
        self.openURL = openURL
    }

    isolated deinit { loading?.cancel() }

    package var title: String {
        switch view {
        case .whatsNew: ReleaseNotesText.whatsNew
        case .all: ReleaseNotesText.title
        }
    }

    // The releases that the dialog shows, newest first. Empty while the list loads or when it
    // could not load.
    package var shown: [Release] {
        guard case .loaded(let releases) = load else { return [] }
        switch view {
        case .whatsNew(let range): return range.releases(in: releases)
        case .all: return Array(releases.prefix(ReleaseNotes.maxReleases))
        }
    }

    // True when the list loaded and has no release to show.
    package var isEmpty: Bool {
        if case .loaded = load { return shown.isEmpty }
        return false
    }

    // Load the list. The source keeps a good answer ten minutes, and two dialogs share one load.
    package func start() {
        guard loading == nil else { return }
        loading = Task {
            let releases = await source.list()
            guard !Task.isCancelled else { return }
            load = releases.map(Load.loaded) ?? .failed
        }
    }

    // Open the page of a release, or the Releases page for nil, in the browser.
    package func openPage(of version: ReleaseVersion?) {
        guard let page = source.page(of: version) else { return }
        openURL(page)
    }

    package func close() {
        loading?.cancel()
        onClose(self)
    }
}

struct ReleaseNotesDialogView: View {
    let model: ReleaseNotesDialogModel
    let style: PanelStyle
    // The height of the content, so the list shows with no scroll bar while it fits.
    @State private var contentHeight = CGFloat.zero

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(12)) {
            DialogTitle(text: model.title, style: style)
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                        contentHeight = $0
                    }
            }
            .frame(height: min(contentHeight, style.points(420)))
            HStack {
                Spacer(minLength: 0)
                Button(ReleaseNotesText.close) { model.close() }
                    .buttonStyle(DialogButtonStyle(style: style))
            }
        }
        .accessibilityLabel(model.title)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: style.points(12)) {
            switch model.load {
            case .loading:
                Text(ReleaseNotesText.loading).foregroundStyle(style.dim)
            case .failed:
                ReleasesPage(model: model, style: style, text: ReleaseNotesText.failed)
            case .loaded:
                if model.isEmpty {
                    ReleasesPage(model: model, style: style, text: ReleaseNotesText.empty)
                }
                ForEach(model.shown, id: \.version) { release in
                    ReleaseBlock(model: model, style: style, release: release)
                }
            }
        }
        .font(style.font(12))
    }
}

// A line of text and the button that opens the Releases page on GitHub.
private struct ReleasesPage: View {
    let model: ReleaseNotesDialogModel
    let style: PanelStyle
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(8)) {
            Text(text).textSelection(.enabled)
            PageButton(style: style, title: ReleaseNotesText.releasesPage) {
                model.openPage(of: nil)
            }
        }
    }
}

// One release: its version and date, the button of its page, the summary and the sections.
private struct ReleaseBlock: View {
    let model: ReleaseNotesDialogModel
    let style: PanelStyle
    let release: Release

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(8)) {
            HStack(alignment: .firstTextBaseline, spacing: style.points(8)) {
                Text(verbatim: "Version \(release.version)")
                    .font(style.font(12, weight: .semibold))
                    .foregroundStyle(ThemeTokens.textStrong.color)
                    .textSelection(.enabled)
                Text(ReleaseNotesText.date(release.date))
                    .font(style.font(11))
                    .foregroundStyle(style.dim)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                PageButton(style: style, title: ReleaseNotesText.viewOnGitHub) {
                    model.openPage(of: release.version)
                }
            }
            if !release.summary.isEmpty {
                Text(InlineText.attributed(release.summary))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(release.sections, id: \.title) { section in
                SectionBlock(style: style, section: section)
            }
            if release.isInternalOnly {
                Text(ReleaseNotesText.internal).foregroundStyle(style.dim)
            }
        }
        .padding(.top, style.points(12))
        .overlay(alignment: .top) { Rectangle().fill(style.edge).frame(height: style.points(1)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "Version \(release.version)"))
    }
}

private struct SectionBlock: View {
    let style: PanelStyle
    let section: ReleaseSection

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(4)) {
            Text(section.title)
                .font(style.font(11, weight: .semibold))
                .foregroundStyle(ThemeTokens.textStrong.color)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: style.points(6)) {
                    Text("•").foregroundStyle(style.dim).accessibilityHidden(true)
                    line(of: item)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // The scope in the dim colour, then the text.
    private func line(of item: ReleaseItem) -> Text {
        var text = InlineText.attributed(item.text)
        if let scope = item.scope {
            var head = AttributedString(scope + " ")
            head.font = style.font(11)
            head.foregroundColor = style.dim
            text = head + text
        }
        return Text(text)
    }
}

// The small button of a GitHub page: the icon of an outside link and a dim text.
private struct PageButton: View {
    let style: PanelStyle
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: style.points(4)) {
                ButtonIcon(icon: .externalLink, size: style.points(11))
                Text(title).fixedSize()
            }
            .padding(.horizontal, style.points(4))
            .font(style.font(11))
            .foregroundStyle((hovered ? ThemeTokens.text : ThemeTokens.textDim).color)
        }
        .buttonStyle(PressTintStyle())
        .onHover { hovered = $0 }
    }
}
