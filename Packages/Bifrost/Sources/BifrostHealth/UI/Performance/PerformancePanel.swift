// The Performance panel (docs/behaviour/health.md, "The panel"): the headline with the level of
// Bifrost's health, the Clear button while a reason comes from a past event, the Details row, and
// under it the five sections: Bifrost, Claude sessions, Your Mac, Network and Limits and disk. A
// test home measures no network, so it has no Network section.
import AppKit
import BifrostFoundation
import BifrostLook
import BifrostSessions
import SwiftUI

// The thermal state is a type of ProcessInfo, which the model layer does not use, so its text and
// its colour are here.
extension PerformanceText {
    package static func thermal(_ state: ProcessInfo.ThermalState?) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        default: none
        }
    }
}

extension PerformanceColours {
    // The colour of the thermal state, or nil for Fair and for no value.
    static func thermal(_ state: ProcessInfo.ThermalState?) -> TokenColour? {
        switch state {
        case .nominal: ThemeTokens.ctxLow
        case .serious: ThemeTokens.ctxMid
        case .critical: ThemeTokens.ctxHigh
        default: nil
        }
    }
}

package struct PerformancePanel: View {
    package let model: PerformancePanelModel

    package init(model: PerformancePanelModel) {
        self.model = model
    }

    package var body: some View {
        let style = model.style
        let snapshot = model.snapshot
        let open = model.detailsOpen
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Headline(model: model, style: style)
                DetailsRow(open: open, style: style) { model.toggleDetails() }
                if open {
                    BifrostDetails(section: snapshot.bifrost, style: style)
                    SessionsDetails(model: model, sessions: snapshot.sessions, style: style)
                    MacDetails(mac: snapshot.mac, style: style)
                    if let network = snapshot.network {
                        NetworkDetails(network: network, style: style)
                    }
                    LimitsDetails(limits: snapshot.limits, zone: model.zone, style: style)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .font(style.font(12))
        .foregroundStyle(ThemeTokens.text.color)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusable(false)
        .focusEffectDisabled()
    }
}

// A line of the panel edge colour under a part of the panel.
private struct EdgeLine: View {
    let style: PanelStyle

    var body: some View {
        Rectangle().fill(style.edge).frame(height: style.points(1)).accessibilityHidden(true)
    }
}

// A small square in a colour: the square of the level and the square of each reason.
private struct Square: View {
    let colour: TokenColour
    let size: Double
    let style: PanelStyle

    var body: some View {
        Rectangle().fill(colour.color)
            .frame(width: style.points(size), height: style.points(size))
            .accessibilityHidden(true)
    }
}

// The headline: "Checking Bifrost…" in the dim colour with no square, or the square and the word
// of the level, then the OK text or one item for each reason. Clear shows under the reasons while
// a reason comes from a past event.
private struct Headline: View {
    let model: PerformancePanelModel
    let style: PanelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.headline {
            case .checking:
                Text(PerformanceText.checking).foregroundStyle(style.dim)
            case .ok(let text):
                LevelWord(level: .ok, style: style)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, style.points(14))
                    .padding(.top, style.points(3))
            case .reasons(let level, let items):
                LevelWord(level: level, style: style)
                let gap = style.points(PerformancePanelModel.reasonGap)
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: style.points(8)) {
                            Square(colour: item.colour, size: 4, style: style)
                                .padding(.top, style.points(5))
                            Text(item.text).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, style.points(2))
                    }
                }
                .padding(.top, style.points(6))
            }
            if model.showsClear {
                Button(PerformanceText.clear) { model.clear() }
                    .buttonStyle(DialogButtonStyle(style: style))
                    .font(style.font(11))
                    .padding(.top, style.points(8))
                    .padding(.leading, style.points(2))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(style.points(8))
        .overlay(alignment: .bottom) { EdgeLine(style: style) }
    }
}

// The square and the word of the level, in the colour of the level.
private struct LevelWord: View {
    let level: HealthLevel
    let style: PanelStyle

    var body: some View {
        let colour = PerformanceColours.level(level)
        HStack(spacing: style.points(6)) {
            Square(colour: colour, size: 8, style: style)
            Text(PerformanceText.word(level)).fontWeight(.semibold).foregroundStyle(colour.color)
        }
    }
}

