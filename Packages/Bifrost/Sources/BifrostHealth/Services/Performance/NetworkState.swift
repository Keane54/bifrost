import BifrostFoundation
import Darwin
import Foundation
import Network

// The kind of the link of the Mac to the network.
package enum LinkKind: Sendable, Equatable {
    case wifi, ethernet, vpn, other

    // A utun or ipsec interface is a VPN. Else the type of the interface decides.
    package init(name: String, type: NWInterface.InterfaceType) {
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") {
            self = .vpn
            return
        }
        switch type {
        case .wifi: self = .wifi
        case .wiredEthernet: self = .ethernet
        default: self = .other
        }
    }
}

// The state of the network path: online or not, and the interface that the system uses first.
package struct NetworkPath: Sendable, Equatable {
    package var online: Bool
    package var kind: LinkKind?
    // The name of the interface, for its byte counters, for example "en0".
    package var interface: String?

    package init(online: Bool, kind: LinkKind?, interface: String?) {
        self.online = online
        self.kind = kind
        self.interface = interface
    }
}

// The byte counters of an interface at a time of the timeline. The counters of the system have 32
// bits, so they wrap at 4 GB.
package struct ByteCount: Sendable, Equatable {
    package var received: UInt32
    package var sent: UInt32
    package var at: Duration

    package init(received: UInt32, sent: UInt32, at: Duration) {
        self.received = received
        self.sent = sent
        self.at = at
    }
}

// The download and the upload rates in bytes a second.
package struct ByteRates: Sendable, Equatable {
    package var down: Double
    package var up: Double

    package init(down: Double, up: Double) {
        self.down = down
        self.up = up
    }
}

// The response time of a host: the time until the headers of the answer, no answer in 5 s, or a
// DNS or connection error.
package enum ResponseTime: Sendable, Equatable {
    case answered(Duration)
    case noAnswer
    case unreachable

    // Each HTTP status is an answer.
    package init(_ answer: GuardedGet.HeadAnswer, after time: Duration) {
        switch answer {
        case .status: self = .answered(time)
        case .timedOut: self = .noAnswer
        case .failed: self = .unreachable
        }
    }
}

// The values of the section "Network" of the panel.
package struct NetworkValues: Sendable, Equatable {
    package var online: Bool
    package var kind: LinkKind?
    package var rates: ByteRates?
    package var anthropic: ResponseTime?
    package var github: ResponseTime?
}

// The reads of the network (docs/behaviour/health.md, "Performance"): the path from NWPathMonitor,
// the byte counters from getifaddrs, and one HEAD request to Anthropic and one to GitHub for the
// response times. A request has no token and no data of the user (GuardedGet). A test home has no
// network state, so a test makes no request.
package struct NetworkState: Sendable {
    // The hosts of the response times.
    package static let anthropic = probe("https://api.anthropic.com")
    package static let github = probe("https://api.github.com")
    package static let probeTimeout = Duration.seconds(5)

    private let get: GuardedGet

    // The configuration of each request. The app uses an ephemeral configuration.
    package init(
        configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) {
        get = GuardedGet(configuration: configuration)
    }

    // The path of now, then each change, until the reader stops.
    package func paths() -> AsyncStream<NetworkPath> {
        AsyncStream { continuation in
            let task = Task {
                for await path in NWPathMonitor() {
                    let first = path.availableInterfaces.first
                    continuation.yield(
                        NetworkPath(
                            online: path.status == .satisfied,
                            kind: first.map { LinkKind(name: $0.name, type: $0.type) },
                            interface: first?.name))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // The byte counters of the interface (getifaddrs, the link entry), or nil when the interface
    // is not there.
    package func bytes(of interface: String, at time: Duration) -> ByteCount? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var cursor = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr,
                address.pointee.sa_family == UInt8(AF_LINK),
                String(cString: entry.pointee.ifa_name) == interface,
                let data = entry.pointee.ifa_data
            else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            return ByteCount(received: counters.ifi_ibytes, sent: counters.ifi_obytes, at: time)
        }
        return nil
    }

    // The rates between two counts of one interface. A counter that wrapped once counts the
    // bytes after the wrap. nil when no time passed.
    package static func rates(from earlier: ByteCount, to later: ByteCount) -> ByteRates? {
        guard later.at > earlier.at else { return nil }
        let seconds = (later.at - earlier.at) / .seconds(1)
        return ByteRates(
            down: Double(later.received &- earlier.received) / seconds,
            up: Double(later.sent &- earlier.sent) / seconds)
    }

    // The response times of the two hosts, with their requests at the same time.
    @concurrent package func responseTimes() async -> ProbeTimes {
        async let anthropic = responseTime(of: Self.anthropic)
        async let github = responseTime(of: Self.github)
        return ProbeTimes(anthropic: await anthropic, github: await github)
    }

    // One HEAD request to the host, with no token and no cookie. The time is the real time until
    // the headers of the answer.
    @concurrent package func responseTime(of url: URL) async -> ResponseTime {
        let clock = ContinuousClock()
        let start = clock.now
        let answer = await get.head(url, timeout: Self.probeTimeout)
        return ResponseTime(answer, after: clock.now - start)
    }

    private static func probe(_ text: String) -> URL {
        guard let url = URL(string: text) else { preconditionFailure("bad probe URL") }
        return url
    }
}

// The response times of Anthropic and GitHub.
package struct ProbeTimes: Sendable, Equatable {
    package var anthropic: ResponseTime
    package var github: ResponseTime
}
