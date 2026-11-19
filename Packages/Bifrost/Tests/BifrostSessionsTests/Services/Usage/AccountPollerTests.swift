// The poller of the account usage (docs/behaviour/usage.md, "The account values"). Safety: the
// token comes from a fake runner and goes to a fake fetcher, so no test runs security, reads the
// Keychain or reaches the network. Each token is fake, and the fakes record no token.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

private let fakeToken = "fake-access-token-for-tests"
private let now = Date(timeIntervalSince1970: 1_794_016_800)
private let nowMs = 1_794_016_800_000

private func keychainText() -> String {
    """
    {"claudeAiOauth":{"accessToken":"\(fakeToken)","refreshToken":"fake-refresh-token",\
    "expiresAt":\(nowMs + 3_600_000)}}

    """
}

private let goodKeychain = ExecResult(.exited(0), stdout: keychainText())
private let noKeychain = ExecResult(.exited(44), stderr: "The item could not be found.")

private func answer(percent: Int) -> Data {
    Data(
        """
        {"five_hour":{"utilization":\(percent),"resets_at":"2026-11-07T05:00:00+00:00"},\
        "extra_usage":{"is_enabled":false}}
        """.utf8)
}

private func usage(percent: Int) -> AccountUsage {
    AccountUsage(
        fetchedAt: nowMs,
        limits: RateLimits(
            fiveHour: RateWindow(usedPercent: Double(percent), resetsAt: utcMs(2026, 11, 7, 5))),
        extraUsage: false)
}

private func ok(_ percent: Int) -> UsageResponse? {
    UsageResponse(status: 200, body: answer(percent: percent))
}

// A Keychain read that gives the result of now. With a gate, each read waits at it first.
private final class FakeKeychain: CommandRunner {
    private let result = Mutex(goodKeychain)
    private let reads = Mutex(0)
    let gate: TestGate?

    init(gate: TestGate? = nil) { self.gate = gate }

    var readCount: Int { reads.withLock { $0 } }

    func set(_ next: ExecResult) { result.withLock { $0 = next } }

    func run(_ command: Command) async -> ExecResult {
        reads.withLock { $0 += 1 }
        await gate?.pass()
        return result.withLock { $0 }
    }
}

// A fetcher that gives the answers in their order, then the last answer again. With a gate, each
// fetch waits at it first. It records no token: only whether the token was the one of the login.
private final class FakeFetcher: UsageFetcher {
    enum Call: Equatable {
        case fetch(loginToken: Bool, timeout: Duration)
    }

    private let answers: [UsageResponse?]
    private let recorded = Mutex<[Call]>([])
    let gate: TestGate?

    init(_ answers: [UsageResponse?], gate: TestGate? = nil) {
        self.answers = answers
        self.gate = gate
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func fetch(token: String, timeout: Duration) async -> UsageResponse? {
        let index = recorded.withLock { calls in
            calls.append(.fetch(loginToken: token == fakeToken, timeout: timeout))
            return calls.count - 1
        }
        await gate?.pass()
        return answers[min(index, answers.count - 1)]
    }
}

// The poller of a test with its fakes and a manual clock.
@MainActor
private final class PollerFixture {
    let clock = ManualClock()
    let keychain: FakeKeychain
    let fetcher: FakeFetcher
    let log = Recorder<AccountUsageEvent>()
    let poller: AccountPoller

    init(
        _ answers: [UsageResponse?], keychainGate: TestGate? = nil, fetchGate: TestGate? = nil,
        health: HealthReporter = .none
    ) {
        keychain = FakeKeychain(gate: keychainGate)
        fetcher = FakeFetcher(answers, gate: fetchGate)
        poller = AccountPoller(
            runner: keychain, fetcher: fetcher, clock: clock, now: { now }, log: log,
            health: health)
    }

    var fetches: Int { fetcher.calls.count }

    // Start and wait for the end of the first poll.
    func start() async {
        poller.start()
        await poller.pollTask?.value
    }

    // Move the clock to the next timer and wait for the end of its poll.
    func nextPoll(after duration: Duration) async {
        let timer = poller.timerTask
        clock.advance(by: duration)
        await timer?.value
        await poller.pollTask?.value
    }

