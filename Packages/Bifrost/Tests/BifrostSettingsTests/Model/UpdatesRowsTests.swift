// The rows of Settings > Updates (docs/behaviour/updates.md, "Settings > Updates").
import Foundation
import Testing

@testable import BifrostSettings

@Suite("the rows of Settings > Updates")
struct UpdatesRowsTests {
    @Test func eachRowHasItsExactLabelInOrder() {
        #expect(
            UpdatesRow.allCases.map(\.rawValue) == [
                "Check for updates automatically", "Version", "Last checked", "Check for updates",
                "Release notes",
            ])
    }

    @Test(arguments: UpdatesRow.allCases)
    func theSearchFindsEachUpdatesRow(_ row: UpdatesRow) {
        let index = SettingsSearch.index(
            general: [], slash: [], keys: [], live: [], skills: [], updates: UpdatesRow.allCases,
            shown: [.updates])
        #expect(index.map(\.id) == [.updates])
        let hits = SettingsSearch.search(row.rawValue, index)
        #expect(hits?.first?.rows.contains(row.rawValue) == true)
    }

    // The title of the section finds all its rows.
    @Test func theTitleOfTheSectionFindsAllRows() {
        let index = SettingsSearch.index(
            general: [], slash: [], keys: [], live: [], skills: [], updates: UpdatesRow.allCases,
            shown: [.updates])
        let hit = SettingsSearch.search("updates", index)?.first
        #expect(hit?.whole == true)
        #expect(hit?.rows == UpdatesRow.allCases.map(\.rawValue))
    }

    @Test func noRowsGiveNoSectionInTheIndex() {
        let index = SettingsSearch.index(
            general: [], slash: [], keys: [], live: [], skills: [], shown: [.updates])
        #expect(index.isEmpty)
    }

    @Test func theVersionTextHasAFallback() {
        #expect(UpdatesRows.versionText("0.4.0") == "0.4.0")
        #expect(UpdatesRows.versionText(nil) == "Unknown")
        #expect(UpdatesRows.versionText("") == "Unknown")
    }

    @Test func theLastCheckIsTheClockToday() throws {
        let now = Date(timeIntervalSince1970: 1_794_301_200 + 3600)
        let check = Date(timeIntervalSince1970: 1_794_301_200)
        #expect(UpdatesRows.lastCheckText(check, now: now, zone: .gmt) == "09:00")
    }

    @Test func theLastCheckOfAnotherDayHasTheDate() {
        let now = Date(timeIntervalSince1970: 1_794_301_200 + 3 * 86_400)
        let check = Date(timeIntervalSince1970: 1_794_301_200)
        #expect(UpdatesRows.lastCheckText(check, now: now, zone: .gmt) == "Tue 10 Nov 09:00")
    }

    @Test func noCheckYetHasItsText() {
        #expect(UpdatesRows.lastCheckText(nil, now: Date(), zone: .gmt) == "Not yet")
    }
}
