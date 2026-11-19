// The Layouts popover (docs/behaviour/windows.md, "The side bar and layouts"): a name field and
// Save, then the saved names, each with Load and Delete. The field takes the focus when the popover
// opens, and again at each Cmd+Option+S. Enter in the field saves. A bad name or a full list shows
// its message. The box is 256 units wide, on the title colour, with a border of the panel edge
// colour, a padding of 12 and the UI font at 12.
import BifrostLayout
import BifrostLook
import SwiftUI

struct LayoutPopover: View {
    @Bindable var model: SideBarModel
    @State private var name = ""
    @State private var message: String?
    @FocusState private var fieldFocused: Bool

    // The message of a save result, or nil for a save.
    static func message(for result: LayoutSaveResult) -> String? {
        switch result {
        case .saved: nil
        case .badName: "Use 1 to \(UIState.maxName) characters."
        case .full: "Delete a layout first. The limit is \(UIState.maxLayouts)."
        }
    }

    var body: some View {
        let metrics = model.metrics
        let font = Font(Fonts.ui(metrics.points(12), weight: .regular) as CTFont)
        VStack(alignment: .leading, spacing: metrics.points(8)) {
            HStack(spacing: metrics.points(8)) {
                TextField("Layout name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit(save)
                    .onChange(of: name) { message = nil }
                    .padding(.horizontal, metrics.points(8))
                    .padding(.vertical, metrics.points(4))
                    .background(ThemeTokens.bg.color)
                    .overlay {
                        Rectangle().strokeBorder(
                            fieldFocused ? strong30 : ThemeTokens.panelEdge.color,
                            lineWidth: metrics.points(1))
                    }
                    .accessibilityLabel("Layout name")
                SmallButton(title: "Save", label: "Save", model: model, action: save)
            }
            if let message {
                Text(message)
            }
            if model.layoutNames.isEmpty {
                Text("No saved layouts.").foregroundStyle(ThemeTokens.textDim.color)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: metrics.points(4)) {
                        // Each name is one time in the list (row U5), so the name is the
                        // identity of its row. The hover state stays with its row after a
                        // delete.
                        ForEach(model.layoutNames, id: \.self) { name in
                            row(name)
                        }
                    }
                }
                .frame(maxHeight: metrics.points(256))
                .accessibilityLabel("Saved layouts")
            }
        }
        .font(font)
        .foregroundStyle(ThemeTokens.text.color)
        .padding(metrics.points(12))
        .frame(width: metrics.points(256), alignment: .leading)
        .background(ThemeTokens.title.color)
        .overlay {
            Rectangle().strokeBorder(ThemeTokens.panelEdge.color, lineWidth: metrics.points(1))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layouts")
        .onAppear { fieldFocused = true }
        .onChange(of: model.popoverFocusRequest) { fieldFocused = true }
    }

    private var strong30: Color {
        var colour = ThemeTokens.textStrong
        colour.a = 0.3
        return colour.color
    }

    private func row(_ item: String) -> some View {
        HStack(spacing: model.metrics.points(8)) {
            Text(item)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(item)
                .frame(maxWidth: .infinity, alignment: .leading)
            SmallButton(title: "Load", label: "Load \(item)", model: model) {
                model.loadLayout(item)
            }
            SmallButton(title: "Delete", label: "Delete \(item)", model: model) {
                model.deleteLayout(item)
            }
        }
    }

    // Enter in the name field also saves.
    private func save() {
        let result = model.saveLayout(name)
        message = Self.message(for: result)
        if result == .saved { name = "" }
    }
}

// A small button of the popover: a border of the panel edge colour and a padding of 8 by 2.
private struct SmallButton: View {
    let title: String
    let label: String
    let model: SideBarModel
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let metrics = model.metrics
        Button(action: action) {
            Text(title)
                .padding(.horizontal, metrics.points(8))
                .padding(.vertical, metrics.points(2))
        }
        .buttonStyle(SideButtonStyle(hovered: hovered, transparency: model.panelTransparency))
        .fixedSize()
        .overlay {
            Rectangle().strokeBorder(ThemeTokens.panelEdge.color, lineWidth: metrics.points(1))
        }
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}
