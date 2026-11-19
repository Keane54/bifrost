// The Work areas row of Settings > Daily update (docs/behaviour/daily-update.md, "Settings > Daily
// update"): one box for each work area with On, the name, the channel, Remove, "Which work goes
// here" and "Takes all other work". Add work area adds an area with a free name ("Work area 2"),
// which the user then changes, so each area in the settings file has a name. Each change saves
// through the section (DailyUpdateSection.commit), so a refusal shows on the row: an empty name,
// a text over its limit, an eleventh area, or a second area that takes all other work. Remove
// asks first when the panel has the confirm dialog.
import BifrostDailyUpdate
import BifrostLook
import Foundation
import SwiftUI

extension DailyUpdateSection {
    // Add a new area at the end. At most DailySettings.maxAreas.
    @discardableResult
    package func addArea(id: String = UUID().uuidString) -> Task<Bool, Never>? {
        commit(.areas) { settings in
            settings.areas.append(DailyUpdateRows.newArea(after: settings.areas, id: id))
        }
    }

    // Remove the area. With the confirm dialog of the window, the user confirms first. The
    // task gives true when the area went.
    @discardableResult
    package func removeArea(_ id: String) -> Task<Bool, Never> {
        let confirm = model.links.confirm
        let area = daily.areas.first { $0.id == id }
        return Task {
            guard let area else { return false }
            if let confirm, !(await confirm(DailyUpdateRows.removeText(area))) { return false }
            guard let saving = commit(.areas, { $0.areas.removeAll { $0.id == id } }) else {
                return false
            }
            return await saving.value
        }
    }

    @discardableResult
    package func set(area id: String, on: Bool) -> Task<Bool, Never>? {
        commit(.areas) { settings in
            if let index = settings.areas.firstIndex(where: { $0.id == id }) {
                settings.areas[index].on = on
            }
        }
    }

    // Give the flag "takes all other work" to the area, or take it away. A second area with the
    // flag is refused.
    @discardableResult
    package func set(area id: String, takesRest on: Bool) -> Task<Bool, Never>? {
        if case .failure(let refusal) = DailyUpdateRows.settingTakesRest(daily.areas, id, on: on) {
            model.refuse(self.id(.areas), reason: refusal.message)
            return nil
        }
        return commit(.areas) { settings in
            if case .success(let areas) = DailyUpdateRows.settingTakesRest(
                settings.areas, id, on: on)
            {
                settings.areas = areas
            }
        }
    }

    // What a text field of an area saves.
    package func saveArea(
        _ id: String, _ field: WritableKeyPath<WorkArea, String>, _ text: String
    ) -> TextSave {
        textSave { settings in
            if let index = settings.areas.firstIndex(where: { $0.id == id }) {
                settings.areas[index][keyPath: field] = text
            }
        }
    }
}

struct WorkAreaEditor: View {
    let section: DailyUpdateSection
    let style: PanelStyle

    private var model: SettingsModel { section.model }

    var body: some View {
        let areas = section.daily.areas
        let row = section.id(.areas)
        SettingRow(model: model, row: row, label: DailyUpdateRow.areas.rawValue) {
            Button(DailyUpdateRows.addAreaButton) { section.addArea() }
                .buttonStyle(DialogButtonStyle(style: style))
                .disabled(!section.canAddArea)
        } detail: {
            VStack(alignment: .leading, spacing: style.points(8)) {
                ForEach(areas) { area in
                    AreaBox(section: section, area: area, style: style)
                }
            }
            .padding(.horizontal, style.points(12))
            .padding(.bottom, areas.isEmpty ? 0 : style.points(8))
        }
    }
}

// The box of one work area.
private struct AreaBox: View {
    let section: DailyUpdateSection
    let area: WorkArea
    let style: PanelStyle

    var body: some View {
        let model = section.model
        let row = section.id(.areas)
        let id = area.id
        VStack(alignment: .leading, spacing: style.points(6)) {
            HStack(alignment: .bottom, spacing: style.points(8)) {
                caption("On") {
                    Toggle(
                        isOn: Binding(get: { area.on }, set: { section.set(area: id, on: $0) })
                    ) {
                        Text(area.on ? "On" : "Off")
                    }
                    .toggleStyle(BifrostCheckboxStyle(metrics: style.metrics))
                    .fixedSize()
                }
                caption(DailyUpdateRows.nameLabel) {
                    DraftField(
                        model: model, row: row, label: DailyUpdateRows.nameLabel, saved: area.name,
                        width: 150, keepOnRefusal: true
                    ) { section.saveArea(id, \.name, $0) }
                }
                caption(DailyUpdateRows.channelLabel) {
                    DraftField(
                        model: model, row: row, label: DailyUpdateRows.channelLabel,
                        saved: area.channel, width: 150, keepOnRefusal: true
                    ) { section.saveArea(id, \.channel, $0) }
                }
                Spacer(minLength: 0)
                Button(DailyUpdateRows.removeButton) { section.removeArea(id) }
                    .buttonStyle(DialogButtonStyle(style: style))
            }
            Text(DailyUpdateRows.descriptionLabel).foregroundStyle(style.dim)
            DraftArea(model: model, row: row, saved: area.description, lines: 2) {
                section.saveArea(id, \.description, $0)
            }
            Toggle(
                isOn: Binding(
                    get: { area.takesRest }, set: { section.set(area: id, takesRest: $0) })
            ) {
                Text(DailyUpdateRows.takesRestLabel)
            }
            .toggleStyle(BifrostCheckboxStyle(metrics: style.metrics))
        }
        .padding(style.points(8))
        .overlay {
            Rectangle().strokeBorder(style.edge, lineWidth: style.points(1))
                .accessibilityHidden(true)
        }
    }

    // A small dim caption above a control.
    private func caption<Content: View>(
        _ text: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: style.points(2)) {
            Text(text).foregroundStyle(style.dim)
            content()
        }
    }
}
