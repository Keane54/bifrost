import BifrostTestSupport
import Testing

@testable import BifrostLive

// The new reads of the Live details status while a warning shows (docs/behaviour/live.md, "The
// warning dot"). The first read can give a short failure, for example before the server listens,
// and the warning dot must then go away by itself.

private let on = LiveStatus(
    plugin: .enabled, modCurrent: true, oldInstall: false, listening: true, liveSessions: 0,
    claudeVersion: "2.1.318", versionOk: true, error: nil)
// The status of a read before the server listens.
private let notReceiving = LiveStatus(
    plugin: .enabled, modCurrent: true, oldInstall: false, listening: false, liveSessions: 0,
    claudeVersion: "2.1.318", versionOk: true, error: nil)
private let goodVersion = ClaudeVersionCheck(
    version: "2.1.318", ok: true, minimum: ClaudeVersionCheck.liveMinimum)

// The model of the app as the retry sees it. The first read ended at the start. Each read sets
// the warning, as the model does. While an action runs, a read does nothing, and the version is
// read again only when it is not good: the two closures of the model have these rules.
@MainActor
private final class World {
    let clock = ManualClock()
    let first: LiveStatus
    var status: LiveStatus
    // The status of each later read, or nil for the first status.
    var next: LiveStatus?
    var version: ClaudeVersionCheck?
    var versionFailed: Bool
    // The number of version reads that fail before one works.
    var versionFails: Int
    var busy = false
    // A status read waits at this gate while it is set.
    var hold: TestGate?
    private(set) var statusReads = 0
    private(set) var versionReads = 0
    // The time of each status read from the start, in seconds.
    private(set) var at: [Int64] = []
    private(set) var retry: LiveRetry!

    init(
        status: LiveStatus, next: LiveStatus? = nil, version: ClaudeVersionCheck? = goodVersion,
        versionFailed: Bool = false, versionFails: Int = 0
    ) {
        first = status
        self.status = status
        self.next = next
        self.version = version
        self.versionFailed = versionFailed
        self.versionFails = versionFails
        retry = LiveRetry(
            clock: clock, read: { [unowned self] in await self.readStatus() },
            readVersion: { [unowned self] in await self.readVersion() })
        retry.readEnded()
        retry.warn(warning)
    }

    var warning: Bool { LiveRules.hasWarning(status, version, versionFailed: versionFailed) }

    private func readStatus() async {
        guard !busy else { return }
        statusReads += 1
        at.append(clock.now.offset.components.seconds)
        if let hold { await hold.pass() }
        status = next ?? first
        retry.warn(warning)
    }

    private func readVersion() async {
        guard !busy, versionFailed || version?.ok != true else { return }
        versionReads += 1
        if versionFails > 0 {
            versionFails -= 1
            return
        }
        version = goodVersion
        versionFailed = false
        retry.warn(warning)
    }

    var reads: [Int] { [statusReads, versionReads] }

    // Move the clock on by the time. Each step that comes acts at its own time, and its read ends
    // before the next step, unless the read waits at the gate.
    func advance(_ time: Duration) async {
        let target = clock.now.offset + time
        while retry.isWaiting {
            await clock.waitForSleepers(1)
            guard let next = clock.nextDeadline, next.offset <= target else { break }
            let step = retry.timerTask
            clock.advance(by: next.offset - clock.now.offset)
            await step?.value
            if hold == nil { await retry.readTask?.value }
        }
        clock.advance(by: target - clock.now.offset)
    }

    // Move the clock on by the time, then give a focus of the window, and wait for its read.
    func focus(after time: Duration) async {
        await advance(time)
        let read = retry.focus()
        if hold == nil { await read?.value }
    }
}

private let minute = Duration.seconds(60)

@MainActor
@Suite("the new reads of the Live details status", .timeLimit(.minutes(1)))
struct LiveRetryTests {
    @Test func theStepsAndTheTwoGaps() {
        #expect(LiveRetry.steps == [minute, minute * 2, minute * 5, minute * 10])
        #expect(LiveRetry.focusGap == minute * 5)
        #expect(LiveRetry.recentRead == .seconds(30))
    }

    @Test func aReadAfterOneMinuteClearsTheWarningAndTheTimer() async {
        let w = World(status: notReceiving, next: on)
        #expect(w.warning)
        await w.advance(minute - .milliseconds(1))
        #expect(w.reads == [0, 0])
        await w.advance(.milliseconds(1))
        #expect(w.reads == [1, 0])
        #expect(!w.warning)
        #expect(!w.retry.isWaiting)
        await w.advance(minute * 30)
        #expect(w.reads == [1, 0])
    }

    @Test func theReadsComeAtOneTwoFiveAndTenMinutesThenStop() async {
        let w = World(status: notReceiving)
        await w.advance(minute * 10)
        #expect(w.at == [60, 120, 300, 600])
        #expect(!w.retry.isWaiting)
        await w.advance(minute * 60)
        #expect(w.at == [60, 120, 300, 600])
        #expect(w.warning)
    }

    @Test func onlyANewWarningStartsTheStepsAgain() async {
        let w = World(status: notReceiving)
        await w.advance(minute * 2)
        // The warning stays, so the steps go on from the first warning.
        w.retry.warn(true)
        await w.advance(minute * 3)
        #expect(w.at == [60, 120, 300])
        // The warning goes and comes back at 5 minutes, so the steps start again.
        w.retry.warn(false)
        #expect(!w.retry.isWaiting)
        w.retry.warn(true)
        await w.advance(minute * 2)
        #expect(w.at == [60, 120, 300, 360, 420])
    }

