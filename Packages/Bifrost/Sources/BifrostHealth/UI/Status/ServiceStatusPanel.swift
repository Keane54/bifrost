// The Service status panel (docs/behaviour/health.md, "Service status"): one row for each service
// with its level, the time since its incident, its name and the button that opens its status page,
// then a line under the row for each open incident, then the time of the last check.
//
// The panel shows one form for all rows (ServiceForm), the fullest form that fits the width of
// the panel: ViewThatFits tries the three whole-list forms in order. A wider panel goes back to a
// fuller form, because each form is a new try. An incident line wraps, so it asks for no width.
//
// The level is a colour and a text. The colours are not yellow, red or grey (ServiceColours).
import AppKit
import BifrostLayout
import BifrostLook
import SwiftUI

// The form of the rows. full: the button has its icon and its text. iconButton: the button has its
// icon only, and its text is its tooltip and its label. squareOnly: also no level text, and the
// square has the level as its tooltip and its label.
package enum ServiceForm: Int, Sendable, CaseIterable {
    case full, iconButton, squareOnly
}

// The colour of the square and of the text of each level. "No data" has no colour.
package enum ServiceColours {
    package static func colour(of level: ServiceLevel) -> TokenColour? {
        switch level {
        case .none: .rgb(0x86, 0xc4, 0x8f)
        case .minor: .rgb(0x22, 0xb8, 0xc8)
        case .major: .rgb(0x5b, 0x9c, 0xf2)
        case .critical: .rgb(0xd4, 0x73, 0x0a)
        case .maintenance: .rgb(0xa5, 0xc8, 0xf5)
        case .unknown: nil
        }
    }
}

#if DEBUG
// The form that the panel shows now, for a test. Only a Debug build reports it.
private struct FormKey: PreferenceKey {
    static let defaultValue: ServiceForm? = nil
    static func reduce(value: inout ServiceForm?, nextValue: () -> ServiceForm?) {
        value = nextValue() ?? value
    }
}
#endif

extension View {
    // The list gives its form to the panel, for a test (ServiceStatusModel.shownForm). A Release
    // build reports nothing.
    fileprivate func reportsForm(_ form: ServiceForm) -> some View {
        #if DEBUG
        preference(key: FormKey.self, value: form)
        #else
        self
        #endif
    }

    // The panel keeps the form of the list that fits, for a test. A Release build keeps nothing.
    fileprivate func keepsShownForm(in model: ServiceStatusModel) -> some View {
        #if DEBUG
        onPreferenceChange(FormKey.self) { model.shownForm = $0 }
        #else
        self
        #endif
    }
}