    // The time of the next timer since the start of the clock, when it waits.
    func nextTimer() async -> Duration? {
        await clock.waitForSleepers(exactly: 1)
        return clock.nextDeadline?.offset
    }
}

@MainActor
@Suite("account poller")
struct AccountPollerTests {
    @Test func theTimesAreFiveMinutesOneMinuteAndFifteenMinutes() {
        #expect(AccountPoller.interval == .seconds(300))
        #expect(AccountPoller.hudGap == .seconds(60))
        #expect(AccountPoller.rateLimitWait == .seconds(900))
        #expect(AccountPoller.requestTimeout == .seconds(10))
        #expect(AccountPoller.deadline == .seconds(25))
    }

    @Test func aStartPollsAtOnceAndSetsTheValues() async {
        let fixture = PollerFixture([ok(37)])
        #expect(fixture.poller.value == nil)
        #expect(fixture.poller.lastResult == nil)
        await fixture.start()
        #expect(fixture.poller.value == usage(percent: 37))
        #expect(fixture.poller.lastResult == .ok)
        #expect(fixture.fetcher.calls == [.fetch(loginToken: true, timeout: .seconds(10))])
        #expect(fixture.log.values.isEmpty)
    }

    @Test func theNextPollComesAfterFiveMinutesAndReadsTheTokenAgain() async {
        let fixture = PollerFixture([ok(37), ok(41)])
        await fixture.start()
        #expect(await fixture.nextTimer() == .seconds(300))
        await fixture.nextPoll(after: .seconds(300))
        #expect(fixture.keychain.readCount == 2)
        #expect(fixture.fetches == 2)
        #expect(fixture.poller.value == usage(percent: 41))
        #expect(await fixture.nextTimer() == .seconds(600))
    }

    // Each poll tells the health log its result (lastResult). A stop tells it that the poll
    // stopped, so its failures in a row end. A second stop tells it nothing.
    @Test func eachPollTellsTheHealthLogItsResultAndAStopEndsTheStreak() async {
        let (health, events) = HealthReporter.make()
        let told = Recorder<HealthEvent>()
        let reader = Task { for await event in events { told.record(event) } }
        defer { reader.cancel() }
        // The events in their order, after a wait of at most 5 s for the count.
        func toldEvents(_ count: Int) async -> [HealthEvent] {
            await waitUntil(within: .seconds(5)) { told.values.count >= count }
            return told.values
        }
        let fixture = PollerFixture([ok(37), nil], health: health)
        await fixture.start()
        #expect(await toldEvents(1) == [.poll(.accountUsage, .ok)])
        await fixture.nextPoll(after: .seconds(300))
        #expect(fixture.poller.lastResult == .failed)
        fixture.keychain.set(noKeychain)
        await fixture.nextPoll(after: .seconds(300))
        fixture.poller.stop()
        fixture.poller.stop()
        fixture.keychain.set(goodKeychain)
        await fixture.start()
        fixture.poller.stop()
        #expect(
            await toldEvents(6) == [
                .poll(.accountUsage, .ok), .poll(.accountUsage, .failed),
                .poll(.accountUsage, .noData), .stopped(.accountUsage),
                .poll(.accountUsage, .failed), .stopped(.accountUsage),
            ])
    }

    @Test func aSecondStartDoesNothing() async {
        let fixture = PollerFixture([ok(37)])
        await fixture.start()
        await fixture.start()
        #expect(fixture.fetches == 1)
    }

    @Test func noTokenGivesNoDataAndKeepsTheValues() async {
        let fixture = PollerFixture([ok(37)])
        await fixture.start()
        fixture.keychain.set(noKeychain)
        await fixture.nextPoll(after: .seconds(300))
        #expect(fixture.fetches == 1)
        #expect(fixture.poller.value == usage(percent: 37))
        #expect(fixture.poller.lastResult == .noData)
        #expect(fixture.log.values == [.noToken])
    }

