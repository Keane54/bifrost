import Foundation
import Synchronization

// Runs a program and gives each line of its stdout to a test, until the test accepts a line. Then
// the program stops. The probe of the MCP servers of the Daily update uses it: the first event of
// claude holds the servers and their tools, and the probe needs nothing after it
// (docs/behaviour/process.md, "Stopping at the first line that fits").
//
// The run uses the one process core of the app (Execution, as ProcessRunner does): the start, the
// output limit, the time limit on the clock, the kill signal and the grace of the command. Only
// the split of stdout into lines is here.
// - A line ends at each LF. A CR before the LF is not part of the line. The text after the last
//   LF is the last line when the program ends by itself. An empty line goes to no test.
// - stdin is empty and closed, as for each command with no input.
// - The program stops at the accepted line, at the time limit, at the output limit and at a
//   cancel of the caller. Each stop sends the kill signal of the command, and a SIGTERM turns into
//   SIGKILL after the grace of the command.
// - The call returns after the end of the program: it waits for the end also after a stop and
//   a cancel. The kill signal goes to the program only, so a child of the program can outlive it.
// - After a stop the call does not wait for the end of stdout. When the program ends by itself
//   with no accepted line while a child of it keeps stdout open, the call ends at the time limit.
package enum ProcessLines {
    // The accepted line, or nil: the program ended or stopped with no accepted line, or it did
    // not start.
    @concurrent package static func firstLine(
        _ command: Command, clock: any Clock<Duration> = ContinuousClock(),
        where accept: @Sendable (String) -> Bool
    ) async -> String? {
        var command = command
        command.waitsForEnd = true
        // The call waits for the end of the program, so a SIGTERM always has a grace and then a
        // SIGKILL: a program that ignores SIGTERM cannot hold the call.
        if command.killSignal == .terminate, command.terminateGrace == nil {
            command.terminateGrace = Command.defaultTerminateGrace
        }
        let (lines, sink) = AsyncStream<String>.makeStream()
        let splitter = LineSplitter(sink: sink)
        let execution = Execution(command, clock: clock) { splitter.add($0) }
        return await withTaskExecutorPreference(BlockingExecutor.shared) {
            await withTaskCancellationHandler {
                await withTaskGroup(of: Void.self, returning: String?.self) { group in
                    group.addTask {
                        _ = await execution.run()
                        splitter.end(lastLine: !execution.wasStopped)
                    }
                    var accepted: String?
                    for await line in lines where accept(line) {
                        accepted = line
                        break
                    }
                    // The run gives its result when the program ended.
                    execution.stop(.requested)
                    await group.waitForAll()
                    return accepted
                }
            } onCancel: {
                execution.stop(.cancelled)
            }
        }
    }
}

// The split of stdout into lines. The chunks come in order from the read queue of the run.
private final class LineSplitter: Sendable {
    private let sink: AsyncStream<String>.Continuation
    // The bytes after the last LF.
    private let partial = Mutex(Data())

    init(sink: AsyncStream<String>.Continuation) {
        self.sink = sink
    }

    func add(_ chunk: Data) {
        let lines = partial.withLock { bytes -> [String] in
            bytes.append(chunk)
            var lines: [String] = []
            while let end = bytes.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(Self.text(bytes[bytes.startIndex..<end]))
                bytes.removeSubrange(bytes.startIndex...end)
            }
            return lines
        }
        for line in lines where !line.isEmpty { sink.yield(line) }
    }

    // The end of the run. lastLine: the program ended by itself, so the text after the last LF
    // is the last line. After a stop, that text is a part of a line, so it goes nowhere.
    func end(lastLine: Bool) {
        let last = partial.withLock { bytes -> String? in
            defer { bytes = Data() }
            return lastLine && !bytes.isEmpty ? Self.text(bytes) : nil
        }
        if let last, !last.isEmpty { sink.yield(last) }
        sink.finish()
    }

    // The UTF-8 text of a line, with no CR at its end. A byte that is not UTF-8 becomes U+FFFD.
    private static func text(_ bytes: Data) -> String {
        let line = bytes.last == UInt8(ascii: "\r") ? bytes.dropLast() : bytes[...]
        return String(decoding: line, as: UTF8.self)
    }
}
