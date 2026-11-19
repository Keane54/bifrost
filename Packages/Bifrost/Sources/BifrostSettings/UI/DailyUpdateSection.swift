// Settings > Daily update (docs/behaviour/daily-update.md, "Settings > Daily update"): the ticket
// source and its tools, you on the board, the merged PRs, the times, the days, the model, the
// format with its examples, the work areas and the open of the panel. The rows come from
// DailyUpdateRow, so the search finds each row by its label.
//
// Each change checks the whole Daily update block first (DailyUpdateRows.reason), so a refused
// change shows its own reason on its row and saves nothing. A change that passes saves through
// the model on the newest settings (SettingsModel.save).
//
// The ticket source picker lists the servers of the last read (Find servers). The read starts a
// short claude run, so only the button starts it. A new server saves with no tools: its
// proposed read tools wait in the tools list until the user uses them (ToolProposalDraft).
//
// When the Daily update does not run (another copy of Bifrost holds it, or the app found no
// claude), the line at the top of the section says why.
import BifrostDailyUpdate
import BifrostFoundation
import BifrostLook
import BifrostSessions
import Foundation
import Observation
import SwiftUI

// What a read of the MCP servers gave.
package enum InventoryRead: Sendable, Equatable {
    case found(MCPInventory)
    // The app has no claude to run.
    case noClaude
    // The probe ended with no list of servers.
    case failed
}

// The values and the actions of the Daily update that the section needs. The shell gives them
// (SettingsLinks.dailyUpdate). The default reads nothing and opens nothing.
package struct DailyUpdateLinks {
    // Read the MCP servers of the Claude Code of the user. It takes up to 30 seconds.
    package var readInventory: @MainActor () async -> InventoryRead
    // Why the Daily update does not run, or nil. It reads observed values.
    package var unavailable: @MainActor () -> String?
    // Open the Daily update panel.
    package var openPanel: @MainActor () -> Void

    @MainActor
    package init(
        readInventory: @escaping @MainActor () async -> InventoryRead = { .noClaude },
        unavailable: @escaping @MainActor () -> String? = { nil },
        openPanel: @escaping @MainActor () -> Void = {}
    ) {
        self.readInventory = readInventory
        self.unavailable = unavailable
        self.openPanel = openPanel
    }
}

// The state of the section that the settings file does not keep: the servers of the last read,
// the read that runs, its failure and the proposal of the tools. The model keeps it, so it stays
// when SwiftUI makes the views of the section again.
@MainActor
@Observable
package final class DailyUpdateSectionState {
    // The servers of the last read, or nil before the first read.
    package var inventory: MCPInventory?
    // True while a read runs.
    package var reading = false
    // Why the last read failed, or nil.
    package var readError: String?
    // The read tools that wait for the confirm of the user, or nil.
    package var proposal: ToolProposalDraft?
    // The identity of each example box, in the order of the examples
    // (DailyUpdateRows.exampleItems).
    package var exampleIDs: [UUID] = []
    // The examples that the last add or remove of the section gives, while its save runs, or nil.
    // The boxes show this list, so the IDs and the examples always fit.
    package var pendingExamples: [String]?

    package init() {}

    // Give the IDs the count of the stored examples after a change from outside the section: new
    // IDs at the end, or fewer IDs from the end. While an add or a remove of the section saves,
    // the IDs already fit its list.
    package func syncExamples(_ stored: [String]) {
        guard pendingExamples == nil, exampleIDs.count != stored.count else { return }
        if exampleIDs.count < stored.count {
            exampleIDs += (exampleIDs.count..<stored.count).map { _ in UUID() }
        } else {
            exampleIDs.removeLast(exampleIDs.count - stored.count)
        }
    }
}

