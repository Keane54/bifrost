import Foundation

// One check of the report: its name, whether it passed and what it measured. The value goes in
// pass or fail, so the phase 1 plan gets the real numbers either way.
struct Check {
    let name: String
    let passed: Bool
    let value: JSON
}

// The checks of the plan against the real host. The main host gets the test module and stays up
// for the hello, the self-test, the module's start lines, the first tree, the pings, the clicks,
// the footprints and its stderr. A second host gets a code line over the cap and a third has its
// stdin closed after the hello. Each host keeps its stdin open until its last check is done, and
// is killed and reaped at the end whatever happened.
struct HostChecks {
    let hostPath: String
    let source: String

    private static let helloWait = Duration.seconds(5)
    // The first batch passes within 500 ms, but the check waits longer so a slow one still gets
    // its real time in the report.
    private static let firstTreeLimit = Duration.milliseconds(500)
    private static let firstTreeWait = Duration.seconds(10)
    // A first tree has to be the whole 50-card app, counting create and text ops together.
    private static let firstTreeNodes = 500
    // The module logs its globals line and its import line within this long of the code line.
    private static let startLinesLimit = Duration.seconds(2)
    private static let globalNames = [
        "fetch", "XMLHttpRequest", "WebSocket", "Worker", "require", "process",
    ]
    private static let pings = 1_000
    private static let roundTripLimit = Duration.milliseconds(5)
    private static let clicks = 1_000
    private static let replyWait = Duration.seconds(2)
    // With the JIT on, the spike's host reached 90 MB after 1,000 clicks.
    private static let footprintLimit: UInt64 = 40 * 1_048_576
    private static let oversizedBytes = 9 * 1_048_576
    private static let oversizedLimit = Duration.seconds(2)
    private static let stdinClosedLimit = Duration.seconds(1)
    private static let moduleNames = [
        "globals", "importRejected", "firstTree", "roundTrip", "footprintFirstTree",
        "footprintAfterEvents",
    ]

    func run() -> [Check] {
        // Opened before the first host starts and held until the last one has gone.
        let canary = Canary.open()
        defer { canary?.close() }
        return mainHost(canary: canary) + [oversizedLine(), stdinClosed()]
    }

    private func mainHost(canary: Canary?) -> [Check] {
        let host: HostProcess
        do {
            host = try HostProcess.start(hostPath)
        } catch {
            let names = ["hello", "selfTest"] + Self.moduleNames + ["stderrEmpty"]
            return names.map {
                Check(name: $0, passed: false, value: ["error": .string(error.message)])
            }
        }
        defer { host.stop() }
        // Nothing goes to the host before its hello, so the hello can't depend on any input.
        let hello = host.next(by: host.startedAt + Self.helloWait)
        let first = [Self.hello(hello, host), Self.selfTest(hello, canary)]
        guard first.allSatisfy(\.passed) else {
            // The host ends itself after a failed self-test, so its exit is in by the time the
            // skipped checks say what happened to it.
            let stderr = Self.stderrEmpty(host)
            let skipped = Self.moduleNames.map { name in
                Check(
                    name: name, passed: false,
                    value: [
                        "error": "the host never got the code, as the hello or self-test failed",
                        "host": host.state,
                    ])
            }
            return first + skipped + [stderr]
        }
        return first + moduleChecks(host) + [Self.stderrEmpty(host)]
    }

    // The code goes in once, and everything after it reads what the module does with it.
    private func moduleChecks(_ host: HostProcess) -> [Check] {
        let code = Self.lineBytes(["type": "code", "source": .string(source)])
        let sent = ContinuousClock.now
        let delivered = host.send(code, by: sent + Self.firstTreeWait) == code.count
        let batch = delivered ? host.next(by: sent + Self.firstTreeWait) : nil
        let firstFootprint = host.footprint
        let firstTree = Self.firstTree(batch, sent: sent, host: host)
        let globals = Self.globals(
            host.log(by: sent + Self.startLinesLimit) { $0.hasPrefix("globals ") })
        let importLine = host.log(by: sent + Self.startLinesLimit) {
            $0.hasPrefix("import rejected") || $0.hasPrefix("import allowed")
        }
        let importRejected = Self.importRejected(importLine, sent: sent)
        let roundTrip = Self.roundTrip(host)
        let footprintFirstTree = Self.footprintFirstTree(
            firstFootprint, problem: Self.firstBatchProblem(delivered: delivered, batch))
        let footprintAfterEvents = Self.clicks(host, handler: Self.buttonHandler(batch))
        return [
            globals, importRejected, firstTree, roundTrip, footprintFirstTree, footprintAfterEvents,
        ]
    }

