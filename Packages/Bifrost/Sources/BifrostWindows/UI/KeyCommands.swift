import AppKit
import BifrostKeyboard
import BifrostLayout
import BifrostSessions

// The commands of the Bifrost keys. The window key filter gives each slot that acts.
//
// Each slot has its command here: the window commands, the Overview commands, the row commands,
// the session keys, the Settings key (settings:mod, Cmd+,) and the keys of the Event log and the
// Usage HUD. Esc and the dictation key have their own paths: the key layer gives Esc as an intent
// (escape(_:in:)), and the chat input reads the dictation key. docs/behaviour/keys.md lists the
// slots.
//
// The session keys run their action through the action runner (runner): on the selected row, on
// the clicked row of a hold click, or with no row (New session and Resume all). A focus in a chat
// window selects the row of its chat, so a key in a chat acts on its session. The runner reads the
// row by its ID at the run, and it shows the reason of a refusal in its error line. While a dialog
// shows, no session key and no global key acts.
@MainActor
public final class KeyCommands {
    private let layout: WindowLayoutModel
    private let sideBar: SideBarModel
    private let selection: SelectionModel
    // The Overview bodies and their model: the tabs, the rows and the rows focus of each
    // Overview.
    private let overviews: OverviewPanels
    private let openChat: (String) -> Void
    private let menu: (MenuItemModel.Action) -> Void
    // The runner of the session actions. The app sets it when the services found claude. With
    // no runner, the session keys and the global keys do nothing.
    package var runner: ActionRunner?

    // openChat opens the chat of a session ID, or brings its frame to the front. menu runs an
    // action of the menu (the key of toggle-fullscreen).
    package init(
        layout: WindowLayoutModel, sideBar: SideBarModel, selection: SelectionModel,
        overviews: OverviewPanels, openChat: @escaping (String) -> Void,
        menu: @escaping (MenuItemModel.Action) -> Void
    ) {
        self.layout = layout
        self.sideBar = sideBar
        self.selection = selection
        self.overviews = overviews
        self.openChat = openChat
        self.menu = menu
    }

    // The command of a key slot. Esc and the dictation key do nothing here (see the header).
    package func run(_ slot: KeySlot) {
        switch slot.command {
        // The menu gets the keys of the two menu slots first. The debug test port can give them
        // here too.
        case .closePanel: layout.apply(.closeActive)
        case .toggleFullscreen: menu(.toggleFullScreen)
        case .prevStackTab: stepStack(by: -1)
        case .nextStackTab: stepStack(by: 1)
        case .loadLayout(let number): loadLayout(number)
        case .saveLayout: sideBar.openLayoutSave()
        case .focusOverview: focusOverview()
        case .nextOverviewTab: stepOverviewTab(by: 1)
        case .prevOverviewTab: stepOverviewTab(by: -1)
        case .selectRow(let row): selectRow(row)
        case .selectPrev: stepRow(by: -1)
        case .selectNext: stepRow(by: 1)
        case .open:
            if let id = selection.selectedId, selection.hasSelectedRow { open(id) }
        case .interrupt, .sendMessage, .runSlash, .rename, .showInfo, .copyId, .openProject,
            .openInTerminal, .takeControl, .resume, .setPriority, .stop, .delete:
            if let id = selection.selectedId, selection.hasSelectedRow {
                runSessionKey(slot.command, on: id)
            }
        case .newSession: runGlobal(.newSession)
        case .resumeAll: runGlobal(.resumeAll)
        // The dictation key does nothing here: the input of the chat reads the hold key.
        case .dictation: break
        // The panel keys open their panel, or bring it to the front.
        case .eventLog: layout.apply(.open(.eventLog))
        case .usageHud: layout.apply(.open(.usageHud))
        // The Settings key opens Settings, or brings it to the front.
        case .settings: openSettings()
        // The key layer gives Esc as an intent (escape(_:in:)).
        case .escape: break
        }
    }

    // The hold click of a hold slot on a row (planHold). The action acts on the clicked row, and
    // the click does not select the row (D8). Send message then selects the row for its send box,
    // as the button does. The hold slots are Open, Send message, Show Info, Open in terminal,
    // Interrupt and Set priority 1 to 5.
    package func runHold(_ slot: KeySlot, row: String) {
        switch slot.command {
        case .open: open(row)
        default: runSessionKey(slot.command, on: row)
        }
    }

    // The intent of Esc. In the send box, Esc gives up the focus of the send box: the window
    // becomes the first responder, so the focus is in the other zone and the draft stays. Else
    // Esc opens Settings and brings it to the front, or closes it when it is the active panel of
    // the top frame.
    package func escape(_ intent: EscapeIntent, in window: NSWindow? = nil) {
        switch intent {
        case .none: break
        case .leaveSendBox: _ = window?.makeFirstResponder(nil)
        case .openSettings: openSettings()
        case .closeSettings: layout.apply(.close(.settings))
        }
    }

    // True when Settings is the active panel of the top frame that shows (the Esc rule).
    package var settingsOnTop: Bool {
        layout.layout.topFrame?.active.kind == .settings
    }

    // MARK: - The window commands

    private func openSettings() {
        layout.apply(.open(.settings))
    }

    // The panel after or before the active panel of the top frame. It wraps (stepStack).
    private func stepStack(by step: Int) {
        guard let frame = layout.layout.topFrame, frame.panels.count > 1,
            let index = frame.panels.firstIndex(of: frame.active)
        else { return }
        let count = frame.panels.count
        layout.apply(.activate(frame.panels[(index + step + count) % count]))
    }

