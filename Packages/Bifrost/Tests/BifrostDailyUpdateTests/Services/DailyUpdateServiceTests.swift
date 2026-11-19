import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The service of the Daily update (docs/behaviour/daily-update.md, "The schedule") with the fake
// claude -p in a test home (RunHome). The service has its own manual clock, the wall time is a
// value that the test sets, and the notifier is a fake: no notification shows and no sound plays.
// Safety: the fake reads and writes only the test home, gh is a FakeRunner, and no test uses a
// real model.

private let secondArea = WorkArea(id: "area-2", name: "Beta")

private let twoAreas = """
    {"version":1,"areas":[{"id":"area-1","moved":true,"items":[],"draft":"**One**\\nDone."},\
    {"id":"area-2","moved":false,"items":[],"draft":"**Two**\\nDone."}],"unplaced":[]}
    """

// The wall time of a test.
@MainActor
private final class Wall {
    var date: Date

    init(_ date: Date) { self.date = date }
}

// What the service asked the app to do.
@MainActor
private final class Calls {
    var bounces = 0
    var refused = 0
    var opened: [String?] = []
}

// The settings of a test, so a test can change them.
@MainActor
private final class Config {
    var value: DailySettings

    init(_ value: DailySettings) { self.value = value }
}

// The calendar of a test, so a test can change the time zone.
@MainActor
private final class Zone {
    var calendar = BifrostDailyUpdateTests.calendar()
}

@MainActor
private final class Setup {
    let home: RunHome
    let wall: Wall
    let clock = ManualClock()
    let notifier = FakeNotifier()
    let calls = Calls()
    let zone = Zone()
    let config: Config
    let store: DailyStateStore
    let service: DailyUpdateService

    init(at time: Date, areas: [WorkArea] = [areaOne], result: String = goodResult) async throws {
        home = try RunHome()
        wall = Wall(time)
        try home.write("fake-daily-result.json", output(result))
        store = try await DailyStateStore.open(layout: home.layout)
        var values = boardSettings(areas: areas)
        values.mergedPrs = false
        let config = Config(values)
        self.config = config
        let runner = home.runner()
        let wall = wall
        let calls = calls
        let zone = zone
        service = DailyUpdateService(
            store: store, runner: runner, settings: { config.value }, notifier: notifier,
            bounceDock: { calls.bounces += 1 }, openPanel: { calls.opened.append($0) },
            clock: clock, now: { wall.date }, calendar: { zone.calendar },
            refused: { calls.refused += 1 })
    }

    // Move the wall time and the clock together.
    func advance(to time: Date) {
        clock.advance(by: .seconds(time.timeIntervalSince(wall.date)))
        wall.date = time
    }

    func finish() async {
        service.stop()
        await service.savesEnded()
        await store.close()
        home.finish()
    }
}

// Run a test body with a setup, and end the setup after the body, also after a failure.
@MainActor
private func withSetup(
    at time: Date, areas: [WorkArea] = [areaOne], result: String = goodResult,
    _ body: (Setup) async throws -> Void
) async throws {
    let setup = try await Setup(at: time, areas: areas, result: result)
    do {
        try await body(setup)
    } catch {
        await setup.finish()
        throw error
    }
    await setup.finish()
}

@MainActor
@Suite("the Daily update service", .timeLimit(.minutes(2)), .tags(.realProcess))
struct DailyUpdateServiceTests {
    @Test func theFirstReminderRunsThenNotifiesWithSound() async throws {
        try await withSetup(at: wednesday(9, 0)) { setup in
            setup.service.start()
            await setup.clock.waitForSleepers(exactly: 1)
            #expect(setup.notifier.shown.isEmpty)
            setup.advance(to: wednesday(9, 30))
            await waitUntil { setup.notifier.shown.count == 1 }
            let note = try #require(setup.notifier.shown.first)
            #expect(note.body == "Your daily update is ready to check.")
            #expect(note.source == .dailyUpdate)
            #expect(note.sound)
            #expect(setup.home.runCalls.count == 1)
            #expect(setup.calls.bounces == 0)
            #expect(setup.service.snapshot.tabs.first?.draft == "**Daily update**\nDone.")
            #expect(setup.service.showsMarker)
        }
    }

