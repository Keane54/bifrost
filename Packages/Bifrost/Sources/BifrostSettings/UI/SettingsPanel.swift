// The body of the Settings panel (docs/behaviour/settings.md): the search field, the tabs, the
// section or the search results in a scroll area, and the footer with the Save button. It is
// SwiftUI in one NSHostingView (SettingsHost). The look follows the panel of the Electron app:
// the UI font at 12, the stack tab style of the frame, and the edge colour between the parts
// (row S3 of docs/ports/settings).
import AppKit
import BifrostKeyboard
import BifrostLook
import SwiftUI

package struct SettingsPanel: View {
    let model: SettingsModel

    package init(model: SettingsModel) {
        self.model = model
    }

    // The tabs, in the order of the sections.
    package static let tabs = SettingsSection.allCases

    package var body: some View {
        let style = PanelStyle(model)
        VStack(spacing: 0) {
            searchBar(style)
            line(style)
            tabBar(style)
            line(style)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) { content(style) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            line(style)
            footer(style)
        }
        .font(style.font)
        .foregroundStyle(ThemeTokens.text.color)
    }

    // MARK: - The parts

    // The search field above the tabs. Esc clears it, then closes Settings. It is off while Save
    // runs.
    private func searchBar(_ style: PanelStyle) -> some View {
        HStack(spacing: style.points(6)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: style.points(10)))
                .foregroundStyle(style.dim)
                .accessibilityHidden(true)
            SettingsTextField(
                text: { model.query }, label: "Search settings", placeholder: "Search settings",
                identifier: SettingsHost.searchField, enabled: !model.isSaving,
                font: style.nsFont, onChange: { model.query = $0 }, onEnter: {},
                onEscape: { composing in model.escapeInSearch(composing: composing) }
            )
            .fieldLook(style, width: nil)
        }
        .padding(.horizontal, style.points(12))
        .padding(.vertical, style.points(6))
    }

    // The tabs. During a search no tab is active, and a click on a tab ends the search. The tabs
    // are off while Save runs. The Live details tab shows the dot of the side bar Settings button
    // while Live details or Claude Code has a warning.
    private func tabBar(_ style: PanelStyle) -> some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs, id: \.self) { section in
                Button {
                    model.showTab(section)
                } label: {
                    HStack(spacing: style.points(4)) {
                        Text(section.title)
                        if Self.showsDot(section, model) {
                            Rectangle().fill(ThemeTokens.textStrong.color)
                                .frame(width: style.points(6), height: style.points(6))
                                .accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(StackTabStyle(style: style, active: model.activeTab == section))
                .disabled(model.isSaving)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(model.activeTab == section ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .frame(height: style.points(22))
    }

    // True when the tab of the section shows the warning dot.
    package static func showsDot(_ section: SettingsSection, _ model: SettingsModel) -> Bool {
        section == .live && model.live.warning
    }

    // The section of the active tab, or the matches of each section under its title, or the
    // line that tells that nothing matches.
    @ViewBuilder
    private func content(_ style: PanelStyle) -> some View {
        switch model.content {
        case .section(let section):
            SectionBody(model: model, section: section, hit: nil)
        case .hits(let hits):
            ForEach(hits, id: \.id) { hit in
                Text(hit.title)
                    .foregroundStyle(ThemeTokens.textStrong.color)
                    .padding(.horizontal, style.points(12))
                    .padding(.vertical, style.points(4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ThemeTokens.title.color)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(style.edge).frame(height: style.points(1))
                    }
                    .accessibilityAddTraits(.isHeader)
                SectionBody(model: model, section: hit.id, hit: hit)
            }
        case .noMatch(let text):
            Text(text)
                .foregroundStyle(style.dim)
                .padding(.horizontal, style.points(12))
                .padding(.vertical, style.points(8))
        }
    }

    // The footer with the Save button. The button is off while Save runs and while a dialog
    // shows.
    private func footer(_ style: PanelStyle) -> some View {
        HStack {
            Spacer(minLength: 0)
            Button("Save") { Task { await model.saveAndClose() } }
                .buttonStyle(DialogButtonStyle(style: style))
                .disabled(model.isSaving || model.links.dialogShows())
        }
        .padding(.horizontal, style.points(12))
        .padding(.vertical, style.points(6))
    }

    private func line(_ style: PanelStyle) -> some View {
        Rectangle().fill(style.edge).frame(height: style.points(1)).accessibilityHidden(true)
    }
}

// The rows of one section. hit is the match of the section during a search. A section that a
// later build fills shows the later text. Live details and Skills are one search row each, so a
// hit always shows the whole section.
package struct SectionBody: View {
    let model: SettingsModel
    let section: SettingsSection
    let hit: SearchHit?

    package init(model: SettingsModel, section: SettingsSection, hit: SearchHit?) {
        self.model = model
        self.section = section
        self.hit = hit
    }

    package var body: some View {
        switch section {
        case .general: GeneralSection(model: model)
        case .slash: SlashSection(model: model, hit: hit)
        case .keys: KeysSection(model: model, hit: hit)
        case .live: LiveSection(model: model)
        case .skills: SkillsSection(model: model)
        case .reviews: ReviewsSection(model: model)
        case .updates: UpdatesSection(model: model)
        case .dailyUpdate: DailyUpdateSection(model: model)
        case .modules: LaterSection(model: model)
        }
    }
}

// MARK: - The host

// The host of the Settings panel. It has the control mark, so a focused SwiftUI control of the
// panel is in the control zone of the key rules. AppKit offers each key equivalent to the views
// of the key window before the menu, so the host gets Cmd+F there and moves the focus to the
// search field (SettingsModel.isSearchShortcut). While the key recorder records, it keeps each
// key, Cmd+F too.
//
// The host takes the focus for the panel: a click on a part with no control gives it the focus,
// so Cmd+F works there. A change can remove the view of the panel that has the focus, for example
// a text field in a row that a search or a tab change hides. AppKit then gives the focus to the
// window, where the single keys act. So after that change the host gives the focus to the search
// field during a search, else to the panel (focusLeft(_:)).
package final class SettingsHost: NSHostingView<SettingsPanel> {
    // The identifier of the search field.
    package static let searchField = NSUserInterfaceItemIdentifier("bifrost.settings-search")

    // A check of the focus after a change. The view that lost the focus is weak, so a removed
    // view can go before the check.
    private struct FocusCheck {
        weak var view: NSView?
    }

    // The check that waits to run after the change, or nil.
    private var focusCheck: FocusCheck?

    package convenience init(model: SettingsModel) {
        self.init(rootView: SettingsPanel(model: model))
        identifier = FocusMark.control
        sizingOptions = []
    }

    override package var acceptsFirstResponder: Bool { true }

    // Tab does not stop on the host. The host takes the focus only from a click or from
    // focusLeft(_:).
    override package var canBecomeKeyView: Bool { false }

    // A view of the panel lost the focus. The check runs in a task of the main actor, after the
    // change: when the focus fell to the window and the view is out of the window, a
    // change removed the view, and the focus goes to the search field during a search, else to
    // the panel. A focus that went to another view, a view that stays, and a panel that left the
    // window need no help.
    //
    // The check cannot run in makeFirstResponder of the window: AppKit calls makeFirstResponder
    // when a focused text field leaves the window or hides, but not when another focused view
    // leaves the window (for example the key recorder), and SwiftUI removes the views during
    // its update of the panel, where a new first responder must not come yet.
    package func focusLeft(_ view: NSView) {
        if focusCheck == nil {
            Task { @MainActor [weak self] in self?.takeFallenFocus() }
        }
        focusCheck = FocusCheck(view: view)
    }

    // The host of the panel that holds the view, or nil: the first SettingsHost above the view,
    // as enclosingScrollView finds a scroll view.
    package static func holding(_ view: NSView) -> SettingsHost? {
        sequence(first: view, next: \.superview).dropFirst().lazy.compactMap { $0 as? SettingsHost }
            .first
    }

    // The search field, after SwiftUI made it and it joined the window. The field tells the host
    // itself (SettingsField).
    package private(set) weak var searchFieldView: NSTextField?

    // The search field of the panel joined the window.
    func searchFieldJoined(_ field: NSTextField) {
        searchFieldView = field
    }

    // True while a check of the focus waits.
    package var isCheckingFocus: Bool { focusCheck != nil }

    private func takeFallenFocus() {
        let view = focusCheck?.view
        focusCheck = nil
        guard let window, window.firstResponder === window, view?.window !== window else {
            return
        }
        if rootView.model.hits != nil {
            focusSearch()
        } else {
            window.makeFirstResponder(self)
        }
    }

    override package func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let window, !Self.isRecording(window.firstResponder),
            let key = KeyEvent(event, isComposing: Self.isComposing(window.firstResponder)),
            rootView.model.isSearchShortcut(key, focus: focusPlace())
        {
            focusSearch()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // The place of the focus for Cmd+F: in this panel, nowhere (the window has the focus), or
    // in another view.
    package func focusPlace() -> SearchFocus {
        guard let responder = window?.firstResponder, responder !== window else { return .none }
        guard let view = responder as? NSView else { return .other }
        return view.isDescendant(of: self) ? .settings : .other
    }

    // Move the focus to the search field, with the caret at the end of its text. A field that
    // edits already keeps its selection.
    package func focusSearch() {
        guard let window, let field = searchFieldView else { return }
        if (window.firstResponder as? NSText)?.delegate === field { return }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() else { return }
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    }

    // End the edit of the text field of this panel that has the focus, as a blur does. The end
    // of the edit saves the text of the field before this call returns.
    package func endEditing() {
        guard let window, let text = window.firstResponder as? NSText, text.isDescendant(of: self)
        else { return }
        window.makeFirstResponder(nil)
    }

    private static func isComposing(_ responder: NSResponder?) -> Bool {
        (responder as? any NSTextInputClient)?.hasMarkedText() ?? false
    }

    private static func isRecording(_ responder: NSResponder?) -> Bool {
        (responder as? KeyRecorderView)?.isRecording ?? false
    }
}
