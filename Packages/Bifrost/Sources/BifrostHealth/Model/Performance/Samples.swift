import Foundation

// The samples of the Performance monitor (docs/behaviour/health.md, "Performance"): the use of
// Bifrost at each tick, and the history of the last hour that the checks read.

// One process of one read of the process table (ProcessTable).
package struct ProcessSample: Sendable, Equatable {
    package var pid: pid_t
    package var parent: pid_t
    // The memory of the process in bytes: its physical footprint, as Activity Monitor shows it.
    package var footprint: UInt64
    // The CPU time of the process since its start: user and system.
    package var cpuTime: Duration

    package init(pid: pid_t, parent: pid_t, footprint: UInt64, cpuTime: Duration) {
        self.pid = pid
        self.parent = parent
        self.footprint = footprint
        self.cpuTime = cpuTime
    }
}

// The memory and the CPU of a process or of a group of processes. The memory is in bytes. The CPU
// is in percent of one core, as Activity Monitor shows it, so a total can be above 100.
package struct Use: Sendable, Equatable {
    package static let zero = Use(memory: 0, cpu: 0)

    package var memory: UInt64
    package var cpu: Double

    package init(memory: UInt64, cpu: Double) {
        self.memory = memory
        self.cpu = cpu
    }

    package static func + (a: Use, b: Use) -> Use {
        Use(memory: a.memory + b.memory, cpu: a.cpu + b.cpu)
    }
}

// One read of the process table at a time of the timeline of the monitor. The CPU of a process
// comes from two reads: the change of its CPU time over the time between them.
package struct TableRead: Sendable {
    package let at: Duration
    package let processes: [pid_t: ProcessSample]

    // A pid that is in the table two times keeps its last process.
    package init(at: Duration, _ table: [ProcessSample]) {
        self.at = at
        processes = Dictionary(table.map { ($0.pid, $0) }) { _, last in last }
    }

    // The CPU of the process since the earlier read, in percent of one core. nil when the earlier
    // read has no such process, when the CPU time went down (the system gave the pid to a new
    // process) or when no time passed between the reads.
    package func cpu(of pid: pid_t, since earlier: TableRead?) -> Double? {
        guard let earlier, let now = processes[pid], let before = earlier.processes[pid],
            now.cpuTime >= before.cpuTime, at > earlier.at
        else { return nil }
        return (now.cpuTime - before.cpuTime) / (at - earlier.at) * 100
    }
}

// The use of Bifrost at one tick: the process of the app and its chat terminals. A chat terminal
// is a terminal process of the PTY manager: the attach of a chat window or a hidden attach of the
// session input.
package struct BifrostUse: Sendable, Equatable {
    package var app: Use
    package var terminals: Use
    package var terminalCount: Int
    // The memory of the largest chat terminal, or 0 with no chat terminal.
    package var largestTerminal: UInt64

    // The app and its chat terminals together.
    package var total: Use { app + terminals }
}

// The use of Bifrost at one tick of the timeline.
package struct Sample: Sendable, Equatable {
    package var at: Duration
    package var use: BifrostUse
    // The time from the read before to this read: the time of the CPU values.
    package var span: Duration
}

// The samples of the last hour. The memory and CPU checks read them, and the trend line of the
// panel shows the last 10 minutes. The history is in memory only.
package struct SampleHistory: Sendable {
    // A read more than this time after the last read clears the history first, for example after
    // a sleep of the Mac or a long failure of the reads. The ticks are 15 s at most, so a normal
    // tick never clears the history.
    package static let gap = Duration.seconds(60)
    // The growth check needs samples for the full hour, so one step in the memory gives no trend.
    package static let growthSpan = Duration.seconds(3600)
    // The CPU check uses the average of this time.
    package static let cpuSpan = Duration.seconds(120)
    // The trend line of the panel shows this time.
    package static let trendSpan = Duration.seconds(600)

    package private(set) var samples: [Sample] = []
    // The last read: the CPU of the next read comes from it.
    package private(set) var lastRead: TableRead?

    package init() {}

    package var newest: Sample? { samples.last }

    // Add the use of the app and the chat terminals at the read. The CPU needs an earlier read,
    // so the first read and the first read after a gap only start the CPU: they add no sample. A
    // read with no app process adds no sample either. A chat terminal with no earlier CPU time
    // counts 0 % CPU.
    package mutating func add(_ read: TableRead, app: pid_t, terminals: [pid_t]) {
        defer { lastRead = read }
        guard let earlier = lastRead, read.at - earlier.at <= Self.gap else {
            samples = []
            return
        }
        guard let process = read.processes[app], let appCPU = read.cpu(of: app, since: earlier)
        else { return }
        var use = BifrostUse(
            app: Use(memory: process.footprint, cpu: appCPU), terminals: .zero,
            terminalCount: terminals.count, largestTerminal: 0)
        for pid in terminals {
            let memory = read.processes[pid]?.footprint ?? 0
            let cpu = read.cpu(of: pid, since: earlier) ?? 0
            use.terminals = use.terminals + Use(memory: memory, cpu: cpu)
            use.largestTerminal = max(use.largestTerminal, memory)
        }
        samples.append(Sample(at: read.at, use: use, span: read.at - earlier.at))
        // Keep the newest sample before the hour: it shows that the samples cover the full hour.
        let start = read.at - Self.growthSpan
        while samples.count > 1, samples[1].at <= start { samples.removeFirst() }
    }

    // Forget all samples and the last read.
    package mutating func clear() {
        samples = []
        lastRead = nil
    }

    // The least-squares slope of the memory of the app (the chat terminals not included) over the
    // last hour, in bytes per hour. nil until the samples cover the full hour.
    package func growth(at now: Duration) -> Double? {
        guard let oldest = samples.first, now - oldest.at >= Self.growthSpan else { return nil }
        let used = samples.filter { $0.at >= now - Self.growthSpan }
        guard used.count >= 2 else { return nil }
        let times = used.map { $0.at / .seconds(3600) }
        let values = used.map { Double($0.use.app.memory) }
        let meanTime = times.reduce(0, +) / Double(used.count)
        let meanValue = values.reduce(0, +) / Double(used.count)
        var covariance = 0.0
        var variance = 0.0
        for (time, value) in zip(times, values) {
            covariance += (time - meanTime) * (value - meanValue)
            variance += (time - meanTime) * (time - meanTime)
        }
        return variance > 0 ? covariance / variance : nil
    }

    // The average CPU of the app (the chat terminals not included) over the last 2 minutes. nil
    // until the samples cover the 2 minutes. Each sample counts for the part of its span in the 2
    // minutes, so the short ticks while the panel shows do not take most of the weight.
    package func averageCPU(at now: Duration) -> Double? {
        guard let oldest = samples.first, now - oldest.at >= Self.cpuSpan else { return nil }
        let start = now - Self.cpuSpan
        var weighted = 0.0
        var total = 0.0
        for sample in samples where sample.at > start {
            let seconds = (sample.at - max(sample.at - sample.span, start)) / .seconds(1)
            weighted += sample.use.app.cpu * seconds
            total += seconds
        }
        return total > 0 ? weighted / total : nil
    }

    // The samples of the trend line: the last 10 minutes.
    package func trend(at now: Duration) -> [Sample] {
        samples.filter { $0.at >= now - Self.trendSpan }
    }
}