// The Details row opens and closes the sections. It has a line under it only while it is open,
// so a closed row ends flush with the edge of the panel (user decision, 2026-11-09).
private struct DetailsRow: View {
    let open: Bool
    let style: PanelStyle
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: style.points(6)) {
                ButtonIcon(icon: .chevronRight, size: style.points(12))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(PerformanceText.details)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, style.points(8))
            .padding(.vertical, style.points(5))
        }
        .buttonStyle(IconButtonStyle(style: style, fills: true))
        .overlay(alignment: .bottom) {
            if open { EdgeLine(style: style) }
        }
    }
}

// One section: the title and the text at its right in the small font, then the content, and a
// line under it.
private struct DetailsSection<Content: View>: View {
    let title: String
    var right: String? = nil
    var rightColour: TokenColour? = nil
    let style: PanelStyle
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(4)) {
            HStack(spacing: style.points(8)) {
                Text(title).foregroundStyle(style.dim)
                Spacer(minLength: 0)
                if let right {
                    Text(right).foregroundStyle((rightColour ?? ThemeTokens.text).color)
                }
            }
            .font(style.font(11))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, style.points(8))
        .padding(.vertical, style.points(6))
        .overlay(alignment: .bottom) { EdgeLine(style: style) }
    }
}

// The rows of keys and values of a section: the key in a column of 130 units.
private struct KeyValueRow<Value: View>: View {
    let key: String
    let style: PanelStyle
    @ViewBuilder let value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(key).frame(width: style.points(130), alignment: .leading)
            value
            Spacer(minLength: 0)
        }
    }
}

private struct BifrostDetails: View {
    let section: BifrostSection
    let style: PanelStyle

    var body: some View {
        DetailsSection(
            title: "Bifrost", right: section.use.map { PerformanceText.total($0.total) },
            style: style
        ) {
            if let use = section.use {
                TrendLine(trend: section.trend, style: style)
                Grid(
                    alignment: .leading, horizontalSpacing: style.points(14),
                    verticalSpacing: style.points(2)
                ) {
                    usageRow("App", use.app)
                    usageRow(PerformanceText.terminals(use.terminalCount), use.terminals)
                    GridRow {
                        Text("Frame rate").foregroundStyle(style.dim)
                        Text(PerformanceText.frameRate(section.frameRate))
                            .gridColumnAlignment(.trailing)
                        Color.clear.frame(width: 0, height: 0)
                    }
                    GridRow {
                        Text("Main process delay").foregroundStyle(style.dim)
                        Text(PerformanceText.delay(section.mainThreadDelay))
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
            } else {
                Text(PerformanceText.noData).foregroundStyle(style.dim)
            }
        }
    }

    private func usageRow(_ name: String, _ use: Use) -> some View {
        GridRow {
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
            Text(HealthText.memory(use.memory)).gridColumnAlignment(.trailing)
            Text(PerformanceText.percent(use.cpu)).foregroundStyle(style.dim)
                .gridColumnAlignment(.trailing)
        }
    }
}

// The Claude sessions with the most memory, each with Stop when Bifrost owns it and it runs,
// then one row with the others.
private struct SessionsDetails: View {
    let model: PerformancePanelModel
    let sessions: SessionsUse?
    let style: PanelStyle

    var body: some View {
        if let sessions, !sessions.top.isEmpty {
            DetailsSection(
                title: "Claude sessions", right: PerformanceText.total(sessions.total), style: style
            ) {
                Grid(
                    alignment: .leading, horizontalSpacing: style.points(12),
                    verticalSpacing: style.points(2)
                ) {
                    ForEach(sessions.top, id: \.row.sessionId) { session in
                        GridRow(alignment: .center) {
                            Text(session.row.name).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(HealthText.memory(session.use.memory))
                                .gridColumnAlignment(.trailing)
                            Text(PerformanceText.percent(session.use.cpu))
                                .foregroundStyle(style.dim)
                                .gridColumnAlignment(.trailing)
                            if model.showsStop(session.row) {
                                Button(PerformanceText.stop) { model.stop(session) }
                                    .buttonStyle(DialogButtonStyle(style: style))
                                    .font(style.font(11))
                                    .gridColumnAlignment(.trailing)
                            } else {
                                Color.clear.frame(width: 0, height: 0)
                            }
                        }
                    }
                    if sessions.more.count > 0 {
                        GridRow {
                            Text(PerformanceText.more(sessions.more.count))
                            Text(HealthText.memory(sessions.more.use.memory))
                            Text(PerformanceText.percent(sessions.more.use.cpu))
                            Color.clear.frame(width: 0, height: 0)
                        }
                        .foregroundStyle(style.dim)
                    }
                }
            }
        } else {
            DetailsSection(title: "Claude sessions", style: style) {
                Text(sessions == nil ? PerformanceText.noData : PerformanceText.noSessions)
                    .foregroundStyle(style.dim)
            }
        }
    }
}

private struct MacDetails: View {
    let mac: MacValues?
    let style: PanelStyle

    var body: some View {
        DetailsSection(title: "Your Mac", style: style) {
            VStack(alignment: .leading, spacing: style.points(2)) {
                KeyValueRow(key: "Memory pressure", style: style) {
                    PressureValue(pressure: mac?.pressure, style: style)
                }
                KeyValueRow(key: "Swap", style: style) { Text(PerformanceText.swap(mac?.swap)) }
                KeyValueRow(key: "CPU load", style: style) { Text(PerformanceText.load(mac?.load)) }
                KeyValueRow(key: "Thermal state", style: style) {
                    Text(PerformanceText.thermal(mac?.thermal)).foregroundStyle(
                        (PerformanceColours.thermal(mac?.thermal) ?? ThemeTokens.text).color)
                }
                KeyValueRow(key: "Battery", style: style) {
                    Text(PerformanceText.battery(mac?.battery))
                }
            }
        }
    }
}

// The memory pressure: a bar that fills a third, two thirds or all of its width, and the word,
// both in the colour of the pressure.
private struct PressureValue: View {
    let pressure: MemoryPressure?
    let style: PanelStyle

    var body: some View {
        let colour = PerformanceColours.pressure(pressure)
        HStack(spacing: style.points(8)) {
            if let pressure, let colour {
                let fill: Double =
                    switch pressure {
                    case .normal: 1.0 / 3
                    case .warning: 2.0 / 3
                    case .critical: 1
                    }
                Rectangle().fill(style.edge)
                    .frame(width: style.points(110), height: style.points(6))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(colour.color)
                            .frame(width: style.points(110 * fill))
                    }
                    .accessibilityHidden(true)
            }
            Text(PerformanceText.pressure(pressure))
                .foregroundStyle((colour ?? ThemeTokens.text).color)
        }
    }
}

private struct NetworkDetails: View {
    let network: NetworkValues
    let style: PanelStyle