    @Test(arguments: [401, 403])
    func anExpiredLoginGivesNoDataAndClearsTheValues(status: Int) async {
        let fixture = PollerFixture([ok(37), UsageResponse(status: status, body: Data())])
        await fixture.start()
        await fixture.nextPoll(after: .seconds(300))
        #expect(fixture.poller.value == nil)
        #expect(fixture.poller.lastResult == .noData)
        #expect(fixture.log.values == [.loginRefused(status: status)])
        // The next poll reads the token again, because Claude Code refreshes it.
        #expect(await fixture.nextTimer() == .seconds(600))
    }

    // The status decides when the read of the body failed (UsageResponse.body is nil): a 401 or a
    // 403 is a refused login, and a 429 is a rate limit with the wait of 15 minutes.
    @Test(arguments: [401, 403])
    func aRefusedLoginWithAFailedReadIsStillRefused(status: Int) async {
        let fixture = PollerFixture([ok(37), UsageResponse(status: status, body: nil)])
        await fixture.start()
        await fixture.nextPoll(after: .seconds(300))
        #expect(fixture.poller.value == nil)
        #expect(fixture.log.values == [.loginRefused(status: status)])
    }

    @Test func aRateLimitWithAFailedReadStillWaitsFifteenMinutes() async {
        let fixture = PollerFixture([ok(37), UsageResponse(status: 429, body: nil), ok(41)])
        await fixture.start()
        await fixture.nextPoll(after: .seconds(300))
        #expect(fixture.log.values == [.rateLimited])
        #expect(await fixture.nextTimer() == .seconds(1200))
    }

    @Test func theRateLimitWaitsFifteenMinutesAndKeepsTheValues() async {
        let fixture = PollerFixture([ok(37), UsageResponse(status: 429, body: nil), ok(41)])
        await fixture.start()
        await fixture.nextPoll(after: .seconds(300))
        #expect(fixture.poller.value == usage(percent: 37))
        #expect(fixture.poller.lastResult == .noData)
        #expect(fixture.log.values == [.rateLimited])
        #expect(await fixture.nextTimer() == .seconds(1200))
        // The HUD does not poll during the wait.
        fixture.clock.advance(by: .seconds(120))
        fixture.poller.hudOpened()
        #expect(fixture.poller.pollTask == nil)
        // A stop and a start do not end the wait.
        fixture.poller.stop()
        fixture.poller.start()
        #expect(fixture.poller.pollTask == nil)
        #expect(await fixture.nextTimer() == .seconds(1200))
        await fixture.nextPoll(after: .seconds(780))
        #expect(fixture.fetches == 3)
        #expect(fixture.poller.value == usage(percent: 41))
        #expect(await fixture.nextTimer() == .seconds(1500))
    }

    @Test(arguments: [500, 404, 302, 100])
    func aBadStatusFailsAndKeepsTheValues(status: Int) async {
        let bad = UsageResponse(status: status, body: answer(percent: 41))
        let fixture = PollerFixture([ok(37), bad])
        await fixture.start()
        await fixture.nextPoll(after: .seconds(300))
        #expect(fixture.poller.value == usage(percent: 37))
        #expect(fixture.poller.lastResult == .failed)
        #expect(fixture.log.values == [.badStatus(status)])
    }

    @Test func aFetchErrorFailsAndKeepsTheValues() async {
        let fixture = PollerFixture([ok(37), nil])
        await fixture.start()
        await fixture.nextPoll(after: .seconds(300))
        #expect(fixture.poller.value == usage(percent: 37))
        #expect(fixture.poller.lastResult == .failed)
        #expect(fixture.log.values == [.fetchFailed])
    }

    @Test func aReadErrorFailsAndKeepsTheValues() async {
        let fixture = PollerFixture([ok(37), UsageResponse(status: 200, body: nil)])
        await fixture.start()
        await fixture.nextPoll(after: .seconds(300))
        #expect(fixture.poller.value == usage(percent: 37))
        #expect(fixture.poller.lastResult == .failed)
        #expect(fixture.log.values == [.readFailed])
    }

