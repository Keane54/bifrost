// The thin bar on the left edge, in SwiftUI in one NSHostingView: the Overview button, the New
// Overview button, the Selected Item button, the panel buttons, a separator, the global buttons
// (New session and Resume all), a separator when a frame is minimised, one button for each
// minimised frame, then the Layouts button and the Settings button at the bottom. The bar is 40
// units wide (40 points at the scale 100), on the title colour, with the panel edge colour as its
// right border. Each button is 32 units square with an icon of 16 (15 for a global button): the
// dim text colour, the panel colour and the text colour under the pointer, and the cyan tint
// during a press. Each button has the Bifrost tooltip at its right, not the native tooltip (user
// decision, 2026-11-09). While Live details or Claude Code has a warning, the Settings button
// shows a small square dot at its top right, and its tooltip and its accessibility hint say that
// something needs attention. The Reviews button shows the same dot while a pull request waits for
// the user. The Daily update button has the same dot on a due day after the draft time while an
// area is not sent. The Performance button, the last panel button, has a dot in the colour of
// the level while Bifrost's health is Warning or Problem. The other panel buttons come with their
// panels in later phases.
import AppKit
import BifrostKeyboard
import BifrostLayout
import BifrostLook
import BifrostSessions
import SwiftUI

public struct SideBarView: View {
    private let model: SideBarModel
    private let bodies: any PanelBodies

    package init(model: SideBarModel, bodies: any PanelBodies) {
        self.model = model
        self.bodies = bodies
    }

    // The width of the bar, in layout units.
    public static let width = 40.0

    // The icon of a minimised frame: the icon of the kind of its active panel. The icon of the
    // session of a chat and the icon of the manifest of a module come with those panels.
    static func icon(of panel: PanelID) -> IconName { panel.kind.icon }

    // The Overview button opens the top Overview, else overview:1.
    var overviewButton: SideBarButton {
        SideBarButton(
            id: "overview", icon: PanelKind.overview.icon, label: "Overview", tip: "Overview"
        ) { [model] in model.openOverview() }
    }

    // The New Overview button opens the lowest free Overview number. It is off when each of the
    // 99 Overviews has a frame.
    var newOverviewButton: SideBarButton {
        SideBarButton(
            id: "new-overview", icon: .listPlus, label: "New Overview", tip: "New Overview",
            disabled: model.freeOverview == nil
        ) { [model] in model.openNewOverview() }
    }

    // The Selected Item button opens the Selected Item panel, or brings it to the front.
    var selectedItemButton: SideBarButton {
        SideBarButton(
            id: "selected-item", icon: PanelKind.selectedItem.icon, label: "Selected Item",
            tip: "Selected Item"
        ) { [model] in model.open(.selectedItem) }
    }

    // The text of the dot of the Daily update button.
    package static let dailyUpdateAttention = "Daily update - Not sent yet"

    // The panel buttons below Selected Item, in the order of the side bar of the Electron app.
    // Each button opens its panel, or brings it to the front, and shows the dot of its panel
    // (SideBarModel.dot).
    var panelButtons: [SideBarButton] {
        let panels: [(PanelID, String)] = [
            (.watchlist, "Watchlist"), (.eventLog, "Event log"), (.usageHud, "Usage HUD"),
            (.serviceStatus, "Service status"), (.reviews, "Reviews"),
            (.dailyUpdate, "Daily update"), (.performance, "Performance"),
        ]
        return panels.map { panel, label in
            let dot = model.dot(panel)
            return SideBarButton(
                id: panel.text, icon: panel.kind.icon, label: label, tip: dot?.text ?? label,
                dot: dot?.text, dotColour: dot?.colour
            ) { [model] in model.open(panel) }
        }
    }

    // The text of the dot of the Reviews button.
    package static let reviewsAttention = "Reviews - a pull request waits for you"

    // The buttons of the actions that need no row: New session, then Resume all. Each has the
    // state of the action model. The tooltip gives the title, and the reason of an off button on
    // a second line. An off button takes no click.
    var globalButtons: [SideBarButton] {
        let labels = model.labels
        let buttons: [(GlobalActionID, IconName)] = [
            (.newSession, .squarePlus), (.resumeAll, .rotateCcw),
        ]
        return buttons.map { id, icon in
            let action = id.action
            let state = model.globalState(id)
            return SideBarButton(
                id: id.rawValue, icon: icon, label: action.label(labels),
                tip: ActionModel.buttonTip(action, state, labels), disabled: !state.enabled,
                iconSize: 15
            ) { [model] in model.runGlobal(id) }
        }
    }

    // One button for each minimised frame, in z-order. The tooltip gives the title of the active
    // panel. The label is "Restore" and the title. A title comes from observed values (the rows
    // of the session list), so SwiftUI shows a new title at once.
    var minimisedButtons: [SideBarButton] {
        model.minimised.map { frame in
            let title = bodies.title(for: frame.active)
            return SideBarButton(
                id: frame.id.text, icon: Self.icon(of: frame.active), label: "Restore \(title)",
                tip: title
            ) { [model] in model.restore(frame.id) }
        }
    }

    // The Layouts button opens and closes the Layouts popover.
    var layoutsButton: SideBarButton {
        SideBarButton(id: "layouts", icon: .layoutGrid, label: "Layouts", tip: "Layouts") {
            [model] in model.popoverOpen.toggle()
        }
    }

    // The text of the dot of the Settings button.
    package static let settingsAttention = "Settings - something needs your attention"

