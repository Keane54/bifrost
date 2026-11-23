// The log line of a slow main thread (docs/behaviour/health.md, "Performance").
import Testing

@testable import BifrostHealth

@Suite("slow main thread log")
struct SlowMainLogTests {
    @Test func aSlowWindowGivesOneLineAndANewWindowGivesAnother() {
        var log = SlowMainLog()
        #expect(log.line(delay: nil, window: 1) == nil)
        #expect(log.line(delay: .milliseconds(200), window: 1) == nil)
        #expect(
            log.line(delay: .milliseconds(201), window: 1)
                == "main thread slow to respond: up to 201 ms")
        #expect(log.line(delay: .milliseconds(201), window: 1) == nil)
        #expect(log.line(delay: .milliseconds(900), window: 1) == nil)
        #expect(log.line(delay: .milliseconds(50), window: 2) == nil)
        #expect(
            log.line(delay: .milliseconds(201), window: 3)
                == "main thread slow to respond: up to 201 ms")
    }
}