package struct ServiceStatusPanel: View {
    package let model: ServiceStatusModel

    package init(model: ServiceStatusModel) {
        self.model = model
    }

    package var body: some View {
        let metrics = model.metrics
        Group {
            if model.isChecking {
                ViewThatFits(in: .horizontal) {
                    ServiceList(model: model, metrics: metrics, form: .full)
                    ServiceList(model: model, metrics: metrics, form: .iconButton)
                    ServiceList(model: model, metrics: metrics, form: .squareOnly)
                }
                .keepsShownForm(in: model)
            } else {
                Text(StatusText.testHome)
                    .font(Self.font(11, metrics))
                    .foregroundStyle(ThemeTokens.textDim.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(metrics.points(12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(ThemeTokens.text.color)
        .focusable(false)
        .focusEffectDisabled()
    }

    // The font of the UI at a size in layout units.
    static func font(_ size: Double, _ metrics: CanvasMetrics) -> Font {
        Font(Fonts.ui(metrics.points(size), weight: .regular) as CTFont)
    }
}

// The whole list in one form: the rows, then the time of the last check at the bottom.
private struct ServiceList: View {
    let model: ServiceStatusModel
    let metrics: CanvasMetrics
    let form: ServiceForm

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(12)) {
            ForEach(model.services, id: \.id) { service in
                ServiceBlock(model: model, service: service, metrics: metrics, form: form)
            }
            Spacer(minLength: 0)
            Text(StatusText.checked(model.checkedAt, zone: model.zone))
                .font(ServiceStatusPanel.font(11, metrics))
                .foregroundStyle(ThemeTokens.textDim.color)
        }
        .reportsForm(form)
    }
}

// One service: its row, its incident lines and, for a service with no answer, the line that says
// so.
private struct ServiceBlock: View {
    let model: ServiceStatusModel
    let service: ServiceStatus
    let metrics: CanvasMetrics
    let form: ServiceForm

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(4)) {
            ServiceRow(model: model, service: service, metrics: metrics, form: form)
            ForEach(Array(service.incidents.enumerated()), id: \.offset) { _, incident in
                line(StatusText.incident(incident, now: model.now), ThemeTokens.text)
            }
            if service.level == .unknown, service.checkedAt != nil {
                line(StatusText.noAnswer, ThemeTokens.textDim)
            }
        }
    }

    // A line under the row. It wraps at the width that the panel gives, and its own width is no
    // reason for a narrower form.
    private func line(_ text: String, _ colour: TokenColour) -> some View {
        Text(text)
            .font(ServiceStatusPanel.font(11, metrics))
            .foregroundStyle(colour.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.leading, metrics.points(16))
    }
}

// The row of a service: the level square, the level text, the since text, the name and the button.
private struct ServiceRow: View {
    let model: ServiceStatusModel
    let service: ServiceStatus
    let metrics: CanvasMetrics
    let form: ServiceForm

    var body: some View {
        let level = StatusText.level(service.level)
        let colour = ServiceColours.colour(of: service.level)
        HStack(spacing: metrics.points(8)) {
            if let colour {
                let square = Rectangle().fill(colour.color)
                    .frame(width: metrics.points(8), height: metrics.points(8))
                if form == .squareOnly {
                    // The square alone gives the level to a screen reader and in its tooltip.
                    square
                        .background(TipAnchor(text: level, side: .top))
                        .accessibilityElement()
                        .accessibilityLabel(level)
                } else {
                    square.accessibilityHidden(true)
                    Text(level).foregroundStyle(colour.color).fixedSize()
                }
                if let since = StatusText.since(
                    service.level, service.since, now: model.now, zone: model.zone)
                {
                    Text(since).foregroundStyle(ThemeTokens.textDim.color).fixedSize()
                }
            } else {
                // "No data" has no square, so it keeps its text in each form.
                Text(level).italic().fixedSize()
            }
            Text(service.id.name)
                .foregroundStyle(ThemeTokens.textStrong.color)
                .lineLimit(1)
                .fixedSize(horizontal: form != .squareOnly, vertical: false)
            Spacer(minLength: 0)
            PageButton(model: model, id: service.id, metrics: metrics, form: form)
        }
        .font(ServiceStatusPanel.font(12, metrics))
    }
}

// The button that opens the status page of a service. Only the full form has its text. The other
// forms have it as the tooltip and as the label.
private struct PageButton: View {
    let model: ServiceStatusModel
    let id: ServiceID
    let metrics: CanvasMetrics
    let form: ServiceForm
    @State private var hovered = false

    var body: some View {
        let label = StatusText.openPageOf(id)
        Button {
            model.openPage(id)
        } label: {
            HStack(spacing: metrics.points(4)) {
                ButtonIcon(icon: .externalLink, size: metrics.points(11))
                    .accessibilityHidden(true)
                if form == .full {
                    Text(StatusText.openPage).fixedSize()
                }
            }
            .padding(.horizontal, metrics.points(4))
            .font(ServiceStatusPanel.font(11, metrics))
            .foregroundStyle((hovered ? ThemeTokens.text : ThemeTokens.textDim).color)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressTintStyle())
        .onHover { hovered = $0 }
        .background {
            if form != .full { TipAnchor(text: label, side: .top) }
        }
        .accessibilityLabel(label)
    }
}
