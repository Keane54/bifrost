// The dialogs of the window (docs/behaviour/actions.md, "The dialogs"). Each dialog is a Bifrost
// box inside the window, in SwiftUI, and never a sheet, an alert or another window (user
// decision, 2026-11-16). The overlay (DialogLayerView) is one NSHostingView over the canvas: it
// shows the backdrop and the box of the dialog, and it is hidden while no dialog shows.
//
// - One dialog shows at a time. A request while a dialog shows does not open: a confirmation
//   gives false and calls onBusy, and Rename and New session give the busy notice of the runner.
// - The overlay has the dialog mark (FocusMark.modal), and the window puts each key in the modal
//   zone while a dialog shows, so no key of Bifrost acts. At the open, a Bifrost menu of the
//   window closes, and then the overlay takes the key focus. The focus stays in the overlay until
//   the close (BifrostWindow.makeFirstResponder), also when a save or the checks of a start turn
//   the fields off. Then a view in the overlay holds it (DialogLayerView.focusHolder). At the
//   close, the old first responder of the window gets the focus back.
// - Esc cancels the dialog. A click on the backdrop closes Rename and New session, and does
//   nothing for a confirmation. While a save runs, Rename stays open, and while the checks of a
//   start run, New session stays open.
// - Esc and a click on the backdrop do nothing for the Setup dialog: only its Skip and Done
//   close it. Esc and a click on the backdrop close the release notes dialog.
import AppKit
import BifrostFoundation
import BifrostKeyboard
import BifrostLook
import BifrostSessions
import BifrostSettings
import Observation
import SwiftUI