package struct DailyUpdateSection: View {
    let model: SettingsModel

    package init(model: SettingsModel) {
        self.model = model
    }

    // The rows, in their order.
    package static let rows = DailyUpdateRow.allCases

    private var state: DailyUpdateSectionState { model.dailyUpdate }
    private var links: DailyUpdateLinks { model.links.dailyUpdate }

    // The Daily update block of now. No block gives the defaults.
    package var daily: DailySettings { model.store.settings.dailyUpdate ?? .defaults }

    // MARK: - What the section shows

    // The line at the top: why the Daily update does not run, or nil. nil during a search.
    package var notice: String? {
        model.hits == nil ? links.unavailable() : nil
    }

    // The choices of the ticket source: no source, the saved server when the last read does not
    // list it, then each server of the last read.
    package var sourceChoices: [ServerChoice] {
        var list = [ServerChoice(name: "", label: DailyUpdateRows.noSource, enabled: true)]
        let servers = DailyUpdateRows.serverChoices(state.inventory)
        if let saved = daily.source.server, !servers.contains(where: { $0.name == saved }) {
            list.append(ServerChoice(name: saved, label: saved, enabled: true))
        }
        return list + servers
    }

    package var toolRows: [ToolRow] {
        DailyUpdateRows.toolRows(state.inventory, daily.source, proposal: currentProposal)
    }

    // The proposal of the saved server, or nil.
    package var currentProposal: ToolProposalDraft? {
        guard let proposal = state.proposal, proposal.server == daily.source.server else {
            return nil
        }
        return proposal
    }

    package var canAddExample: Bool {
        daily.format.examples.count < DailySettings.maxExamples
    }

    // The example boxes: the list that an add or a remove saves now, else the stored list.
    package var exampleItems: [ExampleItem] {
        DailyUpdateRows.exampleItems(
            state.pendingExamples ?? daily.format.examples, ids: state.exampleIDs)
    }

    package var canAddArea: Bool { daily.areas.count < DailySettings.maxAreas }

    // MARK: - The ticket source

    // Read the servers. One read runs at a time. Its failure shows on the source row until the
    // next read or a close.
    package func findServers() async {
        guard !state.reading else { return }
        state.reading = true
        state.readError = nil
        defer { state.reading = false }
        switch await links.readInventory() {
        case .found(let inventory): state.inventory = inventory
        case .noClaude: state.readError = DailyUpdateRows.noClaude
        case .failed: state.readError = DailyUpdateRows.readFailed
        }
    }

    // Choose the ticket source. A new server saves with no tools, and its proposed read tools
    // wait for the confirm. A server that is not connected is refused. nil: no change saved.
    @discardableResult
    package func choose(server name: String?) -> Task<Bool, Never>? {
        guard let name, !name.isEmpty else {
            state.proposal = nil
            guard daily.source.server != nil else { return nil }
            return commit(.source) { $0.source = DailySource() }
        }
        guard name != daily.source.server else { return nil }
        if let server = state.inventory?.server(named: name) {
            guard server.status == "connected" else {
                model.refuse(id(.source), reason: DailyUpdateRows.notConnected(server))
                return nil
            }
            state.proposal = ToolProposalDraft(
                server: name, tools: ToolProposal.proposed(server))
        } else {
            state.proposal = nil
        }
        return commit(.source) { $0.source = DailySource(server: name) }
    }

    // Tick or untick a tool. While a proposal waits, the tick changes the proposal only. A tool
    // with a write word never gets a tick.
    @discardableResult
    package func set(tool: ToolRow, on: Bool) -> Task<Bool, Never>? {
        guard !tool.write || !on else { return nil }
        if var proposal = currentProposal {
            proposal.tools = DailyUpdateRows.toggled(proposal.tools, tool.id, on: on)
            state.proposal = proposal
            return nil
        }
        let name = tool.id
        return commit(.tools) {
            $0.source.tools = DailyUpdateRows.toggled($0.source.tools, name, on: on)
        }
    }

    // Save the proposed tools. The proposal stays until the save worked.
    @discardableResult
    package func useProposedTools() -> Task<Bool, Never>? {
        guard let proposal = currentProposal else { return nil }
        let tools = proposal.tools
        guard let saving = commit(.tools, { $0.source.tools = tools }) else { return nil }
        let state = state
        return Task {
            let ok = await saving.value
            if ok, state.proposal == proposal { state.proposal = nil }
            return ok
        }
    }

    // MARK: - The other rows

    // Tick or untick a day. The last day is refused.
    @discardableResult
    package func toggle(day: Int) -> Task<Bool, Never>? {
        let on = !daily.days.contains(day)
        return commit(.days) { if on { $0.days.insert(day) } else { $0.days.remove(day) } }
    }

    @discardableResult
    package func choose(model choice: ModelChoice) -> Task<Bool, Never>? {
        commit(.model) { $0.model = choice }
    }

    // Add an empty example, with a new box. At most three.
    @discardableResult
    package func addExample() -> Task<Bool, Never>? {
        state.syncExamples(daily.format.examples)
        let list = state.pendingExamples ?? daily.format.examples
        guard let saving = commit(.examples, { $0.format.examples.append("") }) else {
            return nil
        }
        return track(saving, ids: state.exampleIDs + [UUID()], examples: list + [""])
    }

    // Remove the example and its box, with the text that the box kept. The edit of an open field
    // ends first, so its text saves at its own example.
    @discardableResult
    package func removeExample(at index: Int) -> Task<Bool, Never>? {
        model.endEditing()
        state.syncExamples(daily.format.examples)
        var list = state.pendingExamples ?? daily.format.examples
        guard list.indices.contains(index), state.exampleIDs.indices.contains(index) else {
            return nil
        }
        let removal = commit(.examples) { settings in
            if settings.format.examples.indices.contains(index) {
                settings.format.examples.remove(at: index)
            }
        }
        guard let removal else { return nil }
        var ids = state.exampleIDs
        ids.remove(at: index)
        list.remove(at: index)
        return track(removal, ids: ids, examples: list)
    }

    // Show the add or the remove at once, with the IDs that fit it, while its save runs. A failed
    // save puts the old IDs back.
    private func track(
        _ saving: Task<Bool, Never>, ids: [UUID], examples: [String]
    ) -> Task<Bool, Never> {
        let state = state
        let old = state.exampleIDs
        state.exampleIDs = ids
        state.pendingExamples = examples
        return Task {
            let ok = await saving.value
            if state.pendingExamples == examples { state.pendingExamples = nil }
            if !ok, state.exampleIDs == ids { state.exampleIDs = old }
            return ok
        }
    }

    // What the text of each text row saves.
    package func saveYou(_ text: String) -> TextSave { textSave { $0.you = text } }

    package func saveTime(_ text: String, deadline: Bool) -> TextSave {
        guard let time = ClockTime(text) else { return .refused(DailyUpdateRows.timeReason) }
        return textSave { if deadline { $0.deadline = time } else { $0.draftTime = time } }
    }

    package func saveTemplate(_ text: String) -> TextSave {
        textSave { $0.format.template = text }
    }

    package func saveExample(_ text: String, at index: Int) -> TextSave {
        guard daily.format.examples.indices.contains(index) else {
            return .refused(DailyUpdateRows.examplesReason)
        }
        return textSave { settings in
            if settings.format.examples.indices.contains(index) {
                settings.format.examples[index] = text
            }
        }
    }

    package func openPanel() { links.openPanel() }

    // MARK: - The saves

    // The ID of a row: the search finds it by its label.
    package func id(_ row: DailyUpdateRow) -> SettingsRowID {
        SettingsRowID(.dailyUpdate, .found(row.rawValue))
    }

    // Check the change on the block of now, then save it on the newest settings. A refused
    // change shows its reason on the row. nil: refused.
    @discardableResult
    func commit(
        _ row: DailyUpdateRow, _ edit: @escaping (inout DailySettings) -> Void
    ) -> Task<Bool, Never>? {
        var next = daily
        edit(&next)
        if let reason = DailyUpdateRows.reason(next) {
            model.refuse(id(row), reason: reason)
            return nil
        }
        return model.save(id(row)) { Self.change(&$0, edit) }
    }

    // The one edit of the Daily update block of the settings: the edit on the block, or on the
    // defaults when the file has no block.
    static func change(_ settings: inout Settings, _ edit: (inout DailySettings) -> Void) {
        var value = settings.dailyUpdate ?? .defaults
        edit(&value)
        settings.dailyUpdate = value
    }

    // What a text saves: the edit on the newest settings, or the reason of the check.
    func textSave(_ edit: @escaping (inout DailySettings) -> Void) -> TextSave {
        var next = daily
        edit(&next)
        if let reason = DailyUpdateRows.reason(next) { return .refused(reason) }
        return .edit { Self.change(&$0, edit) }
    }

    // MARK: - The view

    package var body: some View {
        let style = PanelStyle(model)
        VStack(alignment: .leading, spacing: 0) {
            if let notice {
                Text(notice)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, style.points(12))
                    .padding(.vertical, style.points(6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(style.edge).frame(height: style.points(1))
                    }
            }
            sourceRow(style)
            toolsRow(style)
            SettingRow(
                model: model, row: id(.you), label: DailyUpdateRow.you.rawValue,
                hint: DailyUpdateRows.youHint
            ) {
                DraftField(
                    model: model, row: id(.you), label: DailyUpdateRow.you.rawValue,
                    saved: daily.you, width: 220, keepOnRefusal: true, save: saveYou)
            }
            CheckRow(
                model: model, row: id(.mergedPrs), label: DailyUpdateRow.mergedPrs.rawValue,
                isOn: daily.mergedPrs,
                set: { settings, on in Self.change(&settings) { $0.mergedPrs = on } })
            timeRow(.draftTime, value: daily.draftTime, hint: nil, deadline: false)
            timeRow(
                .deadline, value: daily.deadline, hint: DailyUpdateRows.deadlineHint,
                deadline: true)
            SettingRow(model: model, row: id(.days), label: DailyUpdateRow.days.rawValue) {
                DayButtons(section: self, style: style)
            }
            SelectRow(
                model: model, row: id(.model), label: DailyUpdateRow.model.rawValue,
                value: daily.model,
                choices: NewSessionRules.modelOptions().map { RowChoice($0.value, $0.label) },
                choose: { choose(model: $0) })
            SettingRow(
                model: model, row: id(.format), label: DailyUpdateRow.format.rawValue,
                hint: DailyUpdateRows.formatHint
            ) {
                EmptyView()
            } detail: {
                DraftArea(
                    model: model, row: id(.format), saved: daily.format.template, lines: 5,
                    save: saveTemplate
                )
                .padding(.horizontal, style.points(12))
                .padding(.bottom, style.points(8))
            }
            examplesRow(style)
            WorkAreaEditor(section: self, style: style)
            SettingRow(model: model, row: id(.panel), label: DailyUpdateRow.panel.rawValue) {
                Button(DailyUpdateRows.panelButton) { openPanel() }
                    .buttonStyle(DialogButtonStyle(style: style))
            }
        }
    }

    private func sourceRow(_ style: PanelStyle) -> some View {
        let label = DailyUpdateRow.source.rawValue
        let choices = sourceChoices
        return SettingRow(
            model: model, row: id(.source), label: label, hint: DailyUpdateRows.sourceHint
        ) {
            Picker(
                label,
                selection: Binding(
                    get: { daily.source.server ?? "" }, set: { choose(server: $0) })
            ) {
                ForEach(choices, id: \.name) { choice in
                    Text(choice.label).tag(choice.name).selectionDisabled(!choice.enabled)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .disabled(state.reading)
            Button(DailyUpdateRows.findServersButton) { Task { await findServers() } }
                .buttonStyle(DialogButtonStyle(style: style))
                .disabled(state.reading)
        } detail: {
            if state.reading {
                Text(DailyUpdateRows.readingLine)
                    .foregroundStyle(style.dim)
                    .padding(.horizontal, style.points(12))
                    .padding(.bottom, style.points(4))
            }
            ErrorLine(model: model, message: state.readError) { state.readError = nil }
        }
    }

    private func toolsRow(_ style: PanelStyle) -> some View {
        let proposal = currentProposal
        let hint: String
        if daily.source.server == nil {
            hint = DailyUpdateRows.noSourceTools
        } else if proposal != nil {
            hint = DailyUpdateRows.proposalHint
        } else if state.inventory?.server(named: daily.source.server) == nil {
            hint = "\(DailyUpdateRows.toolsHint) \(DailyUpdateRows.findToSeeTools)"
        } else {
            hint = DailyUpdateRows.toolsHint
        }
        return SettingRow(
            model: model, row: id(.tools), label: DailyUpdateRow.tools.rawValue, hint: hint
        ) {
            if proposal != nil {
                Button(DailyUpdateRows.useToolsButton) { useProposedTools() }
                    .buttonStyle(DialogButtonStyle(style: style, strong: true))
            }
        } detail: {
            VStack(alignment: .leading, spacing: style.points(4)) {
                ForEach(toolRows) { tool in
                    HStack(spacing: style.points(8)) {
                        Toggle(
                            isOn: Binding(get: { tool.on }, set: { set(tool: tool, on: $0) })
                        ) {
                            Text(tool.name)
                        }
                        .toggleStyle(BifrostCheckboxStyle(metrics: style.metrics))
                        .disabled(tool.write)
                        if let note = tool.note {
                            Text(note).foregroundStyle(style.dim).lineLimit(1).fixedSize()
                        }
                    }
                }
            }
            .padding(.horizontal, style.points(12))
            .padding(.bottom, toolRows.isEmpty ? 0 : style.points(8))
        }
    }

    private func timeRow(
        _ row: DailyUpdateRow, value: ClockTime, hint: String?, deadline: Bool
    ) -> some View {
        SettingRow(model: model, row: id(row), label: row.rawValue, hint: hint) {
            DraftField(
                model: model, row: id(row), label: row.rawValue, saved: value.text, width: 64,
                keepOnRefusal: true
            ) { text in saveTime(text, deadline: deadline) }
        }
    }

    private func examplesRow(_ style: PanelStyle) -> some View {
        let items = exampleItems
        return SettingRow(
            model: model, row: id(.examples), label: DailyUpdateRow.examples.rawValue,
            hint: DailyUpdateRows.examplesHint
        ) {
            Button(DailyUpdateRows.addExampleButton) { addExample() }
                .buttonStyle(DialogButtonStyle(style: style))
                .disabled(!canAddExample)
        } detail: {
            VStack(alignment: .leading, spacing: style.points(6)) {
                // Each box goes with its example, so a remove takes the box and its kept text.
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: style.points(8)) {
                        DraftArea(model: model, row: id(.examples), saved: item.text, lines: 4) {
                            saveExample($0, at: item.index)
                        }
                        Button(DailyUpdateRows.removeButton) { removeExample(at: item.index) }
                            .buttonStyle(DialogButtonStyle(style: style))
                    }
                }
            }
            .padding(.horizontal, style.points(12))
            .padding(.bottom, items.isEmpty ? 0 : style.points(8))
            .onChange(of: daily.format.examples, initial: true) { _, stored in
                state.syncExamples(stored)
            }
        }
    }
}

// The days as buttons from Monday to Sunday. A day that is on has the strong text and the panel
// colour.
private struct DayButtons: View {
    let section: DailyUpdateSection
    let style: PanelStyle

    var body: some View {
        let days = section.daily.days
        HStack(spacing: style.points(4)) {
            ForEach(DailyUpdateRows.dayChoices, id: \.day) { choice in
                let on = days.contains(choice.day)
                Button(choice.label) { section.toggle(day: choice.day) }
                    .buttonStyle(DialogButtonStyle(style: style, strong: on))
                    .background(on ? style.hover : .clear)
            }
        }
    }
}
