import BifrostTestSupport
import Testing

@testable import BifrostSessions

// The alert of a finished turn after a prompt (docs/behaviour/alerts.md, "A finished turn"). The
// prompt lines of the Live details mod go into the registry, and the rows of the registry go to
// the core of the alert monitor. So each test checks the full path from a line to an alert.

// A session of the registry, the core of the alert monitor, and each notification and sound so
// far. The first update of the core comes at the start, as in the app.
private struct Flow {
    var registry = BifrostSessionsTests.registry()
    var core = AlertMonitorCore()
    var now = 100
    var notes: [AlertNote] = []
    var sounds = 0

    init() {
        registry.applyAgents([bg()], sampledAt: now)
        update()
    }

    // The core gets the rows of the registry. The window has no focus.
    mutating func update() {
        core.update(
            registry.rows(), now: .milliseconds(now), notifications: true, redBoxSound: true,
            focused: false)
        for effect in core.takeEffects() {
            switch effect {
            case .notify(let note): notes.append(note)
            case .playSound: sounds += 1
            }
        }
    }

    // One state event of the session, then an update.
    mutating func event(_ name: HookEventName) {
        now += 1000
        registry.applyEvents([ev(name, "s1", now)], now: now)
        update()
    }

    // A turn of the session that ends with the event end. A prompt line with person comes first.
    // A nil person gives no prompt line, as from a mod with no prompt lines.
    mutating func turn(person: Bool?, end: HookEventName = .stop) {
        if let person {
            now += 1000
            registry.applyPrompt("s1", person: person, at: now)
        }
        event(.userPromptSubmit)
        event(.postToolUse)
        event(end)
    }

    // The bodies of the notifications so far.
    var bodies: [String] { notes.map(\.body) }
}

private let finished = "Claude finished its turn."

@Suite("prompt lines in the registry")
struct RegistryPromptTests {
    // The order numbers of the prompts of a person increase together for all sessions. Another
    // prompt makes the prompts known and keeps the number.
    @Test func eachPromptOfAPersonGetsTheNextOrderNumber() {
        var r = registry()
        let second = bg(id: "bbbbbbbb", name: "beta", pid: 6, sessionId: "s2")
        r.applyAgents([bg(), second], sampledAt: 100)
        #expect(r.row("s1")?.personPrompt == nil)
        r.applyPrompt("s1", person: false, at: 200)
        #expect(r.row("s1")?.personPrompt == 0)
        r.applyPrompt("s1", person: true, at: 300)
        r.applyPrompt("s2", person: true, at: 400)
        r.applyPrompt("s1", person: false, at: 500)
        #expect(r.row("s1")?.personPrompt == 1)
        #expect(r.row("s2")?.personPrompt == 2)
        r.applyPrompt("s1", person: true, at: 600)
        #expect(r.row("s1")?.personPrompt == 3)
    }

    // A prompt line is a line of the mod, so it keeps the row live. It is not activity.
    @Test func aPromptLineKeepsTheRowLiveAndIsNoActivity() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        let before = r.row("s1")?.lastActivity
        r.applyPrompt("s1", person: true, at: 200)
        #expect(r.row("s1")?.live == true)
        #expect(r.row("s1")?.lastActivity == before)
    }

    // The prompt counts only while the row is live. With Live details off, it does not count.
    @Test func thePromptOfARowThatIsNotLiveIsNil() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyPrompt("s1", person: true, at: 1000)
        r.tick(now: 91_001)
        #expect(r.row("s1")?.personPrompt == nil)
        r.applyPrompt("s1", person: false, at: 91_001)
        #expect(r.row("s1")?.personPrompt == 1)
        r.clearLive()
        #expect(r.row("s1")?.personPrompt == nil)
    }

    // A prompt line can come before the session list shows the session.
    @Test func thePromptOfAnUnknownSessionCountsWhenTheRowShows() {
        var r = registry()
        r.applyPrompt("s1", person: true, at: 100)
        r.applyAgents([bg()], sampledAt: 200)
        #expect(r.row("s1")?.personPrompt == 1)
    }

    @Test func aForgottenSessionLosesItsPrompts() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyPrompt("s1", person: true, at: 200)
        r.forget("s1")
        #expect(r.personPrompts["s1"] == nil)
    }
}