    // The hello must be the host's very first line and arrive within 5 s of the start.
    private static func hello(_ line: HostLine?, _ host: HostProcess) -> Check {
        guard let line else {
            return Check(
                name: "hello", passed: false,
                value: ["error": "no hello within 5 s", "host": host.state])
        }
        guard line.type == "hello", line.index == 0 else {
            return Check(
                name: "hello", passed: false,
                value: ["error": "the first line wasn't a hello", "line": .string(line.text)])
        }
        let elapsed = line.at - host.startedAt
        let version = line.json?["protocol"] ?? .null
        return Check(
            name: "hello", passed: version == 0 && elapsed <= helloWait,
            value: ["ms": milliseconds(elapsed), "protocol": version])
    }

    // The host's own probes must all hit the sandbox, and the canary must really have been
    // inheritable, or a closed fds outcome would prove nothing.
    private static func selfTest(_ line: HostLine?, _ canary: Canary?) -> Check {
        let outcomes = line?.type == "hello" ? line?.json?["selfTest"] : nil
        let expected = ["fds": "closed", "read": "denied", "socket": "denied", "spawn": "denied"]
        let probesPassed = expected.allSatisfy { outcomes?[$0.key]?.string == $0.value }
        let canaryValue: JSON =
            switch canary {
            case .some(let canary) where canary.inheritable: .number(Double(canary.descriptor))
            case .some: "not inheritable"
            case .none: "not opened"
            }
        return Check(
            name: "selfTest", passed: probesPassed && canary?.inheritable == true,
            value: ["canaryFd": canaryValue, "outcomes": outcomes ?? .null])
    }

    private static func firstTree(
        _ line: HostLine?, sent: ContinuousClock.Instant, host: HostProcess
    ) -> Check {
        guard let line, line.type == "batch", let ops = line.json?["ops"]?.array else {
            return Check(
                name: "firstTree", passed: false,
                value: [
                    "error": line == nil ? "no batch within 10 s" : "the first line wasn't a batch",
                    "line": line.map { .string($0.text) } ?? .null,
                    "logs": .array(host.logs.map { .string($0.logText) }),
                    "host": host.state,
                ])
        }
        let created = ops.count { $0[0] == "create" }
        let texts = ops.count { $0[0] == "text" }
        let elapsed = line.at - sent
        return Check(
            name: "firstTree",
            passed: elapsed <= firstTreeLimit && created + texts > firstTreeNodes,
            value: [
                "ms": milliseconds(elapsed), "create": .number(Double(created)),
                "text": .number(Double(texts)), "nodes": .number(Double(created + texts)),
                "ops": .number(Double(ops.count)), "bytes": .number(Double(line.text.utf8.count)),
            ])
    }

    // What kept a real first batch from arriving, or nil when one came with its ops.
    private static func firstBatchProblem(delivered: Bool, _ line: HostLine?) -> String? {
        guard delivered else { return "the code line didn't go in" }
        guard let line else { return "no batch within 10 s" }
        guard line.type == "batch", line.json?["ops"]?.array != nil else {
            return "the first line after the code wasn't a batch"
        }
        return nil
    }

    // The footprint only counts once a real first tree is in, because a host that never rendered
    // is small for the wrong reason.
    private static func footprintFirstTree(_ bytes: UInt64?, problem: String?) -> Check {
        var fields = footprintFields(bytes)
        if let problem { fields["error"] = .string(problem) }
        let small = bytes.map { $0 <= footprintLimit } ?? false
        return Check(
            name: "footprintFirstTree", passed: problem == nil && small, value: .object(fields))
    }

    // The module logs "globals " and then the typeof of each name as JSON, and every one must be
    // missing. The names are listed here too, so a line that leaves one out can't pass.
    private static func globals(_ line: HostLine?) -> Check {
        guard let text = line?.logText else {
            return Check(
                name: "globals", passed: false,
                value: ["error": "no globals line within 2 s of the code"])
        }
        let json = try? JSONDecoder().decode(
            JSON.self, from: Data(text.dropFirst("globals ".count).utf8))
        guard let json else {
            return Check(
                name: "globals", passed: false,
                value: ["error": "the globals line isn't JSON", "line": .string(text)])
        }
        return Check(
            name: "globals", passed: globalNames.allSatisfy { json[$0] == "undefined" },
            value: json)
    }

