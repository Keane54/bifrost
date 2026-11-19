// An icon button for one action of a session in the Selected Item panel (docs/behaviour/actions.md,
// "The Selected Item panel"): a square of 24 units with a lucide icon of 15, the hover colour
// under the pointer and the cyan tint during a press. A button that is off is at 40 % opacity,
// takes no click and keeps its tooltip: the title, and the reason on a second line. Hand over
// shows the warning colour when the context is nearly full. The button is not focusable (the
// section "The UI" of the architecture design), so it is never in the Tab loop of the window.
import AppKit
import BifrostLook
import BifrostSessions
import SwiftUI

// One button: its action, its icon, its label for accessibility, its tooltip, its state, the
// reason of a button that is off (the hint for accessibility) and the warning colour of Hand over.
package struct ActionButtonItem: Identifiable, Equatable {
    package var action: ActionID
    package var icon: IconName
    package var label: String
    package var tip: String
    package var enabled: Bool
    package var hint: String?
    package var warn: Bool
    package var id: ActionID { action }

    // The icon of each action that the panel shows.
    package static func icon(_ action: ActionID) -> IconName? {
        switch action {
        case .compact: .shrink
        case .handOver: .arrowRightLeft
        case .interrupt: .hand
        case .open: .appWindow
        case .openInTerminal: .squareTerminal
        case .runSlash: .slash
        case .sendMessage: .messageSquare
        case .showInfo: .info
        case .stop: .power
        case .watchAdd: .eye
        case .watchRemove: .eyeOff
        default: nil
        }
    }

    // The button of the action for the row, with the context of the runner now. An action with
    // no icon has no button.
    package static func of(_ action: ActionID, _ row: SessionRow, _ ctx: ActionContext)
        -> ActionButtonItem?
    {
        guard let icon = icon(action) else { return nil }
        let state = ActionModel.state(action, row, ctx)
        return ActionButtonItem(
            action: action, icon: icon, label: action.label(ctx.labels),
            tip: ActionModel.buttonTip(action, state, ctx.labels), enabled: state.enabled,
            hint: state.enabled ? nil : state.reason,
            warn: action == .handOver && ActionModel.handOverWarning(row))
    }
}

// The button. press gets the rect of the button in the coordinates of its window, for the menu
// of Add to watchlist.
struct ActionButton: View {
    let item: ActionButtonItem
    let style: PanelStyle
    let press: (ActionButtonItem, NSView?) -> Void
    @State private var anchor = AnchorBox()

    var body: some View {
        Button {
            press(item, anchor.view)
        } label: {
            Image(nsImage: Icons.image(item.icon))
                .renderingMode(.template)
                .resizable()
                .frame(width: style.points(15), height: style.points(15))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .buttonStyle(ActionButtonStyle(style: style, warn: item.warn))
        .disabled(!item.enabled)
        .frame(width: style.points(24), height: style.points(24))
        .focusable(false)
        .focusEffectDisabled()
        .background(ButtonAnchor(box: anchor))
        .background(TipAnchor(text: item.tip, side: .top))
        .accessibilityLabel(item.label)
        .accessibilityHint(item.hint ?? "")
    }
}

// The look of an action button: the text colour (or the warning colour), the hover colour under
// the pointer, the cyan tint during a press, and 40 % opacity while it is off.
struct ActionButtonStyle: ButtonStyle {
    let style: PanelStyle
    let warn: Bool

    func makeBody(configuration: Configuration) -> some View {
        Look(configuration: configuration, style: style, warn: warn)
    }

    private struct Look: View {
        let configuration: Configuration
        let style: PanelStyle
        let warn: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle((warn ? ThemeTokens.ctxMid : ThemeTokens.text).color)
                .background(background)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }

        private var background: Color {
            guard enabled else { return .clear }
            if configuration.isPressed { return style.press }
            return hovered ? ThemeTokens.hover.color : .clear
        }
    }
}

// The view behind a button that the menu of Add to watchlist opens below. It takes no pointer
// input and is hidden from accessibility.
@MainActor
final class AnchorBox {
    weak var view: NSView?
}

struct ButtonAnchor: NSViewRepresentable {
    let box: AnchorBox

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        box.view = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        box.view = view
    }
}

final class AnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
