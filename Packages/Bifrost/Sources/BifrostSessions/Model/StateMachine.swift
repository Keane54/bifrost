// The state machine of one session. Each function gives a new value and changes nothing.

package struct MachineState: Sendable, Equatable {
    // The alert box of a session. since is the time of the box. confirmed is true after a status
    // sample confirmed the box. A status sample clears only a confirmed box
    // (docs/behaviour/registry.md, "States and alert boxes"). Only a red box has a reason.
    package enum Box: Sendable, Equatable {
        case none
        case yellow(since: Int, confirmed: Bool)
        case red(SessionBoxReason, since: Int, confirmed: Bool)
    }

    package var state: SessionState
    package var box: Box
    package var lastMessage: String?

    package init(_ state: SessionState, box: Box = .none, lastMessage: String? = nil) {
        self.state = state
        self.box = box
        self.lastMessage = lastMessage
    }

    package static let initial = MachineState(.idle)

    // An idle sample counts only when it starts more than this time after the red box. An older
    // poll can finish after the prompt and report an idle that is no longer true.
    package static let statusGrace = Duration.seconds(1)
}

extension MachineState.Box {
    // The box as the row shows it.
    package var alert: SessionAlert {
        switch self {
        case .none: .none
        case .yellow(let since, _): .yellow(since: since)
        case .red(let reason, let since, _): .red(reason, since: since)
        }
    }

    package var since: Int? {
        switch self {
        case .none: nil
        case .yellow(let since, _), .red(_, let since, _): since
        }
    }

    var confirmed: Bool {
        switch self {
        case .none: false
        case .yellow(_, let confirmed), .red(_, _, let confirmed): confirmed
        }
    }

    // The same box with the confirmed flag.
    func confirming() -> Self {
        switch self {
        case .none: .none
        case .yellow(let since, _): .yellow(since: since, confirmed: true)
        case .red(let reason, let since, _): .red(reason, since: since, confirmed: true)
        }
    }
}


// One sample of the session list for one session. prevStatus is the status before this sample:
// nil for a new session. live is true when the mod sent a line for the session recently.
package struct StatusSample: Sendable, Equatable {
    package var status: AgentStatus
    package var waitingFor: String?
    package var sampledAt: Int
    package var prevStatus: AgentStatus?
    package var live: Bool

    package init(
        _ status: AgentStatus, at sampledAt: Int, waitingFor: String? = nil,
        prevStatus: AgentStatus? = nil, live: Bool = false
    ) {
        self.status = status
        self.waitingFor = waitingFor
        self.sampledAt = sampledAt
        self.prevStatus = prevStatus
        self.live = live
    }
}

extension MachineState {
    // The state with no box. The last message stays.
    private func withoutBox(_ state: SessionState) -> MachineState {
        MachineState(state, lastMessage: lastMessage)
    }

    // The state with a new box. The last message stays.
    private func with(_ state: SessionState, _ box: Box) -> MachineState {
        MachineState(state, box: box, lastMessage: lastMessage)
    }

    private var isPromptBox: Bool {
        if case .red(.prompt, _, _) = box { true } else { false }
    }

    // A repeated prompt event keeps the box, its time and its confirmed flag. A box from a hook
    // event is not confirmed.
    private func promptBox(at: Int) -> MachineState {
        isPromptBox ? self : with(.needsYou, .red(.prompt, since: at, confirmed: false))
    }

    // Apply one state event of the mod.
    package func onHookEvent(_ ev: HookEvent) -> MachineState {
        // A parked session leaves the parked state only on SessionStart. For a session that runs,
        // SessionStart changes nothing (D7): the mod sends it again at each reload.
        if state == .parked { return ev.name == .sessionStart ? withoutBox(.idle) : self }
        switch ev.name {
        case .userPromptSubmit, .postToolUse:
            return withoutBox(.working)
        case .preToolUse:
            return ev.toolName == "AskUserQuestion" ? promptBox(at: ev.at) : self
        case .permissionRequest:
            return promptBox(at: ev.at)
        case .notification:
            return ev.notificationType == "permission_prompt" ? promptBox(at: ev.at) : self
        case .stop:
            var next = with(.needsYou, .yellow(since: ev.at, confirmed: false))
            if let message = ev.lastAssistantMessage { next.lastMessage = message }
            return next
        case .turnAborted:
            // The user stopped the turn. This needs no alert (D6). Keep the partial answer.
            var next = withoutBox(.idle)
            if let message = ev.lastAssistantMessage { next.lastMessage = message }
            return next
        case .stopFailure:
            // The mod can send the same error two times. A repeated error keeps the box.
            if case .red(.error, _, _) = box { return self }
            return with(.error, .red(.error, since: ev.at, confirmed: false))
        case .sessionEnd:
            return withoutBox(.parked)
        case .sessionStart:
            return self
        }
    }

    // Apply one sample of the session list: first the M1 rules, then the poll yellow box (O3)
    // for a session with no mod. An idle sample after busy or waiting with no box means that the
    // turn ended. The sample confirms this box.
    package func onStatus(_ sample: StatusSample) -> MachineState {
        let next = statusRules(sample)
        let turnEnded =
            sample.status == .idle && (sample.prevStatus == .busy || sample.prevStatus == .waiting)
        guard turnEnded, next.box == .none, next.state != .parked, !sample.live else { return next }
        return next.with(.needsYou, .yellow(since: sample.sampledAt, confirmed: true))
    }

    // A sample confirms the current box, and clears a box only after a sample confirmed it.
    // Claude Code can report busy while the Stop hooks run.
    private func statusRules(_ sample: StatusSample) -> MachineState {
        if state == .parked { return self }
        // A sample that is not newer than the box comes from a poll that started before it.
        if let since = box.since, sample.sampledAt <= since { return self }
        switch sample.status {
        case .busy:
            return box == .none || box.confirmed ? withoutBox(.working) : self
        case .waiting:
            guard let waitingFor = sample.waitingFor, !waitingFor.isEmpty else { return self }
            if isPromptBox { return with(state, box.confirming()) }
            return with(.needsYou, .red(.prompt, since: sample.sampledAt, confirmed: true))
        case .idle:
            switch box {
            case .red(.prompt, let since, let confirmed):
                let late = Duration.milliseconds(sample.sampledAt - since) > Self.statusGrace
                return confirmed && late ? withoutBox(.idle) : self
            case .yellow, .red:
                return with(state, box.confirming())
            case .none:
                return state == .working ? withoutBox(.idle) : self
            }
        case .unknown:
            return self
        }
    }

    // A yellow box changes to red after the escalation time. The confirmed flag stays. An
    // escalation time of 0 or less stops the escalation.
    package func onTick(now: Int, escalation: Duration) -> MachineState {
        guard case .yellow(let since, let confirmed) = box, escalation > .zero,
            Duration.milliseconds(now - since) >= escalation
        else { return self }
        return with(state, .red(.escalated, since: now, confirmed: confirmed))
    }

    package func parked() -> MachineState { withoutBox(.parked) }

    // A PR session gets no yellow box (docs/behaviour/registry.md, "States and alert boxes"). A
    // yellow box becomes no box with the state idle. The last message stays.
    package func withoutYellow() -> MachineState {
        if case .yellow = box { withoutBox(.idle) } else { self }
    }
}