    // The module tries to import a data URL that any working loader could load, so a host with a
    // loader logs "import allowed" and fails. The line can come before or after the first batch.
    private static func importRejected(_ line: HostLine?, sent: ContinuousClock.Instant) -> Check {
        guard let line else {
            return Check(
                name: "importRejected", passed: false,
                value: ["error": "no import line within 2 s of the code"])
        }
        let elapsed = line.at - sent
        return Check(
            name: "importRejected",
            passed: line.logText.hasPrefix("import rejected") && elapsed <= startLinesLimit,
            value: ["ms": milliseconds(elapsed), "text": .string(line.logText)])
    }

    // 1,000 pings, one at a time, each timed from its write to the moment its pong is read.
    private static func roundTrip(_ host: HostProcess) -> Check {
        var times: [Duration] = []
        var problem: String?
        for id in 1...pings {
            let start = ContinuousClock.now
            let ping = lineBytes(["type": "ping", "id": .number(Double(id))])
            guard host.send(ping, by: start + replyWait) == ping.count else {
                problem = "ping \(id) didn't go in"
                break
            }
            guard let reply = host.next(by: start + replyWait) else {
                problem = "no pong for ping \(id) within 2 s"
                break
            }
            guard reply.type == "pong", reply.json?["id"] == .number(Double(id)) else {
                problem = "ping \(id) got \(reply.text)"
                break
            }
            times.append(reply.at - start)
        }
        times.sort()
        let median = percentile(times, 0.5)
        var fields: [String: JSON] = [
            "pongs": .number(Double(times.count)), "p50Ms": median.map(milliseconds) ?? .null,
            "p90Ms": percentile(times, 0.9).map(milliseconds) ?? .null,
            "p99Ms": percentile(times, 0.99).map(milliseconds) ?? .null,
            "maxMs": times.last.map(milliseconds) ?? .null,
        ]
        if let problem { fields["error"] = .string(problem) }
        return Check(
            name: "roundTrip",
            passed: problem == nil && median.map { $0 <= roundTripLimit } == true,
            value: .object(fields))
    }

    // 1,000 clicks on the first card's button, each waiting for its batch, then the footprint.
    // The button's text counts the clicks, so the last setText should read 1000.
    private static func clicks(_ host: HostProcess, handler: Int?) -> Check {
        guard let handler else {
            return Check(
                name: "footprintAfterEvents", passed: false,
                value: ["error": "the first tree has no Button with an onPress handler"])
        }
        let started = ContinuousClock.now
        var batches = 0
        var lastText: JSON = .null
        var problem: String?
        for number in 1...clicks {
            let start = ContinuousClock.now
            let event = lineBytes([
                "type": "event", "handler": .number(Double(handler)), "value": .null,
            ])
            guard host.send(event, by: start + replyWait) == event.count else {
                problem = "click \(number) didn't go in"
                break
            }
            guard let reply = host.next(by: start + replyWait), reply.type == "batch",
                let ops = reply.json?["ops"]?.array
            else {
                problem = "click \(number) got no batch within 2 s"
                break
            }
            batches += 1
            if let op = ops.last, op[0] == "setText" { lastText = op[2] ?? .null }
        }
        let elapsed = ContinuousClock.now - started
        let footprint = host.footprint
        var fields = footprintFields(footprint)
        fields["clicks"] = .number(Double(clicks))
        fields["batches"] = .number(Double(batches))
        fields["lastText"] = lastText
        fields["clicksMs"] = milliseconds(elapsed)
        if let problem { fields["error"] = .string(problem) }
        let small = footprint.map { $0 <= footprintLimit } ?? false
        return Check(
            name: "footprintAfterEvents", passed: problem == nil && batches == clicks && small,
            value: .object(fields))
    }

    // Everything the main host wrote on stderr in its whole run, which must be nothing:
    // JavaScriptCore writes there about an option it doesn't know, and the host must never write
    // anything but its protocol lines.
    private static func stderrEmpty(_ host: HostProcess) -> Check {
        host.closeInput()
        _ = host.waitForExit(by: .now + replyWait)
        host.stop()
        let text = String(decoding: host.errorBytes, as: UTF8.self)
        return Check(name: "stderrEmpty", passed: text.isEmpty, value: .string(text))
    }

