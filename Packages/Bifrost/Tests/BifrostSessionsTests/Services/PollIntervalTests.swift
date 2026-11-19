import Testing

@testable import BifrostSessions

@Suite("poll interval")
struct PollIntervalTests {
    @Test("the normal interval applies to a visible window")
    func visible() {
        #expect(RegistryTiming.pollInterval(.seconds(2), visible: true) == .seconds(2))
    }

    @Test("a hidden window uses 15 seconds")
    func hidden() {
        #expect(RegistryTiming.hiddenPoll == .seconds(15))
        #expect(RegistryTiming.pollInterval(.seconds(2), visible: false) == .seconds(15))
    }

    @Test("a normal interval above 15 seconds stays while hidden")
    func longStays() {
        #expect(RegistryTiming.pollInterval(.seconds(30), visible: false) == .seconds(30))
    }
}
