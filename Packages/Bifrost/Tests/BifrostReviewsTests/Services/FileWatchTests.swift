// The watch of one file of Reviews (docs/behaviour/reviews.md, "PR sessions"): the coming of the
// file gives one call, and a stop ends the watch.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the watch of one file", .timeLimit(.minutes(1)), .tags(.timing))
struct FileWatchTests {
    // The coming of a file that was missing gives a call.
    @Test func theComingOfTheFileGivesACall() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.realPath + "/result.json"
        let signal = TestSignal()
        let watch = FileWatch(
            file: file, folder: folder.realPath, label: "bifrost.test-watch",
            changed: { signal.send() })
        watch.start()
        defer { watch.stop() }
        try Data("{}".utf8).write(to: URL(filePath: file))
        #expect(await signal.value(within: .seconds(10)))
    }

    // An arm after a stop (an event that came during the stop) makes a source and drops it at
    // once. The drop of a source that never became active must not stop the process.
    @Test func anArmAfterAStopDropsItsSource() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let watch = FileWatch(
            file: folder.realPath + "/result.json", folder: folder.realPath,
            label: "bifrost.test-watch", changed: {})
        watch.start()
        watch.stop()
        watch.start()
        watch.start()
    }
}