    @Test func theSecondReminderBouncesTheDockOnce() async throws {
        try await withSetup(at: wednesday(9, 40)) { setup in
            setup.service.start()
            await waitUntil { setup.notifier.shown.count == 1 }
            #expect(setup.calls.bounces == 0)
            await setup.clock.waitForSleepers(exactly: 1)
            setup.advance(to: wednesday(9, 50))
            await waitUntil { setup.notifier.shown.count == 2 }
            #expect(setup.notifier.shown.last?.body == DailyUpdateService.secondText)
            #expect(setup.notifier.shown.last?.sound == true)
            #expect(setup.calls.bounces == 1)
            // The second reminder runs no new draft.
            #expect(setup.home.runCalls.count == 1)
        }
    }

    @Test func aWakeAfterTheDraftTimeRunsAtOnceWithOneNotification() async throws {
        try await withSetup(at: wednesday(9, 40)) { setup in
            setup.service.start()
            await waitUntil { setup.notifier.shown.count == 1 }
            await setup.clock.waitForSleepers(exactly: 1)
            // Another wake in the same minute adds no run and no notification.
            setup.service.timeChanged()
            await setup.clock.waitForSleepers(exactly: 1)
            await setup.service.settled()
            #expect(setup.notifier.shown.count == 1)
            #expect(setup.home.runCalls.count == 1)
            #expect(setup.notifier.shown.first?.body == "Your daily update is ready to check.")
        }
    }

    @Test func aWakeInTheSecondWindowGivesTheSecondReminderAlone() async throws {
        try await withSetup(at: wednesday(9, 55)) { setup in
            setup.service.start()
            await waitUntil { setup.notifier.shown.count == 1 }
            #expect(setup.notifier.shown.first?.body == DailyUpdateService.secondText)
            #expect(setup.calls.bounces == 1)
            setup.service.timeChanged()
            await setup.clock.waitForSleepers(exactly: 1)
            #expect(setup.notifier.shown.count == 1)
            #expect(setup.home.runCalls.count == 1)
        }
    }

    @Test func aClockChangePlansAgain() async throws {
        try await withSetup(at: wednesday(9, 0)) { setup in
            setup.service.start()
            await setup.clock.waitForSleepers(exactly: 1)
            let first = try #require(setup.clock.nextDeadline)
            #expect(first == setup.clock.now.advanced(by: .seconds(30 * 60)))
            // The clock of the Mac jumps to 09:45 with no time on the clock of the service.
            setup.wall.date = wednesday(9, 45)
            setup.service.timeChanged()
            await waitUntil { setup.notifier.shown.count == 1 }
            await setup.clock.waitForSleepers(exactly: 1)
            let next = try #require(setup.clock.nextDeadline)
            #expect(next == setup.clock.now.advanced(by: .seconds(5 * 60)))
        }
    }

    @Test(arguments: [true, false])
    func noReminderAfterMarkAsSentOrSkipToday(markSent: Bool) async throws {
        try await withSetup(at: wednesday(9, 40)) { setup in
            setup.service.start()
            await waitUntil { setup.notifier.shown.count == 1 }
            await setup.clock.waitForSleepers(exactly: 1)
            if markSent { setup.service.markSent("area-1") } else { setup.service.skipToday() }
            #expect(!setup.service.showsMarker)
            setup.advance(to: wednesday(9, 50))
            await setup.clock.waitForSleepers(exactly: 1)
            #expect(setup.notifier.shown.count == 1)
            #expect(setup.calls.bounces == 0)
        }
    }

    @Test func openingThePanelWithinFiveMinutesOfARunDoesNotRun() async throws {
        try await withSetup(at: wednesday(9, 0)) { setup in
            setup.service.start()
            setup.service.panelOpened()
            await setup.service.manual?.value
            #expect(setup.home.runCalls.count == 1)
            setup.wall.date = wednesday(9, 4)
            setup.service.panelOpened()
            #expect(setup.service.manual == nil)
            #expect(setup.home.runCalls.count == 1)
            setup.wall.date = wednesday(9, 6)
            setup.service.panelOpened()
            await setup.service.manual?.value
            #expect(setup.home.runCalls.count == 2)
        }
    }

