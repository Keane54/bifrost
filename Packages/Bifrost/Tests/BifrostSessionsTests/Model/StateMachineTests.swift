import BifrostTestSupport
import Testing

@testable import BifrostSessions

// The state machine of one session as tables. Each step is a start state, one input and the
// state after the input. A step with no result keeps the start state.

// MARK: - States

private func at(
    _ state: SessionState, _ box: MachineState.Box = .none, _ message: String? = nil
) -> MachineState {
    MachineState(state, box: box, lastMessage: message)
}

// A box from a hook event is not confirmed. A status sample confirms a box.
private func yellow(_ since: Int, confirmed: Bool = false) -> MachineState.Box {
    .yellow(since: since, confirmed: confirmed)
}

private func red(
    _ reason: SessionBoxReason, _ since: Int, confirmed: Bool = false
) -> MachineState.Box {
    .red(reason, since: since, confirmed: confirmed)
}

private let working = at(.working)

// One start state of each kind, with and without a box, a confirmed flag and a message.
private let everyState: [MachineState] = [
    .initial,
    at(.working, .none, "m"),
    at(.needsYou, yellow(10), "m"),
    at(.needsYou, yellow(10, confirmed: true)),
    at(.needsYou, red(.prompt, 10)),
    at(.needsYou, red(.prompt, 10, confirmed: true), "m"),
    at(.needsYou, red(.escalated, 10)),
    at(.error, red(.error, 10), "m"),
    at(.idle, .none, "m"),
    at(.parked),
]

// MARK: - Inputs

enum MachineInput: Sendable {
    case event(HookEvent)
    case sample(StatusSample)
    case tick(now: Int, escalation: Duration)
}

private func hook(
    _ name: HookEventName, _ at: Int, tool: String? = nil, notification: String? = nil,
    message: String? = nil
) -> MachineInput {
    .event(
        HookEvent(
            name, "s", at: at, toolName: tool, notificationType: notification,
            lastAssistantMessage: message))
}

private func busy(_ at: Int, after prev: AgentStatus? = nil) -> MachineInput {
    .sample(StatusSample(.busy, at: at, prevStatus: prev))
}

private func idle(_ at: Int, after prev: AgentStatus? = nil, live: Bool = false) -> MachineInput {
    .sample(StatusSample(.idle, at: at, prevStatus: prev, live: live))
}

private func waiting(
    _ at: Int, for reason: String? = "approval", after prev: AgentStatus? = nil
) -> MachineInput {
    .sample(StatusSample(.waiting, at: at, waitingFor: reason, prevStatus: prev))
}

private func tick(_ now: Int, escalation: Duration = .seconds(600)) -> MachineInput {
    .tick(now: now, escalation: escalation)
}

extension MachineState {
    fileprivate func apply(_ input: MachineInput) -> MachineState {
        switch input {
        case .event(let event): onHookEvent(event)
        case .sample(let sample): onStatus(sample)
        case .tick(let now, let escalation): onTick(now: now, escalation: escalation)
        }
    }
}

// One row of a table: what the step shows, the start state, the input and the result.
struct MachineStep: Sendable, CustomTestStringConvertible {
    let what: String
    let before: MachineState
    let input: MachineInput
    let after: MachineState

    var testDescription: String { what }
}

private func step(
    _ what: String, _ before: MachineState, _ input: MachineInput, _ after: MachineState? = nil
) -> MachineStep {
    MachineStep(what: what, before: before, input: input, after: after ?? before)
}

// MARK: - The tables

