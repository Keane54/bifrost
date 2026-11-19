import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

// The lock of the Reviews folder: only one copy of Bifrost runs Reviews at a time. A second open
// of the lock file in this process is a second open file description, as a second copy of the app
// has, so flock refuses it too.

private func layout(_ folder: TemporaryFolder) -> ReviewsLayout {
    ReviewsLayout(
        folder: folder.url.appending(path: ".bifrost/reviews", directoryHint: .isDirectory))
}

private func mode(_ url: URL) -> mode_t {
    var info = stat()
    guard lstat(path(url), &info) == 0 else { return 0 }
    return info.st_mode & 0o777
}

@MainActor
private func openStore(_ layout: ReviewsLayout) async throws(ReviewsStoreError) -> ReviewsStore {
    try await ReviewsStore.open(layout: layout, log: Recorder<StoreEvent>())
}

@MainActor
@Suite("the Reviews lock", .timeLimit(.minutes(1)))
struct ReviewsLockTests {
    // While one store is open, a second open is refused with otherCopy and touches no file. The
    // lock file has the mode 0600 in a folder with the mode 0700.
    @Test func aSecondOpenIsRefusedWithOtherCopy() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let reviews = layout(folder)
        let store = try await openStore(reviews)
        let saved = try Data(contentsOf: reviews.stateFile)

        await #expect(throws: ReviewsStoreError.otherCopy) { try await openStore(reviews) }
        #expect(throws: ReviewsStoreError.otherCopy) { try ReviewsStore.takeLock(reviews) }
        #expect(try Data(contentsOf: reviews.stateFile) == saved)
        #expect(mode(reviews.lockFile) == 0o600)
        #expect(mode(reviews.folder) == 0o700)
        #expect(
            ReviewsStoreError.otherCopy.message
                == "Reviews is running in another copy of Bifrost.")
        await store.close().value
    }

    // A closed store frees the lock after its saves, so a new open works. An update after the
    // close changes nothing.
    @Test func aClosedStoreFreesTheLock() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let reviews = layout(folder)
        let store = try await openStore(reviews)
        await store.close().value
        await store.update { $0.setUpAt = Date(timeIntervalSince1970: 1) }
        #expect(store.state.setUpAt == nil)

        let again = try await openStore(reviews)
        #expect(again.state.setUpAt == nil)
        await again.close().value

        let lock = try ReviewsStore.takeLock(reviews)
        lock.release()
        lock.release()
        try ReviewsStore.takeLock(reviews).release()
    }
}
