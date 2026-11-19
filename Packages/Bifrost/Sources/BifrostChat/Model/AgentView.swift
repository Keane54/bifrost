// The Claude Code agent view in the screen lines of a chat window (docs/behaviour/chat.md, "The
// agent view"). The left arrow key opens this view. Bifrost can attach again, but only a few
// times.

// One row of the terminal screen. A wrapped row continues the row above it.
package struct ScreenRow: Sendable, Equatable {
    package var text: String
    package var wrapped: Bool

    package init(text: String, wrapped: Bool) {
        self.text = text
        self.wrapped = wrapped
    }

    // True when the row holds only white space (Character.isWhitespace), or nothing. A chat
    // window shows its first text when a row is not blank.
    package var isBlank: Bool { AgentView.isBlank(text) }
}

// The watch of a chat window for the agent view.
package enum AgentWatch: Sendable, Equatable {
    // The window checks the screen, and its input is free.
    case watching
    // The agent view shows, and the reattach waits for a row that can attach. The input is
    // blocked.
    case waiting
    // The window attached again too often. It checks no more, and the input stays blocked.
    case gaveUp
}

// What a screen check does. free: the input starts again. Each other step except none stops the
// input at once.
package enum AgentStep: Sendable, Equatable {
    case none, free, giveUp, wait, reattach
}

package enum AgentView {
    // Bifrost reads the screen 250 ms after the last chunk. During continuous output, for
    // example a spinner, it reads the screen at least each second. So the input stops soon
    // (D10).
    package static let quiet = Duration.milliseconds(250)
    package static let maxWait = Duration.seconds(1)
    // The window gives up when the history has this number of attaches in the window of time.
    package static let maxReattach = 3
    package static let reattachWindow = Duration.seconds(60)

    // The footer of the agent view, and the number of the last non-empty lines that can hold
    // it. Text that a conversation quotes higher on the screen does not match.
    private static let footer = "enter to return · space to reply"
    private static let footerLines = 3

    // The counts line of the agent view. The digits are ASCII and the match is on Unicode
    // scalars. A Regex is not Sendable, so this is a computed property.
    private static var counts: Regex<Substring> {
        /[0-9]+ awaiting input · [0-9]+ working · [0-9]+ completed/.matchingSemantics(
            .unicodeScalar)
    }

    // In the agent view, the footer is the last non-empty line. A footer line with a border
    // after it is in the prompt box. A paste of more than one line puts the footer on a
    // continuation line. That line starts with spaces only, so the start rule of isFooterLine
    // does not refuse it.
    package static func isAgentView(_ lines: [String]) -> Bool {
        let filled = lines.filter { !isBlank($0) }
        let start = max(0, filled.count - footerLines)
        let footerShows = filled.indices.contains { i in
            i >= start && isFooterLine(filled[i]) && !filled[(i + 1)...].contains(where: isBorder)
        }
        let pattern = counts
        return footerShows && lines.contains { $0.contains(pattern) }
    }

    // A narrow terminal wraps the footer into more than one row. This function joins the rows
    // of each line. Do not trim the white space of a row before the join, because a wrap can
    // occur at a space. The trim of the end of each line occurs after the join.
    package static func joinWrapped(_ rows: [ScreenRow]) -> [String] {
        var lines: [String] = []
        for row in rows {
            if row.wrapped, let last = lines.indices.last {
                lines[last] += row.text
            } else {
                lines.append(row.text)
            }
        }
        return lines.map(trimmedEnd)
    }

    // The wait before the next check, at the time of a chunk. firstAt is the time of the first
    // chunk after the last check.
    package static func checkDelay(
        firstAt: ContinuousClock.Instant, now: ContinuousClock.Instant
    ) -> Duration {
        max(.zero, min(quiet, maxWait - firstAt.duration(to: now)))
    }

    // The attaches of the history that are in the window of time. The owner of a history keeps
    // only these.
    package static func recentAttaches(
        _ history: [ContinuousClock.Instant], now: ContinuousClock.Instant
    ) -> [ContinuousClock.Instant] {
        history.filter { $0.duration(to: now) < reattachWindow }
    }

    // The step of one screen check. history has the times of the recent attaches of the
    // session.
    package static func step(
        _ watch: AgentWatch, agentView: Bool, targetReady: Bool,
        history: [ContinuousClock.Instant], now: ContinuousClock.Instant
    ) -> AgentStep {
        switch watch {
        case .gaveUp: return .none
        case .waiting where !agentView: return .free
        case .watching where !agentView: return .none
        case .watching, .waiting: break
        }
        if recentAttaches(history, now: now).count >= maxReattach { return .giveUp }
        return targetReady ? .reattach : .wait
    }

    // True for a step that stops the input of the window.
    package static func blocks(_ step: AgentStep) -> Bool {
        switch step {
        case .giveUp, .wait, .reattach: true
        case .none, .free: false
        }
    }

    // The footer must fill its line. Text before it, such as a prompt mark, gives no match.
    // White space and box-drawing characters can frame the line. The footer matches on Unicode
    // scalars, as Claude Code draws it.
    private static func isFooterLine(_ line: String) -> Bool {
        guard let first = line.firstIndex(where: { !isFrame($0) }) else { return false }
        return line[first...].unicodeScalars.starts(with: footer.unicodeScalars)
    }

    // A border of the prompt box or a rule line: only box-drawing characters and white space,
    // with at least one box-drawing character.
    private static func isBorder(_ line: String) -> Bool {
        line.allSatisfy(isFrame) && line.contains(where: isBox)
    }

    fileprivate static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    private static func trimmedEnd(_ line: String) -> String {
        guard let last = line.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(line[...last])
    }

    private static func isFrame(_ character: Character) -> Bool {
        character.isWhitespace || isBox(character)
    }

    // The box-drawing characters U+2500 to U+257F.
    private static func isBox(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x2500...0x257F).contains(scalar.value)
    }
}