private let hookEventSteps = [
    step(
        "a prompt submit ends a red prompt box", at(.needsYou, red(.prompt, 5)),
        hook(.userPromptSubmit, 6), working),
    step(
        "a tool use ends a red prompt box", at(.needsYou, red(.prompt, 5)), hook(.postToolUse, 6),
        working),
    step(
        "a prompt submit ends a red error box", at(.error, red(.error, 0)),
        hook(.userPromptSubmit, 1), working),
    step(
        "a prompt submit ends a box that no sample confirmed", at(.needsYou, yellow(10_000)),
        hook(.userPromptSubmit, 10_500), working),
    step(
        "a question tool gives a red prompt box", working,
        hook(.preToolUse, 7, tool: "AskUserQuestion"), at(.needsYou, red(.prompt, 7))),
    step("another tool changes nothing", working, hook(.preToolUse, 7, tool: "Bash")),
    step(
        "a permission request gives a red prompt box", working, hook(.permissionRequest, 8),
        at(.needsYou, red(.prompt, 8))),
    step(
        "a permission notification gives a red prompt box", working,
        hook(.notification, 9, notification: "permission_prompt"), at(.needsYou, red(.prompt, 9))),
    step(
        "an idle notification changes nothing", at(.needsYou, yellow(3)),
        hook(.notification, 4, notification: "idle_prompt")),
    step(
        "a stop gives a yellow box and the last message", working,
        hook(.stop, 10, message: "Done"), at(.needsYou, yellow(10), "Done")),
    step(
        "a prompt submit keeps the last message", at(.needsYou, yellow(10), "Done"),
        hook(.userPromptSubmit, 11), at(.working, .none, "Done")),
    step(
        "the next stop replaces the last message", at(.working, .none, "Done"),
        hook(.stop, 12, message: "Again"), at(.needsYou, yellow(12), "Again")),
    step(
        "a stop with no message keeps the last message", at(.working, .none, "Done"),
        hook(.stop, 12), at(.needsYou, yellow(12), "Done")),
    step(
        "a stop replaces a red prompt box with a yellow box", at(.needsYou, red(.prompt, 1)),
        hook(.stop, 50), at(.needsYou, yellow(50))),
    step(
        "a stop failure gives a red error box", working, hook(.stopFailure, 11),
        at(.error, red(.error, 11))),
    step(
        "a repeated stop failure keeps the box and its time", at(.error, red(.error, 5)),
        hook(.stopFailure, 6)),
    step(
        "a stop failure replaces an escalated box", at(.needsYou, red(.escalated, 10)),
        hook(.stopFailure, 20), at(.error, red(.error, 20))),
    step(
        "a permission request replaces a yellow box and keeps the message",
        at(.needsYou, yellow(1), "m"), hook(.permissionRequest, 50),
        at(.needsYou, red(.prompt, 50), "m")),
    step(
        "a prompt replaces a red error box", at(.error, red(.error, 0)),
        hook(.permissionRequest, 5), at(.needsYou, red(.prompt, 5))),
    step(
        "a prompt replaces an escalated box", at(.needsYou, red(.escalated, 10)),
        hook(.permissionRequest, 20), at(.needsYou, red(.prompt, 20))),
    step(
        "a repeated permission notification keeps the box and its time",
        at(.needsYou, red(.prompt, 100)),
        hook(.notification, 200, notification: "permission_prompt")),
    step(
        "a repeated question tool keeps the box and its time", at(.needsYou, red(.prompt, 100)),
        hook(.preToolUse, 300, tool: "AskUserQuestion")),
    step(
        "a repeated permission request keeps the box and its time",
        at(.needsYou, red(.prompt, 100)), hook(.permissionRequest, 400)),
    step(
        "a repeated prompt keeps the confirmed flag",
        at(.needsYou, red(.prompt, 20_000, confirmed: true)),
        hook(.notification, 21_000, notification: "permission_prompt")),
    step(
        "a stop gives a new box that is not confirmed",
        at(.needsYou, yellow(10_000, confirmed: true)), hook(.stop, 12_000),
        at(.needsYou, yellow(12_000))),
    step(
        "a stop failure gives a box that is not confirmed",
        at(.needsYou, yellow(10_000, confirmed: true)), hook(.stopFailure, 12_000),
        at(.error, red(.error, 12_000))),
    step(
        "a permission request gives a box that is not confirmed",
        at(.needsYou, yellow(10_000, confirmed: true)), hook(.permissionRequest, 12_000),
        at(.needsYou, red(.prompt, 12_000))),
    step(
        "an aborted turn gives idle with no box and keeps the partial answer", working,
        hook(.turnAborted, 10, message: "part"), at(.idle, .none, "part")),
    step(
        "an aborted turn with no answer keeps the last message", at(.working, .none, "Done"),
        hook(.turnAborted, 7), at(.idle, .none, "Done")),
    step(
        "a session start keeps a session that runs", at(.needsYou, yellow(1)),
        hook(.sessionStart, 2)),
    step(
        "a session end parks the session", at(.needsYou, yellow(1), "m"), hook(.sessionEnd, 2),
        at(.parked, .none, "m")),
    step(
        "a session end parks a session with a red box", at(.needsYou, red(.prompt, 0)),
        hook(.sessionEnd, 1), at(.parked)),
]

