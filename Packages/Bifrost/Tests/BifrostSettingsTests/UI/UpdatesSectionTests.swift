import AppKit
import BifrostTestSupport
import Foundation
import Observation
import SwiftUI
import Testing

@testable import BifrostSettings

// Settings > Updates (docs/behaviour/updates.md, "Settings > Updates"): the rows, Check now with
// its reason, the Release notes button, and the search. The updater is a set of fake links, so no
// test starts a check.

// What the fake links did.
@MainActor
private final class Calls {
    var checks = 0
    var notes = 0
}

private let noon = Date(timeIntervalSince1970: 1_794_301_200)

@MainActor
private func links(
    _ calls: Calls, state: UpdaterState, version: String? = "0.4.0", now: Date = noon
) -> UpdatesLinks {
    UpdatesLinks(
        version: version, state: state, check: { calls.checks += 1 },
        openReleaseNotes: { calls.notes += 1 }, now: { now })
}

@MainActor
@Suite("Settings > Updates", .serialized, .timeLimit(.minutes(1)), .tags(.window))
struct UpdatesSectionTests {
    @Test func theRowsAreInOrder() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.updates)
        #expect(UpdatesSection.rows.map(\.rawValue) == UpdatesRow.allCases.map(\.rawValue))
        #expect(
            await shownLabels(UpdatesSection(model: p.model)) == UpdatesRow.allCases.map(\.rawValue)
        )
    }

    @Test func theDefaultLinksCheckNothing() async throws {
        let p = try await SettingsParts()
        let section = UpdatesSection(model: p.model)
        #expect(section.checkNowReason == UpdatesRows.offReason)
        #expect(!section.canCheck)
        #expect(section.versionText == "Unknown")
        #expect(section.lastCheckText == "Not yet")
        // A press does nothing: no check and no release notes dialog starts.
        section.checkNow()
        section.openReleaseNotes()
        #expect(p.model.links.updates.state.phase == .off)
    }

    @Test func checkNowIsOffInADevelopmentBuildWithItsReason() async throws {
        let calls = Calls()
        let state = UpdaterState(phase: .off)
        let p = try await SettingsParts()
        p.model.links = SettingsLinks(updates: links(calls, state: state))
        let section = UpdatesSection(model: p.model)
        #expect(section.checkNowReason == "This build doesn't update itself.")
        #expect(!section.canCheck)
        section.checkNow()
        #expect(calls.checks == 0)
        // The updater runs: Check now is on, with no reason, and it starts one check.
        state.phase = .idle
        #expect(section.checkNowReason == nil)
        section.checkNow()
        #expect(calls.checks == 1)
    }

    // An updater that runs but cannot check now shows no "does not update itself" text.
    @Test func aRunningCheckShowsItsLineAndNotTheOffReason() async throws {
        let calls = Calls()
        let state = UpdaterState(phase: .checking)
        let p = try await SettingsParts()
        p.model.links = SettingsLinks(updates: links(calls, state: state))
        let section = UpdatesSection(model: p.model)
        #expect(section.checkNowReason == "Checking for updates…")
        #expect(section.checkNowReason != UpdatesRows.offReason)
        #expect(!section.canCheck)
        section.checkNow()
        #expect(calls.checks == 0)
    }

    // The end of an update cycle changes the state, and the section follows at that event: the
    // observed text of the last check changes, and Check now turns on again.
    @Test func theEndOfACycleChangesLastCheckedAndTurnsCheckNowOn() async throws {
        let calls = Calls()
        let state = UpdaterState(phase: .checking)
        let p = try await SettingsParts()
        p.model.links = SettingsLinks(updates: links(calls, state: state))
        let section = UpdatesSection(model: p.model)
        #expect(section.lastCheckText == "Not yet")
        await confirmation("the section hears the end of the cycle") { heard in
            withObservationTracking {
                _ = section.lastCheckText
                _ = section.canCheck
            } onChange: {
                heard()
            }
            state.lastCheck = noon.addingTimeInterval(-60)
            state.phase = .idle
        }
        #expect(section.lastCheckText != "Not yet")
        #expect(section.canCheck)
    }

    @Test func theLastCheckTextUsesTheTimeOfTheLink() async throws {
        let state = UpdaterState(phase: .idle, lastCheck: noon.addingTimeInterval(-3600))
        let p = try await SettingsParts()
        p.model.links = SettingsLinks(updates: links(Calls(), state: state))
        let section = UpdatesSection(model: p.model)
        let expected = UpdatesRows.lastCheckText(
            state.lastCheck, now: noon, zone: .current)
        #expect(section.lastCheckText == expected)
        #expect(!expected.contains("Not yet"))
    }

    @Test func releaseNotesOpensTheDialog() async throws {
        let calls = Calls()
        let p = try await SettingsParts()
        p.model.links = SettingsLinks(updates: links(calls, state: UpdaterState()))
        UpdatesSection(model: p.model).openReleaseNotes()
        // The button works with no updater too.
        #expect(calls.notes == 1)
        #expect(calls.checks == 0)
    }

    @Test func theVersionShows() async throws {
        let p = try await SettingsParts()
        let given = links(Calls(), state: UpdaterState(), version: "1.2.3")
        p.model.links = SettingsLinks(updates: given)
        #expect(UpdatesSection(model: p.model).versionText == "1.2.3")
    }

    @Test func theSearchFindsTheUpdatesRowsAndTheModelIndexHasThem() async throws {
        let p = try await SettingsParts()
        #expect(SettingsModel.built.contains(.updates))
        #expect(p.model.index.first { $0.id == .updates }?.rows.count == UpdatesRow.allCases.count)
        p.model.query = "automatically"
        #expect(
            await shownLabels(UpdatesSection(model: p.model)) == ["Check for updates automatically"]
        )
        p.model.query = "release notes"
        #expect(await shownLabels(UpdatesSection(model: p.model)) == ["Release notes"])
        // The title finds the whole section.
        p.model.query = "updates"
        #expect(
            await shownLabels(UpdatesSection(model: p.model)) == UpdatesRow.allCases.map(\.rawValue)
        )
    }

    @Test func theSectionIsNoLaterSection() async throws {
        let p = try await SettingsParts()
        UITestApp.prepare()
        let later = NSHostingView(rootView: LaterSection(model: p.model)).fittingSize
        let body = NSHostingView(
            rootView: SectionBody(model: p.model, section: .updates, hit: nil)
        ).fittingSize
        #expect(body != later)
    }
}