    @Test func aBadAnswerFailsAndClearsTheValues() async {
        let large = Data(repeating: UInt8(ascii: " "), count: AccountAnswer.maxBytes + 1)
        let fixture = PollerFixture([
            ok(37), UsageResponse(status: 200, body: Data("{}".utf8)), ok(41),
            UsageResponse(status: 200, body: large),
        ])
        await fixture.start()
        await fixture.nextPoll(after: .seconds(300))
        #expect(fixture.poller.value == nil)
        #expect(fixture.poller.lastResult == .failed)
        await fixture.nextPoll(after: .seconds(300))
        #expect(fixture.poller.value == usage(percent: 41))
        await fixture.nextPoll(after: .seconds(300))
        #expect(fixture.poller.value == nil)
        #expect(fixture.log.values == [.badAnswer, .badAnswer])
    }

    @Test func aPollNeverLastsPastItsDeadline() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let fixture = PollerFixture([ok(37), ok(41)], fetchGate: gate)
        gate.open()
        await fixture.start()
        let timer = fixture.poller.timerTask
        fixture.clock.advance(by: .seconds(300))
        await timer?.value
        let poll = fixture.poller.pollTask
        // The second fetch hangs and does not see the cancel. The poll ends at its deadline.
        await gate.waitUntilHolding(1)
        let request = fixture.poller.requestTask
        await fixture.clock.waitForSleepers(exactly: 1)
        #expect(fixture.clock.nextDeadline?.offset == .seconds(325))
        fixture.clock.advance(by: .seconds(25))
        await poll?.value
        #expect(fixture.poller.lastResult == .failed)
        #expect(fixture.poller.value == usage(percent: 37))
        #expect(fixture.log.values == [.pastDeadline])
        #expect(await fixture.nextTimer() == .seconds(625))
        // The answer after the deadline changes nothing.
        gate.open()
        _ = await request?.value
        #expect(fixture.poller.value == usage(percent: 37))
        #expect(fixture.poller.lastResult == .failed)
    }

    @Test func aStopClearsTheValuesAndEndsThePolling() async {
        let fixture = PollerFixture([ok(37)])
        await fixture.start()
        fixture.poller.stop()
        #expect(fixture.poller.value == nil)
        #expect(fixture.poller.lastResult == nil)
        await fixture.clock.waitUntilNoSleepers()
        fixture.clock.advance(by: .seconds(3600))
        fixture.poller.hudOpened()
        #expect(fixture.poller.pollTask == nil)
        #expect(fixture.fetches == 1)
    }

    @Test func aStopDuringAPollChangesNothing() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let fixture = PollerFixture([ok(37), ok(41)], fetchGate: gate)
        gate.open()
        await fixture.start()
        let timer = fixture.poller.timerTask
        fixture.clock.advance(by: .seconds(300))
        await timer?.value
        let poll = fixture.poller.pollTask
        await gate.waitUntilHolding(1)
        let request = fixture.poller.requestTask
        fixture.poller.stop()
        #expect(fixture.poller.value == nil)
        await poll?.value
        gate.open()
        _ = await request?.value
        #expect(fixture.poller.value == nil)
        #expect(fixture.poller.lastResult == nil)
        #expect(fixture.log.values.isEmpty)
        await fixture.clock.waitUntilNoSleepers()
    }

    @Test func aStopDuringTheTokenReadSendsNoRequest() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let fixture = PollerFixture([ok(37)], keychainGate: gate)
        fixture.poller.start()
        await gate.waitUntilHolding(1)
        let request = fixture.poller.requestTask
        fixture.poller.stop()
        gate.open()
        _ = await request?.value
        #expect(fixture.fetches == 0)
        #expect(fixture.poller.value == nil)
    }

    @Test func aStartAfterAStopPollsAgain() async {
        let fixture = PollerFixture([ok(37), ok(41)])
        await fixture.start()
        fixture.poller.stop()
        await fixture.start()
        #expect(fixture.fetches == 2)
        #expect(fixture.poller.value == usage(percent: 41))
    }

    // A start after a stop polls again while the request of the old poll still waits. The old
    // request then ends, and its answer changes nothing: the values come from the new poll.
    @Test func aStartAfterAStopIgnoresTheOldRequest() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let fixture = PollerFixture([ok(37), ok(41)], fetchGate: gate)
        fixture.poller.start()
        await gate.waitUntilHolding(1)
        let old = fixture.poller.requestTask
        fixture.poller.stop()
        fixture.poller.start()
        await gate.waitUntilHolding(2)
        let poll = fixture.poller.pollTask
        // The gate lets the callers through in the order of arrival: the old request first.
        gate.open()
        _ = await old?.value
        #expect(fixture.poller.value == nil)
        #expect(fixture.poller.lastResult == nil)
        gate.open()
        await poll?.value
        #expect(fixture.fetches == 2)
        #expect(fixture.poller.value == usage(percent: 41))
        #expect(fixture.log.values.isEmpty)
    }

    @Test func openingTheHUDPollsAtMostOnceAMinute() async {
        let fixture = PollerFixture([ok(37), ok(41)])
        await fixture.start()
        fixture.poller.hudOpened()
        #expect(fixture.poller.pollTask == nil)
        fixture.clock.advance(by: .seconds(59))
        fixture.poller.hudOpened()
        #expect(fixture.poller.pollTask == nil)
        fixture.clock.advance(by: .seconds(1))
        fixture.poller.hudOpened()
        await fixture.poller.pollTask?.value
        #expect(fixture.fetches == 2)
        #expect(fixture.poller.value == usage(percent: 41))
        // The poll of the HUD moves the next timer.
        #expect(await fixture.nextTimer() == .seconds(360))
    }

    @Test func openingTheHUDWhileStoppedOrDuringAPollDoesNothing() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let fixture = PollerFixture([ok(37)], fetchGate: gate)
        fixture.poller.hudOpened()
        #expect(fixture.poller.pollTask == nil)
        fixture.poller.start()
        await gate.waitUntilHolding(1)
        let poll = fixture.poller.pollTask
        fixture.poller.hudOpened()
        #expect(fixture.poller.pollTask == poll)
        gate.open()
        await poll?.value
        #expect(fixture.fetches == 1)
    }

    @Test func noLogLineHoldsTheToken() async {
        let fixture = PollerFixture(
            [
                UsageResponse(status: 401, body: Data(fakeToken.utf8)),
                UsageResponse(status: 429, body: Data(fakeToken.utf8)),
                UsageResponse(status: 500, body: Data(fakeToken.utf8)),
                nil,
                UsageResponse(status: 200, body: nil),
                UsageResponse(status: 200, body: Data("{\"t\":\"\(fakeToken)\"}".utf8)),
            ])
        await fixture.start()
        for wait in [300, 900, 300, 300, 300] {
            await fixture.nextPoll(after: .seconds(wait))
        }
        fixture.keychain.set(noKeychain)
        await fixture.nextPoll(after: .seconds(300))
        let events = fixture.log.values
        #expect(
            events == [
                .loginRefused(status: 401), .rateLimited, .badStatus(500), .fetchFailed,
                .readFailed, .badAnswer, .noToken,
            ])
        for event in events {
            #expect(!String(reflecting: event).contains(fakeToken))
            #expect(!event.message.contains(fakeToken))
            #expect(!event.message.isEmpty)
        }
        #expect(!AccountUsageEvent.pastDeadline.message.contains(fakeToken))
    }

    @Test func theStatusOfThePollerHoldsNoToken() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let fixture = PollerFixture([ok(37), ok(41)], fetchGate: gate)
        gate.open()
        await fixture.start()
        let timer = fixture.poller.timerTask
        fixture.clock.advance(by: .seconds(300))
        await timer?.value
        // During a request and after it, no value of the poller holds the token.
        await gate.waitUntilHolding(1)
        #expect(!fields(of: fixture.poller).contains(fakeToken))
        gate.open()
        await fixture.poller.pollTask?.value
        #expect(!fields(of: fixture.poller).contains(fakeToken))
        #expect(!String(reflecting: fixture.poller.value).contains(fakeToken))
        #expect(!String(reflecting: fixture.poller.lastResult).contains(fakeToken))
    }
}

// The text of each stored value of the poller. A value that is an object shows only its type.
private func fields(of poller: AccountPoller) -> String {
    Mirror(reflecting: poller).children
        .map { "\($0.label ?? "?") = \(String(reflecting: $0.value))" }
        .joined(separator: "\n")
}