private let sampleSteps = [
    step("busy with no box gives working", .initial, busy(5), working),
    step(
        "busy ends a confirmed yellow box", at(.needsYou, yellow(1, confirmed: true), "m"),
        busy(5), at(.working, .none, "m")),
    step(
        "busy ends a confirmed red prompt box",
        at(.needsYou, red(.prompt, 20_000, confirmed: true)), busy(21_000), working),
    step(
        "busy ends a confirmed red error box", at(.error, red(.error, 0, confirmed: true)),
        busy(5000), working),
    step(
        "busy ends a confirmed escalated box",
        at(.needsYou, red(.escalated, 600_000, confirmed: true)), busy(600_500), working),
    // Claude Code can report busy while the Stop hooks run.
    step(
        "busy keeps a yellow box that no sample confirmed", at(.needsYou, yellow(10_000)),
        busy(10_300)),
    step(
        "busy keeps a red prompt box that no sample confirmed", at(.needsYou, red(.prompt, 20_000)),
        busy(21_000)),
    step(
        "busy keeps an escalated box that no sample confirmed",
        at(.needsYou, red(.escalated, 600_000)), busy(600_500)),
    step(
        "waiting gives a confirmed red prompt box", working, waiting(20),
        at(.needsYou, red(.prompt, 20, confirmed: true))),
    step(
        "waiting replaces a yellow box", at(.needsYou, yellow(10_000)), waiting(11_000),
        at(.needsYou, red(.prompt, 11_000, confirmed: true))),
    step(
        "waiting confirms a red prompt box and keeps its time", at(.needsYou, red(.prompt, 20_000)),
        waiting(20_500), at(.needsYou, red(.prompt, 20_000, confirmed: true))),
    step(
        "a second waiting sample keeps the time of the box",
        at(.needsYou, red(.prompt, 20, confirmed: true)), waiting(30)),
    step("idle after working gives idle", working, idle(5), at(.idle)),
    step(
        "idle confirms a yellow box", at(.needsYou, yellow(0)), idle(99_000),
        at(.needsYou, yellow(0, confirmed: true))),
    step(
        "idle confirms a red error box", at(.error, red(.error, 0)), idle(99_000),
        at(.error, red(.error, 0, confirmed: true))),
    step(
        "idle confirms an escalated box", at(.needsYou, red(.escalated, 600_000)), idle(601_000),
        at(.needsYou, red(.escalated, 600_000, confirmed: true))),
    step(
        "idle keeps a red prompt box that no sample confirmed",
        at(.needsYou, red(.prompt, 20_000)), idle(90_000)),
    step(
        "idle ends a confirmed red prompt box after the grace time",
        at(.needsYou, red(.prompt, 20_000, confirmed: true), "m"), idle(21_500),
        at(.idle, .none, "m")),
    step(
        "idle keeps a confirmed red prompt box in the grace time",
        at(.needsYou, red(.prompt, 20_000, confirmed: true)), idle(21_000)),
    step(
        "busy just after a confirmed box ends it", at(.needsYou, yellow(10_000, confirmed: true)),
        busy(10_002), working),
    step(
        "idle at the time of the box does not confirm it", at(.needsYou, yellow(10_000)),
        idle(10_000)),
    step(
        "busy before the box keeps a confirmed box",
        at(.needsYou, yellow(10_000, confirmed: true)), busy(9_900)),
    step(
        "busy at the time of the box keeps a confirmed box",
        at(.needsYou, yellow(10_000, confirmed: true)), busy(10_000)),
    step(
        "waiting before the box keeps a yellow box", at(.needsYou, yellow(10_000)),
        waiting(9_900)),
    step(
        "waiting before the box keeps a red prompt box", at(.needsYou, red(.prompt, 10_000)),
        waiting(9_000)),
]