    @Test func refreshKeepsAChangedDraft() async throws {
        try await withSetup(at: wednesday(9, 0)) { setup in
            setup.service.start()
            setup.service.refresh()
            await setup.service.manual?.value
            setup.service.edit("area-1", "my words")
            try setup.home.write(
                "fake-daily-result.json", output(goodResult.replacing("Done.", with: "New.")))
            setup.service.refresh()
            await setup.service.manual?.value
            let tab = try #require(setup.service.snapshot.tabs.first)
            #expect(tab.draft == "my words")
            #expect(tab.edited)
            #expect(tab.pending == "**Daily update**\nNew.")
            setup.service.usePending("area-1")
            #expect(setup.service.snapshot.tabs.first?.draft == "**Daily update**\nNew.")
            #expect(setup.service.copyText("area-1") == "**Daily update**\nNew.")
        }
    }

    @Test func redoWritesOnlyItsOwnArea() async throws {
        try await withSetup(at: wednesday(9, 0), areas: [areaOne, secondArea]) { setup in
            let one =
                #"{"id":"area-2","moved":true,"items":[],"draft":"**Two**\nAgain."}"#
            try setup.home.write(
                "fake-daily-result.json", output(#"{"version":1,"areas":[\#(one)],"unplaced":[]}"#))
            setup.service.start()
            setup.service.redo("area-2")
            await setup.service.manual?.value
            let tabs = setup.service.snapshot.tabs
            #expect(tabs.map(\.draft) == ["", "**Two**\nAgain."])
            #expect(setup.service.snapshot.failure == nil)
        }
    }

    @Test func aFailedScheduledRunStillNotifies() async throws {
        try await withSetup(
                at: wednesday(9, 40), result: #"{"version":1,"failure":"no-user"}"#) { setup in
            setup.service.start()
            await waitUntil { setup.notifier.shown.count == 1 }
            let note = try #require(setup.notifier.shown.first)
            #expect(note.body == DailyUpdateService.failedText)
            #expect(note.body.hasPrefix("Bifrost couldn't write your daily update."))
            #expect(note.sound)
            #expect(setup.service.snapshot.failure == DailyFailure(code: .noUser, server: "board"))
            #expect(setup.service.snapshot.status == .failed)
            #expect(setup.service.snapshot.lastRefresh == nil)
        }
    }

    @Test func aClickOpensTheFirstTabThatIsNotSent() async throws {
        try await withSetup(
                at: wednesday(9, 40), areas: [areaOne, secondArea], result: twoAreas) { setup in
            setup.service.start()
            await waitUntil { setup.notifier.shown.count == 1 }
            setup.service.markSent("area-1")
            setup.notifier.click(0)
            #expect(setup.calls.opened == ["area-2"])
            setup.service.markSent("area-2")
            setup.notifier.click(0)
            #expect(setup.calls.opened == ["area-2", nil])
        }
    }

    @Test func theScheduleHasNoTick() async throws {
        try await withSetup(at: wednesday(9, 0)) { setup in
            setup.service.start()
            await setup.clock.waitForSleepers(exactly: 1)
            // Two wakes, and between them one sleeper of the one timer.
            setup.advance(to: wednesday(9, 30))
            await waitUntil { setup.notifier.shown.count == 1 }
            await setup.clock.waitForSleepers(exactly: 1)
            #expect(setup.clock.sleeperCount == 1)
            setup.service.settingsChanged()
            await setup.clock.waitForSleepers(exactly: 1)
            #expect(setup.clock.sleeperCount == 1)
            setup.service.stop()
            await setup.clock.waitUntilNoSleepers()
        }
    }

    @Test func aLateStartMakesNoSound() async throws {
        try await withSetup(at: wednesday(10, 30)) { setup in
            setup.service.start()
            await waitUntil { setup.notifier.shown.count == 1 }
            #expect(setup.notifier.shown.first?.body == "Your daily update is ready to check.")
            #expect(setup.notifier.shown.first?.sound == false)
            #expect(setup.calls.bounces == 0)
        }
    }

    @Test func theSecondReminderNeverFollowsTheFirstWhileItsRunGoes() async throws {
        try await withSetup(at: wednesday(9, 48)) { setup in
            try setup.home.write("fake-daily-hang", "")
            setup.service.start()
            await waitUntil { setup.home.hangingPid != nil }
            await setup.clock.waitForSleepers(exactly: 1)
            setup.advance(to: wednesday(9, 50))
            await setup.clock.waitForSleepers(exactly: 1)
            #expect(setup.notifier.shown.isEmpty)
            // The run ends at its limit. Its reminder is the only one.
            await setup.home.clock.waitForSleepers(1)
            setup.home.clock.advance(by: DailyRunner.limit)
            await waitUntil { setup.notifier.shown.count == 1 }
            await setup.service.settled()
            #expect(setup.notifier.shown.count == 1)
            #expect(setup.calls.bounces == 0)
        }
    }

    @Test(arguments: [true, false])
    func noReminderAfterAMarkDuringTheRun(markSent: Bool) async throws {
        try await withSetup(at: wednesday(9, 40)) { setup in
            try setup.home.write("fake-daily-hang", "")
            setup.service.start()
            await waitUntil { setup.home.hangingPid != nil }
            if markSent { setup.service.markSent("area-1") } else { setup.service.skipToday() }
            await setup.home.clock.waitForSleepers(1)
            setup.home.clock.advance(by: DailyRunner.limit)
            await setup.service.settled()
            #expect(setup.notifier.shown.isEmpty)
            #expect(setup.calls.bounces == 0)
        }
    }

    @Test func aReminderWaitsForTheRunOfTheUserAndUsesItsResult() async throws {
        try await withSetup(at: wednesday(9, 0)) { setup in
            try setup.home.write("fake-daily-hang", "")
            setup.service.start()
            setup.service.refresh()
            await waitUntil { setup.home.hangingPid != nil }
            setup.advance(to: wednesday(9, 30))
            await setup.clock.waitForSleepers(exactly: 1)
            #expect(setup.notifier.shown.isEmpty)
            // The run of the user fails at its limit, so the reminder is the failed one.
            await setup.home.clock.waitForSleepers(1)
            setup.home.clock.advance(by: DailyRunner.limit)
            await waitUntil { setup.notifier.shown.count == 1 }
            #expect(setup.notifier.shown.first?.body == DailyUpdateService.failedText)
            #expect(setup.home.runCalls.count == 1)
        }
    }

    @Test func aRefusedReminderIsReported() async throws {
        try await withSetup(at: wednesday(9, 40)) { setup in
            setup.service.start()
            await waitUntil { setup.notifier.shown.count == 1 }
            setup.notifier.refuse(0)
            #expect(setup.calls.refused == 1)
        }
    }

    @Test func withNoAreaOnNothingRuns() async throws {
        try await withSetup(at: wednesday(9, 0), areas: []) { setup in
            setup.service.start()
            setup.service.panelOpened()
            setup.service.refresh()
            #expect(setup.service.manual == nil)
            #expect(setup.home.calls.isEmpty)
            #expect(setup.home.gh.commands.isEmpty)
            #expect(setup.service.snapshot.status == .noArea)
        }
    }

    @Test func aSettingsChangeReachesTheSnapshot() async throws {
        let off = WorkArea(id: "area-2", on: false, name: "Beta")
        try await withSetup(at: wednesday(9, 0), areas: [areaOne, off]) { setup in
            setup.service.start()
            #expect(setup.service.snapshot.tabs.count == 1)
            setup.config.value.areas[1].on = true
            setup.service.settingsChanged()
            #expect(setup.service.snapshot.tabs.count == 2)
        }
    }

    @Test func aSettingsChangeWithNoStateChangeMovesTheMarker() async throws {
        try await withSetup(at: wednesday(9, 35)) { setup in
            setup.service.start()
            await waitUntil { setup.notifier.shown.count == 1 }
            await setup.service.settled()
            #expect(setup.service.showsMarker)
            // Wednesday is no longer a due day. The marks of today stay as they are, so only the
            // plan can take the marker away.
            setup.config.value.days = [1, 2, 4, 5]
            setup.service.settingsChanged()
            #expect(!setup.service.showsMarker)
        }
    }

    @Test func aTimeZoneChangePlansAgain() async throws {
        // 08:35 in London is 09:35 in Paris: past the draft time there.
        try await withSetup(at: wednesday(8, 35)) { setup in
            setup.service.start()
            await setup.clock.waitForSleepers(exactly: 1)
            #expect(!setup.service.showsMarker)
            setup.zone.calendar = calendar("Europe/Paris")
            setup.service.timeChanged()
            await waitUntil { setup.notifier.shown.count == 1 }
            #expect(setup.notifier.shown.first?.body == "Your daily update is ready to check.")
            #expect(setup.service.showsMarker)
            // The next date is the second reminder at 09:50 in Paris.
            await setup.clock.waitForSleepers(exactly: 1)
            let next = try #require(setup.clock.nextDeadline)
            #expect(next == setup.clock.now.advanced(by: .seconds(15 * 60)))
        }
    }

    @Test func aRedoOfAnAreaThatIsOffRunsNothing() async throws {
        let off = WorkArea(id: "area-2", on: false, name: "Beta")
        try await withSetup(at: wednesday(9, 0), areas: [areaOne, off]) { setup in
            setup.service.start()
            setup.service.redo("area-2")
            #expect(setup.service.manual == nil)
            #expect(setup.home.calls.isEmpty)
        }
    }

    @Test func aSecondMarkAndAnUndoWithNoMarkChangeNothing() async throws {
        try await withSetup(at: wednesday(9, 0)) { setup in
            setup.service.start()
            setup.service.undoSent("area-1")
            #expect(setup.service.snapshot.tabs.first?.sentAt == nil)
            setup.service.markSent("area-1")
            let first = setup.service.snapshot.tabs.first?.sentAt
            #expect(first == wednesday(9, 0))
            setup.wall.date = wednesday(9, 5)
            setup.service.markSent("area-1")
            #expect(setup.service.snapshot.tabs.first?.sentAt == first)
            setup.service.undoSent("area-1")
            #expect(setup.service.snapshot.tabs.first?.sentAt == nil)
        }
    }

    // The store is the one place of the state: each edit is in it at once, and the save of a
    // burst of edits ends with the newest text in the file.
    @Test func anEditReachesTheStoreAtOnce() async throws {
        try await withSetup(at: wednesday(9, 0)) { setup in
            setup.service.start()
            setup.service.refresh()
            await setup.service.manual?.value
            for text in ["a", "ab", "abc"] { setup.service.edit("area-1", text) }
            #expect(setup.store.state.areas["area-1"]?.draft == "abc")
            await setup.service.savesEnded()
            let saved = try readSaved(setup.home.layout.stateFile)
            #expect(saved.object?["areas"]?.object?["area-1"]?.object?["draft"] == "abc")
        }
    }

    // A Refresh while a run goes starts no second run.
    @Test func aRefreshDuringARunStartsNothing() async throws {
        try await withSetup(at: wednesday(9, 0)) { setup in
            try setup.home.write("fake-daily-hang", "")
            setup.service.start()
            setup.service.refresh()
            let first = try #require(setup.service.manual)
            await waitUntil { setup.home.hangingPid != nil }
            #expect(setup.service.snapshot.status == .writing)
            setup.service.refresh()
            setup.service.redo("area-1")
            #expect(setup.service.manual == first)
            await setup.home.clock.waitForSleepers(1)
            setup.home.clock.advance(by: DailyRunner.limit)
            await first.value
            #expect(setup.home.runCalls.count == 1)
            #expect(setup.service.snapshot.status == .failed)
        }
    }

    @Test func aClockThatWentBackRunsAtTheOpen() async throws {
        try await withSetup(at: wednesday(9, 0)) { setup in
            setup.service.start()
            setup.service.panelOpened()
            await setup.service.manual?.value
            setup.wall.date = wednesday(8, 0)
            setup.service.panelOpened()
            await setup.service.manual?.value
            #expect(setup.home.runCalls.count == 2)
        }
    }
}
