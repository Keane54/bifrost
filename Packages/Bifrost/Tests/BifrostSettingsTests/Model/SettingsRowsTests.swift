// The sections of the Settings panel and the labels of the General rows
// (docs/behaviour/settings.md, "The sections" and "The search").
import Testing

@testable import BifrostSettings

@Suite("the sections and the row labels")
struct SettingsRowsTests {
    @Test func theSectionsAreInTheOrderOfTheTabsWithTheirTitles() {
        #expect(
            SettingsSection.allCases == [
                .general, .slash, .keys, .reviews, .dailyUpdate, .live, .skills, .modules, .updates,
            ])
        #expect(
            SettingsSection.allCases.map(\.title) == [
                "General", "Slash commands", "Keys", "Reviews", "Daily update", "Live details",
                "Skills", "Modules", "Updates",
            ])
        #expect(
            SettingsSection.allCases.map(\.rawValue) == [
                "general", "slash", "keys", "reviews", "daily-update", "live", "skills", "modules",
                "updates",
            ])
    }

    // The labels in the order of the rows in Settings > General. A change of a label is a
    // change that the user sees.
    @Test func eachGeneralRowHasItsExactLabel() {
        #expect(
            GeneralRow.allCases.map(\.rawValue) == [
                "Labels", "Terminal app", #"Default app for "Open project""#, "Escalation time",
                "Row flash", "macOS notification", "Sound for a red box", "Start at login",
                "Account usage from Anthropic", "Poll interval", "Snap distance",
                "Panel transparency", "Animated background", "Interface scale", "Terminal font",
                "Display mode", "Introduction",
            ])
    }

    @Test(arguments: GeneralRow.allCases)
    func theSearchFindsEachGeneralRowByItsLabel(_ row: GeneralRow) {
        let index = SettingsSearch.index(
            general: GeneralRow.allCases, slash: [], keys: [], live: [], skills: [],
            shown: [.general])
        let hits = SettingsSearch.search(row.rawValue, index)
        #expect(hits?.first { $0.id == .general }?.rows.contains(row.rawValue) == true)
    }

    // A word of a hint or of a choice, for example "Automatic", does not find a row.
    @Test func theSearchFindsAGeneralRowOnlyByItsLabel() {
        let index = SettingsSearch.index(
            general: GeneralRow.allCases, slash: [], keys: [], live: [], skills: [],
            shown: [.general])
        #expect(SettingsSearch.search("Automatic", index) == [])
        #expect(SettingsSearch.search("Menlo", index) == [])
    }
}
