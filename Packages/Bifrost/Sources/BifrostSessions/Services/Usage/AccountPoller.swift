import BifrostFoundation
import Foundation
import Observation

// Polls the usage endpoint of the account while account usage is on in Settings
// (docs/behaviour/usage.md, "The account values"): at the start, then each 5 minutes, and when
// the Usage HUD opens, at most one time in a minute.
//
// SECURITY: the token lives in memory for one request. Each poll reads it again from the
// Keychain, gives it to the fetcher and drops it. The poller never keeps it in a property, never
// logs it and never sends it to another URL. It never refreshes a token: after no token, a 401
// or a 403 it reads the Keychain again at the next poll, because Claude Code refreshes the token
// itself.
//
// One poll runs at a time, as one task. Its request runs in a second task, so a request that
// hangs cannot hold the poll past its deadline: at the deadline the poll ends, and the request
// gets a cancel. A stop cancels the poll and its request, so an old poll changes nothing.
//
// The health log of the app (HealthReporter) gets the result of each poll (lastResult), and a
// stop.
@MainActor
@Observable
package final class AccountPoller {
    nonisolated package static let interval = Duration.seconds(300)
    nonisolated package static let hudGap = Duration.seconds(60)
    nonisolated package static let rateLimitWait = Duration.seconds(900)
    nonisolated package static let requestTimeout = Duration.seconds(10)
    // A poll ends at this time, also when its request does not.
    nonisolated package static let deadline = Duration.seconds(25)

    // The values of the last good answer. nil before it, and after a stop, an expired login or a
    // bad answer.
    package private(set) var value: AccountUsage?
    // The result of the last poll. nil before the first poll and after a stop.
    package private(set) var lastResult: PollResult?

    private enum Phase {
        case stopped
        // On, and no poll runs. The timer waits for the next poll.
        case waiting
        // On, and this poll runs.
        case polling(Task<Void, Never>)
    }

    // What one request gave: new values, or the reason that it gave none.
    package enum Outcome: Sendable {
        case values(AccountUsage)
        case problem(AccountUsageEvent)
    }

    @ObservationIgnored private let runner: any CommandRunner
    @ObservationIgnored private let fetcher: any UsageFetcher
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let timeline: Timeline
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let log: any AccountUsageLog
    @ObservationIgnored private let health: HealthReporter
    @ObservationIgnored private let timer: TimerSlot
    @ObservationIgnored private var phase = Phase.stopped
    // The start of the last poll on the timeline. A stop forgets it.
    @ObservationIgnored private var lastPollAt: Duration?
    // The end of the wait after a 429 on the timeline. The wait holds across a stop.
    @ObservationIgnored private var waitUntil: Duration?
    // The task of the last request. It can outlive its poll after the deadline or a stop, until
    // it sees the cancel. A test waits for it.
    @ObservationIgnored package private(set) var requestTask: Task<Outcome, Never>?

    package init(
        runner: any CommandRunner, fetcher: any UsageFetcher, clock: any Clock<Duration>,
        now: @escaping @Sendable () -> Date, log: any AccountUsageLog = SystemAccountUsageLog(),
        health: HealthReporter = .none
    ) {
        self.runner = runner
        self.fetcher = fetcher
        self.now = now
        self.log = log
        self.health = health
        self.clock = clock
        timeline = Timeline(clock)
        timer = TimerSlot(clock: clock)
    }

    // The task of the poll that runs, or nil. A test waits for it.
    package var pollTask: Task<Void, Never>? {
        if case .polling(let task) = phase { task } else { nil }
    }

    // The task of the timer of the next poll, or nil. A test waits for it.
    package var timerTask: Task<Void, Never>? { timer.task }

    // Poll now, then each 5 minutes. A second call does nothing. A wait after a 429 from before
    // a stop still holds: the first poll then comes at the end of the wait, or 5 minutes after
    // the start when that is later.
    package func start() {
        guard case .stopped = phase else { return }
        phase = .waiting
        if let waitUntil, timeline.now() < waitUntil {
            schedule()
        } else {
            poll()
        }
    }

    // End the polling and clear the values. A poll that runs changes nothing more, and its
    // request gets a cancel. The health log gets the stop, so the failures in a row end. A
    // poller that does not poll changes nothing.
    package func stop() {
        if case .stopped = phase { return }
        health.record(.stopped(.accountUsage))
        if case .polling(let task) = phase { task.cancel() }
        requestTask?.cancel()
        phase = .stopped
        timer.stop()
        lastPollAt = nil
        lastResult = nil
        value = nil
    }

    // The Usage HUD opened. Poll now, but not during a poll, not within a minute of the last
    // poll and not during the wait after a 429.
    package func hudOpened() {
        guard case .waiting = phase else { return }
        let now = timeline.now()
        if let lastPollAt, now - lastPollAt < Self.hudGap { return }
        if let waitUntil, now < waitUntil { return }
        poll()
    }

    // Start one poll. The poll starts the timer of the next poll at its end.
    private func poll() {
        guard case .waiting = phase else { return }
        timer.stop()
        lastPollAt = timeline.now()
        phase = .polling(Task { [weak self] in await self?.run() })
    }

    private func run() async {
        // A stop before the start of the task: no Keychain read.
        guard !Task.isCancelled else { return }
        let outcome = await requestWithDeadline()
        // A stop cancelled this poll, so it changes nothing.
        guard !Task.isCancelled else { return }
        apply(outcome ?? .problem(.pastDeadline))
        phase = .waiting
        schedule()
    }

    // The outcome of the request, or nil when the deadline comes first or a stop cancels the
    // poll (firstResult). The poll does not wait for the end of the request: it gives the
    // request a cancel.
    private func requestWithDeadline() async -> Outcome? {
        let request = Task { [runner, fetcher, now] in
            await Self.request(runner: runner, fetcher: fetcher, now: now)
        }
        requestTask = request
        let outcome = await firstResult(of: request, within: Self.deadline, on: clock)
        request.cancel()
        return outcome
    }

    // One request: read the token, fetch, and parse the answer. It runs off the main actor. The
    // token is a local value of this function and goes only to the fetcher.
    @concurrent
    nonisolated private static func request(
        runner: any CommandRunner, fetcher: any UsageFetcher, now: @Sendable () -> Date
    ) async -> Outcome {
        guard let token = await AccessToken.read(runner, now: now()) else {
            return .problem(.noToken)
        }
        // A stop or the deadline during the Keychain read: drop the token and send nothing.
        guard !Task.isCancelled else { return .problem(.pastDeadline) }
        guard let response = await fetcher.fetch(token: token, timeout: requestTimeout) else {
            return .problem(.fetchFailed)
        }
        switch response.status {
        case 401, 403: return .problem(.loginRefused(status: response.status))
        case 429: return .problem(.rateLimited)
        case 200..<300: break
        default: return .problem(.badStatus(response.status))
        }
        // A read error is not a bad answer, so the old values stay.
        guard let body = response.body else { return .problem(.readFailed) }
        guard let usage = AccountAnswer.parse(body, fetchedAt: now().millisecondsSince1970) else {
            return .problem(.badAnswer)
        }
        return .values(usage)
    }

    private func apply(_ outcome: Outcome) {
        let result: PollResult
        switch outcome {
        case .values(let usage):
            value = usage
            result = .ok
        case .problem(let event):
            log.record(event)
            if event == .rateLimited { waitUntil = timeline.now() + Self.rateLimitWait }
            if event.clearsValues { value = nil }
            result = event.result
        }
        lastResult = result
        health.record(.poll(.accountUsage, result))
    }

    // Start the timer of the next poll: after 5 minutes, or at the end of the wait after a 429
    // when that is later.
    private func schedule() {
        var wait = Self.interval
        if let waitUntil { wait = max(wait, waitUntil - timeline.now()) }
        timer.start(after: wait) { [weak self] in self?.poll() }
    }
}