// The yellow box of a session with no mod: an idle sample after busy or waiting means that the
// turn ended. The sample confirms this box.
private let pollYellowSteps = [
    step(
        "idle after busy gives a yellow box", working, idle(3000, after: .busy),
        at(.needsYou, yellow(3000, confirmed: true))),
    step(
        "idle after waiting gives a yellow box",
        at(.needsYou, red(.prompt, 1000, confirmed: true)), idle(3000, after: .waiting),
        at(.needsYou, yellow(3000, confirmed: true))),
    step(
        "the yellow box keeps the last message", at(.working, .none, "Done"),
        idle(3000, after: .busy), at(.needsYou, yellow(3000, confirmed: true), "Done")),
    step(
        "a live session gets no yellow box", working, idle(3000, after: .busy, live: true),
        at(.idle)),
    step("idle after idle gives no yellow box", working, idle(3000, after: .idle), at(.idle)),
    step("a first idle sample gives no yellow box", working, idle(3000), at(.idle)),
    step("busy after busy gives no box", working, busy(3000, after: .busy)),
    step("waiting with no reason gives no box", working, waiting(3000, for: nil, after: .busy)),
    step("a parked session gets no yellow box", at(.parked), idle(3000, after: .busy)),
    step(
        "idle after idle keeps the yellow box", at(.needsYou, yellow(3000, confirmed: true)),
        idle(5000, after: .idle)),
    step(
        "busy ends the yellow box", at(.needsYou, yellow(3000, confirmed: true)),
        busy(7000, after: .idle), working),
]

private let tickSteps = [
    step(
        "a yellow box turns red at the escalation time and takes the tick time",
        at(.needsYou, yellow(100), "m"), tick(600_100),
        at(.needsYou, red(.escalated, 600_100), "m")),
    step(
        "a yellow box stays yellow before the escalation time", at(.needsYou, yellow(0)),
        tick(599_999)),
    step(
        "an escalation time of 0 stops the escalation", at(.needsYou, yellow(0)),
        tick(600_000, escalation: .zero)),
    step(
        "the escalation keeps the confirmed flag", at(.needsYou, yellow(0, confirmed: true)),
        tick(600_000), at(.needsYou, red(.escalated, 600_000, confirmed: true))),
    step(
        "a tick keeps a red box", at(.needsYou, red(.prompt, 0)),
        tick(9_000_000_000, escalation: .milliseconds(1))),
    step(
        "a tick keeps a state with no box", working,
        tick(9_000_000_000, escalation: .milliseconds(1))),
]

// MARK: - The tests

@Suite("the state machine")
struct StateMachineTests {
    @Test("a new session is idle with no box")
    func initial() {
        #expect(MachineState.initial == at(.idle))
        #expect(MachineState.statusGrace == .seconds(1))
    }

    @Test("a hook event", arguments: hookEventSteps)
    func hookEvent(_ step: MachineStep) {
        #expect(step.before.apply(step.input) == step.after)
    }

    @Test("a status sample", arguments: sampleSteps)
    func statusSample(_ step: MachineStep) {
        #expect(step.before.apply(step.input) == step.after)
    }

    @Test("the yellow box of a poll", arguments: pollYellowSteps)
    func pollYellow(_ step: MachineStep) {
        #expect(step.before.apply(step.input) == step.after)
    }

    @Test("a tick", arguments: tickSteps)
    func tick(_ step: MachineStep) {
        #expect(step.before.apply(step.input) == step.after)
    }

    @Test(
        "a parked session ignores each event except a session start",
        arguments: HookEventName.allCases.filter { $0 != .sessionStart })
    func parkedIgnoresEvents(name: HookEventName) {
        let parked = at(.parked, .none, "last")
        let event = HookEvent(
            name, "s", at: 50, toolName: "AskUserQuestion", notificationType: "permission_prompt",
            lastAssistantMessage: "x")
        #expect(parked.onHookEvent(event) == parked)
    }