@MainActor
@Observable
package final class DialogHost {
    // The dialog that shows, with its model.
    package enum Dialog {
        case confirm(ConfirmDialogModel)
        case rename(RenameDialogModel)
        case newSession(NewSessionDialogModel)
        case setup(SetupDialogModel)
        case releaseNotes(ReleaseNotesDialogModel)

        var model: AnyObject {
            switch self {
            case .confirm(let model): model
            case .rename(let model): model
            case .newSession(let model): model
            case .setup(let model): model
            case .releaseNotes(let model): model
            }
        }
    }

    // The dialog that shows, or nil.
    package private(set) var dialog: Dialog?
    // The Interface scale and the Panel transparency of the boxes.
    @ObservationIgnored package let look: PanelLook
    @ObservationIgnored let clock: any Clock<Duration>
    // Choose a folder for the New session dialog: the window of the dialog and the folder to show
    // first. nil when the user cancelled. A test gives a fake, so no test shows a panel.
    @ObservationIgnored package var pickFolder: @MainActor (NSWindow?, String?) async -> String? =
        DialogHost.chooseFolder
    // Open a page in the browser: the release notes dialog uses it. A test gives a fake, so no
    // test opens a browser.
    @ObservationIgnored package var openURL: @MainActor (URL) -> Void = {
        _ = NSWorkspace.shared.open($0)
    }
    // The first responder of the window before the dialog opened.
    @ObservationIgnored private weak var oldResponder: NSResponder?
    // The overlay. The app gives it to the canvas (CanvasView.dialogLayer).
    @ObservationIgnored package private(set) lazy var view = DialogLayerView(host: self)

    package init(look: PanelLook, clock: any Clock<Duration>) {
        self.look = look
        self.clock = clock
    }

    // A host that goes away with a confirmation that shows gives false to it.
    isolated deinit {
        if case .confirm(let model) = dialog { model.cancel() }
    }

    package var isOpen: Bool { dialog != nil }

    // Ask with the texts. True only after a click on the confirm button. False when the user
    // cancelled, or at once when another dialog shows (then onBusy runs). openFolder is the action
    // of the Open worktree button, which shows only when the texts have a folder. The dialog stays
    // open after it.
    package func confirm(
        _ text: ConfirmText, openFolder: (() -> Void)?, onBusy: () -> Void
    ) async -> Bool {
        guard dialog == nil else {
            onBusy()
            return false
        }
        return await withCheckedContinuation { continuation in
            let model = ConfirmDialogModel(
                text: text, openFolder: openFolder, clock: clock
            ) { [weak self] model, confirmed in
                self?.close(model)
                continuation.resume(returning: confirmed)
            }
            open(.confirm(model))
        }
    }

    // Open the Rename dialog of the row. The dialog reads the row by its ID at each step.
    package func rename(_ row: SessionRow, runner: ActionRunner) {
        guard dialog == nil else { return runner.dialogBusy() }
        let model = RenameDialogModel(
            sessionId: row.sessionId, name: row.name, runner: runner,
            holdFocus: { [weak self] in self?.holdFocus() },
            close: { [weak self] in self?.close($0) })
        open(.rename(model))
    }

    // Open the New session dialog with new values.
    package func newSession(runner: ActionRunner) {
        guard dialog == nil else { return runner.dialogBusy() }
        let model = NewSessionDialogModel(
            runner: runner, clock: clock,
            pickFolder: { [weak self] start in
                guard let self else { return nil }
                return await self.pickFolder(self.view.window, start)
            },
            holdFocus: { [weak self] in self?.holdFocus() },
            close: { [weak self] in self?.close($0) })
        model.fieldEditor = { [weak self] in self?.view.window?.firstResponder as? NSTextView }
        open(.newSession(model))
    }

    // Show the Setup dialog of the model. False when another dialog shows: then nothing opens.
    // The dialog closes when its Skip or Done closes the model.
    package func setup(_ model: SetupDialogModel) -> Bool {
        guard dialog == nil, !model.isClosed else { return false }
        model.onClose = { [weak self] in self?.close($0) }
        open(.setup(model))
        return true
    }

    // Show the release notes dialog for the view. It starts the load of the list. False when
    // another dialog shows: then nothing opens.
    package func releaseNotes(_ view: ReleaseNotesView, source: ReleaseNotesSource) -> Bool {
        guard dialog == nil else { return false }
        let model = ReleaseNotesDialogModel(
            view: view, source: source, openURL: { [weak self] in self?.openURL($0) })
        model.onClose = { [weak self] in self?.close($0) }
        model.start()
        open(.releaseNotes(model))
        return true
    }

    // Esc: the dialog cancels. The Setup dialog stays.
    package func escape() {
        switch dialog {
        case .confirm(let model): model.cancel()
        case .rename(let model): model.cancel()
        case .newSession(let model): model.cancel()
        case .releaseNotes(let model): model.close()
        case .setup, nil: break
        }
    }

    // A click on the backdrop closes Rename, New session and the release notes. A confirmation
    // and the Setup dialog stay.
    package func backdropClick() {
        switch dialog {
        case .rename(let model): model.cancel()
        case .newSession(let model): model.cancel()
        case .releaseNotes(let model): model.close()
        case .confirm, .setup, nil: break
        }
    }

    // A save or a start begins: the focus must stay in the overlay while the fields are off. The
    // focus holder of the overlay takes it (DialogLayerView.focusHolder).
    func holdFocus() {
        guard let window = view.window, !view.holdsFocus(of: window) else { return }
        window.makeFirstResponder(view.focusHolder)
    }

    // A Bifrost menu of the window closes first, so it does not stay over the dialog. Its close
    // gives the focus back to its old first responder before the dialog reads the first responder
    // of the window.
    private func open(_ next: Dialog) {
        let window = view.window
        (window as? BifrostWindow)?.openMenu?.close()
        dialog = next
        view.isHidden = false
        view.cursorRectsChanged()
        guard let window else { return }
        oldResponder = window.firstResponder
        (window as? BifrostWindow)?.openDialog = view
        window.makeFirstResponder(view)
    }

    // Close the dialog of the model, when it still shows. The old first responder gets the key
    // focus back when the focus is still in the overlay, or when the window itself has it.
    private func close(_ model: AnyObject) {
        guard let dialog, dialog.model === model else { return }
        self.dialog = nil
        let window = view.window
        let focusInLayer = window.map { view.holdsFocus(of: $0) } ?? false
        (window as? BifrostWindow)?.openDialog = nil
        view.isHidden = true
        view.cursorRectsChanged()
        let old = oldResponder
        oldResponder = nil
        guard let window else { return }
        let windowHasFocus = window.firstResponder === window || window.firstResponder == nil
        guard focusInLayer || windowHasFocus else { return }
        if let old = old as? NSView, old.window === window, !old.isHiddenOrHasHiddenAncestor {
            window.makeFirstResponder(old)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    // The system panel that chooses a folder, on the window. It shows the folder of the form
    // when that is an absolute path, else the folder that the panel chooses. It can make a new
    // folder.
    package static func chooseFolder(_ window: NSWindow?, _ start: String?) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let start, start.unicodeScalars.first == "/" {
            panel.directoryURL = URL(filePath: start, directoryHint: .isDirectory)
        }
        let response =
            if let window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        return response == .OK ? panel.url?.path : nil
    }
}

// The overlay of the dialogs over the canvas. It covers the canvas, has the dialog mark, and
// takes the key focus while a dialog shows. Esc cancels the dialog, also when a field of the
// dialog has the focus (cancelOperation comes up the responder chain).
package final class DialogLayerView: NSHostingView<DialogLayer> {
    private(set) weak var host: DialogHost?
    // The view that holds the key focus in the overlay while no field of the dialog has it: when
    // a save or the checks of a start turn the fields off, and when the window keeps the focus in
    // the overlay (BifrostWindow.makeFirstResponder). It is not the overlay itself. While the
    // overlay is the first responder, the focus state of the last field with the focus stays
    // true in SwiftUI. Then the request for the focus after a failed save changes no value, and
    // the field does not get the focus. While the holder has the focus, SwiftUI sets that focus
    // state to false. A key at the holder goes up the responder chain to the overlay.
    let focusHolder = DialogFocusHolder()

    package convenience init(host: DialogHost) {
        self.init(rootView: DialogLayer(ref: DialogHostRef(host)))
        self.host = host
        // The canvas gives the overlay its size. The content never sizes the overlay.
        sizingOptions = []
        identifier = FocusMark.modal
        isHidden = true
        autoresizingMask = [.width, .height]
        addSubview(focusHolder)
    }

    override package var acceptsFirstResponder: Bool { true }

    override package func keyDown(with event: NSEvent) {
        if KeyCode(rawValue: event.keyCode) == KeyCode(.escape) {
            host?.escape()
            return
        }
        super.keyDown(with: event)
    }

    override package func cancelOperation(_ sender: Any?) {
        host?.escape()
    }

    // The overlay owns the cursor of its whole area: the arrow. A chat terminal under the overlay
    // sets the I-beam for its own area, and the cursor rects of a view do not depend on the
    // views over it. A text field of a dialog is a subview, so its own I-beam rect stays.
    override package func resetCursorRects() {
        super.resetCursorRects()
        if let arrowRect { addCursorRect(arrowRect, cursor: .arrow) }
    }

    // The cursor rects are made again after a change of the size, and when a dialog opens or
    // closes.
    override package func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cursorRectsChanged()
    }

    // Ask the window to make the cursor rects of the overlay again.
    func cursorRectsChanged() {
        window?.invalidateCursorRects(for: self)
    }

    // The area with the arrow cursor: the whole overlay while a dialog shows, else none.
    var arrowRect: CGRect? {
        isHidden || bounds.isEmpty ? nil : bounds
    }

    // True when the first responder of the window is the overlay, a view in it, or the field
    // editor of a field in it.
    func holdsFocus(of window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return holds(responder)
    }

    // True when the responder can have the focus while the dialog shows: the overlay, a view in
    // it, or a field editor of a field in it. The field editor of the window with no delegate yet
    // counts too, because a field of the overlay gets it during the change of the focus.
    func keeps(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        if let editor = view as? NSText, editor.delegate == nil,
            editor === window?.fieldEditor(false, for: nil)
        {
            return true
        }
        return holds(view)
    }

    private func holds(_ view: NSView) -> Bool {
        if view === self || view.isDescendant(of: self) { return true }
        let field = (view as? NSText)?.delegate as? NSView
        return field?.isDescendant(of: self) ?? false
    }
}

