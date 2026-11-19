import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostSessions

// MARK: - Values

extension AgentEntry {
    // A copy with some values changed.
    func with(_ change: (inout AgentEntry) -> Void) -> AgentEntry {
        var copy = self
        change(&copy)
        return copy
    }
}

// A background entry. The parameters change the values that a test names.
func bg(
    cwd: String = "/p", id: ShortID? = "aaaaaaaa", background: Bool = true, name: String = "alpha",
    pid: pid_t? = 5, sessionId: String = "s1", startedAt: Int = 1, status: AgentStatus = .idle,
    waitingFor: String? = nil
) -> AgentEntry {
    AgentEntry(
        sessionId: sessionId, cwd: cwd, isBackground: background, startedAt: startedAt,
        name: name, status: status, pid: pid, id: id, waitingFor: waitingFor)
}

func ev(_ name: HookEventName, _ sessionId: String, _ at: Int) -> HookEvent {
    HookEvent(name, sessionId, at: at)
}

func registry(_ store: RegistryStore = RegistryStore()) -> SessionRegistry {
    SessionRegistry(store: store, escalation: .seconds(600))
}

// A fixed UUID source for the tests: 00000000-0000-4000-8000-<12-digit count>.
func countingIDs() -> @Sendable () -> String {
    let count = Mutex(0)
    return {
        let n = count.withLock { value in
            value += 1
            return value
        }
        let digits = String(n)
        return "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - digits.count)
            + digits
    }
}

extension Array {
    // The element at the index, or nil.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension SessionRegistry {
    func row(_ id: String) -> SessionRow? { rows().first { $0.sessionId == id } }
    var ids: [String] { rows().map(\.sessionId) }
}

// MARK: - Fixtures

enum Fixture {
    // The one real sample of the output of claude agents --json, and a registry file. The folder
    // Fixtures next to this file is a resource of the test target.
    static func data(_ name: String) throws -> Data {
        let folder = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try Data(contentsOf: folder.appending(path: name))
    }
}

// MARK: - Store helpers
