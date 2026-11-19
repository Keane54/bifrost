import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Observation
import Synchronization
import Testing

// The usage notification monitor (docs/behaviour/usage.md, "The usage notification"). SAFETY: no
// test shows a notification. The monitor gives each text to a recording closure, and the read of
// the flag reads a fake or the file of a temporary home, never the real ~/.claude.json.

private let start = utcMs(2026, 11, 10, 12, 0)
private let minute = 60_000
private let hour = 60 * minute
private let fiveReset = start + 2 * hour + 5 * minute
private let sevenReset = utcMs(2026, 11, 13, 13, 0)
private let warning = "Warning: extra usage is on"

private struct Shown: Equatable {
    var title: String
    var body: String
}

private let offText = Shown(
    title: "5-hour limit at 92%",
    body: "Claude Code stops at 100% until the limit resets at 14:05.")
private let warningText = Shown(
    title: warning,
    body: "Your 5-hour limit is at 92%. After 100%, Claude Code spends your extra usage credits, "
        + "which costs real money. It resets at 14:05.")

private func fiveAt(_ usedPercent: Double, _ resetsAt: Int = fiveReset) -> RateLimits {
    RateLimits(fiveHour: RateWindow(usedPercent: usedPercent, resetsAt: resetsAt))
}

private func snap(_ limits: RateLimits) -> UsageSnapshot {
    UsageSnapshot(
        sessionId: "abcdef12-0000", name: "bifrost-test-a", updatedAt: start, limits: limits)
}

private func account(_ limits: RateLimits, extraUsage: Bool? = nil, fetchedAt: Int = start)
    -> AccountUsage
{
    AccountUsage(fetchedAt: fetchedAt, limits: limits, extraUsage: extraUsage)
}

private func date(_ ms: Int) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

// The read of the flag of ~/.claude.json in a test: it gives a fixed value and counts the reads.
// With a gate, each read waits at it first.
private final class FakeFlag: Sendable {
    private let value: Bool
    private let homes = Mutex<[URL]>([])
    let gate: TestGate?

    init(_ value: Bool = false, gate: TestGate? = nil) {
        self.value = value
        self.gate = gate
    }

    var reads: [URL] { homes.withLock { $0 } }

    func read(_ home: URL) async -> Bool {
        homes.withLock { $0.append(home) }
        await gate?.pass()
        return value
    }
}

// The inputs of the monitor that a test changes, and the texts that it shows.
@MainActor
private final class Inputs {
    var now = start
    var enabled = true
    var shown: [Shown] = []
}

// A monitor with a real store in a temporary folder. The home is a folder of that folder.
@MainActor
private final class MonitorFixture {
    let folder: TemporaryFolder
    let file: URL
    let home: URL
    let inputs = Inputs()
    let flag: FakeFlag?
    let writes = WriteCounter()
    let log = Recorder<StoreEvent>()
    private(set) var store: UsageAlertStore
    private(set) var monitor: UsageAlertMonitor

    // flag nil reads the file of the home.
    init(enabled: Bool = true, flag: FakeFlag? = FakeFlag(), kept: NotifiedPeriods? = nil)
        async throws
    {
        folder = try TemporaryFolder(short: true)
        file = folder.url.appending(path: "usage-alerts.json")
        home = folder.url.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        if let kept { try JSONFile.encode(kept).write(to: file) }
        self.flag = flag
        inputs.enabled = enabled
        store = await UsageAlertStore.open(
            file: file, now: date(start), log: log, steps: writes.steps)
        monitor = Self.monitor(store, home: home, inputs: inputs, flag: flag)
    }

    var shown: [Shown] { inputs.shown }
    var reads: Int { flag?.reads.count ?? 0 }

