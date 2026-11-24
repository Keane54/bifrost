import AppKit
import BifrostFoundation
import BifrostReviews
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSettings

// Settings > Reviews (docs/behaviour/reviews.md, "Settings > Reviews"): the rows and their order,
// the confirm of each turn-on of Watch GitHub and of the automatic work on the PRs of the user
// (comments, merge conflicts and failing CI), and the ignore list with the reasons of a refused
// entry. The tests that show views use a window that is never ordered front.
@MainActor
@Suite("Settings > Reviews", .serialized, .testTimeLimit, .tags(.window))
struct ReviewsSectionTests {
    // The section shows one row for each label, in the order of the Electron app.
    @Test func theSectionShowsEachRowInItsOrder() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.reviews)
        let labels = await shownLabels(ReviewsSection(model: p.model))
        #expect(labels == ReviewsSettingsRow.shown.map(\.rawValue))
    }

    // Each turn-on asks first with the texts of the Electron app. A Cancel keeps the setting off,
    // and with no confirm dialog a turn-on saves nothing. A turn-off asks nothing. Only the
    // confirmed turn-on of the automatic comment handling gives the consent to Reviews, one time.
    @Test(arguments: [ReviewsSection.Confirmed.watch, .autoFix])
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

    // Each turn-on of the settings of merge conflicts and of failing CI asks first. With no confirm
    // dialog, and after a Cancel, nothing saves and no link runs. A confirm saves and calls the
    // link of that setting one time. A turn-off saves at once and asks nothing.
    @Test(arguments: [ReviewsSection.Confirmed.resolveConflicts, .fixCI])
    func eachTurnOnOfTheNewSettingsAsksFirst(_ setting: ReviewsSection.Confirmed) async throws {
        let p = try await SettingsParts()
        let links = LinkCalls()
        p.model.links.reviews = ReviewsLinks(
            confirmAutoFix: { links.calls.append(.autoFix) },
            confirmResolveConflicts: { links.calls.append(.resolveConflicts) },
            confirmFixCI: { links.calls.append(.fixCI) })
        let section = ReviewsSection(model: p.model)
        let path = setting.setting
        #expect(p.store.settings[keyPath: path] == false)
        #expect(await section.change(setting, to: true) == false)
        #expect(p.store.settings[keyPath: path] == false)
        let asked = Asked()
        p.model.links.confirm = { asked.texts.append($0); return asked.answer }
        #expect(await section.change(setting, to: true) == false)
        #expect(asked.texts == [setting.confirm])
        #expect(p.store.settings[keyPath: path] == false && links.calls.isEmpty)
        asked.answer = true
        #expect(await section.change(setting, to: true))
        #expect(p.store.settings[keyPath: path] == true)
        #expect(links.calls == [setting])
        #expect(await section.change(setting, to: false))
        #expect(p.store.settings[keyPath: path] == false)
        #expect(asked.texts.count == 2 && links.calls == [setting])
    }

    // The settings of merge conflicts and of failing CI come straight after the automatic comment
    // handling, in this order, in the list of the rows. The section does not show the Fix CI row
    // and the search does not find it, until the CI watcher exists.
    @Test func theRowsFollowAutoFixInOrderAndFixCIDoesNotShow() async throws {
        let order: [ReviewsSettingsRow] = [.autoFix, .resolveConflicts, .fixCI]
        let rows = ReviewsSettingsRow.allCases
        let first = try #require(rows.firstIndex(of: .autoFix))
        #expect(Array(rows[first...].prefix(3)) == order)
        let p = try await SettingsParts()
        p.model.showTab(.reviews)
        let labels = await shownLabels(ReviewsSection(model: p.model))
        let shown = try #require(labels.firstIndex(of: ReviewsSettingsRow.autoFix.rawValue))
        #expect(
            Array(labels[shown...].prefix(2)) == order.prefix(2).map(\.rawValue))
        #expect(!labels.contains(ReviewsSettingsRow.fixCI.rawValue))
        #expect(!ReviewsSettingsRow.shown.contains(.fixCI))
    }

    // The hints and the confirms of the settings of merge conflicts and of failing CI.
    // ReviewsRowsTests has their labels.
    @Test func theNewSettingsHaveTheirTexts() {
        #expect(
            ReviewsSection.resolveConflictsHint
                == "When one of your pull requests has conflicts, Claude resolves them and "
                + "Bifrost pushes a merge of the base branch.")
        #expect(
            ReviewsSection.fixCIHint
                == "When GitHub Actions fails on one of your pull requests, Claude fixes the code "
                + "or Bifrost re-runs the failed jobs.")
        let conflicts = ReviewsSection.resolveConflictsConfirm
        #expect(conflicts.title == "Resolve merge conflicts automatically?")
        #expect(conflicts.confirm == "Turn on" && conflicts.confirmAgain == nil)
        #expect(
            conflicts.body
                == "When GitHub says one of your pull requests has conflicts, Bifrost merges the "
                + "base branch into your branch in its own copy of the repository, and Claude "
                + "resolves the conflicts. Bifrost checks Claude's work, then commits the merge "
                + "and pushes it to your branch. It never rebases or force-pushes, and it tries "
                + "once for each new conflict. This includes pull requests that have conflicts "
                + "now.")
        let ci = ReviewsSection.fixCIConfirm
        #expect(ci.title == "Fix failing CI automatically?")
        #expect(ci.confirm == "Turn on" && ci.confirmAgain == nil)
        #expect(
            ci.body
                == "When GitHub Actions fails on one of your pull requests, Claude reads the "
                + "failed logs and your code. Bifrost then pushes Claude's fix to your branch, or "
                + "re-runs the failed jobs if Claude thinks they were flaky, and asks you when "
                + "Claude isn't sure. Each commit you push gets at most two fixes and one re-run. "
                + "This includes pull requests that are failing now.")
        #expect(ReviewsSection.Confirmed.resolveConflicts.confirm == conflicts)
        #expect(ReviewsSection.Confirmed.fixCI.confirm == ci)
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
        #expect(confirm.body.contains("review and request sessions"))
        #expect(confirm.body.contains("Changes in a copy that aren't on GitHub yet go too."))
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

// The calls of the consent links of a test, in their order, by the setting of each link.
@MainActor
private final class LinkCalls {
    var calls: [ReviewsSection.Confirmed] = []
}

// The calls of the consent link or of the removal link of a test, and the failure that the
// removal gives.
@MainActor
private final class Consents {
    var count = 0
    var failure: String?
}
