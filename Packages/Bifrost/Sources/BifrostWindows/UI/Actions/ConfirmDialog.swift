// The confirmation dialog of Stop, Delete, Take control and Reset all keys
// (docs/behaviour/actions.md, "Confirmations"): the title, the body, the Open worktree button when
// the texts have a folder, Cancel and the confirm button. A dialog with confirmAgain asks twice
// (Confirm.step): the first click changes the label, and only a click againWait or more later
// confirms. Esc and Cancel give false. A click on the backdrop does nothing.
import AppKit
import BifrostFoundation
import BifrostLook
import BifrostSessions
import Observation
import SwiftUI

@MainActor
@Observable
package final class ConfirmDialogModel {
    package let text: ConfirmText
    // The step of the confirm button.
    package private(set) var step = ConfirmStep.first
    @ObservationIgnored private let openFolderAction: (() -> Void)?
    @ObservationIgnored private let timeline: Timeline
    // The time of the change to the confirmAgain label.
    @ObservationIgnored private var againAt = Duration.zero
    // The end of the request. nil after the end, so the request ends one time.
    @ObservationIgnored private var finish: ((ConfirmDialogModel, Bool) -> Void)?

    init(
        text: ConfirmText, openFolder: (() -> Void)?, clock: any Clock<Duration>,
        finish: @escaping (ConfirmDialogModel, Bool) -> Void
    ) {
        self.text = text
        openFolderAction = openFolder
        timeline = Timeline(clock)
        self.finish = finish
    }

    // The label of the confirm button now.
    package var confirmLabel: String { Confirm.label(step, text) }

    // True when the dialog shows the Open worktree button.
    package var showsOpenFolder: Bool { text.openFolder != nil && openFolderAction != nil }

    // A press of the confirm button. clickCount is the count of the click: the second half of a
    // double click does not count as the second click. isRepeat is true for a key that the user
    // holds: only the first key down of a press counts.
    package func pressConfirm(clickCount: Int = 1, isRepeat: Bool = false) {
        guard finish != nil, !isRepeat else { return }
        if step == .again && clickCount > 1 { return }
        let result = Confirm.step(step, text, sinceAgain: timeline.now() - againAt)
        if result.resolve { return resolve(true) }
        // A click that comes too soon in the step again changes nothing. The wait does not start
        // again.
        if step == .first {
            againAt = timeline.now()
            step = .again
        }
    }

    // The Open worktree button. The dialog stays open.
    package func openFolder() {
        guard finish != nil else { return }
        openFolderAction?()
    }

    // Cancel and Esc.
    package func cancel() {
        resolve(false)
    }

    private func resolve(_ confirmed: Bool) {
        guard let finish else { return }
        self.finish = nil
        finish(self, confirmed)
    }
}

struct ConfirmDialogView: View {
    let model: ConfirmDialogModel
    let style: PanelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(12)) {
            DialogTitle(text: model.text.title, style: style)
            Text(model.text.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: style.points(8)) {
                if model.showsOpenFolder {
                    Button("Open worktree") { model.openFolder() }
                        .buttonStyle(DialogButtonStyle(style: style))
                }
                Spacer(minLength: 0)
                Button("Cancel") { model.cancel() }
                    .buttonStyle(DialogButtonStyle(style: style))
                Button(model.confirmLabel) { press() }
                    .buttonStyle(DialogButtonStyle(style: style, strong: model.step == .again))
            }
        }
        .accessibilityLabel(model.text.title)
    }

    // The event of the press gives the click count, or the repeat of a held key.
    private func press() {
        let event = NSApp.currentEvent
        switch event?.type {
        case .leftMouseUp?, .leftMouseDown?:
            model.pressConfirm(clickCount: event?.clickCount ?? 1)
        case .keyDown?:
            model.pressConfirm(isRepeat: event?.isARepeat ?? false)
        default:
            model.pressConfirm()
        }
    }
}
