import BifrostFoundation
import BifrostWindows
import Foundation

// The release notes of the app (docs/behaviour/updates.md, "Release notes" and "What's new"): the
// source of the releases, and the decision of What's new at the start with its file. AppServices
// holds one when the app has the address of its releases.
@MainActor
package final class ReleaseNotesService {
    package let source: ReleaseNotesSource
    // The file of What's new. nil when the app never opens What's new by itself (StartPlan).
    private let whatsNewFile: URL?
    // The log of the file of What's new. The app gives the health log of its stores.
    private let log: any StoreLog
    private var whatsNewStore: ReleaseNotesStore?

    package init(source: ReleaseNotesSource, whatsNewFile: URL?, log: any StoreLog) {
        self.source = source
        self.whatsNewFile = whatsNewFile
        self.log = log
    }

    // The source of the release notes for the plan: the file of a test home, else the GitHub
    // releases API of the Releases page. nil with no page, or with a page of another form.
    package static func source(
        plan: StartPlan, releasesPage: URL?, clock: any Clock<Duration>
    ) -> ReleaseNotesSource? {
        guard let releasesPage else { return nil }
        if let file = plan.releasesFile {
            return ReleaseNotesSource(
                fetcher: FileReleasesFetcher(file: file), releasesPage: releasesPage, clock: clock)
        }
        guard let fetcher = SessionReleasesFetcher(releasesPage: releasesPage) else { return nil }
        return ReleaseNotesSource(fetcher: fetcher, releasesPage: releasesPage, clock: clock)
    }

    // The What's new of this start (ReleaseNotesStore.takeWhatsNew), or nil. The store opens at
    // the first call. nil too when the app never opens What's new by itself.
    package func whatsNew(current: String, setupDone: Bool) async -> WhatsNewRange? {
        guard let whatsNewFile else { return nil }
        let store: ReleaseNotesStore
        if let open = whatsNewStore {
            store = open
        } else {
            store = await ReleaseNotesStore.open(file: whatsNewFile, log: log)
            whatsNewStore = store
        }
        return await store.takeWhatsNew(current: current, setupDone: setupDone)
    }
}