    private static func monitor(
        _ store: UsageAlertStore, home: URL, inputs: Inputs, flag: FakeFlag?
    ) -> UsageAlertMonitor {
        let enabled: @MainActor () -> Bool = { inputs.enabled }
        let notify: @MainActor (String, String) -> Void = { title, body in
            inputs.shown.append(Shown(title: title, body: body))
        }
        let now = { date(inputs.now) }
        guard let flag else {
            return UsageAlertMonitor(
                store: store, home: home, enabled: enabled, notify: notify, now: now, zone: .gmt)
        }
        return UsageAlertMonitor(
            store: store, home: home, enabled: enabled, notify: notify, now: now, zone: .gmt,
            readFlag: { await flag.read($0) })
    }

    // The values that the monitor has now. A change of one gives both to the monitor, as a
    // change that the follow of the shell sees does.
    private var lastSession: UsageSnapshot?
    private var lastAccount: AccountUsage?

    // New session values from the usage lines, or nil.
    func session(_ value: UsageSnapshot?) {
        lastSession = value
        monitor.update(session: value, account: lastAccount)
    }

    // New account values from the poller, or nil.
    func account(_ value: AccountUsage?) {
        lastAccount = value
        monitor.update(session: lastSession, account: value)
    }

    // Wait for the read of the flag and for the save of the periods.
    func settle() async {
        await monitor.flagRead?.value
        await monitor.save?.value
    }

    // A new run of the app: a new store reads the file, and a new monitor uses it.
    func restart() async {
        await settle()
        monitor.stop()
        store = await UsageAlertStore.open(
            file: file, now: date(inputs.now), log: log, steps: writes.steps)
        inputs.shown = []
        (lastSession, lastAccount) = (nil, nil)
        monitor = Self.monitor(store, home: home, inputs: inputs, flag: flag)
    }

    func writeClaudeJSON(_ text: String) throws {
        try Data(text.utf8).write(to: ClaudeJSON.file(home: home))
    }
}

// Run the body with a fixture, then wait for its work and remove its folder.
@MainActor
private func withMonitor(
    enabled: Bool = true, flag: FakeFlag? = FakeFlag(), kept: NotifiedPeriods? = nil,
    _ body: (MonitorFixture) async throws -> Void
) async throws {
    let fixture = try await MonitorFixture(enabled: enabled, flag: flag, kept: kept)
    defer { fixture.folder.remove() }
    try await body(fixture)
    await fixture.settle()
    fixture.monitor.stop()
}

// The values that the shell follows: the session usage of the registry and the account values
// of the poller.
@MainActor
@Observable
private final class Sources {
    var session: UsageSnapshot?
    var account: AccountUsage?
}

@MainActor
@Suite("usage alert monitor", .timeLimit(.minutes(1)))
struct UsageAlertMonitorTests {
    @Test func sessionValuesAt90PercentOrMoreShowOneNotification() async throws {
        try await withMonitor { f in
            f.session(snap(fiveAt(91.6)))
            await f.settle()
            #expect(f.shown == [offText])
            #expect(f.store.periods == NotifiedPeriods(fiveHour: fiveReset))
            let saved = try readSaved(f.file)
            #expect(saved == ["fiveHour": .int(fiveReset), "sevenDay": .null])
        }
    }

    @Test func valuesBelow90PercentAndNoValuesShowNothing() async throws {
        try await withMonitor { f in
            f.session(snap(fiveAt(89)))
            f.session(nil)
            f.account(nil)
            await f.settle()
            #expect(f.shown == [])
            #expect(f.writes.writes == 0)
            #expect(f.reads == 0)
        }
    }

    @Test func aLimitNotifiesOneTimeInEachPeriod() async throws {
        try await withMonitor { f in
            f.session(snap(fiveAt(92)))
            await f.settle()
            f.session(snap(fiveAt(95)))
            // The account values give a reset time 5 minutes later for the same period.
            f.account(account(fiveAt(97, fiveReset + 5 * minute), extraUsage: false))
            await f.settle()
            #expect(f.shown.count == 1)
            // The next period notifies again.
            let next = fiveReset + 5 * hour
            f.inputs.now = fiveReset + minute
            f.account(account(fiveAt(93, next), extraUsage: false, fetchedAt: fiveReset))
            await f.settle()
            #expect(f.shown.count == 2)
            #expect(f.store.periods.fiveHour == next)
        }
    }

