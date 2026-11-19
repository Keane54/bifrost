import Foundation

@testable import BifrostHealth

// The shared helpers of the Performance tests.

// A size in bytes from a number of MB (1 MB is 1,048,576 bytes).
func mb(_ count: Double) -> UInt64 {
    UInt64((count * 1_048_576).rounded())
}

// The pid of the app and of two chat terminals in the fake tables.
let appPID: pid_t = 10
let terminalPID: pid_t = 20
let secondTerminalPID: pid_t = 21

// A table read at the time: the app and the chat terminals, each with its memory in MB and its
// CPU time in seconds since its start.
func tableRead(
    at seconds: Int, app: (memory: Double, cpu: Double),
    terminals: [(pid: pid_t, memory: Double, cpu: Double)] = []
) -> TableRead {
    var table = [
        ProcessSample(
            pid: appPID, parent: 1, footprint: mb(app.memory), cpuTime: .seconds(app.cpu))
    ]
    for terminal in terminals {
        table.append(
            ProcessSample(
                pid: terminal.pid, parent: appPID, footprint: mb(terminal.memory),
                cpuTime: .seconds(terminal.cpu)))
    }
    return TableRead(at: .seconds(seconds), table)
}

// A history with one tick each 15 s from 0 s to the last time. The app memory at each tick comes
// from the function (MB), and the app CPU time grows by the CPU of the tick (percent of one core).
func history(
    until last: Int, every step: Int = 15, cpu: Double = 0,
    memory: (Int) -> Double = { _ in 300 }
) -> SampleHistory {
    var history = SampleHistory()
    var cpuSeconds = 0.0
    for at in stride(from: 0, through: last, by: step) {
        history.add(
            tableRead(at: at, app: (memory(at), cpuSeconds)), app: appPID, terminals: [])
        cpuSeconds += Double(step) * cpu / 100
    }
    return history
}
