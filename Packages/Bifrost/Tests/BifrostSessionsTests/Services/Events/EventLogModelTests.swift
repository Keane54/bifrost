import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

// The one Event log of the app (docs/behaviour/panels.md, The Event log): the read of the events
// of the registry, the notices and lines at the time of now, and the entries that the panel
// shows, which change at most once each 250 ms.

private let start = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
@Suite("event log model")
struct EventLogModelTests {
    @Test func theModelReadsEachEventOfTheStream() async {
        let clock = ManualClock()
        let model = EventLogModel(clock: clock)
        let (events, send) = AsyncStream.makeStream(of: HookEvent.self)
        model.read(events)
        send.yield(HookEvent(.userPromptSubmit, "s1", at: 1))
        await waitUntil { model.entries.count == 1 }
        send.yield(HookEvent(.preToolUse, "s1", at: 2, toolName: "Bash"))
        send.yield(HookEvent(.stop, "s2", at: 3))
        send.finish()
        await model.readTask?.value
        #expect(model.entries.count == 1)
        await clock.waitForSleepers(1)
        clock.advance(by: EventBatcher.gap)
        await waitUntil { model.entries.count == 3 }
        #expect(
            model.entries.map(LogView.text) == ["UserPromptSubmit", "PreToolUse (Bash)", "Stop"])
        #expect(model.entries.map(\.tool) == [nil, "Bash", nil])
    }

    @Test func aNoticeAndALineHaveTheTimeOfNow() {
        let model = EventLogModel(clock: ManualClock(), now: { start })
        model.notice(EventLog.notificationRefused)
        #expect(
            model.entries == [
                LogEntry(
                    seq: 1, at: start.millisecondsSince1970, notice: EventLog.notificationRefused)
            ])
    }

    @Test func theEntriesChangeAtMostOnceEach250ms() async {
        let clock = ManualClock()
        let model = EventLogModel(clock: clock, now: { start })
        let changes = Recorder(following: Observations { model.entries.count })
        await waitUntil { changes.values == [0] }
        model.line("First.")
        await waitUntil { changes.values == [0, 1] }
        for i in 0..<20_000 { model.append([HookEvent(.stop, "s1", at: i)]) }
        model.notice("A notice.")
        await clock.waitForSleepers(1)
        #expect(model.entries.count == 1)
        clock.advance(by: EventBatcher.gap)
        await waitUntil { changes.values == [0, 1, 5000] }
        #expect(model.entries.last?.kind == .notice("A notice."))
        changes.stop()
    }

    @Test func afterAStopTheEntriesDoNotChange() async {
        let clock = ManualClock()
        let model = EventLogModel(clock: clock, now: { start })
        model.line("First.")
        model.line("Second.")
        model.stop()
        clock.advance(by: .seconds(1))
        model.line("Third.")
        #expect(model.entries.map(\.kind) == [.notice("First.")])
    }
}