    @Test func aResetTimeThatMovesLaterInSmallStepsStaysInTheSamePeriod() async throws {
        try await withMonitor { f in
            f.session(snap(fiveAt(92)))
            await f.settle()
            #expect(f.shown.count == 1)
            f.session(snap(fiveAt(93, fiveReset + 10 * minute)))
            await f.settle()
            #expect(f.store.periods.fiveHour == fiveReset + 10 * minute)
            // 16 minutes after the first reset time, but 6 minutes after the kept value.
            f.session(snap(fiveAt(94, fiveReset + 16 * minute)))
            await f.settle()
            #expect(f.shown.count == 1)
            #expect(f.store.periods.fiveHour == fiveReset + 16 * minute)
            // The same value again writes nothing new.
            let writes = f.writes.writes
            f.session(snap(fiveAt(95, fiveReset + 16 * minute)))
            await f.settle()
            #expect(f.writes.writes == writes)
        }
    }

    @Test func theKeptPeriodFollowsALaterResetTimeAlsoWithTheSettingOff() async throws {
        try await withMonitor(enabled: false, kept: NotifiedPeriods(fiveHour: fiveReset)) { f in
            f.session(snap(fiveAt(93, fiveReset + 10 * minute)))
            await f.settle()
            #expect(f.shown == [])
            #expect(f.store.periods.fiveHour == fiveReset + 10 * minute)
        }
    }

    // The periods change before the read of the flag, so a new value during the read does not
    // notify again.
    @Test func twoQuickValuesDuringTheReadOfTheFlagNotifyOneTime() async throws {
        let gate = TestGate()
        defer { gate.openAll() }
        try await withMonitor(flag: FakeFlag(gate: gate)) { f in
            f.session(snap(fiveAt(92)))
            try #require(await gate.waitUntilHolding())
            f.session(snap(fiveAt(93)))
            gate.open()
            await f.settle()
            #expect(f.shown == [offText])
            #expect(f.reads == 1)
        }
    }

    // A stop during the read of the flag shows no text, also for an earlier read that still
    // waits. The periods stay notified, and their save goes on.
    @Test func aStopDuringTheReadOfTheFlagShowsNothing() async throws {
        let gate = TestGate()
        defer { gate.openAll() }
        try await withMonitor(flag: FakeFlag(gate: gate)) { f in
            f.session(snap(fiveAt(92)))
            try #require(await gate.waitUntilHolding())
            var both = fiveAt(92)
            both.sevenDay = RateWindow(usedPercent: 95, resetsAt: sevenReset)
            f.session(snap(both))
            try #require(await gate.waitUntilHolding(2))
            f.monitor.stop()
            gate.openAll()
            await f.settle()
            #expect(f.shown.isEmpty)
            #expect(f.reads == 2)
            #expect(f.store.periods.fiveHour != nil)
            #expect(f.store.periods.sevenDay != nil)
        }
    }

    @Test func aRestartDoesNotNotifyAgainForTheSamePeriod() async throws {
        try await withMonitor { f in
            f.session(snap(fiveAt(92)))
            await f.settle()
            #expect(f.shown.count == 1)
            await f.restart()
            #expect(f.store.periods == NotifiedPeriods(fiveHour: fiveReset))
            f.session(snap(fiveAt(92)))
            await f.settle()
            #expect(f.shown == [])
            // The other limit has its own period.
            let seven = RateLimits(sevenDay: RateWindow(usedPercent: 90, resetsAt: sevenReset))
            f.session(snap(seven))
            await f.settle()
            #expect(f.shown.map(\.title) == ["7-day limit at 90%"])
        }
    }