@Suite("alerts after a prompt")
struct PromptAlertTests {
    @Test func aFinishedTurnAfterAPromptOfAPersonNotifies() {
        var flow = Flow()
        flow.turn(person: true)
        #expect(flow.bodies == [finished])
    }

    // A background task wakes the session. Its turn gives a yellow box and no notification.
    @Test func aFinishedTurnAfterATaskNotificationDoesNotNotify() {
        var flow = Flow()
        flow.turn(person: false)
        #expect(flow.registry.row("s1")?.alert.colour == .yellow)
        #expect(flow.notes.isEmpty)
    }

    // The yellow box of the prompt of the person uses the prompt. Two wake-ups after it give no
    // notification. A new prompt of the person gives a notification again.
    @Test func twoWakeUpsWithNoPromptGiveNoNotification() {
        var flow = Flow()
        flow.turn(person: true)
        flow.turn(person: false)
        flow.turn(person: false)
        #expect(flow.bodies == [finished])
        flow.turn(person: true)
        #expect(flow.bodies == [finished, finished])
    }

    // A prompt of the person while a woken turn runs still counts for the end of that turn.
    @Test func aPromptOfAPersonDuringAWokenTurnNotifies() {
        var flow = Flow()
        flow.registry.applyPrompt("s1", person: false, at: flow.now)
        flow.event(.userPromptSubmit)
        flow.registry.applyPrompt("s1", person: true, at: flow.now + 1)
        flow.event(.stop)
        #expect(flow.bodies == [finished])
    }

    // A red box keeps its alert, also in a turn that a background task started.
    @Test func aRedBoxStillNotifiesAndPlaysTheSound() {
        var flow = Flow()
        flow.turn(person: false, end: .permissionRequest)
        #expect(flow.bodies == ["Claude needs you."])
        #expect(flow.sounds == 1)
    }

    // A quiet yellow box that escalates turns red on the row, with no notification and no sound.
    @Test func aQuietFinishedTurnStaysQuietWhenItEscalates() {
        var flow = Flow()
        flow.turn(person: false)
        flow.now += 600_001
        flow.registry.tick(now: flow.now)
        flow.update()
        #expect(flow.registry.row("s1")?.alert.colour == .red)
        #expect(flow.notes.isEmpty)
        #expect(flow.sounds == 0)
    }

    // A yellow box that notified keeps the old rule: its escalation plays the sound once.
    @Test func aNotifiedFinishedTurnPlaysTheSoundWhenItEscalates() {
        var flow = Flow()
        flow.turn(person: true)
        flow.now += 600_001
        flow.registry.tick(now: flow.now)
        flow.update()
        #expect(flow.registry.row("s1")?.alert.colour == .red)
        #expect(flow.bodies == [finished])
        #expect(flow.sounds == 1)
    }

    // A mod with no prompt lines, and Live details off, keep the old rule: each new yellow box
    // notifies.
    @Test func withNoPromptLinesEachFinishedTurnNotifies() {
        var flow = Flow()
        flow.turn(person: nil)
        flow.turn(person: nil)
        #expect(flow.bodies == [finished, finished])
    }

    @Test func withLiveDetailsOffEachFinishedTurnNotifies() {
        var flow = Flow()
        flow.turn(person: false)
        #expect(flow.notes.isEmpty)
        flow.registry.clearLive()
        flow.now += 1000
        flow.registry.applyAgents([bg(status: .busy)], sampledAt: flow.now)
        flow.update()
        flow.now += 1000
        flow.registry.applyAgents([bg(status: .idle)], sampledAt: flow.now)
        flow.update()
        #expect(flow.registry.row("s1")?.alert.colour == .yellow)
        #expect(flow.bodies == [finished])
    }
}