    // load-layout.<n> loads the named layout at index n - 1.
    private func loadLayout(_ number: Int) {
        guard sideBar.layoutNames.indices.contains(number - 1) else { return }
        sideBar.loadLayout(sideBar.layoutNames[number - 1])
    }

    // MARK: - The Overview commands

    // The focused Overview: the Overview whose rows view is the first responder, else the active
    // Overview of the highest frame that shows. The tab keys and the row keys act on it. nil when
    // no Overview shows as the active panel of a frame.
    private var focused: PanelID? {
        overviews.focusedPanel ?? Self.focusedOverview(layout.layout.frames)
    }

    // The active Overview of the highest frame that shows and has an Overview as its active
    // panel.
    static func focusedOverview(_ frames: [LayoutFrame]) -> PanelID? {
        frames.last { !$0.minimised && $0.active.kind == .overview }?.active
    }

    // The focused Overview, else the top Overview of the side bar, else a new overview:1 (D9).
    // Then its rows view becomes the first responder, so the Bifrost keys act on its rows.
    private func focusOverview() {
        let panel = focused ?? SideBarModel.topOverview(layout.layout.frames) ?? .overview(1)
        layout.apply(.open(panel))
        overviews.focusRows(panel)
    }

    // The tab after or before the active tab of the focused Overview becomes the active tab. It
    // wraps: after the last tab comes the first tab, and before the first tab comes the last.
    private func stepOverviewTab(by step: Int) {
        guard let panel = focused else { return }
        let config = overviews.model.config(panel)
        let tabs = config.tabs.map(\.id)
        guard let index = tabs.firstIndex(of: config.activeTab.id) else { return }
        let count = tabs.count
        overviews.model.update(panel, .activate(tabs[(index + step + count) % count]))
    }

    // MARK: - The row commands

    // The rows of the active tab of the focused Overview, in the order of the view: the filter,
    // then the sort. With no focused Overview, the row keys do nothing.
    private var shownRows: [String]? {
        guard let panel = focused else { return nil }
        return overviews.model.viewRows(panel).map(\.sessionId)
    }

    // select-row.<n> selects the n-th row.
    private func selectRow(_ number: Int) {
        guard let rows = shownRows, rows.indices.contains(number - 1) else { return }
        selection.selectedId = rows[number - 1]
    }

    // The next or the previous row. A step past the first or the last row does nothing. With no
    // selection, the next row is the first row and the previous row is the last (stepRow).
    private func stepRow(by step: Int) {
        guard let rows = shownRows, let first = rows.first, let last = rows.last else { return }
        guard let index = rows.firstIndex(where: { $0 == selection.selectedId }) else {
            selection.selectedId = step > 0 ? first : last
            return
        }
        let next = index + step
        if rows.indices.contains(next) { selection.selectedId = rows[next] }
    }

    // Open the chat of a row. Only an owned row that is not parked has a chat (the open action).
    private func open(_ id: String) {
        guard selection.ownedIds.contains(id) else { return }
        openChat(id)
    }

    // MARK: - The session keys

    // Run the action of a session key on the session of a row. The runner plans the action for
    // the row of now: an action that is off for the row plans none and does nothing. While a
    // dialog shows, no session key acts.
    private func runSessionKey(_ command: KeyCommand, on sessionId: String) {
        guard let runner, !runner.dialogs.isOpen,
            let action = Self.sessionAction(command, defaultApp: runner.defaultProjectApp)
        else { return }
        runner.run(action.id, sessionId, arg: action.arg)
    }

    // Run a global key. While a dialog shows, it does nothing.
    private func runGlobal(_ id: GlobalActionID) {
        guard let runner, !runner.dialogs.isOpen else { return }
        runner.runGlobal(id)
    }

    // The action of a session key on a row, and the choice that the key gives it. Set priority 0
    // gives no priority. Open project gives the default project app (defaultApp), and with no
    // default app it has no action. nil for a command that is no session action of a row.
    package static func sessionAction(
        _ command: KeyCommand, defaultApp: @autoclosure () -> ProjectAppID?
    ) -> KeyAction? {
        let id: ActionID
        switch command {
        case .sendMessage: id = .sendMessage
        case .runSlash: id = .runSlash
        case .interrupt: id = .interrupt
        case .rename: id = .rename
        case .showInfo: id = .showInfo
        case .copyId: id = .copyId
        case .openInTerminal: id = .openInTerminal
        case .takeControl: id = .takeControl
        case .resume: id = .resume
        case .stop: id = .stop
        case .delete: id = .delete
        case .setPriority(let number):
            return KeyAction(id: .setPriority, arg: .priority(SessionPriority(rawValue: number)))
        case .openProject:
            return defaultApp().map { KeyAction(id: .openProject, arg: .app($0)) }
        case .newSession, .selectRow, .selectPrev, .selectNext, .focusOverview, .open,
            .resumeAll, .closePanel, .prevStackTab, .nextStackTab, .nextOverviewTab,
            .prevOverviewTab, .loadLayout, .saveLayout, .eventLog, .usageHud, .settings,
            .toggleFullscreen, .escape, .dictation:
            return nil
        }
        return KeyAction(id: id, arg: nil)
    }
}

// A session action that a key runs on a row: the action, and the choice of a menu that the key
// gives it.
package struct KeyAction: Equatable {
    package let id: ActionID
    package let arg: MenuArg?
}
