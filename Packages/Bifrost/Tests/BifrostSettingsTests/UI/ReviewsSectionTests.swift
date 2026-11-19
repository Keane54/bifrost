import AppKit
import BifrostFoundation
import BifrostReviews
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSettings

// Settings > Reviews (docs/behaviour/reviews.md, "Settings > Reviews"): the rows and their order,
// the confirm of each turn-on of Watch GitHub and of the automatic comment handling, and the
// ignore list with the reasons of a refused entry. The tests that show views use a window that is
// never ordered front.
@MainActor
@Suite("Settings > Reviews", .serialized, .timeLimit(.minutes(1)), .tags(.window))
struct ReviewsSectionTests {
    // The section shows one row for each label, in the order of the Electron app.
    @Test func theSectionShowsEachRowInItsOrder() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.reviews)
        let labels = await shownLabels(ReviewsSection(model: p.model))
        #expect(labels == ReviewsSettingsRow.allCases.map(\.rawValue))
    }

    // Each turn-on asks first with the texts of the Electron app. A Cancel keeps the setting off,
    // and with no confirm dialog a turn-on saves nothing. A turn-off asks nothing. Only the
    // confirmed turn-on of the automatic comment handling gives the consent to Reviews, one time.
    @Test(arguments: ReviewsSection.Confirmed.allCases)
    func eachTurnOnAsksFirstAndACancelKeepsItOff(_ setting: ReviewsSection.Confirmed) async throws {
        let p = try await SettingsParts()
        let consents = Consents()
        p.model.links.reviews = ReviewsLinks(confirmAutoFix: { consents.count += 1 })
        let section = ReviewsSection(model: p.model)
        let path = setting.setting
        // Handle comments on my PRs automatically is on by default: it goes off first.
        #expect(await section.change(setting, to: false))
        #expect(p.store.settings[keyPath: path] == false)
        #expect(await section.change(setting, to: true) == false)
        #expect(p.store.settings[keyPath: path] == false)
        let asked = Asked()
        p.model.links.confirm = { asked.texts.append($0); return asked.answer }
        #expect(await section.change(setting, to: true) == false)
        #expect(asked.texts == [setting.confirm])
        #expect(p.store.settings[keyPath: path] == false)
        #expect(consents.count == 0)
        asked.answer = true
        #expect(await section.change(setting, to: true))
        #expect(p.store.settings[keyPath: path] == true)
        #expect(consents.count == (setting == .autoFix ? 1 : 0))
        // On again asks nothing and gives no consent, and nor does a turn-off.
        #expect(await section.change(setting, to: true))
        #expect(await section.change(setting, to: false))
        #expect(asked.texts.count == 2)
        #expect(consents.count == (setting == .autoFix ? 1 : 0))
        #expect(p.store.settings[keyPath: path] == false)
    }

    // Remove all clones asks first with the text of the Electron app. A Cancel removes nothing,
    // and a failure shows on its row until a removal works.
    @Test func removeAllClonesAsksFirstAndShowsAFailure() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.reviews)
        let removals = Consents()
        removals.failure = "Reviews is running in another copy of Bifrost."
        p.model.links.reviews = ReviewsLinks(removeClones: {
            removals.count += 1
            return removals.failure
        })
        let section = ReviewsSection(model: p.model)
        let row = ReviewsSettingsRow.removeClones.row
        #expect(await section.removeClones() == false)
        let asked = Asked()
        p.model.links.confirm = { asked.texts.append($0); return asked.answer }
        #expect(await section.removeClones() == false)
        #expect(asked.texts == [ReviewsSection.removeClonesConfirm])
        #expect(removals.count == 0)
        asked.answer = true
        #expect(await section.removeClones() == false)
        #expect(removals.count == 1)
        #expect(p.model.error(of: row) == "Reviews is running in another copy of Bifrost.")
        removals.failure = nil
        #expect(await section.removeClones())
        #expect(removals.count == 2)
        #expect(p.model.error(of: row) == nil)
        let confirm = ReviewsSection.removeClonesConfirm
        #expect(confirm.title == "Remove all clones?")
        #expect(confirm.confirm == "Remove")
        #expect(confirm.body.hasPrefix("Bifrost will delete its copies of your repositories"))
    }

    @Test func theConfirmsHaveTheTextsOfTheElectronApp() {
        let watch = ReviewsSection.watchConfirm
        #expect(watch.title == "Watch GitHub?" && watch.confirm == "Turn on")
        #expect(
            watch.body
                == "Bifrost will use your gh login to check your review requests and your pull "
                + "requests every few minutes. It makes its own copy of each of their "
                + "repositories, and asks you to trust each copy once. When you click Review, "
                + "Claude reviews the pull request and Bifrost saves a draft review that only you "
                + "can see. On your own pull requests, Claude fixes or answers new review "
                + "comments, and Bifrost pushes the fixes and posts the replies. Bifrost changes, "
                + "sends or approves a review only when you click a button in the Review panel or "
                + "Approve, and it never merges.")
        let autoFix = ReviewsSection.autoFixConfirm
        #expect(autoFix.title == "Handle comments automatically?" && autoFix.confirm == "Turn on")
        #expect(
            autoFix.body
                == "When someone reviews one of your pull requests, Claude fixes or answers each "
                + "new comment. Bifrost then pushes the fixes to your branch, replies to each "
                + "comment and resolves its thread. It never force-pushes, merges or approves. "
                + "Comments from before now wait until you choose Handle now.")
        #expect(autoFix.confirmAgain == nil && watch.confirmAgain == nil)
    }

    // A bad entry, a copy in another case and an entry for a full list each show their reason
    // on the row before a save starts, and the field keeps its text. A new text clears the
    // reason. A good entry saves in its clean form, and Remove takes an entry out.
    @Test func aBadIgnoreEntryShowsItsReason() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.reviews)
        let section = ReviewsSection(model: p.model)
        let row = ReviewsSettingsRow.ignore.row
        section.editIgnore("not a repo")
        #expect(section.addIgnore() == nil)
        #expect(p.model.error(of: row) == "Use owner/repo or owner/*.")
        #expect(p.model.draftText(ReviewsSection.ignoreDraftID) == "not a repo")
        #expect(p.store.settings.reviewsIgnore.isEmpty)
        section.editIgnore(" Owner-A/Repo.B ")
        #expect(p.model.error(of: row) == nil)
        let saving = try #require(section.addIgnore())
        #expect(await saving.value)
        #expect(p.store.settings.reviewsIgnore == ["owner-a/repo.b"])
        #expect(await waitUntil { p.model.draftText(ReviewsSection.ignoreDraftID).isEmpty })
        section.editIgnore("OWNER-A/REPO.B")
        #expect(section.addIgnore() == nil)
        #expect(p.model.error(of: row) == "That repository is already in the list.")
        let full = (1...50).map { "owner-a/repo-\($0)" }
        #expect(await p.model.save(row) { $0.reviewsIgnore = full }.value)
        section.editIgnore("owner-b/*")
        #expect(section.addIgnore() == nil)
        #expect(p.model.error(of: row) == "You can keep up to 50 entries.")
        #expect(await section.removeIgnore("owner-a/repo-1").value)
        #expect(p.store.settings.reviewsIgnore == Array(full.dropFirst()))
        // The good save of the row clears the reason, and the field keeps its text.
        #expect(p.model.error(of: row) == nil)
        #expect(p.model.draftText(ReviewsSection.ignoreDraftID) == "owner-b/*")
    }

    // A search for a label shows only the row of that label, and the field and the list of the
    // ignore list show only with their row.
    @Test func aSearchShowsOnlyTheMatchingRows() async throws {
        let p = try await SettingsParts()
        p.model.query = "poll interval"
        let hit = p.model.hits?.first { $0.id == .reviews }
        #expect(hit?.rows == [ReviewsSettingsRow.pollInterval.rawValue])
        let labels = await shownLabels(ReviewsSection(model: p.model))
        #expect(labels == [ReviewsSettingsRow.pollInterval.rawValue])
        #expect(!p.model.isShown(ReviewsSettingsRow.ignore.row))
    }
}

// The calls of the consent link or of the removal link of a test, and the failure that the
// removal gives.
@MainActor
private final class Consents {
    var count = 0
    var failure: String?
}
