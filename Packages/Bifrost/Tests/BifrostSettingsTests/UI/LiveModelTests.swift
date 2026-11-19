import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostLive
@testable import BifrostSettings

// The rules of the live model (docs/behaviour/live.md, "Settings > Live details" and "The warning
// dot"): a quiet read drops its answer after a busy call started, the back-off reads nothing
// while a Live details action runs, the end of an action counts as a read for the 30 s rule, a
// focus of the window reads again after 5 minutes, and after the stop nothing reads. The controls
// are the real controls in a test home, with plugin commands that run no program (LiveParts),
// and the back-off runs on a manual clock.

@MainActor
@Suite("the live model", .serialized, .testTimeLimit, .tags(.window))
struct LiveModelTests {
    // The first read is quiet. When an action starts while it waits, its answer drops at its
    // end, and the status of the action stays.
    @Test func aQuietReadThatEndsAfterAnActionDropsItsAnswer() async throws {
        let plugins = FakePlugins(.live, installed: true, enabled: false)
        plugins.holdLists(1)
        let l = try LiveParts(live: plugins)
        defer { l.finish() }
        l.model.attach(l.sources)
        #expect(await plugins.listGate.waitUntilHolding(1))
        // The held read has the plugin off. The action turns it on.
        await l.model.press(.enable, .live, confirm: nil)
        #expect(l.model.notice == .on(sessions: 0))
        plugins.listGate.open()
        await l.model.firstReads?.value
        #expect(l.model.notice == .on(sessions: 0))
        #expect(!l.model.warning)
    }

    // A step of the back-off during a Live details action reads nothing: the action sets the
    // status when it ends.
    @Test func aStepDuringAHeldActionReadsNothing() async throws {
        // On, but nothing listens: a warning.
        let plugins = FakePlugins(.live, installed: true, enabled: true)
        let l = try LiveParts(live: plugins)
        defer { l.finish() }
        await l.attach()
        #expect(l.model.warning)
        #expect(await l.clock.waitForSleepers(1))
        plugins.hold(true)
        defer { plugins.hold(false) }
        let action = Task { await l.model.press(.disable, .live, confirm: nil) }
        #expect(await plugins.gate.waitUntilHolding(1))
        let lists = plugins.lists
        l.clock.advance(by: .seconds(60))
        #expect(await waitUntil { l.clock.nextDeadline?.offset == .seconds(120) })
        await l.model.retryReadTask?.value
        #expect(plugins.lists == lists)
        plugins.hold(false)
        await action.value
        #expect(l.model.notice == .off)
        #expect(!l.model.warning)
    }

    // An action that ends 20 s before a step counts as the read of that step.
    @Test func theEndOfAnActionCountsAsARead() async throws {
        let plugins = FakePlugins(.live, installed: true, enabled: true)
        plugins.change { $0.failing = "enable" }
        let l = try LiveParts(live: plugins)
        defer { l.finish() }
        await l.attach()
        #expect(l.model.warning)
        #expect(await l.clock.waitForSleepers(1))
        l.clock.advance(by: .seconds(40))
        await l.model.press(.enable, .live, confirm: nil)
        #expect(l.model.liveState.error == "boom")
        #expect(l.model.warning)
        let lists = plugins.lists
        l.clock.advance(by: .seconds(20))
        #expect(await waitUntil { l.clock.nextDeadline?.offset == .seconds(120) })
        #expect(l.model.retryReadTask == nil)
        #expect(plugins.lists == lists)
        // The next step reads.
        l.clock.advance(by: .seconds(60))
        #expect(await waitUntil { plugins.lists == lists + 1 })
    }

    // After the last step, a focus of the window reads again only when the last read ended 5
    // minutes or more ago, and a good read clears the warning.
    @Test func aFocusReadsAgainFiveMinutesAfterTheLastRead() async throws {
        let plugins = FakePlugins(.live)
        plugins.change { $0.listFails = true }
        let l = try LiveParts(live: plugins)
        defer { l.finish() }
        await l.attach()
        #expect(l.model.warning)
        l.model.windowFocused()
        #expect(l.model.retryReadTask == nil)
        for step in LiveRetry.steps {
            #expect(await l.clock.waitForSleepers(1))
            let before = plugins.lists
            l.clock.advance(by: step - l.clock.now.offset)
            #expect(await waitUntil { plugins.lists == before + 1 })
            await l.model.retryReadTask?.value
        }
        let lists = plugins.lists
        l.clock.advance(by: LiveRetry.focusGap - .seconds(1))
        l.model.windowFocused()
        await l.model.retryReadTask?.value
        #expect(plugins.lists == lists)
        plugins.change { $0.listFails = false }
        l.clock.advance(by: .seconds(1))
        l.model.windowFocused()
        await l.model.retryReadTask?.value
        #expect(plugins.lists == lists + 1)
        #expect(!l.model.warning)
    }

    // After the stop no timer waits, and no read, focus, Try again or action runs a command.
    @Test func afterTheStopNoTimerWaitsAndNoListRuns() async throws {
        let plugins = FakePlugins(.live, installed: true, enabled: true)
        let l = try LiveParts(live: plugins)
        defer { l.finish() }
        await l.attach()
        #expect(l.model.warning)
        #expect(await l.clock.waitForSleepers(1))
        l.model.stop()
        #expect(await l.clock.waitUntilNoSleepers())
        let lists = plugins.lists
        l.clock.advance(by: .seconds(900))
        l.model.windowFocused()
        #expect(l.model.readOnce(.live) == nil)
        await l.model.press(.retry, .live, confirm: nil)
        await l.model.press(.disable, .live, confirm: nil)
        #expect(plugins.lists == lists)
        #expect(plugins.writes == [])
    }

    // An action that ends after the stop sets no status and no reload note.
    @Test func anActionThatEndsAfterTheStopChangesNothing() async throws {
        let plugins = FakePlugins(.live, installed: true, enabled: false)
        let l = try LiveParts(live: plugins)
        defer { l.finish() }
        await l.attach()
        #expect(l.model.notice == .off)
        plugins.hold(true)
        defer { plugins.hold(false) }
        let action = Task { await l.model.press(.enable, .live, confirm: nil) }
        #expect(await plugins.gate.waitUntilHolding(1))
        l.model.stop()
        plugins.hold(false)
        await action.value
        #expect(plugins.writes == ["enable bifrost-live@bifrost-local"])
        #expect(l.model.notice == .off)
        #expect(!l.model.liveState.changed)
    }

    // A read that ends after the stop changes nothing.
    @Test func anAnswerAfterTheStopChangesNothing() async throws {
        let plugins = FakePlugins(.live, installed: true, enabled: true)
        plugins.holdLists(1)
        let l = try LiveParts(live: plugins)
        defer { l.finish() }
        l.model.attach(l.sources)
        #expect(await plugins.listGate.waitUntilHolding(1))
        l.model.stop()
        plugins.listGate.open()
        await l.model.firstReads?.value
        #expect(l.model.status == nil)
        #expect(!l.model.warning)
    }
}
