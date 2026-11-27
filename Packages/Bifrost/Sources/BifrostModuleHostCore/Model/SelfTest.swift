// What the host's self-test found once the sandbox was on: whether any descriptor past 0 to 2 was
// open, and whether a read of /etc/passwd, a TCP socket and a process start got through. It goes
// out in the hello either way, so the parent always sees the real outcomes.
package struct SelfTestResult: Codable, Equatable, Sendable {
    package enum Outcome: String, Codable, Sendable {
        case closed, denied, open, allowed
    }

    package let fds: Outcome
    package let read: Outcome
    package let socket: Outcome
    package let spawn: Outcome

    package init(fds: Outcome, read: Outcome, socket: Outcome, spawn: Outcome) {
        self.fds = fds
        self.read = read
        self.socket = socket
        self.spawn = spawn
    }

    // The host only goes on to read code when every probe hit the sandbox, so a sandbox that
    // quietly stopped working fails closed.
    package var passed: Bool {
        fds == .closed && read == .denied && socket == .denied && spawn == .denied
    }
}