    var body: some View {
        let rates = PerformanceText.rates(network.rates)
        DetailsSection(
            title: "Network", right: PerformanceText.link(network),
            rightColour: network.online ? ThemeTokens.ctxLow : ThemeTokens.ctxHigh, style: style
        ) {
            VStack(alignment: .leading, spacing: style.points(2)) {
                KeyValueRow(key: "Down / up", style: style) {
                    HStack(spacing: style.points(12)) {
                        Text(rates.down)
                        Text(rates.up)
                    }
                }
                KeyValueRow(key: "Anthropic", style: style) {
                    Text(PerformanceText.responseTime(network.anthropic))
                }
                KeyValueRow(key: "GitHub", style: style) {
                    Text(PerformanceText.responseTime(network.github))
                }
            }
        }
    }
}

// The GitHub points, the free disk and, while Reviews has clones, their size. The last section
// has no line under it.
private struct LimitsDetails: View {
    let limits: LimitsSection
    let zone: TimeZone
    let style: PanelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(4)) {
            Text("Limits and disk").font(style.font(11)).foregroundStyle(style.dim)
            VStack(alignment: .leading, spacing: style.points(2)) {
                KeyValueRow(key: "GitHub points", style: style) {
                    Text(PerformanceText.points(limits.github, zone: zone))
                        .fixedSize(horizontal: false, vertical: true)
                }
                KeyValueRow(key: "Free disk", style: style) {
                    Text(PerformanceText.disk(limits.freeSpace))
                }
                if let clones = limits.clones {
                    KeyValueRow(key: "Reviews clones", style: style) {
                        Text(HealthText.memory(clones))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, style.points(8))
        .padding(.vertical, style.points(6))
    }
}
