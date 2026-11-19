// The source of the release notes (docs/behaviour/updates.md, "Release notes"). It reads the
// GitHub releases of Bifrost only when the dialog opens, and keeps the last good answer in memory
// for ten minutes. The releases are public, so no request carries a token. The app uses
// SessionReleasesFetcher. A test home uses FileReleasesFetcher, and a test gives a fake, so no
// test reaches the network.
import BifrostFoundation
import Foundation
import OSLog

// Reads the answer of the releases API. nil: no answer (a fetch error, a timeout, a redirect, a
// status that is not 2xx, or a body over ReleaseNotesSource.maxBytes).
package protocol ReleasesFetcher: Sendable {
    func fetch() async -> Data?
}

@MainActor
package final class ReleaseNotesSource {
    // How long a good answer stays, the time limit of one request, and the most bytes of one
    // answer. Ten release bodies have a few tens of kB.
    nonisolated package static let cache = Duration.seconds(600)
    nonisolated package static let timeout = Duration.seconds(10)
    nonisolated package static let maxBytes = 2_000_000

    private nonisolated static let logger = Logger(bifrost: "release-notes")

    private let fetcher: any ReleasesFetcher
    private let releasesPage: URL
    private let timeline: Timeline
    // The last good answer and its time. It stays after the cache time, for page(of:).
    private var last: (at: Duration, releases: [Release])?
    // The load that runs, so two opens at the same time share one request.
    private var running: Task<[Release]?, Never>?

    // releasesPage is the Releases page of the project on GitHub. Each release page must be below
    // it.
    package init(fetcher: any ReleasesFetcher, releasesPage: URL, clock: any Clock<Duration>) {
        self.fetcher = fetcher
        self.releasesPage = releasesPage
        timeline = Timeline(clock)
    }

    // The releases, newest first, or nil when they could not load. A good answer of the last ten
    // minutes comes from memory.
    package func list() async -> [Release]? {
        if let last, timeline.now() - last.at < Self.cache { return last.releases }
        if let running { return await running.value }
        let load = Task { [fetcher, releasesPage] in
            let releases = await Self.load(fetcher, under: releasesPage)
            self.finish(releases)
            return releases
        }
        running = load
        return await load.value
    }

    // The page to open: the Releases page for nil, else the page of a release of the last good
    // answer. Each other version gives nil. So the dialog never opens another address.
    package func page(of version: ReleaseVersion?) -> URL? {
        guard let version else { return releasesPage }
        return last?.releases.first { $0.version == version }?.page
    }

    private func finish(_ releases: [Release]?) {
        running = nil
        if let releases { last = (timeline.now(), releases) }
    }

    // One request and the parse. The log line has no request data.
    @concurrent private static func load(
        _ fetcher: any ReleasesFetcher, under page: URL
    ) async -> [Release]? {
        guard let data = await fetcher.fetch() else {
            logger.info("The release notes could not load: no answer.")
            return nil
        }
        guard data.count <= maxBytes, let releases = ReleaseNotes.parse(data, pagesUnder: page)
        else {
            logger.info("The release notes could not load: the answer is not a list of releases.")
            return nil
        }
        return releases
    }
}

// The fetcher of a test home: the text of a file in the test home. A missing file is no answer.
package struct FileReleasesFetcher: ReleasesFetcher {
    private let file: URL

    package init(file: URL) {
        self.file = file
    }

    package func fetch() async -> Data? {
        let file = file
        return await BlockingExecutor.run { try? Data(contentsOf: file) }
    }
}

// The fetcher of the app. The request follows the rules of GuardedGet. No request carries a token
// or data of the user.
package struct SessionReleasesFetcher: ReleasesFetcher {
    private let api: URL
    private let get: GuardedGet

    // api is the address of the releases API. A test gives its own address and its stub protocol.
    package init(
        api: URL, configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) {
        self.api = api
        get = GuardedGet(configuration: configuration)
    }

    // The address of the API for the Releases page "https://github.com/<owner>/<repo>/releases",
    // or nil for another form of address.
    package init?(
        releasesPage page: URL,
        configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) {
        let parts = page.pathComponents.filter { $0 != "/" }
        guard page.scheme == "https", page.host() == "github.com", parts.count == 3,
            parts[2] == "releases",
            let api = URL(
                string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases"
                    + "?per_page=\(ReleaseNotes.maxReleases)")
        else { return nil }
        self.init(api: api, configuration: configuration)
    }

    package func fetch() async -> Data? {
        let answer = await get.get(
            api, headers: ["Accept": "application/vnd.github+json"],
            timeout: ReleaseNotesSource.timeout, maxBytes: ReleaseNotesSource.maxBytes)
        guard let answer, answer.isSuccess, !answer.tooLarge else { return nil }
        return answer.body  // nil: the read of the body failed
    }
}
