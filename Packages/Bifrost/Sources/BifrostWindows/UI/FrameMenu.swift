// The Panel menu of a frame (docs/behaviour/menu.md, "The Panel menu"): a Bifrost menu, 208 units
// wide, below the menu button at its right edge. Its rows: the check box Lock, which keeps the
// menu open. A frame has no opacity control. The menu of an Overview also has "Overview
// settings…" above Lock, which opens the Overview Settings panel of that Overview, and the name
// field of its tab set below Lock. It is not a context menu: a press outside closes it and goes on
// to its view (BifrostMenu.OutsidePress.goesOn).
import AppKit

// The Overview part of the Panel menu: the open action of the Overview Settings panel, the saved
// name of the tab set now, and the rename of the tab set.
@MainActor
struct OverviewMenuItems {
    let openSettings: () -> Void
    let setName: () -> String
    let rename: (String) -> Void
}

@MainActor
enum FrameMenu {
    // The width of the menu, in layout units.
    static let width = 208.0

    // The IDs of the rows.
    enum Row: String {
        case overviewSettings = "overview-settings"
        case lock
        case setName = "set-name"
    }

    // The rows for a frame. setName is the saved name of the tab set of an Overview, or nil for
    // another panel.
    static func rows(locked: Bool, setName: String?) -> [MenuRow] {
        var rows: [MenuRow] = []
        if setName != nil {
            rows.append(
                .item(MenuItemSpec(id: Row.overviewSettings.rawValue, label: "Overview settings…")))
        }
        rows.append(.checkbox(MenuItemSpec(id: Row.lock.rawValue, label: "Lock"), checked: locked))
        if let setName {
            rows.append(
                .field(
                    id: Row.setName.rawValue, label: "Tab set name", text: setName,
                    maxLength: OverviewConfig.maxSetName))
        }
        return rows
    }

    // Show the Panel menu of a frame on the menu, below the button at its right edge. locked
    // gives the lock of the frame now, and setLocked changes it. overview gives the items of an
    // Overview, or nil for another panel. After a change, the menu shows the new rows: the check
    // of Lock, and the saved name in the field (an empty name leaves the old name).
    static func show(
        on menu: BifrostMenu, below button: NSView, locked: @escaping () -> Bool,
        setLocked: @escaping (Bool) -> Void, overview: OverviewMenuItems?
    ) {
        guard let window = button.window else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let rows = { Self.rows(locked: locked(), setName: overview?.setName()) }
        menu.show(
            rows(), width: width, at: .below(rect, rightEdge: true), in: window,
            outsidePress: .goesOn,
            onChoose: { [weak menu] id in
                switch Row(rawValue: id) {
                case .lock:
                    setLocked(!locked())
                    menu?.update(rows())
                case .overviewSettings:
                    overview?.openSettings()
                case .setName, nil:
                    break
                }
            },
            onField: { [weak menu] _, text in
                overview?.rename(text)
                menu?.update(rows())
            },
            onClose: {})
    }
}
