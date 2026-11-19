// The network values of the Performance panel: the kind of the link, the byte rates and the
// response times. Safety: no test makes a request or reads the real network.
import BifrostFoundation
import Foundation
import Network
import Testing

@testable import BifrostHealth

@Suite("performance network state")
struct NetworkStateTests {
    @Test func theKindComesFromTheInterface() {
        #expect(LinkKind(name: "en0", type: .wifi) == .wifi)
        #expect(LinkKind(name: "en5", type: .wiredEthernet) == .ethernet)
        #expect(LinkKind(name: "utun4", type: .other) == .vpn)
        #expect(LinkKind(name: "ipsec0", type: .other) == .vpn)
        #expect(LinkKind(name: "pdp_ip0", type: .cellular) == .other)
    }

    @Test func theRatesComeFromTwoCounts() {
        let first = ByteCount(received: 1_000, sent: 500, at: .seconds(10))
        let second = ByteCount(received: 21_000, sent: 4_500, at: .seconds(12))
        #expect(NetworkState.rates(from: first, to: second) == ByteRates(down: 10_000, up: 2_000))
        // The counters of the interface wrap at 4 GB.
        let high = ByteCount(received: UInt32.max - 999, sent: 0, at: .seconds(10))
        let wrapped = ByteCount(received: 1_000, sent: 0, at: .seconds(12))
        #expect(NetworkState.rates(from: high, to: wrapped) == ByteRates(down: 1_000, up: 0))
        // No time between the counts gives no rate.
        #expect(NetworkState.rates(from: first, to: first) == nil)
    }

    @Test func eachAnswerGivesAResponseTime() {
        let time = Duration.milliseconds(120)
        #expect(ResponseTime(.status(404), after: time) == .answered(time))
        #expect(ResponseTime(.status(302), after: time) == .answered(time))
        #expect(ResponseTime(.timedOut, after: .seconds(5)) == .noAnswer)
        #expect(ResponseTime(.failed, after: time) == .unreachable)
    }

    @Test func theProbesGoToTheTwoHosts() {
        #expect(NetworkState.anthropic.absoluteString == "https://api.anthropic.com")
        #expect(NetworkState.github.absoluteString == "https://api.github.com")
        #expect(NetworkState.probeTimeout == .seconds(5))
    }
}