    @Test func withNoWarningNoTimerWaitsAndNothingReads() async {
        let w = World(status: on)
        #expect(!w.warning)
        #expect(!w.retry.isWaiting)
        await w.focus(after: minute * 30)
        #expect(w.reads == [0, 0])
    }

    @Test func aReadThatEndedLessThan30SecondsBeforeAStepCountsAsTheStep() async {
        let w = World(status: notReceiving)
        // A Settings read ends at 40 s. It counts as the step at 1 minute.
        await w.advance(.seconds(40))
        w.retry.readEnded()
        await w.advance(.seconds(20))
        #expect(w.reads == [0, 0])
        // A read that ended 30 s before the step does not count as the step.
        await w.advance(.seconds(30))
        w.retry.readEnded()
        await w.advance(.seconds(30))
        #expect(w.at == [120])
    }

    @Test func aFocusReadsOnlyWhenTheLastReadEndedFiveMinutesOrMoreAgo() async {
        let w = World(status: notReceiving)
        // The last step reads at 10 minutes.
        await w.advance(minute * 10)
        await w.focus(after: LiveRetry.focusGap - .milliseconds(1))
        #expect(w.reads[0] == 4)
        await w.focus(after: .milliseconds(1))
        #expect(w.reads[0] == 5)
        await w.focus(after: .zero)
        #expect(w.reads[0] == 5)
        // A Settings read or the read of an action counts too.
        await w.advance(LiveRetry.focusGap)
        w.retry.readEnded()
        await w.focus(after: LiveRetry.focusGap - .milliseconds(1))
        #expect(w.reads[0] == 5)
    }

    @Test func aReadCountsFromItsEndNotFromItsStart() async {
        let w = World(status: notReceiving)
        await w.advance(minute * 15)
        let slow = TestGate()
        defer { slow.openAll() }
        w.hold = slow
        let read = w.retry.focus()
        #expect(read != nil)
        await slow.waitUntilHolding(1)
        #expect(w.reads[0] == 5)
        // The read takes 2 minutes.
        await w.advance(minute * 2)
        w.hold = nil
        slow.open()
        await read?.value
        await w.focus(after: LiveRetry.focusGap - .milliseconds(1))
        #expect(w.reads[0] == 5)
        await w.focus(after: .milliseconds(1))
        #expect(w.reads[0] == 6)
    }

    @Test func theWarningStaysAfterTheLastStepUntilAFocusReadClearsIt() async {
        let w = World(status: notReceiving)
        await w.advance(minute * 10)
        // The problem ends after the last step, and no timer reads it.
        w.next = on
        await w.advance(minute * 20)
        #expect(w.reads[0] == 4)
        #expect(w.warning)
        await w.focus(after: .zero)
        #expect(w.reads[0] == 5)
        #expect(!w.warning)
    }

    @Test func nothingReadsWhileAnActionRuns() async {
        let w = World(status: notReceiving)
        w.busy = true
        await w.advance(minute)
        #expect(w.reads == [0, 0])
        w.busy = false
        await w.advance(minute)
        #expect(w.at == [120])
        // A focus while an action runs does not read either.
        await w.advance(minute * 8)
        w.busy = true
        await w.focus(after: LiveRetry.focusGap)
        #expect(w.reads[0] == 3)
    }

    @Test func aSecondReadDoesNotStartWhileAReadRuns() async {
        let slow = TestGate()
        defer { slow.openAll() }
        let w = World(status: notReceiving, next: on)
        w.hold = slow
        await w.advance(minute)
        let read = w.retry.readTask
        await slow.waitUntilHolding(1)
        await w.advance(minute * 9)
        #expect(w.reads[0] == 1)
        #expect(w.retry.focus() == nil)
        slow.open()
        await read?.value
        #expect(!w.warning)
    }

    @Test func aFailedVersionIsReadAgainUntilItWorksThenTheWarningGoes() async {
        let w = World(status: on, version: nil, versionFailed: true, versionFails: 1)
        #expect(w.warning)
        await w.advance(minute)
        #expect(w.reads == [1, 1])
        #expect(w.versionFailed)
        await w.advance(minute)
        #expect(w.reads == [2, 2])
        #expect(w.version == goodVersion && !w.versionFailed)
        #expect(!w.warning)
        #expect(!w.retry.isWaiting)
    }

    // A timeout of claude --version gives an answer with no version.
    @Test func anAnswerWithNoVersionIsReadAgainAndAGoodAnswerClearsIt() async {
        let none = ClaudeVersionCheck(
            version: nil, ok: false, minimum: ClaudeVersionCheck.liveMinimum)
        let w = World(status: on, version: none)
        #expect(w.warning)
        await w.advance(minute)
        #expect(w.reads == [1, 1])
        #expect(w.version == goodVersion && !w.versionFailed)
        #expect(!w.warning)
        #expect(!w.retry.isWaiting)
    }

    @Test func aGoodVersionIsNotReadAgain() async {
        let w = World(status: notReceiving)
        await w.advance(minute)
        #expect(w.reads == [1, 0])
    }

    // The stop of the owner ends the steps, and a later warning starts none.
    @Test func aStopEndsTheStepsForGood() async {
        let w = World(status: notReceiving)
        #expect(w.retry.isWaiting)
        w.retry.stop()
        #expect(!w.retry.isWaiting)
        w.retry.warn(false)
        w.retry.warn(true)
        #expect(!w.retry.isWaiting)
        await w.focus(after: minute * 10)
        #expect(w.reads == [0, 0])
    }
}
