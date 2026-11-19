// The sample history of the Performance monitor (docs/behaviour/health.md, "Performance").
import Foundation
import Testing

@testable import BifrostHealth

@Suite("performance samples")
struct SamplesTests {
    @Test func theFirstTickAddsNoSample() throws {
        var history = SampleHistory()
        history.add(
            tableRead(at: 0, app: (400, 10), terminals: [(terminalPID, 150, 2)]), app: appPID,
            terminals: [terminalPID])
        // The first read has no earlier CPU time, so it gives no CPU and no sample.
        #expect(history.samples.isEmpty)
        #expect(history.lastRead?.at == .zero)
        history.add(
            tableRead(at: 15, app: (420, 11.5), terminals: [(terminalPID, 160, 2.3)]),
            app: appPID, terminals: [terminalPID])
        let sample = try #require(history.newest)
        #expect(history.samples.count == 1)
        #expect(sample.at == .seconds(15))
        #expect(sample.use.app == Use(memory: mb(420), cpu: 10))
        #expect(sample.use.terminals.memory == mb(160))
        #expect(abs(sample.use.terminals.cpu - 2) < 0.000_001)
        #expect(sample.use.terminalCount == 1)
        #expect(sample.use.largestTerminal == mb(160))
        #expect(sample.use.total.memory == mb(580))
    }

    @Test func aTerminalOfTheFirstReadCountsNoCPU() throws {
        var history = SampleHistory()
        history.add(tableRead(at: 0, app: (400, 10)), app: appPID, terminals: [])
        history.add(
            tableRead(at: 15, app: (400, 10), terminals: [(terminalPID, 150, 30)]), app: appPID,
            terminals: [terminalPID])
        let sample = try #require(history.newest)
        #expect(sample.use.terminals == Use(memory: mb(150), cpu: 0))
    }

    @Test func aReadWithNoAppProcessAddsNoSample() {
        var history = SampleHistory()
        history.add(tableRead(at: 0, app: (400, 10)), app: appPID, terminals: [])
        history.add(TableRead(at: .seconds(15), []), app: appPID, terminals: [])
        #expect(history.samples.isEmpty)
    }

    @Test func aGapClearsTheHistory() {
        var samples = history(until: 30)
        #expect(samples.samples.count == 2)
        // The Mac slept: the next read comes 61 s after the last one.
        samples.add(tableRead(at: 91, app: (300, 0)), app: appPID, terminals: [])
        #expect(samples.samples.isEmpty)
        // The read after the gap starts the CPU again, so the next tick gives a sample.
        samples.add(tableRead(at: 106, app: (300, 0)), app: appPID, terminals: [])
        #expect(samples.samples.map(\.at) == [.seconds(106)])
        // A gap of exactly 60 s is no gap.
        samples.add(tableRead(at: 166, app: (300, 0)), app: appPID, terminals: [])
        #expect(samples.samples.count == 2)
    }

    @Test func theTrendNeedsAFullHour() throws {
        // The memory grows by 10 MB each minute: 600 MB an hour.
        let growing: (Int) -> Double = { 300 + Double($0) / 6 }
        // The first sample is at 15 s, so at 60 min the samples cover 59 min 45 s.
        let early = history(until: 3600, memory: growing)
        #expect(early.growth(at: .seconds(3600)) == nil)
        let full = history(until: 3615, memory: growing)
        let growth = try #require(full.growth(at: .seconds(3615)))
        #expect(abs(growth - Double(mb(600))) < 1)
        // One step in the memory gives no trend before the full hour.
        let step = history(until: 1800) { $0 < 900 ? 300 : 1300 }
        #expect(step.growth(at: .seconds(1800)) == nil)
    }

    @Test func theHistoryKeepsOneSampleBeforeTheHour() {
        let long = history(until: 7200)
        #expect(long.samples.first?.at == .seconds(3600))
        #expect(long.samples.count == 241)
    }

    @Test func theCPUAverageNeedsTwoMinutes() throws {
        let short = history(until: 120, cpu: 80)
        // The first sample is at 15 s, so the samples cover only 105 s.
        #expect(short.averageCPU(at: .seconds(120)) == nil)
        let covered = history(until: 135, cpu: 80)
        let average = try #require(covered.averageCPU(at: .seconds(135)))
        #expect(abs(average - 80) < 0.000_001)
    }

    // Ticks each 15 s at 10 % CPU, then the panel opens: ticks each 2 s at 100 %. Each sample
    // counts for the part of its interval in the last 2 minutes, so the short ticks do not take
    // most of the weight.
    @Test func theCPUAverageCountsEachSampleForItsInterval() throws {
        var samples = SampleHistory()
        var cpuSeconds = 0.0
        var last = 0
        for at in Array(stride(from: 0, through: 135, by: 15)) + [137, 139, 141, 143, 145] {
            cpuSeconds += Double(at - last) * (at <= 135 ? 0.1 : 1)
            last = at
            samples.add(tableRead(at: at, app: (300, cpuSeconds)), app: appPID, terminals: [])
        }
        let average = try #require(samples.averageCPU(at: .seconds(145)))
        // (10 % for 110 s + 100 % for 10 s) / 120 s.
        #expect(abs(average - 17.5) < 0.000_001)
    }

    @Test func theTrendLineHasTheLast10Minutes() {
        let long = history(until: 1200)
        let line = long.trend(at: .seconds(1200))
        #expect(line.first?.at == .seconds(600))
        #expect(line.last?.at == .seconds(1200))
    }
}
