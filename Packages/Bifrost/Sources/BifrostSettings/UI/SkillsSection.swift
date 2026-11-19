// Settings > Skills (docs/behaviour/skills.md, "Settings > Skills"): the state line, the buttons,
// the steps before Install, the reload note after a change, the error of the last action, and the
// skills of the app with their group labels. The values come from the live model
// (SettingsModel.live), and each button acts through it. Remove asks first with the confirm
// dialog of the window, and with no confirm dialog Remove is off. One plugin change runs at a
// time, so the buttons are also off while Live details is busy.
//
// The section reads its status one time for each open of Settings when it shows
// (LiveModel.readOnce(_:)). When it goes away, its error and its steps go.
import BifrostLive
import BifrostLook
import SwiftUI

package struct SkillsSection: View {
    let model: SettingsModel

    package init(model: SettingsModel) {
        self.model = model
    }

    private var live: LiveModel { model.live }

    // MARK: - What the section shows

    package var content: PluginContent {
        let notice = live.skillsNotice
        let state = live.skillsState
        let steps = state.showsSteps && notice == .notInstalled ? SkillsNotice.steps : nil
        return PluginContent(
            stateLine: notice.stateLine,
            without: notice == .notInstalled ? SkillsNotice.withoutSkills : nil, steps: steps,
            buttons: steps == nil ? SkillsNotice.actions(live.skillsStatus) : [],
            notes: state.changed ? [LiveTexts.reloadNote] : [], error: state.error)
    }

    // The skills of the app, in the order of the status (by name). Empty before the first read.
    package var skills: [SkillInfo] { live.skillsStatus?.skills ?? [] }

    // The hint above the list, or nil with no skill.
    package var groupHint: String? { skills.isEmpty ? nil : SkillsNotice.groupHint }

    // MARK: - The actions

    @discardableResult
    package func press(_ id: LiveActionID) -> Task<Void, Never> {
        PluginBlock.press(model, .skills, id)
    }

    @discardableResult
    package func install() -> Task<Void, Never> {
        PluginBlock.install(model, .skills)
    }

    package func cancelInstall() {
        PluginBlock.cancelInstall(model, .skills)
    }

    // MARK: - The view

    package var body: some View {
        let style = PanelStyle(model)
        VStack(alignment: .leading, spacing: 0) {
            PluginBlock(model: model, part: .skills, content: content)
            ErrorLine(model: model, message: content.error) { live.closeError(.skills) }
            if let groupHint {
                VStack(alignment: .leading, spacing: style.points(8)) {
                    Text(groupHint)
                        .foregroundStyle(style.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    ForEach(skills, id: \.name) { skill in
                        SkillRow(skill: skill, style: style)
                    }
                }
                .padding(.horizontal, style.points(12))
                .padding(.vertical, style.points(8))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { live.readOnce(.skills) }
        .onDisappear { live.sectionHidden(.skills) }
    }
}

// One skill of the list: its name as the user types it, its group label, and its description.
// A listed skill has its label in the text colour, a skill called by name in the dim colour.
private struct SkillRow: View {
    let skill: SkillInfo
    let style: PanelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(2)) {
            HStack(alignment: .firstTextBaseline, spacing: style.points(8)) {
                Text("/\(skill.name)")
                    .fontWeight(.medium)
                    .foregroundStyle(ThemeTokens.textStrong.color)
                    .textSelection(.enabled)
                Text(SkillsNotice.groupLabel(skill.group))
                    .foregroundStyle(skill.group == .listed ? ThemeTokens.text.color : style.dim)
            }
            Text(skill.description)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