    @Test func withTheSettingOffNothingShowsAndThePeriodStaysOpen() async throws {
        try await withMonitor(enabled: false) { f in
            f.session(snap(fiveAt(92)))
            await f.settle()
            #expect(f.shown == [])
            #expect(f.writes.writes == 0)
            // The setting goes on. The next value notifies.
            f.inputs.enabled = true
            f.session(snap(fiveAt(92)))
            await f.settle()
            #expect(f.shown == [offText])
        }
    }

    @Test func bothLimitsAt90PercentShowTwoNotificationsWithOneReadOfTheFlag() async throws {
        try await withMonitor { f in
            f.session(
                snap(
                    RateLimits(
                        fiveHour: RateWindow(usedPercent: 92, resetsAt: fiveReset),
                        sevenDay: RateWindow(usedPercent: 95, resetsAt: sevenReset))))
            await f.settle()
            #expect(f.shown.map(\.title) == ["5-hour limit at 92%", "7-day limit at 95%"])
            #expect(f.reads == 1)
        }
    }

    @Test func freshAccountValuesWinOverTheSessionValues() async throws {
        try await withMonitor { f in
            f.session(snap(fiveAt(99)))
            f.account(account(fiveAt(50), extraUsage: false))
            await f.settle()
            // The session values came first and notified. The account values are below 90%.
            #expect(f.shown.count == 1)
        }
        try await withMonitor { f in
            f.account(account(fiveAt(50), extraUsage: false))
            f.session(snap(fiveAt(99)))
            await f.settle()
            #expect(f.shown == [])
        }
    }

    @Test func accountValuesOlderThan15MinutesFallBackToTheSessionValues() async throws {
        try await withMonitor { f in
            f.account(account(fiveAt(50), fetchedAt: start - 16 * minute))
            f.session(snap(fiveAt(92)))
            await f.settle()
            #expect(f.shown == [offText])
        }
    }

    @Test func freshAccountValuesGiveTheExtraUsageFlagAndTheFileIsNotRead() async throws {
        try await withMonitor(flag: FakeFlag(true)) { f in
            f.account(account(fiveAt(92), extraUsage: false))
            await f.settle()
            #expect(f.shown == [offText])
            #expect(f.reads == 0)
        }
        try await withMonitor { f in
            f.account(account(fiveAt(92), extraUsage: true))
            await f.settle()
            #expect(f.shown == [warningText])
            #expect(f.reads == 0)
        }
    }

    @Test func withoutTheFlagOfTheAccountValuesTheMonitorReadsTheFileOfTheHome() async throws {
        try await withMonitor(flag: FakeFlag(true)) { f in
            f.session(snap(fiveAt(92)))
            await f.settle()
            #expect(f.flag?.reads == [f.home])
            #expect(f.shown == [warningText])
        }
        // Fresh account values with no flag also read the file.
        try await withMonitor(flag: FakeFlag(true)) { f in
            f.account(account(fiveAt(92)))
            await f.settle()
            #expect(f.reads == 1)
            #expect(f.shown.map(\.title) == [warning])
        }
    }

