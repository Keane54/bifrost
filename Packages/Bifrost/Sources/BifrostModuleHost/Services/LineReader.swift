import BifrostModuleHostCore
import Foundation

// Reads stdin on its own thread and hands each message to the main actor, where the module's
// JavaScript lives. It waits for each message to be handled before it reads on, so a busy module
// leaves the rest in the pipe and the parent feels the back-pressure.
enum LineReader {
    static func run(handingTo engine: ModuleEngine) -> Never {
        var line: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var codeArrived = false
        while true {
            let count = read(0, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { HostExit.inputClosed.end() }
            var start = 0
            while let newline = chunk[start..<count].firstIndex(of: UInt8(ascii: "\n")) {
                line.append(contentsOf: chunk[start..<newline])
                let message = decode(line, codeArrived: codeArrived)
                if case .code = message { codeArrived = true }
                DispatchQueue.main.sync { engine.handle(message) }
                line.removeAll(keepingCapacity: true)
                start = newline + 1
            }
            line.append(contentsOf: chunk[start..<count])
            // The cap holds while a line is still coming in, so a line with no end can't grow the
            // host's memory past it.
            if line.count > cap(codeArrived: codeArrived) { HostExit.badLine.end() }
        }
    }

    // Until the code has arrived a line may be as long as the code line, and after that every
    // line gets the small cap.
    private static func cap(codeArrived: Bool) -> Int {
        codeArrived ? HostLimits.lineBytes : HostLimits.codeLineBytes
    }

    // A line that doesn't decode, or that breaks its cap once its type is known, ends the host.
    // So does a second code line, because the parent sends the code once and a host that ran two
    // modules would mix them in one context.
    private static func decode(_ line: [UInt8], codeArrived: Bool) -> HostMessage {
        guard line.count <= cap(codeArrived: codeArrived),
            let message = try? JSONDecoder().decode(HostMessage.self, from: Data(line))
        else { HostExit.badLine.end() }
        if case .code = message {
            if codeArrived { HostExit.badLine.end() }
        } else if line.count > HostLimits.lineBytes {
            HostExit.badLine.end()
        }
        return message
    }
}
