// The labels of the rows of Settings > Reviews and the search of them
// (docs/behaviour/reviews.md, "Settings > Reviews").
import Testing

@testable import BifrostSettings

@Suite("the Reviews rows")
struct ReviewsRowsTests {
    // The labels of the Electron app, in the order of its Reviews section, with the two settings
    // of this app for merge conflicts and failing CI after the automatic comment handling. A
    // change of a label is a change that the user sees.
    @Test func eachReviewsRowHasItsExactLabel() {
        #expect(
            ReviewsSettingsRow.allCases.map(\.rawValue) == [
                "Watch GitHub", "Handle comments on my PRs automatically",
                "Resolve merge conflicts automatically", "Fix failing CI automatically",
                "Sign commits through GitHub", "Show team requests", "Maximum PR sessions",
                "Pause time", "GitHub poll interval", "Model for request sessions",
                "Model for review sessions", "Repositories to ignore", "Remove all clones",
            ])
    }

    @Test(arguments: ReviewsSettingsRow.allCases)
    func theSearchFindsEachReviewsRow(_ row: ReviewsSettingsRow) {
        let index = SettingsSearch.index(
            general: [], slash: [], keys: [], live: [], skills: [], shown: [.reviews])
        let hits = SettingsSearch.search(row.rawValue, index)
        let reviews = hits?.first { $0.id == .reviews }
        #expect(reviews?.rows.contains(row.rawValue) == true)
        #expect(row.row.isShown(section: .general, hits: hits))
    }

    // The section is in the index of the panel, so its title finds each of its rows. A word that
    // is only in a hint or a choice finds no row.
    @MainActor
    @Test func theTitleFindsTheWholeSectionAndAHintFindsNothing() {
        let index = SettingsSearch.index(
            general: [], slash: [], keys: [], live: [], skills: [], shown: SettingsModel.built)
        let hits = SettingsSearch.search("reviews", index)
        #expect(hits?.map(\.id) == [.reviews] && hits?.first?.whole == true)
        #expect(SettingsSearch.search("Verified", index) == [])
        #expect(SettingsSearch.search("Opus", index) == [])
    }
}