    // The read of the real file of the home. No file counts as off.
    @Test func theMonitorReadsClaudeJsonOfItsHome() async throws {
        try await withMonitor(flag: nil) { f in
            try f.writeClaudeJSON(#"{"oauthAccount":{"hasExtraUsageEnabled":true}}"#)
            f.session(snap(fiveAt(92)))
            await f.settle()
            #expect(f.shown == [warningText])
        }
        try await withMonitor(flag: nil) { f in
            f.session(snap(fiveAt(92)))
            await f.settle()
            #expect(f.shown == [offText])
        }
    }

    // A known "on" flag stays in memory, so stale account values after a 429 or a network error
    // do not lose the warning.
    @Test func aKnownOnFlagOfStaleAccountValuesGivesTheWarningWithoutTheFile() async throws {
        try await withMonitor(flag: FakeFlag(false)) { f in
            f.account(account(fiveAt(50), extraUsage: true))
            await f.settle()
            // The account values are now 20 minutes old, so the session values count.
            f.inputs.now = start + 20 * minute
            f.session(snap(fiveAt(92)))
            await f.settle()
            #expect(f.shown.map(\.title) == [warning])
            #expect(f.reads == 0)
        }
    }

    @Test func aNilValueAndAValueWithNoFlagKeepTheKnownFlag() async throws {
        try await withMonitor(flag: FakeFlag(false)) { f in
            f.account(account(fiveAt(50), extraUsage: true))
            f.account(nil)
            f.session(snap(fiveAt(92)))
            await f.settle()
            #expect(f.shown.map(\.title) == [warning])
        }
        try await withMonitor(flag: FakeFlag(false)) { f in
            f.account(account(fiveAt(50), extraUsage: true))
            f.account(account(fiveAt(92)))
            await f.settle()
            #expect(f.shown.map(\.title) == [warning])
        }
    }

    @Test func aFreshOffFlagWinsOverAnOlderOnFlagAndOverTheFile() async throws {
        try await withMonitor(flag: FakeFlag(true)) { f in
            f.account(account(fiveAt(50), extraUsage: true))
            f.inputs.now = start + 5 * minute
            f.account(
                account(fiveAt(92), extraUsage: false, fetchedAt: start + 5 * minute))
            await f.settle()
            #expect(f.shown == [offText])
            #expect(f.reads == 0)
        }
    }

    // The shell follows the session usage of the registry and the account values of the poller.
    // The monitor gets the values of now, then each change.
    @Test func theMonitorGetsEachAccountAndSessionValue() async throws {
        try await withMonitor { f in
            let sources = Sources()
            sources.session = snap(fiveAt(92))
            f.monitor.follow(session: { sources.session }, account: { sources.account })
            #expect(await waitUntil { f.shown == [offText] })
            sources.account = account(
                RateLimits(sevenDay: RateWindow(usedPercent: 95, resetsAt: sevenReset)),
                extraUsage: false)
            #expect(await waitUntil { f.shown.count == 2 })
            #expect(f.shown.last?.title == "7-day limit at 95%")
            // After a stop, a change gives nothing. A second follow of the same values sees the
            // change, so the stopped follow had its turn.
            f.monitor.stop()
            let seen = Recorder(following: Observations { sources.session })
            defer { seen.stop() }
            #expect(await waitUntil { seen.values.count == 1 })
            sources.account = nil
            sources.session = snap(fiveAt(92, fiveReset + 5 * hour))
            #expect(await waitUntil { seen.values.count == 2 })
            await f.settle()
            #expect(f.shown.count == 2)
        }
    }

    // Unlike the box alerts, the usage notification takes no focus input: the monitor gives each
    // due text to notify. The shell tests show it also while the window has the focus.
    @Test func theMonitorHasNoFocusInput() async throws {
        try await withMonitor { f in
            f.account(account(fiveAt(92), extraUsage: false))
            #expect(f.shown == [offText])
        }
    }

    // ~/.claude.json holds account data. The read logs nothing, and no text or store event holds
    // a part of the file, for a good file and for each file that gives no flag.
    @Test func noLogLineHoldsTheContentOfClaudeJson() async throws {
        let secret = "secret-account-value"
        let files = [
            #"{"oauthAccount":{"emailAddress":"\#(secret)","hasExtraUsageEnabled":true}}"#,
            #"{ "oauthAccount": { "emailAddress": "\#(secret)" "#,
            #"{"oauthAccount":"\#(secret)"}"#,
            #"["\#(secret)"]"#,
        ]
        for text in files {
            try await withMonitor(flag: nil) { f in
                try f.writeClaudeJSON(text)
                f.session(snap(fiveAt(92)))
                await f.settle()
                #expect(f.shown.count == 1)
                for shown in f.shown {
                    #expect(!shown.title.contains(secret))
                    #expect(!shown.body.contains(secret))
                }
                #expect(f.log.values == [])
                let saved = try String(contentsOf: f.file, encoding: .utf8)
                #expect(!saved.contains(secret))
            }
        }
    }
}