// The holder of the key focus in the overlay (DialogLayerView.focusHolder). It has no size and
// draws nothing.
final class DialogFocusHolder: NSView {
    override var acceptsFirstResponder: Bool { true }
}

// The host of the overlay, as a weak reference: the host owns the overlay.
@MainActor
package final class DialogHostRef {
    weak var host: DialogHost?

    init(_ host: DialogHost) {
        self.host = host
    }
}

// The backdrop and the box of the dialog that shows: the background colour at 40 % over the
// canvas, and the box in its centre. The box is 420 units wide (440 for New session and the
// Setup dialog, 560 for the release notes), and 16 units narrower than the canvas on each side
// when the canvas is narrow.
package struct DialogLayer: View {
    let ref: DialogHostRef

    package var body: some View {
        if let host = ref.host, let dialog = host.dialog {
            let style = PanelStyle(look: host.look)
            GeometryReader { proxy in
                ZStack {
                    ThemeTokens.bg.opacity(0.4).color
                        .contentShape(Rectangle())
                        .onTapGesture { host.backdropClick() }
                        .accessibilityHidden(true)
                    let room = proxy.size.width - style.points(32)
                    box(dialog, style)
                        .frame(width: max(0, min(width(dialog, style), room)))
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                // Esc in a field of the dialog comes as the cancel action of SwiftUI.
                .onExitCommand { host.escape() }
            }
            .font(style.font(13))
            .foregroundStyle(ThemeTokens.text.color)
        }
    }

    @ViewBuilder
    private func box(_ dialog: DialogHost.Dialog, _ style: PanelStyle) -> some View {
        Group {
            switch dialog {
            case .confirm(let model): ConfirmDialogView(model: model, style: style)
            case .rename(let model): RenameDialogView(model: model, style: style)
            case .newSession(let model): NewSessionDialogView(model: model, style: style)
            case .setup(let model): SetupDialogView(model: model, style: style)
            case .releaseNotes(let model): ReleaseNotesDialogView(model: model, style: style)
            }
        }
        .padding(style.points(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeTokens.title.color)
        .overlay {
            Rectangle().strokeBorder(style.edge, lineWidth: style.points(1))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func width(_ dialog: DialogHost.Dialog, _ style: PanelStyle) -> CGFloat {
        switch dialog {
        case .releaseNotes: style.points(560)
        case .newSession, .setup: style.points(440)
        case .confirm, .rename: style.points(420)
        }
    }
}

// The look of the parts of a dialog, at the Interface scale and the Panel transparency.
extension PanelStyle {
    init(look: PanelLook) {
        self.init(metrics: look.metrics, transparency: look.panelTransparency)
    }
}

// The title of a dialog: the strong text colour, semibold.
struct DialogTitle: View {
    let text: String
    let style: PanelStyle

    var body: some View {
        Text(text)
            .font(style.font(13, weight: .semibold))
            .foregroundStyle(ThemeTokens.textStrong.color)
            .accessibilityAddTraits(.isHeader)
    }
}

// A text field of a dialog: the background colour, a border of the edge colour, and a lighter
// border while it has the focus.
struct DialogFieldStyle: ViewModifier {
    let style: PanelStyle
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, style.points(8))
            .padding(.vertical, style.points(4))
            .background(ThemeTokens.bg.color)
            .overlay {
                Rectangle()
                    .strokeBorder(
                        focused ? style.focusEdge : style.edge, lineWidth: style.points(1))
                    .accessibilityHidden(true)
            }
    }
}

// A small line of a dialog: a reason or a note, in the dim colour or in the text colour.
struct DialogNote: View {
    let text: String
    let style: PanelStyle
    var dim = true

    var body: some View {
        Text(text)
            .font(style.font(12))
            .foregroundStyle(dim ? style.dim : ThemeTokens.text.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