    // The Settings button opens Settings. It shows the dot while there is a warning.
    var settingsButton: SideBarButton {
        let dot = model.dot(.settings)
        return SideBarButton(
            id: "settings", icon: PanelKind.settings.icon, label: "Settings",
            tip: dot?.text ?? "Settings", dot: dot?.text, dotColour: dot?.colour
        ) { [model] in model.openSettings() }
    }

    public var body: some View {
        let metrics = model.metrics
        let edge = ThemeTokens.panelEdge.color
        VStack(spacing: metrics.points(4)) {
            SideButton(
                button: overviewButton, metrics: metrics, transparency: model.panelTransparency)
            SideButton(
                button: newOverviewButton, metrics: metrics,
                transparency: model.panelTransparency)
            SideButton(
                button: selectedItemButton, metrics: metrics,
                transparency: model.panelTransparency)
            ForEach(panelButtons) { button in
                SideButton(
                    button: button, metrics: metrics, transparency: model.panelTransparency)
            }
            Separator(metrics: metrics)
            ForEach(globalButtons) { button in
                SideButton(
                    button: button, metrics: metrics, transparency: model.panelTransparency)
            }
            if !model.minimised.isEmpty { Separator(metrics: metrics) }
            ScrollView(.vertical) {
                VStack(spacing: metrics.points(4)) {
                    ForEach(minimisedButtons) { button in
                        SideButton(
                            button: button, metrics: metrics,
                            transparency: model.panelTransparency)
                    }
                }
            }
            .scrollIndicators(.automatic)
            LayoutsButton(model: model, button: layoutsButton, metrics: metrics)
            SideButton(
                button: settingsButton, metrics: metrics, transparency: model.panelTransparency)
        }
        .padding(.vertical, metrics.points(8))
        .frame(width: metrics.points(Self.width))
        .frame(maxHeight: .infinity)
        .background(ThemeTokens.title.color)
        .overlay(alignment: .trailing) {
            Rectangle().fill(edge).frame(width: metrics.points(1)).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side bar")
    }
}

// One button of the side bar: the icon, the label for accessibility, the text of the tooltip,
// the dot, the off state and the action.
@MainActor
struct SideBarButton: Identifiable {
    let id: String
    let icon: IconName
    let label: String
    let tip: String
    // The text of the dot of the button, or nil for no dot. The button gives it as its
    // accessibility hint.
    var dot: String?
    // The colour of the dot, or nil for no dot.
    var dotColour: TokenColour? = nil
    // An off button is at 40 % opacity, gets no hover colour and takes no click.
    var disabled = false
    // The size of the icon, in layout units.
    var iconSize = 16.0
    let action: () -> Void
}

// The line between two groups of side bar buttons: 24 units wide in the panel edge colour.
private struct Separator: View {
    let metrics: CanvasMetrics

    var body: some View {
        Rectangle().fill(ThemeTokens.panelEdge.color)
            .frame(width: metrics.points(24), height: metrics.points(1))
            .padding(.vertical, metrics.points(4))
            .accessibilityHidden(true)
    }
}

// The Layouts button and its popover. The model keeps the open state, so Cmd+Option+S can open
// the popover.
private struct LayoutsButton: View {
    @Bindable var model: SideBarModel
    let button: SideBarButton
    let metrics: CanvasMetrics

    var body: some View {
        SideButton(button: button, metrics: metrics, transparency: model.panelTransparency)
            .popover(isPresented: $model.popoverOpen, arrowEdge: .trailing) {
                LayoutPopover(model: model)
            }
    }
}

extension SideBarView {
    // The host of the side bar in the window. A focused SwiftUI button makes the host the first
    // responder, so the host has the control mark: each part of the bar that takes the focus is a
    // button, so it is in the control zone. The window sets the size of the host. Its SwiftUI
    // content does not.
    public static func host(
        model: SideBarModel, bodies: any PanelBodies
    ) -> NSHostingView<SideBarView> {
        let host = NSHostingView(rootView: SideBarView(model: model, bodies: bodies))
        host.identifier = FocusMark.control
        host.sizingOptions = []
        return host
    }
}

// One button of the side bar. The icon takes no pointer input and is hidden from accessibility:
// the button has its label.
struct SideButton: View {
    let button: SideBarButton
    let metrics: CanvasMetrics
    let transparency: Int
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: button.action) {
            ButtonIcon(icon: button.icon, size: metrics.points(button.iconSize))
        }
        .buttonStyle(
            SideButtonStyle(hovered: hovered && !button.disabled, transparency: transparency)
        )
        .disabled(button.disabled)
        .opacity(button.disabled ? 0.4 : 1)
        .frame(width: metrics.points(32), height: metrics.points(32))
        .overlay(alignment: .topTrailing) {
            if button.dot != nil {
                Rectangle().fill((button.dotColour ?? ThemeTokens.textStrong).color)
                    .frame(width: metrics.points(6), height: metrics.points(6))
                    .padding(metrics.points(6))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .focused($focused)
        .onHover { hovered = $0 }
        .background(TipAnchor(text: button.tip, side: .right, focused: focused))
        .accessibilityLabel(button.label)
        .accessibilityHint(button.dot ?? "")
    }
}

// The look of a side bar button and of the small buttons of the Layouts popover.
struct SideButtonStyle: ButtonStyle {
    let hovered: Bool
    let transparency: Int

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle((hovered ? ThemeTokens.text : ThemeTokens.textDim).color)
            .background(background(pressed: configuration.isPressed))
            .contentShape(Rectangle())
    }

    private func background(pressed: Bool) -> Color {
        if pressed { return Color(cgColor: TitleButton.pressColour) }
        return hovered ? ThemeTokens.panel(transparency: transparency).color : .clear
    }
}
