// The speech helper of Bifrost. It turns speech from the microphone into text on this Mac.
// Bifrost starts it and writes one command on each line to stdin: start, stop or quit. The helper
// writes one JSON event on each line to stdout (src/shared/dictation-protocol.ts). Notes for the
// log go to stderr. The helper never saves audio and never sends audio or text off the Mac.
import Foundation

// A closed stdout gives a write error, not a signal. Out then stops the helper.
signal(SIGPIPE, SIG_IGN)

// Set when quit or the end of stdin comes. After that, a start does nothing.
final class Closing: @unchecked Sendable {
  private let lock = NSLock()
  private var closing = false
  var isSet: Bool { lock.guarded { closing } }
  func set() { lock.guarded { closing = true } }
}

let closing = Closing()
var commandInput: AsyncStream<String>.Continuation!
let commands = AsyncStream<String> { commandInput = $0 }

Task { @MainActor in
  let helper = Helper()
  await helper.boot()
  // One command at a time, in order.
  for await command in commands {
    if command == "start" && closing.isSet { continue }
    await helper.handle(command)
  }
  helper.close()
  Out.flush()
  exit(0)
}

// Read stdin on its own thread. The end of stdin means that Bifrost closed the pipe or stopped.
Thread {
  while let line = readLine() {
    let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if command == "quit" { break }
    if !command.isEmpty { commandInput.yield(command) }
  }
  closing.set()
  commandInput.finish()
  // Stop after 2 s also when a command does not end, for example a start that waits for macOS.
  DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
    Out.flush()
    exit(0)
  }
}.start()

RunLoop.main.run()