    // A second host gets a code line of 9 MB, over the 8 MB cap, and has to end with exit 73 in
    // 2 s rather than hold on to it.
    private func oversizedLine() -> Check {
        let name = "oversizedLine"
        let host: HostProcess
        do {
            host = try startAndGreet()
        } catch {
            return Check(name: name, passed: false, value: ["error": .string(error.message)])
        }
        defer { host.stop() }
        let line = Self.oversizedCodeLine()
        let sent = ContinuousClock.now
        let written = host.send(line, by: sent + Self.oversizedLimit)
        let exit = host.waitForExit(by: sent + Self.oversizedLimit)
        let elapsed = host.exitedAt.map { $0 - sent }
        return Check(
            name: name,
            passed: exit == .exited(73) && elapsed.map { $0 <= Self.oversizedLimit } == true,
            value: [
                "exit": exit?.json ?? "running", "ms": elapsed.map(Self.milliseconds) ?? .null,
                "lineBytes": .number(Double(line.count)), "sentBytes": .number(Double(written)),
            ])
    }

    // A third host has its stdin closed after the hello, as when its parent goes away, and has
    // to end with exit 0 within 1 s.
    private func stdinClosed() -> Check {
        let name = "stdinClosed"
        let host: HostProcess
        do {
            host = try startAndGreet()
        } catch {
            return Check(name: name, passed: false, value: ["error": .string(error.message)])
        }
        defer { host.stop() }
        let closed = ContinuousClock.now
        host.closeInput()
        let exit = host.waitForExit(by: closed + Self.stdinClosedLimit)
        let elapsed = host.exitedAt.map { $0 - closed }
        return Check(
            name: name,
            passed: exit == .exited(0) && elapsed.map { $0 <= Self.stdinClosedLimit } == true,
            value: ["exit": exit?.json ?? "running", "ms": elapsed.map(Self.milliseconds) ?? .null])
    }

    // Starts a host and waits for its hello, so the check after it starts from a host that's
    // ready for input.
    private func startAndGreet() throws(HostStartError) -> HostProcess {
        let host = try HostProcess.start(hostPath)
        guard host.next(by: host.startedAt + Self.helloWait)?.type == "hello" else {
            let state = String(decoding: host.state.encodedLine(), as: UTF8.self)
            host.stop()
            throw HostStartError(message: "no hello within 5 s, host \(state)")
        }
        return host
    }

    // The button of the first card, which the first batch creates with its onPress handler.
    private static func buttonHandler(_ line: HostLine?) -> Int? {
        for op in line?.json?["ops"]?.array ?? [] where op[0] == "create" && op[2] == "Button" {
            if let handler = op[3]?["onPress"]?["$fn"]?.number { return Int(handler) }
        }
        return nil
    }

    // A code line of exactly 9 MB with its newline. It's valid JSON, so only its size can make
    // the host refuse it.
    private static func oversizedCodeLine() -> [UInt8] {
        let head = Array(#"{"type":"code","source":""#.utf8)
        let tail = Array("\"}\n".utf8)
        let filler = oversizedBytes - head.count - tail.count
        return head + [UInt8](repeating: UInt8(ascii: "a"), count: filler) + tail
    }

    private static func lineBytes(_ message: JSON) -> [UInt8] {
        message.encodedLine() + [UInt8(ascii: "\n")]
    }

    private static func footprintFields(_ bytes: UInt64?) -> [String: JSON] {
        guard let bytes else { return ["error": "proc_pid_rusage failed"] }
        let megabytes = Double(bytes) / 1_048_576
        return ["bytes": .number(Double(bytes)), "mb": .number((megabytes * 100).rounded() / 100)]
    }

    // The nearest-rank percentile of sorted times.
    private static func percentile(_ sorted: [Duration], _ fraction: Double) -> Duration? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((Double(sorted.count) * fraction).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    // A duration in milliseconds, to the microsecond.
    private static func milliseconds(_ duration: Duration) -> JSON {
        let (seconds, attoseconds) = duration.components
        let value = Double(seconds) * 1000 + Double(attoseconds) / 1e15
        return .number((value * 1000).rounded() / 1000)
    }
}
