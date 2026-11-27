import Testing

@testable import BifrostModuleHostCore

// The self-test only passes when every probe hit the sandbox, so a host whose sandbox quietly
// stopped working ends before it reads any code.

// A result where every probe hit the sandbox, apart from the outcome a test changes.
private func result(
    fds: SelfTestResult.Outcome = .closed, read: SelfTestResult.Outcome = .denied,
    socket: SelfTestResult.Outcome = .denied, spawn: SelfTestResult.Outcome = .denied
) -> SelfTestResult {
    SelfTestResult(fds: fds, read: read, socket: socket, spawn: spawn)
}

@Suite("Self-test")
struct SelfTestTests {
    @Test func allDeniedAndClosedPasses() {
        #expect(result().passed)
    }

    @Test func anOpenDescriptorFails() {
        #expect(!result(fds: .open).passed)
    }

    @Test func anAllowedReadFails() {
        #expect(!result(read: .allowed).passed)
    }

    @Test func anAllowedSocketFails() {
        #expect(!result(socket: .allowed).passed)
    }

    @Test func anAllowedSpawnFails() {
        #expect(!result(spawn: .allowed).passed)
    }
}
