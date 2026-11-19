// The source of the release notes (docs/behaviour/updates.md, "Release notes"). Safety: the
// fetcher is a fake that gives bytes, so no test reaches the network. The clock is a manual
// clock.
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostWindows

// Gives the bytes that the test sets, and counts the requests. A gate holds an answer until the
// test lets it go.
private final class FakeFetcher: ReleasesFetcher {
    private let state = Mutex<(answer: Data?, count: Int)>((nil, 0))
    let gate: TestGate?

    init(answer: Data?, gate: TestGate? = nil) {
        state.withLock { $0.answer = answer }
        self.gate = gate
    }

    var requests: Int { state.withLock { $0.count } }
    func setAnswer(_ data: Data?) { state.withLock { $0.answer = data } }

    func fetch() async -> Data? {
        state.withLock { $0.count += 1 }
        await gate?.pass()
        return state.withLock { $0.answer }
    }
}

private let twoReleases = releasesAnswer(
    releaseJSON(tag: "v1.1.0", body: "New things."), releaseJSON(tag: "v1.0.0"))

@MainActor
@Suite("release notes source", .timeLimit(.minutes(1)))
struct ReleaseNotesSourceTests {
    private func source(
        _ fetcher: FakeFetcher, _ clock: ManualClock = ManualClock()
    ) -> ReleaseNotesSource {
        ReleaseNotesSource(fetcher: fetcher, releasesPage: releasesPage, clock: clock)
    }

    @Test func theLimitsAreTenMinutesTenSecondsAndTwoMegabytes() {
        #expect(ReleaseNotesSource.cache == .seconds(600))
        #expect(ReleaseNotesSource.timeout == .seconds(10))
        #expect(ReleaseNotesSource.maxBytes == 2_000_000)
    }

    @Test func aGoodAnswerGivesTheReleases() async {
        let fetcher = FakeFetcher(answer: twoReleases)
        let releases = await source(fetcher).list()
        #expect(releases?.map(\.version.description) == ["1.1.0", "1.0.0"])
        #expect(releases?.first?.summary == "New things.")
    }

    // A failed load is not cached, so a call that does not join the running load would make a
    // second request. One request for two calls proves that they share the load.
    @Test func twoOpensShareOneLoad() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let fetcher = FakeFetcher(answer: nil, gate: gate)
        let source = source(fetcher)
        let first = Task { await source.list() }
        await gate.waitUntilHolding()
        // The second call starts while the first load waits at the gate.
        let second = Task { await source.list() }
        for _ in 0..<20 { await Task.yield() }
        gate.open()
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(fetcher.requests == 1)
    }

    @Test func theCacheLastsTenMinutes() async {
        let clock = ManualClock()
        let fetcher = FakeFetcher(answer: twoReleases)
        let source = source(fetcher, clock)
        _ = await source.list()
        clock.advance(by: .seconds(599))
        _ = await source.list()
        #expect(fetcher.requests == 1)
        clock.advance(by: .seconds(1))
        _ = await source.list()
        #expect(fetcher.requests == 2)
    }

    @Test func aFailedLoadIsNotKeptInTheCache() async {
        let fetcher = FakeFetcher(answer: nil)
        let source = source(fetcher)
        #expect(await source.list() == nil)
        fetcher.setAnswer(twoReleases)
        #expect(await source.list()?.count == 2)
        #expect(fetcher.requests == 2)
    }

    @Test func onlyAKnownReleasePageOpens() async {
        let clock = ManualClock()
        let fetcher = FakeFetcher(answer: twoReleases)
        let source = source(fetcher, clock)
        // The Releases page opens at any time. A release page needs an answer first.
        #expect(source.page(of: nil) == releasesPage)
        #expect(source.page(of: version("1.1.0")) == nil)
        _ = await source.list()
        #expect(source.page(of: version("1.1.0"))?.absoluteString == releasePage("v1.1.0"))
        #expect(source.page(of: version("1.0.0"))?.absoluteString == releasePage("v1.0.0"))
        #expect(source.page(of: version("9.9.9")) == nil)
        // The page of the last good answer stays after the cache time and after a failed load.
        clock.advance(by: .seconds(601))
        fetcher.setAnswer(nil)
        #expect(await source.list() == nil)
        #expect(source.page(of: version("1.1.0"))?.absoluteString == releasePage("v1.1.0"))
    }

    @Test func aReleaseOfAnotherAddressNeverOpens() async {
        let other = "https://example.invalid/releases/tag/v9.0.0"
        let data = releasesAnswer(
            releaseJSON(tag: "v1.0.0"), releaseJSON(tag: "v9.0.0", page: other))
        let source = source(FakeFetcher(answer: data))
        let releases = await source.list()
        #expect(releases?.map(\.version.description) == ["1.0.0"])
        #expect(source.page(of: version("9.0.0")) == nil)
    }

    @Test func anAnswerThatIsNotAListCouldNotLoad() async {
        #expect(await source(FakeFetcher(answer: Data(#"{"message":"x"}"#.utf8))).list() == nil)
        #expect(await source(FakeFetcher(answer: Data("<html>".utf8))).list() == nil)
        #expect(await source(FakeFetcher(answer: nil)).list() == nil)
    }

    @Test func anAnswerOverTwoMegabytesCouldNotLoad() async {
        let big = Data(repeating: UInt8(ascii: " "), count: ReleaseNotesSource.maxBytes + 1)
        #expect(await source(FakeFetcher(answer: big)).list() == nil)
        // The same size with the bytes of a list stays under the limit, so it loads.
        let atLimit = twoReleases + Data(repeating: UInt8(ascii: " "), count: 1000)
        #expect(await source(FakeFetcher(answer: atLimit)).list()?.count == 2)
    }
}