    @Test("a session start gives a parked session idle and keeps the last message")
    func parkedSessionStart() {
        let parked = at(.parked, .none, "last")
        #expect(
            parked.onHookEvent(HookEvent(.sessionStart, "s", at: 50)) == at(.idle, .none, "last"))
    }

    @Test(
        "a parked session ignores each status sample",
        arguments: [busy(5000), idle(5000, after: .busy), waiting(5000)])
    func parkedIgnoresSamples(input: MachineInput) {
        let parked = at(.parked, .none, "last")
        #expect(parked.apply(input) == parked)
    }

    @Test(
        "an idle sample clears a confirmed red prompt box only more than 1 s after the box",
        arguments: [
            (10_000, false), (10_001, false), (10_999, false), (11_000, false), (11_001, true),
            (20_000, true), (9_999, false),
        ])
    func idleGrace(sampledAt: Int, clears: Bool) {
        let box = at(.needsYou, red(.prompt, 10_000, confirmed: true))
        #expect(box.apply(idle(sampledAt)) == (clears ? at(.idle) : box))
    }

    @Test("a waiting sample with no reason changes nothing", arguments: [nil, ""] as [String?])
    func waitingWithoutReason(reason: String?) {
        for start in everyState {
            #expect(start.apply(waiting(99_999, for: reason)) == start, "\(start)")
        }
    }

    @Test("an unknown status changes nothing", arguments: everyState)
    func unknownStatus(start: MachineState) {
        #expect(start.onStatus(StatusSample(.unknown, at: 99_999, prevStatus: .busy)) == start)
    }

    @Test(
        "a yellow box turns red when the time reaches the escalation time",
        arguments: [
            // (escalation time in ms, ms after the box, turns red)
            (600_000, 599_999, false), (600_000, 600_000, true), (600_000, 600_001, true),
            (1, 0, false), (1, 1, true), (1000, 999, false), (1000, 1000, true),
            (0, 10_000_000, false), (-5, 10_000_000, false), (-1, 0, false),
        ])
    func escalation(escalationMs: Int, after: Int, turnsRed: Bool) {
        let yellowBox = at(.needsYou, yellow(1000, confirmed: true), "m")
        let now = 1000 + after
        let result = yellowBox.onTick(now: now, escalation: .milliseconds(escalationMs))
        let redBox = at(.needsYou, red(.escalated, now, confirmed: true), "m")
        #expect(result == (turnsRed ? redBox : yellowBox))
    }

    @Test(
        "a tick changes nothing for a state with no yellow box",
        arguments: everyState.filter { $0.box.alert.colour != .yellow })
    func tickWithoutYellow(start: MachineState) {
        #expect(start.onTick(now: 99_999_999, escalation: .milliseconds(1)) == start)
    }

    @Test("a park ends the box and keeps the last message", arguments: everyState)
    func park(start: MachineState) {
        #expect(start.parked() == at(.parked, .none, start.lastMessage))
    }

    // A PR session gets no yellow box.
    @Test("without yellow, a yellow box goes and each other state stays", arguments: everyState)
    func withoutYellow(start: MachineState) {
        if case .yellow = start.box {
            #expect(start.withoutYellow() == at(.idle, .none, start.lastMessage))
        } else {
            #expect(start.withoutYellow() == start)
        }
    }

    @Test("the row gets the colour, the reason and the time of the box")
    func rowValues() {
        #expect(MachineState.Box.none.alert == .none)
        #expect(yellow(5, confirmed: true).alert == .yellow(since: 5))
        #expect(red(.error, 5).alert == .red(.error, since: 5))
        #expect(red(.escalated, 5, confirmed: true).alert == .red(.escalated, since: 5))
        #expect(MachineState.Box.none.since == nil)
        #expect(yellow(5).since == 5)
        #expect(red(.prompt, 7).since == 7)
    }
}
